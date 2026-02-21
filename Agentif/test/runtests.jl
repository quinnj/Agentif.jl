using Test
using Agentif
using JSON
using LocalSearch
using SQLite

function dummy_model()
    return Model(
        id = "test-model",
        name = "test-model",
        api = "openai-completions",
        provider = "test",
        baseUrl = "http://localhost",
        reasoning = false,
        input = ["text"],
        cost = Dict(
            "input" => 0.0,
            "output" => 0.0,
            "cacheRead" => 0.0,
            "cacheWrite" => 0.0,
        ),
        contextWindow = 1,
        maxTokens = 1,
        headers = nothing,
        compat = nothing,
        kw = (;),
    )
end

function make_agent(; prompt = "test prompt", tools = AgentTool[])
    return Agent(
        id = "agent-1",
        prompt = prompt,
        model = dummy_model(),
        apikey = "test-key",
        tools = tools,
    )
end

function make_base_handler(; with_tool_call::Bool = false, call_counter = Ref(0), inputs = Agentif.AgentTurnInput[])
    return function (f, agent::Agent, state::AgentState, current_input::Agentif.AgentTurnInput, abort::Agentif.Abort; kw...)
        call_counter[] += 1
        push!(inputs, current_input)
        msg = AssistantMessage(; provider = "test", api = "test", model = "test")
        if with_tool_call && call_counter[] == 1
            call = AgentToolCall(; call_id = "call-1", name = "echo", arguments = "{\"text\":\"hi\"}")
            push!(msg.tool_calls, call)
        end
        Agentif.append_state!(state, current_input, msg, Usage())
        if with_tool_call && call_counter[] == 1
            state.pending_tool_calls = Agentif.PendingToolCall[Agentif.PendingToolCall(; call_id = "call-1", name = "echo", arguments = "{\"text\":\"hi\"}")]
            state.most_recent_stop_reason = :tool_calls
        else
            state.pending_tool_calls = Agentif.PendingToolCall[]
            state.most_recent_stop_reason = :stop
        end
        return state
    end
end

struct SessionTestChannel <: Agentif.AbstractChannel
    id::String
    user::Union{Nothing, Agentif.ChannelUser}
    message_id::Union{Nothing, String}
end

Agentif.channel_id(ch::SessionTestChannel) = ch.id
Agentif.get_current_user(ch::SessionTestChannel) = ch.user
Agentif.source_message_id(ch::SessionTestChannel) = ch.message_id

@testset "stream (MiniMax live)" begin
    provider = get(ENV, "VO_AGENT_PROVIDER", "")
    model_id = get(ENV, "VO_AGENT_MODEL", "")
    apikey = get(ENV, "VO_AGENT_API_KEY", "")

    if isempty(provider) || isempty(model_id) || isempty(apikey)
        @info "Skipping live MiniMax tests; VO_AGENT_* env vars are not set."
    else
        model = getModel(provider, model_id)
        @test model !== nothing
        tool = @tool "Echo a string." echo(text::String) = text
        agent = Agent(
            id = "live-agent",
            prompt = "You must call the echo tool with JSON arguments {\"text\":\"pong\"}. Do not answer directly.",
            model = model,
            apikey = apikey,
            tools = [tool],
        )
        events = AgentEvent[]
        state = AgentState()
        result_state = stream(
            e -> push!(events, e),
            agent,
            state,
            "ping",
            Abort();
            tool_choice = Dict("type" => "function", "function" => Dict("name" => "echo")),
        )
        @test result_state isa AgentState
        @test result_state.most_recent_stop_reason !== nothing
        @test !isempty(result_state.messages)
        @test !isempty(result_state.pending_tool_calls)
        @test result_state.pending_tool_calls[1].name == "echo"
        @test any(e -> e isa ToolCallRequestEvent, events)
    end
end

@testset "steer_middleware" begin
    steer_queue = Channel{Agentif.AgentTurnInput}(1)
    put!(steer_queue, "steer")
    call_counter = Ref(0)
    inputs = Agentif.AgentTurnInput[]
    base_handler = make_base_handler(; call_counter, inputs)
    handler = steer_middleware(base_handler, steer_queue)
    agent = make_agent()
    state = AgentState()
    result_state = handler(identity, agent, state, "original", Abort())
    @test call_counter[] == 1
    @test inputs[1] == "steer"
    @test length(result_state.messages) >= 2
    @test result_state.messages[1] isa UserMessage
    @test message_text(result_state.messages[1]) == "original"
    @test result_state.messages[2] isa UserMessage
    @test message_text(result_state.messages[2]) == "steer"
end

@testset "tool_call_middleware" begin
    call_counter = Ref(0)
    inputs = Agentif.AgentTurnInput[]
    base_handler = make_base_handler(; with_tool_call = true, call_counter, inputs)
    handler = tool_call_middleware(base_handler)
    tool = @tool "Echo a string." echo(text::String) = text
    agent = make_agent(; tools = [tool])
    state = AgentState()
    result_state = handler(identity, agent, state, "hello", Abort())
    @test call_counter[] == 2
    @test length(inputs) == 2
    @test inputs[2] isa Vector{ToolResultMessage}
    tool_results = inputs[2]
    @test length(tool_results) == 1
    @test message_text(tool_results[1]) == "hi"
    @test isempty(result_state.pending_tool_calls)
end

@testset "queue_middleware" begin
    message_queue = Channel{Agentif.AgentTurnInput}(2)
    put!(message_queue, "followup")
    put!(message_queue, "followup-2")
    call_counter = Ref(0)
    inputs = Agentif.AgentTurnInput[]
    base_handler = make_base_handler(; call_counter, inputs)
    handler = queue_middleware(base_handler, message_queue)
    agent = make_agent()
    state = AgentState()
    result_state = handler(identity, agent, state, "first", Abort())
    @test call_counter[] == 3
    @test inputs[1] == "first"
    @test inputs[2] == "followup"
    @test inputs[3] == "followup-2"
    @test !isempty(result_state.messages)
end

@testset "session_middleware" begin
    store = InMemorySessionStore()
    call_counter = Ref(0)
    base_handler = make_base_handler(; call_counter)
    handler = session_middleware(base_handler, store)
    agent = make_agent()
    state = AgentState()
    result_state = handler(identity, agent, state, "hello", Abort())
    @test result_state.session_id !== nothing
    sid = result_state.session_id
    @test haskey(store.sessions, sid)

    len1 = length(result_state.messages)
    result_state_2 = handler(identity, agent, AgentState(), "again", Abort())
    @test result_state_2.session_id == sid
    @test length(result_state_2.messages) > len1
end

@testset "SessionEntry metadata serialization" begin
    entry = SessionEntry(;
        id = "entry-1",
        created_at = 123.0,
        messages = AgentMessage[UserMessage("hello")],
        is_compaction = false,
        user_id = "U123",
        post_id = "P123",
        channel_id = "chan:123",
        channel_flags = 0x03,
    )
    roundtrip = JSON.parse(JSON.json(entry), SessionEntry)
    @test roundtrip.user_id == "U123"
    @test roundtrip.post_id == "P123"
    @test roundtrip.channel_id == "chan:123"
    @test roundtrip.channel_flags == 3
    @test roundtrip.id == "entry-1"
    @test roundtrip.messages[1] isa UserMessage
end

@testset "session_middleware captures channel metadata" begin
    store = InMemorySessionStore()
    handler = session_middleware(make_base_handler(), store)
    agent = make_agent()
    channel = SessionTestChannel("chan:1", Agentif.ChannelUser("U555", "Taylor"), "post-777")

    state = Agentif.with_channel(channel) do
        handler(identity, agent, AgentState(), "hello", Abort())
    end

    entries = session_entries(store, state.session_id)
    @test length(entries) == 1
    @test entries[1].user_id == "U555"
    @test entries[1].post_id == "post-777"
    @test entries[1].channel_id == "chan:1"
    # SessionTestChannel defaults: is_group=false, is_private=true → flags=0x01
    @test entries[1].channel_flags == 1
end

@testset "AgentifSQLiteExt session store" begin
    @test isdefined(Agentif, :SQLiteSessionStore)
    store = Agentif.SQLiteSessionStore(tempname(); embed = nothing)
    db = store.db
    search_store = store.search_store
    sid = "session-1"

    entry = SessionEntry(;
        id = "entry-1",
        created_at = 1000.5,
        messages = AgentMessage[UserMessage("hello sqlite world")],
        user_id = "U100",
        post_id = "P100",
        channel_id = "chan:alpha",
    )
    append_session_entry!(store, sid, entry)

    channel_entry = SessionEntry(;
        id = "entry-2",
        created_at = 1001.5,
        messages = AgentMessage[UserMessage("second sqlite row")],
        user_id = "U200",
        post_id = "P200",
        channel_id = "chan:beta",
    )
    append_session_entry!(store, sid, channel_entry)

    @test session_entry_count(store, sid) == 2

    entries = session_entries(store, sid)
    @test length(entries) == 2
    @test entries[1].id == "entry-1"
    @test entries[1].user_id == "U100"
    @test entries[1].post_id == "P100"
    @test entries[1].channel_id == "chan:alpha"
    @test entries[2].id == "entry-2"
    @test entries[2].user_id == "U200"
    @test entries[2].post_id == "P200"
    @test entries[2].channel_id == "chan:beta"

    row_iter = SQLite.DBInterface.execute(db, "SELECT entry, user_id, post_id, channel_id FROM session_entries WHERE entry_id = ?", ("entry-1",))
    row = iterate(row_iter)
    @test row !== nothing
    parsed = JSON.parse(row[1].entry, SessionEntry)
    @test parsed.id == "entry-1"
    @test parsed.user_id == "U100"
    @test parsed.post_id == "P100"
    @test parsed.channel_id == "chan:alpha"
    @test row[1].user_id == "U100"
    @test row[1].post_id == "P100"
    @test row[1].channel_id == "chan:alpha"

    results = LocalSearch.search(search_store, "hello sqlite world"; limit = 5)
    matches = filter(r -> startswith(r.id, "session:$(sid):entry-1"), results)
    @test !isempty(matches)
    @test occursin("\"id\":\"entry-1\"", matches[1].text)
    @test occursin("\"messages\":", matches[1].text)
    @test occursin("\"channel_id\":\"chan:alpha\"", matches[1].text)
    tag_rows = SQLite.DBInterface.execute(
        db,
        "SELECT dt.tag FROM document_tags dt JOIN documents d ON d.id = dt.document_id WHERE d.key = ?",
        ("session:$(sid):entry-1",),
    )
    tags = String[String(r.tag) for r in tag_rows]
    @test "session_entry" in tags
    # entry has no channel_flags → tagged as public
    @test "session:public" in tags
    @test "session:ch:chan:alpha" in tags
end

@testset "AgentifSQLiteExt schema columns" begin
    ext = Base.get_extension(Agentif, :AgentifSQLiteExt)
    @test ext !== nothing
    db = SQLite.DB(tempname())
    Agentif.init_sqlite_session_schema!(db)
    cols = Set{String}()
    for row in SQLite.DBInterface.execute(db, "PRAGMA table_info(session_entries)")
        push!(cols, String(row.name))
    end
    @test "entry" in cols
    @test "user_id" in cols
    @test "post_id" in cols
    @test "channel_id" in cols
    @test "channel_flags" in cols
end

@testset "session search channel visibility" begin
    store = InMemorySessionStore()
    base_handler = make_base_handler()
    handler = session_middleware(base_handler, store; session_id = "vis-test")
    agent = make_agent()

    # Manually append entries with different channel visibility
    public_entry = SessionEntry(;
        id = "pub-1", messages = AgentMessage[UserMessage("public info")],
        channel_id = "chan:public", channel_flags = 0x02,  # is_group=true, is_private=false
    )
    private_entry = SessionEntry(;
        id = "priv-1", messages = AgentMessage[UserMessage("private secret")],
        channel_id = "chan:dm", channel_flags = 0x01,  # is_group=false, is_private=true
    )
    private_group_entry = SessionEntry(;
        id = "pgrp-1", messages = AgentMessage[UserMessage("private group info")],
        channel_id = "chan:pgroup", channel_flags = 0x03,  # is_group=true, is_private=true
    )
    legacy_entry = SessionEntry(;
        id = "legacy-1", messages = AgentMessage[UserMessage("legacy data")],
    )
    for e in [public_entry, private_entry, private_group_entry, legacy_entry]
        append_session_entry!(store, "vis-test", e)
    end

    # No channel context → see everything
    all_results = search_sessions(store, "info secret data"; limit=10)
    @test length(all_results) == 4

    # From the public channel → see public + legacy + own channel, NOT other private channels
    pub_results = search_sessions(store, "info secret data"; limit=10, current_channel_id="chan:public")
    pub_sids = Set(r.session_id for r in pub_results)
    @test length(pub_results) == 2  # public_entry + legacy_entry

    # From the DM → see own DM + public + legacy, NOT private group
    dm_results = search_sessions(store, "info secret data"; limit=10, current_channel_id="chan:dm")
    @test length(dm_results) == 3  # private_entry + public_entry + legacy_entry

    # From the private group → see own group + public + legacy, NOT DM
    pgrp_results = search_sessions(store, "info secret data"; limit=10, current_channel_id="chan:pgroup")
    @test length(pgrp_results) == 3  # private_group_entry + public_entry + legacy_entry
end

@testset "input_guardrail_middleware" begin
    guardrail = (prompt, input, apikey) -> input != "blocked"
    base_handler = make_base_handler()
    handler = input_guardrail_middleware(base_handler, guardrail)
    agent = make_agent()
    state = AgentState()
    @test_throws Agentif.InvalidInputError handler(identity, agent, state, "blocked", Abort())
end

@testset "compaction" begin
    @testset "estimate_message_tokens" begin
        user_msg = UserMessage("hello world")
        @test Agentif.estimate_message_tokens(user_msg) > 0

        # Longer message should have more tokens
        long_msg = UserMessage("a" ^ 400)
        short_msg = UserMessage("hi")
        @test Agentif.estimate_message_tokens(long_msg) > Agentif.estimate_message_tokens(short_msg)

        # AssistantMessage with tool calls should count arguments
        assistant_msg = AssistantMessage(; provider = "test", api = "test", model = "test")
        push!(assistant_msg.tool_calls, AgentToolCall(; call_id = "c1", name = "read", arguments = "{\"path\":\"/foo/bar/baz.jl\"}"))
        @test Agentif.estimate_message_tokens(assistant_msg) > 0

        # CompactionSummaryMessage
        compaction_msg = CompactionSummaryMessage(; summary = "some summary text", tokens_before = 100, compacted_at = time())
        @test Agentif.estimate_message_tokens(compaction_msg) > 0
    end

    @testset "find_cut_point" begin
        # Empty / single message: no cut point
        @test Agentif.find_cut_point(AgentMessage[], 100) == 0
        @test Agentif.find_cut_point(AgentMessage[UserMessage("hi")], 100) == 0

        # Build messages: User → Assistant → ToolResult → User → Assistant
        # Each ~100 chars ≈ 25 tokens
        msgs = AgentMessage[
            UserMessage("a" ^ 100),           # ~25 tokens
            AssistantMessage(; provider = "t", api = "t", model = "t"),
            ToolResultMessage("c1", "tool1", "b" ^ 100),  # ~25 tokens
            UserMessage("c" ^ 100),           # ~25 tokens
            AssistantMessage(; provider = "t", api = "t", model = "t"),
        ]
        Agentif.append_text!(msgs[2], "x" ^ 100)
        Agentif.append_text!(msgs[5], "y" ^ 100)

        # With keep_recent=50 tokens, should keep last ~50 tokens worth of messages
        # Walking backwards: msg5 (~25) + msg4 (~25) = 50, candidate = 4
        # msg4 is UserMessage → valid cut point
        cut = Agentif.find_cut_point(msgs, 50)
        @test cut == 4
        @test msgs[cut] isa UserMessage

        # With keep_recent=10 tokens, candidate is near the end
        # but if no UserMessage exists after the candidate, returns 0
        cut2 = Agentif.find_cut_point(msgs, 10)
        @test cut2 == 0 || msgs[cut2] isa UserMessage

        # With keep_recent very large, nothing to compact
        @test Agentif.find_cut_point(msgs, 100000) == 0

        # Cut point must land on UserMessage
        # If candidate is an AssistantMessage, walk forward to next UserMessage
        msgs2 = AgentMessage[
            UserMessage("a" ^ 100),
            AssistantMessage(; provider = "t", api = "t", model = "t"),
            UserMessage("b" ^ 100),
        ]
        Agentif.append_text!(msgs2[2], "x" ^ 100)
        # keep_recent=30 → walks back, candidate hits msg2 (AssistantMessage)
        # walks forward → msg3 (UserMessage)
        cut3 = Agentif.find_cut_point(msgs2, 30)
        @test cut3 == 0 || msgs2[cut3] isa UserMessage
    end

    @testset "format_messages_for_summary" begin
        msgs = AgentMessage[
            UserMessage("What is 2+2?"),
            AssistantMessage(; provider = "t", api = "t", model = "t"),
            ToolResultMessage("c1", "calculator", "4"),
        ]
        push!(msgs[2].tool_calls, AgentToolCall(; call_id = "c1", name = "calculator", arguments = "{\"expr\":\"2+2\"}"))
        Agentif.append_text!(msgs[2], "Let me calculate that.")

        text = Agentif.format_messages_for_summary(msgs)
        @test occursin("User: What is 2+2?", text)
        @test occursin("Assistant: Let me calculate that.", text)
        @test occursin("Assistant called tool: calculator", text)
        @test occursin("Tool calculator result: 4", text)

        # Truncation of long tool results
        long_result = ToolResultMessage("c2", "read_file", "z" ^ 1000)
        text2 = Agentif.format_messages_for_summary(AgentMessage[long_result])
        @test occursin("(truncated)", text2)
        @test length(text2) < 1000

        # Error tool result
        err_result = ToolResultMessage("c3", "bad_tool", "file not found"; is_error = true)
        text3 = Agentif.format_messages_for_summary(AgentMessage[err_result])
        @test occursin("Tool bad_tool error:", text3)
    end

    @testset "CompactionSummaryMessage serialization" begin
        using JSON
        msg = CompactionSummaryMessage(; summary = "test summary", tokens_before = 500, compacted_at = 1234567890.0)
        json_str = JSON.json(msg)
        parsed = JSON.parse(json_str)
        @test parsed["type"] == "compaction_summary"
        @test parsed["summary"] == "test summary"
        @test parsed["tokens_before"] == 500
        @test parsed["compacted_at"] == 1234567890.0

        # Round-trip through AgentMessage choosetype
        restored = JSON.parse(json_str, AgentMessage)
        @test restored isa CompactionSummaryMessage
        @test restored.summary == "test summary"
        @test restored.tokens_before == 500
    end

    @testset "session compaction entry" begin
        # Normal entry appends messages
        state = AgentState()
        entry1 = SessionEntry(; messages = AgentMessage[UserMessage("hello")])
        Agentif.apply_session_entry!(state, entry1)
        @test length(state.messages) == 1

        entry2 = SessionEntry(; messages = AgentMessage[
            AssistantMessage(; provider = "t", api = "t", model = "t"),
            UserMessage("followup"),
        ])
        Agentif.apply_session_entry!(state, entry2)
        @test length(state.messages) == 3

        # Compaction entry resets messages
        compaction_msg = CompactionSummaryMessage(; summary = "summary of prior conversation", tokens_before = 200, compacted_at = time())
        compaction_entry = SessionEntry(;
            messages = AgentMessage[compaction_msg, UserMessage("recent message")],
            is_compaction = true,
        )
        Agentif.apply_session_entry!(state, compaction_entry)
        @test length(state.messages) == 2
        @test state.messages[1] isa CompactionSummaryMessage
        @test state.messages[2] isa UserMessage
        @test message_text(state.messages[2]) == "recent message"

        # Subsequent normal entry appends after compaction
        entry3 = SessionEntry(; messages = AgentMessage[UserMessage("after compaction")])
        Agentif.apply_session_entry!(state, entry3)
        @test length(state.messages) == 3
        @test state.messages[1] isa CompactionSummaryMessage
        @test message_text(state.messages[3]) == "after compaction"
    end

    @testset "session_middleware writes compaction entry" begin
        store = InMemorySessionStore()
        # Base handler that sets last_compaction flag (simulating compact! having run)
        base_handler = function (f, agent::Agent, state::AgentState, input::Agentif.AgentTurnInput, abort::Agentif.Abort; kw...)
            # Simulate compaction having happened
            compaction_msg = CompactionSummaryMessage(; summary = "compacted", tokens_before = 100, compacted_at = time())
            empty!(state.messages)
            push!(state.messages, compaction_msg)
            push!(state.messages, UserMessage("kept"))
            state.last_compaction = compaction_msg
            # Also add the assistant response
            msg = AssistantMessage(; provider = "test", api = "test", model = "test")
            Agentif.append_text!(msg, "response")
            Agentif.append_state!(state, input, msg, Usage())
            state.pending_tool_calls = Agentif.PendingToolCall[]
            state.most_recent_stop_reason = :stop
            return state
        end
        handler = session_middleware(base_handler, store)
        agent = make_agent()
        state = AgentState()
        result = handler(identity, agent, state, "hello", Abort())
        sid = result.session_id

        # Verify compaction entry was written
        entries = session_entries(store, sid)
        @test length(entries) == 1
        @test entries[1].is_compaction == true
        @test entries[1].messages[1] isa CompactionSummaryMessage

        # Verify last_compaction was cleared
        @test result.last_compaction === nothing

        # Loading session should produce the compacted state
        loaded = load_session(store, sid)
        @test loaded.messages[1] isa CompactionSummaryMessage
        @test loaded.messages[1].summary == "compacted"
    end

    @testset "compaction_middleware passthrough" begin
        # When compaction not needed, middleware should pass through transparently
        call_counter = Ref(0)
        inputs = Agentif.AgentTurnInput[]
        base_handler = make_base_handler(; call_counter, inputs)
        config = CompactionConfig(; enabled = true, reserve_tokens = 100, keep_recent_tokens = 100)
        handler = compaction_middleware(base_handler, config)
        agent = make_agent()
        state = AgentState()
        result = handler(identity, agent, state, "hello", Abort())
        @test call_counter[] == 1
        @test result.most_recent_stop_reason == :stop
    end

    @testset "compaction_middleware disabled" begin
        call_counter = Ref(0)
        base_handler = make_base_handler(; call_counter)
        config = CompactionConfig(; enabled = false)
        handler = compaction_middleware(base_handler, config)
        agent = make_agent()
        state = AgentState()
        result = handler(identity, agent, state, "hello", Abort())
        @test call_counter[] == 1
    end

    @testset "compaction_middleware tracks input tokens" begin
        # Base handler that reports usage with specific input token counts
        call_count = Ref(0)
        base_handler = function (f, agent::Agent, state::AgentState, input::Agentif.AgentTurnInput, abort::Agentif.Abort; kw...)
            call_count[] += 1
            msg = AssistantMessage(; provider = "test", api = "test", model = "test")
            Agentif.append_text!(msg, "response $(call_count[])")
            # Report input usage that simulates growing context
            usage = Usage(; input = 5000 * call_count[], output = 100, total = 5000 * call_count[] + 100)
            Agentif.append_state!(state, input, msg, usage)
            state.pending_tool_calls = Agentif.PendingToolCall[]
            state.most_recent_stop_reason = :stop
            return state
        end

        # contextWindow=1 in dummy_model, so threshold = 1 - 16384 < 0
        # This means compaction would always trigger after first call
        # Use a model with a realistic context window
        model = Model(
            id = "test-model", name = "test-model", api = "openai-completions",
            provider = "test", baseUrl = "http://localhost", reasoning = false,
            input = ["text"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 100000, maxTokens = 4096,
        )
        agent = Agent(; id = "a", prompt = "test", model, apikey = "k")
        config = CompactionConfig(; enabled = true, reserve_tokens = 16384, keep_recent_tokens = 5000)
        handler = compaction_middleware(base_handler, config)

        # First call: no previous tokens, should not compact
        state = AgentState()
        result = handler(identity, agent, state, "hello", Abort(); model)
        @test call_count[] == 1
        # state.usage.input should now be 5000

        # Second call: last_input_tokens=5000, threshold=100000-16384=83616
        # 5000 < 83616, so no compaction
        result = handler(identity, agent, result, "world", Abort(); model)
        @test call_count[] == 2
        # state.usage.input should now be 5000+10000=15000
    end

    @testset "CompactionConfig defaults" begin
        config = CompactionConfig()
        @test config.enabled == true
        @test config.reserve_tokens == 16384
        @test config.keep_recent_tokens == 20000
    end
end

@testset "skills_middleware" begin
    meta = SkillMetadata(
        "demo",
        "demo skill",
        nothing,
        nothing,
        Dict{String, String}(),
        nothing,
        "/tmp/demo",
        "/tmp/demo/SKILL.md",
    )
    registry = SkillRegistry(Dict("demo" => meta), Dict{String, String}())
    prompt_seen = Ref("")
    base_handler = function (f, agent::Agent, state::AgentState, current_input::Agentif.AgentTurnInput, abort::Agentif.Abort; kw...)
        prompt_seen[] = agent.prompt
        msg = AssistantMessage(; provider = "test", api = "test", model = "test")
        Agentif.append_state!(state, current_input, msg, Usage())
        state.pending_tool_calls = Agentif.PendingToolCall[]
        state.most_recent_stop_reason = :stop
        return state
    end
    handler = skills_middleware(base_handler, registry)
    agent = make_agent(; prompt = "base")
    state = AgentState()
    handler(identity, agent, state, "hello", Abort())
    @test occursin("<available_skills>", prompt_seen[])
end
