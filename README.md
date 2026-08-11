# Agentif Monorepo

This repository contains the core packages that power the `Agentif` Julia agent stack.

The intended workflow is monorepo-first:

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

After that, you can load any of the top-level packages directly from the repo root:

```julia
using Agentif, LLMTools, LLMProviders, Claw, LLMOAuth, Juco
```

## Packages

- `Agentif`: core agent runtime, message/state types, middleware, sessions, skills, and provider adapters.
- `LLMTools`: tool suites for file editing, shell/PTY sessions, worker execution, web fetch/search, and subagents.
- `LLMProviders`: model registry plus request/response types for the supported LLM providers.
- `Claw`: SQLite-backed event-driven assistant app built on top of `Agentif` and `LLMTools`.
- `LLMOAuth`: OAuth helpers for Codex/OpenAI and Anthropic flows.
- `Juco`: uber-minimal coding agent (bash/read/edit + memory, single-SQLite persistence); see `Juco/README.md`.

Each package has its own README:

- [`Agentif/README.md`](Agentif/README.md)
- [`LLMTools/README.md`](LLMTools/README.md)
- [`LLMProviders/README.md`](LLMProviders/README.md)
- [`Claw/README.md`](Claw/README.md)
- [`LLMOAuth/README.md`](LLMOAuth/README.md)
- [`Juco/README.md`](Juco/README.md)

## Quick Start

Build a basic agent with read-only tools:

```julia
using Agentif, LLMTools

agent = Agent(
    prompt = "You are a concise assistant.",
    model = getModel("openai", "gpt-4.1-mini"),
    apikey = ENV["OPENAI_API_KEY"],
    tools = LLMTools.read_only_tools(pwd()),
)

state = evaluate(agent, "List the files in the current directory.")
println(message_text(state.messages[end]))
```

## Examples

- `examples/coding_agent.jl`: interactive coding-agent REPL built on `Agentif` + `LLMTools`.
- `examples/provider_smoke_test.jl`: provider/model smoke test across the configured registry.
- `examples/terminal_tools/README.md`: standalone examples for PTY-backed terminal tools.
- `Claw/examples/`: live and smoke-style integration examples for Claw event sources.

## Testing

Run the full repo test suite from the root environment:

```bash
julia --project=. test/runtests.jl
```

Run a single package test entrypoint:

```bash
julia --project=. test/runtests.jl Agentif
```

## Notes

- The repo-root environment currently relies on Julia `1.11+` because the monorepo setup uses `Project.toml` `[sources]` entries.
- There is no separate `docs/` site right now; the READMEs are the source of truth.

[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE.md)
