using Test
using LLMTools

function with_mock_codex(f::Function, json_lines::Vector{String})
    mktempdir() do tmpdir
        bindir = joinpath(tmpdir, "bin")
        mkpath(bindir)
        script_path = joinpath(bindir, "codex")
        open(script_path, "w") do io
            write(io, "#!/usr/bin/env bash\n")
            write(io, "cat <<'JSON'\n")
            for line in json_lines
                write(io, line)
                write(io, '\n')
            end
            write(io, "JSON\n")
        end
        chmod(script_path, 0o755)

        old_path = get(ENV, "PATH", "")
        old_exec = get(ENV, "LLMTOOLS_CODEX_EXECUTABLE", nothing)
        ENV["PATH"] = bindir * ":" * old_path
        ENV["LLMTOOLS_CODEX_EXECUTABLE"] = script_path
        try
            return f()
        finally
            ENV["PATH"] = old_path
            if old_exec === nothing
                delete!(ENV, "LLMTOOLS_CODEX_EXECUTABLE")
            else
                ENV["LLMTOOLS_CODEX_EXECUTABLE"] = old_exec
            end
        end
    end
end

@testset "Codex tool" begin
    tool = LLMTools.create_codex_tool()

    @testset "extracts session, summary, and branch" begin
        lines = [
            "{\"type\":\"thread.started\",\"thread_id\":\"thread-123\"}",
            "{\"type\":\"item.completed\",\"item\":{\"type\":\"command_execution\",\"command\":\"git worktree add -b feature/test-branch /worktrees/feature/test-branch main\",\"aggregated_output\":\"worktree created\",\"exit_code\":0}}",
            "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Implemented requested changes\"}}",
        ]
        with_mock_codex(lines) do
            mktempdir() do repo_dir
                result = tool.func("apply requested updates", repo_dir, nothing)
                @test result["session_id"] == "thread-123"
                @test result["branch"] == "feature/test-branch"
                @test result["success"] == true
                @test occursin("Implemented requested changes", result["summary"])
            end
        end
    end

    @testset "reports command failures" begin
        lines = [
            "{\"type\":\"thread.started\",\"thread_id\":\"thread-456\"}",
            "{\"type\":\"item.completed\",\"item\":{\"type\":\"command_execution\",\"command\":\"git worktree add -b fix/failing-branch /worktrees/fix/failing-branch main\",\"aggregated_output\":\"fatal: worktree add failed\",\"exit_code\":1}}",
        ]
        with_mock_codex(lines) do
            mktempdir() do repo_dir
                result = tool.func("run failing command", repo_dir, nothing)
                @test result["session_id"] == "thread-456"
                @test result["branch"] == "fix/failing-branch"
                @test result["success"] == false
                @test haskey(result, "errors")
                @test any(err -> occursin("Exit code: 1", err), result["errors"])
            end
        end
    end

    @testset "enforces explicit timeout argument" begin
        mktempdir() do tmpdir
            bindir = joinpath(tmpdir, "bin")
            mkpath(bindir)
            script_path = joinpath(bindir, "codex")
            open(script_path, "w") do io
                write(io, "#!/usr/bin/env bash\n")
                write(io, "sleep 2\n")
                write(io, "echo '{\"type\":\"thread.started\",\"thread_id\":\"thread-timeout\"}'\n")
            end
            chmod(script_path, 0o755)

            old_exec = get(ENV, "LLMTOOLS_CODEX_EXECUTABLE", nothing)
            ENV["LLMTOOLS_CODEX_EXECUTABLE"] = script_path
            try
                mktempdir() do repo_dir
                    @test_throws Exception tool.func("run for a while", repo_dir, 1)
                end
            finally
                if old_exec === nothing
                    delete!(ENV, "LLMTOOLS_CODEX_EXECUTABLE")
                else
                    ENV["LLMTOOLS_CODEX_EXECUTABLE"] = old_exec
                end
            end
        end
    end
end
