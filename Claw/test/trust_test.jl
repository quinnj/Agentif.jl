# trust_test.jl — trust boundaries (hardening §2.1–§2.2)
#
# Negative tests are the point here. The positive assertions that matter are the
# no-regression ones: an existing handler, constructed the way every existing call
# site constructs it, must still see the full tool set.

module TrustTests

using Test
using Agentif
using Claw
using HTTP
using JSON
using Logging
using SQLite

# Load the HTTP-listening extensions so their bind-address defaults can be asserted;
# each is optional in this environment (same pattern as extensions_test.jl).
const HAS_MSTEAMS = try; @eval using MSTeams; true; catch; false; end
const HAS_TELEGRAM = try; @eval using Telegram; true; catch; false; end
const HAS_GITHUB = try; @eval using GitHub; true; catch; false; end

# ─── Fixtures ───

struct TrustChannel <: Agentif.AbstractChannel
    id::String
    group::Bool
    private::Bool
end
TrustChannel(id; group = false, private = true) = TrustChannel(id, group, private)
Agentif.channel_id(ch::TrustChannel) = ch.id
Agentif.channel_name(ch::TrustChannel) = ch.id
Agentif.is_group(ch::TrustChannel) = ch.group
Agentif.is_private(ch::TrustChannel) = ch.private
Agentif.start_streaming(::TrustChannel) = nothing
Agentif.append_to_stream(::TrustChannel, ::AbstractString) = nothing
Agentif.finish_streaming(::TrustChannel) = nothing
Agentif.send_message(::TrustChannel, _) = nothing
Agentif.close_channel(::TrustChannel) = nothing

struct TrustEvent <: Claw.ChannelEvent
    content::String
    channel::TrustChannel
end
Claw.get_name(::TrustEvent) = "trust_test_event"
Claw.get_channel(ev::TrustEvent) = ev.channel
Claw.event_content(ev::TrustEvent) = ev.content

# Stand-ins for the real thing: the JMAP/LLMTools tools may not be loadable here, but
# the policy keys off tool *names*, so same-named stubs exercise the same code path.
const EMAIL_SEND_TOOL = Agentif.@tool "Send an email." function email_send(to::String)
    return "sent to $to"
end
const EMAIL_SEARCH_TOOL = Agentif.@tool "Search email." function email_search(q::String)
    return "results for $q"
end
const EXEC_COMMAND_TOOL = Agentif.@tool "Run a shell command." function exec_command(cmd::String)
    return "ran $cmd"
end
const UNKNOWN_CUSTOM_TOOL = Agentif.@tool "A deployment-specific mutation." function custom_mutation(value::String)
    return value
end
const LATE_TOOL = Agentif.@tool "A tool registered after resolution." function late_tool()
    return "late"
end

# A registered stub model so `evaluate` can build an Agent without reaching a
# provider; the stub `base_handler` below returns before any request is made.
const TEST_MODEL = Agentif.registerModel!(Agentif.Model(;
    id = "trust-test-model", name = "trust-test-model", api = "openai-completions",
    provider = "trust-test", baseUrl = "http://127.0.0.1:1/v1", reasoning = false,
    input = ["text"], cost = Dict("input" => 0.0, "output" => 0.0),
    contextWindow = 4096, maxTokens = 1024))

function make_assistant(db_path::String = ":memory:"; sources = Claw.EventSource[], kwargs...)
    a = Claw.AgentAssistant(db_path;
        provider = "trust-test", model_id = "trust-test-model", apikey = "test-key",
        timezone = "UTC", level = :error, kwargs...)
    for es in sources
        Claw.register_event_source!(a, es)
    end
    append!(a.tools, Claw.MANAGEMENT_TOOLS)
    append!(a.tools, Claw.TEMPUS_TOOLS)
    append!(a.tools, Claw.DB_TOOLS)
    append!(a.tools, Agentif.AgentTool[
        EMAIL_SEND_TOOL, EMAIL_SEARCH_TOOL, EXEC_COMMAND_TOOL, UNKNOWN_CUSTOM_TOOL])
    return a
end

tool_names(tools) = sort!(String[t.name for t in tools])

# Sources used by the exposure report tests.
struct ThirdPartySource <: Claw.EventSource end
Claw.get_event_types(::ThirdPartySource) = Claw.EventType[Claw.EventType("inbox_mail", "inbound email")]
Claw.get_event_handlers(::ThirdPartySource) = Claw.EventHandler[]
Claw.third_party_content(::ThirdPartySource) = true

struct DMSource <: Claw.EventSource end
Claw.get_event_types(::DMSource) = Claw.EventType[Claw.EventType("dm_message", "a direct message")]
Claw.get_event_handlers(::DMSource) = Claw.EventHandler[]
Claw.get_channels(::DMSource) = Agentif.AbstractChannel[TrustChannel("dm-1")]

struct GroupSource <: Claw.EventSource end
Claw.get_event_types(::GroupSource) = Claw.EventType[Claw.EventType("group_message", "a group message")]
Claw.get_event_handlers(::GroupSource) = Claw.EventHandler[]
Claw.get_channels(::GroupSource) = Agentif.AbstractChannel[TrustChannel("group-1"; group = true, private = false)]

# ─── §2.2 The no-regression guarantee ───

@testset "existing handlers keep the full tool set (owner is the default)" begin
    a = make_assistant()
    try
        # Constructed exactly the way every pre-Stage-2 call site constructs it.
        legacy = Claw.EventHandler("legacy", ["trust_test_event"], "", nothing)
        @test legacy.trust === :owner
        @test legacy.tools === nothing
        resolved = Claw.resolve_handler_tools(a, legacy)
        @test resolved !== a.tools
        @test tool_names(resolved) == tool_names(a.tools)
        lock(a._integrations_lock) do
            push!(a.tools, LATE_TOOL)
        end
        @test !("late_tool" in tool_names(resolved))

        # Same through the database round-trip a real dispatch takes.
        Claw.execute_write(a._writer,
            "INSERT OR IGNORE INTO claw_event_types (name, description) VALUES (?, ?)",
            ("trust_test_event", "trust test"))
        Claw.register_event_handler!(a, legacy)
        rows = Claw._event_handlers_for(a, "trust_test_event")
        @test length(rows) == 1
        @test rows[1].trust === :owner
        @test rows[1].tools === nothing
        @test tool_names(Claw.resolve_handler_tools(a, rows[1])) == tool_names(a.tools)
    finally
        Claw.shutdown!(a; timeout_s = 5)
    end
end

@testset "a row written before §2.2 existed comes back at :owner" begin
    # The migration backfills `trust` with 'owner', so upgrading a live database does
    # not silently strip tools from a running automation.
    path = tempname() * ".sqlite"
    a = make_assistant(path)
    try
        @test Claw._get_user_version(a.db) == Claw.CLAW_SCHEMA_VERSION
        @test Claw._column_exists(a.db, "claw_event_handlers", "trust")
        @test Claw._column_exists(a.db, "claw_event_handlers", "tools")
        # Simulate the pre-migration shape: columns present but never written.
        Claw.execute_write(a._writer,
            "INSERT INTO claw_event_handlers (id, prompt, channel_id) VALUES (?, ?, ?)",
            ("ancient", "do the thing", nothing))
        Claw.execute_write(a._writer,
            "INSERT OR IGNORE INTO claw_event_types (name, description) VALUES (?, ?)",
            ("trust_test_event", "trust test"))
        Claw.execute_write(a._writer,
            "INSERT INTO claw_handler_event_types (handler_id, event_type_name) VALUES (?, ?)",
            ("ancient", "trust_test_event"))
        row = only(Claw._event_handlers_for(a, "trust_test_event"))
        @test row.trust === :owner
        @test Claw.resolve_handler_tools(a, row) !== a.tools
        @test tool_names(Claw.resolve_handler_tools(a, row)) == tool_names(a.tools)
        # Re-running migrations is a no-op.
        @test Claw._migrate_claw_schema!(a.db) == Claw.CLAW_SCHEMA_VERSION
    finally
        Claw.shutdown!(a; timeout_s = 5)
        rm(path; force = true)
        rm(path * "-wal"; force = true)
        rm(path * "-shm"; force = true)
    end
end

# ─── §2.2 Untrusted tier ───

@testset "an :untrusted handler loses the dangerous tools, an :owner one keeps them" begin
    a = make_assistant()
    try
        Claw.execute_write(a._writer,
            "INSERT OR IGNORE INTO claw_event_types (name, description) VALUES (?, ?)",
            ("trust_test_event", "trust test"))
        Claw.register_event_handler!(a, Claw.EventHandler("owner-h", ["trust_test_event"], "", nothing))
        Claw.register_event_handler!(a,
            Claw.EventHandler("untrusted-h", ["trust_test_event"], "", nothing; trust = :untrusted))

        rows = Dict(h.id => h for h in Claw._event_handlers_for(a, "trust_test_event"))
        @test rows["untrusted-h"].trust === :untrusted    # persisted, not just in-memory

        owner_tools = Set(tool_names(Claw.resolve_handler_tools(a, rows["owner-h"])))
        untrusted_tools = Set(tool_names(Claw.resolve_handler_tools(a, rows["untrusted-h"])))

        for denied in ("set_system_prompt", "add_event_handler", "remove_event_handler",
                       "add_job", "remove_job", "email_send", "exec_command")
            @test denied in owner_tools
            @test !(denied in untrusted_tools)
        end
        # Only reviewed read/scratch tools survive. A deployment-specific tool is
        # denied until the operator explicitly allowlists it.
        for kept in ("db_search", "db_store", "db_list_keys", "email_search",
                     "get_system_prompt", "list_channels", "list_event_handlers")
            @test kept in untrusted_tools
        end
        @test !("custom_mutation" in untrusted_tools)
        @test untrusted_tools ⊆ owner_tools
    finally
        Claw.shutdown!(a; timeout_s = 5)
    end
end

@testset "trust filtering wins over an explicit tools list" begin
    a = make_assistant()
    try
        # Naming a denied tool does not grant it back.
        h = Claw.EventHandler("narrow", ["trust_test_event"], "", nothing;
            tools = ["db_search", "email_send"], trust = :untrusted)
        @test tool_names(Claw.resolve_handler_tools(a, h)) == ["db_search"]
        # The same subset at :owner trust keeps both.
        owner = Claw.EventHandler("narrow-owner", ["trust_test_event"], "", nothing;
            tools = ["db_search", "email_send"])
        @test tool_names(Claw.resolve_handler_tools(a, owner)) == ["db_search", "email_send"]
        # A corrupted tier is read back as the restrictive one, never as owner.
        @test Claw._decode_handler_trust("nonsense") === :untrusted
        @test Claw._decode_handler_trust("") === :untrusted
        @test Claw._decode_handler_trust(1) === :untrusted
        @test Claw._decode_handler_trust(missing) === :owner
        @test Claw._handler_trust((; trust = "owner")) === :untrusted
        # Corrupt stored subsets must become an empty set. `nothing` means the full
        # default set, so treating malformed JSON as `nothing` would fail open.
        @test Claw._decode_handler_tools("not-json") == String[]
        @test Claw._decode_handler_tools("{}") == String[]
        @test Claw._decode_handler_tools("[1]") == String[]
        @test Claw._decode_handler_tools(1) == String[]
        @test Claw._decode_handler_tools(missing) === nothing
        corrupt = (;
            trust = :owner,
            tools = Claw._decode_handler_tools("not-json"),
        )
        @test isempty(Claw.resolve_handler_tools(a, corrupt))
    finally
        Claw.shutdown!(a; timeout_s = 5)
    end
end

@testset "the resolved tool set reaches the agent that runs the handler" begin
    # End-to-end through _run_event_handler! → evaluate → Agentif.Agent, with a stub
    # base handler capturing what the agent was actually built with. Without this the
    # policy could be perfectly correct and still not wired to anything.
    a = make_assistant()
    Claw.CURRENT_ASSISTANT[] = a
    try
        seen = Ref{Vector{String}}(String[])
        capture = function (f, agent, state, input, abort; kw...)
            seen[] = sort!(String[t.name for t in agent.tools])
            return state
        end
        ch = TrustChannel("trust-eval")
        ev = TrustEvent("hello", ch)

        Claw._run_event_handler!(a, ev,
            (; id = "o", prompt = "", channel_id = nothing, trust = :owner, tools = nothing);
            base_handler = capture)
        @test "set_system_prompt" in seen[]
        @test "email_send" in seen[]

        Claw._run_event_handler!(a, ev,
            (; id = "u", prompt = "", channel_id = nothing, trust = :untrusted, tools = nothing);
            base_handler = capture)
        @test !("set_system_prompt" in seen[])
        @test !("email_send" in seen[])
        @test !("add_job" in seen[])
        @test "db_search" in seen[]
    finally
        Claw.shutdown!(a; timeout_s = 5)
    end
end

@testset "watcher supervision cannot restore owner tools" begin
    watcher = Claw.WatcherConfig(;
        provider = "trust-test",
        model_id = "trust-test-model",
        apikey = "test-key",
        stall_timeout_s = 5.0,
        max_eval_duration_s = 10.0,
        check_interval_s = 0.05,
        watcher_timeout_s = 5.0,
    )
    a = make_assistant(; watcher)
    Claw.CURRENT_ASSISTANT[] = a
    try
        seen = Ref{Vector{String}}(String[])
        capture = function (f, agent, state, input, abort; kw...)
            seen[] = sort!(String[t.name for t in agent.tools])
            return state
        end
        ev = TrustEvent("hello", TrustChannel("watched-trust-eval"))
        handler = (;
            id = "watched-untrusted",
            prompt = "",
            channel_id = nothing,
            trust = :untrusted,
            tools = nothing,
        )

        Claw._run_event_handler!(a, ev, handler; base_handler = capture)

        @test !("set_system_prompt" in seen[])
        @test !("email_send" in seen[])
        @test !("custom_mutation" in seen[])
        @test "db_search" in seen[]
    finally
        Claw.shutdown!(a; timeout_s = 5)
    end
end

# ─── §2.2 Startup exposure warning ───

@testset "startup exposure warning names the exposed handlers" begin
    sources = Claw.EventSource[ThirdPartySource(), GroupSource(), DMSource()]
    a = make_assistant(; sources = sources)
    try
        Claw.register_event_handler!(a, Claw.EventHandler("mail-triage", ["inbox_mail"], "", nothing))
        Claw.register_event_handler!(a, Claw.EventHandler("group-chat", ["group_message"], "", nothing))
        Claw.register_event_handler!(a, Claw.EventHandler("dm-only", ["dm_message"], "", nothing))
        Claw.register_event_handler!(a, Claw.EventHandler(
            "mail-owner-narrow",
            ["inbox_mail"],
            "",
            nothing;
            tools = ["db_search"],
        ))
        Claw.register_event_handler!(a,
            Claw.EventHandler("mail-triage-safe", ["inbox_mail"], "", nothing; trust = :untrusted))

        rows = Claw.trust_exposure_report(a, sources)
        ids = sort!(String[r.id for r in rows])
        @test ids == ["group-chat", "mail-triage"]
        @test any(r -> occursin("third-party-authored content", join(r.reasons, " ")),
            filter(r -> r.id == "mail-triage", rows))
        @test any(r -> occursin("group/public", join(r.reasons, " ")),
            filter(r -> r.id == "group-chat", rows))

        # A handler replying into a group channel counts even when its trigger is a DM.
        Claw.register_event_handler!(a,
            Claw.EventHandler("dm-to-group", ["dm_message"], "", "group-1"))
        @test "dm-to-group" in String[r.id for r in Claw.trust_exposure_report(a, sources)]

        # And the log is a single consolidated block naming ids and tools at risk.
        logs = Test.collect_test_logs(min_level = Logging.Warn) do
            Claw._log_trust_exposure(a, sources)
        end[1]
        warnings = filter(l -> l.level == Logging.Warn, logs)
        @test length(warnings) == 1
        msg = string(warnings[1].message)
        @test occursin("mail-triage", msg)
        @test occursin("group-chat", msg)
        @test occursin("dm-to-group", msg)
        @test !occursin("dm-only", msg)
        @test !occursin("mail-owner-narrow", msg)
        @test !occursin("mail-triage-safe:", msg)
        @test occursin("set_system_prompt", msg)      # tools at risk are named
        @test occursin("email_send", msg)
        @test occursin("trust = :untrusted", msg)     # and the one-line fix
    finally
        Claw.shutdown!(a; timeout_s = 5)
    end
end

@testset "startup exposure warning stays silent when nothing qualifies" begin
    sources = Claw.EventSource[DMSource()]
    a = make_assistant(; sources = sources)
    try
        Claw.register_event_handler!(a, Claw.EventHandler("dm-only", ["dm_message"], "", nothing))
        Claw.register_event_handler!(a,
            Claw.EventHandler("mail-safe", ["dm_message"], "", nothing; trust = :untrusted))
        @test isempty(Claw.trust_exposure_report(a, sources))
        logs = Test.collect_test_logs(min_level = Logging.Warn) do
            Claw._log_trust_exposure(a, sources)
        end[1]
        @test isempty(filter(l -> l.level == Logging.Warn, logs))
    finally
        Claw.shutdown!(a; timeout_s = 5)
    end
end

# ─── §2.1 Bind addresses default to loopback ───

@testset "HTTP-listening sources default to loopback" begin
    @test Claw.is_loopback_host("127.0.0.1")
    @test Claw.is_loopback_host("127.1.2.3")
    @test Claw.is_loopback_host("localhost")
    @test Claw.is_loopback_host("::1")
    @test Claw.is_loopback_host("[::1]")
    @test !Claw.is_loopback_host("0.0.0.0")
    @test !Claw.is_loopback_host("10.0.0.4")
    @test !Claw.is_loopback_host("::")
    @test !Claw.is_loopback_host("not-a-host")

    msteams = Base.get_extension(Claw, :ClawMSTeamsExt)
    if msteams !== nothing
        @test Claw.is_loopback_host(msteams.MSTeamsEventSource(; app_id = "a", app_password = "b").host)
    end
    telegram = Base.get_extension(Claw, :ClawTelegramExt)
    if telegram !== nothing
        @test Claw.is_loopback_host(telegram.TelegramEventSource().host)
    end
    github = Base.get_extension(Claw, :ClawGitHubExt)
    if github !== nothing
        @test Claw.is_loopback_host(github.GitHubEventSource(; secret = "s").host)
    end
end

@testset "Telegram webhook authentication is mandatory" begin
    telegram = Base.get_extension(Claw, :ClawTelegramExt)
    if telegram !== nothing
        @test Claw.validate_source(telegram.TelegramEventSource(; use_polling = true)) === nothing
        @test_throws ErrorException Claw.validate_source(
            telegram.TelegramEventSource(; use_polling = false, secret_token = nothing))
        @test_throws ErrorException Claw.validate_source(
            telegram.TelegramEventSource(; use_polling = false, secret_token = "  "))
        @test Claw.validate_source(telegram.TelegramEventSource(;
            use_polling = false,
            secret_token = "reviewed-secret",
        )) === nothing
    end
end

end # module TrustTests
