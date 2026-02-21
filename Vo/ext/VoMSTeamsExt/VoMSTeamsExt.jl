module VoMSTeamsExt

using MSTeams
import Agentif
import Vo

export MSTeamsEventSource

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
Agentif.is_group(ch::MSTeamsChannel) = ch.conversation_type != "personal"
Agentif.is_private(ch::MSTeamsChannel) = ch.conversation_type in ("personal", "groupChat")

function Agentif.get_current_user(ch::MSTeamsChannel)
    isempty(ch.user_id) && return nothing
    return Agentif.ChannelUser(ch.user_id, ch.user_name)
end

Agentif.source_message_id(ch::MSTeamsChannel) = isempty(ch.message_id) ? nothing : ch.message_id

# ─── Channel Events ───

struct MSTeamsMessageEvent <: Vo.ChannelEvent
    channel::MSTeamsChannel
    content::String
    direct_ping::Bool
end

Vo.get_name(::MSTeamsMessageEvent) = "msteams_message"
Vo.get_channel(ev::MSTeamsMessageEvent) = ev.channel
function Vo.event_content(ev::MSTeamsMessageEvent)
    if Agentif.is_group(ev.channel) && !isempty(ev.channel.user_name)
        return "[$(ev.channel.user_name)]: $(ev.content)"
    end
    return ev.content
end

struct MSTeamsReactionEvent <: Vo.ChannelEvent
    channel::MSTeamsChannel
    reaction::String
    user_name::String
    action::String
end

Vo.get_name(::MSTeamsReactionEvent) = "msteams_reaction"
Vo.get_channel(ev::MSTeamsReactionEvent) = ev.channel

function Vo.event_content(ev::MSTeamsReactionEvent)
    return "User '$(ev.user_name)' $(ev.action) reaction '$(ev.reaction)'"
end

# ─── Event Types & Handlers ───

const MESSAGE_EVENT_TYPE = Vo.EventType("msteams_message", "A new message activity in Microsoft Teams")
const REACTION_EVENT_TYPE = Vo.EventType("msteams_reaction", "A reaction added or removed in Microsoft Teams")

const REACTION_HANDLER_PROMPT = """
A user reacted to one of your messages. Interpret the reaction and respond appropriately:
- Positive reactions (like, heart, laugh): Approval. Continue with your current approach.
- Negative reactions (sad, angry): Potential disapproval. Ask what should change.
- Other reactions: Acknowledge briefly if appropriate.
Keep your response concise."""

Base.@kwdef struct MSTeamsEventSource <: Vo.EventSource
    app_id::String = get(ENV, "MSTEAMS_APP_ID", "")
    app_password::String = get(ENV, "MSTEAMS_APP_PASSWORD", "")
    host::String = "0.0.0.0"
    port::Int = 3978
    path::String = "/api/messages"
    health_path::String = "/healthz"
end

Vo.get_event_types(::MSTeamsEventSource) = Vo.EventType[MESSAGE_EVENT_TYPE, REACTION_EVENT_TYPE]

function Vo.get_event_handlers(::MSTeamsEventSource)
    Vo.EventHandler[
        Vo.EventHandler("msteams_message_default", ["msteams_message"], "", nothing),
        Vo.EventHandler("msteams_reaction_default", ["msteams_reaction"], REACTION_HANDLER_PROMPT, nothing),
    ]
end

# ─── Activity handling ───

_string_or_empty(x) = x === nothing ? "" : String(x)

function _conversation_info(activity::AbstractDict)
    conversation = get(() -> nothing, activity, "conversation")
    conversation_id = ""
    conversation_type = "personal"

    if conversation !== nothing
        conversation_id = _string_or_empty(get(() -> "", conversation, "id"))
        ct = _string_or_empty(get(() -> "", conversation, "conversationType"))
        if isempty(ct) && get(() -> false, conversation, "isGroup") === true
            ct = "groupChat"
        end
        !isempty(ct) && (conversation_type = ct)
    end

    return conversation_id, conversation_type
end

function _activity_channel(activity::AbstractDict, client::MSTeams.BotClient, user_id::String, user_name::String, message_id::String)
    conversation_id, conversation_type = _conversation_info(activity)
    return MSTeamsChannel(client, activity, user_id, user_name, conversation_id, conversation_type, message_id, nothing)
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
    events = Vo.ChannelEvent[]

    message_event = _message_activity_to_event(activity, client)
    message_event !== nothing && push!(events, message_event)

    append!(events, _reaction_activity_to_events(activity, client))
    return events
end

# ─── start! ───

function Vo.start!(source::MSTeamsEventSource, assistant::Vo.AgentAssistant)
    app_id = strip(source.app_id)
    app_password = strip(source.app_password)
    isempty(app_id) && error("VoMSTeamsExt: missing MSTEAMS_APP_ID")
    isempty(app_password) && error("VoMSTeamsExt: missing MSTEAMS_APP_PASSWORD")

    errormonitor(Threads.@spawn begin
        client = MSTeams.BotClient(; app_id=app_id, app_password=app_password)
        @info "VoMSTeamsExt: Starting webhook server" host=source.host port=source.port path=source.path
        MSTeams.run_server(; host=source.host, port=source.port, client=client, path=source.path, health_path=source.health_path) do activity
            for event in _activity_to_events(activity, client)
                if event isa MSTeamsMessageEvent
                    ch = event.channel
                    @info "VoMSTeamsExt: message" conversation_id=ch.conversation_id user_id=ch.user_id direct_ping=event.direct_ping
                elseif event isa MSTeamsReactionEvent
                    ch = event.channel
                    @info "VoMSTeamsExt: reaction" conversation_id=ch.conversation_id user_id=ch.user_id reaction=event.reaction action=event.action
                end
                put!(assistant.event_queue, event)
            end
            return nothing
        end
    end)
end

end # module VoMSTeamsExt
