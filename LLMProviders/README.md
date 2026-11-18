# LLMProviders

`LLMProviders` is the model registry and provider-shaping layer used by `Agentif`.

It exposes:

- `Model`
- `getProviders()`
- `getModels(provider)`
- `getModel(provider, model_id)`
- `registerModel!(model)`
- `discover_models!(base_url; provider=...)`
- provider-specific request/response modules such as `OpenAIResponses` and `AnthropicMessages`

## Repo-Root Workflow

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

Then:

```julia
using LLMProviders
```

## Quick Start

```julia
using LLMProviders

providers = getProviders()
models = getModels("openai")
model = getModel("openai", "gpt-4.1-mini")
```

Register a custom model entry:

```julia
using LLMProviders

registerModel!(Model(
    id = "local-model",
    name = "Local Model",
    api = "openai-completions",
    provider = "local",
    baseUrl = "http://127.0.0.1:8000/v1",
    reasoning = false,
    input = ["text"],
    cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
    contextWindow = 8192,
    maxTokens = 1024,
))
```

### Model `compat` options

`Model.compat` is an optional `Dict{String, Any}` of per-model switches. Keys that are not listed here are ignored.

| Key | Used by | Meaning |
|---|---|---|
| `bedrockProxy` | `anthropic-messages` | `true` for an Anthropic model behind a gateway for AWS Bedrock. The request goes to `<baseUrl>/model/<id>/invoke-with-response-stream` (or `/invoke` when streaming is disabled), with the model id percent-encoded, `anthropic_version` in the body, and no `model` or `stream` field. |
| `anthropicVersion` | `anthropic-messages` with `bedrockProxy` | Value of `anthropic_version`; default `"bedrock-2023-05-31"`. |

## Tests

From the repo root:

```bash
julia --project=. test/runtests.jl LLMProviders
```
