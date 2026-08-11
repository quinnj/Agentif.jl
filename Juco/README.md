# Juco

An uber-minimal pure-Julia coding agent built on `Agentif` + `LLMTools` + `LLMProviders`.

## Philosophy

Juco follows the [pi coding agent](https://github.com/badlogic/pi-mono)'s minimalism and
then goes one step further. Pi's default toolset is 4 tools (`read`, `bash`, `edit`,
`write`, with grep/find/ls as optional extras). Juco ships **3 coding tools + 1 memory
tool**:

| tool | what it does |
|------|--------------|
| `bash` | one-shot shell command, output tail-truncated (2000 lines / 50KB). Doubles as ls/grep/find via `ls`, `rg`, `find`. |
| `read` | file contents, head-truncated with `offset`/`limit` continuation (reused from LLMTools). |
| `edit` | exact-unique text replacement; an empty `oldText` **creates a new file**, subsuming `write`. |
| `remember` | append a durable memory. Recall is automatic — no recall tool. |

## Persistence: one SQLite file

Everything Juco persists lives in a single SQLite database (default
`~/.juco/juco.sqlite`):

- **Session history** — `Agentif.SQLiteSessionStore` (session_entries/session_branches
  + LocalSearch FTS), so sessions survive restarts and can be resumed.
- **Memories** — `juco_memories`, written by the `remember` tool and injected into the
  system prompt at the start of every session (most recent 50).
- **Session metadata** — `juco_sessions`, powering `--list`/`--continue`.

## Usage

```julia
using Juco
Juco.repl()                      # interactive session
Juco.evaluate("fix the bug")     # one programmatic turn
Juco.main(["-p", "explain this repo", "--preset", "pi"])  # CLI form
```

Configuration via environment: `JUCO_MODEL_PROVIDER` / `JUCO_MODEL` select the model
(defaults: `anthropic` / `claude-sonnet-4-5`); the API key comes from the provider's
conventional env var (`ANTHROPIC_API_KEY`, `XAI_API_KEY`, ...) or `JUCO_API_KEY`.
See `Juco.main(["-h"])` for all CLI flags.

## Eval

`eval/` contains a small harness that measures toolset minimalism against six
self-contained coding tasks (fix-bug, implement, hidden-bug, refactor-rename,
create-file, precise-edit), each with a programmatic pass/fail check:

```sh
julia --project=. Juco/eval/run.jl                    # all presets × all tasks
julia --project=. Juco/eval/run.jl --preset juco -v   # one preset, verbose
julia --project=. Juco/eval/run.jl --task fix-bug     # one task
```

Three presets are compared: `bash` (bash only, mini-swe-agent style), `juco`
(bash/read/edit + remember), and `pi` (bash/read/edit/write, pi's default set).
Each run reports pass/fail, tool calls, tokens, and wall time, in a fresh temp
directory and fresh temp db.

## Tests

```sh
julia --project=. Juco/test/runtests.jl
```

Unit tests cover the tools, db layer, presets, and prompt construction — no LLM
calls required.
