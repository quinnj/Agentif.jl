# Custom model registry entries that are not generated.

function _init_custom_models!()
    _model_registry["google-gemini-cli"] = Dict{String,Model}(
        "gemini-2.0-flash" => Model(
            id="gemini-2.0-flash",
            name="Gemini 2.0 Flash (Cloud Code Assist)",
            api="google-gemini-cli",
            provider="google-gemini-cli",
            baseUrl="https://cloudcode-pa.googleapis.com",
            reasoning=false,
            input=["text", "image"],
            cost=Dict("input"=>0.0, "output"=>0.0, "cacheRead"=>0.0, "cacheWrite"=>0.0),
            contextWindow=1048576,
            maxTokens=8192,
            headers=nothing
        ),
        "gemini-2.5-flash" => Model(
            id="gemini-2.5-flash",
            name="Gemini 2.5 Flash (Cloud Code Assist)",
            api="google-gemini-cli",
            provider="google-gemini-cli",
            baseUrl="https://cloudcode-pa.googleapis.com",
            reasoning=true,
            input=["text", "image"],
            cost=Dict("input"=>0.0, "output"=>0.0, "cacheRead"=>0.0, "cacheWrite"=>0.0),
            contextWindow=1048576,
            maxTokens=65535,
            headers=nothing
        ),
        "gemini-2.5-pro" => Model(
            id="gemini-2.5-pro",
            name="Gemini 2.5 Pro (Cloud Code Assist)",
            api="google-gemini-cli",
            provider="google-gemini-cli",
            baseUrl="https://cloudcode-pa.googleapis.com",
            reasoning=true,
            input=["text", "image"],
            cost=Dict("input"=>0.0, "output"=>0.0, "cacheRead"=>0.0, "cacheWrite"=>0.0),
            contextWindow=1048576,
            maxTokens=65535,
            headers=nothing
        ),
        "gemini-3-flash-preview" => Model(
            id="gemini-3-flash-preview",
            name="Gemini 3 Flash Preview (Cloud Code Assist)",
            api="google-gemini-cli",
            provider="google-gemini-cli",
            baseUrl="https://cloudcode-pa.googleapis.com",
            reasoning=true,
            input=["text", "image"],
            cost=Dict("input"=>0.0, "output"=>0.0, "cacheRead"=>0.0, "cacheWrite"=>0.0),
            contextWindow=1048576,
            maxTokens=65535,
            headers=nothing
        ),
        "gemini-3-pro-preview" => Model(
            id="gemini-3-pro-preview",
            name="Gemini 3 Pro Preview (Cloud Code Assist)",
            api="google-gemini-cli",
            provider="google-gemini-cli",
            baseUrl="https://cloudcode-pa.googleapis.com",
            reasoning=true,
            input=["text", "image"],
            cost=Dict("input"=>0.0, "output"=>0.0, "cacheRead"=>0.0, "cacheWrite"=>0.0),
            contextWindow=1048576,
            maxTokens=65535,
            headers=nothing
        ),
    )
end

_init_custom_models!()
