module OpenAICompletions

using StructUtils, JSON, JSONSchema


schema(::Type{T}) where {T} = JSONSchema.schema(T; all_fields_required = false, additionalProperties = false)

@omit_null @kwarg struct ToolFunction{T}
    name::String
    description::Union{Nothing, String} = nothing
    parameters::JSONSchema.Schema{T}
    strict::Union{Nothing, Bool} = nothing
end

@omit_null @kwarg struct FunctionTool{T}
    type::String = "function"
    var"function"::ToolFunction{T}
end

const Tool = Union{FunctionTool}


@omit_null @kwarg struct ToolCallFunction
    name::String
    arguments::String
end

@omit_null @kwarg struct ToolCall
    id::String
    type::String = "function"
    var"function"::ToolCallFunction
end

@omit_null @kwarg struct ImageURL
    url::String
end

@omit_null @kwarg struct ContentPart
    type::String
    text::Union{Nothing, String} = nothing
    image_url::Union{Nothing, ImageURL} = nothing
end

@omit_null @kwarg mutable struct Message
    role::String
    content::Union{Nothing, String, Vector{ContentPart}} = nothing
    reasoning_content::Union{Nothing, String} = nothing
    reasoning::Union{Nothing, String} = nothing
    reasoning_text::Union{Nothing, String} = nothing
    reasoning_details::Union{Nothing, Any} = nothing
    tool_calls::Union{Nothing, Vector{ToolCall}} = nothing
    tool_call_id::Union{Nothing, String} = nothing
    name::Union{Nothing, String} = nothing
    extra::Union{Nothing, Dict{String, Any}} = nothing
end

function JSON.lower(x::Message)
    data = Dict{String, Any}("role" => x.role)
    x.content !== nothing && (data["content"] = x.content)
    x.reasoning_content !== nothing && (data["reasoning_content"] = x.reasoning_content)
    x.reasoning !== nothing && (data["reasoning"] = x.reasoning)
    x.reasoning_text !== nothing && (data["reasoning_text"] = x.reasoning_text)
    x.reasoning_details !== nothing && (data["reasoning_details"] = x.reasoning_details)
    x.tool_calls !== nothing && (data["tool_calls"] = x.tool_calls)
    x.tool_call_id !== nothing && (data["tool_call_id"] = x.tool_call_id)
    x.name !== nothing && (data["name"] = x.name)
    if x.extra !== nothing
        for (k, v) in x.extra
            data[k] = v
        end
    end
    return data
end

@omit_null @kwarg struct Usage
    prompt_tokens::Union{Nothing, Int} = nothing
    completion_tokens::Union{Nothing, Int} = nothing
    total_tokens::Union{Nothing, Int} = nothing
end

@omit_null @kwarg struct ResponseChoice
    index::Int
    message::Message
    finish_reason::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct Response
    id::String
    choices::Vector{ResponseChoice}
    usage::Union{Nothing, Usage} = nothing
end

@omit_null @kwarg struct StreamToolCallFunctionDelta
    name::Union{Nothing, String} = nothing
    arguments::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct StreamToolCallDelta
    index::Int
    id::Union{Nothing, String} = nothing
    type::String = "function"
    var"function"::StreamToolCallFunctionDelta
end

@omit_null @kwarg struct StreamDelta
    role::Union{Nothing, String} = nothing
    content::Union{Nothing, String} = nothing
    reasoning_content::Union{Nothing, String} = nothing
    reasoning::Union{Nothing, String} = nothing
    reasoning_text::Union{Nothing, String} = nothing
    reasoning_details::Union{Nothing, Any} = nothing
    tool_calls::Union{Nothing, Vector{StreamToolCallDelta}} = nothing
    name::Union{Nothing, String} = nothing
    audio_content::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct StreamChoice
    delta::StreamDelta
    finish_reason::Union{Nothing, String} = nothing
    index::Int
end

@omit_null @kwarg struct StreamChunk
    id::Union{Nothing, String} = nothing
    choices::Vector{StreamChoice}
    usage::Union{Nothing, Usage} = nothing
    created::Union{Nothing, Int} = nothing
    model::Union{Nothing, String} = nothing
    object::Union{Nothing, String} = nothing
    input_sensitive::Union{Nothing, Bool} = nothing
    output_sensitive::Union{Nothing, Bool} = nothing
    input_sensitive_type::Union{Nothing, Int} = nothing
    output_sensitive_type::Union{Nothing, Int} = nothing
    output_sensitive_int::Union{Nothing, Int} = nothing
end

struct StreamDoneEvent end

@omit_null @kwarg struct StreamErrorEvent
    message::String
end

@omit_null @kwarg struct Request
    model::String
    messages::Vector{Message}
    stream::Bool
    tools::Union{Nothing, Vector{Tool}} = nothing
    tool_choice::Union{Nothing, Any} = nothing
    store::Union{Nothing, Bool} = nothing
    stream_options::Union{Nothing, Any} = nothing
    reasoning_effort::Union{Nothing, String} = nothing
    thinking::Union{Nothing, Any} = nothing
    reasoning_split::Union{Nothing, Bool} = nothing
    max_tokens::Union{Nothing, Int} = nothing
    max_completion_tokens::Union{Nothing, Int} = nothing
    temperature::Union{Nothing, Float64} = nothing
    top_p::Union{Nothing, Float64} = nothing
    stop::Union{Nothing, Union{String, Vector{String}}} = nothing
    parallel_tool_calls::Union{Nothing, Bool} = nothing
end

end # module OpenAICompletions
