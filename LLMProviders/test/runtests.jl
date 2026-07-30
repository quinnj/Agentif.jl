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

# Mirrors the field surface of Agentif.Usage (which has no `cost` field);
# calculateCost must not require or mutate one.
struct DummyUsage
    input::Int
    output::Int
    cacheRead::Int
    cacheWrite::Int
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

    usage_chunk = JSON.parse(
        """
        {
          "choices": [{"delta": {}, "index": 0}],
          "usage": {
            "prompt_tokens": 10,
            "completion_tokens": 4,
            "total_tokens": 14,
            "prompt_tokens_details": {"cached_tokens": 3},
            "completion_tokens_details": {"reasoning_tokens": 2}
          }
        }
        """,
        OpenAICompletions.StreamChunk,
    )
    @test usage_chunk.usage !== nothing
    @test usage_chunk.usage.prompt_tokens_details.cached_tokens == 3
    @test usage_chunk.usage.completion_tokens_details.reasoning_tokens == 2
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

    # redacted_thinking parses as a first-class block
    redacted_event = JSON.parse(
        "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"redacted_thinking\",\"data\":\"EmwKAhgB\"}}",
        AnthropicMessages.StreamEvent,
    )
    @test redacted_event isa AnthropicMessages.StreamContentBlockStartEvent
    @test redacted_event.content_block isa AnthropicMessages.RedactedThinkingBlock
    @test redacted_event.content_block.data == "EmwKAhgB"

    # redacted_thinking serializes back to the wire shape for replay
    lowered = JSON.parse(JSON.json(AnthropicMessages.RedactedThinkingBlock(; data = "opaque")))
    @test lowered["type"] == "redacted_thinking"
    @test lowered["data"] == "opaque"

    # unknown content block types parse to the catch-all instead of throwing
    unknown_block_event = JSON.parse(
        "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"server_tool_use\",\"id\":\"srvtoolu_1\",\"name\":\"web_search\",\"input\":{}}}",
        AnthropicMessages.StreamEvent,
    )
    @test unknown_block_event isa AnthropicMessages.StreamContentBlockStartEvent
    @test unknown_block_event.content_block isa AnthropicMessages.UnknownContentBlock
    @test unknown_block_event.content_block.type == "server_tool_use"

    # unknown delta types parse to the catch-all instead of throwing
    unknown_delta_event = JSON.parse(
        "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"citations_delta\",\"citation\":{\"type\":\"web_search_result_location\"}}}",
        AnthropicMessages.StreamEvent,
    )
    @test unknown_delta_event isa AnthropicMessages.StreamContentBlockDeltaEvent
    @test unknown_delta_event.delta isa AnthropicMessages.UnknownContentBlockDelta
    @test unknown_delta_event.delta.type == "citations_delta"

    # non-streaming Response tolerates unknown and redacted blocks
    response = JSON.parse(
        """
        {
          "id": "msg_1",
          "model": "claude-test",
          "role": "assistant",
          "stop_reason": "end_turn",
          "content": [
            {"type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": {"query": "x"}},
            {"type": "redacted_thinking", "data": "opaque"},
            {"type": "text", "text": "done"}
          ],
          "usage": {"input_tokens": 3, "output_tokens": 5}
        }
        """,
        AnthropicMessages.Response,
    )
    @test response.content[1] isa AnthropicMessages.UnknownContentBlock
    @test response.content[2] isa AnthropicMessages.RedactedThinkingBlock
    @test response.content[2].data == "opaque"
    @test response.content[3] isa AnthropicMessages.TextBlock
    @test response.content[3].text == "done"
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

    usage = DummyUsage(1000, 2000, 3000, 4000)
    cost = LLMProviders.calculateCost(model, usage)
    @test cost["input"] == 0.001
    @test cost["output"] == 0.004
    @test cost["cacheRead"] == 0.0
    @test cost["cacheWrite"] == 0.0
    @test cost["total"] == 0.005
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

    v54 = LLMProviders.getModel("openai-codex", "gpt-5.4")
    @test v54 !== nothing
    @test v54.id == "gpt-5.4"
end

@testset "Generated model registry" begin
    # Roster shipped by models_generated.jl + models_custom.jl. Pinned explicitly so
    # the structural sweep below ignores providers other testsets register ad hoc,
    # and so an upstream provider appearing/disappearing is a deliberate test update.
    registry_providers = [
        "amazon-bedrock", "anthropic", "azure-openai-responses", "cerebras",
        "github-copilot", "google", "google-antigravity", "google-gemini-cli",
        "google-vertex", "groq", "huggingface", "kimi-coding", "minimax",
        "minimax-cn", "mistral", "openai", "openai-codex", "opencode",
        "opencode-go", "openrouter", "vercel-ai-gateway", "xai", "zai",
    ]
    @test issubset(registry_providers, LLMProviders.getProviders())
    all_models = [m for p in registry_providers for m in LLMProviders.getModels(p)]
    # Lower bound, not an exact count: models_custom.jl layers additional entries on
    # top, so an exact assertion fails every time a custom model is added.
    @test length(all_models) >= 784

    # (a) Current frontier models are present with the prices upstream publishes.
    # Values are verbatim from pi-mono packages/ai/src/models.generated.ts.
    for (provider, id, input, output) in [
            ("anthropic", "claude-sonnet-4-6", 3.0, 15.0),
            ("anthropic", "claude-opus-4-6", 5.0, 25.0),
            ("anthropic", "claude-haiku-4-5", 1.0, 5.0),
            ("openai", "gpt-5.4", 2.5, 15.0),
            ("google", "gemini-3.1-pro-preview", 2.0, 12.0),
            ("zai", "glm-5", 1.0, 3.2),
        ]
        model = LLMProviders.getModel(provider, id)
        @test model !== nothing
        if model !== nothing
            @test model.id == id
            @test model.provider == provider
            @test model.cost["input"] == input
            @test model.cost["output"] == output
            @test model.contextWindow > 0
            @test model.maxTokens > 0
        end
    end

    # Providers that only exist after the 2026-07 registry refresh.
    for provider in ["azure-openai-responses", "huggingface", "kimi-coding", "opencode-go"]
        @test !isempty(LLMProviders.getModels(provider))
    end

    # (b) Structural sanity across every registered model.
    # `openrouter/auto` carries a -1_000_000 sentinel upstream (dynamic pricing
    # resolved per request), so it is the one documented exception.
    negative_cost_sentinels = Set([("openrouter", "openrouter/auto")])
    for model in all_models
        key = (model.provider, model.id)
        if key in negative_cost_sentinels
            @test model.cost["input"] == -1.0e6
        else
            @test all(>=(0.0), values(model.cost))
        end
        @test model.contextWindow > 0
        @test model.maxTokens > 0
        @test !isempty(model.id)
        @test !isempty(model.api)
        @test !isempty(model.input)
    end

    # Every model must expose the four cost keys `calculateCost` reads.
    @test all(m -> issetequal(keys(m.cost), ["input", "output", "cacheRead", "cacheWrite"]), all_models)

    # (c) Costs are carried through verbatim from upstream, including the
    # binary-float dust in the source data. Fidelity beats cosmetics: rounding
    # here would silently diverge from pi-mono's published numbers.
    olmo = LLMProviders.getModel("openrouter", "allenai/olmo-3.1-32b-instruct")
    @test olmo !== nothing
    @test olmo !== nothing && olmo.cost["input"] === 0.19999999999999998
    @test olmo !== nothing && olmo.cost["input"] !== 0.2

    # models_custom.jl is layered on top of the generated file and must keep winning.
    spark = LLMProviders.getModel("openai-codex", "gpt-5.3-codex-spark")
    @test spark !== nothing && spark.maxTokens == 32000          # custom value, not upstream's
    for id in ["gpt-5.1", "gpt-5.2", "gpt-5.3-codex", "gpt-5.4"]
        m = LLMProviders.getModel("openai-codex", id)
        @test m !== nothing
        # ChatGPT-OAuth transport is subscription-billed; custom zeroes upstream's API prices.
        @test m !== nothing && all(==(0.0), values(m.cost))
    end
    @test LLMProviders.getModel("openai-codex", "gpt-codex-5.3") !== nothing  # custom-only alias

    # Upstream now ships a real `minimax` provider; the custom overlay adds its
    # OpenAI-compatible entry alongside (keyed by the OpenRouter id, `id` field
    # holds the MiniMax API name -- a pre-existing quirk, asserted so it is not
    # broken silently by a refresh).
    @test LLMProviders.getModel("minimax", "MiniMax-M2.5") !== nothing
    m21 = LLMProviders.getModel("minimax", "minimax/minimax-m2.1")
    @test m21 !== nothing
    @test m21 !== nothing && m21.baseUrl == "https://api.minimax.io/v1"
    @test m21 !== nothing && m21.id == "MiniMax-M2.1"

    # google-gemini-cli entries stay on the Cloud Code Assist endpoint at $0.
    for model in LLMProviders.getModels("google-gemini-cli")
        @test model.api == "google-gemini-cli"
        @test model.baseUrl == "https://cloudcode-pa.googleapis.com"
        @test all(==(0.0), values(model.cost))
    end
end

@testset "Custom frontier Anthropic models" begin
    # Upstream's generated registry tops out at the 4.6 generation; models_custom.jl
    # fills in the current frontier. Prices from Anthropic's model overview docs
    # (retrieved 2026-07-30).
    expected = Dict(
        "claude-fable-5"  => (10.0, 50.0),
        "claude-opus-5"   => (5.0, 25.0),
        "claude-sonnet-5" => (3.0, 15.0),   # standard rate; intro $2/$10 ends 2026-08-31
        "claude-opus-4-8" => (5.0, 25.0),
        "claude-opus-4-7" => (5.0, 25.0),
    )
    for (id, (input_cost, output_cost)) in expected
        model = LLMProviders.getModel("anthropic", id)
        @test model !== nothing
        model === nothing && continue
        @test model.api == "anthropic-messages"
        @test model.provider == "anthropic"
        @test model.cost["input"] == input_cost
        @test model.cost["output"] == output_cost
        # Anthropic's published cache multipliers: read 0.1x, write 1.25x input.
        @test model.cost["cacheRead"] == round(input_cost * 0.1; digits = 6)
        @test model.cost["cacheWrite"] == round(input_cost * 1.25; digits = 6)
        # derived values must not carry binary-float dust of our own making
        @test model.cost["cacheRead"] != 0.30000000000000004
        @test model.contextWindow == 1000000
        @test model.maxTokens == 128000
        @test model.reasoning
    end

    # Custom entries must only fill gaps, never shadow a generated model.
    haiku = LLMProviders.getModel("anthropic", "claude-haiku-4-5")
    @test haiku !== nothing
    @test haiku.cost["input"] == 1
    @test haiku.contextWindow == 200000
end
