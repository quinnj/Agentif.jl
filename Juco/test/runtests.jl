using Test
using JSON
using Juco
using Agentif
using HTTP
using LLMProviders
using Sockets
using SQLite

include(joinpath(@__DIR__, "..", "eval", "env.jl"))

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
        # overlapping occurrences are also ambiguous
        write(joinpath(dir, "overlap.txt"), "aaa")
        @test_throws ArgumentError edit.func("overlap.txt", "aa", "b")
        # not-found errors include nearest-match candidates
        write(joinpath(dir, "near.txt"), "alpha\nbeta = 1\ngamma\n")
        err = try edit.func("near.txt", "beta = 2", "beta = 3"); nothing catch e; e end
        @test err isa ArgumentError && occursin("Closest candidates", err.msg)
        @test occursin("beta = 1", err.msg)
        # missing file errors
        @test_throws ArgumentError edit.func("nope.txt", "a", "b")
        # identical replacement errors
        @test_throws ArgumentError edit.func("sub/new.txt", "line b", "line b")
        # edited-region reporting must not byte-index before a match that follows UTF-8
        write(joinpath(dir, "utf8.txt"), "cafétarget\n")
        result = edit.func("utf8.txt", "target", "done")
        @test read(joinpath(dir, "utf8.txt"), String) == "cafédone\n"
        @test occursin("1 | cafédone", result)
    end
end

@testset "tail truncation byte limit" begin
    result = Juco.truncate_tail("éé"; max_lines = 10, max_bytes = 3)
    @test result.truncated
    @test ncodeunits(result.content) <= 3
    @test result.content == "é"
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
        st = Juco.ReplState(jdb, "s-original"; base_dir = dir)
        @test st.mode == "openrouter"
        @test st.model_id == Juco.MODE_DEFAULT_MODEL["openrouter"]
        buf = IOBuffer()
        Juco.handle_command(st, "/new", buf)
        @test st.session_id != "s-original"
        Juco.handle_command(st, "/model nonsense-model-id", buf)
        @test occursin("unknown model", String(take!(buf)))
        Juco.handle_command(st, "/model codex gpt-5.3-codex", buf)
        @test st.mode == "codex" && st.model_id == "gpt-5.3-codex"
        Juco.handle_command(st, "/model openrouter", buf)
        @test st.mode == "openrouter"
        @test st.model_id == Juco.MODE_DEFAULT_MODEL["openrouter"]
        Juco.handle_command(st, "/model codex", buf)
        @test st.mode == "codex"
        @test st.model_id == Juco.MODE_DEFAULT_MODEL["codex"]
        # selection persists: a fresh state reloads it from the db
        st2 = Juco.ReplState(jdb, "other"; base_dir = dir)
        @test st2.mode == "codex" && st2.model_id == "gpt-5.3-codex"
        Juco.handle_command(st, "/model bogus-mode some-model", buf)
        @test occursin("unknown mode", String(take!(buf)))
        Juco.remember!(jdb, "a memory")
        Juco.handle_command(st, "/memories", buf)
        @test occursin("a memory", String(take!(buf)))
        Juco.handle_command(st, "/skills", buf)
        @test occursin("No skills found", String(take!(buf)))
        Juco.handle_command(st, "/quit", buf)
        @test st.quit
        Juco.handle_command(st, "/bogus", buf)
        @test occursin("unknown command", String(take!(buf)))
    end
end

@testset "config store" begin
    mktempdir() do dir
        jdb = Juco.opendb(joinpath(dir, "t.sqlite"))
        @test Juco.get_config(jdb, "k") === nothing
        @test Juco.get_config(jdb, "k", "fallback") == "fallback"
        Juco.set_config!(jdb, "k", "v1")
        @test Juco.get_config(jdb, "k") == "v1"
        Juco.set_config!(jdb, "k", "v2")
        @test Juco.get_config(jdb, "k") == "v2"
        Juco.set_config!(jdb, "k", nothing)
        @test Juco.get_config(jdb, "k") === nothing
        Juco.set_config!(jdb, "k", "final")
        @test Juco.get_config(jdb, "k") == "final"
        # A partial one-row SELECT must release its statement and schema lock.
        @test_nowarn SQLite.execute(jdb.db, "DROP TABLE juco_config")
    end
end

@testset "database lifecycle" begin
    mktempdir() do dir
        normal_db = Ref{Juco.JucoDB}()
        @test Juco.with_jdb(joinpath(dir, "normal.sqlite")) do jdb
            normal_db[] = jdb
            :done
        end === :done
        @test !isopen(normal_db[].db)

        failed_db = Ref{Juco.JucoDB}()
        @test_throws ErrorException Juco.with_jdb(joinpath(dir, "failed.sqlite")) do jdb
            failed_db[] = jdb
            error("stop")
        end
        @test !isopen(failed_db[].db)
    end
end

@testset "failed evaluation setup does not create a session" begin
    mktempdir() do dir
        Juco.with_jdb(joinpath(dir, "failed-setup.sqlite")) do jdb
            missing = joinpath(dir, "missing")
            @test_throws ArgumentError Juco.evaluate("hello";
                jdb, base_dir = missing, provider = "anthropic",
                model_id = "claude-sonnet-4-5", apikey = "test")
            @test isempty(Juco.list_sessions(jdb))

            server = HTTP.serve!("127.0.0.1", 0) do _
                HTTP.Response(400, ["Content-Type" => "application/json"],
                    JSON.json(Dict("error" => Dict("message" => "forced failure"))))
            end
            try
                port = applicable(HTTP.port, server) && HTTP.port(server) != 0 ?
                    HTTP.port(server) : Sockets.getsockname(server.listener.server)[2]
                provider = "juco-failed-turn-test"
                model_id = "failed-turn"
                LLMProviders.registerModel!(LLMProviders.Model(;
                    id = model_id, name = model_id, api = "openai-completions",
                    provider, baseUrl = "http://127.0.0.1:$(port)", reasoning = false,
                    input = ["text"], cost = Dict("input" => 0.0, "output" => 0.0,
                        "cacheRead" => 0.0, "cacheWrite" => 0.0),
                    contextWindow = 4096, maxTokens = 256,
                ))
                @test_throws Exception Juco.evaluate("hello";
                    jdb, base_dir = dir, provider, model_id, apikey = "test")
                @test isempty(Juco.list_sessions(jdb))
            finally
                close(server)
            end
        end
    end
end

@testset "eval environment" begin
    withenv("OPENROUTER_API_KEY" => nothing) do
        @test_throws ArgumentError load_eval_env!()
    end
    withenv(
            "OPENROUTER_API_KEY" => "test-key",
            "JUCO_MODEL_PROVIDER" => nothing,
            "JUCO_MODEL" => nothing,
            "JUCO_REASONING" => nothing,
            "JUCO_OPENROUTER_ORDER" => nothing,
        ) do
        @test load_eval_env!() === nothing
        @test ENV["JUCO_MODEL_PROVIDER"] == "openrouter"
        @test ENV["JUCO_MODEL"] == "deepseek/deepseek-v4-flash-0731"
        @test ENV["JUCO_REASONING"] == "medium"
        @test ENV["JUCO_OPENROUTER_ORDER"] == "siliconflow/fp8"
    end
end

@testset "model modes" begin
    @test Juco.mode_provider("openrouter") == "openrouter"
    @test Juco.mode_provider("codex") == "openai-codex"
    @test Juco.mode_apikey("codex") == "OAUTH"
    @test "gpt-5.3-codex" in Juco.mode_models("codex")
    @test Juco.reasoning_levels("codex", "gpt-5.3-codex") ==
        ["none", "minimal", "low", "medium", "high", "xhigh"]
    @test Juco.reasoning_levels("openrouter", "deepseek/deepseek-v4-flash-0731") ==
        ["none", "low", "medium", "high"]
    @test Juco.reasoning_levels("openrouter", "not-a-model") == ["none"]
    @test occursin("ago", Juco.session_age(time() - 7200))
    @test Juco.session_age(time() - 10) == "just now"

    mktempdir() do dir
        jdb = Juco.opendb(joinpath(dir, "state.sqlite"))
        Juco.set_config!(jdb, "model_mode", "removed-mode")
        Juco.set_config!(jdb, "model_id", "removed-model")
        Juco.set_config!(jdb, "reasoning", "extreme")
        @test Juco.load_model_state(jdb) ==
            ("openrouter", Juco.MODE_DEFAULT_MODEL["openrouter"], nothing)
        @test Juco.get_config(jdb, "model_mode") == "openrouter"
        @test Juco.get_config(jdb, "model_id") == Juco.MODE_DEFAULT_MODEL["openrouter"]
        @test Juco.get_config(jdb, "reasoning") === nothing
    end

    mktempdir() do dir
        jdb = Juco.opendb(joinpath(dir, "atomic-state.sqlite"))
        Juco.save_model_state!(jdb, "openrouter", Juco.MODE_DEFAULT_MODEL["openrouter"], nothing)
        SQLite.execute(jdb.db, """
            CREATE TRIGGER reject_reasoning
            BEFORE INSERT ON juco_config
            WHEN NEW.key = 'reasoning'
            BEGIN
                SELECT RAISE(ABORT, 'reject reasoning');
            END
        """)
        @test_throws SQLite.SQLiteException Juco.save_model_state!(
            jdb, "codex", Juco.MODE_DEFAULT_MODEL["codex"], "high")
        @test Juco.get_config(jdb, "model_mode") == "openrouter"
        @test Juco.get_config(jdb, "model_id") == Juco.MODE_DEFAULT_MODEL["openrouter"]
        @test Juco.get_config(jdb, "reasoning") === nothing
    end
end

@testset "non-TTY menu EOF cancels" begin
    buf = IOBuffer()
    @test Juco.choose(buf, "Pick:", ["one", "two"]; default = 2, input = IOBuffer("")) === nothing
    @test Juco.choose(buf, "Pick:", ["one", "two"]; default = 2, input = IOBuffer("\n")) == 2
    @test Juco.choose(buf, "Pick:", ["one", "two"]; input = IOBuffer("9\n")) === nothing
end

@testset "CLI argument parsing" begin
    parsed = Juco.parse_cli_args(["--list", "--db", "/tmp/juco-test.sqlite"])
    @test parsed.list
    @test parsed.db_path == "/tmp/juco-test.sqlite"
    @test_throws ArgumentError Juco.parse_cli_args(["--db"])
    @test_throws ArgumentError Juco.parse_cli_args(["--prompt"])
    @test_throws ArgumentError Juco.parse_cli_args(["--preset", "unknown"])
end

@testset "skills" begin
    mktempdir() do dir
        skdir = joinpath(dir, ".agent", "skills")
        mkpath(joinpath(skdir, "review"))
        write(joinpath(skdir, "review", "SKILL.md"), """
            ---
            description: Careful code review checklist
            ---
            # Review
            Look for bugs first.
            """)
        mkpath(joinpath(skdir, "tdd"))
        write(joinpath(skdir, "tdd", "SKILL.md"), "Write the failing test first.\n")
        skills = Juco.discover_skills(dir)
        # may include user-global ~/.agent/skills too; ours must be present
        names = [s.name for s in skills]
        @test "review" in names && "tdd" in names
        review = skills[findfirst(==("review"), names)]
        @test review.description == "Careful code review checklist"
        tdd = skills[findfirst(==("tdd"), names)]
        @test tdd.description == "Write the failing test first."

        ours = [s for s in skills if s.name in ("review", "tdd")]
        # completion: after "$re" completes to review
        names2, range, should = Juco.skill_completions("please \$re", ncodeunits("please \$re"), ours)
        @test names2 == ["review"] && should
        @test (first(range), last(range)) == (9, 10)
        # bare "$" offers everything
        names3, _, _ = Juco.skill_completions("\$", 1, ours)
        @test sort(names3) == ["review", "tdd"]
        # no $ context: no completions
        names4, _, should4 = Juco.skill_completions("hello", 5, ours)
        @test isempty(names4) && !should4

        # expansion appends blocks once per used skill
        expanded, used = Juco.expand_skills("apply \$tdd and \$review and \$tdd again", ours)
        @test used == ["tdd", "review"]
        @test occursin("<skill name=\"tdd\">", expanded)
        @test occursin("Write the failing test first.", expanded)
        @test count("<skill name=\"tdd\">", expanded) == 1
        # unknown tokens untouched, no blocks
        expanded2, used2 = Juco.expand_skills("cost is \$100", ours)
        @test isempty(used2) && expanded2 == "cost is \$100"
    end
end

@testset "steering instrumentation" begin
    mktempdir() do dir
        bash = Juco.create_bash_tool(dir)
        counter = Threads.Atomic{Int}(0)
        steer = Channel{String}(4)
        delivered = String[]
        tool = Juco.instrument_tool(bash, counter, 50, steer, t -> push!(delivered, t))
        # nothing queued: result unchanged
        @test !occursin("interjected", tool.func("echo hi", nothing))
        # queued messages are appended to the next result and reported delivered
        put!(steer, "also update the docs")
        put!(steer, "and run the linter")
        result = tool.func("echo hi", nothing)
        @test occursin("user interjected", result)
        @test occursin("also update the docs", result)
        @test occursin("and run the linter", result)
        @test delivered == ["also update the docs", "and run the linter"]
        # drained: next call is clean again
        @test !occursin("interjected", tool.func("echo hi", nothing))
    end
end

@testset "steering queue drain is serialized" begin
    steer = Channel{String}(2)
    put!(steer, "only once")
    lk = ReentrantLock()
    tasks = [Threads.@spawn Juco.drain_steering!(steer, lk) for _ in 1:2]
    @test timedwait(() -> all(istaskdone, tasks), 2.0) == :ok
    drained = reduce(vcat, fetch.(tasks))
    @test drained == ["only once"]
end

@testset "turn task failure handling" begin
    buf = IOBuffer()
    interrupted = @async throw(InterruptException())
    @test Juco.wait_turn(interrupted, Agentif.Abort(), buf) === nothing

    inner = @async error("root turn failure")
    nested = @async fetch(inner)
    @test Juco.wait_turn(nested, Agentif.Abort(), buf) === nothing
    output = String(take!(buf))
    @test occursin("error: root turn failure", output)
    @test !occursin("error: TaskFailedException", output)

    no_login = @async error("No stored Codex credentials found")
    @test Juco.wait_turn(no_login, Agentif.Abort(), buf) === nothing
    @test occursin("LLMOAuth.codex_login()", String(take!(buf)))
end

@testset "terminal output shares one lock" begin
    buf = IOBuffer()
    lk = ReentrantLock()
    channel = Juco.TerminalChannel("s", buf; io_lock = lk)
    @test channel.io_lock === lk
    handler = Juco.display_handler(buf; io_lock = lk)
    tc = Agentif.PendingToolCall(call_id = "c", name = "bash", arguments = "{\"command\":\"true\"}")
    handler(Agentif.ToolExecutionStartEvent(tc))
    Agentif.append_to_stream(channel, "done")
    Agentif.finish_streaming(channel)
    @test occursin("done", String(take!(buf)))
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
