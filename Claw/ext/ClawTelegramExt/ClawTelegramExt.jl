module ClawTelegramExt

using Telegram
import Agentif
import Claw

export TelegramEventSource

# ─── Markdown → Telegram MarkdownV2 conversion ───

# Characters that must be escaped outside formatting entities
const _ESCAPE_CHARS = Set("_*[]()~`>#+-=|{}.!")

function _escape_mdv2(text::AbstractString)
    buf = IOBuffer()
    for ch in text
        ch in _ESCAPE_CHARS && write(buf, '\\')
        write(buf, ch)
    end
    return String(take!(buf))
end

"""
    markdown_to_telegramv2(md::AbstractString) -> String

Convert standard markdown (as LLMs produce) to Telegram MarkdownV2 format.
Handles code blocks, inline code, bold, italic, links, headings, and bullet lists.
"""
function markdown_to_telegramv2(md::AbstractString)
    buf = IOBuffer()
    lines = split(md, '\n')
    i = 1
    while i <= length(lines)
        line = lines[i]
        # Fenced code block
        if startswith(lstrip(line), "```")
            lang = strip(replace(lstrip(line), r"^```" => ""))
            write(buf, "```", lang, "\n")
            i += 1
            while i <= length(lines)
                if startswith(lstrip(lines[i]), "```")
                    i += 1
                    break
                end
                # Inside code blocks: escape only ` and \
                cb_line = replace(lines[i], "\\" => "\\\\", "`" => "\\`")
                write(buf, cb_line, "\n")
                i += 1
            end
            write(buf, "```")
            i <= length(lines) && write(buf, "\n")
            continue
        end
        write(buf, _convert_line(line))
        i <= length(lines) && write(buf, "\n")
        i += 1
    end
    return String(take!(buf))
end

function _convert_line(line::AbstractString)
    # Headings → bold (strip inner bold markers since heading is already bold)
    m = match(r"^(#{1,6})\s+(.*)", line)
    if m !== nothing
        content = replace(m[2], r"\*\*(.+?)\*\*" => s"\1")
        return string("*", _format_inline(content), "*")
    end
    # Horizontal rule
    if match(r"^[-*_]{3,}\s*$", line) !== nothing
        return "———"
    end
    # Bullet lists: - or * at start → •
    m = match(r"^(\s*)[-*]\s+(.*)", line)
    if m !== nothing
        indent = _escape_mdv2(m[1])
        return string(indent, "• ", _format_inline(m[2]))
    end
    # Numbered lists: keep number, escape the dot
    m = match(r"^(\s*)(\d+)\.\s+(.*)", line)
    if m !== nothing
        indent = _escape_mdv2(m[1])
        return string(indent, m[2], "\\. ", _format_inline(m[3]))
    end
    return _format_inline(line)
end

# Walk through text identifying markdown inline elements; escape everything else.
function _format_inline(text::AbstractString)
    buf = IOBuffer()
    i = firstindex(text)
    while i <= lastindex(text)
        remaining = SubString(text, i)
        # Inline code: `...`
        m = match(r"^`([^`]+)`", remaining)
        if m !== nothing
            code = replace(m[1], "\\" => "\\\\", "`" => "\\`")
            write(buf, '`', code, '`')
            i += ncodeunits(m.match)
            continue
        end
        # Link: [text](url)
        m = match(r"^\[([^\]]+)\]\(([^)]+)\)", remaining)
        if m !== nothing
            url = replace(m[2], "\\" => "\\\\", ")" => "\\)")
            write(buf, '[', _escape_mdv2(m[1]), "](", url, ')')
            i += ncodeunits(m.match)
            continue
        end
        # Strikethrough: ~~text~~ → ~text~
        m = match(r"^~~(.+?)~~", remaining)
        if m !== nothing
            write(buf, '~', _escape_mdv2(m[1]), '~')
            i += ncodeunits(m.match)
            continue
        end
        # Bold: **text** → *text*
        m = match(r"^\*\*(.+?)\*\*", remaining)
        if m !== nothing
            write(buf, '*', _escape_mdv2(m[1]), '*')
            i += ncodeunits(m.match)
            continue
        end
        # Italic: *text* → _text_ (single asterisk = italic in std markdown, bold in Telegram)
        m = match(r"^\*([^*]+)\*", remaining)
        if m !== nothing
            write(buf, '_', _escape_mdv2(m[1]), '_')
            i += ncodeunits(m.match)
            continue
        end
        # Italic: _text_
        m = match(r"^_([^_]+)_", remaining)
        if m !== nothing
            write(buf, '_', _escape_mdv2(m[1]), '_')
            i += ncodeunits(m.match)
            continue
        end
        # Plain character — escape if needed
        ch = text[i]
        ch in _ESCAPE_CHARS && write(buf, '\\')
        write(buf, ch)
        i = nextind(text, i)
    end
    return String(take!(buf))
end

# ─── Channel ───

mutable struct TelegramChannel <: Agentif.AbstractChannel
    chat_id::Any
    message_id::Union{Nothing, Int64}
    client::Telegram.Client
    buffer::IOBuffer
    user_id::String
    user_name::String
    # "private" = DM, "group" = basic group, "supergroup" = large/public group, "channel" = broadcast
    chat_type::String
end

Agentif.start_streaming(::TelegramChannel) = nothing

function Agentif.append_to_stream(ch::TelegramChannel, delta::AbstractString)
    write(ch.buffer, delta)
end

function Agentif.finish_streaming(ch::TelegramChannel)
    text = String(take!(ch.buffer))
    isempty(text) && return
    _send_mdv2(ch, text)
end

Agentif.close_channel(::TelegramChannel) = nothing

function _send_mdv2(ch::TelegramChannel, text::AbstractString)
    mdv2 = markdown_to_telegramv2(text)
    parts = Telegram.split_message_text(mdv2)
    Telegram.with_client(ch.client) do
        for part in parts
            try
                Telegram.send_message(ch.chat_id, part; parse_mode="MarkdownV2")
            catch e
                # MarkdownV2 parse error — fall back to plain text
                if e isa Telegram.TelegramError
                    @warn "ClawTelegramExt: MarkdownV2 send failed, falling back to plain text" exception=e
                    Telegram.send_message(ch.chat_id, text)
                else
                    rethrow()
                end
                break
            end
        end
    end
end

function Agentif.send_message(ch::TelegramChannel, msg)
    _send_mdv2(ch, string(msg))
end

Agentif.channel_id(ch::TelegramChannel) = "telegram:$(ch.chat_id)"
Agentif.is_group(ch::TelegramChannel) = ch.chat_type in ("group", "supergroup", "channel")
Agentif.is_private(ch::TelegramChannel) = ch.chat_type in ("private", "group")
Agentif.entry_id(ch::TelegramChannel) = ch.message_id === nothing ? nothing : string(ch.message_id)

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

struct TelegramMessageEvent <: Claw.ChannelEvent
    channel::TelegramChannel
    content::String
    direct_ping::Bool
end

Claw.get_name(::TelegramMessageEvent) = "telegram_message"
Claw.get_channel(ev::TelegramMessageEvent) = ev.channel
function Claw.event_content(ev::TelegramMessageEvent)
    if Agentif.is_group(ev.channel) && !isempty(ev.channel.user_name)
        return "[$(ev.channel.user_name)]: $(ev.content)"
    end
    return ev.content
end

struct TelegramReactionEvent <: Claw.ChannelEvent
    channel::TelegramChannel
    emoji::String
    user_name::String
    message_id::Int64
end

Claw.get_name(::TelegramReactionEvent) = "telegram_reaction"
Claw.get_channel(ev::TelegramReactionEvent) = ev.channel

function Claw.event_content(ev::TelegramReactionEvent)
    return "User '$(ev.user_name)' reacted with $(ev.emoji) to message #$(ev.message_id)"
end

# ─── Event Types & Handlers ───

const MESSAGE_EVENT_TYPE = Claw.EventType("telegram_message", "A new message in a Telegram chat")
const REACTION_EVENT_TYPE = Claw.EventType("telegram_reaction", "An emoji reaction added to a message in Telegram")

const REACTION_HANDLER_PROMPT = """
A user reacted to one of your messages with an emoji. Interpret the reaction and respond appropriately:
- Positive reactions (👍, ❤️, 🔥, 🎉, ✅): Approval. Continue with your current approach.
- Negative reactions (👎, 😢): Disapproval. Stop and ask what to change.
- Other reactions: Acknowledge briefly if appropriate.
Keep your response concise."""

# ─── EventSource ───

Base.@kwdef mutable struct TelegramEventSource <: Claw.EventSource
    use_polling::Bool = true
    timeout::Int = 30
    host::String = "0.0.0.0"
    port::Int = 8080
    path::String = "/webhook"
    secret_token::Union{String, Nothing} = nothing
    # Runtime state (set during start!)
    client::Union{Nothing, Telegram.Client} = nothing
end

Claw.get_event_types(::TelegramEventSource) = Claw.EventType[MESSAGE_EVENT_TYPE, REACTION_EVENT_TYPE]

function Claw.get_event_handlers(::TelegramEventSource)
    Claw.EventHandler[
        Claw.EventHandler("telegram_message_default", ["telegram_message"], "", nothing),
        Claw.EventHandler("telegram_reaction_default", ["telegram_reaction"], REACTION_HANDLER_PROMPT, nothing),
    ]
end

# ─── Update handling ───

function _handle_message(update, bot_user_id, bot_username, assistant)
    msg = update.message
    if msg === nothing
        @debug "ClawTelegramExt: update has no message field"
        return
    end

    text = msg.text
    if text === nothing || isempty(text)
        @debug "ClawTelegramExt: message has no text" chat_id=msg.chat.id
        return
    end

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

    @info "ClawTelegramExt: message" chat_id message_id direct_ping

    ch = TelegramChannel(chat_id, message_id, Telegram._get_client(), IOBuffer(), user_id, user_name, chat_type)
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

    @info "ClawTelegramExt: reaction" emoji chat_id message_id user_id

    ch = TelegramChannel(chat_id, message_id, Telegram._get_client(), IOBuffer(), user_id, user_name, chat_type)
    put!(assistant.event_queue, TelegramReactionEvent(ch, emoji, user_name, message_id))
end

function _handle_update(update, bot_user_id::String, bot_username::String, assistant::Claw.AgentAssistant)
    @info "ClawTelegramExt: update received" update_id=update.update_id has_message=(update.message !== nothing) has_reaction=(hasproperty(update, :message_reaction) && update.message_reaction !== nothing)
    _handle_message(update, bot_user_id, bot_username, assistant)
    _handle_reaction(update, bot_user_id, assistant)
end

# ─── start! ───

function Claw.start!(source::TelegramEventSource, assistant::Claw.AgentAssistant)
    errormonitor(Threads.@spawn begin
        Telegram.with_telegram(ENV["TELEGRAM_BOT_TOKEN"]) do
            me = Telegram.get_me()
            bot_user_id = string(me.id)
            bot_username = me.username !== nothing ? lowercase(string(me.username)) : ""
            @info "ClawTelegramExt: Bot user: @$(bot_username) ($(bot_user_id))"

            # Store client for on-demand channel construction
            source.client = Telegram._get_client()

            # Seed channels from persisted handler/job channel_ids so that
            # non-ChannelEvents (e.g. JMAP email) can route to Telegram
            # immediately, before any Telegram message arrives.
            seed_channels = Agentif.AbstractChannel[]
            for row in Claw.SQLite.DBInterface.execute(assistant.db,
                "SELECT DISTINCT channel_id FROM claw_event_handlers WHERE channel_id LIKE 'telegram:%'")
                cid = row.channel_id === missing ? "" : String(row.channel_id)
                # Group/supergroup chat ids are negative — the sign must be accepted
                # or persisted group handlers silently resolve to a sink after restart.
                m = match(r"^telegram:(-?\d+)$", cid)
                m !== nothing && push!(seed_channels, TelegramChannel(
                    parse(Int64, m.captures[1]), nothing, source.client, IOBuffer(), "", "", "private"))
            end
            if !isempty(seed_channels)
                Claw.register_channels!(assistant, seed_channels)
                @info "ClawTelegramExt: seeded channels from DB" count=length(seed_channels)
            end

            if source.use_polling
                @info "ClawTelegramExt: Starting polling mode (timeout=$(source.timeout)s)"
                Telegram.run_polling(
                    update -> _handle_update(update, bot_user_id, bot_username, assistant);
                    timeout=source.timeout,
                    allowed_updates=["message", "message_reaction"],
                )
            else
                @info "ClawTelegramExt: Starting webhook mode ($(source.host):$(source.port)$(source.path))"
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

end # module ClawTelegramExt
