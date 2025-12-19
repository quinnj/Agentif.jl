abstract type AgentEvent end

abstract type AgentMessage end

struct UserTextMessage <: AgentMessage
    text::String
end

mutable struct AssistantTextMessage <: AgentMessage
    response_id::Union{Nothing,String}
    text::String
    refusal::String
    reasoning::String
end

AssistantTextMessage(; response_id::Union{Nothing,String}=nothing) = AssistantTextMessage(response_id, "", "", "")

@kwarg struct ToolResultMessage <: AgentMessage
    call_id::String
    name::String
    arguments::String
    output::String
    is_error::Bool
end

struct AgentEvaluateStartEvent <: AgentEvent end

struct AgentEvaluateEndEvent <: AgentEvent
    result
end

struct TurnStartEvent <: AgentEvent
    turn::Int
end

struct TurnEndEvent <: AgentEvent
    turn::Int
    assistant_message::Union{Nothing,AssistantTextMessage}
    pending_tool_calls::Vector{PendingToolCall}
end

struct MessageStartEvent{M<:AgentMessage} <: AgentEvent
    role::Symbol
    message::M
end

struct MessageUpdateEvent{M<:AgentMessage} <: AgentEvent
    role::Symbol
    message::M
    kind::Symbol
    delta::String
    item_id::Union{Nothing,String}
end

struct MessageEndEvent{M<:AgentMessage} <: AgentEvent
    role::Symbol
    message::M
end

struct ToolCallRequestEvent <: AgentEvent
    tool_call::PendingToolCall
    requires_approval::Bool
end

struct ToolExecutionStartEvent <: AgentEvent
    tool_call::PendingToolCall
end

struct ToolExecutionEndEvent <: AgentEvent
    tool_call::PendingToolCall
    result::ToolResultMessage
end

struct AgentErrorEvent <: AgentEvent
    error::Exception
end
