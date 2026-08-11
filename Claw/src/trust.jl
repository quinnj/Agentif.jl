# trust.jl — per-handler tool policy (hardening §2.2)
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
Tools an `:untrusted` handler may use.

This is an allowlist. A denylist silently grants every new or custom tool until
somebody remembers to classify it. That is the wrong failure mode at a trust
boundary. The built-in set is limited to local reads, read-only discovery, email
reads, and Claw's local scratch space. Network fetches, external mutations, shells,
delegation, and unknown tools are denied by default.

The set is mutable so an operator can deliberately add a reviewed custom tool at
startup.
"""
const UNTRUSTED_ALLOWED_TOOLS = Set{String}([
    # Local file reads
    "read", "grep", "find", "ls",
    # Claw configuration discovery (read-only; enable/disable_integration are
    # standing-configuration mutations and stay denied)
    "list_channels", "list_event_types", "list_event_handlers",
    "get_system_prompt", "list_jobs", "list_integrations",
    # Local scratch space
    "db_store", "db_search", "db_list_keys", "db_list_tags", "db_remove",
    # Read-only JMAP operations
    "email_search", "email_read", "jmap_list_mailboxes", "email_thread",
])

# Handlers arrive here either as an `EventHandler` or as the NamedTuple row
# `_event_handlers_for` builds, so read the fields defensively.
function _handler_trust(handler)
    hasproperty(handler, :trust) || return :owner
    t = getproperty(handler, :trust)
    t isa Symbol || return :untrusted
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
- `trust = :untrusted` then keeps only names in
  [`UNTRUSTED_ALLOWED_TOOLS`](@ref). Unknown and custom tools fail closed.
"""
function resolve_handler_tools(assistant::AgentAssistant, handler)
    tools = assistant.tools
    names = _handler_tool_names(handler)
    if names !== nothing
        allowed = Set{String}(names)
        tools = Agentif.AgentTool[t for t in tools if Agentif.tool_name(t) in allowed]
    end
    _handler_trust(handler) === :untrusted || return tools
    return Agentif.AgentTool[t for t in tools if Agentif.tool_name(t) in UNTRUSTED_ALLOWED_TOOLS]
end

function _handler_at_risk_tool_names(assistant::AgentAssistant, handler)
    return sort!(String[Agentif.tool_name(t) for t in resolve_handler_tools(assistant, handler)
        if !(Agentif.tool_name(t) in UNTRUSTED_ALLOWED_TOOLS)])
end

# ─── Bind-address safety (§2.1) ───

"""
    is_loopback_host(host) -> Bool

Is this bind address reachable only from the machine itself? HTTP-listening sources
use this rule for their safe loopback defaults and tests.
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

Every handler that is `:owner`-tier, fed by third-party-authored content, and
actually granted tools outside the untrusted allowlist. Includes the reason and the
exact at-risk tools. Pure enough to test directly;
[`_log_trust_exposure`](@ref) formats it.

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
        at_risk = _handler_at_risk_tool_names(assistant, h)
        isempty(at_risk) && continue
        push!(rows, (; id = h.id, reasons = unique!(reasons), at_risk))
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
    at_risk = sort!(unique!(reduce(vcat, (r.at_risk for r in rows); init = String[])))
    io = IOBuffer()
    println(io, "Claw trust exposure: $(length(rows)) event handler(s) run at :owner trust on ",
        "third-party-authored content. A prompt injection can reach one or more of the tools below.")
    for r in rows
        println(io, "  - ", r.id, ": ", join(r.reasons, "; "),
            " [tools: ", join(r.at_risk, ", "), "]")
    end
    println(io, "  tools at risk: ", isempty(at_risk) ? "(none loaded)" : join(at_risk, ", "))
    print(io, "  to restrict: EventHandler(id, event_types, prompt, channel_id; trust = :untrusted)")
    @warn String(take!(io))
    return nothing
end
