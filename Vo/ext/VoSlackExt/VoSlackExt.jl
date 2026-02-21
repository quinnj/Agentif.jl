module VoSlackExt

using Slack
using Slack: JSON
import Agentif
import Vo

export SlackEventSource

# ─── Channel ───

mutable struct SlackChannel <: Agentif.AbstractChannel
    channel::String
    thread_ts::String
    post_ts::String
    web_client::Slack.WebClient
    sm::Union{Nothing, Slack.ChatStream}
    io::Union{Nothing, IOBuffer}
    user_id::String
    user_name::String
    # "channel" = public, "group" = private channel, "im" = DM, "mpim" = multi-party DM
    channel_type::String
    recipient_team_id::Union{Nothing, String}
    recipient_user_id::Union{Nothing, String}
end

const STREAM_BUFFER_SIZE = 32

function Agentif.start_streaming(ch::SlackChannel)
    if ch.sm === nothing && ch.io === nothing
        if !isempty(ch.thread_ts) && ch.recipient_team_id !== nothing && ch.recipient_user_id !== nothing
            ch.sm = Slack.ChatStream(ch.web_client;
                channel=ch.channel,
                thread_ts=ch.thread_ts,
                buffer_size=STREAM_BUFFER_SIZE,
                recipient_team_id=ch.recipient_team_id,
                recipient_user_id=ch.recipient_user_id,
            )
        else
            ch.io = IOBuffer()
        end
    end
end

function Agentif.append_to_stream(ch::SlackChannel, delta::AbstractString)
    sm = ch.sm
    if sm !== nothing
        Slack.append!(sm; markdown_text=String(delta))
        return
    end
    io = ch.io
    io === nothing && return
    write(io, String(delta))
end

function Agentif.finish_streaming(ch::SlackChannel)
    sm = ch.sm
    if sm !== nothing && !isempty(sm.buffer)
        Slack.flush_buffer!(sm)
    end
    return nothing
end

function Agentif.close_channel(ch::SlackChannel)
    sm = ch.sm
    if sm !== nothing
        if sm.state != "completed"
            Slack.stop!(sm)
        end
        ch.sm = nothing
        return
    end

    io = ch.io
    io === nothing && return
    text = String(take!(io))
    if !isempty(text)
        Agentif.send_message(ch, text)
    end
    ch.io = nothing
end

function Agentif.send_message(ch::SlackChannel, msg)
    if isempty(ch.thread_ts)
        Slack.chat_post_message(ch.web_client; channel=ch.channel, text=string(msg))
    else
        Slack.chat_post_message(ch.web_client; channel=ch.channel, text=string(msg), thread_ts=ch.thread_ts)
    end
end

function Agentif.channel_id(ch::SlackChannel)
    base = "slack:$(ch.channel)"
    return isempty(ch.thread_ts) ? base : "$(base):$(ch.thread_ts)"
end

Agentif.is_group(ch::SlackChannel) = ch.channel_type in ("channel", "group", "mpim")
Agentif.is_private(ch::SlackChannel) = ch.channel_type != "channel"

function Agentif.get_current_user(ch::SlackChannel)
    isempty(ch.user_id) && return nothing
    return Agentif.ChannelUser(ch.user_id, ch.user_name)
end

Agentif.source_message_id(ch::SlackChannel) = isempty(ch.post_ts) ? nothing : ch.post_ts

# ─── Channel Events ───

struct SlackMessageEvent <: Vo.ChannelEvent
    channel::SlackChannel
    content::String
    direct_ping::Bool
end

Vo.get_name(::SlackMessageEvent) = "slack_message"
Vo.get_channel(ev::SlackMessageEvent) = ev.channel
function Vo.event_content(ev::SlackMessageEvent)
    if Agentif.is_group(ev.channel) && !isempty(ev.channel.user_name)
        return "[$(ev.channel.user_name)]: $(ev.content)"
    end
    return ev.content
end

struct SlackReactionEvent <: Vo.ChannelEvent
    channel::SlackChannel
    emoji::String
    user_name::String
    reacted_to_ts::String
end

Vo.get_name(::SlackReactionEvent) = "slack_reaction"
Vo.get_channel(ev::SlackReactionEvent) = ev.channel

function Vo.event_content(ev::SlackReactionEvent)
    lines = ["User '$(ev.user_name)' reacted with :$(ev.emoji):"]
    !isempty(ev.reacted_to_ts) && push!(lines, "Reacted to message timestamp $(ev.reacted_to_ts)")
    return join(lines, "\n")
end

# ─── Event Types & Handlers ───

const MESSAGE_EVENT_TYPE = Vo.EventType("slack_message", "A new message in a Slack conversation")
const REACTION_EVENT_TYPE = Vo.EventType("slack_reaction", "An emoji reaction added to a Slack message")

const REACTION_HANDLER_PROMPT = """
A user reacted to one of your messages with an emoji. Interpret the reaction and respond appropriately:
- Positive reactions (thumbsup, white_check_mark, heart, +1): Approval. Continue with your current approach.
- Negative reactions (thumbsdown, x, -1): Disapproval. Stop and ask what to change.
- Other reactions: Acknowledge briefly if appropriate.
Keep your response concise."""

# ─── EventSource ───

Base.@kwdef struct SlackEventSource <: Vo.EventSource
    app_token::String = get(ENV, "SLACK_APP_TOKEN", "")
    bot_token::String = get(ENV, "SLACK_BOT_TOKEN", "")
    bot_user_id::String = get(ENV, "SLACK_BOT_USER_ID", "")
    bot_username::String = get(ENV, "SLACK_BOT_USERNAME", "")
    recipient_team_id::String = get(ENV, "SLACK_STREAM_RECIPIENT_TEAM_ID", "")
    recipient_user_id::String = get(ENV, "SLACK_STREAM_RECIPIENT_USER_ID", "")
end

Vo.get_event_types(::SlackEventSource) = Vo.EventType[MESSAGE_EVENT_TYPE, REACTION_EVENT_TYPE]

function Vo.get_event_handlers(::SlackEventSource)
    Vo.EventHandler[
        Vo.EventHandler("slack_message_default", ["slack_message"], "", nothing),
        Vo.EventHandler("slack_reaction_default", ["slack_reaction"], REACTION_HANDLER_PROMPT, nothing),
    ]
end

# ─── Request handling ───

_string_or_empty(x) = x === nothing ? "" : String(x)

function _normalize_channel_type(raw::String)
    value = lowercase(strip(raw))
    isempty(value) && return ""
    value == "private_channel" && return "group"
    value == "dm" && return "im"
    return value
end

function _infer_channel_type(channel::String)
    isempty(channel) && return "channel"
    first_char = first(channel)
    first_char == 'C' && return "channel"
    first_char == 'D' && return "im"
    first_char == 'G' && return "group"
    return "channel"
end

function _channel_type_from_info(channel_info)
    channel_info isa AbstractDict || return nothing
    get(() -> false, channel_info, "is_im") == true && return "im"
    get(() -> false, channel_info, "is_mpim") == true && return "mpim"
    get(() -> false, channel_info, "is_group") == true && return "group"
    if get(() -> false, channel_info, "is_channel") == true
        return get(() -> false, channel_info, "is_private") == true ? "group" : "channel"
    end
    get(() -> false, channel_info, "is_private") == true && return "group"
    return nothing
end

function _resolve_channel_type(channel::String, raw_type::String, web_client::Slack.WebClient, channel_type_cache::Dict{String, String})
    cached = get(() -> "", channel_type_cache, channel)
    !isempty(cached) && return cached

    normalized = _normalize_channel_type(raw_type)
    inferred = isempty(normalized) ? _infer_channel_type(channel) : normalized
    if inferred == "im"
        channel_type_cache[channel] = inferred
        return inferred
    end

    needs_metadata_lookup = isempty(normalized) || normalized in ("channel", "group")
    if !needs_metadata_lookup
        channel_type_cache[channel] = inferred
        return inferred
    end

    resolved = inferred
    try
        info_response = Slack.conversations_info(web_client; channel=channel)
        channel_info = get(() -> nothing, info_response, "channel")
        inferred_info = _channel_type_from_info(channel_info)
        inferred_info !== nothing && (resolved = inferred_info)
    catch e
        @debug "VoSlackExt: failed to resolve channel metadata" channel exception=e
    end
    channel_type_cache[channel] = resolved
    return resolved
end

function _payload_event(payload)
    if payload isa Slack.SlackEventsApiPayload
        return payload.event
    elseif payload isa AbstractDict
        return get(() -> nothing, payload, "event")
    end
    return nothing
end

function _event_type(event)
    if event isa Slack.SlackAppMentionEvent
        return event.type === nothing ? "app_mention" : String(event.type)
    elseif event isa Slack.SlackMessageEvent
        return event.type === nothing ? "message" : String(event.type)
    elseif event isa AbstractDict
        return _string_or_empty(get(() -> "", event, "type"))
    end
    return ""
end

function _extract_message_event(event, web_client::Slack.WebClient, bot_user_id::String, bot_username::String,
        recipient_team_id::Union{Nothing, String}, recipient_user_id::Union{Nothing, String},
        channel_type_cache::Dict{String, String}=Dict{String, String}())
    event === nothing && return nothing
    event_type = _event_type(event)
    (event_type == "message" || event_type == "app_mention") || return nothing

    text = ""
    channel = ""
    thread_ts = ""
    ts = ""
    subtype = ""
    bot_id = ""
    user_id = ""
    channel_type = ""

    if event isa Slack.SlackAppMentionEvent
        text = _string_or_empty(event.text)
        channel = _string_or_empty(event.channel)
        thread_ts = _string_or_empty(event.thread_ts)
        ts = _string_or_empty(event.ts)
        user_id = _string_or_empty(event.user)
    elseif event isa Slack.SlackMessageEvent
        text = _string_or_empty(event.text)
        channel = _string_or_empty(event.channel)
        thread_ts = _string_or_empty(event.thread_ts)
        ts = _string_or_empty(event.ts)
        subtype = _string_or_empty(event.subtype)
        bot_id = _string_or_empty(event.bot_id)
        user_id = _string_or_empty(event.user)
        channel_type = _string_or_empty(event.channel_type)
    elseif event isa AbstractDict
        text = _string_or_empty(get(() -> "", event, "text"))
        channel = _string_or_empty(get(() -> "", event, "channel"))
        thread_ts = _string_or_empty(get(() -> "", event, "thread_ts"))
        ts = _string_or_empty(get(() -> "", event, "ts"))
        subtype = _string_or_empty(get(() -> "", event, "subtype"))
        bot_id = _string_or_empty(get(() -> "", event, "bot_id"))
        user_id = _string_or_empty(get(() -> "", event, "user"))
        channel_type = _string_or_empty(get(() -> "", event, "channel_type"))
    else
        return nothing
    end

    isempty(channel) && return nothing
    isempty(text) && return nothing
    isempty(ts) && return nothing
    !isempty(subtype) && return nothing
    !isempty(bot_id) && return nothing
    !isempty(bot_user_id) && lowercase(user_id) == lowercase(bot_user_id) && return nothing
    isempty(thread_ts) && (thread_ts = ts)
    channel_type = _resolve_channel_type(channel, channel_type, web_client, channel_type_cache)

    mention_token = isempty(bot_user_id) ? "" : "<@" * lowercase(bot_user_id) * ">"
    lower_text = lowercase(text)
    direct_ping = event_type == "app_mention" ||
        channel_type == "im" ||
        (!isempty(mention_token) && occursin(mention_token, lower_text)) ||
        (!isempty(bot_username) && occursin("@" * lowercase(bot_username), lower_text))

    user_name = user_id
    ch = SlackChannel(channel, thread_ts, ts, web_client, nothing, nothing, user_id, user_name, channel_type, recipient_team_id, recipient_user_id)
    return SlackMessageEvent(ch, text, direct_ping)
end

function _extract_reaction_event(event, web_client::Slack.WebClient, bot_user_id::String,
        recipient_team_id::Union{Nothing, String}, recipient_user_id::Union{Nothing, String},
        channel_type_cache::Dict{String, String}=Dict{String, String}())
    event isa AbstractDict || return nothing
    _event_type(event) == "reaction_added" || return nothing

    emoji = _string_or_empty(get(() -> "", event, "reaction"))
    user_id = _string_or_empty(get(() -> "", event, "user"))
    !isempty(bot_user_id) && lowercase(user_id) == lowercase(bot_user_id) && return nothing

    item = get(() -> nothing, event, "item")
    item isa AbstractDict || return nothing
    _string_or_empty(get(() -> "", item, "type")) == "message" || return nothing

    channel = _string_or_empty(get(() -> "", item, "channel"))
    reacted_to_ts = _string_or_empty(get(() -> "", item, "ts"))
    if isempty(channel) || isempty(emoji) || isempty(reacted_to_ts)
        return nothing
    end

    channel_type = _resolve_channel_type(channel, "", web_client, channel_type_cache)
    user_name = user_id
    ch = SlackChannel(channel, reacted_to_ts, reacted_to_ts, web_client, nothing, nothing, user_id, user_name, channel_type, recipient_team_id, recipient_user_id)
    return SlackReactionEvent(ch, emoji, user_name, reacted_to_ts)
end

function _handle_request(request::Slack.SocketModeRequest, web_client::Slack.WebClient, bot_user_id::String, bot_username::String,
        recipient_team_id::Union{Nothing, String}, recipient_user_id::Union{Nothing, String},
        assistant::Vo.AgentAssistant, channel_type_cache::Dict{String, String}=Dict{String, String}())
    request.type == "events_api" || return
    payload = request.payload
    payload === nothing && return
    event = _payload_event(payload)
    event === nothing && return
    event_type = _event_type(event)

    message_event = _extract_message_event(event, web_client, bot_user_id, bot_username, recipient_team_id, recipient_user_id, channel_type_cache)
    if message_event !== nothing
        ch = message_event.channel
        @info "VoSlackExt: message" channel=ch.channel thread_ts=ch.thread_ts user_id=ch.user_id direct_ping=message_event.direct_ping event_type
        put!(assistant.event_queue, message_event)
    end

    reaction_event = _extract_reaction_event(event, web_client, bot_user_id, recipient_team_id, recipient_user_id, channel_type_cache)
    if reaction_event !== nothing
        ch = reaction_event.channel
        @info "VoSlackExt: reaction" channel=ch.channel thread_ts=ch.thread_ts emoji=reaction_event.emoji user_id=ch.user_id
        put!(assistant.event_queue, reaction_event)
    end

    return nothing
end

# ─── start! ───

function Vo.start!(source::SlackEventSource, assistant::Vo.AgentAssistant)
    app_token = strip(source.app_token)
    bot_token = strip(source.bot_token)
    isempty(app_token) && error("VoSlackExt: missing SLACK_APP_TOKEN")
    isempty(bot_token) && error("VoSlackExt: missing SLACK_BOT_TOKEN")

    errormonitor(Threads.@spawn begin
        web_client = Slack.WebClient(; token=bot_token)
        channel_type_cache = Dict{String, String}()
        bot_user_id = string(strip(source.bot_user_id))
        bot_username = lowercase(strip(source.bot_username))
        recipient_team_id = let v = strip(source.recipient_team_id); isempty(v) ? nothing : String(v); end
        recipient_user_id = let v = strip(source.recipient_user_id); isempty(v) ? nothing : String(v); end
        @info "VoSlackExt: Starting Socket Mode"

        Slack.run!(app_token; web_client=web_client) do socket_client, request
            if request.envelope_id !== nothing
                try
                    Slack.ack!(socket_client, request)
                catch e
                    @warn "VoSlackExt: failed to ack request" exception=(e, catch_backtrace())
                end
            end
            _handle_request(request, web_client, bot_user_id, bot_username, recipient_team_id, recipient_user_id, assistant, channel_type_cache)
        end
    end)
end

end # module VoSlackExt
