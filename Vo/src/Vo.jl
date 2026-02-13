module Vo

using Agentif
using LLMTools
using Dates
using JSON
using LocalSearch
using Logging
using SHA
using SQLite
using Tempus
using UUIDs
using ScopedValues

export AgentAssistant, AssistantConfig
export search_session
export AssistantMessage, UserMessage
export run!, evaluate, @a_str
export getIdentityAndPurpose, setIdentityAndPurpose!
export getHeartbeatTasks, setHeartbeatTasks!, trigger_event_heartbeat!
export addNewMemory, searchMemories, forgetMemory
export SkillMetadata, getSkills, addNewSkill, forgetSkill
export listJobs, addJob!, removeJob!
export ReplChannel

const TRIGGER_PROMPT = ScopedValue{Union{String, Nothing}}(nothing)
const DEFAULT_IDENTITY = read(joinpath(@__DIR__, "soul_template.md"), String)
const DEFAULT_SESSION_CONTEXT_LIMIT = 10
const DEFAULT_MEMORY_CONTEXT_LIMIT = 6
const ENV_AGENT_PROVIDER = "VO_AGENT_PROVIDER"
const ENV_AGENT_MODEL = "VO_AGENT_MODEL"
const ENV_AGENT_API_KEY = "VO_AGENT_API_KEY"
const HEARTBEAT_JOB_NAME = "heartbeat"
const DEFAULT_HEARTBEAT_TASKS = ""
const HEARTBEAT_START_HOUR = 6
const HEARTBEAT_END_HOUR = 23
const HEARTBEAT_MINUTE = 0
const DEFAULT_HEARTBEAT_INTERVAL_MINUTES = 30
const SESSION_STALE_SECONDS = 3600  # 1 hour

const SkillMetadata = Agentif.SkillMetadata

struct Memory
    memory::String
    createdAt::Float64
    eval_id::Union{Nothing, String}
    priority::String  # "high", "medium", "low"
    referenced_at::Union{Nothing, String}  # ISO date or natural language temporal anchor
end
Memory(memory::String, createdAt::Float64, eval_id::Union{Nothing, String}) = Memory(memory, createdAt, eval_id, "medium", nothing)

const MEMORY_TIMESTAMP_FORMAT = dateformat"yyyy-mm-dd HH:MM:SS"

function format_memory_timestamp(unix_time::Float64)
    dt = Dates.unix2datetime(unix_time)
    return string(Dates.format(dt, MEMORY_TIMESTAMP_FORMAT), "Z")
end

Base.@kwdef struct AssistantConfig
    provider::String
    model_id::String
    api_key::String
    session_context_limit::Int = DEFAULT_SESSION_CONTEXT_LIMIT
    memory_context_limit::Int = DEFAULT_MEMORY_CONTEXT_LIMIT
    base_dir::String = pwd()
    enable_heartbeat::Bool = true
    heartbeat_interval_minutes::Int = DEFAULT_HEARTBEAT_INTERVAL_MINUTES
end

# Global ref to the single assistant instance
const CURRENT_ASSISTANT = Ref{Any}(nothing)

function get_current_assistant()
    return CURRENT_ASSISTANT[]
end

# --- SQLite Schema ---

function init_schema!(db::SQLite.DB)
    SQLite.execute(db, "PRAGMA journal_mode=WAL")
    SQLite.execute(db, "PRAGMA synchronous=NORMAL")
    SQLite.execute(db, "PRAGMA foreign_keys=ON")
    SQLite.execute(db, "PRAGMA busy_timeout=5000")

    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS kv_store (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
    """)
    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS memories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            memory TEXT NOT NULL,
            created_at REAL NOT NULL,
            eval_id TEXT,
            priority TEXT NOT NULL DEFAULT 'medium',
            referenced_at TEXT
        )
    """)
    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS skills (
            name TEXT PRIMARY KEY,
            description TEXT NOT NULL,
            content TEXT NOT NULL
        )
    """)
    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS channel_sessions (
            channel_id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            last_activity REAL NOT NULL
        )
    """)
    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS session_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            entry_id TEXT,
            created_at REAL NOT NULL,
            messages TEXT NOT NULL,
            is_compaction INTEGER NOT NULL DEFAULT 0
        )
    """)
    SQLite.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_session_entries_session
        ON session_entries(session_id, id)
    """)
    # Migrate existing memories table if missing new columns
    migrate_memories_schema!(db)
end

function migrate_memories_schema!(db::SQLite.DB)
    # Check if priority column exists
    cols = Set{String}()
    for row in SQLite.DBInterface.execute(db, "PRAGMA table_info(memories)")
        push!(cols, String(row.name))
    end
    if "priority" ∉ cols
        SQLite.execute(db, "ALTER TABLE memories ADD COLUMN priority TEXT NOT NULL DEFAULT 'medium'")
    end
    if "referenced_at" ∉ cols
        SQLite.execute(db, "ALTER TABLE memories ADD COLUMN referenced_at TEXT")
    end
end

# --- SQLiteSessionStore ---

struct SQLiteSessionStore <: Agentif.SessionStore
    db::SQLite.DB
    search_store::Union{Nothing, LocalSearch.Store}
end

function Agentif.session_entry_count(store::SQLiteSessionStore, session_id::String)
    row = SQLite.DBInterface.execute(store.db,
        "SELECT COUNT(*) as n FROM session_entries WHERE session_id = ?", (session_id,))
    r = iterate(row)
    return r === nothing ? 0 : r[1].n
end

function Agentif.session_entries(store::SQLiteSessionStore, session_id::String; start::Int=1, limit::Int=typemax(Int))
    offset = max(0, start - 1)
    rows = SQLite.DBInterface.execute(store.db,
        "SELECT entry_id, created_at, messages, is_compaction FROM session_entries WHERE session_id = ? ORDER BY id ASC LIMIT ? OFFSET ?",
        (session_id, limit, offset))
    entries = Agentif.SessionEntry[]
    for row in rows
        # Reconstruct SessionEntry JSON and parse via Agentif's JSON.@choosetype
        entry_json = JSON.json(Dict(
            "id" => row.entry_id === missing ? nothing : row.entry_id,
            "created_at" => Float64(row.created_at),
            "messages" => JSON.parse(row.messages),
            "is_compaction" => row.is_compaction == 1,
        ))
        push!(entries, JSON.parse(entry_json, Agentif.SessionEntry))
    end
    return entries
end

function Agentif.load_session(store::SQLiteSessionStore, session_id::String)
    entries = Agentif.session_entries(store, session_id)
    state = Agentif.AgentState()
    state.session_id = session_id
    for entry in entries
        Agentif.apply_session_entry!(state, entry)
    end
    return state
end

function Agentif.append_session_entry!(store::SQLiteSessionStore, session_id::String, entry::Agentif.SessionEntry)
    messages_json = JSON.json(entry.messages)
    SQLite.execute(store.db,
        "INSERT INTO session_entries (session_id, entry_id, created_at, messages, is_compaction) VALUES (?, ?, ?, ?, ?)",
        (session_id, entry.id, entry.created_at, messages_json, entry.is_compaction ? 1 : 0))
    # Index session text into LocalSearch
    if store.search_store !== nothing
        text = session_entry_search_text(entry)
        if !isempty(strip(text))
            doc_id = "session:$(session_id):$(something(entry.id, string(entry.created_at)))"
            try
                LocalSearch.load!(store.search_store, text; id=doc_id, title="session")
            catch err
                @debug "Failed to index session entry" exception=err
            end
        end
    end
    return nothing
end

# --- AgentAssistant ---

mutable struct AgentAssistant
    db::SQLite.DB
    search_store::Union{Nothing, LocalSearch.Store}
    session_store::SQLiteSessionStore
    scheduler::Tempus.Scheduler
    config::AssistantConfig
    initialized::Bool
    @atomic evaluating::Bool
    last_heartbeat_hash::UInt64
    last_heartbeat_time::Float64
end

function normalize_text(value::Union{Nothing, AbstractString})
    value === nothing && return nothing
    cleaned = strip(value)
    isempty(cleaned) && return nothing
    return String(cleaned)
end

function normalize_memory_text(value::AbstractString)
    cleaned = replace(strip(String(value)), r"\s+" => " ")
    isempty(cleaned) && throw(ArgumentError("memory cannot be empty"))
    return cleaned
end

function append_prompt(prompt::AbstractString, section::AbstractString)
    section_clean = strip(String(section))
    isempty(section_clean) && return String(prompt)
    isempty(strip(String(prompt))) && return section_clean
    return string(prompt, "\n\n", section_clean)
end

function insert_memories_section(prompt::AbstractString, mem_section::AbstractString)
    mem_clean = strip(String(mem_section))
    isempty(mem_clean) && return String(prompt)
    marker = "\n## Trigger Prompt\n"
    idx = findfirst(marker, prompt)
    idx === nothing && return append_prompt(prompt, mem_clean)
    before = prompt[1:(first(idx) - 1)]
    after = prompt[first(idx):end]
    combined = append_prompt(before, mem_clean)
    return combined * after
end

function append_tools(agent::Agentif.Agent, new_tools::Vector{Agentif.AgentTool})
    isempty(new_tools) && return agent
    tools = isempty(agent.tools) ? new_tools : vcat(agent.tools, new_tools)
    return Agentif.with_tools(agent, tools)
end

parse_keywords(keywords::String)::Vector{String} = [lowercase(k) for k in split(strip(keywords); keepempty = false)]

function matches_keywords(text::String, keywords::Vector{String})::Bool
    isempty(keywords) && return true
    text_lower = lowercase(text)
    for kw in keywords
        occursin(kw, text_lower) && return true
    end
    return false
end

function apply_limit(results::Vector{T}, limit::Union{Nothing, Int}) where {T}
    limit === nothing && return results
    length(results) <= limit && return results
    return results[1:limit]
end

function get_env_with_fallback(primary::String, fallback::String, default::Union{String, Nothing})::Union{String, Nothing}
    value = Base.get(() -> nothing, ENV, primary)
    if value !== nothing && !isempty(value) && uppercase(value) != "OAUTH"
        return String(value)
    end
    value = Base.get(() -> nothing, ENV, fallback)
    if value !== nothing && !isempty(value) && uppercase(value) != "OAUTH"
        return String(value)
    end
    return default
end

function get_env_value(name::String)::Union{String, Nothing}
    value = Base.get(() -> nothing, ENV, name)
    if value === nothing || isempty(value) || uppercase(value) == "OAUTH"
        return nothing
    end
    return String(value)
end

function resolve_api_key(provider::String, api_key::Union{Nothing, String})::Union{String, Nothing}
    api_key_value = api_key === nothing ? get_env_with_fallback(ENV_AGENT_API_KEY, "ANTHROPIC_API_KEY", nothing) : api_key
    if api_key === nothing
        if provider == "openrouter"
            openrouter_key = get_env_value("OPENROUTER_API_KEY")
            openrouter_key !== nothing && return openrouter_key
        elseif provider == "minimax"
            minimax_key = get_env_value("MINIMAX_API_KEY")
            minimax_key !== nothing && return minimax_key
        end
    end
    return api_key_value
end

function resolve_provider_overrides(provider::String, model_id::Union{Nothing, String}, api_key::Union{Nothing, String}, api_key_provided::Bool)
    provider_value = provider
    model_id_value = model_id
    api_key_value = api_key
    model_id_value === nothing && return provider_value, model_id_value, api_key_value
    if !api_key_provided && provider_value == "openrouter" && startswith(lowercase(model_id_value), "minimax/")
        openrouter_key = get_env_value("OPENROUTER_API_KEY")
        minimax_key = get_env_value("MINIMAX_API_KEY")
        if openrouter_key === nothing && minimax_key !== nothing && Agentif.getModel("minimax", model_id_value) !== nothing
            @info "OpenRouter API key missing; falling back to MiniMax provider" model_id = model_id_value
            provider_value = "minimax"
            api_key_value = minimax_key
        end
    end
    return provider_value, model_id_value, api_key_value
end

include("tools.jl")
include("channels.jl")

# --- KV helpers ---

function kv_get(db::SQLite.DB, key::String, default::String="")
    row = iterate(SQLite.DBInterface.execute(db, "SELECT value FROM kv_store WHERE key = ?", (key,)))
    return row === nothing ? default : String(row[1].value)
end

function kv_set!(db::SQLite.DB, key::String, value::String)
    SQLite.execute(db, "INSERT OR REPLACE INTO kv_store (key, value) VALUES (?, ?)", (key, value))
end

# --- Identity & Heartbeat (backed by kv_store) ---

function getIdentityAndPurpose(db::SQLite.DB)
    cleaned = normalize_text(kv_get(db, "identity", ""))
    cleaned === nothing && return DEFAULT_IDENTITY
    return cleaned
end
getIdentityAndPurpose(a::AgentAssistant) = getIdentityAndPurpose(a.db)

function setIdentityAndPurpose!(db::SQLite.DB, text::String)
    kv_set!(db, "identity", text)
end
setIdentityAndPurpose!(a::AgentAssistant, text::String) = setIdentityAndPurpose!(a.db, text)

function getHeartbeatTasks(db::SQLite.DB)
    return kv_get(db, "heartbeat_tasks", DEFAULT_HEARTBEAT_TASKS)
end
getHeartbeatTasks(a::AgentAssistant) = getHeartbeatTasks(a.db)

function setHeartbeatTasks!(db::SQLite.DB, text::String)
    kv_set!(db, "heartbeat_tasks", text)
end
setHeartbeatTasks!(a::AgentAssistant, text::String) = setHeartbeatTasks!(a.db, text)

# --- Memories (backed by memories table + LocalSearch) ---

const VALID_PRIORITIES = ("high", "medium", "low")

function validate_priority(p::Union{Nothing, String})
    p === nothing && return "medium"
    lp = lowercase(strip(p))
    lp in VALID_PRIORITIES && return lp
    return "medium"
end

function addNewMemory(db::SQLite.DB, memory::String; eval_id::Union{Nothing, String}=nothing, priority::Union{Nothing, String}=nothing, referenced_at::Union{Nothing, String}=nothing, search_store::Union{Nothing, LocalSearch.Store}=nothing)
    text = normalize_memory_text(memory)
    created_at = time()
    eval_id_str = eval_id === nothing ? nothing : string(eval_id)
    pri = validate_priority(priority)
    ref_at = referenced_at === nothing ? nothing : strip(referenced_at)
    SQLite.execute(db, "INSERT INTO memories (memory, created_at, eval_id, priority, referenced_at) VALUES (?, ?, ?, ?, ?)", (text, created_at, eval_id_str, pri, ref_at))
    mem = Memory(text, created_at, eval_id_str, pri, ref_at)
    # Index into LocalSearch
    if search_store !== nothing
        try
            doc_id = "memory:$(bytes2hex(sha256(text))[1:16])"
            LocalSearch.load!(search_store, text; id=doc_id, title="memory")
        catch err
            @debug "Failed to index memory" exception=err
        end
    end
    return mem
end

function _row_to_memory(r)
    Memory(
        String(r.memory),
        Float64(r.created_at),
        r.eval_id === missing ? nothing : String(r.eval_id),
        r.priority === missing ? "medium" : String(r.priority),
        r.referenced_at === missing ? nothing : String(r.referenced_at),
    )
end

function load_all_memories(db::SQLite.DB)
    rows = SQLite.DBInterface.execute(db, "SELECT memory, created_at, eval_id, priority, referenced_at FROM memories ORDER BY created_at DESC")
    return Memory[_row_to_memory(r) for r in rows]
end

"""Batch-lookup Memory structs from SQLite by exact text, preserving the input order."""
function lookup_memories_by_text(db::SQLite.DB, texts::Vector{String})
    isempty(texts) && return Memory[]
    placeholders = join(fill("?", length(texts)), ", ")
    rows = SQLite.DBInterface.execute(db,
        "SELECT memory, created_at, eval_id, priority, referenced_at FROM memories WHERE memory IN ($placeholders)", texts)
    by_text = Dict{String, Memory}()
    for r in rows
        by_text[String(r.memory)] = _row_to_memory(r)
    end
    # Return in original order (LocalSearch relevance ranking)
    return Memory[by_text[t] for t in texts if haskey(by_text, t)]
end

function searchMemories(db::SQLite.DB, keywords::String; limit::Union{Nothing, Int}=nothing, search_store::Union{Nothing, LocalSearch.Store}=nothing)
    limit_value = limit === nothing ? 10 : limit
    # Try LocalSearch if available — results contain the full original memory text
    if search_store !== nothing && !isempty(strip(keywords))
        try
            results = LocalSearch.search(search_store, keywords; limit=limit_value)
            memory_results = filter(r -> startswith(r.id, "memory:"), results)
            if !isempty(memory_results)
                return lookup_memories_by_text(db, [r.text for r in memory_results])
            end
        catch err
            @debug "LocalSearch memory search failed, falling back to keyword search" exception=err
        end
    end
    # Fallback: keyword search in SQLite
    keywords_list = parse_keywords(keywords)
    all_memories = load_all_memories(db)
    results = filter(m -> matches_keywords(m.memory, keywords_list), all_memories)
    return apply_limit(results, limit)
end

function forgetMemory(db::SQLite.DB, memory::String; search_store::Union{Nothing, LocalSearch.Store}=nothing)
    result = SQLite.DBInterface.execute(db, "SELECT COUNT(*) as n FROM memories WHERE memory = ?", (memory,))
    row = iterate(result)
    count = row === nothing ? 0 : row[1].n
    SQLite.execute(db, "DELETE FROM memories WHERE memory = ?", (memory,))
    # Remove from LocalSearch
    if search_store !== nothing && count > 0
        try
            doc_id = "memory:$(bytes2hex(sha256(memory))[1:16])"
            Base.delete!(search_store, doc_id)
        catch err
            @debug "Failed to remove memory from search index" exception=err
        end
    end
    return count
end

# --- Skills (backed by skills table) ---

function getSkills(db::SQLite.DB)
    rows = SQLite.DBInterface.execute(db, "SELECT name, description FROM skills ORDER BY name")
    return SkillMetadata[Agentif.SkillMetadata(String(r.name), String(r.description), nothing, nothing, Dict{String,String}(), nothing, "", "") for r in rows]
end

function addNewSkill(db::SQLite.DB, content::AbstractString)
    text = String(content)
    isempty(strip(text)) && throw(ArgumentError("skill content cannot be empty"))
    name, description = parse_skill_metadata(text)
    SQLite.execute(db, "INSERT OR REPLACE INTO skills (name, description, content) VALUES (?, ?, ?)", (name, description, text))
    return Agentif.SkillMetadata(name, description, nothing, nothing, Dict{String,String}(), nothing, "", "")
end

function forgetSkill(db::SQLite.DB, name::AbstractString)
    result = SQLite.DBInterface.execute(db, "SELECT COUNT(*) as n FROM skills WHERE name = ?", (String(name),))
    row = iterate(result)
    count = row === nothing ? 0 : row[1].n
    SQLite.execute(db, "DELETE FROM skills WHERE name = ?", (String(name),))
    return count
end

function parse_skill_metadata(content::AbstractString)
    fields = Agentif.parse_frontmatter(content)
    name = get(() -> nothing, fields, "name")
    description = get(() -> nothing, fields, "description")
    name === nothing && throw(ArgumentError("skill content missing name"))
    description === nothing && throw(ArgumentError("skill content missing description"))
    Agentif.validate_skill_name(name)
    return String(name), String(description)
end

function get_skills_registry(db::SQLite.DB)
    rows = SQLite.DBInterface.execute(db, "SELECT name, description, content FROM skills ORDER BY name")
    skills = Dict{String, Agentif.SkillMetadata}()
    loaded = Dict{String, String}()
    for r in rows
        name = String(r.name)
        skills[name] = Agentif.SkillMetadata(name, String(r.description), nothing, nothing, Dict{String,String}(), nothing, "", "")
        loaded[name] = String(r.content)
    end
    registry = Agentif.SkillRegistry(skills, loaded)
    return registry
end

# --- Channel-Session Mapping ---

Agentif.channel_id(ch::ReplChannel) = "repl"

"""
    resolve_session!(db, chan_id) -> String

Return the active session_id for the given channel. Creates a new session
(and optionally bridges context) if the last activity is stale (>1hr).
"""
function resolve_session!(db::SQLite.DB, chan_id::String)
    now = time()
    row = iterate(SQLite.DBInterface.execute(db,
        "SELECT session_id, last_activity FROM channel_sessions WHERE channel_id = ?", (chan_id,)))
    if row !== nothing
        session_id = String(row[1].session_id)
        last_activity = Float64(row[1].last_activity)
        if (now - last_activity) < SESSION_STALE_SECONDS
            # Session still active — update activity timestamp
            SQLite.execute(db, "UPDATE channel_sessions SET last_activity = ? WHERE channel_id = ?", (now, chan_id))
            return session_id
        end
        # Session stale — rotate
        old_session_id = session_id
    else
        old_session_id = nothing
    end
    new_session_id = string(UUIDs.uuid4())
    SQLite.execute(db, "INSERT OR REPLACE INTO channel_sessions (channel_id, session_id, last_activity) VALUES (?, ?, ?)",
        (chan_id, new_session_id, now))
    return new_session_id
end

"""
    bridge_context(db, old_session_id) -> String

Build a brief context bridge from the previous session's recent messages.
"""
function bridge_context(db::SQLite.DB, session_id::String)
    rows = SQLite.DBInterface.execute(db,
        "SELECT messages FROM session_entries WHERE session_id = ? ORDER BY id DESC LIMIT 3", (session_id,))
    parts = String[]
    for row in rows
        msgs = JSON.parse(row.messages)
        for m in msgs
            if get(m, "type", "") == "user"
                content = get(m, "content", [])
                for c in content
                    if get(c, "type", "") == "text"
                        text = get(c, "text", "")
                        !isempty(text) && push!(parts, "User: " * text)
                    end
                end
            elseif get(m, "type", "") == "assistant"
                content = get(m, "content", [])
                for c in content
                    if get(c, "type", "") == "text"
                        text = get(c, "text", "")
                        !isempty(text) && push!(parts, "Vo: " * text)
                    end
                end
            end
        end
    end
    isempty(parts) && return ""
    return "## Previous Session Context\n" * join(reverse(parts), "\n") * "\n"
end

# --- Job helpers ---

function job_summary(job::Tempus.Job)
    enabled = !Tempus.isdisabled(job)
    schedule_str = job.schedule === nothing ? "" : strip(string(job.schedule), '"')
    return (; name = job.name, schedule = schedule_str, enabled = enabled)
end

function local_utc_offset_minutes(now_local::DateTime = Dates.now())
    delta_ms = Dates.value(now_local - Dates.now(UTC))
    return Int(div(delta_ms, 60_000))
end

function heartbeat_schedule(offset_minutes::Int, interval_minutes::Int=DEFAULT_HEARTBEAT_INTERVAL_MINUTES)
    interval_minutes = clamp(interval_minutes, 1, 60)
    base = mod(HEARTBEAT_MINUTE - offset_minutes, 60)
    minutes = Int[]
    m = base
    while true
        push!(minutes, mod(m, 60))
        m += interval_minutes
        mod(m, 60) == mod(base, 60) && break
        length(minutes) >= 60 && break
    end
    sort!(unique!(minutes))
    return join(minutes, ",") * " * * * *"
end

function format_utc_offset(offset_minutes::Int)
    sign = offset_minutes < 0 ? "-" : "+"
    abs_minutes = abs(offset_minutes)
    hours = abs_minutes ÷ 60
    minutes = abs_minutes % 60
    return string(sign, lpad(string(hours), 2, "0"), ":", lpad(string(minutes), 2, "0"))
end

function heartbeat_prompt(local_time::DateTime, offset_minutes::Int, heartbeat_tasks::String, skill_names::Vector{String})
    offset_str = format_utc_offset(offset_minutes)
    time_str = Dates.format(local_time, "yyyy-mm-dd HH:MM")
    first_heartbeat = Dates.hour(local_time) == HEARTBEAT_START_HOUR
    last_heartbeat = Dates.hour(local_time) == HEARTBEAT_END_HOUR
    has_tasks = !isempty(strip(heartbeat_tasks))

    skill_section = if !isempty(skill_names)
        skill_list = join(["  - `$(s)`" for s in skill_names], "\n")
        """
        - Run relevant skills to surface recent or upcoming items. Available skills:
        $(skill_list)
          Use these to catch todos, events, messages, or content relevant to the user."""
    else
        "- Check for any available skills that surface recent or upcoming items (email, calendar, messaging, news)."
    end

    tasks_section = if has_tasks
        """

        Pending heartbeat tasks (from HEARTBEAT.md — process these):
        $(heartbeat_tasks)

        After processing tasks, update HEARTBEAT.md to remove completed items."""
    else
        ""
    end

    return """
    Heartbeat check-in.
    Current local time: $(time_str) (UTC$(offset_str)).
    First heartbeat of day: $(first_heartbeat ? "yes" : "no"). Last heartbeat of day: $(last_heartbeat ? "yes" : "no").
    $(tasks_section)
    Rules:
    - Always respond on the first heartbeat (hour $(HEARTBEAT_START_HOUR)): greet with a concise good morning and offer a short plan or priorities for the day.
    - Always respond on the last heartbeat (hour $(HEARTBEAT_END_HOUR)): say goodnight and provide a brief look-back + look-forward summary.
    - If there are pending heartbeat tasks above, always respond (process them).
    - For other heartbeats with no pending tasks, only respond if you find something useful; otherwise respond exactly with HEARTBEAT_OK.

    Checklist:
    - Review recent session entries and memories for events, lessons, or follow-ups worth acting on.
    $(skill_section)
    - Use memories about user interests to find or propose noteworthy content, refining interest/topics over time.
    - If responding outside the first/last heartbeat, be concise — only meaningful updates or actions.

    Learnings (#20):
    - If you discover any stable facts, patterns, or insights during this heartbeat, store them with addNewMemory.
    - On the last heartbeat of the day, briefly review recent memories for any that are stale or redundant — propose pruning if needed.
    """
end

# --- Constructor ---

function AgentAssistant(;
        db::Union{Nothing, SQLite.DB} = nothing,
        db_path::Union{Nothing, String} = nothing,
        provider::Union{Nothing, String} = nothing,
        model_id::Union{Nothing, String} = nothing,
        api_key::Union{Nothing, String} = nothing,
        session_context_limit::Int = DEFAULT_SESSION_CONTEXT_LIMIT,
        memory_context_limit::Int = DEFAULT_MEMORY_CONTEXT_LIMIT,
        base_dir::String = pwd(),
        enable_heartbeat::Bool = true,
        heartbeat_interval_minutes::Int = DEFAULT_HEARTBEAT_INTERVAL_MINUTES,
        embed = nothing,  # pass LocalSearch embed option (nothing=BM25 only, :default=vector+BM25)
    )
    # Resolve database
    if db !== nothing
        sqlite_db = db
    elseif db_path !== nothing
        sqlite_db = SQLite.DB(db_path)
    else
        # Check env
        env_path = Base.get(ENV, "VO_DATA_DIR", nothing)
        if env_path !== nothing && !isempty(env_path)
            mkpath(env_path)
            sqlite_db = SQLite.DB(joinpath(env_path, "vo.sqlite"))
        else
            sqlite_db = SQLite.DB()  # in-memory
        end
    end

    init_schema!(sqlite_db)

    # Create LocalSearch store on the same DB path for search
    db_file = sqlite_db.file
    search_store = if !isempty(db_file) && db_file != ":memory:"
        # Use a separate LocalSearch DB in the same directory
        search_path = db_file * ".search"
        try
            LocalSearch.Store(search_path; embed=embed === nothing ? nothing : embed)
        catch err
            @warn "Failed to initialize LocalSearch" exception=err
            nothing
        end
    else
        try
            LocalSearch.Store(; embed=embed === nothing ? nothing : embed)
        catch err
            @warn "Failed to initialize in-memory LocalSearch" exception=err
            nothing
        end
    end

    session_store = SQLiteSessionStore(sqlite_db, search_store)

    # Create Tempus scheduler backed by SQLite
    tempus_store = Tempus.SQLiteStore(sqlite_db)
    scheduler = Tempus.Scheduler(tempus_store; logging=false)

    # Resolve provider/model/key
    provider_value = provider === nothing ? get_env_with_fallback(ENV_AGENT_PROVIDER, "ANTHROPIC_PROVIDER", "anthropic") : provider
    model_id_value = model_id === nothing ? get_env_with_fallback(ENV_AGENT_MODEL, "ANTHROPIC_MODEL", nothing) : model_id
    api_key_value = resolve_api_key(provider_value, api_key)
    provider_value, model_id_value, api_key_value = resolve_provider_overrides(provider_value, model_id_value, api_key_value, api_key !== nothing)
    model_id_value === nothing && error("Missing model ID. Set $(ENV_AGENT_MODEL) or ANTHROPIC_MODEL")
    if api_key_value === nothing
        if provider_value == "openrouter"
            error("Missing API key. Set $(ENV_AGENT_API_KEY) or OPENROUTER_API_KEY")
        elseif provider_value == "minimax"
            error("Missing API key. Set $(ENV_AGENT_API_KEY) or MINIMAX_API_KEY")
        end
        error("Missing API key. Set $(ENV_AGENT_API_KEY) or ANTHROPIC_API_KEY")
    end
    config = AssistantConfig(
        provider = provider_value,
        model_id = model_id_value,
        api_key = api_key_value,
        session_context_limit = session_context_limit,
        memory_context_limit = memory_context_limit,
        base_dir = base_dir,
        enable_heartbeat = enable_heartbeat,
        heartbeat_interval_minutes = heartbeat_interval_minutes,
    )
    model = Agentif.getModel(config.provider, config.model_id)
    model === nothing && error("Unknown model provider=$(config.provider) model_id=$(config.model_id)")
    assistant = AgentAssistant(
        sqlite_db,
        search_store,
        session_store,
        scheduler,
        config,
        true,     # initialized
        false,    # evaluating
        UInt64(0),# last_heartbeat_hash
        0.0,      # last_heartbeat_time
    )
    CURRENT_ASSISTANT[] = assistant
    return assistant
end

# --- Session helpers ---

function session_entry_count(assistant::AgentAssistant, session_id::String)
    return Agentif.session_entry_count(assistant.session_store, session_id)
end

function list_session_entries(assistant::AgentAssistant, session_id::String, start::Int, limit::Int)
    return Agentif.session_entries(assistant.session_store, session_id; start, limit)
end

function recent_session_entries(assistant::AgentAssistant, session_id::String)
    entry_count = session_entry_count(assistant, session_id)
    start_index = max(1, entry_count - assistant.config.session_context_limit + 1)
    return entry_count == 0 ? Agentif.SessionEntry[] : list_session_entries(assistant, session_id, start_index, assistant.config.session_context_limit)
end

function session_entry_summary(entry::Agentif.SessionEntry)
    user = ""
    assistant = ""
    for msg in entry.messages
        if msg isa Agentif.UserMessage
            user = Agentif.message_text(msg)
        elseif msg isa Agentif.AssistantMessage
            assistant = Agentif.message_text(msg)
        end
    end
    return user, assistant
end

function session_entry_search_text(entry::Agentif.SessionEntry)
    parts = String[]
    for msg in entry.messages
        if msg isa Agentif.UserMessage
            push!(parts, Agentif.message_text(msg))
        elseif msg isa Agentif.AssistantMessage
            push!(parts, Agentif.message_text(msg))
            thinking = Agentif.message_thinking(msg)
            !isempty(thinking) && push!(parts, thinking)
        elseif msg isa Agentif.ToolResultMessage
            push!(parts, Agentif.message_text(msg))
        end
    end
    return join(parts, "\n")
end

function search_session(assistant::AgentAssistant, keywords::String; limit::Union{Nothing, Int}=nothing, offset::Int=0, session_id::Union{Nothing, String}=nothing)
    limit_value = limit === nothing ? 10 : max(limit, 0)
    limit_value == 0 && return Dict{String,Any}[]
    # Try LocalSearch first
    if assistant.search_store !== nothing && !isempty(strip(keywords))
        try
            results = LocalSearch.search(assistant.search_store, keywords; limit=(limit_value + offset) * 3)
            session_prefix = session_id === nothing ? "session:" : "session:$(session_id):"
            session_results = filter(r -> startswith(r.id, session_prefix), results)
            if !isempty(session_results)
                if offset > 0
                    offset >= length(session_results) && return Dict{String,Any}[]
                    session_results = session_results[(offset + 1):end]
                end
                length(session_results) > limit_value && (session_results = session_results[1:limit_value])
                return [Dict("path" => r.id, "score" => r.score, "snippet" => r.text) for r in session_results]
            end
        catch err
            @debug "LocalSearch session search failed" exception=err
        end
    end
    # Fallback: keyword search in session_entries
    sid = session_id
    if sid === nothing
        # Search across all sessions
        keywords_list = parse_keywords(keywords)
        results = Dict{String,Any}[]
        rows = SQLite.DBInterface.execute(assistant.db, "SELECT messages FROM session_entries ORDER BY id DESC LIMIT ?", (limit_value + offset,))
        seen = 0
        for row in rows
            msgs = JSON.parse(row.messages)
            text = join([get(c, "text", "") for m in msgs for c in get(m, "content", []) if get(c, "type", "") == "text"], " ")
            if matches_keywords(text, keywords_list)
                if seen >= offset
                    push!(results, Dict("path" => "session", "score" => 1.0, "snippet" => text))
                end
                seen += 1
                length(results) >= limit_value && break
            end
        end
        return results
    else
        keywords_list = parse_keywords(keywords)
        results = Dict{String,Any}[]
        entries = Agentif.session_entries(assistant.session_store, sid)
        seen = 0
        for entry in entries
            text = session_entry_search_text(entry)
            if matches_keywords(text, keywords_list)
                if seen >= offset
                    push!(results, Dict("path" => "session", "score" => 1.0, "snippet" => text))
                end
                seen += 1
                length(results) >= limit_value && break
            end
        end
        return results
    end
end

# --- Memory middleware ---

function build_memory_query(session_entries::Vector{Agentif.SessionEntry}; max_chars::Int=500)
    isempty(session_entries) && return ""
    parts = String[]
    total_chars = 0
    for entry in reverse(session_entries)
        user_text, assistant_text = session_entry_summary(entry)
        if !isempty(user_text) && total_chars < max_chars
            push!(parts, user_text)
            total_chars += length(user_text)
        end
        if !isempty(assistant_text) && total_chars < max_chars
            snippet = length(assistant_text) > 100 ? assistant_text[1:100] : assistant_text
            push!(parts, snippet)
            total_chars += length(snippet)
        end
        total_chars >= max_chars && break
    end
    return join(parts, " ")
end

function get_relevant_memories(assistant::AgentAssistant, session_entries::Vector{Agentif.SessionEntry})
    limit = assistant.config.memory_context_limit
    limit <= 0 && return Memory[]
    context_query = build_memory_query(session_entries)
    # Try LocalSearch — results are already relevance-ranked and contain full memory text
    if !isempty(context_query) && assistant.search_store !== nothing
        try
            results = LocalSearch.search(assistant.search_store, context_query; limit=limit)
            memory_results = filter(r -> startswith(r.id, "memory:"), results)
            if !isempty(memory_results)
                memories = lookup_memories_by_text(assistant.db, [r.text for r in memory_results])
                !isempty(memories) && return memories
            end
        catch err
            @debug "LocalSearch memory retrieval failed" exception=err
        end
    end
    # Fallback: most recent memories
    all_memories = load_all_memories(assistant.db)
    return all_memories[1:min(limit, length(all_memories))]
end

const PRIORITY_EMOJI = Dict("high" => "🔴", "medium" => "🟡", "low" => "🟢")

function format_relative_time(memory_time::Dates.DateTime, now_time::Dates.DateTime)
    diff = now_time - memory_time
    days = Dates.value(diff) ÷ (1000 * 60 * 60 * 24)
    days == 0 && return "today"
    days == 1 && return "yesterday"
    days < 7 && return "$(days) days ago"
    days < 14 && return "1 week ago"
    days < 30 && return "$(days ÷ 7) weeks ago"
    days < 60 && return "1 month ago"
    days < 365 && return "$(days ÷ 30) months ago"
    return "$(days ÷ 365) year(s) ago"
end

function build_relevant_memories_section(assistant::AgentAssistant, session_entries::Vector{Agentif.SessionEntry})
    relevant_memories = get_relevant_memories(assistant, session_entries)
    isempty(relevant_memories) && return ""
    now_time = Dates.now(Dates.UTC)
    io = IOBuffer()
    print(io, "## Relevant Memories\n")
    print(io, "These memories are from past interactions. Reference them when relevant — prefer the most recent for current state.\n")
    for mem in relevant_memories
        emoji = get(PRIORITY_EMOJI, mem.priority, "🟡")
        mem_time = Dates.unix2datetime(mem.createdAt)
        date_str = Dates.format(mem_time, "yyyy-mm-dd HH:MM")
        relative = format_relative_time(mem_time, now_time)
        print(io, "- ", emoji, " [", date_str, " — ", relative, "] ", mem.memory)
        if mem.referenced_at !== nothing
            print(io, " (re: ", mem.referenced_at, ")")
        end
        print(io, "\n")
    end
    return String(take!(io))
end

# --- Prompt building ---

function build_base_prompt(assistant::AgentAssistant; trigger_prompt::Union{Nothing, String}=TRIGGER_PROMPT[], session_id::Union{Nothing, String}=nothing, bridge::String="")
    identity = getIdentityAndPurpose(assistant)
    io = IOBuffer()
    local_time = Dates.now()
    offset_minutes = local_utc_offset_minutes(local_time)
    offset_str = format_utc_offset(offset_minutes)
    utc_time = Dates.now(Dates.UTC)
    local_time_str = Dates.format(local_time, "yyyy-mm-dd HH:MM:SS")
    utc_time_str = Dates.format(utc_time, "yyyy-mm-dd HH:MM:SS")
    local_day = Dates.dayname(local_time)
    utc_day = Dates.dayname(utc_time)

    print(io, "You are Vo.\n\n## Current Date & Time\n")
    print(io, "Local time: ", local_time_str, " (", local_day, ", UTC", offset_str, ").\n")
    print(io, "UTC time: ", utc_time_str, " (", utc_day, ").\n\n")
    print(io, "## Identity & Purpose\n")
    print(io, identity, "\n")

    if !isempty(bridge)
        print(io, "\n", bridge)
    end
    if trigger_prompt !== nothing
        print(io, "\n## Trigger Prompt\n", trigger_prompt, "\n")
    end
    return String(take!(io))
end

# --- Build error state ---

function build_error_state(input::String, error_text::String)
    messages = Agentif.AgentMessage[]
    push!(messages, Agentif.UserMessage(input))
    push!(messages, Agentif.AssistantMessage(; provider="local", api="local", model="local", content=Agentif.AssistantContentBlock[Agentif.TextContent(error_text)]))
    usage = Agentif.Usage()
    pending = Agentif.PendingToolCall[]
    return Agentif.AgentState(;
        messages,
        response_id = nothing,
        usage,
        pending_tool_calls = pending,
        most_recent_stop_reason = :error,
    )
end

# --- Agent & Middleware ---

function base_agent(assistant::AgentAssistant; session_id::Union{Nothing, String}=nothing, bridge::String="")
    model = Agentif.getModel(assistant.config.provider, assistant.config.model_id)
    model === nothing && error("Unknown model provider=$(assistant.config.provider) model_id=$(assistant.config.model_id)")
    prompt = build_base_prompt(assistant; session_id=session_id, bridge=bridge)
    return Agentif.Agent(
        id = "vo",
        name = "Vo",
        prompt = prompt,
        model = model,
        apikey = assistant.config.api_key,
        tools = Agentif.AgentTool[],
    )
end

function memory_middleware(agent_handler::Agentif.AgentHandler, assistant::AgentAssistant, session_id::String)
    return function (f, agent::Agentif.Agent, state::Agentif.AgentState, current_input::Agentif.AgentTurnInput, abort::Agentif.Abort; kw...)
        entries = recent_session_entries(assistant, session_id)
        mem_section = build_relevant_memories_section(assistant, entries)
        prompt = insert_memories_section(agent.prompt, mem_section)
        agent_with_prompt = Agentif.with_prompt(agent, prompt)
        agent_with_tools = append_tools(agent_with_prompt, build_memory_tools(assistant))
        return agent_handler(f, agent_with_tools, state, current_input, abort; kw...)
    end
end

function manage_skills_middleware(agent_handler::Agentif.AgentHandler, assistant::AgentAssistant)
    return function (f, agent::Agentif.Agent, state::Agentif.AgentState, current_input::Agentif.AgentTurnInput, abort::Agentif.Abort; kw...)
        agent_with_tools = append_tools(agent, build_manage_skills_tools(assistant))
        registry = get_skills_registry(assistant.db)
        !isempty(registry.skills) && (agent_with_tools = append_tools(agent_with_tools, Agentif.AgentTool[Agentif.create_skill_loader_tool(registry)]))
        return agent_handler(f, agent_with_tools, state, current_input, abort; kw...)
    end
end

function scheduler_middleware(agent_handler::Agentif.AgentHandler, assistant::AgentAssistant)
    return function (f, agent::Agentif.Agent, state::Agentif.AgentState, current_input::Agentif.AgentTurnInput, abort::Agentif.Abort; kw...)
        agent_with_tools = append_tools(agent, build_scheduler_tools(assistant))
        return agent_handler(f, agent_with_tools, state, current_input, abort; kw...)
    end
end

function assistant_tools_middleware(agent_handler::Agentif.AgentHandler, assistant::AgentAssistant)
    return function (f, agent::Agentif.Agent, state::Agentif.AgentState, current_input::Agentif.AgentTurnInput, abort::Agentif.Abort; kw...)
        agent_with_tools = append_tools(agent, build_assistant_tools(assistant))
        subagent_tool = LLMTools.create_subagent_tool(agent_with_tools)
        agent_with_tools = append_tools(agent_with_tools, Agentif.AgentTool[subagent_tool])
        return agent_handler(f, agent_with_tools, state, current_input, abort; kw...)
    end
end

function build_handler(assistant::AgentAssistant; session_id::String, channel::Union{Nothing, Agentif.AbstractChannel}=nothing)
    registry = get_skills_registry(assistant.db)
    handler = Agentif.build_default_handler(;
        base_handler = Agentif.stream,
        session_store = assistant.session_store,
        session_id = session_id,
        skill_registry = registry,
        channel = channel,
    )
    handler = assistant_tools_middleware(handler, assistant)
    handler = scheduler_middleware(handler, assistant)
    handler = manage_skills_middleware(handler, assistant)
    handler = memory_middleware(handler, assistant, session_id)
    return handler
end

# --- Evaluate ---

evaluate(assistant::AgentAssistant, input::Agentif.AgentTurnInput; abort::Agentif.Abort=Agentif.Abort(), channel::Union{Nothing, Agentif.AbstractChannel}=nothing, kw...) =
    evaluate(identity, assistant, input; abort, channel, kw...)

function evaluate(f::Function, assistant::AgentAssistant, input::Agentif.AgentTurnInput; abort::Agentif.Abort=Agentif.Abort(), channel::Union{Nothing, Agentif.AbstractChannel}=nothing, kw...)
    chan = if channel !== nothing
        channel
    else
        cur = Agentif.CURRENT_CHANNEL[]
        cur !== nothing ? cur : ReplChannel(devnull)
    end
    chan_id = Agentif.channel_id(chan)
    session_id = resolve_session!(assistant.db, chan_id)

    # Check if this is a rotated session and build bridge context
    bridge = ""
    row = iterate(SQLite.DBInterface.execute(assistant.db,
        "SELECT session_id FROM channel_sessions WHERE channel_id = ?", (chan_id,)))
    # Bridge context only on brand new sessions with no entries yet
    if session_entry_count(assistant, session_id) == 0
        # Find the previous session for this channel to bridge from
        prev_rows = SQLite.DBInterface.execute(assistant.db,
            "SELECT DISTINCT session_id FROM session_entries WHERE session_id != ? ORDER BY id DESC LIMIT 1", (session_id,))
        prev = iterate(prev_rows)
        if prev !== nothing
            bridge = bridge_context(assistant.db, String(prev[1].session_id))
        end
    end

    agent = base_agent(assistant; session_id=session_id, bridge=bridge)
    state = Agentif.AgentState()
    handler = build_handler(assistant; session_id=session_id, channel=chan)
    @atomic assistant.evaluating = true
    try
        return handler(f, agent, state, input, abort; kw...)
    finally
        @atomic assistant.evaluating = false
    end
end

# --- Heartbeat ---

function heartbeat_has_tasks(assistant::AgentAssistant)
    tasks = getHeartbeatTasks(assistant)
    for line in split(tasks, "\n")
        stripped = strip(line)
        isempty(stripped) && continue
        startswith(stripped, "#") && continue
        return true
    end
    return false
end

function execute_heartbeat!(assistant::AgentAssistant)
    local_time = Dates.now()
    local_hour = Dates.hour(local_time)
    if local_hour < HEARTBEAT_START_HOUR || local_hour > HEARTBEAT_END_HOUR
        return nothing
    end
    if @atomic assistant.evaluating
        @debug "[vo] Heartbeat skipped: evaluation in progress"
        return nothing
    end
    first_heartbeat = local_hour == HEARTBEAT_START_HOUR
    last_heartbeat = local_hour == HEARTBEAT_END_HOUR
    has_tasks = heartbeat_has_tasks(assistant)
    if !first_heartbeat && !last_heartbeat && !has_tasks
        @debug "[vo] Heartbeat skipped: no pending tasks, not first/last"
        return nothing
    end
    offset_minutes = local_utc_offset_minutes(local_time)
    heartbeat_tasks_str = getHeartbeatTasks(assistant)
    skill_names = try
        skills = getSkills(assistant.db)
        [s.name for s in skills]
    catch
        String[]
    end
    prompt = heartbeat_prompt(local_time, offset_minutes, heartbeat_tasks_str, skill_names)
    result_state = @with TRIGGER_PROMPT => prompt evaluate(assistant, "Evaluate heartbeat prompt")
    if result_state !== nothing
        response_text = ""
        for msg in result_state.messages
            if msg isa Agentif.AssistantMessage
                response_text = Agentif.message_text(msg)
            end
        end
        response_hash = hash(response_text)
        now_unix = time()
        if response_hash == assistant.last_heartbeat_hash && (now_unix - assistant.last_heartbeat_time) < 86400.0
            @debug "[vo] Heartbeat deduplicated: identical to last response within 24h"
            return nothing
        end
        assistant.last_heartbeat_hash = response_hash
        assistant.last_heartbeat_time = now_unix
    end
    return nothing
end

function ensure_heartbeat!(assistant::AgentAssistant)
    offset_minutes = local_utc_offset_minutes()
    interval = assistant.config.heartbeat_interval_minutes
    schedule = heartbeat_schedule(offset_minutes, interval)
    job = Tempus.Job(
        () -> begin
            a = get_current_assistant()
            a === nothing && return nothing
            execute_heartbeat!(a)
        end, HEARTBEAT_JOB_NAME, schedule
    )
    Tempus.purgeJob!(assistant.scheduler.store, job.name)
    Tempus.isdisabled(job) && return job
    Tempus.addJob!(assistant.scheduler.store, job)
    return job
end

function trigger_event_heartbeat!(assistant::AgentAssistant, event_prompt::String)
    if @atomic assistant.evaluating
        @debug "[vo] Event heartbeat skipped: evaluation in progress"
        return nothing
    end
    @with TRIGGER_PROMPT => event_prompt evaluate(assistant, "Process event notification")
    return nothing
end

# --- Lifecycle ---

function run!(assistant::AgentAssistant)
    assistant.config.enable_heartbeat && ensure_heartbeat!(assistant)
    Tempus.run!(assistant.scheduler)
    @info "AgentAssistant initialized" provider=assistant.config.provider model=assistant.config.model_id
    return nothing
end

function Base.close(assistant::AgentAssistant)
    CURRENT_ASSISTANT[] === assistant && (CURRENT_ASSISTANT[] = nothing)
    try
        assistant.scheduler.running && Tempus.close(assistant.scheduler)
    catch err
        @warn "Failed to close scheduler" exception=(err, catch_backtrace())
    end
    return nothing
end

# --- REPL ---

function __init__()
    Base.get(ENV, "VO_AUTO_RUN", "") == "1" || return
    init!()
    return
end

function init!()
    agent = AgentAssistant()
    CURRENT_ASSISTANT[] = agent
    run!(agent)
    return
end

struct ReplResponse
    input::String
end

function Base.show(io::IO, resp::ReplResponse)
    return evaluate(get_current_assistant(), resp.input; channel=ReplChannel(io))
end

macro a_str(input)
    return :(ReplResponse($input))
end

end
