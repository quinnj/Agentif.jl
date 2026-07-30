# Inter-package API cleanup — findings and proposed direction

Scratch notes for the "clean up inter-package contracts/APIs" workstream. Nothing here
is implemented yet; the round-1 PR fixed only the one item that was an outright bug
(`calculateCost` mutating a field its natural argument doesn't have).

The package split is `LLMProviders` = wire types + model registry, `Agentif` = transport
+ agent semantics, `LLMTools` = tool implementations, `Claw` = the always-on app. The
idea is sound; these are the places the seam leaks.

## 1. The typed request models are bypassed in the hot path

`OpenAIResponses.Request` is the most elaborate typed request model in the stack, and
both the openai-responses and codex branches build **raw `Dict` bodies** instead,
because opaque reasoning items can't round-trip through the typed structs. So the types
are effectively test-only for the busiest provider.

Pick one and commit to it:
- give `Request.input` an escape hatch for raw pass-through items, so the typed path
  can actually be used; or
- accept Dict-building as the norm for request *construction* and slim the request
  types down to what is genuinely used (they'd still earn their keep for responses).

Half-and-half is the current state and it is the worst of both.

## 2. `model.kw...` splatting makes registry entries version-fragile

`stream()` splats `model.kw` into `@kwarg` constructors, so an unknown key is a hard
`MethodError` rather than an ignorable extra. This is exactly why Anthropic thinking
could not be enabled without changing the Request struct, and it means a registry entry
carrying a newer provider option breaks the older code that reads it. Consider an
explicit `extra::Dict{String,Any}` passthrough on request types (serialized flat), so
forward-compatible options don't require a type change.

## 3. Two sources of truth for provider compat

Compatibility is split between `Model.compat` dicts in the registry and hard-coded URL
substring sniffing in `openai_completions_detect_compat`. New backends have to be taught
in two places, and the sniffing silently wins/loses depending on call order. Collapse to
one: registry-declared compat, with detection as a fallback that only fills gaps.

## 4. Layering violations in `LLMProviders`

`GoogleGeminiCli` carries transport concerns (spoofed client headers, `build_request`,
credential parsing) while its sibling modules are pure types, and `discover_models!`
performs HTTP inside what is supposed to be the types package. Either rename the
package's remit or move those into `Agentif`.

## 5. Duplication that will drift

- `google_generative_adapter.jl` and `google_gemini_cli_adapter.jl` are ~250 lines each
  and differ mainly by module prefix.
- `_split_compound_id` and the Responses input-building logic exist in both the
  responses adapter and the codex provider.
- Each provider branch in `stream()` hand-rolls its own started/ended/finalize/error
  handling; the round-1 SSE retry work already had to touch all five identically, and
  the Google branches were missing error handling *because* it was copy-paste rather
  than shared.

A shared "stream driver" owning the started/ended/finalize/error-mapping lifecycle
would collapse a few hundred lines of divergent boilerplate and is the single highest-
leverage structural change available. It is also the natural home for a default
`readtimeout` (currently only codex sets one).

## 6. Small contract inconsistencies worth settling

- `Usage.total` means different things per provider (Anthropic includes cacheWrite;
  completions folds reasoning tokens into output; Google has no cache fields at all),
  yet they all accumulate into one `AgentState.usage`.
- `close_channel` is documented as "final cleanup" but runs once per LLM turn, because
  `tool_call_middleware` wraps `channel_middleware`. Either hoist channel setup/teardown
  above the tool loop or rename the hook to match reality.
- `CURRENT_CHANNEL` is a `ScopedValue` that tools never see, because tools execute on
  spawned tasks outside the binding scope. Anything security-relevant must be passed by
  closure — worth deleting the scoped value rather than leaving a trap.
- The `@tool` macro silently ignores `;`-style keyword arguments, producing a schema
  missing them and a positional call that can't supply them. Should be an error.

## Suggested sequencing

The stream driver (item 5) first, since it subsumes the readtimeout gap and makes the
per-provider error contract uniform; then the request-type decision (items 1–2), which
is what unblocks forward-compatible provider options; then the smaller contract items,
which are mostly one-liners once the first two settle.
