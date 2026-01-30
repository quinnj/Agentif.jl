# Custom model registry entries that are not generated.

function _init_custom_models!()
    _model_registry["google-gemini-cli"] = Dict{String, Model}(
        "gemini-2.0-flash" => Model(
            id = "gemini-2.0-flash",
            name = "Gemini 2.0 Flash (Cloud Code Assist)",
            api = "google-gemini-cli",
            provider = "google-gemini-cli",
            baseUrl = "https://cloudcode-pa.googleapis.com",
            reasoning = false,
            input = ["text", "image"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 1048576,
            maxTokens = 8192,
            headers = nothing
        ),
        "gemini-2.5-flash" => Model(
            id = "gemini-2.5-flash",
            name = "Gemini 2.5 Flash (Cloud Code Assist)",
            api = "google-gemini-cli",
            provider = "google-gemini-cli",
            baseUrl = "https://cloudcode-pa.googleapis.com",
            reasoning = true,
            input = ["text", "image"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 1048576,
            maxTokens = 65535,
            headers = nothing
        ),
        "gemini-2.5-pro" => Model(
            id = "gemini-2.5-pro",
            name = "Gemini 2.5 Pro (Cloud Code Assist)",
            api = "google-gemini-cli",
            provider = "google-gemini-cli",
            baseUrl = "https://cloudcode-pa.googleapis.com",
            reasoning = true,
            input = ["text", "image"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 1048576,
            maxTokens = 65535,
            headers = nothing
        ),
        "gemini-3-flash-preview" => Model(
            id = "gemini-3-flash-preview",
            name = "Gemini 3 Flash Preview (Cloud Code Assist)",
            api = "google-gemini-cli",
            provider = "google-gemini-cli",
            baseUrl = "https://cloudcode-pa.googleapis.com",
            reasoning = true,
            input = ["text", "image"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 1048576,
            maxTokens = 65535,
            headers = nothing
        ),
        "gemini-3-pro-preview" => Model(
            id = "gemini-3-pro-preview",
            name = "Gemini 3 Pro Preview (Cloud Code Assist)",
            api = "google-gemini-cli",
            provider = "google-gemini-cli",
            baseUrl = "https://cloudcode-pa.googleapis.com",
            reasoning = true,
            input = ["text", "image"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 1048576,
            maxTokens = 65535,
            headers = nothing
        ),
    )

    # OpenAI Codex models (via ChatGPT OAuth)
    _model_registry["openai-codex"] = Dict{String, Model}(
        "gpt-5.1" => Model(
            id = "gpt-5.1",
            name = "GPT-5.1",
            api = "openai-codex-responses",
            provider = "openai-codex",
            baseUrl = "https://chatgpt.com/backend-api",
            reasoning = true,
            input = ["text", "image"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 272000,
            maxTokens = 128000,
            headers = nothing
        ),
        "gpt-5.1-codex-max" => Model(
            id = "gpt-5.1-codex-max",
            name = "GPT-5.1 Codex Max",
            api = "openai-codex-responses",
            provider = "openai-codex",
            baseUrl = "https://chatgpt.com/backend-api",
            reasoning = true,
            input = ["text", "image"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 272000,
            maxTokens = 128000,
            headers = nothing
        ),
        "gpt-5.1-codex-mini" => Model(
            id = "gpt-5.1-codex-mini",
            name = "GPT-5.1 Codex Mini",
            api = "openai-codex-responses",
            provider = "openai-codex",
            baseUrl = "https://chatgpt.com/backend-api",
            reasoning = true,
            input = ["text", "image"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 272000,
            maxTokens = 128000,
            headers = nothing
        ),
        "gpt-5.2" => Model(
            id = "gpt-5.2",
            name = "GPT-5.2",
            api = "openai-codex-responses",
            provider = "openai-codex",
            baseUrl = "https://chatgpt.com/backend-api",
            reasoning = true,
            input = ["text", "image"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 272000,
            maxTokens = 128000,
            headers = nothing
        ),
        "gpt-5.2-codex" => Model(
            id = "gpt-5.2-codex",
            name = "GPT-5.2 Codex",
            api = "openai-codex-responses",
            provider = "openai-codex",
            baseUrl = "https://chatgpt.com/backend-api",
            reasoning = true,
            input = ["text", "image"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 272000,
            maxTokens = 128000,
            headers = nothing
        ),
    )

    if !haskey(_model_registry, "minimax")
        openrouter_models = get(() -> nothing, _model_registry, "openrouter")
        if openrouter_models !== nothing
            minimax = Dict{String, Model}()
            m21 = get(() -> nothing, openrouter_models, "minimax/minimax-m2.1")
            m21 !== nothing && (minimax["minimax/minimax-m2.1"] = m21)
            m21l = get(() -> nothing, openrouter_models, "minimax/minimax-m2.1-lightning")
            m21l !== nothing && (minimax["minimax/minimax-m2.1-lightning"] = m21l)
            !isempty(minimax) && (_model_registry["minimax"] = minimax)
        end
    end

    # Add direct MiniMax OpenAI-compatible entries under the minimax provider.
    minimax_models = get(() -> nothing, _model_registry, "minimax")
    openrouter_models = get(() -> nothing, _model_registry, "openrouter")
    return if minimax_models !== nothing && openrouter_models !== nothing
        function minimax_openai_model(openrouter_id::String, minimax_id::String)
            base = get(() -> nothing, openrouter_models, openrouter_id)
            base === nothing && return nothing
            return Model(
                id = minimax_id,
                name = base.name,
                api = "openai-completions",
                provider = "minimax",
                baseUrl = "https://api.minimax.io/v1",
                reasoning = base.reasoning,
                input = base.input,
                cost = base.cost,
                contextWindow = base.contextWindow,
                maxTokens = base.maxTokens,
                headers = base.headers,
                kw = base.kw,
            )
        end
        if !haskey(minimax_models, "minimax/minimax-m2.1")
            m21_direct = minimax_openai_model("minimax/minimax-m2.1", "MiniMax-M2.1")
            m21_direct !== nothing && (minimax_models["minimax/minimax-m2.1"] = m21_direct)
        end
        if !haskey(minimax_models, "minimax/minimax-m2.1-lightning")
            m21l_direct = minimax_openai_model("minimax/minimax-m2.1-lightning", "MiniMax-M2.1-lightning")
            m21l_direct !== nothing && (minimax_models["minimax/minimax-m2.1-lightning"] = m21l_direct)
        end
    end
end

_init_custom_models!()
