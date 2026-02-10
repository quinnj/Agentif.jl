module VoTelegramExt

using Vo
using Telegram
import Agentif
using Logging

"""
    Vo.run_telegram_bot(; use_polling=true, timeout=30, kwargs...)

Start a Telegram bot that forwards incoming messages to the current Vo
`AgentAssistant` and streams responses back via Telegram's `editMessageText`.
"""
function Vo.run_telegram_bot(;
        use_polling::Bool = true,
        timeout::Int = 30,
        host::String = "0.0.0.0",
        port::Int = 8080,
        path::String = "/webhook",
        secret_token::Union{String, Nothing} = nothing,
        error_handler::Union{Function, Nothing} = nothing,
        allowed_updates::Union{Vector{String}, Nothing} = nothing)
    assistant = Vo.get_current_assistant()
    if assistant === nothing
        @warn "VoTelegramExt: No assistant is currently active."
    else
        @info "VoTelegramExt: Starting bot with assistant (provider=$(assistant.config.provider), model=$(assistant.config.model_id))"
    end

    if use_polling
        @info "VoTelegramExt: Starting polling mode (timeout=$(timeout)s)"
        Telegram.run_polling(_handle_update; timeout, allowed_updates, error_handler)
    else
        @info "VoTelegramExt: Starting webhook mode (host=$(host), port=$(port), path=$(path))"
        Telegram.run_webhook(_handle_update; host, port, path, secret_token, error_handler)
    end
end

# TelegramChannel — streams responses to a Telegram chat
mutable struct TelegramChannel <: Agentif.AbstractChannel
    chat_id::Any
    sm::Union{Nothing, Telegram.StreamingMessage}
end
TelegramChannel(chat_id) = TelegramChannel(chat_id, nothing)

function Agentif.start_streaming(ch::TelegramChannel)
    if ch.sm === nothing
        ch.sm = Telegram.send_streaming_message(ch.chat_id)
    end
    return ch.sm
end

function Agentif.append_to_stream(::TelegramChannel, sm::Telegram.StreamingMessage, delta::AbstractString)
    Telegram.append!(sm, delta)
end

function Agentif.finish_streaming(::TelegramChannel, ::Telegram.StreamingMessage)
    return nothing
end

function Agentif.close_channel(ch::TelegramChannel, sm::Telegram.StreamingMessage)
    Telegram.finish!(sm)
    ch.sm = nothing
end

function Agentif.send_message(ch::TelegramChannel, msg)
    Telegram.send_message(ch.chat_id, string(msg))
end

# Channel ID for session mapping — Vo.channel_id dispatch
function Vo.channel_id(ch::TelegramChannel)
    return "telegram:$(ch.chat_id)"
end

function _handle_update(update::Telegram.Update)
    @debug "VoTelegramExt: Received update" update_id=update.update_id

    msg = update.message
    if msg === nothing
        @debug "VoTelegramExt: Update has no message, skipping"
        return
    end

    text = msg.text
    if text === nothing || isempty(text)
        @debug "VoTelegramExt: Message has no text, skipping" chat_id=msg.chat.id
        return
    end

    chat_id = msg.chat.id
    @info "VoTelegramExt: Processing message" chat_id=chat_id text_length=length(text)

    assistant = Vo.get_current_assistant()
    if assistant === nothing
        @warn "VoTelegramExt: No assistant active" chat_id=chat_id
        Telegram.send_message(chat_id, "No assistant is currently active.")
        return
    end

    try
        ch = TelegramChannel(chat_id)
        Vo.evaluate(assistant, text; channel=ch)
    catch e
        @error "VoTelegramExt: evaluation error" chat_id=chat_id exception=(e, catch_backtrace())
    end
end

end # module VoTelegramExt
