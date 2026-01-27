using Test, Agentif, JSON

function build_tools()
    return Agentif.AgentTool[
        Agentif.@tool("adds two integers", add(x::Int, y::Int) = x + y),
    ]
end

function build_agent(model, apikey; tools = Agentif.AgentTool[], prompt = "You are a helpful assistant.")
    return Agentif.Agent(
        ; prompt,
        model,
        apikey,
        input_guardrail = nothing,
        tools,
    )
end

function run_stream(agent, input; state = Agentif.AgentState(), kw...)
    events = []
    f = event -> push!(events, event)
    response = Agentif.stream(f, agent, state, input, agent.apikey; kw...)
    return response, events, state
end

function run_evaluate!(agent, input; kw...)
    events = []
    f = event -> push!(events, event)
    result = wait(Agentif.evaluate!(f, agent, input; kw...))
    return result, events
end

function run_evaluate(agent, input; kw...)
    events = []
    f = event -> push!(events, event)
    result = Agentif.evaluate(f, agent, input; kw...)
    return result, events
end

function assert_stream_response(response, events; expect_tool = false)
    @test response isa Agentif.AgentResponse
    @test response.message isa Agentif.AssistantMessage
    @test any(e -> e isa Agentif.MessageEndEvent, events)
    return if expect_tool
        @test response.stop_reason == :tool_calls
        @test !isempty(response.message.tool_calls)
        @test any(e -> e isa Agentif.ToolCallRequestEvent, events)
    end
end

function assert_evaluate_result(result, events)
    @test result isa Agentif.AgentResult
    return @test any(e -> e isa Agentif.MessageEndEvent, events)
end

function tool_choice_kwargs(model::Agentif.Model)
    if model.api == "openai-responses"
        return (; tool_choice = "required")
    elseif model.api == "openai-completions"
        return (; tool_choice = Dict("type" => "function", "function" => Dict("name" => "add")))
    elseif model.api == "anthropic-messages"
        return (; tool_choice = Dict("type" => "tool", "name" => "add"))
    elseif model.api == "google-generative-ai"
        return (; toolConfig = Dict("functionCallingConfig" => Dict("mode" => "ANY")))
    elseif model.api == "google-gemini-cli"
        return (; toolChoice = "any")
    end
    return (;)
end

function tool_call_sum(call::Agentif.AgentToolCall)
    args = JSON.parse(call.arguments)
    x = get(() -> nothing, args, "x")
    y = get(() -> nothing, args, "y")
    x === nothing && return nothing
    y === nothing && return nothing
    return x + y
end

function assert_tool_execution(events; expected_output = "5")
    tool_execs = filter(e -> e isa Agentif.ToolExecutionEndEvent, events)
    @test !isempty(tool_execs)
    @test tool_execs[1].result.name == "add"
    return @test message_text(tool_execs[1].result) == expected_output
end
