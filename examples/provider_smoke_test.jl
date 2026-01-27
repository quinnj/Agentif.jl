using Agentif

const PROMPTS = [
    "Say hello in one sentence.",
    "Use the `ls` tool to list files in the current directory, then summarize the filenames in one sentence.",
]

const PROVIDER_ENV_MAP = Dict(
    "anthropic" => ["ANTHROPIC_API_KEY"],
    "openai" => ["OPENAI_API_KEY", "OPENAI_RESPONSES_API_KEY", "OPENAI_COMPLETIONS_API_KEY"],
    "xai" => ["XAI_API_KEY", "OPENAI_COMPAT_API_KEY"],
    "openrouter" => ["OPENROUTER_API_KEY"],
    "google-generative-ai" => ["GOOGLE_API_KEY", "GEMINI_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY"],
    "google-gemini-cli" => ["GOOGLE_GEMINI_CLI_OAUTH", "GEMINI_CLI_OAUTH", "GOOGLE_GEMINI_CLI_TOKEN"],
    "google" => ["GOOGLE_API_KEY", "GEMINI_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY"],
    "minimax" => ["MINIMAX_API_KEY"],
)

const MODEL_PREFERENCES = [
    "nano", "mini", "small", "haiku", "flash", "lite", "tiny",
]

function env_value(keys::Vector{String})
    for key in keys
        value = get(ENV, key, "")
        isempty(value) || return (key = key, value = value)
    end
    return nothing
end

function select_model(models::Vector{Model})
    isempty(models) && return nothing
    by_id = sort(models; by = x -> lowercase(x.id))
    for pref in MODEL_PREFERENCES
        match = findfirst(m -> occursin(pref, lowercase(m.id)), by_id)
        match === nothing || return by_id[match]
    end
    return by_id[1]
end

function api_key_for_model(model::Model)
    keys = get(() -> String[], PROVIDER_ENV_MAP, model.provider)
    return env_value(keys)
end

function safe_error_message(err)
    msg = err isa Exception ? sprint(showerror, err) : string(err)
    msg = replace(msg, r"sk-[A-Za-z0-9_-]+" => "<redacted>")
    return replace(msg, r"xai-[A-Za-z0-9_-]+" => "<redacted>")
end

function request_kwargs(model::Model)
    if model.api == "openai-responses"
        return (; max_output_tokens = 200)
    elseif model.api == "openai-completions" || model.api == "anthropic-messages"
        return (; max_tokens = 200)
    elseif model.api == "google-gemini-cli"
        return (; maxTokens = 200)
    end
    return (;)
end

function run_prompt(agent::Agent, prompt::String; kw)
    result = evaluate(agent, prompt; kw...)
    idx = findlast(msg -> msg isa AssistantMessage, result.state.messages)
    idx === nothing && return ""
    return message_text(result.state.messages[idx])
end

function run_provider(provider::String)
    models = getModels(provider)
    isempty(models) && return [(status = "no-models", provider = provider, model = nothing, detail = nothing)]
    by_api = Dict{String, Vector{Model}}()
    for model in models
        push!(get!(() -> Model[], by_api, model.api), model)
    end

    results = []
    for (api_name, api_models) in sort(collect(by_api); by = x -> x[1])
        model = select_model(api_models)
        model === nothing && push!(results, (status = "no-models", provider = provider, model = nothing, detail = api_name))
        model === nothing && continue
        api = api_key_for_model(model)
        if api === nothing
            push!(results, (status = "no-credentials", provider = provider, model = model.id, detail = api_name))
            continue
        end

        agent = Agent(
            model = model,
            apikey = api.value,
            tools = read_only_tools(),
            prompt = "You are a concise assistant.",
            stream_output = false,
        )

        kw = request_kwargs(model)
        local ok = true
        for prompt in PROMPTS
            try
                run_prompt(agent, prompt; kw = kw)
            catch err
                push!(results, (status = "failed", provider = provider, model = model.id, detail = safe_error_message(err)))
                ok = false
                break
            end
        end

        ok && push!(results, (status = "ok", provider = provider, model = model.id, detail = api.key))
    end

    return results
end

function main()
    providers = sort(getProviders())
    results = []
    for provider in providers
        append!(results, run_provider(provider))
    end

    println("\nProvider smoke test summary:")
    for result in results
        if result.status == "ok"
            println("  ✓ $(result.provider) $(result.model) (via $(result.detail))")
        elseif result.status == "no-credentials"
            println("  - $(result.provider) $(result.model): missing credentials")
        elseif result.status == "no-models"
            label = result.model === nothing ? result.provider : "$(result.provider) $(result.model)"
            println("  - $(label): no models")
        else
            println("  ✗ $(result.provider) $(result.model): $(result.detail)")
        end
    end
    return
end

main()
