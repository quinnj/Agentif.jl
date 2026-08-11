# integrations.jl — user-driven integration enablement (Tier 1).
#
# The split, following the pattern every mature event platform converged on
# (Home Assistant manifests, VS Code activation events, OpenClaw plugin records):
#
# - a **static catalog** (`INTEGRATION_SPECS`) describes every integration Claw
#   knows how to run — name, owning package, config keys — and is listable without
#   the package being loaded;
# - a **factory registry** (`INTEGRATION_FACTORIES`) is populated by each Claw
#   extension's `__init__` when its trigger package loads (`using Slack` ⇒ the
#   "slack" factory appears);
# - the **enabled-set** is a persisted `claw_integrations` row per integration,
#   reconciled at `init!` — so which integrations run is data, not runner code.
#
# All code loads eagerly (deployments `using` the packages they ship with); a
# toggle activates or deactivates an already-loadable integration. No runtime
# `require` — deliberate, to stay trim-compile friendly.

"""
    IntegrationSpec(name, package, description, config_keys)

Catalog entry for one integration. `config_keys` maps constructor keyword names to
short descriptions (mentioning the environment variable that supplies the default,
when there is one). Present in the catalog even when `package` is not loaded —
that is what makes `list_integrations` useful before anything is enabled.
"""
struct IntegrationSpec
    name::String
    package::String
    description::String
    config_keys::Vector{Pair{String, String}}
end

const INTEGRATION_SPECS = Dict{String, IntegrationSpec}(
    "slack" => IntegrationSpec("slack", "Slack",
        "Slack workspace via Socket Mode: messages and emoji reactions, streamed replies.",
        ["app_token" => "Slack app-level token (default: ENV SLACK_APP_TOKEN)",
         "bot_token" => "bot user OAuth token (default: ENV SLACK_BOT_TOKEN)",
         "bot_user_id" => "bot user id, used to ignore own messages (default: ENV SLACK_BOT_USER_ID)",
         "bot_username" => "bot username for @-mention detection (default: ENV SLACK_BOT_USERNAME)",
         "recipient_team_id" => "team id for streamed replies outside DMs (default: ENV SLACK_STREAM_RECIPIENT_TEAM_ID)",
         "recipient_user_id" => "user id for streamed replies outside DMs (default: ENV SLACK_STREAM_RECIPIENT_USER_ID)"]),
    "telegram" => IntegrationSpec("telegram", "Telegram",
        "Telegram bot: messages and reactions via long polling (default) or webhook. The bot token comes from ENV TELEGRAM_BOT_TOKEN.",
        ["use_polling" => "true = long polling (default), false = webhook server",
         "timeout" => "long-poll timeout seconds (default 30)",
         "host" => "webhook bind host (default: ENV TELEGRAM_WEBHOOK_HOST or 127.0.0.1)",
         "port" => "webhook port (default 8080)",
         "path" => "webhook path (default /webhook)",
         "secret_token" => "webhook secret (default: ENV TELEGRAM_WEBHOOK_SECRET_TOKEN)"]),
    "signal" => IntegrationSpec("signal", "Signal",
        "Signal messenger via signal-cli REST API: direct and group messages.",
        ["number" => "the Signal account number (default: ENV SIGNAL_NUMBER)",
         "base_url" => "signal-cli REST API base URL (default: ENV SIGNAL_API_URL or http://127.0.0.1:8080)",
         "auto_reconnect" => "reconnect the websocket on drop (default true)"]),
    "msteams" => IntegrationSpec("msteams", "MSTeams",
        "Microsoft Teams via Bot Framework webhook (JWT-validated).",
        ["app_id" => "Bot Framework app id (default: ENV MSTEAMS_APP_ID)",
         "app_password" => "Bot Framework app password (default: ENV MSTEAMS_APP_PASSWORD)",
         "host" => "webhook bind host (default: ENV MSTEAMS_HOST or 127.0.0.1)",
         "port" => "webhook port (default 3978)",
         "path" => "webhook path (default /api/messages)"]),
    "mattermost" => IntegrationSpec("mattermost", "Mattermost",
        "Mattermost server via websocket: messages and reactions. Connection settings come from the MATTERMOST_* environment variables.",
        Pair{String, String}[]),
    "github" => IntegrationSpec("github", "GitHub",
        "GitHub webhooks (push, PRs, issues, comments, releases, workflow runs...) via a local HTTP listener.",
        ["secret" => "webhook HMAC secret (default: ENV GITHUB_WEBHOOK_SECRET)",
         "host" => "bind host (default: ENV GITHUB_WEBHOOK_HOST or 127.0.0.1)",
         "port" => "listen port (default: ENV GITHUB_WEBHOOK_PORT or 8080)",
         "repos" => "optional allowlist of owner/repo full names",
         "events" => "optional allowlist of webhook event kinds"]),
    "fastmail" => IntegrationSpec("fastmail", "JMAP",
        "Fastmail email via JMAP push: new-email events plus email tools (search, read, send).",
        ["token" => "JMAP API token (default: ENV JMAP_API_TOKEN)",
         "session_url" => "JMAP session URL (default: ENV JMAP_SESSION_URL)",
         "ping" => "EventSource ping interval seconds (default 30)"]),
)

# name => zero-or-keyword-arg callable returning an EventSource. Populated by the
# extensions' `__init__`s, so a factory's presence means the package is loaded.
const INTEGRATION_FACTORIES = Dict{String, Any}()
const INTEGRATIONS_LOCK = ReentrantLock()

"""
    register_integration!(name, factory)
    register_integration!(spec::IntegrationSpec, factory)

Register the factory for a cataloged integration (the form each Claw extension
calls from its `__init__`), or a spec + factory pair for a third-party integration
not in the built-in catalog.
"""
function register_integration!(name::AbstractString, factory)
    key = lowercase(strip(String(name)))
    lock(INTEGRATIONS_LOCK) do
        haskey(INTEGRATION_SPECS, key) || throw(ArgumentError(
            "unknown integration '$key'; third-party integrations must register an IntegrationSpec: register_integration!(spec, factory)"))
        INTEGRATION_FACTORIES[key] = factory
    end
    return factory
end

function register_integration!(spec::IntegrationSpec, factory)
    key = lowercase(strip(spec.name))
    isempty(key) && throw(ArgumentError("integration name cannot be empty"))
    canonical = IntegrationSpec(key, spec.package, spec.description, spec.config_keys)
    lock(INTEGRATIONS_LOCK) do
        INTEGRATION_SPECS[key] = canonical
        INTEGRATION_FACTORIES[key] = factory
    end
    return factory
end

_integration_factory(key::String) = lock(() -> get(INTEGRATION_FACTORIES, key, nothing), INTEGRATIONS_LOCK)

# The catalog name for an explicitly-constructed source, so runner-passed sources
# and catalog-enabled ones cannot double-enable. Factories are the source types
# themselves, so `isa` is the match.
function _integration_name_for(es::EventSource)
    return lock(INTEGRATIONS_LOCK) do
        for (name, factory) in INTEGRATION_FACTORIES
            factory isa Type && es isa factory && return name
        end
        return nothing
    end
end

# ─── Persistence ───

function _persist_integration!(assistant::AgentAssistant, name::String, enabled::Bool,
        config::Union{Nothing, AbstractDict})
    cfg_json = config === nothing ? nothing : JSON.json(_sanitize_integration_config(config))
    now = time()
    execute_write(assistant._writer) do db
        _with_busy_retry() do
            if cfg_json === nothing
                # Keep the stored config so disable/enable round-trips it.
                _exec!(db, """
                    INSERT INTO claw_integrations (name, enabled, updated_at) VALUES (?, ?, ?)
                    ON CONFLICT(name) DO UPDATE SET enabled = excluded.enabled, updated_at = excluded.updated_at
                """, (name, enabled ? 1 : 0, now))
            else
                _exec!(db, """
                    INSERT INTO claw_integrations (name, enabled, config, updated_at) VALUES (?, ?, ?, ?)
                    ON CONFLICT(name) DO UPDATE SET enabled = excluded.enabled, config = excluded.config, updated_at = excluded.updated_at
                """, (name, enabled ? 1 : 0, cfg_json, now))
            end
            return nothing
        end
    end
    return nothing
end

function _sensitive_integration_values(config::AbstractDict)
    values = String[]
    for (key, value) in config
        if _is_sensitive_integration_key(key)
            if value !== nothing
                rendered = value isa AbstractString ? String(value) : string(value)
                isempty(rendered) || push!(values, rendered)
            end
        elseif value isa AbstractDict
            append!(values, _sensitive_integration_values(value))
        elseif value isa AbstractVector
            for item in value
                item isa AbstractDict && append!(values, _sensitive_integration_values(item))
            end
        end
    end
    return values
end

function _redact_sensitive_values(message::AbstractString, values)
    redacted = String(message)
    for value in unique(values)
        isempty(value) || (redacted = replace(redacted, value => "[REDACTED]"))
    end
    return redacted
end

_config_error_detail(error, config::AbstractDict) =
    _redact_sensitive_values(sprint(showerror, _unwrap_error(error)),
        _sensitive_integration_values(config))

function _source_error_detail(source::EventSource, error)
    config = Dict{String, Any}()
    for field in fieldnames(typeof(source))
        _is_sensitive_integration_key(field) || continue
        value = try
            getfield(source, field)
        catch
            nothing
        end
        config[String(field)] = value
    end
    return _config_error_detail(error, config)
end

function _set_integration_status!(assistant::AgentAssistant, name::String, status::AbstractString)
    try
        execute_write(assistant._writer,
            "UPDATE claw_integrations SET status = ? WHERE name = ?",
            (first(String(status), 500), name))
    catch e
        @debug "Claw: failed to record integration status" integration = name exception = (e,)
    end
    return nothing
end

# ─── Registration bookkeeping ───

# `register_event_source!` plus a record of exactly what it added, so disable can
# undo precisely that.
function _register_event_source_tracked!(assistant::AgentAssistant, es::EventSource)
    return lock(assistant._integrations_lock) do
        channels = collect(get_channels(es))
        event_types = collect(get_event_types(es))
        handlers = collect(get_event_handlers(es))
        tools = collect(get_tools(es))
        channel_ids = String[Agentif.channel_id(ch) for ch in channels]
        event_type_names = String[et.name for et in event_types]
        tool_names = String[Agentif.tool_name(tool) for tool in tools]

        # Runtime enablement can run from a tool task while the pipeline writer is
        # active. Keep registration writes on that writer instead of racing the
        # main SQLite handle.
        _writer_txn(assistant) do db
            for et in event_types
                _exec!(db, "INSERT OR IGNORE INTO claw_event_types (name, description) VALUES (?, ?)",
                    (et.name, et.description))
            end
            for eh in handlers
                _upsert_event_handler!(db, eh)
            end
            return nothing
        end

        register_event_source!(es)
        for (id, ch) in zip(channel_ids, channels)
            assistant._channels[id] = ch
        end
        append!(assistant.tools, tools)
        return (; channel_ids, event_type_names, tool_names)
    end
end

# ─── Enable / disable ───

"""
    enable_integration!(assistant, name; config = Dict(), persist = true) -> IntegrationState

Construct, register and start the cataloged integration `name`. `config` entries
are passed as keyword arguments to the integration's constructor (environment
variables supply the defaults). With `persist` (the default), the integration is
recorded enabled in `claw_integrations` and comes back automatically on the next
`init!`. Credential-like config values are never persisted; future boots must get
them from environment variables. Throws with a descriptive message when the
integration is unknown, already enabled, or its package is not loaded.
"""
function enable_integration!(assistant::AgentAssistant, name::AbstractString;
        config::AbstractDict = Dict{String, Any}(), persist::Bool = true)
    key = lowercase(strip(String(name)))
    # The whole enable runs under the integrations lock so two concurrent enables
    # of the same name cannot both pass the already-enabled check and construct
    # duplicate sources. Persistence stays inside the same critical section so a
    # concurrent disable cannot leave the database disagreeing with runtime state.
    # Lock order: _integrations_lock, then _sources_lock.
    state = lock(assistant._integrations_lock) do
        assistant._state[] === :running || error(
            "Cannot enable integration '$key' while the pipeline is $(assistant._state[]).")
        haskey(assistant._integrations, key) && error("Integration '$key' is already enabled.")
        spec, factory, known = lock(INTEGRATIONS_LOCK) do
            (get(INTEGRATION_SPECS, key, nothing), get(INTEGRATION_FACTORIES, key, nothing),
                sort!(collect(keys(INTEGRATION_SPECS))))
        end
        spec === nothing && error("Unknown integration '$key'. Known integrations: $(join(known, ", ")).")
        factory === nothing && error(
            "Integration '$key' is in the catalog but package $(spec.package) is not loaded in this process. " *
            "Add `using $(spec.package)` to the deployment; the Claw extension registers the factory when the package loads.")
        valid_keys = Set(first.(spec.config_keys))
        unknown_keys = sort!(String[String(k) for k in keys(config) if !(String(k) in valid_keys)])
        if !isempty(unknown_keys)
            valid = isempty(valid_keys) ? "none" : join(sort!(collect(valid_keys)), ", ")
            error("Unknown config key(s) for integration '$key': $(join(unknown_keys, ", ")). Valid config keys: $valid.")
        end
        kwargs = Dict{Symbol, Any}(Symbol(String(k)) => v for (k, v) in config)
        es = try
            factory(; kwargs...)
        catch e
            valid = isempty(spec.config_keys) ? "none" : join(first.(spec.config_keys), ", ")
            detail = _config_error_detail(e, config)
            error("Failed to construct integration '$key': $detail. Valid config keys: $valid.")
        end
        try
            validate_source(es)
        catch e
            error("Integration '$key' configuration is invalid: $(_source_error_detail(es, e))")
        end
        reg = _register_event_source_tracked!(assistant, es)
        st = IntegrationState(key, es, nothing, reg.channel_ids, reg.event_type_names, reg.tool_names)
        assistant._integrations[key] = st
        st.supervised = _start_supervised_source!(assistant, es; validated = true)
        if persist
            try
                _persist_integration!(assistant, key, true, config)
            catch
                pop!(assistant._integrations, key, nothing)
                try
                    _disable_integration_locked!(assistant, key, st; persist = false)
                catch rollback_error
                    @error "Claw: failed to roll back integration after persistence failure" integration = key exception = (rollback_error, catch_backtrace())
                end
                rethrow()
            end
            _set_integration_status!(assistant, key, "")
        end
        st
    end
    _journal_source!(assistant, _source_tag(state.source), "enabled")
    # An integration enabled at runtime was not covered by the boot report; state
    # any third-party-content exposure it introduces now.
    assistant._state[] === :running && _log_trust_exposure(assistant, EventSource[state.source])
    return state
end

"""
    disable_integration!(assistant, name; persist = true)

Stop the integration's source (supervision ends and `stop!` is called) and remove
what enabling registered: its channels, its tools, and its
event types. Handlers subscribed to those event types are kept — they show as
"(inactive)" in `list_event_handlers` and fire again when the integration is
re-enabled. With `persist` (the default), the integration is recorded disabled so
it stays off across restarts (its stored non-sensitive config is kept).
"""
function disable_integration!(assistant::AgentAssistant, name::AbstractString; persist::Bool = true)
    key = lowercase(strip(String(name)))
    lock(assistant._integrations_lock) do
        assistant._state[] === :running || error(
            "Cannot disable integration '$key' while the pipeline is $(assistant._state[]).")
        state = get(assistant._integrations, key, nothing)
        state === nothing && error("Integration '$key' is not enabled.")
        # Persist the transition before changing runtime state. If this write
        # fails, the source stays fully enabled and a restart agrees with it.
        persist && _persist_integration!(assistant, key, false, nothing)
        try
            _disable_integration_locked!(assistant, key, state; persist = false)
            pop!(assistant._integrations, key)
        catch
            # If cooperative shutdown fails, keep durable and runtime state
            # enabled. The supervisor is restored by the stop helper.
            persist && _persist_integration!(assistant, key, true, nothing)
            rethrow()
        end
    end
    return nothing
end

# Caller holds `_integrations_lock` for the full transition. In particular, do not
# let a re-enable register a replacement source until this old source has stopped
# and all registrations attributed to it have been removed.
function _disable_integration_locked!(assistant::AgentAssistant, key::String,
        state::IntegrationState; persist::Bool)
    ss = state.supervised
    if ss === nothing
        ss = lock(assistant._sources_lock) do
            idx = findfirst(s -> s.source === state.source, assistant._sources)
            idx === nothing ? nothing : assistant._sources[idx]
        end
    end
    ss === nothing || _stop_supervised_source!(assistant, ss)
    # Channels: the ones recorded at registration plus whatever the source reports
    # now (sources like Slack register their channel list during start!).
    channel_ids = Set{String}(state.channel_ids)
    try
        for ch in get_channels(state.source)
            push!(channel_ids, Agentif.channel_id(ch))
        end
    catch e
        @debug "Claw: get_channels failed during disable" integration = key exception = (e,)
    end
    for id in channel_ids
        Base.delete!(assistant._channels, id)
    end
    if !isempty(state.tool_names)
        remove = Set(state.tool_names)
        filter!(t -> !(Agentif.tool_name(t) in remove), assistant.tools)
    end
    if !isempty(state.event_type_names)
        execute_write(assistant._writer) do db
            _with_busy_retry() do
                for et in state.event_type_names
                    _exec!(db, "DELETE FROM claw_event_types WHERE name = ?", (et,))
                end
                return nothing
            end
        end
    end
    lock(EVENT_SOURCES_LOCK) do
        Base.delete!(EVENT_SOURCES, state.source)
    end
    persist && _persist_integration!(assistant, key, false, nothing)
    _journal_source!(assistant, _source_tag(state.source), "disabled")
    return nothing
end

# ─── init! reconciliation ───

# Runner-passed sources that match a registered factory are adopted under their
# catalog name (not persisted — the runner re-passes them every boot), so the
# enabled-set cannot double-start them and disable_integration! works on them.
function _adopt_explicit_integrations!(assistant::AgentAssistant, regs)
    for (es, reg) in regs
        name = _integration_name_for(es)
        name === nothing && continue
        already = lock(assistant._integrations_lock) do
            haskey(assistant._integrations, name)
        end
        if already
            @warn "Claw: multiple sources for one integration; disable_integration! will only manage the first" integration = name
            continue
        end
        ss = lock(assistant._sources_lock) do
            idx = findfirst(s -> s.source === es, assistant._sources)
            idx === nothing ? nothing : assistant._sources[idx]
        end
        state = IntegrationState(name, es, ss, reg.channel_ids, reg.event_type_names, reg.tool_names)
        lock(assistant._integrations_lock) do
            assistant._integrations[name] = state
        end
    end
    return nothing
end

# Bring up everything recorded enabled in `claw_integrations`. Per-integration
# failure isolation: one bad token must not abort init! or the other integrations.
function _reconcile_integrations!(assistant::AgentAssistant)
    rows = Tuple{String, Union{Nothing, String}}[]
    for row in SQLite.DBInterface.execute(assistant.db,
            "SELECT name, config FROM claw_integrations WHERE enabled = 1")
        nm = row.name === missing ? "" : String(row.name)
        isempty(nm) && continue
        cfg = (row.config === missing || row.config === nothing) ? nothing : String(row.config)
        push!(rows, (nm, cfg))
    end
    for (nm, cfg_raw) in rows
        already = lock(assistant._integrations_lock) do
            haskey(assistant._integrations, nm)
        end
        already && continue
        try
            config = Dict{String, Any}()
            if cfg_raw !== nothing && !isempty(strip(cfg_raw))
                parsed = try
                    JSON.parse(cfg_raw)
                catch
                    error("Stored integration config is not valid JSON.")
                end
                parsed isa AbstractDict || error("Stored integration config is not a JSON object.")
                for (k, v) in parsed
                    config[String(k)] = v
                end
            end
            enable_integration!(assistant, nm; config, persist = false)
            _set_integration_status!(assistant, nm, "")
        catch e
            msg = sprint(showerror, e)
            @error "Claw: failed to enable persisted integration" integration = nm exception = (e, catch_backtrace())
            _set_integration_status!(assistant, nm, msg)
        end
    end
    return nothing
end

# ─── Tools ───

const LIST_INTEGRATIONS_TOOL = @tool """List every integration Claw knows about with its status and config keys.

Statuses:
- "enabled": running now (managed — can be disabled with disable_integration).
- "enabled (stopped)": configured as enabled, but its supervisor stopped after a permanent failure or exhausted restart budget.
- "available": package loaded, ready to enable with enable_integration.
- "unavailable": in the catalog, but its package is not loaded in this deployment, so it cannot be enabled until the deployment adds it.

When to use: To see what messaging/event platforms this assistant can connect to, before calling enable_integration or disable_integration.

Arguments: none.

Returns one block per integration: name, status, description, config keys, and the last recorded error for integrations that failed to start.""" function list_integrations()
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    persisted = Dict{String, Tuple{Bool, String}}()
    for row in SQLite.DBInterface.execute(a.db, "SELECT name, enabled, status FROM claw_integrations")
        nm = row.name === missing ? "" : String(row.name)
        isempty(nm) && continue
        st = (row.status === missing || row.status === nothing) ? "" : String(row.status)
        persisted[nm] = (row.enabled == 1, st)
    end
    specs = lock(() -> sort!(collect(values(INTEGRATION_SPECS)); by = s -> s.name), INTEGRATIONS_LOCK)
    lines = String[]
    for spec in specs
        state = lock(a._integrations_lock) do
            get(a._integrations, spec.name, nothing)
        end
        status = if state !== nothing
            ss = state.supervised
            ss !== nothing && ss.stopped[] ? "enabled (stopped)" : "enabled"
        elseif _integration_factory(spec.name) !== nothing
            "available"
        else
            "unavailable (package $(spec.package) not loaded)"
        end
        push!(lines, "- $(spec.name) [$status]: $(spec.description)")
        if !isempty(spec.config_keys)
            for (k, desc) in spec.config_keys
                push!(lines, "    $k — $desc")
            end
        end
        p = get(persisted, spec.name, nothing)
        if p !== nothing && !isempty(p[2])
            push!(lines, "    last error: $(p[2])")
        end
    end
    isempty(lines) ? "No integrations in the catalog" : join(lines, "\n")
end

const ENABLE_INTEGRATION_TOOL = @tool """Enable an integration: construct it, start it, and persist it as enabled so it comes back after restarts.

Arguments:
- name (String, required): Integration name from list_integrations (e.g. "slack", "telegram").
- config_json (String, optional): JSON object of constructor config, e.g. {"bot_token": "xoxb-..."}. Omit to use environment-variable defaults (the common case). See list_integrations for each integration's keys.

Gotchas:
- Fails if the integration's package is not loaded in this deployment ("unavailable" in list_integrations) — that requires a deployment change, not a tool call.
- Non-sensitive config values are persisted. Credential-like values are used for this process only; provide them through environment variables for future boots.
- The integration starts immediately; a misconfigured one will log errors and retry under its restart budget.""" function enable_integration(name::String, config_json::Union{Nothing, String} = nothing)
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    config = Dict{String, Any}()
    if config_json !== nothing && !isempty(strip(config_json))
        parsed = try
            JSON.parse(config_json)
        catch e
            return "config_json is not valid JSON: $(sprint(showerror, e))"
        end
        parsed isa AbstractDict || return "config_json must be a JSON object"
        for (k, v) in parsed
            config[String(k)] = v
        end
    end
    try
        enable_integration!(a, name; config)
    catch e
        return sprint(showerror, e)
    end
    secret_note = any(_is_sensitive_integration_key, keys(config)) ?
        " Sensitive values were not persisted; future boots must get them from the environment." : ""
    return "Integration '$name' enabled and started. It will start automatically on future boots.$secret_note"
end

const DISABLE_INTEGRATION_TOOL = @tool """Disable a running integration: stop its event source and persist it as disabled so it stays off across restarts.

Its event handlers are kept (shown "(inactive)" in list_event_handlers) and fire again if the integration is re-enabled. Its stored non-sensitive config is kept too.

Arguments:
- name (String, required): Integration name from list_integrations.

Gotchas:
- Integrations passed explicitly by the deployment's runner script are re-enabled on every boot regardless; disabling one only lasts until the next restart.""" function disable_integration(name::String)
    a = get_current_assistant()
    a === nothing && return "No assistant initialized"
    try
        disable_integration!(a, name)
    catch e
        return sprint(showerror, e)
    end
    return "Integration '$name' disabled."
end

const INTEGRATION_TOOLS = Agentif.AgentTool[
    LIST_INTEGRATIONS_TOOL, ENABLE_INTEGRATION_TOOL, DISABLE_INTEGRATION_TOOL,
]
