isdefined(@__MODULE__, :durable_fixture) || include("durable_fixtures.jl")

function until(predicate;seconds=20)
    @test timedwait(predicate,seconds;pollint=.01)===:ok
end
function awaitsignal(event)
    task=@async wait(event)
    until(()->istaskdone(task))
    istaskdone(task) || error("controlled provider did not reach its barrier")
    fetch(task)
end
function turn_result!(a,s,input,text;calls=Agentif.AgentToolCall[],stop=:stop)
    msg=durable_message(a,text;calls)
    Agentif.append_state!(s,input,msg,Agentif.Usage(;input=2,output=1,total=3))
    s.most_recent_stop_reason=stop
    s
end
function tool_then_answer(name,args="{}")
    (f,a,s,input,abort;kw...)->isempty(filter(m->m isa Agentif.ToolResultMessage,s.messages)) ?
        turn_result!(a,s,input,"";calls=[Agentif.AgentToolCall(;call_id="call",name,arguments=args)],stop=:tool_calls) :
        turn_result!(a,s,input,"finished")
end

@testset "submission modes, withdrawal and final-boundary ordering" begin
    mktempdir() do dir
        entered=Threads.Event();release=Threads.Event();calls=Threads.Atomic{Int}(0)
        stream=(f,a,s,input,abort;kw...)->begin
            number=Threads.atomic_add!(calls,1)+1
            if number==1
                notify(entered);wait(release)
            end
            turn_result!(a,s,input,"answer $number")
        end
        h,c,p=durable_fixture(joinpath(dir,"claw.sqlite");stream)
        try
            first=Claw.submit!(h,c,"first";request_id="first")
            awaitsignal(entered)
            steer=Claw.submit!(h,c,"steer";request_id="steer",mode=:steer)
            passive=Claw.submit!(h,c,"passive";request_id="passive",mode=:write)
            followup=Claw.submit!(h,c,"followup";request_id="followup")
            withdrawn=Claw.submit!(h,c,"withdraw";request_id="withdraw")
            @test Claw.withdraw!(withdrawn)
            @test !Claw.withdraw!(withdrawn)
            caller_abort=Agentif.Abort();Agentif.abort!(caller_abort)
            @test Claw.wait_submission(first;abort=caller_abort)===nothing
            @test Claw.submission(first).state=="placed"
            notify(release)
            @test Claw.wait_submission(followup;timeout_s=20).state=="answered"
            @test Claw.submission(steer).state=="answered"
            @test Claw.submission(passive).reason=="passive_write"
            @test Claw.submission(withdrawn).state=="withdrawn"
            text=Agentif.message_text.(Agentif.load_branch(h.history,"test").messages)
            @test text==["first","answer 1","passive","steer","answer 2","followup","answer 3"]
            @test Claw.submission(first).run_id==Claw.submission(steer).run_id
            @test Claw.submission(first).run_id!=Claw.submission(followup).run_id
        finally
            notify(release);Claw.close_harness!(h;grace_s=10)
        end
    end
end

@testset "durable cancellation rejects late progress and tool calls" begin
    mktempdir() do dir
        entered=Threads.Event();invoked=Ref(0)
        tool=Agentif.@tool "must not run" late()=begin invoked[]+=1;"late" end
        stream=(f,a,s,input,abort;kw...)->begin
            notify(entered)
            while !Agentif.isaborted(abort);sleep(.01);end
            msg=durable_message(a,"late partial")
            try f(Agentif.MessageUpdateEvent(:assistant,msg,:text_delta,"late partial",nothing)) catch e;@test e isa Claw.StaleInvocation;end
            turn_result!(a,s,input,"";calls=[Agentif.AgentToolCall(;call_id="late",name="late",arguments="{}")],stop=:tool_calls)
        end
        h,c,p=durable_fixture(joinpath(dir,"claw.sqlite");stream,tools=Agentif.AgentTool[tool])
        try
            r=Claw.submit!(h,c,"cancel";request_id="cancel")
            awaitsignal(entered);Claw.abort_conversation!(h,c)
            @test Claw.wait_submission(r;timeout_s=20).state=="unanswered"
            @test invoked[]==0
            @test !occursin("late partial",JSON.json(Agentif.load_branch(h.history,"test").messages))
            @test all(t->t.status=="terminal",Claw.snapshot(h,c).tasks)
        finally Claw.close_harness!(h;grace_s=10) end
    end
end

@testset "uncertain effect requires evidence and fences settled callbacks" begin
    mktempdir() do dir
        invoked=Ref(0);saved=Ref{Any}(nothing)
        tool=Agentif.@tool "opaque" opaque()="unused"
        invoke=(t,args,ctx)->begin
            saved[]=ctx;invoked[]+=1
            Claw.report_progress!(ctx,Dict("large"=>repeat("🦊",1000)))
            error("effect happened; lost response secret-test-key")
        end
        h,c,p=durable_fixture(joinpath(dir,"claw.sqlite");stream=tool_then_answer("opaque"),tools=Agentif.AgentTool[tool],
            specs=[Claw.ToolSpec(tool;version="opaque-v1",invoke)],limits=Claw.HarnessLimits(;progress_bytes=96))
        try
            r=Claw.submit!(h,c,"work";request_id="opaque")
            until(()->any(t->t.blocked!==nothing && occursin("uncertain effect",t.blocked),Claw.snapshot(h,c).tasks))
            @test invoked[]==1
            @test Claw.submission(r).state=="placed"
            task=only(filter(t->t.kind=="tool",Claw.snapshot(h,c).tasks))
            @test JSON.parse(task.progress)["truncated"]
            @test !occursin("secret-test-key",task.blocked)
            @test_throws Claw.StaleInvocation Claw.report_progress!(saved[],"late")
            @test_throws ArgumentError Claw.resolve_effect!(h,task.id,Agentif.ToolOutcome("proven");note="")
            Claw.resolve_effect!(h,task.id,Agentif.ToolOutcome("proven");note="independent effect receipt verified")
            @test Claw.wait_submission(r;timeout_s=20).state=="answered"
            @test invoked[]==1
            @test_throws Claw.StaleInvocation Claw.report_progress!(saved[],"later")
        finally Claw.close_harness!(h;grace_s=10) end
    end
end

@testset "owned child releases the only model and tool permits" begin
    mktempdir() do dir
        cfg=Claw.AgentConfig(;provider="test",model_id="durable-test",apikey="key",base_dir=dir)
        tools=Claw._create_subagent_tools(Claw.LLMToolsEventSource(cfg))
        order=String[];order_lock=ReentrantLock()
        stream=(f,a,s,input,abort;kw...)->begin
            lock(order_lock) do;push!(order,a.prompt=="child" ? "child" : "parent");end
            if a.prompt=="child"
                turn_result!(a,s,input,"child answer")
            elseif any(m->m isa Agentif.ToolResultMessage,s.messages)
                turn_result!(a,s,input,"parent answer")
            else
                args=JSON.json(Dict("name"=>"worker","system_prompt"=>"child","input_message"=>"child input","run_sync"=>true))
                turn_result!(a,s,input,"";calls=[Agentif.AgentToolCall(;call_id="spawn",name="start_subagent",arguments=args)],stop=:tool_calls)
            end
        end
        h,c,p=durable_fixture(joinpath(dir,"claw.sqlite");stream,tools,limits=Claw.HarnessLimits(;models=1,tools=1))
        try
            r=Claw.submit!(h,c,"parent input";request_id="parent")
            @test Claw.wait_submission(r;timeout_s=30).state=="answered"
            until(()->all(t->t.status=="terminal",Claw.snapshot(h,c).tasks))
            @test order==["parent","child","parent"]
            children=Claw._dread(db->Claw._drows(db,"SELECT * FROM claw_child_aliases"),h)
            @test length(children)==1
            @test length(Claw.snapshot(h,only(children).child_id).submissions)==1
            @test length(filter(t->t.kind=="child",Claw.snapshot(h,c).tasks))==1
            @test Agentif.message_text(Agentif.load_branch(h.history,"test").messages[3])=="child answer"
            Claw.submit!(h,c,"parent input";request_id="parent")
            @test length(order)==3
        finally Claw.close_harness!(h;grace_s=10) end
    end
end

@testset "durable summary validation, known usage and complete context" begin
    for stop in (:stop,:length)
        mktempdir() do dir
            contexts=Any[]
            stream=(f,a,s,input,abort;kw...)->begin
                push!(contexts,deepcopy(s.messages))
                summary=a.prompt==Agentif.COMPACTION_SUMMARY_PROMPT
                turn_result!(a,s,input,summary ? "compacted memory" : "answer";stop=summary ? stop : :stop)
            end
            h,c,p=durable_fixture(joinpath(dir,"claw.sqlite");stream,compact=true,window=180)
            try
                Claw._transition!(h;point=:fixture_history) do db,seq
                    row=Claw._done(db,"SELECT * FROM claw_conversations WHERE id=?",(c.id,))
                    Claw._entry!(db,h,seq,row,[Agentif.UserMessage(repeat("old ",100)),durable_message(h.agents[p.id],repeat("response ",100))])
                end
                fresh=repeat("fresh input ",8)
                r=Claw.submit!(h,c,fresh;request_id="fresh")
                result=Claw.wait_submission(r;timeout_s=20)
                @test result!==nothing
                @test result.state==(stop===:stop ? "answered" : "unanswered")
                history=Agentif.load_branch(h.history,"test").messages
                @test any(m->m isa Agentif.CompactionSummaryMessage,history)==(stop===:stop)
                usage=Claw.snapshot(h,c).usage
                @test count(u->u.category=="compaction",usage)==1
                @test count(u->u.category=="model",usage)==(stop===:stop ? 1 : 0)
                @test stop!==:stop || Agentif.message_text.(history)[end-1:end]==[fresh,"answer"]
            finally Claw.close_harness!(h;grace_s=10) end
        end
    end
end

@testset "reset CAS prevents an interrupted summary reviving context" begin
    mktempdir() do dir
        entered=Threads.Event();release=Threads.Event()
        stream=(f,a,s,input,abort;kw...)->begin
            notify(entered);wait(release);turn_result!(a,s,input,"stale summary")
        end
        h,c,p=durable_fixture(joinpath(dir,"claw.sqlite");stream,compact=true,window=180)
        try
            Claw._transition!(h) do db,seq
                row=Claw._done(db,"SELECT * FROM claw_conversations WHERE id=?",(c.id,))
                Claw._entry!(db,h,seq,row,[Agentif.UserMessage(repeat("old ",200)),durable_message(h.agents[p.id],"old answer")])
            end
            r=Claw.submit!(h,c,repeat("new input ",10);request_id="reset")
            awaitsignal(entered)
            revision=Int(Claw.snapshot(h,c).context_revision)
            @test_throws Claw.StaleInvocation Claw.reset_conversation!(h,c.id;expected_revision=revision-1)
            Claw.reset_conversation!(h,c.id;expected_revision=revision)
            notify(release)
            @test Claw.wait_submission(r;timeout_s=20).state=="unanswered"
            @test isempty(Agentif.load_branch(h.history,"test").messages)
        finally notify(release);Claw.close_harness!(h;grace_s=10) end
    end
end

@testset "immutable delivery address and remote ambiguity" begin
    for capability in (:unsafe,:idempotent,:reconcile)
        mktempdir() do dir
            path=joinpath(dir,"claw.sqlite");keys=Set{String}();attempts=Ref(0);addresses=String[]
            adapter=Claw.DeliveryAdapter((address,body,key)->begin
                attempts[]+=1;push!(addresses,address["destination"]);push!(keys,key);Dict("remote"=>key)
            end;capability,reconcile=capability===:reconcile ? (address,key,receipt)->Dict("remote"=>key) : nothing)
            fault=(point,h)->point===:after_remote_send ? error("lost local send receipt") : nothing
            h,c,p=durable_fixture(path;fault)
            Claw.register_delivery_adapter!(h,"fixture",adapter)
            c=Claw.ensure_conversation!(h;branch_id="test",profile=p,delivery=Claw.DeliveryAddress("fixture",1,Dict("destination"=>"original")))
            r=Claw.submit!(h,c,"answer and send";request_id="send")
            until(()->any(o->o.state=="uncertain",Claw.snapshot(h,c).deliveries))
            @test Claw.submission(r).state=="answered"
            @test attempts[]==1
            @test Claw.close_harness!(h;grace_s=10).status==:closed
            h,c,p=durable_fixture(path)
            try
                Claw.register_delivery_adapter!(h,"fixture",adapter)
                Claw.ensure_conversation!(h;branch_id="test",profile=p,delivery=Claw.DeliveryAddress("fixture",1,Dict("destination"=>"changed")))
                Claw.resume!(h)
                until(()->begin
                    deliveries=Claw.snapshot(h,c).deliveries
                    !isempty(deliveries) && only(deliveries).state==(capability===:unsafe ? "uncertain" : "sent")
                end)
                o=only(Claw.snapshot(h,c).deliveries)
                @test o.state==(capability===:unsafe ? "uncertain" : "sent")
                @test attempts[]==(capability===:idempotent ? 2 : 1)
                @test length(keys)==1
                @test all(==("original"),addresses)
                if capability===:unsafe
                    Claw.resolve_delivery!(h,o.id;receipt=Dict("remote"=>only(keys)),note="remote post verified")
                    @test only(Claw.snapshot(h,c).deliveries).state=="sent"
                end
            finally Claw.close_harness!(h;grace_s=10) end
        end
    end
end

@testset "native environment containment, UTF-8 and mutation serialization" begin
    mktempdir() do dir
        env=LLMTools.LocalExecutionEnv(LLMTools.EnvRef(dir;id="fixture"))
        LLMTools.env_write(env,"a.txt","one")
        LLMTools.env_edit(env,"a.txt","one","two")
        @test occursin("two",LLMTools.env_read(env,"a.txt"))
        @test LLMTools.env_stat(env,"a.txt").size==3
        @test "a.txt" in LLMTools.env_list(env)
        @test_throws ArgumentError LLMTools.env_read(env,"../escape")
        shell=LLMTools.env_shell(env,"printf '\\377'";max_bytes=100)
        @test isvalid(shell.output)
        aborted=Agentif.Abort();Agentif.abort!(aborted)
        @test_throws Agentif.AbortEvaluation LLMTools.env_shell(env,"echo forbidden";abort=aborted)
        denied=LLMTools.LocalExecutionEnv(LLMTools.EnvRef(dir;id="denied",capabilities=["read"]))
        @test_throws ArgumentError LLMTools.env_write(denied,"denied","no")
    end
end
