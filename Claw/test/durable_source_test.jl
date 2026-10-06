isdefined(@__MODULE__, :durable_jev) || include("durable_source_fixtures.jl")

@testset "frozen source policy, receipt replay and distinct followup batches" begin
    for cut in (:after_relevance_receipt, :before_dispatch, :after_dispatch)
        mktempdir() do dir
            path = joinpath(dir, "source.sqlite");calls = Ref(0);original = Claw.JEV_REQUEST_FN[]
            a, h = attached_fixture(path; jev = durable_jev())
            durable_source_rehydrate!(a)
            Claw._register_default_profile!(h, a)
            handler = Claw.EventHandler("source", ["durable-relevance"], "original handler"; trust = :untrusted, tools = String[], relevance = durable_policy())
            Claw.register_event_handler!(a, handler)
            group = source_claims(a, ["keep fact", "unrelated fact"])
            first_id = group[1][1].id;second_id = group[2][1].id
            Claw.JEV_REQUEST_FN[] = (cfg, request) -> begin
                calls[] += 1;durable_relevance_response(request; reject = [second_id])
            end
            h.fault = (point, h) -> point == cut && error("injected source cut")
            try
                @test_throws ErrorException Claw._durable_dispatch_group!(a, group, [handler])
                @test calls[] == 1
            finally
                Claw.shutdown!(a; timeout_s = 10)
            end
            a, h = attached_fixture(path; jev = durable_jev())
            durable_source_rehydrate!(a)
            Claw._register_default_profile!(h, a)
            try
                changed = Claw.EventHandler(
                    "source", ["durable-relevance"], "changed handler"; trust = :owner,
                    relevance = Claw.EventRelevancePolicy("unrelated interests", "keep nothing")
                )
                Claw.register_event_handler!(a, changed)
                if cut != :after_dispatch
                    Claw._reclaim_crashed_events!(a; durable_upgrade = true)
                    row = Claw._claim_event!(a, first_id)
                    ev = Claw.rehydrate_event(row.source, row)
                    Claw._durable_dispatch_group!(a, [(row, ev)], [changed])
                end
                Claw.resume!(h)
                integration_until(() -> Claw._on_writer(db -> Claw._scalar(db, "SELECT COUNT(*) FROM claw_submissions WHERE state='answered'"), h) == 1)
                @test calls[] == 1
                dispatch = only(Claw._on_writer(db -> Claw._fetch_all(db, "SELECT * FROM claw_event_dispatches"), h))
                @test JSON.parse(dispatch.verdicts) == Dict(string(first_id) => true, string(second_id) => false)
                frozen = JSON.parse(dispatch.handler_snapshot)
                @test frozen["prompt"] == "original handler"
                @test frozen["trust"] == "untrusted" && isempty(frozen["tools"])
                saved = only(Claw._on_writer(db -> Claw._fetch_all(db, "SELECT * FROM claw_submissions"), h))
                @test !occursin("unrelated fact", saved.input_json)
                next = source_claims(a, ["new fact"])
                Claw._durable_dispatch_group!(a, next, [changed])
                @test calls[] == 2
                @test Claw._on_writer(db -> Claw._scalar(db, "SELECT COUNT(*) FROM claw_dispatch_groups"), h) == 2
            finally
                Claw.JEV_REQUEST_FN[] = original;Claw.shutdown!(a; timeout_s = 10)
            end
        end
    end
end

@testset "late source classifiers cannot journal or admit" begin
    for invalid in (:abort, :reclaimed, :epoch)
        mktempdir() do dir
            a, h = attached_fixture(joinpath(dir, "source.sqlite"); jev = durable_jev())
            handler = Claw.EventHandler("source", ["durable-relevance"], "source"; relevance = durable_policy())
            group = source_claims(a, ["fact"]);abort = Agentif.Abort();original = Claw.JEV_REQUEST_FN[]
            Claw.JEV_REQUEST_FN[] = (cfg, request) -> begin
                if invalid == :abort
                    Agentif.abort!(abort)
                elseif invalid == :reclaimed
                    Claw._release_claim!(a, group[1][1])
                    @test Claw._claim_event!(a, group[1][1].id) !== nothing
                else
                    Claw._on_writer(Claw._advance_owner!, h)
                end
                durable_relevance_response(request)
            end
            try
                @test_throws (invalid == :abort ? Agentif.AbortEvaluation : Claw.StaleInvocation) Claw._durable_dispatch_group!(a, group, [handler]; abort)
                @test Claw._on_writer(db -> Claw._scalar(db, "SELECT COUNT(*) FROM claw_relevance_batches"), h) == 0
                @test Claw._on_writer(db -> Claw._scalar(db, "SELECT COUNT(*) FROM claw_submissions"), h) == 0
            finally
                Claw.JEV_REQUEST_FN[] = original;Claw.shutdown!(a; timeout_s = 10)
            end
        end
    end
end

@testset "group settlement rejects one stale member atomically" begin
    mktempdir() do dir
        a, h = attached_fixture(joinpath(dir, "group.sqlite"))
        try
            rows = [r for (r, e) in source_claims(a, ["one", "two"])]
            Claw._release_claim!(a, rows[2])
            replacement = Claw._claim_event!(a, rows[2].id)
            @test_throws Claw.StaleInvocation Claw._finish_event!(a, rows, "done")
            @test all(r -> r.status == "running", Claw._on_writer(db -> Claw._fetch_all(db, "SELECT status FROM claw_events"), h))
            current = [rows[1], replacement]
            Claw._on_writer(h) do db
                SQLite.execute(db, "CREATE TRIGGER fail_second BEFORE UPDATE ON claw_events WHEN NEW.id=$(replacement.id) AND NEW.status='done' BEGIN SELECT RAISE(ABORT,'fixture'); END")
            end
            @test_throws SQLite.SQLiteException Claw._finish_event!(a, current, "done")
            @test all(r -> r.status == "running", Claw._on_writer(db -> Claw._fetch_all(db, "SELECT status FROM claw_events"), h))
        finally
            Claw.shutdown!(a; timeout_s = 10)
        end
    end
end
