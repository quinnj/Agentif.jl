# Claw

`Claw` is the event-driven assistant app layer built on top of `Agentif` and `LLMTools`.

It combines:

- SQLite-backed assistant/session state
- built-in management, scheduling, and storage tools
- event sources and handlers
- optional channel/platform extensions

## Repo-Root Workflow

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

Then:

```julia
using Claw
```

## Quick Start

Initialize an assistant with the built-in `LLMToolsEventSource`:

```julia
using Claw

assistant = Claw.init!("claw.sqlite";
    provider = "openai",
    model_id = "gpt-4.1-mini",
    apikey = ENV["OPENAI_API_KEY"],
)
```

`Claw.init!` returns an `AgentAssistant` and starts the event loop immediately. `Claw.run` is a convenience wrapper around `init!` with the same keyword arguments:

```julia
assistant = Claw.run(;
    db_path = "claw.sqlite",
    provider = "openai",
    model_id = "gpt-4.1-mini",
    apikey = ENV["OPENAI_API_KEY"],
)
```

Unless you explicitly provide your own `LLMToolsEventSource`, `Claw.init!` adds one automatically so the assistant has the built-in management, scheduling, storage, and tool-execution surface.

## REPL Usage

In an interactive Julia session, `Claw` registers a `ReplEventSource` automatically. For explicit examples and scripts, it is clearer to pass it yourself:

```julia
using Claw

assistant = Claw.init!("claw-repl.sqlite";
    provider = "openai",
    model_id = "gpt-4.1-mini",
    apikey = ENV["OPENAI_API_KEY"],
    event_sources = Claw.EventSource[Claw.ReplEventSource()],
)
```

The easiest REPL entrypoint is the `a"..."` macro:

```julia
a"Say hello and explain what tools you have available."
```

If you want the lower-level channel/event form, submit the event yourself with
`ReplChannel` and `ReplInputEvent`:

```julia
ch = Claw.ReplChannel()
Claw.submit_event!(assistant, Claw.ReplInputEvent(
    "Summarize the last reply in one sentence.",
    ch,
))
wait(ch.completion)
```

That sends input through the assistant's event loop and streams output back to `stdout` via the `ReplChannel`.

`submit_event!` persists the event to the `claw_events` inbox first and only then
wakes the dispatcher, so events survive a crash. Never `put!` onto
`assistant.event_queue` directly: it carries persisted rowids as wakeups, not events.
Pass `dedup_key` when the upstream platform supplies a delivery id — redelivery of a
key that is already in the table is then a no-op.

## Slack Event Source

Load the optional Slack extension by importing `Slack`, then construct a `SlackEventSource`:

```julia
using Claw
using Slack

const ClawSlackExt = Base.get_extension(Claw, :ClawSlackExt)

source = ClawSlackExt.SlackEventSource()

assistant = Claw.run(;
    db_path = "claw-slack.sqlite",
    name = "Claw",
    provider = ENV["CLAW_AGENT_PROVIDER"],
    model_id = ENV["CLAW_AGENT_MODEL"],
    apikey = ENV["CLAW_AGENT_API_KEY"],
    event_sources = Claw.EventSource[source],
)
```

Required environment variables:

- `CLAW_AGENT_PROVIDER`
- `CLAW_AGENT_MODEL`
- `CLAW_AGENT_API_KEY`
- `SLACK_APP_TOKEN`
- `SLACK_BOT_TOKEN`

Optional Slack-specific environment variables:

- `SLACK_BOT_USER_ID`
- `SLACK_BOT_USERNAME`
- `SLACK_STREAM_RECIPIENT_TEAM_ID`
- `SLACK_STREAM_RECIPIENT_USER_ID`

The Slack source listens in Socket Mode, registers visible channels once connected, and emits message/reaction events into Claw's event loop.

## Mattermost Event Source

Load the Mattermost extension by importing `Mattermost`, then construct a `MattermostEventSource`:

```julia
using Claw
using Mattermost

const ClawMattermostExt = Base.get_extension(Claw, :ClawMattermostExt)

source = ClawMattermostExt.MattermostEventSource()

assistant = Claw.run(;
    db_path = "claw-mattermost.sqlite",
    name = "Claw",
    provider = ENV["CLAW_AGENT_PROVIDER"],
    model_id = ENV["CLAW_AGENT_MODEL"],
    apikey = ENV["CLAW_AGENT_API_KEY"],
    event_sources = Claw.EventSource[source],
)
```

Required environment variables:

- `CLAW_AGENT_PROVIDER`
- `CLAW_AGENT_MODEL`
- `CLAW_AGENT_API_KEY`
- `MATTERMOST_URL`
- `MATTERMOST_TOKEN`

If you want to run the live integration example in `Claw/examples/mattermost_live_test.jl`, you will also want `MATTERMOST_PAT` for posting as a human test user.

The Mattermost source connects over the websocket API, registers available channels after login, and maps posts/reactions into Claw channel events.

## Event Sources And Channels

Core exports include:

- `EventSource`, `Event`, `ChannelEvent`
- `EventType`, `EventHandler`
- `register_event_source!`, `register_event_handler!`, `register_channels!`
- `init!`, `run`, `start!`
- `ReplEventSource`, `ReplChannel`, `ReplInputEvent`, `@a_str`

Useful starting points in the repo:

- `Claw/ext/slack_run.jl`
- `Claw/ext/mattermost_run.jl`
- `Claw/examples/mattermost_live_test.jl`

Examples live in `Claw/examples/`.

## Integrations (user-driven enablement)

Every integration (Slack, Telegram, Signal, MS Teams, Mattermost, GitHub, Fastmail)
lives in a static catalog with its config keys, listable before anything is loaded
or enabled. Loading the trigger package (`using Slack`) registers the integration's
factory; enabling it constructs, registers and starts the source, and persists it
in the `claw_integrations` table so it comes back on the next `init!`:

```julia
using Claw, Slack           # load: the "slack" factory registers itself
assistant = Claw.init!(db_path; ...)
Claw.enable_integration!(assistant, "slack")   # env vars supply the config
Claw.disable_integration!(assistant, "slack")  # stops it, persists disabled
```

The agent has the same surface as tools: `list_integrations`,
`enable_integration`, `disable_integration`. Sources passed explicitly via
`init!(event_sources = [...])` still work and are adopted under their catalog
names (the runner re-enables them every boot). All integration code loads
eagerly — a toggle activates code that is already loadable, so nothing here
depends on runtime `require` (trim-compile friendly).

## Subscription filters

`EventHandler` accepts an optional `filter` that narrows which events fire it:

```julia
EventHandler("main-repo", ["github_push"], "Summarize the push.", "mm-dev";
    filter = EventFilter(:jsonpath, "\$.extra.repo", "^quinnj/"))
EventFilter(:regex, "(?i)urgent")               # regex over event content
EventFilter(:prompt, "a real person wrote it")  # one-shot LLM classifier per event
```

JSONPath filters evaluate against `{"name": ..., "content": ... (parsed as JSON
when possible), "extra": ...}` with a `$.a.b`, `['name']`, `[0]`, `[*]` subset.
Filters run per event *before* coalescing; a `:prompt` filter that cannot reach
the model sends the event to the pipeline's retry ladder rather than silently
dropping or delivering it. The `add_event_handler` tool takes
`filter_type`/`filter_expr`/`filter_pattern` arguments.

## Coalescing

When several events of the same type pile up on one lane behind a running
evaluation (a burst of chat messages), the next drain folds up to
`PipelineConfig.max_coalesce` (default 8) of them into a single evaluation whose
prompt demarcates each event (`--- Event i of N ---`). Filters apply per event
before the batch forms. `max_coalesce = 1` disables coalescing. The global
concurrency cap is `PipelineConfig.max_concurrent_evals`.

## Untrusted event content

Non-conversational event content (inbound email bodies, webhook payloads) is
fenced in the evaluation prompt between `<<<UNTRUSTED_EVENT_CONTENT>>>` markers
with an instruction to treat it as data, not instructions; markers appearing
inside the payload are defanged. Chat messages on connected channels are the
operator's interface and pass through unfenced — tool restriction for
third-party-fed handlers is the trust tier's job (see `EventHandler`'s `trust`).

## Watcher (dual-model supervision)

An assistant can be configured with a second, cheaper "watcher" model that supervises
every event-handler evaluation: evals are journaled to the `claw_evals` table, stalled
or overrunning evals are aborted, and on failure the watcher composes a short note that
is sent to the event's channel (with a hardcoded fallback if the watcher itself fails).
No configured watcher = today's behavior, unchanged.

```julia
watcher = Claw.WatcherConfig(;
    provider = "anthropic",          # encouraged: different from the primary
    model_id = "claude-haiku-4-5",
    apikey   = ENV["ANTHROPIC_API_KEY"],
)
assistant = Claw.init!(db_path; watcher)
```

See `Claw/docs/watcher.md` for the full design (timeouts, failure classification,
journal schema, and the config-gated on-track checks).

## Tests

From the repo root:

```bash
julia --project=. test/runtests.jl Claw
```
