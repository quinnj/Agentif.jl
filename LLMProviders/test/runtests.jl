using Test
using HTTP
using JSON
using Sockets
using LLMProviders

const OpenAIResponses = LLMProviders.OpenAIResponses
const OpenAICompletions = LLMProviders.OpenAICompletions
const AnthropicMessages = LLMProviders.AnthropicMessages
const GoogleGenerativeAI = LLMProviders.GoogleGenerativeAI
const GoogleGeminiCli = LLMProviders.GoogleGeminiCli

mutable struct DummyUsage
    input::Int
    output::Int
    cacheRead::Int
    cacheWrite::Int
    cost::Any
end

@testset "Future" begin
    f = LLMProviders.Future{Int}(() -> 42)
    @test wait(f) == 42

    f_err = LLMProviders.Future{Int}(() -> error("boom"))
    @test_throws CapturedException wait(f_err)
end

@testset "OpenAICompletions" begin
    msg = OpenAICompletions.Message(
        ; role = "assistant",
        content = "hello",
        extra = Dict("custom_key" => "custom_value"),
    )
    lowered = JSON.lower(msg)
    @test lowered["role"] == "assistant"
    @test lowered["content"] == "hello"
    @test lowered["custom_key"] == "custom_value"

    tool_delta = OpenAICompletions.StreamToolCallDelta(
        ; index = 0,
        id = "call-1",
        var"function" = OpenAICompletions.StreamToolCallFunctionDelta(; name = "read", arguments = "{\"path\":\"README.md\"}"),
    )
    chunk = OpenAICompletions.StreamChunk(
        ; choices = [OpenAICompletions.StreamChoice(; delta = OpenAICompletions.StreamDelta(; tool_calls = [tool_delta]), index = 0)],
    )
    parsed = JSON.parse(JSON.json(chunk), OpenAICompletions.StreamChunk)
    @test parsed.choices[1].delta.tool_calls[1].var"function".name == "read"
end

@testset "OpenAIResponses" begin
    content_json = Vector{UInt8}(codeunits("{\"type\":\"input_text\",\"text\":\"hello\"}"))
    content = JSON.parse(content_json, OpenAIResponses.Content)
    @test content isa OpenAIResponses.InputTextContent
    @test content.text == "hello"

    output = JSON.parse("{\"type\":\"function_call\",\"arguments\":\"{}\",\"call_id\":\"call-1\",\"name\":\"echo\"}", OpenAIResponses.Output)
    @test output isa OpenAIResponses.FunctionToolCall
    @test output.name == "echo"

    event = JSON.parse("{\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}", OpenAIResponses.StreamEvent)
    @test event isa OpenAIResponses.StreamOutputTextDeltaEvent
    @test event.delta == "hi"

    user_item = OpenAIResponses.Message(; role = "user", content = OpenAIResponses.Content[OpenAIResponses.InputTextContent(; text = "hello")])
    req = OpenAIResponses.Request(; model = "gpt-test", input = OpenAIResponses.InputItem[user_item], stream = true)
    roundtrip = JSON.parse(JSON.json(req))
    @test roundtrip["model"] == "gpt-test"
    @test roundtrip["stream"] == true

    unknown_content = JSON.parse("{\"type\":\"output_audio\",\"audio\":\"...\"}", OpenAIResponses.Content)
    @test unknown_content isa OpenAIResponses.UnknownContent

    unknown_output = JSON.parse("{\"type\":\"new_output_type\",\"foo\":\"bar\"}", OpenAIResponses.Output)
    @test unknown_output isa OpenAIResponses.UnknownOutput

    unknown_event = JSON.parse("{\"type\":\"response.unrecognized\",\"foo\":123}", OpenAIResponses.StreamEvent)
    @test unknown_event isa OpenAIResponses.UnknownStreamEvent

    params_schema = OpenAIResponses.schema(@NamedTuple{required::String, optional::Union{Nothing, String}})
    required_fields = haskey(params_schema.spec, "required") ? Set(String.(params_schema.spec["required"])) : Set{String}()
    @test "required" in required_fields
    @test !("optional" in required_fields)
end

@testset "AnthropicMessages" begin
    event = JSON.parse(
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}",
        AnthropicMessages.StreamEvent,
    )
    @test event isa AnthropicMessages.StreamContentBlockDeltaEvent
    @test event.delta isa AnthropicMessages.TextDelta
    @test event.delta.text == "hello"

    msg = JSON.parse("{\"role\":\"user\",\"content\":\"hi\"}", AnthropicMessages.Message)
    @test msg.content == "hi"
end

@testset "GoogleGenerativeAI" begin
    schema = Dict("\$schema" => "https://json-schema.org/draft/2020-12/schema", "type" => Any["string", "null"])
    sanitized = GoogleGenerativeAI.sanitize_schema(schema)
    @test !haskey(sanitized, "\$schema")
    @test sanitized["type"] == "string"
    @test sanitized["nullable"] == true

    anyof_schema = Dict("anyOf" => Any[Dict("type" => "null"), Dict("type" => "integer")])
    sanitized_anyof = GoogleGenerativeAI.sanitize_schema(anyof_schema)
    @test sanitized_anyof["type"] == "integer"
    @test sanitized_anyof["nullable"] == true
end

@testset "GoogleGeminiCli" begin
    model = LLMProviders.Model(
        ; id = "gemini-test",
        name = "Gemini Test",
        api = "google-gemini-cli",
        provider = "google",
        baseUrl = GoogleGeminiCli.DEFAULT_ENDPOINT,
        reasoning = true,
        input = ["text"],
        cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
        contextWindow = 1048576,
        maxTokens = 8192,
    )

    contents = [GoogleGeminiCli.Content(; role = "user", parts = [GoogleGeminiCli.Part(; text = "Hello")])]
    req = GoogleGeminiCli.build_request(
        model,
        contents,
        "project-123";
        toolChoice = "none",
        maxTokens = 256,
        temperature = 0.2,
        thinking = (; enabled = true, level = "high"),
    )
    @test req.project == "project-123"
    @test req.request.toolConfig.functionCallingConfig.mode == "NONE"
    @test req.request.generationConfig.maxOutputTokens == 256
    @test req.request.generationConfig.thinkingConfig.includeThoughts == true
    @test req.request.generationConfig.thinkingConfig.thinkingLevel == "high"
    @test startswith(req.requestId, "agentif-")

    @test GoogleGeminiCli.map_tool_choice("auto") == "AUTO"
    @test GoogleGeminiCli.map_tool_choice("none") == "NONE"
    @test GoogleGeminiCli.map_tool_choice("any") == "ANY"
    @test GoogleGeminiCli.map_tool_choice("unknown") == "AUTO"

    token, project = GoogleGeminiCli.parse_oauth_credentials("{\"token\":\"abc\",\"projectId\":\"proj\"}")
    @test token == "abc"
    @test project == "proj"
end

@testset "Model registry helpers" begin
    provider = "unit-provider-$(rand(1:10^9))"
    model = LLMProviders.Model(
        ; id = "unit-model",
        name = "Unit Model",
        api = "openai-completions",
        provider = provider,
        baseUrl = "https://example.com/v1",
        reasoning = false,
        input = ["text"],
        cost = Dict("input" => 1.0, "output" => 2.0),  # intentionally partial to verify default zero handling
        contextWindow = 4096,
        maxTokens = 1024,
    )
    LLMProviders.registerModel!(model)
    fetched = LLMProviders.getModel(provider, "unit-model")
    @test fetched !== nothing
    @test fetched.id == "unit-model"
    @test provider in LLMProviders.getProviders()
    @test any(m -> m.id == "unit-model", LLMProviders.getModels(provider))

    usage = DummyUsage(1000, 2000, 3000, 4000, nothing)
    cost = LLMProviders.calculateCost(model, usage)
    @test cost["input"] == 0.001
    @test cost["output"] == 0.004
    @test cost["cacheRead"] == 0.0
    @test cost["cacheWrite"] == 0.0
    @test cost["total"] == 0.005
    @test usage.cost === cost
end

@testset "discover_models!" begin
    server = HTTP.serve!(ip"127.0.0.1", 0) do req
        if req.target == "/v1/models"
            return HTTP.Response(
                200,
                ["Content-Type" => "application/json"],
                """
                {
                  "data": [
                    {"id": "local-a"},
                    {"name": "missing-id"}
                  ]
                }
                """,
            )
        elseif req.target == "/bad-data/v1/models"
            return HTTP.Response(200, ["Content-Type" => "application/json"], "{\"data\": {\"id\": \"oops\"}}")
        elseif req.target == "/bad-json/v1/models"
            return HTTP.Response(200, ["Content-Type" => "application/json"], "{bad json")
        end
        return HTTP.Response(404, ["Content-Type" => "text/plain"], "not found")
    end

    try
        sock = getsockname(server.listener.server)
        port = sock[2]

        provider_ok = "discover-ok-$(rand(1:10^9))"
        models = LLMProviders.discover_models!("http://127.0.0.1:$port"; provider = provider_ok)
        @test length(models) == 1
        @test models[1].id == "local-a"
        @test LLMProviders.getModel(provider_ok, "local-a") !== nothing

        @test_throws Exception LLMProviders.discover_models!("http://127.0.0.1:$port/bad-data"; provider = "discover-bad-data")
        @test_throws Exception LLMProviders.discover_models!("http://127.0.0.1:$port/bad-json"; provider = "discover-bad-json")
        @test_throws Exception LLMProviders.discover_models!("http://127.0.0.1:$port/missing"; provider = "discover-404")
    finally
        close(server)
    end
end

@testset "OpenAI Codex model registry" begin
    spark = LLMProviders.getModel("openai-codex", "gpt-5.3-codex-spark")
    @test spark !== nothing
    @test spark.id == "gpt-5.3-codex-spark"
    @test spark.api == "openai-codex-responses"
    @test spark.provider == "openai-codex"
    @test spark.maxTokens == 32000

    v51 = LLMProviders.getModel("openai-codex", "gpt-5.1-codex")
    @test v51 !== nothing
    @test v51.id == "gpt-5.1-codex"
end
