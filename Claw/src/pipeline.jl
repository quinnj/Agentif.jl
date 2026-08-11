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
end

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
                        (dedup_key, source, name, payload, status, attempts, lane, created_at, next_attempt_at)
                    VALUES (?, ?, ?, ?, 'pending', 0, ?, ?, ?)
                """, (dk, String(source), name, payload, lane_key, now, now))
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
    _claim_event!(assistant, id) -> Union{Nothing, EventRow}

Conditional claim. `nothing` means the row was not `pending` — another worker took
it, or it already finished.
"""
function _claim_event!(assistant::AgentAssistant, id::Int)
    lease = time() + assistant.pipeline.lease_duration_s
    return _writer_txn(assistant) do db
        _exec!(db,
            "UPDATE claw_events SET status='running', attempts=attempts+1, lease_expires_at=? WHERE id=? AND status='pending'",
            (lease, id))
        Int(_scalar(db, "SELECT changes()")) == 0 && return nothing
        result = nothing
        for row in SQLite.DBInterface.execute(db,
                "SELECT id, source, name, dedup_key, payload, lane, attempts FROM claw_events WHERE id = ?", (id,))
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
                cid, content, extra, String(row.lane), Int(row.attempts), assistant)
        end
        return result
    end
end

function _finish_event!(assistant::AgentAssistant, id::Int, status::AbstractString;
        last_error::Union{Nothing, AbstractString} = nothing,
        next_attempt_at::Union{Nothing, Float64} = nothing,
    )
    next = next_attempt_at === nothing ? time() : next_attempt_at
    try
        execute_write(assistant._writer,
            "UPDATE claw_events SET status = ?, lease_expires_at = NULL, next_attempt_at = ?, last_error = COALESCE(?, last_error) WHERE id = ?",
            (String(status), next, last_error === nothing ? nothing : first(String(last_error), 4000), id))
    catch e
        @error "Claw: failed to record event outcome" event_id = id status exception = (e, catch_backtrace())
    end
    return nothing
end

# Return an unfinished claim to `pending` without charging an attempt (§1.3 `:aborted`).
function _release_claim!(assistant::AgentAssistant, id::Int;
        delay::Float64 = 0.0,
        last_error::Union{Nothing, AbstractString} = nothing,
    )
    try
        execute_write(assistant._writer, """
            UPDATE claw_events
            SET status='pending', attempts = MAX(attempts - 1, 0), lease_expires_at = NULL,
                next_attempt_at = ?, last_error = COALESCE(?, last_error)
            WHERE id = ? AND status = 'running'
        """, (time() + delay, last_error === nothing ? nothing : first(String(last_error), 4000), id))
    catch e
        @error "Claw: failed to release claim" event_id = id exception = (e, catch_backtrace())
    end
    return nothing
end

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
            # Coalesce: drain whatever else is already queued on this lane (up to
            # max_coalesce), so a burst that piled up behind a slow evaluation is
            # handled as one demarcated batch instead of N sequential evaluations.
            # Only this worker consumes the queue, so isready/take! cannot race.
            items = [item]
            max_coalesce = max(assistant.pipeline.max_coalesce, 1)
            while length(items) < max_coalesce && isready(lane.queue)
                extra = try
                    take!(lane.queue)
                catch
                    break
                end
                Threads.atomic_sub!(lane.depth, 1)
                push!(items, extra)
            end
            waited = time() - items[1][2]
            if waited > assistant.pipeline.lane_backlog_warn_s
                @warn "Claw: lane backlog" lane = lane.key wait_s = round(waited; digits = 2) queue_depth = lane.depth[] drained = length(items)
            end
            ids = [id for (id, _) in items]
            lane.busy[] = true
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

function _handle_event_failure!(assistant::AgentAssistant, row::EventRow, ev::Event, handlers, err;
        notify::Bool = true)
    cfg = assistant.pipeline
    class = classify_eval_failure(err)
    action, delay = _retry_decision(cfg, class, row.attempts)
    text = string(class, ": ", first(sprint(showerror, _unwrap_error(err)), 2000))
    if action === :pending
        @info "Claw: evaluation aborted; returning event to pending" event_id = row.id event_name = row.name
        _release_claim!(assistant, row.id; delay = cfg.min_refire_gap_s, last_error = text)
    elseif action === :retry
        refire = max(delay, cfg.min_refire_gap_s)
        @warn "Claw: event handling failed; scheduling retry" event_id = row.id event_name = row.name class attempts = row.attempts retry_in_s = round(refire; digits = 2)
        _finish_event!(assistant, row.id, "pending"; last_error = text, next_attempt_at = time() + refire)
    else
        @error "Claw: event dead-lettered" event_id = row.id event_name = row.name class attempts = row.attempts error = text
        _finish_event!(assistant, row.id, "dead"; last_error = text)
        notify && _dead_letter_notify!(assistant, row.id, ev, handlers, class, text)
        _forget_live_event!(assistant, row.id)
    end
    return action
end

"""
    _process_event_batch!(assistant, ids)

Claim and process one lane drain. Claimed events are split into runs of
consecutive rows with the same event name; each run is handled as one group —
its events go through the group's handler filters individually, and the
survivors are folded into a single coalesced evaluation per handler.
"""
function _process_event_batch!(assistant::AgentAssistant, ids::Vector{Int})
    claimed = Tuple{EventRow, Event}[]
    for id in ids
        row = try
            _claim_event!(assistant, id)
        catch e
            @error "Claw: claim failed" event_id = id exception = (e, catch_backtrace())
            nothing
        end
        if row === nothing
            _clear_wakeup!(assistant, id)
            continue
        end

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
            _release_claim!(assistant, id; delay = 60.0, last_error = "no rehydrator for source '$(row.source)'")
            _clear_wakeup!(assistant, id)
            continue
        end
        push!(claimed, (row, ev))
    end
    isempty(claimed) && return nothing

    # Consecutive same-name runs only: grouping non-adjacent events would reorder
    # them relative to interleaved events of other types on the same lane.
    i = 1
    while i <= length(claimed)
        if assistant._state[] !== :running
            remaining = claimed[i:end]
            for (row, _) in remaining
                _release_claim!(assistant, row.id)
                _clear_wakeup!(assistant, row.id)
            end
            _release_group_channels!(remaining, nothing)
            break
        end
        j = i
        while j < length(claimed) && claimed[j + 1][1].name == claimed[i][1].name
            j += 1
        end
        _process_claimed_group!(assistant, claimed[i:j])
        i = j + 1
    end
    return nothing
end

_process_event!(assistant::AgentAssistant, id::Int) = _process_event_batch!(assistant, [id])

function _process_claimed_group!(assistant::AgentAssistant, group::Vector{Tuple{EventRow, Event}})
    name = group[1][1].name
    handlers = try
        _event_handlers_for(assistant, name)
    catch e
        @error "Claw: event handler lookup failed" event = name exception = (e, catch_backtrace())
        notify = true
        for (row, ev) in group
            action = _handle_event_failure!(assistant, row, ev, (), e; notify)
            action === :dead && (notify = false)
            _clear_wakeup!(assistant, row.id)
        end
        _release_group_channels!(group, nothing)
        return nothing
    end

    if isempty(handlers)
        for (row, _) in group
            @debug "Claw: no handlers for event" event_id = row.id event_name = name
            _finish_event!(assistant, row.id, "done")
            _forget_live_event!(assistant, row.id)
            _clear_wakeup!(assistant, row.id)
        end
        _release_group_channels!(group, nothing)
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
    try
        for handler in handlers
            kept = Event[]
            for (row, ev) in group
                # Filter errors (e.g. a :prompt filter that cannot reach the model)
                # propagate: the group rides the retry ladder rather than the event
                # being silently dropped or spuriously delivered.
                passes_filter(assistant, handler, ev, row.extra) && push!(kept, ev)
            end
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
            )
            ev_input isa ChannelEvent && push!(streamed, get_channel(ev_input))
            @info "Claw: handler completed" handler_id = handler.id event_name = name duration_s = round(time() - started_at; digits = 4)
        end
        for (row, _) in group
            _finish_event!(assistant, row.id, "done")
            _forget_live_event!(assistant, row.id)
        end
        _release_group_channels!(group, streamed)
    catch e
        # One failure fails the whole group: every row returns to the retry ladder
        # together (same at-least-once semantics as a multi-handler single event).
        # Only the first row sends a dead-letter notice, so a dead group does not
        # spam its channel N times.
        notify = true
        for (row, ev) in group
            action = _handle_event_failure!(assistant, row, ev, handlers, e; notify)
            action === :dead && (notify = false)
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
    try
        execute_write(assistant._writer, """
            UPDATE claw_events SET status='pending', lease_expires_at=NULL
            WHERE status='running' AND lease_expires_at IS NOT NULL AND lease_expires_at <= ?
        """, (now,))
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

function start_event_loop!(assistant::AgentAssistant; level::Union{Nothing, LogLevel} = assistant.log_level)
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
            ss.stopped[] = true
            break
        end
        _sleep_interruptible(assistant, min(backoff, 60.0)) || break
        backoff *= 2
    end
    return nothing
end

function _request_source_restart!(assistant::AgentAssistant, ss::SupervisedSource)
    inner = lock(ss.lock) do
        ss.restart_requested[] = true
        try
            stop!(ss.source)
        catch e
            @warn "Claw: source stop! failed" source = ss.tag exception = (e,)
        end
        ss.inner
    end
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
                ss.stopped[] = true
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
    try
        execute_write(assistant._writer, """
            UPDATE claw_events
            SET status='pending', attempts = MAX(attempts - 1, 0), lease_expires_at = NULL, next_attempt_at = ?
            WHERE status='running'
        """, (time(),))
    catch e
        @error "Claw: failed to return unfinished claims to pending" exception = (e, catch_backtrace())
    end
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
