module Claw

using Agentif
using Dates
using HTTP
using JSON
using LLMTools
using LocalSearch
using Logging
using ScopedValues: @with
using SQLite
using Tempus
using TimeZones
# Imported, not `using`d: these only ever appear qualified (`Sockets.IPv4`,
# `Base64.base64decode`, `SHA.sha256`), and `using Sockets` alongside `using HTTP`
# would make bare `listen`/`bind` ambiguous for anything added here later.
import Base64
import SHA
import Sockets

export EventSource, Event, ChannelEvent, EventType, EventHandler
export AgentConfig, AgentAssistant, PipelineConfig
export get_channels, get_event_types, get_event_handlers, get_tools
export get_name, get_channel, event_content
export register_event_source!, register_channels!, register_event_handler!, unregister_event_handler!
export evaluate, init!, run, start!, get_current_assistant, scrub_post!
export submit_event!, shutdown!, wait_for_shutdown
export is_owner_context, resolve_handler_tools, trust_exposure_report, third_party_content
export ReplChannel, ReplEventSource, ReplInputEvent
export @a_str

# ─── Abstract types ───

abstract type EventSource end
abstract type Event end
abstract type ChannelEvent <: Event end

# ─── Soul template ───

const SOUL_TEMPLATE = read(joinpath(@__DIR__, "soul_template.md"), String)
const AGENT_SYSTEM_PROMPT_KEY = "agent_system_prompt"

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

"""
    _exec!(db, sql, params = ())

Run a write and *reset the statement*. `SQLite.DBInterface.execute` returns a lazy
cursor; for a write, the statement stays in progress — holding its lock and leaving
the change uncommitted — until something else runs on that connection or the cursor
is finalized by GC. That is invisible while everything shares one handle, and turns
into lost/stale writes the moment a second connection exists (§1.7).
"""
_exec!(db::SQLite.DB, sql::AbstractString, params = ()) = (SQLite.execute(db, sql, params); nothing)

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

"""
    _fetch_one(db, sql, params) -> row or nothing

Fetch the first row of a query and **close the cursor**.

`SQLite.DBInterface.execute` returns a lazy cursor; taking only its first row with
`iterate` leaves the statement mid-step, which under WAL pins that connection to the
read snapshot it started with. The connection then stops seeing other connections'
commits — verified directly: a partially-consumed SELECT made a second connection's
committed INSERT permanently invisible to the first. (The same lazy-cursor mechanic in
a row-returning `PRAGMA` is what left `journal_mode=WAL` holding its lock and made
every second connection fail with "database is locked".)
"""
function _fetch_one(db::SQLite.DB, sql::String, params = ())
    cursor = SQLite.DBInterface.execute(db, sql, params)
    state = iterate(cursor)
    # A row is a lazy view over the live statement, so its columns must be copied
    # out before the cursor closes — reading them afterwards yields `missing`.
    result = if state === nothing
        nothing
    else
        row = state[1]
        names = Tuple(propertynames(row))
        NamedTuple{names}(map(n -> getproperty(row, n), names))
    end
    SQLite.DBInterface.close!(cursor)
    return result
end

function _get_agent_metadata(db::SQLite.DB, key::String)
    row = _fetch_one(db, "SELECT value FROM claw_agent_metadata WHERE key = ?", (key,))
    row === nothing && return nothing
    return String(row.value)
end

function _set_agent_metadata!(db::SQLite.DB, key::String, value::String)
    _exec!(db, "INSERT OR REPLACE INTO claw_agent_metadata (key, value, updated_at) VALUES (?, ?, ?)",
        (key, value, time()))
    return
end

function _ensure_agent_metadata_defaults!(db::SQLite.DB)
    _exec!(db, "INSERT OR IGNORE INTO claw_agent_metadata (key, value, updated_at) VALUES (?, ?, ?)",
        (AGENT_SYSTEM_PROMPT_KEY, SOUL_TEMPLATE, time()))
    return
end

function _agent_system_prompt(db::SQLite.DB)
    prompt = _get_agent_metadata(db, AGENT_SYSTEM_PROMPT_KEY)
    prompt === nothing && return SOUL_TEMPLATE
    return prompt
end

# ─── Core types ───

struct EventType
    name::String
    description::String
end

"""
    EventHandler(id, event_types, prompt, channel_id = nothing; tools = nothing, trust = :owner)

A standing automation: when one of `event_types` fires, `prompt` is prepended to the
event content and evaluated, with the response sent to `channel_id`.

`trust` selects the tool policy for that evaluation (§2.2):

- `:owner` (**default**) — the full tool set, including `set_system_prompt`,
  `add_event_handler`/`add_job`, the send-email tools and the shell/coding tools.
- `:untrusted` — read/search/db tools only. Use this for anything fed by content
  someone else wrote (inbound email, webhooks, group chat).

The default is deliberately the permissive one so existing automations keep working
unchanged; restriction is a one-field opt-in. Because that default persists, `init!`
logs a single startup warning naming every owner-tier handler that is fed by
third-party content — see [`trust_exposure_report`](@ref).

`tools` optionally narrows the handler to a named subset (`nothing` = the default
set). Trust filtering applies on top: naming a denied tool does not grant it to an
`:untrusted` handler.
"""
struct EventHandler
    id::String
    event_types::Vector{String}  # event type names
    prompt::String
    channel_id::Union{Nothing, String}
    tools::Union{Nothing, Vector{String}}
    trust::Symbol
end

function EventHandler(id::AbstractString, event_types, prompt::AbstractString,
        channel_id::Union{Nothing, AbstractString} = nothing;
        tools::Union{Nothing, AbstractVector} = nothing,
        trust::Symbol = :owner,
    )
    trust in TRUST_TIERS || throw(ArgumentError(
        "EventHandler trust must be one of $(collect(TRUST_TIERS)), got :$trust"))
    return EventHandler(
        String(id),
        String[String(et) for et in event_types],
        String(prompt),
        channel_id === nothing ? nothing : String(channel_id),
        tools === nothing ? nothing : String[String(t) for t in tools],
        trust,
    )
end

Base.@kwdef struct AgentConfig
    name::Union{Nothing, String} = nothing
    provider::String
    model_id::String
    apikey::String
    timezone::String = _detect_timezone()
    base_dir::String = pwd()
    enable_web::Bool = false
    enable_coding::Bool = false
    # Owner identity (§2.2). Empty by default; the REPL is always owner regardless.
    owner_channels::Vector{String} = String[]
    owner_user_ids::Vector{String} = String[]
end

# SQLite ownership discipline + pipeline runtime structures (§1.7).
include("dbwriter.jl")

Base.@kwdef struct AgentAssistant
    config::AgentConfig
    db::SQLite.DB
    db_path::String = ""
    _channels::Dict{String, Agentif.AbstractChannel} = Dict{String, Agentif.AbstractChannel}()  # runtime-only registry
    # The in-memory queue carries persisted event rowids as wakeups only (§1.1);
    # the events themselves live in `claw_events`.
    event_queue::Base.Channel{Int} = Base.Channel{Int}(Inf)
    session_store::Agentif.SessionStore
    tools::Vector{Agentif.AgentTool} = Agentif.AgentTool[]
    scheduler::Tempus.Scheduler
    log_level::Union{Nothing, LogLevel} = nothing
    pipeline::PipelineConfig = PipelineConfig()
    _writer::SQLiteWriter
    _readers::ReaderPool
    # Live event objects for the hot path: a freshly-arrived event still holds its
    # streaming channel, which cannot survive serialization. Replay falls back to
    # `rehydrate_event`.
    _live_events::Dict{Int, Event} = Dict{Int, Event}()
    _live_lock::ReentrantLock = ReentrantLock()
    _lanes::Dict{String, Lane} = Dict{String, Lane}()
    _lanes_lock::ReentrantLock = ReentrantLock()
    _inflight::Dict{Int, Agentif.Abort} = Dict{Int, Agentif.Abort}()
    _inflight_lock::ReentrantLock = ReentrantLock()
    _pending_wakeups::Set{Int} = Set{Int}()
    _wakeup_lock::ReentrantLock = ReentrantLock()
    _sem::Base.Semaphore = Base.Semaphore(4)
    _sources::Vector{SupervisedSource} = SupervisedSource[]
    _tasks::Vector{Task} = Task[]
    _state::Base.RefValue{Symbol} = Ref(:new)   # :new | :running | :stopping | :stopped
    _shutdown_lock::ReentrantLock = ReentrantLock()
    _shutdown_complete::Threads.Event = Threads.Event()
    _scheduler_started::Base.RefValue{Bool} = Ref(false)
    _signal_handler_installed::Base.RefValue{Bool} = Ref(false)
end

# ─── SQLite schema ───

function _init_claw_schema!(db::SQLite.DB)
    # Pragmas go through `SQLite.execute` (step + reset). `DBInterface.execute`
    # hands back a lazy cursor, and an unconsumed `PRAGMA journal_mode=WAL` cursor
    # keeps holding its exclusive lock, which blocks every other connection to the
    # file — including the dedicated writer connection (§1.7).
    SQLite.execute(db, "PRAGMA busy_timeout=5000")
    SQLite.execute(db, "PRAGMA journal_mode=WAL")
    SQLite.execute(db, "PRAGMA synchronous=NORMAL")

    # Drop legacy table before enabling foreign keys to avoid lock errors
    SQLite.execute(db, "DROP TABLE IF EXISTS claw_channels")

    SQLite.execute(db, "PRAGMA foreign_keys=ON")

    SQLite.DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS claw_event_types (
            name TEXT PRIMARY KEY,
            description TEXT NOT NULL DEFAULT ''
        )
    """)

    SQLite.DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS claw_event_handlers (
            id TEXT PRIMARY KEY,
            prompt TEXT NOT NULL DEFAULT '',
            channel_id TEXT
        )
    """)

    SQLite.DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS claw_handler_event_types (
            handler_id TEXT NOT NULL,
            event_type_name TEXT NOT NULL,
            PRIMARY KEY (handler_id, event_type_name)
        )
    """)

    SQLite.DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS claw_agent_data (
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
        CREATE TABLE IF NOT EXISTS claw_agent_data_tags (
            key TEXT NOT NULL REFERENCES claw_agent_data(key) ON DELETE CASCADE,
            tag TEXT NOT NULL,
            PRIMARY KEY (key, tag)
        )
    """)
    SQLite.DBInterface.execute(db, "CREATE INDEX IF NOT EXISTS idx_claw_agent_data_tags_tag ON claw_agent_data_tags(tag)")

    SQLite.DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS claw_agent_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at REAL NOT NULL
        )
    """)
    _ensure_agent_metadata_defaults!(db)

    # Everything above is the version-1 baseline (it predates any migration
    # mechanism, so it stays idempotent CREATE IF NOT EXISTS); everything after is
    # applied through the PRAGMA user_version ladder.
    _migrate_claw_schema!(db)
    return nothing
end

# ─── EventSource interface ───

get_channels(::EventSource) = Agentif.AbstractChannel[]
get_event_types(::EventSource) = EventType[]
get_event_handlers(::EventSource) = EventHandler[]
get_tools(::EventSource) = Agentif.AgentTool[]
start!(::EventSource, ::AgentAssistant) = nothing

function run(; db_path::String="", event_sources=nothing, kwargs...)
    return init!(db_path; event_sources, kwargs...)
end

# ─── Event interface ───

get_name(ev::Event) = error("get_name not implemented for $(typeof(ev))")
get_channel(ev::ChannelEvent) = error("get_channel not implemented for $(typeof(ev))")
event_content(ev::Event) = error("event_content not implemented for $(typeof(ev))")

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
        _exec!(db, "INSERT OR IGNORE INTO claw_event_types (name, description) VALUES (?, ?)",
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

_encode_handler_tools(tools::Nothing) = nothing
_encode_handler_tools(tools::Vector{String}) = JSON.json(tools)

function _decode_handler_tools(raw)
    (raw === nothing || raw === missing) && return nothing
    s = String(raw)
    isempty(strip(s)) && return nothing
    parsed = try
        JSON.parse(s)
    catch
        return nothing
    end
    parsed isa AbstractVector || return nothing
    return String[String(x) for x in parsed]
end

function _decode_handler_trust(raw)
    (raw === nothing || raw === missing) && return :owner
    s = strip(lowercase(String(raw)))
    isempty(s) && return :owner
    sym = Symbol(s)
    # An unrecognized tier is treated as the restrictive one: a corrupted or
    # hand-edited value must not silently upgrade a handler to full trust.
    return sym === :owner ? :owner : :untrusted
end

function _upsert_event_handler!(db::SQLite.DB, eh::EventHandler)
    _exec!(db, "INSERT OR REPLACE INTO claw_event_handlers (id, prompt, channel_id, trust, tools) VALUES (?, ?, ?, ?, ?)",
        (eh.id, eh.prompt, eh.channel_id, String(eh.trust), _encode_handler_tools(eh.tools)))
    # Insert new subscriptions before deleting stale ones so a partial upsert can
    # never leave the handler with zero event types (a dead automation);
    # worst case is a transient union of old+new until the next upsert.
    for et_name in eh.event_types
        _exec!(db, "INSERT OR IGNORE INTO claw_handler_event_types (handler_id, event_type_name) VALUES (?, ?)",
            (eh.id, et_name))
    end
    if isempty(eh.event_types)
        _exec!(db, "DELETE FROM claw_handler_event_types WHERE handler_id = ?", (eh.id,))
    else
        placeholders = join(fill("?", length(eh.event_types)), ",")
        _exec!(db, "DELETE FROM claw_handler_event_types WHERE handler_id = ? AND event_type_name NOT IN ($placeholders)",
            (eh.id, eh.event_types...))
    end
end

function register_event_handler!(assistant::AgentAssistant, eh::EventHandler)
    _upsert_event_handler!(assistant.db, eh)
    return
end

function unregister_event_handler!(assistant::AgentAssistant, handler_id::String)
    db = assistant.db
    _exec!(db, "DELETE FROM claw_handler_event_types WHERE handler_id = ?", (handler_id,))
    _exec!(db, "DELETE FROM claw_event_handlers WHERE id = ?", (handler_id,))
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

function build_system_prompt(config::AgentConfig; channel::Union{Nothing, Agentif.AbstractChannel}=nothing, base_prompt::Union{Nothing, String}=nothing)
    prompt = base_prompt === nothing ? SOUL_TEMPLATE : base_prompt
    if config.name !== nothing
        prompt = string(prompt, "\n\n## Your name\nYour user has given you the name: **$(config.name)**\n")
    end
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

function build_system_prompt(assistant::AgentAssistant; channel::Union{Nothing, Agentif.AbstractChannel}=nothing)
    prompt = _with_busy_retry() do
        _agent_system_prompt(assistant.db)
    end
    return build_system_prompt(assistant.config; channel=channel, base_prompt=prompt)
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
    submit_event!(assistant, TempusJobEvent(event_type); source = "tempus")
    return
end

# ─── Management tools ───

const LIST_CHANNELS_TOOL = @tool """List all registered messaging channels with their IDs, type (group/direct), and visibility (public/private).

Channels represent messaging destinations — Mattermost channels, Telegram chats, the REPL, etc. Each channel has a unique ID string.

When to use: Before calling add_job or add_event_handler, since both require a channel_id. Also useful for discovering what integrations are active.

Arguments: none.

Returns one line per channel: "- name (id) — group/direct, public/private".

Example output:
  - general (mm-abc123) — group, public
  - repl — direct, private""" function list_channels()
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

const LIST_EVENT_TYPES_TOOL = @tool """List all registered event types with their names and descriptions.

Event types define the kinds of events the system can produce (e.g., "repl_input", "jmap_new_email", "tempus_job:daily-report"). Each event type can have event handlers attached to it via add_event_handler.

When to use: Before calling add_event_handler, to see what event types are available to listen for.

Arguments: none.

Returns one line per event type: "- name: description".""" function list_event_types()
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    lines = String[]
    for row in SQLite.DBInterface.execute(a.db, "SELECT name, description FROM claw_event_types")
        push!(lines, "- $(row.name): $(row.description)")
    end
    isempty(lines) ? "No event types registered" : join(lines, "\n")
end

const LIST_EVENT_HANDLERS_TOOL = @tool """List all registered event handlers showing their IDs, subscribed event types, target channel, and prompt text.

Event handlers define how the agent responds to events. When an event fires, matching handlers trigger an agent evaluation with the handler's prompt prepended to the event content, and the response is sent to the handler's target channel.

When to use: To audit what automations are active, debug why events aren't being handled, or find handler IDs before calling remove_event_handler.

Arguments: none.

Each entry shows the handler's trust tier: `owner` handlers get the full tool set, `untrusted` handlers cannot use self-modification, standing-automation, send-email or shell tools.

Returns one entry per handler with: ID, subscribed event types, channel, trust tier, and a preview of the prompt text.""" function list_event_handlers()
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    lines = String[]
    for h in _all_event_handlers(a)
        ch_id = h.channel_id === nothing ? "none" : h.channel_id
        prompt_preview = length(h.prompt) > 80 ? string(first(h.prompt, 80), "...") : h.prompt
        tool_note = h.tools === nothing ? "" : " [tools: $(join(h.tools, ", "))]"
        push!(lines, "- $(h.id) [events: $(join(h.event_types, ", "))] [channel: $ch_id] [trust: $(h.trust)]$tool_note\n  prompt: $prompt_preview")
    end
    isempty(lines) ? "No event handlers registered" : join(lines, "\n")
end

const GET_SYSTEM_PROMPT_TOOL = @tool """Retrieve the current agent system prompt text (your own instructions).

When to use: To review your current instructions before modifying them with set_system_prompt, or to audit what behavioral guidelines are active.

Arguments: none.

Returns the full system prompt string.""" function get_system_prompt()
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    return _with_busy_retry() do
        _agent_system_prompt(a.db)
    end
end

const SET_SYSTEM_PROMPT_TOOL = @tool """Update the agent system prompt — your own instructions for ALL future evaluations.

WARNING: This change persists across restarts (stored in SQLite) and affects every future conversation. Use get_system_prompt first to review the current prompt before overwriting.

Arguments:
- prompt (String, required): The new system prompt text. Cannot be empty or whitespace-only.

Gotchas:
- Replaces the ENTIRE system prompt, not a partial update. Include everything you want to keep.
- Takes effect on the NEXT evaluation, not the current one.
- Use with care — a bad system prompt can break the agent's behavior.""" function set_system_prompt(prompt::String)
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    isempty(strip(prompt)) && return "System prompt cannot be empty"
    lock(AGENT_DATA_WRITE_LOCK) do
        _with_busy_retry() do
            _set_agent_metadata!(a.db, AGENT_SYSTEM_PROMPT_KEY, prompt)
            return nothing
        end
    end
    return "System prompt updated ($(length(prompt)) chars)"
end

const ADD_EVENT_HANDLER_TOOL = @tool """Register a new event handler that triggers an agent evaluation when specified events fire.

When an event matches, the handler's prompt is prepended to the event content, and the combined text is evaluated as agent input. If a channel_id is provided, the response is sent there. If omitted, evaluation still runs (results stored in session history) but no response is sent externally.

Arguments:
- id (String, required): Unique identifier for this handler. Use a descriptive name like "email-summary" or "daily-standup".
- event_type_names (String, required): Comma-separated event type names to listen for. Use list_event_types to see available types. Example: "jmap_new_email" or "repl_input,tempus_job:reminder".
- prompt (String, required): Text prepended to the event content before evaluation. This is your instruction for how to handle the event. Example: "Summarize this email and flag if urgent."
- channel_id (String or nothing, optional): Where to send the response. Use list_channels to find valid IDs. If omitted, the handler evaluates without sending a response — useful for background processing like building event logs.

Examples:
  add_event_handler("email-triage", "jmap_new_email", "Triage this email: if spam or marketing, archive it. If important, summarize it.", "mm-general")
  add_event_handler("github-log", "github_push", "Summarize this push event and store a log entry.")

Gotchas:
- Fails if event_type_names contains unknown event types (use list_event_types first).
- Fails if channel_id is provided but is not a registered channel (use list_channels first).
- If an id already exists, it will be replaced (upsert behavior).""" function add_event_handler(id::String, event_type_names::String, prompt::String, channel_id::Union{Nothing, String} = nothing)
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    cid = channel_id === nothing ? nothing : strip(channel_id)
    if cid !== nothing && isempty(cid)
        cid = nothing
    end
    names = strip.(split(event_type_names, ","))
    for n in names
        result = _fetch_one(a.db, "SELECT 1 FROM claw_event_types WHERE name = ?", (n,))
        result === nothing && return "Unknown event type: $n"
    end
    if cid !== nothing
        haskey(a._channels, cid) || return "Unknown channel: $cid. Use list_channels to see available channels."
    end
    eh = EventHandler(id, names, prompt, cid)
    register_event_handler!(a, eh)
    cid === nothing ? "Event handler '$id' registered (no channel — evaluate only)" : "Event handler '$id' registered for channel '$cid'"
end

const REMOVE_EVENT_HANDLER_TOOL = @tool """Remove an event handler by its ID, stopping it from triggering on future events.

Arguments:
- id (String, required): The handler ID to remove. Use list_event_handlers to find IDs.

Silently succeeds even if the ID doesn't exist.""" function remove_event_handler(id::String)
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    unregister_event_handler!(a, id)
    "Event handler '$id' removed"
end

const MANAGEMENT_TOOLS = Agentif.AgentTool[
    LIST_CHANNELS_TOOL, LIST_EVENT_TYPES_TOOL, LIST_EVENT_HANDLERS_TOOL,
    GET_SYSTEM_PROMPT_TOOL, SET_SYSTEM_PROMPT_TOOL,
    ADD_EVENT_HANDLER_TOOL, REMOVE_EVENT_HANDLER_TOOL,
]

# ─── Tempus tools ───

const LIST_JOBS_TOOL = @tool """List all scheduled recurring jobs with their cron expression, enabled/disabled status, and timezone.

When to use: To see what recurring automations are active, verify a job was created correctly, or find job names before calling remove_job.

Arguments: none.

Returns one line per job: "- name [cron_schedule] [enabled/disabled] [tz: timezone]".""" function list_jobs()
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

const ADD_JOB_TOOL = @tool """Schedule a recurring job that evaluates a prompt on a channel at a cron schedule.

When the cron fires, the prompt text is sent as agent input on the specified channel — the agent evaluates it like any other message.

Arguments:
- name (String, required): Unique job name. Used as identifier for remove_job.
- schedule (String, required): Cron expression with 5 fields: minute hour day-of-month month day-of-week.
  Examples: "0 9 * * *" (daily 9am), "0 9 * * 1" (Mondays 9am), "*/30 * * * *" (every 30min), "0 0 1 * *" (1st of month midnight).
- prompt (String, required): The text evaluated as agent input when the job fires. Example: "Give me a summary of unread emails from today."
- channel_id (String, required): Target channel for the response. Use list_channels to find valid IDs.
- timezone (String, optional): IANA timezone for the schedule (e.g., "America/New_York"). Defaults to the agent's configured timezone.

Gotchas:
- Fails if channel_id is not a registered channel.
- Job names must be unique — reusing a name overwrites the previous job.
- Jobs persist across restarts (stored in SQLite).""" function add_job(name::String, schedule::String, prompt::String, channel_id::String, timezone::Union{Nothing, String} = nothing)
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    haskey(a._channels, channel_id) || return "Unknown channel: $channel_id"
    et_name = "tempus_job:$name"
    SQLite.DBInterface.execute(a.db,
        "INSERT OR IGNORE INTO claw_event_types (name, description) VALUES (?, ?)",
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

const REMOVE_JOB_TOOL = @tool """Remove a scheduled job by name, stopping all future executions.

Also cleans up the associated event type and event handler.

Arguments:
- name (String, required): The job name as specified when created with add_job. Use list_jobs to find names.

Silently succeeds even if the job doesn't exist.""" function remove_job(name::String)
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    Tempus.purgeJob!(a.scheduler.store, name)
    et_name = "tempus_job:$name"
    unregister_event_handler!(a, et_name)
    SQLite.DBInterface.execute(a.db, "DELETE FROM claw_event_types WHERE name = ?", (et_name,))
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

const DB_STORE_TOOL = @tool """Store a key-value entry in your persistent scratch space (survives restarts).

Use this to remember facts, save intermediate results, or build up structured knowledge over time. Entries are searchable via db_search (semantic/keyword hybrid search).

Arguments:
- key (String, required): Unique identifier for the entry. If the key already exists, the value and tags are REPLACED (upsert). The original created_at timestamp is preserved on update.
- value (String, required): The content to store. Can be plain text, JSON, or any string data.
- tags (String, optional): Comma-separated tags for categorization and filtering. Tags are lowercased and deduplicated. Example: "meeting-notes,project-x,2024".

Examples:
- db_store("user-prefs", "Prefers concise responses, uses dark mode", "preferences")
- db_store("api-key-location", "Stored in ~/.config/app/secrets.json", "config,secrets")

Gotchas:
- Keys are unique — storing with an existing key overwrites the value and tags.
- Entries are scoped by channel visibility: data stored from a private channel is only searchable from that channel.
- Value is indexed for semantic search, so descriptive text is more findable than raw IDs.""" function db_store(key::String, value::String, tags::Union{Nothing, String} = nothing)
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    parsed_tags = _parse_tags(tags)
    user_id, ch_id, _sch_id, ch_flags = Agentif.current_session_entry_metadata()
    ch = Agentif.CURRENT_CHANNEL[]
    post_id = ch !== nothing ? Agentif.entry_id(ch) : nothing
    now = time()
    lock(AGENT_DATA_WRITE_LOCK) do
        _with_busy_retry() do
            # Preserve original created_at on update
            existing = _fetch_one(a.db, "SELECT created_at FROM claw_agent_data WHERE key = ?", (key,))
            created = existing !== nothing ? existing.created_at : now
            SQLite.DBInterface.execute(a.db,
                "INSERT OR REPLACE INTO claw_agent_data (key, value, created_at, updated_at, channel_id, channel_flags, user_id, post_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (key, value, created, now, ch_id, ch_flags, user_id, post_id))
            # Update tags
            SQLite.DBInterface.execute(a.db, "DELETE FROM claw_agent_data_tags WHERE key = ?", (key,))
            for tag in parsed_tags
                SQLite.DBInterface.execute(a.db,
                    "INSERT INTO claw_agent_data_tags (key, tag) VALUES (?, ?)", (key, tag))
            end
            search_store = _get_search_store(a)
            vis_tags = _agent_data_visibility_tags(ch_id, ch_flags)
            LocalSearch.load!(search_store, value; id="agent_data:$key", title=key, tags=vcat(parsed_tags, ["claw_agent_data"], vis_tags))
            return nothing
        end
    end
    tag_str = isempty(parsed_tags) ? "" : " [tags: $(join(parsed_tags, ", "))]"
    "Stored '$key'$tag_str"
end

const DB_SEARCH_TOOL = @tool """Search your stored scratch space entries by semantic/keyword query.

Uses hybrid search (BM25 keyword + vector similarity), so natural language queries work well. Use db_list_keys for browsing by tags/time without a search query.

Arguments:
- query (String, required): Search text. Natural language works best (e.g., "user preferences for notifications") but keywords also work.
- tags (String, optional): Comma-separated tags to filter by (AND logic — all tags must match). Example: "project-x,meeting-notes".
- after (String, optional): Only return entries created after this time. Relative: "7d", "24h", "30m". Absolute: "2024-01-15" or "2024-01-15T09:00:00".
- before (String, optional): Only return entries created before this time. Same format as after.
- limit (Int, optional): Max results to return. Default: 10.

Returns matching entries with keys and relevance scores, sorted by relevance.

Gotchas:
- Results are channel-scoped: entries from private channels are only visible in that channel. Public entries are always visible.
- Time filters apply to the entry's created_at timestamp, not updated_at.""" function db_search(query::String, tags::Union{Nothing, String} = nothing, after::Union{Nothing, String} = nothing, before::Union{Nothing, String} = nothing, limit::Union{Nothing, Int} = nothing)
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
        LocalSearch.search(search_store, query; tags=["claw_agent_data"], limit=max_fetch)  # no channel context → all agent data
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
                "SELECT tag FROM claw_agent_data_tags WHERE key = ?", (k,))
                push!(row_tags, trow.tag)
            end
            all(t -> t in row_tags, filter_tags) || continue
        end
        # Time filter
        meta = _fetch_one(a.db, "SELECT created_at, updated_at FROM claw_agent_data WHERE key = ?", (k,))
        if meta !== nothing
            row = meta
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

const DB_LIST_KEYS_TOOL = @tool """List keys in your scratch space, sorted by most recently updated. Use this to browse stored entries without a search query.

For finding specific content by meaning, use db_search instead.

Arguments:
- tags (String, optional): Comma-separated tags to filter by (AND logic — all tags must match). Example: "project-x,config".
- after (String, optional): Only entries created after this time. Relative: "7d", "24h", "30m". Absolute: "2024-01-15".
- before (String, optional): Only entries created before this time. Same format as after.
- limit (Int, optional): Max entries to return. Default: 50.

Returns entries with key, tags, created and updated timestamps.

Gotchas:
- Results are channel-scoped (same rules as db_search).
- Shows keys and metadata only, not values. Use db_search to see content.""" function db_list_keys(tags::Union{Nothing, String} = nothing, after::Union{Nothing, String} = nothing, before::Union{Nothing, String} = nothing, limit::Union{Nothing, Int} = nothing)
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
            "SELECT key, created_at, updated_at FROM claw_agent_data$where ORDER BY updated_at DESC LIMIT ?", params)
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
               FROM claw_agent_data d
               INNER JOIN claw_agent_data_tags t ON d.key = t.key
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
            "SELECT tag FROM claw_agent_data_tags WHERE key = ? ORDER BY tag", (row.key,))
            push!(key_tags, trow.tag)
        end
        tag_str = isempty(key_tags) ? "" : " [$(join(key_tags, ", "))]"
        push!(lines, "- $(row.key)$tag_str (created: $created, updated: $updated)")
    end
    isempty(lines) ? "No stored entries" : join(lines, "\n")
end

const DB_LIST_TAGS_TOOL = @tool """List all distinct tags used across your scratch space entries.

Useful for discovering what categories exist before filtering with db_search or db_list_keys.

Arguments: none.

Returns a comma-separated list of all tags, sorted alphabetically.""" function db_list_tags()
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    tags = String[]
    for row in SQLite.DBInterface.execute(a.db,
        "SELECT DISTINCT tag FROM claw_agent_data_tags ORDER BY tag")
        push!(tags, row.tag)
    end
    isempty(tags) ? "No tags stored" : join(tags, ", ")
end

const DB_REMOVE_TOOL = @tool """Permanently remove an entry from your scratch space by key.

This deletes the entry, its tags, and its search index entry. This action is irreversible.

Arguments:
- key (String, required): The exact key to delete. Use db_list_keys to find keys.

Returns confirmation or "Key not found" if the key doesn't exist.""" function db_remove(key::String)
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    removed = lock(AGENT_DATA_WRITE_LOCK) do
        _with_busy_retry() do
            existing = _fetch_one(a.db, "SELECT 1 FROM claw_agent_data WHERE key = ?", (key,))
            existing === nothing && return false
            SQLite.DBInterface.execute(a.db, "DELETE FROM claw_agent_data WHERE key = ?", (key,))
            search_store = _get_search_store(a)
            LocalSearch.delete!(search_store, "agent_data:$key")
            return true
        end
    end
    !removed && return "Key '$key' not found"
    "Removed '$key'"
end

const DB_TOOLS = Agentif.AgentTool[DB_STORE_TOOL, DB_SEARCH_TOOL, DB_LIST_KEYS_TOOL, DB_LIST_TAGS_TOOL, DB_REMOVE_TOOL]

# ─── LLMTools event source ───

include("llmtools.jl")

# Per-handler tool policy, owner identity, startup exposure report (§2.2).
include("trust.jl")

# ─── Evaluate ───

function evaluate(
        assistant::AgentAssistant,
        input;
        channel::Union{Nothing, Agentif.AbstractChannel} = nothing,
        level::Union{Nothing, LogLevel, Int, Symbol, AbstractString} = nothing,
        # Tool availability is resolved per evaluation from the handler's trust tier
        # (§2.2). `nothing` keeps the assistant-wide set, which is what every direct
        # (non-handler) caller gets.
        tools::Union{Nothing, Vector{Agentif.AgentTool}} = nothing,
        kw...,
    )
    cfg = assistant.config
    model = Agentif.getModel(cfg.provider, cfg.model_id)
    model === nothing && error("Unknown model: provider=$(cfg.provider) model_id=$(cfg.model_id)")
    effective_level = level === nothing ? assistant.log_level : Agentif.resolve_log_level(level)
    @debug "Claw evaluate dispatch" assistant = cfg.name provider = cfg.provider model = cfg.model_id channel_id = (channel === nothing ? nothing : Agentif.channel_id(channel)) level = effective_level
    agent = Agentif.Agent(
        prompt = build_system_prompt(assistant; channel),
        model = model,
        apikey = cfg.apikey,
        tools = tools === nothing ? assistant.tools : tools,
    )
    # Prepend date/time context to user input (not system prompt) to preserve
    # LLM provider prefix-based prompt caching across turns.
    ctx = build_context_prefix(cfg)
    prefixed_input = input isa String ? string(ctx, "\n\n", input) : input
    return Agentif.evaluate(agent, prefixed_input;
        session_store = assistant.session_store,
        channel = channel,
        compaction_config = Agentif.CompactionConfig(),
        level = effective_level,
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
                "SELECT key FROM claw_agent_data WHERE post_id = ?", (post_id,))
            keys = String[String(r.key) for r in rows]
            if !isempty(keys)
                search_store = _get_search_store(assistant)
                for key in keys
                    try
                        Base.delete!(search_store, "agent_data:$key")
                    catch
                    end
                end
                SQLite.execute(db, "DELETE FROM claw_agent_data WHERE post_id = ?", (post_id,))
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
            SELECT eh.id, eh.prompt, eh.channel_id, eh.trust, eh.tools
            FROM claw_event_handlers eh
            JOIN claw_handler_event_types het ON eh.id = het.handler_id
            WHERE het.event_type_name = ?
        """, (event_name,))
            handler_id = row.id === missing ? "" : String(row.id)
            isempty(handler_id) && continue
            prompt = row.prompt === missing ? "" : String(row.prompt)
            channel_id = row.channel_id === missing ? nothing : String(row.channel_id)
            trust = _decode_handler_trust(row.trust)
            tools = _decode_handler_tools(row.tools)
            push!(handlers, (; id=handler_id, prompt, channel_id, trust, tools))
        end
        return handlers
    end
end

"""
    _all_event_handlers(assistant) -> Vector{NamedTuple}

Every registered handler with its subscribed event types and trust tier. Feeds
[`trust_exposure_report`](@ref) and the `list_event_handlers` tool.
"""
function _all_event_handlers(assistant::AgentAssistant)
    return _with_busy_retry() do
        handlers = NamedTuple[]
        rows = NamedTuple[]
        for row in SQLite.DBInterface.execute(assistant.db,
                "SELECT id, prompt, channel_id, trust, tools FROM claw_event_handlers")
            id = row.id === missing ? "" : String(row.id)
            isempty(id) && continue
            push!(rows, (; id,
                prompt = row.prompt === missing ? "" : String(row.prompt),
                channel_id = row.channel_id === missing ? nothing : String(row.channel_id),
                trust = _decode_handler_trust(row.trust),
                tools = _decode_handler_tools(row.tools)))
        end
        for r in rows
            event_types = String[]
            for et_row in SQLite.DBInterface.execute(assistant.db,
                    "SELECT event_type_name FROM claw_handler_event_types WHERE handler_id = ?", (r.id,))
                push!(event_types, String(et_row.event_type_name))
            end
            push!(handlers, (; r..., event_types))
        end
        return handlers
    end
end

# ─── SinkChannel ───
# No-op channel for event handlers without a target channel.
# Evaluation runs and session tracks results, but nothing is sent externally.

struct SinkChannel <: Agentif.AbstractChannel
    id::String
end
Agentif.channel_id(ch::SinkChannel) = ch.id
Agentif.channel_name(ch::SinkChannel) = "Internal ($(ch.id))"
Agentif.start_streaming(::SinkChannel) = nothing
Agentif.append_to_stream(::SinkChannel, ::AbstractString) = nothing
Agentif.finish_streaming(::SinkChannel) = nothing
Agentif.send_message(::SinkChannel, _) = nothing
Agentif.close_channel(::SinkChannel) = nothing
Agentif.is_group(::SinkChannel) = false
Agentif.is_private(::SinkChannel) = true

function _resolve_event_channel(assistant::AgentAssistant, ev::Event, handler_channel_id::Union{Nothing, String})
    if ev isa ChannelEvent
        ch = get_channel(ev)
        # Register dynamically-created channels so non-ChannelEvent handlers
        # (e.g. JMAP email → telegram) can look them up by channel_id.
        id = Agentif.channel_id(ch)
        assistant._channels[id] = ch
        return ch
    end
    handler_channel_id === nothing && return nothing
    return get(assistant._channels, handler_channel_id, nothing)
end

function _run_event_handler!(
        assistant::AgentAssistant,
        ev::Event,
        handler;
        level::Union{Nothing, LogLevel} = assistant.log_level,
        abort::Union{Nothing, Agentif.Abort} = nothing,
        kw...,     # forwarded to `evaluate` (tests inject a stub `base_handler`)
    )
    ch = _resolve_event_channel(assistant, ev, handler.channel_id)
    if ch === nothing
        ch = SinkChannel("handler:$(handler.id)")
    end
    input = make_prompt(handler.prompt, ev)
    # §2.2: the tool vector is resolved here, per evaluation, from this handler's
    # trust tier — not once at init! for the whole assistant.
    tools = resolve_handler_tools(assistant, handler)
    @debug "Claw handler evaluate start" handler_id = handler.id event_name = get_name(ev) channel_id = Agentif.channel_id(ch) trust = _handler_trust(handler) n_tools = length(tools)
    if abort === nothing
        evaluate(assistant, input; channel = ch, level = level, tools = tools, kw...)
    else
        evaluate(assistant, input; channel = ch, level = level, tools = tools, abort = abort, kw...)
    end
    @debug "Claw handler evaluate end" handler_id = handler.id event_name = get_name(ev)
    return nothing
end

# The durable event pipeline: ingestion, claiming, lanes, retries, supervision and
# graceful shutdown (§1.1–§1.6).
include("pipeline.jl")

# ─── Constructor ───

function AgentAssistant(db_path::String;
    name::Union{Nothing, String}=nothing,
    provider::String=get(ENV, "CLAW_AGENT_PROVIDER", ""),
    model_id::String=get(ENV, "CLAW_AGENT_MODEL", ""),
    apikey::String=get(ENV, "CLAW_AGENT_API_KEY", ""),
    timezone::String=_detect_timezone(),
    base_dir::String=pwd(),
    enable_web::Bool=false,
    enable_coding::Bool=false,
    owner_channels::Vector{String}=String[],
    owner_user_ids::Vector{String}=String[],
    level::Union{Nothing, LogLevel, Int, Symbol, AbstractString}=nothing,
    pipeline::PipelineConfig=PipelineConfig(),
)
    db_path = isempty(db_path) ? joinpath(pwd(), "$(something(name, "claw")).sqlite") : db_path
    db = SQLite.DB(db_path)
    _init_claw_schema!(db)
    search_store = LocalSearch.Store(db)
    session_store = Agentif.SQLiteSessionStore(db, search_store)
    tempus_store = Tempus.SQLiteStore(db)
    scheduler = Tempus.Scheduler(tempus_store)
    config = AgentConfig(; name, provider, model_id, apikey, timezone, base_dir, enable_web, enable_coding,
        owner_channels, owner_user_ids)
    log_level = Agentif.resolve_log_level(level)
    return AgentAssistant(;
        config,
        db,
        db_path,
        session_store,
        scheduler,
        log_level,
        pipeline,
        _writer = SQLiteWriter(db_path, db),
        _readers = ReaderPool(db_path, db),
        _sem = Base.Semaphore(max(1, pipeline.max_concurrent_evals)),
    )
end

# ─── Lifecycle ───

function init!(
        db_path::String = "";
        event_sources = nothing,
        level::Union{Nothing, LogLevel, Int, Symbol, AbstractString} = nothing,
        install_signal_handlers::Bool = !isinteractive(),
        kwargs...,
    )
    sources = event_sources === nothing ? lock(() -> collect(EVENT_SOURCES), EVENT_SOURCES_LOCK) : event_sources
    assistant = AgentAssistant(db_path; level, kwargs...)
    CURRENT_ASSISTANT[] = assistant
    # Purge ephemeral tables (re-populated from EventSources)
    SQLite.DBInterface.execute(assistant.db, "DELETE FROM claw_event_types")
    # Re-seed event types for persisted Tempus jobs: they are only inserted at
    # add_job time, so the purge above would otherwise orphan them (breaking
    # list_event_types and add_event_handler validation for those types).
    for j in Tempus.getJobs(assistant.scheduler.store)
        et_name = "tempus_job:$(j.name)"
        SQLite.DBInterface.execute(assistant.db,
            "INSERT OR IGNORE INTO claw_event_types (name, description) VALUES (?, ?)",
            (et_name, "Scheduled job: $(j.name)"))
    end
    # Auto-register LLMToolsEventSource if not already provided
    if !any(es -> es isa LLMToolsEventSource, sources)
        llm_es = LLMToolsEventSource(assistant.config)
        register_event_source!(assistant, llm_es)
    end
    for es in sources
        register_event_source!(assistant, es)
    end
    append!(assistant.tools, MANAGEMENT_TOOLS)
    append!(assistant.tools, TEMPUS_TOOLS)
    append!(assistant.tools, DB_TOOLS)
    # §2.2: the permissive default is the one that persists, so state the exposure
    # once per boot instead of relying on anyone remembering it. Runs after tools and
    # handlers are registered and before any event can be dispatched.
    _log_trust_exposure(assistant, sources)
    Tempus.run!(assistant.scheduler)
    assistant._scheduler_started[] = true
    start_event_loop!(assistant; level = assistant.log_level)
    # Crash/stuck-worker recovery before sources start producing new work.
    _recover_events!(assistant)
    start_sources!(assistant, sources)
    install_signal_handlers && install_shutdown_handler!(assistant)
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
# Notify on close so `a"..."` never hangs when an evaluation errors out or the
# response is suppressed (finish_streaming never runs on those paths).
Agentif.close_channel(ch::ReplChannel) = notify(ch.completion)

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

event_source_tag(::ReplInputEvent) = "repl"
event_lane(::ReplInputEvent) = "repl"

# ─── REPL macro ───

macro a_str(input)
    quote
        a = Claw.get_current_assistant()
        a === nothing && error("No assistant initialized. Call Claw.init!() first.")
        ch = ReplChannel()
        if Claw.submit_event!(a, ReplInputEvent($(esc(input)), ch)) === nothing
            error("Claw: failed to enqueue REPL input")
        end
        wait(ch.completion)
        nothing
    end
end

function __init__()
    isinteractive() && register_event_source!(ReplEventSource())
    _register_builtin_rehydrators!()
    return
end

end
