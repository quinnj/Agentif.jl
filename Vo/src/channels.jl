# ReplChannel - prints streaming text to an IO
struct ReplChannel <: Agentif.AbstractChannel
    io::IO
end
ReplChannel() = ReplChannel(stdout)

Agentif.channel_id(::ReplChannel) = "repl"
Agentif.start_streaming(ch::ReplChannel) = ch.io
Agentif.append_to_stream(::ReplChannel, io::IO, delta::AbstractString) = print(io, delta)
Agentif.finish_streaming(::ReplChannel, io::IO) = println(io)
Agentif.send_message(ch::ReplChannel, msg) = println(ch.io, msg)
Agentif.close_channel(::ReplChannel, ::IO) = nothing
