# ─── Watcher: dual-model supervised evaluation ───
# See Claw/docs/watcher.md for the full design. A configured WatcherConfig makes
# _run_event_handler! route through supervised_evaluate: the primary eval runs in
# a task observed for liveness (stall/overrun detection + journaling to the
# claw_evals table), and on failure a second, cheaper "watcher" model composes a
# short user-facing note that is sent to the event's channel. If the watcher
# itself fails, a hardcoded fallback string is sent. Every path terminates.

using HTTP: HTTP

# ─── Configuration ───

Base.@kwdef struct WatcherConfig
    provider::String
    model_id::String
    apikey::String
    stall_timeout_s::Float64 = 120.0
    max_eval_duration_s::Float64 = 900.0
    check_interval_s::Float64 = 5.0
    respond_on_failure::Bool = true
    watcher_timeout_s::Float64 = 60.0
    on_track_checks::Bool = false
    on_track_every_turns::Int = 5
    # How long to wait for the primary task to observe an abort before giving up
    # on it (a primary wedged in un-timed I/O may never observe the flag; the
    # watcher must still respond and journal rather than wedge alongside it).
    abort_grace_s::Float64 = 10.0
    # INTERNAL (test seam): when set, forwarded as `base_handler` to
    # Agentif.evaluate for the watcher's own eval, letting tests run the watcher
    # fully offline. Leave as `nothing` in production.
    base_handler::Any = nothing
end

# ─── Watch state & observer ───

const WATCH_TRACE_MAX = 50

mutable struct WatchState
    last_activity::Threads.Atomic{Float64}
    turns::Threads.Atomic{Int}
    tool_calls::Threads.Atomic{Int}
    trace::Vector{String}       # bounded ring buffer of one-line summaries
    trace_lock::ReentrantLock
    eval_id::Int                # claw_evals journal rowid
end

WatchState(eval_id::Int) = WatchState(
    Threads.Atomic{Float64}(time()),
    Threads.Atomic{Int}(0),
    Threads.Atomic{Int}(0),
    String[],
    ReentrantLock(),
    eval_id,
)

function _trace!(ws::WatchState, line::String)
    lock(ws.trace_lock) do
        push!(ws.trace, line)
        length(ws.trace) > WATCH_TRACE_MAX && popfirst!(ws.trace)
    end
    return nothing
end

function _trace_tail(ws::WatchState, n::Int = 15)
    lock(ws.trace_lock) do
        return join(ws.trace[max(1, end - n + 1):end], "\n")
    end
end

# Returns an event callback for Agentif.evaluate's f-form: touches last_activity
# on EVERY event (the heartbeat), counts turns/tool calls, and appends one-line
# summaries to the bounded trace. Must never throw.
function watch_observer(ws::WatchState)
    return function (event)
        try
            ws.last_activity[] = time()
            if event isa Agentif.TurnStartEvent
                n = Threads.atomic_add!(ws.turns, 1) + 1
                _trace!(ws, "turn $n")
            elseif event isa Agentif.ToolExecutionStartEvent
                Threads.atomic_add!(ws.tool_calls, 1)
                _trace!(ws, "tool $(event.tool_call.name)")
            elseif event isa Agentif.AgentErrorEvent
                _trace!(ws, string("error: ", first(sprint(showerror, event.error), 200)))
            end
        catch e
            @debug "watch_observer failed" exception = (e,)
        end
        return nothing
    end
end

# ─── Failure classification ───

function _unwrap_error(err)
    e = err
    for _ in 1:20
        if e isa TaskFailedException
            e = e.task.exception
        elseif e isa CapturedException
            e = e.ex
        elseif e isa CompositeException && !isempty(e.exceptions)
            e = first(e.exceptions)
        else
            break
        end
    end
    return e
end

"""
    classify_eval_failure(err) -> Symbol

Map an exception (possibly wrapped in TaskFailedException/CompositeException/
CapturedException layers) to a failure class:
`:rate_limit | :auth | :overloaded | :network | :aborted | :unknown`.
"""
function classify_eval_failure(err)
    e = _unwrap_error(err)
    if e isa HTTP.StatusError
        s = Int(e.status)
        s == 429 && return :rate_limit
        (s == 401 || s == 403) && return :auth
        (s == 500 || s == 502 || s == 503 || s == 529) && return :overloaded
    end
    e isa Agentif.AbortEvaluation && return :aborted
    (e isa EOFError || e isa Base.IOError) && return :network
    name = e isa Exception ? nameof(typeof(e)) : Symbol("")
    name in (:ConnectError, :DNSError, :TimeoutError, :ReadTimeoutError, :RequestError) && return :network
    msg = lowercase(e isa Exception ? sprint(showerror, e) : string(e))
    (occursin("rate limit", msg) || occursin("rate_limit", msg)) && return :rate_limit
    occursin("overloaded", msg) && return :overloaded
    (occursin("timed out", msg) || occursin("timeout", msg) || occursin("connection", msg) || occursin("dns", msg)) && return :network
    return :unknown
end

# ─── Journal (claw_evals) ───

const WATCHER_JOURNAL_LOCK = ReentrantLock()

function _journal_insert!(db::SQLite.DB, event_name::String, handler_id::String, channel_id::Union{Nothing, String}, started::Float64)
    # Lock so concurrent handler tasks can't interleave INSERT/last_insert_rowid.
    return lock(WATCHER_JOURNAL_LOCK) do
        _with_busy_retry() do
            SQLite.DBInterface.execute(db, """
                INSERT INTO claw_evals (event_name, handler_id, channel_id, status, started_at, last_activity_at)
                VALUES (?, ?, ?, 'running', ?, ?)
            """, (event_name, handler_id, channel_id, started, started))
            row = iterate(SQLite.DBInterface.execute(db, "SELECT last_insert_rowid() AS id"))
            return Int(row[1].id)
        end
    end
end

function _journal_activity!(db::SQLite.DB, ws::WatchState)
    _with_busy_retry() do
        SQLite.DBInterface.execute(db,
            "UPDATE claw_evals SET last_activity_at = ?, turns = ?, tool_calls = ? WHERE id = ?",
            (ws.last_activity[], ws.turns[], ws.tool_calls[], ws.eval_id))
        return nothing
    end
end

function _journal_note!(db::SQLite.DB, eval_id::Int, note::String)
    _with_busy_retry() do
        SQLite.DBInterface.execute(db,
            "UPDATE claw_evals SET watcher_note = ? WHERE id = ?", (note, eval_id))
        return nothing
    end
end

function _journal_fallback!(db::SQLite.DB, eval_id::Int, note::String, sent::Bool)
    _with_busy_retry() do
        SQLite.DBInterface.execute(db,
            "UPDATE claw_evals SET fallback_sent = ?, watcher_note = ? WHERE id = ?",
            (sent ? 1 : 0, note, eval_id))
        return nothing
    end
end

function _journal_finalize!(db::SQLite.DB, ws::WatchState; status::String, failure_class::Union{Nothing, String}, error::Union{Nothing, String})
    _with_busy_retry() do
        SQLite.DBInterface.execute(db, """
            UPDATE claw_evals SET status = ?, failure_class = ?, error = ?, finished_at = ?,
                last_activity_at = ?, turns = ?, tool_calls = ?
            WHERE id = ?
        """, (status, failure_class, error, time(), ws.last_activity[], ws.turns[], ws.tool_calls[], ws.eval_id))
        return nothing
    end
end

# ─── Watcher model evals ───

const WATCHER_SYSTEM_PROMPT = """
You are the supervisor of a personal assistant. One of the assistant's event-handler
evaluations failed, and you must write the short note the assistant sends to its user
about it.

Given the failed evaluation's context, reply with a 1-3 sentence note, written in the
assistant's voice (first person), covering: what was being processed, what went wrong
in plain language, and whether retrying later makes sense.

Rules:
- No markdown headers.
- Do not apologize more than once.
- Do not call tools.
- Reply with the note text only — it is sent to the user verbatim.
"""

const WATCHER_ON_TRACK_PROMPT = """
You are the supervisor of a personal assistant. An evaluation is in progress and you
must judge whether it is on track.

Reply with a verdict as the FIRST word of your reply — ON_TRACK, CONCERN, or ABORT —
followed by one sentence explaining why. ABORT means the evaluation is making no real
progress (e.g. a tool loop or a doomed path) and should be cancelled; CONCERN records
a worry without acting; ON_TRACK means let it continue.
"""

function _watcher_agent(cfg::WatcherConfig, prompt::String)
    model = Agentif.getModel(cfg.provider, cfg.model_id)
    model === nothing && error("Unknown watcher model: provider=$(cfg.provider) model_id=$(cfg.model_id)")
    return Agentif.Agent(; prompt, model, apikey = cfg.apikey, tools = Agentif.AgentTool[])
end

# Run the watcher's own eval with a hard budget of cfg.watcher_timeout_s: abort on
# expiry, give a short grace period for the abort to land, then give up (throw).
# Returns the non-empty note text or throws.
function _run_watcher_eval(cfg::WatcherConfig, agent::Agentif.Agent, input::String)
    abort = Agentif.Abort()
    kw = cfg.base_handler === nothing ? (;) : (; base_handler = cfg.base_handler)
    task = @async Agentif.evaluate(agent, input; abort, kw...)
    if timedwait(() -> istaskdone(task), cfg.watcher_timeout_s; pollint = 0.05) !== :ok
        Agentif.abort!(abort)
        timedwait(() -> istaskdone(task), 5.0; pollint = 0.05) === :ok ||
            error("watcher eval did not finish within watcher_timeout_s=$(cfg.watcher_timeout_s)")
    end
    state = fetch(task)
    msg = Agentif.last_assistant_message(state)
    msg === nothing && error("watcher eval produced no assistant message")
    text = strip(Agentif.message_text(msg))
    isempty(text) && error("watcher eval produced empty output")
    return String(text)
end

"""
    compose_fallback_note(cfg::WatcherConfig, ctx::NamedTuple) -> String

Ask the watcher model for a 1-3 sentence user-facing note about a failed eval.
`ctx` carries `failure_class`, `handler_id`, `handler_prompt`, `event_name`,
`event_content`, `elapsed_s`, `turns`, `tool_calls`, `trace_tail`. Throws on any
watcher failure (unknown model, timeout, empty output) — see
`fallback_note_or_default` for the never-throws wrapper.
"""
function compose_fallback_note(cfg::WatcherConfig, ctx::NamedTuple)
    agent = _watcher_agent(cfg, WATCHER_SYSTEM_PROMPT)
    input = string(
        "A handler evaluation failed; compose the user-facing note.\n\n",
        "Failure class: ", ctx.failure_class, "\n",
        "Handler: ", ctx.handler_id, "\n",
        "Handler prompt: ", first(ctx.handler_prompt, 500), "\n",
        "Event: ", ctx.event_name, "\n",
        "Event content: ", first(ctx.event_content, 1000), "\n",
        "Elapsed: ", round(ctx.elapsed_s; digits = 1), "s, turns: ", ctx.turns,
        ", tool calls: ", ctx.tool_calls, "\n",
        "Recent activity:\n", ctx.trace_tail,
    )
    return _run_watcher_eval(cfg, agent, input)
end

function fallback_note_or_default(cfg::WatcherConfig, ctx::NamedTuple)
    try
        return compose_fallback_note(cfg, ctx)
    catch e
        @warn "Claw watcher: fallback note composition failed; using default" exception = (e, catch_backtrace())
        return "⚠️ I hit a problem while handling this event ($(ctx.failure_class)) and couldn't finish. The error has been logged; you may want to retry or check the logs."
    end
end

# ─── Phase 2 (config-gated): on-track checks ───

# Lenient verdict parse: uppercase match anywhere in the first line; ON_TRACK wins
# over CONCERN so "ON_TRACK — no concern here" parses correctly; unknown → :on_track.
function _parse_on_track_verdict(text::AbstractString)
    first_line = String(first(split(text, '\n'; limit = 2)))
    u = uppercase(first_line)
    verdict = occursin("ON_TRACK", u) ? :on_track :
        occursin("ABORT", u) ? :abort :
        occursin("CONCERN", u) ? :concern : :on_track
    sentence = strip(replace(first_line, r"^\s*(ON_TRACK|CONCERN|ABORT)[\s:,.—-]*"i => ""))
    isempty(sentence) && (sentence = strip(text))
    return verdict, String(sentence)
end

function watcher_on_track_verdict(cfg::WatcherConfig, ctx::NamedTuple)
    agent = _watcher_agent(cfg, WATCHER_ON_TRACK_PROMPT)
    input = string(
        "Progress check for an in-flight evaluation.\n\n",
        "Handler: ", ctx.handler_id, "\n",
        "Handler prompt: ", first(ctx.handler_prompt, 500), "\n",
        "Elapsed: ", round(ctx.elapsed_s; digits = 1), "s, turns: ", ctx.turns,
        ", tool calls: ", ctx.tool_calls, "\n",
        "Recent activity:\n", ctx.trace_tail,
    )
    return _parse_on_track_verdict(_run_watcher_eval(cfg, agent, input))
end

# ─── Supervised evaluation ───

function _watch_ctx(ws::WatchState, handler, ev::Event, event_name::String, started::Float64, failure_class::Union{Nothing, String})
    content = try
        event_content(ev)
    catch
        ""
    end
    return (;
        failure_class = something(failure_class, "unknown"),
        handler_id = String(handler.id),
        handler_prompt = String(handler.prompt),
        event_name,
        event_content = content,
        elapsed_s = time() - started,
        turns = ws.turns[],
        tool_calls = ws.tool_calls[],
        trace_tail = _trace_tail(ws, 15),
    )
end

"""
    supervised_evaluate(assistant, ev, handler, ch; level, eval_kw...)

Run one event-handler evaluation under watcher supervision (see docs/watcher.md):
journal to `claw_evals`, observe liveness via `watch_observer`, abort on stall or
overrun, and on failure/stall/overrun send a watcher-composed note to `ch` (unless
`ch` is a `SinkChannel`). `eval_kw` is forwarded to `evaluate` (test seam for
`base_handler` injection). Never throws for eval failures — they are journaled.
"""
function supervised_evaluate(assistant, ev::Event, handler, ch::Agentif.AbstractChannel;
        level = assistant.log_level, eval_kw...)
    cfg = assistant.watcher
    db = assistant.db
    event_name = get_name(ev)
    input = make_prompt(handler.prompt, ev)
    started = time()
    eval_id = _journal_insert!(db, event_name, String(handler.id), Agentif.channel_id(ch), started)
    ws = WatchState(eval_id)
    observer = watch_observer(ws)
    abort = Agentif.Abort()
    @debug "Claw watcher: supervised evaluate start" eval_id handler_id = handler.id event_name channel_id = Agentif.channel_id(ch)
    task = @async evaluate(assistant, input; channel = ch, observer, abort, level, eval_kw...)
    abort_reason = nothing
    ontrack_note = nothing
    status = "completed"
    failure_class = nothing
    err_text = nothing
    try
        # Supervisor loop: small poll granularity so tiny check intervals (tests)
        # and shutdown are responsive even with large configured intervals.
        pollint = max(0.01, min(0.25, cfg.check_interval_s / 2))
        last_journal = 0.0
        last_ontrack_turns = 0
        while !istaskdone(task)
            timedwait(() -> istaskdone(task), cfg.check_interval_s; pollint)
            istaskdone(task) && break
            now = time()
            if now - ws.last_activity[] > cfg.stall_timeout_s
                abort_reason = :stalled
                @warn "Claw watcher: eval stalled; aborting" eval_id handler_id = handler.id idle_s = round(now - ws.last_activity[]; digits = 1)
                Agentif.abort!(abort)
                break
            elseif now - started > cfg.max_eval_duration_s
                abort_reason = :overrun
                @warn "Claw watcher: eval overran; aborting" eval_id handler_id = handler.id elapsed_s = round(now - started; digits = 1)
                Agentif.abort!(abort)
                break
            end
            if now - last_journal >= 2.0
                try
                    _journal_activity!(db, ws)
                catch e
                    @debug "Claw watcher: journal heartbeat failed" eval_id exception = (e,)
                end
                last_journal = now
            end
            # Phase 2 (off by default): periodic on-track verdicts from the watcher.
            if cfg.on_track_checks && ws.turns[] - last_ontrack_turns >= cfg.on_track_every_turns
                last_ontrack_turns = ws.turns[]
                try
                    verdict, sentence = watcher_on_track_verdict(cfg, _watch_ctx(ws, handler, ev, event_name, started, nothing))
                    if verdict === :abort
                        abort_reason = :off_track
                        ontrack_note = sentence
                        @warn "Claw watcher: off-track verdict; aborting" eval_id handler_id = handler.id note = sentence
                        Agentif.abort!(abort)
                        break
                    elseif verdict === :concern
                        @info "Claw watcher: on-track concern" eval_id note = sentence
                        _journal_note!(db, eval_id, sentence)
                    end
                catch e
                    @warn "Claw watcher: on-track check failed" eval_id exception = (e, catch_backtrace())
                end
            end
        end
        # Settle the primary. Aborted evals may either throw AbortEvaluation (via
        # a middleware check_abort) or return a state with an :aborted stop reason;
        # abort_reason takes precedence over exception classification either way.
        # After an abort, the wait is bounded: a primary wedged in un-timed I/O
        # may never observe the flag, and the watcher must respond regardless.
        settled = istaskdone(task) ||
            (abort_reason === nothing || timedwait(() -> istaskdone(task), max(cfg.abort_grace_s, 0.01)) === :ok)
        if !settled
            @warn "Claw watcher: primary eval did not stop within abort grace; responding without it" eval_id grace_s = cfg.abort_grace_s
            err_text = "primary eval task did not terminate after abort (zombie task)"
        end
        try
            settled && wait(task)
        catch e
            if abort_reason === nothing
                cls = classify_eval_failure(e)
                status = cls === :aborted ? "aborted" : "failed"
                failure_class = String(cls)
                err_text = String(first(sprint(showerror, _unwrap_error(e)), 2000))
            end
        end
        if abort_reason === :stalled
            status = "stalled"
            failure_class = "stalled"
        elseif abort_reason === :overrun
            status = "overrun"
            failure_class = "overrun"
        elseif abort_reason === :off_track
            status = "aborted"
            failure_class = "off_track"
        end
        # Fallback response: only for error/stall/overrun/off-track terminations
        # (silent completions are NOT failures), only onto real channels.
        respond = failure_class !== nothing && failure_class != "aborted" &&
            cfg.respond_on_failure && !(ch isa SinkChannel)
        if respond
            ctx = _watch_ctx(ws, handler, ev, event_name, started, failure_class)
            note = ontrack_note !== nothing ? ontrack_note : fallback_note_or_default(cfg, ctx)
            sent = false
            try
                Agentif.send_message(ch, note)
                sent = true
            catch e
                @warn "Claw watcher: fallback send failed" eval_id channel_id = Agentif.channel_id(ch) exception = (e, catch_backtrace())
            end
            try
                _journal_fallback!(db, eval_id, sent ? note : string(note, " [send failed]"), sent)
            catch e
                @debug "Claw watcher: fallback journal failed" eval_id exception = (e,)
            end
        end
    finally
        try
            _journal_finalize!(db, ws; status, failure_class, error = err_text)
        catch e
            @error "Claw watcher: journal finalize failed" eval_id exception = (e, catch_backtrace())
        end
    end
    @debug "Claw watcher: supervised evaluate end" eval_id status failure_class
    return nothing
end
