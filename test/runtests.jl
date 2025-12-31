using Test, Agentif

@testset "Agentif Unit Tests" begin
    @testset "Session Stores" begin
        @testset "InMemorySessionStore" begin
            store = InMemorySessionStore()
            session_id = "session-1"
            state = load_session(store, session_id)
            @test state isa AgentState
            @test isempty(state.messages)

            push!(state.messages, UserMessage("hello"))
            save_session!(store, session_id, state)

            loaded = load_session(store, session_id)
            @test loaded === state
            @test length(loaded.messages) == 1
            @test loaded.messages[1] isa UserMessage
            @test loaded.messages[1].text == "hello"
        end

        @testset "FileSessionStore" begin
            base_dir = mktempdir()
            store = FileSessionStore(base_dir)
            session_id = "session-1"
            state = load_session(store, session_id)

            push!(state.messages, UserMessage("hello"))
            save_session!(store, session_id, state)

            session_file = joinpath(base_dir, session_id)
            @test isfile(session_file)

            fresh_store = FileSessionStore(base_dir)
            loaded = load_session(fresh_store, session_id)
            @test length(loaded.messages) == 1
            msg = loaded.messages[1]
            @test msg isa UserMessage
            @test msg.text == "hello"

            write(session_file, "{not json")
            corrupt_store = FileSessionStore(base_dir)
            recovered = load_session(corrupt_store, session_id)
            @test recovered isa AgentState
            @test isempty(recovered.messages)
        end
    end

    @testset "Predefined Tools" begin
        base_dir = mktempdir()

        write_tool = Agentif.create_write_tool(base_dir)
        read_tool = Agentif.create_read_tool(base_dir)
        ls_tool = Agentif.create_ls_tool(base_dir)

        write_result = write_tool.func("notes/hello.txt", "hi")
        @test contains(write_result, "Successfully wrote")

        read_result = read_tool.func("notes/hello.txt", nothing, nothing)
        @test read_result == "hi"

        ls_result = ls_tool.func("notes", nothing)
        @test contains(ls_result, "hello.txt")

        @test_throws ArgumentError write_tool.func(joinpath(base_dir, "abs.txt"), "nope")
        @test_throws ArgumentError read_tool.func("../outside.txt", nothing, nothing)

        tool_names = [tool.name for tool in Agentif.coding_tools(base_dir)]
        @test tool_names == ["read", "bash", "edit", "write"]

        read_only_names = [tool.name for tool in Agentif.read_only_tools(base_dir)]
        @test read_only_names == ["read", "grep", "find", "ls"]
    end

    @testset "Pending Tool Calls" begin
        ptc = Agentif.PendingToolCall(; call_id="call-1", name="add", arguments="{\"x\": 1, \"y\": 2}")
        @test ptc.approved === nothing
        Agentif.approve!(ptc)
        @test ptc.approved == true

        ptc2 = Agentif.PendingToolCall(; call_id="call-2", name="multiply", arguments="{}")
        Agentif.reject!(ptc2, "nope")
        @test ptc2.approved == false
        @test ptc2.rejected_reason == "nope"

        calls = [ptc, ptc2]
        @test Agentif.findpendingtool(calls, "call-1") === ptc
        @test_throws ArgumentError Agentif.findpendingtool(calls, "missing")
    end
end

include("integration/helpers.jl")
include("integration/providers/openai_responses.jl")
include("integration/providers/openai_completions.jl")
include("integration/providers/anthropic_messages.jl")
include("integration/providers/google_generative_ai.jl")
include("integration/providers/google_gemini_cli.jl")
include("integration.jl")
