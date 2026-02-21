module VoMattermostExt

using Mattermost
using Mattermost: JSON
import Agentif
import Vo

export MattermostEventSource

# ─── Channel ───

mutable struct MattermostChannel <: Agentif.AbstractChannel
    channel_id::String
    root_id::String
    post_id::String
    client::Mattermost.Client
    sm::Union{Nothing, Mattermost.StreamingMessage}
    user_id::String
    user_name::String
    channel_type::String  # "O" = public, "P" = private, "D" = DM, "G" = group DM
end

Agentif.start_streaming(::MattermostChannel) = nothing

function Agentif.append_to_stream(ch::MattermostChannel, delta::AbstractString)
    Mattermost.with_client(ch.client) do
        if ch.sm === nothing
            kwargs = isempty(ch.root_id) ? (;) : (; root_id=ch.root_id)
            ch.sm = Mattermost.send_streaming_message(ch.channel_id; kwargs...)
            Mattermost.update!(ch.sm, string(delta))
        else
            Mattermost.append!(ch.sm, delta)
        end
    end
end

Agentif.finish_streaming(::MattermostChannel) = nothing

function Agentif.close_channel(ch::MattermostChannel)
    sm = ch.sm
    sm === nothing && return
    Mattermost.with_client(ch.client) do
        Mattermost.finish!(sm)
    end
    ch.sm = nothing
end

function Agentif.send_message(ch::MattermostChannel, msg)
    kwargs = isempty(ch.root_id) ? (;) : (; root_id=ch.root_id)
    Mattermost.with_client(ch.client) do
        Mattermost.create_post(ch.channel_id, string(msg); kwargs...)
    end
end

function Agentif.channel_id(ch::MattermostChannel)
    base = "mattermost:$(ch.channel_id)"
    return isempty(ch.root_id) ? base : "$(base):$(ch.root_id)"
end

Agentif.is_group(ch::MattermostChannel) = ch.channel_type in ("O", "P", "G")
Agentif.is_private(ch::MattermostChannel) = ch.channel_type != "O"

function Agentif.get_current_user(ch::MattermostChannel)
    isempty(ch.user_id) && return nothing
    return Agentif.ChannelUser(ch.user_id, ch.user_name)
end

Agentif.source_message_id(ch::MattermostChannel) = isempty(ch.post_id) ? nothing : ch.post_id

function Agentif.create_channel_tools(ch::MattermostChannel)
    post_id = ch.post_id
    client = ch.client
    isempty(post_id) && return Agentif.AgentTool[]
    react_fn = function react_to_message(emoji_name::String)
        Mattermost.with_client(client) do
            Mattermost.add_reaction(post_id, emoji_name)
        end
        return """{"status":"ok","emoji":"$emoji_name","post_id":"$post_id"}"""
    end
    react_tool = Agentif.AgentTool{typeof(react_fn), @NamedTuple{emoji_name::String}}(;
        name = "react_to_message",
        description = "React to the user's message with an emoji instead of (or in addition to) sending a text reply. Use this for simple acknowledgments, approvals, or expressing sentiment without a full response. Common emoji names: thumbsup, white_check_mark, eyes, heart, laughing, tada, thinking, thumbsdown, warning, x",
        func = react_fn,
    )
    return Agentif.AgentTool[react_tool]
end

# ─── Channel Events ───

struct MattermostMessageEvent <: Vo.ChannelEvent
    channel::MattermostChannel
    content::String
    direct_ping::Bool
end

Vo.get_name(::MattermostMessageEvent) = "mattermost_message"
Vo.get_channel(ev::MattermostMessageEvent) = ev.channel
function Vo.event_content(ev::MattermostMessageEvent)
    if Agentif.is_group(ev.channel) && !isempty(ev.channel.user_name)
        return "[$(ev.channel.user_name)]: $(ev.content)"
    end
    return ev.content
end
Vo.is_direct_ping(ev::MattermostMessageEvent) = ev.direct_ping

struct MattermostReactionEvent <: Vo.ChannelEvent
    channel::MattermostChannel
    emoji::String
    user_name::String
    reacted_to::String
end

Vo.get_name(::MattermostReactionEvent) = "mattermost_reaction"
Vo.get_channel(ev::MattermostReactionEvent) = ev.channel
Vo.is_direct_ping(::MattermostReactionEvent) = true

function Vo.event_content(ev::MattermostReactionEvent)
    lines = ["User '$(ev.user_name)' reacted with :$(ev.emoji):"]
    if !isempty(ev.reacted_to)
        push!(lines, "Reacted to your message: \"$(ev.reacted_to)\"")
    end
    return join(lines, "\n")
end

# ─── Event Types & Handlers ───

const MESSAGE_EVENT_TYPE = Vo.EventType("mattermost_message", "A new message posted in a Mattermost channel")
const REACTION_EVENT_TYPE = Vo.EventType("mattermost_reaction", "An emoji reaction added to a message in Mattermost")

const REACTION_HANDLER_PROMPT = """
A user reacted to one of your messages with an emoji. Interpret the reaction and respond appropriately:
- Positive reactions (thumbsup, white_check_mark, heart, +1): Approval. Continue with your current approach.
- Negative reactions (thumbsdown, x, -1): Disapproval. Stop and ask what to change.
- Other reactions: Acknowledge briefly if appropriate.
Keep your response concise."""

# ─── EventSource ───

struct MattermostEventSource <: Vo.EventSource end

Vo.get_event_types(::MattermostEventSource) = Vo.EventType[MESSAGE_EVENT_TYPE, REACTION_EVENT_TYPE]

function Vo.get_event_handlers(::MattermostEventSource)
    Vo.EventHandler[
        Vo.EventHandler("mattermost_message_default", ["mattermost_message"], "", nothing),
        Vo.EventHandler("mattermost_reaction_default", ["mattermost_reaction"], REACTION_HANDLER_PROMPT, nothing),
    ]
end

# ─── WebSocket event handling ───

function _handle_posted(event, bot_user_id, bot_username, assistant)
    post_json = get(event.data, "post", nothing)
    post_json === nothing && return
    post_data = JSON.parse(post_json)

    user_id = get(post_data, "user_id", "")
    user_id == bot_user_id && return

    message = get(post_data, "message", "")
    (message === nothing || isempty(message)) && return

    channel_id = get(post_data, "channel_id", "")
    post_root_id = get(post_data, "root_id", "")
    post_id = get(post_data, "id", "")
    root_id = post_root_id  # empty for top-level messages → shared session per channel

    user_name = get(event.data, "sender_name", "")
    startswith(user_name, "@") && (user_name = user_name[2:end])

    channel_type = get(event.data, "channel_type", "O")
    direct_ping = channel_type == "D" || (!isempty(bot_username) && occursin("@" * bot_username, lowercase(message)))

    @info "VoMattermostExt: message" channel_id post_id direct_ping

    ch = MattermostChannel(channel_id, root_id, post_id, Mattermost._get_client(), nothing, user_id, user_name, channel_type)
    put!(assistant.event_queue, MattermostMessageEvent(ch, message, direct_ping))
end

function _handle_reaction(event, bot_user_id, assistant)
    reaction_json = get(event.data, "reaction", nothing)
    reaction_json === nothing && return
    reaction_data = JSON.parse(reaction_json)

    user_id = get(reaction_data, "user_id", "")
    user_id == bot_user_id && return

    emoji_name = get(reaction_data, "emoji_name", "")
    post_id = get(reaction_data, "post_id", "")
    isempty(post_id) && return

    channel_id = event.broadcast !== nothing ? get(event.broadcast, "channel_id", "") : ""
    isempty(channel_id) && return

    # Fetch the reacted-to post for thread root_id and message content
    root_id = post_id
    reacted_to = ""
    user_name = user_id
    try
        post = Mattermost.get_post(post_id)
        if hasproperty(post, :root_id) && post.root_id !== nothing && !isempty(string(post.root_id))
            root_id = string(post.root_id)
        end
        if hasproperty(post, :message) && post.message !== nothing
            reacted_to = string(post.message)
        end
    catch e
        @debug "VoMattermostExt: failed to fetch post for reaction" post_id exception=e
    end

    @info "VoMattermostExt: reaction" emoji=emoji_name post_id channel_id user_id

    ch = MattermostChannel(channel_id, root_id, post_id, Mattermost._get_client(), nothing, user_id, user_name, "")
    put!(assistant.event_queue, MattermostReactionEvent(ch, emoji_name, user_name, reacted_to))
end

function _handle_post_deleted(event, assistant)
    post_json = get(event.data, "post", nothing)
    post_json === nothing && return
    post_data = JSON.parse(post_json)
    post_id = get(post_data, "id", "")
    isempty(post_id) && return
    @info "VoMattermostExt: post deleted" post_id
    try
        Vo.scrub_post!(assistant, post_id)
    catch e
        @error "VoMattermostExt: scrub_post! failed" post_id exception=(e, catch_backtrace())
    end
end

function _handle_event(event::Mattermost.WebSocketEvent, bot_user_id::String, bot_username::String, assistant::Vo.AgentAssistant)
    event.data === nothing && return

    if event.event == "posted"
        _handle_posted(event, bot_user_id, bot_username, assistant)
    elseif event.event == "reaction_added"
        _handle_reaction(event, bot_user_id, assistant)
    elseif event.event == "post_deleted"
        _handle_post_deleted(event, assistant)
    end
end

# ─── start! ───

function Vo.start!(::MattermostEventSource, assistant::Vo.AgentAssistant)
    errormonitor(Threads.@spawn begin
        Mattermost.with_mattermost(ENV["MATTERMOST_TOKEN"], ENV["MATTERMOST_URL"]) do
            me = Mattermost.get_me()
            bot_user_id = me.id
            bot_username = me.username !== nothing ? lowercase(string(me.username)) : ""
            @info "VoMattermostExt: Bot user: $(me.username) ($(bot_user_id))"

            Mattermost.run_websocket() do event
                _handle_event(event, bot_user_id, bot_username, assistant)
            end
        end
    end)
end

end # module VoMattermostExt
