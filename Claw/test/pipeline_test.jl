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

function status_error(status::Integer;
    headers = Pair{String, String}[],
    body::AbstractString = "")
    request = HTTP.Request("POST", "/v1/messages")
    return HTTP.StatusError(HTTP.Response(status, headers; body, request))
end

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

struct NamedPipelineEvent <: Claw.ChannelEvent
    name::String
    content::String
    channel::RecordingChannel
end
Claw.get_name(ev::NamedPipelineEvent) = ev.name
Claw.get_channel(ev::NamedPipelineEvent) = ev.channel
Claw.event_content(ev::NamedPipelineEvent) = ev.content

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

event_row(a, id::Int) = Claw._fetch_one(a.db,
    "SELECT status, attempts, last_error, next_attempt_at FROM claw_events WHERE id = ?", (id,))

count_rows(a, sql, params = ()) =
    Int(Claw._fetch_one(a.db, "SELECT COUNT(*) AS n FROM claw_events " * sql, params).n)

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
        # Session writes must not run on the handle that serves Claw's reads: a
        # lazy read cursor pins that connection to an old WAL snapshot, and a
        # write from a pinned handle can no longer upgrade once another
        # connection commits (it fails with "database is locked" even after
        # waiting out busy_timeout).
        @test a.session_store.db !== a.db
        @test a.session_store.db !== a._writer.db

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
            Int(Claw._fetch_one(db, "SELECT COUNT(*) AS n FROM claw_source_journal").n)
        end
        @test n == 1

        # Concurrent writers are serialized by the single writer task, and a
        # transaction on the write connection succeeds even with live readers.
        tasks = [Threads.@spawn Claw.execute_write(a._writer,
            "INSERT INTO claw_source_journal (ts, source, action, detail) VALUES (?, ?, ?, ?)",
            (time(), "test", "concurrent", string(i))) for i in 1:20]
        foreach(wait, tasks)
        @test count_rows(a, "") == 0
        journal_n = Int(Claw._fetch_one(a.db,
            "SELECT COUNT(*) AS n FROM claw_source_journal").n)
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

@testset "session persistence shares the pipeline writer" begin
    path = tempname() * ".sqlite"
    a = make_assistant(path)
    try
        # Pause inside LocalSearch after it has read the document metadata and
        # before it writes the embedding rows. With a second write connection,
        # the journal commit below makes that read snapshot stale and the chunk
        # insert fails with SQLITE_BUSY_SNAPSHOT (extended code 517).
        embedding_started = Base.Event()
        search_stores = Any[a.session_store.search_store]
        if hasproperty(a.session_store, :write_search_store)
            push!(search_stores, a.session_store.write_search_store)
        end
        unique!(search_stores)
        for search_store in search_stores
            dims = search_store.dimensions
            search_store.embed = texts -> begin
                notify(embedding_started)
                sleep(0.15)
                zeros(Float32, dims, length(texts))
            end
        end

        n = 8
        start = Base.Event()
        session_errors = Any[]
        session_errors_lock = ReentrantLock()
        tasks = map(1:n) do i
            Threads.@spawn begin
                wait(start)
                entry = Agentif.SessionEntry(;
                    id = "contention-$i",
                    messages = Agentif.AgentMessage[Agentif.UserMessage("message $i")],
                )
                try
                    Agentif.append_entry!(a.session_store, entry)
                catch e
                    lock(session_errors_lock) do
                        push!(session_errors, e)
                    end
                end
            end
        end
        writer_errors = Any[]
        writer_task = Threads.@spawn begin
            wait(embedding_started)
            for i in 1:32
                try
                    Claw.execute_write(a._writer,
                        "INSERT INTO claw_source_journal (ts, source, action, detail) VALUES (?, ?, ?, ?)",
                        (time(), "test", "session-contention", string(i)))
                catch e
                    push!(writer_errors, e)
                end
            end
        end

        notify(start)
        foreach(wait, tasks)
        wait(writer_task)

        @test isempty(session_errors)
        @test isempty(writer_errors)
        @test hasproperty(a.session_store, :write_search_store)
        @test a.session_store.write_search_store.db === a._writer.db
        @test Int(Claw._fetch_one(a.db,
            "SELECT COUNT(*) AS n FROM session_entries WHERE entry_id LIKE 'contention-%'").n) == n
        @test Int(Claw._fetch_one(a.db,
            "SELECT COUNT(*) AS n FROM documents WHERE key LIKE 'session:entry:contention-%'").n) == n
        @test Int(Claw._fetch_one(a.db,
            "SELECT COUNT(*) AS n FROM chunks WHERE hash IN (SELECT hash FROM documents WHERE key LIKE 'session:entry:contention-%')").n) == n
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

@testset "submission failures propagate so sources do not acknowledge loss" begin
    a = make_assistant(":memory:"; FAST...)
    ch = RecordingChannel("persist-failure")
    Claw.close_writer!(a._writer)
    @test_throws ErrorException Claw.submit_event!(
        a,
        PipelineTestEvent("must not be acknowledged", ch),
    )
    Claw.close_readers!(a._readers)
    close(a.db)
end

# ─── §1.3 Failure classification + retry policy (pure) ───

@testset "classify_eval_failure + retry policy table" begin
    # Captured shapes, not spec-shaped fabrications: Anthropic returns 429 with a
    # rate_limit_error body, and a rotated key comes back as 401 with an
    # invalid_request_error body (no `invalid_grant` anywhere).
    rate_limited = status_error(429;
        headers = ["retry-after" => "23"],
        body = """{"type":"error","error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded your per-minute rate limit"}}""")
    rotated_key = status_error(401;
        body = """{"type":"error","error":{"type":"invalid_request_error","message":"invalid x-api-key"}}""")
    overloaded = status_error(529;
        body = """{"type":"error","error":{"type":"overloaded_error"}}""")

    @test Claw.classify_eval_failure(rate_limited) == :rate_limit
    @test Claw.classify_eval_failure(rotated_key) == :auth
    @test Claw.classify_eval_failure(overloaded) == :overloaded
    @test Claw.classify_eval_failure(status_error(402)) == :billing
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
    @test cfg.retry_backoff_s == [30.0, 60.0, 300.0, 900.0]
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
    @test Claw._retry_decision(cfg, :unsafe_to_retry, 1) == (:dead, 0.0)
    @test Claw._retry_decision(cfg, :off_track, 1) == (:dead, 0.0)
    # Unknown and watcher-policy failures retry twice, then die.
    for class in (:unknown, :stalled, :overrun)
        @test Claw._retry_decision(cfg, class, 1)[1] == :retry
        @test Claw._retry_decision(cfg, class, 2)[1] == :retry
        @test Claw._retry_decision(cfg, class, 3)[1] == :dead
    end
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
    # max_coalesce = 1: this test is about serialization; with coalescing on, the
    # second event would fold into the first drain and there would be one eval.
    a = make_assistant(":memory:"; max_concurrent_evals = 4, max_coalesce = 1, FAST...)
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
    boom = status_error(429;
        body = """{"type":"error","error":{"type":"rate_limit_error"}}""")

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
    rotated_key = status_error(401;
        body = """{"type":"error","error":{"type":"invalid_request_error","message":"invalid x-api-key"}}""")

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
            @test timedwait(() -> event_row(recovered, id).status == "done", 20.0) == :ok
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

@testset "rehydrator failures consume the retry budget" begin
    a = make_assistant(":memory:"; retry_backoff_s = [0.05],
        unknown_max_attempts = 2, FAST...)
    Claw.CURRENT_ASSISTANT[] = a
    register_test_handler!(a)
    a._state[] = :running
    id = Claw.submit_event!(a, UnownedEvent("broken replay"))
    take!(a.event_queue)
    Claw._clear_wakeup!(a, id)
    Claw._forget_live_event!(a, id)
    Claw.register_rehydrator!("no-such-source", _ -> error("rehydrator broke"))
    try
        Claw.start_event_loop!(a)
        Claw._wake!(a, id)
        @test timedwait(() -> event_row(a, id).status == "dead", 15.0) == :ok
        row = event_row(a, id)
        @test row.attempts == 2
        @test occursin("rehydrator broke", String(row.last_error))
    finally
        lock(Claw.EVENT_REHYDRATORS_LOCK) do
            Base.delete!(Claw.EVENT_REHYDRATORS, "no-such-source")
        end
        Claw.shutdown!(a; timeout_s = 5)
    end
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
        row = Claw._fetch_one(probe,
            "SELECT status, attempts FROM claw_events WHERE id = ?", (id,))
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
            Claw.register_channels!(a, [ch])  # the owning source re-registers its channel
            @test a._state[] == :running
            @test !a._signal_handler_installed[]
            @test any(ss -> ss.source isa Claw.LLMToolsEventSource, a._sources)
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
    stops::Threads.Atomic{Int}
    fail::Bool
    healthy::Threads.Atomic{Bool}
end
FlakySource(; fail::Bool = true) = FlakySource(
    Threads.Atomic{Int}(0), Threads.Atomic{Int}(0), fail, Threads.Atomic{Bool}(true))

Claw.get_channels(::FlakySource) = Agentif.AbstractChannel[]
Claw.get_event_types(::FlakySource) = Claw.EventType[]
Claw.get_event_handlers(::FlakySource) = Claw.EventHandler[]
Claw.get_tools(::FlakySource) = Agentif.AgentTool[]
Claw.is_healthy(s::FlakySource) = s.healthy[]
Claw.stop!(s::FlakySource) = (Threads.atomic_add!(s.stops, 1); nothing)
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

journal_count(a, source, action) = Int(Claw._fetch_one(a.db,
    "SELECT COUNT(*) AS n FROM claw_source_journal WHERE source = ? AND action = ?",
    (source, action)).n)

@testset "source restarts are capped and never take down the others" begin
    a = make_assistant(":memory:";
        source_restart_cap = 2, source_restart_backoff_s = 0.1,
        source_health_interval_s = 3600.0, FAST...)
    Claw.CURRENT_ASSISTANT[] = a
    flaky = FlakySource()
    healthy = FlakySource(; fail = false)
    invalid = InvalidSource()

    Claw.start_event_loop!(a)
    started_at = time()
    Claw.start_sources!(a, Claw.EventSource[invalid, flaky, healthy])

    # Initial start + 2 restarts, then the budget is exhausted.
    @test timedwait(() -> flaky.starts[] == 3, 15.0) == :ok
    @test time() - started_at >= 0.28  # consecutive failures back off 0.1s, then 0.2s
    sleep(0.5)
    @test flaky.starts[] == 3
    @test flaky.stops[] == 1
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
    @test src.stops[] == 2

    Claw.shutdown!(a; timeout_s = 5)
end

@testset "LLMTools source cancels subagents cooperatively" begin
    a = make_assistant(":memory:"; FAST...)
    es = Claw.LLMToolsEventSource(a.config)
    abort = Agentif.Abort()
    entered = Threads.Atomic{Bool}(false)
    cleaned = Threads.Atomic{Bool}(false)
    task = Threads.@spawn begin
        entered[] = true
        while !Agentif.isaborted(abort)
            sleep(0.01)
        end
        cleaned[] = true
    end
    now = time()
    session = Claw.ClawLLMSession("cooperative", :subagent, 0, nothing, nothing,
        abort, task, "subagent:cooperative", "", now, now, "running")
    lock(es.lock) do
        es.sessions[session.name] = session
    end
    try
        @test timedwait(() -> entered[], 5.0) == :ok
        Claw.stop!(es)
        @test timedwait(() -> cleaned[], 5.0) == :ok
        @test istaskdone(task)
        @test isempty(es.sessions)
    finally
        Agentif.abort!(abort)
        timedwait(() -> istaskdone(task), 5.0)
        Claw.shutdown!(a; timeout_s = 5)
    end
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

    handler_row = Claw._fetch_one(a.db,
        "SELECT channel_id FROM claw_event_handlers WHERE id = ?", ("subagent:digest",))
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

    # Persisted async completions retain their origin route across a restart.
    completion = Claw.SubagentOutputEvent("subagent:digest", "digest", "done")
    extra = Claw.event_extra(completion)
    @test extra["origin_channel_id"] == "origin-chat"
    Base.delete!(a._channels, "async:digest")
    replayed = Claw._rehydrate_llmtools_event(Claw.EventRow(
        1,
        "llmtools",
        "subagent:digest",
        nothing,
        nothing,
        "done",
        extra,
        "async",
        1,
        a,
    ))
    @test replayed isa Claw.ReplayedEvent
    restored = a._channels["async:digest"]
    Agentif.send_message(restored, "after restart")
    @test sent_messages(origin)[end] == "after restart"

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
    @testset "PTY cleanup cannot discard unread final output" begin
        a = make_assistant(":memory:"; pty_notify_interval_s = 5.0, FAST...)
        Claw.CURRENT_ASSISTANT[] = a
        es = Claw.LLMToolsEventSource(a.config)
        tools = Claw.get_tools(es)
        start_pty = tools[findfirst(t -> t.name == "start_pty", tools)].func

        # Non-login shells start fast enough to expose the process-exit/PTY-drain
        # race. Repeat the short path so a one-shot scheduling win cannot hide it.
        for i in 1:20
            sync_output = start_pty("sync-race-$i", "printf sync-sentinel; exit 9",
                nothing, nothing, true)
            @test occursin("sync-sentinel", sync_output)
        end

        exit_gate = tempname()
        start_pty("cleanup-race",
            "printf final-sentinel; while [ ! -f '$exit_gate' ]; do sleep 0.01; done; exit 7",
            nothing, nothing, nothing)
        registry_id = lock(es.lock) do
            es.sessions["cleanup-race"].registry_id
        end
        # Hold the poller before its removal step, then let the process exit.
        # This creates the old cleanup race deterministically.
        lock(es.lock)
        try
            write(exit_gate, "exit")
            @test timedwait(() -> begin
                meta = Claw.LLMTools.get_session(Claw.LLMTools.PTY_REGISTRY, registry_id)
                meta !== nothing && !Claw.LLMTools.PtySessions.isactive(meta.session)
            end, 5.0) == :ok

            # Claw owns this session until its poller drains the PTY, so the
            # generic sweep must leave the exited session open.
            Claw.LLMTools.cleanup_exited_sessions!(Claw.LLMTools.PTY_REGISTRY)
            @test Claw.LLMTools.get_session(Claw.LLMTools.PTY_REGISTRY, registry_id) !== nothing
        finally
            unlock(es.lock)
            rm(exit_gate; force = true)
        end

        @test timedwait(() -> count_rows(a, "WHERE name = ?", ("pty:cleanup-race",)) == 1, 10.0) == :ok
        payload = String(Claw._fetch_one(a.db,
            "SELECT payload FROM claw_events WHERE name = ? ORDER BY id DESC LIMIT 1",
            ("pty:cleanup-race",)).payload)
        @test occursin("final-sentinel", payload)
        @test occursin("[Process exited with code 7]", payload)
        @test Claw.LLMTools.get_session(Claw.LLMTools.PTY_REGISTRY, registry_id) === nothing
        Claw.shutdown!(a; timeout_s = 5)
    end

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
        last_payload = String(Claw._fetch_one(a.db,
            "SELECT payload FROM claw_events WHERE name = ? ORDER BY id DESC LIMIT 1", ("pty:chatty",)).payload)
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
    @test_throws Claw.EventPayloadError Claw._decode_payload("not json")
end

@testset "corrupt persisted payload is dead-lettered" begin
    a = make_assistant(":memory:"; FAST...)
    id = Claw.execute_write(a._writer) do db
        Claw._exec!(db, """
            INSERT INTO claw_events
                (source, name, payload, status, attempts, lane, created_at, next_attempt_at)
            VALUES ('claw', 'pipeline_test_event', 'not json', 'pending', 0, 'default', ?, ?)
        """, (time(), time()))
        Int(Claw._scalar(db, "SELECT last_insert_rowid()"))
    end
    @test Claw._claim_event!(a, id) === nothing
    row = event_row(a, id)
    @test row.status == "dead"
    @test occursin("invalid persisted event payload", String(row.last_error))
    Claw.shutdown!(a; timeout_s = 5)
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

# ─── Coalescing + subscription filters in the pipeline ───

@testset "coalescing: burst on one lane folds into a demarcated batch" begin
    a = make_assistant(":memory:"; max_concurrent_evals = 4, FAST...)
    Claw.CURRENT_ASSISTANT[] = a
    ch = RecordingChannel("coalesce-lane")
    a._channels[ch.id] = ch
    register_test_handler!(a)

    seen = []
    slock = ReentrantLock()
    gate = Base.Channel{Nothing}(1)
    runner = function (assistant, ev, handler; kwargs...)
        lock(slock) do
            push!(seen, ev)
        end
        take!(gate)
        return nothing
    end
    with_handler(runner) do
        Claw.start_event_loop!(a)
        Claw.submit_event!(a, PipelineTestEvent("one", ch))
        @test timedwait(() -> length(seen) == 1, 15.0) == :ok
        # These three arrive while the first evaluation is still running, so they
        # pile up on the lane and the next drain folds them into one batch.
        Claw.submit_event!(a, PipelineTestEvent("two", ch))
        Claw.submit_event!(a, PipelineTestEvent("three", ch))
        Claw.submit_event!(a, PipelineTestEvent("four", ch))
        @test timedwait(() -> begin
            lane = get(a._lanes, "coalesce-lane", nothing)
            lane !== nothing && lane.depth[] == 3
        end, 15.0) == :ok
        put!(gate, nothing)
        @test timedwait(() -> length(seen) == 2, 15.0) == :ok
        put!(gate, nothing)
        @test timedwait(() -> count_rows(a, "WHERE status='done'") == 4, 15.0) == :ok
    end
    @test length(seen) == 2
    @test seen[1] isa PipelineTestEvent
    batch = seen[2]
    @test batch isa Claw.ChannelEventBatch
    @test length(Claw.batch_events(batch)) == 3
    @test Claw.get_channel(batch) === ch
    content = Claw.event_content(batch)
    @test occursin("3 'pipeline_test_event' events", content)
    @test occursin("--- Event 1 of 3 ---\ntwo", content)
    @test occursin("--- Event 2 of 3 ---\nthree", content)
    @test occursin("--- Event 3 of 3 ---\nfour", content)
    Claw.shutdown!(a; timeout_s = 5)
end

@testset "coalescing: filters run per event before the batch forms" begin
    a = make_assistant(":memory:"; max_concurrent_evals = 4, FAST...)
    Claw.CURRENT_ASSISTANT[] = a
    ch = RecordingChannel("filter-lane")
    a._channels[ch.id] = ch
    Claw.execute_write(a._writer,
        "INSERT OR IGNORE INTO claw_event_types (name, description) VALUES (?, ?)",
        ("pipeline_test_event", "pipeline test"))
    Claw.register_event_handler!(a, Claw.EventHandler(
        "filtering_handler", ["pipeline_test_event"], "";
        filter = Claw.EventFilter(:regex, "keep")))

    seen = []
    slock = ReentrantLock()
    gate = Base.Channel{Nothing}(1)
    runner = function (assistant, ev, handler; kwargs...)
        lock(slock) do
            push!(seen, ev)
        end
        take!(gate)
        return nothing
    end
    with_handler(runner) do
        Claw.start_event_loop!(a)
        Claw.submit_event!(a, PipelineTestEvent("keep-1", ch))
        @test timedwait(() -> length(seen) == 1, 15.0) == :ok
        Claw.submit_event!(a, PipelineTestEvent("drop-2", ch))
        Claw.submit_event!(a, PipelineTestEvent("keep-3", ch))
        Claw.submit_event!(a, PipelineTestEvent("drop-4", ch))
        @test timedwait(() -> begin
            lane = get(a._lanes, "filter-lane", nothing)
            lane !== nothing && lane.depth[] == 3
        end, 15.0) == :ok
        put!(gate, nothing)
        @test timedwait(() -> length(seen) == 2, 15.0) == :ok
        put!(gate, nothing)
        # Filtered events complete too: nothing stays pending, nothing dead.
        @test timedwait(() -> count_rows(a, "WHERE status='done'") == 4, 15.0) == :ok
        # A drain whose events are all filtered runs no evaluation at all.
        Claw.submit_event!(a, PipelineTestEvent("drop-5", ch))
        @test timedwait(() -> count_rows(a, "WHERE status='done'") == 5, 15.0) == :ok
    end
    @test length(seen) == 2
    @test Claw.event_content(seen[1]) == "keep-1"
    # Only the matching event survived into the second drain — and a single
    # survivor is delivered as a plain event, not a batch of one.
    @test seen[2] isa PipelineTestEvent
    @test Claw.event_content(seen[2]) == "keep-3"
    Claw.shutdown!(a; timeout_s = 5)
end

@testset "prompt filter transport failure rides the retry ladder" begin
    a = make_assistant(":memory:"; max_concurrent_evals = 2,
        retry_backoff_s = [0.05], FAST...)
    Claw.CURRENT_ASSISTANT[] = a
    ch = RecordingChannel("prompt-filter-lane")
    a._channels[ch.id] = ch
    Claw.execute_write(a._writer,
        "INSERT OR IGNORE INTO claw_event_types (name, description) VALUES (?, ?)",
        ("pipeline_test_event", "pipeline test"))
    Claw.register_event_handler!(a, Claw.EventHandler(
        "prompt_filtered_handler", ["pipeline_test_event"], "";
        filter = Claw.EventFilter(:prompt, "only real questions")))

    model_down = Ref(true)
    original_filter = Claw.PROMPT_FILTER_FN[]
    Claw.PROMPT_FILTER_FN[] = (assistant, criteria, content) ->
        model_down[] ? error("model unreachable") : true
    ran = Threads.Atomic{Int}(0)
    runner = (assistant, ev, handler; kwargs...) -> (Threads.atomic_add!(ran, 1); nothing)
    try
        with_handler(runner) do
            Claw.start_event_loop!(a)
            id = Claw.submit_event!(a, PipelineTestEvent("is this a question?", ch))
            # The filter error sends the event to retry, not to done/dead, and the
            # evaluation never ran.
            @test timedwait(() -> begin
                row = event_row(a, id)
                row !== nothing && row.status == "pending" && row.attempts >= 1
            end, 15.0) == :ok
            @test ran[] == 0
            # Once the "model" recovers, the scheduled retry passes the filter and
            # the handler finally runs.
            model_down[] = false
            @test timedwait(() -> event_row(a, id).status == "done", 15.0) == :ok
            @test ran[] == 1
        end
    finally
        Claw.PROMPT_FILTER_FN[] = original_filter
    end
    Claw.shutdown!(a; timeout_s = 5)
end

@testset "coalesced REPL inputs release every waiter" begin
    a = make_assistant(":memory:"; max_concurrent_evals = 2, FAST...)
    Claw.CURRENT_ASSISTANT[] = a
    Claw.execute_write(a._writer,
        "INSERT OR IGNORE INTO claw_event_types (name, description) VALUES (?, ?)",
        ("repl_input", "repl"))
    Claw.register_event_handler!(a, Claw.EventHandler("repl_default", ["repl_input"], "", nothing))

    gate = Base.Channel{Nothing}(1)
    runner = function (assistant, ev, handler; kwargs...)
        # Emulate the real evaluation's channel lifecycle: stream to the resolved
        # channel and finish it (which notifies that ReplChannel's completion).
        if ev isa Claw.ChannelEvent
            resolved = Claw.get_channel(ev)
            Agentif.finish_streaming(resolved)
        end
        take!(gate)
        return nothing
    end
    ch1 = Claw.ReplChannel(devnull, Threads.Event())
    ch2 = Claw.ReplChannel(devnull, Threads.Event())
    ch3 = Claw.ReplChannel(devnull, Threads.Event())
    with_handler(runner) do
        Claw.start_event_loop!(a)
        Claw.submit_event!(a, Claw.ReplInputEvent("first", ch1))
        @test timedwait(() -> begin
            lane = get(a._lanes, "repl", nothing)
            lane !== nothing && lane.busy[]
        end, 15.0) == :ok
        # Two more REPL inputs while the first is evaluating: they coalesce, the
        # response streams to the *last* channel, and the non-primary waiter (ch2)
        # must still be released via close_channel.
        Claw.submit_event!(a, Claw.ReplInputEvent("second", ch2))
        Claw.submit_event!(a, Claw.ReplInputEvent("third", ch3))
        @test timedwait(() -> begin
            lane = get(a._lanes, "repl", nothing)
            lane !== nothing && lane.depth[] == 2
        end, 15.0) == :ok
        put!(gate, nothing)   # release first eval
        put!(gate, nothing)   # release batch eval
        @test timedwait(() -> count_rows(a, "WHERE status='done'") == 3, 15.0) == :ok
    end
    waiters = [Threads.@spawn wait(ch.completion) for ch in (ch1, ch2, ch3)]
    @test timedwait(() -> all(istaskdone, waiters), 5.0) == :ok
    Claw.shutdown!(a; timeout_s = 5)
end

@testset "handler lookup failure releases REPL waiters" begin
    a = make_assistant(":memory:"; retry_backoff_s = [0.05],
        unknown_max_attempts = 2, FAST...)
    a._state[] = :running
    ch = Claw.ReplChannel(devnull, Threads.Event())
    id = Claw.submit_event!(a, Claw.ReplInputEvent("lookup failure", ch))
    @test take!(a.event_queue) == id
    row = Claw._claim_event!(a, id)
    @test row !== nothing
    # Force the handler lookup itself to fail while leaving claw_events writable,
    # which is the path that used to return the claim but strand the REPL waiter.
    Claw.execute_write(a._writer, "DROP TABLE claw_event_handlers")
    waiter = Threads.@spawn wait(ch.completion)
    Claw._process_claimed_group!(a,
        Tuple{Claw.EventRow, Claw.Event}[(row, Claw.ReplInputEvent("lookup failure", ch))])
    @test timedwait(() -> istaskdone(waiter), 5.0) == :ok
    @test event_row(a, id).status == "pending"
    @test event_row(a, id).attempts == 1

    # A persistent lookup failure is an infrastructure failure. It must consume
    # the retry budget instead of returning to attempt zero forever.
    row = Claw._claim_event!(a, id)
    @test row !== nothing
    Claw._process_claimed_group!(a,
        Tuple{Claw.EventRow, Claw.Event}[(row, Claw.ReplInputEvent("lookup failure", ch))])
    @test event_row(a, id).status == "dead"
    @test event_row(a, id).attempts == 2
    Claw.shutdown!(a; timeout_s = 5)
end

@testset "shutdown releases queued REPL waiters" begin
    a = make_assistant(":memory:"; FAST...)
    # Accept a durable event without starting the intake task. It remains queued
    # when shutdown starts, as can happen when intake loses the shutdown race.
    a._state[] = :running
    ch = Claw.ReplChannel(devnull, Threads.Event())
    id = Claw.submit_event!(a, Claw.ReplInputEvent("queued at shutdown", ch))
    waiter = Threads.@spawn wait(ch.completion)
    Claw.shutdown!(a; timeout_s = 5)
    @test timedwait(() -> istaskdone(waiter), 5.0) == :ok
    @test isempty(a._pending_wakeups)
    @test isempty(a._live_events)
    @test id isa Int
end

@testset "stopping returns later claimed groups without evaluating them" begin
    a = make_assistant(":memory:"; FAST...)
    a._state[] = :running
    ch = RecordingChannel("stop-between-groups")
    for name in ("first_group", "second_group")
        Claw.execute_write(a._writer,
            "INSERT OR IGNORE INTO claw_event_types (name, description) VALUES (?, ?)",
            (name, "shutdown group test"))
        Claw.register_event_handler!(a, Claw.EventHandler(name, [name], ""))
    end
    first_id = Claw.submit_event!(a, NamedPipelineEvent("first_group", "first", ch))
    second_id = Claw.submit_event!(a, NamedPipelineEvent("second_group", "second", ch))
    take!(a.event_queue)
    take!(a.event_queue)

    runs = Threads.Atomic{Int}(0)
    started = Threads.Atomic{Bool}(false)
    gate = Base.Event()
    runner = function (assistant, ev, handler; kwargs...)
        Threads.atomic_add!(runs, 1)
        started[] = true
        wait(gate)
        return nothing
    end
    with_handler(runner) do
        task = Threads.@spawn Claw._process_event_batch!(a, [first_id, second_id])
        @test timedwait(() -> started[], 5.0) == :ok
        a._state[] = :stopping
        notify(gate)
        @test timedwait(() -> istaskdone(task), 5.0) == :ok
        fetch(task)
    end
    @test runs[] == 1
    @test event_row(a, first_id).status == "done"
    second = event_row(a, second_id)
    @test second.status == "pending"
    @test second.attempts == 0
    a._state[] = :running
    Claw.shutdown!(a; timeout_s = 5)
end

end # module PipelineTests
