abstract type SessionStore end

@kwarg struct SessionEntry
    id::Union{Nothing, String} = nothing
    created_at::Float64 = time()
    messages::Vector{AgentMessage} = AgentMessage[]
    is_compaction::Bool = false
end

JSON.lower(x::SessionEntry) = (; id = x.id, created_at = x.created_at, messages = x.messages, is_compaction = x.is_compaction)

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
            for idx in start:stop
                seek(io, offsets[idx])
                line = readline(io)
                isempty(strip(line)) && continue
                push!(entries, JSON.parse(line, SessionEntry))
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
        open(path, "w") do io
            write(io, JSON.json(entry))
            write(io, '\n')
        end
        store.offsets[session_id] = [0]
        store.counts[session_id] = 1
        push!(store.indexed, session_id)
    end
    return
end

function new_session_id()
    return string(UID8())
end
