abstract type SessionStore end

@kwarg struct SessionEntry
    id::String
    parent_id::Union{Nothing, String} = nothing
    created_at::Float64 = time()
    messages::Vector{StoredAgentMessage} = StoredAgentMessage[]
    is_compaction::Bool = false
    first_kept_entry_id::Union{Nothing, String} = nothing
    is_deleted::Bool = false
    user_id::Union{Nothing, String} = nothing
    channel_id::Union{Nothing, String} = nothing
    search_channel_id::Union{Nothing, String} = nothing
    channel_flags::Union{Nothing, Int} = nothing
end

struct EntryBoundary
    entry_id::String
    message_start::Int  # 1-based index into state.messages
    message_end::Int
end

mutable struct InMemorySessionStore <: SessionStore
    lock::ReentrantLock
    entries::Dict{String, SessionEntry}
    branches::Dict{String, String}
    branch_locks::Dict{String, ReentrantLock}
end

InMemorySessionStore() = InMemorySessionStore(ReentrantLock(), Dict{String, SessionEntry}(), Dict{String, String}(), Dict{String, ReentrantLock}())

# Stubs for package extension (AgentifSQLiteExt)
function SQLiteSessionStore end
function init_sqlite_session_schema! end

# ─── SessionStore interface ───

function append_entry! end
function get_entry end
function get_branch_leaf end
function set_branch_leaf! end
function lock_branch end

# ─── InMemorySessionStore implementations ───

function append_entry!(store::InMemorySessionStore, entry::SessionEntry)
    lock(store.lock) do
        store.entries[entry.id] = entry
    end
end

function get_entry(store::InMemorySessionStore, entry_id::String)
    return lock(store.lock) do
        get(store.entries, entry_id, nothing)
    end
end

function get_branch_leaf(store::InMemorySessionStore, branch_id::String)
    return lock(store.lock) do
        get(store.branches, branch_id, nothing)
    end
end

function set_branch_leaf!(store::InMemorySessionStore, branch_id::String, entry_id::String)
    lock(store.lock) do
        store.branches[branch_id] = entry_id
    end
end

function lock_branch(f::F, store::InMemorySessionStore, branch_id::String) where {F <: Function}
    branch_lock = lock(store.lock) do
        get!(store.branch_locks, branch_id) do
            ReentrantLock()
        end
    end
    return lock(branch_lock) do
        f()
    end
end

# ─── Lineage walk ───

function apply_session_entry!(state::AgentState, entry::SessionEntry)
    append!(state.messages, entry.messages)
    for msg in entry.messages
        msg isa AssistantMessage || continue
        msg.response_id !== nothing && (state.response_id = msg.response_id)
    end
    return state
end

function _collect_lineage(store::SessionStore, leaf_entry_id::String)
    entries = SessionEntry[]
    compaction_idx = 0
    stop_at = nothing
    current_id = leaf_entry_id

    while current_id !== nothing
        entry = get_entry(store, current_id)
        entry === nothing && break
        push!(entries, entry)

        if entry.is_compaction && compaction_idx == 0
            compaction_idx = length(entries)
            stop_at = entry.first_kept_entry_id
            if stop_at === nothing
                break  # everything compacted, no kept entries
            end
        elseif stop_at !== nothing && entry.id == stop_at
            break  # included the stop_at entry, done
        end

        current_id = entry.parent_id
    end

    # entries is leaf→root order, reverse to root→leaf
    reverse!(entries)

    # If compaction found, reorder: compaction FIRST, then kept, then post-compaction
    if compaction_idx > 0
        comp_pos = length(entries) - compaction_idx + 1
        compaction_entry = entries[comp_pos]
        kept = entries[1:comp_pos-1]
        post_compaction = entries[comp_pos+1:end]
        entries = vcat([compaction_entry], kept, post_compaction)
    end

    return entries
end

function load_branch(store::SessionStore, branch_id::String)
    leaf_id = get_branch_leaf(store, branch_id)
    leaf_id === nothing && return AgentState()
    entries = _collect_lineage(store, leaf_id)
    state = AgentState()
    for entry in entries
        apply_session_entry!(state, entry)
    end
    return state
end

function load_branch_with_boundaries(store::SessionStore, branch_id::String)
    leaf_id = get_branch_leaf(store, branch_id)
    if leaf_id === nothing
        return AgentState(), EntryBoundary[]
    end
    entries = _collect_lineage(store, leaf_id)
    state = AgentState()
    boundaries = EntryBoundary[]
    for entry in entries
        start_idx = length(state.messages) + 1
        apply_session_entry!(state, entry)
        end_idx = length(state.messages)
        if end_idx >= start_idx
            push!(boundaries, EntryBoundary(entry.id, start_idx, end_idx))
        end
    end
    return state, boundaries
end

# ─── Session search ───

struct SessionSearchResult
    entry_id::String
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

# Channel visibility: entry is visible if no search context, or entry shares the
# same base channel, or entry is from a public channel (is_private bit unset).
# Bitmask: 0x01 = is_private, 0x02 = is_group
function _visible_entry(entry::SessionEntry, current_search_channel_id::Union{Nothing, String})
    current_search_channel_id === nothing && return true
    entry.search_channel_id === nothing && return true
    entry.channel_flags === nothing && return true
    entry.search_channel_id == current_search_channel_id && return true
    (entry.channel_flags & 0x01) == 0 && return true
    return false
end

# Default: no results
search_sessions(store::SessionStore, query::String; limit::Int=10, current_search_channel_id::Union{Nothing, String}=nothing) = SessionSearchResult[]

function search_sessions(store::InMemorySessionStore, query::String; limit::Int=10, current_search_channel_id::Union{Nothing, String}=nothing)
    keywords = [lowercase(k) for k in split(strip(query); keepempty=false)]
    isempty(keywords) && return SessionSearchResult[]
    results = SessionSearchResult[]
    lock(store.lock) do
        for (eid, entry) in store.entries
            entry.is_deleted && continue
            _visible_entry(entry, current_search_channel_id) || continue
            text = _entry_search_text(entry)
            if _matches_keywords(text, keywords)
                push!(results, SessionSearchResult(eid, text, _keyword_score(text, keywords)))
            end
        end
    end
    sort!(results; by=r -> r.score, rev=true)
    return first(results, min(limit, length(results)))
end

# Default no-op: scrub_post! is implemented by store types that support it
scrub_post!(store::SessionStore, post_id::String) = nothing

function scrub_post!(store::InMemorySessionStore, post_id::String)
    lock(store.lock) do
        entry = get(store.entries, post_id, nothing)
        entry === nothing && return
        store.entries[post_id] = SessionEntry(;
            id=entry.id, parent_id=entry.parent_id, created_at=entry.created_at,
            is_deleted=true, channel_id=entry.channel_id,
            search_channel_id=entry.search_channel_id, channel_flags=entry.channel_flags,
        )
    end
end
