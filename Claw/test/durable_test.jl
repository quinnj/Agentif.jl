isdefined(@__MODULE__, :durable_fixture) || include("durable_fixtures.jl")

@testset "durable admission, answer, atomic history and usage" begin
    mktempdir() do dir
        path=joinpath(dir,"claw.sqlite")
        h,c,p=durable_fixture(path)
        try
            r=Claw.submit!(h,c,"hello";request_id="one",origin=Dict("post_id"=>"post"))
            @test Claw.wait_submission(r;timeout_s=20).state=="answered"
            @test Claw.submit!(h,c,"hello";request_id="one",origin=Dict("post_id"=>"post")).id==r.id
            @test_throws Claw.SubmissionConflict Claw.submit!(h,c,"changed";request_id="one",origin=Dict("post_id"=>"post"))
            @test_throws Claw.SubmissionConflict Claw.submit!(h,c,"hello";request_id="one",mode=:steer,origin=Dict("post_id"=>"post"))
            s=Claw.snapshot(h,c)
            @test length(s.usage)==1
            @test JSON.parse(s.usage[1].usage)["total"]==5
            history=Agentif.load_branch(h.history,"test").messages
            @test Agentif.message_text.(history)==["hello","answer"]
            @test_throws Exception Claw.open_harness(path)
            w=Claw.watch(h,c.id;capacity=1)
            @test Claw.next_frame!(w).reset
            Claw.ensure_conversation!(h;branch_id="other",profile=p)
            Claw.ensure_conversation!(h;branch_id="third",profile=p)
            @test Claw.next_frame!(w).reset
            close(w)
        finally
            @test Claw.close_harness!(h;grace_s=10).status==:closed
        end
        h,c,p=durable_fixture(path)
        try
            @test Claw.lookup_submission(h,c.id,"one")!==nothing
            @test length(Agentif.load_branch(h.history,"test").messages)==2
            r=Claw.submit!(h,c,"hello";request_id="one",origin=Dict("post_id"=>"post"))
            @test Claw.submission(r).state=="answered"
        finally
            Claw.close_harness!(h;grace_s=10)
        end
    end
end

@testset "one-turn failure precedence and copied progress" begin
    agent=Agentif.Agent(;model=durable_model(),prompt="p",apikey="key")
    seen=Agentif.AgentEvent[]
    function failure_stream(f,a,s,input,abort;kw...)
        msg=durable_message(a,"partial";calls=[Agentif.AgentToolCall(;call_id="c",name="x",arguments="{}")])
        f(Agentif.MessageUpdateEvent(:assistant,msg,:text_delta,"partial",nothing))
        msg.content[1].text *= " changed"
        Agentif.append_state!(s,input,msg,Agentif.Usage())
        s.most_recent_stop_reason=:tool_calls
        f(Agentif.AgentErrorEvent(ErrorException("provider overloaded")))
        s
    end
    outcome=Agentif.model_turn(e->push!(seen,e),agent,Agentif.AgentState();stream_fn=failure_stream)
    @test outcome.stop_reason==:error
    @test isempty(Agentif.eligible_tool_calls(outcome))
    @test Agentif.message_text(seen[1].message)=="partial"
    @test isempty(Agentif.AgentState().messages)
end

@testset "tool receipts, parse gating and ordered context" begin
    for invalid in (false,true)
        mktempdir() do dir
            count=Ref(0)
            tool=Agentif.@tool "increment" increment(n::Int)=begin count[]+=1;"done" end
            function tool_stream(f,a,s,input,abort;kw...)
                message=if any(m->m isa Agentif.ToolResultMessage,s.messages)
                    durable_message(a,"finished")
                else
                    durable_message(a,"";calls=[Agentif.AgentToolCall(;call_id="call",name="increment",arguments=invalid ? "{\"n\":\"bad\"}" : "{\"n\":1}")])
                end
                Agentif.append_state!(s,input,message,Agentif.Usage(;total=1))
                s.most_recent_stop_reason=isempty(message.tool_calls) ? :stop : :tool_calls
                s
            end
            h,c,p=durable_fixture(joinpath(dir,"claw.sqlite");stream=tool_stream,tools=Agentif.AgentTool[tool])
            try
                r=Claw.submit!(h,c,"work";request_id="tool")
                @test Claw.wait_submission(r;timeout_s=20).state=="answered"
                @test count[]==(invalid ? 0 : 1)
                messages=Agentif.load_branch(h.history,"test").messages
                @test length(messages)==4
                @test messages[3] isa Agentif.ToolResultMessage
                @test messages[3].is_error==invalid
                @test Claw.submit!(h,c,"work";request_id="tool").id==r.id
                @test count[]==(invalid ? 0 : 1)
            finally
                Claw.close_harness!(h;grace_s=10)
            end
        end
    end
end

@testset "waiting, suspension, compatibility and privacy" begin
    mktempdir() do dir
        started=Threads.Event()
        function slow_stream(f,a,s,input,abort;kw...)
            notify(started)
            sleep(.25)
            durable_stream(f,a,s,input,abort;kw...)
        end
        path=joinpath(dir,"claw.sqlite")
        h,c,p=durable_fixture(path;stream=slow_stream)
        r=Claw.submit!(h,c,"private";request_id="private",origin=Dict("post_id"=>"delete-me"))
        @test Claw.wait_submission(r;timeout_s=0)===nothing
        @test Claw.submission(r).state in ("queued","placed")
        wait(started)
        @test Claw.close_harness!(h;grace_s=.01).status==:draining
        @test_throws Exception Claw.open_harness(path)
        sleep(.3)
        @test Claw.close_harness!(h;grace_s=10).status==:closed
        h,c,p=durable_fixture(path)
        try
            r=Claw.lookup_submission(h,c.id,"private")
            @test Claw.wait_submission(r;timeout_s=20).state=="answered"
            @test Claw.snapshot(h,c).unknown_spend_attempts==1
            fork=Claw.fork_conversation!(h,c.id;branch_id="fork")
            @test isempty(Claw.snapshot(h,fork).submissions)
            Claw.scrub_durable_post!(h,"delete-me")
            @test !occursin("private",JSON.json(Agentif.load_branch(h.history,"test").messages))
            @test !occursin("private",JSON.json(Agentif.load_branch(h.history,"fork").messages))
            @test Claw.submission(r).input_json==JSON.json(Agentif.UserMessage("[redacted]"))
        finally
            Claw.close_harness!(h;grace_s=10)
        end
    end
end
