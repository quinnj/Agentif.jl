isdefined(@__MODULE__, :attached_fixture) || include("durable_integration_fixtures.jl")

@testset "multi-handler receipts, durable classifiers and source dedup" begin
    mktempdir() do dir
        requests=String[];guard=ReentrantLock()
        stream=(f,a,s,input,abort;kw...)->begin
            text=Agentif.message_text(last(s.messages))
            if a.prompt==Claw.EVENT_FILTER_PROMPT
                lock(guard) do;push!(requests,"classifier");end
                msg=durable_message(a,"{\"match\":true}")
            else
                label=occursin("handler-B",text) ? "B" : "A"
                lock(guard) do;push!(requests,label);end
                if label=="B"
                    f(Agentif.AgentErrorEvent(ErrorException("permanent provider rejection")))
                    s.most_recent_stop_reason=:error
                    return s
                end
                msg=durable_message(a,"handler A answer")
            end
            Agentif.append_state!(s,input,msg,Agentif.Usage(;total=1));s.most_recent_stop_reason=:stop;s
        end
        a,h=attached_fixture(joinpath(dir,"claw.sqlite");stream)
        old=Claw.CURRENT_ASSISTANT[];Claw.CURRENT_ASSISTANT[]=a
        try
            a._state[]=:running
            Claw.register_event_handler!(a,Claw.EventHandler("A",["durable-event"],"handler-A";
                filter=Claw.EventFilter(:prompt,"operator criteria")))
            Claw.register_event_handler!(a,Claw.EventHandler("B",["durable-event"],"handler-B"))
            channel=DurableChannel("integration";post="input-post")
            event=DurableEvent(channel,"source body")
            id=Claw.submit_event!(a,event;dedup_key="source-delivery-1")
            @test Claw.submit_event!(a,event;dedup_key="source-delivery-1")===nothing
            Claw._process_event!(a,id)
            integration_until(()->Claw.with_read(db->Claw._done(db,"SELECT status FROM claw_events WHERE id=?",(id,)).status,a._readers)=="dead")
            @test lock(()->copy(requests),guard)==["classifier","A","B"]
            receipts=Claw._dread(db->Claw._drows(db,"SELECT d.handler_id,s.state FROM claw_event_dispatches d JOIN claw_submissions s ON s.id=d.submission_id ORDER BY d.handler_id"),h)
            @test [r.state for r in receipts]==["answered","unanswered"]
            @test count(u->u.category=="filter",Claw._dread(db->Claw._drows(db,"SELECT category FROM claw_usage"),h))==1
            Claw._process_event!(a,id)
            @test lock(()->copy(requests),guard)==["classifier","A","B"]
            integration_until(()->length(channel.responses)==1)
            @test channel.responses==["handler A answer"]
            @test channel.closed
        finally
            Claw.shutdown!(a;timeout_s=10);Claw.CURRENT_ASSISTANT[]=old
        end
    end
end

@testset "direct receipts retain input date, thread cutoffs and privacy" begin
    mktempdir() do dir
        a,h=attached_fixture(joinpath(dir,"claw.sqlite"))
        try
            parent=DurableChannel("root";post="incoming-1")
            first=Claw.evaluate(a,"first";channel=parent,input_key="fixed")
            @test first.most_recent_stop_reason==:stop
            Claw.evaluate(a,"first";channel=parent,input_key="fixed")
            root=Claw._dread(db->Claw._done(db,"SELECT id FROM claw_conversations WHERE branch_id='root'"),h)
            @test length(Claw.snapshot(h,root.id).submissions)==1
            @test_throws Claw.SubmissionConflict Claw.evaluate(a,"different";channel=parent,input_key="fixed")
            integration_until(()->length(parent.responses)==1)
            thread=DurableChannel("thread";parent="root",cutoff="response:incoming-1",post="thread-post")
            Claw.evaluate(a,"thread question";channel=thread,input_key="thread")
            history=Agentif.load_branch(h.history,"thread").messages
            @test occursin("first",Agentif.message_text(history[1]))
            @test Agentif.message_text(history[2])=="answer"
            @test occursin("thread question",Agentif.message_text(history[3]))
            public_thread=DurableChannel("public-thread";parent="root",private=false)
            @test_throws ArgumentError Claw.evaluate(a,"public";channel=public_thread,input_key="public")
            Claw.scrub_durable_post!(h,"thread-post")
            @test occursin("first",JSON.json(Agentif.load_branch(h.history,"root").messages))
            @test !occursin("thread question",JSON.json(Agentif.load_branch(h.history,"thread").messages))
        finally Claw.shutdown!(a;timeout_s=10) end
    end
end

@testset "embedding work cannot delay admission; redaction wins indexing race" begin
    mktempdir() do dir
        entered=Base.Channel{Nothing}(1);release=Base.Channel{Nothing}(1)
        embed=texts->begin
            if texts!=["test"]
                isready(entered) || put!(entered,nothing)
                take!(release)
            end
            zeros(Float32,2,length(texts))
        end
        a,h=attached_fixture(joinpath(dir,"claw.sqlite");embed)
        try
            profile=Claw.register_profile!(h,Agentif.Agent(;model=durable_model(),apikey="key",prompt="test"))
            c=Claw.ensure_conversation!(h;branch_id="indexed",profile)
            r=Claw.submit!(h,c,"erase this exact content";request_id="indexed",origin=Dict("post_id"=>"erase"))
            integration_until(()->isready(entered))
            start=time()
            second=Claw.submit!(h,c,"following input";request_id="following")
            @test time()-start<2
            @test Claw.submission(second)!==nothing
            Claw.scrub_durable_post!(h,"erase")
            put!(release,nothing)
            integration_until(()->h.indexer===nothing || istaskdone(h.indexer))
            @test !occursin("erase this exact content",JSON.json(Agentif.load_branch(h.history,"indexed").messages))
            @test Claw.submission(r).input_json==JSON.json(Agentif.UserMessage("[redacted]"))
            indexed=Claw._dread(db->Claw._drows(db,"SELECT c.body FROM documents d JOIN content c ON c.hash=d.hash WHERE d.key LIKE 'session:entry:%'"),h)
            @test all(r->!occursin("erase this exact content",r.body),indexed)
        finally
            for _ in 1:10;isready(release) || put!(release,nothing);sleep(.01);end
            Claw.shutdown!(a;timeout_s=10)
        end
    end
end
