module AnthropicMessages

using StructUtils, JSON, JSONSchema

import ..Model

schema(::Type{T}) where {T} = JSONSchema.schema(
    T;
    draft = "https://json-schema.org/draft/2020-12/schema",
    refs = :defs,
    all_fields_required = false,
    additionalProperties = false,
)

@omit_null @kwarg struct CacheControl
    type::String
end

@omit_null @kwarg mutable struct TextBlock
    type::String = "text"
    text::String
    cache_control::Union{Nothing, CacheControl} = nothing
end

@omit_null @kwarg mutable struct ToolUseBlock
    type::String = "tool_use"
    id::String
    name::String
    input::Any
end

@omit_null @kwarg struct ToolResultBlock
    type::String = "tool_result"
    tool_use_id::String
    content::Union{String, Vector{TextBlock}}
    is_error::Union{Nothing, Bool} = nothing
end

const ContentBlock = Union{TextBlock, ToolUseBlock, ToolResultBlock}

JSON.@choosetype ContentBlock x -> begin
    type = x.type[]
    if type == "text"
        return TextBlock
    elseif type == "tool_use"
        return ToolUseBlock
    elseif type == "tool_result"
        return ToolResultBlock
    else
        return Any
    end
end

@omit_null @kwarg struct Message
    role::String
    content::Union{String, Vector{ContentBlock}} & (json = (choosetype = x -> x[] isa String ? String : Vector{ContentBlock},),)
end

@omit_null @kwarg struct Tool{T}
    name::String
    description::Union{Nothing, String} = nothing
    input_schema::JSONSchema.Schema{T}
end


@omit_null @kwarg struct Usage
    input_tokens::Union{Nothing, Int} = nothing
    output_tokens::Union{Nothing, Int} = nothing
    cache_creation_input_tokens::Union{Nothing, Int} = nothing
    cache_read_input_tokens::Union{Nothing, Int} = nothing
end

@omit_null @kwarg struct ResponseMessage
    id::Union{Nothing, String} = nothing
    role::String
    content::Vector{ContentBlock} = ContentBlock[]
    model::Union{Nothing, String} = nothing
    stop_reason::Union{Nothing, String} = nothing
    stop_sequence::Union{Nothing, String} = nothing
    usage::Union{Nothing, Usage} = nothing
end

@omit_null @kwarg struct Response
    id::String
    content::Vector{ContentBlock} = ContentBlock[]
    model::String
    role::String
    stop_reason::Union{Nothing, String} = nothing
    stop_sequence::Union{Nothing, String} = nothing
    usage::Union{Nothing, Usage} = nothing
end

@omit_null @kwarg struct TextDelta
    type::String = "text_delta"
    text::String
end

@omit_null @kwarg struct InputJsonDelta
    type::String = "input_json_delta"
    partial_json::String
end

const ContentBlockDelta = Union{TextDelta, InputJsonDelta}

JSON.@choosetype ContentBlockDelta x -> begin
    type = x.type[]
    if type == "text_delta"
        return TextDelta
    elseif type == "input_json_delta"
        return InputJsonDelta
    else
        return Any
    end
end

@omit_null @kwarg struct StreamMessageStartEvent
    type::String = "message_start"
    message::ResponseMessage
end

@omit_null @kwarg struct StreamContentBlockStartEvent
    type::String = "content_block_start"
    index::Int
    content_block::ContentBlock
end

@omit_null @kwarg struct StreamContentBlockDeltaEvent
    type::String = "content_block_delta"
    index::Int
    delta::ContentBlockDelta
end

@omit_null @kwarg struct StreamContentBlockStopEvent
    type::String = "content_block_stop"
    index::Int
end

@omit_null @kwarg struct StreamMessageDeltaEvent
    type::String = "message_delta"
    delta::Any = nothing
    usage::Union{Nothing, Usage} = nothing
end

@omit_null @kwarg struct StreamMessageStopEvent
    type::String = "message_stop"
end

@omit_null @kwarg struct StreamErrorEvent
    type::String = "error"
    error::Any = nothing
end

const StreamEvent = Union{
    StreamMessageStartEvent,
    StreamContentBlockStartEvent,
    StreamContentBlockDeltaEvent,
    StreamContentBlockStopEvent,
    StreamMessageDeltaEvent,
    StreamMessageStopEvent,
    StreamErrorEvent,
}

JSON.@choosetype StreamEvent x -> begin
    type = x.type[]
    if type == "message_start"
        return StreamMessageStartEvent
    elseif type == "content_block_start"
        return StreamContentBlockStartEvent
    elseif type == "content_block_delta"
        return StreamContentBlockDeltaEvent
    elseif type == "content_block_stop"
        return StreamContentBlockStopEvent
    elseif type == "message_delta"
        return StreamMessageDeltaEvent
    elseif type == "message_stop"
        return StreamMessageStopEvent
    elseif type == "error"
        return StreamErrorEvent
    else
        return Any
    end
end

@omit_null @kwarg struct Request
    model::String
    messages::Vector{Message}
    max_tokens::Int
    system::Union{Nothing, String, Vector{TextBlock}} = nothing
    tools::Union{Nothing, Vector{Tool}} = nothing
    tool_choice::Union{Nothing, Any} = nothing
    stream::Union{Nothing, Bool} = nothing
    temperature::Union{Nothing, Float64} = nothing
    top_p::Union{Nothing, Float64} = nothing
    stop_sequences::Union{Nothing, Vector{String}} = nothing
end

end # module AnthropicMessages
