abstract type AgentEvent end

function event_timestamp()
    return floor(Int, time() * 1000)
end

struct AgentEvaluateStartEvent <: AgentEvent
    timestamp::Int64
end

AgentEvaluateStartEvent() = AgentEvaluateStartEvent(event_timestamp())

struct AgentEvaluateEndEvent <: AgentEvent
    timestamp::Int64
    result
end

AgentEvaluateEndEvent(result) = AgentEvaluateEndEvent(event_timestamp(), result)

struct TurnStartEvent <: AgentEvent
    timestamp::Int64
    turn::Int
end

TurnStartEvent(turn::Int) = TurnStartEvent(event_timestamp(), turn)

struct TurnEndEvent <: AgentEvent
    timestamp::Int64
    turn::Int
    assistant_message::Union{Nothing,AssistantMessage}
    pending_tool_calls::Vector{PendingToolCall}
end

TurnEndEvent(turn::Int, assistant_message::Union{Nothing,AssistantMessage}, pending_tool_calls::Vector{PendingToolCall}) = TurnEndEvent(event_timestamp(), turn, assistant_message, pending_tool_calls)

struct MessageStartEvent{M<:AgentMessage} <: AgentEvent
    timestamp::Int64
    role::Symbol
    message::M
end

MessageStartEvent(role::Symbol, message::M) where {M<:AgentMessage} = MessageStartEvent{M}(event_timestamp(), role, message)

struct MessageUpdateEvent{M<:AgentMessage} <: AgentEvent
    timestamp::Int64
    role::Symbol
    message::M
    kind::Symbol
    delta::String
    item_id::Union{Nothing,String}
end

MessageUpdateEvent(role::Symbol, message::M, kind::Symbol, delta::String, item_id::Union{Nothing,String}) where {M<:AgentMessage} = MessageUpdateEvent{M}(event_timestamp(), role, message, kind, delta, item_id)

struct MessageEndEvent{M<:AgentMessage} <: AgentEvent
    timestamp::Int64
    role::Symbol
    message::M
end

MessageEndEvent(role::Symbol, message::M) where {M<:AgentMessage} = MessageEndEvent{M}(event_timestamp(), role, message)

struct ToolCallRequestEvent <: AgentEvent
    timestamp::Int64
    tool_call::PendingToolCall
    requires_approval::Bool
end

ToolCallRequestEvent(tool_call::PendingToolCall, requires_approval::Bool) = ToolCallRequestEvent(event_timestamp(), tool_call, requires_approval)

struct ToolExecutionStartEvent <: AgentEvent
    timestamp::Int64
    tool_call::PendingToolCall
end

ToolExecutionStartEvent(tool_call::PendingToolCall) = ToolExecutionStartEvent(event_timestamp(), tool_call)

struct ToolExecutionEndEvent <: AgentEvent
    timestamp::Int64
    tool_call::PendingToolCall
    result::ToolResultMessage
    duration_ms::Int64
end

ToolExecutionEndEvent(tool_call::PendingToolCall, result::ToolResultMessage) = ToolExecutionEndEvent(event_timestamp(), tool_call, result, 0)
ToolExecutionEndEvent(tool_call::PendingToolCall, result::ToolResultMessage, duration_ms::Int64) = ToolExecutionEndEvent(event_timestamp(), tool_call, result, duration_ms)

struct AgentErrorEvent <: AgentEvent
    timestamp::Int64
    error::Exception
end

AgentErrorEvent(error::Exception) = AgentErrorEvent(event_timestamp(), error)
