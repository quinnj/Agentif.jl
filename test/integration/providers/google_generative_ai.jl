using Test, Agentif

@testset "Google Generative AI Stream" begin
    apikey = get(() -> nothing, ENV, "GOOGLE_GENERATIVE_AI_API_KEY")
    model_id = get(() -> nothing, ENV, "GOOGLE_GENERATIVE_AI_MODEL")
    provider = get(() -> "google", ENV, "GOOGLE_GENERATIVE_AI_PROVIDER")
    if apikey === nothing || model_id === nothing
        @info "Skipping Google Generative AI stream; set GOOGLE_GENERATIVE_AI_API_KEY and GOOGLE_GENERATIVE_AI_MODEL (optional GOOGLE_GENERATIVE_AI_PROVIDER)"
        return
    end

    model = Agentif.getModel(provider, model_id)
    model === nothing && error("unknown model: provider=$(repr(provider)) model_id=$(repr(model_id))")
    model.api != "google-generative-ai" && error("expected google-generative-ai model, got api=$(repr(model.api))")

    tools = build_tools()
    agent = build_agent(
        model,
        apikey;
        tools,
        prompt="You are a math assistant. Always use the add tool for additions.",
    )

    kwargs = tool_choice_kwargs(model)
    isempty(kwargs) && error("tool choice not configured for api=$(repr(model.api))")

    response, events, _ = run_stream(
        agent,
        "Use the add tool to compute 2 + 3.";
        kwargs...,
    )

    assert_stream_response(response, events; expect_tool=true)
    sum = tool_call_sum(response.message.tool_calls[1])
    @test sum == 5
end
