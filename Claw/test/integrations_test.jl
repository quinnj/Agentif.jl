# integrations_test.jl — Tier 1 integration enablement: catalog, factories,
# enable/disable, persisted enabled-set reconciliation, adoption of runner-passed
# sources, and the agent-facing tools.

module IntegrationsTests

using Test
using Agentif
using Claw
using JSON
using SQLite

# ─── Toy integration ───

mutable struct ToyChannel <: Agentif.AbstractChannel
    id::String
end
Agentif.channel_id(ch::ToyChannel) = ch.id
Agentif.is_group(::ToyChannel) = false
Agentif.is_private(::ToyChannel) = true
Agentif.start_streaming(::ToyChannel) = nothing
Agentif.append_to_stream(::ToyChannel, ::AbstractString) = nothing
Agentif.finish_streaming(::ToyChannel) = nothing
Agentif.send_message(::ToyChannel, msg) = nothing
Agentif.close_channel(::ToyChannel) = nothing

mutable struct ToyEventSource <: Claw.EventSource
    token::String
    label::String
    started::Threads.Atomic{Bool}
    stopped::Threads.Atomic{Bool}
end
ToyEventSource(; token::String = "default-token", label::String = "default-label") =
    ToyEventSource(token, label, Threads.Atomic{Bool}(false), Threads.Atomic{Bool}(false))

toy_tool_impl() = "toy"
const TOY_TOOL = Agentif.AgentTool{typeof(toy_tool_impl), @NamedTuple{}}(;
    name = "toy_integration_tool", description = "toy tool", func = toy_tool_impl)

Claw.get_channels(::ToyEventSource) = Agentif.AbstractChannel[ToyChannel("toy-chan")]
Claw.get_event_types(::ToyEventSource) = Claw.EventType[Claw.EventType("toy_event", "toy event")]
Claw.get_event_handlers(::ToyEventSource) = Claw.EventHandler[]
Claw.get_tools(::ToyEventSource) = Agentif.AgentTool[TOY_TOOL]
Claw.start!(es::ToyEventSource, ::Claw.AgentAssistant) = (es.started[] = true; nothing)
Claw.stop!(es::ToyEventSource) = (es.stopped[] = true; nothing)

struct ToyChannelEvent <: Claw.ChannelEvent
    channel::ToyChannel
end
Claw.get_name(::ToyChannelEvent) = "toy_event"
Claw.get_channel(event::ToyChannelEvent) = event.channel
Claw.event_content(::ToyChannelEvent) = "runtime channel"
Claw.event_source_tag(::ToyChannelEvent) = "toy"

const TOY_SPEC = Claw.IntegrationSpec("toy", "ToyPkg", "toy integration for tests",
    ["token" => "the toy token", "label" => "a non-sensitive label"])
Claw.register_integration!(TOY_SPEC, ToyEventSource)

mutable struct LeakyStartSource <: Claw.EventSource
    token::String
end
LeakyStartSource(; token::String = "default-token") = LeakyStartSource(token)
Claw.start!(es::LeakyStartSource, ::Claw.AgentAssistant) =
    Threads.@spawn error("source rejected token $(es.token)")

const LEAKY_START_SPEC = Claw.IntegrationSpec(
    "leaky-start", "LeakyPkg", "source whose error contains its token", ["token" => "secret token"])
Claw.register_integration!(LEAKY_START_SPEC, LeakyStartSource)

struct LeakyInvalidSource <: Claw.EventSource
    token::String
end
LeakyInvalidSource(; token::String = "default-token") = LeakyInvalidSource(token)
Claw.validate_source(es::LeakyInvalidSource) = error("invalid token $(es.token)")

const LEAKY_INVALID_SPEC = Claw.IntegrationSpec(
    "leaky-invalid", "LeakyPkg", "invalid source whose error contains its token", ["token" => "secret token"])
Claw.register_integration!(LEAKY_INVALID_SPEC, LeakyInvalidSource)

mutable struct SlowExitSource <: Claw.EventSource
    entered::Threads.Atomic{Bool}
    cleaned::Threads.Atomic{Bool}
    stop_event::Base.Event
end
SlowExitSource() = SlowExitSource(
    Threads.Atomic{Bool}(false), Threads.Atomic{Bool}(false), Base.Event())
function Claw.start!(es::SlowExitSource, ::Claw.AgentAssistant)
    return Threads.@spawn begin
        es.entered[] = true
        try
            wait(es.stop_event)
            sleep(0.25)
        catch e
            e isa InterruptException || rethrow()
            sleep(0.25)
        end
        es.cleaned[] = true
    end
end
Claw.stop!(es::SlowExitSource) = (notify(es.stop_event); nothing)

const SLOW_EXIT_SPEC = Claw.IntegrationSpec(
    "slow-exit", "SlowExitPkg", "source with observable asynchronous cleanup", [])
Claw.register_integration!(SLOW_EXIT_SPEC, SlowExitSource)

mutable struct StartRaceSource <: Claw.EventSource
    start_entered::Threads.Atomic{Bool}
    start_release::Base.Event
    stopping::Threads.Atomic{Bool}
end
StartRaceSource() = StartRaceSource(
    Threads.Atomic{Bool}(false), Base.Event(), Threads.Atomic{Bool}(false))
function Claw.start!(es::StartRaceSource, ::Claw.AgentAssistant)
    es.start_entered[] = true
    wait(es.start_release)
    es.stopping[] = false
    return Threads.@spawn begin
        while !es.stopping[]
            sleep(0.01)
        end
    end
end
Claw.stop!(es::StartRaceSource) = (es.stopping[] = true; nothing)

const START_RACE_SPEC = Claw.IntegrationSpec(
    "start-race", "StartRacePkg", "source with a controlled start/stop race", [])
Claw.register_integration!(START_RACE_SPEC, StartRaceSource)

struct PermissiveEventSource <: Claw.EventSource
    label::String
    internal_state::Any
end
PermissiveEventSource(; label::String = "", internal_state = nothing) =
    PermissiveEventSource(label, internal_state)

const PERMISSIVE_SPEC = Claw.IntegrationSpec(
    "permissive", "PermissivePkg", "source with internal constructor state",
    ["label" => "public label"])
Claw.register_integration!(PERMISSIVE_SPEC, PermissiveEventSource)

struct OverlapEventSource <: Claw.EventSource
    channel::ToyChannel
end
OverlapEventSource() = OverlapEventSource(ToyChannel("toy-chan"))
Claw.get_channels(es::OverlapEventSource) = Agentif.AbstractChannel[es.channel]
Claw.get_event_types(::OverlapEventSource) =
    Claw.EventType[Claw.EventType("toy_event", "overlapping event")]
Claw.get_tools(::OverlapEventSource) = Agentif.AgentTool[TOY_TOOL]

const OVERLAP_SPEC = Claw.IntegrationSpec(
    "overlap", "OverlapPkg", "source with overlapping registrations", [])
Claw.register_integration!(OVERLAP_SPEC, OverlapEventSource)

mutable struct BlockingEventSource <: Claw.EventSource
    stop_entered::Base.Event
    stop_release::Base.Event
    block_stop::Threads.Atomic{Bool}
end

const BLOCKING_STOP_ENTERED = Ref{Base.Event}(Base.Event())
const BLOCKING_STOP_RELEASE = Ref{Base.Event}(Base.Event())
const BLOCKING_STOP_STARTED = Threads.Atomic{Bool}(false)
BlockingEventSource() = BlockingEventSource(
    BLOCKING_STOP_ENTERED[], BLOCKING_STOP_RELEASE[], Threads.Atomic{Bool}(true))

Claw.get_channels(::BlockingEventSource) = Agentif.AbstractChannel[ToyChannel("blocking-chan")]
Claw.get_event_types(::BlockingEventSource) = Claw.EventType[Claw.EventType("blocking_event", "blocking event")]
Claw.get_tools(::BlockingEventSource) = Agentif.AgentTool[TOY_TOOL]
Claw.start!(::BlockingEventSource, ::Claw.AgentAssistant) = nothing
function Claw.stop!(es::BlockingEventSource)
    es.block_stop[] || return nothing
    BLOCKING_STOP_STARTED[] = true
    notify(es.stop_entered)
    wait(es.stop_release)
    return nothing
end

const BLOCKING_SPEC = Claw.IntegrationSpec(
    "blocking", "BlockingPkg", "blocking integration for race tests", [])
Claw.register_integration!(BLOCKING_SPEC, BlockingEventSource)

struct InvalidEventSource <: Claw.EventSource end
Claw.validate_source(::InvalidEventSource) = error("invalid test configuration")

const INVALID_SPEC = Claw.IntegrationSpec(
    "invalid", "InvalidPkg", "invalid integration for validation tests", [])
Claw.register_integration!(INVALID_SPEC, InvalidEventSource)

# A catalog entry with no factory, i.e. an integration whose package is not loaded.
# (Registered directly so the assertion cannot go stale when another test file
# loads the real Telegram/Slack packages into this process.)
Claw.INTEGRATION_SPECS["ghost"] = Claw.IntegrationSpec("ghost", "GhostPkg", "ghost integration for tests", [])

make_assistant(db_path::String = ":memory:") = Claw.AgentAssistant(db_path;
    provider = "openai-completions", model_id = "gpt-4o-mini", apikey = "test-key",
    timezone = "UTC", level = :error)

has_tool(a, name) = any(t -> Agentif.tool_name(t) == name, a.tools)
event_type_registered(a, name) =
    Claw._fetch_one(a.db, "SELECT 1 FROM claw_event_types WHERE name = ?", (name,)) !== nothing
integration_row(a, name) =
    Claw._fetch_one(a.db, "SELECT enabled, config, status FROM claw_integrations WHERE name = ?", (name,))

# ─── Registry ───

@testset "integration registry" begin
    # built-in catalog entries exist without their packages loaded
    @test haskey(Claw.INTEGRATION_SPECS, "slack")
    @test haskey(Claw.INTEGRATION_SPECS, "fastmail")
    # registering a factory for an uncataloged name requires a spec
    @test_throws ArgumentError Claw.register_integration!("not-in-catalog", ToyEventSource)
    # the toy spec + factory registered above is visible
    @test Claw._integration_factory("toy") === ToyEventSource
    @test Claw._integration_name_for(ToyEventSource()) == "toy"
    mixed = Claw.IntegrationSpec("MiXeD", "MixedPkg", "mixed-case test", [])
    Claw.register_integration!(mixed, InvalidEventSource)
    @test Claw.INTEGRATION_SPECS["mixed"].name == "mixed"
    @test Claw._integration_factory("mixed") === InvalidEventSource
end

# ─── Enable / disable ───

@testset "enable_integration! / disable_integration!" begin
    a = make_assistant()
    a._state[] = :running   # pretend init! ran, so enable starts supervision
    try
        st = Claw.enable_integration!(a, "toy"; config = Dict{String, Any}("token" => "abc"))
        @test st.source isa ToyEventSource
        @test st.source.token == "abc"
        @test haskey(a._channels, "toy-chan")
        @test has_tool(a, "toy_integration_tool")
        @test event_type_registered(a, "toy_event")
        row = integration_row(a, "toy")
        @test row.enabled == 1
        @test !occursin("abc", String(row.config))
        @test timedwait(() -> st.source.started[], 5.0) == :ok
        @test st.supervised !== nothing

        # double enable and unknown names are descriptive errors
        err = try; Claw.enable_integration!(a, "toy"); nothing; catch e; e; end
        @test err !== nothing && occursin("already enabled", sprint(showerror, err))
        err = try; Claw.enable_integration!(a, "no-such"); nothing; catch e; e; end
        @test err !== nothing && occursin("Unknown integration", sprint(showerror, err))
        # cataloged but not loaded reports the package to add
        err = try; Claw.enable_integration!(a, "ghost"); nothing; catch e; e; end
        @test err !== nothing && occursin("GhostPkg is not loaded", sprint(showerror, err))
        # bad config key is a descriptive construction error
        err = try
            Claw.disable_integration!(a, "toy")
            Claw.enable_integration!(a, "toy"; config = Dict{String, Any}("bogus_key" => 1))
            nothing
        catch e
            e
        end
        @test err !== nothing && occursin("Valid config keys", sprint(showerror, err))

        # The catalog remains an allowlist when a constructor accepts internal
        # keywords that must not be exposed through the agent tool.
        err = try
            Claw.enable_integration!(a, "permissive";
                config = Dict{String, Any}("internal_state" => "injected"))
            nothing
        catch e
            e
        end
        @test err !== nothing && occursin("Unknown config key", sprint(showerror, err))
        @test lock(() -> !haskey(a._integrations, "permissive"), a._integrations_lock)

        # bring it back for the disable assertions
        st = Claw.enable_integration!(a, "toy")
        src = st.source
        Claw.disable_integration!(a, "toy")
        @test timedwait(() -> src.stopped[], 5.0) == :ok        # stop! was called
        @test !haskey(a._channels, "toy-chan")
        @test !has_tool(a, "toy_integration_tool")
        @test !event_type_registered(a, "toy_event")
        @test integration_row(a, "toy").enabled == 0
        @test all(ss -> ss.source !== src, a._sources)
        err = try; Claw.disable_integration!(a, "toy"); nothing; catch e; e; end
        @test err !== nothing && occursin("not enabled", sprint(showerror, err))
    finally
        Claw.shutdown!(a; timeout_s = 5)
    end
end

@testset "integration transitions stay serialized" begin
    a = make_assistant()
    a._state[] = :running
    BLOCKING_STOP_ENTERED[] = Base.Event()
    BLOCKING_STOP_RELEASE[] = Base.Event()
    BLOCKING_STOP_STARTED[] = false
    first = Claw.enable_integration!(a, "blocking")
    disable_task = Threads.@spawn Claw.disable_integration!(a, "blocking")
    try
        @test timedwait(() -> BLOCKING_STOP_STARTED[], 5.0) == :ok
        enable_task = Threads.@spawn Claw.enable_integration!(a, "blocking")
        # A new enable must wait until the old source has stopped and all of its
        # registrations have been removed. Otherwise the old cleanup removes the
        # new source's channels, event types, and tools.
        @test timedwait(() -> istaskdone(enable_task), 0.2) == :timed_out
        notify(BLOCKING_STOP_RELEASE[])
        @test timedwait(() -> istaskdone(disable_task), 5.0) == :ok
        @test timedwait(() -> istaskdone(enable_task), 5.0) == :ok
        fetch(disable_task)
        second = fetch(enable_task)
        @test second.source !== first.source
        @test haskey(a._channels, "blocking-chan")
        @test has_tool(a, "toy_integration_tool")
        @test event_type_registered(a, "blocking_event")
        @test integration_row(a, "blocking").enabled == 1
        second.source.block_stop[] = false
    finally
        notify(BLOCKING_STOP_RELEASE[])
        first.source.block_stop[] = false
        try
            timedwait(() -> istaskdone(disable_task), 5.0)
            istaskdone(disable_task) && fetch(disable_task)
        catch
        end
        st = lock(() -> get(a._integrations, "blocking", nothing), a._integrations_lock)
        st === nothing || (st.source.block_stop[] = false)
        Claw.shutdown!(a; timeout_s = 5)
    end
end

@testset "disable preserves registrations from other sources" begin
    a = make_assistant()
    a._state[] = :running
    try
        first = Claw.enable_integration!(a, "toy")
        second = Claw.enable_integration!(a, "overlap")
        runtime_channel = ToyChannel("runtime-only")
        Claw.register_channels!(a, Agentif.AbstractChannel[runtime_channel]; source = first.source)
        event_channel = ToyChannel("event-only")
        @test Claw._resolve_event_channel(a, ToyChannelEvent(event_channel), nothing) === event_channel
        first_shared = ToyChannel("runtime-shared")
        second_shared = ToyChannel("runtime-shared")
        Claw.register_channels!(a, Agentif.AbstractChannel[first_shared]; source = first.source)
        Claw.register_channels!(a, Agentif.AbstractChannel[second_shared]; source = second.source)
        @test a._channels["toy-chan"] === second.source.channel
        @test a._channels["runtime-only"] === runtime_channel
        @test a._channels["event-only"] === event_channel
        @test a._channels["runtime-shared"] === second_shared
        @test count(t -> Agentif.tool_name(t) == "toy_integration_tool", a.tools) == 2

        Claw.disable_integration!(a, "toy")
        @test a._channels["toy-chan"] === second.source.channel
        @test !haskey(a._channels, "runtime-only")
        @test !haskey(a._channels, "event-only")
        @test a._channels["runtime-shared"] === second_shared
        Claw.register_channels!(a, Agentif.AbstractChannel[ToyChannel("late-channel")];
            source = first.source)
        @test !haskey(a._channels, "late-channel")
        @test has_tool(a, "toy_integration_tool")
        @test event_type_registered(a, "toy_event")

        Claw.disable_integration!(a, "overlap")
        @test !haskey(a._channels, "toy-chan")
        @test !has_tool(a, "toy_integration_tool")
        @test !event_type_registered(a, "toy_event")
        @test !haskey(a._channels, "runtime-shared")
        @test first.source.stopped[]
    finally
        Claw.shutdown!(a; timeout_s = 5)
    end
end

@testset "disable waits for source cleanup" begin
    a = make_assistant()
    a._state[] = :running
    st = Claw.enable_integration!(a, "slow-exit")
    try
        @test timedwait(() -> st.source.entered[], 5.0) == :ok
        Claw.disable_integration!(a, "slow-exit")
        @test st.source.cleaned[]
        @test st.supervised.task === nothing || istaskdone(st.supervised.task)
    finally
        notify(st.source.stop_event)
        Claw.shutdown!(a; timeout_s = 5)
    end
end

@testset "disable serializes with source start" begin
    cfg = Claw.PipelineConfig(; source_stop_timeout_s = 0.5)
    a = Claw.AgentAssistant(":memory:";
        provider = "openai-completions", model_id = "gpt-4o-mini", apikey = "test-key",
        timezone = "UTC", level = :error, pipeline = cfg)
    a._state[] = :running
    st = Claw.enable_integration!(a, "start-race")
    disable_task = nothing
    try
        @test timedwait(() -> st.source.start_entered[], 5.0) == :ok
        disable_task = Threads.@spawn Claw.disable_integration!(a, "start-race")
        @test timedwait(() -> st.source.stopping[], 0.1) == :timed_out
        notify(st.source.start_release)
        @test timedwait(() -> istaskdone(disable_task), 5.0) == :ok
        fetch(disable_task)
        @test st.source.stopping[]
        @test st.supervised.task === nothing || istaskdone(st.supervised.task)
    finally
        st.source.stopping[] = true
        notify(st.source.start_release)
        disable_task === nothing || try
            timedwait(() -> istaskdone(disable_task), 5.0)
            istaskdone(disable_task) && fetch(disable_task)
        catch
        end
        Claw.shutdown!(a; timeout_s = 5)
    end
end

@testset "invalid integrations do not become enabled" begin
    a = make_assistant()
    a._state[] = :running
    try
        @test_throws ErrorException Claw.enable_integration!(a, "invalid")
        @test lock(() -> !haskey(a._integrations, "invalid"), a._integrations_lock)
        @test all(ss -> !(ss.source isa InvalidEventSource), a._sources)
        @test integration_row(a, "invalid") === nothing
    finally
        Claw.shutdown!(a; timeout_s = 5)
    end
end

@testset "enable persistence failure rolls runtime back" begin
    a = make_assistant()
    a._state[] = :running
    try
        Claw.execute_write(a._writer, """
            CREATE TRIGGER reject_integration_insert
            BEFORE INSERT ON claw_integrations
            BEGIN SELECT RAISE(ABORT, 'integration insert blocked'); END
        """)
        @test_throws SQLite.SQLiteException Claw.enable_integration!(a, "toy")
        @test lock(() -> !haskey(a._integrations, "toy"), a._integrations_lock)
        @test !haskey(a._channels, "toy-chan")
        @test !has_tool(a, "toy_integration_tool")
        @test !event_type_registered(a, "toy_event")
        @test !any(es -> es isa ToyEventSource, Claw.EVENT_SOURCES)
    finally
        Claw.execute_write(a._writer, "DROP TRIGGER IF EXISTS reject_integration_insert")
        lock(() -> haskey(a._integrations, "toy"), a._integrations_lock) &&
            Claw.disable_integration!(a, "toy")
        Claw.shutdown!(a; timeout_s = 5)
    end
end

@testset "disable persistence failure keeps runtime enabled" begin
    a = make_assistant()
    a._state[] = :running
    st = Claw.enable_integration!(a, "toy")
    try
        Claw.execute_write(a._writer, """
            CREATE TRIGGER reject_integration_disable
            BEFORE UPDATE OF enabled ON claw_integrations
            WHEN NEW.enabled = 0
            BEGIN SELECT RAISE(ABORT, 'integration disable blocked'); END
        """)
        @test_throws SQLite.SQLiteException Claw.disable_integration!(a, "toy")
        @test lock(() -> get(a._integrations, "toy", nothing), a._integrations_lock) === st
        @test haskey(a._channels, "toy-chan")
        @test has_tool(a, "toy_integration_tool")
        @test event_type_registered(a, "toy_event")
        @test integration_row(a, "toy").enabled == 1
    finally
        Claw.execute_write(a._writer, "DROP TRIGGER IF EXISTS reject_integration_disable")
        lock(() -> haskey(a._integrations, "toy"), a._integrations_lock) &&
            Claw.disable_integration!(a, "toy")
        Claw.shutdown!(a; timeout_s = 5)
    end
end

@testset "event type cleanup failure keeps runtime enabled" begin
    a = make_assistant()
    a._state[] = :running
    st = Claw.enable_integration!(a, "toy")
    try
        Claw.execute_write(a._writer, """
            CREATE TRIGGER reject_event_type_cleanup
            BEFORE DELETE ON claw_event_types
            WHEN OLD.name = 'toy_event'
            BEGIN SELECT RAISE(ABORT, 'event type cleanup blocked'); END
        """)
        @test_throws SQLite.SQLiteException Claw.disable_integration!(a, "toy")
        @test lock(() -> get(a._integrations, "toy", nothing), a._integrations_lock) === st
        @test !st.source.stopped[]
        @test any(ss -> ss.source === st.source && !ss.stopped[], a._sources)
        @test haskey(a._channels, "toy-chan")
        @test has_tool(a, "toy_integration_tool")
        @test event_type_registered(a, "toy_event")
        @test integration_row(a, "toy").enabled == 1
    finally
        Claw.execute_write(a._writer, "DROP TRIGGER IF EXISTS reject_event_type_cleanup")
        lock(() -> haskey(a._integrations, "toy"), a._integrations_lock) &&
            Claw.disable_integration!(a, "toy")
        Claw.shutdown!(a; timeout_s = 5)
    end
end

# ─── Persisted enabled-set reconciliation ───

@testset "init! reconciles the persisted enabled-set" begin
    path = tempname() * ".sqlite"
    a = make_assistant(path)
    a._state[] = :running
    Claw.enable_integration!(a, "toy"; config = Dict{String, Any}(
        "token" => "ephemeral-secret", "label" => "persisted-label"))
    Claw.shutdown!(a; timeout_s = 5)

    # a fresh assistant on the same database re-enables it with the stored config
    b = Claw.init!(path;
        provider = "openai-completions", model_id = "gpt-4o-mini", apikey = "test-key",
        timezone = "UTC", level = :error,
        event_sources = Claw.EventSource[], install_signal_handlers = false)
    try
        st = lock(() -> get(b._integrations, "toy", nothing), b._integrations_lock)
        @test st !== nothing
        @test st.source.token == "default-token"
        @test st.source.label == "persisted-label"
        @test timedwait(() -> st.source.started[], 5.0) == :ok
        @test has_tool(b, "toy_integration_tool")
        @test event_type_registered(b, "toy_event")
    finally
        Claw.shutdown!(b; timeout_s = 5)
        Claw.CURRENT_ASSISTANT[] = nothing
    end

    # disabled stays disabled across restarts
    c = Claw.init!(path;
        provider = "openai-completions", model_id = "gpt-4o-mini", apikey = "test-key",
        timezone = "UTC", level = :error,
        event_sources = Claw.EventSource[], install_signal_handlers = false)
    Claw.disable_integration!(c, "toy")
    Claw.shutdown!(c; timeout_s = 5)
    Claw.CURRENT_ASSISTANT[] = nothing
    d = Claw.init!(path;
        provider = "openai-completions", model_id = "gpt-4o-mini", apikey = "test-key",
        timezone = "UTC", level = :error,
        event_sources = Claw.EventSource[], install_signal_handlers = false)
    try
        @test lock(() -> !haskey(d._integrations, "toy"), d._integrations_lock)
    finally
        Claw.shutdown!(d; timeout_s = 5)
        Claw.CURRENT_ASSISTANT[] = nothing
    end
    rm(path; force = true)
end

@testset "integration secrets are not persisted" begin
    path = tempname() * ".sqlite"
    a = make_assistant(path)
    try
        Claw._exec!(a.db, """
            INSERT INTO claw_integrations (name, enabled, config, status, updated_at)
            VALUES ('toy', 0,
                '{"token":"legacy-secret","credentials_json":"secret-json","label":"kept","nested":{"authorization_header":"Bearer hidden"},"items":[{"api_token_file":"/secret/path"}]}',
                NULL, 0)
        """)
        Claw._set_user_version!(a.db, 4)
    finally
        Claw.shutdown!(a; timeout_s = 5)
    end

    b = make_assistant(path)
    try
        @test Claw._get_user_version(b.db) == Claw.CLAW_SCHEMA_VERSION
        row = integration_row(b, "toy")
        parsed = JSON.parse(String(row.config))
        @test !haskey(parsed, "token")
        @test parsed["label"] == "kept"
        @test !occursin("legacy-secret", String(row.config))
        @test !haskey(parsed, "credentials_json")
        @test !haskey(parsed["nested"], "authorization_header")
        @test !haskey(only(parsed["items"]), "api_token_file")
    finally
        Claw.shutdown!(b; timeout_s = 5)
        rm(path; force = true)
        rm(path * "-wal"; force = true)
        rm(path * "-shm"; force = true)
    end
end

@testset "integration errors redact source secrets" begin
    a = make_assistant()
    a._state[] = :running
    try
        Claw.enable_integration!(a, "leaky-start";
            config = Dict{String, Any}("token" => "journal-secret"))
        @test timedwait(() -> Claw._fetch_one(a.db, """
            SELECT detail FROM claw_source_journal
            WHERE source = 'leakystartsource' AND action IN ('start_failed', 'crashed')
            ORDER BY id DESC LIMIT 1
        """) !== nothing, 5.0) == :ok
        journal = Claw._fetch_one(a.db, """
            SELECT detail FROM claw_source_journal
            WHERE source = 'leakystartsource' AND action IN ('start_failed', 'crashed')
            ORDER BY id DESC LIMIT 1
        """)
        @test !occursin("journal-secret", String(journal.detail))
        @test occursin("[REDACTED]", String(journal.detail))

        err = try
            Claw.enable_integration!(a, "leaky-invalid";
                config = Dict{String, Any}("token" => "status-secret"))
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test !occursin("status-secret", sprint(showerror, err))
        @test occursin("[REDACTED]", sprint(showerror, err))

        Claw._exec!(a.db, """
            INSERT INTO claw_integrations (name, enabled, config, updated_at)
            VALUES ('leaky-invalid', 1, NULL, 0)
        """)
        Claw._reconcile_integrations!(a)
        status = String(integration_row(a, "leaky-invalid").status)
        @test !occursin("default-token", status)
        @test occursin("[REDACTED]", status)
    finally
        Claw.shutdown!(a; timeout_s = 5)
    end
end

@testset "reconcile failure isolation records status" begin
    path = tempname() * ".sqlite"
    a = make_assistant(path)
    # persist an enabled integration whose package is "not loaded"
    Claw._exec!(a.db,
        "INSERT INTO claw_integrations (name, enabled, config, updated_at) VALUES ('ghost', 1, NULL, 0)")
    Claw.shutdown!(a; timeout_s = 5)
    b = Claw.init!(path;
        provider = "openai-completions", model_id = "gpt-4o-mini", apikey = "test-key",
        timezone = "UTC", level = :error,
        event_sources = Claw.EventSource[], install_signal_handlers = false)
    try
        # init! completed despite the failure, and the error is recorded
        @test lock(() -> !haskey(b._integrations, "ghost"), b._integrations_lock)
        row = integration_row(b, "ghost")
        @test row !== nothing && occursin("not loaded", String(row.status))
    finally
        Claw.shutdown!(b; timeout_s = 5)
        Claw.CURRENT_ASSISTANT[] = nothing
    end
    rm(path; force = true)
end

@testset "reconcile rejects corrupt stored config" begin
    path = tempname() * ".sqlite"
    a = make_assistant(path)
    Claw._exec!(a.db, """
        INSERT INTO claw_integrations (name, enabled, config, updated_at)
        VALUES ('toy', 1, '{broken', 0)
    """)
    # Mark this as a current-version row. A migration would correctly discard a
    # version-4 config before reconciliation gets to validate it.
    Claw.shutdown!(a; timeout_s = 5)

    b = Claw.init!(path;
        provider = "openai-completions", model_id = "gpt-4o-mini", apikey = "test-key",
        timezone = "UTC", level = :error,
        event_sources = Claw.EventSource[], install_signal_handlers = false)
    try
        @test lock(() -> !haskey(b._integrations, "toy"), b._integrations_lock)
        row = integration_row(b, "toy")
        @test occursin("not valid JSON", String(row.status))
    finally
        Claw.shutdown!(b; timeout_s = 5)
        Claw.CURRENT_ASSISTANT[] = nothing
        rm(path; force = true)
        rm(path * "-wal"; force = true)
        rm(path * "-shm"; force = true)
    end
end

# ─── Adoption of runner-passed sources ───

@testset "explicit sources are adopted, not double-enabled" begin
    path = tempname() * ".sqlite"
    a = make_assistant(path)
    a._state[] = :running
    Claw.enable_integration!(a, "toy")   # persist enabled=1
    Claw.shutdown!(a; timeout_s = 5)

    explicit = ToyEventSource(; token = "explicit")
    b = Claw.init!(path;
        provider = "openai-completions", model_id = "gpt-4o-mini", apikey = "test-key",
        timezone = "UTC", level = :error,
        event_sources = Claw.EventSource[explicit], install_signal_handlers = false)
    try
        st = lock(() -> get(b._integrations, "toy", nothing), b._integrations_lock)
        # the runner-passed instance won; the persisted row did not start a second one
        @test st !== nothing && st.source === explicit
        @test count(ss -> ss.source isa ToyEventSource, b._sources) == 1
        # and it is disable-able like a managed integration
        Claw.disable_integration!(b, "toy")
        @test timedwait(() -> explicit.stopped[], 5.0) == :ok
    finally
        Claw.shutdown!(b; timeout_s = 5)
        Claw.CURRENT_ASSISTANT[] = nothing
    end
    rm(path; force = true)
end

# ─── Tools ───

@testset "integration tools" begin
    a = make_assistant()
    a._state[] = :running
    old = Claw.CURRENT_ASSISTANT[]
    Claw.CURRENT_ASSISTANT[] = a
    try
        listing = Claw.list_integrations()
        @test occursin("- toy [available]", listing)
        @test occursin("- ghost [unavailable (package GhostPkg not loaded)]", listing)
        @test occursin("token — the toy token", listing)

        @test occursin("not valid JSON", Claw.enable_integration("toy", "{nope"))
        @test occursin("must be a JSON object", Claw.enable_integration("toy", "[1,2]"))
        msg = Claw.enable_integration("toy", "{\"token\": \"via-tool\"}")
        @test occursin("enabled and started", msg)
        @test occursin("- toy [enabled]", Claw.list_integrations())
        st = lock(() -> a._integrations["toy"], a._integrations_lock)
        @test st.source.token == "via-tool"
        @test !occursin("via-tool", String(integration_row(a, "toy").config))
        st.supervised.stopped[] = true
        @test occursin("- toy [enabled (stopped)]", Claw.list_integrations())

        msg = Claw.disable_integration("toy")
        @test occursin("disabled", msg)
        @test occursin("- toy [available]", Claw.list_integrations())
        @test occursin("not enabled", Claw.disable_integration("toy"))

        # handlers referencing the removed event type are marked inactive
        Claw._exec!(a.db, "INSERT OR IGNORE INTO claw_event_types (name, description) VALUES ('toy_event', 't')")
        Claw.register_event_handler!(a, Claw.EventHandler("toy-h", ["toy_event"], "", nothing))
        Claw._exec!(a.db, "DELETE FROM claw_event_types WHERE name = 'toy_event'")
        @test occursin("toy_event (inactive)", Claw.list_event_handlers())
    finally
        Claw.CURRENT_ASSISTANT[] = old
        Claw.shutdown!(a; timeout_s = 5)
    end
end

end # module IntegrationsTests
