using Test, Agentif

@testset "OpenAI Responses Stream" begin
    apikey = get(() -> nothing, ENV, "OPENAI_RESPONSES_API_KEY")
    model_id = get(() -> nothing, ENV, "OPENAI_RESPONSES_MODEL")
    provider = get(() -> "openai", ENV, "OPENAI_RESPONSES_PROVIDER")
    if apikey === nothing || model_id === nothing
        @info "Skipping OpenAI Responses stream; set OPENAI_RESPONSES_API_KEY and OPENAI_RESPONSES_MODEL (optional OPENAI_RESPONSES_PROVIDER)"
        return
    end

    model = Agentif.getModel(provider, model_id)
    model === nothing && error("unknown model: provider=$(repr(provider)) model_id=$(repr(model_id))")
    model.api != "openai-responses" && error("expected openai-responses model, got api=$(repr(model.api))")

    tools = build_tools()
    agent = build_agent(
        model,
        apikey;
        tools,
        prompt = "You are a math assistant. Always use the add tool for additions.",
    )

    kwargs = tool_choice_kwargs(model)
    isempty(kwargs) && error("tool choice not configured for api=$(repr(model.api))")

    response, events, _ = run_stream(
        agent,
        "Use the add tool to compute 2 + 3.";
        kwargs...,
    )

    assert_stream_response(response, events; expect_tool = true)
    sum = tool_call_sum(response.message.tool_calls[1])
    @test sum == 5
end
