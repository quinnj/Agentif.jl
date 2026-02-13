module AgentifSlackExt

using Slack
import Agentif
using Logging
using ScopedValues: @with

export run_slack_bot

"""
    run_slack_bot(handler; app_token=ENV["SLACK_APP_TOKEN"], bot_token=ENV["SLACK_BOT_TOKEN"], kwargs...)

Start a Slack bot that listens for incoming messages via Socket Mode and calls
`handler(text::String)` for each one, with the appropriate `AbstractChannel`
scoped via `Agentif.with_channel`.
"""
function run_slack_bot(handler::Function;
        app_token::AbstractString = ENV["SLACK_APP_TOKEN"],
        bot_token::AbstractString = ENV["SLACK_BOT_TOKEN"],
        kwargs...)
    web_client = Slack.WebClient(; token=bot_token)
    @info "AgentifSlackExt: Starting Socket Mode bot"

    Slack.run!(app_token; web_client=web_client, kwargs...) do sm_client, request
        Slack.ack!(sm_client, request)
        _handle_request(handler, request, web_client)
    end
end

# SlackChannel — streams responses to a Slack channel/thread
mutable struct SlackChannel <: Agentif.AbstractChannel
    channel::String
    thread_ts::String
    web_client::Slack.WebClient
    sm::Union{Nothing, Slack.ChatStream}
    user_id::String
    # "channel" = public, "group" = private channel, "im" = DM, "mpim" = multi-party DM
    channel_type::String
end

function Agentif.start_streaming(ch::SlackChannel)
    if ch.sm === nothing
        ch.sm = Slack.ChatStream(ch.web_client;
            channel=ch.channel,
            thread_ts=ch.thread_ts,
        )
    end
    return ch.sm
end

function Agentif.append_to_stream(::SlackChannel, sm::Slack.ChatStream, delta::AbstractString)
    Slack.append!(sm; markdown_text=delta)
end

function Agentif.finish_streaming(::SlackChannel, ::Slack.ChatStream)
    return nothing
end

function Agentif.close_channel(ch::SlackChannel, sm::Slack.ChatStream)
    if sm.state != "completed"
        Slack.stop!(sm)
    end
    ch.sm = nothing
end

function Agentif.send_message(ch::SlackChannel, msg)
    Slack.chat_post_message(ch.web_client;
        channel=ch.channel,
        text=string(msg),
        thread_ts=ch.thread_ts,
    )
end

function Agentif.channel_id(ch::SlackChannel)
    return "slack:$(ch.channel)"
end

function Agentif.is_group(ch::SlackChannel)
    return ch.channel_type in ("channel", "group", "mpim")
end

function Agentif.is_private(ch::SlackChannel)
    # "channel" = public; everything else (DM, private channel, multi-party DM) is private
    return ch.channel_type != "channel"
end

function Agentif.get_current_user(ch::SlackChannel)
    isempty(ch.user_id) && return nothing
    return Agentif.ChannelUser(ch.user_id, ch.user_id)  # name requires users.info API call
end

function _handle_request(handler::Function, request::Slack.SocketModeRequest, web_client::Slack.WebClient)
    request.type == "events_api" || return

    payload = request.payload
    payload === nothing && return
    payload isa Slack.SlackEventsApiPayload || return

    event = payload.event
    event === nothing && return

    # Skip bot messages
    if event isa Slack.SlackMessageEvent && event.bot_id !== nothing
        return
    end

    text = event.text
    (text === nothing || isempty(text)) && return

    channel = event.channel
    channel === nothing && return

    # Reply in existing thread, or start a new thread under the message
    thread_ts = event.thread_ts !== nothing ? event.thread_ts : event.ts
    thread_ts === nothing && return

    user_id = event.user !== nothing ? string(event.user) : ""
    channel_type = event.channel_type !== nothing ? string(event.channel_type) : "channel"

    # Detect direct ping: app_mention event or DM
    direct_ping = event isa Slack.SlackAppMentionEvent || channel_type == "im"

    @info "AgentifSlackExt: Processing message" channel=channel user_id=user_id channel_type=channel_type direct_ping=direct_ping text_length=length(text)

    try
        ch = SlackChannel(channel, thread_ts, web_client, nothing, user_id, channel_type)
        Agentif.with_channel(ch) do
            @with Agentif.DIRECT_PING => direct_ping handler(text)
        end
    catch e
        @error "AgentifSlackExt: handler error" channel=channel exception=(e, catch_backtrace())
    end
end

end # module AgentifSlackExt
