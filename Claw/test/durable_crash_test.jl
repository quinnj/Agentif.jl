using Test, JSON

@testset "fresh-process SIGKILL recovery boundaries" begin
    fixture = joinpath(@__DIR__, "durable_crash_child.jl")
    project = dirname(dirname(@__DIR__))
    for (cut, replay) in (
            ("before_intake", "unsafe"), ("after_intake", "unsafe"), ("after_request_intent", "unsafe"),
            ("after_partial", "unsafe"), ("before_model_result", "unsafe"), ("after_tool_intent", "unsafe"),
            ("after_effect_body", "unsafe"), ("after_tool_result", "unsafe"), ("before_answer", "unsafe"), ("after_answer", "unsafe"),
            ("after_effect_body", "safe"),
        )
        mktempdir() do dir
            path = joinpath(dir, "claw.sqlite");counter = joinpath(dir, "effects");marker = joinpath(dir, "cut");result = joinpath(dir, "result.json")
            log = joinpath(dir, "child.log")
            crashed = false
            open(log, "w") do io
                cmd = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $fixture crash $path $cut $counter $marker $result $replay`
                process = Base.run(pipeline(cmd; stdout = io, stderr = io); wait = false)
                reached = timedwait(() -> isfile(marker) || process_exited(process), 90; pollint = 0.05)
                if reached === :ok && isfile(marker)
                    kill(process, Base.SIGKILL)
                    wait(process)
                    crashed = process.termsignal == 9
                else
                    process_running(process) && kill(process, Base.SIGKILL)
                    wait(process)
                    println(read(log, String))
                end
            end
            @test crashed
            crashed || return
            cmd = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $fixture recover $path none $counter $marker $result $replay`
            open(log, "a") do io
                @test success(pipeline(cmd; stdout = io, stderr = io))
            end
            @test isfile(result)
            isfile(result) || (println(read(log, String)); return)
            state = JSON.parsefile(result)
            receipt = state["receipt"]
            expected_barrier = replay == "unsafe" && cut in ("after_tool_intent", "after_effect_body")
            @test receipt["state"] == (expected_barrier ? "placed" : "answered")
            invocations = isfile(counter) ? length(readlines(counter)) : 0
            @test invocations == (cut == "after_tool_intent" ? 0 : replay == "safe" ? 2 : 1)
            @test count(m -> get(m, "type", nothing) == "user", state["history"]) == 1
            if expected_barrier
                @test only(state["effects"])["effect_state"] == "uncertain"
            end
            if cut in ("after_request_intent", "after_partial")
                @test state["snapshot"]["unknown_spend_attempts"] == 1
            end
            println("SIGKILL ", cut, " replay=", replay, ": receipt=", receipt["state"], ", effects=", invocations)
            flush(stdout)
        end
    end
end
