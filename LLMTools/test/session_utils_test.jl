using Test
using JSON
using LLMTools

@testset "Session Utils" begin
    @testset "approx_token_count" begin
        @test LLMTools.approx_token_count("") == 0
        @test LLMTools.approx_token_count("abcd") == 1
        @test LLMTools.approx_token_count("abcdefgh") == 2
        @test LLMTools.approx_token_count("a") == 1  # cld(1,4) == 1
    end

    @testset "line_count" begin
        @test LLMTools.line_count("") == 1
        @test LLMTools.line_count("a") == 1
        @test LLMTools.line_count("a\nb") == 2
        @test LLMTools.line_count("a\nb\nc") == 3
    end

    @testset "HeadTailBuffer" begin
        # Short text — no truncation
        buf = LLMTools.create_head_tail_buffer("a\nb\nc", 10)
        @test !buf.truncated
        @test buf.total_lines == 3
        @test LLMTools.format_head_tail_buffer(buf) == "a\nb\nc"

        # Truncation required
        text = join(string.(1:20), "\n")
        buf = LLMTools.create_head_tail_buffer(text, 6)
        @test buf.truncated
        @test buf.total_lines == 20
        @test buf.head_lines == 3
        @test buf.tail_lines == 3
        formatted = LLMTools.format_head_tail_buffer(buf)
        @test occursin("truncated", formatted)
        @test occursin("1", formatted)  # head includes first line
        @test occursin("20", formatted) # tail includes last line
    end

    @testset "truncate_text_head_tail_bytes" begin
        short = "hello"
        result = LLMTools.truncate_text_head_tail_bytes(short, 100)
        @test result.text == short
        @test !result.truncated

        long = repeat("x", 200)
        result = LLMTools.truncate_text_head_tail_bytes(long, 50)
        @test result.truncated
        @test ncodeunits(result.text) < ncodeunits(long)
        @test occursin("truncated bytes", result.text)
    end

    @testset "truncate_text_head_tail_tokens" begin
        short = "hello"
        result = LLMTools.truncate_text_head_tail_tokens(short, 100)
        @test result.text == short
        @test !result.truncated

        long = repeat("x", 1000)
        result = LLMTools.truncate_text_head_tail_tokens(long, 10)
        @test result.truncated
    end

    @testset "chunk_text_by_bytes" begin
        @test LLMTools.chunk_text_by_bytes("", 100) == String[]
        chunks = LLMTools.chunk_text_by_bytes("abcdefghij", 3)
        @test length(chunks) >= 3
        @test join(chunks) == "abcdefghij"
    end

    @testset "project_output" begin
        proj = LLMTools.project_output("hello\nworld", 1000, 10000)
        @test proj.output == "hello\nworld"
        @test !proj.truncated
        @test proj.original_line_count == 2

        big = join(["line $i" for i in 1:500], "\n")
        proj = LLMTools.project_output(big, 10, 10000)
        @test proj.line_truncated
        @test proj.truncated
        @test proj.original_line_count == 500
    end

    @testset "SessionRegistry basics" begin
        # Create a minimal test metadata type
        mutable struct TestMeta
            status::String
            created_at::Float64
            last_used::Float64
        end

        LLMTools.resolve_status(m::TestMeta) = m.status
        LLMTools.close_quietly(::TestMeta) = nothing
        LLMTools.session_command(::TestMeta) = "test"
        LLMTools.session_workdir(::TestMeta) = ""
        LLMTools.session_created_at(m::TestMeta) = m.created_at
        LLMTools.session_last_used(m::TestMeta) = m.last_used
        LLMTools.set_last_used!(m::TestMeta, t::Float64) = (m.last_used = t)
        LLMTools.set_status!(m::TestMeta, s::String) = (m.status = s)

        config = LLMTools.SessionRegistryConfig(5, 4, 60.0, 1)
        reg = LLMTools.SessionRegistry{TestMeta}(config)

        @test LLMTools.active_session_count(reg) == 0

        id1 = LLMTools.next_session_id!(reg)
        @test id1 == 1
        id2 = LLMTools.next_session_id!(reg)
        @test id2 == 2

        now = time()
        meta1 = TestMeta(LLMTools.SESSION_STATUS_RUNNING, now, now)
        LLMTools.register_session!(reg, id1, meta1)
        @test LLMTools.active_session_count(reg) == 1

        fetched = LLMTools.get_session(reg, id1)
        @test fetched === meta1

        @test LLMTools.get_session(reg, 999) === nothing

        removed = LLMTools.remove_session!(reg, id1; close_session = false)
        @test removed === meta1
        @test LLMTools.active_session_count(reg) == 0

        # cleanup_exited_sessions!
        meta2 = TestMeta(LLMTools.SESSION_STATUS_EXITED, now, now)
        meta3 = TestMeta(LLMTools.SESSION_STATUS_RUNNING, now, now)
        LLMTools.register_session!(reg, 10, meta2)
        LLMTools.register_session!(reg, 11, meta3)
        @test LLMTools.active_session_count(reg) == 2
        cleaned = LLMTools.cleanup_exited_sessions!(reg)
        @test cleaned == 1
        @test LLMTools.active_session_count(reg) == 1
        @test LLMTools.get_session(reg, 11) === meta3

        # reset
        LLMTools.reset_sessions_for_tests!(reg)
        @test LLMTools.active_session_count(reg) == 0
    end

    @testset "Event system" begin
        config = LLMTools.SessionRegistryConfig(5, 4, 60.0, 1)
        reg = LLMTools.SessionRegistry{LLMTools.PtySessionMetadata}(config)

        evt = LLMTools.make_event(reg, "test_kind"; session_id=42, payload=Dict("foo" => "bar"))
        @test evt["kind"] == "test_kind"
        @test evt["session_id"] == 42
        @test evt["foo"] == "bar"
        @test haskey(evt, "id")
        @test haskey(evt, "timestamp")
    end

    @testset "render_process_response" begin
        json_str = LLMTools.render_process_response("test_tool";
            ok=true,
            status=LLMTools.SESSION_STATUS_RUNNING,
            session_id=1,
            command="echo hi",
            wall_time_s=0.5,
            active_sessions=1,
        )
        parsed = JSON.parse(json_str)
        @test parsed["tool"] == "test_tool"
        @test parsed["ok"] == true
        @test parsed["status"] == LLMTools.SESSION_STATUS_RUNNING
        @test parsed["session_id"] == 1
        @test haskey(parsed, "summary")
        @test haskey(parsed, "schema_version")
    end
end
