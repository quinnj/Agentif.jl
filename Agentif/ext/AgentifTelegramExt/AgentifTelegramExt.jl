module AgentifTelegramExt

using Telegram
import Agentif
using Logging
using ScopedValues: @with

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
    # Get bot username for @mention detection in group chats
    bot_username = try
        me = Telegram.get_me()
        me.username !== nothing ? lowercase(string(me.username)) : ""
    catch
        ""
    end
    !isempty(bot_username) && @info "AgentifTelegramExt: Bot username: @$(bot_username)"

    if use_polling
        @info "AgentifTelegramExt: Starting polling mode (timeout=$(timeout)s)"
        Telegram.run_polling(update -> _handle_update(handler, update, bot_username); timeout, allowed_updates, error_handler)
    else
        @info "AgentifTelegramExt: Starting webhook mode (host=$(host), port=$(port), path=$(path))"
        Telegram.run_webhook(update -> _handle_update(handler, update, bot_username); host, port, path, secret_token, error_handler)
    end
end

# TelegramChannel — streams responses to a Telegram chat
mutable struct TelegramChannel <: Agentif.AbstractChannel
    chat_id::Any
    client::Telegram.Client
    sm::Union{Nothing, Telegram.StreamingMessage}
    user_id::String
    user_name::String
    # "private" = DM, "group" = basic group, "supergroup" = large/public group, "channel" = broadcast
    chat_type::String
end

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

function Agentif.is_group(ch::TelegramChannel)
    return ch.chat_type in ("group", "supergroup", "channel")
end

function Agentif.is_private(ch::TelegramChannel)
    # "private" = DM (private), "group" = basic group (private)
    # "supergroup" and "channel" are treated as potentially public
    return ch.chat_type in ("private", "group")
end

function Agentif.get_current_user(ch::TelegramChannel)
    isempty(ch.user_id) && return nothing
    return Agentif.ChannelUser(ch.user_id, ch.user_name)
end

function _handle_update(handler::Function, update::Telegram.Update, bot_username::String="")
    @debug "AgentifTelegramExt: Received update" update_id=update.update_id

    msg = update.message
    msg === nothing && return

    text = msg.text
    (text === nothing || isempty(text)) && return

    chat_id = msg.chat.id
    chat_type = msg.chat.type !== nothing ? string(msg.chat.type) : "private"

    # Extract user identity
    user_id = ""
    user_name = ""
    if msg.from !== nothing
        user_id = string(msg.from.id)
        user_name = msg.from.first_name !== nothing ? string(msg.from.first_name) : ""
        if msg.from.last_name !== nothing
            user_name *= " " * string(msg.from.last_name)
        end
    end

    # Detect direct ping: private chat or @bot_username mention in group
    direct_ping = chat_type == "private" || (!isempty(bot_username) && occursin("@" * bot_username, lowercase(text)))

    @info "AgentifTelegramExt: Processing message" chat_id=chat_id chat_type=chat_type user_id=user_id direct_ping=direct_ping text_length=length(text)

    try
        ch = TelegramChannel(chat_id, Telegram._get_client(), nothing, user_id, user_name, chat_type)
        Agentif.with_channel(ch) do
            @with Agentif.DIRECT_PING => direct_ping handler(text)
        end
    catch e
        @error "AgentifTelegramExt: handler error" chat_id=chat_id exception=(e, catch_backtrace())
    end
end

end # module AgentifTelegramExt
