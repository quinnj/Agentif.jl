# integrations_test.jl — Tier 1 integration enablement: catalog, factories,
# enable/disable, persisted enabled-set reconciliation, adoption of runner-passed
# sources, and the agent-facing tools.

module IntegrationsTests

using Test
using Agentif
using Claw
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
    started::Threads.Atomic{Bool}
    stopped::Threads.Atomic{Bool}
end
ToyEventSource(; token::String = "default-token") =
    ToyEventSource(token, Threads.Atomic{Bool}(false), Threads.Atomic{Bool}(false))

toy_tool_impl() = "toy"
const TOY_TOOL = Agentif.AgentTool{typeof(toy_tool_impl), @NamedTuple{}}(;
    name = "toy_integration_tool", description = "toy tool", func = toy_tool_impl)

Claw.get_channels(::ToyEventSource) = Agentif.AbstractChannel[ToyChannel("toy-chan")]
Claw.get_event_types(::ToyEventSource) = Claw.EventType[Claw.EventType("toy_event", "toy event")]
Claw.get_event_handlers(::ToyEventSource) = Claw.EventHandler[]
Claw.get_tools(::ToyEventSource) = Agentif.AgentTool[TOY_TOOL]
Claw.start!(es::ToyEventSource, ::Claw.AgentAssistant) = (es.started[] = true; nothing)
Claw.stop!(es::ToyEventSource) = (es.stopped[] = true; nothing)

const TOY_SPEC = Claw.IntegrationSpec("toy", "ToyPkg", "toy integration for tests",
    ["token" => "the toy token"])
Claw.register_integration!(TOY_SPEC, ToyEventSource)

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
        @test occursin("abc", String(row.config))
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

# ─── Persisted enabled-set reconciliation ───

@testset "init! reconciles the persisted enabled-set" begin
    path = tempname() * ".sqlite"
    a = make_assistant(path)
    a._state[] = :running
    Claw.enable_integration!(a, "toy"; config = Dict{String, Any}("token" => "persisted-token"))
    Claw.shutdown!(a; timeout_s = 5)

    # a fresh assistant on the same database re-enables it with the stored config
    b = Claw.init!(path;
        provider = "openai-completions", model_id = "gpt-4o-mini", apikey = "test-key",
        timezone = "UTC", level = :error,
        event_sources = Claw.EventSource[], install_signal_handlers = false)
    try
        st = lock(() -> get(b._integrations, "toy", nothing), b._integrations_lock)
        @test st !== nothing
        @test st.source.token == "persisted-token"
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
