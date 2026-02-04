module VoTelegramExt

using Vo
using Telegram
import Agentif
using Logging

"""
    Vo.run_telegram_bot(; use_polling=true, timeout=30, kwargs...)

Start a Telegram bot that forwards incoming messages to the current Vo
`AgentAssistant` and streams responses back via Telegram's `editMessageText`.

Requires both `Vo` and `Telegram` to be loaded, and a Telegram client to be
active (via `Telegram.with_telegram`).

With `use_polling=true` (default), uses long-polling via `getUpdates`.
Set `use_polling=false` for webhook mode (call `Telegram.set_webhook` first).

# Example
```julia
using Vo, Telegram

Telegram.with_telegram(ENV["TELEGRAM_BOT_TOKEN"]) do
    Vo.run_telegram_bot()
end
```
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
    # Check if assistant is set before starting
    assistant = Vo.get_current_assistant()
    if assistant === nothing
        @warn "VoTelegramExt: No assistant is currently active. Create one with `Vo.AgentAssistant()` before running the bot."
        @info "VoTelegramExt: Example usage:" 
        @info "  using Vo, Telegram"
        @info "  assistant = Vo.AgentAssistant()"
        @info "  Telegram.with_telegram(ENV[\"TELEGRAM_BOT_TOKEN\"]) do"
        @info "      Vo.run_telegram_bot()"
        @info "  end"
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
        @warn "VoTelegramExt: No assistant active, sending error message" chat_id=chat_id
        Telegram.send_message(chat_id, "No assistant is currently active. Please create an assistant first with `Vo.AgentAssistant()`.")
        return
    end

    @debug "VoTelegramExt: Starting evaluation" chat_id=chat_id assistant_provider=assistant.config.provider
    sm = Telegram.send_streaming_message(chat_id)
    try
        Vo.evaluate(assistant, text) do event
            if event isa Agentif.MessageUpdateEvent && event.kind == :text
                Telegram.append!(sm, event.delta)
            end
        end
        @debug "VoTelegramExt: Evaluation completed" chat_id=chat_id
    catch e
        @error "VoTelegramExt: evaluation error" chat_id=chat_id exception=(e, catch_backtrace())
        sm.buffer = "Sorry, an error occurred while processing your message."
    finally
        try
            Telegram.finish!(sm)
        catch e
            @error "VoTelegramExt: Error finishing streaming message" chat_id=chat_id exception=(e, catch_backtrace())
        end
    end
end

end # module VoTelegramExt
