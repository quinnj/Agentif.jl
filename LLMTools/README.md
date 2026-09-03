# LLMTools

`LLMTools` provides the tool suites used by the higher-level agent packages in this repo.

Current tool areas include:

- file editing and search
- PTY-backed terminal sessions
- Julia worker execution
- web fetch and search
- Subagent helpers

The `ls`, `find`, and `grep` tools omit `.git` and honor applicable
`.gitignore` rules. Other dotfiles remain visible.

Semantic/code-search experiments are no longer exposed from `LLMTools`; that work moved to `LocalSearch.jl`.

## Repo-Root Workflow

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

Then:

```julia
using LLMTools
```

## Tool Suites

```julia
using LLMTools

read_only = LLMTools.read_only_tools(pwd())
coding = LLMTools.coding_tools(pwd())
everything = LLMTools.all_tools(pwd(); workers = true)
```

## Terminal Tools

The PTY-backed terminal tools are created with:

```julia
tools = LLMTools.create_terminal_tools(pwd())
```

See:

- `examples/terminal_tools/README.md`
- `examples/terminal_tools/run_all.jl`
- `examples/terminal_tools/quick_smoke_test.jl`

## Web Tools

```julia
using LLMTools

tools = LLMTools.web_tools()
```

These provide the `web_fetch` and `web_search` tool wrappers used in tests and agent setups.

## Tests

From the repo root:

```bash
julia --project=. test/runtests.jl LLMTools
```
