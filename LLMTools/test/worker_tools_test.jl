using Test
using LLMTools

function worker_funcs()
    tools = LLMTools.create_worker_tools()
    return Dict(tool.name => tool.func for tool in tools)
end

@testset "Worker Tools" begin
    funcs = worker_funcs()
    exec_code = funcs["exec_code"]
    eval_code = funcs["eval_code"]
    kill_worker = funcs["kill_worker"]
    list_workers = funcs["list_workers"]

    @testset "Structured exec_code response" begin
        LLMTools.reset_sessions_for_tests!(LLMTools.WORKER_REGISTRY)
        parsed = parse_tool_json(exec_code("1 + 1", nothing))
        @test parsed["schema_version"] == 1
        @test parsed["tool"] == "exec_code"
        @test parsed["ok"] == true
        @test parsed["status"] in [LLMTools.SESSION_STATUS_RUNNING, LLMTools.SESSION_STATUS_EXITED]
        @test haskey(parsed, "summary")
        @test haskey(parsed, "events")
        @test parsed["result"] == "2"

        # Clean up the worker if still running
        if parsed["session_id"] !== nothing
            kill_worker(parsed["session_id"])
        end
    end

    @testset "eval_code in existing worker" begin
        LLMTools.reset_sessions_for_tests!(LLMTools.WORKER_REGISTRY)
        # Start a worker
        started = parse_tool_json(exec_code("x = 42", nothing))
        @test started["ok"] == true
        worker_id = started["session_id"]
        @test worker_id !== nothing

        # Eval more code in the same worker — state persists
        evaled = parse_tool_json(eval_code(worker_id, "x + 8", nothing))
        @test evaled["ok"] == true
        @test evaled["result"] == "50"

        # Clean up
        kill_worker(worker_id)
    end

    @testset "Multi-line code execution" begin
        LLMTools.reset_sessions_for_tests!(LLMTools.WORKER_REGISTRY)
        code = """
        a = 10
        b = 20
        a + b
        """
        parsed = parse_tool_json(exec_code(code, nothing))
        @test parsed["ok"] == true
        @test parsed["result"] == "30"

        if parsed["session_id"] !== nothing
            kill_worker(parsed["session_id"])
        end
    end

    @testset "kill_worker" begin
        LLMTools.reset_sessions_for_tests!(LLMTools.WORKER_REGISTRY)
        started = parse_tool_json(exec_code("1", nothing))
        worker_id = started["session_id"]
        @test worker_id !== nothing

        killed = parse_tool_json(kill_worker(worker_id))
        @test killed["ok"] == true
        @test killed["status"] == LLMTools.SESSION_STATUS_KILLED

        # Kill again should fail gracefully
        missing_kill = parse_tool_json(kill_worker(worker_id))
        @test missing_kill["ok"] == false
        @test missing_kill["error_kind"] == "session_not_found"
    end

    @testset "Missing worker eval" begin
        LLMTools.reset_sessions_for_tests!(LLMTools.WORKER_REGISTRY)
        missing = parse_tool_json(eval_code(9999, "1 + 1", nothing))
        @test missing["ok"] == false
        @test missing["error_kind"] == "session_not_found"
        @test missing["status"] == LLMTools.SESSION_STATUS_UNKNOWN
    end

    @testset "list_workers" begin
        LLMTools.reset_sessions_for_tests!(LLMTools.WORKER_REGISTRY)

        # Empty list
        listed = parse_tool_json(list_workers())
        @test listed["tool"] == "list_workers"
        @test listed["ok"] == true
        @test listed["active_workers"] == 0

        # Start a worker and list again
        started = parse_tool_json(exec_code("1", nothing))
        worker_id = started["session_id"]
        @test worker_id !== nothing

        listed = parse_tool_json(list_workers())
        @test listed["active_workers"] >= 1
        first_worker = listed["workers"][1]
        @test haskey(first_worker, "worker_id")
        @test haskey(first_worker, "status")
        @test haskey(first_worker, "description")
        @test haskey(first_worker, "age_s")

        # Clean up
        kill_worker(worker_id)
    end

    @testset "stdout capture" begin
        LLMTools.reset_sessions_for_tests!(LLMTools.WORKER_REGISTRY)
        parsed = parse_tool_json(exec_code("println(\"hello from worker\")", nothing))
        @test parsed["ok"] == true
        @test occursin("hello from worker", parsed["output"])

        if parsed["session_id"] !== nothing
            kill_worker(parsed["session_id"])
        end
    end

    # Final cleanup
    LLMTools.reset_sessions_for_tests!(LLMTools.WORKER_REGISTRY)
end
