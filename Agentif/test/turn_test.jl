module DurableTurnTests
using Test, Agentif, SQLite, LocalSearch, JSON

@testset "single model turn preserves raw codec and never invokes tools" begin
    model = Agentif.Model(;
        id = "turn-fixture", name = "fixture", api = "openai-completions", provider = "test", baseUrl = "http://localhost",
        reasoning = false, input = ["text"], cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
        contextWindow = 100000, maxTokens = 1000, headers = nothing, compat = nothing, kw = (;)
    )
    invoked = Ref(0)
    tool = Agentif.@tool "effect fixture" mark() = (invoked[] += 1; "effect")
    agent = Agentif.Agent(; model, prompt = "p", apikey = "fixture", tools = [tool], http_kw = (; readtimeout = 7, retries = 99))
    calls = [Agentif.AgentToolCall(; call_id = "call", name = "mark", arguments = "{}")]
    opaque = Agentif.AssistantContentBlock[
        Agentif.TextContent(; text = "output", textSignature = "opaque-text"),
        Agentif.ThinkingContent(; thinking = "", thinkingSignature = "opaque-redacted", redacted = true),
        Agentif.ToolCallContent(; id = "call", name = "mark", arguments = Dict{String, Any}(), thoughtSignature = "opaque-thought"),
    ]
    message = Agentif.AssistantMessage(; provider = "test", api = "openai-completions", model = "turn-fixture", response_id = "opaque-response", content = opaque, tool_calls = calls)
    for stop in (:stop, :tool_calls, :length, :error, :refusal, :aborted, :content_filter)
        stream = (f, a, s, input, abort; http_kw, kw...) -> begin
            @test http_kw.readtimeout == 7
            @test http_kw.retries == 0 && !http_kw.retry
            f(Agentif.MessageUpdateEvent(:assistant, message, :text_delta, "output", nothing))
            Agentif.append_state!(s, input, deepcopy(message), Agentif.Usage(; total = 5));s.most_recent_stop_reason = stop;s
        end
        original = Agentif.AgentState(; messages = [Agentif.UserMessage("prepared")])
        progress = Agentif.AgentEvent[]
        outcome = Agentif.model_turn(e -> push!(progress, e), agent, original; stream_fn = stream)
        @test length(original.messages) == 1
        @test invoked[] == 0
        @test outcome.stop_reason == stop
        @test !isempty(Agentif.eligible_tool_calls(outcome)) == (stop in (:stop, :tool_calls))
        decoded = JSON.parse(JSON.json(outcome.message), Agentif.AssistantMessage)
        @test decoded.content[1].textSignature == "opaque-text"
        @test decoded.content[2].thinkingSignature == "opaque-redacted" && decoded.content[2].redacted
        @test decoded.content[3].thoughtSignature == "opaque-thought"
        @test decoded.response_id == "opaque-response"
        @test outcome.usage.total == 5
    end
    aborted = Agentif.Abort();Agentif.abort!(aborted)
    outcome = Agentif.model_turn(e -> nothing, agent, Agentif.AgentState(), aborted; stream_fn = (a...; kw...) -> error("must not start"))
    @test outcome.stop_reason == :aborted
    @test isempty(Agentif.eligible_tool_calls(outcome))
end

@testset "caller transaction rolls back entry and leaf together" begin
    db = SQLite.DB()
    try
        Agentif.init_sqlite_session_schema!(db)
        entry = Agentif.SessionEntry(; id = "atomic", messages = [Agentif.UserMessage("input")])
        @test_throws ArgumentError Agentif.append_session_batch!(db, "branch", [entry])
        SQLite.execute(db, "BEGIN IMMEDIATE")
        Agentif.append_session_batch!(db, "branch", [entry])
        SQLite.execute(db, "ROLLBACK")
        @test isempty(collect(SQLite.DBInterface.execute(db, "SELECT entry_id FROM session_entries")))
        @test isempty(collect(SQLite.DBInterface.execute(db, "SELECT branch_id FROM session_branches")))
    finally
        close(db)
    end
end
end
