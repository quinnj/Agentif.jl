using Test, Claw, Agentif, SQLite, JSON, LLMTools

function durable_model(; window = 100000)
    return Agentif.Model(;
        id = "durable-test", name = "durable-test", api = "openai-completions", provider = "test", baseUrl = "http://localhost",
        reasoning = false, input = ["text"], cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
        contextWindow = window, maxTokens = 1000, headers = nothing, compat = nothing, kw = (;)
    )
end
function durable_message(agent, text; calls = Agentif.AgentToolCall[])
    return Agentif.AssistantMessage(;
        provider = agent.model.provider, api = agent.model.api, model = agent.model.id,
        content = Agentif.AssistantContentBlock[Agentif.TextContent(text)], tool_calls = calls
    )
end
function durable_stream(f, agent, state, input, abort; kw...)
    message = durable_message(agent, "answer")
    f(Agentif.MessageUpdateEvent(:assistant, message, :text_delta, "answer", nothing))
    Agentif.append_state!(state, input, message, Agentif.Usage(; input = 3, output = 2, total = 5))
    state.most_recent_stop_reason = :stop
    return state
end
function durable_fixture(path; stream = durable_stream, tools = Agentif.AgentTool[], specs = nothing, limits = Claw.HarnessLimits(), fault = (p, h) -> nothing, window = 100000, compact = false)
    h = Claw.open_harness(path; stream_fn = stream, limits, fault, compaction = Agentif.CompactionConfig(; enabled = compact, keep_recent_tokens = 16, reserve_tokens = compact ? 1000 : 20))
    agent = Agentif.Agent(; model = durable_model(; window), prompt = "test", apikey = "secret-test-key", tools)
    profile = specs === nothing ? Claw.register_profile!(h, agent) : Claw.register_profile!(h, agent; specs)
    c = Claw.ensure_conversation!(h; branch_id = "test", profile)
    return h, c, profile
end
