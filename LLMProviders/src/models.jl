# Model definitions and registry
# Ported from TypeScript models.ts and models.generated.ts

# Model type definition
@kwarg struct Model
    id::String
    name::String
    api::String  # "openai-responses", "openai-completions", "anthropic-messages", "google-generative-ai"
    provider::String
    baseUrl::String
    reasoning::Bool
    input::Vector{String}  # ["text"], ["text", "image"], etc.
    cost::Dict{String, Float64}  # input, output, cacheRead, cacheWrite (per million tokens)
    contextWindow::Int
    maxTokens::Int
    headers::Union{Nothing, Dict{String, String}} = nothing
    compat::Union{Nothing, Dict{String, Any}} = nothing
    kw::Any = (;) # additional keyword arguments that will be passed when api calls are made
end

with(model::Model; kw...) =
    Model(;
    id = model.id,
    name = model.name,
    api = model.api,
    provider = model.provider,
    baseUrl = model.baseUrl,
    reasoning = model.reasoning,
    input = model.input,
    cost = model.cost,
    contextWindow = model.contextWindow,
    maxTokens = model.maxTokens,
    headers = model.headers,
    compat = model.compat,
    kw = kw
)

# Model registry - will be populated from models_generated.jl
const _model_registry = Dict{String, Dict{String, Model}}()

"""
    registerModel!(model::Model) -> Model

Register a model in the registry under its `provider` and `id`.
Overwrites any existing entry with the same provider/id.
"""
function registerModel!(model::Model)
    models = get!(() -> Dict{String, Model}(), _model_registry, model.provider)
    models[model.id] = model
    return model
end

"""
    getModel(provider::String, modelId::String) -> Union{Nothing,Model}

Get a model by provider and model ID.
"""
function getModel(provider::String, modelId::String)
    providerModels = get(() -> nothing, _model_registry, provider)
    providerModels === nothing && return nothing
    return get(() -> nothing, providerModels, modelId)
end

"""
    getProviders() -> Vector{String}

Get all available provider names.
"""
function getProviders()
    return collect(keys(_model_registry))
end

"""
    getModels(provider::String) -> Vector{Model}

Get all models for a given provider.
"""
function getModels(provider::String)
    providerModels = get(() -> Dict{String, Model}(), _model_registry, provider)
    return collect(values(providerModels))
end

"""
    calculateCost(model::Model, usage::Usage) -> Dict{String,Float64}

Calculate cost based on model pricing and usage.
Returns the cost dictionary with input, output, cacheRead, cacheWrite, and total.
"""
function calculateCost(model::Model, usage)
    input_rate = get(() -> 0.0, model.cost, "input")
    output_rate = get(() -> 0.0, model.cost, "output")
    cache_read_rate = get(() -> 0.0, model.cost, "cacheRead")
    cache_write_rate = get(() -> 0.0, model.cost, "cacheWrite")
    cost = Dict{String, Float64}(
        "input" => (input_rate / 1000000) * usage.input,
        "output" => (output_rate / 1000000) * usage.output,
        "cacheRead" => (cache_read_rate / 1000000) * usage.cacheRead,
        "cacheWrite" => (cache_write_rate / 1000000) * usage.cacheWrite,
    )
    cost["total"] = cost["input"] + cost["output"] + cost["cacheRead"] + cost["cacheWrite"]
    usage.cost = cost
    return cost
end

const _LOCAL_COMPAT = Dict{String, Any}(
    "supportsStore" => false,
    "supportsDeveloperRole" => false,
    "supportsReasoningEffort" => false,
    "stripThinkTags" => true,
    "maxTokensField" => "max_tokens",
)

"""
    discover_models!(base_url::String; provider::String="local") -> Vector{Model}

Query a local OpenAI-compatible server at `base_url` (e.g. "http://localhost:8000")
and register all discovered models. Supports vLLM, Ollama, llama.cpp, LM Studio, etc.
"""
function discover_models!(base_url::String; provider::String="local")
    url = rstrip(base_url, '/') * "/v1/models"
    resp = HTTP.get(url; status_exception=false)
    resp.status == 200 || error("Failed to query $url: HTTP $(resp.status)")
    data = try
        JSON.parse(resp.body)
    catch e
        error("Invalid JSON from $url: $(sprint(showerror, e))")
    end
    entries = get(() -> nothing, data, "data")
    entries isa AbstractVector || error("Invalid /v1/models payload from $url: expected `data` array")
    models = Model[]
    api_base = rstrip(base_url, '/') * "/v1"
    for (idx, entry) in enumerate(entries)
        entry isa AbstractDict || continue
        id = get(() -> nothing, entry, "id")
        if !(id isa AbstractString) || isempty(strip(id))
            @warn "Skipping discovered model without valid id" index = idx provider
            continue
        end
        model = Model(
            id = String(id),
            name = String(id),
            api = "openai-completions",
            provider = provider,
            baseUrl = api_base,
            reasoning = false,
            input = ["text"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 131072,
            maxTokens = 8192,
            compat = _LOCAL_COMPAT,
        )
        registerModel!(model)
        push!(models, model)
    end
    return models
end

# Load generated models
include("models_generated.jl")
include("models_custom.jl")
