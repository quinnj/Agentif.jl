module OpenAIResponses

using StructUtils, JSON, JSONSchema


function _required_field_names(::Type{T}) where {T}
    names = fieldnames(T)
    types = fieldtypes(T)
    required = String[]
    for (nm, ty) in zip(names, types)
        Nothing <: ty && continue
        push!(required, string(nm))
    end
    return required
end

function schema(::Type{T}) where {T}
    sch = JSONSchema.schema(T; all_fields_required = true, additionalProperties = false)
    required = _required_field_names(T)
    data = JSONSchema.spec(sch)
    if isempty(required)
        haskey(data, "required") && delete!(data, "required")
    else
        data["required"] = required
    end
    return sch
end

@omit_null @kwarg struct InputTextContent
    type::String = "input_text"
    text::String
end

@omit_null @kwarg struct InputImageContent
    type::String = "input_image"
    detail::String = "auto" # high, low, auto
    image_url::Union{Nothing, String} = nothing
    file_id::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct InputFileContent
    type::String = "input_file"
    file_data::Union{Nothing, String} = nothing
    file_id::Union{Nothing, String} = nothing
    file_url::Union{Nothing, String} = nothing
    filename::Union{Nothing, String} = nothing
end

const InputContent = Union{InputTextContent, InputImageContent, InputFileContent}

@omit_null @kwarg struct OutputTextContent
    type::String = "output_text"
    text::String
    annotations::Vector{Any} = []
    logprobs::Union{Nothing, Vector{Any}} = nothing
end

@omit_null @kwarg struct Refusal
    refusal::String
    type::String = "refusal"
end

@omit_null @kwarg struct ReasoningText
    text::Union{Nothing, String} = nothing
    type::String = "reasoning_text"
end

@omit_null @kwarg struct UnknownOutputContent
    type::Union{Nothing, String} = nothing
end

const OutputContent = Union{OutputTextContent, Refusal, ReasoningText, UnknownOutputContent}

JSON.@choosetype OutputContent x -> begin
    type = try
        x.type[]
    catch
        nothing
    end
    if type == "output_text"
        return OutputTextContent
    elseif type == "refusal"
        return Refusal
    elseif type == "reasoning_text"
        return ReasoningText
    else
        return UnknownOutputContent
    end
end

@omit_null @kwarg struct UnknownContent
    type::Union{Nothing, String} = nothing
end

const Content = Union{InputContent, OutputContent, UnknownContent}

JSON.@choosetype Content x -> begin
    type = try
        x.type[]
    catch
        nothing
    end
    if type == "input_text"
        return InputTextContent
    elseif type == "input_image"
        return InputImageContent
    elseif type == "input_file"
        return InputFileContent
    elseif type == "output_text"
        return OutputTextContent
    elseif type == "refusal"
        return Refusal
    elseif type == "reasoning_text"
        return ReasoningText
    else
        return UnknownContent
    end
end

@omit_null @kwarg struct Message
    id::Union{Nothing, String} = nothing
    status::Union{Nothing, String} = nothing # in_progress, completed, incomplete
    content::Union{String, Vector{Content}} & (json = (choosetype = x -> x[] isa String ? String : Vector{Content},),)
    role::String # user, assistant, developer, system
    type::String = "message"
end

@omit_null @kwarg struct FunctionToolCallOutput
    type::String = "function_call_output"
    call_id::String # from FunctionToolCall
    output::Union{String, Vector{InputContent}} & (json = (choosetype = x -> x[] isa String ? String : Vector{InputContent},),)
    id::Union{Nothing, String} = nothing
    status::Union{Nothing, String} = nothing # "in_progress", "completed", "incomplete"
end

@omit_null @kwarg struct UnknownItem
    type::Union{Nothing, String} = nothing
end

const InputItem = Union{Message, FunctionToolCallOutput, UnknownItem}

JSON.@choosetype InputItem x -> begin
    type = try
        x.type[]
    catch
        nothing
    end
    if type == "function_call_output"
        return FunctionToolCallOutput
    elseif type == "message" || type === nothing
        return Message
    else
        return UnknownItem
    end
end

@omit_null @kwarg struct FunctionTool
    name::String
    strict::Bool = true
    type::String = "function"
    description::Union{Nothing, String} = nothing
    parameters::Union{JSONSchema.Schema, AbstractDict{String, Any}}
end

const Tool = Union{FunctionTool}

@omit_null @kwarg struct Error
    code::Union{Nothing, String} = nothing
    message::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct ReasoningSummary
    text::Union{Nothing, String} = nothing
    type::String = "summary_text"
end

@omit_null @kwarg struct ReasoningOutput
    id::Union{Nothing, String} = nothing
    summary::Union{Nothing, Vector{ReasoningSummary}} = nothing
    type::String = "reasoning"
    content::Union{Nothing, Vector{ReasoningText}} = nothing
    encrypted_content::Union{Nothing, String} = nothing
    status::Union{Nothing, String} = nothing # completed, in_progress, incomplete
end

@omit_null @kwarg struct FunctionToolCall
    type::String = "function_call"
    arguments::String
    call_id::String
    name::String
    id::Union{Nothing, String} = nothing
    status::Union{Nothing, String} = nothing # "in_progress", "completed", "incomplete"
end

@omit_null @kwarg struct UnknownOutput
    type::Union{Nothing, String} = nothing
end

const Output = Union{
    Message,
    ReasoningOutput,
    FunctionToolCall,
    UnknownOutput,
}

JSON.@choosetype Output x -> begin
    type = try
        x.type[]
    catch
        nothing
    end
    if type == "message"
        return Message
    elseif type == "reasoning"
        return ReasoningOutput
    elseif type == "function_call"
        return FunctionToolCall
    else
        return UnknownOutput
    end
end

@omit_null @kwarg struct Usage
    input_tokens::Union{Nothing, Int} = nothing
    input_tokens_details::Union{Nothing, @NamedTuple{cached_tokens::Union{Nothing, Int}}} = nothing
    output_tokens::Union{Nothing, Int} = nothing
    output_tokens_details::Union{Nothing, @NamedTuple{reasoning_tokens::Union{Nothing, Int}}} = nothing
    total_tokens::Union{Nothing, Int} = nothing
end

@omit_null @kwarg struct Response
    background::Union{Nothing, Bool} = nothing
    conversation::Union{Nothing, @NamedTuple{id::String}} = nothing
    created_at::Union{Nothing, Float64} = nothing
    error::Union{Nothing, Error} = nothing
    id::String
    incomplete_details::Union{Nothing, @NamedTuple{reason::Union{Nothing, String}}} = nothing
    max_output_tokens::Union{Nothing, Int} = nothing
    max_tool_calls::Union{Nothing, Int} = nothing
    model::String
    output::Union{Nothing, Vector{Output}} = nothing
    output_text::Union{Nothing, String} = nothing
    parallel_tool_calls::Union{Nothing, Bool} = nothing
    previous_response_id::Union{Nothing, String} = nothing
    prompt_cache_key::Union{Nothing, String} = nothing
    prompt_cache_retention::Union{Nothing, String} = nothing
    safety_identifier::Union{Nothing, String} = nothing
    service_tier::Union{Nothing, String} = nothing
    status::Union{Nothing, String} = nothing # completed, failed, in_progress, cancelled, queued, incomplete
    temperature::Union{Nothing, Float64} = nothing
    top_logprobs::Union{Nothing, Int} = nothing
    top_p::Union{Nothing, Float64} = nothing
    truncation::Union{Nothing, String} = nothing # "auto", "disabled"
    usage::Union{Nothing, Usage} = nothing
end

abstract type StreamEvent end

@omit_null @kwarg struct StreamResponseCreatedEvent <: StreamEvent
    type::String = "response.created"
    response::Response
    sequence_number::Union{Nothing, Int} = nothing
end

@omit_null @kwarg struct StreamResponseCompletedEvent <: StreamEvent
    type::String = "response.completed"
    response::Response
    sequence_number::Union{Nothing, Int} = nothing
end

# failed
@omit_null @kwarg struct StreamResponseFailedEvent <: StreamEvent
    type::String = "response.failed"
    response::Response
    sequence_number::Union{Nothing, Int} = nothing
end

# incomplete
@omit_null @kwarg struct StreamResponseIncompleteEvent <: StreamEvent
    type::String = "response.incomplete"
    response::Response
    sequence_number::Union{Nothing, Int} = nothing
end

# output_item.done
@omit_null @kwarg struct StreamOutputItemDoneEvent <: StreamEvent
    type::String = "response.output_item.done"
    sequence_number::Union{Nothing, Int} = nothing
    output_index::Union{Nothing, Int} = nothing
    item::Output
end

# output_text.delta
@omit_null @kwarg struct StreamOutputTextDeltaEvent <: StreamEvent
    type::String = "response.output_text.delta"
    sequence_number::Union{Nothing, Int} = nothing
    content_index::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    logprobs::Vector{Any} = []
    output_index::Union{Nothing, Int} = nothing
    delta::String
end

# refusal.delta
@omit_null @kwarg struct StreamRefusalDeltaEvent <: StreamEvent
    type::String = "response.refusal.delta"
    sequence_number::Union{Nothing, Int} = nothing
    content_index::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    delta::String
end

# response.reasoning_summary_text.delta
@omit_null @kwarg struct StreamReasoningSummaryTextDeltaEvent <: StreamEvent
    type::String = "response.reasoning_summary_text.delta"
    sequence_number::Union{Nothing, Int} = nothing
    summary_index::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    delta::String
end

# response.reasoning_text.delta
@omit_null @kwarg struct StreamReasoningTextDeltaEvent <: StreamEvent
    type::String = "response.reasoning_text.delta"
    sequence_number::Union{Nothing, Int} = nothing
    content_index::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    delta::String
end

# response.function_call_arguments.delta
@omit_null @kwarg struct StreamFunctionCallArgumentsDeltaEvent <: StreamEvent
    type::String = "response.function_call_arguments.delta"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    delta::String
end

# error
@omit_null @kwarg struct StreamErrorEvent <: StreamEvent
    type::String = "error"
    sequence_number::Union{Nothing, Int} = nothing
    code::Union{Nothing, String} = nothing
    message::Union{Nothing, String} = nothing
    param::Union{Nothing, String} = nothing
    # OpenAI wraps error details in an "error" object: {"type":"error","error":{"message":"...",...}}
    error::Union{Nothing, Error} = nothing
end

@omit_null @kwarg struct UnknownStreamEvent <: StreamEvent
    type::Union{Nothing, String} = nothing
end

JSON.@choosetype StreamEvent x -> begin
    type = try
        x.type[]
    catch
        nothing
    end
    if type == "response.created"
        return StreamResponseCreatedEvent
    elseif type == "response.completed"
        return StreamResponseCompletedEvent
    elseif type == "response.failed"
        return StreamResponseFailedEvent
    elseif type == "response.incomplete"
        return StreamResponseIncompleteEvent
    elseif type == "response.output_item.done"
        return StreamOutputItemDoneEvent
    elseif type == "response.output_text.delta"
        return StreamOutputTextDeltaEvent
    elseif type == "response.refusal.delta"
        return StreamRefusalDeltaEvent
    elseif type == "response.reasoning_summary_text.delta"
        return StreamReasoningSummaryTextDeltaEvent
    elseif type == "response.reasoning_text.delta"
        return StreamReasoningTextDeltaEvent
    elseif type == "response.function_call_arguments.delta"
        return StreamFunctionCallArgumentsDeltaEvent
    elseif type == "error"
        return StreamErrorEvent
    else
        return UnknownStreamEvent
    end
end

end # module OpenAIResponses
