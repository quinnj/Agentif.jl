using Test,JSON

@testset "fresh-process child, compaction, source and remote-send recovery" begin
    fixture=joinpath(@__DIR__,"durable_graph_crash_child.jl")
    project=dirname(dirname(@__DIR__))
    cases=[("child","after_child_creation","unsafe"),("child","after_tool_child_wait","unsafe"),
        ("summary","after_compaction_prepare","unsafe"),("summary","after_summary_result","unsafe"),
        ("source","after_source_intake","unsafe"),("source","after_source_claim","unsafe"),
        ("source","before_relevance_receipt","unsafe"),("source","after_relevance_receipt","unsafe"),
        ("source","before_dispatch","unsafe"),("source","after_dispatch","unsafe"),
        ("delivery","after_delivery_intent","unsafe"),("delivery","after_remote_send","unsafe"),
        ("delivery","after_remote_send","idempotent"),("delivery","after_delivery_receipt","unsafe")]
    for (scenario,cut,capability) in cases
        mktempdir() do dir
            path=joinpath(dir,"crash.sqlite");counter=joinpath(dir,"effects");marker=joinpath(dir,"cut");result=joinpath(dir,"result.json")
            log=joinpath(dir,"child.log");crashed=false
            open(log,"w") do io
                cmd=`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $fixture crash $path $scenario $cut $counter $marker $result $capability`
                process=Base.run(pipeline(cmd;stdout=io,stderr=io);wait=false)
                timedwait(()->isfile(marker)||process_exited(process),100;pollint=.05)
                if isfile(marker)
                    if scenario=="summary" && cut=="after_compaction_prepare"
                        @test !isfile(counter)
                    end
                    kill(process,Base.SIGKILL);wait(process);crashed=process.termsignal==9
                else
                    process_running(process) && kill(process,Base.SIGKILL)
                    wait(process);println(read(log,String))
                end
            end
            @test crashed
            crashed || return
            cmd=`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $fixture recover $path $scenario none $counter $marker $result $capability`
            open(log,"a") do io
                @test success(pipeline(cmd;stdout=io,stderr=io))
            end
            @test isfile(result)
            isfile(result) || (println(read(log,String));return)
            state=JSON.parsefile(result);effects=isfile(counter) ? length(readlines(counter)) : 0
            if scenario=="source"
                @test length(state["receipts"])==1 && only(state["receipts"])["state"]=="answered"
                @test length(state["dispatch"])==1
                @test only(state["events"])["durable"]==1
                @test effects==(cut=="before_relevance_receipt" ? 2 : 1)
                if cut in ("after_relevance_receipt","before_dispatch","after_dispatch")
                    @test JSON.parse(only(state["dispatch"])["handler_snapshot"])["prompt"]=="issued"
                end
            else
                @test state["receipt"]["state"]=="answered"
                if scenario=="child"
                    @test length(state["aliases"])==1 && length(state["children"])==1
                    @test count(t->t["kind"]=="child",state["tasks"])==1
                    @test all(t->t["status"]=="terminal",state["tasks"])
                    @test effects==1
                elseif scenario=="summary"
                    @test count(m->get(m,"type",nothing)=="compaction_summary",state["history"])==1
                    @test count(t->t["kind"]=="compaction",state["tasks"])==1
                    @test effects==1
                else
                    expected=cut in ("after_delivery_intent","after_remote_send") && capability=="unsafe" ? "uncertain" : "sent"
                    @test only(state["snapshot"]["deliveries"])["state"]==expected
                    @test effects==(cut=="after_delivery_intent" ? 0 : 1)
                end
            end
            println("SIGKILL ",scenario," ",cut," capability=",capability,": effects=",effects)
            flush(stdout)
        end
    end
end
