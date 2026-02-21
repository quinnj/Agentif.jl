module VoSignalExt

using Signal
import Agentif
import Vo

export SignalEventSource

# ─── Channel ───

mutable struct SignalChannel <: Agentif.AbstractChannel
    recipient::String
    client::Signal.Client
    sm::Union{Nothing, Signal.StreamingMessage}
    user_id::String
    user_name::String
    is_group_chat::Bool
    source_timestamp::Union{Nothing, String}
    display_name::String
end

Agentif.start_streaming(::SignalChannel) = nothing

function Agentif.append_to_stream(ch::SignalChannel, delta::AbstractString)
    Signal.with_client(ch.client) do
        if ch.sm === nothing
            ch.sm = Signal.send_streaming_message(ch.recipient, String(delta))
        else
            append!(ch.sm, String(delta))
        end
    end
end

Agentif.finish_streaming(::SignalChannel) = nothing

function Agentif.close_channel(ch::SignalChannel)
    sm = ch.sm
    sm === nothing && return
    Signal.with_client(ch.client) do
        Signal.finish!(sm)
    end
    ch.sm = nothing
end

function Agentif.send_message(ch::SignalChannel, msg)
    Signal.with_client(ch.client) do
        Signal.send_message(ch.recipient, string(msg))
    end
end

Agentif.channel_id(ch::SignalChannel) = "signal:$(ch.recipient)"
Agentif.channel_name(ch::SignalChannel) = isempty(ch.display_name) ? Agentif.channel_id(ch) : ch.display_name
Agentif.is_group(ch::SignalChannel) = ch.is_group_chat
Agentif.is_private(::SignalChannel) = true

function Agentif.get_current_user(ch::SignalChannel)
    isempty(ch.user_id) && return nothing
    return Agentif.ChannelUser(ch.user_id, ch.user_name)
end

Agentif.source_message_id(ch::SignalChannel) = ch.source_timestamp

function Agentif.create_channel_tools(ch::SignalChannel)
    isempty(ch.user_id) && return Agentif.AgentTool[]
    ts_str = ch.source_timestamp
    ts_str === nothing && return Agentif.AgentTool[]
    ts = tryparse(Int64, ts_str)
    ts === nothing && return Agentif.AgentTool[]

    recipient = ch.recipient
    target_author = ch.user_id
    client = ch.client
    react_fn = function react_to_message(emoji::String)
        Signal.with_client(client) do
            Signal.send_reaction(recipient, emoji, target_author, ts)
        end
        return """{"status":"ok","emoji":"$emoji","recipient":"$recipient","timestamp":$ts}"""
    end
    react_tool = Agentif.AgentTool{typeof(react_fn), @NamedTuple{emoji::String}}(;
        name = "react_to_message",
        description = "React to the user's Signal message with an emoji (for quick acknowledgement).",
        func = react_fn,
    )
    return Agentif.AgentTool[react_tool]
end

# ─── Channel Events ───

struct SignalMessageEvent <: Vo.ChannelEvent
    channel::SignalChannel
    content::String
    direct_ping::Bool
end

Vo.get_name(::SignalMessageEvent) = "signal_message"
Vo.get_channel(ev::SignalMessageEvent) = ev.channel
function Vo.event_content(ev::SignalMessageEvent)
    if Agentif.is_group(ev.channel) && !isempty(ev.channel.user_name)
        return "[$(ev.channel.user_name)]: $(ev.content)"
    end
    return ev.content
end

# ─── Event Types & Handlers ───

const MESSAGE_EVENT_TYPE = Vo.EventType("signal_message", "A new Signal message")

Base.@kwdef struct SignalEventSource <: Vo.EventSource
    number::String = get(ENV, "SIGNAL_NUMBER", "")
    base_url::String = get(ENV, "SIGNAL_API_URL", "http://127.0.0.1:8080")
    auto_reconnect::Bool = true
end

Vo.get_event_types(::SignalEventSource) = Vo.EventType[MESSAGE_EVENT_TYPE]

function Vo.get_event_handlers(::SignalEventSource)
    Vo.EventHandler[
        Vo.EventHandler("signal_message_default", ["signal_message"], "", nothing),
    ]
end

# ─── Envelope handling ───

_string_or_empty(x) = x === nothing ? "" : String(x)
_normalize_number(x::String) = replace(x, r"[^0-9+]" => "")

function _envelope_to_message_event(envelope::Signal.Envelope, client::Signal.Client, bot_number::String)
    dm = envelope.dataMessage
    dm === nothing && return nothing

    text = _string_or_empty(dm.message)
    isempty(text) && return nothing

    user_id = envelope.sourceNumber !== nothing ? String(envelope.sourceNumber) : _string_or_empty(envelope.source)
    isempty(user_id) && return nothing
    !isempty(bot_number) && _normalize_number(user_id) == _normalize_number(bot_number) && return nothing

    user_name = envelope.sourceName !== nothing ? String(envelope.sourceName) : user_id

    is_group_chat = dm.groupInfo !== nothing && dm.groupInfo.groupId !== nothing && !isempty(String(dm.groupInfo.groupId))
    recipient = if is_group_chat
        Signal.group_recipient(String(dm.groupInfo.groupId))
    else
        user_id
    end

    source_timestamp = if dm.timestamp !== nothing
        string(dm.timestamp)
    elseif envelope.timestamp !== nothing
        string(envelope.timestamp)
    else
        nothing
    end

    ch = SignalChannel(recipient, client, nothing, user_id, user_name, is_group_chat, source_timestamp, "")
    direct_ping = !is_group_chat
    return SignalMessageEvent(ch, text, direct_ping)
end

# ─── start! ───

function Vo.start!(source::SignalEventSource, assistant::Vo.AgentAssistant)
    number = strip(source.number)
    isempty(number) && error("VoSignalExt: missing SIGNAL_NUMBER")

    errormonitor(Threads.@spawn begin
        Signal.with_signal(number; base_url=source.base_url) do
            client = Signal._get_client()
            @info "VoSignalExt: Starting websocket listener" number=number base_url=source.base_url

            Signal.run_websocket(; auto_reconnect=source.auto_reconnect) do envelope
                event = _envelope_to_message_event(envelope, client, number)
                event === nothing && return
                ch = event.channel
                @info "VoSignalExt: message" recipient=ch.recipient user_id=ch.user_id is_group=ch.is_group_chat direct_ping=event.direct_ping
                put!(assistant.event_queue, event)
            end
        end
    end)
end

end # module VoSignalExt
