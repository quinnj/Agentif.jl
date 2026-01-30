module Vo

using Agentif
using LLMTools
using Dates
using JSON
using Logging
using Qmd
using SQLite
using Tempus
using UUIDs
using ScopedValues

export AbstractAssistantStore, FileStore, InMemoryStore
export AgentAssistant, AssistantConfig
export AgentSnapshot, HistoryEntry  # Note: Memory not exported to avoid conflict with Base.Memory in Julia 1.11+
export AssistantMessage, UserMessage
export run!, evaluate!, @a_str
export getIdentityAndPurpose, setIdentityAndPurpose!
export getUserProfile, setUserProfile!
export getBootstrap, setBootstrap!
export getHeartbeatTasks, setHeartbeatTasks!, trigger_event_heartbeat!
export getToolsGuide, setToolsGuide!
export addNewMemory, searchMemories, forgetMemory
export getHistoryAtIndex, appendHistory, searchHistory
export SkillMetadata, getSkills, addNewSkill, forgetSkill
export listJobs, addJob!, removeJob!
export enable_markdown_rendering, disable_markdown_rendering

const TRIGGER_PROMPT = ScopedValue{Union{String, Nothing}}(nothing)
const DEFAULT_IDENTITY = read(joinpath(@__DIR__, "soul_template.md"), String)
const DEFAULT_USER_PROFILE = read(joinpath(@__DIR__, "user_template.md"), String)
const DEFAULT_BOOTSTRAP = read(joinpath(@__DIR__, "bootstrap_template.md"), String)
const DEFAULT_TOOLS_GUIDE = read(joinpath(@__DIR__, "tools_template.md"), String)
const DEFAULT_HISTORY_CONTEXT_LIMIT = 10
const DEFAULT_MEMORY_CONTEXT_LIMIT = 6
const DEFAULT_HISTORY_PAGE_SIZE = 10
const ENV_AGENT_PROVIDER = "VO_AGENT_PROVIDER"
const ENV_AGENT_MODEL = "VO_AGENT_MODEL"
const ENV_AGENT_API_KEY = "VO_AGENT_API_KEY"
const IDENTITY_FILENAME = "identity.md"
const USER_PROFILE_FILENAME = "user.md"
const BOOTSTRAP_FILENAME = "bootstrap.md"
const MODES_DIRNAME = "modes"
const DEFAULT_MODES_DIR = joinpath(@__DIR__, "default_modes")
const MEMORIES_FILENAME = "memories.jsonl"
const HISTORY_FILENAME = "history.jsonl"
const SKILLS_DIRNAME = "skills"
const SCHEDULER_STORE_FILENAME = "scheduler.bin"
const HEARTBEAT_JOB_NAME = "heartbeat"
const TOOLS_GUIDE_FILENAME = "tools.md"
const HEARTBEAT_TASKS_FILENAME = "heartbeat.md"
const DEFAULT_HEARTBEAT_TASKS = ""
const HEARTBEAT_START_HOUR = 6
const HEARTBEAT_END_HOUR = 23
const HEARTBEAT_MINUTE = 0
const DEFAULT_HEARTBEAT_INTERVAL_MINUTES = 30
const DATABASE_FILENAME = "vo.sqlite"
const QMD_COLLECTION_NAME = "vo_data"
const QMD_COLLECTION_PATTERN = "**/*.{md,jsonl}"

const SkillMetadata = Agentif.SkillMetadata

struct Memory
    memory::String
    createdAt::Float64
    historyIndex::Int64
end

struct PersonalityMode
    name::String
    content::String
    chance::Float64       # 0.0-1.0, probability of activating when eligible
    active_start::Int     # Hour (0-23), -1 = no constraint
    active_end::Int       # Hour (0-23), -1 = no constraint
end

struct AgentSnapshot
    prompt::String
    provider::String
    modelId::String
    tools::Vector{String}
    skills::Vector{String}
end

struct HistoryEntry
    index::Int64
    createdAt::Float64
    snapshot::AgentSnapshot
    state::Agentif.AgentState
end

Base.@kwdef struct AssistantConfig
    provider::String
    model_id::String
    api_key::String
    history_context_limit::Int = DEFAULT_HISTORY_CONTEXT_LIMIT
    memory_context_limit::Int = DEFAULT_MEMORY_CONTEXT_LIMIT
    history_page_size::Int = DEFAULT_HISTORY_PAGE_SIZE
    base_dir::String = pwd()
    enable_heartbeat::Bool = true
    heartbeat_interval_minutes::Int = DEFAULT_HEARTBEAT_INTERVAL_MINUTES
end

abstract type AbstractAssistantStore end
mutable struct FileStore <: AbstractAssistantStore
    root::String
    lock::ReentrantLock
    identity_path::String
    user_profile_path::String
    bootstrap_path::String
    tools_guide_path::String
    heartbeat_tasks_path::String
    memories_path::String
    history_path::String
    skills_dir::String
    modes_dir::String
    history_offsets::Vector{Int64}
    history_count::Int64
    history_indexed::Bool
end

mutable struct InMemoryStore <: AbstractAssistantStore
    lock::ReentrantLock
    identity::String
    user_profile::String
    bootstrap::String
    tools_guide::String
    heartbeat_tasks::String
    memories::Vector{Memory}
    history::Vector{HistoryEntry}
    skills_dir::String
    modes_dir::String
    skills_registry::Agentif.SkillRegistry
end

# Global ref to the single assistant instance (Vo only runs one assistant at a time)
# Job closures capture nothing - they just access this global ref at execution time
const CURRENT_ASSISTANT = Ref{Any}(nothing)

function get_current_assistant()
    return CURRENT_ASSISTANT[]
end

mutable struct AgentAssistant{S <: AbstractAssistantStore, T <: IO} <: Agentif.AgentContext
    store::S
    scheduler::Tempus.Scheduler
    lock::ReentrantLock
    config::AssistantConfig
    messages::Channel{Union{String, Vector{Agentif.PendingToolCall}}} # channel type matches Agentif.evaluate! input type
    output::T
    initialized::Bool
    current_snapshot::Union{Nothing, AgentSnapshot}
    watcher_state::Union{Nothing, Qmd.Watcher.WatcherState}
    @atomic evaluating::Bool                      # true while an evaluation is in progress (#8: in-flight check)
    last_heartbeat_hash::UInt64                    # hash of last heartbeat response (#9: dedup)
    last_heartbeat_time::Float64                   # unix time of last heartbeat delivery (#9: dedup)
end

function normalize_text(value::Union{Nothing, AbstractString})
    value === nothing && return nothing
    cleaned = strip(value)
    isempty(cleaned) && return nothing
    return String(cleaned)
end

"""
Check if a bootstrap document still has unchecked items (`- [ ]`).
"""
bootstrap_has_unchecked(text::AbstractString) = occursin("- [ ]", text)

"""
Parse a keywords string into a list of lowercase keywords for searching.
"""
parse_keywords(keywords::String)::Vector{String} = [lowercase(k) for k in split(strip(keywords); keepempty = false)]

"""
Check if text contains any of the given keywords.
Returns true if keywords list is empty (matches everything) or if any keyword is found.
"""
function matches_keywords(text::String, keywords::Vector{String})::Bool
    isempty(keywords) && return true
    text_lower = lowercase(text)
    for kw in keywords
        occursin(kw, text_lower) && return true
    end
    return false
end

"""
Apply limit to results, returning first `limit` items or all if limit is nothing.
"""
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

function ensure_file(path::String)
    isfile(path) && return nothing
    mkpath(dirname(path))
    touch(path)
    return nothing
end

function write_atomic(path::String, content::String)
    dir = dirname(path)
    isdir(dir) || mkpath(dir)
    tmp_path = path * "." * string(UUIDs.uuid4()) * ".tmp"
    open(tmp_path, "w") do io
        write(io, content)
    end
    mv(tmp_path, path; force = true)
    return nothing
end

function write_jsonl_atomic(path::String, entries)
    dir = dirname(path)
    isdir(dir) || mkpath(dir)
    tmp_path = path * "." * string(UUIDs.uuid4()) * ".tmp"
    open(tmp_path, "w") do io
        for entry in entries
            write(io, JSON.json(entry))
            write(io, "\n")
        end
    end
    mv(tmp_path, path; force = true)
    return nothing
end

function append_jsonl(path::String, entry)
    dir = dirname(path)
    isdir(dir) || mkpath(dir)
    open(path, "a") do io
        write(io, JSON.json(entry))
        write(io, "\n")
    end
    return nothing
end

function FileStore(root::String)
    abs_root = abspath(root)
    store = FileStore(
        abs_root,
        ReentrantLock(),
        joinpath(abs_root, IDENTITY_FILENAME),
        joinpath(abs_root, USER_PROFILE_FILENAME),
        joinpath(abs_root, BOOTSTRAP_FILENAME),
        joinpath(abs_root, TOOLS_GUIDE_FILENAME),
        joinpath(abs_root, HEARTBEAT_TASKS_FILENAME),
        joinpath(abs_root, MEMORIES_FILENAME),
        joinpath(abs_root, HISTORY_FILENAME),
        joinpath(abs_root, SKILLS_DIRNAME),
        joinpath(abs_root, MODES_DIRNAME),
        Int64[],
        0,
        false,
    )
    initialize_store!(store)
    return store
end

function InMemoryStore(; identity::String = DEFAULT_IDENTITY, user_profile::String = DEFAULT_USER_PROFILE, bootstrap::String = DEFAULT_BOOTSTRAP)
    skills_dir = mktempdir()
    modes_dir = mktempdir()
    registry = Agentif.create_skill_registry([skills_dir]; warn = false)
    store = InMemoryStore(ReentrantLock(), identity, user_profile, bootstrap, DEFAULT_TOOLS_GUIDE, DEFAULT_HEARTBEAT_TASKS, Memory[], HistoryEntry[], skills_dir, modes_dir, registry)
    finalizer(store) do s
        isdir(s.skills_dir) && rm(s.skills_dir; recursive = true, force = true)
        isdir(s.modes_dir) && rm(s.modes_dir; recursive = true, force = true)
    end
    return store
end

function initialize_store!(store::FileStore)
    mkpath(store.root)
    if !isfile(store.identity_path)
        write_atomic(store.identity_path, DEFAULT_IDENTITY)
    end
    if !isfile(store.user_profile_path)
        write_atomic(store.user_profile_path, DEFAULT_USER_PROFILE)
    end
    if !isfile(store.bootstrap_path)
        write_atomic(store.bootstrap_path, DEFAULT_BOOTSTRAP)
    end
    if !isfile(store.tools_guide_path)
        write_atomic(store.tools_guide_path, DEFAULT_TOOLS_GUIDE)
    end
    ensure_file(store.heartbeat_tasks_path)
    ensure_file(store.memories_path)
    ensure_file(store.history_path)
    isdir(store.skills_dir) || mkpath(store.skills_dir)
    if !isdir(store.modes_dir)
        mkpath(store.modes_dir)
        # Seed default modes from package
        if isdir(DEFAULT_MODES_DIR)
            for f in readdir(DEFAULT_MODES_DIR)
                endswith(f, ".md") || continue
                src = joinpath(DEFAULT_MODES_DIR, f)
                dst = joinpath(store.modes_dir, f)
                isfile(dst) || cp(src, dst)
            end
        end
    end
    store.history_offsets = Int64[]
    store.history_count = 0
    store.history_indexed = false
    return nothing
end

function initialize_store!(store::InMemoryStore)
    isdir(store.skills_dir) || mkpath(store.skills_dir)
    return nothing
end

function ensure_history_index!(store::FileStore)
    store.history_indexed && return nothing
    offsets = Int64[]
    count = 0
    isfile(store.history_path) || begin
        store.history_offsets = offsets
        store.history_count = count
        store.history_indexed = true
        return nothing
    end
    open(store.history_path, "r") do io
        while !eof(io)
            push!(offsets, position(io))
            readline(io)
            count += 1
        end
    end
    store.history_offsets = offsets
    store.history_count = count
    store.history_indexed = true
    return nothing
end

function history_count(store::FileStore)
    return lock(store.lock) do
        ensure_history_index!(store)
        return store.history_count
    end
end

function history_count(store::InMemoryStore)
    return lock(store.lock) do
        return length(store.history)
    end
end

function ensure_initialized!(assistant::AgentAssistant)
    lock(assistant.lock) do
        assistant.initialized && return nothing
        initialize_store!(assistant.store)
        base_index = history_count(assistant.store) + 1
        assistant.initialized = true
    end
    return nothing
end

include("tools.jl")

function job_summary(job::Tempus.Job)
    enabled = !Tempus.isdisabled(job)
    schedule_str = job.schedule === nothing ? "" : string(job.schedule)
    return (; name = job.name, schedule = schedule_str, enabled = enabled)
end

function local_utc_offset_minutes(now_local::DateTime = Dates.now())
    delta_ms = Dates.value(now_local - Dates.now(UTC))
    return Int(div(delta_ms, 60_000))
end

function heartbeat_schedule(offset_minutes::Int, interval_minutes::Int=DEFAULT_HEARTBEAT_INTERVAL_MINUTES)
    # Generate cron minute field for the given interval
    # e.g. interval=60 → "0", interval=30 → "0,30", interval=15 → "0,15,30,45"
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

    # Build skill-aware checklist (#19)
    skill_section = if !isempty(skill_names)
        skill_list = join(["  - `$(s)`" for s in skill_names], "\n")
        """
        - Run relevant skills to surface recent or upcoming items. Available skills:
        $(skill_list)
          Use these to catch todos, events, messages, or content relevant to the user."""
    else
        "- Check for any available skills that surface recent or upcoming items (email, calendar, messaging, news)."
    end

    # Build pending tasks section (#6)
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
    - Review recent history and memories for events, lessons, or follow-ups worth acting on.
    $(skill_section)
    - Use memories about user interests to find or propose noteworthy content, refining interest/topics over time.
    - If responding outside the first/last heartbeat, be concise — only meaningful updates or actions.

    Learnings (#20):
    - If you discover any stable facts, patterns, or insights during this heartbeat, store them with addNewMemory.
    - On the last heartbeat of the day, briefly review recent memories for any that are stale or redundant — propose pruning if needed.
    """
end

function build_scheduler(store::AbstractAssistantStore)
    if store isa FileStore
        path = joinpath(store.root, SCHEDULER_STORE_FILENAME)
        isfile(path) && rm(path; force = true)
        return Tempus.Scheduler(Tempus.FileStore(path))
    end
    return Tempus.Scheduler(Tempus.InMemoryStore())
end

function AgentAssistant(;
        data_dir::Union{Nothing, String} = nothing,
        provider::Union{Nothing, String} = nothing,
        model_id::Union{Nothing, String} = nothing,
        api_key::Union{Nothing, String} = nothing,
        history_context_limit::Int = DEFAULT_HISTORY_CONTEXT_LIMIT,
        memory_context_limit::Int = DEFAULT_MEMORY_CONTEXT_LIMIT,
        history_page_size::Int = DEFAULT_HISTORY_PAGE_SIZE,
        base_dir::String = pwd(),
        enable_heartbeat::Bool = true,
        heartbeat_interval_minutes::Int = DEFAULT_HEARTBEAT_INTERVAL_MINUTES,
        output::IO = stdout
    )
    data_dir = data_dir === nothing ? Base.get(ENV, "VO_DATA_DIR", nothing) : data_dir
    if data_dir === nothing
        store = InMemoryStore()
        scheduler = Tempus.Scheduler(Tempus.InMemoryStore())
    else
        store = FileStore(data_dir)
        scheduler = build_scheduler(store)
    end
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
        history_context_limit = history_context_limit,
        memory_context_limit = memory_context_limit,
        history_page_size = history_page_size,
        base_dir = base_dir,
        enable_heartbeat = enable_heartbeat,
        heartbeat_interval_minutes = heartbeat_interval_minutes,
    )
    model = Agentif.getModel(config.provider, config.model_id)
    model === nothing && error("Unknown model provider=$(config.provider) model_id=$(config.model_id)")
    assistant = AgentAssistant(
        store,
        scheduler,
        ReentrantLock(),
        config,
        Channel{Union{String, Vector{Agentif.PendingToolCall}}}(Inf),
        output,
        false,
        nothing,  # current_snapshot
        nothing,  # watcher_state
        false,    # evaluating (in-flight flag)
        UInt64(0),# last_heartbeat_hash
        0.0,      # last_heartbeat_time
    )
    # Set as current assistant so job closures can access it without capturing the full object
    CURRENT_ASSISTANT[] = assistant
    return assistant
end

"""
Build a context query string from recent history for memory retrieval.
"""
function build_memory_query(history_entries::Vector{HistoryEntry}; max_chars::Int=500)
    isempty(history_entries) && return ""

    # Collect recent user messages and assistant responses
    parts = String[]
    total_chars = 0

    # Process entries in reverse (most recent first)
    for entry in reverse(history_entries)
        user_text, assistant_text = history_summary(entry)

        # Add user message (prioritize user context)
        if !isempty(user_text) && total_chars < max_chars
            push!(parts, user_text)
            total_chars += length(user_text)
        end

        # Add assistant response keywords if space allows
        if !isempty(assistant_text) && total_chars < max_chars
            # Take first 100 chars of assistant response
            snippet = length(assistant_text) > 100 ? assistant_text[1:100] : assistant_text
            push!(parts, snippet)
            total_chars += length(snippet)
        end

        total_chars >= max_chars && break
    end

    return join(parts, " ")
end

"""
Retrieve memories relevant to the current conversation context using semantic search.
Falls back to recent memories if semantic search is unavailable.
"""
function get_relevant_memories(assistant::AgentAssistant, history_entries::Vector{HistoryEntry})
    store = assistant.store
    limit = assistant.config.memory_context_limit
    limit <= 0 && return Memory[]

    # Build context query from recent history
    context_query = build_memory_query(history_entries)

    # Try semantic search if we have context and Qmd is available
    if !isempty(context_query)
        db_path = get_database_path(store)
        if db_path !== nothing && isfile(db_path)
            try
                # Search memories using Qmd semantic search
                result = LLMTools.qmd_search(context_query; limit=limit * 2, search_mode=:combined)
                if result["success"] && !isempty(result["results"])
                    # Load all memories and match against semantic results
                    all_memories = load_all_memories(store)
                    isempty(all_memories) && return Memory[]

                    # Score memories with weighted relevance + recency
                    scored_memories = Tuple{Memory, Float64}[]
                    result_snippets = [(r["snippet"], r["score"]) for r in result["results"]]
                    now_unix = time()
                    # Find time range for normalization
                    oldest = minimum(m.createdAt for m in all_memories)
                    time_range = max(now_unix - oldest, 1.0)

                    for mem in all_memories
                        mem_lower = lowercase(mem.memory)
                        best_relevance = 0.0

                        for (snippet, score) in result_snippets
                            snippet_lower = lowercase(snippet)
                            if occursin(mem_lower, snippet_lower) || occursin(snippet_lower, mem_lower)
                                best_relevance = max(best_relevance, score)
                            end
                        end

                        if best_relevance > 0.0
                            # Weighted combination: 70% relevance, 30% recency
                            recency = (mem.createdAt - oldest) / time_range  # 0.0 (oldest) to 1.0 (newest)
                            combined = 0.7 * best_relevance + 0.3 * recency
                            push!(scored_memories, (mem, combined))
                        end
                    end

                    if !isempty(scored_memories)
                        sort!(scored_memories; by=x -> -x[2])
                        return [m for (m, _) in scored_memories[1:min(limit, length(scored_memories))]]
                    end
                end
            catch err
                @debug "Semantic memory retrieval failed, falling back to keyword search" exception=err
            end
        end
    end

    # Fallback: return most recent memories that match any keywords from context
    if !isempty(context_query)
        keywords = split(context_query)
        # Filter to meaningful keywords (length > 3)
        keywords = filter(k -> length(k) > 3, keywords)
        if !isempty(keywords)
            # Search with first few keywords
            keyword_str = join(keywords[1:min(5, length(keywords))], " ")
            results = searchMemories(store, keyword_str; limit=limit, semantic=false)
            !isempty(results) && return results
        end
    end

    # Ultimate fallback: return most recent memories
    all_memories = load_all_memories(store)
    sort!(all_memories; by=m -> m.createdAt, rev=true)
    return all_memories[1:min(limit, length(all_memories))]
end

"""
Parse a personality mode from a markdown file with frontmatter.
Expected format:
```
---
name: casual
chance: 0.15
active_start: 17
active_end: 23
---
Mode content here...
```
"""
function parse_personality_mode(path::String)
    text = read(path, String)
    # Parse frontmatter between --- delimiters
    m = match(r"^---\s*\n(.*?)\n---\s*\n(.*)"s, text)
    m === nothing && return nothing
    frontmatter = m.captures[1]
    content = strip(String(m.captures[2]))
    isempty(content) && return nothing

    name = ""
    chance = 0.0
    active_start = -1
    active_end = -1
    for line in split(frontmatter, "\n")
        kv = split(strip(line), ":", limit=2)
        length(kv) != 2 && continue
        key = strip(kv[1])
        val = strip(kv[2])
        if key == "name"
            name = val
        elseif key == "chance"
            chance = parse(Float64, val)
        elseif key == "active_start"
            active_start = parse(Int, val)
        elseif key == "active_end"
            active_end = parse(Int, val)
        end
    end
    isempty(name) && return nothing
    return PersonalityMode(name, content, chance, active_start, active_end)
end

function list_personality_modes(store::AbstractAssistantStore)
    dir = store isa FileStore ? store.modes_dir : store.modes_dir
    isdir(dir) || return PersonalityMode[]
    modes = PersonalityMode[]
    for f in readdir(dir)
        endswith(f, ".md") || continue
        mode = parse_personality_mode(joinpath(dir, f))
        mode !== nothing && push!(modes, mode)
    end
    return modes
end

"""
Check all personality modes and return one if conditions match (time window + random chance).
Returns nothing if no mode activates.
"""
function resolve_active_mode(store::AbstractAssistantStore)
    modes = list_personality_modes(store)
    isempty(modes) && return nothing
    hour = Dates.hour(Dates.now())
    eligible = PersonalityMode[]
    for mode in modes
        # Check time window
        if mode.active_start >= 0 && mode.active_end >= 0
            if mode.active_start <= mode.active_end
                (hour < mode.active_start || hour >= mode.active_end) && continue
            else  # wraps midnight, e.g. 22-6
                (hour < mode.active_start && hour >= mode.active_end) && continue
            end
        end
        push!(eligible, mode)
    end
    isempty(eligible) && return nothing
    # Roll dice for each eligible mode
    for mode in eligible
        rand() < mode.chance && return mode
    end
    return nothing
end

function build_prompt(assistant::AgentAssistant; trigger_prompt::Union{Nothing, String} = TRIGGER_PROMPT[])
    identity = getIdentityAndPurpose(assistant.store)
    user_profile = getUserProfile(assistant.store)
    history_entries = listHistory(assistant.store, max(1, history_count(assistant.store) - assistant.config.history_context_limit + 1), assistant.config.history_context_limit)

    # Retrieve relevant memories based on conversation context
    relevant_memories = get_relevant_memories(assistant, history_entries)

    io = IOBuffer()
    print(io, "You are Vo.\n\n## Identity & Purpose\n")
    print(io, identity, "\n")

    # Check for active personality mode overlay
    active_mode = resolve_active_mode(assistant.store)
    if active_mode !== nothing
        print(io, "\n## Active Personality Mode: ", active_mode.name, "\n")
        print(io, active_mode.content, "\n")
    end

    # Inject user profile
    print(io, "\n## User Profile\n")
    print(io, user_profile, "\n")

    # Inject bootstrap checklist if onboarding is still in progress
    bootstrap = getBootstrap(assistant.store)
    if bootstrap_has_unchecked(bootstrap)
        print(io, "\n## Onboarding\n")
        print(io, "You are still learning about this user. Use natural conversation to fill in the gaps below. Don't interrogate — weave questions into helpful interactions. When you learn something, check it off here and update the user profile.\n\n")
        print(io, bootstrap, "\n")
    end

    # Inject tools guide
    tools_guide = getToolsGuide(assistant.store)
    if !isempty(strip(tools_guide))
        print(io, "\n## Tool Usage Guide\n")
        print(io, tools_guide, "\n")
    end

    # Inject relevant memories
    if !isempty(relevant_memories)
        print(io, "\n## Relevant Memories\n")
        print(io, "The following memories may be relevant to the current conversation:\n")
        for mem in relevant_memories
            # Format timestamp
            timestamp = Dates.unix2datetime(mem.createdAt)
            date_str = Dates.format(timestamp, "yyyy-mm-dd HH:MM")
            print(io, "- [", date_str, "] ", mem.memory, "\n")
        end
    end

    if !isempty(history_entries)
        print(io, "\n## Recent History\n")
        for entry in history_entries
            user_text, assistant_text = history_summary(entry)
            print(io, "- [", entry.index, "] User: ", user_text, "\n  Vo: ", assistant_text, "\n")
        end
    end
    if trigger_prompt !== nothing
        print(io, "\n## Trigger Prompt\n", trigger_prompt, "\n")
    end
    return String(take!(io))
end

available_tool_names(tools::Vector{Agentif.AgentTool}) = [tool.name for tool in tools]

function available_skill_names(registry::Agentif.SkillRegistry)
    names = collect(keys(registry.skills))
    sort!(names)
    return names
end

function history_summary(entry::HistoryEntry)
    user = ""
    assistant = ""
    for msg in entry.state.messages
        if msg isa Agentif.UserMessage
            user = Agentif.message_text(msg)
        elseif msg isa Agentif.AssistantMessage
            assistant = Agentif.message_text(msg)
        end
    end
    return user, assistant
end

function history_search_text(entry::HistoryEntry)
    parts = String[]
    for msg in entry.state.messages
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
    return lowercase(join(parts, "\n"))
end

function build_error_state(input::String, error_text::String)
    messages = Agentif.AgentMessage[]
    push!(messages, Agentif.UserMessage(input))
    push!(messages, Agentif.AssistantMessage(; provider = "local", api = "local", model = "local", content = Agentif.AssistantContentBlock[Agentif.TextContent(error_text)]))
    usage = Agentif.Usage()
    pending = Agentif.PendingToolCall[]
    return Agentif.AgentState(messages, nothing, usage, pending)
end

function Agentif.get_agent(assistant::AgentAssistant)
    ensure_initialized!(assistant)
    prompt = build_prompt(assistant)
    tools = build_tools(assistant)
    tool_names = available_tool_names(tools)
    registry = get_skills_registry(assistant.store)
    skill_names = available_skill_names(registry)
    assistant.current_snapshot = AgentSnapshot(prompt, assistant.config.provider, assistant.config.model_id, tool_names, skill_names)
    return Agentif.Agent(
        ; prompt,
        model = Agentif.getModel(assistant.config.provider, assistant.config.model_id),
        apikey = assistant.config.api_key,
        state = Agentif.AgentState(),
        skills = registry,
        tools,
    )
end

function Agentif.handle_event(assistant::AgentAssistant, event::Agentif.AgentEvent)
    return if event isa Agentif.AgentEvaluateStartEvent
        @debug "[vo] AgentEvaluateStartEvent received"
        @atomic assistant.evaluating = true
        lock(assistant.lock) # ensure only one evaluation happens at a time (mostly user inputs vs. scheduled prompts)
    elseif event isa Agentif.AgentEvaluateEndEvent
        @debug "[vo] AgentEvaluateEndEvent received" has_result = (event.result !== nothing)
        try
            @atomic assistant.evaluating = false
            # event.result can be nothing if evaluation failed
            if event.result !== nothing && hasproperty(event.result, :state)
                index = history_count(assistant.store) + 1
                history_entry = HistoryEntry(index, time(), assistant.current_snapshot, event.result.state)
                appendHistory(assistant.store, history_entry)
            end
        finally
            unlock(assistant.lock)
        end
    elseif event isa Agentif.MessageUpdateEvent
        # Write directly to avoid any terminal width-based wrapping
        @debug "[vo] MessageUpdateEvent" delta_len = length(event.delta) output_type = typeof(assistant.output)
        write(assistant.output, event.delta)
    elseif event isa Agentif.MessageEndEvent
        @debug "[vo] MessageEndEvent"
        println(assistant.output)
    end
end

function run!(assistant::AgentAssistant)
    ensure_initialized!(assistant)
    # Register heartbeat job in the store BEFORE starting the scheduler,
    # so Tempus.run! picks it up from the store at startup.
    # We can't use push! here because the scheduler loop isn't running yet
    # and push! acquires scheduler.lock which deadlocks on single-threaded Julia.
    assistant.config.enable_heartbeat && ensure_heartbeat!(assistant)
    Tempus.run!(assistant.scheduler)
    # Start Qmd watcher for semantic search
    start_qmd_watcher!(assistant)
    @info "AgentAssistant initialized" provider = assistant.config.provider model = assistant.config.model_id
    return nothing
end

function get_database_path(store::FileStore)
    return joinpath(store.root, DATABASE_FILENAME)
end

function get_database_path(store::InMemoryStore)
    return nothing  # In-memory stores don't use SQLite
end

function start_qmd_watcher!(assistant::AgentAssistant)
    store = assistant.store
    store isa InMemoryStore && return nothing  # Skip for in-memory stores

    data_dir = store.root
    db_path = get_database_path(store)

    # Set the LLMTools store path so qmd_* tools use our database
    LLMTools.qmd_set_store_path(db_path)

    # Ensure Qmd collection exists for the data directory
    try
        existing = Qmd.Collections.get_collection(QMD_COLLECTION_NAME)
        if existing === nothing || existing.path != data_dir
            existing !== nothing && Qmd.Collections.remove(QMD_COLLECTION_NAME)
            Qmd.Collections.add(QMD_COLLECTION_NAME, data_dir; pattern=QMD_COLLECTION_PATTERN)
        end

        # Index only the vo_data collection (not all collections, which may include
        # stale entries pointing to deleted temp directories)
        collection = Qmd.Collections.get_collection(QMD_COLLECTION_NAME)
        local_store = Qmd.Store.open_store(db_path)
        try
            Qmd.Indexer.index_collection(local_store, collection)
        finally
            Qmd.Store.close(local_store)
        end

        # Start watching for changes (non-blocking)
        assistant.watcher_state = Qmd.start_watching(;
            debounce_ms=500,
            store_path=db_path,
            on_error=(collection, err) -> @warn "Qmd watcher error" collection exception=err
        )
        @debug "Qmd watcher started for" data_dir
    catch err
        @warn "Failed to start Qmd watcher" exception=(err, catch_backtrace())
    end
    return nothing
end

function stop_qmd_watcher!(assistant::AgentAssistant)
    if assistant.watcher_state !== nothing
        try
            Qmd.stop_watching()
            assistant.watcher_state = nothing
            @debug "Qmd watcher stopped"
        catch err
            @warn "Failed to stop Qmd watcher" exception=(err, catch_backtrace())
        end
    end
    return nothing
end

function Base.close(assistant::AgentAssistant)
    # Clear global ref if this is the current assistant
    CURRENT_ASSISTANT[] === assistant && (CURRENT_ASSISTANT[] = nothing)
    lock(assistant.lock) do
        try
            isopen(assistant.messages) && close(assistant.messages)
            # Only close scheduler if it's actually running to avoid hanging
            assistant.scheduler.running && Tempus.close(assistant.scheduler)
        catch err
            @warn "Failed to close scheduler" exception = (err, catch_backtrace())
        end
        # Stop Qmd watcher
        stop_qmd_watcher!(assistant)
    end
    return nothing
end

function sync_scheduled_jobs!(assistant::AgentAssistant)
    for job in listJobs(assistant.scheduler)
        sync_job!(assistant, job)
    end
    return nothing
end

function sync_job!(assistant::AgentAssistant, job::Tempus.Job)
    Tempus.purgeJob!(assistant.scheduler.store, job.name)
    Tempus.isdisabled(job) && return nothing
    push!(assistant.scheduler, job)
    return nothing
end

"""
Check if heartbeat.md has actionable content (non-empty, non-comment-only).
"""
function heartbeat_has_tasks(store::AbstractAssistantStore)
    tasks = getHeartbeatTasks(store)
    # Strip comments (lines starting with #) and whitespace
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

    # #8: Skip if an evaluation is currently in progress (don't interrupt active conversation)
    if @atomic assistant.evaluating
        @debug "[vo] Heartbeat skipped: evaluation in progress"
        return nothing
    end

    first_heartbeat = local_hour == HEARTBEAT_START_HOUR
    last_heartbeat = local_hour == HEARTBEAT_END_HOUR
    has_tasks = heartbeat_has_tasks(assistant.store)

    # #11: Empty-check optimization — skip LLM call for mid-day heartbeats with nothing to do
    if !first_heartbeat && !last_heartbeat && !has_tasks
        @debug "[vo] Heartbeat skipped: no pending tasks, not first/last"
        return nothing
    end

    # Build heartbeat prompt with tasks and skill names
    offset_minutes = local_utc_offset_minutes(local_time)
    heartbeat_tasks = getHeartbeatTasks(assistant.store)
    skill_names = try
        skills = getSkills(assistant.store)
        [s.name for s in skills]
    catch
        String[]
    end
    prompt = heartbeat_prompt(local_time, offset_minutes, heartbeat_tasks, skill_names)

    result = @with TRIGGER_PROMPT => prompt Agentif.evaluate(assistant, "Evaluate heartbeat prompt")

    # #9: Deduplication — skip delivery if response is identical to last heartbeat within 24h
    if result !== nothing && hasproperty(result, :state)
        response_text = ""
        for msg in result.state.messages
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
    # Job closure captures nothing - looks up assistant from global ref at execution time
    job = Tempus.Job(
        () -> begin
            a = get_current_assistant()
            a === nothing && return nothing  # Assistant was closed
            execute_heartbeat!(a)
        end, HEARTBEAT_JOB_NAME, schedule
    )
    # Add directly to store (not push!) so scheduler picks it up at startup.
    # push! acquires scheduler.lock which deadlocks when scheduler loop isn't running
    # or is holding the lock on single-threaded Julia.
    Tempus.purgeJob!(assistant.scheduler.store, job.name)
    Tempus.isdisabled(job) && return job
    Tempus.addJob!(assistant.scheduler.store, job)
    return job
end

"""
Trigger an immediate heartbeat-like evaluation with a custom prompt.
Used for exec completion events (#10) and other proactive notifications.
"""
function trigger_event_heartbeat!(assistant::AgentAssistant, event_prompt::String)
    # Skip if evaluation in progress
    if @atomic assistant.evaluating
        @debug "[vo] Event heartbeat skipped: evaluation in progress"
        return nothing
    end
    @with TRIGGER_PROMPT => event_prompt Agentif.evaluate(assistant, "Process event notification")
    return nothing
end

# include("vo_repl_mode.jl")

function is_test_mode()
    # Check environment variable for explicit skip
    Base.get(ENV, "VO_SKIP_INIT", "") == "1" && return true
    # Check if running a test script (program file contains "test" or "runtests")
    prog = string(Base.PROGRAM_FILE)
    !isempty(prog) && occursin(r"(runtests|test)"i, prog) && return true
    # Check ARGS for test file paths
    for arg in ARGS
        occursin(r"(runtests|test)"i, arg) && return true
    end
    return false
end

function __init__()
    is_test_mode() && return
    agent = AgentAssistant()
    CURRENT_ASSISTANT[] = agent
    run!(agent)
    return
end

struct ReplResponse
    input::String
end

mutable struct Done
    @atomic done::Bool
end

Done() = Done(false)
done!(d::Done) = @atomic d.done = true
isdone(d::Done) = @atomic d.done

const SPINNER_FRAMES = ('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')
const CLEAR_LINE = "\e[2K"

function Base.show(io::IO, resp::ReplResponse)
    d = Done()
    # immediately spawn 'thinking...' task
    Threads.@spawn begin
        idx = 1
        while !isdone(d)
            i = mod1(idx, length(SPINNER_FRAMES))
            spinner_text = "$(SPINNER_FRAMES[i]) thinking..."
            # Simple in-place update: go to start of line, clear, print spinner
            print(io, "\r", CLEAR_LINE, spinner_text)
            flush(io)
            idx += 1
            sleep(0.08)
        end
    end
    return Agentif.evaluate(get_current_assistant(), resp.input) do event
        if event isa Agentif.MessageUpdateEvent
            if !isdone(d)
                done!(d)
                println(io)
            end
        end
    end
end

macro a_str(input)
    return :(ReplResponse($input))
end

end
