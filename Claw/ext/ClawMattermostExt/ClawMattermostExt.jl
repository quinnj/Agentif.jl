module ClawMattermostExt

using Mattermost
using Mattermost: JSON
import Agentif
import Claw
import HTTP

export MattermostEventSource

# ─── Channel ───

const CREATE_POST_FN = Ref{Function}(Mattermost.create_post)
const GET_POST_FN = Ref{Function}(Mattermost.get_post)
const SEND_STREAMING_MESSAGE_FN = Ref{Function}(Mattermost.send_streaming_message)
const STREAM_APPEND_FN = Ref{Function}((sm, delta) -> Mattermost.append!(sm, delta))
const STREAM_FLUSH_FN = Ref{Function}(Mattermost.flush!)
const STREAM_FINISH_FN = Ref{Function}(Mattermost.finish!)
const STREAM_MIN_INTERVAL_S = 1.0

mutable struct MattermostChannel <: Agentif.AbstractChannel
    channel_id::String
    root_id::String
    post_id::String
    source_post_id::String
    client::Mattermost.Client
    sm::Union{Nothing, Mattermost.StreamingMessage}
    io::Union{Nothing, IOBuffer}
    user_id::String
    user_name::String
    channel_type::String  # "O" = public, "P" = private, "D" = DM, "G" = group DM
    display_name::String
end

function Agentif.start_streaming(ch::MattermostChannel)
    if ch.sm === nothing && ch.io === nothing
        kwargs = isempty(ch.root_id) ? (;) : (; root_id=ch.root_id)
        try
            sm = Mattermost.with_client(ch.client) do
                SEND_STREAMING_MESSAGE_FN[](ch.channel_id, ""; min_interval=STREAM_MIN_INTERVAL_S, kwargs...)
            end
            ch.sm = sm
            if hasproperty(sm, :post_id)
                post_id = String(getproperty(sm, :post_id))
                !isempty(post_id) && (ch.post_id = post_id)
            end
        catch e
            @warn "ClawMattermostExt: failed to start streaming message; falling back to buffered send" exception=e
            ch.io = IOBuffer()
        end
    end
    return nothing
end

function Agentif.append_to_stream(ch::MattermostChannel, delta::AbstractString)
    sm = ch.sm
    if sm !== nothing
        try
            Mattermost.with_client(ch.client) do
                STREAM_APPEND_FN[](sm, String(delta))
            end
            return
        catch e
            @warn "ClawMattermostExt: stream append failed; switching to buffered send" exception=e
            ch.sm = nothing
            fallback = IOBuffer()
            if hasproperty(sm, :buffer)
                prior = String(getproperty(sm, :buffer))
                !isempty(prior) && write(fallback, prior)
            end
            ch.io = fallback
        end
    end
    io = ch.io
    if io === nothing
        io = IOBuffer()
        ch.io = io
    end
    write(io, String(delta))
end

function Agentif.finish_streaming(ch::MattermostChannel)
    sm = ch.sm
    sm === nothing && return nothing
    try
        Mattermost.with_client(ch.client) do
            STREAM_FLUSH_FN[](sm)
        end
    catch e
        @warn "ClawMattermostExt: stream flush failed" exception=e
    end
    return nothing
end

function Agentif.close_channel(ch::MattermostChannel)
    sm = ch.sm
    if sm !== nothing
        try
            Mattermost.with_client(ch.client) do
                STREAM_FINISH_FN[](sm)
            end
            if hasproperty(sm, :post_id)
                post_id = String(getproperty(sm, :post_id))
                !isempty(post_id) && (ch.post_id = post_id)
            end
        catch e
            @warn "ClawMattermostExt: stream finish failed" exception=e
        end
        ch.sm = nothing
        return nothing
    end

    io = ch.io
    io === nothing && return
    text = String(take!(io))
    ch.io = nothing
    isempty(text) && return
    Agentif.send_message(ch, text)
end

function Agentif.send_message(ch::MattermostChannel, msg)
    kwargs = isempty(ch.root_id) ? (;) : (; root_id=ch.root_id)
    response = Mattermost.with_client(ch.client) do
        CREATE_POST_FN[](ch.channel_id, string(msg); kwargs...)
    end
    if hasproperty(response, :id)
        post_id = String(getproperty(response, :id))
        !isempty(post_id) && (ch.post_id = post_id)
    end
    return response
end

# A true thread reply has root_id set by the platform AND root_id differs from the message's own ID.
# Top-level messages set root_id = post_id (self-referencing) just for reply-in-thread behavior.
_is_thread(ch::MattermostChannel) = !isempty(ch.root_id) && ch.root_id != ch.source_post_id

function Agentif.channel_id(ch::MattermostChannel)
    base = "mattermost:$(ch.channel_id)"
    return _is_thread(ch) ? "$(base):$(ch.root_id)" : base
end

Agentif.channel_name(ch::MattermostChannel) = ch.display_name
Agentif.is_group(ch::MattermostChannel) = ch.channel_type in ("O", "P", "G")
Agentif.is_private(ch::MattermostChannel) = ch.channel_type != "O"

function Agentif.get_current_user(ch::MattermostChannel)
    isempty(ch.user_id) && return nothing
    return Agentif.ChannelUser(ch.user_id, ch.user_name)
end

Agentif.entry_id(ch::MattermostChannel) = isempty(ch.source_post_id) ? nothing : ch.source_post_id
Agentif.response_entry_id(ch::MattermostChannel) = isempty(ch.post_id) ? nothing : ch.post_id
Agentif.parent_branch_id(ch::MattermostChannel) = _is_thread(ch) ? "mattermost:$(ch.channel_id)" : nothing
Agentif.branch_entry_id(ch::MattermostChannel) = _is_thread(ch) ? ch.root_id : nothing
Agentif.search_channel_id(ch::MattermostChannel) = "mattermost:$(ch.channel_id)"

function Agentif.create_channel_tools(ch::MattermostChannel)
    post_id = ch.source_post_id
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

struct MattermostMessageEvent <: Claw.ChannelEvent
    channel::MattermostChannel
    content::String
    direct_ping::Bool
end

Claw.get_name(::MattermostMessageEvent) = "mattermost_message"
Claw.get_channel(ev::MattermostMessageEvent) = ev.channel
function Claw.event_content(ev::MattermostMessageEvent)
    if Agentif.is_group(ev.channel) && !isempty(ev.channel.user_name)
        return "[$(ev.channel.user_name)]: $(ev.content)"
    end
    return ev.content
end

struct MattermostReactionEvent <: Claw.ChannelEvent
    channel::MattermostChannel
    emoji::String
    user_name::String
    reacted_to::String
end

Claw.get_name(::MattermostReactionEvent) = "mattermost_reaction"
Claw.get_channel(ev::MattermostReactionEvent) = ev.channel

function Claw.event_content(ev::MattermostReactionEvent)
    lines = ["User '$(ev.user_name)' reacted with :$(ev.emoji):"]
    if !isempty(ev.reacted_to)
        push!(lines, "Reacted to your message: \"$(ev.reacted_to)\"")
    end
    return join(lines, "\n")
end

Claw.event_source_tag(::MattermostMessageEvent) = "mattermost"
Claw.event_source_tag(::MattermostReactionEvent) = "mattermost"
Claw.event_extra(ev::MattermostMessageEvent) = Dict{String, Any}(
    "direct_ping" => ev.direct_ping,
    "user_id" => ev.channel.user_id,
    "user_name" => ev.channel.user_name,
    "channel_type" => ev.channel.channel_type,
    "post_id" => ev.channel.source_post_id,
)
Claw.event_extra(ev::MattermostReactionEvent) = Dict{String, Any}(
    "emoji" => ev.emoji,
    "user_id" => ev.channel.user_id,
    "user_name" => ev.user_name,
    "channel_type" => ev.channel.channel_type,
    "post_id" => ev.channel.source_post_id,
)

# ─── Event Types & Handlers ───

const MESSAGE_EVENT_TYPE = Claw.EventType("mattermost_message", "A new message posted in a Mattermost channel")
const REACTION_EVENT_TYPE = Claw.EventType("mattermost_reaction", "An emoji reaction added to a message in Mattermost")

const REACTION_HANDLER_PROMPT = """
A user reacted to one of your messages with an emoji. Interpret the reaction and respond appropriately:
- Positive reactions (thumbsup, white_check_mark, heart, +1): Approval. Continue with your current approach.
- Negative reactions (thumbsdown, x, -1): Disapproval. Stop and ask what to change.
- Other reactions: Acknowledge briefly if appropriate.
Keep your response concise."""

# ─── EventSource ───

mutable struct MattermostEventSource <: Claw.EventSource
    client::Union{Nothing, Mattermost.Client}
    bot_user_id::Union{Nothing, String}
    _ws::Any
    _stopping::Threads.Atomic{Bool}
    _lock::ReentrantLock
end
MattermostEventSource() = MattermostEventSource(
    nothing, nothing, nothing, Threads.Atomic{Bool}(false), ReentrantLock())

function Claw.get_channels(source::MattermostEventSource)
    source.client === nothing && return Agentif.AbstractChannel[]
    Mattermost.with_client(source.client) do
        _fetch_channels(source.client, source.bot_user_id)
    end
end

Claw.get_event_types(::MattermostEventSource) = Claw.EventType[MESSAGE_EVENT_TYPE, REACTION_EVENT_TYPE]

function Claw.get_event_handlers(::MattermostEventSource)
    Claw.EventHandler[
        Claw.EventHandler("mattermost_message_default", ["mattermost_message"], "", nothing),
        Claw.EventHandler("mattermost_reaction_default", ["mattermost_reaction"], REACTION_HANDLER_PROMPT, nothing),
    ]
end

function _rehydrate_mattermost_channel(source::MattermostEventSource, row)
    channel_id = row.channel_id
    channel_id === nothing && return nothing
    client = source.client
    client === nothing && return nothing
    m = match(r"^mattermost:([^:]+)(?::(.+))?$", channel_id)
    m === nothing && return nothing
    chan = String(m.captures[1])
    post_id = let value = get(() -> "", row.extra, "post_id")
        value isa AbstractString ? String(value) : ""
    end
    # A top-level message uses its own post id as the reply root but stays on the
    # base session branch. A true thread carries a distinct root in channel_id.
    root_id = m.captures[2] === nothing ? post_id : String(m.captures[2])
    user_id = let value = get(() -> "", row.extra, "user_id")
        value isa AbstractString ? String(value) : ""
    end
    user_name = let value = get(() -> "", row.extra, "user_name")
        value isa AbstractString ? String(value) : ""
    end
    channel_type = let value = get(() -> "O", row.extra, "channel_type")
        value isa AbstractString ? String(value) : "O"
    end
    return MattermostChannel(
        chan, root_id, "", post_id, client, nothing, nothing,
        user_id, user_name, channel_type, "")
end

function _register_mattermost_rehydrator!(source::MattermostEventSource)
    Claw.register_rehydrator!("mattermost", function (row)
        ch = _rehydrate_mattermost_channel(source, row)
        ch === nothing && return nothing
        return Claw.ReplayedChannelEvent(row.name, row.content, ch)
    end)
    return nothing
end

# ─── WebSocket event handling ───

function _handle_posted(event, bot_user_id, bot_username, assistant)
    post_json = get(() -> nothing, event.data, "post")
    post_json === nothing && return
    post_data = JSON.parse(post_json)

    user_id = get(() -> "", post_data, "user_id")
    user_id == bot_user_id && return

    post_type = get(() -> "", post_data, "type")
    !isempty(post_type) && return

    message = get(() -> "", post_data, "message")
    (message === nothing || isempty(message)) && return

    channel_id = get(() -> "", post_data, "channel_id")
    post_root_id = get(() -> "", post_data, "root_id")
    post_id = get(() -> "", post_data, "id")
    isempty(channel_id) && return
    isempty(post_id) && return
    root_id = isempty(post_root_id) ? post_id : post_root_id

    user_name = get(() -> "", event.data, "sender_name")
    startswith(user_name, "@") && (user_name = user_name[2:end])

    channel_type = get(() -> "O", event.data, "channel_type")
    direct_ping = channel_type == "D" || (!isempty(bot_username) && occursin("@" * bot_username, lowercase(message)))

    @info "ClawMattermostExt: message" channel_id post_id direct_ping

    ch = MattermostChannel(channel_id, root_id, post_id, post_id, Mattermost._get_client(), nothing, nothing, user_id, user_name, channel_type, "")
    # Mattermost post ids are unique per post; a websocket replay after reconnect
    # therefore dedupes for free.
    Claw.submit_event!(assistant, MattermostMessageEvent(ch, message, direct_ping);
        dedup_key = "mattermost:post:$(post_id)")
end

function _handle_reaction(event, bot_user_id, assistant)
    reaction_json = get(() -> nothing, event.data, "reaction")
    reaction_json === nothing && return
    reaction_data = JSON.parse(reaction_json)

    user_id = get(() -> "", reaction_data, "user_id")
    user_id == bot_user_id && return

    emoji_name = get(() -> "", reaction_data, "emoji_name")
    post_id = get(() -> "", reaction_data, "post_id")
    isempty(post_id) && return

    channel_id = event.broadcast !== nothing ? get(() -> "", event.broadcast, "channel_id") : ""
    isempty(channel_id) && return

    # Fetch the reacted-to post for thread root_id and message content
    root_id = post_id
    reacted_to = ""
    user_name = user_id
    try
        post = GET_POST_FN[](post_id)
        if hasproperty(post, :root_id) && post.root_id !== nothing && !isempty(string(post.root_id))
            root_id = string(post.root_id)
        end
        if hasproperty(post, :message) && post.message !== nothing
            reacted_to = string(post.message)
        end
    catch e
        @debug "ClawMattermostExt: failed to fetch post for reaction" post_id exception=e
    end

    @info "ClawMattermostExt: reaction" emoji=emoji_name post_id channel_id user_id

    ch = MattermostChannel(channel_id, root_id, post_id, "", Mattermost._get_client(), nothing, nothing, user_id, user_name, "", "")
    Claw.submit_event!(assistant, MattermostReactionEvent(ch, emoji_name, user_name, reacted_to);
        dedup_key = "mattermost:reaction:$(post_id):$(user_id):$(emoji_name)")
end

function _handle_post_deleted(event, assistant)
    post_json = get(() -> nothing, event.data, "post")
    post_json === nothing && return
    post_data = JSON.parse(post_json)
    post_id = get(() -> "", post_data, "id")
    isempty(post_id) && return
    @info "ClawMattermostExt: post deleted" post_id
    try
        Claw.scrub_post!(assistant, post_id)
    catch e
        @error "ClawMattermostExt: scrub_post! failed" post_id exception=(e, catch_backtrace())
    end
end

function _handle_event(event::Mattermost.WebSocketEvent, bot_user_id::String, bot_username::String, assistant::Claw.AgentAssistant)
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

function _fetch_channels(client::Mattermost.Client, bot_user_id::String)
    channels = MattermostChannel[]
    teams = Mattermost.get_teams()
    for team in teams
        for mm_ch in Mattermost.get_channels_for_user(bot_user_id, team.id)
            push!(channels, MattermostChannel(mm_ch.id, "", "", "", client, nothing, nothing, "", "", mm_ch.type, mm_ch.display_name))
        end
    end
    return channels
end

function _mattermost_sleep(source::MattermostEventSource, seconds::Real)
    deadline = time() + seconds
    while time() < deadline
        source._stopping[] && return false
        sleep(min(0.1, max(0.0, deadline - time())))
    end
    return !source._stopping[]
end

function _run_mattermost_websocket(source::MattermostEventSource, handler::Function)
    client = source.client
    client === nothing && error("ClawMattermostExt: no Mattermost client")
    ws_url = Mattermost._websocket_url(client)
    headers = ["Authorization" => "Bearer $(client.token)"]
    consecutive_errors = 0
    while !source._stopping[]
        try
            HTTP.WebSockets.open(ws_url; headers) do ws
                lock(source._lock) do
                    source._ws = ws
                    source._stopping[] && HTTP.WebSockets.close(ws)
                end
                consecutive_errors = 0
                for msg in ws
                    source._stopping[] && break
                    try
                        data = JSON.parse(String(msg))
                        haskey(data, "event") || continue
                        handler(Mattermost._parse_result(Mattermost.WebSocketEvent, data))
                    catch e
                        (e isa HTTP.WebSockets.WebSocketError || e isa EOFError) && rethrow()
                        @error "ClawMattermostExt: WebSocket event failed" exception=(e, catch_backtrace())
                    end
                end
            end
        catch e
            source._stopping[] && break
            consecutive_errors += 1
            backoff = min(60, 2^min(consecutive_errors, 6))
            @error "ClawMattermostExt: WebSocket connection failed" exception=(e, catch_backtrace())
            _mattermost_sleep(source, backoff) || break
        finally
            lock(source._lock) do
                source._ws = nothing
            end
        end
    end
    return nothing
end

function Claw.start!(source::MattermostEventSource, assistant::Claw.AgentAssistant)
    lock(source._lock) do
        source._ws = nothing
        source._stopping[] = false
    end
    errormonitor(Threads.@spawn begin
        Mattermost.with_mattermost(ENV["MATTERMOST_TOKEN"], ENV["MATTERMOST_URL"]) do
            me = Mattermost.get_me()
            bot_user_id = me.id
            bot_username = me.username !== nothing ? lowercase(string(me.username)) : ""
            source.client = Mattermost._get_client()
            source.bot_user_id = bot_user_id
            _register_mattermost_rehydrator!(source)
            Claw.register_channels!(assistant, _fetch_channels(source.client, bot_user_id))
            @info "ClawMattermostExt: Bot user: $(me.username) ($(bot_user_id))"

            _run_mattermost_websocket(source) do event
                _handle_event(event, bot_user_id, bot_username, assistant)
            end
        end
    end)
end

function Claw.stop!(source::MattermostEventSource)
    lock(source._lock) do
        source._stopping[] = true
        source._ws === nothing || HTTP.WebSockets.close(source._ws)
    end
    return nothing
end

# Loading the trigger package makes this integration enable-able by name
# (list_integrations / enable_integration!).
__init__() = Claw.register_integration!("mattermost", MattermostEventSource)

end # module ClawMattermostExt
