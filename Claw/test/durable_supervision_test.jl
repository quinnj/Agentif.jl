isdefined(@__MODULE__, :attached_fixture) || include("durable_integration_fixtures.jl")

@testset "durable watcher notes are model tasks and delivery receipts" begin
    for failed_watcher in (false, true)
        mktempdir() do dir
            calls = Threads.Atomic{Int}(0)
            stream = (f, a, s, input, abort; kw...) -> begin
                if a.prompt == Claw.WATCHER_SYSTEM_PROMPT
                    Threads.atomic_add!(calls, 1)
                    if !failed_watcher
                        msg = durable_message(a, "I could not finish this event.")
                        Agentif.append_state!(s, input, msg, Agentif.Usage(; total = 1));s.most_recent_stop_reason = :stop;return s
                    end
                end
                f(Agentif.AgentErrorEvent(ErrorException("permanent failure")))
                s.most_recent_stop_reason = :error;s
            end
            watcher = Claw.WatcherConfig(; provider = "test", model_id = "durable-test", apikey = "watcher-live-secret", check_interval_s = 0.05)
            a, h = attached_fixture(joinpath(dir, "watcher.sqlite"); stream, watcher)
            sent = Threads.Atomic{Bool}(false);receipt_release = Threads.Event()
            h.fault = (point, _) -> begin
                if point === :after_remote_send
                    sent[] = true
                    wait(receipt_release)
                end
                nothing
            end
            try
                a._state[] = :running
                Claw.register_event_handler!(a, Claw.EventHandler("watched", ["durable-event"], "watch this"))
                channel = DurableChannel("watcher")
                id = Claw.submit_event!(a, DurableEvent(channel, "source"))
                Claw._process_event!(a, id)
                # Remote visibility precedes the local receipt commit. Hold that
                # gap open so observing the response cannot satisfy receipt checks.
                integration_until(() -> sent[])
                @test length(channel.responses) == 1
                before = Claw._on_writer(db -> Claw._fetch_one(db, "SELECT * FROM claw_evals ORDER BY id DESC LIMIT 1"), h)
                @test before.fallback_sent == 0
                notify(receipt_release)
                integration_until(
                    () -> Claw._on_writer(
                        db -> Claw._fetch_one(
                            db,
                            "SELECT fallback_sent FROM claw_evals ORDER BY id DESC LIMIT 1"
                        ), h
                    ).fallback_sent == 1
                )
                @test calls[] == 1
                @test failed_watcher ? occursin("problem", only(channel.responses)) : only(channel.responses) == "I could not finish this event."
                journal = Claw._on_writer(db -> Claw._fetch_one(db, "SELECT * FROM claw_evals ORDER BY id DESC LIMIT 1"), h)
                @test journal.status == "failed"
                @test journal.fallback_sent == 1
                @test length(Claw._on_writer(db -> Claw._fetch_all(db, "SELECT * FROM claw_usage WHERE category='watcher'"), h)) == 1
                @test !occursin("watcher-live-secret", join((r.payload for r in Claw._on_writer(db -> Claw._fetch_all(db, "SELECT payload FROM claw_agent_profiles"), h))))
            finally
                notify(receipt_release)
                Claw.shutdown!(a; timeout_s = 10)
            end
        end
    end
end

@testset "durable zombies retain permits and lock while fallback has a budget" begin
    mktempdir() do dir
        started = Threads.Event();release = Threads.Event()
        stream = (f, a, s, input, abort; kw...) -> begin
            notify(started);wait(release) # deliberately ignores Abort
            durable_stream(f, a, s, input, abort; kw...)
        end
        watcher = Claw.WatcherConfig(;
            provider = "test", model_id = "durable-test", apikey = "key", stall_timeout_s = 0.15,
            check_interval_s = 0.02, abort_grace_s = 0.05, watcher_timeout_s = 0.15
        )
        path = joinpath(dir, "zombie.sqlite")
        a, h = attached_fixture(path; stream, watcher, limits = Claw.HarnessLimits(; models = 1, tools = 1))
        try
            a._state[] = :running
            Claw.register_event_handler!(a, Claw.EventHandler("zombie", ["durable-event"], "zombie"))
            channel = DurableChannel("zombie")
            id = Claw.submit_event!(a, DurableEvent(channel, "source"));Claw._process_event!(a, id)
            signal = @async wait(started)
            integration_until(() -> istaskdone(signal));fetch(signal)
            integration_until(() -> length(channel.responses) == 1)
            @test occursin("stalled", only(channel.responses))
            c = Claw._on_writer(db -> Claw._fetch_one(db, "SELECT id FROM claw_conversations WHERE branch_id='zombie'"), h)
            @test length(Claw.live_activity(h, c.id)) == 1
            @test only(Claw.live_activity(h, c.id)).abort_requested
            @test Claw.close_harness!(h; grace_s = 0.01).status == :draining
            @test_throws ErrorException Claw.open_harness(path)
        finally
            notify(release)
            Claw.shutdown!(a; timeout_s = 10)
        end
    end
end

@testset "mode guards and legacy interruption do not replay parked work" begin
    mktempdir() do dir
        path = joinpath(dir, "mode.sqlite")
        a, h = attached_fixture(path)
        try
            p = Claw._register_default_profile!(h, a)
            c = Claw.ensure_conversation!(h; branch_id = "parked", profile = p)
            Claw._transition!(h) do db, seq
                Claw._admit!(db, seq, Claw._fetch_one(db, "SELECT * FROM claw_conversations WHERE id=?", (c.id,)), Agentif.UserMessage("parked"), "parked", :followup, Dict(), p.id)
            end
        finally
            Claw.shutdown!(a; timeout_s = 10)
        end
        a = Claw.AgentAssistant(path; search_options = (; embed = nothing), level = :error)
        try
            @test_throws ErrorException Claw._guard_legacy_runtime!(a)
            a._durable_parked[] = true
            @test Claw._guard_legacy_runtime!(a) === nothing
            id = Claw.submit_event!(a, DurableEvent(DurableChannel("legacy"), "legacy"))
            row = Claw._claim_event!(a, id)
            Claw._reclaim_crashed_events!(a; durable_upgrade = true)
            saved = Claw.with_read(db -> Claw._fetch_one(db, "SELECT status,last_error FROM claw_events WHERE id=?", (id,)), a._readers)
            @test saved.status == "dead"
            @test startswith(saved.last_error, "legacy_interrupted")
            @test_throws Claw.StaleInvocation Claw._finish_event!(a, row, "done")
            @test Claw._lookup_event_admission(a, string(id)) === nothing
        finally
            Claw.shutdown!(a; timeout_s = 10)
        end
    end
end
