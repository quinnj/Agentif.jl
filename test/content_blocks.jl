using Test, Agentif, JSON

function dummy_model(; id = "test-model", name = "Test Model", api, provider, baseUrl = "https://example.com", reasoning = false, input = ["text"], compat = nothing)
    return Agentif.Model(;
        id,
        name,
        api,
        provider,
        baseUrl,
        reasoning,
        input,
        cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
        contextWindow = 1024,
        maxTokens = 256,
        compat,
    )
end

@testset "JSON union content parsing" begin
    user = Agentif.UserMessage("hello")
    parsed_user = JSON.parse(JSON.json(user), Agentif.UserMessage)
    @test parsed_user.content[1] isa Agentif.TextContent

    tool = Agentif.ToolResultMessage("call-1", "echo", "ok")
    parsed_tool = JSON.parse(JSON.json(tool), Agentif.ToolResultMessage)
    @test parsed_tool.content[1] isa Agentif.TextContent
end

@testset "OpenAI Completions content blocks" begin
    model = dummy_model(
        api = "openai-completions",
        provider = "mistral",
        baseUrl = "https://api.mistral.ai/v1",
        reasoning = true,
    )
    agent = Agentif.Agent(; prompt = "System prompt", model, apikey = "", input_guardrail = nothing)
    state = Agentif.AgentState()
    assistant = Agentif.assistant_message_for_model(model)
    push!(assistant.content, Agentif.ThinkingContent("Thoughts here"))
    push!(assistant.content, Agentif.TextContent("Answer"))
    push!(
        assistant.content,
        Agentif.ToolCallContent(;
            id = "tool-1",
            name = "add",
            arguments = Dict("x" => 1, "y" => 2),
            thoughtSignature = JSON.json(Dict("foo" => "bar")),
        ),
    )
    push!(state.messages, assistant)

    messages, _ = Agentif.openai_completions_build_messages(agent, state, "hi", model)
    assistant_msgs = [m for m in messages if m.role == "assistant"]
    @test !isempty(assistant_msgs)
    amsg = assistant_msgs[end]
    if amsg.content isa Vector
        text_parts = String[]
        for part in amsg.content
            part.type == "text" || continue
            part.text === nothing && continue
            push!(text_parts, part.text)
        end
        @test any(text -> occursin("Thoughts here", text), text_parts)
    elseif amsg.content isa String
        @test occursin("Thoughts here", amsg.content)
    end
    @test amsg.reasoning_details !== nothing
    @test amsg.reasoning_details[1]["foo"] == "bar"
end

@testset "Google tool result images" begin
    model = dummy_model(
        id = "gemini-3-pro",
        api = "google-generative-ai",
        provider = "google",
        input = ["text", "image"],
    )
    agent = Agentif.Agent(; prompt = "Prompt", model, apikey = "", input_guardrail = nothing)
    state = Agentif.AgentState()
    result = Agentif.ToolResultMessage(;
        call_id = "call-1",
        name = "read",
        content = Agentif.ToolResultContentBlock[Agentif.ImageContent("ZGF0YQ==", "image/png")],
        is_error = false,
    )
    contents = Agentif.google_generative_build_contents(agent, state, [result], model)
    @test !isempty(contents)
    parts = contents[1].parts
    @test parts !== nothing
    @test parts[1].functionResponse !== nothing
    response = parts[1].functionResponse
    @test response.parts !== nothing
    @test !isempty(response.parts)
end

@testset "Anthropic tool result images" begin
    model = dummy_model(
        api = "anthropic-messages",
        provider = "anthropic",
        input = ["text", "image"],
    )
    agent = Agentif.Agent(; prompt = "Prompt", model, apikey = "", input_guardrail = nothing)
    state = Agentif.AgentState()
    result = Agentif.ToolResultMessage(;
        call_id = "call-2",
        name = "read",
        content = Agentif.ToolResultContentBlock[Agentif.ImageContent("ZGF0YQ==", "image/png")],
        is_error = false,
    )
    messages = Agentif.anthropic_build_messages(agent, state, [result], Dict{String, String}(), model)
    @test !isempty(messages)
    msg = messages[1]
    @test msg.role == "user"
    @test msg.content isa Vector
    block = msg.content[1]
    @test block isa Agentif.AnthropicMessages.ToolResultBlock
    @test block.content isa Vector
    @test block.content[1] isa Agentif.AnthropicMessages.TextBlock
end

@testset "MiniMax OpenAI role compatibility" begin
    model = dummy_model(
        api = "openai-completions",
        provider = "minimax",
        baseUrl = "https://api.minimax.io/v1",
        reasoning = true,
    )
    agent = Agentif.Agent(; prompt = "System prompt", model, apikey = "", input_guardrail = nothing)
    state = Agentif.AgentState()
    messages, _ = Agentif.openai_completions_build_messages(agent, state, "hi", model)
    @test !isempty(messages)
    @test messages[1].role == "system"
end
