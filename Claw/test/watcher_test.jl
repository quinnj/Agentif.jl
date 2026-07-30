# Watcher (dual-model supervised evaluation) tests — fully offline.
# Fake `base_handler`s (Agentif's test seam) stand in for both the primary model
# and the watcher model; no network calls are made.
# Run: julia --project=. Claw/test/watcher_test.jl (from the repo root)

using Claw
using Agentif
using HTTP
using SQLite
using Test

# ─── Offline model registry ───
# getModel() resolves from an in-memory registry that is empty offline; register
# a dummy model so Claw.evaluate/_watcher_agent can resolve it. The fake
# base_handlers below mean it is never actually called.

const WATCHER_TEST_MODEL = Agentif.Model(
    id = "watcher-test-model", name = "watcher-test-model", api = "openai-completions",
    provider = "watcher-test", baseUrl = "http://localhost", reasoning = false,
    input = ["text"],
    cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
    contextWindow = 100000, maxTokens = 4096,
)
Agentif.registerModel!(WATCHER_TEST_MODEL)

# ─── Recording channel ───

struct RecordingChannel <: Agentif.AbstractChannel
    id::String
    sent::Vector{Any}
    streamed::Vector{String}
end
RecordingChannel(id::String) = RecordingChannel(id, Any[], String[])

Agentif.channel_id(ch::RecordingChannel) = ch.id
Agentif.start_streaming(::RecordingChannel) = nothing
Agentif.append_to_stream(ch::RecordingChannel, delta::AbstractString) = (push!(ch.streamed, String(delta)); nothing)
Agentif.finish_streaming(::RecordingChannel) = nothing
Agentif.send_message(ch::RecordingChannel, msg) = (push!(ch.sent, msg); nothing)
Agentif.close_channel(::RecordingChannel) = nothing

# ─── Test event ───

struct WatcherTestEvent <: Claw.Event
    name::String
    content::String
end
Claw.get_name(ev::WatcherTestEvent) = ev.name
Claw.event_content(ev::WatcherTestEvent) = ev.content

# ─── Fake base_handlers ───

# Finish an eval state the way Agentif's stream handler would.
function finish_state!(state, input; text::Union{Nothing, String} = nothing)
    content = Agentif.AssistantContentBlock[]
    text !== nothing && push!(content, Agentif.TextContent(text))
    msg = Agentif.AssistantMessage(; provider = "test", api = "test", model = "test", content)
    Agentif.append_state!(state, input, msg, Agentif.Usage())
    state.pending_tool_calls = Agentif.PendingToolCall[]
    state.most_recent_stop_reason = :stop
    return state
end

# Emits `tool_events` synthetic tool-execution events, then returns cleanly.
function make_success_handler(; text::Union{Nothing, String} = "All done.", tool_events::Int = 0)
    return function (f, agent, state, input, abort; kw...)
        for i in 1:tool_events
            f(Agentif.ToolExecutionStartEvent(Agentif.PendingToolCall(;
                call_id = "call-$i", name = "fake_tool_$i", arguments = "{}")))
        end
        return finish_state!(state, input; text)
    end
end

make_throwing_handler(err) = (f, agent, state, input, abort; kw...) -> throw(err)

# Simulates a stalled (or, with emit_activity, an overrunning-but-alive) eval.
# MUST honor abort so tests terminate; records whether it observed the abort.
function make_hanging_handler(observed_abort::Ref{Bool}; emit_activity::Bool = false)
    return function (f, agent, state, input, abort; kw...)
        deadline = time() + 30.0
        while !Agentif.isaborted(abort) && time() < deadline
            emit_activity && f(Agentif.AgentEvaluateStartEvent(Agentif.UID8()))
            sleep(0.02)
        end
        observed_abort[] = Agentif.isaborted(abort)
        throw(Agentif.AbortEvaluation())
    end
end

# Fake watcher-model handlers (installed via WatcherConfig.base_handler).
canned_watcher_handler(note::String) =
    (f, agent, state, input, abort; kw...) -> finish_state!(state, input; text = note)
throwing_watcher_handler = (f, agent, state, input, abort; kw...) -> error("watcher model down")

# ─── Helpers ───

function make_watcher_assistant(; watcher = nothing)
    AgentAssistant(":memory:";
        provider = "watcher-test", model_id = "watcher-test-model", apikey = "test-key",
        timezone = "America/Denver", watcher)
end

function watcher_cfg(; kw...)
    Claw.WatcherConfig(;
        provider = "watcher-test", model_id = "watcher-test-model", apikey = "watcher-key",
        stall_timeout_s = 60.0, max_eval_duration_s = 120.0, check_interval_s = 0.1,
        watcher_timeout_s = 5.0,
        base_handler = canned_watcher_handler("Canned watcher note."),
        kw...)
end

function fetch_evals(db)
    out = []
    for r in SQLite.DBInterface.execute(db, """
        SELECT id, event_name, handler_id, channel_id, status, failure_class, started_at,
               last_activity_at, finished_at, turns, tool_calls, error, fallback_sent, watcher_note
        FROM claw_evals ORDER BY id
    """)
        push!(out, (;
            id = r.id, event_name = r.event_name, handler_id = r.handler_id,
            channel_id = r.channel_id, status = r.status, failure_class = r.failure_class,
            started_at = r.started_at, last_activity_at = r.last_activity_at,
            finished_at = r.finished_at, turns = r.turns, tool_calls = r.tool_calls,
            error = r.error, fallback_sent = r.fallback_sent, watcher_note = r.watcher_note,
        ))
    end
    return out
end

# Guard every potentially-hanging run so regressions fail rather than hang.
function run_handler_guarded(a, ev, handler; timeout = 30.0, kw...)
    t = @async Claw._run_event_handler!(a, ev, handler; kw...)
    status = timedwait(() -> istaskdone(t), timeout)
    @test status == :ok
    status == :ok || error("_run_event_handler! did not finish within $(timeout)s (test guard)")
    return fetch(t)
end

# ============================================================================
println("=" ^ 60)
println("WATCHER TESTS: dual-model supervised evaluation")
println("=" ^ 60)

@testset "WatcherConfig defaults" begin
    cfg = Claw.WatcherConfig(provider = "p", model_id = "m", apikey = "k")
    @test cfg.stall_timeout_s == 120.0
    @test cfg.max_eval_duration_s == 900.0
    @test cfg.check_interval_s == 5.0
    @test cfg.respond_on_failure
    @test cfg.watcher_timeout_s == 60.0
    @test !cfg.on_track_checks
    @test cfg.on_track_every_turns == 5
    @test cfg.base_handler === nothing
end

@testset "classify_eval_failure" begin
    se(status) = HTTP.StatusError(status, "POST", "/v1", HTTP.Response(status))
    @test Claw.classify_eval_failure(se(429)) === :rate_limit
    @test Claw.classify_eval_failure(se(401)) === :auth
    @test Claw.classify_eval_failure(se(403)) === :auth
    for s in (500, 502, 503, 529)
        @test Claw.classify_eval_failure(se(s)) === :overloaded
    end
    @test Claw.classify_eval_failure(Agentif.AbortEvaluation()) === :aborted
    @test Claw.classify_eval_failure(EOFError()) === :network
    @test Claw.classify_eval_failure(ErrorException("provider rate limit exceeded")) === :rate_limit
    @test Claw.classify_eval_failure(ErrorException("Overloaded, try again later")) === :overloaded
    @test Claw.classify_eval_failure(ErrorException("connection refused by host")) === :network
    @test Claw.classify_eval_failure(ErrorException("boom")) === :unknown
    # Wrapped layers unwrap: TaskFailedException, CompositeException, CapturedException
    t = @async throw(se(429))
    wrapped = try
        wait(t)
        nothing
    catch e
        e
    end
    @test wrapped isa TaskFailedException
    @test Claw.classify_eval_failure(wrapped) === :rate_limit
    ce = CompositeException()
    push!(ce.exceptions, CapturedException(EOFError(), Any[]))
    @test Claw.classify_eval_failure(ce) === :network
    println("  ✓ classify_eval_failure passed")
end

@testset "on-track verdict parsing" begin
    @test Claw._parse_on_track_verdict("ON_TRACK — steady progress")[1] === :on_track
    @test Claw._parse_on_track_verdict("ABORT: tool loop detected") == (:abort, "tool loop detected")
    @test Claw._parse_on_track_verdict("CONCERN, this seems slow")[1] === :concern
    # ON_TRACK wins even when the sentence mentions "concern"
    @test Claw._parse_on_track_verdict("ON_TRACK — no concern here")[1] === :on_track
    # Unknown/lowercase junk → lenient default
    @test Claw._parse_on_track_verdict("gibberish reply")[1] === :on_track
    println("  ✓ on-track verdict parsing passed")
end

@testset "No watcher configured: path unchanged, no journal rows" begin
    a = make_watcher_assistant()
    @test a.watcher === nothing
    ch = RecordingChannel("rec-nowatch")
    a._channels[ch.id] = ch
    ran = Ref(false)
    fake = function (f, agent, state, input, abort; kw...)
        ran[] = true
        return finish_state!(state, input; text = "plain response")
    end
    ev = WatcherTestEvent("test_event", "hello")
    handler = (; id = "h-nowatch", prompt = "Test prompt", channel_id = ch.id)
    run_handler_guarded(a, ev, handler; base_handler = fake)
    @test ran[]
    @test isempty(fetch_evals(a.db))
    @test isempty(ch.sent)
    println("  ✓ no-watcher path passed")
end

@testset "Successful eval: journaled completed, counts, no fallback" begin
    a = make_watcher_assistant(; watcher = watcher_cfg())
    ch = RecordingChannel("rec-success")
    a._channels[ch.id] = ch
    ev = WatcherTestEvent("test_event", "do the thing")
    handler = (; id = "h-success", prompt = "Test prompt", channel_id = ch.id)
    run_handler_guarded(a, ev, handler; base_handler = make_success_handler(; tool_events = 2))
    rows = fetch_evals(a.db)
    @test length(rows) == 1
    row = rows[1]
    @test row.status == "completed"
    @test row.event_name == "test_event"
    @test row.handler_id == "h-success"
    @test row.channel_id == "rec-success"
    @test row.turns == 1
    @test row.tool_calls == 2
    @test row.fallback_sent == 0
    @test row.failure_class === missing
    @test row.finished_at !== missing
    @test isempty(ch.sent)
    println("  ✓ successful eval passed")
end

@testset "Eval throws 429: failed/rate_limit + watcher fallback sent" begin
    a = make_watcher_assistant(; watcher = watcher_cfg())
    ch = RecordingChannel("rec-429")
    a._channels[ch.id] = ch
    ev = WatcherTestEvent("test_event", "process email")
    handler = (; id = "h-429", prompt = "Test prompt", channel_id = ch.id)
    err = HTTP.StatusError(429, "POST", "/v1/messages", HTTP.Response(429))
    run_handler_guarded(a, ev, handler; base_handler = make_throwing_handler(err))
    rows = fetch_evals(a.db)
    @test length(rows) == 1
    row = rows[1]
    @test row.status == "failed"
    @test row.failure_class == "rate_limit"
    @test row.error !== missing
    @test occursin("429", row.error)
    @test row.fallback_sent == 1
    @test row.watcher_note == "Canned watcher note."
    @test ch.sent == Any["Canned watcher note."]
    println("  ✓ 429 failure + fallback passed")
end

@testset "Stall: abort + status stalled + fallback" begin
    a = make_watcher_assistant(; watcher = watcher_cfg(; stall_timeout_s = 0.5, check_interval_s = 0.1))
    ch = RecordingChannel("rec-stall")
    a._channels[ch.id] = ch
    ev = WatcherTestEvent("test_event", "long thing")
    handler = (; id = "h-stall", prompt = "Test prompt", channel_id = ch.id)
    observed = Ref(false)
    run_handler_guarded(a, ev, handler; base_handler = make_hanging_handler(observed))
    @test observed[]  # abort! was triggered and the handler saw it
    rows = fetch_evals(a.db)
    @test length(rows) == 1
    row = rows[1]
    @test row.status == "stalled"
    @test row.failure_class == "stalled"
    @test row.fallback_sent == 1
    @test ch.sent == Any["Canned watcher note."]
    println("  ✓ stall passed")
end

@testset "Zombie primary: bounded abort grace, fallback still sent" begin
    # A primary wedged in un-timed I/O never observes the abort flag; the
    # supervisor must respond within abort_grace_s instead of wedging with it.
    a = make_watcher_assistant(; watcher = watcher_cfg(;
        stall_timeout_s = 0.3, check_interval_s = 0.1, abort_grace_s = 0.2))
    ch = RecordingChannel("rec-zombie")
    a._channels[ch.id] = ch
    ev = WatcherTestEvent("test_event", "wedged thing")
    handler = (; id = "h-zombie", prompt = "Test prompt", channel_id = ch.id)
    # Ignores abort entirely; bounded sleep so the leaked task ends on its own.
    zombie_handler = (f, agent, state, input, abort; kw...) -> (sleep(5.0); state)
    elapsed = @elapsed run_handler_guarded(a, ev, handler; base_handler = zombie_handler)
    @test elapsed < 4.0  # returned well before the zombie's 5s sleep
    rows = fetch_evals(a.db)
    @test length(rows) == 1
    row = rows[1]
    @test row.status == "stalled"
    @test row.fallback_sent == 1
    @test ch.sent == Any["Canned watcher note."]
    @test occursin("zombie", something(row.error, ""))
    println("  ✓ zombie primary passed")
end

@testset "Overrun: abort + status overrun + fallback" begin
    a = make_watcher_assistant(; watcher = watcher_cfg(; stall_timeout_s = 60.0, max_eval_duration_s = 0.5, check_interval_s = 0.1))
    ch = RecordingChannel("rec-overrun")
    a._channels[ch.id] = ch
    ev = WatcherTestEvent("test_event", "endless thing")
    handler = (; id = "h-overrun", prompt = "Test prompt", channel_id = ch.id)
    observed = Ref(false)
    # emit_activity keeps last_activity fresh so only the wall-clock ceiling can fire
    run_handler_guarded(a, ev, handler; base_handler = make_hanging_handler(observed; emit_activity = true))
    @test observed[]
    rows = fetch_evals(a.db)
    @test length(rows) == 1
    row = rows[1]
    @test row.status == "overrun"
    @test row.failure_class == "overrun"
    @test row.fallback_sent == 1
    @test ch.sent == Any["Canned watcher note."]
    println("  ✓ overrun passed")
end

@testset "Watcher model fails: hardcoded fallback sent" begin
    a = make_watcher_assistant(; watcher = watcher_cfg(; base_handler = throwing_watcher_handler))
    ch = RecordingChannel("rec-watcherfail")
    a._channels[ch.id] = ch
    ev = WatcherTestEvent("test_event", "x")
    handler = (; id = "h-watcherfail", prompt = "Test prompt", channel_id = ch.id)
    err = HTTP.StatusError(429, "POST", "/v1/messages", HTTP.Response(429))
    run_handler_guarded(a, ev, handler; base_handler = make_throwing_handler(err))
    rows = fetch_evals(a.db)
    @test length(rows) == 1
    @test rows[1].status == "failed"
    @test rows[1].fallback_sent == 1
    @test length(ch.sent) == 1
    note = ch.sent[1]
    @test startswith(note, "⚠️ I hit a problem while handling this event")
    @test occursin("(rate_limit)", note)
    @test rows[1].watcher_note == note
    println("  ✓ watcher-failure hardcoded fallback passed")
end

@testset "SinkChannel: journaled, no fallback attempted" begin
    a = make_watcher_assistant(; watcher = watcher_cfg())
    ev = WatcherTestEvent("test_event", "background work")
    handler = (; id = "h-sink", prompt = "Test prompt", channel_id = nothing)  # → SinkChannel
    run_handler_guarded(a, ev, handler; base_handler = make_throwing_handler(ErrorException("boom sink")))
    rows = fetch_evals(a.db)
    @test length(rows) == 1
    row = rows[1]
    @test row.status == "failed"
    @test row.failure_class == "unknown"
    @test row.channel_id == "handler:h-sink"
    @test row.fallback_sent == 0
    @test row.watcher_note === missing
    println("  ✓ sink channel passed")
end

@testset "Group silence: no output is not a failure" begin
    a = make_watcher_assistant(; watcher = watcher_cfg())
    ch = RecordingChannel("rec-silence")
    a._channels[ch.id] = ch
    ev = WatcherTestEvent("test_event", "group chatter")
    handler = (; id = "h-silence", prompt = "Test prompt", channel_id = ch.id)
    # The eval returns normally but emits nothing to the channel (∅ no-reply).
    run_handler_guarded(a, ev, handler; base_handler = make_success_handler(; text = "∅"))
    rows = fetch_evals(a.db)
    @test length(rows) == 1
    @test rows[1].status == "completed"
    @test rows[1].fallback_sent == 0
    @test isempty(ch.sent)
    @test isempty(ch.streamed)
    println("  ✓ group silence passed")
end

@testset "init! crash recovery: running rows flipped to failed/process_crash" begin
    db_path = tempname() * ".sqlite"
    a1 = AgentAssistant(db_path;
        provider = "watcher-test", model_id = "watcher-test-model", apikey = "test-key")
    SQLite.DBInterface.execute(a1.db, """
        INSERT INTO claw_evals (event_name, handler_id, status, started_at, last_activity_at)
        VALUES ('crash_event', 'h-crash', 'running', ?, ?)
    """, (time(), time()))
    @test fetch_evals(a1.db)[1].status == "running"
    close(a1.db)  # simulate process exit

    a2 = Claw.init!(db_path;
        event_sources = Claw.EventSource[],
        provider = "watcher-test", model_id = "watcher-test-model", apikey = "test-key",
        watcher = watcher_cfg())
    @test a2.watcher isa Claw.WatcherConfig  # watcher kwarg threads through init!
    rows = fetch_evals(a2.db)
    @test length(rows) == 1
    @test rows[1].status == "failed"
    @test rows[1].failure_class == "process_crash"
    @test rows[1].finished_at !== missing

    # Teardown the init!-started machinery
    close(a2.event_queue)
    close(a2.scheduler)
    close(a2.db)
    rm(db_path; force = true)
    rm(db_path * "-wal"; force = true)
    rm(db_path * "-shm"; force = true)
    println("  ✓ crash recovery passed")
end

println()
println("=" ^ 60)
println("ALL WATCHER TESTS PASSED")
println("=" ^ 60)
