# Agentif

`Agentif` is the core runtime for building LLM-powered Julia agents with middleware, tool calling, sessions, streaming events, skills, and provider adapters.

## Repo-Root Workflow

From the monorepo root:

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

Then load the package:

```julia
using Agentif
```

## Basic Usage

`Agentif` provides the runtime and agent types. Tool suites such as `coding_tools()` and `read_only_tools()` live in `LLMTools`.

```julia
using Agentif, LLMTools

agent = Agent(
    prompt = "You are a helpful assistant.",
    model = getModel("openai", "gpt-4.1-mini"),
    apikey = ENV["OPENAI_API_KEY"],
    tools = LLMTools.read_only_tools(pwd()),
)

state = evaluate(agent, "List the files in the current directory.")
println(message_text(state.messages[end]))
```

To stream events as they happen:

```julia
using Agentif

state = evaluate(agent, "Say hello.") do event
    if event isa MessageUpdateEvent && event.role == :assistant && event.kind == :text
        print(event.delta)
    end
end
```

## Main Concepts

- `Agent`: prompt, model, API key, and tool list.
- `AgentState`: accumulated messages, usage, pending tool calls, and response metadata.
- `evaluate` / `stream`: run a turn against the configured model.
- `build_default_handler`: compose middleware for tools, sessions, skills, channels, and compaction.
- `@tool` and `AgentTool`: wrap Julia functions as callable tools.

## Sessions and Crash Recovery

With a `session_store` and a `channel`, `evaluate` loads the channel's branch of the session tree and saves progress while it runs: a model turn that requests tools is saved before any of them starts, and each tool result is saved as soon as it is known. If the process dies mid-run:

- finished turns and tool results are in the history;
- a tool call that was running gets an error result saying it was interrupted and may or may not have taken effect, and it is never re-run automatically;
- a turn that ended in a provider error or an abort is not saved as an answer.

A refused turn (stop reason `:refusal`) adds nothing to the session, neither the input it refused nor the refusal, so later turns do not carry the refused request (a local choice). A refusal after a tool round keeps that round, which was saved before the refusal.

Pass `input_key` to make running the same input again safe. If the branch already holds an evaluation with that key, `evaluate` continues it from where it stopped instead of appending the input again, or returns without calling the model when it was already answered. The key stands for that input: a different input under a key the branch already holds is not run.

```julia
store = InMemorySessionStore()   # or SQLiteSessionStore(path)
state = evaluate(agent, "Triage issue #42"; session_store = store, channel, input_key = "issue-42")
```

## Related Packages

- `LLMTools` for ready-made tool suites.
- `LLMProviders` for model metadata and provider-specific request/response types.
- `LLMOAuth` for Codex/OpenAI and Anthropic OAuth helpers.

## Tests

From the repo root:

```bash
julia --project=. test/runtests.jl Agentif
```
