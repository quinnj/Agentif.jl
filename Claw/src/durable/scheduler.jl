function _recover_harness!(h)
    return _transition!(h; point = :recovery) do db, seq
        for t in _fetch_all(db, "SELECT * FROM claw_tasks WHERE status='running'")
            if t.kind in ("generation", "compaction", "filter", "watcher")
                _exec!(db, "UPDATE claw_task_attempts SET unknown_spend=1,ended_seq=?,failure='process_interrupted' WHERE task_id=? AND ended_seq IS NULL", (seq, t.id))
                # A request that keeps killing the process must not loop forever.
                cp = try
                    JSON.parse(t.checkpoint)
                catch
                    nothing
                end
                if cp isa AbstractDict && get(cp, "phase", "") == "request"
                    cp["failures"] = get(cp, "failures", 0) + 1
                    _exec!(db, "UPDATE claw_tasks SET checkpoint=? WHERE id=?", (JSON.json(cp), t.id))
                end
                if _or_nothing(t.progress) !== nothing
                    c = _fetch_one(db, "SELECT * FROM claw_conversations WHERE id=?", (t.conversation_id,))
                    _entry!(db, h, seq, c, []; run = _or_nothing(t.run_id), task = t.id, audit = JSON.parse(t.progress), stop = "interrupted")
                end
            elseif t.kind == "tool"
                e = _fetch_one(db, "SELECT * FROM claw_tool_executions WHERE task_id=?", (t.id,))
                if e !== nothing && e.effect_state == "executing"
                    manifest = JSON.parse(e.manifest)
                    state = manifest["replay"] == "safe" ? "ready" : "uncertain"
                    _exec!(db, "UPDATE claw_tool_executions SET effect_state=? WHERE task_id=?", (state, t.id))
                end
            end
            _exec!(db, "UPDATE claw_tasks SET status='pending',token=NULL,revision=revision+1,progress=NULL WHERE id=?", (t.id,))
        end
        _exec!(db, "UPDATE claw_managed_resources SET state='interrupted' WHERE state='running'")
        _exec!(
            db, raw"""UPDATE claw_evals SET status='running',failure_class=NULL,finished_at=NULL WHERE id IN
            (SELECT json_extract(input_json,'$.supervision.eval_id') FROM claw_tasks WHERE kind='generation' AND status!='terminal')"""
        )
        _reconcile_ownership!(db, h, seq)
    end
end

function _block_invocation!(ctx, reason; recheck_s = BLOCKED_RECHECK_S)
    h = ctx.harness
    _transition!(h; context = ctx, point = :blocked) do db, seq
        _exec!(db, "UPDATE claw_tasks SET status='pending',token=NULL,blocked=?,due_at=? WHERE id=?", (reason, h.clock() + recheck_s, ctx.task_id))
    end
    return nothing
end

# Registrations and resolutions can unblock work immediately, without waiting
# out the recheck delay.
function _recheck_blocked!(h)
    h.state === :open || return nothing
    # An uncertain effect waits for its reconcile backoff or an operator.
    _transition!(h; point = :recheck_blocked) do db, seq
        _exec!(db, "UPDATE claw_tasks SET due_at=0 WHERE status='pending' AND blocked IS NOT NULL AND blocked NOT LIKE 'uncertain%'")
    end
    return nothing
end

function _eligibility(h, t)
    t.version == 1 && t.codec == 1 || return nothing, "unsupported task definition or codec version"
    t.kind in ("generation", "compaction", "filter", "watcher", "tool", "delivery", "child") || return nothing, "unknown task definition $(t.kind)"
    cp = try
        JSON.parse(t.checkpoint)
    catch
        return nothing, "corrupt task checkpoint"
    end
    input = try
        JSON.parse(t.input_json)
    catch
        return nothing, "corrupt task input"
    end
    cp isa AbstractDict || return nothing, "corrupt task checkpoint"
    input isa AbstractDict || return nothing, "corrupt task input"
    t.kind == "watcher" && _watcher_expired!(h, t) && return (;), nothing
    if t.kind == "delivery"
        o = _on_writer(db -> _fetch_one(db, "SELECT * FROM claw_outbox WHERE id=?", (get(input, "outbox", ""),)), h)
        o === nothing && return nothing, "missing outbox intent"
        a = JSON.parse(o.address)
        adapter = lock(() -> get(h.adapters, a["adapter"], nothing), h.lock)
        adapter === nothing && return nothing, "delivery adapter unavailable"
        adapter.version == a["version"] || return nothing, "delivery version incompatible"
        String(adapter.capability) == get(a, "capability", "unsafe") || return nothing, "delivery capability incompatible"
        o.state == "sent" && return (;), nothing
        o.state == "redacted" && return nothing, "redacted delivery"
        available = try
            adapter.available(a["routing"])
        catch err
            return nothing, "delivery source/credentials unavailable: " * _diagnostic(h, err)
        end
        available || return nothing, "delivery source/credentials unavailable"
        o.state == "uncertain" && adapter.capability == :unsafe && return nothing, "uncertain delivery"
        return (;), nothing
    end
    resolved, reason = _resolve_profile(h, get(input, "profile", ""))
    reason === nothing || return nothing, reason
    if t.kind == "tool"
        e = _on_writer(db -> _fetch_one(db, "SELECT * FROM claw_tool_executions WHERE task_id=?", (t.id,)), h)
        e === nothing && return nothing, "missing tool intent"
        manifest = JSON.parse(e.manifest)
        spec = get(h.specs, (e.tool_name, manifest["version"]), nothing)
        spec === nothing && return nothing, "tool version unavailable"
        e.effect_state == "uncertain" && spec.reconcile === nothing && return nothing, "uncertain effect: $(e.effect_key)"
        if haskey(cp, "after")
            # A dependency, not a block: the predecessor's commit wakes us.
            previous = _task_row(h, cp["after"])
            previous.status == "terminal" || return nothing, :waiting
        end
    end
    return resolved, nothing
end

function _reserve!(h, t)
    lock(() -> haskey(h.live, t.id), h.lock) && return nothing
    group = t.kind in ("tool", "delivery") ? :tool : t.kind in ("generation", "compaction", "filter", "watcher") && get(JSON.parse(t.checkpoint), "phase", "") == "request" ? :model : :local
    t.kind == "watcher" && _watcher_expired!(h, t) && (group = :local)
    active = lock(() -> count(x -> x.group == group, values(h.live)), h.lock)
    group == :model && active >= h.limits.models && return nothing
    group == :tool && active >= h.limits.tools && return nothing
    token = _new_id()
    revision = _transition!(h; point = :reserve) do db, seq
        _exec!(
            db, "UPDATE claw_tasks SET status='running',epoch=?,token=?,revision=revision+1,blocked=NULL WHERE id=? AND status='pending' AND revision=? AND cancel=0",
            (h.epoch, token, t.id, t.revision)
        )
        Int(_scalar(db, "SELECT changes()")) == 1 || throw(StaleInvocation())
        Int(t.revision) + 1
    end
    timeout = group == :tool ? h.limits.tool_timeout : h.limits.request_timeout
    issued = JSON.parse(t.input_json)
    run_key = "deadline:" * something(_or_nothing(t.run_id), t.id)
    maximum = t.kind == "watcher" ? get(issued, "timeout", h.limits.request_timeout) : h.limits.run_timeout
    end_at = _deadline_timer!(h, run_key, get(issued, "deadline", h.clock() + timeout), maximum)
    remaining = min(timeout, max(0, end_at - _monotonic_s()))
    ctx = InvocationContext(
        h, t.id, h.epoch, token, Ref(revision), Agentif.Abort(), h.clock() + remaining, _monotonic_s() + remaining,
        ReentrantLock(), Ref(-Inf), Ref(_monotonic_s())
    )
    return ctx, group
end

function _phase_fault!(ctx, error)
    h = ctx.harness
    h.state in (:open, :closing) || return
    return _transition!(h; point = :phase_fault) do db, seq
        t = _fetch_one(db, "SELECT * FROM claw_tasks WHERE id=?", (ctx.task_id,))
        t.status == "running" && t.token == ctx.token || return
        if t.cancel == 1
            _settle_cancelled!(db, h, seq, t)
        elseif t.kind == "tool"
            _exec!(db, "UPDATE claw_tool_executions SET effect_state='uncertain' WHERE task_id=? AND effect_state='executing'", (t.id,))
            _exec!(db, "UPDATE claw_tasks SET status='pending',token=NULL,blocked=? WHERE id=?", ("uncertain effect: " * _diagnostic(h, error), t.id))
        elseif t.kind == "generation"
            _exec!(db, "UPDATE claw_task_attempts SET unknown_spend=1,ended_seq=?,failure='phase_fault' WHERE task_id=? AND ended_seq IS NULL", (seq, t.id))
            c = _fetch_one(db, "SELECT * FROM claw_conversations WHERE id=?", (t.conversation_id,))
            _generation_settle!(db, h, seq, t, c; reason = "phase_fault", audit = Dict("error" => _diagnostic(h, error)))
        elseif t.kind == "delivery"
            id = JSON.parse(t.input_json)["outbox"]
            _exec!(db, "UPDATE claw_outbox SET state='uncertain',error=? WHERE id=?", (_diagnostic(h, error), id))
            _exec!(
                db, "UPDATE claw_tasks SET status='pending',token=NULL,blocked='uncertain delivery',due_at=? WHERE id=?",
                (h.clock() + min(h.limits.retry_delays[1], h.limits.max_retry_delay), t.id)
            )
        elseif t.kind == "watcher"
            _watcher_settle!(db, h, seq, t, nothing)
        else
            _exec!(db, "UPDATE claw_task_attempts SET unknown_spend=1,ended_seq=?,failure='phase_fault' WHERE task_id=? AND ended_seq IS NULL", (seq, t.id))
            _finish_task!(db, t, Dict("status" => "faulted", "error" => _diagnostic(h, error)))
        end
    end
end

function _child_phase!(ctx, t)
    h = ctx.harness
    cp = JSON.parse(t.checkpoint)
    return _transition!(h; context = ctx, point = :child_join) do db, seq
        s = _fetch_one(db, "SELECT * FROM claw_submissions WHERE id=?", (cp["submission"],))
        if s.state in ("queued", "placed")
            # Wait on the run that answers the submission, or on the child run
            # still ahead of it in the queue; never poll.
            run = _or_nothing(s.run_id) === nothing ? nothing : _fetch_one(db, "SELECT task_id FROM claw_runs WHERE id=?", (s.run_id,))
            ahead = run !== nothing ? nothing : _fetch_one(db, "SELECT id FROM claw_tasks WHERE conversation_id=? AND kind='generation' AND status!='terminal' LIMIT 1", (s.conversation_id,))
            if run !== nothing
                _wait_tasks!(db, t.id, [run.task_id])
            elseif ahead !== nothing
                _wait_tasks!(db, t.id, [ahead.id])
            else
                _exec!(db, "UPDATE claw_tasks SET status='pending',token=NULL,due_at=? WHERE id=?", (h.clock() + 0.25, t.id))
            end
            return
        end
        status = s.state == "answered" ? "completed" : "failed"
        _finish_task!(db, t, Dict("status" => status, "submission" => s.id, "entry" => _or_nothing(s.answer_entry)))
        issued = JSON.parse(t.input_json)
        event_type = get(issued, "event_type", nothing)
        if event_type !== nothing
            address = Dict(
                "adapter" => "claw-child-event", "version" => 1, "capability" => "idempotent",
                "routing" => Dict("event_type" => event_type, "name" => issued["name"])
            )
            answer = _or_nothing(s.answer_entry)
            body = answer === nothing ? JSON.json(Dict("submission" => s.id, "state" => s.state)) :
                join(Agentif.message_text.(JSON.parse(_fetch_one(db, "SELECT entry FROM session_entries WHERE entry_id=?", (answer,)).entry, Agentif.SessionEntry).messages), "\n")
            _enqueue_delivery!(db, seq, t.conversation_id, "child-completion:$(t.id)", JSON.json(address), body; entry = answer)
        end
    end
end

function _invoke_phase!(ctx, resolved)
    h = ctx.harness
    return try
        t = _task_row(h, ctx.task_id)
        t.kind == "generation" ? _generation_phase!(ctx, t, resolved) :
            t.kind == "compaction" ? _model_request!(ctx, t, resolved; summary = true) :
            t.kind in ("filter", "watcher") ? _model_request!(ctx, t, resolved; purpose = true) :
            t.kind == "tool" ? _tool_phase!(ctx, t, resolved) :
            t.kind == "delivery" ? _delivery_phase!(ctx, t) : _child_phase!(ctx, t)
        current = _task_row(h, t.id)
        current.status == "running" && current.token == ctx.token && error("phase returned without checkpoint, wait, or outcome")
    catch err
        if err isa StaleInvocation
            _release_if_owned!(ctx)
        elseif h.state !== :poisoned
            try
                _phase_fault!(ctx, err)
            catch
                h.state = :poisoned
            end
        end
    finally
        lock(h.lock) do
            current = get(h.live, ctx.task_id, nothing)
            current === nothing || current.context !== ctx || delete!(h.live, ctx.task_id)
        end
        notify(h.wake)
    end
end

# A phase can lose a compare-and-swap inside its own transition (for example a
# context revision that moved). If the fence still holds, the task goes back to
# pending instead of staying `running` with no worker until the next restart.
function _release_if_owned!(ctx)
    h = ctx.harness
    h.state === :open || return nothing
    try
        _transition!(h; context = ctx, point = :release) do db, seq
            _exec!(db, "UPDATE claw_tasks SET status='pending',token=NULL,due_at=? WHERE id=?", (h.clock() + 0.1, ctx.task_id))
        end
    catch err
        err isa StaleInvocation || rethrow()
    end
    return nothing
end

function _deadline_timer!(h, key, due, maximum_delay)
    wall = Float64(due)
    return lock(h.lock) do
        saved = get(h.due_timers, key, nothing)
        if saved === nothing || saved[1] != wall
            saved = (wall, _monotonic_s() + clamp(wall - h.clock(), 0, maximum_delay))
            h.due_timers[key] = saved
        end
        saved[2]
    end
end
function _is_due!(h, key, due)
    end_at = _deadline_timer!(h, key, due, h.limits.max_retry_delay)
    # UTC is the restart record; a live monotonic timer prevents a wall-clock
    # correction from extending a retry indefinitely. Overdue timers run now.
    return h.clock() >= due || _monotonic_s() >= end_at
end
function _watcher_expired!(h, t)
    issued = JSON.parse(t.input_json)
    due = get(issued, "deadline", Inf)
    return _monotonic_s() >= _deadline_timer!(h, "deadline:" * t.id, due, get(issued, "timeout", h.limits.request_timeout))
end

function _ownership_ready(db, h)
    live = lock(() -> collect(keys(h.live)), h.lock)
    for t in _fetch_all(db, "SELECT id,status,cancel FROM claw_tasks WHERE status IN ('waiting','completing') OR (cancel=1 AND status!='terminal')")
        t.cancel == 1 && t.status != "completing" && !(t.id in live) && return true
        if t.status == "completing"
            _fetch_one(db, "SELECT id FROM claw_tasks WHERE owner_task=? AND background=0 AND status!='terminal' LIMIT 1", (t.id,)) === nothing && return true
        elseif t.status == "waiting"
            waits = _fetch_all(db, "SELECT t.status FROM claw_task_waits w JOIN claw_tasks t ON t.id=w.awaited WHERE w.waiter=?", (t.id,))
            all(w -> w.status == "terminal", waits) && return true
        end
    end
    return false
end

# A blocked task is re-checked after this delay, or sooner when a registration
# or resolution wakes the scheduler; it never re-runs on every tick.
const BLOCKED_RECHECK_S = 30.0

function _scheduler_tick!(h)
    _start_runs!(h)
    _monotonic_s() >= h.supervision_due && _supervise_durable!(h)
    needs_join = _on_writer(db -> _ownership_ready(db, h), h)
    needs_dispatch = _on_writer(
        db -> _fetch_one(
            db, """SELECT e.id FROM claw_events e WHERE e.status='dispatched' AND NOT EXISTS
            (SELECT 1 FROM claw_dispatch_members m JOIN claw_event_dispatches d ON d.id=m.dispatch_id
             LEFT JOIN claw_submissions s ON s.id=d.submission_id WHERE m.event_id=e.id AND d.result IS NULL
             AND (s.state IS NULL OR s.state NOT IN ('answered','unanswered','withdrawn'))) LIMIT 1"""
        ), h
    )
    if needs_join || needs_dispatch !== nothing
        _transition!(h; point = :joins) do db, seq
            _reconcile_ownership!(db, h, seq)
            _aggregate_dispatches!(db, h)
        end
    end
    tasks = _on_writer(db -> _fetch_all(db, "SELECT * FROM claw_tasks WHERE status='pending' AND cancel=0 ORDER BY created_seq,rowid"), h)
    if length(h.due_timers) > 256
        ongoing = _on_writer(db -> _fetch_all(db, "SELECT id,run_id FROM claw_tasks WHERE status!='terminal'"), h)
        keep = Set{String}()
        for t in ongoing
            push!(keep, t.id, "deadline:" * something(_or_nothing(t.run_id), t.id), "supervision:" * t.id, "abort:" * t.id)
        end
        lock(h.lock) do
            filter!(p -> p.first in keep, h.due_timers)
        end
    end
    for t in tasks
        h.state === :open || break
        _is_due!(h, t.id, t.due_at) || continue
        resolved, reason = _eligibility(h, t)
        reason === :waiting && continue
        if reason !== nothing
            _transition!(h; point = :compatibility) do db, seq
                _exec!(
                    db, "UPDATE claw_tasks SET blocked=?,due_at=? WHERE id=? AND status='pending' AND revision=?",
                    (reason, h.clock() + BLOCKED_RECHECK_S, t.id, t.revision)
                )
            end
            continue
        end
        reserved = _reserve!(h, t)
        reserved === nothing && continue
        ctx, group = reserved
        # Register before spawning: the worker removes its own entry when done.
        lock(h.lock) do
            h.live[t.id] = (; context = ctx, group)
        end
        errormonitor(Threads.@spawn _invoke_phase!(ctx, resolved))
    end
    for live in lock(() -> collect(values(h.live)), h.lock)
        _monotonic_s() > live.context.monotonic_deadline && Agentif.abort!(live.context.abort)
    end
    if h.assistant !== nothing && (h.indexer === nothing || istaskdone(h.indexer))
        job = _on_writer(db -> _fetch_one(db, "SELECT entry_id FROM claw_index_jobs WHERE state IN ('pending','redacted') AND due_at<=? LIMIT 1", (h.clock(),)), h)
        job === nothing || (h.indexer = errormonitor(Threads.@spawn drain_index_jobs!(h)))
    end
    return nothing
end

# Seconds until the next time-based event: a future task due time, a live
# deadline, the next supervision pass or a deferred index job. Work that is due
# now but waiting for capacity is started by the wake that frees the capacity;
# a one-second ceiling bounds anything a wake could miss.
function _next_wakeup_s(h)
    now = h.clock()
    due = _on_writer(h) do db
        tasks = _scalar(db, "SELECT MIN(due_at) FROM claw_tasks WHERE status='pending' AND cancel=0 AND due_at>?", (now,))
        index = _scalar(db, "SELECT MIN(due_at) FROM claw_index_jobs WHERE state IN ('pending','redacted') AND due_at>?", (now,))
        minimum(x -> x === missing || x === nothing ? Inf : Float64(x), (tasks, index))
    end
    delay = min(1.0, due - now, h.supervision_due - _monotonic_s())
    for live in lock(() -> collect(values(h.live)), h.lock)
        delay = min(delay, live.context.monotonic_deadline - _monotonic_s())
    end
    return max(0.0, delay)
end

function _scheduler_loop(h)
    while h.state === :open
        try
            _scheduler_tick!(h)
        catch err
            # A commit whose outcome is unknown already poisoned the harness
            # inside `_transition!`. Anything else is logged and retried.
            h.state === :open || break
            err isa StaleInvocation || @error "durable scheduler tick failed; retrying" error = _diagnostic(h, err)
            sleep(1.0)
            continue
        end
        delay = try
            _next_wakeup_s(h)
        catch
            1.0
        end
        delay > 0 || continue
        timer = Timer(_ -> notify(h.wake), delay)
        try
            wait(h.wake)
        finally
            close(timer)
        end
    end
    return nothing
end

function resume!(h::Harness)
    h.state === :open || error("cannot resume a closed or poisoned harness")
    lock(h.lock) do
        if h.scheduler === nothing || istaskdone(h.scheduler)
            h.scheduler = errormonitor(Threads.@spawn _scheduler_loop(h))
        end
    end
    notify(h.wake)
    return h
end
