using Test, Agentif

apikey = "***REDACTED_OPENAI_KEY***"

model = Agentif.getModel("openai", "gpt-5-nano")

# Define tools
tools = Agentif.AgentTool[
    Agentif.@tool("can be used to add 2 integers together", add(x::Int, y::Int) = x + y),
    Agentif.@tool_requires_approval("can be used to multiply 2 integers together", multiply(x::Int, y::Int) = x * y)
]

agent = Agentif.Agent(;
    prompt="You are a math assistant solely purposed to help with math questions",
    model,
    input_guardrail=(args...) -> true, # Permissive guardrail for logic tests
    tools
)

# Helper to run agent and capture events
function run_agent(agent, input, apikey; kw...)
    events = Any[]
    f = (event) -> push!(events, event)
    # evaluate! returns a Future, we wait on it to get the Result
    result = wait(Agentif.evaluate!(f, agent, input, apikey; kw...))
    return result, events
end

@testset "OpenAI Completions Compatible (requires OPENAI_COMPAT_API_KEY)" begin
    apikey = get(() -> nothing, ENV, "OPENAI_COMPAT_API_KEY")
    provider = get(() -> nothing, ENV, "OPENAI_COMPAT_PROVIDER")
    model_id = get(() -> nothing, ENV, "OPENAI_COMPAT_MODEL")
    if apikey === nothing || provider === nothing || model_id === nothing
        @info "Skipping OpenAI Completions compatible test; set OPENAI_COMPAT_API_KEY, OPENAI_COMPAT_PROVIDER, OPENAI_COMPAT_MODEL"
        return
    end
    model = Agentif.getModel(provider, model_id)
    model === nothing && error("unknown model: provider=$(repr(provider)) model_id=$(repr(model_id))")
    compat_agent = Agentif.Agent(;
        prompt="You are a test assistant.",
        model,
        input_guardrail=nothing,
        tools=Agentif.AgentTool[]
    )
    result, events = run_agent(compat_agent, "Say hello in one short sentence.", apikey)
    @test result isa Agentif.Result
    @test !isempty(result.previous_response_id)
    @test any(e -> e isa Agentif.MessageEndEvent, events)
end

@testset "Anthropic Messages (requires ANTHROPIC_API_KEY)" begin
    apikey = get(() -> nothing, ENV, "ANTHROPIC_API_KEY")
    if apikey === nothing
        @info "Skipping Anthropic test; set ANTHROPIC_API_KEY"
        return
    end
    model_id = get(() -> "claude-sonnet-4-5", ENV, "ANTHROPIC_MODEL_ID")
    model = Agentif.getModel("anthropic", model_id)
    model === nothing && error("unknown anthropic model: $(repr(model_id))")
    anthropic_agent = Agentif.Agent(;
        prompt="You are a test assistant.",
        model,
        input_guardrail=nothing,
        tools=Agentif.AgentTool[]
    )
    result, events = run_agent(anthropic_agent, "Say hello in one short sentence.", apikey)
    @test result isa Agentif.Result
    @test !isempty(result.previous_response_id)
    @test any(e -> e isa Agentif.MessageEndEvent, events)
end

@testset "Google Generative AI (requires GOOGLE_API_KEY)" begin
    apikey = get(() -> nothing, ENV, "GOOGLE_API_KEY")
    if apikey === nothing
        @info "Skipping Google Generative AI test; set GOOGLE_API_KEY"
        return
    end
    model_id = get(() -> "gemini-2.5-flash", ENV, "GOOGLE_MODEL_ID")
    model = Agentif.getModel("google", model_id)
    model === nothing && error("unknown google model: $(repr(model_id))")
    google_agent = Agentif.Agent(;
        prompt="You are a test assistant.",
        model,
        input_guardrail=nothing,
        tools=Agentif.AgentTool[]
    )
    result, events = run_agent(google_agent, "Say hello in one short sentence.", apikey)
    @test result isa Agentif.Result
    @test !isempty(result.previous_response_id)
    @test any(e -> e isa Agentif.MessageEndEvent, events)
end

@testset "Agentif Tests" begin

    @testset "Basic Tool Execution (No Approval)" begin
        input = "What is 10 + 20?"
        result, events = run_agent(agent, input, apikey)

        # Should finish without pending tools
        @test isempty(result.pending_tool_calls)
        
        # Check that the tool was executed
        tool_execs = filter(e -> e isa Agentif.ToolExecutionEndEvent, events)
        if isempty(tool_execs)
             # Fallback: check if the model just answered directly (valid behavior, though we prefer tool use for this test)
             final_msgs = filter(e -> e isa Agentif.MessageEndEvent, events)
             @test !isempty(final_msgs)
             @test contains(final_msgs[end].message.text, "30")
        else
            @test tool_execs[1].result.name == "add"
            @test tool_execs[1].result.output == "30"

            # Check final response text
            final_msgs = filter(e -> e isa Agentif.MessageEndEvent, events)
            @test !isempty(final_msgs)
            last_msg = final_msgs[end].message
            @test last_msg isa Agentif.AssistantTextMessage
            @test contains(last_msg.text, "30")
        end
    end

    @testset "Tool Approval Workflow" begin
        input = "Calculate 3 * 4 using the multiply tool."
        result, events = run_agent(agent, input, apikey)

        # Should have pending tool call for multiply
        @test !isempty(result.pending_tool_calls)
        ptc = result.pending_tool_calls[1]
        @test ptc.name == "multiply"
        
        # Verify execution hasn't happened yet (no ToolExecutionEndEvent for this call)
        # Note: Depending on implementation, ToolCallRequestEvent happens, but Execution shouldn't complete if approval is needed.
        # Actually in evaluate!, it stops and returns.
        
        # APPROVE
        Agentif.approve!(ptc)
        
        # Continue execution
        result_2, events_2 = run_agent(agent, result.pending_tool_calls, apikey; previous_response_id=result.previous_response_id)
        
        # Should now be finished
        @test isempty(result_2.pending_tool_calls)
        
        # Check execution
        tool_execs = filter(e -> e isa Agentif.ToolExecutionEndEvent, events_2)
        @test !isempty(tool_execs)
        @test tool_execs[1].result.name == "multiply"
        @test tool_execs[1].result.output == "12"
        
        # Check final text
        final_msgs = filter(e -> e isa Agentif.MessageEndEvent, events_2)
        @test !isempty(final_msgs)
        @test contains(final_msgs[end].message.text, "12")
    end

    @testset "Tool Rejection Workflow" begin
        input = "Calculate 10 * 10 using the multiply tool."
        result, events = run_agent(agent, input, apikey)

        @test !isempty(result.pending_tool_calls)
        ptc = result.pending_tool_calls[1]
        @test ptc.name == "multiply"

        # REJECT
        Agentif.reject!(ptc, "User denied this operation.")

        # Continue execution
        result_2, events_2 = run_agent(agent, result.pending_tool_calls, apikey; previous_response_id=result.previous_response_id)
        
        # Check that it handled the rejection (failed tool execution or specific output)
        tool_execs = filter(e -> e isa Agentif.ToolExecutionEndEvent, events_2)
        @test !isempty(tool_execs)
        @test tool_execs[1].result.is_error == true
        @test tool_execs[1].result.output == "User denied this operation."

        # Agent should likely acknowledge the cancellation or mention the tool wasn't used
        final_msgs = filter(e -> e isa Agentif.MessageEndEvent, events_2)
        @test !isempty(final_msgs)
        # We don't strictly assert the text content as LLM might vary (and might even do the math mentally)
        # The important part is that the tool execution was recorded as an error with the rejection reason.
    end

    @testset "Input Guardrail" begin
        # Create a specific agent with the strict guardrail for this test
        strict_agent = Agentif.Agent(;
            prompt="You are a math assistant solely purposed to help with math questions",
            model,
            input_guardrail=Agentif.default_input_guardrail(model),
            tools
        )
        
        # Question unrelated to math
        input = "What is the capital of France?"
        
        # We expect the strict guardrail to throw an ArgumentError, which comes wrapped in a CapturedException
        try
            run_agent(strict_agent, input, apikey)
            @error "Should have thrown an exception"
            @test false
        catch e
            if e isa CapturedException
                @test e.ex isa ArgumentError
            else
                # If it's not wrapped (depending on how Future works in that path), check direct
                @test e isa ArgumentError
            end
        end
    end

end
