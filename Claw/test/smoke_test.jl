# Smoke test for the SQLite-backed event-driven Claw architecture
# Run: julia --project=Claw Claw/test/smoke_test.jl

using Claw
using Agentif
using Logging
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

struct TestEventSource <: Claw.EventSource
    channels::Vector{Agentif.AbstractChannel}
    event_types::Vector{Claw.EventType}
    event_handlers::Vector{Claw.EventHandler}
    tools::Vector{Agentif.AgentTool}
end

Claw.get_channels(es::TestEventSource) = es.channels
Claw.get_event_types(es::TestEventSource) = es.event_types
Claw.get_event_handlers(es::TestEventSource) = es.event_handlers
Claw.get_tools(es::TestEventSource) = es.tools

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
println("SMOKE TEST: SQLite-Backed Claw Architecture")
println("=" ^ 60)

# ============================================================================
# Phase 1: Soul template + temporal anchoring
# ============================================================================
@testset "Phase 1: Soul template & system prompt" begin
    @test !isempty(Claw.SOUL_TEMPLATE)
    @test occursin("Identity, Operating Principles", Claw.SOUL_TEMPLATE)

    tz = Claw._detect_timezone()
    @test !isempty(tz)
    println("  Detected timezone: $tz")

    config = Claw.AgentConfig(
        provider="openai-completions",
        model_id="gpt-4o-mini",
        apikey="test-key",
        timezone="America/Denver",
    )
    @test config.timezone == "America/Denver"
    @test config.name === nothing

    prompt = Claw.build_system_prompt(config)
    @test occursin(Claw.SOUL_TEMPLATE, prompt)
    @test !occursin("Current date", prompt)
    context_prefix = Claw.build_context_prefix(config)
    @test occursin("Current date", context_prefix)
    @test occursin("time:", context_prefix)
    @test occursin("America/Denver", context_prefix)
    println("  System prompt length: $(length(prompt)) chars")
    println("  ✓ Phase 1 passed")
end

@testset "Logging level configuration" begin
    a_warn = AgentAssistant(":memory:";
        provider = "openai-completions",
        model_id = "gpt-4o-mini",
        apikey = "test-key",
        level = :warn,
    )
    @test a_warn.log_level == Warn

    a_default = AgentAssistant(":memory:";
        provider = "openai-completions",
        model_id = "gpt-4o-mini",
        apikey = "test-key",
    )
    @test a_default.log_level === nothing
end

# ============================================================================
# Phase 2: LLMTools gating
# ============================================================================
@testset "Phase 2: LLMTools event source tools" begin
    # Base config — no coding/web flags → only the 12 Claw wrapper tools
    cfg_base = Claw.AgentConfig(
        provider="openai-completions", model_id="gpt-4o-mini", apikey="test-key",
    )
    es_base = Claw.LLMToolsEventSource(cfg_base)
    tools_base = Claw.get_tools(es_base)
    names_base = Set(t.name for t in tools_base)
    @test length(tools_base) == 12
    # Sub-agent tools
    @test "start_subagent" in names_base
    @test "message_subagent" in names_base
    @test "list_subagents" in names_base
    @test "kill_subagent" in names_base
    # PTY tools
    @test "start_pty" in names_base
    @test "write_pty" in names_base
    @test "list_ptys" in names_base
    @test "kill_pty" in names_base
    # Worker tools
    @test "start_worker" in names_base
    @test "eval_worker" in names_base
    @test "list_workers" in names_base
    @test "kill_worker" in names_base
    println("  Base: $(length(tools_base)) tools — $names_base")

    # With coding enabled → 12 wrappers + 7 coding tools
    cfg_coding = Claw.AgentConfig(
        provider="openai-completions", model_id="gpt-4o-mini", apikey="test-key",
        enable_coding=true,
    )
    es_coding = Claw.LLMToolsEventSource(cfg_coding)
    tools_coding = Claw.get_tools(es_coding)
    names_coding = Set(t.name for t in tools_coding)
    @test "read" in names_coding
    @test "exec_command" in names_coding
    @test "start_subagent" in names_coding
    println("  enable_coding: $(length(tools_coding)) tools — $names_coding")

    # With web enabled → 12 wrappers + 2 web tools
    cfg_web = Claw.AgentConfig(
        provider="openai-completions", model_id="gpt-4o-mini", apikey="test-key",
        enable_web=true,
    )
    es_web = Claw.LLMToolsEventSource(cfg_web)
    tools_web = Claw.get_tools(es_web)
    names_web = Set(t.name for t in tools_web)
    @test "web_fetch" in names_web
    @test "web_search" in names_web
    @test "start_subagent" in names_web
    println("  enable_web: $(length(tools_web)) tools — $names_web")

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
    @test "claw_event_types" in tables
    @test "claw_event_handlers" in tables
    @test "claw_handler_event_types" in tables
    @test "claw_agent_metadata" in tables
    @test "session_entries" in tables  # from AgentifSQLiteExt
    @test "session_branches" in tables  # from AgentifSQLiteExt
    @test "tempus_jobs" in tables  # from TempusSQLiteExt
    println("  Tables: $tables")

    metadata_row = iterate(SQLite.DBInterface.execute(a.db,
        "SELECT value FROM claw_agent_metadata WHERE key = ?", ("agent_system_prompt",)))
    @test metadata_row !== nothing
    @test metadata_row[1].value == Claw.SOUL_TEMPLATE

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
    Claw.CURRENT_ASSISTANT[] = a

    # Register mock channels via event source
    ch1 = MockChannel("slack-general"; is_group=true, is_private=false)
    ch2 = MockChannel("dm-alice"; is_group=false, is_private=true)
    et1 = Claw.EventType("message", "A chat message")
    eh1 = Claw.EventHandler("msg_handler", ["message"], "Respond helpfully", "slack-general")

    es = TestEventSource(
        Agentif.AbstractChannel[ch1, ch2],
        Claw.EventType[et1],
        Claw.EventHandler[eh1],
        Agentif.AgentTool[],
    )
    Claw.register_event_source!(a, es)

    append!(a.tools, Claw.MANAGEMENT_TOOLS)
    append!(a.tools, Claw.TEMPUS_TOOLS)

    # Verify data in SQLite / runtime registry
    @test length(a._channels) == 2
    @test count_rows(a.db, "claw_event_types") == 1
    @test count_rows(a.db, "claw_event_handlers") == 1

    # Test list_channels (reads from runtime _channels dict)
    result = Claw.list_channels()
    @test occursin("slack-general", result)
    @test occursin("dm-alice", result)
    @test occursin("group", result)
    @test occursin("public", result)
    @test occursin("private", result)
    println("  list_channels:\n$result")

    # Test list_event_types
    result_et = Claw.list_event_types()
    @test occursin("message", result_et)
    println("  list_event_types: $result_et")

    # Test list_event_handlers
    result_eh = Claw.list_event_handlers()
    @test occursin("msg_handler", result_eh)
    @test occursin("slack-general", result_eh)
    @test occursin("Respond helpfully", result_eh)
    println("  list_event_handlers:\n$result_eh")

    # Test get/set system prompt tools
    result_prompt = Claw.get_system_prompt()
    @test result_prompt == Claw.SOUL_TEMPLATE
    custom_prompt = "You are Claw. Prioritize concise, direct responses."
    result_set_prompt = Claw.set_system_prompt(custom_prompt)
    @test occursin("updated", result_set_prompt)
    @test Claw.get_system_prompt() == custom_prompt
    println("  set_system_prompt: $result_set_prompt")

    # Test add_event_handler
    result_add = Claw.add_event_handler("new_handler", "message", "Do something", "dm-alice")
    @test occursin("registered", result_add)
    @test count_rows(a.db, "claw_event_handlers") == 2
    result_eh2 = Claw.list_event_handlers()
    @test occursin("new_handler", result_eh2)
    @test occursin("dm-alice", result_eh2)
    println("  add_event_handler: $result_add")

    # Test add_event_handler with unknown event type
    result_bad_et = Claw.add_event_handler("bad", "nonexistent", "x", "dm-alice")
    @test occursin("Unknown event type", result_bad_et)

    # Test add_event_handler with unknown channel
    result_bad_ch = Claw.add_event_handler("bad2", "message", "x", "fake-channel")
    @test occursin("Unknown channel", result_bad_ch)

    # Test add_event_handler without channel_id (evaluate-only)
    result_no_ch = Claw.add_event_handler("bg-logger", "message", "Log this event")
    @test occursin("registered", result_no_ch)
    @test occursin("evaluate only", result_no_ch)
    @test count_rows(a.db, "claw_event_handlers") == 3
    Claw.remove_event_handler("bg-logger")
    @test count_rows(a.db, "claw_event_handlers") == 2
    println("  add_event_handler (no channel): $result_no_ch")

    # Test remove_event_handler
    result_rm = Claw.remove_event_handler("new_handler")
    @test occursin("removed", result_rm)
    @test count_rows(a.db, "claw_event_handlers") == 1
    result_eh3 = Claw.list_event_handlers()
    @test !occursin("new_handler", result_eh3)
    println("  remove_event_handler: $result_rm")

    # Unregister unknown ID is a no-op (shouldn't error)
    Claw.unregister_event_handler!(a, "nonexistent_id")
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
    Claw.CURRENT_ASSISTANT[] = a

    # Register a mock channel (via event source so it's in SQLite)
    ch = MockChannel("slack-general"; is_group=true, is_private=false)
    es = TestEventSource(
        Agentif.AbstractChannel[ch],
        Claw.EventType[],
        Claw.EventHandler[],
        Agentif.AgentTool[],
    )
    Claw.register_event_source!(a, es)
    append!(a.tools, Claw.TEMPUS_TOOLS)

    # Test list_jobs (empty)
    result_empty = Claw.list_jobs()
    @test occursin("No scheduled jobs", result_empty)
    println("  list_jobs (empty): $result_empty")

    # Test add_job
    result_add = Claw.add_job("morning-standup", "0 9 * * *", "Good morning team!", "slack-general", nothing)
    @test occursin("scheduled", result_add)
    @test occursin("slack-general", result_add)
    @test occursin("America/Denver", result_add)
    println("  add_job: $result_add")

    # Verify event type was created in SQLite
    et_result = iterate(SQLite.DBInterface.execute(a.db,
        "SELECT 1 FROM claw_event_types WHERE name = ?", ("tempus_job:morning-standup",)))
    @test et_result !== nothing

    # Verify event handler was created in SQLite
    eh_result = iterate(SQLite.DBInterface.execute(a.db,
        "SELECT prompt, channel_id FROM claw_event_handlers WHERE id = ?", ("tempus_job:morning-standup",)))
    @test eh_result !== nothing
    @test eh_result[1].prompt == "Good morning team!"
    @test eh_result[1].channel_id == "slack-general"

    # Verify job was added to scheduler
    jobs = Tempus.getJobs(a.scheduler.store)
    @test length(jobs) == 1
    job = first(jobs)
    @test job.name == "morning-standup"

    # Test list_jobs (non-empty)
    result_list = Claw.list_jobs()
    @test occursin("morning-standup", result_list)
    println("  list_jobs: $result_list")

    # Test add_job with explicit timezone
    result_tz = Claw.add_job("evening-review", "0 17 * * 1-5", "Time to review!", "slack-general", "America/Los_Angeles")
    @test occursin("America/Los_Angeles", result_tz)
    println("  add_job (explicit tz): $result_tz")

    # Test add_job with unknown channel
    result_bad = Claw.add_job("bad-job", "0 * * * *", "nope", "fake-channel", nothing)
    @test occursin("Unknown channel", result_bad)

    # Test remove_job
    result_rm = Claw.remove_job("morning-standup")
    @test occursin("removed", result_rm)
    # Event type should be removed
    et_after = iterate(SQLite.DBInterface.execute(a.db,
        "SELECT 1 FROM claw_event_types WHERE name = ?", ("tempus_job:morning-standup",)))
    @test et_after === nothing
    # Event handler should be removed
    eh_after = iterate(SQLite.DBInterface.execute(a.db,
        "SELECT 1 FROM claw_event_handlers WHERE id = ?", ("tempus_job:morning-standup",)))
    @test eh_after === nothing
    println("  remove_job: $result_rm")

    println("  ✓ Phase 4 passed")
end

# ============================================================================
# Event system: make_prompt, TempusJobEvent, get_channel dispatch
# ============================================================================
@testset "Event system" begin
    @test Claw.make_prompt("Do X", Claw.TempusJobEvent("test")) == "Do X"

    struct TestContentEvent <: Claw.Event
        content::String
    end
    Claw.get_name(::TestContentEvent) = "test"
    Claw.event_content(e::TestContentEvent) = e.content

    @test Claw.make_prompt("", TestContentEvent("hello")) == "hello"
    @test Claw.make_prompt("Prompt", TestContentEvent("content")) == "Prompt\n\nEvent content:\n\ncontent"
    @test Claw.make_prompt("", TestContentEvent("")) == ""

    # TempusJobEvent
    ev = Claw.TempusJobEvent("tempus_job:test")
    @test Claw.get_name(ev) == "tempus_job:test"
    @test Claw.event_content(ev) == ""

    # get_channel dispatch: ChannelEvent carries its own channel
    repl_ev = Claw.ReplInputEvent("hi", Claw.ReplChannel())
    @test Claw.get_channel(repl_ev) isa Claw.ReplChannel

    println("  ✓ Event system passed")
end

# ============================================================================
# Session helper
# ============================================================================
@testset "Session store branch API" begin
    a = make_test_assistant()
    store = a.session_store

    # Append entries and set branch leaf
    Agentif.append_entry!(store, Agentif.SessionEntry(; id="e1", messages=Agentif.AgentMessage[Agentif.UserMessage("hello")]))
    Agentif.set_branch_leaf!(store, "branch-1", "e1")
    @test Agentif.get_branch_leaf(store, "branch-1") == "e1"

    # Different branch has no leaf
    @test Agentif.get_branch_leaf(store, "branch-2") === nothing

    # Load branch returns the state
    state = Agentif.load_branch(store, "branch-1")
    @test length(state.messages) == 1

    println("  ✓ Session store branch API passed")
end

# ============================================================================
# Constructor + tool registration
# ============================================================================
@testset "Constructor & tool registration" begin
    a = make_test_assistant()
    @test length(a.tools) == 0
    @test a.config.timezone == "America/Denver"
    @test a.config.name === nothing

    append!(a.tools, Claw.MANAGEMENT_TOOLS)
    append!(a.tools, Claw.TEMPUS_TOOLS)
    @test length(a.tools) == length(Claw.MANAGEMENT_TOOLS) + length(Claw.TEMPUS_TOOLS)

    tool_names = Set(t.name for t in a.tools)
    @test "list_channels" in tool_names
    @test "list_event_types" in tool_names
    @test "list_event_handlers" in tool_names
    @test "get_system_prompt" in tool_names
    @test "set_system_prompt" in tool_names
    @test "add_event_handler" in tool_names
    @test "remove_event_handler" in tool_names
    @test "list_jobs" in tool_names
    @test "add_job" in tool_names
    @test "remove_job" in tool_names
    println("  All 10 management+tempus tools: $tool_names")

    # With coding enabled via LLMToolsEventSource
    a2 = AgentAssistant(":memory:";
        provider="openai-completions", model_id="gpt-4o-mini", apikey="test-key",
        enable_coding=true,
    )
    llm_es = Claw.LLMToolsEventSource(a2.config)
    Claw.register_event_source!(a2, llm_es)
    # 12 wrapper tools + 7 coding tools = 19
    @test length(a2.tools) == 19
    tool_names2 = Set(t.name for t in a2.tools)
    @test "start_subagent" in tool_names2
    @test "read" in tool_names2
    @test "exec_command" in tool_names2
    append!(a2.tools, Claw.MANAGEMENT_TOOLS)
    append!(a2.tools, Claw.TEMPUS_TOOLS)
    @test length(a2.tools) == 19 + 7 + 3
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
    et1 = Claw.EventType("evt1", "Event 1")
    et2 = Claw.EventType("evt2", "Event 2")
    eh1 = Claw.EventHandler("h1", ["evt1"], "prompt1", "ch1")

    es = TestEventSource(
        Agentif.AbstractChannel[ch1, ch2],
        Claw.EventType[et1, et2],
        Claw.EventHandler[eh1],
        Agentif.AgentTool[],
    )
    Claw.register_event_source!(a, es)

    @test length(a._channels) == 2
    @test count_rows(a.db, "claw_event_types") == 2
    @test count_rows(a.db, "claw_event_handlers") == 1

    # Registering same source again: channels update in-place, INSERT OR IGNORE for types, REPLACE for handlers
    Claw.register_event_source!(a, es)
    @test length(a._channels) == 2  # no duplication
    @test count_rows(a.db, "claw_event_types") == 2  # no duplication
    @test count_rows(a.db, "claw_event_handlers") == 1  # upsert, not duplicate

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
    Claw.CURRENT_ASSISTANT[] = a1

    ch = MockChannel("slack-general"; is_group=true, is_private=false)
    es = TestEventSource(
        Agentif.AbstractChannel[ch],
        Claw.EventType[Claw.EventType("message", "A chat message")],
        Claw.EventHandler[Claw.EventHandler("es_handler", ["message"], "from source", "slack-general")],
        Agentif.AgentTool[],
    )
    Claw.register_event_source!(a1, es)
    append!(a1.tools, Claw.MANAGEMENT_TOOLS)

    # Agent creates a handler (simulating tool call)
    Claw.add_event_handler("user_handler", "message", "user-created", "slack-general")
    @test count_rows(a1.db, "claw_event_handlers") == 2
    @test length(a1._channels) == 1
    @test count_rows(a1.db, "claw_event_types") == 1

    # Close first db to release lock, simulating process exit
    close(a1.db)

    # Second init with same db_path: simulates restart
    a2 = AgentAssistant(db_path;
        provider="openai-completions", model_id="gpt-4o-mini", apikey="test-key",
        timezone="America/Denver",
    )
    Claw.CURRENT_ASSISTANT[] = a2

    # Purge ephemeral tables (as init! does)
    SQLite.DBInterface.execute(a2.db, "DELETE FROM claw_event_types")

    @test isempty(a2._channels)  # fresh instance, no channels registered yet
    @test count_rows(a2.db, "claw_event_types") == 0  # purged
    # Handlers survive the purge!
    @test count_rows(a2.db, "claw_event_handlers") == 2

    # Re-register event source
    ch2 = MockChannel("slack-general"; is_group=true, is_private=false)
    es2 = TestEventSource(
        Agentif.AbstractChannel[ch2],
        Claw.EventType[Claw.EventType("message", "A chat message")],
        Claw.EventHandler[Claw.EventHandler("es_handler", ["message"], "from source", "slack-general")],
        Agentif.AgentTool[],
    )
    Claw.register_event_source!(a2, es2)

    @test length(a2._channels) == 1  # re-populated
    @test count_rows(a2.db, "claw_event_types") == 1  # re-populated
    @test count_rows(a2.db, "claw_event_handlers") == 2  # both still there

    # Verify user-created handler persisted
    append!(a2.tools, Claw.MANAGEMENT_TOOLS)
    result = Claw.list_event_handlers()
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
    repl = Claw.ReplEventSource()
    channels = Claw.get_channels(repl)
    @test length(channels) == 1
    @test channels[1] isa Claw.ReplChannel
    @test Agentif.channel_id(channels[1]) == "repl"

    event_types = Claw.get_event_types(repl)
    @test length(event_types) == 1
    @test event_types[1].name == "repl_input"

    event_handlers = Claw.get_event_handlers(repl)
    @test length(event_handlers) == 1
    @test event_handlers[1].id == "repl_default"
    @test event_handlers[1].event_types == ["repl_input"]

    # ReplInputEvent
    ch = Claw.ReplChannel()
    ev = Claw.ReplInputEvent("hello world", ch)
    @test Claw.get_name(ev) == "repl_input"
    @test Claw.get_channel(ev) === ch
    @test Claw.event_content(ev) == "hello world"

    # close_channel must notify completion so a"..." never hangs when an
    # evaluation errors out before finish_streaming runs.
    ch2 = Claw.ReplChannel()
    Agentif.close_channel(ch2)
    waiter = @async wait(ch2.completion)
    @test timedwait(() -> istaskdone(waiter), 5.0) == :ok

    println("  ✓ REPL EventSource passed")
end

println()
println("=" ^ 60)
println("ALL SMOKE TESTS PASSED")
println("=" ^ 60)
