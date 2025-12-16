module OpenAIResponses

using StructUtils, JSON, HTTP, InteractiveUtils

import ..Model, ..Future, ..AgentTool, ..parameters

schema(::Type{T}) where {T} = JSON.schema(T; all_fields_required=true, additionalProperties=false)

@omit_null @kwarg struct InputTextContent
    type::String = "input_text"
    text::String
end

@omit_null @kwarg struct InputImageContent
    type::String = "input_image"
    detail::String = "auto" # high, low, auto
    image_url::String
    file_id::Union{Nothing,String} = nothing
end

@omit_null @kwarg struct InputFileContent
    type::String = "input_file"
    file_data::Union{Nothing,String} = nothing
    file_id::Union{Nothing,String} = nothing
    file_url::Union{Nothing,String} = nothing
    filename::Union{Nothing,String} = nothing
end

const InputContent = Union{InputTextContent, InputImageContent, InputFileContent}

@omit_null @kwarg struct OutputTextContent
    type::String = "output_text"
    text::String
    # logprobs::Union{Nothing,Vector{LogProb}} = nothing
    # annotations::Union{Nothing,Vector{Annotation}} = nothing
end

@omit_null @kwarg struct Refusal
    refusal::String
    type::String = "refusal"
end

@omit_null @kwarg struct ReasoningText
    text::Union{Nothing,String} = nothing
    type::String = "reasoning_text"
end

const OutputContent = Union{OutputTextContent, Refusal, ReasoningText}

JSON.@choosetype OutputContent x -> begin
    type = x.type[]
    if type == "output_text"
        return OutputTextContent
    elseif type == "refusal"
        return Refusal
    elseif type == "reasoning_text"
        return ReasoningText
    else
        return error("Invalid output content type: $type")
    end
end

const Content = Union{InputContent, OutputContent}

JSON.@choosetype Content x -> begin
    type = x.type[]
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
        return error("Invalid content type: $type")
    end
end

@omit_null @kwarg struct Message
    id::Union{Nothing,String} = nothing
    status::Union{Nothing,String} = nothing # in_progress, completed, incomplete
    content::Union{String,Vector{Content}} &(json=(choosetype=x->x[] isa String ? String : Vector{Content},),)
    role::String # user, assistant, developer, system
    type::String = "message"
end

@omit_null @kwarg struct FunctionToolCallOutput
    type::String = "function_call_output"
    call_id::String # from FunctionToolCall
    output::String # JSON string of function tool call output
    id::Union{Nothing,String} = nothing
    status::Union{Nothing,String} = nothing # "in_progress", "completed", "incomplete"
end

const Item = Union{Message,FunctionToolCallOutput} # TODO: add other item types here: Function tool call, Function tool call output, etc.

@omit_null @kwarg struct ItemReference
    id::String
    type::String = "item_reference"
end

const InputItem = Union{Message, Item, ItemReference}

@omit_null @kwarg struct Prompt
    id::String
    variables::Union{Nothing,Dict{String,Any}} = nothing
    version::Union{Nothing,String} = nothing
end

@omit_null @kwarg struct Reasoning
    effort::Union{Nothing,String} = nothing # "none", "minimal", "low", "medium", "high", "xhigh"
    summary::Union{Nothing,String} = nothing # "auto", "concise", "detailed"
end


@omit_null @kwarg struct TextFormatText
    type::String = "text"
end

@omit_null @kwarg struct TextFormatJSONSchema{T}
    type::String = "json_schema"
    name::String
    description::Union{Nothing,String} = nothing
    # the JSON.Schema *must* have all fields be required, and additionalProperties: false
    # allOf, not, dependentRequired, dependentSchemas, if, then, else are not supported
    # root schema must be an object
    schema::JSON.Schema{T}
    strict::Union{Nothing,Bool} = nothing
end

const TextFormat = Union{TextFormatText,TextFormatJSONSchema}

JSON.@choosetype TextFormat x -> begin
    type = x.type[]
    if type == "text"
        return TextFormatText
    elseif type == "json_schema"
        return TextFormatJSONSchema
    else
        return Any
    end
end

@omit_null @kwarg struct Text
    format::TextFormat
end

@omit_null @kwarg struct FunctionTool{T}
    name::String
    strict::Bool = true
    type::String = "function"
    description::Union{Nothing,String} = nothing
    parameters::JSON.Schema{T}
end

function FunctionTool(tool::AgentTool)
    return FunctionTool(
        name=tool.name,
        description=tool.description,
        strict=tool.strict,
        parameters=schema(parameters(tool))
    )
end

const Tool = Union{FunctionTool}

# this struct is meant to *exactly* match the OpenAI API reference:
# https://platform.openai.com/docs/api-reference/responses/create
@omit_null @kwarg struct Request
    background::Union{Nothing,Bool} = nothing
    conversation::Union{Nothing,String,@NamedTuple{id::String}} = nothing
    include::Union{Nothing,Vector{String}} = ["reasoning.encrypted_content"] # "web_search_call.action.sources", "code_interpreter_call.outputs", "computer_call_output.output.image_url", "file_search_call.results", "message.input_image.image_url", "message.output_text.logprobs", "reasoning.encrypted_content"
    input::Union{Nothing,String,Vector{InputItem}} = nothing
    instructions::Union{Nothing,String} = nothing # for stateful, instructions from previous response will be used if not provided
    max_output_tokens::Union{Nothing,Int} = nothing
    max_tool_calls::Union{Nothing,Int} = nothing
    model::String
    parallel_tool_calls::Union{Nothing,Bool} = nothing
    previous_response_id::Union{Nothing,String} = nothing
    prompt::Union{Nothing,Prompt} = nothing
    prompt_cache_key::Union{Nothing,String} = nothing
    prompt_cache_retention::Union{Nothing,String} = nothing
    reasoning::Union{Nothing,Reasoning} = Reasoning(effort="low", summary="auto")
    safety_identifier::Union{Nothing,String} = nothing
    service_tier::Union{Nothing,String} = nothing
    store::Union{Nothing,Bool} = nothing
    stream::Union{Nothing,Bool} = nothing
    stream_options::Union{Nothing,@NamedTuple{include_obfuscation::Union{Nothing,Bool}}} = nothing
    temperature::Union{Nothing,Float64} = nothing
    text::Union{Nothing,Text} = nothing
    tool_choice::Union{Nothing,String} = nothing # "none", "auto", "required"; TODO: can be more specific on tool types to be required
    tools::Union{Nothing,Vector{Tool}} = nothing
    top_logprobs::Union{Nothing,Int} = nothing
    top_p::Union{Nothing,Float64} = nothing
    truncation::Union{Nothing,String} = nothing # "auto", "disabled"
end

@omit_null @kwarg struct Error
    code::Union{Nothing,String} = nothing
    message::Union{Nothing,String} = nothing
end

@omit_null @kwarg struct ReasoningSummary
    text::Union{Nothing,String} = nothing
    type::String = "summary_text"
end

@omit_null @kwarg struct ReasoningOutput
    id::Union{Nothing,String} = nothing
    summary::Union{Nothing,Vector{ReasoningSummary}} = nothing
    type::String = "reasoning"
    content::Union{Nothing,Vector{ReasoningText}} = nothing
    encrypted_content::Union{Nothing,String} = nothing
    status::Union{Nothing,String} = nothing # completed, in_progress, incomplete
end

@omit_null @kwarg struct FunctionToolCall
    type::String = "function_call"
    arguments::Union{Nothing,String} = nothing
    call_id::Union{Nothing,String} = nothing
    name::String
    id::String
    status::String # "in_progress", "completed", "incomplete"
end

const Output = Union{Message, ReasoningOutput, FunctionToolCall} # TODO: add other output types here: Tool call, Tool call output, etc.

JSON.@choosetype Output x -> begin
    type = x.type[]
    if type == "message"
        return Message
    elseif type == "reasoning"
        return ReasoningOutput
    elseif type == "function_call"
        return FunctionToolCall
    else
        return error("Invalid output type: $type")
    end
end

@omit_null @kwarg struct Usage
    input_tokens::Union{Nothing,Int} = nothing
    input_tokens_details::Union{Nothing,@NamedTuple{cached_tokens::Union{Nothing,Int}}} = nothing
    output_tokens::Union{Nothing,Int} = nothing
    output_tokens_details::Union{Nothing,@NamedTuple{reasoning_tokens::Union{Nothing,Int}}} = nothing
    total_tokens::Union{Nothing,Int} = nothing
end

@omit_null @kwarg struct Response
    background::Union{Nothing,Bool} = nothing
    conversation::Union{Nothing,@NamedTuple{id::String}} = nothing
    created_at::Union{Nothing,Float64} = nothing
    error::Union{Nothing,Error} = nothing
    id::String
    incomplete_details::Union{Nothing,@NamedTuple{reason::Union{Nothing,String}}} = nothing
    # instructions::Union{Nothing,String} = nothing 
    max_output_tokens::Union{Nothing,Int} = nothing
    max_tool_calls::Union{Nothing,Int} = nothing
    model::String
    output::Union{Nothing,Vector{Output}} = nothing
    output_text::Union{Nothing,String} = nothing
    parallel_tool_calls::Union{Nothing,Bool} = nothing
    previous_response_id::Union{Nothing,String} = nothing
    prompt::Union{Nothing,Prompt} = nothing
    prompt_cache_key::Union{Nothing,String} = nothing
    prompt_cache_retention::Union{Nothing,String} = nothing
    reasoning::Union{Nothing,Reasoning} = nothing
    safety_identifier::Union{Nothing,String} = nothing
    service_tier::Union{Nothing,String} = nothing
    status::Union{Nothing,String} = nothing # completed, failed, in_progress, cancelled, queued, incomplete
    temperature::Union{Nothing,Float64} = nothing
    # text::Union{Nothing,Text} = nothing
    # tool_choice::Union{Nothing,ToolChoice} = nothing
    # tools::Union{Nothing,Vector{Tool}} = nothing
    top_logprobs::Union{Nothing,Int} = nothing
    top_p::Union{Nothing,Float64} = nothing
    truncation::Union{Nothing,String} = nothing # "auto", "disabled"
    usage::Union{Nothing,Usage} = nothing
end

abstract type StreamEvent end
abstract type StreamDeltaEvent <: StreamEvent end

@omit_null @kwarg struct StreamResponseCreatedEvent <: StreamEvent
    type::String = "response.created"
    response::Response
    sequence_number::Union{Nothing,Int} = nothing
end

@omit_null @kwarg struct StreamResponseInProgressEvent <: StreamEvent
    type::String = "response.in_progress"
    response::Response
    sequence_number::Union{Nothing,Int} = nothing
end

@omit_null @kwarg struct StreamResponseCompletedEvent <: StreamEvent
    type::String = "response.completed"
    response::Response
    sequence_number::Union{Nothing,Int} = nothing
end

# failed
@omit_null @kwarg struct StreamResponseFailedEvent <: StreamEvent
    type::String = "response.failed"
    response::Response
    sequence_number::Union{Nothing,Int} = nothing
end

# incomplete
@omit_null @kwarg struct StreamResponseIncompleteEvent <: StreamEvent
    type::String = "response.incomplete"
    response::Response
    sequence_number::Union{Nothing,Int} = nothing
end

# output_item.added
@omit_null @kwarg struct StreamOutputItemAddedEvent <: StreamEvent
    type::String = "response.output_item.added"
    sequence_number::Union{Nothing,Int} = nothing
    item::Output
end

# output_item.done
@omit_null @kwarg struct StreamOutputItemDoneEvent <: StreamEvent
    type::String = "response.output_item.done"
    sequence_number::Union{Nothing,Int} = nothing
    item::Output
end

# content_part.added
@omit_null @kwarg struct StreamContentPartAddedEvent <: StreamEvent
    type::String = "response.content_part.added"
    sequence_number::Union{Nothing,Int} = nothing
    content_index::Union{Nothing,Int} = nothing
    item_id::Union{Nothing,String} = nothing
    output_index::Union{Nothing,Int} = nothing
    part::OutputContent
end

# content_part.done
@omit_null @kwarg struct StreamContentPartDoneEvent <: StreamEvent
    type::String = "response.content_part.done"
    sequence_number::Union{Nothing,Int} = nothing
    content_index::Union{Nothing,Int} = nothing
    item_id::Union{Nothing,String} = nothing
    output_index::Union{Nothing,Int} = nothing
    part::OutputContent
end

# output_text.delta
@omit_null @kwarg struct StreamOutputTextDeltaEvent <: StreamDeltaEvent
    type::String = "response.output_text.delta"
    sequence_number::Union{Nothing,Int} = nothing
    content_index::Union{Nothing,Int} = nothing
    item_id::Union{Nothing,String} = nothing
    output_index::Union{Nothing,Int} = nothing
    delta::String
end

# output_text.done
@omit_null @kwarg struct StreamOutputTextDoneEvent <: StreamEvent
    type::String = "response.output_text.done"
    sequence_number::Union{Nothing,Int} = nothing
    content_index::Union{Nothing,Int} = nothing
    item_id::Union{Nothing,String} = nothing
    output_index::Union{Nothing,Int} = nothing
    text::String
end

# refusal.delta
@omit_null @kwarg struct StreamRefusalDeltaEvent <: StreamDeltaEvent
    type::String = "response.refusal.delta"
    sequence_number::Union{Nothing,Int} = nothing
    content_index::Union{Nothing,Int} = nothing
    item_id::Union{Nothing,String} = nothing
    output_index::Union{Nothing,Int} = nothing
    delta::String
end

# refusal.done
@omit_null @kwarg struct StreamRefusalDoneEvent <: StreamEvent
    type::String = "response.refusal.done"
    sequence_number::Union{Nothing,Int} = nothing
    content_index::Union{Nothing,Int} = nothing
    item_id::Union{Nothing,String} = nothing
    output_index::Union{Nothing,Int} = nothing
    refusal::Refusal
end

# response.reasoning_summary_part.added
@omit_null @kwarg struct StreamReasoningSummaryPartAddedEvent <: StreamEvent
    type::String = "response.reasoning_summary_part.added"
    sequence_number::Union{Nothing,Int} = nothing
    summary_index::Union{Nothing,Int} = nothing
    item_id::Union{Nothing,String} = nothing
end

# response.reasoning_summary_part.done
@omit_null @kwarg struct StreamReasoningSummaryPartDoneEvent <: StreamEvent
    type::String = "response.reasoning_summary_part.done"
    sequence_number::Union{Nothing,Int} = nothing
    summary_index::Union{Nothing,Int} = nothing
    item_id::Union{Nothing,String} = nothing
end

# response.reasoning_summary_text.delta
@omit_null @kwarg struct StreamReasoningSummaryTextDeltaEvent <: StreamDeltaEvent
    type::String = "response.reasoning_summary_text.delta"
    sequence_number::Union{Nothing,Int} = nothing
    summary_index::Union{Nothing,Int} = nothing
    item_id::Union{Nothing,String} = nothing
    delta::String
end

# response.reasoning_summary_text.done
@omit_null @kwarg struct StreamReasoningSummaryTextDoneEvent <: StreamEvent
    type::String = "response.reasoning_summary_text.done"
    sequence_number::Union{Nothing,Int} = nothing
    summary_index::Union{Nothing,Int} = nothing
    item_id::Union{Nothing,String} = nothing
    text::String
end

# response.reasoning_text.delta
@omit_null @kwarg struct StreamReasoningTextDeltaEvent <: StreamDeltaEvent
    type::String = "response.reasoning_text.delta"
    sequence_number::Union{Nothing,Int} = nothing
    text_index::Union{Nothing,Int} = nothing
    item_id::Union{Nothing,String} = nothing
    delta::String
end

# response.reasoning_text.done
@omit_null @kwarg struct StreamReasoningTextDoneEvent <: StreamEvent
    type::String = "response.reasoning_text.done"
    sequence_number::Union{Nothing,Int} = nothing
    text_index::Union{Nothing,Int} = nothing
    item_id::Union{Nothing,String} = nothing
    text::String
end

# response.function_call_arguments.delta
@omit_null @kwarg struct StreamFunctionCallArgumentsDeltaEvent <: StreamDeltaEvent
    type::String = "response.function_call_arguments.delta"
    sequence_number::Union{Nothing,Int} = nothing
    call_id::Union{Nothing,String} = nothing
    delta::String
end

# response.function_call_arguments.done
@omit_null @kwarg struct StreamFunctionCallArgumentsDoneEvent <: StreamEvent
    type::String = "response.function_call_arguments.done"
    sequence_number::Union{Nothing,Int} = nothing
    call_id::Union{Nothing,String} = nothing
    arguments::String
end

# response.mcp_call.completed
@omit_null @kwarg struct StreamMCPCallCompletedEvent <: StreamEvent
    type::String = "response.mcp_call.completed"
    sequence_number::Union{Nothing,Int} = nothing
    call_id::Union{Nothing,String} = nothing
    result::String
end

# response.mcp_call.failed
@omit_null @kwarg struct StreamMCPCallFailedEvent <: StreamEvent
    type::String = "response.mcp_call.failed"
    sequence_number::Union{Nothing,Int} = nothing
    call_id::Union{Nothing,String} = nothing
    error::String
end

# response.mcp_call.in_progress
@omit_null @kwarg struct StreamMCPCallInProgressEvent <: StreamEvent
    type::String = "response.mcp_call.in_progress"
    sequence_number::Union{Nothing,Int} = nothing
    call_id::Union{Nothing,String} = nothing
    result::String
end

# repsonse.queued
@omit_null @kwarg struct StreamResponseQueuedEvent <: StreamEvent
    type::String = "response.queued"
    sequence_number::Union{Nothing,Int} = nothing
    response::Response
end

# error
@omit_null @kwarg struct StreamErrorEvent <: StreamEvent
    type::String = "error"
    sequence_number::Union{Nothing,Int} = nothing
    code::Union{Nothing,String} = nothing
    message::Union{Nothing,String} = nothing
    param::Union{Nothing,String} = nothing
end

JSON.@choosetype StreamEvent x -> begin
    type = x.type[]
    if type == "response.created"
        return StreamResponseCreatedEvent
    elseif type == "response.in_progress"
        return StreamResponseInProgressEvent
    elseif type == "response.completed"
        return StreamResponseCompletedEvent
    elseif type == "response.failed"
        return StreamResponseFailedEvent
    elseif type == "response.incomplete"
        return StreamResponseIncompleteEvent
    elseif type == "response.output_item.added"
        return StreamOutputItemAddedEvent
    elseif type == "response.output_item.done"
        return StreamOutputItemDoneEvent
    elseif type == "response.content_part.added"
        return StreamContentPartAddedEvent
    elseif type == "response.content_part.done"
        return StreamContentPartDoneEvent
    elseif type == "response.output_text.delta"
        return StreamOutputTextDeltaEvent
    elseif type == "response.output_text.done"
        return StreamOutputTextDoneEvent
    elseif type == "response.refusal.delta"
        return StreamRefusalDeltaEvent
    elseif type == "response.refusal.done"
        return StreamRefusalDoneEvent
    elseif type == "response.reasoning_summary_part.added"
        return StreamReasoningSummaryPartAddedEvent
    elseif type == "response.reasoning_summary_part.done"
        return StreamReasoningSummaryPartDoneEvent
    elseif type == "response.reasoning_summary_text.delta"
        return StreamReasoningSummaryTextDeltaEvent
    elseif type == "response.reasoning_summary_text.done"
        return StreamReasoningSummaryTextDoneEvent
    elseif type == "response.reasoning_text.delta"
        return StreamReasoningTextDeltaEvent
    elseif type == "response.reasoning_text.done"
        return StreamReasoningTextDoneEvent
    elseif type == "response.function_call_arguments.delta"
        return StreamFunctionCallArgumentsDeltaEvent
    elseif type == "response.function_call_arguments.done"
        return StreamFunctionCallArgumentsDoneEvent
    elseif type == "response.mcp_call.completed"
        return StreamMCPCallCompletedEvent
    elseif type == "response.mcp_call.failed"
        return StreamMCPCallFailedEvent
    elseif type == "response.mcp_call.in_progress"
        return StreamMCPCallInProgressEvent
    elseif type == "response.queued"
        return StreamResponseQueuedEvent
    elseif type == "error"
        return StreamErrorEvent
    else
        return error("Invalid stream event type: $type")
    end
end

function get_sse_callback(f)
    function sse_callback(event::HTTP.SSEEvent)
        f(JSON.parse(event.data, StreamEvent))
    end
end

function stream(f::Function, model::Model, input::Union{String,Vector{InputItem}}, apikey::String; http_kw=(;), kw...)
    req = Request(; model=model.id, input=input, stream=true, model.kw..., kw...)
    headers = Dict(
        "Authorization" => "Bearer $apikey",
        "Content-Type" => "application/json",
    )
    model.headers !== nothing && merge!(headers, model.headers)
    url = joinpath(model.baseUrl, "responses")
    HTTP.post(url, headers; body=JSON.json(req), sse_callback=get_sse_callback(f), http_kw...)
end

function request(model::Model, input::Union{String,Vector{InputItem}}, apikey::String; http_kw=(;), kw...)
    req = Request(; model=model.id, input=input, stream=false, model.kw..., kw...)
    headers = Dict(
        "Authorization" => "Bearer $apikey",
        "Content-Type" => "application/json",
    )
    model.headers !== nothing && merge!(headers, model.headers)
    url = joinpath(model.baseUrl, "responses")
    return JSON.parse(HTTP.post(url, headers; body=JSON.json(req), http_kw...).body, Response)
end  

end # module OpenAIResponses