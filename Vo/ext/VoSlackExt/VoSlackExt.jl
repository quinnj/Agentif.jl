module VoSlackExt

using Slack
import Agentif
import Vo
export SlackTriggerSource

# === Channel (unchanged from AgentifSlackExt) ===

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
end

function Agentif.append_to_stream(ch::SlackChannel, delta::AbstractString)
    sm = ch.sm
    sm === nothing && return
    Slack.append!(sm; markdown_text=delta)
end

Agentif.finish_streaming(::SlackChannel) = nothing

function Agentif.close_channel(ch::SlackChannel)
    sm = ch.sm
    sm === nothing && return
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
    return "slack:$(ch.channel):$(ch.thread_ts)"
end

function Agentif.is_group(ch::SlackChannel)
    return ch.channel_type in ("channel", "group", "mpim")
end

function Agentif.is_private(ch::SlackChannel)
    return ch.channel_type != "channel"
end

function Agentif.get_current_user(ch::SlackChannel)
    isempty(ch.user_id) && return nothing
    return Agentif.ChannelUser(ch.user_id, ch.user_id)
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

    thread_ts = event.thread_ts !== nothing ? event.thread_ts : event.ts
    thread_ts === nothing && return

    user_id = event.user !== nothing ? string(event.user) : ""
    channel_type = event.channel_type !== nothing ? string(event.channel_type) : "channel"

    direct_ping = event isa Slack.SlackAppMentionEvent || channel_type == "im"

    @info "VoSlackExt: Processing message" channel=channel user_id=user_id channel_type=channel_type direct_ping=direct_ping text_length=length(text)

    Threads.@spawn try
        ch = SlackChannel(channel, thread_ts, web_client, nothing, user_id, channel_type)
        Agentif.with_channel(ch) do
            handler(text)
        end
    catch e
        @error "VoSlackExt: handler error" channel=channel exception=(e, catch_backtrace())
    end
end

# === TriggerSource ===

struct SlackTriggerSource <: Vo.TriggerSource
    name::String
    app_token::String
    bot_token::String
end

function SlackTriggerSource(; name::String="slack", app_token=ENV["SLACK_APP_TOKEN"], bot_token=ENV["SLACK_BOT_TOKEN"])
    SlackTriggerSource(name, String(app_token), String(bot_token))
end

Vo.source_name(s::SlackTriggerSource) = s.name

function Vo.run(handler::Function, source::SlackTriggerSource)
    web_client = Slack.WebClient(; token=source.bot_token)
    @info "VoSlackExt: Starting Socket Mode bot"
    Slack.run!(source.app_token; web_client=web_client) do sm_client, request
        Slack.ack!(sm_client, request)
        _handle_request(handler, request, web_client)
    end
end

end # module VoSlackExt
