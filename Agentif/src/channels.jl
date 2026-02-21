# AbstractChannel interface for routing agent output to different frontends
abstract type AbstractChannel end

# --- Channel user identity ---

"""
    ChannelUser(id, name)

Represents the user who sent the current message on a channel.
`id` is a platform-specific identifier (Slack user ID, phone number, etc.).
`name` is a human-readable display name.
"""
struct ChannelUser
    id::String
    name::String
end

# Interface stubs - each channel type should implement these
# start_streaming(ch) -> nothing (channel should mutate itself to set up streaming state)
function start_streaming end
# append_to_stream(ch, delta) -> nothing
function append_to_stream end
# finish_streaming(ch) -> nothing (called per-message on MessageEndEvent)
function finish_streaming end
# send_message(ch, msg) -> nothing (non-streaming message)
function send_message end
# close_channel(ch) -> nothing (final cleanup in finally block)
function close_channel end
# channel_id(ch) -> String (stable identifier for session mapping)
function channel_id end
channel_id(::AbstractChannel) = "default"

# --- Group/privacy/user interface ---
# These have sensible defaults for backward compatibility (single-user DM behavior).

"""
    is_group(ch::AbstractChannel) -> Bool

Whether this channel is a multi-user conversation (group chat, public channel, etc.).
Default: `false` (DM/single-user behavior).
"""
function is_group end
is_group(::AbstractChannel) = false

"""
    is_private(ch::AbstractChannel) -> Bool

Whether this channel's data should be restricted from cross-channel search.
Private channels (DMs, private groups) should not have their sessions, memories,
or documents searchable from other channels.
Default: `true` (conservative — data is private unless explicitly public).
"""
function is_private end
is_private(::AbstractChannel) = true

"""
    get_current_user(ch::AbstractChannel) -> Union{Nothing, ChannelUser}

Return the identity of the user who sent the current message.
Default: `nothing` (no user identity available).
"""
function get_current_user end
get_current_user(::AbstractChannel) = nothing

"""
    source_message_id(ch::AbstractChannel) -> Union{Nothing, String}

Return the platform-specific message ID of the incoming message that triggered
this evaluation. Used for tracking which stored data (memories, session entries)
originated from a specific message, enabling scrubbing on deletion.
Default: `nothing` (no message ID tracking).
"""
function source_message_id end
source_message_id(::AbstractChannel) = nothing

"""
    create_channel_tools(ch::AbstractChannel) -> Vector{AgentTool}

Return platform-specific tools for the current channel (e.g. emoji reactions).
Channel extensions should specialize this for their channel types.
Default: empty vector.
"""
create_channel_tools(::AbstractChannel) = AgentTool[]

const CURRENT_CHANNEL = ScopedValue{Union{AbstractChannel, Nothing}}(nothing)

"""
    with_channel(f, ch::AbstractChannel)

Execute `f` with `CURRENT_CHANNEL` bound to `ch`.
"""
with_channel(f, ch::AbstractChannel) = @with CURRENT_CHANNEL => ch f()

"""
    NO_REPLY_SENTINEL

Single-character sentinel (`∅`, U+2205) that an agent can emit as the first character
of a response to signal "no output". The channel middleware detects this on the first
text delta and suppresses the entire response without ever starting to stream.
Used by group chat prompts to let the agent stay silent when it has nothing to add.
"""
const NO_REPLY_SENTINEL = '∅'

function channel_middleware(agent_handler::AgentHandler, ch::Union{Nothing, AbstractChannel})
    return function (f, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort; kw...)
        ch === nothing && return agent_handler(f, agent, state, current_input, abort; kw...)
        streaming = false
        suppressed = false
        try
            return @with CURRENT_CHANNEL => ch agent_handler(function (event)
                if event isa MessageStartEvent && event.role == :assistant
                    streaming = false
                    suppressed = false
                elseif event isa MessageUpdateEvent && event.role == :assistant && event.kind == :text
                    if !streaming && !suppressed
                        if !isempty(event.delta) && event.delta[1] == NO_REPLY_SENTINEL
                            suppressed = true
                        else
                            start_streaming(ch)
                            streaming = true
                        end
                    end
                    streaming && append_to_stream(ch, event.delta)
                elseif event isa MessageEndEvent && event.role == :assistant
                    streaming && finish_streaming(ch)
                end
                f(event)
            end, agent, state, current_input, abort; kw...)
        finally
            try
                close_channel(ch)
            catch
            end
        end
    end
end
