using Test
using JSON
using Juco
using Agentif

@testset "Juco" begin

@testset "db: memories and sessions" begin
    mktempdir() do dir
        jdb = Juco.opendb(joinpath(dir, "test.sqlite"))
        @test isempty(Juco.memories(jdb))
        Juco.remember!(jdb, "first fact")
        Juco.remember!(jdb, "second fact")
        @test Juco.memories(jdb) == ["first fact", "second fact"]
        @test Juco.memories(jdb; limit = 1) == ["second fact"]

        @test Juco.latest_session(jdb) === nothing
        Juco.touch_session!(jdb, "s1"; title = "hello", cwd = "/tmp/a")
        sleep(0.01)
        Juco.touch_session!(jdb, "s2"; title = "world", cwd = "/tmp/b")
        sessions = Juco.list_sessions(jdb)
        @test length(sessions) == 2
        @test sessions[1].id == "s2"
        @test Juco.latest_session(jdb) == "s2"
        # touching an existing session keeps its title, bumps updated_at
        sleep(0.01)
        Juco.touch_session!(jdb, "s1"; title = "changed")
        @test Juco.latest_session(jdb) == "s1"
        @test [s.title for s in Juco.list_sessions(jdb) if s.id == "s1"] == ["hello"]
    end
end

@testset "bash tool" begin
    mktempdir() do dir
        bash = Juco.create_bash_tool(dir)
        @test bash.name == "bash"
        @test strip(bash.func("echo hello", nothing)) == "hello"
        # combined stdout/stderr
        @test occursin("to-stderr", bash.func("echo to-stderr 1>&2", nothing))
        # nonzero exit code is reported
        @test occursin("[exit code 3]", bash.func("exit 3", nothing))
        # runs in base_dir
        @test strip(bash.func("pwd", nothing)) == realpath(dir)
        # timeout kills the command
        result = bash.func("sleep 5", 1)
        @test occursin("timed out after 1s", result)
        # orphaned background child holding the pipe open must not hang the tool
        t0 = time()
        result = bash.func("echo started; sleep 30 & disown", nothing)
        @test time() - t0 < 10
        @test occursin("started", result)
        # a single giant line is capped instead of eating the whole byte budget
        result = bash.func("printf 'x%.0s' {1..60000}; echo; echo done", nothing)
        @test occursin("[line truncated]", result)
        @test occursin("done", result)
        @test length(result) < 5000
        # tail truncation keeps the END of output
        result = bash.func("seq 1 3000", nothing)
        @test occursin("[Output truncated: showing last 2000 of 3001 lines]", result)
        @test occursin("3000", result)
        @test !occursin("\n500\n", result)
    end
end

@testset "edit tool" begin
    mktempdir() do dir
        edit = Juco.create_edit_tool(dir)
        @test edit.name == "edit"
        # create via empty oldText
        @test occursin("Created", edit.func("sub/new.txt", "", "line a\nline b\n"))
        @test read(joinpath(dir, "sub", "new.txt"), String) == "line a\nline b\n"
        # creating an existing file errors
        @test_throws ArgumentError edit.func("sub/new.txt", "", "other")
        # unique replace returns the edited region for verification
        result = edit.func("sub/new.txt", "line a", "line A")
        @test read(joinpath(dir, "sub", "new.txt"), String) == "line A\nline b\n"
        @test occursin("Edited sub/new.txt", result)
        @test occursin("1 | line A", result)
        @test occursin("2 | line b", result)
        # non-unique match errors name the occurrence lines
        write(joinpath(dir, "dup.txt"), "x\nx\n")
        err = try edit.func("dup.txt", "x", "y"); nothing catch e; e end
        @test err isa ArgumentError && occursin("at lines 1, 2", err.msg)
        # not-found errors include nearest-match candidates
        write(joinpath(dir, "near.txt"), "alpha\nbeta = 1\ngamma\n")
        err = try edit.func("near.txt", "beta = 2", "beta = 3"); nothing catch e; e end
        @test err isa ArgumentError && occursin("Closest candidates", err.msg)
        @test occursin("beta = 1", err.msg)
        # missing file errors
        @test_throws ArgumentError edit.func("nope.txt", "a", "b")
        # identical replacement errors
        @test_throws ArgumentError edit.func("sub/new.txt", "line b", "line b")
    end
end

@testset "remember tool" begin
    mktempdir() do dir
        jdb = Juco.opendb(joinpath(dir, "test.sqlite"))
        remember = Juco.create_remember_tool(jdb)
        @test remember.name == "remember"
        @test remember.func("the user prefers tabs") == "Saved."
        @test Juco.memories(jdb) == ["the user prefers tabs"]
    end
end

@testset "absolute paths within the working directory" begin
    mktempdir() do dir
        edit = Juco.create_edit_tool(dir)
        # absolute path inside base is accepted (including through macOS /var symlink)
        abs_inside = joinpath(realpath(dir), "abs.txt")
        @test occursin("Created", edit.func(abs_inside, "", "content\n"))
        @test isfile(joinpath(dir, "abs.txt"))
        # the unresolved (symlinked) form works too
        alt = joinpath(dir, "abs2.txt")
        @test occursin("Created", edit.func(alt, "", "content\n"))
        # absolute path outside base is rejected
        @test_throws ArgumentError edit.func("/etc/hosts", "a", "b")
        # relative escape is rejected
        @test_throws ArgumentError edit.func("../escape.txt", "", "x")
    end
end

@testset "openrouter provider prefs" begin
    delete!(ENV, "JUCO_OPENROUTER_ORDER")
    prefs = Juco.openrouter_provider_prefs()
    @test prefs["sort"] == "price"
    @test prefs["require_parameters"] === true
    @test "fp8" in prefs["quantizations"] && !("fp4" in prefs["quantizations"])
    ENV["JUCO_OPENROUTER_ORDER"] = "atlas-cloud/fp4, siliconflow/fp8"
    prefs = Juco.openrouter_provider_prefs()
    @test prefs["order"] == ["atlas-cloud/fp4", "siliconflow/fp8"]
    @test prefs["allow_fallbacks"] === true
    delete!(ENV, "JUCO_OPENROUTER_ORDER")
end

@testset "budget notice wrapping" begin
    mktempdir() do dir
        bash = Juco.create_bash_tool(dir)
        counter = Threads.Atomic{Int}(0)
        wrapped = Juco.with_budget_notice(bash, counter, 10)
        @test wrapped.name == "bash"
        @test Agentif.parameters(wrapped) == Agentif.parameters(bash)
        counter[] = 2   # plenty of budget: no notice
        @test !occursin("wrap up", wrapped.func("echo hi", nothing))
        counter[] = 6   # within the warning margin
        result = wrapped.func("echo hi", nothing)
        @test occursin("only 4 tool calls remain", result)
        @test occursin("hi", result)
    end
end

@testset "toolset presets" begin
    mktempdir() do dir
        jdb = Juco.opendb(joinpath(dir, "test.sqlite"))
        names(ts) = [t.name for t in ts]
        @test names(Juco.toolset(:juco, dir, jdb)) == ["bash", "read", "edit", "remember"]
        @test names(Juco.toolset(:juco, dir, nothing)) == ["bash", "read", "edit"]
        @test names(Juco.toolset(:pi, dir)) == ["bash", "read", "edit", "write"]
        @test names(Juco.toolset(:bash, dir)) == ["bash"]
        @test_throws ArgumentError Juco.toolset(:nope, dir)
    end
end

@testset "display formatters" begin
    @test Juco.format_tool_call("bash", "{\"command\": \"ls -la\\nfoo\"}") == "▸ bash ls -la foo"
    @test Juco.format_tool_call("read", "{\"path\": \"a.jl\", \"offset\": 10}") == "▸ read a.jl:10"
    @test Juco.format_tool_call("edit", "{\"path\": \"a.jl\", \"oldText\": \"x\"}") == "▸ edit a.jl"
    @test Juco.format_tool_call("edit", "{\"path\": \"a.jl\", \"oldText\": \"\"}") == "▸ edit a.jl (new file)"
    @test Juco.format_tool_call("bash", "not json") == "▸ bash not json"
    long = Juco.format_tool_call("bash", JSON.json(Dict("command" => "x"^300)))
    @test length(long) < 120 && endswith(long, "…")
    @test Juco.format_duration(75) == "75ms"
    @test Juco.format_duration(2350) == "2.4s"
    @test Juco.format_tokens(950) == "950"
    @test Juco.format_tokens(18234) == "18.2k"
    usage = Agentif.Usage(input = 1000, output = 200, cacheRead = 500, cacheWrite = 0, total = 1700)
    m = Agentif.getModel("anthropic", "claude-sonnet-4-5")
    line = Juco.usage_line(usage, m, 3, 12.34)
    @test occursin("12.3s", line)
    @test occursin("3 tools", line)
    @test occursin("1.5k in (33% cached)", line)
    @test occursin("200 out", line)
    @test occursin("\$", line)
end

@testset "display handler renders tool lines" begin
    buf = IOBuffer()
    handler = Juco.display_handler(buf)
    tc = Agentif.PendingToolCall(call_id = "c1", name = "bash", arguments = "{\"command\": \"echo hi\"}")
    handler(Agentif.ToolExecutionStartEvent(tc))
    result = Agentif.ToolResultMessage(call_id = "c1", name = "bash",
        content = [Agentif.TextContent(text = "hi")], is_error = false)
    handler(Agentif.ToolExecutionEndEvent(1, tc, result, 42))
    out = String(take!(buf))
    @test occursin("▸ bash echo hi", out)
    @test occursin("✓ 42ms", out)
    # error results show the message
    handler(Agentif.ToolExecutionStartEvent(tc))
    errres = Agentif.ToolResultMessage(call_id = "c1", name = "bash",
        content = [Agentif.TextContent(text = "{\"message\": \"boom happened\"}")], is_error = true)
    handler(Agentif.ToolExecutionEndEvent(1, tc, errres, 10))
    @test occursin("✗ boom happened", String(take!(buf)))
end

@testset "repl slash commands" begin
    mktempdir() do dir
        jdb = Juco.opendb(joinpath(dir, "t.sqlite"))
        st = Juco.ReplState(jdb, "s-original", "anthropic", "claude-sonnet-4-5", false)
        buf = IOBuffer()
        Juco.handle_command(st, "/new", buf)
        @test st.session_id != "s-original"
        Juco.handle_command(st, "/model", buf)
        @test occursin("anthropic/claude-sonnet-4-5", String(take!(buf)))
        Juco.handle_command(st, "/model nonsense-model-id", buf)
        @test occursin("unknown model", String(take!(buf)))
        @test st.model_id == "claude-sonnet-4-5"
        Juco.handle_command(st, "/model anthropic claude-haiku-4-5", buf)
        @test st.model_id == "claude-haiku-4-5"
        Juco.remember!(jdb, "a memory")
        Juco.handle_command(st, "/memories", buf)
        @test occursin("a memory", String(take!(buf)))
        Juco.handle_command(st, "/quit", buf)
        @test st.quit
        Juco.handle_command(st, "/bogus", buf)
        @test occursin("unknown command", String(take!(buf)))
    end
end

@testset "prompt" begin
    prompt = Juco.build_prompt(pwd(), :juco; memories = ["user likes short names"])
    @test occursin("user likes short names", prompt)
    @test occursin("Working directory: $(abspath(pwd()))", prompt)
    bare = Juco.build_prompt(pwd(), :bash)
    @test !occursin("Memories", bare)
    @test occursin("your only tool", bare)
    # directory snapshot: entries listed, dirs marked, big dirs capped
    mktempdir() do dir
        mkdir(joinpath(dir, "src"))
        write(joinpath(dir, "a.jl"), "")
        p = Juco.build_prompt(dir, :juco)
        @test occursin("a.jl", p)
        @test occursin("src/", p)
        for i in 1:60; write(joinpath(dir, "f$(lpad(i, 2, '0')).txt"), ""); end
        p = Juco.build_prompt(dir, :juco)
        @test occursin("more entries)", p)
    end
end

end
