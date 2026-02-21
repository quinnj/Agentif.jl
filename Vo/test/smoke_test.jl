# Smoke test for the SQLite-backed event-driven Vo architecture
# Run: julia --project=Vo Vo/test/smoke_test.jl

using Vo
using Agentif
using SQLite
using Tempus
using Test

# ─── Mock Channel ───

struct MockChannel <: Agentif.AbstractChannel
    id::String
    _is_group::Bool
    _is_private::Bool
end
MockChannel(id; is_group=false, is_private=true) = MockChannel(id, is_group, is_private)

Agentif.channel_id(ch::MockChannel) = ch.id
Agentif.is_group(ch::MockChannel) = ch._is_group
Agentif.is_private(ch::MockChannel) = ch._is_private
Agentif.start_streaming(::MockChannel) = nothing
Agentif.append_to_stream(::MockChannel, ::AbstractString) = nothing
Agentif.finish_streaming(::MockChannel) = nothing
Agentif.send_message(::MockChannel, msg) = nothing
Agentif.close_channel(::MockChannel) = nothing

# ─── Mock EventSource ───

struct TestEventSource <: Vo.EventSource
    channels::Vector{Agentif.AbstractChannel}
    event_types::Vector{Vo.EventType}
    event_handlers::Vector{Vo.EventHandler}
    tools::Vector{Agentif.AgentTool}
end

Vo.get_channels(es::TestEventSource) = es.channels
Vo.get_event_types(es::TestEventSource) = es.event_types
Vo.get_event_handlers(es::TestEventSource) = es.event_handlers
Vo.get_tools(es::TestEventSource) = es.tools

# ─── Helper ───

function make_test_assistant(; kwargs...)
    AgentAssistant(":memory:";
        provider="openai-completions",
        model_id="gpt-4o-mini",
        apikey="test-key",
        timezone="America/Denver",
        kwargs...
    )
end

# Helper to count rows
function count_rows(db, table)
    result = iterate(SQLite.DBInterface.execute(db, "SELECT COUNT(*) as n FROM $table"))
    return result[1].n
end

# ============================================================================
println("=" ^ 60)
println("SMOKE TEST: SQLite-Backed Vo Architecture")
println("=" ^ 60)

# ============================================================================
# Phase 1: Soul template + temporal anchoring
# ============================================================================
@testset "Phase 1: Soul template & system prompt" begin
    @test !isempty(Vo.SOUL_TEMPLATE)
    @test occursin("Vo", Vo.SOUL_TEMPLATE)

    tz = Vo._detect_timezone()
    @test !isempty(tz)
    println("  Detected timezone: $tz")

    config = Vo.AgentConfig(
        provider="openai-completions",
        model_id="gpt-4o-mini",
        apikey="test-key",
        timezone="America/Denver",
    )
    @test config.timezone == "America/Denver"
    @test config.name == "Vo"

    prompt = Vo.build_system_prompt(config)
    @test occursin(Vo.SOUL_TEMPLATE, prompt)
    @test occursin("America/Denver", prompt)
    @test occursin("Date", prompt)
    @test occursin("Time", prompt)
    println("  System prompt length: $(length(prompt)) chars")
    println("  ✓ Phase 1 passed")
end

# ============================================================================
# Phase 2: LLMTools gating
# ============================================================================
@testset "Phase 2: LLMTools tool gating" begin
    cfg_none = Vo.AgentConfig(
        provider="openai-completions", model_id="gpt-4o-mini", apikey="test-key",
    )
    tools_none = Vo._build_llmtools(cfg_none)
    @test length(tools_none) == 0
    println("  No flags: $(length(tools_none)) tools")

    cfg_coding = Vo.AgentConfig(
        provider="openai-completions", model_id="gpt-4o-mini", apikey="test-key",
        enable_coding=true,
    )
    tools_coding = Vo._build_llmtools(cfg_coding)
    @test length(tools_coding) == 7
    names_coding = Set(t.name for t in tools_coding)
    @test "read" in names_coding
    @test "exec_command" in names_coding
    println("  enable_coding: $(length(tools_coding)) tools — $names_coding")

    cfg_term = Vo.AgentConfig(
        provider="openai-completions", model_id="gpt-4o-mini", apikey="test-key",
        enable_terminal=true,
    )
    tools_term = Vo._build_llmtools(cfg_term)
    @test length(tools_term) == 4
    println("  enable_terminal: $(length(tools_term)) tools")

    cfg_ww = Vo.AgentConfig(
        provider="openai-completions", model_id="gpt-4o-mini", apikey="test-key",
        enable_web=true, enable_workers=true,
    )
    tools_ww = Vo._build_llmtools(cfg_ww)
    @test length(tools_ww) == 6
    names_ww = Set(t.name for t in tools_ww)
    @test "web_fetch" in names_ww
    @test "web_search" in names_ww
    println("  enable_web+workers: $(length(tools_ww)) tools — $names_ww")

    println("  ✓ Phase 2 passed")
end

# ============================================================================
# SQLite schema & constructor
# ============================================================================
@testset "SQLite schema & constructor" begin
    a = make_test_assistant()

    # Verify tables exist
    tables = Set{String}()
    for row in SQLite.DBInterface.execute(a.db, "SELECT name FROM sqlite_master WHERE type='table'")
        push!(tables, row.name)
    end
    @test "vo_channels" in tables
    @test "vo_event_types" in tables
    @test "vo_event_handlers" in tables
    @test "vo_handler_event_types" in tables
    @test "vo_sessions" in tables
    @test "session_entries" in tables  # from AgentifSQLiteExt
    @test "tempus_jobs" in tables  # from TempusSQLiteExt
    println("  Tables: $tables")

    # Verify session store is SQLite-backed
    @test nameof(typeof(a.session_store)) === :SQLiteSessionStore

    # Verify scheduler uses SQLite store
    @test a.scheduler.store isa Tempus.SQLiteStore

    println("  ✓ SQLite schema & constructor passed")
end

# ============================================================================
# Phase 3: Management tools
# ============================================================================
@testset "Phase 3: Management tools" begin
    a = make_test_assistant()
    Vo.CURRENT_ASSISTANT[] = a

    # Register mock channels via event source
    ch1 = MockChannel("slack-general"; is_group=true, is_private=false)
    ch2 = MockChannel("dm-alice"; is_group=false, is_private=true)
    et1 = Vo.EventType("message", "A chat message")
    eh1 = Vo.EventHandler("msg_handler", ["message"], "Respond helpfully", "slack-general")

    es = TestEventSource(
        Agentif.AbstractChannel[ch1, ch2],
        Vo.EventType[et1],
        Vo.EventHandler[eh1],
        Agentif.AgentTool[],
    )
    Vo.register_event_source!(a, es)

    append!(a.tools, Vo.MANAGEMENT_TOOLS)
    append!(a.tools, Vo.TEMPUS_TOOLS)

    # Verify data in SQLite
    @test count_rows(a.db, "vo_channels") == 2
    @test count_rows(a.db, "vo_event_types") == 1
    @test count_rows(a.db, "vo_event_handlers") == 1

    # Test list_channels (reads from SQLite)
    result = Vo.list_channels()
    @test occursin("slack-general", result)
    @test occursin("dm-alice", result)
    @test occursin("MockChannel", result)
    @test occursin("group", result)
    @test occursin("public", result)
    @test occursin("private", result)
    println("  list_channels:\n$result")

    # Test list_event_types
    result_et = Vo.list_event_types()
    @test occursin("message", result_et)
    println("  list_event_types: $result_et")

    # Test list_event_handlers
    result_eh = Vo.list_event_handlers()
    @test occursin("msg_handler", result_eh)
    @test occursin("slack-general", result_eh)
    @test occursin("Respond helpfully", result_eh)
    println("  list_event_handlers:\n$result_eh")

    # Test add_event_handler
    result_add = Vo.add_event_handler("new_handler", "message", "Do something", "dm-alice")
    @test occursin("registered", result_add)
    @test count_rows(a.db, "vo_event_handlers") == 2
    result_eh2 = Vo.list_event_handlers()
    @test occursin("new_handler", result_eh2)
    @test occursin("dm-alice", result_eh2)
    println("  add_event_handler: $result_add")

    # Test add_event_handler with unknown event type
    result_bad_et = Vo.add_event_handler("bad", "nonexistent", "x", nothing)
    @test occursin("Unknown event type", result_bad_et)

    # Test add_event_handler with unknown channel
    result_bad_ch = Vo.add_event_handler("bad2", "message", "x", "fake-channel")
    @test occursin("Unknown channel", result_bad_ch)

    # Test remove_event_handler
    result_rm = Vo.remove_event_handler("new_handler")
    @test occursin("removed", result_rm)
    @test count_rows(a.db, "vo_event_handlers") == 1
    result_eh3 = Vo.list_event_handlers()
    @test !occursin("new_handler", result_eh3)
    println("  remove_event_handler: $result_rm")

    # Unregister unknown ID is a no-op (shouldn't error)
    Vo.unregister_event_handler!(a, "nonexistent_id")
    println("  unregister unknown ID: no error (good)")

    # Verify _channels runtime registry
    @test haskey(a._channels, "slack-general")
    @test haskey(a._channels, "dm-alice")
    @test a._channels["slack-general"] === ch1

    println("  ✓ Phase 3 passed")
end

# ============================================================================
# Phase 4: Tempus tools
# ============================================================================
@testset "Phase 4: Tempus tools" begin
    a = make_test_assistant()
    Vo.CURRENT_ASSISTANT[] = a

    # Register a mock channel (via event source so it's in SQLite)
    ch = MockChannel("slack-general"; is_group=true, is_private=false)
    es = TestEventSource(
        Agentif.AbstractChannel[ch],
        Vo.EventType[],
        Vo.EventHandler[],
        Agentif.AgentTool[],
    )
    Vo.register_event_source!(a, es)
    append!(a.tools, Vo.TEMPUS_TOOLS)

    # Test list_jobs (empty)
    result_empty = Vo.list_jobs()
    @test occursin("No scheduled jobs", result_empty)
    println("  list_jobs (empty): $result_empty")

    # Test add_job
    result_add = Vo.add_job("morning-standup", "0 9 * * *", "Good morning team!", "slack-general", nothing)
    @test occursin("scheduled", result_add)
    @test occursin("slack-general", result_add)
    @test occursin("America/Denver", result_add)
    println("  add_job: $result_add")

    # Verify event type was created in SQLite
    et_result = iterate(SQLite.DBInterface.execute(a.db,
        "SELECT 1 FROM vo_event_types WHERE name = ?", ("tempus_job:morning-standup",)))
    @test et_result !== nothing

    # Verify event handler was created in SQLite
    eh_result = iterate(SQLite.DBInterface.execute(a.db,
        "SELECT prompt, channel_id FROM vo_event_handlers WHERE id = ?", ("tempus_job:morning-standup",)))
    @test eh_result !== nothing
    @test eh_result[1].prompt == "Good morning team!"
    @test eh_result[1].channel_id == "slack-general"

    # Verify job was added to scheduler
    jobs = Tempus.getJobs(a.scheduler.store)
    @test length(jobs) == 1
    job = first(jobs)
    @test job.name == "morning-standup"

    # Test list_jobs (non-empty)
    result_list = Vo.list_jobs()
    @test occursin("morning-standup", result_list)
    println("  list_jobs: $result_list")

    # Test add_job with explicit timezone
    result_tz = Vo.add_job("evening-review", "0 17 * * 1-5", "Time to review!", "slack-general", "America/Los_Angeles")
    @test occursin("America/Los_Angeles", result_tz)
    println("  add_job (explicit tz): $result_tz")

    # Test add_job with unknown channel
    result_bad = Vo.add_job("bad-job", "0 * * * *", "nope", "fake-channel", nothing)
    @test occursin("Unknown channel", result_bad)

    # Test remove_job
    result_rm = Vo.remove_job("morning-standup")
    @test occursin("removed", result_rm)
    # Event type should be removed
    et_after = iterate(SQLite.DBInterface.execute(a.db,
        "SELECT 1 FROM vo_event_types WHERE name = ?", ("tempus_job:morning-standup",)))
    @test et_after === nothing
    # Event handler should be removed
    eh_after = iterate(SQLite.DBInterface.execute(a.db,
        "SELECT 1 FROM vo_event_handlers WHERE id = ?", ("tempus_job:morning-standup",)))
    @test eh_after === nothing
    println("  remove_job: $result_rm")

    println("  ✓ Phase 4 passed")
end

# ============================================================================
# Event system: make_prompt, TempusJobEvent, get_channel dispatch
# ============================================================================
@testset "Event system" begin
    @test Vo.make_prompt("Do X", Vo.TempusJobEvent("test")) == "Do X"

    struct TestContentEvent <: Vo.Event
        content::String
    end
    Vo.get_name(::TestContentEvent) = "test"
    Vo.event_content(e::TestContentEvent) = e.content

    @test Vo.make_prompt("", TestContentEvent("hello")) == "hello"
    @test Vo.make_prompt("Prompt", TestContentEvent("content")) == "Prompt\n\nEvent content:\n\ncontent"
    @test Vo.make_prompt("", TestContentEvent("")) == ""

    # TempusJobEvent
    ev = Vo.TempusJobEvent("tempus_job:test")
    @test Vo.get_name(ev) == "tempus_job:test"
    @test Vo.event_content(ev) == ""

    # get_channel dispatch: ChannelEvent carries its own channel
    repl_ev = Vo.ReplInputEvent("hi", Vo.ReplChannel())
    @test Vo.get_channel(repl_ev) isa Vo.ReplChannel

    println("  ✓ Event system passed")
end

# ============================================================================
# Session helper
# ============================================================================
@testset "Session helper" begin
    a = make_test_assistant()

    # First call creates a new session
    sid1 = Vo._get_or_create_session(a.db, "handler-1")
    @test !isempty(sid1)

    # Second call returns the same session
    sid2 = Vo._get_or_create_session(a.db, "handler-1")
    @test sid1 == sid2

    # Different handler gets different session
    sid3 = Vo._get_or_create_session(a.db, "handler-2")
    @test sid3 != sid1

    # Verify in SQLite
    @test count_rows(a.db, "vo_sessions") == 2

    println("  ✓ Session helper passed")
end

# ============================================================================
# Constructor + tool registration
# ============================================================================
@testset "Constructor & tool registration" begin
    a = make_test_assistant()
    @test length(a.tools) == 0
    @test a.config.timezone == "America/Denver"
    @test a.config.name == "Vo"

    append!(a.tools, Vo.MANAGEMENT_TOOLS)
    append!(a.tools, Vo.TEMPUS_TOOLS)
    @test length(a.tools) == length(Vo.MANAGEMENT_TOOLS) + length(Vo.TEMPUS_TOOLS)

    tool_names = Set(t.name for t in a.tools)
    @test "list_channels" in tool_names
    @test "list_event_types" in tool_names
    @test "list_event_handlers" in tool_names
    @test "add_event_handler" in tool_names
    @test "remove_event_handler" in tool_names
    @test "list_jobs" in tool_names
    @test "add_job" in tool_names
    @test "remove_job" in tool_names
    println("  All 8 management+tempus tools: $tool_names")

    # With coding enabled
    a2 = AgentAssistant(":memory:";
        provider="openai-completions", model_id="gpt-4o-mini", apikey="test-key",
        enable_coding=true,
    )
    @test length(a2.tools) == 7
    append!(a2.tools, Vo.MANAGEMENT_TOOLS)
    append!(a2.tools, Vo.TEMPUS_TOOLS)
    @test length(a2.tools) == 7 + 5 + 3
    println("  With coding: $(length(a2.tools)) tools total")

    println("  ✓ Constructor & tool registration passed")
end

# ============================================================================
# EventSource registration + dedup
# ============================================================================
@testset "EventSource registration" begin
    a = make_test_assistant()

    ch1 = MockChannel("ch1")
    ch2 = MockChannel("ch2")
    et1 = Vo.EventType("evt1", "Event 1")
    et2 = Vo.EventType("evt2", "Event 2")
    eh1 = Vo.EventHandler("h1", ["evt1"], "prompt1", "ch1")

    es = TestEventSource(
        Agentif.AbstractChannel[ch1, ch2],
        Vo.EventType[et1, et2],
        Vo.EventHandler[eh1],
        Agentif.AgentTool[],
    )
    Vo.register_event_source!(a, es)

    @test count_rows(a.db, "vo_channels") == 2
    @test count_rows(a.db, "vo_event_types") == 2
    @test count_rows(a.db, "vo_event_handlers") == 1

    # Registering same source again: INSERT OR IGNORE for channels/types, REPLACE for handlers
    Vo.register_event_source!(a, es)
    @test count_rows(a.db, "vo_channels") == 2  # no duplication
    @test count_rows(a.db, "vo_event_types") == 2  # no duplication
    @test count_rows(a.db, "vo_event_handlers") == 1  # upsert, not duplicate

    println("  ✓ EventSource registration passed")
end

# ============================================================================
# Purge behavior: channels + event_types purged, handlers persist
# ============================================================================
@testset "Purge behavior" begin
    # Use a temp file so we can test persistence across AgentAssistant instances
    db_path = tempname() * ".sqlite"

    # First init: register channels, event types, and an agent-created handler
    a1 = AgentAssistant(db_path;
        provider="openai-completions", model_id="gpt-4o-mini", apikey="test-key",
        timezone="America/Denver",
    )
    Vo.CURRENT_ASSISTANT[] = a1

    ch = MockChannel("slack-general"; is_group=true, is_private=false)
    es = TestEventSource(
        Agentif.AbstractChannel[ch],
        Vo.EventType[Vo.EventType("message", "A chat message")],
        Vo.EventHandler[Vo.EventHandler("es_handler", ["message"], "from source", "slack-general")],
        Agentif.AgentTool[],
    )
    Vo.register_event_source!(a1, es)
    append!(a1.tools, Vo.MANAGEMENT_TOOLS)

    # Agent creates a handler (simulating tool call)
    Vo.add_event_handler("user_handler", "message", "user-created", "slack-general")
    @test count_rows(a1.db, "vo_event_handlers") == 2
    @test count_rows(a1.db, "vo_channels") == 1
    @test count_rows(a1.db, "vo_event_types") == 1

    # Close first db to release lock, simulating process exit
    close(a1.db)

    # Second init with same db_path: simulates restart
    a2 = AgentAssistant(db_path;
        provider="openai-completions", model_id="gpt-4o-mini", apikey="test-key",
        timezone="America/Denver",
    )
    Vo.CURRENT_ASSISTANT[] = a2

    # Purge ephemeral tables (as init! does)
    SQLite.DBInterface.execute(a2.db, "DELETE FROM vo_channels")
    SQLite.DBInterface.execute(a2.db, "DELETE FROM vo_event_types")

    @test count_rows(a2.db, "vo_channels") == 0  # purged
    @test count_rows(a2.db, "vo_event_types") == 0  # purged
    # Handlers survive the purge!
    @test count_rows(a2.db, "vo_event_handlers") == 2

    # Re-register event source
    ch2 = MockChannel("slack-general"; is_group=true, is_private=false)
    es2 = TestEventSource(
        Agentif.AbstractChannel[ch2],
        Vo.EventType[Vo.EventType("message", "A chat message")],
        Vo.EventHandler[Vo.EventHandler("es_handler", ["message"], "from source", "slack-general")],
        Agentif.AgentTool[],
    )
    Vo.register_event_source!(a2, es2)

    @test count_rows(a2.db, "vo_channels") == 1  # re-populated
    @test count_rows(a2.db, "vo_event_types") == 1  # re-populated
    @test count_rows(a2.db, "vo_event_handlers") == 2  # both still there

    # Verify user-created handler persisted
    append!(a2.tools, Vo.MANAGEMENT_TOOLS)
    result = Vo.list_event_handlers()
    @test occursin("user_handler", result)
    @test occursin("user-created", result)
    @test occursin("es_handler", result)

    # Clean up temp file
    rm(db_path; force=true)
    rm(db_path * "-wal"; force=true)
    rm(db_path * "-shm"; force=true)

    println("  ✓ Purge behavior passed")
end

# ============================================================================
# REPL event source
# ============================================================================
@testset "REPL EventSource" begin
    repl = Vo.ReplEventSource()
    channels = Vo.get_channels(repl)
    @test length(channels) == 1
    @test channels[1] isa Vo.ReplChannel
    @test Agentif.channel_id(channels[1]) == "repl"

    event_types = Vo.get_event_types(repl)
    @test length(event_types) == 1
    @test event_types[1].name == "repl_input"

    event_handlers = Vo.get_event_handlers(repl)
    @test length(event_handlers) == 1
    @test event_handlers[1].id == "repl_default"
    @test event_handlers[1].event_types == ["repl_input"]

    # ReplInputEvent
    ch = Vo.ReplChannel()
    ev = Vo.ReplInputEvent("hello world", ch)
    @test Vo.get_name(ev) == "repl_input"
    @test Vo.get_channel(ev) === ch
    @test Vo.event_content(ev) == "hello world"

    println("  ✓ REPL EventSource passed")
end

println()
println("=" ^ 60)
println("ALL SMOKE TESTS PASSED")
println("=" ^ 60)
