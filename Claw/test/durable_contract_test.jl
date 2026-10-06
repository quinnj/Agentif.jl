isdefined(@__MODULE__, :attached_fixture) || include("durable_integration_fixtures.jl")

function contract_context(h, c, p, key)
    id = Claw._transition!(h) do db, seq
        Claw._task_create!(db, seq, c.id, "tool", key; input = Dict("profile" => p.id), checkpoint = Dict("phase" => "execute"))
    end
    return first(Claw._reserve!(h, Claw._task_row(h, id)))
end

@testset "child trust, tool contracts, keyed creation and interrupted resources" begin
    mktempdir() do dir
        path = joinpath(dir, "contracts.sqlite")
        tool = Agentif.@tool "contract fixture" read() = "allowed"
        h, c, p = durable_fixture(path; tools = Agentif.AgentTool[tool])
        try
            parent = Claw.register_profile!(h, h.agents[p.id]; trust = :untrusted)
            ctx = contract_context(h, c, parent, "parent")
            owner = Claw.register_profile!(h, Agentif.with_prompt(h.agents[p.id], "child owner"); trust = :owner)
            @test_throws ArgumentError Claw.create_owned_child!(ctx; creation_key = "owner", name = "owner", profile = owner, input = "input")
            widened = Claw.register_profile!(
                h, Agentif.with_prompt(h.agents[p.id], "changed contract"); trust = :untrusted,
                specs = [Claw.ToolSpec(tool; version = "different-version", replay = :safe)]
            )
            @test_throws ArgumentError Claw.create_owned_child!(ctx; creation_key = "tool", name = "tool", profile = widened, input = "input")
            child = Claw.register_profile!(h, Agentif.with_prompt(h.agents[p.id], "permitted child"); trust = :untrusted)
            created = Claw.create_owned_child!(ctx; creation_key = "stable", name = "worker", profile = child, input = "input")
            @test Claw.create_owned_child!(ctx; creation_key = "stable", name = "worker", profile = child, input = "input") == created
            @test_throws Claw.SubmissionConflict Claw.create_owned_child!(ctx; creation_key = "stable", name = "worker", profile = child, input = "changed")
            @test length(Claw.snapshot(h, created.conversation).submissions) == 1
            resource = Claw.record_managed_resource!(ctx; kind = "worker", key = "resource", details = Dict("name" => "worker"))
            @test only(Claw.snapshot(h, c).resources).state == "running"
            Claw.close_harness!(h)
            h, c, p = durable_fixture(path; tools = Agentif.AgentTool[tool])
            @test only(Claw.snapshot(h, c).resources).state == "interrupted"
            @test only(Claw.snapshot(h, c).resources).id == resource
            broken = contract_context(h, c, p, "corrupt").task_id
            Claw._on_writer(db -> Claw._exec!(db, "UPDATE claw_tasks SET status='pending',token=NULL,checkpoint='corrupt' WHERE id=?", (broken,)), h)
            @test last(Claw._eligibility(h, Claw._task_row(h, broken))) == "corrupt task checkpoint"
            @test JSON.parse(Claw.inspect_task(h, broken).checkpoint)["phase"] == "corrupt"
            @test only(filter(t -> t.id == broken, Claw.snapshot(h, c).tasks)).phase == "corrupt"
            Claw._on_writer(db -> Claw._exec!(db, "UPDATE claw_tasks SET checkpoint='[]' WHERE id=?", (broken,)), h)
            @test last(Claw._eligibility(h, Claw._task_row(h, broken))) == "corrupt task checkpoint"
            @test JSON.parse(Claw.inspect_task(h, broken).checkpoint)["phase"] == "corrupt"
            Claw._on_writer(db -> Claw._exec!(db, "UPDATE claw_tasks SET checkpoint=?,input_json='[]' WHERE id=?", (JSON.json(Dict("phase" => "execute")), broken)), h)
            @test last(Claw._eligibility(h, Claw._task_row(h, broken))) == "corrupt task input"
            valid = Claw.submit!(h, c, "unrelated work"; request_id = "compatible", mode = :write)
            @test Claw.wait_submission(valid; timeout_s = 20).reason == "passive_write"
            @test h.state === :open
        finally
            Claw.close_harness!(h)
        end
    end
end

@testset "retry attempts, UTC restart and bounded clock corrections" begin
    mktempdir() do dir
        calls = Ref(0)
        stream = (f, a, s, input, abort; kw...) -> begin
            calls[] += 1;f(Agentif.AgentErrorEvent(EOFError()));s.most_recent_stop_reason = :error;s
        end
        limits = Claw.HarnessLimits(; attempts = 3, retry_delays = [0.01], max_retry_delay = 0.05)
        path = joinpath(dir, "retry.sqlite")
        h, c, p = durable_fixture(path; stream, limits)
        try
            r = Claw.submit!(h, c, "retry"; request_id = "retry")
            @test Claw.wait_submission(r; timeout_s = 20).state == "unanswered"
            @test calls[] == 3
            @test length(Claw.snapshot(h, c).usage) == 3
            @test Claw.snapshot(h, c).unknown_spend_attempts == 0
            wall = Ref(1000.0);h.clock = () -> wall[]
            @test !Claw._is_due!(h, "clock", 1000.02)
            wall[] = 1.0;sleep(0.04)
            @test Claw._is_due!(h, "clock", 1000.02)
            @test !Claw._is_due!(h, "future", 1000000.0)
            sleep(0.07)
            @test Claw._is_due!(h, "future", 1000000.0)
            @test Claw._is_due!(h, "overdue", 0.0)
            watcher = Claw._transition!(h) do db, seq
                Claw._task_create!(
                    db, seq, c.id, "watcher", "clock-watcher";
                    input = Dict("profile" => p.id, "deadline" => wall[] + 0.02, "timeout" => 0.02), checkpoint = Dict("phase" => "request")
                )
            end
            @test !Claw._watcher_expired!(h, Claw._task_row(h, watcher))
            wall[] = wall[] - 1000;sleep(0.04)
            @test Claw._watcher_expired!(h, Claw._task_row(h, watcher))
            Claw._transition!(h) do db, seq
                Claw._finish_task!(db, Claw._fetch_one(db, "SELECT * FROM claw_tasks WHERE id=?", (watcher,)), Dict("status" => "completed"))
            end
            h.clock = time
            Claw.close_harness!(h)
            h, c, p = durable_fixture(path; stream, limits)
            @test Claw.lookup_submission(h, c.id, "retry").id == r.id
            Claw.resume!(h);sleep(0.1)
            @test calls[] == 3
        finally
            Claw.close_harness!(h)
        end
    end
end

function finish_contract_context!(ctx)
    return Claw._transition!(ctx.harness; context = ctx) do db, seq
        Claw._finish_task!(db, Claw._fetch_one(db, "SELECT * FROM claw_tasks WHERE id=?", (ctx.task_id,)), Dict("status" => "completed"))
    end
end

@testset "native child followup, steering, notifications and boot type restoration" begin
    mktempdir() do dir
        path = joinpath(dir, "native.sqlite")
        cfg = Claw.AgentConfig(; provider = "test", model_id = "durable-test", apikey = "key", base_dir = dir)
        tools = Claw._create_subagent_tools(Claw.LLMToolsEventSource(cfg))
        a, h = attached_fixture(path)
        old = Claw.CURRENT_ASSISTANT[]
        try
            p = Claw.register_profile!(h, Agentif.Agent(; model = durable_model(), apikey = "key", prompt = "parent", tools))
            c = Claw.ensure_conversation!(h; branch_id = "native", profile = p)
            ctx = contract_context(h, c, p, "launch")
            result = Claw._subagent_operation!(1, (; name = "worker", system_prompt = "child", input_message = "initial", run_sync = true, prompt = nothing), ctx)
            @test result isa Claw.OwnedToolWait
            finish_contract_context!(ctx);Claw.resume!(h)
            integration_until(() -> Claw.inspect_task(h, result.task).status == "terminal")
            alias = Claw._on_writer(db -> Claw._fetch_one(db, "SELECT * FROM claw_child_aliases"), h)
            child_id = alias.child_id
            @test ismissing(alias.event_type)
            for mode in ("followup", "steer")
                ctx = contract_context(h, c, p, "message:$mode")
                @test Claw._subagent_operation!(2, (; name = "worker", input_message = mode, run_sync = false, mode), ctx) isa Agentif.ToolOutcome
                finish_contract_context!(ctx)
                alias = Claw._on_writer(db -> Claw._fetch_one(db, "SELECT * FROM claw_child_aliases"), h)
                @test alias.child_id == child_id
                @test !ismissing(alias.event_type)
                integration_until(() -> Claw.inspect_task(h, alias.task_id).status == "terminal")
                key = "child-completion:$(alias.task_id)"
                integration_until(() -> Claw._on_writer(db -> Claw._scalar(db, "SELECT COUNT(*) FROM claw_events WHERE dedup_key=?", (key,)), h) == 1)
                adapter = h.adapters["claw-child-event"]
                @test adapter.send(Dict("event_type" => alias.event_type, "name" => "worker"), "duplicate", key) === nothing
                @test Claw._on_writer(db -> Claw._scalar(db, "SELECT COUNT(*) FROM claw_events WHERE dedup_key=?", (key,)), h) == 1
                event = Claw._on_writer(db -> Claw._fetch_one(db, "SELECT id FROM claw_events WHERE dedup_key=?", (key,)), h)
                row = Claw._claim_event!(a, Int(event.id));Claw._finish_event!(a, row, "done")
            end
            @test [s.mode for s in Claw.snapshot(h, child_id).submissions] == ["followup", "followup", "steer"]
            @test all(s -> s.state == "answered", Claw.snapshot(h, child_id).submissions)
            event_type = alias.event_type
            Claw.shutdown!(a; timeout_s = 10)
            a = Claw.init!(
                path; provider = "test", model_id = "durable-test", apikey = "secret-test-key", base_dir = dir,
                search_options = (; embed = nothing), level = :error, event_sources = Claw.EventSource[], install_signal_handlers = false,
                durable = true, harness_options = (; stream_fn = durable_stream, compaction = Agentif.CompactionConfig(; enabled = false))
            )
            h = a._harness[]
            @test Claw._on_writer(db -> Claw._scalar(db, "SELECT COUNT(*) FROM claw_event_types WHERE name=?", (event_type,)), h) == 1
            @test length(Claw._event_handlers_for(a, event_type)) == 1
            @test only(Claw._on_writer(db -> Claw._fetch_all(db, "SELECT child_id FROM claw_child_aliases"), h)).child_id == child_id
        finally
            Claw.shutdown!(a; timeout_s = 10);Claw.CURRENT_ASSISTANT[] = old
        end
    end
end

@testset "full fresh request budget and incomplete tool pairs stop before network" begin
    for incomplete in (false, true)
        mktempdir() do dir
            calls = Ref(0)
            stream = (f, a, s, input, abort; kw...) -> begin
                calls[] += 1;durable_stream(f, a, s, input, abort; kw...)
            end
            h, c, p = durable_fixture(joinpath(dir, "context.sqlite"); stream, window = 1000)
            try
                if incomplete
                    Claw._transition!(h) do db, seq
                        row = Claw._fetch_one(db, "SELECT * FROM claw_conversations WHERE id=?", (c.id,))
                        assistant = durable_message(h.agents[p.id], ""; calls = [Agentif.AgentToolCall(; call_id = "unsettled", name = "missing", arguments = "{}")])
                        Claw._entry!(db, h, seq, row, [Agentif.UserMessage("prior"), assistant])
                    end
                end
                r = Claw.submit!(h, c, incomplete ? "small" : repeat("large ", 2000); request_id = "context")
                if incomplete
                    integration_until(() -> any(t -> t.blocked !== nothing && occursin("incomplete", t.blocked), Claw.snapshot(h, c).tasks))
                    @test Claw.submission(r).state == "placed"
                else
                    @test Claw.wait_submission(r; timeout_s = 20).reason == "context_overflow"
                end
                @test calls[] == 0
            finally
                Claw.close_harness!(h)
            end
        end
    end
end

@testset "tool capacity, sequential contracts and ordered model adoption" begin
    for execution in (:parallel, :sequential)
        mktempdir() do dir
            first_entered = Threads.Event();release = Threads.Event();guard = ReentrantLock()
            started = Int[];completed = Int[];active = Ref(0);maximum = Ref(0);model_results = String[]
            tool = Agentif.@tool "controlled tool" step(n::Int) = "unused"
            invoke = (tool, args, ctx) -> begin
                args.n == 1 || wait(first_entered)
                lock(guard) do
                    push!(started, args.n);active[] += 1;maximum[] = max(maximum[], active[])
                end
                args.n == 1 && (notify(first_entered); wait(release))
                lock(guard) do;
                    push!(completed, args.n);active[] -= 1
                end
                Agentif.ToolOutcome("result $(args.n)")
            end
            stream = (f, a, s, input, abort; kw...) -> begin
                results = filter(m -> m isa Agentif.ToolResultMessage, s.messages)
                calls = isempty(results) ? [Agentif.AgentToolCall(; call_id = "call:$i", name = "step", arguments = JSON.json(Dict("n" => i))) for i in 1:3] : Agentif.AgentToolCall[]
                isempty(results) || append!(model_results, [m.call_id for m in results])
                msg = durable_message(a, isempty(results) ? "" : "answer"; calls)
                Agentif.append_state!(s, input, msg, Agentif.Usage(; total = 1));s.most_recent_stop_reason = isempty(calls) ? :stop : :tool_calls;s
            end
            h, c, p = durable_fixture(
                joinpath(dir, "capacity.sqlite"); stream, tools = Agentif.AgentTool[tool],
                specs = [Claw.ToolSpec(tool; version = "controlled-v1", replay = :safe, execution, invoke)], limits = Claw.HarnessLimits(; models = 1, tools = 2)
            )
            try
                r = Claw.submit!(h, c, "three calls"; request_id = "capacity")
                signal = @async wait(first_entered)
                integration_until(() -> istaskdone(signal));fetch(signal)
                if execution === :parallel
                    integration_until(() -> lock(() -> length(completed) == 2, guard))
                    @test lock(() -> copy(completed), guard) == [2, 3]
                    @test lock(() -> maximum[], guard) == 2
                else
                    sleep(0.1)
                    @test lock(() -> copy(started), guard) == [1]
                    @test isempty(lock(() -> copy(completed), guard))
                end
                @test Claw.submission(r).state == "placed"
                notify(release)
                @test Claw.wait_submission(r; timeout_s = 20).state == "answered"
                @test model_results == ["call:1", "call:2", "call:3"]
                @test lock(() -> maximum[], guard) == (execution === :parallel ? 2 : 1)
                @test sort(lock(() -> copy(completed), guard)) == [1, 2, 3]
            finally
                notify(release);Claw.close_harness!(h; grace_s = 10)
            end
        end
    end
end

@testset "parked joins and blocked phases do not write or false-stall" begin
    mktempdir() do dir
        watcher = Claw.WatcherConfig(; provider = "test", model_id = "durable-test", apikey = "key", stall_timeout_s = 0.05, check_interval_s = 0.02)
        a, h = attached_fixture(joinpath(dir, "parked.sqlite"); watcher)
        try
            p = Claw._register_default_profile!(h, a)
            c = Claw.ensure_conversation!(h; branch_id = "parked", profile = p)
            parent = contract_context(h, c, p, "join")
            child = Claw._transition!(h) do db, seq
                child = Claw._task_create!(db, seq, c.id, "unsupported", "blocked"; owner = parent.task_id)
                Claw._wait_tasks!(db, parent.task_id, [child]);child
            end
            Claw.resume!(h)
            integration_until(() -> Claw.inspect_task(h, child).blocked !== nothing)
            sleep(0.1) # allow the eligibility pass which observed the old row to settle
            original = Claw.snapshot(h, c).seq
            sleep(0.15)
            @test Claw.snapshot(h, c).seq == original
            @test Claw.inspect_task(h, parent.task_id).status == "waiting"
            @test Claw.inspect_task(h, parent.task_id).cancel == 0
        finally
            Claw.shutdown!(a; timeout_s = 10)
        end
    end
end

@testset "supervised uncertainty is waiting rather than stalled" begin
    # The body reports an interruption, so its effect is uncertain.
    tool = Agentif.@tool "uncertain fixture" uncertain() = throw(Agentif.AbortEvaluation())
    stream = (f, a, s, input, abort; kw...) -> begin
        msg = durable_message(a, ""; calls = [Agentif.AgentToolCall(; call_id = "uncertain", name = "uncertain", arguments = "{}")])
        Agentif.append_state!(s, input, msg, Agentif.Usage(; total = 1));s.most_recent_stop_reason = :tool_calls;s
    end
    function start_uncertain(dir; watcher = nothing)
        a, h = attached_fixture(joinpath(dir, "supervised.sqlite"); watcher, stream)
        a._state[] = :running
        push!(a.tools, tool)
        Claw.register_event_handler!(a, Claw.EventHandler("uncertain", ["durable-event"], "uncertain"))
        Claw._process_event!(a, Claw.submit_event!(a, DurableEvent(DurableChannel("uncertain"), "uncertain")))
        integration_until(() -> Claw._on_writer(db -> Claw._scalar(db, "SELECT COUNT(*) FROM claw_tool_executions WHERE effect_state='uncertain'"), h) == 1)
        return a, h
    end
    supervisor(stall) = Claw.WatcherConfig(; provider = "test", model_id = "durable-test", apikey = "key", stall_timeout_s = stall, check_interval_s = 0.02)
    # First-call compilation outlasts the short stall budget below, so run the
    # same supervised path once with a long budget first.
    mktempdir() do dir
        a, _ = start_uncertain(dir; watcher = supervisor(60))
        Claw.shutdown!(a; timeout_s = 10)
    end
    mktempdir() do dir
        a, h = start_uncertain(dir; watcher = supervisor(0.25))
        try
            integration_until(() -> isempty(lock(() -> collect(h.live), h.lock)))
            sleep(0.1) # let a supervisor that sampled the last live phase commit its heartbeat
            seq = Claw._on_writer(db -> Claw._scalar(db, "SELECT seq FROM claw_runtime_meta"), h)
            sleep(0.4) # longer than the stall budget plus a check interval
            @test Claw._on_writer(db -> Claw._scalar(db, "SELECT seq FROM claw_runtime_meta"), h) == seq
            journal = Claw._on_writer(db -> Claw._fetch_one(db, "SELECT status,failure_class FROM claw_evals"), h)
            @test journal.status == "running" && ismissing(journal.failure_class)
            @test Claw._on_writer(db -> Claw._scalar(db, "SELECT COUNT(*) FROM claw_tasks WHERE cancel=1"), h) == 0
        finally
            Claw.shutdown!(a; timeout_s = 10)
        end
    end
end
