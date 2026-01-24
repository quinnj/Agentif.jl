abstract type AgentMessage end

@kwarg struct AgentToolCall
    call_id::String
    name::String
    arguments::String
end

struct UserMessage <: AgentMessage
    text::String
end

@kwarg mutable struct AssistantMessage <: AgentMessage
    response_id::Union{Nothing, String} = nothing
    text::String = ""
    reasoning::String = ""
    refusal::String = ""
    tool_calls::Vector{AgentToolCall} = AgentToolCall[]
    kind::String = "text"
end

@kwarg struct ToolResultMessage <: AgentMessage
    call_id::String
    name::String
    arguments::String
    output::String
    is_error::Bool
end

const AGENT_MESSAGE_TYPE_USER = "user"
const AGENT_MESSAGE_TYPE_ASSISTANT = "assistant"
const AGENT_MESSAGE_TYPE_TOOL_RESULT = "tool_result"

JSON.lower(x::UserMessage) = (; type = AGENT_MESSAGE_TYPE_USER, text = x.text)
JSON.lower(x::AssistantMessage) = (;
    type = AGENT_MESSAGE_TYPE_ASSISTANT,
    response_id = x.response_id,
    text = x.text,
    reasoning = x.reasoning,
    refusal = x.refusal,
    tool_calls = x.tool_calls,
    kind = x.kind,
)
JSON.lower(x::ToolResultMessage) = (;
    type = AGENT_MESSAGE_TYPE_TOOL_RESULT,
    call_id = x.call_id,
    name = x.name,
    arguments = x.arguments,
    output = x.output,
    is_error = x.is_error,
)

JSON.@choosetype AgentMessage x -> begin
    msg_type = x.type[]
    if msg_type == AGENT_MESSAGE_TYPE_USER
        return UserMessage
    elseif msg_type == AGENT_MESSAGE_TYPE_ASSISTANT
        return AssistantMessage
    elseif msg_type == AGENT_MESSAGE_TYPE_TOOL_RESULT
        return ToolResultMessage
    end
    throw(ArgumentError("Unknown agent message type: $(msg_type)"))
end

const AgentTurnInput = Union{String, Vector{ToolResultMessage}}

function include_in_context(msg::AgentMessage)
    if msg isa UserMessage
        return true
    elseif msg isa AssistantMessage
        return msg.kind != "tool"
    elseif msg isa ToolResultMessage
        return true
    end
    return false
end

@kwarg mutable struct Usage
    input::Int = 0
    output::Int = 0
    cacheRead::Int = 0
    cacheWrite::Int = 0
    total::Int = 0
end

function add_usage!(base::Usage, delta::Usage)
    base.input += delta.input
    base.output += delta.output
    base.cacheRead += delta.cacheRead
    base.cacheWrite += delta.cacheWrite
    base.total += delta.total
    return base
end

@kwarg mutable struct AgentState
    messages::Vector{AgentMessage} = AgentMessage[]
    response_id::Union{Nothing, String} = nothing
    usage::Usage = Usage()
    pending_tool_calls::Vector{PendingToolCall} = PendingToolCall[]
end

function set!(dest::AgentState, source::AgentState)
    dest.messages = source.messages
    dest.response_id = source.response_id
    dest.usage = source.usage
    dest.pending_tool_calls = source.pending_tool_calls
    return
end

@kwarg struct AgentResponse
    message::AssistantMessage
    usage::Usage
    stop_reason::Symbol
end

@kwarg struct AgentResult
    state::AgentState
end
