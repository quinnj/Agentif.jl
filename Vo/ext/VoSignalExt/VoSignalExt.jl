module VoSignalExt

using Signal
import Agentif
import Vo
export SignalTriggerSource

# === Channel (unchanged from AgentifSignalExt) ===

mutable struct SignalChannel <: Agentif.AbstractChannel
    recipient::String
    client::Signal.Client
    sm::Union{Nothing, Signal.StreamingMessage}
    user_id::String
    user_name::String
    is_group_chat::Bool
end

function Agentif.start_streaming(ch::SignalChannel)
    if ch.sm === nothing
        ch.sm = Signal.with_client(ch.client) do
            Signal.send_streaming_message(ch.recipient)
        end
    end
end

function Agentif.append_to_stream(ch::SignalChannel, delta::AbstractString)
    sm = ch.sm
    sm === nothing && return
    Signal.with_client(ch.client) do
        append!(sm, String(delta))
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

function Agentif.channel_id(ch::SignalChannel)
    return "signal:$(ch.recipient)"
end

function Agentif.is_group(ch::SignalChannel)
    return ch.is_group_chat
end

function Agentif.is_private(ch::SignalChannel)
    return true
end

function Agentif.get_current_user(ch::SignalChannel)
    isempty(ch.user_id) && return nothing
    return Agentif.ChannelUser(ch.user_id, ch.user_name)
end

function _handle_envelope(handler::Function, envelope::Signal.Envelope)
    dm = envelope.dataMessage
    dm === nothing && return

    text = dm.message
    (text === nothing || isempty(text)) && return

    user_id = envelope.sourceNumber !== nothing ? string(envelope.sourceNumber) :
              envelope.source !== nothing ? string(envelope.source) : ""
    user_name = envelope.sourceName !== nothing ? string(envelope.sourceName) : user_id

    is_group_chat = dm.groupInfo !== nothing && dm.groupInfo.groupId !== nothing
    recipient = if is_group_chat
        Signal.group_recipient(dm.groupInfo.groupId)
    else
        isempty(user_id) && return
        user_id
    end

    direct_ping = !is_group_chat

    @info "VoSignalExt: Processing message" recipient=recipient user_id=user_id is_group=is_group_chat direct_ping=direct_ping text_length=length(text)

    Threads.@spawn try
        ch = SignalChannel(recipient, Signal._get_client(), nothing, user_id, user_name, is_group_chat)
        Agentif.with_channel(ch) do
            handler(text)
        end
    catch e
        @error "VoSignalExt: handler error" recipient=recipient exception=(e, catch_backtrace())
    end
end

# === TriggerSource ===

struct SignalTriggerSource <: Vo.TriggerSource
    name::String
    number::String
    base_url::String
end

function SignalTriggerSource(;
        name::String="signal",
        number::AbstractString=ENV["SIGNAL_NUMBER"],
        base_url::AbstractString=get(ENV, "SIGNAL_API_URL", "http://127.0.0.1:8080"),
    )
    SignalTriggerSource(name, String(number), String(base_url))
end

Vo.source_name(s::SignalTriggerSource) = s.name

function Vo.run(handler::Function, source::SignalTriggerSource)
    @info "VoSignalExt: Starting Signal bot" number=source.number base_url=source.base_url
    Signal.with_signal(source.number; base_url=source.base_url) do
        Signal.run_websocket() do envelope
            _handle_envelope(handler, envelope)
        end
    end
end

end # module VoSignalExt
