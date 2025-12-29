module GoogleGeminiCli

using StructUtils, JSON, HTTP, UUIDs

import ..Model, ..AgentTool, ..parameters

schema(::Type{T}) where {T} = JSON.schema(T; all_fields_required = true, additionalProperties = false)

@omit_null @kwarg struct FunctionDeclaration{T}
    name::String
    description::Union{Nothing, String} = nothing
    parameters::JSON.Schema{T}
end

@omit_null @kwarg struct Tool{T}
    functionDeclarations::Vector{FunctionDeclaration{T}}
end

function Tool(tools::Vector{AgentTool})
    decls = FunctionDeclaration[]
    for tool in tools
        push!(decls, FunctionDeclaration(; name = tool.name, description = tool.description, parameters = schema(parameters(tool))))
    end
    return Tool(; functionDeclarations = decls)
end

@omit_null @kwarg struct FunctionCall
    id::Union{Nothing, String} = nothing
    name::Union{Nothing, String} = nothing
    args::Union{Nothing, Any} = nothing
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
end

@omit_null @kwarg struct UsageMetadata
    promptTokenCount::Union{Nothing, Int} = nothing
    candidatesTokenCount::Union{Nothing, Int} = nothing
    thoughtsTokenCount::Union{Nothing, Int} = nothing
    totalTokenCount::Union{Nothing, Int} = nothing
    cachedContentTokenCount::Union{Nothing, Int} = nothing
end

@omit_null @kwarg struct StreamResponse
    candidates::Union{Nothing, Vector{Candidate}} = nothing
    usageMetadata::Union{Nothing, UsageMetadata} = nothing
    modelVersion::Union{Nothing, String} = nothing
    responseId::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct StreamChunk
    response::Union{Nothing, StreamResponse} = nothing
    traceId::Union{Nothing, String} = nothing
end

struct StreamDoneEvent end

@omit_null @kwarg struct StreamErrorEvent
    message::String
end

@omit_null @kwarg struct ThinkingConfig
    includeThoughts::Union{Nothing, Bool} = nothing
    thinkingBudget::Union{Nothing, Int} = nothing
    thinkingLevel::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct GenerationConfig
    maxOutputTokens::Union{Nothing, Int} = nothing
    temperature::Union{Nothing, Float64} = nothing
    thinkingConfig::Union{Nothing, ThinkingConfig} = nothing
end

@omit_null @kwarg struct FunctionCallingConfig
    mode::String
end

@omit_null @kwarg struct ToolConfig
    functionCallingConfig::FunctionCallingConfig
end

@omit_null @kwarg struct RequestPayload
    contents::Vector{Content}
    systemInstruction::Union{Nothing, Content} = nothing
    generationConfig::Union{Nothing, GenerationConfig} = nothing
    tools::Union{Nothing, Vector{Tool}} = nothing
    toolConfig::Union{Nothing, ToolConfig} = nothing
end

@omit_null @kwarg struct Request
    project::String
    model::String
    request::RequestPayload
    userAgent::Union{Nothing, String} = nothing
    requestId::Union{Nothing, String} = nothing
end

const DEFAULT_ENDPOINT = "https://cloudcode-pa.googleapis.com"
const GEMINI_CLI_HEADERS = Dict(
    "User-Agent" => "google-cloud-sdk vscode_cloudshelleditor/0.1",
    "X-Goog-Api-Client" => "gl-node/22.17.0",
    "Client-Metadata" => JSON.json(
        Dict(
            "ideType" => "IDE_UNSPECIFIED",
            "platform" => "PLATFORM_UNSPECIFIED",
            "pluginType" => "GEMINI",
        )
    ),
)
const ANTIGRAVITY_HEADERS = Dict(
    "User-Agent" => "antigravity/1.11.5 darwin/arm64",
    "X-Goog-Api-Client" => "google-cloud-sdk vscode_cloudshelleditor/0.1",
    "Client-Metadata" => JSON.json(
        Dict(
            "ideType" => "IDE_UNSPECIFIED",
            "platform" => "PLATFORM_UNSPECIFIED",
            "pluginType" => "GEMINI",
        )
    ),
)

function emit_stream_error(f, http_stream, err)
    message = err isa Exception ? sprint(showerror, err) : string(err)
    return f(http_stream, StreamErrorEvent(; message))
end

function map_tool_choice(choice::String)
    if choice == "auto"
        return "AUTO"
    elseif choice == "none"
        return "NONE"
    elseif choice == "any"
        return "ANY"
    end
    return "AUTO"
end

function build_request(
        model::Model,
        contents::Vector{Content},
        project_id::String;
        systemInstruction::Union{Nothing, Content} = nothing,
        tools::Union{Nothing, Vector{Tool}} = nothing,
        toolChoice::Union{Nothing, String} = nothing,
        maxTokens::Union{Nothing, Int} = nothing,
        temperature::Union{Nothing, Float64} = nothing,
        thinking::Union{Nothing, Any} = nothing,
    )
    generation_config = nothing
    if temperature !== nothing || maxTokens !== nothing
        generation_config = GenerationConfig(; temperature = temperature, maxOutputTokens = maxTokens)
    end

    if thinking !== nothing
        enabled = false
        thinking_level = nothing
        thinking_budget = nothing
        if thinking isa NamedTuple
            enabled = haskey(thinking, :enabled) ? thinking.enabled : false
            thinking_level = haskey(thinking, :level) ? thinking.level : nothing
            thinking_budget = haskey(thinking, :budgetTokens) ? thinking.budgetTokens : nothing
        elseif thinking isa AbstractDict
            enabled = get(() -> false, thinking, "enabled")
            thinking_level = get(() -> nothing, thinking, "level")
            thinking_budget = get(() -> nothing, thinking, "budgetTokens")
        elseif hasproperty(thinking, :enabled)
            enabled = getproperty(thinking, :enabled)
            hasproperty(thinking, :level) && (thinking_level = getproperty(thinking, :level))
            hasproperty(thinking, :budgetTokens) && (thinking_budget = getproperty(thinking, :budgetTokens))
        end
        if enabled
            thinking_config = ThinkingConfig(; includeThoughts = true)
            if thinking_level !== nothing
                thinking_config = ThinkingConfig(; thinking_config..., thinkingLevel = string(thinking_level))
            elseif thinking_budget !== nothing
                thinking_config = ThinkingConfig(; thinking_config..., thinkingBudget = thinking_budget)
            end
            generation_config = GenerationConfig(
                ; temperature = temperature,
                maxOutputTokens = maxTokens,
                thinkingConfig = thinking_config,
            )
        end
    end

    tool_config = nothing
    if toolChoice !== nothing
        tool_config = ToolConfig(; functionCallingConfig = FunctionCallingConfig(; mode = map_tool_choice(toolChoice)))
    end

    payload = RequestPayload(; contents, systemInstruction, generationConfig = generation_config, tools, toolConfig = tool_config)
    return Request(
        ; project = project_id,
        model = model.id,
        request = payload,
        userAgent = "agentif",
        requestId = "agentif-$(UUIDs.uuid4())",
    )
end

function parse_oauth_credentials(apikey::String)
    parsed = JSON.parse(apikey)
    token = get(() -> nothing, parsed, "token")
    project_id = get(() -> nothing, parsed, "projectId")
    return token, project_id
end

function stream(f::Function, model::Model, contents::Vector{Content}, apikey::String; http_kw = (;), kw...)
    token, project_id = parse_oauth_credentials(apikey)
    token === nothing && throw(ArgumentError("Missing `token` in google-gemini-cli credentials JSON"))
    project_id === nothing && throw(ArgumentError("Missing `projectId` in google-gemini-cli credentials JSON"))

    system_instruction = haskey(kw, :systemInstruction) ? kw[:systemInstruction] : nothing
    tools = haskey(kw, :tools) ? kw[:tools] : nothing
    tool_choice = haskey(kw, :toolChoice) ? kw[:toolChoice] : nothing
    max_tokens = haskey(kw, :maxTokens) ? kw[:maxTokens] : nothing
    temperature = haskey(kw, :temperature) ? kw[:temperature] : nothing
    thinking = haskey(kw, :thinking) ? kw[:thinking] : nothing

    req = build_request(
        model,
        contents,
        project_id;
        systemInstruction = system_instruction,
        tools = tools,
        toolChoice = tool_choice,
        maxTokens = max_tokens,
        temperature = temperature,
        thinking = thinking,
    )

    endpoint = isempty(model.baseUrl) ? DEFAULT_ENDPOINT : model.baseUrl
    url = string(endpoint, "/v1internal:streamGenerateContent?alt=sse")
    headers = occursin("sandbox.googleapis.com", endpoint) ? copy(ANTIGRAVITY_HEADERS) : copy(GEMINI_CLI_HEADERS)
    headers["Authorization"] = "Bearer $token"
    headers["Content-Type"] = "application/json"
    headers["Accept"] = "text/event-stream"
    model.headers !== nothing && merge!(headers, model.headers)

    debug_stream = haskey(kw, :debug_stream) ? kw[:debug_stream] : false

    return HTTP.open("POST", url, headers; http_kw...) do http
        write(http, JSON.json(req))
        HTTP.closewrite(http)
        response = HTTP.startread(http)
        if response.status < 200 || response.status >= 300
            error_text = try
                String(read(http))
            catch
                ""
            end
            emit_stream_error(f, http, "Cloud Code Assist API error ($(response.status)): $(error_text)")
            return response
        end

        buffer = ""
        try
            while !eof(http)
                data = String(readavailable(http))
                isempty(data) && continue
                buffer *= data
                while true
                    newline = findfirst('\n', buffer)
                    newline === nothing && break
                    line = buffer[1:prevind(buffer, newline)]
                    buffer = buffer[nextind(buffer, newline):end]
                    line = strip(line)
                    isempty(line) && continue
                    startswith(line, "data:") || continue
                    payload = strip(line[6:end])
                    isempty(payload) && continue
                    debug_stream && @info "gemini-cli stream line" length=length(payload)
                    if payload == "[DONE]"
                        f(http, StreamDoneEvent())
                        return response
                    end
                    try
                        f(http, JSON.parse(payload, StreamChunk))
                    catch e
                        emit_stream_error(f, http, e)
                    end
                end
            end
            f(http, StreamDoneEvent())
        catch e
            emit_stream_error(f, http, e)
        end

        return response
    end
end

end # module GoogleGeminiCli
