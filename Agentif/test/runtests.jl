using Test
using Agentif

function dummy_model()
    return Model(
        id = "test-model",
        name = "test-model",
        api = "openai-completions",
        provider = "test",
        baseUrl = "http://localhost",
        reasoning = false,
        input = ["text"],
        cost = Dict(
            "input" => 0.0,
            "output" => 0.0,
            "cacheRead" => 0.0,
            "cacheWrite" => 0.0,
        ),
        contextWindow = 1,
        maxTokens = 1,
        headers = nothing,
        compat = nothing,
        kw = (;),
    )
end

function make_agent(; prompt = "test prompt", tools = AgentTool[])
    return Agent(
        id = "agent-1",
        name = "agent-1",
        prompt = prompt,
        model = dummy_model(),
        apikey = "test-key",
        tools = tools,
    )
end

function make_base_handler(; with_tool_call::Bool = false, call_counter = Ref(0), inputs = Agentif.AgentTurnInput[])
    return function (f, agent::Agent, state::AgentState, current_input::Agentif.AgentTurnInput, abort::Agentif.Abort; kw...)
        call_counter[] += 1
        push!(inputs, current_input)
        msg = AssistantMessage(; provider = "test", api = "test", model = "test")
        if with_tool_call && call_counter[] == 1
            call = AgentToolCall(; call_id = "call-1", name = "echo", arguments = "{\"text\":\"hi\"}")
            push!(msg.tool_calls, call)
        end
        Agentif.append_state!(state, current_input, msg, Usage())
        if with_tool_call && call_counter[] == 1
            state.pending_tool_calls = Agentif.PendingToolCall[Agentif.PendingToolCall(; call_id = "call-1", name = "echo", arguments = "{\"text\":\"hi\"}")]
            state.most_recent_stop_reason = :tool_calls
        else
            state.pending_tool_calls = Agentif.PendingToolCall[]
            state.most_recent_stop_reason = :stop
        end
        return state
    end
end

@testset "stream (MiniMax live)" begin
    provider = get(ENV, "VO_AGENT_PROVIDER", "")
    model_id = get(ENV, "VO_AGENT_MODEL", "")
    apikey = get(ENV, "VO_AGENT_API_KEY", "")

    if isempty(provider) || isempty(model_id) || isempty(apikey)
        @info "Skipping live MiniMax tests; VO_AGENT_* env vars are not set."
    else
        model = getModel(provider, model_id)
        @test model !== nothing
        tool = @tool "Echo a string." echo(text::String) = text
        agent = Agent(
            id = "live-agent",
            name = "live-agent",
            prompt = "You must call the echo tool with JSON arguments {\"text\":\"pong\"}. Do not answer directly.",
            model = model,
            apikey = apikey,
            tools = [tool],
        )
        events = AgentEvent[]
        state = AgentState()
        result_state = stream(
            e -> push!(events, e),
            agent,
            state,
            "ping",
            Abort();
            tool_choice = Dict("type" => "function", "function" => Dict("name" => "echo")),
        )
        @test result_state isa AgentState
        @test result_state.most_recent_stop_reason !== nothing
        @test !isempty(result_state.messages)
        @test !isempty(result_state.pending_tool_calls)
        @test result_state.pending_tool_calls[1].name == "echo"
        @test any(e -> e isa ToolCallRequestEvent, events)
    end
end

@testset "steer_middleware" begin
    steer_queue = Channel{Agentif.AgentTurnInput}(1)
    put!(steer_queue, "steer")
    call_counter = Ref(0)
    inputs = Agentif.AgentTurnInput[]
    base_handler = make_base_handler(; call_counter, inputs)
    handler = steer_middleware(base_handler, steer_queue)
    agent = make_agent()
    state = AgentState()
    result_state = handler(identity, agent, state, "original", Abort())
    @test call_counter[] == 1
    @test inputs[1] == "steer"
    @test length(result_state.messages) >= 2
    @test result_state.messages[1] isa UserMessage
    @test message_text(result_state.messages[1]) == "original"
    @test result_state.messages[2] isa UserMessage
    @test message_text(result_state.messages[2]) == "steer"
end

@testset "tool_call_middleware" begin
    call_counter = Ref(0)
    inputs = Agentif.AgentTurnInput[]
    base_handler = make_base_handler(; with_tool_call = true, call_counter, inputs)
    handler = tool_call_middleware(base_handler)
    tool = @tool "Echo a string." echo(text::String) = text
    agent = make_agent(; tools = [tool])
    state = AgentState()
    result_state = handler(identity, agent, state, "hello", Abort())
    @test call_counter[] == 2
    @test length(inputs) == 2
    @test inputs[2] isa Vector{ToolResultMessage}
    tool_results = inputs[2]
    @test length(tool_results) == 1
    @test message_text(tool_results[1]) == "hi"
    @test isempty(result_state.pending_tool_calls)
end

@testset "queue_middleware" begin
    message_queue = Channel{Agentif.AgentTurnInput}(2)
    put!(message_queue, "followup")
    put!(message_queue, "followup-2")
    call_counter = Ref(0)
    inputs = Agentif.AgentTurnInput[]
    base_handler = make_base_handler(; call_counter, inputs)
    handler = queue_middleware(base_handler, message_queue)
    agent = make_agent()
    state = AgentState()
    result_state = handler(identity, agent, state, "first", Abort())
    @test call_counter[] == 3
    @test inputs[1] == "first"
    @test inputs[2] == "followup"
    @test inputs[3] == "followup-2"
    @test !isempty(result_state.messages)
end

@testset "session_middleware" begin
    store = InMemorySessionStore()
    call_counter = Ref(0)
    base_handler = make_base_handler(; call_counter)
    handler = session_middleware(base_handler, store)
    agent = make_agent()
    state = AgentState()
    result_state = handler(identity, agent, state, "hello", Abort())
    @test result_state.session_id !== nothing
    sid = result_state.session_id
    @test haskey(store.sessions, sid)

    len1 = length(result_state.messages)
    result_state_2 = handler(identity, agent, AgentState(), "again", Abort())
    @test result_state_2.session_id == sid
    @test length(result_state_2.messages) > len1
end

@testset "input_guardrail_middleware" begin
    guardrail = (prompt, input, apikey) -> input != "blocked"
    base_handler = make_base_handler()
    handler = input_guardrail_middleware(base_handler, guardrail)
    agent = make_agent()
    state = AgentState()
    @test_throws Agentif.InvalidInputError handler(identity, agent, state, "blocked", Abort())
end

@testset "skills_middleware" begin
    meta = SkillMetadata(
        "demo",
        "demo skill",
        nothing,
        nothing,
        Dict{String, String}(),
        nothing,
        "/tmp/demo",
        "/tmp/demo/SKILL.md",
    )
    registry = SkillRegistry(Dict("demo" => meta), Dict{String, String}())
    prompt_seen = Ref("")
    base_handler = function (f, agent::Agent, state::AgentState, current_input::Agentif.AgentTurnInput, abort::Agentif.Abort; kw...)
        prompt_seen[] = agent.prompt
        msg = AssistantMessage(; provider = "test", api = "test", model = "test")
        Agentif.append_state!(state, current_input, msg, Usage())
        state.pending_tool_calls = Agentif.PendingToolCall[]
        state.most_recent_stop_reason = :stop
        return state
    end
    handler = skills_middleware(base_handler, registry)
    agent = make_agent(; prompt = "base")
    state = AgentState()
    handler(identity, agent, state, "hello", Abort())
    @test occursin("<available_skills>", prompt_seen[])
end
