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
- `Claw/examples/heartbeat_poll_source.jl`

Examples live in `Claw/examples/`.

## Tests

From the repo root:

```bash
julia --project=. test/runtests.jl Claw
```
