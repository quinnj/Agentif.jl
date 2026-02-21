module VoMSTeamsExt

using MSTeams
import Agentif
import Vo
export MSTeamsTriggerSource

# === Channel (unchanged from AgentifMSTeamsExt) ===

mutable struct MSTeamsChannel <: Agentif.AbstractChannel
    client::MSTeams.BotClient
    activity::AbstractDict
    user_id::String
    user_name::String
    # "personal" = DM, "groupChat" = group, "channel" = team channel
    conversation_type::String
    io::Union{Nothing, IOBuffer}
end

function Agentif.start_streaming(ch::MSTeamsChannel)
    if ch.io === nothing
        ch.io = IOBuffer()
    end
end

function Agentif.append_to_stream(ch::MSTeamsChannel, delta::AbstractString)
    ch.io === nothing && return
    write(ch.io, delta)
end

Agentif.finish_streaming(::MSTeamsChannel) = nothing

function Agentif.close_channel(ch::MSTeamsChannel)
    io = ch.io
    io === nothing && return
    text = String(take!(io))
    if !isempty(text)
        MSTeams.reply_text(ch.client, ch.activity, text)
    end
    ch.io = nothing
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

    from = get(() -> nothing, activity, "from")
    user_id = from !== nothing ? string(get(() -> "", from, "id")) : ""
    user_name = from !== nothing ? string(get(() -> "", from, "name")) : ""

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

    direct_ping = conversation_type == "personal" || occursin("<at>", lowercase(text))

    @info "VoMSTeamsExt: Processing message" conversation_id=conv_id conversation_type=conversation_type user_id=user_id direct_ping=direct_ping text_length=length(text)

    Threads.@spawn try
        ch = MSTeamsChannel(client, activity, user_id, user_name, conversation_type, nothing)
        Agentif.with_channel(ch) do
            handler(text)
        end
    catch e
        @error "VoMSTeamsExt: handler error" conversation_id=conv_id exception=(e, catch_backtrace())
    end
end

# === TriggerSource ===

struct MSTeamsTriggerSource <: Vo.TriggerSource
    name::String
    app_id::String
    app_password::String
    host::String
    port::Int
    path::String
end

function MSTeamsTriggerSource(;
        name::String="msteams",
        app_id::AbstractString=ENV["MSTEAMS_APP_ID"],
        app_password::AbstractString=ENV["MSTEAMS_APP_PASSWORD"],
        host::String="0.0.0.0",
        port::Int=3978,
        path::String="/api/messages",
    )
    MSTeamsTriggerSource(name, String(app_id), String(app_password), host, port, path)
end

Vo.source_name(s::MSTeamsTriggerSource) = s.name

function Vo.run(handler::Function, source::MSTeamsTriggerSource)
    client = MSTeams.BotClient(; app_id=source.app_id, app_password=source.app_password)
    @info "VoMSTeamsExt: Starting webhook server (host=$(source.host), port=$(source.port), path=$(source.path))"
    MSTeams.run_server(; host=source.host, port=source.port, client=client, path=source.path) do activity
        _handle_activity(handler, activity, client)
        return nothing
    end
end

end # module VoMSTeamsExt
