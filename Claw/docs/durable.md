# Durable Claw runtime

Opt in with `Claw.init!("claw.sqlite"; durable=true, ...)`. The default remains
legacy mode. Durable mode records acknowledged input, model attempts, tool
intent/results, owned children, compaction and outbound delivery in the existing
SQLite database. It uses `Agentif.model_turn`, which runs one logical provider
turn without the ordinary tool, queue, session or compaction middleware.

## Opening and admission

```julia
using Claw, Agentif, LLMTools

# Share the assistant's writer, integrations and owner lock.
h = Claw.open_harness(assistant)
env = LLMTools.LocalExecutionEnv(LLMTools.EnvRef(assistant.config.base_dir))
p = Claw.register_profile!(h, agent; environment=env)
c = Claw.ensure_conversation!(h; branch_id="investigation", profile=p)
r = Claw.submit!(h, c, "Investigate this failure"; request_id="operator:123")
Claw.wait_submission(r; timeout_s=30)
Claw.lookup_submission(h, c.id, "operator:123")
Claw.snapshot(h, c)
```

`init!` attaches and configures the Harness automatically. `open_harness(assistant)`
returns that attached instance. `open_harness(path)` is also available
for a standalone file-backed host. Register its model/profile, exact tool
contracts, environments and delivery adapters before `resume!`. Opening recovers
records but does not dispatch them; submission, wait or `resume!` starts scheduling.

An identical `(conversation, request_id, input, mode, origin, profile)` returns
the same durable receipt. A conflict throws `SubmissionConflict`. States are
`queued`, `placed`, `answered`, `unanswered` and `withdrawn`. An answered receipt
references its committed entry; failures and partial output are audit records.
Wait timeout or caller Abort only stops waiting. `withdraw!` affects queued input;
`abort_conversation!` persists cancellation for placed work and ordinary descendants.

Default follow-ups start distinct ordered runs. `mode=:steer` joins the current
run at an eligible model/tool boundary, one at a time. `mode=:write` places passive
context at a boundary and settles as `unanswered` with `passive_write`. At final
answer, the answer is placed first, then queued writes and the next steer. Already
placed inputs share the eventual answer; a later follow-up has a separate run.
Ordering uses committed sequence and row ordinal. There is no implicit consume-all
mode. A profile/default change affects later admissions, never an issued run.

## Effects and recovery

```julia
spec = Claw.ToolSpec(tool; version="my-adapter-v1", replay=:unsafe)
p = Claw.register_profile!(h, agent; specs=[spec], environment=env)
```

Every legacy/custom tool defaults to unsafe. Parsing, authorization, final args,
schema/adapter version, environment, policy and operation key commit before its
body begins. Completed receipts are reused. An interrupted unsafe invocation is
`uncertain` and holds the run; the next model request cannot repeat it under a
new call ID. Explicit safe replay permits repetition of the same compatible
intent, including a read that may return changed data. Safety is the adapter
author's versioned contract, not a name or purity guess.

A context adapter receives `InvocationContext` with Abort, deadline, progress and
fenced commit helpers. `Claw.execution_intent(ctx)` and
`Claw.execution_environment(ctx)` expose the issued receipt/environment.
`report_progress!` bounds serialized UTF-8/JSON and checks the fence before
throttling. Normal `ToolOutcome(is_error=true)` is an application result;
infrastructure interruption/unknown effects have separate states.

`ToolSpec(reconcile=...)` can return a proven `ToolOutcome`, `:retry` under the
adapter's explicit protocol, or `nothing` to remain held. An operator can call
`resolve_effect!(h, task_id, outcome; note="independent receipt/evidence")`.
Resolution records evidence; it never silently repeats an unsafe body.

Final answer, history leaf, run/receipt settlement, known usage and outbox intent
are atomic. Delivery uses the immutable issued address and stable logical key.
Native channel sends are unsafe because no universal remote dedup guarantee is
assumed. A lost send receipt produces uncertainty. A registered `DeliveryAdapter`
may explicitly declare `:idempotent` or `:reconcile` when its remote protocol
supports that behavior. `resolve_delivery!` also requires operator evidence.
An answered input means the local answer exists; inspect delivery separately.

Model requests can repeat after interruption. Known usage is unique by
task/attempt/category; unreceived spend is unknown. Each request intent and bounded
partial output is persisted, and interrupted partials remain audit-only. Transport
retry is disabled for durable calls. `HarnessLimits.attempts` limits total model
requests per logical task (including tool turns); `run_timeout`, request/tool
timeouts and bounded persisted UTC backoff also apply. Live deadlines, retry timers,
progress throttling and supervision use monotonic time. Restart delays clamp to
their configured budgets; UTC records remain available for diagnosis. Anthropic pause-turn
continuations remain one logical turn and can contain several wire requests.
No mid-socket or deferred provider handle is restored.

Errors, aborts, refusals, length stops, empty responses and invalid tool termination
cannot create an answered receipt or execute their calls. Context overflow gets
at most one non-substantive compaction retry. Prompt classifiers and watchers are
model-purpose tasks with their own attempts/usage. Invalid classifiers fail visibly
rather than discard input. Optional Jev selection persists conservative evidence
after base filters and before dispatch; source permission/timeouts are described in
[relevance.md](relevance.md). A crash before its receipt can repeat that cheap
request; a valid committed receipt is reused with its frozen policy.

## Ownership and local execution

`start_subagent`, `message_subagent`, `list_subagents` and `kill_subagent` map to
stored child conversations and aliases. Keyed creation, initial submission and
ownership commit together. Child tool contracts are a subset of inherited exact
manifests; trust/environment cannot widen. `message_subagent` accepts
`mode="steer"` in durable mode and can admit input while the child runs.
Completion notifications are idempotent local source events with persisted intent.
Their handler and event type survive restart, including asynchronous messages to a
child that was initially created synchronously.

Parents release model/tool permits while waiting. Ordinary children drain before
the parent task becomes terminal. `allSettled` and owned-only `failFast` are
supported; ancestor and cross-task dependency cycles are rejected. A local answer
can be inspectable while its generation is still `completing` owned work.
Background work is excluded from normal abort unless `include_background=true`.

PTY/worker launch metadata and correlation identities are visible managed resources.
After process loss they become `interrupted`; their VM, socket, Julia Task or
arbitrary shell process is not recreated. Starting new work requires an explicit
action. Local environments preserve native path/symlink containment and scrubbed
subprocess variables. File mutation guards serialize native operations on canonical
paths in this process. Shell and other processes can bypass those guards, and shell
can access paths outside cwd. This is native execution, not an OS sandbox.

`close_harness!(h; mode=:suspend, grace_s=30)` keeps work resumable.
`mode=:abort` records cancellation. Cooperative workers drain; a noncooperative
worker returns `status=:draining` and retains capacity and the owner lock until it
actually exits or the process ends. Repeated close can finish draining. Watchers
observe committed phases and live heartbeats; joins, backoff, compatibility blocks
and uncertainty are expected waiting. A watcher note has its own bounded request
budget and outbox receipt, including a default note if a zombie occupies the only
model permit.

## Context, privacy and operations

Threshold compaction is an owned summary task. The complete prepared request budget
includes fresh input, prompt, actual tool schemas, opaque content and retained
tool pairs. The estimate is serialized bytes divided by four, not a provider
tokenizer guarantee. Only useful normally terminated summaries without calls can
replace context, and their captured head revision must still match. Summary usage
is separate. Historical entries remain immutable until redaction. Forks retain a
reviewed committed context/privacy cutoff with fresh runs, inbox, usage and
ownership. Reset uses `expected_revision` and cancels obsolete work. Background
compaction and a general state-document/plugin DSL remain optional later work.

New search indexing is eventual. Embedding/tokenizer work runs outside the writer;
committed index intents remain visible until the host's search store processes
them. A standalone Harness without a search host leaves them pending.
`scrub_durable_post!` immediately masks source/descendant history, summary copies,
classifier checkpoints, derived child state, payloads, outbox and index work before
observation/search. It conservatively cancels and clears runtime payloads in
affected conversations, including saved supervision routing, managed-resource
details and child completion events already admitted to another conversation.
Older independent history is preserved. Redaction can therefore
remove later derived context; it does not attempt to edit a summary sentence by
sentence. Legacy standalone Agentif summaries have the narrower existing scrub
contract and are not retroactively assigned durable provenance.

`inspect_task` hides input/checkpoint/progress payloads by default; owner diagnosis
can explicitly select `include_payload=true`. `snapshot`, `watch` and
`live_activity` show graph/phase, block reason, UTC due time, unknown effects,
usage, deliveries, resources and indexing. These local handles are for the trusted
host. Watch registration and its first snapshot share the writer sequence; bounded
overflow declares a reset snapshot. They are observations, not external delivery
queues. Closing/failing an observer does not fail execution.

Unknown definition/codec, model configuration, credential reference, adapter/tool
revision, environment or source blocks the specific work with an inspectable
reason. Register its exact compatible revision before resuming. Reviewed codec
repair can use `migrate_task_checkpoint!` with expected revision and evidence;
it cannot authorize an uncertain effect.

## Migration and guarantees

The canonical database path has one POSIX advisory-lock owner before startup writes.
An owner epoch plus invocation token/revision fences callbacks and event claims.
Claimed groups settle atomically; frozen dispatch/filter/relevance membership
prevents a later event or handler edit from replaying an earlier admission.
Every transition uses the shared writer and publishes after commit. A known
rollback leaves the host usable; commit/adoption uncertainty poisons scheduling,
requiring close/reopen to derive truth from committed records.

Schema v6 remains the reviewed legacy batch migration. Durable v7 adds fenced
claims/version metadata, v8 conversations/tasks/receipts and the explicit event
CHECK rebuild, v9 effects/outbox/indexing and v10 child/resource/platform aliases.
Pass `backup_path` before production migration or use `backup_harness!` for a
SQLite-backup-API snapshot including WAL. Shared schemas and integrity are checked;
future writer/schema versions fail before baseline mutation. v1–v6 migration
fixtures preserve old IDs, branches, handlers, schedules and source metadata and
invent no historical effect receipts.

Running legacy events during durable upgrade become `legacy_interrupted`, since
their effects are unknown. Pending rows bridge normally. Durable intake carries a
marker before acknowledgment, so loss between claim and dispatch remains resumable.
Turning durable mode off requires settled work or explicit `park_durable=true`
under this capable binary. Parked durable branches/events cannot run through legacy
evaluation. A manually split historical legacy batch is not automatically repaired.

Default `durability=:process_crash` uses SQLite WAL/NORMAL.
`durability=:acknowledged_write` selects FULL, tested for configuration and recovery,
not power failure. Guarantees assume a healthy local filesystem, intact database
and a capable cooperating launcher. Old pre-guard binaries must not use a migrated
live file. Windows durable ownership, network filesystems, hard-link aliases,
multi-host ownership, host/storage loss, paid-provider accuracy, universal remote
reconciliation and arbitrary process restoration are outside these guarantees.
No runtime here claims universal exactly-once external effects. Redacting local
copies cannot erase content already sent to a remote channel or provider.

The fault suites use fake providers, real files, fresh Julia processes, SIGKILL and
independent effect counters. See `Claw/test/durable_all_test.jl` and its named
request/tool/child/summary/source/delivery cut fixtures for executable contracts.
