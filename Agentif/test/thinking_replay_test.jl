using Test, Agentif, JSON

@testset "reasoning-only completions replay has assistant content" begin
    model = Agentif.Model(
        id = "local-reasoner", name = "local-reasoner", api = "openai-completions",
        provider = "local", baseUrl = "http://localhost/v1", reasoning = true,
        input = ["text"], cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
        contextWindow = 4096, maxTokens = 1024,
    )
    agent = Agentif.Agent(; model, prompt = "", apikey = "test")
    for signature in (nothing, "reasoning_content"), text in ("", " \t\n", "visible answer")
        content = Agentif.AssistantContentBlock[
            Agentif.ThinkingContent(; thinking = "retained reasoning", thinkingSignature = signature),
            Agentif.TextContent(text),
        ]
        assistant = Agentif.AssistantMessage(; provider = model.provider, api = model.api, model = model.id, content)
        state = Agentif.AgentState(; messages = Agentif.StoredAgentMessage[Agentif.UserMessage("first question"), assistant])
        messages, _ = Agentif.openai_completions_build_messages(agent, state, "next question", model)
        wire = JSON.parse(JSON.json(messages))
        @test getindex.(wire, "role") == ["user", "assistant", "user"]
        replay = wire[2]
        @test !isempty(replay["content"])
        expected = signature === nothing || isempty(strip(text)) ? "retained reasoning" : "visible answer"
        @test occursin(expected, JSON.json(replay["content"]))
        if signature !== nothing
            @test replay[signature] == "retained reasoning"
            isempty(strip(text)) || @test !occursin("retained reasoning", JSON.json(replay["content"]))
        end
        @test assistant.content[1].thinking == "retained reasoning"
    end

    assistant = Agentif.AssistantMessage(;
        provider = model.provider, api = model.api, model = model.id,
        content = Agentif.AssistantContentBlock[
            Agentif.ThinkingContent(; thinking = "plan", thinkingSignature = "reasoning_content"),
            Agentif.ToolCallContent(; id = "call-1", name = "lookup", arguments = Dict{String, Any}()),
        ],
    )
    state = Agentif.AgentState(; messages = Agentif.StoredAgentMessage[assistant])
    messages, _ = Agentif.openai_completions_build_messages(agent, state, Agentif.ToolResultMessage[], model)
    replay = only(m for m in messages if m.role == "assistant")
    @test replay.content === nothing
    @test length(replay.tool_calls) == 1
    @test replay.extra["reasoning_content"] == "plan"
end
