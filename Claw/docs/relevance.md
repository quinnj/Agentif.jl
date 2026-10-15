# Jev source relevance and batch deduplication

Claw can use JevSDK to reduce the source events sent to a handler's full model.
During subscription setup, the full model captures the user's stated interests
and writes contextual relevance criteria. The full model still decides actions
for the retained events with the handler's existing trust tier and tool policy.

For example, "follow reviews and issues about Claw durability" should become a
policy that includes new reviews, comments, failures, changes and possible
connections to durability. An unrelated routine post is a possible rejection.
Sharing a PR number is insufficient evidence that two events say the same thing.

## Setup and lifecycle

Existing handlers have no relevance policy and retain their existing behavior.
`add_event_handler` accepts `relevance_interests` and `relevance_policy` together.
Its tool instructions ask the subscription-setup model to construct the policy
from the user's interests; no extra full-model generation call is added.
The Julia equivalent is:

```julia
policy = Claw.EventRelevancePolicy(
    "Follow reviews and issues about Claw durability",
    "Include new reviews, comments, crash reports, retry changes and any possibly related regression. Routine unrelated activity is irrelevant.";
    mode=:shadow,
)
handler = Claw.EventHandler("claw-durability", ["GitHubPRReady"],
    "Summarize relevant changes and explain whether I need to act.";
    relevance=policy, trust=:untrusted, tools=String[],
)
Claw.register_event_handler!(assistant, handler)
```

Policies are opt-in. Each validated specification has an immutable SHA-256
version, including its interests, criteria, thresholds, mode and dedup setting.
Updating a subscription changes its active policy link; older specifications
and decision records remain. Omitting relevance arguments on an upsert removes
the active policy. An event payload cannot update a policy.

Use shadow mode on representative synthetic or approved data before enabling
suppression. Shadow records proposed exclusions and passes every event that
survived the existing subscription filter. Enforcement is selected explicitly
with `mode=:enforce` or the tool's default `relevance_mode="enforce"` when adding
a new policy. A malformed or missing persisted policy passes events through.

No event data is sent to Jev merely because an API key exists in the environment.
The operator must approve transmission of the specified sources and endpoint,
then explicitly configure a client:

```julia
import JevSDK

client = JevSDK.Client(ENV["TYPESAFE_API_KEY"];
    connect_timeout=1, request_timeout=2)
jev = Claw.JevConfig(client; allowed_sources=["github", "slack", "msteams"])
# Pass jev=jev to Claw.init! or Claw.AgentAssistant.
```

The repository pins JevSDK v1.0.0's verified release commit in its project sources
and portable manifest. Its required HTTP/JSON versions replace the older manifest
pins; unrelated package versions are preserved. Before registry availability,
use the repository environment's source pins rather than guessing a registered
package version.

The subscription tool cannot approve sources or configure credentials. Client
credentials stay in memory and are omitted from policy/decision records and
configuration display. Internal REPL, scheduled-job and completion sources are
excluded. Metadata-marked direct pings pass without a Jev request.

## Selection and deduplication

The pipeline persists the original event first. It collects a same-lane batch,
preserves FIFO order by processing consecutive event types separately, and
applies each handler's existing regex/JSONPath/prompt filter per event. Jev then
selects from that handler's surviving events before the full-model evaluation.
Existing filter semantics are preserved. A `prompt` filter still costs a model
call per event and retains its existing failure/uncertainty behavior; use a Jev
policy directly when reducing model calls is the purpose.

The default rejection cutoff is a relevance probability at or below `0.01`.
All higher probabilities, missing answers, wrong answer types and invalid
probabilities pass. These are conservative engineering thresholds, not a
guarantee of model accuracy or calibrated probability. The operator should
inspect false exclusions in shadow mode against the subscription's actual data.

Dedup applies **only within this handler's current same-type coalesced batch**:

* Literal copies are detected locally from content and complete persisted
  provenance. Their redundant questions are omitted from the Jev request.
* Semantic duplicates require both confidence and chosen-label probability
  of at least `0.99`, a valid probability distribution, and an earlier retained
  representative with identical source, event type, lane, channel and metadata.
* Any difference in review/comment ID, author, action, timestamp or other
  metadata preserves the event. This intentionally passes some repeated
  information when its provenance differs. Jev's instructions also require
  new facts, status changes and SHAs to pass even when metadata is identical.
  GitHub notifications carrying `kind` metadata permit only literal dedup;
  changed rendered state is retained even if a duplicate answer is wrong.
* A rejected representative cannot cover another relevant event. Uncertain,
  unknown, later or invalid representatives cannot suppress an event.

There is no recent-event queue, cross-batch information comparison or cache of
completed work. A fresh event in a later batch is considered afresh. Existing
source delivery-key dedup in `submit_event!` remains a separate mechanism.
A duplicate decision means that another event conveys the information; it
does not mean that any action has already succeeded.

All retained events keep their order and existing per-member trust fences.
Semantic output is only a selection decision. It cannot select tools, change
trust, create permissions, send a message or acknowledge a successful action.
New handlers consuming third-party data should use `trust=:untrusted` and a
deliberate tool subset, independently of relevance filtering.

## Burst window and limits

Before this feature, a lane drained only events already queued when its worker
became available. There was no fixed collection timer or semantic dedup.
That remains the default with `coalesce_window_s=0`.

```julia
pipeline = Claw.PipelineConfig(coalesce_window_s=1.0, max_coalesce=8)
```

An opt-in window must be finite and between zero and two seconds. It expires
from the first event's queued age and never extends for later arrivals. It stops
early at `max_coalesce`; an aged backlog drains immediately. Collection holds
neither an event claim nor an evaluation permit. Different event types retain
their original ordering and are claimed only when their run becomes eligible.
Shutdown interrupts collection, leaving the persisted events pending for replay.
The latency is a collection bound; queueing, SDK transport and model execution
can add their own delay.

Jev makes at most one SDK request per eligible handler batch, with one relevance
question per unique candidate and optional duplicate questions. Defaults cap
the request at 32 candidates and 64,000 serialized bytes, with two concurrent
requests per `JevConfig`. Larger batches retain excess events; oversized requests
pass through. Saturation passes immediately rather than queueing more Jev work.
SDK connect and request timeouts must each be at most two seconds. There are no
SDK retries in this stage. Cancellation is checked before and after the call;
an in-progress transport ends according to its SDK timeouts.

The adapter validates raw probability tokens before typed decoding: the released
JevSDK v1 JSON conversion accepts a boolean as a float, which could otherwise
turn malformed output into a confident exclusion. It uses the release-pinned
SDK's `_validate` and `_request` helpers for that guard and preserves the SDK's
transport/credential behavior. Upgrading the SDK requires reviewing this internal
API coupling; a strict decoder or supported raw-response hook upstream would
remove it. Boolean probabilities and confidence pass through as failures.

## Failure, retention and replay

Network errors, rate limits, authentication failures and malformed responses
pass candidates to the full model. Literal copies may still be folded locally.
API error text is never logged or persisted because it may echo event data.
Decision reasons use fixed codes such as `jev_error_pass`, `jev_busy_pass` and
`invalid_relevance_pass`.

`claw_events` retains the original content and metadata with its existing
retention behavior. `claw_relevance_policies` retains immutable specifications;
`claw_handler_relevance` holds the active link. `claw_relevance_batches` records
ordered event IDs, kept IDs, per-event outcome/reason/probability/confidence/representative,
policy version, returned model and reported usage. It contains references to raw
events rather than another copy of their private payloads.

A decision snapshot is committed through Claw's writer before an event can be
excluded or sent to the full-model handler. Persistence failures use the ordinary
event retry path. Exact same-batch retries and database reopen reuse the stored
selection without another API call. A damaged selection/audit snapshot is
repaired to pass-through. Disabling the client passes new batches; an existing
frozen retry retains its earlier recorded selection. Remove the active policy
to bypass relevance for a new dispatch.

A crash before the decision journal commits can repeat the cheap request. Failed
requests may have incurred provider cost even when usage is unavailable. The
request cap and timeouts bound this stage; they are separate from durable handler
model/effect budgets and receipts.

The updated PR27 path persists claimed batch membership and settles each group
atomically, so newly queued follow-ups remain separate on retry. Already-split
legacy state, individually corrupt/dead-lettered members, changed prompt-filter
verdicts or handler configuration can still change the kept-ID input key.
Exact-batch Jev snapshots stabilize its own selection for identical inputs;
they do not freeze existing prompt-filter verdicts or handler revisions.
The durable dispatch bridge must freeze handler policy/revision, batch membership
and final selected IDs alongside its existing filter/dispatch receipts before
creating a handler run. Do not treat relevance journaling as an effect receipt.

Retained exclusions can be inspected by joining audit event IDs to `claw_events`
and policy versions to `claw_relevance_policies`. Deliberate replay through the
normal durable admission/dispatch API must preserve action receipts and source
delivery semantics; simply changing a raw event to pending is not evidence that
repeating its actions is safe. No automatic replay or retention purge is added.

## Cost and validation

Compare already-coalesced **handler batches**, not raw event counts. Let `C_J`
be one Jev batch's cost, `C_L` a full-model batch's cost, and `p` the fraction of
batches with any retained event. Approximate model cost is `C_J + p*C_L` versus
`C_L` before filtering. The stage pays off when `C_J < (1-p)*C_L`. SDK outages
restore the full-model cost plus the failed cheap call. In-batch dedup primarily
reduces tokens; it rarely removes a full-model call by itself.

For independent events with relevant fraction `r` and batch size `b`, a batch
reaches the full model with probability `1-(1-r)^b`. At `r=10%` and `b=8`, that
is about 57%, even though 90% of individual events are irrelevant. Larger windows
therefore trade latency and coalescing savings against how often a batch contains
at least one relevant event. Measure request counts, retained batches, payload
bytes, token usage, latency and false exclusions before tuning.

Fixture tests exercise typed SDK request/answer construction, uncertainty,
literal and semantic duplicates, fresh-batch behavior, different review/change
provenance, hostile text fencing, permission preservation, missing configuration,
oversize/saturated requests, API failures, shadow mode, persisted replay and
pipeline selection. Window tests exercise FIFO batching, zero-window compatibility,
event limits, fixed deadline, unclaimed waiting, free evaluation slots, cancellation
and reopen/recovery. They use synthetic data, mocked model/SDK transport, and
real SDK success, malformed numeric output, rate-limit and timeout requests to a
synthetic loopback HTTP fixture. They do not measure
real Jev accuracy, production throughput or paid API cost.
