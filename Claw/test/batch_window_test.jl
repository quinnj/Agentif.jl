module BatchWindowTests

using Test, Claw, Agentif
using ..RelevanceTests: assistant, handler!, submit, SourceEvent

function queue!(lane, id, ts=time())
    Threads.atomic_add!(lane.depth, 1)
    put!(lane.queue, (id, ts))
end

@testset "bounded window preserves the zero-window drain and event cap" begin
    @test Claw.PipelineConfig().coalesce_window_s == 0
    for value in (-1.0, Inf, NaN, 2.01)
        @test_throws ArgumentError assistant(; pipeline=Claw.PipelineConfig(coalesce_window_s=value))
    end
    for (window, cap, expected) in ((0.0, 8, [1, 2, 3]), (2.0, 1, [1]))
        a = assistant(; jev=nothing, pipeline=Claw.PipelineConfig(coalesce_window_s=window, max_coalesce=cap))
        try
            a._state[] = :running
            lane = Claw.Lane("test")
            queue!(lane, 2)
            queue!(lane, 3)
            # A full/disabled batch never waits for the two-second window.
            task = Threads.@spawn Claw._collect_lane_batch!(a, lane, (1, time()))
            @test timedwait(() -> istaskdone(task), 1.0; pollint=0.01) == :ok
            @test first.(fetch(task)) == expected
            @test lane.depth[] == 3 - length(expected)
        finally
            Claw.shutdown!(a; timeout_s=5)
        end
    end
end

@testset "idle lane collects a burst with no lease or model slot while waiting" begin
    a = assistant(; jev=nothing, pipeline=Claw.PipelineConfig(
        coalesce_window_s=2.0, max_coalesce=2,
        scan_interval_s=0.01, max_concurrent_evals=1))
    original = Claw.RUN_EVENT_HANDLER_FN[]
    try
        handler!(a; relevance=nothing)
        seen = Claw.Event[]
        guard = ReentrantLock()
        Claw.RUN_EVENT_HANDLER_FN[] = (a, ev, h; kwargs...) -> lock(() -> push!(seen, ev), guard)
        Claw.start_event_loop!(a)
        # Warm the lane/claim/handler path before checking collection timing:
        # compiling a cold Julia pipeline is not part of the burst window.
        warm_id = submit(a, "Warm fixture")
        @test timedwait(() -> Claw._fetch_one(a.db,
            "SELECT status, attempts FROM claw_events WHERE id = ?", (warm_id,)).status == "done",
            15.0; pollint=0.01) == :ok
        lock(() -> empty!(seen), guard)
        first_id = submit(a, "First review")
        @test timedwait(() -> lock(a._lanes_lock) do
            lane = get(a._lanes, "default", nothing)
            lane !== nothing && lane.busy[]
        end, 5.0; pollint=0.01) == :ok
        row = Claw._fetch_one(a.db, "SELECT status, attempts FROM claw_events WHERE id = ?", (first_id,))
        @test row.status == "pending" && row.attempts == 0
        @test isempty(a._inflight)
        # Another evaluation could acquire the sole model slot during collection.
        slot = Threads.@spawn begin
            Base.acquire(a._sem)
            Base.release(a._sem)
        end
        @test timedwait(() -> istaskdone(slot), 1.0; pollint=0.01) == :ok
        second_id = submit(a, "Second review")
        @test timedwait(() -> Claw._fetch_one(a.db,
            "SELECT COUNT(*) AS n FROM claw_events WHERE status='done'").n == 3, 15.0; pollint=0.01) == :ok
        @test length(seen) == 1
        @test only(seen) isa Claw.EventBatch
        @test Claw.event_content.(Claw.batch_events(only(seen))) == ["First review", "Second review"]
        @test first_id < second_id
    finally
        Claw.RUN_EVENT_HANDLER_FN[] = original
        Claw.shutdown!(a; timeout_s=5)
    end
end

@testset "fixed deadline, aged backlog, and interruptible collection" begin
    a = assistant(; jev=nothing, pipeline=Claw.PipelineConfig(coalesce_window_s=1.0, max_coalesce=10_000))
    try
        a._state[] = :running
        lane = Claw.Lane("deadline")
        producer = Threads.@spawn begin
            for id in 2:25
                sleep(0.1)
                queue!(lane, id)
            end
        end
        task = Threads.@spawn Claw._collect_lane_batch!(a, lane, (1, time()))
        @test timedwait(() -> istaskdone(task), 2.0; pollint=0.01) == :ok
        @test length(fetch(task)) < 25 # subsequent arrivals do not extend the window
        wait(producer)
        aged = Claw.Lane("aged")
        queue!(aged, 2, time()-10)
        task = Threads.@spawn Claw._collect_lane_batch!(a, aged, (1, time()-10))
        @test timedwait(() -> istaskdone(task), 0.5; pollint=0.01) == :ok
        @test first.(fetch(task)) == [1, 2]
        empty_lane = Claw.Lane("cancel")
        task = Threads.@spawn Claw._collect_lane_batch!(a, empty_lane, (1, time()))
        a._state[] = :stopping
        @test timedwait(() -> istaskdone(task), 0.5; pollint=0.01) == :ok
        @test first.(fetch(task)) == [1]
    finally
        Claw.shutdown!(a; timeout_s=5)
    end
end

@testset "shutdown during collection leaves raw events pending for replay" begin
    path = tempname() * ".sqlite"
    a = assistant(path; jev=nothing, pipeline=Claw.PipelineConfig(coalesce_window_s=2.0))
    original = Claw.RUN_EVENT_HANDLER_FN[]
    prior = lock(() -> get(Claw.EVENT_REHYDRATORS, "fixture", nothing), Claw.EVENT_REHYDRATORS_LOCK)
    try
        handler!(a; relevance=nothing)
        Claw.RUN_EVENT_HANDLER_FN[] = (a, ev, h; kwargs...) -> error("must not evaluate while collecting")
        Claw.start_event_loop!(a)
        id = submit(a, "Recover this review"; source="fixture")
        @test timedwait(() -> lock(a._lanes_lock) do
            lane = get(a._lanes, "default", nothing)
            lane !== nothing && lane.busy[]
        end, 5.0; pollint=0.01) == :ok
        Claw.shutdown!(a; timeout_s=1.0)
        a = assistant(path; jev=nothing)
        row = Claw._fetch_one(a.db, "SELECT status, attempts FROM claw_events WHERE id = ?", (id,))
        @test row.status == "pending" && row.attempts == 0
        Claw.register_rehydrator!("fixture", row -> SourceEvent(row.source, row.content, row.extra))
        recovered = String[]
        Claw.RUN_EVENT_HANDLER_FN[] = (a, ev, h; kwargs...) -> push!(recovered, Claw.event_content(ev))
        a._state[] = :running
        Claw._process_event_batch!(a, [id])
        @test recovered == ["Recover this review"]
        @test Claw._fetch_one(a.db, "SELECT status FROM claw_events WHERE id = ?", (id,)).status == "done"
    finally
        Claw.RUN_EVENT_HANDLER_FN[] = original
        lock(Claw.EVENT_REHYDRATORS_LOCK) do
            prior === nothing ? delete!(Claw.EVENT_REHYDRATORS, "fixture") : (Claw.EVENT_REHYDRATORS["fixture"] = prior)
        end
        Claw.shutdown!(a; timeout_s=5)
        for suffix in ("", "-wal", "-shm")
            rm(path * suffix; force=true)
        end
    end
end

end # module
