module OpenAICompletions

using StructUtils, JSON, HTTP

import ..Model, ..AgentTool, ..parameters, ..ToolResultMessage

schema(::Type{T}) where {T} = JSON.schema(T; all_fields_required=true, additionalProperties=false)

@omit_null @kwarg struct ToolFunction{T}
    name::String
    description::Union{Nothing,String} = nothing
    parameters::JSON.Schema{T}
    strict::Union{Nothing,Bool} = nothing
end

@omit_null @kwarg struct FunctionTool{T}
    type::String = "function"
    var"function"::ToolFunction{T}
end

const Tool = Union{FunctionTool}

function FunctionTool(tool::AgentTool)
    return FunctionTool(
        var"function"=ToolFunction(
            name=tool.name,
            description=tool.description,
            parameters=schema(parameters(tool)),
            strict=tool.strict
        )
    )
end

@omit_null @kwarg struct ToolCallFunction
    name::String
    arguments::String
end

@omit_null @kwarg struct ToolCall
    id::String
    type::String = "function"
    var"function"::ToolCallFunction
end

@omit_null @kwarg struct Message
    role::String
    content::Union{Nothing,String} = nothing
    reasoning_content::Union{Nothing,String} = nothing
    reasoning::Union{Nothing,String} = nothing
    reasoning_text::Union{Nothing,String} = nothing
    tool_calls::Union{Nothing,Vector{ToolCall}} = nothing
    tool_call_id::Union{Nothing,String} = nothing
    name::Union{Nothing,String} = nothing
end

@omit_null @kwarg struct Usage
    prompt_tokens::Union{Nothing,Int} = nothing
    completion_tokens::Union{Nothing,Int} = nothing
    total_tokens::Union{Nothing,Int} = nothing
end

@omit_null @kwarg struct ResponseChoice
    index::Int
    message::Message
    finish_reason::Union{Nothing,String} = nothing
end

@omit_null @kwarg struct Response
    id::String
    choices::Vector{ResponseChoice}
    usage::Union{Nothing,Usage} = nothing
end

@omit_null @kwarg struct StreamToolCallFunctionDelta
    name::Union{Nothing,String} = nothing
    arguments::Union{Nothing,String} = nothing
end

@omit_null @kwarg struct StreamToolCallDelta
    index::Int
    id::Union{Nothing,String} = nothing
    type::String = "function"
    var"function"::StreamToolCallFunctionDelta
end

@omit_null @kwarg struct StreamDelta
    role::Union{Nothing,String} = nothing
    content::Union{Nothing,String} = nothing
    reasoning_content::Union{Nothing,String} = nothing
    reasoning::Union{Nothing,String} = nothing
    reasoning_text::Union{Nothing,String} = nothing
    tool_calls::Union{Nothing,Vector{StreamToolCallDelta}} = nothing
end

@omit_null @kwarg struct StreamChoice
    delta::StreamDelta
    finish_reason::Union{Nothing,String} = nothing
    index::Int
end

@omit_null @kwarg struct StreamChunk
    id::Union{Nothing,String} = nothing
    choices::Vector{StreamChoice}
    usage::Union{Nothing,Usage} = nothing
end

struct StreamDoneEvent end

@omit_null @kwarg struct StreamErrorEvent
    message::String
end

@omit_null @kwarg struct Request
    model::String
    messages::Vector{Message}
    stream::Bool
    tools::Union{Nothing,Vector{Tool}} = nothing
    tool_choice::Union{Nothing,Any} = nothing
    reasoning_effort::Union{Nothing,String} = nothing
    max_tokens::Union{Nothing,Int} = nothing
    temperature::Union{Nothing,Float64} = nothing
    top_p::Union{Nothing,Float64} = nothing
    stop::Union{Nothing,Union{String,Vector{String}}} = nothing
    parallel_tool_calls::Union{Nothing,Bool} = nothing
end

function get_sse_callback(f)
    function sse_callback(stream, event::HTTP.SSEEvent)
        data = String(event.data)
        if data == "[DONE]"
            f(stream, StreamDoneEvent())
            return
        end
        try
            f(stream, JSON.parse(data, StreamChunk))
        catch e
            f(stream, StreamErrorEvent(; message=sprint(showerror, e)))
        end
    end
end

function stream(f::Function, model::Model, messages::Vector{Message}, apikey::String; http_kw=(;), kw...)
    req = Request(; model=model.id, messages, stream=true, model.kw..., kw...)
    headers = Dict(
        "Authorization" => "Bearer $apikey",
        "Content-Type" => "application/json",
    )
    model.headers !== nothing && merge!(headers, model.headers)
    url = joinpath(model.baseUrl, "chat", "completions")
    HTTP.post(url, headers; body=JSON.json(req), sse_callback=get_sse_callback(f), http_kw...)
end

function request(model::Model, messages::Vector{Message}, apikey::String; http_kw=(;), kw...)
    req = Request(; model=model.id, messages, stream=false, model.kw..., kw...)
    headers = Dict(
        "Authorization" => "Bearer $apikey",
        "Content-Type" => "application/json",
    )
    model.headers !== nothing && merge!(headers, model.headers)
    url = joinpath(model.baseUrl, "chat", "completions")
    return JSON.parse(HTTP.post(url, headers; body=JSON.json(req), http_kw...).body, Response)
end

end # module OpenAICompletions
