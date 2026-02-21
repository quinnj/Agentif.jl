module Vo

using Agentif
using Dates
using LLMTools
using LocalSearch
using ScopedValues: @with
using SQLite
using Tempus
using TimeZones

export EventSource, Event, ChannelEvent, EventType, EventHandler
export AgentConfig, AgentAssistant
export get_channels, get_event_types, get_event_handlers, get_tools
export get_name, get_channel, event_content, get_session_key
export register_event_source!, register_channels!, register_event_handler!, unregister_event_handler!
export evaluate, init!, run, start!, get_current_assistant, scrub_post!
export ReplChannel, ReplEventSource, ReplInputEvent
export @a_str

# ─── Abstract types ───

abstract type EventSource end
abstract type Event end
abstract type ChannelEvent <: Event end

# ─── Soul template ───

const SOUL_TEMPLATE = read(joinpath(@__DIR__, "soul_template.md"), String)

function _detect_timezone()
    tz = get(ENV, "TZ", "")
    !isempty(tz) && return tz
    if Sys.isunix()
        try
            link = readlink("/etc/localtime")
            m = match(r"zoneinfo/(.+)$", link)
            m !== nothing && return String(m.captures[1])
        catch; end
    end
    return "UTC"
end

const AGENT_DATA_WRITE_LOCK = ReentrantLock()

function _resolve_timezone(name::String)
    try
        return TimeZone(name)
    catch
        return tz"UTC"
    end
end

function _zdt_to_unix(zdt::ZonedDateTime)
    return datetime2unix(DateTime(astimezone(zdt, tz"UTC")))
end

# ─── Core types ───

struct EventType
    name::String
    description::String
end

struct EventHandler
    id::String
    event_types::Vector{String}  # event type names
    prompt::String
    channel_id::Union{Nothing, String}
end

Base.@kwdef struct AgentConfig
    name::String = "Vo"
    provider::String
    model_id::String
    apikey::String
    timezone::String = _detect_timezone()
    base_dir::String = pwd()
    enable_terminal::Bool = false
    enable_workers::Bool = false
    enable_web::Bool = false
    enable_coding::Bool = false
end

struct AgentAssistant
    config::AgentConfig
    db::SQLite.DB
    _channels::Dict{String, Agentif.AbstractChannel}  # runtime-only registry
    event_queue::Base.Channel{Event}
    session_store::Agentif.SessionStore
    tools::Vector{Agentif.AgentTool}
    scheduler::Tempus.Scheduler
end

# ─── SQLite schema ───

function _init_vo_schema!(db::SQLite.DB)
    SQLite.DBInterface.execute(db, "PRAGMA journal_mode=WAL")
    SQLite.DBInterface.execute(db, "PRAGMA synchronous=NORMAL")
    SQLite.DBInterface.execute(db, "PRAGMA foreign_keys=ON")
    SQLite.DBInterface.execute(db, "PRAGMA busy_timeout=5000")

    SQLite.DBInterface.execute(db, "DROP TABLE IF EXISTS vo_channels")

    SQLite.DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS vo_event_types (
            name TEXT PRIMARY KEY,
            description TEXT NOT NULL DEFAULT ''
        )
    """)

    SQLite.DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS vo_event_handlers (
            id TEXT PRIMARY KEY,
            prompt TEXT NOT NULL DEFAULT '',
            channel_id TEXT
        )
    """)

    SQLite.DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS vo_handler_event_types (
            handler_id TEXT NOT NULL,
            event_type_name TEXT NOT NULL,
            PRIMARY KEY (handler_id, event_type_name)
        )
    """)

    SQLite.DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS vo_sessions (
            session_key TEXT PRIMARY KEY,
            session_id TEXT NOT NULL
        )
    """)

    SQLite.DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS vo_agent_data (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            channel_id TEXT,
            channel_flags INTEGER,
            user_id TEXT,
            post_id TEXT
        )
    """)

    SQLite.DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS vo_agent_data_tags (
            key TEXT NOT NULL REFERENCES vo_agent_data(key) ON DELETE CASCADE,
            tag TEXT NOT NULL,
            PRIMARY KEY (key, tag)
        )
    """)
    SQLite.DBInterface.execute(db, "CREATE INDEX IF NOT EXISTS idx_vo_agent_data_tags_tag ON vo_agent_data_tags(tag)")
end

# ─── EventSource interface ───

get_channels(::EventSource) = Agentif.AbstractChannel[]
get_event_types(::EventSource) = EventType[]
get_event_handlers(::EventSource) = EventHandler[]
get_tools(::EventSource) = Agentif.AgentTool[]
start!(::EventSource, ::AgentAssistant) = nothing

function run(; event_sources=nothing, kwargs...)
    return init!(""; event_sources, kwargs...)
end

# ─── Event interface ───

get_name(ev::Event) = error("get_name not implemented for $(typeof(ev))")
get_channel(ev::ChannelEvent) = error("get_channel not implemented for $(typeof(ev))")
event_content(ev::Event) = error("event_content not implemented for $(typeof(ev))")
get_session_key(::Event) = nothing
get_session_key(ev::ChannelEvent) = Agentif.channel_id(get_channel(ev))

# ─── Global state ───

const CURRENT_ASSISTANT = Ref{Union{Nothing, AgentAssistant}}(nothing)
get_current_assistant() = CURRENT_ASSISTANT[]

const EVENT_SOURCES = Set{EventSource}()
const EVENT_SOURCES_LOCK = ReentrantLock()

function register_event_source!(es::EventSource)
    lock(EVENT_SOURCES_LOCK) do
        push!(EVENT_SOURCES, es)
    end
    return es
end

# ─── Registration ───

function register_event_source!(assistant::AgentAssistant, es::EventSource)
    register_event_source!(es)
    db = assistant.db
    for ch in get_channels(es)
        id = Agentif.channel_id(ch)
        assistant._channels[id] = ch
    end
    for et in get_event_types(es)
        SQLite.DBInterface.execute(db,
            "INSERT OR IGNORE INTO vo_event_types (name, description) VALUES (?, ?)",
            (et.name, et.description))
    end
    for eh in get_event_handlers(es)
        _upsert_event_handler!(db, eh)
    end
    append!(assistant.tools, get_tools(es))
    return es
end

function register_channels!(assistant::AgentAssistant, channels)
    for ch in channels
        id = Agentif.channel_id(ch)
        assistant._channels[id] = ch
    end
end

function _upsert_event_handler!(db::SQLite.DB, eh::EventHandler)
    SQLite.DBInterface.execute(db,
        "INSERT OR REPLACE INTO vo_event_handlers (id, prompt, channel_id) VALUES (?, ?, ?)",
        (eh.id, eh.prompt, eh.channel_id))
    SQLite.DBInterface.execute(db,
        "DELETE FROM vo_handler_event_types WHERE handler_id = ?", (eh.id,))
    for et_name in eh.event_types
        SQLite.DBInterface.execute(db,
            "INSERT OR IGNORE INTO vo_handler_event_types (handler_id, event_type_name) VALUES (?, ?)",
            (eh.id, et_name))
    end
end

function register_event_handler!(assistant::AgentAssistant, eh::EventHandler)
    _upsert_event_handler!(assistant.db, eh)
    return
end

function unregister_event_handler!(assistant::AgentAssistant, handler_id::String)
    db = assistant.db
    SQLite.DBInterface.execute(db, "DELETE FROM vo_handler_event_types WHERE handler_id = ?", (handler_id,))
    SQLite.DBInterface.execute(db, "DELETE FROM vo_event_handlers WHERE id = ?", (handler_id,))
    SQLite.DBInterface.execute(db, "DELETE FROM vo_sessions WHERE session_key = ?", (handler_id,))
    return
end

# ─── Prompt building ───

function make_prompt(prompt::String, ev::Event)
    content = event_content(ev)
    isempty(prompt) && return content
    isempty(content) && return prompt
    return string(prompt, "\n\nEvent content:\n\n", content)
end

# ─── System prompt ───

const GROUP_CHAT_PROMPT = """

## Group Chat Guidelines

You are in a **group chat** with multiple users. Messages are prefixed with `[Username]:` to identify the sender.

### When to Respond
- Respond when directly addressed by name or @-mention.
- Respond when asked a question you can meaningfully answer.
- Respond when you can correct a significant factual error.
- Do NOT respond to every message. Silence is appropriate when users are conversing among themselves.
- Do NOT echo, agree with, or restate what someone already said.

### When to Stay Silent
If no response is needed, reply with exactly `∅` and nothing else.
Be extremely selective — only reply when directly addressed or when you can add clear value. When in doubt, stay silent.

### How to Respond
- Keep responses concise — group chats favor brevity.
- Address the specific user by name when replying.
- Write like a human — avoid overly structured formatting in group chats.
- Be a good group participant: mostly lurk and follow the conversation.

### Privacy
- Never share information from private/DM conversations in the group.
- Only reference information from this group's history or public channels.
"""

const PRIVATE_GROUP_ADDENDUM = """
This is a **private** group chat. Content here should not be shared in public channels.
"""

const PUBLIC_GROUP_ADDENDUM = """
This is a **public** channel. Be mindful that responses are visible to everyone.
Do not reference or reveal information from private conversations or DMs.
"""

function build_system_prompt(config::AgentConfig; channel::Union{Nothing, Agentif.AbstractChannel}=nothing)
    prompt = SOUL_TEMPLATE
    if channel !== nothing && Agentif.is_group(channel)
        prompt = string(prompt, GROUP_CHAT_PROMPT)
        if Agentif.is_private(channel)
            prompt = string(prompt, PRIVATE_GROUP_ADDENDUM)
        else
            prompt = string(prompt, PUBLIC_GROUP_ADDENDUM)
        end
    end
    return prompt
end

function build_context_prefix(config::AgentConfig)
    tz = _resolve_timezone(config.timezone)
    now_dt = TimeZones.now(tz)
    local_dt = DateTime(now_dt)
    date_str = Dates.format(local_dt, "EEEE, U d, yyyy")
    time_str = Dates.format(local_dt, "HH:MM")
    return string("[Current date: ", date_str, ", time: ", time_str, " (", config.timezone, ")]")
end

# ─── Tempus event ───

struct TempusJobEvent <: Event
    event_type::String
end

get_name(ev::TempusJobEvent) = ev.event_type
event_content(::TempusJobEvent) = ""

function _fire_tempus_job(; event_type::String)
    assistant = get_current_assistant()
    assistant === nothing && return
    put!(assistant.event_queue, TempusJobEvent(event_type))
    return
end

# ─── Session helper ───

function _get_or_create_session(db::SQLite.DB, session_key::String)
    result = iterate(SQLite.DBInterface.execute(db,
        "SELECT session_id FROM vo_sessions WHERE session_key = ?", (session_key,)))
    if result !== nothing
        return result[1].session_id
    end
    sid = Agentif.new_session_id()
    SQLite.DBInterface.execute(db,
        "INSERT INTO vo_sessions (session_key, session_id) VALUES (?, ?)",
        (session_key, sid))
    return sid
end

# ─── Management tools ───

const LIST_CHANNELS_TOOL = @tool "List all registered messaging channels with their IDs, type, and group/private status. Use the channel ID when calling add_job or add_event_handler." function list_channels()
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    # Refresh channels from all event sources
    lock(EVENT_SOURCES_LOCK) do
        for es in EVENT_SOURCES
            for ch in get_channels(es)
                a._channels[Agentif.channel_id(ch)] = ch
            end
        end
    end
    lines = String[]
    for (id, ch) in sort!(collect(a._channels); by=first)
        name = Agentif.channel_name(ch)
        group = Agentif.is_group(ch) ? "group" : "direct"
        privacy = Agentif.is_private(ch) ? "private" : "public"
        label = name == id ? id : "$name ($id)"
        push!(lines, "- $label — $group, $privacy")
    end
    isempty(lines) ? "No channels registered" : join(lines, "\n")
end

const LIST_EVENT_TYPES_TOOL = @tool "List all registered event types." function list_event_types()
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    lines = String[]
    for row in SQLite.DBInterface.execute(a.db, "SELECT name, description FROM vo_event_types")
        push!(lines, "- $(row.name): $(row.description)")
    end
    isempty(lines) ? "No event types registered" : join(lines, "\n")
end

const LIST_EVENT_HANDLERS_TOOL = @tool "List all registered event handlers with their event types, channel, and prompt." function list_event_handlers()
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    lines = String[]
    for row in SQLite.DBInterface.execute(a.db, "SELECT id, prompt, channel_id FROM vo_event_handlers")
        ch_id = row.channel_id === missing ? "none" : row.channel_id
        ets = String[]
        for et_row in SQLite.DBInterface.execute(a.db,
            "SELECT event_type_name FROM vo_handler_event_types WHERE handler_id = ?", (row.id,))
            push!(ets, et_row.event_type_name)
        end
        prompt_preview = length(row.prompt) > 80 ? string(row.prompt[1:80], "...") : row.prompt
        push!(lines, "- $(row.id) [events: $(join(ets, ", "))] [channel: $ch_id]\n  prompt: $prompt_preview")
    end
    isempty(lines) ? "No event handlers registered" : join(lines, "\n")
end

const ADD_EVENT_HANDLER_TOOL = @tool "Register a new event handler. event_type_names is comma-separated. Use list_event_types and list_channels first." function add_event_handler(id::String, event_type_names::String, prompt::String, channel_id::Union{Nothing, String} = nothing)
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    names = strip.(split(event_type_names, ","))
    for n in names
        result = iterate(SQLite.DBInterface.execute(a.db,
            "SELECT 1 FROM vo_event_types WHERE name = ?", (n,)))
        result === nothing && return "Unknown event type: $n"
    end
    if channel_id !== nothing
        haskey(a._channels, channel_id) || return "Unknown channel: $channel_id"
    end
    eh = EventHandler(id, names, prompt, channel_id)
    register_event_handler!(a, eh)
    "Event handler '$id' registered"
end

const REMOVE_EVENT_HANDLER_TOOL = @tool "Remove an event handler by its ID." function remove_event_handler(id::String)
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    unregister_event_handler!(a, id)
    "Event handler '$id' removed"
end

const MANAGEMENT_TOOLS = Agentif.AgentTool[
    LIST_CHANNELS_TOOL, LIST_EVENT_TYPES_TOOL, LIST_EVENT_HANDLERS_TOOL,
    ADD_EVENT_HANDLER_TOOL, REMOVE_EVENT_HANDLER_TOOL,
]

# ─── Tempus tools ───

const LIST_JOBS_TOOL = @tool "List all scheduled jobs with their cron schedule, status, and timezone." function list_jobs()
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    jobs = Tempus.getJobs(a.scheduler.store)
    lines = String[]
    for j in jobs
        sched = j.schedule === nothing ? "one-shot" : string(j.schedule)
        tz = j.options.timezone === nothing ? a.config.timezone : j.options.timezone
        status = Tempus.isdisabled(j) ? "disabled" : "enabled"
        push!(lines, "- $(j.name) [$sched] [$status] [tz: $tz]")
    end
    isempty(lines) ? "No scheduled jobs" : join(lines, "\n")
end

const ADD_JOB_TOOL = @tool "Schedule a recurring job with a cron expression (e.g. '0 9 * * *' for daily at 9am). The job fires the given prompt on the specified channel. Use list_channels to find channel IDs." function add_job(name::String, schedule::String, prompt::String, channel_id::String, timezone::Union{Nothing, String} = nothing)
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    haskey(a._channels, channel_id) || return "Unknown channel: $channel_id"
    et_name = "tempus_job:$name"
    SQLite.DBInterface.execute(a.db,
        "INSERT OR IGNORE INTO vo_event_types (name, description) VALUES (?, ?)",
        (et_name, "Scheduled job: $name"))
    eh = EventHandler(et_name, [et_name], prompt, channel_id)
    register_event_handler!(a, eh)
    tz = timezone !== nothing ? timezone : a.config.timezone
    job = Tempus.Job(_fire_tempus_job, name, schedule;
        job_params = Dict("event_type" => et_name),
        timezone = tz,
    )
    push!(a.scheduler, job)
    "Job '$name' scheduled: $schedule (timezone: $tz) -> channel: $channel_id"
end

const REMOVE_JOB_TOOL = @tool "Remove a scheduled job and its event handler by name." function remove_job(name::String)
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    Tempus.purgeJob!(a.scheduler.store, name)
    et_name = "tempus_job:$name"
    unregister_event_handler!(a, et_name)
    SQLite.DBInterface.execute(a.db, "DELETE FROM vo_event_types WHERE name = ?", (et_name,))
    "Job '$name' removed"
end

const TEMPUS_TOOLS = Agentif.AgentTool[LIST_JOBS_TOOL, ADD_JOB_TOOL, REMOVE_JOB_TOOL]

# ─── Agent data (scratch space) tools ───

function _parse_tags(s::Union{Nothing, String})
    s === nothing && return String[]
    return unique(sort([lowercase(strip(t)) for t in split(s, ",") if !isempty(strip(t))]))
end

function _parse_time_filter(s::Union{Nothing, String}; timezone::Union{Nothing, String}=nothing)
    s === nothing && return nothing
    s = strip(s)
    isempty(s) && return nothing
    # Relative: "7d", "24h", "30m"
    m = match(r"^(\d+)([dhm])$", s)
    if m !== nothing
        n = parse(Float64, m.captures[1])
        unit = m.captures[2]
        secs = unit == "d" ? n * 86400 : unit == "h" ? n * 3600 : n * 60
        return time() - secs
    end
    tz = _resolve_timezone(something(timezone, "UTC"))
    # Absolute: ISO 8601 with explicit timezone/offset
    try
        zdt = ZonedDateTime(s)
        return _zdt_to_unix(zdt)
    catch
    end
    # Absolute: ISO 8601 without timezone (interpret in configured timezone)
    try
        dt = DateTime(s, dateformat"yyyy-mm-ddTHH:MM:SS")
        return _zdt_to_unix(ZonedDateTime(dt, tz))
    catch
    end
    # Date only (midnight in configured timezone)
    try
        d = Date(s, dateformat"yyyy-mm-dd")
        return _zdt_to_unix(ZonedDateTime(DateTime(d), tz))
    catch
    end
    return nothing
end

function _get_search_store(a::AgentAssistant)
    return a.session_store.search_store
end

function _merge_search_results(primary::Vector, secondary::Vector; limit::Int)
    by_id = Dict{String, Any}()
    for result in primary
        by_id[result.id] = result
    end
    for result in secondary
        existing = get(() -> nothing, by_id, result.id)
        if existing === nothing || result.score > existing.score
            by_id[result.id] = result
        end
    end
    merged = Any[values(by_id)...]
    sort!(merged; by = r -> r.score, rev = true)
    return first(merged, min(limit, length(merged)))
end

function _agent_data_visibility_tags(channel_id, channel_flags)
    tags = String[]
    if channel_id === nothing || channel_flags === nothing || (channel_flags & 0x01) == 0
        push!(tags, "agent_data:public")
    end
    if channel_id !== nothing
        push!(tags, "agent_data:ch:$channel_id")
    end
    return tags
end

const DB_STORE_TOOL = @tool "Store a key-value entry in your persistent scratch space. Use tags to categorize entries for later retrieval. Value can be plain text or JSON." function db_store(key::String, value::String, tags::Union{Nothing, String} = nothing)
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    parsed_tags = _parse_tags(tags)
    user_id, post_id, ch_id, ch_flags = Agentif.current_session_entry_metadata()
    now = time()
    lock(AGENT_DATA_WRITE_LOCK) do
        _with_busy_retry() do
            # Preserve original created_at on update
            existing = iterate(SQLite.DBInterface.execute(a.db,
                "SELECT created_at FROM vo_agent_data WHERE key = ?", (key,)))
            created = existing !== nothing ? existing[1].created_at : now
            SQLite.DBInterface.execute(a.db,
                "INSERT OR REPLACE INTO vo_agent_data (key, value, created_at, updated_at, channel_id, channel_flags, user_id, post_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (key, value, created, now, ch_id, ch_flags, user_id, post_id))
            # Update tags
            SQLite.DBInterface.execute(a.db, "DELETE FROM vo_agent_data_tags WHERE key = ?", (key,))
            for tag in parsed_tags
                SQLite.DBInterface.execute(a.db,
                    "INSERT INTO vo_agent_data_tags (key, tag) VALUES (?, ?)", (key, tag))
            end
            search_store = _get_search_store(a)
            vis_tags = _agent_data_visibility_tags(ch_id, ch_flags)
            LocalSearch.load!(search_store, value; id="agent_data:$key", title=key, tags=vcat(parsed_tags, ["vo_agent_data"], vis_tags))
            return nothing
        end
    end
    tag_str = isempty(parsed_tags) ? "" : " [tags: $(join(parsed_tags, ", "))]"
    "Stored '$key'$tag_str"
end

const DB_SEARCH_TOOL = @tool "Search your stored data by text query. Optionally filter by tags (comma-separated, AND logic) and time range (after/before: relative like '7d','24h','30m' or absolute 'yyyy-mm-dd')." function db_search(query::String, tags::Union{Nothing, String} = nothing, after::Union{Nothing, String} = nothing, before::Union{Nothing, String} = nothing, limit::Union{Nothing, Int} = nothing)
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    n = limit === nothing ? 10 : limit
    search_store = _get_search_store(a)
    max_fetch = n * 3
    # Channel visibility: include current-channel (private/public) plus public entries.
    ch = Agentif.CURRENT_CHANNEL[]
    results = if ch !== nothing
        ch_id = Agentif.channel_id(ch)
        channel_results = LocalSearch.search(search_store, query; tags=["agent_data:ch:$ch_id"], limit=max_fetch)
        public_results = LocalSearch.search(search_store, query; tags=["agent_data:public"], limit=max_fetch)
        _merge_search_results(channel_results, public_results; limit=max_fetch)
    else
        LocalSearch.search(search_store, query; tags=["vo_agent_data"], limit=max_fetch)  # no channel context → all agent data
    end
    isempty(results) && return "No results found for: $query"
    # Extract keys from doc IDs
    filter_tags = _parse_tags(tags)
    after_ts = _parse_time_filter(after; timezone = a.config.timezone)
    before_ts = _parse_time_filter(before; timezone = a.config.timezone)
    lines = String[]
    for r in results
        length(lines) >= n * 2 && break  # each result is 2 lines
        # Extract key from "agent_data:{key}"
        k = replace(r.id, r"^agent_data:" => "")
        # Tag filter (AND logic)
        if !isempty(filter_tags)
            row_tags = String[]
            for trow in SQLite.DBInterface.execute(a.db,
                "SELECT tag FROM vo_agent_data_tags WHERE key = ?", (k,))
                push!(row_tags, trow.tag)
            end
            all(t -> t in row_tags, filter_tags) || continue
        end
        # Time filter
        meta = iterate(SQLite.DBInterface.execute(a.db,
            "SELECT created_at, updated_at FROM vo_agent_data WHERE key = ?", (k,)))
        if meta !== nothing
            row = meta[1]
            after_ts !== nothing && row.created_at < after_ts && continue
            before_ts !== nothing && row.created_at > before_ts && continue
        end
        score_str = round(r.score; digits=2)
        push!(lines, "--- [$k] (score: $score_str) ---")
        push!(lines, r.text)
    end
    isempty(lines) && return "No results found matching filters for: $query"
    return join(lines, "\n")
end

const DB_LIST_KEYS_TOOL = @tool "List keys stored in your scratch space. Optionally filter by tags (comma-separated, AND logic) and time range." function db_list_keys(tags::Union{Nothing, String} = nothing, after::Union{Nothing, String} = nothing, before::Union{Nothing, String} = nothing, limit::Union{Nothing, Int} = nothing)
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    n = limit === nothing ? 50 : limit
    filter_tags = _parse_tags(tags)
    after_ts = _parse_time_filter(after; timezone = a.config.timezone)
    before_ts = _parse_time_filter(before; timezone = a.config.timezone)
    # Channel visibility
    ch = Agentif.CURRENT_CHANNEL[]
    current_ch_id = ch !== nothing ? Agentif.channel_id(ch) : nothing
    # Build query
    if isempty(filter_tags)
        conditions = String[]
        params = Any[]
        if current_ch_id !== nothing
            push!(conditions, "(channel_flags IS NULL OR channel_id = ? OR (channel_flags & 1) = 0)")
            push!(params, current_ch_id)
        end
        after_ts !== nothing && (push!(conditions, "created_at >= ?"); push!(params, after_ts))
        before_ts !== nothing && (push!(conditions, "created_at <= ?"); push!(params, before_ts))
        where = isempty(conditions) ? "" : " WHERE " * join(conditions, " AND ")
        push!(params, n)
        rows = SQLite.DBInterface.execute(a.db,
            "SELECT key, created_at, updated_at FROM vo_agent_data$where ORDER BY updated_at DESC LIMIT ?", params)
    else
        conditions = ["t.tag IN ($(join(fill("?", length(filter_tags)), ",")))"]
        params = Any[filter_tags...]
        if current_ch_id !== nothing
            push!(conditions, "(d.channel_flags IS NULL OR d.channel_id = ? OR (d.channel_flags & 1) = 0)")
            push!(params, current_ch_id)
        end
        after_ts !== nothing && (push!(conditions, "d.created_at >= ?"); push!(params, after_ts))
        before_ts !== nothing && (push!(conditions, "d.created_at <= ?"); push!(params, before_ts))
        where = " WHERE " * join(conditions, " AND ")
        push!(params, length(filter_tags))
        push!(params, n)
        rows = SQLite.DBInterface.execute(a.db,
            """SELECT d.key, d.created_at, d.updated_at
               FROM vo_agent_data d
               INNER JOIN vo_agent_data_tags t ON d.key = t.key
               $where
               GROUP BY d.key HAVING COUNT(DISTINCT t.tag) >= ?
               ORDER BY d.updated_at DESC LIMIT ?""", params)
    end
    lines = String[]
    for row in rows
        created = Dates.format(unix2datetime(row.created_at), "yyyy-mm-dd HH:MM")
        updated = Dates.format(unix2datetime(row.updated_at), "yyyy-mm-dd HH:MM")
        # Fetch tags for this key
        key_tags = String[]
        for trow in SQLite.DBInterface.execute(a.db,
            "SELECT tag FROM vo_agent_data_tags WHERE key = ? ORDER BY tag", (row.key,))
            push!(key_tags, trow.tag)
        end
        tag_str = isempty(key_tags) ? "" : " [$(join(key_tags, ", "))]"
        push!(lines, "- $(row.key)$tag_str (created: $created, updated: $updated)")
    end
    isempty(lines) ? "No stored entries" : join(lines, "\n")
end

const DB_LIST_TAGS_TOOL = @tool "List all tags you have used in your scratch space." function db_list_tags()
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    tags = String[]
    for row in SQLite.DBInterface.execute(a.db,
        "SELECT DISTINCT tag FROM vo_agent_data_tags ORDER BY tag")
        push!(tags, row.tag)
    end
    isempty(tags) ? "No tags stored" : join(tags, ", ")
end

const DB_REMOVE_TOOL = @tool "Remove an entry from your scratch space by key." function db_remove(key::String)
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    removed = lock(AGENT_DATA_WRITE_LOCK) do
        _with_busy_retry() do
            existing = iterate(SQLite.DBInterface.execute(a.db,
                "SELECT 1 FROM vo_agent_data WHERE key = ?", (key,)))
            existing === nothing && return false
            SQLite.DBInterface.execute(a.db, "DELETE FROM vo_agent_data WHERE key = ?", (key,))
            search_store = _get_search_store(a)
            LocalSearch.delete!(search_store, "agent_data:$key")
            return true
        end
    end
    !removed && return "Key '$key' not found"
    "Removed '$key'"
end

const DB_TOOLS = Agentif.AgentTool[DB_STORE_TOOL, DB_SEARCH_TOOL, DB_LIST_KEYS_TOOL, DB_LIST_TAGS_TOOL, DB_REMOVE_TOOL]

# ─── LLMTools builder ───

function _build_llmtools(config::AgentConfig)
    tools = Agentif.AgentTool[]
    if config.enable_coding
        append!(tools, LLMTools.coding_tools(config.base_dir))
    elseif config.enable_terminal
        append!(tools, LLMTools.create_terminal_tools(config.base_dir))
    end
    config.enable_workers && append!(tools, LLMTools.create_worker_tools())
    config.enable_web && append!(tools, LLMTools.web_tools())
    return tools
end

# ─── Evaluate ───

function evaluate(assistant::AgentAssistant, input; session_id::String, channel::Union{Nothing, Agentif.AbstractChannel}=nothing, kw...)
    cfg = assistant.config
    model = Agentif.getModel(cfg.provider, cfg.model_id)
    model === nothing && error("Unknown model: provider=$(cfg.provider) model_id=$(cfg.model_id)")
    agent = Agentif.Agent(
        prompt = build_system_prompt(cfg; channel),
        model = model,
        apikey = cfg.apikey,
        tools = assistant.tools,
    )
    # Prepend date/time context to user input (not system prompt) to preserve
    # LLM provider prefix-based prompt caching across turns.
    ctx = build_context_prefix(cfg)
    prefixed_input = input isa String ? string(ctx, "\n\n", input) : input
    return Agentif.evaluate(agent, prefixed_input;
        session_store = assistant.session_store,
        session_id = session_id,
        channel = channel,
        kw...,
    )
end

# ─── Post scrubbing ───

function scrub_post!(assistant::AgentAssistant, post_id::String)
    # 1. Mark session entries as deleted (preserves AgentState for prompt caching)
    Agentif.scrub_post!(assistant.session_store, post_id)
    # 2. Hard-delete agent data matching this post_id
    lock(AGENT_DATA_WRITE_LOCK) do
        _with_busy_retry() do
            db = assistant.db
            rows = SQLite.DBInterface.execute(db,
                "SELECT key FROM vo_agent_data WHERE post_id = ?", (post_id,))
            keys = String[String(r.key) for r in rows]
            if !isempty(keys)
                search_store = _get_search_store(assistant)
                for key in keys
                    try
                        Base.delete!(search_store, "agent_data:$key")
                    catch
                    end
                end
                SQLite.execute(db, "DELETE FROM vo_agent_data WHERE post_id = ?", (post_id,))
                @info "scrub_post!: deleted agent data" post_id count=length(keys)
            end
            return nothing
        end
    end
    return nothing
end

# ─── Event loop ───

function _is_sqlite_busy_error(e)
    msg = lowercase(sprint(showerror, e))
    return occursin("busy", msg) || occursin("locked", msg)
end

function _with_busy_retry(f::Function; retries::Int = 3, base_delay_s::Float64 = 0.05)
    attempt = 1
    while true
        try
            return f()
        catch e
            if !_is_sqlite_busy_error(e) || attempt >= retries
                rethrow()
            end
            sleep(base_delay_s * attempt)
            attempt += 1
        end
    end
end

function _event_handlers_for(assistant::AgentAssistant, event_name::String)
    return _with_busy_retry() do
        handlers = NamedTuple[]
        for row in SQLite.DBInterface.execute(assistant.db, """
            SELECT eh.id, eh.prompt, eh.channel_id
            FROM vo_event_handlers eh
            JOIN vo_handler_event_types het ON eh.id = het.handler_id
            WHERE het.event_type_name = ?
        """, (event_name,))
            handler_id = row.id === missing ? "" : String(row.id)
            isempty(handler_id) && continue
            prompt = row.prompt === missing ? "" : String(row.prompt)
            channel_id = row.channel_id === missing ? nothing : String(row.channel_id)
            push!(handlers, (; id=handler_id, prompt, channel_id))
        end
        return handlers
    end
end

function _resolve_event_channel(assistant::AgentAssistant, ev::Event, handler_channel_id::Union{Nothing, String})
    if ev isa ChannelEvent
        return get_channel(ev)
    end
    handler_channel_id === nothing && return nothing
    return get(assistant._channels, handler_channel_id, nothing)
end

function _run_event_handler!(assistant::AgentAssistant, ev::Event, handler)
    ch = _resolve_event_channel(assistant, ev, handler.channel_id)
    if ch === nothing
        @warn "No channel available for handler" handler_id=handler.id channel_id=handler.channel_id
        return nothing
    end
    input = make_prompt(handler.prompt, ev)
    session_key = something(get_session_key(ev), handler.id)
    sid = _with_busy_retry() do
        _get_or_create_session(assistant.db, session_key)
    end
    evaluate(assistant, input; session_id=sid, channel=ch)
    return nothing
end

function start_event_loop!(assistant::AgentAssistant)
    errormonitor(@async begin
        for ev in assistant.event_queue
            nm = try
                get_name(ev)
            catch e
                @error "Event dropped: failed to compute event name" event_type=typeof(ev) exception=(e, catch_backtrace())
                continue
            end
            handlers = try
                _event_handlers_for(assistant, nm)
            catch e
                @error "Event handler lookup failed" event=nm exception=(e, catch_backtrace())
                continue
            end
            for handler in handlers
                errormonitor(@async begin
                    try
                        _run_event_handler!(assistant, ev, handler)
                    catch e
                        @error "Event handler failed" handler=handler.id event=nm exception=(e, catch_backtrace())
                    end
                end)
            end
        end
    end)
end

# ─── Constructor ───

function AgentAssistant(db_path::String="";
    name::String="Vo",
    provider::String=get(ENV, "VO_AGENT_PROVIDER", ""),
    model_id::String=get(ENV, "VO_AGENT_MODEL", ""),
    apikey::String=get(ENV, "VO_AGENT_API_KEY", ""),
    timezone::String=_detect_timezone(),
    base_dir::String=pwd(),
    enable_terminal::Bool=false,
    enable_workers::Bool=false,
    enable_web::Bool=false,
    enable_coding::Bool=false,
)
    db_path = isempty(db_path) ? joinpath(pwd(), "$name.sqlite") : db_path
    db = SQLite.DB(db_path)
    _init_vo_schema!(db)
    search_store = LocalSearch.Store(db)
    session_store = Agentif.SQLiteSessionStore(db, search_store)
    tempus_store = Tempus.SQLiteStore(db)
    scheduler = Tempus.Scheduler(tempus_store)
    config = AgentConfig(; name, provider, model_id, apikey, timezone, base_dir, enable_terminal, enable_workers, enable_web, enable_coding)
    tools = _build_llmtools(config)
    return AgentAssistant(
        config, db,
        Dict{String, Agentif.AbstractChannel}(),
        Base.Channel{Event}(Inf),
        session_store, tools, scheduler,
    )
end

# ─── Lifecycle ───

function init!(db_path::String=""; event_sources=nothing, kwargs...)
    sources = event_sources === nothing ? lock(() -> collect(EVENT_SOURCES), EVENT_SOURCES_LOCK) : event_sources
    assistant = AgentAssistant(db_path; kwargs...)
    CURRENT_ASSISTANT[] = assistant
    # Purge ephemeral tables (re-populated from EventSources)
    SQLite.DBInterface.execute(assistant.db, "DELETE FROM vo_event_types")
    for es in sources
        register_event_source!(assistant, es)
    end
    append!(assistant.tools, MANAGEMENT_TOOLS)
    append!(assistant.tools, TEMPUS_TOOLS)
    append!(assistant.tools, DB_TOOLS)
    Tempus.run!(assistant.scheduler)
    start_event_loop!(assistant)
    for es in sources
        start!(es, assistant)
    end
    return assistant
end

# ─── REPL Event Source ───

struct ReplChannel <: Agentif.AbstractChannel
    io::IO
    completion::Threads.Event
end
ReplChannel() = ReplChannel(stdout, Threads.Event())

Agentif.channel_id(::ReplChannel) = "repl"
function Agentif.start_streaming(ch::ReplChannel)
    reset(ch.completion)
end
Agentif.append_to_stream(ch::ReplChannel, delta::AbstractString) = print(ch.io, delta)
function Agentif.finish_streaming(ch::ReplChannel)
    println(ch.io)
    notify(ch.completion)
end
Agentif.send_message(ch::ReplChannel, msg) = println(ch.io, msg)
Agentif.close_channel(::ReplChannel) = nothing

struct ReplEventSource <: EventSource end

struct ReplInputEvent <: ChannelEvent
    input::String
    channel::ReplChannel
end

get_name(::ReplInputEvent) = "repl_input"
get_channel(ev::ReplInputEvent) = ev.channel
event_content(ev::ReplInputEvent) = ev.input

const REPL_INPUT_EVENT_TYPE = EventType("repl_input", "User input submitted at the Julia REPL")

get_channels(::ReplEventSource) = Agentif.AbstractChannel[ReplChannel()]
get_event_types(::ReplEventSource) = EventType[REPL_INPUT_EVENT_TYPE]
get_event_handlers(::ReplEventSource) = EventHandler[
    EventHandler("repl_default", ["repl_input"], "", nothing)
]

# ─── REPL macro ───

macro a_str(input)
    quote
        a = Vo.get_current_assistant()
        a === nothing && error("No assistant initialized. Call Vo.init!() first.")
        ch = ReplChannel()
        put!(a.event_queue, ReplInputEvent($(esc(input)), ch))
        wait(ch.completion)
        nothing
    end
end

function __init__()
    isinteractive() && register_event_source!(ReplEventSource())
    return
end

end
