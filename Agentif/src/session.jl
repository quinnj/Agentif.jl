abstract type SessionStore end

@kwarg struct SessionEntry
    id::Union{Nothing, String} = nothing
    created_at::Float64 = time()
    messages::Vector{AgentMessage} = AgentMessage[]
    is_compaction::Bool = false
    is_deleted::Bool = false
    user_id::Union{Nothing, String} = nothing
    post_id::Union{Nothing, String} = nothing
    channel_id::Union{Nothing, String} = nothing
    channel_flags::Union{Nothing, Int} = nothing
end

mutable struct InMemorySessionStore <: SessionStore
    lock::ReentrantLock
    sessions::Dict{String, AgentState}
    entries::Dict{String, Vector{SessionEntry}}
end

InMemorySessionStore() = InMemorySessionStore(ReentrantLock(), Dict{String, AgentState}(), Dict{String, Vector{SessionEntry}}())

mutable struct FileSessionStore <: SessionStore
    directory::String
    lock::ReentrantLock
    offsets::Dict{String, Vector{Int64}}
    counts::Dict{String, Int64}
    indexed::Set{String}
end

function FileSessionStore(directory::AbstractString)
    dir = abspath(directory)
    mkpath(dir)
    return FileSessionStore(dir, ReentrantLock(), Dict{String, Vector{Int64}}(), Dict{String, Int64}(), Set{String}())
end

# Stubs for package extension (AgentifSQLiteExt)
function SQLiteSessionStore end
function init_sqlite_session_schema! end

function ensure_session_id(session_id::String)
    isempty(session_id) && throw(ArgumentError("session_id is required"))
    occursin(r"[\\/]", session_id) && throw(ArgumentError("session_id must not contain path separators: $session_id"))
    return session_id
end

function session_path(store::FileSessionStore, session_id::String)
    sid = ensure_session_id(session_id)
    return joinpath(store.directory, sid)
end

function apply_session_entry!(state::AgentState, entry::SessionEntry)
    if entry.is_compaction
        empty!(state.messages)
    end
    append!(state.messages, entry.messages)
    for msg in entry.messages
        msg isa AssistantMessage || continue
        msg.response_id !== nothing && (state.response_id = msg.response_id)
    end
    return state
end

function ensure_session_index!(store::FileSessionStore, session_id::String)
    session_id in store.indexed && return
    offsets = Int64[]
    count = 0
    path = session_path(store, session_id)
    if isfile(path)
        open(path, "r") do io
            while !eof(io)
                push!(offsets, position(io))
                readline(io)
                count += 1
            end
        end
    end
    store.offsets[session_id] = offsets
    store.counts[session_id] = count
    push!(store.indexed, session_id)
    return
end

function session_entry_count(store::InMemorySessionStore, session_id::String)
    return lock(store.lock) do
        entries = get(() -> SessionEntry[], store.entries, session_id)
        return length(entries)
    end
end

function session_entry_count(store::FileSessionStore, session_id::String)
    return lock(store.lock) do
        ensure_session_index!(store, session_id)
        return get(() -> 0, store.counts, session_id)
    end
end

function session_entries(store::InMemorySessionStore, session_id::String; start::Int = 1, limit::Union{Nothing, Int} = nothing)
    return lock(store.lock) do
        entries = get(() -> SessionEntry[], store.entries, session_id)
        total = length(entries)
        total == 0 && return SessionEntry[]
        start = max(1, start)
        stop = limit === nothing ? total : min(total, start + limit - 1)
        stop < start && return SessionEntry[]
        return entries[start:stop]
    end
end

function session_entries(store::FileSessionStore, session_id::String; start::Int = 1, limit::Union{Nothing, Int} = nothing)
    return lock(store.lock) do
        ensure_session_index!(store, session_id)
        total = get(() -> 0, store.counts, session_id)
        total == 0 && return SessionEntry[]
        start = max(1, start)
        stop = limit === nothing ? total : min(total, start + limit - 1)
        stop < start && return SessionEntry[]
        offsets = get(() -> Int64[], store.offsets, session_id)
        path = session_path(store, session_id)
        entries = SessionEntry[]
        isfile(path) || return entries
        open(path, "r") do io
            final_idx = min(stop, length(offsets))
            for idx in start:final_idx
                seek(io, offsets[idx])
                line = readline(io)
                isempty(strip(line)) && continue
                parsed = try
                    JSON.parse(line, SessionEntry)
                catch e
                    @warn "Skipping invalid session entry line" session_id index=idx error=sprint(showerror, e)
                    nothing
                end
                parsed === nothing && continue
                push!(entries, parsed)
            end
        end
        return entries
    end
end

function load_session(store::InMemorySessionStore, session_id::String)
    return lock(store.lock) do
        return get!(store.sessions, session_id) do
            state = AgentState()
            entries = get(() -> SessionEntry[], store.entries, session_id)
            for entry in entries
                apply_session_entry!(state, entry)
            end
            state
        end
    end
end

function load_session(store::FileSessionStore, session_id::String)
    entries = session_entries(store, session_id)
    state = AgentState()
    for entry in entries
        apply_session_entry!(state, entry)
    end
    return state
end

function append_session_entry!(store::InMemorySessionStore, session_id::String, entry::SessionEntry)
    lock(store.lock) do
        entries = get!(() -> SessionEntry[], store.entries, session_id)
        push!(entries, entry)
        state = get!(() -> AgentState(), store.sessions, session_id)
        apply_session_entry!(state, entry)
    end
    return
end

function append_session_entry!(store::FileSessionStore, session_id::String, entry::SessionEntry)
    lock(store.lock) do
        path = session_path(store, session_id)
        mkpath(dirname(path))
        open(path, "a+") do io
            seekend(io)
            offset = position(io)
            write(io, JSON.json(entry))
            write(io, '\n')
            flush(io)
            if session_id in store.indexed
                offsets = get!(() -> Int64[], store.offsets, session_id)
                push!(offsets, offset)
                store.counts[session_id] = get(() -> 0, store.counts, session_id) + 1
            end
        end
    end
    return
end

function save_session!(store::InMemorySessionStore, session_id::String, state::AgentState)
    lock(store.lock) do
        store.sessions[session_id] = state
        entry = SessionEntry(; id = nothing, created_at = time(), messages = copy(state.messages))
        store.entries[session_id] = [entry]
    end
    return
end

function save_session!(store::FileSessionStore, session_id::String, state::AgentState)
    entry = SessionEntry(; id = nothing, created_at = time(), messages = copy(state.messages))
    path = session_path(store, session_id)
    lock(store.lock) do
        mkpath(dirname(path))
        tmp_path = string(path, ".tmp.", string(UID8()))
        open(tmp_path, "w") do io
            write(io, JSON.json(entry))
            write(io, '\n')
            flush(io)
        end
        mv(tmp_path, path; force = true)
        store.offsets[session_id] = [0]
        store.counts[session_id] = 1
        push!(store.indexed, session_id)
    end
    return
end

function new_session_id()
    return string(UID8())
end

# ─── Session search ───

struct SessionSearchResult
    session_id::String
    entry_text::String
    score::Float64
end

function _entry_search_text(entry::SessionEntry)
    parts = String[]
    for msg in entry.messages
        push!(parts, message_text(msg))
        if msg isa AssistantMessage
            thinking = message_thinking(msg)
            !isempty(thinking) && push!(parts, thinking)
        end
    end
    return join(parts, "\n")
end

function _matches_keywords(text::String, keywords::Vector{String})
    isempty(keywords) && return true
    text_lower = lowercase(text)
    return any(kw -> occursin(kw, text_lower), keywords)
end

function _keyword_score(text::String, keywords::Vector{String})
    text_lower = lowercase(text)
    return count(kw -> occursin(kw, text_lower), keywords) / length(keywords)
end

# Channel visibility: entry is visible if no channel context, or entry is from
# the current channel, or entry is from a public channel (is_private bit unset).
# Bitmask: 0x01 = is_private, 0x02 = is_group
function _visible_entry(entry::SessionEntry, current_channel_id::Union{Nothing, String})
    current_channel_id === nothing && return true
    entry.channel_id === nothing && return true
    entry.channel_flags === nothing && return true
    entry.channel_id == current_channel_id && return true
    (entry.channel_flags & 0x01) == 0 && return true
    return false
end

# Default: no results
search_sessions(store::SessionStore, query::String; limit::Int=10, current_channel_id::Union{Nothing, String}=nothing) = SessionSearchResult[]

function search_sessions(store::InMemorySessionStore, query::String; limit::Int=10, current_channel_id::Union{Nothing, String}=nothing)
    keywords = [lowercase(k) for k in split(strip(query); keepempty=false)]
    isempty(keywords) && return SessionSearchResult[]
    results = SessionSearchResult[]
    lock(store.lock) do
        for (sid, entries) in store.entries
            for entry in entries
                entry.is_deleted && continue
                _visible_entry(entry, current_channel_id) || continue
                text = _entry_search_text(entry)
                if _matches_keywords(text, keywords)
                    push!(results, SessionSearchResult(sid, text, _keyword_score(text, keywords)))
                end
            end
        end
    end
    sort!(results; by=r -> r.score, rev=true)
    return first(results, min(limit, length(results)))
end

function search_sessions(store::FileSessionStore, query::String; limit::Int=10, current_channel_id::Union{Nothing, String}=nothing)
    keywords = [lowercase(k) for k in split(strip(query); keepempty=false)]
    isempty(keywords) && return SessionSearchResult[]
    limit <= 0 && return SessionSearchResult[]
    results = SessionSearchResult[]
    files = lock(store.lock) do
        isdir(store.directory) || return String[]
        files = Tuple{String, Float64}[]
        for fname in readdir(store.directory)
            fpath = joinpath(store.directory, fname)
            isfile(fpath) || continue
            mtime = try
                stat(fpath).mtime
            catch
                0.0
            end
            push!(files, (fpath, mtime))
        end
        sort!(files; by = x -> x[2], rev = true)
        return [f[1] for f in files]
    end
    for fpath in files
        sid = basename(fpath)
        for line in eachline(fpath)
            isempty(strip(line)) && continue
            entry = try
                JSON.parse(line, SessionEntry)
            catch
                continue
            end
            entry.is_deleted && continue
            _visible_entry(entry, current_channel_id) || continue
            text = _entry_search_text(entry)
            if _matches_keywords(text, keywords)
                push!(results, SessionSearchResult(sid, text, _keyword_score(text, keywords)))
            end
            length(results) >= limit * 10 && break
        end
        length(results) >= limit * 10 && break
    end
    sort!(results; by=r -> r.score, rev=true)
    return first(results, min(limit, length(results)))
end

# Default no-op: scrub_post! is implemented by store types that support it
scrub_post!(store::SessionStore, post_id::String) = nothing
