abstract type AgentMessage end

@kwarg struct AgentToolCall
    call_id::String
    name::String
    arguments::String
end

abstract type ContentBlock end

@kwarg mutable struct TextContent <: ContentBlock
    type::String = "text"
    text::String
    textSignature::Union{Nothing, String} = nothing
end

@kwarg mutable struct ThinkingContent <: ContentBlock
    type::String = "thinking"
    thinking::String
    thinkingSignature::Union{Nothing, String} = nothing
end

@kwarg mutable struct ImageContent <: ContentBlock
    type::String = "image"
    data::String
    mimeType::String
end

@kwarg mutable struct ToolCallContent <: ContentBlock
    type::String = "toolCall"
    id::String
    name::String
    arguments::Dict{String, Any}
    thoughtSignature::Union{Nothing, String} = nothing
end

const UserContentBlock = Union{TextContent, ImageContent}
const AssistantContentBlock = Union{TextContent, ThinkingContent, ToolCallContent}
const ToolResultContentBlock = Union{TextContent, ImageContent}

struct UserMessage <: AgentMessage
    content::Vector{UserContentBlock}
end

@kwarg mutable struct AssistantMessage <: AgentMessage
    response_id::Union{Nothing, String} = nothing
    provider::String
    api::String
    model::String
    content::Vector{AssistantContentBlock} = AssistantContentBlock[]
    tool_calls::Vector{AgentToolCall} = AgentToolCall[]
end

@kwarg struct ToolResultMessage <: AgentMessage
    call_id::String
    name::String
    content::Vector{ToolResultContentBlock}
    is_error::Bool
end

const AGENT_MESSAGE_TYPE_USER = "user"
const AGENT_MESSAGE_TYPE_ASSISTANT = "assistant"
const AGENT_MESSAGE_TYPE_TOOL_RESULT = "tool_result"

TextContent(text::String) = TextContent(; text)
ThinkingContent(thinking::String) = ThinkingContent(; thinking)
ImageContent(data::String, mimeType::String) = ImageContent(; data, mimeType)
UserMessage(text::String) = UserMessage(UserContentBlock[TextContent(text)])

function ToolResultMessage(call_id::String, name::String, output::String; is_error::Bool = false)
    return ToolResultMessage(; call_id, name, content = ToolResultContentBlock[TextContent(output)], is_error)
end

function content_text(blocks::Vector{<:ContentBlock})
    parts = String[]
    for block in blocks
        block isa TextContent && push!(parts, block.text)
    end
    return join(parts, "")
end

function content_thinking(blocks::Vector{<:ContentBlock})
    parts = String[]
    for block in blocks
        block isa ThinkingContent && push!(parts, block.thinking)
    end
    return join(parts, "")
end

message_text(msg::UserMessage) = content_text(msg.content)
message_text(msg::AssistantMessage) = content_text(msg.content)
message_text(msg::ToolResultMessage) = content_text(msg.content)

message_thinking(msg::AssistantMessage) = content_thinking(msg.content)

function message_has_images(msg::AgentMessage)
    if msg isa UserMessage || msg isa ToolResultMessage
        for block in msg.content
            block isa ImageContent && return true
        end
    end
    return false
end

function append_text!(msg::AssistantMessage, delta::String)
    if isempty(msg.content) || !(msg.content[end] isa TextContent)
        push!(msg.content, TextContent(delta))
    else
        msg.content[end].text *= delta
    end
    return msg
end

function append_thinking!(msg::AssistantMessage, delta::String)
    if isempty(msg.content) || !(msg.content[end] isa ThinkingContent)
        push!(msg.content, ThinkingContent(delta))
    else
        msg.content[end].thinking *= delta
    end
    return msg
end

function set_last_thinking!(msg::AssistantMessage, text::String)
    for idx in length(msg.content):-1:1
        block = msg.content[idx]
        if block isa ThinkingContent
            block.thinking = text
            return msg
        end
    end
    push!(msg.content, ThinkingContent(text))
    return msg
end

function set_last_text!(msg::AssistantMessage, text::String)
    for idx in length(msg.content):-1:1
        block = msg.content[idx]
        if block isa TextContent
            block.text = text
            return msg
        end
    end
    push!(msg.content, TextContent(text))
    return msg
end

JSON.lower(x::TextContent) = (; type = x.type, text = x.text, textSignature = x.textSignature)
JSON.lower(x::ThinkingContent) = (; type = x.type, thinking = x.thinking, thinkingSignature = x.thinkingSignature)
JSON.lower(x::ImageContent) = (; type = x.type, data = x.data, mimeType = x.mimeType)
JSON.lower(x::ToolCallContent) = (;
    type = x.type,
    id = x.id,
    name = x.name,
    arguments = x.arguments,
    thoughtSignature = x.thoughtSignature,
)

JSON.lower(x::UserMessage) = (; type = AGENT_MESSAGE_TYPE_USER, content = x.content)
JSON.lower(x::AssistantMessage) = (;
    type = AGENT_MESSAGE_TYPE_ASSISTANT,
    response_id = x.response_id,
    provider = x.provider,
    api = x.api,
    model = x.model,
    content = x.content,
    tool_calls = x.tool_calls,
)
JSON.lower(x::ToolResultMessage) = (;
    type = AGENT_MESSAGE_TYPE_TOOL_RESULT,
    call_id = x.call_id,
    name = x.name,
    content = x.content,
    is_error = x.is_error,
)

JSON.@choosetype ContentBlock x -> begin
    block_type = x.type[]
    if block_type == "text"
        return TextContent
    elseif block_type == "thinking"
        return ThinkingContent
    elseif block_type == "image"
        return ImageContent
    elseif block_type == "toolCall"
        return ToolCallContent
    end
    throw(ArgumentError("Unknown content block type: $(block_type)"))
end

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

function StructUtils.make(st::StructUtils.StructStyle, ::Type{Union{TextContent, ImageContent}}, source, tags)
    return StructUtils.make(st, ContentBlock, source, tags)
end

function StructUtils.make(st::StructUtils.StructStyle, ::Type{Union{TextContent, ImageContent}}, source)
    return StructUtils.make(st, ContentBlock, source)
end

function StructUtils.make(st::StructUtils.StructStyle, ::Type{Union{TextContent, ThinkingContent, ToolCallContent}}, source, tags)
    return StructUtils.make(st, ContentBlock, source, tags)
end

function StructUtils.make(st::StructUtils.StructStyle, ::Type{Union{TextContent, ThinkingContent, ToolCallContent}}, source)
    return StructUtils.make(st, ContentBlock, source)
end

const AgentTurnInput = Union{String, Vector{ToolResultMessage}, Vector{UserContentBlock}, UserMessage}

function include_in_context(msg::AgentMessage)
    return msg isa AgentMessage
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
    most_recent_stop_reason::Union{Nothing, Symbol} = nothing
    session_id::Union{Nothing, String} = nothing
end

function set!(dest::AgentState, source::AgentState)
    dest.messages = source.messages
    dest.response_id = source.response_id
    dest.usage = source.usage
    dest.pending_tool_calls = source.pending_tool_calls
    dest.most_recent_stop_reason = source.most_recent_stop_reason
    dest.session_id = source.session_id
    return
end
