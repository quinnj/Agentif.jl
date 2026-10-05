module GoogleShared

# Wire types and schema handling shared by the GoogleGenerativeAI and
# GoogleGeminiCli provider modules, which speak the same generateContent
# format. UsageMetadata is the superset of both providers' fields; the
# extra optional fields simply stay `nothing` for responses that omit them.

using StructUtils, JSON, JSONSchema

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
    raw = JSONSchema.schema(T; all_fields_required = false, additionalProperties = false)
    return sanitize_schema(JSON.parse(JSON.json(raw)))
end

@omit_null @kwarg struct FunctionDeclaration
    name::String
    description::Union{Nothing, String} = nothing
    parameters::AbstractDict{String, Any}
end

@omit_null @kwarg struct Tool
    functionDeclarations::Vector{FunctionDeclaration}
end


@omit_null @kwarg struct FunctionCall
    id::Union{Nothing, String} = nothing
    name::Union{Nothing, String} = nothing
    args::Union{Nothing, Dict{String, Any}} = nothing
end

@omit_null @kwarg struct InlineData
    mimeType::String
    data::String
end

@omit_null @kwarg struct FunctionResponse
    id::Union{Nothing, String} = nothing
    name::String
    response::Dict{String, Any}
    parts::Union{Nothing, Vector{Any}} = nothing
end

@omit_null @kwarg struct Part
    text::Union{Nothing, String} = nothing
    thought::Union{Nothing, Bool} = nothing
    thoughtSignature::Union{Nothing, String} = nothing
    inlineData::Union{Nothing, InlineData} = nothing
    functionCall::Union{Nothing, FunctionCall} = nothing
    functionResponse::Union{Nothing, FunctionResponse} = nothing
end

@omit_null @kwarg struct Content
    parts::Union{Nothing, Vector{Part}} = nothing
    role::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct Candidate
    content::Union{Nothing, Content} = nothing
    finishReason::Union{Nothing, String} = nothing
    finishMessage::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct UsageMetadata
    promptTokenCount::Union{Nothing, Int} = nothing
    candidatesTokenCount::Union{Nothing, Int} = nothing
    thoughtsTokenCount::Union{Nothing, Int} = nothing
    totalTokenCount::Union{Nothing, Int} = nothing
    cachedContentTokenCount::Union{Nothing, Int} = nothing
end

end # module GoogleShared
