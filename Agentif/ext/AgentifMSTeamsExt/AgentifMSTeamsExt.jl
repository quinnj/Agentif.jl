module AgentifMSTeamsExt

using MSTeams
import Agentif
using Logging
using ScopedValues: @with

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
    user_id::String
    user_name::String
    # "personal" = DM, "groupChat" = group, "channel" = team channel
    conversation_type::String
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

function Agentif.is_group(ch::MSTeamsChannel)
    return ch.conversation_type != "personal"
end

function Agentif.is_private(ch::MSTeamsChannel)
    # "personal" = DM (private), "groupChat" = group (private)
    # "channel" = team channel (public within org)
    return ch.conversation_type in ("personal", "groupChat")
end

function Agentif.get_current_user(ch::MSTeamsChannel)
    isempty(ch.user_id) && return nothing
    return Agentif.ChannelUser(ch.user_id, ch.user_name)
end

function _handle_activity(handler::Function, activity::AbstractDict, client::MSTeams.BotClient)
    activity_type = get(() -> nothing, activity, "type")
    activity_type == "message" || return

    text = get(() -> nothing, activity, "text")
    (text === nothing || isempty(text)) && return

    # Extract user identity
    from = get(() -> nothing, activity, "from")
    user_id = from !== nothing ? string(get(() -> "", from, "id")) : ""
    user_name = from !== nothing ? string(get(() -> "", from, "name")) : ""

    # Determine conversation type
    conversation = get(() -> nothing, activity, "conversation")
    conversation_type = "personal"
    if conversation !== nothing
        ct = get(() -> nothing, conversation, "conversationType")
        if ct !== nothing
            conversation_type = string(ct)
        elseif get(() -> false, conversation, "isGroup") === true
            conversation_type = "groupChat"
        end
    end

    conv_id = conversation !== nothing ? get(() -> "unknown", conversation, "id") : "unknown"

    # Detect direct ping: personal chat or <at> mention tag in text
    direct_ping = conversation_type == "personal" || occursin("<at>", lowercase(text))

    @info "AgentifMSTeamsExt: Processing message" conversation_id=conv_id conversation_type=conversation_type user_id=user_id direct_ping=direct_ping text_length=length(text)

    try
        ch = MSTeamsChannel(client, activity, user_id, user_name, conversation_type)
        Agentif.with_channel(ch) do
            @with Agentif.DIRECT_PING => direct_ping handler(text)
        end
    catch e
        @error "AgentifMSTeamsExt: handler error" conversation_id=conv_id exception=(e, catch_backtrace())
    end
end

end # module AgentifMSTeamsExt
