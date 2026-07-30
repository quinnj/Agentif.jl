# pipeline_test.jl — failure injection for the durable event pipeline (§1.1–§1.8)
#
# These are deliberately not happy paths: crash recovery, duplicate delivery, lane
# serialization, retry/dead-lettering, shutdown draining, source restart budgets and
# PTY coalescing. Every wait is guarded with `timedwait` so a regression fails
# instead of hanging the suite.

module PipelineTests

using Test
using Agentif
using Claw
using HTTP
using Logging
using SQLite

# ─── Fixtures ───

mutable struct RecordingChannel <: Agentif.AbstractChannel
    id::String
    sent::Vector{String}
    lock::ReentrantLock
end
RecordingChannel(id::String) = RecordingChannel(id, String[], ReentrantLock())

Agentif.channel_id(ch::RecordingChannel) = ch.id
Agentif.channel_name(ch::RecordingChannel) = ch.id
Agentif.start_streaming(::RecordingChannel) = nothing
Agentif.append_to_stream(::RecordingChannel, ::AbstractString) = nothing
Agentif.finish_streaming(::RecordingChannel) = nothing
Agentif.close_channel(::RecordingChannel) = nothing
Agentif.is_group(::RecordingChannel) = false
Agentif.is_private(::RecordingChannel) = true
function Agentif.send_message(ch::RecordingChannel, msg)
    lock(ch.lock) do
        push!(ch.sent, string(msg))
    end
    return nothing
end
sent_messages(ch::RecordingChannel) = lock(() -> copy(ch.sent), ch.lock)

struct PipelineTestEvent <: Claw.ChannelEvent
    content::String
    channel::RecordingChannel
end
Claw.get_name(::PipelineTestEvent) = "pipeline_test_event"
Claw.get_channel(ev::PipelineTestEvent) = ev.channel
Claw.event_content(ev::PipelineTestEvent) = ev.content

struct UnownedEvent <: Claw.Event
    content::String
end
Claw.get_name(::UnownedEvent) = "pipeline_test_event"
Claw.event_content(ev::UnownedEvent) = ev.content
Claw.event_source_tag(::UnownedEvent) = "no-such-source"

function make_assistant(db_path::String = ":memory:"; kwargs...)
    return Claw.AgentAssistant(db_path;
        provider = "openai-completions",
        model_id = "gpt-4o-mini",
        apikey = "test-key",
        timezone = "UTC",
        level = :error,
        pipeline = Claw.PipelineConfig(; kwargs...),
    )
end

function register_test_handler!(a; id = "pipeline_test_handler", channel_id = nothing)
    Claw.execute_write(a._writer,
        "INSERT OR IGNORE INTO claw_event_types (name, description) VALUES (?, ?)",
        ("pipeline_test_event", "pipeline test"))
    Claw.register_event_handler!(a, Claw.EventHandler(id, ["pipeline_test_event"], "", channel_id))
    return nothing
end

event_row(a, id::Int) = iterate(SQLite.DBInterface.execute(a.db,
    "SELECT status, attempts, last_error, next_attempt_at FROM claw_events WHERE id = ?", (id,)))[1]

count_rows(a, sql, params = ()) = Int(iterate(SQLite.DBInterface.execute(a.db,
    "SELECT COUNT(*) AS n FROM claw_events " * sql, params))[1].n)

# Swap the handler runner for the duration of `f` (same `*_FN` seam convention the
# extension tests use), so the pipeline can be exercised without an LLM.
function with_handler(f, runner)
    original = Claw.RUN_EVENT_HANDLER_FN[]
    Claw.RUN_EVENT_HANDLER_FN[] = runner
    try
        return f()
    finally
        Claw.RUN_EVENT_HANDLER_FN[] = original
    end
end

const FAST = (; scan_interval_s = 0.05, min_refire_gap_s = 0.05, lane_backlog_warn_s = 0.5)

# ─── §1.7 SQLite ownership + migrations ───

@testset "SQLite writer + user_version migrations" begin
    path = tempname() * ".sqlite"
    a = make_assistant(path)
    try
        @test Claw._get_user_version(a.db) == Claw.CLAW_SCHEMA_VERSION
        @test a._writer.owns_db     # real file ⇒ dedicated write connection

        tables = Set{String}()
        for row in SQLite.DBInterface.execute(a.db, "SELECT name FROM sqlite_master WHERE type='table'")
            push!(tables, row.name)
        end
        @test "claw_events" in tables
        @test "claw_source_journal" in tables

        # Writes land on the writer connection and are visible to readers.
        Claw.execute_write(a._writer,
            "INSERT INTO claw_source_journal (ts, source, action, detail) VALUES (?, ?, ?, ?)",
            (time(), "test", "probe", "x"))
        n = Claw.with_read(a._readers) do db
            Int(iterate(SQLite.DBInterface.execute(db, "SELECT COUNT(*) AS n FROM claw_source_journal"))[1].n)
        end
        @test n == 1

        # Concurrent writers are serialized by the single writer task, and a
        # transaction on the write connection succeeds even with live readers.
        tasks = [Threads.@spawn Claw.execute_write(a._writer,
            "INSERT INTO claw_source_journal (ts, source, action, detail) VALUES (?, ?, ?, ?)",
            (time(), "test", "concurrent", string(i))) for i in 1:20]
        foreach(wait, tasks)
        @test count_rows(a, "") == 0
        journal_n = Int(iterate(SQLite.DBInterface.execute(a.db,
            "SELECT COUNT(*) AS n FROM claw_source_journal"))[1].n)
        @test journal_n == 21

        # Re-running migrations on an existing database is a no-op.
        @test Claw._migrate_claw_schema!(a.db) == Claw.CLAW_SCHEMA_VERSION
    finally
        Claw.shutdown!(a; timeout_s = 5)
        rm(path; force = true)
        rm(path * "-wal"; force = true)
        rm(path * "-shm"; force = true)
    end
end

@testset "pipeline writes are committed, not parked in an open statement" begin
    # `DBInterface.execute` hands back a lazy cursor; for a write the statement
    # stays in progress (uncommitted, holding its lock) until something else runs on
    # the connection. A crash right after a write would therefore lose it.
    path = tempname() * ".sqlite"
    a = make_assistant(path; FAST...)
    Claw.CURRENT_ASSISTANT[] = a
    ch = RecordingChannel("commit-check")
    a._channels[ch.id] = ch
    try
        id = Claw.submit_event!(a, PipelineTestEvent("durable", ch))
        row = Claw._claim_event!(a, id)
        @test row !== nothing
        Claw._finish_event!(a, id, "done")     # last statement on the writer

        probe = SQLite.DB(path)                # an independent connection
        status = nothing
        for r in SQLite.DBInterface.execute(probe,
                "SELECT status FROM claw_events WHERE id = ?", (id,))
            status = String(r.status)
        end
        close(probe)
        @test status == "done"
    finally
        Claw.shutdown!(a; timeout_s = 5)
        rm(path; force = true)
        rm(path * "-wal"; force = true)
        rm(path * "-shm"; force = true)
    end
end

# ─── §1.3 Failure classification + retry policy (pure) ───

@testset "classify_eval_failure + retry policy table" begin
    # Captured shapes, not spec-shaped fabrications: Anthropic returns 429 with a
    # rate_limit_error body, and a rotated key comes back as 401 with an
    # invalid_request_error body (no `invalid_grant` anywhere).
    rate_limited = HTTP.StatusError(429, "POST", "/v1/messages",
        HTTP.Response(429, ["retry-after" => "23"];
            body = """{"type":"error","error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded your per-minute rate limit"}}"""))
    rotated_key = HTTP.StatusError(401, "POST", "/v1/messages",
        HTTP.Response(401; body = """{"type":"error","error":{"type":"invalid_request_error","message":"invalid x-api-key"}}"""))
    overloaded = HTTP.StatusError(529, "POST", "/v1/messages",
        HTTP.Response(529; body = """{"type":"error","error":{"type":"overloaded_error"}}"""))

    @test Claw.classify_eval_failure(rate_limited) == :rate_limit
    @test Claw.classify_eval_failure(rotated_key) == :auth
    @test Claw.classify_eval_failure(overloaded) == :overloaded
    @test Claw.classify_eval_failure(HTTP.StatusError(402, "POST", "/x", HTTP.Response(402))) == :billing
    @test Claw.classify_eval_failure(Agentif.AbortEvaluation()) == :aborted
    @test Claw.classify_eval_failure(EOFError()) == :network
    @test Claw.classify_eval_failure(ErrorException("read timed out after 30s")) == :network
    @test Claw.classify_eval_failure(ErrorException("your credit balance is too low")) == :billing
    @test Claw.classify_eval_failure(ErrorException("kaboom")) == :unknown
    # Wrapped layers unwrap to the same class.
    failed_task = Threads.@spawn throw(rate_limited)
    @test timedwait(() -> istaskdone(failed_task), 5.0) == :ok
    @test Claw.classify_eval_failure(TaskFailedException(failed_task)) == :rate_limit

    cfg = Claw.PipelineConfig()
    @test cfg.retry_backoff_s == [30.0, 60.0, 300.0, 900.0, 3600.0]
    for class in (:rate_limit, :overloaded, :network)
        @test Claw._retry_decision(cfg, class, 1) == (:retry, 30.0)
        @test Claw._retry_decision(cfg, class, 2) == (:retry, 60.0)
        @test Claw._retry_decision(cfg, class, 3) == (:retry, 300.0)
        @test Claw._retry_decision(cfg, class, 4) == (:retry, 900.0)
        @test Claw._retry_decision(cfg, class, 5)[1] == :dead   # max 5 attempts
    end
    # :auth / :billing never retry.
    @test Claw._retry_decision(cfg, :auth, 1) == (:dead, 0.0)
    @test Claw._retry_decision(cfg, :billing, 1) == (:dead, 0.0)
    # :unknown retries twice, then dies.
    @test Claw._retry_decision(cfg, :unknown, 1)[1] == :retry
    @test Claw._retry_decision(cfg, :unknown, 2)[1] == :retry
    @test Claw._retry_decision(cfg, :unknown, 3)[1] == :dead
    # :aborted returns to pending without charging an attempt.
    @test Claw._retry_decision(cfg, :aborted, 4) == (:pending, 0.0)
    # The 2s minimum refire gap wins over a shorter configured backoff.
    fast = Claw.PipelineConfig(; retry_backoff_s = [0.01])
    @test Claw._retry_decision(fast, :network, 1)[2] == 2.0
end

# ─── §1.1 Duplicate delivery ───

@testset "duplicate delivery ⇒ exactly one evaluation" begin
    a = make_assistant(":memory:"; FAST...)
    Claw.CURRENT_ASSISTANT[] = a
    ch = RecordingChannel("dup-1")
    a._channels[ch.id] = ch
    register_test_handler!(a)
    runs = Threads.Atomic{Int}(0)

    with_handler((args...; kwargs...) -> (Threads.atomic_add!(runs, 1); nothing)) do
        Claw.start_event_loop!(a)
        id1 = Claw.submit_event!(a, PipelineTestEvent("hello", ch); dedup_key = "delivery-1")
        id2 = Claw.submit_event!(a, PipelineTestEvent("hello", ch); dedup_key = "delivery-1")
        @test id1 isa Int
        @test id2 === nothing                       # UNIQUE dedup_key ⇒ no-op
        @test count_rows(a, "WHERE dedup_key = ?", ("delivery-1",)) == 1
        @test timedwait(() -> runs[] == 1, 10.0) == :ok
        sleep(0.4)                                   # nothing re-fires it
        @test runs[] == 1
        @test event_row(a, id1).status == "done"
    end
    Claw.shutdown!(a; timeout_s = 5)
end

# ─── §1.4 Lanes ───

@testset "lane serialization: same channel never overlaps" begin
    a = make_assistant(":memory:"; max_concurrent_evals = 4, FAST...)
    Claw.CURRENT_ASSISTANT[] = a
    ch = RecordingChannel("lane-serial")
    a._channels[ch.id] = ch
    register_test_handler!(a)

    intervals = Tuple{Float64, Float64}[]
    ilock = ReentrantLock()
    runner = function (assistant, ev, handler; kwargs...)
        t0 = time()
        sleep(0.25)
        t1 = time()
        lock(ilock) do
            push!(intervals, (t0, t1))
        end
        return nothing
    end

    with_handler(runner) do
        Claw.start_event_loop!(a)
        Claw.submit_event!(a, PipelineTestEvent("one", ch))
        Claw.submit_event!(a, PipelineTestEvent("two", ch))
        @test timedwait(() -> length(intervals) == 2, 15.0) == :ok
    end
    sort!(intervals; by = first)
    # Observed timestamps must not overlap: the second eval starts only after the
    # first finished. Before lanes, both ran concurrently against one session.
    @test intervals[1][2] <= intervals[2][1]
    Claw.shutdown!(a; timeout_s = 5)
end

@testset "lanes: different channels run concurrently under the global cap" begin
    a = make_assistant(":memory:"; max_concurrent_evals = 4, FAST...)
    Claw.CURRENT_ASSISTANT[] = a
    ch1 = RecordingChannel("lane-a")
    ch2 = RecordingChannel("lane-b")
    a._channels[ch1.id] = ch1
    a._channels[ch2.id] = ch2
    register_test_handler!(a)

    inflight = Threads.Atomic{Int}(0)
    peak = Threads.Atomic{Int}(0)
    runner = function (assistant, ev, handler; kwargs...)
        n = Threads.atomic_add!(inflight, 1) + 1
        while true
            p = peak[]
            n <= p && break
            Threads.atomic_cas!(peak, p, n) == p && break
        end
        sleep(0.25)
        Threads.atomic_sub!(inflight, 1)
        return nothing
    end

    with_handler(runner) do
        Claw.start_event_loop!(a)
        Claw.submit_event!(a, PipelineTestEvent("a", ch1))
        Claw.submit_event!(a, PipelineTestEvent("b", ch2))
        @test timedwait(() -> count_rows(a, "WHERE status='done'") == 2, 15.0) == :ok
    end
    @test peak[] == 2
    Claw.shutdown!(a; timeout_s = 5)
end

@testset "global max_concurrent_evals caps total in-flight evaluations" begin
    a = make_assistant(":memory:"; max_concurrent_evals = 2, FAST...)
    Claw.CURRENT_ASSISTANT[] = a
    channels = [RecordingChannel("cap-$i") for i in 1:4]
    for ch in channels
        a._channels[ch.id] = ch
    end
    register_test_handler!(a)

    inflight = Threads.Atomic{Int}(0)
    peak = Threads.Atomic{Int}(0)
    runner = function (assistant, ev, handler; kwargs...)
        n = Threads.atomic_add!(inflight, 1) + 1
        while true
            p = peak[]
            n <= p && break
            Threads.atomic_cas!(peak, p, n) == p && break
        end
        sleep(0.2)
        Threads.atomic_sub!(inflight, 1)
        return nothing
    end

    with_handler(runner) do
        Claw.start_event_loop!(a)
        for ch in channels
            Claw.submit_event!(a, PipelineTestEvent("x", ch))
        end
        @test timedwait(() -> count_rows(a, "WHERE status='done'") == 4, 20.0) == :ok
    end
    @test peak[] <= 2
    Claw.shutdown!(a; timeout_s = 5)
end

@testset "idle lanes are retired so tasks do not accumulate forever" begin
    # Lane keys include thread ids, so without reaping an always-on instance grows
    # one task + one channel per conversation it has ever seen.
    a = make_assistant(":memory:"; lane_idle_timeout_s = 0.2, FAST...)
    Claw.CURRENT_ASSISTANT[] = a
    ch = RecordingChannel("ephemeral")
    a._channels[ch.id] = ch
    register_test_handler!(a)

    with_handler((args...; kwargs...) -> nothing) do
        Claw.start_event_loop!(a)
        Claw.submit_event!(a, PipelineTestEvent("x", ch))
        @test timedwait(() -> count_rows(a, "WHERE status='done'") == 1, 10.0) == :ok
        @test haskey(a._lanes, "ephemeral")
        @test timedwait(() -> !haskey(a._lanes, "ephemeral"), 10.0) == :ok
        # A new event after reaping still gets handled (the lane is recreated).
        Claw.submit_event!(a, PipelineTestEvent("y", ch))
        @test timedwait(() -> count_rows(a, "WHERE status='done'") == 2, 10.0) == :ok
    end
    Claw.shutdown!(a; timeout_s = 5)
end

@testset "event lanes" begin
    ch = RecordingChannel("lane-key")
    @test Claw.event_lane(PipelineTestEvent("x", ch)) == "lane-key"
    @test Claw.event_lane(Claw.TempusJobEvent("tempus_job:daily")) == "cron"
    @test Claw.event_lane(Claw.SubagentOutputEvent("subagent:x", "x", "out")) == "async"
    @test Claw.event_lane(Claw.PtyOutputEvent("pty:x", "x", "out", nothing)) == "async"
    @test Claw.event_lane(Claw.WorkerOutputEvent("worker:x", "x", "out")) == "async"
end

# ─── §1.3 Retry + dead-letter (integration) ───

@testset "retryable failure retries then dead-letters with an apology" begin
    a = make_assistant(":memory:";
        retry_backoff_s = [0.05, 0.05], max_attempts = 3, min_refire_gap_s = 0.05,
        scan_interval_s = 0.05, lane_backlog_warn_s = 5.0)
    Claw.CURRENT_ASSISTANT[] = a
    ch = RecordingChannel("retry-1")
    a._channels[ch.id] = ch
    register_test_handler!(a)
    attempts = Threads.Atomic{Int}(0)
    boom = HTTP.StatusError(429, "POST", "/v1/messages",
        HTTP.Response(429; body = """{"type":"error","error":{"type":"rate_limit_error"}}"""))

    local id
    with_handler((args...; kwargs...) -> (Threads.atomic_add!(attempts, 1); throw(boom))) do
        Claw.start_event_loop!(a)
        id = Claw.submit_event!(a, PipelineTestEvent("boom", ch))
        @test timedwait(() -> event_row(a, id).status == "dead", 20.0) == :ok
    end
    row = event_row(a, id)
    @test row.status == "dead"
    @test row.attempts == 3                    # initial + 2 retries, then dead
    @test attempts[] == 3
    @test occursin("rate_limit", String(row.last_error))
    # Best-effort apology on the originating channel.
    @test timedwait(() -> any(m -> occursin("event #$(id)", m), sent_messages(ch)), 5.0) == :ok
    Claw.shutdown!(a; timeout_s = 5)
end

@testset ":auth failure dead-letters without retrying" begin
    a = make_assistant(":memory:";
        retry_backoff_s = [0.05], max_attempts = 5, min_refire_gap_s = 0.05,
        scan_interval_s = 0.05, lane_backlog_warn_s = 5.0)
    Claw.CURRENT_ASSISTANT[] = a
    ch = RecordingChannel("auth-1")
    a._channels[ch.id] = ch
    register_test_handler!(a)
    attempts = Threads.Atomic{Int}(0)
    rotated_key = HTTP.StatusError(401, "POST", "/v1/messages",
        HTTP.Response(401; body = """{"type":"error","error":{"type":"invalid_request_error","message":"invalid x-api-key"}}"""))

    local id
    with_handler((args...; kwargs...) -> (Threads.atomic_add!(attempts, 1); throw(rotated_key))) do
        Claw.start_event_loop!(a)
        id = Claw.submit_event!(a, PipelineTestEvent("nope", ch))
        @test timedwait(() -> event_row(a, id).status == "dead", 20.0) == :ok
        sleep(0.5)                              # give the scanner room to re-fire
    end
    @test attempts[] == 1                       # credentials will not fix themselves
    @test event_row(a, id).attempts == 1
    Claw.shutdown!(a; timeout_s = 5)
end

@testset "poison event stops instead of spinning" begin
    a = make_assistant(":memory:";
        retry_backoff_s = [0.05], max_attempts = 2, unknown_max_attempts = 2,
        min_refire_gap_s = 0.05, scan_interval_s = 0.05, lane_backlog_warn_s = 5.0)
    Claw.CURRENT_ASSISTANT[] = a
    ch = RecordingChannel("poison")
    a._channels[ch.id] = ch
    register_test_handler!(a)
    attempts = Threads.Atomic{Int}(0)

    local id
    with_handler((args...; kwargs...) -> (Threads.atomic_add!(attempts, 1); error("kaboom"))) do
        Claw.start_event_loop!(a)
        id = Claw.submit_event!(a, PipelineTestEvent("poison", ch))
        @test timedwait(() -> event_row(a, id).status == "dead", 20.0) == :ok
        sleep(0.5)
    end
    @test attempts[] == 2
    @test count_rows(a, "WHERE status='dead'") == 1
    Claw.shutdown!(a; timeout_s = 5)
end

# ─── §1.1 Kill and recover ───

@testset "kill-and-recover: claimed events return to pending and re-run" begin
    path = tempname() * ".sqlite"
    crashed = make_assistant(path; lease_duration_s = 0.3, FAST...)
    Claw.CURRENT_ASSISTANT[] = crashed
    ch = RecordingChannel("crash-ch")
    crashed._channels[ch.id] = ch
    register_test_handler!(crashed)

    id = Claw.submit_event!(crashed, PipelineTestEvent("survive me", ch))
    @test id isa Int
    # Simulate a worker that claimed the event and then died mid-eval: the row is
    # 'running' with a lease, and nothing ever finishes it.
    claimed = Claw._claim_event!(crashed, id)
    @test claimed !== nothing
    @test event_row(crashed, id).status == "running"
    Claw.close_writer!(crashed._writer)
    Claw.close_readers!(crashed._readers)
    close(crashed.db)
    sleep(0.4)                                   # lease expires

    recovered = make_assistant(path; lease_duration_s = 30.0, FAST...)
    Claw.CURRENT_ASSISTANT[] = recovered
    ch2 = RecordingChannel("crash-ch")
    recovered._channels[ch2.id] = ch2            # source re-registers its channel
    seen = String[]
    runner = function (assistant, ev, handler; kwargs...)
        push!(seen, Claw.event_content(ev))
        return nothing
    end

    try
        with_handler(runner) do
            Claw.start_event_loop!(recovered)
            @test Claw._recover_events!(recovered) >= 1
            @test timedwait(() -> length(seen) == 1, 20.0) == :ok
        end
        # Rehydrated through the channel registry, not the (dead) live object.
        @test seen == ["survive me"]
        @test event_row(recovered, id).status == "done"
        @test event_row(recovered, id).attempts == 2   # the crashed claim counts
    finally
        Claw.shutdown!(recovered; timeout_s = 5)
        rm(path; force = true)
        rm(path * "-wal"; force = true)
        rm(path * "-shm"; force = true)
    end
end

# ─── §1.2 Rehydration ───

@testset "unregistered source stays pending instead of being dropped" begin
    a = make_assistant(":memory:"; FAST...)
    Claw.CURRENT_ASSISTANT[] = a
    register_test_handler!(a)
    runs = Threads.Atomic{Int}(0)

    local id
    with_handler((args...; kwargs...) -> (Threads.atomic_add!(runs, 1); nothing)) do
        Claw.start_event_loop!(a)
        id = Claw.submit_event!(a, UnownedEvent("orphan"))
        @test timedwait(() -> event_row(a, id).status == "done", 3.0) == :ok
    end
    @test runs[] == 1                            # live object present: hot path works

    # Now drop the live object, as a restart would, and force a replay.
    Claw._forget_live_event!(a, id)
    Claw.execute_write(a._writer,
        "UPDATE claw_events SET status='pending', next_attempt_at=? WHERE id=?", (time(), id))
    with_handler((args...; kwargs...) -> (Threads.atomic_add!(runs, 1); nothing)) do
        sleep(1.0)
    end
    @test runs[] == 1                            # never evaluated with a missing source
    @test event_row(a, id).status == "pending"   # and never dropped either
    @test occursin("no rehydrator", String(event_row(a, id).last_error))
    Claw.shutdown!(a; timeout_s = 5)
end

@testset "channel-event replay rebuilds via the channel registry" begin
    a = make_assistant(":memory:"; FAST...)
    Claw.CURRENT_ASSISTANT[] = a
    ch = RecordingChannel("replay-ch")
    register_test_handler!(a)

    id = Claw.submit_event!(a, PipelineTestEvent("replayed", ch))
    Claw._forget_live_event!(a, id)
    row = Claw._claim_event!(a, id)
    @test row !== nothing
    @test row.channel_id == "replay-ch"
    @test row.content == "replayed"

    # Channel not registered yet ⇒ no event, row stays recoverable.
    @test Claw.rehydrate_event(row.source, row) === nothing
    a._channels[ch.id] = ch
    replayed = Claw.rehydrate_event(row.source, row)
    @test replayed isa Claw.ReplayedChannelEvent
    @test Claw.get_name(replayed) == "pipeline_test_event"
    @test Claw.event_content(replayed) == "replayed"
    @test Agentif.channel_id(Claw.get_channel(replayed)) == "replay-ch"
    Claw.shutdown!(a; timeout_s = 5)
end

# ─── §1.5 Graceful shutdown ───

@testset "shutdown drains an in-flight evaluation" begin
    a = make_assistant(":memory:"; FAST...)
    Claw.CURRENT_ASSISTANT[] = a
    ch = RecordingChannel("drain")
    a._channels[ch.id] = ch
    register_test_handler!(a)
    started = Threads.Atomic{Bool}(false)
    finished = Threads.Atomic{Bool}(false)
    runner = function (assistant, ev, handler; kwargs...)
        started[] = true
        sleep(0.6)
        finished[] = true
        return nothing
    end

    local id
    with_handler(runner) do
        Claw.start_event_loop!(a)
        id = Claw.submit_event!(a, PipelineTestEvent("drain me", ch))
        @test timedwait(() -> started[], 10.0) == :ok
        Claw.shutdown!(a; timeout_s = 10)
    end
    @test finished[]                              # drained, not killed
    @test a._state[] == :stopped
    # Idempotent, and safe from an atexit hook.
    @test Claw.shutdown!(a; timeout_s = 1) === nothing
end

@testset "shutdown aborts stragglers and returns their claims to pending" begin
    path = tempname() * ".sqlite"
    a = make_assistant(path; FAST...)
    Claw.CURRENT_ASSISTANT[] = a
    ch = RecordingChannel("straggler")
    a._channels[ch.id] = ch
    register_test_handler!(a)
    started = Threads.Atomic{Bool}(false)
    saw_abort = Threads.Atomic{Bool}(false)
    runner = function (assistant, ev, handler; abort = nothing, kwargs...)
        started[] = true
        for _ in 1:400
            if abort !== nothing && Agentif.isaborted(abort)
                saw_abort[] = true
                throw(Agentif.AbortEvaluation())
            end
            sleep(0.02)
        end
        return nothing
    end

    local id
    try
        with_handler(runner) do
            Claw.start_event_loop!(a)
            id = Claw.submit_event!(a, PipelineTestEvent("never ends", ch))
            @test timedwait(() -> started[], 10.0) == :ok
            Claw.shutdown!(a; timeout_s = 0.5)
        end
        @test saw_abort[]
        # An aborted eval is returned to pending with no attempt charged, so the
        # next boot picks it up again.
        probe = SQLite.DB(path)
        row = iterate(SQLite.DBInterface.execute(probe,
            "SELECT status, attempts FROM claw_events WHERE id = ?", (id,)))[1]
        @test row.status == "pending"
        @test row.attempts == 0
        close(probe)
    finally
        rm(path; force = true)
        rm(path * "-wal"; force = true)
        rm(path * "-shm"; force = true)
    end
end

@testset "wait_for_shutdown unblocks when shutdown! completes" begin
    a = make_assistant(":memory:"; FAST...)
    Claw.start_event_loop!(a)
    waiter = @async Claw.wait_for_shutdown(a)
    sleep(0.1)
    @test !istaskdone(waiter)
    Claw.shutdown!(a; timeout_s = 5)
    @test timedwait(() -> istaskdone(waiter), 5.0) == :ok
end

@testset "init! wires recovery + supervision and shutdown! tears it down" begin
    path = tempname() * ".sqlite"
    # Seed a pending row as if a previous process had persisted but not run it.
    seed = make_assistant(path; FAST...)
    Claw.CURRENT_ASSISTANT[] = seed
    ch = RecordingChannel("boot-ch")
    seed._channels[ch.id] = ch
    register_test_handler!(seed)
    seeded_id = Claw.submit_event!(seed, PipelineTestEvent("from a previous life", ch))
    Claw.close_writer!(seed._writer)
    Claw.close_readers!(seed._readers)
    close(seed.db)

    seen = String[]
    a = nothing
    try
        with_handler(function (assistant, ev, handler; kwargs...)
            push!(seen, Claw.event_content(ev))
            return nothing
        end) do
            a = Claw.init!(path;
                event_sources = Claw.EventSource[],
                provider = "openai-completions", model_id = "gpt-4o-mini", apikey = "test-key",
                level = :error, install_signal_handlers = false,
                pipeline = Claw.PipelineConfig(; FAST...),
            )
            a._channels[ch.id] = ch      # the owning source re-registers its channel
            @test a._state[] == :running
            @test !a._signal_handler_installed[]
            @test timedwait(() -> length(seen) == 1, 20.0) == :ok
        end
        @test seen == ["from a previous life"]
    finally
        a === nothing || Claw.shutdown!(a; timeout_s = 10)
        rm(path; force = true)
        rm(path * "-wal"; force = true)
        rm(path * "-shm"; force = true)
    end
end

# ─── §1.6 Source supervision ───

mutable struct FlakySource <: Claw.EventSource
    starts::Threads.Atomic{Int}
    fail::Bool
    healthy::Threads.Atomic{Bool}
end
FlakySource(; fail::Bool = true) = FlakySource(Threads.Atomic{Int}(0), fail, Threads.Atomic{Bool}(true))

Claw.get_channels(::FlakySource) = Agentif.AbstractChannel[]
Claw.get_event_types(::FlakySource) = Claw.EventType[]
Claw.get_event_handlers(::FlakySource) = Claw.EventHandler[]
Claw.get_tools(::FlakySource) = Agentif.AgentTool[]
Claw.is_healthy(s::FlakySource) = s.healthy[]
function Claw.start!(s::FlakySource, ::Claw.AgentAssistant)
    Threads.atomic_add!(s.starts, 1)
    s.fail || return nothing
    return Threads.@spawn (sleep(0.01); error("source blew up"))
end

struct InvalidSource <: Claw.EventSource end
Claw.get_channels(::InvalidSource) = Agentif.AbstractChannel[]
Claw.get_event_types(::InvalidSource) = Claw.EventType[]
Claw.get_event_handlers(::InvalidSource) = Claw.EventHandler[]
Claw.get_tools(::InvalidSource) = Agentif.AgentTool[]
Claw.validate_source(::InvalidSource) = error("missing MY_TOKEN")
Claw.start!(::InvalidSource, ::Claw.AgentAssistant) = error("should never be started")

journal_count(a, source, action) = Int(iterate(SQLite.DBInterface.execute(a.db,
    "SELECT COUNT(*) AS n FROM claw_source_journal WHERE source = ? AND action = ?",
    (source, action)))[1].n)

@testset "source restarts are capped and never take down the others" begin
    a = make_assistant(":memory:";
        source_restart_cap = 2, source_restart_backoff_s = 0.02,
        source_health_interval_s = 3600.0, FAST...)
    Claw.CURRENT_ASSISTANT[] = a
    flaky = FlakySource()
    healthy = FlakySource(; fail = false)
    invalid = InvalidSource()

    Claw.start_event_loop!(a)
    Claw.start_sources!(a, Claw.EventSource[invalid, flaky, healthy])

    # Initial start + 2 restarts, then the budget is exhausted.
    @test timedwait(() -> flaky.starts[] == 3, 15.0) == :ok
    sleep(0.5)
    @test flaky.starts[] == 3
    @test journal_count(a, "flakysource", "restart_cap_exceeded") == 1

    # An invalid source is never started and does not abort the others.
    @test healthy.starts[] == 1
    @test journal_count(a, "invalidsource", "invalid_config") == 1
    @test journal_count(a, "flakysource", "crashed") >= 1
    invalid_ss = only(filter(ss -> ss.tag == "invalidsource", a._sources))
    @test invalid_ss.stopped[]

    Claw.shutdown!(a; timeout_s = 5)
end

@testset "unhealthy source is restarted under the same budget" begin
    a = make_assistant(":memory:";
        source_restart_cap = 1, source_restart_backoff_s = 0.02,
        source_health_interval_s = 0.05, FAST...)
    Claw.CURRENT_ASSISTANT[] = a
    src = FlakySource(; fail = false)   # start! returns nothing (fire and forget)

    Claw.start_event_loop!(a)
    Claw.start_sources!(a, Claw.EventSource[src])
    @test timedwait(() -> src.starts[] == 1, 5.0) == :ok

    src.healthy[] = false
    @test timedwait(() -> src.starts[] == 2, 15.0) == :ok
    @test journal_count(a, "flakysource", "unhealthy") >= 1

    # Budget of 1 is now spent: further unhealthy polls give up rather than loop.
    @test timedwait(() -> journal_count(a, "flakysource", "restart_cap_exceeded") >= 1, 15.0) == :ok
    sleep(0.4)
    @test src.starts[] == 2

    Claw.shutdown!(a; timeout_s = 5)
end

# ─── §1.8 Async completions reach humans ───

@testset "async sessions notify the originating channel on their own branch" begin
    a = make_assistant(":memory:"; FAST...)
    Claw.CURRENT_ASSISTANT[] = a
    origin = RecordingChannel("origin-chat")
    a._channels[origin.id] = origin
    es = Claw.LLMToolsEventSource(a.config)

    session = Agentif.with_channel(origin) do
        Claw._register_async_session!(es, "digest", :subagent, "subagent:digest", "Summarize")
    end
    @test session.status == "running"

    async_ch = a._channels["async:digest"]
    @test async_ch isa Claw.AsyncSessionChannel
    @test async_ch.origin_channel_id == "origin-chat"
    # Its own branch, not the shared "parent" one.
    @test Agentif.branch_id(async_ch) == "async:digest"
    @test Agentif.branch_id(async_ch) != "parent"

    handler_row = iterate(SQLite.DBInterface.execute(a.db,
        "SELECT channel_id FROM claw_event_handlers WHERE id = ?", ("subagent:digest",)))[1]
    @test handler_row.channel_id == "async:digest"

    # The completion actually reaches the human who asked for it.
    Agentif.send_message(async_ch, "here is your digest")
    @test sent_messages(origin) == ["here is your digest"]

    # Buffered streaming flushes through the origin on close.
    Agentif.start_streaming(async_ch)
    Agentif.append_to_stream(async_ch, "partial ")
    Agentif.append_to_stream(async_ch, "result")
    Agentif.finish_streaming(async_ch)
    Agentif.close_channel(async_ch)
    @test sent_messages(origin)[end] == "partial result"

    Claw._cleanup_session!(es, "digest")
    @test !haskey(a._channels, "async:digest")
    Claw.shutdown!(a; timeout_s = 5)
end

# ─── §1.4/§1.8 PTY coalescing + exit codes ───

@testset "PTY output truncation keeps a bounded, valid tail" begin
    text = "abcdefghij" ^ 10                        # 100 bytes
    kept = Claw._truncate_pty_output(text, 40)
    @test endswith(kept, text[end - 39:end])
    @test occursin("bytes of earlier output truncated", kept)
    @test ncodeunits(kept) < ncodeunits(text) + 100
    @test Claw._truncate_pty_output("short", 1000) == "short"
    # Never splits a multi-byte character.
    unicode = "héllo wörld ✓ " ^ 20
    trimmed = Claw._truncate_pty_output(unicode, 50)
    @test isvalid(trimmed)
    @test endswith(unicode, split(trimmed, "\n")[end])
end

@testset "PTY event content reports the real exit status" begin
    @test occursin("exited with code 3",
        Claw.event_content(Claw.PtyOutputEvent("pty:x", "x", "done", 3, true)))
    @test occursin("status unavailable",
        Claw.event_content(Claw.PtyOutputEvent("pty:x", "x", "done", nothing, true)))
    # Mid-stream output is not an exit notice.
    @test !occursin("exited", Claw.event_content(Claw.PtyOutputEvent("pty:x", "x", "chunk", nothing, false)))
end

if !Sys.iswindows()
    @testset "PTY output is coalesced into few events with the real exit code" begin
        a = make_assistant(":memory:"; pty_notify_interval_s = 1.5, pty_max_event_bytes = 4096, FAST...)
        Claw.CURRENT_ASSISTANT[] = a
        es = Claw.LLMToolsEventSource(a.config)
        tools = Claw.get_tools(es)
        start_pty = tools[findfirst(t -> t.name == "start_pty", tools)].func

        # ~4s of chatty output: the 0.5s poll used to emit ~8 events (each a full
        # LLM evaluation); coalescing must bound that.
        start_pty("chatty", "for i in \$(seq 1 40); do echo line-\$i; sleep 0.1; done; exit 3",
            nothing, nothing, nothing)
        @test timedwait(() -> count_rows(a, "WHERE name = ?", ("pty:chatty",)) >= 1, 20.0) == :ok
        @test timedwait(() -> begin
            rows = SQLite.DBInterface.execute(a.db,
                "SELECT payload FROM claw_events WHERE name = ? ORDER BY id", ("pty:chatty",))
            any(r -> occursin("Process exited", String(r.payload)) || occursin("exit_code", String(r.payload)) &&
                occursin("\"exited\":true", String(r.payload)), rows)
        end, 30.0) == :ok

        n = count_rows(a, "WHERE name = ?", ("pty:chatty",))
        @test 1 <= n <= 5                          # not one per 0.5s poll
        last_payload = String(iterate(SQLite.DBInterface.execute(a.db,
            "SELECT payload FROM claw_events WHERE name = ? ORDER BY id DESC LIMIT 1", ("pty:chatty",)))[1].payload)
        @test occursin("[Process exited with code 3]", last_payload)
        @test occursin("line-40", last_payload)
        Claw.shutdown!(a; timeout_s = 5)
    end
end

# ─── Payload round-trip ───

@testset "event payload round-trip" begin
    encoded = Claw._encode_payload("ch-1", "hello", Dict{String, Any}("direct_ping" => true, "n" => 3))
    cid, content, extra = Claw._decode_payload(encoded)
    @test cid == "ch-1"
    @test content == "hello"
    @test extra["direct_ping"] == true
    @test extra["n"] == 3
    cid2, content2, _ = Claw._decode_payload(Claw._encode_payload(nothing, "", Dict{String, Any}()))
    @test cid2 === nothing
    @test content2 == ""
    # Unparseable payload degrades instead of throwing.
    @test Claw._decode_payload("not json")[2] == ""
end


# ── SQLite cursor hygiene ────────────────────────────────────────────────────
# Two bugs, same root cause: SQLite.DBInterface.execute returns a lazy cursor, and a
# statement left mid-step holds its lock / pins its read snapshot until GC finalizes
# it (which is why both were intermittent).

@testset "row-returning PRAGMA does not lock out other connections" begin
    path = joinpath(mktempdir(), "pragma.sqlite")
    db = SQLite.DB(path)
    Claw._init_claw_schema!(db)          # runs PRAGMA journal_mode=WAL, which returns a row
    second = SQLite.DB(path)
    # Before the fix this threw SQLiteException("database is locked"), and no
    # busy_timeout could rescue it: nothing ever released the parked statement.
    @test (SQLite.execute(second, "CREATE TABLE IF NOT EXISTS probe (v TEXT)"); true)
    @test (SQLite.execute(second, "INSERT INTO probe VALUES ('ok')"); true)
end

@testset "_fetch_one releases the read snapshot" begin
    path = joinpath(mktempdir(), "snapshot.sqlite")
    db = SQLite.DB(path)
    Claw._init_claw_schema!(db)
    Claw._set_agent_metadata!(db, "probe-key", "first")
    # Take a first row through the helper; it must not pin this connection's snapshot.
    @test Claw._get_agent_metadata(db, "probe-key") == "first"

    writer = SQLite.DB(path)
    SQLite.execute(writer, "INSERT OR REPLACE INTO claw_agent_metadata (key, value, updated_at) VALUES ('probe-key2', 'second', 0.0)")

    # With a parked cursor this connection would still see only the pre-write snapshot.
    @test Claw._get_agent_metadata(db, "probe-key2") == "second"
end

end # module PipelineTests
