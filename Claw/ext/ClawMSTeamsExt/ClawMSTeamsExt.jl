module ClawMSTeamsExt

using MSTeams
import Agentif
import Base64
import Claw
import HTTP
import JSON
import SHA

export MSTeamsEventSource

# Bot Framework inbound JWT validation (§2.1).
include("botframework_auth.jl")

# ─── Channel ───

mutable struct MSTeamsChannel <: Agentif.AbstractChannel
    client::MSTeams.BotClient
    activity::AbstractDict
    user_id::String
    user_name::String
    conversation_id::String
    # "personal" = DM, "groupChat" = private group, "channel" = team/public channel
    conversation_type::String
    message_id::String
    io::Union{Nothing, IOBuffer}
    display_name::String
end

function Agentif.start_streaming(ch::MSTeamsChannel)
    if ch.io === nothing
        ch.io = IOBuffer()
    end
end

function Agentif.append_to_stream(ch::MSTeamsChannel, delta::AbstractString)
    io = ch.io
    io === nothing && return
    write(io, String(delta))
end

Agentif.finish_streaming(::MSTeamsChannel) = nothing

function Agentif.close_channel(ch::MSTeamsChannel)
    io = ch.io
    io === nothing && return
    text = String(take!(io))
    if !isempty(text)
        MSTeams.reply_text(ch.client, ch.activity, text)
    end
    ch.io = nothing
end

function Agentif.send_message(ch::MSTeamsChannel, msg)
    MSTeams.reply_text(ch.client, ch.activity, string(msg))
end

Agentif.channel_id(ch::MSTeamsChannel) = "msteams:$(ch.conversation_id)"
Agentif.channel_name(ch::MSTeamsChannel) = isempty(ch.display_name) ? Agentif.channel_id(ch) : ch.display_name
Agentif.is_group(ch::MSTeamsChannel) = ch.conversation_type != "personal"
Agentif.is_private(ch::MSTeamsChannel) = ch.conversation_type in ("personal", "groupChat")

function Agentif.get_current_user(ch::MSTeamsChannel)
    isempty(ch.user_id) && return nothing
    return Agentif.ChannelUser(ch.user_id, ch.user_name)
end

Agentif.entry_id(ch::MSTeamsChannel) = isempty(ch.message_id) ? nothing : ch.message_id

# ─── Channel Events ───

struct MSTeamsMessageEvent <: Claw.ChannelEvent
    channel::MSTeamsChannel
    content::String
    direct_ping::Bool
end

Claw.get_name(::MSTeamsMessageEvent) = "msteams_message"
Claw.get_channel(ev::MSTeamsMessageEvent) = ev.channel
function Claw.event_content(ev::MSTeamsMessageEvent)
    if Agentif.is_group(ev.channel) && !isempty(ev.channel.user_name)
        return "[$(ev.channel.user_name)]: $(ev.content)"
    end
    return ev.content
end

struct MSTeamsReactionEvent <: Claw.ChannelEvent
    channel::MSTeamsChannel
    reaction::String
    user_name::String
    action::String
end

Claw.get_name(::MSTeamsReactionEvent) = "msteams_reaction"
Claw.get_channel(ev::MSTeamsReactionEvent) = ev.channel

function Claw.event_content(ev::MSTeamsReactionEvent)
    return "User '$(ev.user_name)' $(ev.action) reaction '$(ev.reaction)'"
end

# ─── Event Types & Handlers ───

const MESSAGE_EVENT_TYPE = Claw.EventType("msteams_message", "A new message activity in Microsoft Teams")
const REACTION_EVENT_TYPE = Claw.EventType("msteams_reaction", "A reaction added or removed in Microsoft Teams")

const REACTION_HANDLER_PROMPT = """
A user reacted to one of your messages. Interpret the reaction and respond appropriately:
- Positive reactions (like, heart, laugh): Approval. Continue with your current approach.
- Negative reactions (sad, angry): Potential disapproval. Ask what should change.
- Other reactions: Acknowledge briefly if appropriate.
Keep your response concise."""

"""
    MSTeamsEventSource(; app_id, app_password, host, port, path, health_path,
                         verify_jwt = true, issuers, clock_skew_s, openid_config_url)

Teams webhook receiver.

Two §2.1 changes from the original: `host` defaults to **loopback**, not
`0.0.0.0` — the safe deployment (behind a proxy) is the one you get by default —
and every inbound activity must carry a valid Bot Framework JWT before an event is
created.

`verify_jwt = false` exists for local development against the Bot Framework
Emulator. It is refused at `validate_source` on any non-loopback bind address:
turning off authentication *and* listening on the network is the configuration this
whole section exists to prevent.
"""
Base.@kwdef struct MSTeamsEventSource <: Claw.EventSource
    app_id::String = get(ENV, "MSTEAMS_APP_ID", "")
    app_password::String = get(ENV, "MSTEAMS_APP_PASSWORD", "")
    host::String = get(ENV, "MSTEAMS_HOST", "127.0.0.1")
    port::Int = 3978
    path::String = "/api/messages"
    health_path::String = "/healthz"
    verify_jwt::Bool = get(ENV, "MSTEAMS_VERIFY_JWT", "1") != "0"
    issuers::Vector{String} = BF_DEFAULT_ISSUERS
    clock_skew_s::Float64 = 300.0
    openid_config_url::String = BF_OPENID_CONFIG_URL
end

# Teams messages are written by whoever is in the conversation, and the default
# handlers cover `channel`/`groupChat` conversations as well as 1:1. Declared at the
# source level rather than left to the group/public-channel rule because Teams
# channels are minted per activity — `get_channels` is empty at startup, so the
# channel rule could never see them (§2.2).
Claw.third_party_content(::MSTeamsEventSource) = true

Claw.get_event_types(::MSTeamsEventSource) = Claw.EventType[MESSAGE_EVENT_TYPE, REACTION_EVENT_TYPE]

function Claw.get_event_handlers(::MSTeamsEventSource)
    Claw.EventHandler[
        Claw.EventHandler("msteams_message_default", ["msteams_message"], "", nothing),
        Claw.EventHandler("msteams_reaction_default", ["msteams_reaction"], REACTION_HANDLER_PROMPT, nothing),
    ]
end

# ─── Activity handling ───

_string_or_empty(x) = x === nothing ? "" : String(x)

function _conversation_info(activity::AbstractDict)
    conversation = get(() -> nothing, activity, "conversation")
    conversation_id = ""
    conversation_type = "personal"
    conversation_name = ""

    if conversation !== nothing
        conversation_id = _string_or_empty(get(() -> "", conversation, "id"))
        conversation_name = _string_or_empty(get(() -> "", conversation, "name"))
        ct = _string_or_empty(get(() -> "", conversation, "conversationType"))
        if isempty(ct) && get(() -> false, conversation, "isGroup") === true
            ct = "groupChat"
        end
        !isempty(ct) && (conversation_type = ct)
    end

    return conversation_id, conversation_type, conversation_name
end

function _activity_channel(activity::AbstractDict, client::MSTeams.BotClient, user_id::String, user_name::String, message_id::String)
    conversation_id, conversation_type, conversation_name = _conversation_info(activity)
    return MSTeamsChannel(client, activity, user_id, user_name, conversation_id, conversation_type, message_id, nothing, conversation_name)
end

function _message_activity_to_event(activity::AbstractDict, client::MSTeams.BotClient)
    _string_or_empty(get(() -> "", activity, "type")) == "message" || return nothing

    text = _string_or_empty(get(() -> "", activity, "text"))
    isempty(text) && return nothing

    from = get(() -> nothing, activity, "from")
    recipient = get(() -> nothing, activity, "recipient")
    user_id = from === nothing ? "" : _string_or_empty(get(() -> "", from, "id"))
    user_name = from === nothing ? "" : _string_or_empty(get(() -> "", from, "name"))
    isempty(user_name) && (user_name = user_id)

    bot_id = recipient === nothing ? "" : _string_or_empty(get(() -> "", recipient, "id"))
    !isempty(bot_id) && lowercase(bot_id) == lowercase(user_id) && return nothing

    message_id = _string_or_empty(get(() -> "", activity, "id"))
    ch = _activity_channel(activity, client, user_id, user_name, message_id)
    direct_ping = ch.conversation_type == "personal" || MSTeams.bot_is_mentioned(activity)
    return MSTeamsMessageEvent(ch, text, direct_ping)
end

function _reaction_entries(activity::AbstractDict, key::String)
    entries = get(() -> nothing, activity, key)
    entries isa AbstractVector || return []
    return entries
end

function _reaction_activity_to_events(activity::AbstractDict, client::MSTeams.BotClient)
    _string_or_empty(get(() -> "", activity, "type")) == "messageReaction" || return MSTeamsReactionEvent[]

    from = get(() -> nothing, activity, "from")
    user_id = from === nothing ? "" : _string_or_empty(get(() -> "", from, "id"))
    user_name = from === nothing ? "" : _string_or_empty(get(() -> "", from, "name"))
    isempty(user_name) && (user_name = user_id)

    message_id = _string_or_empty(get(() -> "", activity, "replyToId"))
    isempty(message_id) && (message_id = _string_or_empty(get(() -> "", activity, "id")))
    ch = _activity_channel(activity, client, user_id, user_name, message_id)

    out = MSTeamsReactionEvent[]
    for reaction in _reaction_entries(activity, "reactionsAdded")
        reaction isa AbstractDict || continue
        reaction_name = _string_or_empty(get(() -> "", reaction, "type"))
        isempty(reaction_name) && continue
        push!(out, MSTeamsReactionEvent(ch, reaction_name, user_name, "added"))
    end
    for reaction in _reaction_entries(activity, "reactionsRemoved")
        reaction isa AbstractDict || continue
        reaction_name = _string_or_empty(get(() -> "", reaction, "type"))
        isempty(reaction_name) && continue
        push!(out, MSTeamsReactionEvent(ch, reaction_name, user_name, "removed"))
    end

    return out
end

function _activity_to_events(activity::AbstractDict, client::MSTeams.BotClient)
    events = Claw.ChannelEvent[]

    message_event = _message_activity_to_event(activity, client)
    message_event !== nothing && push!(events, message_event)

    append!(events, _reaction_activity_to_events(activity, client))
    return events
end

Claw.event_source_tag(::MSTeamsMessageEvent) = "msteams"
Claw.event_source_tag(::MSTeamsReactionEvent) = "msteams"

# Bot Framework activity ids are unique per delivery.
function _msteams_dedup_key(activity::AbstractDict, event)
    id = _string_or_empty(get(() -> "", activity, "id"))
    isempty(id) && return nothing
    if event isa MSTeamsReactionEvent
        return "msteams:$(id):reaction:$(event.action):$(event.reaction)"
    end
    return "msteams:$(id):message"
end

# ─── start! ───

function Claw.validate_source(source::MSTeamsEventSource)
    isempty(strip(source.app_id)) && error("ClawMSTeamsExt: missing MSTEAMS_APP_ID")
    isempty(strip(source.app_password)) && error("ClawMSTeamsExt: missing MSTEAMS_APP_PASSWORD")
    # Fail closed (§2.1): unauthenticated + reachable is the combination that turns
    # any POST into an evaluated "user message" with the owner's full tool set.
    if !source.verify_jwt && !Claw.is_loopback_host(source.host)
        error("ClawMSTeamsExt: refusing to bind $(source.host):$(source.port) with " *
              "verify_jwt = false. Inbound Bot Framework JWT validation is the only thing " *
              "distinguishing a real Teams activity from anyone who can reach the port. " *
              "Either leave verify_jwt = true, or bind 127.0.0.1 and put an authenticating " *
              "proxy in front.")
    end
    return nothing
end

"""
    _authenticating_handler(inner, source, keys) -> Function

Wrap MSTeams.jl's own routing with the §2.1 inbound check. Only POSTs to the
activity path are gated; the health endpoint and 404/405 routing stay exactly as
MSTeams.jl defines them.

This exists because `run_server`'s callback receives the parsed activity and nothing
else — the `Authorization` header never reaches it, so the check cannot live inside
the callback. Serving here and delegating to `build_server_handler` gets the header
without needing an upstream change, and guarantees the check runs *before* any event
is created.
"""
function _authenticating_handler(inner::Function, source::MSTeamsEventSource, keys::BotFrameworkKeys)
    activity_path = String(source.path)
    return function (req::HTTP.Request)
        method = uppercase(String(req.method))
        req_path = String(HTTP.URI(req.target).path)
        if method == "POST" && req_path == activity_path
            ok, reason = _bf_authorize(req, source, keys)
            if !ok
                @warn "ClawMSTeamsExt: rejected unauthenticated activity" reason maxlog = 50
                return HTTP.Response(401, ["WWW-Authenticate" => "Bearer"], "unauthorized")
            end
        end
        return inner(req)
    end
end

function Claw.start!(source::MSTeamsEventSource, assistant::Claw.AgentAssistant)
    app_id = strip(source.app_id)
    app_password = strip(source.app_password)
    isempty(app_id) && error("ClawMSTeamsExt: missing MSTEAMS_APP_ID")
    isempty(app_password) && error("ClawMSTeamsExt: missing MSTEAMS_APP_PASSWORD")
    Claw.validate_source(source)

    errormonitor(Threads.@spawn begin
        client = MSTeams.BotClient(; app_id=app_id, app_password=app_password)
        Claw.register_rehydrator!("msteams", Claw.channel_lookup_rehydrator)
        routed = MSTeams.build_server_handler(; client=client, path=source.path, health_path=source.health_path) do activity
            for event in _activity_to_events(activity, client)
                if event isa MSTeamsMessageEvent
                    ch = event.channel
                    @info "ClawMSTeamsExt: message" conversation_id=ch.conversation_id user_id=ch.user_id direct_ping=event.direct_ping
                elseif event isa MSTeamsReactionEvent
                    ch = event.channel
                    @info "ClawMSTeamsExt: reaction" conversation_id=ch.conversation_id user_id=ch.user_id reaction=event.reaction action=event.action
                end
                Claw.submit_event!(assistant, event; dedup_key = _msteams_dedup_key(activity, event))
            end
            return nothing
        end
        handler = routed
        if source.verify_jwt
            keys = BotFrameworkKeys(source.openid_config_url)
            # Warm the cache so the first real activity is not the one paying for the
            # fetch; a failure here is non-fatal (and fails closed on every request
            # until a refresh succeeds).
            _bf_refresh_keys!(keys)
            handler = _authenticating_handler(routed, source, keys)
        else
            @warn "ClawMSTeamsExt: inbound JWT validation is DISABLED; every POST to $(source.path) is trusted" host=source.host port=source.port
        end
        @info "ClawMSTeamsExt: Starting webhook server" host=source.host port=source.port path=source.path verify_jwt=source.verify_jwt
        HTTP.serve(handler, source.host, source.port)
    end)
end

end # module ClawMSTeamsExt
