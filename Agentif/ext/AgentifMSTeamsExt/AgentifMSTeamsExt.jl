module AgentifMSTeamsExt

using MSTeams
import Agentif
using Logging

export run_msteams_bot

"""
    run_msteams_bot(handler; app_id=ENV["MSTEAMS_APP_ID"], app_password=ENV["MSTEAMS_APP_PASSWORD"], kwargs...)

Start an MS Teams bot that listens for incoming messages via webhook and calls
`handler(text::String)` for each one, with the appropriate `AbstractChannel`
scoped via `Agentif.with_channel`.

Note: MS Teams does not support streaming, so all streamed text is buffered
and sent as a single reply when the channel is closed.
"""
function run_msteams_bot(handler::Function;
        app_id::AbstractString = ENV["MSTEAMS_APP_ID"],
        app_password::AbstractString = ENV["MSTEAMS_APP_PASSWORD"],
        host::String = "0.0.0.0",
        port::Int = 3978,
        path::String = "/api/messages",
        kwargs...)
    client = MSTeams.BotClient(; app_id=app_id, app_password=app_password)
    @info "AgentifMSTeamsExt: Starting webhook server (host=$(host), port=$(port), path=$(path))"

    MSTeams.run_server(; host=host, port=port, client=client, path=path) do activity
        _handle_activity(handler, activity, client)
        return nothing
    end
end

# MSTeamsChannel — buffers responses and sends as a single reply
# (MS Teams does not support streaming)
struct MSTeamsChannel <: Agentif.AbstractChannel
    client::MSTeams.BotClient
    activity::AbstractDict
end

function Agentif.start_streaming(::MSTeamsChannel)
    return IOBuffer()
end

function Agentif.append_to_stream(::MSTeamsChannel, io::IOBuffer, delta::AbstractString)
    write(io, delta)
end

function Agentif.finish_streaming(::MSTeamsChannel, ::IOBuffer)
    return nothing
end

function Agentif.close_channel(ch::MSTeamsChannel, io::IOBuffer)
    text = String(take!(io))
    if !isempty(text)
        MSTeams.reply_text(ch.client, ch.activity, text)
    end
end

function Agentif.send_message(ch::MSTeamsChannel, msg)
    MSTeams.reply_text(ch.client, ch.activity, string(msg))
end

function Agentif.channel_id(ch::MSTeamsChannel)
    conversation = get(() -> nothing, ch.activity, "conversation")
    conv_id = conversation !== nothing ? get(() -> "unknown", conversation, "id") : "unknown"
    return "msteams:$(conv_id)"
end

function _handle_activity(handler::Function, activity::AbstractDict, client::MSTeams.BotClient)
    activity_type = get(() -> nothing, activity, "type")
    activity_type == "message" || return

    text = get(() -> nothing, activity, "text")
    (text === nothing || isempty(text)) && return

    conversation = get(() -> nothing, activity, "conversation")
    conv_id = conversation !== nothing ? get(() -> "unknown", conversation, "id") : "unknown"
    @info "AgentifMSTeamsExt: Processing message" conversation_id=conv_id text_length=length(text)

    try
        ch = MSTeamsChannel(client, activity)
        Agentif.with_channel(ch) do
            handler(text)
        end
    catch e
        @error "AgentifMSTeamsExt: handler error" conversation_id=conv_id exception=(e, catch_backtrace())
    end
end

end # module AgentifMSTeamsExt
