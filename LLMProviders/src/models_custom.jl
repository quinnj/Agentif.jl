# Custom model registry entries that are not generated.

function _init_custom_models!()
    google_gemini_cli_models = Dict{String, Model}(
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
    merge!(get!(() -> Dict{String, Model}(), _model_registry, "google-gemini-cli"), google_gemini_cli_models)

    # Frontier Anthropic models that the upstream generated registry does not carry
    # yet (it tops out at the 4.6 generation). Prices, context windows and max
    # output are from Anthropic's model overview docs, retrieved 2026-07-30:
    # https://platform.claude.com/docs/en/docs/about-claude/models/overview
    # Cache prices follow Anthropic's published multipliers (read 0.1x input,
    # write 1.25x input), which the upstream 4.6 entries also use.
    # NOTE: these models do NOT support extended thinking
    # (`thinking.type = "enabled"`); they use adaptive thinking with an `effort`
    # parameter. `reasoning = true` here means "reasons", not "accepts a
    # thinking budget".
    function anthropic_model(
            model_id::String,
            name::String,
            input_cost::Float64,
            output_cost::Float64;
            context_window::Int = 1000000,
            max_tokens::Int = 128000,
        )
        return Model(
            id = model_id,
            name = name,
            api = "anthropic-messages",
            provider = "anthropic",
            baseUrl = "https://api.anthropic.com",
            reasoning = true,
            input = ["text", "image"],
            cost = Dict(
                "input" => input_cost,
                "output" => output_cost,
                # round: 3.0 * 0.1 is 0.30000000000000004 in binary floating point,
                # and these are our own derived values, not upstream's verbatim ones
                "cacheRead" => round(input_cost * 0.1; digits = 6),
                "cacheWrite" => round(input_cost * 1.25; digits = 6),
            ),
            contextWindow = context_window,
            maxTokens = max_tokens,
            headers = nothing,
        )
    end

    anthropic_models = Dict{String, Model}(
        "claude-fable-5" => anthropic_model("claude-fable-5", "Claude Fable 5", 10.0, 50.0),
        "claude-opus-5" => anthropic_model("claude-opus-5", "Claude Opus 5", 5.0, 25.0),
        # Standard pricing; an introductory $2/$10 rate applies through 2026-08-31.
        "claude-sonnet-5" => anthropic_model("claude-sonnet-5", "Claude Sonnet 5", 3.0, 15.0),
        "claude-opus-4-8" => anthropic_model("claude-opus-4-8", "Claude Opus 4.8", 5.0, 25.0),
        "claude-opus-4-7" => anthropic_model("claude-opus-4-7", "Claude Opus 4.7", 5.0, 25.0),
    )
    # Generated entries win where they already exist; only fill the gaps.
    anthropic_registry = get!(() -> Dict{String, Model}(), _model_registry, "anthropic")
    for (k, v) in anthropic_models
        haskey(anthropic_registry, k) || (anthropic_registry[k] = v)
    end

    # OpenAI Codex models (via ChatGPT OAuth)
    function codex_model(
            model_id::String,
            name::String;
            context_window::Int = 272000,
            max_tokens::Int = 128000,
        )
        return Model(
            id = model_id,
            name = name,
            api = "openai-codex-responses",
            provider = "openai-codex",
            baseUrl = "https://chatgpt.com/backend-api",
            reasoning = true,
            input = ["text", "image"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = context_window,
            maxTokens = max_tokens,
            headers = nothing,
        )
    end
    openai_codex_models = Dict{String, Model}(
        "gpt-5-codex" => codex_model("gpt-5-codex", "GPT-5 Codex"),
        "gpt-5.1" => codex_model("gpt-5.1", "GPT-5.1"),
        "gpt-5.1-codex" => codex_model("gpt-5.1-codex", "GPT-5.1 Codex"),
        "gpt-5.1-codex-max" => codex_model("gpt-5.1-codex-max", "GPT-5.1 Codex Max"),
        "gpt-5.1-codex-mini" => codex_model("gpt-5.1-codex-mini", "GPT-5.1 Codex Mini"),
        "gpt-5.2" => codex_model("gpt-5.2", "GPT-5.2"),
        "gpt-5.2-codex" => codex_model("gpt-5.2-codex", "GPT-5.2 Codex"),
        "gpt-5.3-codex" => codex_model("gpt-5.3-codex", "GPT-5.3 Codex"; context_window = 400000),
        "gpt-5.3-codex-spark" => codex_model(
            "gpt-5.3-codex-spark",
            "GPT-5.3 Codex Spark";
            context_window = 128000,
            max_tokens = 32000,
        ),
        "gpt-5.4" => codex_model("gpt-5.4", "GPT-5.4"),
        # Friendly aliases: keep lookup compatibility while using canonical API ids.
        "gpt-codex-5.3" => codex_model("gpt-5.3-codex", "GPT Codex 5.3"; context_window = 400000),
    )
    merge!(get!(() -> Dict{String, Model}(), _model_registry, "openai-codex"), openai_codex_models)

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
