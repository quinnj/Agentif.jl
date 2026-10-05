include("durable_source_fixtures.jl")
mode,path,scenario,cut,counter,marker,result_path,capability=ARGS
function graph_cut(point,h)
    mode=="crash" && String(point)==cut || return
    write(marker,String(point))
    while true;sleep(.05);end
end
function graph_counter(label)
    open(counter,"a") do io;println(io,label);end
end

if scenario=="source"
    a,h=attached_fixture(path;jev=durable_jev())
    durable_source_rehydrate!(a)
    Claw._register_default_profile!(h,a)
    h.fault=graph_cut
    Claw.JEV_REQUEST_FN[]=(cfg,request)->begin graph_counter("classifier");durable_relevance_response(request) end
    try
        handler=Claw.EventHandler("source",["durable-relevance"],mode=="crash" ? "issued" : "changed";
            relevance=mode=="crash" ? durable_policy() : Claw.EventRelevancePolicy("changed","changed"),tools=String[],trust=:untrusted)
        Claw.register_event_handler!(a,handler)
        if mode=="crash"
            event=DurableRelevanceEvent(DurableChannel("source";post="source-post"),"source input")
            id=Claw.submit_event!(a,event;dedup_key="stable-source")
            graph_cut(:after_source_intake,h)
            row=Claw._claim_event!(a,id)
            graph_cut(:after_source_claim,h)
            Claw._durable_dispatch_group!(a,[(row,event)],[handler])
            sleep(60)
        else
            Claw._reclaim_crashed_events!(a;durable_upgrade=true)
            row=Claw._dread(db->Claw._done(db,"SELECT id,status FROM claw_events"),h)
            if row.status=="pending"
                claim=Claw._claim_event!(a,row.id)
                Claw._durable_dispatch_group!(a,[(claim,Claw.rehydrate_event(claim.source,claim))],[handler])
            end
            Claw.resume!(h)
            timedwait(()->Claw._dread(db->Claw._scalar(db,"SELECT COUNT(*) FROM claw_submissions WHERE state='answered'"),h)==1,30;pollint=.02)
            receipts=Claw._dread(db->Claw._drows(db,"SELECT * FROM claw_submissions"),h)
            dispatch=Claw._dread(db->Claw._drows(db,"SELECT * FROM claw_event_dispatches"),h)
            events=Claw._dread(db->Claw._drows(db,"SELECT id,status,durable FROM claw_events"),h)
            write(result_path,JSON.json((;receipts,dispatch,events)))
        end
    finally Claw.shutdown!(a;timeout_s=10) end
else
    tools=Agentif.AgentTool[]
    if scenario=="child"
        cfg=Claw.AgentConfig(;provider="test",model_id="durable-test",apikey="key",base_dir=dirname(path))
        tools=Claw._create_subagent_tools(Claw.LLMToolsEventSource(cfg))
    end
    stream=(f,a,s,input,abort;kw...)->begin
        msg=if a.prompt==Agentif.COMPACTION_SUMMARY_PROMPT
            # The scheduler may discover the committed child before the parent's
            # post-prepare fault callback runs. Hold this synthetic provider at
            # the request boundary until SIGKILL so this cut precedes any summary.
            if mode=="crash" && cut=="after_compaction_prepare"
                while true;sleep(.05);end
            end
            graph_counter("summary");durable_message(a,"committed summary")
        elseif a.prompt=="child"
            graph_counter("child");durable_message(a,"child answer")
        elseif scenario=="child" && !any(m->m isa Agentif.ToolResultMessage,s.messages)
            args=JSON.json(Dict("name"=>"worker","system_prompt"=>"child","input_message"=>"child input","run_sync"=>true))
            durable_message(a,"";calls=[Agentif.AgentToolCall(;call_id="child-call",name="start_subagent",arguments=args)])
        else
            durable_message(a,"final answer")
        end
        Agentif.append_state!(s,input,msg,Agentif.Usage(;total=1));s.most_recent_stop_reason=isempty(msg.tool_calls) ? :stop : :tool_calls;s
    end
    h,c,p=durable_fixture(path;stream,tools,compact=scenario=="summary",window=scenario=="summary" ? 2000 : 100000,
        limits=Claw.HarnessLimits(;models=1,tools=1),fault=graph_cut)
    try
        if scenario=="summary" && Agentif.get_branch_leaf(h.history,"test")===nothing
            Claw._transition!(h;point=:fixture_history) do db,seq
                row=Claw._done(db,"SELECT * FROM claw_conversations WHERE id=?",(c.id,))
                Claw._entry!(db,h,seq,row,[Agentif.UserMessage(repeat("old ",1000)),durable_message(h.agents[p.id],repeat("response ",100))])
            end
        elseif scenario=="delivery"
            adapter=Claw.DeliveryAdapter((address,body,key)->begin
                existing=isfile(counter) ? readlines(counter) : String[]
                Symbol(capability)==:idempotent && key in existing || graph_counter(key)
                Dict("remote"=>key)
            end;capability=Symbol(capability))
            Claw.register_delivery_adapter!(h,"graph",adapter)
            global c=Claw.ensure_conversation!(h;branch_id="test",profile=p,delivery=Claw.DeliveryAddress("graph",1,Dict("destination"=>"original")))
        end
        r=Claw.submit!(h,c,"input";request_id="stable")
        if mode=="recover"
            Claw.wait_submission(r;timeout_s=30)
            timedwait(()->begin
                snapshot=Claw.snapshot(h,c)
                scenario!="delivery" ? all(t->t.status=="terminal",snapshot.tasks) :
                    !isempty(snapshot.deliveries) && only(snapshot.deliveries).state in ("sent","uncertain")
            end,30;pollint=.02)
            aliases=Claw._dread(db->Claw._drows(db,"SELECT * FROM claw_child_aliases"),h)
            tasks=Claw._dread(db->Claw._drows(db,"SELECT id,kind,status FROM claw_tasks"),h)
            children=Claw._dread(db->Claw._drows(db,"SELECT id,request_id,state FROM claw_submissions WHERE conversation_id!=?",(c.id,)),h)
            write(result_path,JSON.json((;receipt=Claw.submission(r),snapshot=Claw.snapshot(h,c),aliases,tasks,children,
                history=JSON.parse(JSON.json(Agentif.load_branch(h.history,"test").messages)))))
        else
            Claw.wait_submission(r;timeout_s=60);sleep(60)
        end
    finally Claw.close_harness!(h;grace_s=2) end
end
