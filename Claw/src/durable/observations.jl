mutable struct ConversationWatch
    harness::Harness
    conversation::String
    frames::Vector{Any}
    capacity::Int
    closed::Bool
end

_checkpoint_phase(value) = try
    parsed = JSON.parse(value)
    parsed isa AbstractDict ? get(parsed, "phase", "unknown") : "corrupt"
catch
    "corrupt"
end

function _snapshot(db, cid)
    c = _fetch_one(db, "SELECT * FROM claw_conversations WHERE id=?", (cid,))
    c === nothing && throw(ArgumentError("unknown conversation"))
    seq = _fetch_one(db, "SELECT seq FROM claw_runtime_meta WHERE id=1").seq
    # Like `inspect_task`, snapshots show phase and status, never payloads:
    # progress can hold partial model output and tool data.
    tasks = _fetch_all(db, "SELECT id,owner_task,kind,status,checkpoint,blocked,due_at,cancel,outcome,progress IS NOT NULL AS has_progress FROM claw_tasks WHERE conversation_id=? ORDER BY created_seq,rowid", (cid,))
    graph = [
        (;
            id = t.id, owner = _or_nothing(t.owner_task), kind = t.kind, status = t.status,
            phase = _checkpoint_phase(t.checkpoint), blocked = _or_nothing(t.blocked), due_at = t.due_at,
            cancel = t.cancel == 1, outcome = _or_nothing(t.outcome), has_progress = t.has_progress == 1,
        ) for t in tasks
    ]
    receipts = _fetch_all(db, "SELECT id,request_id,mode,state,run_id,answer_entry,reason FROM claw_submissions WHERE conversation_id=? ORDER BY admitted_seq,rowid", (cid,))
    deliveries = _fetch_all(db, "SELECT id,state,receipt,error FROM claw_outbox WHERE conversation_id=?", (cid,))
    usage = _fetch_all(db, "SELECT u.* FROM claw_usage u JOIN claw_tasks t ON t.id=u.task_id WHERE t.conversation_id=?", (cid,))
    effects = _fetch_all(db, "SELECT task_id,tool_name,effect_key,effect_state,result_entry FROM claw_tool_executions WHERE conversation_id=?", (cid,))
    resources = _fetch_all(db, "SELECT id,kind,state FROM claw_managed_resources WHERE conversation_id=?", (cid,))
    indexing = Int(_scalar(db, "SELECT COUNT(*) FROM claw_index_jobs WHERE state!='done'"))
    unknown = Int(_scalar(db, "SELECT COUNT(*) FROM claw_task_attempts a JOIN claw_tasks t ON t.id=a.task_id WHERE t.conversation_id=? AND a.unknown_spend=1", (cid,)))
    return (;
        seq, conversation = cid, branch = c.branch_id, context_revision = c.context_revision, tasks = graph, submissions = receipts,
        deliveries, usage, effects, resources, pending_index_jobs = indexing, unknown_spend_attempts = unknown,
    )
end
snapshot(h::Harness, cid::String) = _on_writer(db -> _snapshot(db, cid), h)
snapshot(h::Harness, c::ConversationRef) = snapshot(h, c.id)
"""Live heartbeat diagnostics, separate from the committed snapshot cursor.
Overdue workers retain their capacity and owner lock until they actually exit.
"""
function live_activity(h::Harness, cid::Union{String, ConversationRef})
    s = snapshot(h, cid)
    ids = Set(t.id for t in s.tasks)
    return lock(h.lock) do
        [
            (;
                task = id, group = x.group, idle_s = max(0, _monotonic_s() - x.context.heartbeat[]),
                overdue = _monotonic_s() > x.context.monotonic_deadline, abort_requested = Agentif.isaborted(x.context.abort),
            ) for (id, x) in h.live if id in ids
        ]
    end
end
_task_row(h::Harness, id::String) = _on_writer(db -> _fetch_one(db, "SELECT * FROM claw_tasks WHERE id=?", (id,)), h)
"""Inspect committed status and phase. Payloads are hidden by default; an owner
can explicitly request `include_payload=true` for checkpoint diagnosis.
"""
function inspect_task(h::Harness, id::String; include_payload::Bool = false)
    t = _task_row(h, id)
    t === nothing && return nothing
    include_payload && return t
    return merge(t, (; input_json = "{}", checkpoint = JSON.json(Dict("phase" => _checkpoint_phase(t.checkpoint))), progress = nothing))
end

"""Committed snapshot subscription. Frames are snapshots, with explicit overflow
reset and sequence. Subscription and initial read share the writer line.
"""
function watch(h::Harness, cid::String; after_seq::Int = -1, capacity::Int = h.limits.observer_frames)
    capacity > 0 || throw(ArgumentError("watch capacity must be positive"))
    return _on_writer(h) do db
        s = _snapshot(db, cid)
        w = ConversationWatch(h, cid, Any[], capacity, false)
        after_seq < s.seq && push!(w.frames, (; reset = true, snapshot = s))
        lock(h.lock) do
            push!(h.observers, w)
        end
        w
    end
end
function _publish!(h, seq)
    lock(() -> all(w -> w.closed, h.observers), h.lock) && return
    return _on_writer(h) do db
        lock(h.lock) do
            for w in h.observers
                w.closed && continue
                try
                    s = _snapshot(db, w.conversation)
                    # A publish queued behind another mutation delivers its latest
                    # committed snapshot. Cursor semantics never claim every delta.
                    isempty(w.frames) || last(w.frames).snapshot.seq < s.seq || continue
                    reset = length(w.frames) >= w.capacity || any(t -> t.blocked == "redacted", s.tasks)
                    reset && empty!(w.frames)
                    push!(w.frames, (; reset, snapshot = s))
                catch
                    w.closed = true
                end
            end
        end
    end
end

"""Explicit checkpoint migration for parked work. The deterministic transform
returns `(input, checkpoint)` for the built-in v1 codec. It cannot authorize replay
of an already executing effect or bypass its separate receipt.
"""
function migrate_task_checkpoint!(
        transform::Function, h::Harness, id::String;
        expected_revision::Int, from_version::Int, from_codec::Int, note::String
    )
    isempty(strip(note)) && throw(ArgumentError("migration evidence required"))
    return _transition!(h; point = :checkpoint_migration) do db, seq
        t = _fetch_one(db, "SELECT * FROM claw_tasks WHERE id=?", (id,))
        t.status == "pending" && t.revision == expected_revision && t.version == from_version && t.codec == from_codec || throw(StaleInvocation())
        e = _fetch_one(db, "SELECT effect_state FROM claw_tool_executions WHERE task_id=?", (id,))
        e === nothing || e.effect_state != "executing" || throw(ArgumentError("executing effects cannot be migrated"))
        input, checkpoint = transform(JSON.parse(t.input_json), JSON.parse(t.checkpoint))
        input isa AbstractDict && checkpoint isa AbstractDict && haskey(checkpoint, "phase") || throw(ArgumentError("invalid migrated checkpoint"))
        _exec!(
            db, "UPDATE claw_tasks SET version=1,codec=1,input_json=?,checkpoint=?,blocked=NULL,revision=revision+1,progress=? WHERE id=?",
            (JSON.json(input), JSON.json(checkpoint), JSON.json(Dict("migration" => first(note, 2000))), id)
        )
    end
end
function next_frame!(w::ConversationWatch)
    return lock(w.harness.lock) do
        isempty(w.frames) ? nothing : popfirst!(w.frames)
    end
end
Base.close(w::ConversationWatch) = lock(w.harness.lock) do
    w.closed = true
    empty!(w.frames)
    filter!(x -> x !== w, w.harness.observers)
    nothing
end

"""
    scrub_durable_post!(h, post_id)

Remove a deleted platform post from every durable copy before search or
observation can read it.

- **History.** Masks the post's own entries, its reply, the entries of runs it
  started, and compaction entries after them (a summary or kept copy may
  contain it). Their search documents are deleted in the same transaction.
- **Runtime copies.** Masks the post's submissions, source events and classifier
  inputs. In conversations whose context includes the post, it also wipes task,
  tool, outbox and resource payloads and cancels unfinished work. Child
  conversations started there are wiped entirely.

Entries that merely follow the post are kept, as the default `scrub_post!`
does, so deleting one message does not erase what came after it. Unrelated
submissions keep their inputs. Content already sent to a provider or channel
cannot be recalled.
"""
function scrub_durable_post!(h::Harness, post_id::String)
    found = _redaction_transaction(h) do db, seq
        _redact_post!(db, h, post_id)
    end
    lock(h.lock) do
        foreach(id -> delete!(h.agents, id), found.profiles)
    end
    for x in lock(() -> collect(values(h.live)), h.lock)
        _task_row(h, x.context.task_id).conversation_id in found.conversations && Agentif.abort!(x.context.abort)
    end
    if h.assistant !== nothing
        a = h.assistant
        lock(() -> foreach(id -> delete!(a._live_events, id), found.events), a._live_lock)
        lock(a._inflight_lock) do
            for id in found.events
                abort = get(a._inflight, id, nothing)
                abort === nothing || Agentif.abort!(abort)
            end
        end
    end
    return nothing
end

# Privacy outranks a poisoned scheduler: the redaction is plain SQL that never
# depends on in-memory runtime state, so it commits even then.
function _redaction_transaction(f, h)
    h.state === :poisoned || return _transition!(f, h; point = :redaction)
    return execute_write(h.writer) do db
        SQLite.execute(db, "BEGIN IMMEDIATE")
        try
            seq = Int(_fetch_one(db, "SELECT seq FROM claw_runtime_meta WHERE id=1").seq) + 1
            value = f(db, seq)
            _exec!(db, "UPDATE claw_runtime_meta SET seq=? WHERE id=1", (seq,))
            SQLite.execute(db, "COMMIT")
            return value
        catch
            SQLite.intransaction(db) && SQLite.execute(db, "ROLLBACK")
            rethrow()
        end
    end
end

_column(db, sql, params = ()) = [first(r) for r in _fetch_all(db, sql, params)]
_in_list(values) = join(fill("?", length(values)), ",")

# Grow the redaction sets to a fixed point, then mask. Returns the affected
# conversations, erased events and redacted profiles for live cleanup.
function _redact_post!(db, h, post)
    tainted = Set{String}(_column(db, "SELECT entry_id FROM session_entries WHERE post_id=?", (post,)))
    union!(tainted, _column(db, "SELECT entry_id FROM claw_platform_entries WHERE platform_id=?", (post,)))
    # Sources record the platform post as `source_id` (GitHub) or `post_id` (Mattermost).
    events = Set{Int}(
        _column(
            db, raw"""SELECT id FROM claw_events WHERE json_valid(payload) AND
            (json_extract(payload,'$.extra.source_id')=?1 OR json_extract(payload,'$.extra.post_id')=?1)""", (post,)
        )
    )
    affected = Set{String}(_column(db, raw"SELECT id FROM claw_conversations WHERE json_valid(routing) AND json_extract(routing,'$.post_id')=?", (post,)))
    derived = Set{String}()
    submissions = Set{String}()
    SQLite.execute(db, "CREATE TEMP TABLE IF NOT EXISTS claw_redaction_seed(id TEXT PRIMARY KEY)")
    while true
        before = (length(tainted), length(affected), length(derived), length(events), length(submissions))
        # Submissions that carry the post: from it, admitted for an erased event,
        # or anywhere in a derived conversation.
        linked = Set{String}(_column(db, "SELECT d.submission_id FROM claw_dispatch_members m JOIN claw_event_dispatches d ON d.id=m.dispatch_id
            WHERE m.event_id IN ($(_id_list(events))) AND d.submission_id IS NOT NULL"))
        carrying = _fetch_all(
            db, raw"""SELECT id,conversation_id,run_id,placed_seq FROM claw_submissions
            WHERE (json_valid(origin) AND json_extract(origin,'$.post_id')=?)""" *
                " OR id IN ($(_in_list(linked))) OR conversation_id IN ($(_in_list(derived)))", (post, linked..., derived...)
        )
        for s in carrying
            push!(submissions, s.id)
            push!(affected, s.conversation_id)
            run = _or_nothing(s.run_id)
            run === nothing || union!(tainted, _column(db, "SELECT entry_id FROM claw_entry_runtime WHERE run_id=?", (run,)))
            _or_nothing(s.placed_seq) === nothing ||
                union!(tainted, _column(db, "SELECT entry_id FROM claw_entry_runtime WHERE seq=? AND run_id IS NULL", (s.placed_seq,)))
        end
        for cid in derived
            union!(tainted, _column(db, "SELECT e.entry_id FROM claw_entry_runtime e JOIN claw_runs r ON r.id=e.run_id WHERE r.conversation_id=?", (cid,)))
        end
        # Conversations whose context includes a tainted entry, and compaction
        # entries after one (they may hold a summary or a kept copy of it).
        _exec!(db, "DELETE FROM claw_redaction_seed")
        for id in tainted
            _exec!(db, "INSERT OR IGNORE INTO claw_redaction_seed VALUES(?)", (id,))
        end
        lineage = """WITH RECURSIVE later(id) AS (SELECT id FROM claw_redaction_seed
        UNION SELECT e.entry_id FROM session_entries e JOIN later l ON e.parent_id=l.id)"""
        union!(tainted, _column(db, "$lineage SELECT e.entry_id FROM session_entries e JOIN later l ON l.id=e.entry_id WHERE e.is_compaction=1"))
        union!(affected, _column(db, "$lineage SELECT c.id FROM claw_conversations c JOIN session_branches b ON b.branch_id=c.branch_id JOIN later l ON l.id=b.leaf_entry_id"))
        # Child conversations started by work in an affected conversation, and
        # the completion events they sent back.
        for cid in collect(union(affected, derived))
            union!(derived, _column(db, "SELECT c.id FROM claw_conversations c JOIN claw_tasks t ON t.id=c.owner_task WHERE t.conversation_id=?", (cid,)))
            union!(events, _column(db, "SELECT e.id FROM claw_events e JOIN claw_outbox o ON o.logical_key=e.dedup_key WHERE o.conversation_id=?", (cid,)))
        end
        union!(affected, derived)
        before == (length(tainted), length(affected), length(derived), length(events), length(submissions)) && break
    end
    profiles = _mask_runtime!(db, h, post, affected, derived, submissions, events)
    _mask_entries!(db, h, tainted)
    return (; conversations = affected, events, profiles)
end

function _mask_runtime!(db, h, post, affected, derived, submissions, events)
    for id in submissions
        _exec!(
            db, """UPDATE claw_submissions SET input_json=?,origin='{}',routing='{}',reason='redacted',
            state=CASE state WHEN 'queued' THEN 'withdrawn' ELSE state END WHERE id=?""", (JSON.json(Agentif.UserMessage("[redacted]")), id)
        )
        _exec!(db, "UPDATE claw_runs SET routing='{}' WHERE id=(SELECT run_id FROM claw_submissions WHERE id=?)", (id,))
    end
    for cid in affected
        # Unfinished work may carry the post: cancel it (queued unrelated input stays).
        for t in _fetch_all(db, "SELECT id FROM claw_tasks WHERE conversation_id=? AND status!='terminal'", (cid,))
            _cancel_task!(db, t.id)
        end
        _exec!(db, raw"UPDATE claw_conversations SET routing='{}' WHERE id=? AND (NOT json_valid(routing) OR json_extract(routing,'$.post_id')=?)", (cid, post))
        _exec!(db, "UPDATE claw_tasks SET input_json='{}',checkpoint='{}',progress=NULL,outcome=NULL,blocked='redacted' WHERE conversation_id=?", (cid,))
        _exec!(db, "UPDATE claw_tool_executions SET args='{}',result=NULL,effect_state='redacted' WHERE conversation_id=?", (cid,))
        _exec!(db, "UPDATE claw_outbox SET body='',error=NULL,receipt=NULL,state='redacted' WHERE conversation_id=?", (cid,))
        _exec!(db, "UPDATE claw_managed_resources SET details='{}' WHERE conversation_id=?", (cid,))
        for alias in _fetch_all(db, "SELECT event_type FROM claw_child_aliases WHERE (conversation_id=? OR child_id=?) AND event_type IS NOT NULL", (cid, cid))
            _redact_child_handler!(db, alias.event_type)
        end
    end
    profiles = String[]
    for cid in derived
        _exec!(
            db, "UPDATE claw_submissions SET input_json=?,origin='{}',routing='{}',reason='redacted' WHERE conversation_id=?",
            (JSON.json(Agentif.UserMessage("[redacted]")), cid)
        )
        _exec!(db, "UPDATE claw_conversations SET routing='{}',context_revision=context_revision+1 WHERE id=?", (cid,))
        _exec!(db, "UPDATE claw_runs SET routing='{}' WHERE conversation_id=?", (cid,))
        for p in _column(db, "SELECT DISTINCT profile_id FROM claw_submissions WHERE conversation_id=? AND profile_id IS NOT NULL", (cid,))
            row = _fetch_one(db, "SELECT payload FROM claw_agent_profiles WHERE id=?", (p,))
            row === nothing && continue
            payload = JSON.parse(row.payload)
            payload["prompt"] = "[redacted derived profile]"
            _exec!(db, "UPDATE claw_agent_profiles SET payload=? WHERE id=?", (JSON.json(payload), p))
            push!(profiles, p)
        end
    end
    # Source payloads (and classifier contexts built from them) are copies too.
    for id in events
        row = _fetch_one(db, "SELECT payload FROM claw_events WHERE id=?", (id,))
        row === nothing && continue
        channel, extra = try
            cid, _, ex = _decode_payload(row.payload)
            cid, ex
        catch
            nothing, Dict{String, Any}()
        end
        minimal = Dict{String, Any}("redacted" => true)
        haskey(extra, "source_id") && (minimal["source_id"] = extra["source_id"])
        _exec!(
            db, "UPDATE claw_events SET payload=?,status='dead',last_error='redacted',claim_token=NULL,claim_revision=claim_revision+1 WHERE id=?",
            (JSON.json(Dict("channel_id" => channel, "content" => "[redacted]", "extra" => minimal)), id)
        )
    end
    return profiles
end

function _redact_child_handler!(db, handler_id)
    _exec!(db, "UPDATE claw_event_handlers SET prompt='[redacted child completion]' WHERE id=?", (handler_id,))
    for g in _fetch_all(db, "SELECT * FROM claw_dispatch_groups WHERE handlers LIKE ?", ("%" * handler_id * "%",))
        handlers = JSON.parse(g.handlers)
        for raw in handlers
            raw["id"] == handler_id && (raw["prompt"] = "[redacted child completion]")
        end
        _exec!(db, "UPDATE claw_dispatch_groups SET handlers=? WHERE group_key=?", (JSON.json(handlers), g.group_key))
    end
    for d in _fetch_all(db, "SELECT id,handler_snapshot FROM claw_event_dispatches WHERE handler_id=?", (handler_id,))
        raw = JSON.parse(d.handler_snapshot)
        raw["prompt"] = "[redacted child completion]"
        _exec!(db, "UPDATE claw_event_dispatches SET handler_snapshot=? WHERE id=?", (JSON.json(raw), d.id))
    end
    return nothing
end

# Mask history entries and drop their search documents in the same transaction,
# so search never returns deleted content while an index job is pending.
function _mask_entries!(db, h, ids)
    search = h.assistant === nothing ? nothing : h.assistant.session_store.write_search_store
    for id in ids
        row = _fetch_one(db, "SELECT entry FROM session_entries WHERE entry_id=?", (id,))
        row === nothing && continue
        old = JSON.parse(row.entry, Agentif.SessionEntry)
        mask = Agentif.SessionEntry(;
            id = old.id, parent_id = old.parent_id, is_deleted = true, run_id = old.run_id,
            is_compaction = old.is_compaction, first_kept_entry_id = old.first_kept_entry_id, post_id = old.post_id
        )
        _exec!(db, "UPDATE session_entries SET is_deleted=1,entry=?,user_id=NULL WHERE entry_id=?", (JSON.json(mask), id))
        _exec!(db, "UPDATE claw_entry_runtime SET audit=NULL,eligible=0 WHERE entry_id=?", (id,))
        _exec!(db, "INSERT INTO claw_index_jobs(entry_id,revision,state) VALUES(?,1,'redacted') ON CONFLICT(entry_id) DO UPDATE SET revision=revision+1,state='redacted'", (id,))
        search === nothing || search.db !== db || LocalSearch.delete!(search, "session:entry:$id")
    end
    return nothing
end
