isdefined(@__MODULE__, :durable_fixture) || include("durable_fixtures.jl")

mode,path,cut,counter,marker,result_path,replay=ARGS
tool=Agentif.@tool "record a fixture invocation" mark()=begin
    open(counter,"a") do io
        println(io,"effect")
    end
    "marked"
end
function crash_stream(f,a,s,input,abort;kw...)
    if cut=="after_partial"
        msg=durable_message(a,"audit partial")
        f(Agentif.MessageUpdateEvent(:assistant,msg,:text_delta,"audit partial",nothing))
    end
    msg=if any(m->m isa Agentif.ToolResultMessage,s.messages)
        durable_message(a,"recovered answer")
    else
        durable_message(a,"";calls=[Agentif.AgentToolCall(;call_id="fixture-call",name="mark",arguments="{}")])
    end
    Agentif.append_state!(s,input,msg,Agentif.Usage(;input=2,output=1,total=3))
    s.most_recent_stop_reason=isempty(msg.tool_calls) ? :stop : :tool_calls
    s
end
function stop_at(point,h)
    String(point)==cut || return
    open(marker,"w") do io
        write(io,String(point))
    end
    while true
        sleep(.05)
    end
end
h,c,p=durable_fixture(path;stream=crash_stream,tools=Agentif.AgentTool[tool],
    specs=[Claw.ToolSpec(tool;version="fixture-v1",replay=Symbol(replay))],fault=mode=="crash" ? stop_at : (p,h)->nothing)
try
    r=Claw.submit!(h,c,"durable input";request_id="stable",origin=Dict("post_id"=>"fixture-post"))
    if mode=="recover"
        Claw.resume!(h)
        timedwait(()->begin
            s=Claw.snapshot(h,c)
            Claw.submission(r).state in ("answered","unanswered") || any(t->t.blocked!==nothing && occursin("uncertain effect",t.blocked),s.tasks)
        end,30;pollint=.02)
        s=Claw.snapshot(h,c)
        receipt=Claw.submission(r)
        effects=Claw._dread(db->Claw._drows(db,"SELECT * FROM claw_tool_executions"),h)
        known=Agentif.load_branch(h.history,"test").messages
        open(result_path,"w") do io
            write(io,JSON.json((;receipt,snapshot=s,effects,history=JSON.parse(JSON.json(known)))))
        end
    else
        Claw.wait_submission(r;timeout_s=60)
    end
finally
    Claw.close_harness!(h;grace_s=2)
end
