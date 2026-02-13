module AgentifTelegramExt

using Telegram
import Agentif
using Logging

export run_telegram_bot

"""
    run_telegram_bot(handler; use_polling=true, timeout=30, kwargs...)

Start a Telegram bot that listens for incoming messages and calls
`handler(text::String)` for each one, with the appropriate `AbstractChannel`
scoped via `Agentif.with_channel`.
"""
function run_telegram_bot(handler::Function;
        use_polling::Bool = true,
        timeout::Int = 30,
        host::String = "0.0.0.0",
        port::Int = 8080,
        path::String = "/webhook",
        secret_token::Union{String, Nothing} = nothing,
        error_handler::Union{Function, Nothing} = nothing,
        allowed_updates::Union{Vector{String}, Nothing} = nothing)
    if use_polling
        @info "AgentifTelegramExt: Starting polling mode (timeout=$(timeout)s)"
        Telegram.run_polling(update -> _handle_update(handler, update); timeout, allowed_updates, error_handler)
    else
        @info "AgentifTelegramExt: Starting webhook mode (host=$(host), port=$(port), path=$(path))"
        Telegram.run_webhook(update -> _handle_update(handler, update); host, port, path, secret_token, error_handler)
    end
end

# TelegramChannel — streams responses to a Telegram chat
mutable struct TelegramChannel <: Agentif.AbstractChannel
    chat_id::Any
    client::Telegram.Client
    sm::Union{Nothing, Telegram.StreamingMessage}
end
TelegramChannel(chat_id) = TelegramChannel(chat_id, Telegram._get_client(), nothing)

function Agentif.start_streaming(ch::TelegramChannel)
    if ch.sm === nothing
        ch.sm = Telegram.with_client(ch.client) do
            Telegram.send_streaming_message(ch.chat_id)
        end
    end
    return ch.sm
end

function Agentif.append_to_stream(ch::TelegramChannel, sm::Telegram.StreamingMessage, delta::AbstractString)
    Telegram.with_client(ch.client) do
        Telegram.append!(sm, delta)
    end
end

function Agentif.finish_streaming(::TelegramChannel, ::Telegram.StreamingMessage)
    return nothing
end

function Agentif.close_channel(ch::TelegramChannel, sm::Telegram.StreamingMessage)
    Telegram.with_client(ch.client) do
        Telegram.finish!(sm)
    end
    ch.sm = nothing
end

function Agentif.send_message(ch::TelegramChannel, msg)
    Telegram.with_client(ch.client) do
        Telegram.send_message(ch.chat_id, string(msg))
    end
end

function Agentif.channel_id(ch::TelegramChannel)
    return "telegram:$(ch.chat_id)"
end

function _handle_update(handler::Function, update::Telegram.Update)
    @debug "AgentifTelegramExt: Received update" update_id=update.update_id

    msg = update.message
    msg === nothing && return

    text = msg.text
    (text === nothing || isempty(text)) && return

    chat_id = msg.chat.id
    @info "AgentifTelegramExt: Processing message" chat_id=chat_id text_length=length(text)

    try
        ch = TelegramChannel(chat_id)
        Agentif.with_channel(ch) do
            handler(text)
        end
    catch e
        @error "AgentifTelegramExt: handler error" chat_id=chat_id exception=(e, catch_backtrace())
    end
end

end # module AgentifTelegramExt
