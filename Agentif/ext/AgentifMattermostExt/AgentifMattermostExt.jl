module AgentifMattermostExt

using Mattermost
using Mattermost: JSON
import Agentif
using Logging

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
    @info "AgentifMattermostExt: Bot user: $(me.username) ($(bot_user_id))"

    Mattermost.run_websocket(; error_handler) do event
        _handle_event(handler, event, bot_user_id)
    end
end

# MattermostChannel — streams responses to a Mattermost channel
mutable struct MattermostChannel <: Agentif.AbstractChannel
    channel_id::String
    client::Mattermost.Client
    sm::Union{Nothing, Mattermost.StreamingMessage}
end
MattermostChannel(channel_id) = MattermostChannel(channel_id, Mattermost._get_client(), nothing)

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

function _handle_event(handler::Function, event::Mattermost.WebSocketEvent, bot_user_id::String)
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
    @info "AgentifMattermostExt: Processing message" channel_id=channel_id user_id=user_id text_length=length(message)

    try
        ch = MattermostChannel(channel_id)
        Agentif.with_channel(ch) do
            handler(message)
        end
    catch e
        @error "AgentifMattermostExt: handler error" channel_id=channel_id exception=(e, catch_backtrace())
    end
end

end # module AgentifMattermostExt
