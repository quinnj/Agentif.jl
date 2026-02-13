module AgentifSignalExt

using Signal
import Agentif
using Logging
using ScopedValues: @with

export run_signal_bot

"""
    run_signal_bot(handler; number=ENV["SIGNAL_NUMBER"], base_url=ENV["SIGNAL_API_URL"], kwargs...)

Start a Signal bot that listens for incoming messages via WebSocket and calls
`handler(text::String)` for each one, with the appropriate `AbstractChannel`
scoped via `Agentif.with_channel`.

Requires a signal-cli-rest-api instance running in json-rpc mode.
"""
function run_signal_bot(handler::Function;
        number::AbstractString = ENV["SIGNAL_NUMBER"],
        base_url::AbstractString = get(ENV, "SIGNAL_API_URL", "http://127.0.0.1:8080"),
        error_handler::Union{Function, Nothing} = nothing,
        kwargs...)
    @info "AgentifSignalExt: Starting Signal bot" number=number base_url=base_url

    Signal.with_signal(String(number); base_url=String(base_url)) do
        Signal.run_websocket(; error_handler, kwargs...) do envelope
            _handle_envelope(handler, envelope)
        end
    end
end

# SignalChannel — streams responses to a Signal conversation
# Note: Signal has no concept of "public" groups — all groups are private.
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
    return ch.sm
end

function Agentif.append_to_stream(ch::SignalChannel, sm::Signal.StreamingMessage, delta::AbstractString)
    Signal.with_client(ch.client) do
        append!(sm, String(delta))
    end
end

function Agentif.finish_streaming(::SignalChannel, ::Signal.StreamingMessage)
    return nothing
end

function Agentif.close_channel(ch::SignalChannel, sm::Signal.StreamingMessage)
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
    # Signal groups are always private (no public channel concept)
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

    # Extract user identity
    user_id = envelope.sourceNumber !== nothing ? string(envelope.sourceNumber) :
              envelope.source !== nothing ? string(envelope.source) : ""
    user_name = envelope.sourceName !== nothing ? string(envelope.sourceName) : user_id

    # Determine reply target: group or direct
    is_group_chat = dm.groupInfo !== nothing && dm.groupInfo.groupId !== nothing
    recipient = if is_group_chat
        Signal.group_recipient(dm.groupInfo.groupId)
    else
        isempty(user_id) && return
        user_id
    end

    # Detect direct ping: DM (non-group) is always direct; Signal has no @mention concept
    direct_ping = !is_group_chat

    @info "AgentifSignalExt: Processing message" recipient=recipient user_id=user_id is_group=is_group_chat direct_ping=direct_ping text_length=length(text)

    try
        ch = SignalChannel(recipient, Signal._get_client(), nothing, user_id, user_name, is_group_chat)
        Agentif.with_channel(ch) do
            @with Agentif.DIRECT_PING => direct_ping handler(text)
        end
    catch e
        @error "AgentifSignalExt: handler error" recipient=recipient exception=(e, catch_backtrace())
    end
end

end # module AgentifSignalExt
