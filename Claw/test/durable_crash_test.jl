using Test, JSON

@testset "fresh-process SIGKILL recovery boundaries" begin
    fixture=joinpath(@__DIR__,"durable_crash_child.jl")
    project=dirname(dirname(@__DIR__))
    for cut in ("after_intake","after_request_intent","after_partial","after_tool_intent","after_effect_body","after_tool_result","after_answer")
        mktempdir() do dir
            path=joinpath(dir,"claw.sqlite");counter=joinpath(dir,"effects");marker=joinpath(dir,"cut");result=joinpath(dir,"result.json")
            log=joinpath(dir,"child.log")
            crashed=false
            open(log,"w") do io
                cmd=`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $fixture crash $path $cut $counter $marker $result unsafe`
                process=run(pipeline(cmd;stdout=io,stderr=io);wait=false)
                reached=timedwait(()->isfile(marker) || process_exited(process),90;pollint=.05)
                if reached===:ok && isfile(marker)
                    kill(process,Base.SIGKILL)
                    wait(process)
                    crashed=process.termsignal==9
                else
                    process_running(process) && kill(process,Base.SIGKILL)
                    wait(process)
                    println(read(log,String))
                end
            end
            @test crashed
            crashed || return
            cmd=`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $fixture recover $path none $counter $marker $result unsafe`
            open(log,"a") do io
                @test success(pipeline(cmd;stdout=io,stderr=io))
            end
            @test isfile(result)
            isfile(result) || (println(read(log,String));return)
            state=JSON.parsefile(result)
            receipt=state["receipt"]
            expected_barrier=cut in ("after_tool_intent","after_effect_body")
            @test receipt["state"]==(expected_barrier ? "placed" : "answered")
            invocations=isfile(counter) ? length(readlines(counter)) : 0
            @test invocations==(cut=="after_tool_intent" ? 0 : 1)
            @test count(m->get(m,"type",nothing)=="user",state["history"])==1
            if expected_barrier
                @test only(state["effects"])["effect_state"]=="uncertain"
            end
            if cut in ("after_request_intent","after_partial")
                @test state["snapshot"]["unknown_spend_attempts"]==1
            end
            println("SIGKILL ",cut,": receipt=",receipt["state"],", effects=",invocations)
        end
    end
end
