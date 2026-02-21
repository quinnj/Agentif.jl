module VoTelegramExt

using Telegram
import Agentif
import Vo

export TelegramEventSource

# ─── Channel ───

mutable struct TelegramChannel <: Agentif.AbstractChannel
    chat_id::Any
    message_id::Union{Nothing, Int64}
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
end

function Agentif.append_to_stream(ch::TelegramChannel, delta::AbstractString)
    sm = ch.sm
    sm === nothing && return
    Telegram.with_client(ch.client) do
        Telegram.append!(sm, delta)
    end
end

Agentif.finish_streaming(::TelegramChannel) = nothing

function Agentif.close_channel(ch::TelegramChannel)
    sm = ch.sm
    sm === nothing && return
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

Agentif.channel_id(ch::TelegramChannel) = "telegram:$(ch.chat_id)"
Agentif.is_group(ch::TelegramChannel) = ch.chat_type in ("group", "supergroup", "channel")
Agentif.is_private(ch::TelegramChannel) = ch.chat_type in ("private", "group")

function Agentif.get_current_user(ch::TelegramChannel)
    isempty(ch.user_id) && return nothing
    return Agentif.ChannelUser(ch.user_id, ch.user_name)
end

function Agentif.create_channel_tools(ch::TelegramChannel)
    chat_id = ch.chat_id
    message_id = ch.message_id
    client = ch.client
    message_id === nothing && return Agentif.AgentTool[]
    react_fn = function react_to_message(emoji::String)
        Telegram.with_client(client) do
            Telegram.set_message_reaction(chat_id, message_id; reaction=emoji)
        end
        return """{"status":"ok","emoji":"$emoji","chat_id":"$chat_id","message_id":$message_id}"""
    end
    react_tool = Agentif.AgentTool{typeof(react_fn), @NamedTuple{emoji::String}}(;
        name = "react_to_message",
        description = "React to the user's message with an emoji instead of (or in addition to) sending a text reply. Use this for simple acknowledgments, approvals, or expressing sentiment without a full response. Common emoji: 👍 👎 ❤️ 🔥 🎉 😂 😢 🤔 👀 ✅",
        func = react_fn,
    )
    return Agentif.AgentTool[react_tool]
end

# ─── Channel Events ───

struct TelegramMessageEvent <: Vo.ChannelEvent
    channel::TelegramChannel
    content::String
    direct_ping::Bool
end

Vo.get_name(::TelegramMessageEvent) = "telegram_message"
Vo.get_channel(ev::TelegramMessageEvent) = ev.channel
function Vo.event_content(ev::TelegramMessageEvent)
    if Agentif.is_group(ev.channel) && !isempty(ev.channel.user_name)
        return "[$(ev.channel.user_name)]: $(ev.content)"
    end
    return ev.content
end
Vo.is_direct_ping(ev::TelegramMessageEvent) = ev.direct_ping

struct TelegramReactionEvent <: Vo.ChannelEvent
    channel::TelegramChannel
    emoji::String
    user_name::String
    message_id::Int64
end

Vo.get_name(::TelegramReactionEvent) = "telegram_reaction"
Vo.get_channel(ev::TelegramReactionEvent) = ev.channel
Vo.is_direct_ping(::TelegramReactionEvent) = true

function Vo.event_content(ev::TelegramReactionEvent)
    return "User '$(ev.user_name)' reacted with $(ev.emoji) to message #$(ev.message_id)"
end

# ─── Event Types & Handlers ───

const MESSAGE_EVENT_TYPE = Vo.EventType("telegram_message", "A new message in a Telegram chat")
const REACTION_EVENT_TYPE = Vo.EventType("telegram_reaction", "An emoji reaction added to a message in Telegram")

const REACTION_HANDLER_PROMPT = """
A user reacted to one of your messages with an emoji. Interpret the reaction and respond appropriately:
- Positive reactions (👍, ❤️, 🔥, 🎉, ✅): Approval. Continue with your current approach.
- Negative reactions (👎, 😢): Disapproval. Stop and ask what to change.
- Other reactions: Acknowledge briefly if appropriate.
Keep your response concise."""

# ─── EventSource ───

struct TelegramEventSource <: Vo.EventSource
    use_polling::Bool
    timeout::Int
    host::String
    port::Int
    path::String
    secret_token::Union{String, Nothing}
end

function TelegramEventSource(;
        use_polling::Bool=true,
        timeout::Int=30,
        host::String="0.0.0.0",
        port::Int=8080,
        path::String="/webhook",
        secret_token::Union{String, Nothing}=nothing,
    )
    TelegramEventSource(use_polling, timeout, host, port, path, secret_token)
end

Vo.get_event_types(::TelegramEventSource) = Vo.EventType[MESSAGE_EVENT_TYPE, REACTION_EVENT_TYPE]

function Vo.get_event_handlers(::TelegramEventSource)
    Vo.EventHandler[
        Vo.EventHandler("telegram_message_default", ["telegram_message"], "", nothing),
        Vo.EventHandler("telegram_reaction_default", ["telegram_reaction"], REACTION_HANDLER_PROMPT, nothing),
    ]
end

# ─── Update handling ───

function _handle_message(update, bot_user_id, bot_username, assistant)
    msg = update.message
    msg === nothing && return

    text = msg.text
    (text === nothing || isempty(text)) && return

    chat_id = msg.chat.id
    chat_type = msg.chat.type !== nothing ? string(msg.chat.type) : "private"
    message_id = msg.message_id

    user_id = ""
    user_name = ""
    if msg.from !== nothing
        from_id = string(msg.from.id)
        from_id == bot_user_id && return
        user_id = from_id
        user_name = msg.from.first_name !== nothing ? string(msg.from.first_name) : ""
        if msg.from.last_name !== nothing
            user_name *= " " * string(msg.from.last_name)
        end
    end

    direct_ping = chat_type == "private" || (!isempty(bot_username) && occursin("@" * bot_username, lowercase(text)))

    @info "VoTelegramExt: message" chat_id message_id direct_ping

    ch = TelegramChannel(chat_id, message_id, Telegram._get_client(), nothing, user_id, user_name, chat_type)
    put!(assistant.event_queue, TelegramMessageEvent(ch, text, direct_ping))
end

function _handle_reaction(update, bot_user_id, assistant)
    reaction = update.message_reaction
    reaction === nothing && return

    chat_id = reaction.chat.id
    message_id = reaction.message_id
    chat_type = reaction.chat.type !== nothing ? string(reaction.chat.type) : "private"

    user_id = ""
    user_name = ""
    if hasproperty(reaction, :user) && reaction.user !== nothing
        from_id = string(reaction.user.id)
        from_id == bot_user_id && return
        user_id = from_id
        user_name = reaction.user.first_name !== nothing ? string(reaction.user.first_name) : ""
        if reaction.user.last_name !== nothing
            user_name *= " " * string(reaction.user.last_name)
        end
    end

    # Extract emoji from new_reaction list
    emoji = ""
    if hasproperty(reaction, :new_reaction) && reaction.new_reaction !== nothing
        for r in reaction.new_reaction
            if hasproperty(r, :emoji) && r.emoji !== nothing
                emoji = string(r.emoji)
                break
            end
        end
    end
    isempty(emoji) && return

    @info "VoTelegramExt: reaction" emoji chat_id message_id user_id

    ch = TelegramChannel(chat_id, message_id, Telegram._get_client(), nothing, user_id, user_name, chat_type)
    put!(assistant.event_queue, TelegramReactionEvent(ch, emoji, user_name, message_id))
end

function _handle_update(update, bot_user_id::String, bot_username::String, assistant::Vo.AgentAssistant)
    _handle_message(update, bot_user_id, bot_username, assistant)
    _handle_reaction(update, bot_user_id, assistant)
end

# ─── start! ───

function Vo.start!(source::TelegramEventSource, assistant::Vo.AgentAssistant)
    errormonitor(Threads.@spawn begin
        Telegram.with_telegram(ENV["TELEGRAM_BOT_TOKEN"]) do
            me = Telegram.get_me()
            bot_user_id = string(me.id)
            bot_username = me.username !== nothing ? lowercase(string(me.username)) : ""
            @info "VoTelegramExt: Bot user: @$(bot_username) ($(bot_user_id))"

            if source.use_polling
                @info "VoTelegramExt: Starting polling mode (timeout=$(source.timeout)s)"
                Telegram.run_polling(
                    update -> _handle_update(update, bot_user_id, bot_username, assistant);
                    timeout=source.timeout,
                    allowed_updates=["message", "message_reaction"],
                )
            else
                @info "VoTelegramExt: Starting webhook mode ($(source.host):$(source.port)$(source.path))"
                Telegram.run_webhook(
                    update -> _handle_update(update, bot_user_id, bot_username, assistant);
                    host=source.host, port=source.port, path=source.path,
                    secret_token=source.secret_token,
                    allowed_updates=["message", "message_reaction"],
                )
            end
        end
    end)
end

end # module VoTelegramExt
