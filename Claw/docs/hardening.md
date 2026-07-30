# Claw hardening: durable event pipeline & trust boundaries

Claw today is an at-most-once, in-memory event pipeline with no trust tiers. That is
fine for an attended REPL assistant and wrong for an always-on instance consuming
GitHub webhooks, email, and group chat. This document is the design for making Claw
survivable and safe unattended. It is deliberately split into two shippable stages so
neither review is enormous and the risky parts land separately from the mechanical ones.

Baseline facts (verified in the current source, not assumed):

- The event queue is `Base.Channel{Event}(Inf)` — unbounded, in-memory, never
  persisted. Sources ack upstream *before* the eval runs (Slack acks the envelope,
  GitHub returns 200 right after `put!`, JMAP advances its state cursor), so a crash
  loses events that will never be redelivered.
- Dispatch spawns one unbounded `@async` per (event × handler). Two messages in one
  channel evaluate concurrently against the same session; only the Agentif per-branch
  lock prevents interleaved writes, and it serializes *after* the model calls have
  already both started.
- A failed eval is `@error`-logged and dropped: no retry, no dead letter, no user-
  visible failure, and the user's message is not even recorded in history.
- There is no dedup anywhere. Slack `event_id`, GitHub `X-GitHub-Delivery`, and
  Telegram `update_id` are all available and all ignored. The test suite currently
  asserts redelivery-without-dedup as intended behavior.
- Every handler eval gets *all* tools, including `set_system_prompt` (persistent
  self-modification), `add_event_handler`/`add_job` (standing automations),
  `email_send`, and — with `enable_coding` — an unsandboxed `bash -l -c` PTY.
- `MSTeams.run_server` validates no inbound authentication whatsoever while binding
  `0.0.0.0:3978`.

---

# Stage 1 — Durable event pipeline

## 1.1 Persist-then-dispatch inbox

New table (the mechanism the rest of the stage hangs off):

```sql
CREATE TABLE IF NOT EXISTS claw_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    dedup_key TEXT UNIQUE,             -- source-provided delivery id; NULL = never deduped
    source TEXT NOT NULL,              -- "slack" | "github" | "tempus" | "repl" | ...
    name TEXT NOT NULL,                -- event type name (handler lookup key)
    payload TEXT NOT NULL,             -- serialized event (see 1.2)
    status TEXT NOT NULL CHECK (status IN ('pending','running','done','failed','dead')),
    attempts INTEGER NOT NULL DEFAULT 0,
    lane TEXT NOT NULL,                -- serialization key (see 1.4)
    created_at REAL NOT NULL,
    next_attempt_at REAL NOT NULL DEFAULT 0,
    lease_expires_at REAL,
    last_error TEXT
);
CREATE INDEX IF NOT EXISTS idx_claw_events_claim ON claw_events(status, next_attempt_at);
CREATE INDEX IF NOT EXISTS idx_claw_events_lane ON claw_events(lane, status);
```

Ingestion becomes: `INSERT OR IGNORE` (the UNIQUE `dedup_key` makes redelivery a no-op
for free) → `put!` the **rowid** on the in-memory channel purely as a wakeup. The
dispatcher claims work with a conditional update:

```sql
UPDATE claw_events SET status='running', attempts=attempts+1, lease_expires_at=?
WHERE id=? AND status='pending'
```

A claim that updates zero rows means someone else took it — skip. On boot, rows in
`pending`, or in `running` with an expired lease, are re-enqueued; that is crash
recovery and stuck-worker recovery in one rule.

**Ack ordering.** Sources must persist *before* acknowledging upstream. Slack's
envelope ack, GitHub's 200, and JMAP's cursor advance all move to after the insert
returns. This is the single change that converts the pipeline from at-most-once to
at-least-once.

## 1.2 Event serialization: the hard part

> **Corrected after implementation.** `rehydrate_event(source_tag::String, row)`
> cannot be a dispatch point — Julia dispatches on types, not on a `String` *value* —
> so it is a registry (`register_rehydrator!`) behind that entry point, and
> extensions register inside `start!` when their client is live (registering at
> module top level would not survive precompilation). The `row` must also carry the
> assistant so rehydrators can reach the channel registry. Because a handler only
> ever consumes `get_name` / `event_content` / `get_channel`, replay reconstructs
> exactly that surface, which collapses per-source work to "resolve a channel".

`ChannelEvent`s carry a *live channel object* holding a platform client — that cannot
be serialized and rehydrated after a restart. So events persist as
`(source, name, dedup_key, channel_id, content, extra::Dict)` and are rehydrated
through a per-source `rehydrate_event(source_tag, row)` hook that reconstructs the
channel from the source's live client registry (which exists after `start!` runs).

Consequences we accept explicitly:

- Replay after restart requires the owning source to be registered; events whose
  source is absent stay `pending` and are logged (not silently dropped).
- Rehydrated channels may have lost thread/streaming context — replayed responses
  are sent with `send_message` rather than streamed.
- Events whose handler side effects already partially happened (crash *after* an
  external send) can duplicate that send. At-least-once means handlers should be
  idempotent where it matters; we do not attempt exactly-once.

This is the honest cost of durability and is worth stating in the PR rather than
discovering in production.

## 1.3 Retry, dead-letter, and user-visible failure

Failure classification is already implemented for the watcher
(`classify_eval_failure`); reuse it. Policy per class:

| class | policy |
|---|---|
| `:rate_limit`, `:overloaded`, `:network` | retry with backoff `[30s, 1m, 5m, 15m, 60m]`, max 5 attempts |
| `:auth`, `:billing` | do **not** retry; mark `dead`, notify the owner channel |
| `:unknown` | retry twice, then `dead` |
| `:aborted` (shutdown) | return to `pending`, no attempt increment |

Exhausted retries → `status='dead'` with `last_error`, plus a best-effort apology on
the originating channel ("I hit repeated errors handling this; it's logged as event
#N"). A 2-second minimum refire gap prevents spin. Poison events therefore stop
instead of looping forever, and the operator can inspect `claw_events WHERE
status='dead'`.

## 1.4 Lanes: per-conversation serialization + global cap

Lane key = `Agentif.channel_id(ch)` for channel events, `"cron"` for Tempus,
`"async"` for subagent/PTY/worker completions. Each lane runs `max_concurrent = 1`
by default (so two messages in one channel can no longer race the same session), with
a global semaphore (`max_concurrent_evals`, default 4) bounding total in-flight evals.
Dequeue logs wait time and queue depth when a lane backs up beyond ~2s, which is how
an unattended instance reveals it is saturated.

This directly fixes the PTY-flood amplification: with a lane cap, a chatty process
produces a queue, not 1200 concurrent LLM calls. Additionally, PTY output events are
**coalesced** — chunks accumulate and emit at most one event per `pty_notify_interval`
(default 5s), with a per-event byte cap.

> **Added after implementation.** Lane keys include thread ids, so an always-on
> instance would accrue a task and a channel per conversation forever. Idle lanes are
> reaped (`lane_idle_timeout_s`, default 300s). Also found while implementing
> coalescing: the PTY poll loop's `pty_meta === nothing && break` raced LLMTools'
> session reaper, so the final exit-code event was sometimes never emitted at all.

## 1.5 Graceful shutdown

`Claw.shutdown!(assistant; timeout_s = 30)`: stop intake (close the wake channel),
stop the Tempus scheduler, stop sources, wait for in-flight evals to finish, abort the
stragglers via their `Abort` handles, return unfinished claims to `pending`, close the
DB. `Claw.run`/`init!` install a SIGTERM/SIGINT handler that calls it, so a deploy
restart drains instead of vanishing mid-eval. The five `ext/*_run.jl` scripts and
`projects/claw/runner.jl` block on a shutdown-complete event rather than
`wait(Base.Event())`.

## 1.6 Source supervision & health

`Claw.start!` currently runs sequentially: one source throwing (missing env var,
failed pagination) aborts `init!` with the event loop already running and later
sources never started. Instead: validate configuration up front, start each source in
a supervised task with restart + backoff (cap 3 restarts/hour), and treat one source's
failure as non-fatal to the others. An optional `is_healthy(::EventSource)` hook
(default `true`) is polled every 5 minutes; unhealthy sources are restarted under the
same cap. Restarts and failures are journaled so a silent Slack socket death becomes
visible instead of the assistant just going quiet.

## 1.7 SQLite ownership discipline

> **Corrected after implementation.** The problem is worse than "savepoints don't
> work". `SQLite.DBInterface.execute` returns a *lazy cursor*; a statement that
> returns rows stays mid-step, holding its lock, until something else runs on that
> connection or the GC finalizes it. `_init_claw_schema!` ran
> `PRAGMA journal_mode=WAL` — which **returns a row** — and never consumed it, so
> **every second connection to a Claw database failed with "database is locked"**.
> Verified directly: an unconsumed WAL pragma makes a second connection's write
> throw, and consuming the cursor fixes it. This affects more than the writer task —
> it would equally break an operator opening the file with `sqlite3`, or a backup
> process, while Claw is running. Claw-owned writes now go through a step-and-reset
> helper.
>
> A second consequence limits the scope of this section: Claw, Agentif, Tempus and
> LocalSearch all leave *read* cursors unconsumed, which under WAL pins a stale
> snapshot on the shared handle. Moving legacy-table writes onto a separate
> connection made that staleness observable. So the writer task is scoped to
> `claw_events`, `claw_source_journal` and migrations rather than "all writes", and
> a cursor-hygiene audit across the four packages is follow-up work.

The current single `SQLite.DB` handle is shared across the event loop, tool threads
(Agentif runs every tool via `Threads.@spawn`), the Tempus scheduler, and source
threads. It is in serialized mode so there is no corruption, but multi-statement
sequences interleave — and, as this round already discovered the hard way, savepoint
transactions fail outright ("SQL statements in progress") when other cursors are live.

Design: a **single writer task** owning a dedicated write connection, fed by a request
channel; readers get their own connections (SQLite readers are safe under WAL). Writes
become `execute_write(assistant, sql, params)` which enqueues and waits. This makes
real transactions possible (needed for claim/finish atomicity) and removes the
interleaving hazard. Also add `PRAGMA user_version` migrations — there is currently no
migration mechanism at all, so any column change silently breaks existing databases.

## 1.8 Fixes riding along (small, same subsystem)

- **Slack conversation continuity** (currently broken): top-level messages force
  `thread_ts = ts`, so every top-level DM maps to a fresh empty branch — "my name is
  Jacob" then "what's my name?" lands in different sessions. Mirror the Mattermost
  `_is_thread` logic: top-level → base channel branch; thread ids only for real
  thread replies.
- **Async results reach humans**: `start_subagent`/`start_pty`/`start_worker`
  completions currently evaluate into a no-op sink, so the user is told "you'll be
  notified" and never is. Capture the originating channel at spawn time and use it as
  the completion handler's channel; give each async session its own branch instead of
  a shared `"parent"` branch.
- **JMAP gap recovery**: persist the Email state cursor so mail arriving while the
  process is down is picked up, instead of seeding fresh at every startup.
- **PTY exit codes**: report the real exit status instead of the hardcoded `0` that
  currently tells the agent a failing build succeeded.

---

# Stage 2 — Trust boundaries

Stage 1 makes Claw survive. Stage 2 makes it safe to point at the public internet.
These are separate because they change what the agent is *allowed* to do, and that
deserves its own review.

## 2.1 Inbound authentication

- **MSTeams**: validate the Bot Framework JWT (issuer, audience = app id, signing keys
  from the OpenID config, expiry) before any event is created; refuse to start bound
  to a non-loopback interface without validation configured.
- **GitHub**: secret is already mandatory as of the round-1 fixes. Using
  `X-GitHub-Delivery` as the `dedup_key` is **blocked upstream**: GitHub.jl's
  `WebhookEvent` carries only `(kind, payload, repository, sender)`, so the header
  never reaches the callback. Needs a GitHub.jl change; until then GitHub events are
  deduped only by content, not by delivery id.
- Default all HTTP-listening sources to `127.0.0.1` unless a host is set explicitly,
  so the safe deployment (behind a proxy) is the default one.

## 2.2 Per-handler tool policy

`EventHandler` gains `tools::Union{Nothing, Vector{String}}` (nothing = default set)
and a `trust::Symbol` (`:owner` | `:untrusted`). Untrusted handlers cannot call the
self-modification/standing-automation tools (`set_system_prompt`, `add_event_handler`,
`remove_event_handler`, `add_job`, `remove_job`), the send-email tools, or the
shell/coding tools. Today an injected GitHub comment or inbound email can tell the
assistant to rewrite its own soul or install a mail-forwarding handler, and it will.

**Decision (owner, 2026-07-30): the default is `:owner` — restriction is opt-in.**
Existing automations keep working unchanged; marking a handler `trust = :untrusted`
is a one-field change. The tradeoff is accepted knowingly: until handlers fed by
externally-authored content (JMAP email above all, then GitHub webhooks and group
chat) are explicitly marked untrusted, a prompt injection in an inbound message can
still reach `set_system_prompt` and the send-email tools. Because the permissive
default is the one that persists, the implementation should make the risk visible
rather than silent: log once at startup naming every handler that is owner-tier *and*
fed by a source carrying third-party content, so the exposure is stated on every boot
instead of having to be remembered.

Owner identity: a configured `owner_channels` / `owner_user_ids` list; the REPL is
always owner. Tool availability is resolved per eval from the handler's trust tier.

## 2.3 Egress policy for `web_fetch`

Currently unrestricted: any host, any method, arbitrary headers and bodies, redirects
followed without re-validation. For an agent processing third-party content this is a
ready-made exfiltration and internal-pivot channel. Add: DNS resolution with
private/loopback/link-local ranges denied (re-checked on every redirect hop, since DNS
can rebind), non-GET methods gated behind config, a wall-clock deadline per fetch, and
fetched content wrapped in explicit untrusted-content delimiters when injected into
the model's context.

## 2.4 Subprocess environment scrubbing

PTY/worker/codex subprocesses inherit the full parent environment including every API
key. Pass a minimal allowlisted environment instead, so a prompt-injected `echo
$ANTHROPIC_API_KEY` returns nothing. (Full container sandboxing — the OpenClaw model —
is noted as future work; env scrubbing plus the tool policy is the 80% for a
single-user instance.)

---

## Migration & compatibility

- All new tables are `CREATE TABLE IF NOT EXISTS`; existing databases upgrade in place.
  `PRAGMA user_version` starts the migration ladder at the current implicit schema.
- Default configuration preserves today's *observable* behavior wherever it is safe to:
  lanes default to 1-per-channel (a behavior change, but the current concurrency is a
  race, not a feature), retries default on, dedup defaults on where a source provides
  an id.
- `trust` defaults to `:untrusted` for source-registered handlers, which **will**
  remove tools from existing automations. This is intentional and is the one change
  that requires reading release notes; the owner list is how you opt back in.

## Testing strategy

Stage 1 needs failure-injection tests, not just happy paths: kill-and-recover (claimed
events return after simulated crash), duplicate delivery (same `dedup_key` twice → one
eval), lane serialization (two events in one channel never overlap — assert via
observed timestamps), retry/backoff schedule and dead-lettering, shutdown draining
with in-flight evals, source restart under the hourly cap, and PTY coalescing bounds.
Stage 2 needs negative tests: forged MSTeams payload rejected, untrusted handler
cannot reach `set_system_prompt`, `web_fetch` refuses `169.254.169.254` and a redirect
into it, subprocess cannot see `ANTHROPIC_API_KEY`.

A note on test realism, learned this round: a credential-failure classifier written
against the *documented* error shape (`invalid_grant`, per RFC 6749) missed the shape
the provider actually returns when a token is rotated by another client (HTTP 401,
`invalid_request_error`, no `invalid_grant` anywhere) — the bug it was written to fix
survived in the most common real case, and only live-running against real stored
credentials exposed it. Where this design classifies provider behavior (the retry
policy table in 1.3 especially), the tests must include captured real-world response
bodies, not just hand-written ones matching the spec.
