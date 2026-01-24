using Test, Agentif

@testset "Agentif Integration" begin
    apikey = get(() -> nothing, ENV, "AGENTIF_API_KEY")
    provider = get(() -> nothing, ENV, "AGENTIF_PROVIDER")
    model_id = get(() -> nothing, ENV, "AGENTIF_MODEL")
    if apikey === nothing || provider === nothing || model_id === nothing
        @info "Skipping Agentif integration; set AGENTIF_API_KEY, AGENTIF_PROVIDER, and AGENTIF_MODEL"
        return
    end

    model = Agentif.getModel(provider, model_id)
    model === nothing && error("unknown model: provider=$(repr(provider)) model_id=$(repr(model_id))")

    @testset "stream" begin
        agent = build_agent(model, apikey; prompt = "You are a helpful assistant.")
        response, events, _ = run_stream(agent, "Say hello in one short sentence.")
        assert_stream_response(response, events)
    end

    @testset "evaluate!" begin
        agent = build_agent(model, apikey; prompt = "You are a helpful assistant.")
        result, events = run_evaluate!(agent, "Say hello in one short sentence.")
        assert_evaluate_result(result, events)
    end

    @testset "evaluate + tool" begin
        tools = build_tools()
        agent = build_agent(
            model,
            apikey;
            tools,
            prompt = "You are a math assistant. Always use the add tool for additions.",
        )

        kwargs = tool_choice_kwargs(model)
        if isempty(kwargs)
            @info "Skipping evaluate + tool integration; tool choice not configured for api=$(repr(model.api))"
            return
        end

        result, events = run_evaluate(
            agent,
            "Use the add tool to compute 2 + 3.";
            kwargs...,
        )

        assert_evaluate_result(result, events)
        @test isempty(result.pending_tool_calls)
        assert_tool_execution(events)
    end
end
