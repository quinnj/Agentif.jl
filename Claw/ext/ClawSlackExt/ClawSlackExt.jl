module ClawSlackExt

using Slack
using Slack: JSON
import Agentif
import Claw

export SlackEventSource

# ─── Channel ───

const CHAT_POST_MESSAGE_FN = Ref{Function}(Slack.chat_post_message)
const API_CALL_FN = Ref{Function}(Slack.api_call)
const MARKDOWN_BLOCK_MAX_CHARS = 12_000

mutable struct SlackChannel <: Agentif.AbstractChannel
    channel::String
    thread_ts::String
    post_ts::String
    source_ts::String
    web_client::Slack.WebClient
    sm::Union{Nothing, Slack.ChatStream}
    io::Union{Nothing, IOBuffer}
    user_id::String
    user_name::String
    # "channel" = public, "group" = private channel, "im" = DM, "mpim" = multi-party DM
    channel_type::String
    recipient_team_id::Union{Nothing, String}
    recipient_user_id::Union{Nothing, String}
    display_name::String
end

const STREAM_BUFFER_SIZE = 32

function Agentif.start_streaming(ch::SlackChannel)
    if ch.sm === nothing && ch.io === nothing
        requires_recipients = ch.channel_type != "im"
        has_recipients = ch.recipient_team_id !== nothing && ch.recipient_user_id !== nothing
        can_stream = !isempty(ch.thread_ts) && (!requires_recipients || has_recipients)
        if can_stream
            ch.sm = Slack.ChatStream(ch.web_client;
                channel=ch.channel,
                thread_ts=ch.thread_ts,
                buffer_size=STREAM_BUFFER_SIZE,
                recipient_team_id=ch.recipient_team_id,
                recipient_user_id=ch.recipient_user_id,
            )
        else
            ch.io = IOBuffer()
        end
    end
end

function Agentif.append_to_stream(ch::SlackChannel, delta::AbstractString)
    sm = ch.sm
    if sm !== nothing
        Slack.append!(sm; markdown_text=String(delta))
        return
    end
    io = ch.io
    io === nothing && return
    write(io, String(delta))
end

function Agentif.finish_streaming(ch::SlackChannel)
    sm = ch.sm
    if sm !== nothing && !isempty(sm.buffer)
        Slack.flush_buffer!(sm)
    end
    return nothing
end

function Agentif.close_channel(ch::SlackChannel)
    sm = ch.sm
    if sm !== nothing
        if sm.state != "completed"
            Slack.stop!(sm)
        end
        ch.sm = nothing
        return
    end

    io = ch.io
    io === nothing && return
    text = String(take!(io))
    if !isempty(text)
        Agentif.send_message(ch, text)
    end
    ch.io = nothing
end

function Agentif.send_message(ch::SlackChannel, msg)
    text = string(msg)
    isempty(text) && return nothing

    # Prefer Slack's markdown block to preserve LLM markdown output as-is.
    if ncodeunits(text) <= MARKDOWN_BLOCK_MAX_CHARS
        payload = Dict{String, Any}(
            "channel" => ch.channel,
            "text" => text, # accessibility fallback text
            "blocks" => [Dict{String, Any}(
                "type" => "markdown",
                "text" => text,
            )],
        )
        !isempty(ch.thread_ts) && (payload["thread_ts"] = ch.thread_ts)

        try
            response = API_CALL_FN[](ch.web_client, "chat.postMessage"; json=payload)
            _record_post_ts!(ch, response)
            return response
        catch e
            if e isa Slack.SlackApiError
                response = e.response
                code = if response isa Slack.SlackResponse && response.data isa AbstractDict
                    get(() -> "", response.data, "error")
                else
                    ""
                end
                if code == "invalid_blocks" || code == "invalid_arguments" || code == "invalid_json"
                    @warn "ClawSlackExt: markdown blocks rejected by Slack; falling back to mrkdwn text" error=code
                else
                    rethrow()
                end
            else
                rethrow()
            end
        end
    end

    if isempty(ch.thread_ts)
        response = CHAT_POST_MESSAGE_FN[](
            ch.web_client;
            channel=ch.channel,
            text=text,
            mrkdwn=true,
            parse="none",
        )
        _record_post_ts!(ch, response)
        return response
    end
    response = CHAT_POST_MESSAGE_FN[](
        ch.web_client;
        channel=ch.channel,
        text=text,
        thread_ts=ch.thread_ts,
        mrkdwn=true,
        parse="none",
    )
    _record_post_ts!(ch, response)
    return response
end

# A true thread reply has thread_ts set by Slack AND differing from the message's own
# ts. Top-level messages set thread_ts = ts (self-referencing) purely so the bot's
# reply lands in a thread; treating that as a thread gave every top-level DM its own
# empty branch, so "my name is Jacob" and "what's my name?" landed in different
# sessions. Mirrors ClawMattermostExt's `_is_thread`.
_is_thread(ch::SlackChannel) = !isempty(ch.thread_ts) && ch.thread_ts != ch.source_ts

function Agentif.channel_id(ch::SlackChannel)
    base = "slack:$(ch.channel)"
    return _is_thread(ch) ? "$(base):$(ch.thread_ts)" : base
end

function _record_post_ts!(ch::SlackChannel, response)
    response isa AbstractDict || return nothing
    ts = _string_or_empty(get(() -> "", response, "ts"))
    isempty(ts) && return nothing
    ch.post_ts = ts
    return nothing
end

Agentif.channel_name(ch::SlackChannel) = ch.display_name
Agentif.is_group(ch::SlackChannel) = ch.channel_type in ("channel", "group", "mpim")
Agentif.is_private(ch::SlackChannel) = ch.channel_type != "channel"

function Agentif.get_current_user(ch::SlackChannel)
    isempty(ch.user_id) && return nothing
    return Agentif.ChannelUser(ch.user_id, ch.user_name)
end

Agentif.entry_id(ch::SlackChannel) = isempty(ch.source_ts) ? nothing : ch.source_ts
Agentif.response_entry_id(ch::SlackChannel) = isempty(ch.post_ts) ? nothing : ch.post_ts
Agentif.parent_branch_id(ch::SlackChannel) = _is_thread(ch) ? "slack:$(ch.channel)" : nothing
Agentif.branch_entry_id(ch::SlackChannel) = _is_thread(ch) ? ch.thread_ts : nothing
Agentif.search_channel_id(ch::SlackChannel) = "slack:$(ch.channel)"

function Agentif.create_channel_tools(ch::SlackChannel)
    ts = ch.source_ts
    channel = ch.channel
    web_client = ch.web_client
    (isempty(ts) || isempty(channel)) && return Agentif.AgentTool[]
    react_fn = function react_to_message(emoji_name::String)
        API_CALL_FN[](web_client, "reactions.add";
            json=Dict("channel" => channel, "timestamp" => ts, "name" => emoji_name))
        return """{"status":"ok","emoji":"$emoji_name","channel":"$channel","timestamp":"$ts"}"""
    end
    react_tool = Agentif.AgentTool{typeof(react_fn), @NamedTuple{emoji_name::String}}(;
        name = "react_to_message",
        description = "React to the user's message with an emoji instead of (or in addition to) sending a text reply. Use this for simple acknowledgments, approvals, or expressing sentiment without a full response. Common emoji names: thumbsup, white_check_mark, eyes, heart, laughing, tada, thinking, thumbsdown, warning, x",
        func = react_fn,
    )
    return Agentif.AgentTool[react_tool]
end

# ─── Channel Events ───

struct SlackMessageEvent <: Claw.ChannelEvent
    channel::SlackChannel
    content::String
    direct_ping::Bool
end

Claw.get_name(::SlackMessageEvent) = "slack_message"
Claw.get_channel(ev::SlackMessageEvent) = ev.channel
function Claw.event_content(ev::SlackMessageEvent)
    if Agentif.is_group(ev.channel) && !isempty(ev.channel.user_name)
        return "[$(ev.channel.user_name)]: $(ev.content)"
    end
    return ev.content
end

struct SlackReactionEvent <: Claw.ChannelEvent
    channel::SlackChannel
    emoji::String
    user_name::String
    reacted_to_ts::String
end

Claw.get_name(::SlackReactionEvent) = "slack_reaction"
Claw.get_channel(ev::SlackReactionEvent) = ev.channel

function Claw.event_content(ev::SlackReactionEvent)
    lines = ["User '$(ev.user_name)' reacted with :$(ev.emoji):"]
    !isempty(ev.reacted_to_ts) && push!(lines, "Reacted to message timestamp $(ev.reacted_to_ts)")
    return join(lines, "\n")
end

Claw.event_source_tag(::SlackMessageEvent) = "slack"
Claw.event_source_tag(::SlackReactionEvent) = "slack"
Claw.event_extra(ev::SlackMessageEvent) = Dict{String, Any}(
    "direct_ping" => ev.direct_ping,
    "user_id" => ev.channel.user_id,
    "user_name" => ev.channel.user_name,
    "channel_type" => ev.channel.channel_type,
    "ts" => ev.channel.source_ts,
)
Claw.event_extra(ev::SlackReactionEvent) = Dict{String, Any}(
    "emoji" => ev.emoji,
    "user_id" => ev.channel.user_id,
    "user_name" => ev.user_name,
    "channel_type" => ev.channel.channel_type,
    "reacted_to_ts" => ev.reacted_to_ts,
)

# ─── Event Types & Handlers ───

const MESSAGE_EVENT_TYPE = Claw.EventType("slack_message", "A new message in a Slack conversation")
const REACTION_EVENT_TYPE = Claw.EventType("slack_reaction", "An emoji reaction added to a Slack message")

const REACTION_HANDLER_PROMPT = """
A user reacted to one of your messages with an emoji. Interpret the reaction and respond appropriately:
- Positive reactions (thumbsup, white_check_mark, heart, +1): Approval. Continue with your current approach.
- Negative reactions (thumbsdown, x, -1): Disapproval. Stop and ask what to change.
- Other reactions: Acknowledge briefly if appropriate.
Keep your response concise."""

# ─── EventSource ───

Base.@kwdef mutable struct SlackEventSource <: Claw.EventSource
    app_token::String = get(ENV, "SLACK_APP_TOKEN", "")
    bot_token::String = get(ENV, "SLACK_BOT_TOKEN", "")
    bot_user_id::String = get(ENV, "SLACK_BOT_USER_ID", "")
    bot_username::String = get(ENV, "SLACK_BOT_USERNAME", "")
    recipient_team_id::String = get(ENV, "SLACK_STREAM_RECIPIENT_TEAM_ID", "")
    recipient_user_id::String = get(ENV, "SLACK_STREAM_RECIPIENT_USER_ID", "")
    web_client::Union{Nothing, Slack.WebClient} = nothing
    socket_client::Union{Nothing, Slack.SocketModeClient} = nothing
    _stopping::Threads.Atomic{Bool} = Threads.Atomic{Bool}(false)
    _lock::ReentrantLock = ReentrantLock()
end

function _fetch_channels(source::SlackEventSource)
    wc = source.web_client
    wc === nothing && return Agentif.AbstractChannel[]
    channels = SlackChannel[]
    cursor = nothing
    while true
        resp = Slack.conversations_list(wc; types="public_channel,private_channel,mpim,im", limit=200, cursor=cursor)
        for ch_data in get(() -> [], resp, "channels")
            ch_id = get(() -> "", ch_data, "id")
            isempty(ch_id) && continue
            ch_name = get(() -> "", ch_data, "name")
            is_im = get(() -> false, ch_data, "is_im")
            is_mpim = get(() -> false, ch_data, "is_mpim")
            is_private = get(() -> false, ch_data, "is_private")
            ch_type = is_im ? "im" : is_mpim ? "mpim" : is_private ? "group" : "channel"
            push!(channels, SlackChannel(ch_id, "", "", "", wc, nothing, nothing, "", "", ch_type, nothing, nothing, ch_name))
        end
        meta = get(() -> nothing, resp, "response_metadata")
        cursor = meta !== nothing ? get(() -> "", meta, "next_cursor") : ""
        (cursor === nothing || isempty(cursor)) && break
    end
    return channels
end

function Claw.get_channels(source::SlackEventSource)
    _fetch_channels(source)
end

Claw.get_event_types(::SlackEventSource) = Claw.EventType[MESSAGE_EVENT_TYPE, REACTION_EVENT_TYPE]

function Claw.get_event_handlers(::SlackEventSource)
    Claw.EventHandler[
        Claw.EventHandler("slack_message_default", ["slack_message"], "", nothing),
        Claw.EventHandler("slack_reaction_default", ["slack_reaction"], REACTION_HANDLER_PROMPT, nothing),
    ]
end

# Slack channel ids preserve the session branch. The event metadata separately
# preserves the source message id, which is also the reply root for a top-level
# message. Both are needed after a restart.
function _rehydrate_slack_channel(source::SlackEventSource, row)
    channel_id = row.channel_id
    channel_id === nothing && return nothing
    wc = source.web_client
    wc === nothing && return nothing
    m = match(r"^slack:([^:]+)(?::(.+))?$", channel_id)
    m === nothing && return nothing
    chan = String(m.captures[1])
    source_ts = let value = get(() -> "", row.extra, "ts")
        value isa AbstractString && !isempty(value) ? String(value) : begin
            reacted = get(() -> "", row.extra, "reacted_to_ts")
            reacted isa AbstractString ? String(reacted) : ""
        end
    end
    # Top-level messages use their own ts as the reply root while retaining the
    # base conversation branch. True thread replies use the root from channel_id.
    thread_ts = m.captures[2] === nothing ? source_ts : String(m.captures[2])
    recipient_team_id = let v = strip(source.recipient_team_id); isempty(v) ? nothing : String(v); end
    recipient_user_id = let v = strip(source.recipient_user_id); isempty(v) ? nothing : String(v); end
    channel_type = let value = get(() -> "", row.extra, "channel_type")
        value isa AbstractString && !isempty(value) ? String(value) : _infer_channel_type(chan)
    end
    user_id = let value = get(() -> "", row.extra, "user_id")
        value isa AbstractString ? String(value) : ""
    end
    user_name = let value = get(() -> "", row.extra, "user_name")
        value isa AbstractString ? String(value) : ""
    end
    return SlackChannel(chan, thread_ts, "", source_ts, wc, nothing, nothing, user_id, user_name, channel_type,
        recipient_team_id, recipient_user_id, "")
end

function _register_slack_rehydrator!(source::SlackEventSource)
    Claw.register_rehydrator!("slack", function (row)
        ch = _rehydrate_slack_channel(source, row)
        ch === nothing && return nothing
        return Claw.ReplayedChannelEvent(row.name, row.content, ch)
    end)
    return nothing
end

# ─── Request handling ───

_string_or_empty(x) = x === nothing ? "" : String(x)

function _normalize_channel_type(raw::String)
    value = lowercase(strip(raw))
    isempty(value) && return ""
    value == "private_channel" && return "group"
    value == "dm" && return "im"
    return value
end

function _infer_channel_type(channel::String)
    isempty(channel) && return "channel"
    first_char = first(channel)
    first_char == 'C' && return "channel"
    first_char == 'D' && return "im"
    first_char == 'G' && return "group"
    return "channel"
end

function _channel_type_from_info(channel_info)
    channel_info isa AbstractDict || return nothing
    get(() -> false, channel_info, "is_im") == true && return "im"
    get(() -> false, channel_info, "is_mpim") == true && return "mpim"
    get(() -> false, channel_info, "is_group") == true && return "group"
    if get(() -> false, channel_info, "is_channel") == true
        return get(() -> false, channel_info, "is_private") == true ? "group" : "channel"
    end
    get(() -> false, channel_info, "is_private") == true && return "group"
    return nothing
end

function _resolve_channel_type(channel::String, raw_type::String, web_client::Slack.WebClient, channel_type_cache::Dict{String, String})
    cached = get(() -> "", channel_type_cache, channel)
    !isempty(cached) && return cached

    normalized = _normalize_channel_type(raw_type)
    inferred = isempty(normalized) ? _infer_channel_type(channel) : normalized
    if inferred == "im"
        channel_type_cache[channel] = inferred
        return inferred
    end

    needs_metadata_lookup = isempty(normalized) || normalized in ("channel", "group")
    if !needs_metadata_lookup
        channel_type_cache[channel] = inferred
        return inferred
    end

    resolved = inferred
    try
        info_response = Slack.conversations_info(web_client; channel=channel)
        channel_info = get(() -> nothing, info_response, "channel")
        inferred_info = _channel_type_from_info(channel_info)
        inferred_info !== nothing && (resolved = inferred_info)
    catch e
        @debug "ClawSlackExt: failed to resolve channel metadata" channel exception=e
    end
    channel_type_cache[channel] = resolved
    return resolved
end

function _payload_event(payload)
    if payload isa Slack.SlackEventsApiPayload
        return payload.event
    elseif payload isa AbstractDict
        return get(() -> nothing, payload, "event")
    end
    return nothing
end

function _event_type(event)
    if event isa Slack.SlackAppMentionEvent
        return event.type === nothing ? "app_mention" : String(event.type)
    elseif event isa Slack.SlackMessageEvent
        return event.type === nothing ? "message" : String(event.type)
    elseif event isa AbstractDict
        return _string_or_empty(get(() -> "", event, "type"))
    end
    return ""
end

function _extract_message_event(event, web_client::Slack.WebClient, bot_user_id::String, bot_username::String,
        recipient_team_id::Union{Nothing, String}, recipient_user_id::Union{Nothing, String},
        channel_type_cache::Dict{String, String}=Dict{String, String}())
    event === nothing && return nothing
    event_type = _event_type(event)
    (event_type == "message" || event_type == "app_mention") || return nothing

    text = ""
    channel = ""
    thread_ts = ""
    ts = ""
    subtype = ""
    bot_id = ""
    user_id = ""
    channel_type = ""

    if event isa Slack.SlackAppMentionEvent
        text = _string_or_empty(event.text)
        channel = _string_or_empty(event.channel)
        thread_ts = _string_or_empty(event.thread_ts)
        ts = _string_or_empty(event.ts)
        user_id = _string_or_empty(event.user)
    elseif event isa Slack.SlackMessageEvent
        text = _string_or_empty(event.text)
        channel = _string_or_empty(event.channel)
        thread_ts = _string_or_empty(event.thread_ts)
        ts = _string_or_empty(event.ts)
        subtype = _string_or_empty(event.subtype)
        bot_id = _string_or_empty(event.bot_id)
        user_id = _string_or_empty(event.user)
        channel_type = _string_or_empty(event.channel_type)
    elseif event isa AbstractDict
        text = _string_or_empty(get(() -> "", event, "text"))
        channel = _string_or_empty(get(() -> "", event, "channel"))
        thread_ts = _string_or_empty(get(() -> "", event, "thread_ts"))
        ts = _string_or_empty(get(() -> "", event, "ts"))
        subtype = _string_or_empty(get(() -> "", event, "subtype"))
        bot_id = _string_or_empty(get(() -> "", event, "bot_id"))
        user_id = _string_or_empty(get(() -> "", event, "user"))
        channel_type = _string_or_empty(get(() -> "", event, "channel_type"))
    else
        return nothing
    end

    isempty(channel) && return nothing
    isempty(text) && return nothing
    isempty(ts) && return nothing
    !isempty(subtype) && return nothing
    !isempty(bot_id) && return nothing
    !isempty(bot_user_id) && lowercase(user_id) == lowercase(bot_user_id) && return nothing
    isempty(thread_ts) && (thread_ts = ts)
    channel_type = _resolve_channel_type(channel, channel_type, web_client, channel_type_cache)

    mention_token = isempty(bot_user_id) ? "" : "<@" * lowercase(bot_user_id) * ">"
    lower_text = lowercase(text)
    direct_ping = event_type == "app_mention" ||
        channel_type == "im" ||
        (!isempty(mention_token) && occursin(mention_token, lower_text)) ||
        (!isempty(bot_username) && occursin("@" * lowercase(bot_username), lower_text))

    user_name = user_id
    ch = SlackChannel(channel, thread_ts, ts, ts, web_client, nothing, nothing, user_id, user_name, channel_type, recipient_team_id, recipient_user_id, "")
    return SlackMessageEvent(ch, text, direct_ping)
end

function _extract_reaction_event(event, web_client::Slack.WebClient, bot_user_id::String,
        recipient_team_id::Union{Nothing, String}, recipient_user_id::Union{Nothing, String},
        channel_type_cache::Dict{String, String}=Dict{String, String}())
    event isa AbstractDict || return nothing
    _event_type(event) == "reaction_added" || return nothing

    emoji = _string_or_empty(get(() -> "", event, "reaction"))
    user_id = _string_or_empty(get(() -> "", event, "user"))
    !isempty(bot_user_id) && lowercase(user_id) == lowercase(bot_user_id) && return nothing

    item = get(() -> nothing, event, "item")
    item isa AbstractDict || return nothing
    _string_or_empty(get(() -> "", item, "type")) == "message" || return nothing

    channel = _string_or_empty(get(() -> "", item, "channel"))
    reacted_to_ts = _string_or_empty(get(() -> "", item, "ts"))
    if isempty(channel) || isempty(emoji) || isempty(reacted_to_ts)
        return nothing
    end

    channel_type = _resolve_channel_type(channel, "", web_client, channel_type_cache)
    user_name = user_id
    ch = SlackChannel(channel, reacted_to_ts, reacted_to_ts, "", web_client, nothing, nothing, user_id, user_name, channel_type, recipient_team_id, recipient_user_id, "")
    return SlackReactionEvent(ch, emoji, user_name, reacted_to_ts)
end

function _payload_event_id(payload)
    if payload isa Slack.SlackEventsApiPayload
        return payload.event_id === nothing ? "" : String(payload.event_id)
    elseif payload isa AbstractDict
        return _string_or_empty(get(() -> "", payload, "event_id"))
    end
    return ""
end

function _handle_request(request::Slack.SocketModeRequest, web_client::Slack.WebClient, bot_user_id::String, bot_username::String,
        recipient_team_id::Union{Nothing, String}, recipient_user_id::Union{Nothing, String},
        assistant::Claw.AgentAssistant, channel_type_cache::Dict{String, String}=Dict{String, String}())
    request.type == "events_api" || return
    payload = request.payload
    payload === nothing && return
    event = _payload_event(payload)
    event === nothing && return
    event_type = _event_type(event)
    if event_type == "app_mention"
        @info "ClawSlackExt: skipping app_mention event; relying on message events"
        return
    end
    # Slack redelivers on missed acks; `event_id` is the delivery id that makes the
    # UNIQUE dedup_key turn a redelivery into a no-op.
    event_id = _payload_event_id(payload)

    message_event = _extract_message_event(event, web_client, bot_user_id, bot_username, recipient_team_id, recipient_user_id, channel_type_cache)
    if message_event !== nothing
        ch = message_event.channel
        @info "ClawSlackExt: message" channel=ch.channel thread_ts=ch.thread_ts user_id=ch.user_id direct_ping=message_event.direct_ping event_type
        Claw.submit_event!(assistant, message_event;
            dedup_key = isempty(event_id) ? nothing : "slack:$(event_id):message")
    end

    reaction_event = _extract_reaction_event(event, web_client, bot_user_id, recipient_team_id, recipient_user_id, channel_type_cache)
    if reaction_event !== nothing
        ch = reaction_event.channel
        @info "ClawSlackExt: reaction" channel=ch.channel thread_ts=ch.thread_ts emoji=reaction_event.emoji user_id=ch.user_id
        Claw.submit_event!(assistant, reaction_event;
            dedup_key = isempty(event_id) ? nothing : "slack:$(event_id):reaction")
    end

    return nothing
end

# ─── start! ───

function Claw.validate_source(source::SlackEventSource)
    isempty(strip(source.app_token)) && error("ClawSlackExt: missing SLACK_APP_TOKEN")
    isempty(strip(source.bot_token)) && error("ClawSlackExt: missing SLACK_BOT_TOKEN")
    return nothing
end

function Claw.start!(source::SlackEventSource, assistant::Claw.AgentAssistant)
    app_token = strip(source.app_token)
    bot_token = strip(source.bot_token)
    isempty(app_token) && error("ClawSlackExt: missing SLACK_APP_TOKEN")
    isempty(bot_token) && error("ClawSlackExt: missing SLACK_BOT_TOKEN")
    lock(source._lock) do
        source.socket_client = nothing
        source._stopping[] = false
    end

    errormonitor(Threads.@spawn begin
        web_client = Slack.WebClient(; token=bot_token)
        source.web_client = web_client
        _register_slack_rehydrator!(source)
        # Register channels now that web_client is available
        # (get_channels returns [] during register_event_source! since web_client is still nothing)
        Claw.register_channels!(assistant, Claw.get_channels(source); source)
        channel_type_cache = Dict{String, String}()
        bot_user_id = string(strip(source.bot_user_id))
        bot_username = lowercase(strip(source.bot_username))
        recipient_team_id = let v = strip(source.recipient_team_id); isempty(v) ? nothing : String(v); end
        recipient_user_id = let v = strip(source.recipient_user_id); isempty(v) ? nothing : String(v); end
        @info "ClawSlackExt: Starting Socket Mode"

        socket_client = Slack.SocketModeClient(app_token; web_client)
        Slack.add_request_listener!(socket_client, function (client, request)
            # Persist before acknowledging: acking first meant a crash between the
            # ack and the eval lost the message with no redelivery.
            _handle_request(request, web_client, bot_user_id, bot_username, recipient_team_id, recipient_user_id, assistant, channel_type_cache)
            if request.envelope_id !== nothing
                try
                    Slack.ack!(client, request)
                catch e
                    @warn "ClawSlackExt: failed to ack request" exception=(e, catch_backtrace())
                end
            end
        end)
        should_stop = lock(source._lock) do
            source.socket_client = socket_client
            source._stopping[]
        end
        should_stop && Slack.close!(socket_client)
        try
            Slack.run!(socket_client)
        finally
            Slack.close!(socket_client)
            lock(source._lock) do
                source.socket_client === socket_client && (source.socket_client = nothing)
            end
        end
    end)
end

function Claw.stop!(source::SlackEventSource)
    socket_client = lock(source._lock) do
        source._stopping[] = true
        source.socket_client
    end
    socket_client === nothing || Slack.close!(socket_client)
    return nothing
end

# Loading the trigger package makes this integration enable-able by name
# (list_integrations / enable_integration!).
__init__() = Claw.register_integration!("slack", SlackEventSource)

end # module ClawSlackExt
