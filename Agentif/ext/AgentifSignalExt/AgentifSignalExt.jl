module AgentifSignalExt

using Signal
import Agentif
using Logging

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
mutable struct SignalChannel <: Agentif.AbstractChannel
    recipient::String
    client::Signal.Client
    sm::Union{Nothing, Signal.StreamingMessage}
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

function _handle_envelope(handler::Function, envelope::Signal.Envelope)
    dm = envelope.dataMessage
    dm === nothing && return

    text = dm.message
    (text === nothing || isempty(text)) && return

    # Determine reply target: group or direct
    recipient = if dm.groupInfo !== nothing && dm.groupInfo.groupId !== nothing
        Signal.group_recipient(dm.groupInfo.groupId)
    else
        source = envelope.sourceNumber !== nothing ? envelope.sourceNumber : envelope.source
        source === nothing && return
        source
    end

    @info "AgentifSignalExt: Processing message" recipient=recipient text_length=length(text)

    try
        ch = SignalChannel(recipient, Signal._get_client(), nothing)
        Agentif.with_channel(ch) do
            handler(text)
        end
    catch e
        @error "AgentifSignalExt: handler error" recipient=recipient exception=(e, catch_backtrace())
    end
end

end # module AgentifSignalExt
