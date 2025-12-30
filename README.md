# Agentif.jl

Agentif.jl is a lightweight Julia framework for building autonomous AI agents powered by large language models (LLMs) with seamless tool integration and streaming support.

## Features
- **Multi-provider LLM support**: OpenAI (Responses &amp; Completions APIs), Anthropic, Google Generative AI, Google Gemini CLI
- **Streaming events**: Real-time updates for agent evaluation, messages, tool calls &amp; executions
- **Tool ecosystem**:
  - `@tool` macro to turn Julia functions into agent-callable tools
  - Predefined suites: `coding_tools()`, `read_only_tools()`, `all_tools()`
  - Includes file I/O (`read`, `write`, `edit`), shell (`bash`), filesystem (`ls`, `grep`, `find`)
- **Advanced capabilities**:
  - Input guardrails to prevent unsafe queries
  - Tool call caching for resumable sessions
  - Automatic tool approval or manual `approve!()` for safety
- **REPL-friendly**: `evaluate(agent, query)` with live streaming

## Installation
```julia
using Pkg
Pkg.add(&quot;Agentif&quot;)
```
Requires Julia ≥1.6.

## Quick Start
```julia
using Agentif

# Set API key in env (OPENAI_API_KEY, ANTHROPIC_API_KEY, etc.)
agent = Agent(
    model = getModel(&quot;openai&quot;, &quot;gpt-4o-mini&quot;),
    tools = coding_tools(),  # or read_only_tools()
    prompt = &quot;You are a helpful coding assistant.&quot;
)

# Interactive eval with streaming
evaluate(agent, &quot;Write a Julia function for fibonacci.&quot;)
```

For a full coding agent REPL (like this conversation):
```bash
julia examples/coding_agent.jl
```

## Defining Tools
```julia
@tool function add(a::Int, b::Int)
    return a + b
end

push!(agent.tools, AgentTool(add))
```

## Models &amp; Providers
```julia
getProviders()  # [:openai, :anthropic, ...]
getModels(&quot;openai&quot;)  # [&quot;gpt-4o&quot;, &quot;gpt-4o-mini&quot;, ...]
```

Full list &amp; config in docs.

## Events &amp; Streaming
```julia
evaluate(callback, agent, query, api_key) do event
    event isa MessageUpdateEvent &amp;&amp; print(event.delta)
    # Handle ToolCallRequestEvent, ToolExecutionStartEvent, etc.
end
```

## Examples
- `examples/coding_agent.jl`: Full-featured coding assistant REPL
- `client.jl` / `server.jl`: Standalone HTTP client/server

## Documentation
Build HTML docs:
```bash
julia --project=docs docs/make.jl
```
View in `docs/build`.

## Development
See [AGENTS.md](AGENTS.md) for build/test/performance guidelines.

[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE.md)