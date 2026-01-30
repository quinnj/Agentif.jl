abstract type AgentEvent end

function event_timestamp()
    return floor(Int, time() * 1000)
end

struct AgentEvaluateStartEvent <: AgentEvent
    id::UID8
    timestamp::Int64
end

function AgentEvaluateStartEvent(id::UID8)
    return AgentEvaluateStartEvent(id, event_timestamp())
end

struct AgentEvaluateEndEvent <: AgentEvent
    id::UID8
    timestamp::Int64
    result::Union{Nothing, AgentResult}
end

function AgentEvaluateEndEvent(id::UID8, result)
    return AgentEvaluateEndEvent(id, event_timestamp(), result)
end

struct TurnStartEvent <: AgentEvent
    id::UID8
    timestamp::Int64
    turn::Int
end

function TurnStartEvent(id::UID8, turn::Int)
    return TurnStartEvent(id, event_timestamp(), turn)
end

struct TurnEndEvent <: AgentEvent
    id::UID8
    timestamp::Int64
    turn::Int
    assistant_message::Union{Nothing, AssistantMessage}
    pending_tool_calls::Vector{PendingToolCall}
end

function TurnEndEvent(
        id::UID8,
        turn::Int,
        assistant_message::Union{Nothing, AssistantMessage},
        pending_tool_calls::Vector{PendingToolCall},
    )
    return TurnEndEvent(id, event_timestamp(), turn, assistant_message, pending_tool_calls)
end

struct MessageStartEvent{M <: AgentMessage} <: AgentEvent
    timestamp::Int64
    role::Symbol
    message::M
end

function MessageStartEvent(role::Symbol, message::M) where {M <: AgentMessage}
    return MessageStartEvent{M}(event_timestamp(), role, message)
end

struct MessageUpdateEvent{M <: AgentMessage} <: AgentEvent
    timestamp::Int64
    role::Symbol
    message::M
    kind::Symbol
    delta::String
    item_id::Union{Nothing, String}
end

function MessageUpdateEvent(
        role::Symbol,
        message::M,
        kind::Symbol,
        delta::String,
        item_id::Union{Nothing, String},
    ) where {M <: AgentMessage}
    return MessageUpdateEvent{M}(event_timestamp(), role, message, kind, delta, item_id)
end

struct MessageEndEvent{M <: AgentMessage} <: AgentEvent
    timestamp::Int64
    role::Symbol
    message::M
end

function MessageEndEvent(role::Symbol, message::M) where {M <: AgentMessage}
    return MessageEndEvent{M}(event_timestamp(), role, message)
end

struct ToolCallRequestEvent <: AgentEvent
    timestamp::Int64
    tool_call::PendingToolCall
    requires_approval::Bool
end

function ToolCallRequestEvent(tool_call::PendingToolCall, requires_approval::Bool)
    return ToolCallRequestEvent(event_timestamp(), tool_call, requires_approval)
end

struct ToolExecutionStartEvent <: AgentEvent
    timestamp::Int64
    tool_call::PendingToolCall
end

function ToolExecutionStartEvent(tool_call::PendingToolCall)
    return ToolExecutionStartEvent(event_timestamp(), tool_call)
end

struct ToolExecutionEndEvent <: AgentEvent
    timestamp::Int64
    tool_call::PendingToolCall
    result::ToolResultMessage
    duration_ms::Int64
end

function ToolExecutionEndEvent(tool_call::PendingToolCall, result::ToolResultMessage)
    return ToolExecutionEndEvent(event_timestamp(), tool_call, result, 0)
end

function ToolExecutionEndEvent(tool_call::PendingToolCall, result::ToolResultMessage, duration_ms::Int64)
    return ToolExecutionEndEvent(event_timestamp(), tool_call, result, duration_ms)
end

struct AgentErrorEvent <: AgentEvent
    timestamp::Int64
    error::Exception
end

function AgentErrorEvent(error::Exception)
    return AgentErrorEvent(event_timestamp(), error)
end
