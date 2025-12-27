module GoogleGenerativeAI

using StructUtils, JSON, HTTP

import ..Model, ..AgentTool, ..parameters, ..ToolResultMessage

schema(::Type{T}) where {T} = JSON.schema(T; all_fields_required=true, additionalProperties=false)

@omit_null @kwarg struct FunctionDeclaration{T}
    name::String
    description::Union{Nothing,String} = nothing
    parameters::JSON.Schema{T}
end

@omit_null @kwarg struct Tool{T}
    functionDeclarations::Vector{FunctionDeclaration{T}}
end

function Tool(tools::Vector{AgentTool})
    decls = FunctionDeclaration[]
    for tool in tools
        push!(decls, FunctionDeclaration(; name=tool.name, description=tool.description, parameters=schema(parameters(tool))))
    end
    return Tool(; functionDeclarations=decls)
end

@omit_null @kwarg struct FunctionCall
    id::Union{Nothing,String} = nothing
    name::Union{Nothing,String} = nothing
    args::Union{Nothing,Any} = nothing
end

@omit_null @kwarg struct FunctionResponse
    name::String
    response::Dict{String,Any}
end

@omit_null @kwarg struct Part
    text::Union{Nothing,String} = nothing
    functionCall::Union{Nothing,FunctionCall} = nothing
    functionResponse::Union{Nothing,FunctionResponse} = nothing
end

@omit_null @kwarg struct Content
    parts::Union{Nothing,Vector{Part}} = nothing
    role::Union{Nothing,String} = nothing
end

@omit_null @kwarg struct Candidate
    content::Union{Nothing,Content} = nothing
    finishReason::Union{Nothing,String} = nothing
end

@omit_null @kwarg struct UsageMetadata
    promptTokenCount::Union{Nothing,Int} = nothing
    candidatesTokenCount::Union{Nothing,Int} = nothing
    totalTokenCount::Union{Nothing,Int} = nothing
end

@omit_null @kwarg struct GenerateContentResponse
    candidates::Union{Nothing,Vector{Candidate}} = nothing
    responseId::Union{Nothing,String} = nothing
    usageMetadata::Union{Nothing,UsageMetadata} = nothing
end

@omit_null @kwarg struct Request
    contents::Vector{Content}
    tools::Union{Nothing,Vector{Tool}} = nothing
    systemInstruction::Union{Nothing,Content} = nothing
    toolConfig::Union{Nothing,Any} = nothing
end

struct StreamDoneEvent end

@omit_null @kwarg struct StreamErrorEvent
    message::String
end

function get_sse_callback(f)
    function sse_callback(stream, event::HTTP.SSEEvent)
        data = String(event.data)
        if data == "[DONE]"
            f(stream, StreamDoneEvent())
            return
        end
        try
            f(stream, JSON.parse(data, GenerateContentResponse))
        catch e
            f(stream, StreamErrorEvent(; message=sprint(showerror, e)))
        end
    end
end

function stream(f::Function, model::Model, contents::Vector{Content}, apikey::String; http_kw=(;), kw...)
    req = Request(; contents, model.kw..., kw...)
    headers = Dict(
        "x-goog-api-key" => apikey,
        "Content-Type" => "application/json",
    )
    model.headers !== nothing && merge!(headers, model.headers)
    url = joinpath(model.baseUrl, "models", "$(model.id):streamGenerateContent")
    HTTP.post(url * "?alt=sse", headers; body=JSON.json(req), sse_callback=get_sse_callback(f), http_kw...)
end

function request(model::Model, contents::Vector{Content}, apikey::String; http_kw=(;), kw...)
    req = Request(; contents, model.kw..., kw...)
    headers = Dict(
        "x-goog-api-key" => apikey,
        "Content-Type" => "application/json",
    )
    model.headers !== nothing && merge!(headers, model.headers)
    url = joinpath(model.baseUrl, "models", "$(model.id):generateContent")
    return JSON.parse(HTTP.post(url, headers; body=JSON.json(req), http_kw...).body, GenerateContentResponse)
end

end # module GoogleGenerativeAI
