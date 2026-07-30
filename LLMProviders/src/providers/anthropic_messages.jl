module AnthropicMessages

using StructUtils, JSON, JSONSchema


schema(::Type{T}) where {T} = JSONSchema.schema(
    T;
    draft = "https://json-schema.org/draft/2020-12/schema",
    refs = :defs,
    all_fields_required = false,
    additionalProperties = false,
)

@omit_null @kwarg struct CacheControl
    type::String
    # "1h" opts into the extended-TTL cache; omitted means the default 5m ephemeral cache.
    ttl::Union{Nothing, String} = nothing
end

@omit_null @kwarg mutable struct TextBlock
    type::String = "text"
    text::String
    cache_control::Union{Nothing, CacheControl} = nothing
end

@omit_null @kwarg mutable struct ThinkingBlock
    type::String = "thinking"
    thinking::String
    signature::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct RedactedThinkingBlock
    type::String = "redacted_thinking"
    data::String = ""
end

@omit_null @kwarg struct ImageSource
    type::String = "base64"
    media_type::String
    data::String
end

@omit_null @kwarg mutable struct ImageBlock
    type::String = "image"
    source::ImageSource
    cache_control::Union{Nothing, CacheControl} = nothing
end

@omit_null @kwarg mutable struct ToolUseBlock
    type::String = "tool_use"
    id::String
    name::String
    input::Any
end

const ToolResultContentBlock = Union{TextBlock, ImageBlock}

@omit_null @kwarg mutable struct ToolResultBlock
    type::String = "tool_result"
    tool_use_id::String
    content::Union{String, Vector{ToolResultContentBlock}}
    is_error::Union{Nothing, Bool} = nothing
    cache_control::Union{Nothing, CacheControl} = nothing
end

# Catch-all so unrecognized content block types (e.g. server_tool_use) parse
# without throwing; mirrors OpenAIResponses.UnknownOutput.
@omit_null @kwarg struct UnknownContentBlock
    type::Union{Nothing, String} = nothing
end

const ContentBlock = Union{TextBlock, ThinkingBlock, RedactedThinkingBlock, ImageBlock, ToolUseBlock, ToolResultBlock, UnknownContentBlock}

JSON.@choosetype ContentBlock x -> begin
    type = try
        x.type[]
    catch
        nothing
    end
    if type == "text"
        return TextBlock
    elseif type == "thinking"
        return ThinkingBlock
    elseif type == "redacted_thinking"
        return RedactedThinkingBlock
    elseif type == "image"
        return ImageBlock
    elseif type == "tool_use"
        return ToolUseBlock
    elseif type == "tool_result"
        return ToolResultBlock
    else
        return UnknownContentBlock
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

@omit_null @kwarg struct ThinkingDelta
    type::String = "thinking_delta"
    thinking::String
end

@omit_null @kwarg struct SignatureDelta
    type::String = "signature_delta"
    signature::String
end

@omit_null @kwarg struct InputJsonDelta
    type::String = "input_json_delta"
    partial_json::String
end

# Catch-all so unrecognized delta types (e.g. citations_delta) parse without throwing.
@omit_null @kwarg struct UnknownContentBlockDelta
    type::Union{Nothing, String} = nothing
end

const ContentBlockDelta = Union{TextDelta, ThinkingDelta, SignatureDelta, InputJsonDelta, UnknownContentBlockDelta}

JSON.@choosetype ContentBlockDelta x -> begin
    type = try
        x.type[]
    catch
        nothing
    end
    if type == "text_delta"
        return TextDelta
    elseif type == "thinking_delta"
        return ThinkingDelta
    elseif type == "signature_delta"
        return SignatureDelta
    elseif type == "input_json_delta"
        return InputJsonDelta
    else
        return UnknownContentBlockDelta
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

# Two distinct mechanisms:
#   adaptive thinking  -> {"type": "adaptive"} (+ optional "display")
#   extended thinking  -> {"type": "enabled", "budget_tokens": N}
#   off                -> {"type": "disabled"} (rejected on always-thinking models)
# `display` is "omitted" | "summarized"; it is invalid with type "disabled".
@omit_null @kwarg struct ThinkingConfig
    type::String = "adaptive"
    budget_tokens::Union{Nothing, Int} = nothing
    display::Union{Nothing, String} = nothing
end

# Carries the effort level: low | medium | high | xhigh | max (model dependent).
@omit_null @kwarg struct OutputConfig
    effort::Union{Nothing, String} = nothing
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
    # `Any` (like tool_choice) so callers can pass a raw Dict/NamedTuple through
    # `model.kw`/stream kwargs while the adapter builds the typed structs above.
    thinking::Union{Nothing, Any} = nothing
    output_config::Union{Nothing, Any} = nothing
    metadata::Union{Nothing, Any} = nothing
end

end # module AnthropicMessages
