# Claw Watcher — dual-model supervised evaluation

A Claw assistant can be configured with **two** models: the **primary**, which runs
event-handler evaluations exactly as today, and a **watcher**, which supervises every
evaluation. If the primary eval dies (exception), stalls (no stream activity), or
overruns its deadline, the watcher composes a short observed-failure response and emits
it to the event's channel — so the claw stays alive and responsive even when individual
evals fail. If the watcher model itself fails, a hardcoded plain-text fallback is sent.
No configured watcher = today's behavior, unchanged.

## Design principles

1. **Detection is deterministic code; diagnosis and the user-facing note are the
   watcher model.** Timers, task status, and exception classification decide *that*
   something went wrong; the model only explains it and suggests next steps.
2. **The last resort needs no model.** The watcher's own eval is wrapped in a timeout
   and try/catch; on failure a hardcoded message is emitted. Every path terminates.
3. **Prefer a different provider for the watcher.** A primary-provider outage
   (rate limits, 5xx storms) is exactly when the watcher must still work.
4. **Everything lands in a durable journal.** `claw_evals` records each eval's
   lifecycle (running → completed | failed | stalled | overrun, plus whether a
   fallback was sent), so an unattended instance can be debugged after the fact and
   external monitors have a heartbeat surface. This journal is also groundwork for
   the durable event-inbox work (separate PR).

## Architecture

```
event → handler → supervised_evaluate(assistant, ev, handler)
                    ├── journal row (claw_evals: running, started_at, last_activity_at)
                    ├── primary task: Claw.evaluate(...; middleware = watch_middleware)
                    │     └── watch_middleware: every AgentEvent →
                    │           touch last_activity (atomic) + throttled journal write,
                    │           append one-line summary to bounded trace ring buffer
                    └── supervisor loop (every check_interval_s):
                          primary done?        → journal: completed / failed(classified)
                          no activity > stall_timeout_s  → abort! + reason=:stalled
                          runtime > max_eval_duration_s  → abort! + reason=:overrun
                          on failure & respond_on_failure:
                            watcher model composes fallback (bounded by watcher_timeout_s)
                            → send_message(channel) → journal: fallback_sent
                            watcher failed too? → hardcoded fallback string
```

### Hook points used (all existing Agentif machinery)

- **Event observer**: `Agentif.evaluate(f, agent, input; ...)` already threads an
  event callback `f` through the whole middleware stack — every `AgentEvent` (turn
  starts, message deltas, tool executions, errors) flows through it. `watch_observer`
  is that callback: heartbeats + counters + the trace ring buffer, no middleware
  insertion needed. `Claw.evaluate` gained an `observer` kwarg to pass it through.
- **`Abort`**: the supervisor holds the eval's `Abort` handle and can cancel a stalled
  or overrun eval; the abort is checked between turns/tools and interrupts in-flight
  SSE reads at the next event. Note: an aborted eval can surface either as a thrown
  `AbortEvaluation` or as a clean return (depending on which middleware observes the
  flag first) — the supervisor's own abort reason takes precedence over exception
  classification, so stall/overrun status is reliable either way.
- **Channels**: the fallback goes out via `Agentif.send_message(ch, text)` — never the
  streaming interface — so it cannot collide with a half-open stream. A stalled primary
  may still hold the session **branch lock**; the fallback deliberately bypasses
  session middleware (it is not part of the conversation history).
- **`SinkChannel`**: handlers without a channel get supervision + journaling but no
  fallback message (there is nowhere to send it).

### Failure classification

`classify_eval_failure(err) :: Symbol` maps exceptions to
`:rate_limit | :auth | :overloaded | :network | :aborted | :unknown`
using provider error shapes (HTTP status where available, message heuristics
otherwise). Tool exceptions never reach the classifier — tool execution converts
them to error tool results inside the eval. The class is journaled and given to the watcher model so its note can be
specific ("hit the provider's rate limit", not "something went wrong").

### Group-chat semantics

A silent completion (the `∅` no-reply sentinel, or an eval that simply produced no
channel output) is **not** a failure — group-chat handlers legitimately stay quiet.
The watcher only responds to error/stall/overrun terminations. (A future
`respond_on_silence` per-handler option could revisit this.)

### The watcher prompt

The watcher model receives: the failure class, handler id + prompt, the event name and
truncated content, elapsed time/turns/tool count, and the tail of the trace ring
buffer. It is asked for a 1–3 sentence user-facing note in the assistant's voice —
what was being worked on, what happened, and whether retrying later makes sense. It has
**no tools** and its output is sent verbatim.

### Phase 2 (config-gated, off by default): on-track checks

`on_track_checks = true` additionally runs the watcher every `on_track_every_turns`
turns with the trace tail and handler prompt, asking for a verdict:
`on_track | concern | abort` — `abort` cancels the primary and sends the watcher's
explanation. This catches the failure mode timers can't: an eval that is making
progress but going nowhere (tool loops, burning tokens on a doomed path). Deliberately
conservative: only `abort` acts; `concern` is journaled.

### Explicitly out of scope (future work)

- Retry-with-backoff of failed evals (belongs with the durable event inbox).
- Symmetric consensus (both models evaluate and compare answers).
- Watcher-driven memory repair (Letta-style sleep-time agent).

## Configuration

```julia
watcher = Claw.WatcherConfig(;
    provider   = "anthropic",          # encouraged: different from the primary
    model_id   = "claude-haiku-4-5",   # cheap + fast is the point
    apikey     = ENV["ANTHROPIC_API_KEY"],
    stall_timeout_s      = 120.0,      # no stream activity → abort + respond
    max_eval_duration_s  = 900.0,      # hard wall-clock ceiling
    check_interval_s     = 5.0,
    respond_on_failure   = true,       # send the fallback note to the channel
    watcher_timeout_s    = 60.0,       # budget for the watcher's own eval
    on_track_checks      = false,      # phase 2
    on_track_every_turns = 5,
    abort_grace_s        = 10.0,       # bounded wait for the primary to observe an abort;
                                       # a zombie (wedged in un-timed I/O) is left behind
                                       # and journaled, and the fallback still goes out
)
assistant = Claw.init!(db_path; watcher, ...)
```

`AgentAssistant` gains a `watcher::Union{Nothing, WatcherConfig}` field. With
`nothing` (the default), `_run_event_handler!` behaves exactly as before.

## Journal schema

```sql
CREATE TABLE IF NOT EXISTS claw_evals (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_name TEXT NOT NULL,
    handler_id TEXT NOT NULL,
    channel_id TEXT,
    status TEXT NOT NULL CHECK (status IN
        ('running','completed','failed','stalled','overrun','aborted')),
    failure_class TEXT,
    started_at REAL NOT NULL,
    last_activity_at REAL NOT NULL,
    finished_at REAL,
    turns INTEGER NOT NULL DEFAULT 0,
    tool_calls INTEGER NOT NULL DEFAULT 0,
    error TEXT,
    fallback_sent INTEGER NOT NULL DEFAULT 0,
    watcher_note TEXT
)
```

On `init!`, rows still marked `running` from a previous process are flipped to
`failed` with `failure_class = 'process_crash'` — post-crash forensics for free.

## Prior art

- **Temporal activity heartbeats** — progress pings + deadline, the cleanest
  formalization of stall detection (`last_activity_at` + lease semantics).
- **Erlang/OTP supervisors** — restart-intensity thinking; here: supervise + report
  rather than blind restart (retry belongs with the durable inbox).
- **OpenClaw** (`cli-watchdog-defaults.ts`, no-output watchdog; cron hard timeouts) —
  process-level watchdog ladder, no second model.
- **Letta sleep-time agents** — the closest dual-model prior art: a second, cheaper
  agent sharing state with exclusive repair capabilities; ours is the liveness
  counterpart (phase 2's on-track checks borrow its "cadence + verdict" shape).
