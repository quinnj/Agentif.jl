# AbstractChannel interface for routing agent output to different frontends
abstract type AbstractChannel end

# Interface stubs - each channel type should implement these
# start_streaming(ch) -> stream handle (e.g. IO, StreamingMessage)
function start_streaming end
# append_to_stream(ch, stream, delta) -> nothing
function append_to_stream end
# finish_streaming(ch, stream) -> nothing (called per-message on MessageEndEvent)
function finish_streaming end
# send_message(ch, msg) -> nothing (non-streaming message)
function send_message end
# close_channel(ch, stream) -> nothing (final cleanup in finally block)
function close_channel end
# channel_id(ch) -> String (stable identifier for session mapping)
function channel_id end
channel_id(::AbstractChannel) = "default"

const CURRENT_CHANNEL = ScopedValue{Union{AbstractChannel, Nothing}}(nothing)

"""
    with_channel(f, ch::AbstractChannel)

Execute `f` with `CURRENT_CHANNEL` bound to `ch`.
"""
with_channel(f, ch::AbstractChannel) = @with CURRENT_CHANNEL => ch f()

function channel_middleware(agent_handler::AgentHandler, ch::Union{Nothing, AbstractChannel})
    return function (f, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort; kw...)
        ch === nothing && return agent_handler(f, agent, state, current_input, abort; kw...)
        stream_ref = Ref{Any}(nothing)
        try
            return @with CURRENT_CHANNEL => ch agent_handler(function (event)
                if event isa MessageStartEvent && event.role == :assistant
                    stream_ref[] = start_streaming(ch)
                elseif event isa MessageUpdateEvent && event.role == :assistant && event.kind == :text
                    s = stream_ref[]
                    s !== nothing && append_to_stream(ch, s, event.delta)
                elseif event isa MessageEndEvent && event.role == :assistant
                    s = stream_ref[]
                    s !== nothing && finish_streaming(ch, s)
                end
                f(event)
            end, agent, state, current_input, abort; kw...)
        finally
            s = stream_ref[]
            if s !== nothing
                try
                    close_channel(ch, s)
                catch
                end
            end
        end
    end
end
