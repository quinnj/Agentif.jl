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
    cost = Dict{String, Float64}(
        "input" => (model.cost["input"] / 1000000) * usage.input,
        "output" => (model.cost["output"] / 1000000) * usage.output,
        "cacheRead" => (model.cost["cacheRead"] / 1000000) * usage.cacheRead,
        "cacheWrite" => (model.cost["cacheWrite"] / 1000000) * usage.cacheWrite,
    )
    cost["total"] = cost["input"] + cost["output"] + cost["cacheRead"] + cost["cacheWrite"]
    usage.cost = cost
    return cost
end

# Load generated models
include("models_generated.jl")
include("models_custom.jl")
