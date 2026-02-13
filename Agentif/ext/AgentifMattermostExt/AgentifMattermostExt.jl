module AgentifMattermostExt

using Mattermost
using Mattermost: JSON
import Agentif
using Logging
using ScopedValues: @with

export run_mattermost_bot

"""
    run_mattermost_bot(handler; error_handler=nothing)

Start a Mattermost bot that listens for incoming messages via WebSocket and calls
`handler(text::String)` for each one, with the appropriate `AbstractChannel`
scoped via `Agentif.with_channel`.
"""
function run_mattermost_bot(handler::Function;
        error_handler::Union{Function, Nothing} = nothing)
    me = Mattermost.get_me()
    bot_user_id = me.id
    bot_username = me.username !== nothing ? lowercase(string(me.username)) : ""
    @info "AgentifMattermostExt: Bot user: $(me.username) ($(bot_user_id))"

    Mattermost.run_websocket(; error_handler) do event
        _handle_event(handler, event, bot_user_id, bot_username)
    end
end

# MattermostChannel — streams responses to a Mattermost channel
mutable struct MattermostChannel <: Agentif.AbstractChannel
    channel_id::String
    client::Mattermost.Client
    sm::Union{Nothing, Mattermost.StreamingMessage}
    user_id::String
    user_name::String
    # "O" = open/public, "P" = private, "D" = DM, "G" = group DM
    channel_type::String
end

function Agentif.start_streaming(ch::MattermostChannel)
    if ch.sm === nothing
        ch.sm = Mattermost.with_client(ch.client) do
            Mattermost.send_streaming_message(ch.channel_id)
        end
    end
    return ch.sm
end

function Agentif.append_to_stream(ch::MattermostChannel, sm::Mattermost.StreamingMessage, delta::AbstractString)
    Mattermost.with_client(ch.client) do
        Mattermost.append!(sm, delta)
    end
end

function Agentif.finish_streaming(::MattermostChannel, ::Mattermost.StreamingMessage)
    return nothing
end

function Agentif.close_channel(ch::MattermostChannel, sm::Mattermost.StreamingMessage)
    Mattermost.with_client(ch.client) do
        Mattermost.finish!(sm)
    end
    ch.sm = nothing
end

function Agentif.send_message(ch::MattermostChannel, msg)
    Mattermost.with_client(ch.client) do
        Mattermost.create_post(ch.channel_id, string(msg))
    end
end

function Agentif.channel_id(ch::MattermostChannel)
    return "mattermost:$(ch.channel_id)"
end

function Agentif.is_group(ch::MattermostChannel)
    return ch.channel_type in ("O", "P", "G")
end

function Agentif.is_private(ch::MattermostChannel)
    return ch.channel_type != "O"
end

function Agentif.get_current_user(ch::MattermostChannel)
    isempty(ch.user_id) && return nothing
    return Agentif.ChannelUser(ch.user_id, ch.user_name)
end

function _handle_event(handler::Function, event::Mattermost.WebSocketEvent, bot_user_id::String, bot_username::String="")
    event.event == "posted" || return
    event.data === nothing && return

    post_json = get(event.data, "post", nothing)
    post_json === nothing && return

    post_data = JSON.parse(post_json)
    user_id = get(post_data, "user_id", "")
    user_id == bot_user_id && return

    message = get(post_data, "message", "")
    (message === nothing || isempty(message)) && return

    channel_id = get(post_data, "channel_id", "")

    # Extract user name from event data
    user_name = get(event.data, "sender_name", "")
    # Strip leading @ if present
    if startswith(user_name, "@")
        user_name = user_name[2:end]
    end

    # Extract channel type from event data
    channel_type = get(event.data, "channel_type", "O")

    # Detect direct ping: DM or @bot_username mention in text
    direct_ping = channel_type == "D" || (!isempty(bot_username) && occursin("@" * bot_username, lowercase(message)))

    @info "AgentifMattermostExt: Processing message" channel_id=channel_id channel_type=channel_type user_id=user_id direct_ping=direct_ping text_length=length(message)

    try
        ch = MattermostChannel(channel_id, Mattermost._get_client(), nothing, user_id, user_name, channel_type)
        Agentif.with_channel(ch) do
            @with Agentif.DIRECT_PING => direct_ping handler(message)
        end
    catch e
        @error "AgentifMattermostExt: handler error" channel_id=channel_id exception=(e, catch_backtrace())
    end
end

end # module AgentifMattermostExt
