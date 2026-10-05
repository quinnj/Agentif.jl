isdefined(@__MODULE__, :contract_context) || include("durable_contract_test.jl")

function private_runtime_payloads(h)
    tables=("session_entries","claw_entry_runtime","claw_agent_profiles","claw_conversations","claw_submissions",
        "claw_runs","claw_tasks","claw_tool_executions","claw_outbox","claw_events","claw_managed_resources",
        "claw_event_handlers","claw_dispatch_groups","claw_event_dispatches")
    Claw._dread(db->JSON.json([Claw._drows(db,"SELECT * FROM $table") for table in tables]),h)
end

@testset "redaction removes summary and fork copies while preserving older memory" begin
    mktempdir() do dir
        secret="private-summary-source-6712"
        stream=(f,a,s,input,abort;kw...)->begin
            msg=durable_message(a,a.prompt==Agentif.COMPACTION_SUMMARY_PROMPT ? "summary of $secret" : "answer")
            Agentif.append_state!(s,input,msg,Agentif.Usage(;total=1));s.most_recent_stop_reason=:stop;s
        end
        h,c,p=durable_fixture(joinpath(dir,"summary.sqlite");stream,compact=true,window=2000)
        try
            Claw._transition!(h) do db,seq
                row=Claw._done(db,"SELECT * FROM claw_conversations WHERE id=?",(c.id,))
                Claw._entry!(db,h,seq,row,[Agentif.UserMessage("older independent memory"),durable_message(h.agents[p.id],"older answer")];post_id="older")
                Claw._entry!(db,h,seq,row,[Agentif.UserMessage("$secret "*repeat("old ",1000)),durable_message(h.agents[p.id],repeat("response ",100))];post_id="erase-summary")
            end
            r=Claw.submit!(h,c,"fresh input";request_id="fresh")
            @test Claw.wait_submission(r;timeout_s=20).state=="answered"
            @test any(m->m isa Agentif.CompactionSummaryMessage,Agentif.load_branch(h.history,"test").messages)
            fork=Claw.fork_conversation!(h,c.id;branch_id="summary-fork")
            @test occursin(secret,JSON.json(Agentif.load_branch(h.history,"summary-fork").messages))
            Claw.scrub_durable_post!(h,"erase-summary")
            @test !occursin(secret,private_runtime_payloads(h))
            @test !occursin(secret,JSON.json(Agentif.load_branch(h.history,"summary-fork").messages))
            @test occursin("older independent memory",JSON.json(Agentif.load_branch(h.history,"test").messages))
            @test all(t->t.cancel==1 || t.status=="terminal",Claw.snapshot(h,fork).tasks)
        finally Claw.close_harness!(h;grace_s=10) end
    end
end

@testset "redaction fences a live classifier and removes source metadata copies" begin
    mktempdir() do dir
        secret="private-classifier-source-9138"
        entered=Threads.Event();release=Threads.Event()
        stream=(f,a,s,input,abort;kw...)->begin
            notify(entered);wait(release)
            msg=durable_message(a,"{\"match\":true}")
            Agentif.append_state!(s,input,msg,Agentif.Usage(;total=1));s.most_recent_stop_reason=:stop;s
        end
        a,h=attached_fixture(joinpath(dir,"classifier.sqlite");stream)
        dispatch=nothing
        try
            a._state[]=:running
            Claw.register_event_handler!(a,Claw.EventHandler("classifier",["durable-event"],"handle";filter=Claw.EventFilter(:prompt,"case")))
            id=Claw.submit_event!(a,DurableEvent(DurableChannel("classifier";post="erase-classifier"),secret))
            Claw._transition!(h) do db,seq
                saved=Claw._done(db,"SELECT payload FROM claw_events WHERE id=?",(id,))
                payload=JSON.parse(saved.payload);payload["extra"]["body_copy"]=secret
                Claw._exec!(db,"UPDATE claw_events SET payload=? WHERE id=?",(JSON.json(payload),id))
            end
            dispatch=Threads.@spawn Claw._process_event!(a,id)
            signal=@async wait(entered)
            integration_until(()->istaskdone(signal));fetch(signal)
            @test occursin(secret,private_runtime_payloads(h))
            Claw.scrub_durable_post!(h,"erase-classifier")
            notify(release)
            integration_until(()->istaskdone(dispatch));fetch(dispatch)
            integration_until(()->isempty(lock(()->collect(h.live),h.lock)))
            @test !occursin(secret,private_runtime_payloads(h))
            @test Claw._dread(db->Claw._done(db,"SELECT status FROM claw_events WHERE id=?",(id,)).status,h)=="dead"
            @test Claw._dread(db->Claw._scalar(db,"SELECT COUNT(*) FROM claw_submissions"),h)==0
            @test !haskey(a._live_events,id)
        finally notify(release);Claw.shutdown!(a;timeout_s=10) end
    end
end

@testset "redaction follows owned-child completion events and their dispatch copies" begin
    mktempdir() do dir
        secret="private-child-source-4627"
        stream=(f,a,s,input,abort;kw...)->begin
            msg=durable_message(a,"derived answer: $secret")
            Agentif.append_state!(s,input,msg,Agentif.Usage(;total=1));s.most_recent_stop_reason=:stop;s
        end
        cfg=Claw.AgentConfig(;provider="test",model_id="durable-test",apikey="key",base_dir=dir)
        tools=Claw._create_subagent_tools(Claw.LLMToolsEventSource(cfg))
        a,h=attached_fixture(joinpath(dir,"child.sqlite");stream)
        try
            a._state[]=:running
            p=Claw.register_profile!(h,Agentif.Agent(;model=durable_model(),apikey="key",prompt="parent",tools))
            c=Claw.ensure_conversation!(h;branch_id="parent",profile=p,
                routing=Dict("post_id"=>"erase-child","supervision"=>Dict("event_content"=>secret)))
            Claw._transition!(h) do db,seq
                row=Claw._done(db,"SELECT * FROM claw_conversations WHERE id=?",(c.id,))
                Claw._entry!(db,h,seq,row,[Agentif.UserMessage(secret)];post_id="erase-child")
            end
            ctx=contract_context(h,c,p,"launch")
            Claw.record_managed_resource!(ctx;kind="worker",key="private-resource",details=Dict("name"=>"worker","copied_input"=>secret))
            Claw._subagent_operation!(1,(;name="worker",system_prompt="child context: $secret",input_message=secret,
                run_sync=false,prompt="handle completion of $secret"),ctx)
            finish_contract_context!(ctx);Claw.resume!(h)
            integration_until(()->Claw._dread(db->Claw._scalar(db,"SELECT COUNT(*) FROM claw_events"),h)==1)
            event=Claw._dread(db->Claw._done(db,"SELECT id FROM claw_events"),h)
            Claw._process_event!(a,Int(event.id))
            integration_until(()->Claw._dread(db->Claw._done(db,"SELECT status FROM claw_events WHERE id=?",(event.id,)).status,h)=="done")
            integration_until(()->isempty(lock(()->collect(h.live),h.lock)))
            @test occursin(secret,private_runtime_payloads(h))
            @test Claw._dread(db->Claw._scalar(db,"SELECT COUNT(*) FROM claw_event_dispatches"),h)==1
            Claw.scrub_durable_post!(h,"erase-child")
            @test !occursin(secret,private_runtime_payloads(h))
            @test Claw._dread(db->Claw._done(db,"SELECT status FROM claw_events WHERE id=?",(event.id,)).status,h)=="dead"
            @test all(s->s.reason=="redacted",Claw._dread(db->Claw._drows(db,"SELECT reason FROM claw_submissions"),h))
        finally Claw.shutdown!(a;timeout_s=10) end
    end
end
