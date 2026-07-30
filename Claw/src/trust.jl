# trust.jl — per-handler tool policy and owner identity (hardening §2.2)
#
# Every handler evaluation used to get *every* tool: `set_system_prompt` (persistent
# self-modification), `add_event_handler`/`add_job` (standing automations), the
# send-email tools, and — with `enable_coding` — an unsandboxed shell. An inbound
# email or a GitHub comment is authored by someone who is not the owner, so any of
# those is one prompt injection away from rewriting the assistant's soul or
# installing a mail-forwarding rule.
#
# **Owner decision (2026-07-30): the default tier is `:owner`.** Restriction is
# opt-in (`EventHandler(...; trust = :untrusted)`), so nothing an existing
# deployment does changes when this lands. The accepted cost is that the exposure
# persists until a handler is explicitly marked — which is why `init!` states it out
# loud on every boot instead of leaving it to memory.

const TRUST_TIERS = (:owner, :untrusted)

"""
Tools an `:untrusted` handler does not get. Two families:

1. *Self-modification and standing automation* — the ways a single injected message
   turns into a permanent change (`set_system_prompt`, handler/job registration).
2. *Reach outside the process* — sending mail as the owner, and the shell/worker/
   subagent/codex surface, which is arbitrary code execution.

Read, search and scratch-space (`db_*`) tools stay: an untrusted handler is still
expected to actually read the thing it was triggered by. This is a plain `Set`, so a
deployment with extra dangerous tools can `push!` onto it at startup.
"""
const UNTRUSTED_DENIED_TOOLS = Set{String}([
    # Self-modification / standing automations
    "set_system_prompt",
    "add_event_handler", "remove_event_handler",
    "add_job", "remove_job",
    # Outbound email (JMAP)
    "email_send", "email_reply", "email_forward",
    # Shell / filesystem writes / delegation (LLMTools)
    "exec_command", "write_stdin", "kill_session",
    "edit", "write", "codex", "subagent",
    # Claw async sessions
    "start_pty", "write_pty", "kill_pty",
    "start_worker", "eval_worker", "kill_worker",
    "start_subagent", "message_subagent", "kill_subagent",
])

# Handlers arrive here either as an `EventHandler` or as the NamedTuple row
# `_event_handlers_for` builds, so read the fields defensively.
function _handler_trust(handler)
    hasproperty(handler, :trust) || return :owner
    t = getproperty(handler, :trust)
    t isa Symbol || return :owner
    return t in TRUST_TIERS ? t : :untrusted   # unknown tier ⇒ the safe one
end

function _handler_tool_names(handler)
    hasproperty(handler, :tools) || return nothing
    names = getproperty(handler, :tools)
    names === nothing && return nothing
    return String[String(n) for n in names]
end

"""
    resolve_handler_tools(assistant, handler) -> Vector{Agentif.AgentTool}

The tool vector for one handler evaluation.

- `tools = nothing` and `trust = :owner` (the defaults) returns `assistant.tools`
  itself — byte-for-byte what the handler saw before this file existed. That
  identity is the no-regression guarantee, and it is asserted in the test suite.
- A non-`nothing` `tools` narrows to that named subset.
- `trust = :untrusted` then drops everything in [`UNTRUSTED_DENIED_TOOLS`](@ref).
"""
function resolve_handler_tools(assistant::AgentAssistant, handler)
    tools = assistant.tools
    names = _handler_tool_names(handler)
    if names !== nothing
        allowed = Set{String}(names)
        tools = Agentif.AgentTool[t for t in tools if Agentif.tool_name(t) in allowed]
    end
    _handler_trust(handler) === :untrusted || return tools
    return Agentif.AgentTool[t for t in tools if !(Agentif.tool_name(t) in UNTRUSTED_DENIED_TOOLS)]
end

"""
    denied_tool_names(assistant) -> Vector{String}

The tools this assistant actually has loaded that an `:untrusted` handler would
lose. Used to name the concrete exposure in the startup warning rather than
reciting the whole deny list.
"""
function denied_tool_names(assistant::AgentAssistant)
    return sort!(String[Agentif.tool_name(t) for t in assistant.tools
        if Agentif.tool_name(t) in UNTRUSTED_DENIED_TOOLS])
end

# ─── Owner identity ───

_channel_id_of(::Nothing) = nothing
_channel_id_of(ch::Agentif.AbstractChannel) = try
    Agentif.channel_id(ch)
catch
    nothing
end
_channel_id_of(id::AbstractString) = String(id)

"""
    is_owner_context(assistant, channel, user_id = nothing) -> Bool

Is this evaluation happening in a place the owner controls?

The REPL is always owner — it is the owner's own process. Otherwise the channel id
must be in `owner_channels` or the user id in `owner_user_ids` (both empty by
default, so everything else is *not* owner until configured).

`channel` may be an `AbstractChannel`, a channel id string, or `nothing`.
"""
function is_owner_context(assistant::AgentAssistant, channel = nothing, user_id = nothing)
    channel isa ReplChannel && return true
    cfg = assistant.config
    cid = _channel_id_of(channel)
    cid == "repl" && return true
    cid !== nothing && cid in cfg.owner_channels && return true
    uid = user_id === nothing ? nothing : String(user_id)
    uid !== nothing && !isempty(uid) && uid in cfg.owner_user_ids && return true
    return false
end

# ─── Bind-address safety (§2.1) ───

"""
    is_loopback_host(host) -> Bool

Is this bind address reachable only from the machine itself? HTTP-listening sources
default to loopback and refuse to bind anywhere wider without inbound authentication
configured, so the safe deployment (behind a proxy that terminates TLS and
authenticates) is the one you get by doing nothing.
"""
function is_loopback_host(host::AbstractString)
    h = lowercase(strip(String(host), ['[', ']', ' ']))
    h == "localhost" && return true
    ip = try
        Base.parse(Sockets.IPAddr, h)
    catch
        return false
    end
    ip isa Sockets.IPv4 && return (UInt32(ip.host) >> 24) == 0x7f
    ip isa Sockets.IPv6 && return UInt128(ip.host) == UInt128(1)
    return false
end

# ─── Startup exposure report (§2.2) ───

"""
    third_party_content(es::EventSource) -> Bool

Does this source deliver content authored by someone other than the owner? `true`
for inbound email and webhooks; extensions override it. Chat sources are classified
per-channel instead (a DM is not third-party; a group channel is), so they leave
this at the default.
"""
third_party_content(::EventSource) = false

_channel_is_shared(ch) = try
    Agentif.is_group(ch) || !Agentif.is_private(ch)
catch
    false
end

"""
    trust_exposure_report(assistant, sources) -> Vector{NamedTuple}

Every handler that is `:owner`-tier *and* fed by third-party-authored content, with
the reason. Pure enough to test directly; [`_log_trust_exposure`](@ref) formats it.

Two ways a handler qualifies:

1. It subscribes to an event type published by a source that declares
   [`third_party_content`](@ref) — inbound email, webhooks.
2. It touches a shared channel: either one of its source's registered channels is a
   group/public channel, or its own target channel is.

Chat sources that mint channels lazily (MSTeams, Telegram) register nothing at
startup, so their group chats only become visible to this report once a channel has
been seen. That gap is why rule 1 exists for the sources that can be classified
statically.
"""
function trust_exposure_report(assistant::AgentAssistant, sources)
    # event type name => reason, for event types owned by an exposed source
    exposed_types = Dict{String, String}()
    for es in sources
        reasons = String[]
        try
            third_party_content(es) && push!(reasons, "third-party-authored content")
        catch
        end
        shared = String[]
        try
            for ch in get_channels(es)
                _channel_is_shared(ch) && push!(shared, Agentif.channel_id(ch))
            end
        catch
        end
        isempty(shared) || push!(reasons, "group/public channel(s): $(join(sort!(unique(shared)), ", "))")
        isempty(reasons) && continue
        tag = _source_tag(es)
        try
            for et in get_event_types(es)
                exposed_types[et.name] = string(tag, " (", join(reasons, "; "), ")")
            end
        catch
        end
    end

    rows = NamedTuple[]
    handlers = try
        _all_event_handlers(assistant)
    catch e
        @debug "Claw: could not read handlers for the trust exposure report" exception = (e,)
        return rows
    end
    for h in handlers
        _handler_trust(h) === :owner || continue
        reasons = String[]
        for et in h.event_types
            r = get(exposed_types, et, nothing)
            r === nothing || push!(reasons, "$et via $r")
        end
        if h.channel_id !== nothing
            ch = get(assistant._channels, h.channel_id, nothing)
            ch !== nothing && _channel_is_shared(ch) &&
                push!(reasons, "replies into group/public channel $(h.channel_id)")
        end
        isempty(reasons) && continue
        push!(rows, (; id = h.id, reasons = unique!(reasons)))
    end
    sort!(rows; by = r -> r.id)
    return rows
end

"""
    _log_trust_exposure(assistant, sources)

One consolidated warning at `init!` naming the owner-tier handlers reachable from
third-party content, the tools that reach further than reading, and how to opt in to
restriction. Silent when nothing qualifies — a warning that fires on every boot of a
safe deployment is a warning nobody reads.
"""
function _log_trust_exposure(assistant::AgentAssistant, sources)
    rows = trust_exposure_report(assistant, sources)
    isempty(rows) && return nothing
    at_risk = denied_tool_names(assistant)
    io = IOBuffer()
    println(io, "Claw trust exposure: $(length(rows)) event handler(s) run at :owner trust on ",
        "third-party-authored content. A prompt injection in that content can reach every tool below.")
    for r in rows
        println(io, "  - ", r.id, ": ", join(r.reasons, "; "))
    end
    println(io, "  tools at risk: ", isempty(at_risk) ? "(none loaded)" : join(at_risk, ", "))
    print(io, "  to restrict: EventHandler(id, event_types, prompt, channel_id; trust = :untrusted)")
    @warn String(take!(io))
    return nothing
end
