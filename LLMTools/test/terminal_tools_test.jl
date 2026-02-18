using Test
using JSON
using LLMTools

function parse_tool_json(raw::String)
    return JSON.parse(raw)
end

function terminal_funcs(base_dir::AbstractString)
    tools = LLMTools.create_terminal_tools(base_dir)
    return Dict(tool.name => tool.func for tool in tools)
end

function wait_until(timeout_s::Real, predicate::Function)
    deadline = time() + timeout_s
    while time() < deadline
        predicate() && return true
        sleep(0.05)
    end
    return predicate()
end

@testset "Terminal Tools" begin
    mktempdir() do tmpdir
        funcs = terminal_funcs(tmpdir)
        exec_command = funcs["exec_command"]
        write_stdin = funcs["write_stdin"]
        kill_session = funcs["kill_session"]
        list_sessions = funcs["list_sessions"]

        @testset "Structured exec response" begin
            LLMTools.reset_sessions_for_tests!(LLMTools.PTY_REGISTRY)
            parsed = parse_tool_json(exec_command("echo hello", nothing, nothing, 250, 1000, 10000))
            @test parsed["schema_version"] == 1
            @test parsed["tool"] == "exec_command"
            @test parsed["ok"] == true
            @test parsed["status"] in [LLMTools.SESSION_STATUS_EXITED, LLMTools.SESSION_STATUS_RUNNING]
            @test haskey(parsed, "summary")
            @test haskey(parsed, "events")
            @test occursin("hello", parsed["output"])

            event_kinds = Set(evt["kind"] for evt in parsed["events"])
            @test "begin" in event_kinds
        end

        @testset "Session interaction and events" begin
            LLMTools.reset_sessions_for_tests!(LLMTools.PTY_REGISTRY)
            if Sys.iswindows()
                @test_skip "Interactive PTY test currently unix-only"
            else
                started = parse_tool_json(exec_command("cat", nothing, nothing, 150, 1000, 10000))
                @test started["status"] == LLMTools.SESSION_STATUS_RUNNING
                session_id = started["session_id"]
                @test session_id isa Integer

                echoed = parse_tool_json(write_stdin(session_id, "ping\n", 200, 1000, 10000))
                @test echoed["ok"] == true
                @test echoed["status"] in [LLMTools.SESSION_STATUS_RUNNING, LLMTools.SESSION_STATUS_EXITED]
                @test occursin("ping", echoed["output"])
                kinds = Set(evt["kind"] for evt in echoed["events"])
                @test "stdin" in kinds
                @test "output_delta" in kinds

                kill_resp = parse_tool_json(kill_session(session_id))
                @test kill_resp["status"] in [LLMTools.SESSION_STATUS_KILLED, LLMTools.SESSION_STATUS_UNKNOWN]
            end
        end

        @testset "Race-safe missing-session write" begin
            LLMTools.reset_sessions_for_tests!(LLMTools.PTY_REGISTRY)
            if Sys.iswindows()
                @test_skip "Interactive PTY test currently unix-only"
            else
                started = parse_tool_json(exec_command("cat", nothing, nothing, 100, 1000, 10000))
                @test started["status"] == LLMTools.SESSION_STATUS_RUNNING
                session_id = started["session_id"]
                _ = parse_tool_json(kill_session(session_id))

                missing = parse_tool_json(write_stdin(session_id, "hello\n", 100, 1000, 10000))
                @test missing["ok"] == false
                @test missing["error_kind"] == "session_not_found"
                @test missing["status"] == LLMTools.SESSION_STATUS_UNKNOWN
            end
        end

        @testset "Deterministic cleanup sweeper" begin
            LLMTools.reset_sessions_for_tests!(LLMTools.PTY_REGISTRY)
            cmd = Sys.iswindows() ? "Start-Sleep -Seconds 1" : "sleep 1"
            started = parse_tool_json(exec_command(cmd, nothing, nothing, 100, 1000, 10000))
            @test started["status"] == LLMTools.SESSION_STATUS_RUNNING
            session_id = started["session_id"]

            removed = wait_until(5.0, () -> !haskey(LLMTools.PTY_REGISTRY.sessions, session_id))
            @test removed == true
        end

        @testset "Token-aware truncation and output metadata" begin
            LLMTools.reset_sessions_for_tests!(LLMTools.PTY_REGISTRY)
            cmd = if Sys.iswindows()
                "1..200 | ForEach-Object { Write-Output ('x' * 120) }"
            else
                "for i in {1..200}; do echo 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; done"
            end
            parsed = parse_tool_json(exec_command(cmd, nothing, nothing, 300, 40, 80))
            @test parsed["ok"] == true
            @test parsed["truncated"] == true
            @test parsed["token_truncated"] == true
            @test parsed["original_token_count_est"] >= parsed["output_token_count_est"]
            @test parsed["original_line_count"] >= parsed["output_line_count"]
        end

        @testset "list_sessions structured schema" begin
            LLMTools.reset_sessions_for_tests!(LLMTools.PTY_REGISTRY)
            if Sys.iswindows()
                _ = parse_tool_json(exec_command("Start-Sleep -Seconds 2", nothing, nothing, 100, 1000, 10000))
            else
                _ = parse_tool_json(exec_command("sleep 2", nothing, nothing, 100, 1000, 10000))
            end

            listed = parse_tool_json(list_sessions())
            @test listed["tool"] == "list_sessions"
            @test listed["status"] == LLMTools.SESSION_STATUS_OK
            @test haskey(listed, "sessions")
            @test listed["active_sessions"] >= 1
            first_session = listed["sessions"][1]
            @test haskey(first_session, "session_id")
            @test haskey(first_session, "status")
            @test haskey(first_session, "command")
            @test haskey(first_session, "workdir")
            @test haskey(first_session, "age_s")

            LLMTools.reset_sessions_for_tests!(LLMTools.PTY_REGISTRY)
        end
    end
end
