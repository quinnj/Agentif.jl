module GoogleGenerativeAI

using StructUtils, JSON, HTTP

import ..Model, ..AgentTool, ..parameters, ..ToolResultMessage

function sanitize_schema(schema::Any)
    if schema isa AbstractDict
        out = Dict{String, Any}()
        for (key, value) in schema
            key == "\$schema" && continue
            if key == "type" && value isa AbstractVector
                non_null = [x for x in value if x != "null"]
                if !isempty(non_null)
                    out["type"] = non_null[1]
                end
                if any(x -> x == "null", value)
                    out["nullable"] = true
                end
                continue
            elseif (key == "anyOf" || key == "oneOf") && value isa AbstractVector
                non_null = Any[]
                has_null = false
                for item in value
                    if item isa AbstractDict && get(item, "type", nothing) == "null"
                        has_null = true
                    else
                        push!(non_null, item)
                    end
                end
                if has_null && length(non_null) == 1
                    inner = sanitize_schema(non_null[1])
                    if inner isa AbstractDict
                        for (inner_key, inner_value) in inner
                            out[inner_key] = inner_value
                        end
                        out["nullable"] = true
                    end
                else
                    out[key] = [sanitize_schema(item) for item in value]
                end
                continue
            end
            out[key] = sanitize_schema(value)
        end
        return out
    elseif schema isa AbstractVector
        return [sanitize_schema(item) for item in schema]
    end
    return schema
end

function schema(::Type{T}) where {T}
    raw = JSON.schema(T; all_fields_required=true, additionalProperties=false)
    return sanitize_schema(JSON.parse(JSON.json(raw)))
end

@omit_null @kwarg struct FunctionDeclaration
    name::String
    description::Union{Nothing,String} = nothing
    parameters::AbstractDict{String, Any}
end

@omit_null @kwarg struct Tool
    functionDeclarations::Vector{FunctionDeclaration}
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
