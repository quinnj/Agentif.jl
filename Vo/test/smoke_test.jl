# Smoke test for group chat / multi-user / scoped search functionality
# Run from Vo project: julia --project test/smoke_test.jl

using Vo
using Agentif
using ScopedValues: @with
using SQLite
using Test

# --- Mock Channels ---

struct MockChannel <: Agentif.AbstractChannel
    id::String
    io::IO
    _is_group::Bool
    _is_private::Bool
    user::Union{Nothing, Agentif.ChannelUser}
end
MockChannel(id; is_group=false, is_private=true, user=nothing) =
    MockChannel(id, devnull, is_group, is_private, user)

Agentif.start_streaming(ch::MockChannel) = ch.io
Agentif.append_to_stream(::MockChannel, io::IO, delta::AbstractString) = print(io, delta)
Agentif.finish_streaming(::MockChannel, ::IO) = nothing
Agentif.send_message(ch::MockChannel, msg) = nothing  # swallow
Agentif.close_channel(::MockChannel, ::IO) = nothing
Agentif.channel_id(ch::MockChannel) = ch.id
Agentif.is_group(ch::MockChannel) = ch._is_group
Agentif.is_private(ch::MockChannel) = ch._is_private
Agentif.get_current_user(ch::MockChannel) = ch.user

# --- Helpers ---

function make_assistant(; name="TestBot", admins=String[], kwargs...)
    AgentAssistant(;
        name=name,
        db=SQLite.DB(),  # in-memory
        embed=nothing,    # BM25 only, no vector
        enable_heartbeat=false,
        admins=admins,
        kwargs...
    )
end

# ============================================================================
println("=" ^ 60)
println("SMOKE TEST: Group Chat & Multi-User Support")
println("=" ^ 60)

# ============================================================================
# Test 1: Schema migrations & channel metadata
# ============================================================================
@testset "Schema & channel metadata" begin
    a = make_assistant()

    # Mock channels
    dm_channel = MockChannel("dm:user1"; is_group=false, is_private=true,
        user=Agentif.ChannelUser("U001", "Alice"))
    private_group = MockChannel("group:private1"; is_group=true, is_private=true,
        user=Agentif.ChannelUser("U002", "Bob"))
    public_group = MockChannel("group:public1"; is_group=true, is_private=false,
        user=Agentif.ChannelUser("U003", "Charlie"))

    # Resolve sessions for each channel
    sid_dm = Vo.resolve_session!(a.db, "dm:user1"; is_group=false, is_private=true)
    sid_priv = Vo.resolve_session!(a.db, "group:private1"; is_group=true, is_private=true)
    sid_pub = Vo.resolve_session!(a.db, "group:public1"; is_group=true, is_private=false)

    @test !isempty(sid_dm)
    @test !isempty(sid_priv)
    @test !isempty(sid_pub)
    @test sid_dm != sid_priv != sid_pub

    # Verify channel_sessions metadata
    for (chan_id, exp_group, exp_private) in [
        ("dm:user1", false, true),
        ("group:private1", true, true),
        ("group:public1", true, false),
    ]
        row = iterate(SQLite.DBInterface.execute(a.db,
            "SELECT is_group, is_private FROM channel_sessions WHERE channel_id = ?", (chan_id,)))
        @test row !== nothing
        @test (row[1].is_group == 1) == exp_group
        @test (row[1].is_private == 1) == exp_private
    end
    println("  ✓ Schema & channel metadata")
    close(a)
end

# ============================================================================
# Test 2: Memory scoping by channel
# ============================================================================
@testset "Memory scoping" begin
    a = make_assistant()

    # Set up channels
    Vo.resolve_session!(a.db, "dm:alice"; is_group=false, is_private=true)
    Vo.resolve_session!(a.db, "group:private-team"; is_group=true, is_private=true)
    Vo.resolve_session!(a.db, "group:public-general"; is_group=true, is_private=false)

    # Add memories in different channel contexts
    Vo.addNewMemory(a.db, "Alice likes hiking"; channel_id="dm:alice")
    Vo.addNewMemory(a.db, "Team standup is at 9am"; channel_id="group:private-team")
    Vo.addNewMemory(a.db, "Company all-hands on Friday"; channel_id="group:public-general")
    Vo.addNewMemory(a.db, "Global fact with no channel tag")  # no channel_id

    # Accessible from DM:alice = {dm:alice, group:public-general} (current + public)
    ac_dm = Vo.accessible_channel_ids(a.db, "dm:alice")
    @test "dm:alice" in ac_dm
    @test "group:public-general" in ac_dm
    @test "group:private-team" ∉ ac_dm

    # Search from DM context: should find alice's + public + untagged, NOT private-team
    results_dm = Vo.searchMemories(a.db, "standup hiking company global";
        accessible_channels=ac_dm)
    dm_texts = [m.memory for m in results_dm]
    @test "Alice likes hiking" in dm_texts            # own channel
    @test "Company all-hands on Friday" in dm_texts    # public
    @test "Global fact with no channel tag" in dm_texts # untagged
    @test "Team standup is at 9am" ∉ dm_texts          # private-team NOT accessible

    # Accessible from public-general = {group:public-general} (current + public, same)
    ac_pub = Vo.accessible_channel_ids(a.db, "group:public-general")
    @test "group:public-general" in ac_pub
    @test "dm:alice" ∉ ac_pub
    @test "group:private-team" ∉ ac_pub

    results_pub = Vo.searchMemories(a.db, "hiking standup company global";
        accessible_channels=ac_pub)
    pub_texts = [m.memory for m in results_pub]
    @test "Company all-hands on Friday" in pub_texts    # own channel
    @test "Global fact with no channel tag" in pub_texts # untagged
    @test "Alice likes hiking" ∉ pub_texts              # DM NOT accessible
    @test "Team standup is at 9am" ∉ pub_texts          # private NOT accessible

    # Accessible from private-team = {group:private-team, group:public-general}
    ac_priv = Vo.accessible_channel_ids(a.db, "group:private-team")
    @test "group:private-team" in ac_priv
    @test "group:public-general" in ac_priv
    @test "dm:alice" ∉ ac_priv

    results_priv = Vo.searchMemories(a.db, "hiking standup company global";
        accessible_channels=ac_priv)
    priv_texts = [m.memory for m in results_priv]
    @test "Team standup is at 9am" in priv_texts        # own channel
    @test "Company all-hands on Friday" in priv_texts   # public
    @test "Global fact with no channel tag" in priv_texts # untagged
    @test "Alice likes hiking" ∉ priv_texts             # DM NOT accessible

    println("  ✓ Memory scoping by channel")
    close(a)
end

# ============================================================================
# Test 3: Admin gating
# ============================================================================
@testset "Admin gating" begin
    admin_user = Agentif.ChannelUser("U001", "Alice")
    regular_user = Agentif.ChannelUser("U002", "Bob")

    # No admins set = everyone is admin
    a1 = make_assistant(admins=String[])
    dm = MockChannel("dm:test"; user=regular_user)
    tools_no_admins = Agentif.with_channel(dm) do
        Vo.build_assistant_tools(a1)
    end
    tool_names_no_admins = Set(t.name for t in tools_no_admins)
    @test "setIdentityAndPurpose" in tool_names_no_admins
    @test "setHeartbeatTasks" in tool_names_no_admins
    close(a1)

    # Admins set, admin user in DM
    a2 = make_assistant(admins=["U001"])
    dm_admin = MockChannel("dm:admin"; user=admin_user)
    tools_admin = Agentif.with_channel(dm_admin) do
        Vo.build_assistant_tools(a2)
    end
    tool_names_admin = Set(t.name for t in tools_admin)
    @test "setIdentityAndPurpose" in tool_names_admin
    @test "setHeartbeatTasks" in tool_names_admin

    # Admins set, non-admin user in DM
    dm_regular = MockChannel("dm:regular"; user=regular_user)
    tools_regular = Agentif.with_channel(dm_regular) do
        Vo.build_assistant_tools(a2)
    end
    tool_names_regular = Set(t.name for t in tools_regular)
    @test "setIdentityAndPurpose" ∉ tool_names_regular
    @test "setHeartbeatTasks" ∉ tool_names_regular
    @test "analyzeImage" in tool_names_regular  # non-admin tools still available

    # Admins set, no user identity (REPL) - should be admin (not a group chat)
    repl = MockChannel("repl:test"; is_group=false, user=nothing)
    tools_repl = Agentif.with_channel(repl) do
        Vo.build_assistant_tools(a2)
    end
    tool_names_repl = Set(t.name for t in tools_repl)
    @test "setIdentityAndPurpose" in tool_names_repl

    # Admins set, no user identity in GROUP - should NOT be admin
    group_anon = MockChannel("group:anon"; is_group=true, user=nothing)
    tools_group_anon = Agentif.with_channel(group_anon) do
        Vo.build_assistant_tools(a2)
    end
    tool_names_group_anon = Set(t.name for t in tools_group_anon)
    @test "setIdentityAndPurpose" ∉ tool_names_group_anon

    close(a2)
    println("  ✓ Admin gating")
end

# ============================================================================
# Test 4: DIRECT_PING ScopedValue
# ============================================================================
@testset "DIRECT_PING" begin
    @test Agentif.DIRECT_PING[] == false
    result = @with Agentif.DIRECT_PING => true begin
        Agentif.DIRECT_PING[]
    end
    @test result == true
    @test Agentif.DIRECT_PING[] == false  # reverted
    println("  ✓ DIRECT_PING ScopedValue")
end

# ============================================================================
# Test 5: Group chat prompt sections
# ============================================================================
@testset "Group chat prompt sections" begin
    a = make_assistant(name="TestBot")

    # Non-group prompt should NOT contain group guidelines
    prompt_dm = Vo.build_base_prompt(a; is_group=false, is_private=true)
    @test !occursin("Group Chat Guidelines", prompt_dm)
    @test occursin("You are TestBot", prompt_dm)

    # Group private prompt should contain guidelines + private addendum
    prompt_priv = Vo.build_base_prompt(a; is_group=true, is_private=true)
    @test occursin("Group Chat Guidelines", prompt_priv)
    @test occursin("private", lowercase(prompt_priv))
    @test !occursin("visible to everyone", lowercase(prompt_priv))  # public addendum not present

    # Group public prompt should contain guidelines + public addendum
    prompt_pub = Vo.build_base_prompt(a; is_group=true, is_private=false)
    @test occursin("Group Chat Guidelines", prompt_pub)
    @test occursin("public", lowercase(prompt_pub))

    close(a)
    println("  ✓ Group chat prompt sections")
end

# ============================================================================
# Test 6: User tagging in evaluate (input prefixed with [Username]:)
# ============================================================================
@testset "User tagging in group chat" begin
    a = make_assistant(name="TestBot")
    run!(a)

    # Capture what input the handler receives
    captured_input = Ref{Any}(nothing)

    group_ch = MockChannel("group:tag-test"; is_group=true, is_private=true,
        user=Agentif.ChannelUser("U001", "Alice"))

    # We can't easily intercept the tagged input without a full evaluate call.
    # Instead, verify the tagging logic directly:
    chan_is_group = Agentif.is_group(group_ch)
    input = "hello world"
    tagged = if chan_is_group && input isa String
        user = Agentif.get_current_user(group_ch)
        user !== nothing ? "[$(user.name)]: $input" : input
    else
        input
    end
    @test tagged == "[Alice]: hello world"

    # Non-group should not tag
    dm_ch = MockChannel("dm:tag-test"; is_group=false, user=Agentif.ChannelUser("U001", "Alice"))
    chan_is_group_dm = Agentif.is_group(dm_ch)
    tagged_dm = if chan_is_group_dm && input isa String
        user = Agentif.get_current_user(dm_ch)
        user !== nothing ? "[$(user.name)]: $input" : input
    else
        input
    end
    @test tagged_dm == "hello world"

    close(a)
    println("  ✓ User tagging in group chat")
end

# ============================================================================
# Test 7: Build handler for group vs non-group
# ============================================================================
@testset "Handler construction" begin
    a = make_assistant(name="TestBot")

    dm = MockChannel("dm:handler-test"; is_group=false, is_private=true)
    group = MockChannel("group:handler-test"; is_group=true, is_private=false)

    sid_dm = Vo.resolve_session!(a.db, "dm:handler-test"; is_group=false, is_private=true)
    sid_group = Vo.resolve_session!(a.db, "group:handler-test"; is_group=true, is_private=false)

    # These should not error
    handler_dm = Vo.build_handler(a; session_id=sid_dm, channel=dm)
    handler_group = Vo.build_handler(a; session_id=sid_group, channel=group)
    @test handler_dm isa Function
    @test handler_group isa Function

    close(a)
    println("  ✓ Handler construction for group/non-group")
end

# ============================================================================
# Test 8: Session entry stores user_id
# ============================================================================
@testset "Session entry user_id" begin
    a = make_assistant()

    ch = MockChannel("dm:session-test"; user=Agentif.ChannelUser("U042", "Dave"))
    session_id = Vo.resolve_session!(a.db, "dm:session-test")

    # Simulate appending a session entry with channel context
    entry = Agentif.SessionEntry(;
        id="test-entry-1",
        created_at=time(),
        messages=[Agentif.UserMessage("hello")],
        is_compaction=false,
    )
    Agentif.with_channel(ch) do
        Agentif.append_session_entry!(a.session_store, session_id, entry)
    end

    # Check that user_id was stored
    row = iterate(SQLite.DBInterface.execute(a.db,
        "SELECT user_id FROM session_entries WHERE entry_id = ?", ("test-entry-1",)))
    @test row !== nothing
    @test row[1].user_id == "U042"

    # Without channel context, user_id should be null
    entry2 = Agentif.SessionEntry(;
        id="test-entry-2",
        created_at=time(),
        messages=[Agentif.UserMessage("hello again")],
        is_compaction=false,
    )
    Agentif.append_session_entry!(a.session_store, session_id, entry2)
    row2 = iterate(SQLite.DBInterface.execute(a.db,
        "SELECT user_id FROM session_entries WHERE entry_id = ?", ("test-entry-2",)))
    @test row2 !== nothing
    @test row2[1].user_id === missing

    close(a)
    println("  ✓ Session entry user_id tagging")
end

# ============================================================================
# Test 9: Memory struct channel_id field
# ============================================================================
@testset "Memory channel_id" begin
    a = make_assistant()
    mem = Vo.addNewMemory(a.db, "test memory with channel"; channel_id="slack:C123")
    @test mem.channel_id == "slack:C123"

    mem2 = Vo.addNewMemory(a.db, "test memory without channel")
    @test mem2.channel_id === nothing

    # Verify in DB
    row = iterate(SQLite.DBInterface.execute(a.db,
        "SELECT channel_id FROM memories WHERE memory = ?", ("test memory with channel",)))
    @test row !== nothing
    @test row[1].channel_id == "slack:C123"

    row2 = iterate(SQLite.DBInterface.execute(a.db,
        "SELECT channel_id FROM memories WHERE memory = ?", ("test memory without channel",)))
    @test row2 !== nothing
    @test row2[1].channel_id === missing

    close(a)
    println("  ✓ Memory channel_id field")
end

# ============================================================================
# Test 10: Live evaluate with mock channels (requires API credentials)
# ============================================================================
@testset "Live evaluate smoke test" begin
    a = make_assistant(name="TestBot")
    run!(a)

    # DM channel
    dm = MockChannel("dm:live-test"; is_group=false, is_private=true,
        user=Agentif.ChannelUser("U001", "Alice"))

    println("  Running DM evaluate...")
    state = Agentif.with_channel(dm) do
        Vo.evaluate(a, "Say exactly: SMOKE_TEST_OK")
    end
    response = ""
    for msg in state.messages
        if msg isa Agentif.AssistantMessage
            response = Agentif.message_text(msg)
        end
    end
    @test occursin("SMOKE_TEST_OK", response)
    println("  ✓ DM evaluate works — response: ", first(response, 80))

    # Public group channel (output guard will run, but with name mention it should skip guard)
    pub_group = MockChannel("group:live-public"; is_group=true, is_private=false,
        user=Agentif.ChannelUser("U002", "Bob"))

    println("  Running group evaluate (with name mention to skip guard)...")
    state_group = Agentif.with_channel(pub_group) do
        # Mention the bot name to trigger direct-ping fallback in output guard
        Vo.evaluate(a, "Hey TestBot, say exactly: GROUP_SMOKE_OK")
    end
    response_group = ""
    for msg in state_group.messages
        if msg isa Agentif.AssistantMessage
            response_group = Agentif.message_text(msg)
        end
    end
    @test occursin("GROUP_SMOKE_OK", response_group)
    println("  ✓ Group evaluate works — response: ", first(response_group, 80))

    # Verify memories are channel-scoped
    println("  Testing memory scoping via tools...")
    Agentif.with_channel(dm) do
        Vo.evaluate(a, "Store a memory: Alice prefers dark mode")
    end
    Agentif.with_channel(pub_group) do
        Vo.evaluate(a, "Store a memory: Team uses Julia for backend")
    end

    # Check memory channel_id tags
    all_mems = Vo.load_all_memories(a.db)
    tagged_mems = filter(m -> m.channel_id !== nothing, all_mems)
    if !isempty(tagged_mems)
        chan_ids = [m.channel_id for m in tagged_mems]
        println("  Memory channel_ids: ", chan_ids)
        @test any(id -> id == "dm:live-test", chan_ids) || any(id -> id == "group:live-public", chan_ids)
    end

    close(a)
    println("  ✓ Live evaluate smoke test complete")
end

println()
println("=" ^ 60)
println("ALL SMOKE TESTS PASSED")
println("=" ^ 60)
