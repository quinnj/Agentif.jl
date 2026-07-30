# Model registry generator

`LLMProviders/src/models_generated.jl` is **generated**. Do not hand-edit it —
edits are lost on the next refresh. Hand-maintained entries belong in
`LLMProviders/src/models_custom.jl`, which is layered on top (see below).

## Source of truth

Upstream is [pi-mono](https://github.com/badlogic/pi-mono)'s
`packages/ai/src/models.generated.ts` (package `@mariozechner/pi-ai`), which is
itself machine-generated from provider catalogs. Because it is generated, its
shape is a strictly regular nesting of literal objects, which is what makes a
plain textual parser safe here.

## Refreshing

```bash
# 1. update the upstream checkout
git -C ~/pi-mono pull

# 2. regenerate (no deps, no TS toolchain, no Pkg env needed)
julia LLMProviders/gen/generate_models.jl

# 3. verify
julia --project=. test/runtests.jl LLMProviders

# 4. review the diff -- expect only model add/remove/price churn
git diff --stat LLMProviders/src/models_generated.jl
```

Source resolution order:

1. positional arg 1, e.g.
   `julia LLMProviders/gen/generate_models.jl /path/to/models.generated.ts`
2. `$PI_MONO_MODELS_TS`
3. `$PI_MONO/packages/ai/src/models.generated.ts`
4. `~/pi-mono/packages/ai/src/models.generated.ts`

Positional arg 2 overrides the output path (default
`LLMProviders/src/models_generated.jl`).

The generated header records the source path (with `$HOME` collapsed to `~`),
the upstream revision from `git -C <pi-mono> describe --always --dirty`, and the
generation date, so a stale registry is visible at a glance.

## Design notes

- **Base-only, no TypeScript toolchain.** The parser is line-oriented and keys
  off upstream's exact tab indentation (1 tab = provider, 2 = model id, 3 =
  model field, 4 = nested `cost` field). Single-line values (`input`, `compat`,
  `headers`, all scalars) go through a small JSON/JS literal parser that keeps
  object key order.
- **Fail loud.** Any line that does not match the expected shape raises. Upstream
  restructuring shows up as a generator error rather than a silently truncated
  registry.
- **Deterministic.** Providers and model ids are sorted by codepoint; the only
  non-source-derived content is the header metadata. Re-running on an unchanged
  source produces a byte-identical file.
- **Numbers are copied verbatim as source tokens.** Upstream prices carry
  binary-float dust (e.g. `0.19999999999999998`, `0.7999999999999999`). Reparsing
  and re-printing them, or rounding, would silently diverge from pi-ai's
  published numbers, so the raw token is emitted. This matches what the previous
  hand-run refresh did.
- **Shape-stable entries.** `headers` and `compat` are always emitted, as
  `nothing` when upstream omits them. `kw` is never emitted and falls back to the
  `Model` struct default.
- **Formatting matches the checked-in style**, including the `return` on the last
  provider assignment, so a JuliaFormatter pass is a no-op.

## Known upstream data quirks (carried through unchanged)

- `openrouter/auto` has `cost.input = cost.output = -1000000` — a sentinel for
  "priced dynamically per upstream model", not a real negative price. The
  registry testset asserts this explicitly instead of pretending it is `0`.
- All 38 `azure-openai-responses` models have `baseUrl: ""`; the Azure endpoint
  is per-deployment and supplied at call time.

## Interaction with `models_custom.jl`

`models.jl` includes `models_generated.jl` first, then `models_custom.jl`.
`_init_model_registry!()` *replaces* each provider dict wholesale; the custom
file then `merge!`s its entries in, so **custom wins on id collisions**. In
particular:

- `openai-codex`: upstream now publishes API prices for `gpt-5.1`, `gpt-5.2`,
  `gpt-5.3-codex`, `gpt-5.4` etc. The custom file overwrites them with `$0`
  because that transport is ChatGPT-subscription-billed, and adds ids upstream
  does not carry (`gpt-5-codex`, `gpt-5.1-codex`, and the `gpt-codex-5.3` alias).
  If you ever want upstream pricing to win, that decision belongs in
  `models_custom.jl`, not here.
- `google-gemini-cli`: upstream has converged on the same Cloud Code Assist
  endpoint and `$0` costs, so the custom entries are now value-identical
  overrides.
- `minimax`: upstream now ships a real `minimax` provider, so the custom
  bootstrap branch guarded by `!haskey(_model_registry, "minimax")` is dead code.
  The remaining block still adds an OpenAI-compatible entry keyed by the
  OpenRouter id `minimax/minimax-m2.1` whose `id` field is `MiniMax-M2.1` — a
  pre-existing key/id mismatch, asserted in the testset so a refresh cannot
  change it unnoticed.
