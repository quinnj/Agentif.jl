isdefined(@__MODULE__, :attached_fixture) || include("durable_integration_fixtures.jl")
isdefined(@__MODULE__, :durable_jev) || include("durable_source_fixtures.jl")

# Regression tests for durable runtime liveness, effect, child and privacy bugs.
# Every wait is bounded, so a regression fails instead of hanging.

regr_wait(f; seconds = 10) = timedwait(f, seconds; pollint = 0.01) === :ok
function regr_turn!(a, s, input, text; calls = Agentif.AgentToolCall[], stop = :stop)
    Agentif.append_state!(s, input, durable_message(a, text; calls), Agentif.Usage(; input = 2, output = 1, total = 3))
    s.most_recent_stop_reason = stop
    return s
end
regr_call(name, id = "call"; args = "{}") = Agentif.AgentToolCall(; call_id = id, name, arguments = args)
regr_has_result(s) = any(m -> m isa Agentif.ToolResultMessage, s.messages)
regr_seq(h) = Claw._on_writer(db -> Claw._scalar(db, "SELECT seq FROM claw_runtime_meta"), h)
regr_texts(h, branch) = Agentif.message_text.(Agentif.load_branch(h.history, branch).messages)
regr_results(h, branch) = filter(m -> m isa Agentif.ToolResultMessage, Agentif.load_branch(h.history, branch).messages)
# "answered", or the state and reason, so a failure shows why the run ended.
function regr_outcome(r; timeout_s = 10)
    x = Claw.wait_submission(r; timeout_s)
    x === nothing && return "still $(Claw.submission(r).state) after $(timeout_s)s"
    return ismissing(x.reason) ? x.state : "$(x.state) ($(x.reason))"
end
function regr_context(h, c, p, key)
    id = Claw._transition!(h) do db, seq
        Claw._task_create!(db, seq, c.id, "tool", key; input = Dict("profile" => p.id), checkpoint = Dict("phase" => "execute"))
    end
    return first(Claw._reserve!(h, Claw._task_row(h, id)))
end
regr_finish!(ctx) = Claw._transition!(ctx.harness; context = ctx) do db, seq
    Claw._finish_task!(db, Claw._fetch_one(db, "SELECT * FROM claw_tasks WHERE id=?", (ctx.task_id,)), Dict("status" => "completed"))
end
regr_event(h, id) = Claw._on_writer(db -> Claw._fetch_one(db, "SELECT status,attempts,payload FROM claw_events WHERE id=?", (id,)), h)

@testset "regression: abort during a tool does not brick the conversation" begin
    mktempdir() do dir
        entered = Threads.Atomic{Bool}(false)
        tool = Agentif.@tool "slow" slow() = "unused"
        invoke = (t, args, ctx) -> begin
            entered[] = true
            regr_wait(() -> Agentif.isaborted(ctx.abort))
            throw(Agentif.AbortEvaluation())
        end
        stream = (f, a, s, input, abort; kw...) -> Agentif.message_text(last(s.messages)) == "work" ?
            regr_turn!(a, s, input, ""; calls = [regr_call("slow")], stop = :tool_calls) : regr_turn!(a, s, input, "answer")
        h, c, p = durable_fixture(
            joinpath(dir, "abort.sqlite"); stream, tools = Agentif.AgentTool[tool],
            specs = [Claw.ToolSpec(tool; version = "slow-v1", replay = :safe, invoke)]
        )
        try
            r = Claw.submit!(h, c, "work"; request_id = "work")
            @test regr_wait(() -> entered[])
            Claw.abort_conversation!(h, c)
            @test startswith(regr_outcome(r), "unanswered")
            @test regr_outcome(Claw.submit!(h, c, "next"; request_id = "next"); timeout_s = 5) == "answered"
            aborted = filter(m -> m.is_error && occursin("tool_call_aborted", Agentif.message_text(m)), regr_results(h, "test"))
            @test length(aborted) == 1
        finally
            Claw.close_harness!(h; grace_s = 5)
        end
    end
end

@testset "regression: an ordinary tool error reaches the model without an operator" begin
    mktempdir() do dir
        tool = Agentif.@tool "fails" fails() = throw(ArgumentError("bad tool argument"))
        stream = (f, a, s, input, abort; kw...) -> regr_has_result(s) ? regr_turn!(a, s, input, "handled") :
            regr_turn!(a, s, input, ""; calls = [regr_call("fails")], stop = :tool_calls)
        h, c, p = durable_fixture(joinpath(dir, "error.sqlite"); stream, tools = Agentif.AgentTool[tool])
        try
            @test regr_outcome(Claw.submit!(h, c, "go"; request_id = "go")) == "answered"
            @test only(regr_results(h, "test")).is_error
            @test !any(t -> t.blocked !== nothing && occursin("uncertain", t.blocked), Claw.snapshot(h, c).tasks)
        finally
            Claw.close_harness!(h; grace_s = 5)
        end
    end
end

@testset "regression: a blocked uncertain effect does not spin" begin
    mktempdir() do dir
        reconciles = Threads.Atomic{Int}(0)
        tool = Agentif.@tool "opaque" opaque() = "unused"
        # Interrupted mid-body, so the unsafe effect is uncertain.
        invoke = (t, args, ctx) -> (Agentif.abort!(ctx.abort); error("response lost"))
        reconcile = e -> (Threads.atomic_add!(reconciles, 1); nothing)
        stream = (f, a, s, input, abort; kw...) -> regr_has_result(s) ? regr_turn!(a, s, input, "answer") :
            regr_turn!(a, s, input, ""; calls = [regr_call("opaque")], stop = :tool_calls)
        h, c, p = durable_fixture(
            joinpath(dir, "spin.sqlite"); stream, tools = Agentif.AgentTool[tool],
            specs = [Claw.ToolSpec(tool; version = "opaque-v1", invoke, reconcile)]
        )
        try
            Claw.submit!(h, c, "go"; request_id = "go")
            @test regr_wait(() -> any(e -> e.effect_state == "uncertain", Claw.snapshot(h, c).effects))
            sleep(0.2)
            r0 = reconciles[];s0 = regr_seq(h)
            sleep(1)
            @test reconciles[] - r0 <= 3
            @test regr_seq(h) - s0 <= 3
        finally
            Claw.close_harness!(h; grace_s = 5)
        end
    end
end

@testset "regression: a transient error on the compaction summary is retried" begin
    mktempdir() do dir
        summaries = Threads.Atomic{Int}(0)
        stream = (f, a, s, input, abort; kw...) -> begin
            if a.prompt == Agentif.COMPACTION_SUMMARY_PROMPT && Threads.atomic_add!(summaries, 1) == 0
                f(Agentif.AgentErrorEvent(ErrorException("provider overloaded")))
                s.most_recent_stop_reason = :error
                return s
            end
            regr_turn!(a, s, input, a.prompt == Agentif.COMPACTION_SUMMARY_PROMPT ? "compacted memory" : "answer")
        end
        h, c, p = durable_fixture(
            joinpath(dir, "summary.sqlite"); stream, compact = true, window = 2000,
            limits = Claw.HarnessLimits(; retry_delays = [0.01], max_retry_delay = 0.05)
        )
        try
            Claw._transition!(h) do db, seq
                row = Claw._fetch_one(db, "SELECT * FROM claw_conversations WHERE id=?", (c.id,))
                Claw._entry!(db, h, seq, row, [Agentif.UserMessage(repeat("old ", 1000)), durable_message(h.agents[p.id], repeat("response ", 100))])
            end
            @test regr_outcome(Claw.submit!(h, c, repeat("fresh input ", 8); request_id = "fresh")) == "answered"
            @test summaries[] == 2
            @test any(m -> m isa Agentif.CompactionSummaryMessage, Agentif.load_branch(h.history, "test").messages)
        finally
            Claw.close_harness!(h; grace_s = 5)
        end
    end
end

@testset "regression: a provider overflow below the estimate compacts before the retry" begin
    mktempdir() do dir
        calls = String[];guard = ReentrantLock()
        stream = (f, a, s, input, abort; kw...) -> begin
            summary = a.prompt == Agentif.COMPACTION_SUMMARY_PROMPT
            n = lock(() -> (push!(calls, summary ? "summary" : "model"); count(==("model"), calls)), guard)
            summary && return regr_turn!(a, s, input, "compacted memory")
            if n == 1
                f(Agentif.AgentErrorEvent(ErrorException("prompt is too long: 250000 tokens > 200000 maximum")))
                s.most_recent_stop_reason = :error
                return s
            end
            regr_turn!(a, s, input, "answer")
        end
        h, c, p = durable_fixture(joinpath(dir, "overflow.sqlite"); stream, compact = true, window = 2000)
        try
            Claw._transition!(h) do db, seq
                row = Claw._fetch_one(db, "SELECT * FROM claw_conversations WHERE id=?", (c.id,))
                Claw._entry!(db, h, seq, row, [Agentif.UserMessage(repeat("old ", 100)), durable_message(h.agents[p.id], repeat("response ", 20))])
            end
            @test regr_outcome(Claw.submit!(h, c, "hi"; request_id = "overflow")) == "answered"
            @test calls == ["model", "summary", "model"]
        finally
            Claw.close_harness!(h; grace_s = 5)
        end
    end
end

@testset "regression: a graceful suspend records a tool that finishes within the grace" begin
    mktempdir() do dir
        path = joinpath(dir, "suspend.sqlite")
        entered = Threads.Atomic{Bool}(false);bodies = Threads.Atomic{Int}(0)
        tool = Agentif.@tool "quick" quick() = "unused"
        invoke = (t, args, ctx) -> begin
            Threads.atomic_add!(bodies, 1);entered[] = true;sleep(0.3)
            Agentif.ToolOutcome("done")
        end
        stream = (f, a, s, input, abort; kw...) -> regr_has_result(s) ? regr_turn!(a, s, input, "answer") :
            regr_turn!(a, s, input, ""; calls = [regr_call("quick")], stop = :tool_calls)
        spec = Claw.ToolSpec(tool; version = "quick-v1", invoke)
        h, c, p = durable_fixture(path; stream, tools = Agentif.AgentTool[tool], specs = [spec])
        Claw.submit!(h, c, "go"; request_id = "suspend")
        @test regr_wait(() -> entered[])
        @test Claw.close_harness!(h; mode = :suspend, grace_s = 5).status == :closed
        h, c, p = durable_fixture(path; stream, tools = Agentif.AgentTool[tool], specs = [spec])
        try
            @test only(Claw.snapshot(h, c).effects).effect_state == "completed"
            @test regr_outcome(Claw.lookup_submission(h, c.id, "suspend")) == "answered"
            @test bodies[] == 1
        finally
            Claw.close_harness!(h; grace_s = 5)
        end
    end
end

@testset "regression: aborting an answered generation that is completing keeps its outcome" begin
    mktempdir() do dir
        entered = Threads.Atomic{Bool}(false);release = Threads.Event()
        stream = (f, a, s, input, abort; kw...) -> (entered[] = true; wait(release); regr_turn!(a, s, input, "the answer"))
        h, c, p = durable_fixture(joinpath(dir, "completing.sqlite"); stream)
        try
            r = Claw.submit!(h, c, "go"; request_id = "go")
            @test regr_wait(() -> entered[])
            gen = only(filter(t -> t.kind == "generation", Claw.snapshot(h, c).tasks)).id
            # Owned work that is still unfinished when the generation answers.
            child = Claw._transition!(h) do db, seq
                Claw._task_create!(db, seq, c.id, "unsupported", "owned"; owner = gen)
            end
            notify(release)
            @test regr_outcome(r) == "answered"
            @test Claw.inspect_task(h, gen).status == "completing"
            Claw.abort_conversation!(h, c)
            @test regr_wait(() -> Claw.inspect_task(h, child).status == "terminal" && Claw.inspect_task(h, gen).status == "terminal")
            run = Claw._on_writer(db -> Claw._fetch_one(db, "SELECT status FROM claw_runs WHERE task_id=?", (gen,)), h)
            @test run.status == "completed"
            @test JSON.parse(Claw.inspect_task(h, gen).outcome)["status"] == "completed"
            @test Claw.submission(r).state == "answered"
        finally
            notify(release);Claw.close_harness!(h; grace_s = 5)
        end
    end
end

regr_subagent_tools(dir) = Claw._create_subagent_tools(
    Claw.LLMToolsEventSource(
        Claw.AgentConfig(; provider = "test", model_id = "durable-test", apikey = "key", base_dir = dir)
    )
)

@testset "regression: an async sub-agent does not block its parent conversation" begin
    mktempdir() do dir
        release = Threads.Event()
        stream = (f, a, s, input, abort; kw...) -> begin
            a.prompt == "child" && (wait(release); return regr_turn!(a, s, input, "child answer"))
            last(s.messages) isa Agentif.ToolResultMessage && return regr_turn!(a, s, input, "parent answer")
            Agentif.message_text(last(s.messages)) == "hello again" && return regr_turn!(a, s, input, "second parent answer")
            args = JSON.json(Dict("name" => "bg", "system_prompt" => "child", "input_message" => "long job", "run_sync" => false))
            regr_turn!(a, s, input, ""; calls = [regr_call("start_subagent", "spawn"; args)], stop = :tool_calls)
        end
        h, c, p = durable_fixture(joinpath(dir, "async.sqlite"); stream, tools = regr_subagent_tools(dir))
        try
            @test regr_outcome(Claw.submit!(h, c, "start background work"; request_id = "r1")) == "answered"
            @test regr_outcome(Claw.submit!(h, c, "hello again"; request_id = "r2"); timeout_s = 5) == "answered"
            child = Claw._on_writer(db -> Claw._fetch_one(db, "SELECT child_id FROM claw_child_aliases"), h).child_id
            @test !all(s -> s.state == "answered", Claw.snapshot(h, child).submissions) # the child is still running
        finally
            notify(release);Claw.close_harness!(h; grace_s = 5)
        end
    end
end

@testset "regression: async start then async message both notify completion" begin
    mktempdir() do dir
        release = Threads.Event();childcalls = Threads.Atomic{Int}(0)
        stream = (f, a, s, input, abort; kw...) -> begin
            a.prompt == "child" && Threads.atomic_add!(childcalls, 1) == 0 && wait(release)
            durable_stream(f, a, s, input, abort; kw...)
        end
        a, h = attached_fixture(joinpath(dir, "notify.sqlite"); stream)
        try
            p = Claw.register_profile!(h, Agentif.Agent(; model = durable_model(), apikey = "key", prompt = "parent", tools = regr_subagent_tools(dir)))
            c = Claw.ensure_conversation!(h; branch_id = "native", profile = p)
            ctx = regr_context(h, c, p, "launch")
            Claw._subagent_operation!(1, (; name = "worker", system_prompt = "child", input_message = "first", run_sync = false, prompt = nothing), ctx)
            regr_finish!(ctx);Claw.resume!(h)
            @test regr_wait(() -> childcalls[] >= 1)
            ctx = regr_context(h, c, p, "message")
            Claw._subagent_operation!(2, (; name = "worker", input_message = "second", run_sync = false, mode = "followup"), ctx)
            regr_finish!(ctx)
            notify(release)
            count_rows(sql) = Claw._on_writer(db -> Claw._scalar(db, sql), h)
            events = "SELECT COUNT(*) FROM claw_events WHERE dedup_key LIKE 'child-completion:%'"
            regr_wait(() -> count_rows(events) >= 2)
            @test count_rows(events) == 2
            @test count_rows("SELECT COUNT(*) FROM claw_outbox WHERE logical_key LIKE 'child-completion:%'") == 2
        finally
            notify(release);Claw.shutdown!(a; timeout_s = 10)
        end
    end
end

@testset "regression: more than four tool rounds fit the default attempt budget" begin
    mktempdir() do dir
        tool = Agentif.@tool "step" step() = "ok"
        stream = (f, a, s, input, abort; kw...) -> begin
            k = count(m -> m isa Agentif.ToolResultMessage, s.messages)
            k < 5 ? regr_turn!(a, s, input, ""; calls = [regr_call("step", "s$k")], stop = :tool_calls) : regr_turn!(a, s, input, "done")
        end
        h, c, p = durable_fixture(
            joinpath(dir, "rounds.sqlite"); stream, tools = Agentif.AgentTool[tool],
            specs = [Claw.ToolSpec(tool; version = "step-v1", replay = :safe)]
        )
        try
            @test regr_outcome(Claw.submit!(h, c, "go"; request_id = "rounds")) == "answered"
            @test length(regr_results(h, "test")) == 5
        finally
            Claw.close_harness!(h; grace_s = 5)
        end
    end
end

@testset "regression: queued steers are placed one per boundary" begin
    mktempdir() do dir
        entered = Threads.Atomic{Bool}(false);release = Threads.Event();n = Threads.Atomic{Int}(0)
        stream = (f, a, s, input, abort; kw...) -> begin
            k = Threads.atomic_add!(n, 1) + 1
            k == 1 && (entered[] = true; wait(release))
            regr_turn!(a, s, input, "answer $k")
        end
        h, c, p = durable_fixture(joinpath(dir, "steers.sqlite"); stream)
        try
            Claw.submit!(h, c, "first"; request_id = "first")
            @test regr_wait(() -> entered[])
            s1 = Claw.submit!(h, c, "steer1"; request_id = "s1", mode = :steer)
            s2 = Claw.submit!(h, c, "steer2"; request_id = "s2", mode = :steer)
            notify(release)
            @test regr_outcome(s2) == "answered"
            @test regr_outcome(s1) == "answered"
            @test regr_texts(h, "test") == ["first", "answer 1", "steer1", "answer 2", "steer2", "answer 3"]
        finally
            notify(release);Claw.close_harness!(h; grace_s = 5)
        end
    end
end

@testset "regression: a forward wall-clock jump does not expire an active run" begin
    mktempdir() do dir
        offset = Ref(0.0);entered = Threads.Atomic{Bool}(false);release = Threads.Event()
        tool = Agentif.@tool "noop" noop() = "ok"
        stream = (f, a, s, input, abort; kw...) -> begin
            regr_has_result(s) && return regr_turn!(a, s, input, "answer")
            entered[] = true;wait(release)
            regr_turn!(a, s, input, ""; calls = [regr_call("noop")], stop = :tool_calls)
        end
        h = Claw.open_harness(
            joinpath(dir, "clock.sqlite"); stream_fn = stream, clock = () -> time() + offset[],
            compaction = Agentif.CompactionConfig(; enabled = false)
        )
        try
            agent = Agentif.Agent(; model = durable_model(), prompt = "test", apikey = "secret-test-key", tools = Agentif.AgentTool[tool])
            p = Claw.register_profile!(h, agent; specs = [Claw.ToolSpec(tool; version = "noop-v1", replay = :safe)])
            c = Claw.ensure_conversation!(h; branch_id = "clock", profile = p)
            r = Claw.submit!(h, c, "go"; request_id = "clock")
            @test regr_wait(() -> entered[])
            offset[] = 2 * 3600.0 # an NTP or VM-resume step; little real time passes
            notify(release)
            @test regr_outcome(r) == "answered"
        finally
            notify(release);Claw.close_harness!(h; grace_s = 5)
        end
    end
end

@testset "regression: a delivery cancelled mid-send becomes uncertain and resolvable" begin
    mktempdir() do dir
        entered = Threads.Atomic{Bool}(false);release = Threads.Event()
        adapter = Claw.DeliveryAdapter((address, body, key) -> (entered[] = true; wait(release); Dict("remote" => "posted")))
        h, c, p = durable_fixture(joinpath(dir, "delivery.sqlite"))
        try
            Claw.register_delivery_adapter!(h, "fx", adapter)
            c = Claw.ensure_conversation!(h; branch_id = "test", profile = p, delivery = Claw.DeliveryAddress("fx", 1, Dict("d" => "x")))
            @test regr_outcome(Claw.submit!(h, c, "go"; request_id = "go")) == "answered"
            @test regr_wait(() -> entered[])
            Claw.abort_conversation!(h, c; include_background = true)
            notify(release)
            state() = only(Claw.snapshot(h, c).deliveries).state
            @test regr_wait(() -> state() != "sending"; seconds = 5)
            @test state() == "uncertain"
            Claw.resolve_delivery!(h, only(Claw.snapshot(h, c).deliveries).id; receipt = Dict("remote" => "posted"), note = "remote post verified")
            @test state() == "sent"
        finally
            notify(release);Claw.close_harness!(h; grace_s = 5)
        end
    end
end

@testset "regression: shell tools require the environment's shell capability" begin
    mktempdir() do dir
        tools = Claw._register_coding_adapters!(LLMTools.coding_tools(dir))
        calls = [
            regr_call("write", "w"; args = JSON.json(Dict("path" => "ok.txt", "content" => "written"))),
            regr_call("exec_command", "x"; args = JSON.json(Dict("cmd" => "touch marker.txt", "yield_time_ms" => 2000))),
        ]
        stream = (f, a, s, input, abort; kw...) -> regr_has_result(s) ? regr_turn!(a, s, input, "done") :
            regr_turn!(a, s, input, ""; calls, stop = :tool_calls)
        h = Claw.open_harness(joinpath(dir, "caps.sqlite"); stream_fn = stream, compaction = Agentif.CompactionConfig(; enabled = false))
        try
            env = LLMTools.LocalExecutionEnv(LLMTools.EnvRef(dir; id = "no-shell", capabilities = ["read", "write", "edit"]))
            p = Claw.register_profile!(h, Agentif.Agent(; model = durable_model(), prompt = "test", apikey = "secret-test-key", tools); environment = env)
            c = Claw.ensure_conversation!(h; branch_id = "caps", profile = p)
            @test regr_outcome(Claw.submit!(h, c, "go"; request_id = "caps")) == "answered"
            @test read(joinpath(dir, "ok.txt"), String) == "written"
            @test !isfile(joinpath(dir, "marker.txt"))
            denied = only(filter(m -> m.call_id == "x", regr_results(h, "caps")))
            @test denied.is_error
            @test occursin("capability", Agentif.message_text(denied))
        finally
            Claw.close_harness!(h; grace_s = 5)
        end
    end
end

@testset "regression: file mutation guards cover symlink aliases" begin
    # The concurrent edits only race with more than one thread; the guard check
    # after them is deterministic on any thread count.
    mktempdir() do dir
        env = LLMTools.LocalExecutionEnv(LLMTools.EnvRef(dir))
        original = "A\n" * join(("filler line $i" for i in 1:20000), "\n") * "\nB"
        write(joinpath(dir, "a.txt"), original)
        symlink(joinpath(dir, "a.txt"), joinpath(dir, "link.txt"))
        lost = 0
        for _ in 1:20
            write(joinpath(dir, "a.txt"), original)
            go = Threads.Event()
            t1 = Threads.@spawn (wait(go); LLMTools.env_edit(env, "a.txt", "A\n", "A1\n"))
            t2 = Threads.@spawn (wait(go); LLMTools.env_edit(env, "link.txt", "\nB", "\nB1"))
            notify(go);fetch(t1);fetch(t2)
            text = read(joinpath(dir, "a.txt"), String)
            startswith(text, "A1\n") && endswith(text, "\nB1") || (lost += 1)
        end
        @test lost == 0
        # While a mutation through the real path holds its guard, an edit
        # through the alias waits for it.
        write(joinpath(dir, "a.txt"), original)
        alias_edit = Ref{Task}()
        finished_while_held = LLMTools._env_mutate(env, "a.txt", Agentif.Abort(), Inf) do
            alias_edit[] = Threads.@spawn LLMTools.env_edit(env, "link.txt", "\nB", "\nB1")
            timedwait(() -> istaskdone(alias_edit[]), 0.3; pollint = 0.01) === :ok
        end
        fetch(alias_edit[])
        @test !finished_while_held
    end
end

@testset "regression: a poisoned harness returns claimed events and keeps intake" begin
    mktempdir() do dir
        a, h = attached_fixture(joinpath(dir, "poison.sqlite"))
        try
            a._state[] = :running
            Claw.register_event_handler!(a, Claw.EventHandler("h", ["durable-event"], "handle"))
            id = Claw.submit_event!(a, DurableEvent(DurableChannel("p-chan"; post = "p1"), "acknowledged message"))
            h.state = :poisoned
            Claw._process_event!(a, id)
            row = regr_event(h, id)
            @test row.status == "pending"
            @test row.attempts == 0
            next = try
                Claw.submit_event!(a, DurableEvent(DurableChannel("p2"; post = "p2"), "next message"))
            catch err
                err
            end
            @test next isa Integer && regr_event(h, next).status == "pending"
        finally
            h.state = :open;Claw.shutdown!(a; timeout_s = 10)
        end
    end
end

struct RegrPostIdEvent <: Claw.ChannelEvent
    channel::DurableChannel
    text::String
end
Claw.get_name(::RegrPostIdEvent) = "durable-event"
Claw.get_channel(e::RegrPostIdEvent) = e.channel
Claw.event_content(e::RegrPostIdEvent) = e.text
# Mattermost records the platform post as `post_id` rather than `source_id`.
Claw.event_extra(e::RegrPostIdEvent) = Dict{String, Any}("post_id" => e.channel.post)

@testset "regression: post scrub matches post_id, survives corrupt rows, drops search and keeps later input" begin
    mktempdir() do dir
        secret = "regression-erased-secret-3381"
        a, h = attached_fixture(joinpath(dir, "privacy.sqlite"))
        try
            p = Claw._register_default_profile!(h, a)
            c = Claw.ensure_conversation!(h; branch_id = "privacy", profile = p)
            Claw._transition!(h) do db, seq
                row = Claw._fetch_one(db, "SELECT * FROM claw_conversations WHERE id=?", (c.id,))
                Claw._entry!(db, h, seq, row, [Agentif.UserMessage("conversation $secret")]; post_id = "erase")
                Claw._entry!(db, h, seq, row, [Agentif.UserMessage("later unrelated message")]; post_id = "later")
            end
            event = Claw.submit_event!(a, RegrPostIdEvent(DurableChannel("mm"; post = "erase"), "event $secret"))
            Agentif.append_branch_entry!(
                a.session_store, "searchable", Agentif.SessionEntry(;
                    id = "indexed-entry",
                    messages = Agentif.StoredAgentMessage[Agentif.UserMessage("search $secret")], post_id = "erase", channel_id = "mm"
                )
            )
            documents() = Claw._on_writer(db -> Claw._scalar(db, "SELECT COUNT(*) FROM documents WHERE key='session:entry:indexed-entry'"), h)
            @test documents() > 0
            @test h.scheduler === nothing # so no indexer can remove documents
            Claw.scrub_durable_post!(h, "erase")
            @test !occursin(secret, regr_event(h, event).payload)
            @test documents() == 0
            text = JSON.json(Agentif.load_branch(h.history, "privacy").messages)
            @test !occursin(secret, text)
            @test occursin("later unrelated message", text)
            Claw.execute_write(a._writer, "INSERT INTO claw_events(source,name,payload,status,attempts,lane,created_at,next_attempt_at) VALUES('x','y','{not json','dead',1,'l',0,0)")
            @test try
                Claw.scrub_durable_post!(h, "another-post");true
            catch
                false
            end
        finally
            Claw.shutdown!(a; timeout_s = 10)
        end
    end
end

@testset "regression: a frozen batch with a dead-lettered member dispatches the rest" begin
    mktempdir() do dir
        a, h = attached_fixture(joinpath(dir, "frozen.sqlite"))
        try
            durable_source_rehydrate!(a)
            Claw._register_default_profile!(h, a)
            handler = Claw.EventHandler("source", ["durable-relevance"], "h"; trust = :untrusted, tools = String[])
            Claw.register_event_handler!(a, handler)
            group = source_claims(a, ["one", "two"])
            first_id, second_id = group[1][1].id, group[2][1].id
            # Freeze the batch, then fail before its dispatch commits.
            h.fault = (point, h) -> point == :before_dispatch && error("injected rollback before dispatch")
            @test_throws ErrorException Claw._durable_dispatch_group!(a, group, [handler])
            h.fault = (point, h) -> nothing
            Claw._release_claim!(a, [r for (r, _) in group])
            Claw.execute_write(a._writer, "UPDATE claw_events SET status='dead',last_error='dead-lettered' WHERE id=?", (second_id,))
            a._state[] = :running
            Claw._process_event!(a, first_id)
            regr_wait(() -> regr_event(h, first_id).status == "done")
            @test regr_event(h, first_id).status == "done"
            @test Claw._on_writer(db -> Claw._scalar(db, "SELECT COUNT(*) FROM claw_submissions WHERE state='answered'"), h) == 1
        finally
            Claw.shutdown!(a; timeout_s = 10)
        end
    end
end

@testset "regression: durable dispatch releases live events and unused channels" begin
    mktempdir() do dir
        a, h = attached_fixture(joinpath(dir, "live.sqlite"))
        try
            a._state[] = :running
            Claw.register_event_handler!(a, Claw.EventHandler("rx", ["durable-event"], "handle"; filter = Claw.EventFilter(:regex, "keep")))
            channels = [DurableChannel("live-$i"; post = "p$i") for i in 1:3]
            ids = [Claw.submit_event!(a, DurableEvent(ch, i == 1 ? "keep this" : "drop this")) for (i, ch) in enumerate(channels)]
            Claw._process_event_batch!(a, ids)
            @test regr_wait(() -> all(id -> regr_event(h, id).status in ("done", "dead"), ids))
            @test regr_wait(() -> length(channels[1].responses) == 1)
            regr_wait(() -> lock(() -> isempty(a._live_events), a._live_lock); seconds = 5)
            @test lock(() -> length(a._live_events), a._live_lock) == 0
            @test [ch.closed for ch in channels] == [true, true, true]
        finally
            Claw.shutdown!(a; timeout_s = 10)
        end
    end
end

@testset "regression: snapshots and watches hide progress and resource details" begin
    mktempdir() do dir
        progress_secret = "partial-output-secret-5521";resource_secret = "resource-detail-secret-7730"
        h, c, p = durable_fixture(joinpath(dir, "observe.sqlite"))
        try
            ctx = regr_context(h, c, p, "observed")
            Claw.report_progress!(ctx, Dict("partial" => progress_secret))
            Claw.record_managed_resource!(ctx; kind = "worker", key = "resource", details = Dict("command" => resource_secret))
            w = Claw.watch(h, c.id)
            frame = Claw.next_frame!(w)
            close(w)
            for shown in (repr(Claw.snapshot(h, c)), repr(frame.snapshot))
                @test !occursin(progress_secret, shown)
                @test !occursin(resource_secret, shown)
            end
            @test occursin(progress_secret, Claw.inspect_task(h, ctx.task_id; include_payload = true).progress)
        finally
            Claw.close_harness!(h; grace_s = 5)
        end
    end
end
