using Test
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
        # unique replace
        edit.func("sub/new.txt", "line a", "line A")
        @test read(joinpath(dir, "sub", "new.txt"), String) == "line A\nline b\n"
        # non-unique match errors
        write(joinpath(dir, "dup.txt"), "x\nx\n")
        @test_throws ArgumentError edit.func("dup.txt", "x", "y")
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

@testset "prompt" begin
    prompt = Juco.build_prompt(pwd(), :juco; memories = ["user likes short names"])
    @test occursin("user likes short names", prompt)
    @test occursin("Working directory: $(abspath(pwd()))", prompt)
    bare = Juco.build_prompt(pwd(), :bash)
    @test !occursin("Memories", bare)
    @test occursin("your only tool", bare)
end

end
