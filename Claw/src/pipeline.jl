# pipeline.jl — durable event pipeline (hardening §1.1–§1.6)
#
# Ingestion is persist-then-dispatch: a source INSERTs the event into `claw_events`
# (UNIQUE dedup_key makes redelivery a no-op) and only then `put!`s the rowid on the
# in-memory channel, purely as a wakeup. The dispatcher claims work with a
# conditional UPDATE; a claim that updates zero rows means someone else took it.
# Crash recovery and stuck-worker recovery are the same rule: re-enqueue rows that
# are `pending`, or `running` with an expired lease.

# ─── Per-event metadata hooks ───

"""
    event_source_tag(ev::Event) -> String

The `source` column for this event, and the key `rehydrate_event` dispatches on.
Extensions override this for their own event types.
"""
event_source_tag(::Event) = "claw"

"""
    event_lane(ev::Event) -> String

Serialization key (§1.4). Channel events serialize per conversation, Tempus jobs
share `"cron"`, async completions share `"async"`.
"""
event_lane(ev::Event) = ev isa ChannelEvent ? Agentif.channel_id(get_channel(ev)) : "default"
event_lane(::TempusJobEvent) = "cron"

"""
    event_extra(ev::Event) -> Dict{String, Any}

Extra JSON-serializable fields persisted alongside the event. Purely informational
for replay (the handler only ever sees name/content/channel), but it is what an
operator reads out of `claw_events` when something goes wrong.
"""
event_extra(::Event) = Dict{String, Any}()

"""
    event_dedup_key(ev::Event) -> Union{Nothing, String}

Source-provided delivery id. `nothing` means "never deduped" (SQLite allows many
NULLs in a UNIQUE column), which is correct for locally-generated events.
"""
event_dedup_key(::Event) = nothing

# ─── Persisted row + rehydration (§1.2) ───

"""
    EventRow

A persisted `claw_events` row, handed to `rehydrate_event`. Carries the assistant
so a rehydrator can resolve the live channel registry populated by `start!`.
"""
struct EventRow
    id::Int
    source::String
    name::String
    dedup_key::Union{Nothing, String}
    channel_id::Union{Nothing, String}
    content::String
    extra::Dict{String, Any}
    lane::String
    attempts::Int
    assistant::Any    # AgentAssistant; untyped to keep this file include-order free
    claim_token::Union{Nothing,String}
    claim_revision::Int
    owner_epoch::Int
end

EventRow(id,source,name,dedup_key,channel_id,content,extra,lane,attempts,assistant) =
    EventRow(id,source,name,dedup_key,channel_id,content,extra,lane,attempts,assistant,nothing,0,0)

# A `ChannelEvent` carries a *live* channel object holding a platform client; that
# cannot be serialized and rehydrated after a restart. What a handler actually
# consumes is only `get_name`, `event_content` and (for channel events)
# `get_channel`, so replay reconstructs exactly that much. Rehydrated channels have
# lost their streaming/thread context, so replayed responses go out via
# `send_message` rather than being streamed.

struct ReplayedEvent <: Event
    name::String
    content::String
end
get_name(ev::ReplayedEvent) = ev.name
event_content(ev::ReplayedEvent) = ev.content

struct ReplayedChannelEvent <: ChannelEvent
    name::String
    content::String
    channel::Agentif.AbstractChannel
end
get_name(ev::ReplayedChannelEvent) = ev.name
event_content(ev::ReplayedChannelEvent) = ev.content
get_channel(ev::ReplayedChannelEvent) = ev.channel

const EVENT_REHYDRATORS = Dict{String, Function}()
const EVENT_REHYDRATORS_LOCK = ReentrantLock()

"""
    register_rehydrator!(source_tag::String, f)

Register the replay hook for a source. `f(row::EventRow)` returns an `Event` or
`nothing`; returning `nothing` leaves the row `pending` rather than dropping it.
"""
function register_rehydrator!(source_tag::String, f::Function)
    lock(EVENT_REHYDRATORS_LOCK) do
        EVENT_REHYDRATORS[source_tag] = f
    end
    assistant = CURRENT_ASSISTANT[]
    if assistant !== nothing && assistant._state[] === :running
        _rehydration_ready!(assistant)
    end
    return f
end

"""
    channel_lookup_rehydrator(row::EventRow) -> Union{Nothing, Event}

Default replay for channel-backed sources: look the channel up in the assistant's
live registry by `channel_id`. Sources that can rebuild a channel from their own
client should register something better.
"""
function channel_lookup_rehydrator(row::EventRow)
    cid = row.channel_id
    cid === nothing && return ReplayedEvent(row.name, row.content)
    ch = _channel_get(row.assistant, cid)
    ch === nothing && return nothing
    return ReplayedChannelEvent(row.name, row.content, ch)
end

"""
    rehydrate_event(source_tag::String, row::EventRow) -> Union{Nothing, Event}

Reconstruct a persisted event. Unregistered sources return `nothing` and log: the
row stays `pending` until the owning source is registered. A registered rehydrator
that throws propagates to the pipeline retry ladder.
"""
function rehydrate_event(source_tag::String, row::EventRow)
    f = lock(EVENT_REHYDRATORS_LOCK) do
        get(EVENT_REHYDRATORS, source_tag, nothing)
    end
    if f === nothing
        @warn "Claw: no rehydrator registered for event source; leaving event pending" source = source_tag event_id = row.id event_name = row.name maxlog = 20
        return nothing
    end
    return f(row)
end

# Built-in sources. Channel-backed replay for the REPL rebuilds a fresh stdout
# channel (the original one's completion Event died with the process).
function _register_builtin_rehydrators!()
    register_rehydrator!("repl", row -> ReplInputEvent(row.content, ReplChannel()))
    register_rehydrator!("tempus", row -> TempusJobEvent(row.name))
    register_rehydrator!("llmtools", _rehydrate_llmtools_event)
    register_rehydrator!("claw", channel_lookup_rehydrator)
    return nothing
end

# ─── Failure classification (§1.3) ───
#
# `_unwrap_error` and `classify_eval_failure` are shared with watcher
# supervision and are defined in `watcher.jl`.

"""
    _retry_decision(cfg, class, attempts) -> (Symbol, Float64)

Pure policy table from §1.3. `attempts` is the post-increment attempt count.
Returns `(:pending | :retry | :dead, delay_s)`.
"""
function _retry_decision(cfg::PipelineConfig, class::Symbol, attempts::Int)
    class === :aborted && return (:pending, 0.0)
    (class === :auth || class === :billing || class === :off_track ||
        class === :unsafe_to_retry) &&
        return (:dead, 0.0)
    max_attempts = class in (:unknown, :stalled, :overrun) ?
        cfg.unknown_max_attempts :
        cfg.max_attempts
    attempts >= max_attempts && return (:dead, 0.0)
    isempty(cfg.retry_backoff_s) && return (:dead, 0.0)
    idx = min(max(attempts, 1), length(cfg.retry_backoff_s))
    return (:retry, max(cfg.retry_backoff_s[idx], cfg.min_refire_gap_s))
end

# ─── EventSource lifecycle hooks ───

"""
    validate_source(es::EventSource)

Validate configuration before anything is started. Throwing here marks the source
unusable but never aborts `init!` or the other sources. Default: no-op.
"""
validate_source(::EventSource) = nothing

"""
    is_healthy(es::EventSource) -> Bool

Polled every `source_health_interval_s`; `false` restarts the source under the same
restart budget as a crash. Default: `true`.
"""
is_healthy(::EventSource) = true

"""
    stop!(es::EventSource)

Best-effort request to stop a running source, used by health-restart and shutdown.
Default: no-op.
"""
stop!(::EventSource) = nothing

# ─── JSON payload helpers ───

struct EventPayloadError <: Exception
    detail::String
end
Base.showerror(io::IO, err::EventPayloadError) =
    print(io, "invalid persisted event payload: ", err.detail)

function _encode_payload(channel_id, content::String, extra::Dict{String, Any})
    return JSON.json(Dict{String, Any}(
        "channel_id" => channel_id,
        "content" => content,
        "extra" => extra,
    ))
end

function _decode_payload(payload::AbstractString)
    parsed = try
        JSON.parse(payload)
    catch e
        throw(EventPayloadError(sprint(showerror, e)))
    end
    parsed isa AbstractDict || throw(EventPayloadError("top-level value is not an object"))
    raw_cid = get(() -> nothing, parsed, "channel_id")
    cid = if raw_cid === nothing || raw_cid === missing
        nothing
    elseif raw_cid isa AbstractString
        String(raw_cid)
    else
        throw(EventPayloadError("channel_id is not a string or null"))
    end
    raw_content = get(() -> "", parsed, "content")
    content = if raw_content === nothing
        ""
    elseif raw_content isa AbstractString
        String(raw_content)
    else
        throw(EventPayloadError("content is not a string or null"))
    end
    raw_extra = get(() -> nothing, parsed, "extra")
    extra = Dict{String, Any}()
    if raw_extra isa AbstractDict
        for (k, v) in raw_extra
            extra[String(k)] = v
        end
    elseif raw_extra !== nothing
        throw(EventPayloadError("extra is not an object or null"))
    end
    return (cid, content, extra)
end

_sqlite_str(x) = (x === missing || x === nothing) ? nothing : String(x)

# Always iterate a query to exhaustion: an unconsumed cursor keeps its statement in
# progress, which holds locks and makes `BEGIN IMMEDIATE` fail on that connection.
function _scalar(db::SQLite.DB, sql::AbstractString, params = ())
    value = nothing
    for row in SQLite.DBInterface.execute(db, sql, params)
        value = row[1]
    end
    return value
end

# ─── Journal (§1.6) ───

function _journal_source!(assistant::AgentAssistant, tag::AbstractString, action::AbstractString, detail = nothing)
    try
        execute_write(assistant._writer,
            "INSERT INTO claw_source_journal (ts, source, action, detail) VALUES (?, ?, ?, ?)",
            (time(), String(tag), String(action), detail === nothing ? nothing : first(String(detail), 2000)))
    catch e
        @debug "Claw: failed to journal source event" tag action exception = (e,)
    end
    return nothing
end

# ─── Ingestion (§1.1) ───

"""
    submit_event!(assistant, ev; source, dedup_key, lane) -> Union{Nothing, Int}

Persist-then-dispatch. Returns the new rowid, or `nothing` when the event was a
duplicate delivery (UNIQUE `dedup_key` collision). Preparation and persistence
failures throw so an upstream source does not acknowledge an event that Claw lost.

Sources must call this *before* acknowledging upstream — that ordering is the
single change that converts the pipeline from at-most-once to at-least-once.
"""
function submit_event!(assistant::AgentAssistant, ev::Event;
        source::AbstractString = event_source_tag(ev),
        dedup_key::Union{Nothing, AbstractString} = event_dedup_key(ev),
        lane::Union{Nothing, AbstractString} = nothing,
    )
    h=assistant._harness[]
    h===nothing || h.state===:open || throw(HarnessPoisoned())
    assistant._state[] in (:stopping, :stopped) &&
        error("Claw: cannot persist event while the pipeline is $(assistant._state[])")
    name = try
        get_name(ev)
    catch e
        @error "Claw: event rejected; get_name failed" event_type = typeof(ev) exception = (e, catch_backtrace())
        rethrow()
    end
    cid = nothing
    if ev isa ChannelEvent
        cid = try
            Agentif.channel_id(get_channel(ev))
        catch e
            @error "Claw: event rejected; get_channel failed" event_name = name exception = (e, catch_backtrace())
            rethrow()
        end
    end
    content = try
        event_content(ev)
    catch e
        @error "Claw: event rejected; content failed to render" event_name = name exception = (e, catch_backtrace())
        rethrow()
    end
    extra = try
        event_extra(ev)
    catch e
        @error "Claw: event rejected; metadata failed to render" event_name = name exception = (e, catch_backtrace())
        rethrow()
    end
    lane_key = lane === nothing ? event_lane(ev) : String(lane)
    payload = _encode_payload(cid, String(content), extra)
    dk = dedup_key === nothing ? nothing : String(dedup_key)
    now = time()

    id = try
        execute_write(assistant._writer) do db
            _with_busy_retry() do
                _exec!(db, """
                    INSERT OR IGNORE INTO claw_events
                        (dedup_key, source, name, payload, status, attempts, lane, created_at, next_attempt_at,durable)
                    VALUES (?, ?, ?, ?, 'pending', 0, ?, ?, ?,?)
                """, (dk, String(source), name, payload, lane_key, now, now,Int(h!==nothing)))
                Int(_scalar(db, "SELECT changes()")) == 0 && return nothing
                return Int(_scalar(db, "SELECT last_insert_rowid()"))
            end
        end
    catch e
        @error "Claw: failed to persist event" event_name = name exception = (e, catch_backtrace())
        rethrow()
    end

    if id === nothing
        @info "Claw: duplicate delivery ignored" event_name = name dedup_key = dk
        return nothing
    end

    lock(assistant._live_lock) do
        assistant._live_events[id] = ev
    end
    _wake!(assistant, id)
    return id
end

# The in-memory channel carries rowids only, as a wakeup. `_pending_wakeups` keeps
# the recovery scanner from double-enqueueing something already in a lane queue.
function _wake!(assistant::AgentAssistant, id::Int)
    fresh = lock(assistant._wakeup_lock) do
        id in assistant._pending_wakeups && return false
        push!(assistant._pending_wakeups, id)
        return true
    end
    fresh || return false
    try
        put!(assistant.event_queue, id)
        return true
    catch
        lock(assistant._wakeup_lock) do
            delete!(assistant._pending_wakeups, id)
        end
        @debug "Claw: wakeup channel closed; event stays pending" event_id = id
        return false
    end
end

_clear_wakeup!(assistant::AgentAssistant, id::Int) =
    lock(assistant._wakeup_lock) do
        delete!(assistant._pending_wakeups, id)
    end

_forget_live_event!(assistant::AgentAssistant, id::Int) =
    lock(assistant._live_lock) do
        Base.delete!(assistant._live_events, id)
    end

# ─── Claim / finish (§1.1) ───

# Real transactions are only safe on a connection nobody else holds a cursor on —
# that is exactly what the dedicated writer connection buys. When the writer had to
# share the caller's handle (`:memory:`), skip the explicit transaction: the writer
# task still serializes claw_events writes against each other.
function _writer_txn(f::Function, assistant::AgentAssistant)
    return execute_write(assistant._writer) do db
        assistant._writer.owns_db || return f(db)
        _with_busy_retry() do
            _exec!(db, "BEGIN IMMEDIATE")
            try
                result = f(db)
                _exec!(db, "COMMIT")
                return result
            catch
                try
                    _exec!(db, "ROLLBACK")
                catch
                end
                rethrow()
            end
        end
    end
end

"""
    _claim_event!(assistant, id; batch = nothing) -> Union{Nothing, EventRow}

Conditional claim. `nothing` means the row was not `pending` — another worker took
it, or it already finished. A row claimed for the first time joins `batch`, the
group it runs with from now on (see `_process_event_batch!`).
"""
function _claim_event!(assistant::AgentAssistant, id::Int; batch::Union{Nothing, Int} = nothing)
    lease = time() + assistant.pipeline.lease_duration_s
    token = _did()
    return _writer_txn(assistant) do db
        if assistant._harness[]===nothing
            frozen=_done(db,"SELECT event_id FROM claw_frozen_members WHERE event_id=?",(id,))
            frozen===nothing || return nothing
            mode=_done(db,"SELECT durable FROM claw_events WHERE id=?",(id,))
            mode===nothing || mode.durable==0 || return nothing
        end
        _exec!(db,
            "UPDATE claw_events SET status='running', attempts=attempts+1, lease_expires_at=?,batch=COALESCE(batch,?),claim_token=?,claim_revision=claim_revision+1,owner_epoch=?,durable=MAX(durable,?) WHERE id=? AND status='pending'",
            (lease,batch,token,assistant._owner_epoch,Int(assistant._harness[]!==nothing),id))
        Int(_scalar(db, "SELECT changes()")) == 0 && return nothing
        result = nothing
        for row in SQLite.DBInterface.execute(db,
                "SELECT id, source, name, dedup_key, payload, lane, attempts,claim_token,claim_revision,owner_epoch FROM claw_events WHERE id = ?", (id,))
            cid, content, extra = try
                _decode_payload(String(row.payload))
            catch e
                if e isa EventPayloadError
                    detail = first(sprint(showerror, e), 4000)
                    _exec!(db, """
                        UPDATE claw_events
                        SET status='dead', lease_expires_at=NULL, last_error=?
                        WHERE id=?
                    """, (detail, id))
                    @error "Claw: corrupt persisted event dead-lettered" event_id = id error = detail
                    _forget_live_event!(assistant, id)
                    return nothing
                end
                rethrow()
            end
            result = EventRow(Int(row.id), String(row.source), String(row.name), _sqlite_str(row.dedup_key),
                cid, content, extra, String(row.lane), Int(row.attempts), assistant,String(row.claim_token),Int(row.claim_revision),Int(row.owner_epoch))
        end
        return result
    end
end

# Settle a batch with one SQL UPDATE, and require every member's original fence.
# If even one token is stale, the statement changes no rows. SQL failures propagate.
_id_list(ids) = join((Int(id) for id in ids), ",")
function _fenced_events!(a,rows::AbstractVector{EventRow},assignment,params)
    isempty(rows) && throw(ArgumentError("empty event claim group"))
    length(unique(r.id for r in rows))==length(rows) || throw(ArgumentError("duplicate claim member"))
    values_sql=join(fill("(?,?,?,?)",length(rows)),",")
    values_params=Tuple(Iterators.flatten((r.id,r.claim_token,r.claim_revision,r.owner_epoch) for r in rows))
    _writer_txn(a) do db
        _exec!(db,"""WITH expected(id,token,revision,epoch) AS (VALUES $values_sql)
            UPDATE claw_events SET $assignment
            WHERE status='running' AND EXISTS(SELECT 1 FROM expected x WHERE x.id=claw_events.id
                AND x.token=claw_events.claim_token AND x.revision=claw_events.claim_revision AND x.epoch=claw_events.owner_epoch)
            AND (SELECT COUNT(*) FROM claw_events e JOIN expected x ON e.id=x.id AND e.claim_token=x.token
                AND e.claim_revision=x.revision AND e.owner_epoch=x.epoch
                WHERE e.status='running' AND e.owner_epoch=(SELECT owner_epoch FROM claw_runtime_meta WHERE id=1))=(SELECT COUNT(*) FROM expected)
        """,(values_params...,params...))
        Int(_scalar(db,"SELECT changes()"))==length(rows) || throw(StaleInvocation())
    end
    nothing
end
function _finish_event!(a::AgentAssistant,rows::AbstractVector{EventRow},status::AbstractString;
        last_error::Union{Nothing,AbstractString}=nothing,next_attempt_at::Union{Nothing,Float64}=nothing)
    _fenced_events!(a,rows,"status=?,lease_expires_at=NULL,next_attempt_at=?,last_error=COALESCE(?,last_error),claim_token=NULL,claim_revision=claim_revision+1",
        (String(status),something(next_attempt_at,time()),last_error===nothing ? nothing : first(String(last_error),4000)))
end
_finish_event!(a::AgentAssistant,row::EventRow,status::AbstractString;kw...)=_finish_event!(a,[row],status;kw...)
function _release_claim!(a::AgentAssistant,rows::AbstractVector{EventRow};delay::Float64=0.0,last_error::Union{Nothing,AbstractString}=nothing)
    _fenced_events!(a,rows,"status='pending',attempts=MAX(attempts-1,0),lease_expires_at=NULL,next_attempt_at=?,last_error=COALESCE(?,last_error),claim_token=NULL,claim_revision=claim_revision+1",
        (time()+delay,last_error===nothing ? nothing : first(String(last_error),4000)))
end
_release_claim!(a::AgentAssistant,row::EventRow;kw...)=_release_claim!(a,[row];kw...)

# ─── Dispatch ───

# Test seam (same convention as the extensions' `*_FN` refs): lets the pipeline's
# failure-injection tests drive claim/retry/lane/shutdown behavior without an LLM.
const RUN_EVENT_HANDLER_FN = Ref{Function}(_run_event_handler!)


# Enqueue under the lanes lock so a lane can never be reaped between being handed
# out and being written to. The queue is unbounded, so `put!` never blocks.
function _enqueue_lane!(assistant::AgentAssistant, key::String, id::Int)
    return lock(assistant._lanes_lock) do
        lane = get(assistant._lanes, key, nothing)
        if lane === nothing
            lane = Lane(key)
            assistant._lanes[key] = lane
            lane.task = errormonitor(Threads.@spawn _lane_loop(assistant, lane))
        end
        Threads.atomic_add!(lane.depth, 1)
        lane.last_active[] = time()
        try
            put!(lane.queue, (id, time()))
            return true
        catch
            Threads.atomic_sub!(lane.depth, 1)
            return false
        end
    end
end

# Lane keys include thread ids, so an always-on instance would otherwise accumulate
# one task and one channel per conversation it has ever seen.
function _reap_idle_lanes!(assistant::AgentAssistant)
    timeout = assistant.pipeline.lane_idle_timeout_s
    timeout <= 0 && return 0
    now = time()
    reaped = 0
    lock(assistant._lanes_lock) do
        for (key, lane) in collect(assistant._lanes)
            lane.busy[] && continue
            lane.depth[] == 0 || continue
            now - lane.last_active[] < timeout && continue
            Base.delete!(assistant._lanes, key)
            try
                isopen(lane.queue) && close(lane.queue)
            catch
            end
            reaped += 1
        end
    end
    reaped > 0 && @debug "Claw: retired idle lanes" count = reaped
    return reaped
end

function _collect_lane_batch!(assistant::AgentAssistant, lane::Lane, item)
    items = [item]
    limit = max(assistant.pipeline.max_coalesce, 1)
    # Queue time counts toward the window. A backed-up lane does not add another
    # window after a slow evaluation. New arrivals never extend the deadline.
    remaining = max(0.0, assistant.pipeline.coalesce_window_s - max(0.0, time() - item[2]))
    deadline = time_ns() + UInt64(round(Int, remaining * 1e9))
    while length(items) < limit && assistant._state[] === :running
        remaining > 0 && time_ns() >= deadline && break
        if isready(lane.queue)
            extra = try
                take!(lane.queue)
            catch
                break
            end
            Threads.atomic_sub!(lane.depth, 1)
            push!(items, extra)
        elseif time_ns() < deadline && isopen(lane.queue)
            sleep(min(0.01, max(0.0, Float64(Int128(deadline) - time_ns()) / 1e9)))
        else
            break
        end
    end
    return items
end

function _lane_loop(assistant::AgentAssistant, lane::Lane)
    Agentif.with_log_level(assistant.log_level) do
        while true
            item = try
                take!(lane.queue)
            catch
                break
            end
            Threads.atomic_sub!(lane.depth, 1)
            if assistant._state[] !== :running
                _clear_wakeup!(assistant, item[1])
                break
            end
            # Keep the lane alive while collecting. Waiting consumes neither an
            # event claim nor a model slot; only this worker consumes this queue.
            lane.busy[] = true
            waited = time() - item[2]
            items = _collect_lane_batch!(assistant, lane, item)
            if assistant._state[] !== :running
                foreach(x -> _clear_wakeup!(assistant, x[1]), items)
                lane.busy[] = false
                break
            end
            if waited > assistant.pipeline.lane_backlog_warn_s
                @warn "Claw: lane backlog" lane = lane.key wait_s = round(waited; digits = 2) queue_depth = lane.depth[] drained = length(items)
            end
            ids = [id for (id, _) in items]
            Base.acquire(assistant._sem)
            try
                _process_event_batch!(assistant, ids)
            catch e
                @error "Claw: lane worker error" lane = lane.key event_ids = ids exception = (e, catch_backtrace())
                for id in ids
                    _clear_wakeup!(assistant, id)
                end
            finally
                Base.release(assistant._sem)
                lane.last_active[] = time()
                lane.busy[] = false
            end
        end
    end
    return nothing
end

function _lane_key_for(assistant::AgentAssistant, id::Int)
    return try
        with_read(assistant._readers) do db
            lane = nothing
            for row in SQLite.DBInterface.execute(db, "SELECT lane, status FROM claw_events WHERE id = ?", (id,))
                String(row.status) == "pending" && (lane = String(row.lane))
            end
            return lane
        end
    catch e
        @error "Claw: failed to resolve event lane" event_id = id exception = (e, catch_backtrace())
        return nothing
    end
end

function _dead_letter_channel(assistant::AgentAssistant, ev::Event, handlers)
    ev isa ChannelEvent && return get_channel(ev)
    for h in handlers
        h.channel_id === nothing && continue
        ch = _channel_get(assistant, h.channel_id)
        ch === nothing && continue
        return ch
    end
    return nothing
end

function _dead_letter_notify!(assistant::AgentAssistant, id::Int, ev::Event, handlers, class::Symbol, err::AbstractString)
    assistant.pipeline.dead_letter_notify || return nothing
    ch = _dead_letter_channel(assistant, ev, handlers)
    ch === nothing && return nothing
    ch isa SinkChannel && return nothing
    msg = "I hit repeated errors handling this ($(class)); it's logged as event #$(id)."
    try
        Agentif.send_message(ch, msg)
    catch e
        @warn "Claw: failed to deliver dead-letter notice" event_id = id exception = (e,)
    end
    return nothing
end

# Rows that ran together fail together: one retry decision and one settle
# write for all of them, and a single dead-letter notice (about `ev`, the
# group's first event) rather than one per row.
function _handle_event_failure!(assistant::AgentAssistant, rows::AbstractVector{EventRow}, ev::Event, handlers, err)
    cfg = assistant.pipeline
    class = classify_eval_failure(err)
    ids = [row.id for row in rows]
    attempts = maximum(row.attempts for row in rows)
    action, delay = _retry_decision(cfg, class, attempts)
    text = string(class, ": ", first(sprint(showerror, _unwrap_error(err)), 2000))
    event_name = rows[1].name
    if action === :pending
        @info "Claw: evaluation aborted; returning event to pending" event_ids = ids event_name
        _release_claim!(assistant, rows; delay = cfg.min_refire_gap_s, last_error = text)
    elseif action === :retry
        refire = max(delay, cfg.min_refire_gap_s)
        @warn "Claw: event handling failed; scheduling retry" event_ids = ids event_name class attempts retry_in_s = round(refire; digits = 2)
        _finish_event!(assistant, rows, "pending"; last_error = text, next_attempt_at = time() + refire)
    else
        @error "Claw: event dead-lettered" event_ids = ids event_name class attempts error = text
        _finish_event!(assistant, rows, "dead"; last_error = text)
        assistant._harness[]===nothing && _dead_letter_notify!(assistant, ids[1], ev, handlers, class, text)
        foreach(id -> _forget_live_event!(assistant, id), ids)
    end
    return action
end
_handle_event_failure!(assistant::AgentAssistant, row::EventRow, ev::Event, handlers, err) =
    _handle_event_failure!(assistant, [row], ev, handlers, err)

"""
    _process_event_batch!(assistant, ids)

Claim and process one lane drain. Event ids are split into runs of consecutive
rows with the same event name and the same batch. Each run is claimed only when
the prior run is complete, so it does not spend its lease waiting for another
event type. Its events go through the group's handler filters individually, and
the survivors are folded into a single coalesced evaluation per handler.

Rows claimed together form a batch (`claw_events.batch`) and keep it. A retry
or a restart runs every pending row of the batch together again, and nothing
else with them, so each handler gets the same events and the same resume key
(`input_key` in `_process_claimed_group!`) instead of starting over.
"""
function _pending_event_group(assistant::AgentAssistant, id::Int)
    return try
        with_read(assistant._readers) do db
            group = nothing
            for row in SQLite.DBInterface.execute(db,
                    "SELECT name, status, batch FROM claw_events WHERE id = ?", (id,))
                String(row.status) == "pending" &&
                    (group = (String(row.name), row.batch === missing ? nothing : Int(row.batch)))
            end
            return group
        end
    catch e
        @error "Claw: failed to resolve event name" event_id = id exception = (e, catch_backtrace())
        return nothing
    end
end

_pending_batch_members(assistant::AgentAssistant, batch::Int) = with_read(assistant._readers) do db
    [Int(r.id) for r in SQLite.DBInterface.execute(db,
        "SELECT id FROM claw_events WHERE batch = ? AND status = 'pending' ORDER BY id", (batch,))]
end

function _process_event_run!(assistant::AgentAssistant, ids::Vector{Int}, batch::Union{Nothing, Int} = nothing)
    if assistant._state[] !== :running
        foreach(id -> _clear_wakeup!(assistant, id), ids)
        return nothing
    end
    batch === nothing || (ids = sort!(union(ids, _pending_batch_members(assistant, batch))))
    claimed = Tuple{EventRow, Event}[]
    for id in ids
        row = try
            _claim_event!(assistant, id; batch = something(batch, id))
        catch e
            @error "Claw: claim failed" event_id = id exception = (e, catch_backtrace())
            nothing
        end
        if row === nothing
            _clear_wakeup!(assistant, id)
            continue
        end
        # The first row this run claims names its batch.
        batch === nothing && (batch = row.id)

        ev = lock(assistant._live_lock) do
            get(assistant._live_events, id, nothing)
        end
        if ev === nothing
            ev = try
                rehydrate_event(row.source, row)
            catch e
                @error "Claw: rehydrate_event failed" source = row.source event_id = row.id exception = (e, catch_backtrace())
                fallback = ReplayedEvent(row.name, row.content)
                _handle_event_failure!(assistant, row, fallback, (), e)
                _clear_wakeup!(assistant, id)
                continue
            end
        end
        if ev === nothing
            # The owning source is not registered (or could not rebuild the channel).
            # Leave the row pending and try again later rather than dropping it.
            _release_claim!(assistant, row; delay = 60.0, last_error = "no rehydrator for source '$(row.source)'")
            _clear_wakeup!(assistant, id)
            continue
        end
        push!(claimed, (row, ev))
    end
    isempty(claimed) && return nothing

    if assistant._state[] !== :running
        _release_claim!(assistant, [row for (row, _) in claimed])
        foreach(((row, _),) -> _clear_wakeup!(assistant, row.id), claimed)
        _release_group_channels!(claimed, nothing)
        return nothing
    end
    _process_claimed_group!(assistant, claimed)
    return nothing
end

function _process_event_batch!(assistant::AgentAssistant, ids::Vector{Int})
    run = Int[]
    run_group = nothing
    for id in ids
        group = _pending_event_group(assistant, id)
        if group === nothing
            _clear_wakeup!(assistant, id)
            continue
        end
        if run_group !== nothing && group != run_group
            _process_event_run!(assistant, run, run_group[2])
            empty!(run)
        end
        run_group = group
        push!(run, id)
    end
    isempty(run) || _process_event_run!(assistant, run, run_group[2])
    return nothing
end

_process_event!(assistant::AgentAssistant, id::Int) = _process_event_batch!(assistant, [id])

function _process_claimed_group!(assistant::AgentAssistant, group::Vector{Tuple{EventRow, Event}})
    name = group[1][1].name
    rows = [row for (row, _) in group]
    ids = [row.id for row in rows]
    handlers = try
        _event_handlers_for(assistant, name)
    catch e
        @error "Claw: event handler lookup failed" event = name exception = (e, catch_backtrace())
        _handle_event_failure!(assistant, rows, group[1][2], (), e)
        foreach(id -> _clear_wakeup!(assistant, id), ids)
        _release_group_channels!(group, nothing)
        return nothing
    end

    if isempty(handlers) && assistant._harness[]===nothing
        @debug "Claw: no handlers for event" event_ids = ids event_name = name
        _finish_event!(assistant, rows, "done")
        foreach(id -> (_forget_live_event!(assistant, id); _clear_wakeup!(assistant, id)), ids)
        _release_group_channels!(group, nothing)
        return nothing
    end

    if assistant._harness[] !== nothing
        abort=Agentif.Abort()
        lock(assistant._inflight_lock) do
            for (row,_) in group
                assistant._inflight[row.id]=abort
            end
        end
        try
            _durable_dispatch_group!(assistant,group,handlers;abort)
        catch err
            current_rows=EventRow[]
            for (row,ev) in group
                current=with_read(assistant._readers) do db
                    _done(db,"SELECT status,claim_token FROM claw_events WHERE id=?",(row.id,))
                end
                current!==nothing && current.status=="running" && current.claim_token==row.claim_token && push!(current_rows,row)
            end
            if !isempty(current_rows)
                err isa DurableBlocked ? _release_claim!(assistant,current_rows;delay=60.0,last_error=sprint(showerror,err)) :
                    _handle_event_failure!(assistant,current_rows,group[1][2],(),err)
            end
            _release_group_channels!(group,nothing)
        finally
            lock(assistant._inflight_lock) do
                for (row,_) in group
                    delete!(assistant._inflight,row.id)
                end
            end
            for (row,_) in group
                _clear_wakeup!(assistant,row.id)
            end
        end
        return nothing
    end

    abort = Agentif.Abort()
    lock(assistant._inflight_lock) do
        for (row, _) in group
            assistant._inflight[row.id] = abort
        end
    end
    started_at = time()
    # Channels an evaluation actually streamed to; every other channel event in the
    # group is released afterwards so nothing waits on a response that will never
    # come (a coalesced member, or an event a filter rejected).
    streamed = Base.IdSet{Any}()
    handlers_finished = false
    try
        for handler in handlers
            filtered = Tuple{EventRow, Event}[]
            for (row, ev) in group
                # Filter errors (e.g. a :prompt filter that cannot reach the model)
                # propagate: the group rides the retry ladder rather than the event
                # being silently dropped or spuriously delivered.
                if passes_filter(assistant, handler, ev, row.extra)
                    push!(filtered, (row, ev))
                end
            end
            selected = _select_relevant_events!(assistant, handler, filtered, abort)
            kept = Event[ev for (_, ev) in selected]
            kept_ids = Int[row.id for (row, _) in selected]
            if isempty(kept)
                @debug "Claw: filter matched no events" handler_id = handler.id event_name = name group_size = length(group)
                continue
            end
            ev_input = length(kept) == 1 ? kept[1] : _make_event_batch(name, kept)
            @info "Claw: running handler" handler_id = handler.id event_name = name event_ids = [row.id for (row, _) in group] coalesced = length(kept)
            RUN_EVENT_HANDLER_FN[](
                assistant,
                ev_input,
                handler;
                level = assistant.log_level,
                abort,
                pipeline_managed = true,
                # Running the same events through the same handler again (after
                # a crash or a failed attempt) resumes that run from its session
                # checkpoints instead of starting it over, and skips it if it
                # already answered.
                input_key = string("claw-event:", join(kept_ids, ","), ":", handler.id),
            )
            ev_input isa ChannelEvent && push!(streamed, get_channel(ev_input))
            @info "Claw: handler completed" handler_id = handler.id event_name = name duration_s = round(time() - started_at; digits = 4)
        end
        handlers_finished = true
        _finish_event!(assistant, rows, "done")
        foreach(id -> _forget_live_event!(assistant, id), ids)
        _release_group_channels!(group, streamed)
    catch e
        if handlers_finished
            # Settlement is atomic. Keep failed writes recoverable under the
            # original claims instead of treating completed work as a failure.
            @error "Claw: completed event batch could not be finalized" event_ids = ids exception = (e, catch_backtrace())
        else
            # One handler failure selects one retry decision for the whole
            # group. A failed settlement leaves every claim for recovery.
            try
                _handle_event_failure!(assistant, rows, group[1][2], handlers, e)
            catch settle_error
                @error "Claw: failed event batch could not be settled" event_ids = ids exception = (settle_error, catch_backtrace())
            end
        end
        _release_group_channels!(group, streamed)
    finally
        lock(assistant._inflight_lock) do
            for (row, _) in group
                Base.delete!(assistant._inflight, row.id)
            end
        end
        for (row, _) in group
            _clear_wakeup!(assistant, row.id)
        end
    end
    return nothing
end

# Close channel-event channels that no evaluation streamed to (coalesced members
# and filter-rejected events). `close_channel` flushes buffered transports and
# unblocks REPL waiters; without this, `a"..."` would hang whenever its event was
# coalesced into a batch whose response streamed to a newer channel object.
function _release_group_channels!(group::Vector{Tuple{EventRow, Event}}, streamed)
    for (_, ev) in group
        ev isa ChannelEvent || continue
        ch = try
            get_channel(ev)
        catch
            continue
        end
        streamed !== nothing && ch in streamed && continue
        try
            Agentif.close_channel(ch)
        catch e
            @debug "Claw: failed to release coalesced channel" exception = (e,)
        end
    end
    return nothing
end

# Release every still-live channel event at shutdown. This covers queued rows that
# intake or a lane did not consume, retrying rows whose next attempt is in the
# future, and any straggler that ignored its abort. The durable rows stay pending;
# only their process-local response waiters are completed.
function _release_live_event_channels!(assistant::AgentAssistant)
    events = lock(assistant._live_lock) do
        result = collect(values(assistant._live_events))
        empty!(assistant._live_events)
        result
    end
    channels = Base.IdSet{Any}()
    for ev in events
        ev isa ChannelEvent || continue
        ch = try
            get_channel(ev)
        catch
            continue
        end
        ch in channels && continue
        push!(channels, ch)
        try
            Agentif.close_channel(ch)
        catch e
            @debug "Claw: failed to release live channel during shutdown" exception = (e,)
        end
    end
    lock(assistant._wakeup_lock) do
        empty!(assistant._pending_wakeups)
    end
    return nothing
end

# ─── Recovery scanner ───

"""
    _scan_due_events!(assistant) -> Int

Reclaim rows whose lease expired, then wake every `pending` row that is due. This
is crash recovery, stuck-worker recovery and retry refire in one rule.
"""
function _scan_due_events!(assistant::AgentAssistant)
    now = time()
    # The owner is still alive and owns these invocations. Stealing their lease
    # could execute an unsafe legacy tool twice; expiry is not proof of death.
    active=lock(()->Set(keys(assistant._inflight)),assistant._inflight_lock)
    try
        execute_write(assistant._writer) do db
            for row in _drows(db,"SELECT id,claim_token,claim_revision FROM claw_events WHERE status='running' AND lease_expires_at IS NOT NULL AND lease_expires_at<=?",(now,))
                row.id in active && continue
                _exec!(db,"UPDATE claw_events SET status='pending',lease_expires_at=NULL,claim_token=NULL,claim_revision=claim_revision+1 WHERE id=? AND status='running' AND claim_revision=?",
                    (row.id,row.claim_revision))
            end
        end
    catch e
        @error "Claw: lease reclaim failed" exception = (e, catch_backtrace())
        return 0
    end
    ids = try
        with_read(assistant._readers) do db
            [Int(r.id) for r in SQLite.DBInterface.execute(db,
                "SELECT id FROM claw_events WHERE status='pending' AND next_attempt_at <= ? ORDER BY id LIMIT 500", (now,))]
        end
    catch e
        @error "Claw: due-event scan failed" exception = (e, catch_backtrace())
        return 0
    end
    n = 0
    for id in ids
        _wake!(assistant, id) && (n += 1)
    end
    return n
end

function _scanner_loop(assistant::AgentAssistant)
    interval = assistant.pipeline.scan_interval_s
    while assistant._state[] === :running
        sleep(interval)
        assistant._state[] === :running || break
        try
            _scan_due_events!(assistant)
            _reap_idle_lanes!(assistant)
        catch e
            @error "Claw: recovery scanner error" exception = (e, catch_backtrace())
        end
    end
    return nothing
end

"""
    _reclaim_crashed_events!(assistant)

Boot recovery under the owner lock: every `running` row was claimed by a process
that has since died, so return it to `pending` now instead of waiting out its
lease. Its handlers resume from their session checkpoints (see `input_key` in
`_process_claimed_group!`). A row that has already used `unknown_max_attempts`
attempts (of any kind, not only crashes) is dead-lettered instead, so an event
that kills the process cannot crash-loop it. No dead-letter notice is sent for
it: channels are not available this early in `init!`.
"""
function _reclaim_crashed_events!(assistant::AgentAssistant;durable_upgrade::Bool=false)
    now = time()
    max_attempts = assistant.pipeline.unknown_max_attempts
    execute_write(assistant._writer) do db
        if durable_upgrade
            _exec!(db,"""UPDATE claw_events SET status='dead',lease_expires_at=NULL,claim_token=NULL,claim_revision=claim_revision+1,
                last_error='legacy_interrupted: prior legacy evaluation has no effect receipts; explicit new input requires effect review'
                WHERE status='running' AND durable=0 AND NOT EXISTS(SELECT 1 FROM claw_frozen_members m WHERE m.event_id=claw_events.id)""")
        end
        _exec!(db, """
            UPDATE claw_events
            SET status = 'dead', lease_expires_at = NULL,
                last_error = 'process_crash: the process stopped while handling this event, after ' ||
                    attempts || ' attempts (limit ' || ? || ')'
            WHERE status = 'running' AND attempts >= ?
        """, (max_attempts, max_attempts))
        _exec!(db, """
            UPDATE claw_events SET status = 'pending', lease_expires_at = NULL, next_attempt_at = ?,claim_token=NULL,claim_revision=claim_revision+1
            WHERE status = 'running'
        """, (now,))
        return nothing
    end
    return nothing
end

"""
    _recover_events!(assistant) -> Int

Boot recovery: re-enqueue `pending` rows and `running` rows whose lease expired.
"""
function _recover_events!(assistant::AgentAssistant)
    stats = try
        with_read(assistant._readers) do db
            pending = Int(_scalar(db, "SELECT COUNT(*) FROM claw_events WHERE status='pending'"))
            stale = Int(_scalar(db,
                "SELECT COUNT(*) FROM claw_events WHERE status='running' AND lease_expires_at IS NOT NULL AND lease_expires_at <= ?",
                (time(),)))
            held = Int(_scalar(db,
                "SELECT COUNT(*) FROM claw_events WHERE status='running' AND (lease_expires_at IS NULL OR lease_expires_at > ?)",
                (time(),)))
            (pending, stale, held)
        end
    catch e
        @error "Claw: boot recovery query failed" exception = (e, catch_backtrace())
        return 0
    end
    n = _scan_due_events!(assistant)
    if n > 0 || stats[3] > 0
        @info "Claw: recovered persisted events" pending = stats[1] expired_leases = stats[2] still_leased = stats[3] re_enqueued = n
    end
    return n
end

function _rehydration_ready!(assistant::AgentAssistant)
    # A source can only build its runtime channels after start!. Events that were
    # recovered before that point are parked with a long retry delay. Wake those
    # rows as soon as any source registers channels instead of waiting a minute.
    try
        execute_write(assistant._writer, """
            UPDATE claw_events
            SET next_attempt_at = ?
            WHERE status = 'pending' AND last_error LIKE 'no rehydrator for source %'
        """, (time(),))
        _scan_due_events!(assistant)
    catch e
        @debug "Claw: failed to wake events after channel registration" exception = (e,)
    end
    return nothing
end

# ─── Event loop ───
_lookup_event_admission(a::AgentAssistant,key::String)=with_read(db->_done(db,"SELECT id,status FROM claw_events WHERE dedup_key=?",(key,)),a._readers)

function start_event_loop!(assistant::AgentAssistant; level::Union{Nothing, LogLevel} = assistant.log_level)
    assistant._harness[]===nothing && _guard_legacy_runtime!(assistant)
    assistant._state[] = :running
    intake = errormonitor(@async begin
        Agentif.with_log_level(level) do
            @info "Claw: event loop started" level max_concurrent_evals = assistant.pipeline.max_concurrent_evals
            for id in assistant.event_queue
                assistant._state[] === :running || break
                lane_key = _lane_key_for(assistant, id)
                if lane_key === nothing
                    _clear_wakeup!(assistant, id)
                    continue
                end
                _enqueue_lane!(assistant, lane_key, id) || _clear_wakeup!(assistant, id)
            end
            @info "Claw: event loop stopped"
        end
    end)
    push!(assistant._tasks, intake)
    push!(assistant._tasks, errormonitor(Threads.@spawn _scanner_loop(assistant)))
    return intake
end

# ─── Source supervision (§1.6) ───

_source_tag(es::EventSource) = lowercase(String(nameof(typeof(es))))

function _record_restart!(assistant::AgentAssistant, ss::SupervisedSource)
    cfg = assistant.pipeline
    now = time()
    return lock(ss.lock) do
        filter!(t -> now - t < cfg.source_restart_window_s, ss.restarts)
        length(ss.restarts) >= cfg.source_restart_cap && return false
        push!(ss.restarts, now)
        return true
    end
end

function _sleep_interruptible(assistant::AgentAssistant, seconds::Real)
    deadline = time() + seconds
    while time() < deadline
        assistant._state[] === :running || return false
        sleep(min(0.25, max(0.0, deadline - time())))
    end
    return assistant._state[] === :running
end

function _retire_source!(assistant::AgentAssistant, ss::SupervisedSource)
    inner = lock(ss.lock) do
        ss.stopped[] = true
        try
            stop!(ss.source)
        catch e
            @warn "Claw: source stop! failed after restart budget exhaustion" source = ss.tag exception = (e,)
        end
        ss.inner
    end
    if inner !== nothing && !istaskdone(inner)
        result = timedwait(() -> istaskdone(inner),
            assistant.pipeline.source_stop_timeout_s; pollint = 0.05)
        result == :timed_out && @error "Claw: retired source did not stop" source = ss.tag
    end
    return nothing
end

function _supervise_source!(assistant::AgentAssistant, ss::SupervisedSource)
    backoff = assistant.pipeline.source_restart_backoff_s
    while assistant._state[] === :running && !ss.stopped[]
        started = false
        try
            result, should_start = lock(ss.lock) do
                if assistant._state[] !== :running || ss.stopped[]
                    return (nothing, false)
                end
                value = start!(ss.source, assistant)
                ss.inner = value isa Task ? value : nothing
                return (value, true)
            end
            should_start || break
            started = true
            _journal_source!(assistant, ss.tag, "started")
            if result isa Task
                wait(result)
                _journal_source!(assistant, ss.tag, "exited", "source task returned")
            else
                # Fire-and-forget start!: there is nothing to wait on, so only the
                # health poll can trigger a restart from here on.
                return nothing
            end
        catch e
            unwrapped = _unwrap_error(e)
            detail = _source_error_detail(ss.source, unwrapped)
            _journal_source!(assistant, ss.tag, started ? "crashed" : "start_failed", detail)
            @error "Claw: event source failed" source = ss.tag error = detail
        end
        (assistant._state[] === :running && !ss.stopped[]) || break
        if ss.restart_requested[]
            # Budget already charged by the health poll that asked for this restart.
            ss.restart_requested[] = false
        elseif !_record_restart!(assistant, ss)
            _journal_source!(assistant, ss.tag, "restart_cap_exceeded",
                "more than $(assistant.pipeline.source_restart_cap) restarts within $(assistant.pipeline.source_restart_window_s)s")
            @error "Claw: source exceeded its restart budget; giving up" source = ss.tag cap = assistant.pipeline.source_restart_cap
            _retire_source!(assistant, ss)
            break
        end
        _sleep_interruptible(assistant, min(backoff, 60.0)) || break
        backoff *= 2
    end
    return nothing
end

function _request_source_restart!(assistant::AgentAssistant, ss::SupervisedSource)
    inner, stopped_ok = lock(ss.lock) do
        ss.restart_requested[] = true
        try
            stop!(ss.source)
        catch e
            @warn "Claw: source stop! failed" source = ss.tag exception = (e,)
            ss.restart_requested[] = false
            return (ss.inner, false)
        end
        return (ss.inner, true)
    end
    stopped_ok || return nothing
    if inner !== nothing && !istaskdone(inner)
        result = timedwait(() -> istaskdone(inner),
            assistant.pipeline.source_stop_timeout_s; pollint = 0.05)
        if result == :timed_out
            @error "Claw: source did not stop; refusing to start a duplicate" source = ss.tag
        end
    end
    if ss.task === nothing || istaskdone(ss.task)
        ss.task = errormonitor(Threads.@spawn _supervise_source!(assistant, ss))
    end
    return nothing
end

function _health_loop(assistant::AgentAssistant)
    cfg = assistant.pipeline
    while assistant._state[] === :running
        _sleep_interruptible(assistant, cfg.source_health_interval_s) || break
        for ss in lock(() -> copy(assistant._sources), assistant._sources_lock)
            ss.stopped[] && continue
            ok = try
                is_healthy(ss.source)
            catch e
                @warn "Claw: is_healthy threw; treating source as unhealthy" source = ss.tag exception = (e,)
                false
            end
            ss.healthy[] = ok
            ok && continue
            @warn "Claw: source reported unhealthy; restarting" source = ss.tag
            _journal_source!(assistant, ss.tag, "unhealthy")
            if !_record_restart!(assistant, ss)
                _journal_source!(assistant, ss.tag, "restart_cap_exceeded", "unhealthy restart budget exhausted")
                @error "Claw: unhealthy source exceeded its restart budget; giving up" source = ss.tag
                _retire_source!(assistant, ss)
                continue
            end
            _request_source_restart!(assistant, ss)
        end
    end
    return nothing
end

function _ensure_health_loop!(assistant::AgentAssistant)
    assistant._health_loop_started[] && return nothing
    assistant._health_loop_started[] = true
    push!(assistant._tasks, errormonitor(Threads.@spawn _health_loop(assistant)))
    return nothing
end

"""
    _start_supervised_source!(assistant, es) -> SupervisedSource

Validate one source and start it in its own supervised task. A validation failure
marks it stopped but never throws — one bad source must not take down the rest.
"""
function _start_supervised_source!(assistant::AgentAssistant, es::EventSource;
        validated::Bool = false)
    tag = _source_tag(es)
    ss = SupervisedSource(es, tag)
    lock(() -> push!(assistant._sources, ss), assistant._sources_lock)
    lock(assistant._integrations_lock) do
        for state in values(assistant._integrations)
            state.source === es && (state.supervised = ss)
        end
    end
    if !validated
        try
            validate_source(es)
        catch e
            ss.stopped[] = true
            detail = _source_error_detail(es, e)
            _journal_source!(assistant, tag, "invalid_config", detail)
            @error "Claw: source configuration invalid; not started" source = tag error = detail
            _ensure_health_loop!(assistant)
            return ss
        end
    end
    ss.task = errormonitor(Threads.@spawn _supervise_source!(assistant, ss))
    _ensure_health_loop!(assistant)
    return ss
end

"""
    _stop_supervised_source!(assistant, ss)

Stop one supervised source and drop it from supervision. `stop!` must make a
task returned by `start!` finish within `source_stop_timeout_s`.
"""
function _stop_supervised_source!(assistant::AgentAssistant, ss::SupervisedSource)
    timeout = assistant.pipeline.source_stop_timeout_s
    deadline = time() + timeout
    inner = lock(ss.lock) do
        ss.stopped[] = true
        try
            stop!(ss.source)
        catch e
            @debug "Claw: source stop! failed" source = ss.tag exception = (e,)
        end
        ss.inner
    end
    if inner !== nothing && !istaskdone(inner)
        timedwait(() -> istaskdone(inner), max(0.0, deadline - time());
            pollint = 0.05)
    end
    supervisor = ss.task
    if supervisor !== nothing && !istaskdone(supervisor)
        result = timedwait(() -> istaskdone(supervisor),
            max(0.0, deadline - time()); pollint = 0.05)
        if result == :timed_out
            # The source is still live. Restore supervision so the integration
            # remains internally consistent and can be disabled again later.
            ss.stopped[] = false
            error("Source '$(ss.tag)' did not stop within $timeout seconds.")
        end
    end
    lock(assistant._sources_lock) do
        idx = findfirst(s -> s === ss, assistant._sources)
        idx === nothing || deleteat!(assistant._sources, idx)
    end
    return nothing
end

"""
    start_sources!(assistant, sources)

Validate every source up front, then start each one in its own supervised task.
One source failing must not abort `init!` or take down the others.
"""
function start_sources!(assistant::AgentAssistant, sources)
    for es in sources
        _start_supervised_source!(assistant, es)
    end
    return assistant._sources
end

function _stop_sources!(assistant::AgentAssistant)
    for ss in lock(() -> copy(assistant._sources), assistant._sources_lock)
        lock(ss.lock) do
            ss.stopped[] = true
            try
                stop!(ss.source)
            catch e
                @debug "Claw: source stop! failed during shutdown" source = ss.tag exception = (e,)
            end
        end
    end
    return nothing
end

# ─── Graceful shutdown (§1.5) ───

function _return_claims!(assistant::AgentAssistant)
    execute_write(assistant._writer, """
            UPDATE claw_events
            SET status='pending', attempts = MAX(attempts - 1, 0), lease_expires_at = NULL, next_attempt_at = ?,claim_token=NULL,claim_revision=claim_revision+1
            WHERE status='running' AND owner_epoch=?
    """, (time(),assistant._owner_epoch))
    return nothing
end

"""
    shutdown!(assistant; timeout_s = 30)

Stop intake, stop Tempus, stop sources, drain in-flight evaluations, abort the
stragglers through their `Abort` handles, return unfinished claims to `pending`,
and close the database. Idempotent; safe to call from an `atexit` hook.
"""
function shutdown!(assistant::AgentAssistant; timeout_s::Real = assistant.pipeline.shutdown_timeout_s)
    # Serialize the state transition with runtime integration changes. An enable
    # that won the lock first finishes adding its supervised source before shutdown
    # snapshots sources; one that arrives later sees :stopping and fails closed.
    first_caller = lock(assistant._integrations_lock) do
        lock(assistant._shutdown_lock) do
            assistant._state[] in (:stopping, :stopped) && return false
            assistant._state[] = :stopping
            return true
        end
    end
    if !first_caller
        timedwait(() -> assistant._state[] === :stopped, Float64(timeout_s); pollint = 0.05)
        return nothing
    end

    @info "Claw: shutdown initiated" timeout_s
    deadline = time() + timeout_s

    try
        isopen(assistant.event_queue) && close(assistant.event_queue)
    catch
    end

    if assistant._scheduler_started[]
        try
            close(assistant.scheduler; timeout = max(1.0, min(5.0, Float64(timeout_s))))
        catch e
            @warn "Claw: Tempus scheduler close failed" exception = (e,)
        end
    end

    _stop_sources!(assistant)

    lanes = lock(assistant._lanes_lock) do
        collect(values(assistant._lanes))
    end
    for lane in lanes
        try
            isopen(lane.queue) && close(lane.queue)
        catch
        end
    end

    idle = () -> lock(assistant._inflight_lock) do
        isempty(assistant._inflight)
    end
    timedwait(idle, max(0.0, deadline - time()); pollint = 0.05)

    stragglers = lock(assistant._inflight_lock) do
        collect(values(assistant._inflight))
    end
    if !isempty(stragglers)
        @warn "Claw: aborting in-flight evaluations" count = length(stragglers)
        for ab in stragglers
            try
                Agentif.abort!(ab)
            catch
            end
        end
        timedwait(idle, 5.0; pollint = 0.05)
    end

    source_tasks = Task[]
    for ss in lock(() -> copy(assistant._sources), assistant._sources_lock)
        ss.task === nothing || push!(source_tasks, ss.task)
        ss.inner === nothing || push!(source_tasks, ss.inner)
    end
    all_tasks = vcat(
        assistant._tasks,
        [l.task for l in lanes if l.task !== nothing],
        source_tasks,
    )
    timedwait(() -> all(istaskdone, all_tasks), 5.0; pollint = 0.05)

    h = assistant._harness[]
    if h !== nothing
        result = close_harness!(h;grace_s=max(0.0,deadline-time()))
        if result.status === :draining
            assistant._state[] = :draining
            return result
        end
    end
    if !idle() || assistant._legacy_tools_running[] > 0
        assistant._state[] = :draining
        return (;status=:draining,reason=:noncooperative_invocation)
    end
    _release_live_event_channels!(assistant)
    _return_claims!(assistant)

    close_writer!(assistant._writer)
    close_readers!(assistant._readers)
    # File-backed assistants own the session reader opened by the constructor.
    # Its mutation-side LocalSearch store uses the writer connection, which the
    # preceding call already closed.
    session_db = try
        getproperty(assistant.session_store, :db)
    catch
        nothing
    end
    if session_db isa SQLite.DB && session_db !== assistant.db && session_db !== assistant._writer.db
        try
            close(session_db)
        catch
        end
    end
    try
        close(assistant.db)
    catch
    end
    owner_lock = assistant._owner_lock[]
    if owner_lock !== nothing
        close(owner_lock)
        assistant._owner_lock[] = nothing
    end

    assistant._state[] = :stopped
    CURRENT_ASSISTANT[] === assistant && (CURRENT_ASSISTANT[] = nothing)
    notify(assistant._shutdown_complete)
    @info "Claw: shutdown complete"
    return nothing
end

"""
    wait_for_shutdown(assistant)

Block until `shutdown!` has finished. Runner scripts use this instead of
`wait(Base.Event())` so a deploy restart drains instead of vanishing mid-eval.
"""
function wait_for_shutdown(assistant::AgentAssistant)
    assistant._state[] === :stopped && return nothing
    try
        wait(assistant._shutdown_complete)
    catch e
        e isa InterruptException || rethrow()
        @info "Claw: interrupt received; draining"
        shutdown!(assistant)
    end
    return nothing
end

"""
    install_shutdown_handler!(assistant)

Register an `atexit` hook that drains the pipeline. Julia's default SIGTERM/SIGINT
handling exits the process, which runs `atexit` hooks — so this is the portable way
to make a deploy restart drain. Opt out with `init!(...; install_signal_handlers = false)`.
"""
function install_shutdown_handler!(assistant::AgentAssistant)
    assistant._signal_handler_installed[] && return nothing
    assistant._signal_handler_installed[] = true
    atexit() do
        try
            shutdown!(assistant)
        catch e
            @warn "Claw: shutdown during exit failed" exception = (e,)
        end
    end
    return nothing
end
