using Test
using Agentif
using Base64
using HTTP
using JSON
using Logging
using LLMProviders
using LLMOAuth
using LocalSearch
using SQLite
using Sockets

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

function test_server_port(server)
    if applicable(HTTP.port, server)
        port = HTTP.port(server)
        port != 0 && return port
    end
    if hasproperty(server, :listener) && hasproperty(server.listener, :server)
        return Sockets.getsockname(server.listener.server)[2]
    end
    return parse(Int, last(rsplit(HTTP.WebSockets.server_addr(server), ':'; limit = 2)))
end

function test_websocket_request(ws)
    return hasproperty(ws, :handshake_request) ? ws.handshake_request : ws.request
end

function test_status_error(status::Integer)
    response = HTTP.Response(status)
    if applicable(HTTP.StatusError, status, "POST", "/x", response)
        return HTTP.StatusError(status, "POST", "/x", response)
    end
    return HTTP.StatusError(response)
end

function test_parse_error(message::AbstractString)
    if applicable(HTTP.ParseError, message)
        return HTTP.ParseError(message)
    end
    return HTTP.ParseError(:INVALID_STATUS_LINE, message)
end

function test_force_close_stream(http)
    if hasproperty(http, :tracked)
        tracked = http.tracked
        if tracked !== nothing && hasproperty(tracked, :conn)
            close(tracked.conn)
            return
        end
    end
    if hasproperty(http, :stream) && hasproperty(http.stream, :io)
        close(http.stream.io)
        return
    end
    error("Unable to find the test server stream transport")
end

function fake_jwt(payload::AbstractDict)
    encoded = Base64.base64encode(JSON.json(payload))
    encoded = replace(encoded, '+' => '-', '/' => '_')
    encoded = replace(encoded, "=" => "")
    return "header.$encoded.signature"
end

const CODEX_OAUTH_TEST_TOKEN = fake_jwt(Dict("https://api.openai.com/auth" => Dict("chatgpt_account_id" => "acct-jwt-1")))

struct MockOAuthBackend <: Agentif.AbstractOAuthBackend end

Agentif.get_codex_token(::MockOAuthBackend) = CODEX_OAUTH_TEST_TOKEN
Agentif.get_anthropic_token(::MockOAuthBackend) = "anthropic-token"

function with_oauth_backend(f::Function, backend::Agentif.AbstractOAuthBackend)
    previous = Agentif.OAUTH_BACKEND[]
    Agentif.OAUTH_BACKEND[] = backend
    try
        return f()
    finally
        Agentif.OAUTH_BACKEND[] = previous
    end
end

with_oauth_backend(backend::Agentif.AbstractOAuthBackend, f::Function) = with_oauth_backend(f, backend)

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

# ── Compaction/session integration helpers ──

# Minimal openai-completions SSE body carrying a single assistant text.
function summary_sse_body(text::String)
    chunks = String[]
    isempty(text) || push!(chunks, "data: " * JSON.json((; choices = [(; index = 0, delta = (; content = text), finish_reason = nothing)])))
    push!(chunks, "data: " * JSON.json((; choices = [(; index = 0, delta = (;), finish_reason = "stop")])))
    push!(chunks, "data: [DONE]")
    return join(chunks, "\n\n") * "\n\n"
end

# Mock provider used for compaction's summarization call.
function start_summary_server(; summary_text::String = "SUMMARY", status::Int = 200,
        error_message::String = "bad request", hits = Ref(0))
    server = HTTP.serve!("127.0.0.1", 0) do req
        hits[] += 1
        status == 200 || return HTTP.Response(
            status,
            ["Content-Type" => "application/json"],
            JSON.json(Dict("error" => Dict("message" => error_message))),
        )
        return HTTP.Response(200, ["Content-Type" => "text/event-stream"], summary_sse_body(summary_text))
    end
    port = test_server_port(server)
    return server, port
end

function compaction_test_model(port::Integer; contextWindow::Int)
    return Model(
        id = "test-model", name = "test-model", api = "openai-completions",
        provider = "test", baseUrl = "http://127.0.0.1:$port", reasoning = false,
        input = ["text"],
        cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
        contextWindow = contextWindow, maxTokens = 4096,
    )
end

# Base handler with a scripted per-call usage/tool-call program. Records the
# messages it was handed on every call so tests can assert what the LLM would
# have seen.
function scripted_handler(; usage_inputs::Vector{Int} = Int[], tool_turns = Set{Int}(),
        calls = Ref(0), observed = Vector{Vector{AgentMessage}}())
    return function (f, agent::Agent, state::AgentState, input::Agentif.AgentTurnInput, abort::Agentif.Abort; kw...)
        calls[] += 1
        n = calls[]
        push!(observed, copy(state.messages))
        msg = AssistantMessage(; provider = "test", api = "test", model = "test")
        Agentif.append_text!(msg, "reply-$n")
        args = "{\"text\":\"t\"}"
        n in tool_turns && push!(msg.tool_calls, AgentToolCall(; call_id = "call-$n", name = "echo_back", arguments = args))
        tokens = n <= length(usage_inputs) ? usage_inputs[n] : 0
        Agentif.append_state!(state, input, msg, Usage(; input = tokens, total = tokens))
        if n in tool_turns
            state.pending_tool_calls = Agentif.PendingToolCall[Agentif.PendingToolCall(; call_id = "call-$n", name = "echo_back", arguments = args)]
            state.most_recent_stop_reason = :tool_calls
        else
            state.pending_tool_calls = Agentif.PendingToolCall[]
            state.most_recent_stop_reason = :stop
        end
        return state
    end
end

message_signatures(messages::AbstractVector{<:AgentMessage}) = [(typeof(m), message_text(m)) for m in messages]
message_signatures(state::AgentState) = message_signatures(state.messages)

struct SessionTestChannel <: Agentif.AbstractChannel
    id::String
    user::Union{Nothing, Agentif.ChannelUser}
    message_id::Union{Nothing, String}
end

Agentif.channel_id(ch::SessionTestChannel) = ch.id
Agentif.get_current_user(ch::SessionTestChannel) = ch.user
Agentif.entry_id(ch::SessionTestChannel) = ch.message_id

struct ProactiveSessionTestChannel <: Agentif.AbstractChannel
    id::String
    response_id::String
end

Agentif.channel_id(ch::ProactiveSessionTestChannel) = ch.id
Agentif.response_entry_id(ch::ProactiveSessionTestChannel) = ch.response_id

mutable struct StreamTestChannel <: Agentif.AbstractChannel
    id::String
    started::Int
    finished::Int
    closed::Int
    deltas::Vector{String}
end

StreamTestChannel(id::String = "stream-test") = StreamTestChannel(id, 0, 0, 0, String[])

Agentif.channel_id(ch::StreamTestChannel) = ch.id
Agentif.start_streaming(ch::StreamTestChannel) = (ch.started += 1)
Agentif.append_to_stream(ch::StreamTestChannel, delta::AbstractString) = push!(ch.deltas, String(delta))
Agentif.finish_streaming(ch::StreamTestChannel) = (ch.finished += 1)
Agentif.send_message(::StreamTestChannel, ::Any) = nothing
Agentif.close_channel(ch::StreamTestChannel) = (ch.closed += 1)

@testset "public API bindings" begin
    tool = @tool "Echo text." echo_text(text::String) = text
    @test tool_name(tool) == "echo_text"
    agent = make_agent(; tools = [tool])
    @test eltype(agent.tools) === typeof(tool)
    @test @inferred(Agentif.findtool(agent.tools, "echo_text")) === tool
    default_agent = Agent(
        id = "default-tools",
        prompt = "test",
        model = dummy_model(),
        apikey = "test-key",
    )
    @test Agentif.openai_responses_build_tools(default_agent.tools) === nothing
    @test Agentif.openai_completions_build_tools(default_agent.tools) === nothing
    @test Agentif.build_codex_tools(default_agent.tools) === nothing
    @test Agentif.google_generative_build_tools(default_agent.tools) === nothing
    @test Agentif.google_gemini_cli_build_tools(default_agent.tools) === nothing
    tool_name_map, tool_name_reverse_map =
        Agentif.anthropic_tool_name_maps(default_agent.tools, true)
    @test isempty(tool_name_map)
    @test isempty(tool_name_reverse_map)
    @test Agentif.anthropic_build_tools(default_agent.tools, tool_name_map) === nothing
    pending = Agentif.PendingToolCall(; call_id = "call-1", name = "echo_pending", arguments = "{}")
    @test tool_name(pending) == "echo_pending"
    @test tool_name("literal-name") == "literal-name"
end

let
    provider = get(ENV, "CLAW_AGENT_PROVIDER", "")
    model_id = get(ENV, "CLAW_AGENT_MODEL", "")
    apikey = get(ENV, "CLAW_AGENT_API_KEY", "")

    if !isempty(provider) && !isempty(model_id) && !isempty(apikey)
        @testset "stream (MiniMax live)" begin
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
    else
        @info "Skipping live MiniMax tests; CLAW_AGENT_* env vars are not set."
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

@testset "tool result truncation" begin
    # Save and override the limit for testing
    original_limit = Agentif.MAX_TOOL_RESULT_BYTES[]
    Agentif.MAX_TOOL_RESULT_BYTES[] = 100  # 100 bytes for easy testing
    try
        big_output = "x" ^ 500  # 500 bytes, well over the 100 byte limit
        big_tool = @tool "Return a huge string." huge_tool() = big_output
        base_handler = make_base_handler(; with_tool_call = true)
        # Patch the base handler to call our big tool instead of echo
        patched_handler = function (f, agent::Agent, state::AgentState, current_input::Agentif.AgentTurnInput, abort::Agentif.Abort; kw...)
            if current_input isa String
                msg = AssistantMessage(; provider = "test", api = "test", model = "test")
                call = AgentToolCall(; call_id = "call-1", name = "huge_tool", arguments = "{}")
                push!(msg.tool_calls, call)
                Agentif.append_state!(state, current_input, msg, Usage())
                state.pending_tool_calls = [Agentif.PendingToolCall(; call_id = "call-1", name = "huge_tool", arguments = "{}")]
                state.most_recent_stop_reason = :tool_calls
            else
                msg = AssistantMessage(; provider = "test", api = "test", model = "test")
                Agentif.append_state!(state, current_input, msg, Usage())
                state.pending_tool_calls = Agentif.PendingToolCall[]
                state.most_recent_stop_reason = :stop
            end
            return state
        end
        handler = tool_call_middleware(patched_handler)
        agent = make_agent(; tools = [big_tool])
        state = AgentState()
        result_state = handler(identity, agent, state, "test", Abort())
        # Find the tool result in the messages
        tool_result_msgs = filter(m -> m isa ToolResultMessage, result_state.messages)
        @test length(tool_result_msgs) >= 1
        result_text = message_text(tool_result_msgs[end])
        @test sizeof(result_text) < 500  # Should be truncated from original 500 bytes
        @test occursin("[Tool result truncated:", result_text)
        @test occursin("500B", result_text)  # Original size shown in notice
    finally
        Agentif.MAX_TOOL_RESULT_BYTES[] = original_limit
    end

    # Test that results under the limit are NOT truncated
    small_tool = @tool "Return a small string." small_tool() = "small"
    tc = Agentif.PendingToolCall(; call_id = "call-2", name = "small_tool", arguments = "{}")
    trm = wait(Agentif.call_function_tool!(identity, small_tool, tc))
    @test message_text(trm) == "small"
    @test !occursin("[Tool result truncated:", message_text(trm))
end

@testset "tool error diagnostics as JSON" begin
    exploding_tool = @tool "Always throws." explode(x::Int) = error("boom: $x")
    tc = Agentif.PendingToolCall(; call_id = "call-explode", name = "explode", arguments = "{\"x\":7}")
    trm = wait(Agentif.call_function_tool!(identity, exploding_tool, tc))
    @test trm.is_error
    payload = JSON.parse(message_text(trm))
    @test payload["ok"] == false
    @test payload["error_kind"] == "tool_execution_failed"
    @test payload["tool"] == "explode"
    @test payload["call_id"] == "call-explode"
    @test payload["message"] == "boom: 7"
    @test !haskey(payload, "stacktrace")

    payload_debug = Agentif.with_log_level(Debug) do
        trm_debug = wait(Agentif.call_function_tool!(identity, exploding_tool, tc))
        JSON.parse(message_text(trm_debug))
    end
    @test haskey(payload_debug, "stacktrace")

    tc_parse = Agentif.PendingToolCall(; call_id = "call-parse", name = "explode", arguments = "{\"missing\":1}")
    trm_parse = wait(Agentif.call_function_tool!(identity, exploding_tool, tc_parse))
    @test trm_parse.is_error
    parse_payload = JSON.parse(message_text(trm_parse))
    @test parse_payload["error_kind"] == "tool_argument_parse_failed"
    @test parse_payload["tool"] == "explode"
    @test haskey(parse_payload, "raw_arguments")
end

# Regression: tool_fuzz.jl found that a confused model's arguments produced raw
# Julia conversion errors (`Cannot convert Int64 to String`) that name no field,
# and that truncated argument JSON escaped as a BoundsError from JSON.jl's own
# error-reporting path. Both must arrive as field-level validation errors.
@testset "tool argument validation errors" begin
    T = @NamedTuple{cmd::String, workdir::Union{Nothing, String}, yield_time_ms::Union{Nothing, Int}}
    parse_message(args) = try
        Agentif.parse_tool_arguments(args, T)
        nothing
    catch e
        e isa Agentif.ToolArgumentError || rethrow()
        sprint(showerror, e)
    end

    @test parse_message("{\"cmd\":12345}") ==
        "argument `cmd` expects a string, but received an integer"
    @test parse_message("{\"cmd\":[\"ls\",\"-la\"]}") ==
        "argument `cmd` expects a string, but received an array"
    @test parse_message("{\"cmd\":null}") ==
        "argument `cmd` expects a string, but received null"
    @test parse_message("{\"cmd\":{\"a\":1}}") ==
        "argument `cmd` expects a string, but received an object"
    @test parse_message("{\"workdir\":\"/tmp\"}") ==
        "missing required argument `cmd` (expected a string)"
    @test parse_message("{\"cmd\":\"ls\",\"yield_time_ms\":\"soon\"}") ==
        "argument `yield_time_ms` expects an integer or null, but received a string"
    # every bad field is reported, so one round trip is enough to fix them all
    @test parse_message("{\"cmd\":1,\"yield_time_ms\":\"soon\"}") ==
        "argument `cmd` expects a string, but received an integer; " *
        "argument `yield_time_ms` expects an integer or null, but received a string"
    @test parse_message("\"echo hi\"") ==
        "expected a JSON object of arguments, but received a string"
    # JSON.jl v1.7.1 raises BoundsError, not its own ArgumentError, when the
    # input ends mid-token; the call site must absorb that.
    @test parse_message("{\"cmd\":\"echo") ==
        "the arguments are not valid JSON: the input ends unexpectedly (truncated or malformed)"
    @test parse_message("{") ==
        "the arguments are not valid JSON: the input ends unexpectedly (truncated or malformed)"
    # JSON.jl's own diagnostic survives when it is well formed
    @test occursin("invalid JSON at byte position", parse_message("{cmd:\"echo hi\"}"))

    # valid arguments are untouched, optional fields included
    @test Agentif.parse_tool_arguments("{\"cmd\":\"echo hi\"}", T) ==
        (cmd = "echo hi", workdir = nothing, yield_time_ms = nothing)
    @test Agentif.parse_tool_arguments("{\"cmd\":\"echo hi\",\"yield_time_ms\":500}", T) ==
        (cmd = "echo hi", workdir = nothing, yield_time_ms = 500)

    # the rendered envelope keeps its shape; only the message got specific
    typed_tool = @tool "Echoes." echoer(cmd::String) = cmd
    for (args, expected) in [
            ("{\"cmd\":12345}", "argument `cmd` expects a string, but received an integer"),
            ("{\"cmd\":\"echo", "the input ends unexpectedly (truncated or malformed)"),
        ]
        tc = Agentif.PendingToolCall(; call_id = "call-bad", name = "echoer", arguments = args)
        trm = wait(Agentif.call_function_tool!(identity, typed_tool, tc))
        @test trm.is_error
        payload = JSON.parse(message_text(trm))
        @test payload["ok"] == false
        @test payload["error_kind"] == "tool_argument_parse_failed"
        @test payload["tool"] == "echoer"
        @test payload["call_id"] == "call-bad"
        @test payload["exception_type"] == "Agentif.ToolArgumentError"
        @test payload["raw_arguments"] == args
        @test occursin(expected, payload["message"])
    end
end

@testset "provider tool result output wrapping" begin
    err_output = JSON.json(Dict("ok" => false, "error_kind" => "tool_execution_failed", "message" => "boom"))
    result = ToolResultMessage("call-wrap", "explode", err_output; is_error = true)
    wrapped = Agentif.provider_tool_result_output(result)
    payload = JSON.parse(wrapped)
    @test payload["ok"] == false
    @test payload["tool_error"] == true
    @test payload["tool"] == "explode"
    @test payload["call_id"] == "call-wrap"
    @test haskey(payload, "error")
end

@testset "evaluate consumes level keyword" begin
    observed_kw = Ref{Any}(nothing)
    base_handler = function (_f, _agent::Agent, state::AgentState, _current_input::Agentif.AgentTurnInput, _abort::Agentif.Abort; kw...)
        observed_kw[] = kw
        return state
    end
    agent = make_agent()
    handler = @inferred Agentif.build_default_handler(;
        base_handler,
        compaction_config = nothing,
        steer_queue = nothing,
        message_queue = nothing,
        session_store = nothing,
        input_guardrail = nothing,
        skill_registry = nothing,
        channel = nothing,
    )
    @test handler isa Function
    state = Agentif.evaluate(identity, agent, "hello"; base_handler, level = :debug)
    @test state isa AgentState
    @test observed_kw[] !== nothing
    @test !haskey(observed_kw[], :level)
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
    ch = SessionTestChannel("chan:test", nothing, "msg-1")
    handler = session_middleware(base_handler, store; channel=ch)
    agent = make_agent()
    state = AgentState()
    result_state = handler(identity, agent, state, "hello", Abort())
    @test get_branch_leaf(store, "chan:test") !== nothing

    len1 = length(result_state.messages)
    ch2 = SessionTestChannel("chan:test", nothing, "msg-2")
    handler2 = session_middleware(base_handler, store; channel=ch2)
    result_state_2 = handler2(identity, agent, AgentState(), "again", Abort())
    @test length(result_state_2.messages) > len1
end

@testset "session_middleware channel isolation" begin
    store = InMemorySessionStore()
    handler = session_middleware(make_base_handler(), store)
    agent = make_agent()
    ch1 = SessionTestChannel("chan:iso-1", Agentif.ChannelUser("U1", "One"), "p1")
    ch2 = SessionTestChannel("chan:iso-2", Agentif.ChannelUser("U2", "Two"), "p2")

    Agentif.with_channel(ch1) do
        handler(identity, agent, AgentState(), "hello from one", Abort())
    end
    Agentif.with_channel(ch2) do
        handler(identity, agent, AgentState(), "hello from two", Abort())
    end
    ch1b = SessionTestChannel("chan:iso-1", Agentif.ChannelUser("U1", "One"), "p1b")
    Agentif.with_channel(ch1b) do
        handler(identity, agent, AgentState(), "followup one", Abort())
    end

    # Different channels have different branches
    @test get_branch_leaf(store, "chan:iso-1") !== get_branch_leaf(store, "chan:iso-2")

    st1 = load_branch(store, "chan:iso-1")
    st2 = load_branch(store, "chan:iso-2")
    t1 = join([message_text(m) for m in st1.messages if m isa UserMessage], "\n")
    t2 = join([message_text(m) for m in st2.messages if m isa UserMessage], "\n")
    @test occursin("hello from one", t1)
    @test occursin("followup one", t1)
    @test !occursin("hello from two", t1)
    @test occursin("hello from two", t2)
    @test !occursin("hello from one", t2)
end

@testset "SessionEntry metadata serialization" begin
    entry = SessionEntry(;
        id = "entry-1",
        created_at = 123.0,
        messages = AgentMessage[UserMessage("hello")],
        is_compaction = false,
        user_id = "U123",
        channel_id = "chan:123",
        search_channel_id = "chan:123",
        channel_flags = 0x03,
    )
    roundtrip = JSON.parse(JSON.json(entry), SessionEntry)
    @test roundtrip.user_id == "U123"
    @test roundtrip.channel_id == "chan:123"
    @test roundtrip.search_channel_id == "chan:123"
    @test roundtrip.channel_flags == 3
    @test roundtrip.id == "entry-1"
    @test roundtrip.messages[1] isa UserMessage
end

@testset "session_middleware captures channel metadata" begin
    store = InMemorySessionStore()
    handler = session_middleware(make_base_handler(), store)
    agent = make_agent()
    channel = SessionTestChannel("chan:1", Agentif.ChannelUser("U555", "Taylor"), "post-777")

    Agentif.with_channel(channel) do
        handler(identity, agent, AgentState(), "hello", Abort())
    end

    leaf_id = get_branch_leaf(store, "chan:1")
    @test leaf_id !== nothing
    entry = get_entry(store, leaf_id)
    @test entry !== nothing
    @test entry.user_id == "U555"
    @test entry.channel_id == "chan:1"
    @test entry.search_channel_id == "chan:1"
    # SessionTestChannel defaults: is_group=false, is_private=true → flags=0x01
    @test entry.channel_flags == 1
end

@testset "InMemorySessionStore tree-structured lineage" begin
    store = InMemorySessionStore()
    # Build a 3-entry linear chain: e1 → e2 → e3
    append_entry!(store, SessionEntry(; id="e1", messages=AgentMessage[UserMessage("hello")]))
    append_entry!(store, SessionEntry(; id="e2", parent_id="e1", messages=AgentMessage[UserMessage("world")]))
    append_entry!(store, SessionEntry(; id="e3", parent_id="e2", messages=AgentMessage[UserMessage("!")]))
    set_branch_leaf!(store, "branch-1", "e3")

    state = load_branch(store, "branch-1")
    user_msgs = [Agentif.message_text(m) for m in state.messages if m isa UserMessage]
    @test user_msgs == ["hello", "world", "!"]

    # Search
    results = search_sessions(store, "hello world"; limit=5)
    @test !isempty(results)
end

@testset "AgentifSQLiteExt session store" begin
    @test isdefined(Agentif, :SQLiteSessionStore)
    store = Agentif.SQLiteSessionStore(tempname(); embed = nothing)
    db = store.db
    search_store = store.search_store

    entry = SessionEntry(;
        id = "entry-1",
        created_at = 1000.5,
        messages = AgentMessage[UserMessage("hello sqlite world")],
        user_id = "U100",
        channel_id = "chan:alpha",
        search_channel_id = "chan:alpha",
    )
    append_entry!(store, entry)

    channel_entry = SessionEntry(;
        id = "entry-2",
        parent_id = "entry-1",
        created_at = 1001.5,
        messages = AgentMessage[UserMessage("second sqlite row")],
        user_id = "U200",
        channel_id = "chan:beta",
        search_channel_id = "chan:beta",
    )
    append_entry!(store, channel_entry)
    set_branch_leaf!(store, "branch-1", "entry-2")

    @test get_entry(store, "entry-1") !== nothing
    @test get_entry(store, "entry-2") !== nothing
    @test get_branch_leaf(store, "branch-1") == "entry-2"

    state = load_branch(store, "branch-1")
    user_msgs = [Agentif.message_text(m) for m in state.messages if m isa UserMessage]
    @test user_msgs == ["hello sqlite world", "second sqlite row"]

    rows = SQLite.rowtable(SQLite.DBInterface.execute(
        db,
        "SELECT entry, user_id, channel_id FROM session_entries WHERE entry_id = ?",
        ("entry-1",),
    ))
    @test length(rows) == 1
    row = only(rows)
    parsed = JSON.parse(row.entry, SessionEntry)
    @test parsed.id == "entry-1"
    @test parsed.user_id == "U100"
    @test parsed.channel_id == "chan:alpha"
    @test row.user_id == "U100"
    @test row.channel_id == "chan:alpha"

    results = LocalSearch.search(search_store, "hello sqlite world"; limit = 5)
    matches = filter(r -> startswith(r.id, "session:entry:entry-1"), results)
    @test !isempty(matches)
    @test occursin("\"id\":\"entry-1\"", matches[1].text)
    @test occursin("\"messages\":", matches[1].text)
    @test occursin("\"channel_id\":\"chan:alpha\"", matches[1].text)
    tag_rows = SQLite.DBInterface.execute(
        db,
        "SELECT dt.tag FROM document_tags dt JOIN documents d ON d.id = dt.document_id WHERE d.key = ?",
        ("session:entry:entry-1",),
    )
    tags = String[String(r.tag) for r in tag_rows]
    @test "session_entry" in tags
    # entry has no channel_flags → tagged as public
    @test "session:public" in tags
    @test "session:ch:chan:alpha" in tags
end

@testset "AgentifSQLiteExt schema checks release read snapshots" begin
    path = joinpath(mktempdir(), "session.sqlite")
    initial = SQLite.DB(path)
    Agentif.init_sqlite_session_schema!(initial)
    close(initial)

    # On an existing schema, `_ensure_column!` finds `post_id` before the end of
    # PRAGMA table_info. It must still close that cursor so this connection can
    # observe commits made through another WAL connection.
    reader = SQLite.DB(path)
    Agentif.init_sqlite_session_schema!(reader)
    writer = SQLite.DB(path)
    SQLite.execute(writer,
        "INSERT INTO session_branches (branch_id, leaf_entry_id) VALUES ('probe', 'fresh')")
    leaves = String[
        String(row.leaf_entry_id)
        for row in SQLite.DBInterface.execute(
            reader,
            "SELECT leaf_entry_id FROM session_branches WHERE branch_id = 'probe'",
        )
    ]
    @test leaves == ["fresh"]
    close(writer)
    close(reader)
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
    @test "channel_id" in cols
    @test "search_channel_id" in cols
    @test "channel_flags" in cols
    @test "parent_id" in cols
    @test "first_kept_entry_id" in cols
end

@testset "session search channel visibility" begin
    store = InMemorySessionStore()

    # Manually append entries with different channel visibility
    public_entry = SessionEntry(;
        id = "pub-1", messages = AgentMessage[UserMessage("public info")],
        channel_id = "chan:public", search_channel_id = "chan:public", channel_flags = 0x02,  # is_group=true, is_private=false
    )
    private_entry = SessionEntry(;
        id = "priv-1", messages = AgentMessage[UserMessage("private secret")],
        channel_id = "chan:dm", search_channel_id = "chan:dm", channel_flags = 0x01,  # is_group=false, is_private=true
    )
    private_group_entry = SessionEntry(;
        id = "pgrp-1", messages = AgentMessage[UserMessage("private group info")],
        channel_id = "chan:pgroup", search_channel_id = "chan:pgroup", channel_flags = 0x03,  # is_group=true, is_private=true
    )
    legacy_entry = SessionEntry(;
        id = "legacy-1", messages = AgentMessage[UserMessage("legacy data")],
    )
    for e in [public_entry, private_entry, private_group_entry, legacy_entry]
        append_entry!(store, e)
    end

    # No channel context → see everything
    all_results = search_sessions(store, "info secret data"; limit=10)
    @test length(all_results) == 4

    # From the public channel → see public + legacy + own channel, NOT other private channels
    pub_results = search_sessions(store, "info secret data"; limit=10, current_search_channel_id="chan:public")
    @test length(pub_results) == 2  # public_entry + legacy_entry

    # From the DM → see own DM + public + legacy, NOT private group
    dm_results = search_sessions(store, "info secret data"; limit=10, current_search_channel_id="chan:dm")
    @test length(dm_results) == 3  # private_entry + public_entry + legacy_entry

    # From the private group → see own group + public + legacy, NOT DM
    pgrp_results = search_sessions(store, "info secret data"; limit=10, current_search_channel_id="chan:pgroup")
    @test length(pgrp_results) == 3  # private_group_entry + public_entry + legacy_entry
end

@testset "channel_middleware" begin
    @testset "suppresses NO_REPLY_SENTINEL output" begin
        ch = StreamTestChannel()
        base_handler = function (f, agent::Agent, state::AgentState, current_input::Agentif.AgentTurnInput, abort::Agentif.Abort; kw...)
            msg = AssistantMessage(; provider = "test", api = "test", model = "test")
            f(MessageStartEvent(:assistant, msg))
            f(MessageUpdateEvent(:assistant, msg, :text, string(Agentif.NO_REPLY_SENTINEL, "ignore me"), nothing))
            f(MessageEndEvent(:assistant, msg))
            Agentif.append_state!(state, current_input, msg, Usage())
            state.pending_tool_calls = Agentif.PendingToolCall[]
            state.most_recent_stop_reason = :stop
            return state
        end
        handler = channel_middleware(base_handler, ch)
        handler(identity, make_agent(), AgentState(), "hello", Abort())
        @test ch.started == 0
        @test isempty(ch.deltas)
        @test ch.finished == 0
        @test ch.closed == 1
    end

    @testset "streams regular assistant text and closes channel on error" begin
        ch = StreamTestChannel()
        base_handler = function (f, agent::Agent, state::AgentState, current_input::Agentif.AgentTurnInput, abort::Agentif.Abort; kw...)
            msg = AssistantMessage(; provider = "test", api = "test", model = "test")
            f(MessageStartEvent(:assistant, msg))
            f(MessageUpdateEvent(:assistant, msg, :text, "hello", nothing))
            f(MessageUpdateEvent(:assistant, msg, :text, " world", nothing))
            f(MessageEndEvent(:assistant, msg))
            throw(ErrorException("boom"))
        end
        handler = channel_middleware(base_handler, ch)
        @test_throws ErrorException handler(identity, make_agent(), AgentState(), "hello", Abort())
        @test ch.started == 1
        @test ch.deltas == ["hello", " world"]
        @test ch.finished == 1
        @test ch.closed == 1
    end
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

    @testset "compaction_threshold" begin
        @test Agentif.compaction_threshold(100000, 16384) == 83616
        @test Agentif.compaction_threshold(4096, 16384) == 3276
        @test Agentif.compaction_threshold(4096, 0) == 4096
        @test Agentif.compaction_threshold(0, 10) == 0
    end

    @testset "find_cut_point" begin
        # Empty / single message: no cut point
        @test Agentif.find_cut_point(Agentif.StoredAgentMessage[], 100) == 0
        @test Agentif.find_cut_point(Agentif.StoredAgentMessage[UserMessage("hi")], 100) == 0

        # Build messages: User → Assistant → ToolResult → User → Assistant
        # Each ~100 chars ≈ 25 tokens
        msgs = Agentif.StoredAgentMessage[
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
        # Valid cut points are UserMessage or AssistantMessage not preceded by
        # an AssistantMessage with tool calls
        cut2 = Agentif.find_cut_point(msgs, 10)
        @test cut2 == 0 || msgs[cut2] isa UserMessage || msgs[cut2] isa AssistantMessage

        # With keep_recent very large, nothing to compact
        @test Agentif.find_cut_point(msgs, 100000) == 0

        # Cut point can land on UserMessage or AssistantMessage (at valid boundary)
        msgs2 = Agentif.StoredAgentMessage[
            UserMessage("a" ^ 100),
            AssistantMessage(; provider = "t", api = "t", model = "t"),
            UserMessage("b" ^ 100),
        ]
        Agentif.append_text!(msgs2[2], "x" ^ 100)
        # keep_recent=30 → walks back, candidate hits msg2 (AssistantMessage)
        # msg2 is a valid cut point (not preceded by an assistant with tool calls)
        cut3 = Agentif.find_cut_point(msgs2, 30)
        @test cut3 == 0 || msgs2[cut3] isa UserMessage || msgs2[cut3] isa AssistantMessage
    end

    @testset "format_messages_for_summary" begin
        msgs = Agentif.StoredAgentMessage[
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
        text2 = Agentif.format_messages_for_summary(Agentif.StoredAgentMessage[long_result])
        @test occursin("(truncated)", text2)
        @test length(text2) < 1000

        # Error tool result
        err_result = ToolResultMessage("c3", "bad_tool", "file not found"; is_error = true)
        text3 = Agentif.format_messages_for_summary(Agentif.StoredAgentMessage[err_result])
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
        entry1 = SessionEntry(; id="e1", messages = AgentMessage[UserMessage("hello")])
        Agentif.apply_session_entry!(state, entry1)
        @test length(state.messages) == 1

        entry2 = SessionEntry(; id="e2", messages = AgentMessage[
            AssistantMessage(; provider = "t", api = "t", model = "t"),
            UserMessage("followup"),
        ])
        Agentif.apply_session_entry!(state, entry2)
        @test length(state.messages) == 3

        # Compaction entry appends compaction + kept messages
        compaction_msg = CompactionSummaryMessage(; summary = "summary of prior conversation", tokens_before = 200, compacted_at = time())
        compaction_entry = SessionEntry(;
            id="c1",
            messages = AgentMessage[compaction_msg, UserMessage("recent message")],
            is_compaction = true,
        )
        Agentif.apply_session_entry!(state, compaction_entry)
        # apply_session_entry! just appends — lineage walk controls ordering
        @test state.messages[end-1] isa CompactionSummaryMessage
        @test state.messages[end] isa UserMessage
        @test message_text(state.messages[end]) == "recent message"

        # Subsequent normal entry appends after compaction
        entry3 = SessionEntry(; id="e3", messages = AgentMessage[UserMessage("after compaction")])
        Agentif.apply_session_entry!(state, entry3)
        @test message_text(state.messages[end]) == "after compaction"
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
            # "kept" was produced during this evaluation, so nothing of the
            # persisted prefix survived the cut.
            state.persisted_prefix_count = 0
            # Also add the assistant response
            msg = AssistantMessage(; provider = "test", api = "test", model = "test")
            Agentif.append_text!(msg, "response")
            Agentif.append_state!(state, input, msg, Usage())
            state.pending_tool_calls = Agentif.PendingToolCall[]
            state.most_recent_stop_reason = :stop
            return state
        end
        ch = SessionTestChannel("chan:compact", nothing, "msg-compact")
        handler = session_middleware(base_handler, store; channel=ch)
        agent = make_agent()
        state = AgentState()
        result = handler(identity, agent, state, "hello", Abort())

        # Verify last_compaction was cleared
        @test result.last_compaction === nothing

        # Loading the branch reproduces the in-memory state exactly — including
        # the kept message, which used to be dropped from persistence.
        loaded = load_branch(store, "chan:compact")
        @test loaded.messages[1] isa CompactionSummaryMessage
        @test loaded.messages[1].summary == "compacted"
        @test message_signatures(loaded) == message_signatures(result)
        @test any(m -> m isa UserMessage && message_text(m) == "kept", loaded.messages)
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

    @testset "compaction summary uses override model API" begin
        request_target = Ref("")
        server = HTTP.serve!("127.0.0.1", 0) do req
            request_target[] = string(req.target)
            if endswith(request_target[], "/chat/completions")
                sse = join([
                    "data: {\"id\":\"summary-1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"summary\"},\"finish_reason\":null}]}",
                    "data: {\"id\":\"summary-1\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}",
                    "data: [DONE]",
                ], "\n\n") * "\n\n"
                return HTTP.Response(
                    200, ["Content-Type" => "text/event-stream"], sse)
            end
            return HTTP.Response(400, "wrong provider API")
        end

        try
            port = test_server_port(server)
            summary_model = Model(
                id = "summary-model",
                name = "summary-model",
                api = "openai-completions",
                provider = "test",
                baseUrl = "http://127.0.0.1:$port/v1",
                reasoning = false,
                input = ["text"],
                cost = Dict(
                    "input" => 0.0,
                    "output" => 0.0,
                    "cacheRead" => 0.0,
                    "cacheWrite" => 0.0,
                ),
                contextWindow = 100000,
                maxTokens = 4096,
            )
            source_model = Model(
                id = "source-model",
                name = "source-model",
                api = "openai-responses",
                provider = "test",
                baseUrl = "http://127.0.0.1:$port/v1",
                reasoning = false,
                input = ["text"],
                cost = Dict(
                    "input" => 0.0,
                    "output" => 0.0,
                    "cacheRead" => 0.0,
                    "cacheWrite" => 0.0,
                ),
                contextWindow = 100000,
                maxTokens = 4096,
            )
            agent = Agent(
                id = "source-agent",
                prompt = "test",
                model = source_model,
                apikey = "test-key",
            )
            summary = Agentif.generate_summary(
                agent,
                Agentif.StoredAgentMessage[UserMessage("old context")],
                nothing,
                CompactionConfig(),
                summary_model,
            )
            @test summary == "summary"
            @test endswith(request_target[], "/chat/completions")
        finally
            close(server)
        end
    end

    @testset "CompactionConfig defaults" begin
        config = CompactionConfig()
        @test config.enabled == true
        @test config.reserve_tokens == 16384
        @test config.keep_recent_tokens == 20000
    end

    @testset "context overflow detection" begin
        @test Agentif.is_context_overflow_error("This model's maximum context length is 8192 tokens")
        @test Agentif.is_context_overflow_error("prompt is too long: 210000 tokens > 200000")
        @test Agentif.is_context_overflow_error(ErrorException("Requested tokens exceed context window"))
        @test !Agentif.is_context_overflow_error("rate limit exceeded")
        @test !Agentif.is_context_overflow_error(ErrorException("invalid api key"))
    end

    @testset "estimate_context_tokens" begin
        msgs = AgentMessage[UserMessage("a" ^ 400), UserMessage("b" ^ 400)]
        @test Agentif.estimate_context_tokens(msgs) == 200
        @test Agentif.estimate_context_tokens(AgentMessage[]) == 0
        state = AgentState(; messages = msgs)
        @test Agentif.current_context_tokens(state) == 200
        state.context_tokens = 5000
        @test Agentif.current_context_tokens(state) == 5000
    end

    @testset "context token usage includes new cache writes" begin
        state = AgentState(; usage = Usage(; input = 11, cacheRead = 13, cacheWrite = 17))
        Agentif._record_context_tokens!(state, 7)
        @test state.context_tokens == 34
    end

    @testset "persisted prefix excludes a leading compaction summary" begin
        summary = CompactionSummaryMessage(; summary = "old", tokens_before = 10, compacted_at = 1.0)
        state = AgentState(; messages = AgentMessage[summary, UserMessage("kept")])
        Agentif._reset_persisted_prefix!(state)
        @test state.persisted_prefix_start == 2
        @test state.persisted_prefix_count == 1
    end
end

# ── Compaction × session persistence ──
#
# These drive the real middleware stack (evaluate → session_middleware →
# tool_call_middleware → compaction_middleware → scripted base handler) with a
# mock provider serving the summarization call.

new_sqlite_store() = Agentif.SQLiteSessionStore(tempname(); embed = nothing)

const SESSION_STORE_FACTORIES = [
    ("in-memory", () -> InMemorySessionStore()),
    ("sqlite", new_sqlite_store),
]

@testset "compaction mid-evaluation round-trips through $label store" for (label, make_store) in SESSION_STORE_FACTORIES
    hits = Ref(0)
    server, port = start_summary_server(; summary_text = "SUMMARY-OF-OLD", hits)
    try
        store = make_store()
        model = compaction_test_model(port; contextWindow = 1000)
        tool = @tool "Echo text." echo_back(text::String) = "echoed"
        agent = Agent(; id = "a", prompt = "p", model = model, apikey = "k", tools = [tool])
        # threshold = 1000 - 200 = 800
        config = CompactionConfig(; enabled = true, reserve_tokens = 200, keep_recent_tokens = 100)
        calls = Ref(0)
        observed = Vector{Vector{AgentMessage}}()
        # call 3 (first call of the third evaluation) reports a context over the
        # threshold and requests a tool, so compaction fires mid-evaluation.
        base_handler = scripted_handler(; usage_inputs = [100, 100, 900, 100], tool_turns = Set([3]), calls, observed)

        run_eval(msg_id, input) = Agentif.evaluate(
            agent, input;
            session_store = store, channel = SessionTestChannel("chan:mid", nothing, msg_id),
            base_handler = base_handler, compaction_config = config,
        )

        run_eval("m1", "A" ^ 400)   # entry 1: [user, assistant]
        run_eval("m2", "B" ^ 400)   # entry 2: [user, assistant]
        result = run_eval("m3", "C" ^ 40)

        @test calls[] == 4
        @test hits[] == 1  # exactly one summarization call
        @test result.messages[1] isa CompactionSummaryMessage
        @test result.messages[1].summary == "SUMMARY-OF-OLD"

        loaded = load_branch(store, "chan:mid")
        # Invariant 1: reload == in-memory, message for message.
        @test message_signatures(loaded) == message_signatures(result)
        # The in-evaluation messages survived persistence (H1a).
        @test any(m -> m isa UserMessage && message_text(m) == "C" ^ 40, loaded.messages)
        @test count(m -> m isa AssistantMessage && message_text(m) == "reply-3", loaded.messages) == 1
        # Kept pre-evaluation history appears exactly once, summarized history not at all (H1b).
        @test count(m -> message_text(m) == "B" ^ 400, loaded.messages) == 1
        @test !any(m -> message_text(m) == "A" ^ 400, loaded.messages)
        @test count(m -> m isa CompactionSummaryMessage, loaded.messages) == 1
        # Nothing lost: user turn, assistant turn, tool result, final assistant.
        @test message_signatures(loaded) == [
            (CompactionSummaryMessage, "SUMMARY-OF-OLD"),
            (UserMessage, "B" ^ 400),
            (AssistantMessage, "reply-2"),
            (UserMessage, "C" ^ 40),
            (AssistantMessage, "reply-3"),
            (ToolResultMessage, "echoed"),
            (AssistantMessage, "reply-4"),
        ]

        # Loading again from the same leaf is stable (no growth/duplication).
        @test message_signatures(load_branch(store, "chan:mid")) == message_signatures(loaded)
    finally
        close(server)
    end
end

@testset "restored over-threshold session compacts on the first call ($label)" for (label, make_store) in SESSION_STORE_FACTORIES
    hits = Ref(0)
    server, port = start_summary_server(; summary_text = "RESTORED-SUMMARY", hits)
    try
        store = make_store()
        # threshold = 300 - 100 = 200; the two seeded evaluations estimate ~204
        model = compaction_test_model(port; contextWindow = 300)
        agent = Agent(; id = "a", prompt = "p", model = model, apikey = "k")
        config = CompactionConfig(; enabled = true, reserve_tokens = 100, keep_recent_tokens = 100)
        calls = Ref(0)
        observed = Vector{Vector{AgentMessage}}()
        # Every call reports zero usage: the trigger must come from the restored
        # messages themselves, not from an in-process token counter.
        base_handler = scripted_handler(; usage_inputs = Int[], calls, observed)

        run_eval(msg_id, input) = Agentif.evaluate(
            agent, input;
            session_store = store, channel = SessionTestChannel("chan:restore", nothing, msg_id),
            base_handler = base_handler, compaction_config = config,
        )

        run_eval("m1", "A" ^ 400)
        run_eval("m2", "B" ^ 400)
        result = run_eval("m3", "hello again")

        @test hits[] == 1
        # Invariant 4: the third evaluation compacted BEFORE its first LLM call.
        @test length(observed) == 3
        @test observed[3][1] isa CompactionSummaryMessage
        @test message_signatures(observed[3]) == [
            (CompactionSummaryMessage, "RESTORED-SUMMARY"),
            (UserMessage, "B" ^ 400),
            (AssistantMessage, "reply-2"),
        ]
        loaded = load_branch(store, "chan:restore")
        @test message_signatures(loaded) == message_signatures(result)
        @test !any(m -> message_text(m) == "A" ^ 400, loaded.messages)
    finally
        close(server)
    end
end

@testset "failed summary leaves history intact ($mode)" for (mode, server_kw) in [
        ("provider error", (; status = 400, error_message = "bad request")),
        ("empty summary", (; summary_text = "")),
        ("whitespace summary", (; summary_text = "   \n ")),
    ]
    hits = Ref(0)
    server, port = start_summary_server(; hits, server_kw...)
    try
        store = InMemorySessionStore()
        model = compaction_test_model(port; contextWindow = 300)
        agent = Agent(; id = "a", prompt = "p", model = model, apikey = "k")
        config = CompactionConfig(; enabled = true, reserve_tokens = 100, keep_recent_tokens = 100)
        calls = Ref(0)
        observed = Vector{Vector{AgentMessage}}()
        base_handler = scripted_handler(; calls, observed)

        run_eval(msg_id, input) = Agentif.evaluate(
            agent, input;
            session_store = store, channel = SessionTestChannel("chan:failsum", nothing, msg_id),
            base_handler = base_handler, compaction_config = config,
        )

        run_eval("m1", "A" ^ 400)
        run_eval("m2", "B" ^ 400)
        result = @test_logs (:warn,) match_mode = :any run_eval("m3", "still here")

        # Invariant 3: summarization was attempted and failed; nothing was lost.
        @test hits[] >= 1
        @test !any(m -> m isa CompactionSummaryMessage, result.messages)
        @test result.most_recent_stop_reason == :stop
        @test message_signatures(observed[3]) == [
            (UserMessage, "A" ^ 400),
            (AssistantMessage, "reply-1"),
            (UserMessage, "B" ^ 400),
            (AssistantMessage, "reply-2"),
        ]
        loaded = load_branch(store, "chan:failsum")
        @test message_signatures(loaded) == message_signatures(result)
        @test message_signatures(loaded) == [
            (UserMessage, "A" ^ 400),
            (AssistantMessage, "reply-1"),
            (UserMessage, "B" ^ 400),
            (AssistantMessage, "reply-2"),
            (UserMessage, "still here"),
            (AssistantMessage, "reply-3"),
        ]
    finally
        close(server)
    end
end

@testset "provider context overflow compacts and retries once" begin
    server, port = start_summary_server(; summary_text = "OVERFLOW-SUMMARY")
    try
        # Threshold (100000 - 16384) is far above the estimate, so the only
        # compaction that can happen is the one the overflow error triggers.
        model = compaction_test_model(port; contextWindow = 100000)
        agent = Agent(; id = "a", prompt = "p", model = model, apikey = "k")
        config = CompactionConfig(; enabled = true, reserve_tokens = 16384, keep_recent_tokens = 4)

        overflow_handler(overflow_calls) = function (f, agent::Agent, state::AgentState, input::Agentif.AgentTurnInput, abort::Agentif.Abort; kw...)
            overflow_calls[] += 1
            msg = AssistantMessage(; provider = "test", api = "test", model = "test")
            f(MessageStartEvent(:assistant, msg))
            if overflow_calls[] == 1
                f(MessageEndEvent(:assistant, msg))
                f(Agentif.AgentErrorEvent(ErrorException("prompt is too long: 210000 tokens > 200000 maximum")))
                Agentif.append_state!(state, input, msg, Usage())
                state.pending_tool_calls = Agentif.PendingToolCall[]
                state.most_recent_stop_reason = :error
                return state
            end
            Agentif.append_text!(msg, "recovered")
            f(MessageUpdateEvent(:assistant, msg, :text, "recovered", nothing))
            f(MessageEndEvent(:assistant, msg))
            Agentif.append_state!(state, input, msg, Usage())
            state.pending_tool_calls = Agentif.PendingToolCall[]
            state.most_recent_stop_reason = :stop
            return state
        end

        seed_messages() = AgentMessage[
            UserMessage("O" ^ 4000),
            let m = AssistantMessage(; provider = "t", api = "t", model = "t"); Agentif.append_text!(m, "a1"); m end,
            UserMessage("recent-keep"),
            let m = AssistantMessage(; provider = "t", api = "t", model = "t"); Agentif.append_text!(m, "a2"); m end,
        ]

        calls = Ref(0)
        events = Agentif.AgentEvent[]
        handler = compaction_middleware(overflow_handler(calls), config)
        result = handler(ev -> push!(events, ev), agent, AgentState(; messages = seed_messages()), "hello", Abort())

        @test calls[] == 2  # one failure, one retry — never more
        @test result.messages[1] isa CompactionSummaryMessage
        @test result.messages[1].summary == "OVERFLOW-SUMMARY"
        @test message_text(Agentif.last_assistant_message(result)) == "recovered"
        @test result.most_recent_stop_reason == :stop
        # The rejected turn is not duplicated, and the overflow error is not
        # surfaced because the retry succeeded.
        @test count(m -> m isa UserMessage && message_text(m) == "hello", result.messages) == 1
        @test !any(ev -> ev isa Agentif.AgentErrorEvent, events)
        @test count(ev -> ev isa MessageStartEvent, events) == 1
        @test count(ev -> ev isa MessageEndEvent, events) == 1

        # Nothing to compact → the original error is surfaced and the failed
        # turn's messages and lifecycle are left in place.
        calls2 = Ref(0)
        events2 = Agentif.AgentEvent[]
        handler2 = compaction_middleware(overflow_handler(calls2), config)
        result2 = handler2(ev -> push!(events2, ev), agent, AgentState(), "hello", Abort())
        @test calls2[] == 1
        @test !any(m -> m isa CompactionSummaryMessage, result2.messages)
        @test count(ev -> ev isa Agentif.AgentErrorEvent, events2) == 1
        @test count(ev -> ev isa MessageStartEvent, events2) == 1
        @test count(ev -> ev isa MessageEndEvent, events2) == 1
        @test count(m -> m isa UserMessage && message_text(m) == "hello", result2.messages) == 1

        # A thrown overflow that compaction cannot fix keeps propagating.
        throwing_handler = function (f, agent::Agent, state::AgentState, input::Agentif.AgentTurnInput, abort::Agentif.Abort; kw...)
            throw(ErrorException("This model's maximum context length is 8192 tokens"))
        end
        handler3 = compaction_middleware(throwing_handler, config)
        @test_throws ErrorException handler3(identity, agent, AgentState(), "hello", Abort())

        # …but a thrown overflow with compactable history is retried.
        calls4 = Ref(0)
        retry_after_throw = function (f, agent::Agent, state::AgentState, input::Agentif.AgentTurnInput, abort::Agentif.Abort; kw...)
            calls4[] += 1
            calls4[] == 1 && throw(ErrorException("This model's maximum context length is 8192 tokens"))
            msg = AssistantMessage(; provider = "test", api = "test", model = "test")
            Agentif.append_text!(msg, "recovered-after-throw")
            Agentif.append_state!(state, input, msg, Usage())
            state.pending_tool_calls = Agentif.PendingToolCall[]
            state.most_recent_stop_reason = :stop
            return state
        end
        handler4 = compaction_middleware(retry_after_throw, config)
        result4 = handler4(identity, agent, AgentState(; messages = seed_messages()), "hello", Abort())
        @test calls4[] == 2
        @test result4.messages[1] isa CompactionSummaryMessage
        @test message_text(Agentif.last_assistant_message(result4)) == "recovered-after-throw"

        # Once output is visible, retrying would duplicate it. Surface the
        # overflow and preserve the single partial response instead.
        progress_calls = Ref(0)
        progress_handler = function (f, agent::Agent, state::AgentState, input::Agentif.AgentTurnInput, abort::Agentif.Abort; kw...)
            progress_calls[] += 1
            msg = AssistantMessage(; provider = "test", api = "test", model = "test")
            f(MessageStartEvent(:assistant, msg))
            Agentif.append_text!(msg, "partial")
            f(MessageUpdateEvent(:assistant, msg, :text, "partial", nothing))
            f(MessageEndEvent(:assistant, msg))
            f(Agentif.AgentErrorEvent(ErrorException("prompt is too long after partial output")))
            Agentif.append_state!(state, input, msg, Usage())
            state.pending_tool_calls = Agentif.PendingToolCall[]
            state.most_recent_stop_reason = :error
            return state
        end
        progress_events = Agentif.AgentEvent[]
        handler5 = compaction_middleware(progress_handler, config)
        result5 = handler5(
            ev -> push!(progress_events, ev), agent,
            AgentState(; messages = seed_messages()), "hello", Abort(),
        )
        @test progress_calls[] == 1
        @test !any(m -> m isa CompactionSummaryMessage, result5.messages)
        @test count(ev -> ev isa Agentif.AgentErrorEvent, progress_events) == 1
        @test count(ev -> ev isa MessageUpdateEvent, progress_events) == 1
    finally
        close(server)
    end
end

@testset "newest compaction replaces older summaries ($label)" for (label, make_store) in SESSION_STORE_FACTORIES
    store = make_store()
    old_summary = CompactionSummaryMessage(; summary = "OLD-SUMMARY", tokens_before = 10, compacted_at = 1.0)
    new_summary = CompactionSummaryMessage(; summary = "NEW-SUMMARY", tokens_before = 20, compacted_at = 2.0)
    append_entry!(store, SessionEntry(; id = "e1", messages = AgentMessage[UserMessage("discarded")]))
    append_entry!(store, SessionEntry(; id = "e2", parent_id = "e1", messages = AgentMessage[UserMessage("old-kept")]))
    append_entry!(store, SessionEntry(; id = "e3", parent_id = "e2", messages = AgentMessage[UserMessage("new-kept")]))
    append_entry!(store, SessionEntry(;
        id = "c1", parent_id = "e3", messages = AgentMessage[old_summary],
        is_compaction = true, first_kept_entry_id = "e2",
    ))
    append_entry!(store, SessionEntry(; id = "e4", parent_id = "c1", messages = AgentMessage[UserMessage("after-old")]))
    append_entry!(store, SessionEntry(;
        id = "c2", parent_id = "e4", messages = AgentMessage[new_summary],
        is_compaction = true, first_kept_entry_id = "e3",
    ))
    set_branch_leaf!(store, "branch-two-compactions", "c2")

    @test message_signatures(load_branch(store, "branch-two-compactions")) == [
        (CompactionSummaryMessage, "NEW-SUMMARY"),
        (UserMessage, "new-kept"),
        (UserMessage, "after-old"),
    ]
end

@testset "second compaction round-trips exactly ($label)" for (label, make_store) in SESSION_STORE_FACTORIES
    hits = Ref(0)
    server, port = start_summary_server(; summary_text = "NEW-SUMMARY", hits)
    try
        store = make_store()
        old_summary = CompactionSummaryMessage(; summary = "OLD-SUMMARY", tokens_before = 100, compacted_at = 1.0)
        append_entry!(store, SessionEntry(;
            id = "old-kept", messages = AgentMessage[
                UserMessage("A" ^ 400),
                let msg = AssistantMessage(; provider = "test", api = "test", model = "test")
                    Agentif.append_text!(msg, "old reply")
                    msg
                end,
            ],
        ))
        append_entry!(store, SessionEntry(;
            id = "new-kept", parent_id = "old-kept", messages = AgentMessage[
                UserMessage("B" ^ 400),
                let msg = AssistantMessage(; provider = "test", api = "test", model = "test")
                    Agentif.append_text!(msg, "recent reply")
                    msg
                end,
            ],
        ))
        append_entry!(store, SessionEntry(;
            id = "old-compaction", parent_id = "new-kept", messages = AgentMessage[old_summary],
            is_compaction = true, first_kept_entry_id = "old-kept",
        ))
        set_branch_leaf!(store, "branch:repeat", "old-compaction")

        model = compaction_test_model(port; contextWindow = 280)
        agent = Agent(; id = "a", prompt = "p", model = model, apikey = "k")
        config = CompactionConfig(; enabled = true, reserve_tokens = 100, keep_recent_tokens = 100)
        result = Agentif.evaluate(
            agent, "next";
            session_store = store, channel = SessionTestChannel("branch:repeat", nothing, "repeat-post"),
            base_handler = scripted_handler(), compaction_config = config,
        )

        @test hits[] == 1
        @test message_signatures(result) == [
            (CompactionSummaryMessage, "NEW-SUMMARY"),
            (UserMessage, "B" ^ 400),
            (AssistantMessage, "recent reply"),
            (UserMessage, "next"),
            (AssistantMessage, "reply-1"),
        ]
        @test message_signatures(load_branch(store, "branch:repeat")) == message_signatures(result)
        @test result.persisted_prefix_start == 2
        @test result.persisted_prefix_count == length(result.messages) - 1
    finally
        close(server)
    end
end

@testset "mid-entry compaction cut round-trips exactly ($label)" for (label, make_store) in SESSION_STORE_FACTORIES
    server, port = start_summary_server(; summary_text = "MID-ENTRY-SUMMARY")
    try
        store = make_store()
        append_entry!(store, SessionEntry(;
            id = "combined-entry", messages = AgentMessage[
                UserMessage("D" ^ 400),
                let msg = AssistantMessage(; provider = "test", api = "test", model = "test")
                    Agentif.append_text!(msg, "discarded reply")
                    msg
                end,
                UserMessage("K" ^ 400),
                let msg = AssistantMessage(; provider = "test", api = "test", model = "test")
                    Agentif.append_text!(msg, "kept reply")
                    msg
                end,
            ],
        ))
        set_branch_leaf!(store, "branch:mid-entry", "combined-entry")

        model = compaction_test_model(port; contextWindow = 280)
        agent = Agent(; id = "a", prompt = "p", model = model, apikey = "k")
        config = CompactionConfig(; enabled = true, reserve_tokens = 100, keep_recent_tokens = 100)
        result = Agentif.evaluate(
            agent, "next";
            session_store = store, channel = SessionTestChannel("branch:mid-entry", nothing, "mid-entry-post"),
            base_handler = scripted_handler(), compaction_config = config,
        )

        @test message_signatures(result) == [
            (CompactionSummaryMessage, "MID-ENTRY-SUMMARY"),
            (UserMessage, "K" ^ 400),
            (AssistantMessage, "kept reply"),
            (UserMessage, "next"),
            (AssistantMessage, "reply-1"),
        ]
        @test message_signatures(load_branch(store, "branch:mid-entry")) == message_signatures(result)
        @test !any(m -> message_text(m) == "D" ^ 400, result.messages)
    finally
        close(server)
    end
end

@testset "compaction entry as branch leaf resumes with summary + kept ($label)" for (label, make_store) in SESSION_STORE_FACTORIES
    store = make_store()
    summary = CompactionSummaryMessage(; summary = "SUM", tokens_before = 10, compacted_at = 1.0)
    append_entry!(store, SessionEntry(; id = "e1", messages = AgentMessage[UserMessage("discarded-old")]))
    append_entry!(store, SessionEntry(; id = "e2", parent_id = "e1", messages = AgentMessage[UserMessage("kept-recent")]))
    append_entry!(store, SessionEntry(;
        id = "c1", parent_id = "e2", messages = AgentMessage[summary],
        is_compaction = true, first_kept_entry_id = "e2",
    ))
    set_branch_leaf!(store, "branch-leaf", "c1")

    # Invariant 2: leaf IS the compaction entry — summary + kept only.
    loaded = load_branch(store, "branch-leaf")
    @test message_signatures(loaded) == [(CompactionSummaryMessage, "SUM"), (UserMessage, "kept-recent")]

    state, boundaries = load_branch_with_boundaries(store, "branch-leaf")
    @test message_signatures(state) == message_signatures(loaded)
    @test [b.entry_id for b in boundaries] == ["c1", "e2"]

    # Everything compacted (no kept entries) stops at the compaction entry.
    append_entry!(store, SessionEntry(;
        id = "c2", parent_id = "e2", messages = AgentMessage[summary], is_compaction = true,
    ))
    set_branch_leaf!(store, "branch-all", "c2")
    @test message_signatures(load_branch(store, "branch-all")) == [(CompactionSummaryMessage, "SUM")]
end

@testset "sqlite scrub_post! removes replayable content" begin
    store = new_sqlite_store()
    append_entry!(store, SessionEntry(; id = "s1", messages = AgentMessage[UserMessage("keep alpha")], post_id = "post-1"))
    append_entry!(store, SessionEntry(; id = "s2", parent_id = "s1", messages = AgentMessage[UserMessage("secret bravo")], post_id = "post-2"))
    append_entry!(store, SessionEntry(; id = "s3", parent_id = "s2", messages = AgentMessage[UserMessage("keep charlie")], post_id = "post-3"))
    set_branch_leaf!(store, "branch-scrub", "s3")
    @test length(load_branch(store, "branch-scrub").messages) == 3

    scrub_post!(store, "post-2")

    # Invariant 5: content is gone from the lineage, tree structure intact.
    loaded = load_branch(store, "branch-scrub")
    @test message_signatures(loaded) == [(UserMessage, "keep alpha"), (UserMessage, "keep charlie")]
    @test !any(occursin("bravo", message_text(m)) for m in loaded.messages)
    scrubbed = get_entry(store, "s2")
    @test scrubbed !== nothing
    @test isempty(scrubbed.messages)
    @test scrubbed.is_deleted
    @test scrubbed.parent_id == "s1"
    @test get_entry(store, "s3").parent_id == "s2"
    # Stored JSON no longer carries the message text at all.
    rows = SQLite.rowtable(SQLite.DBInterface.execute(
        store.db,
        "SELECT entry FROM session_entries WHERE entry_id = ?",
        ("s2",),
    ))
    @test !occursin("bravo", String(only(rows).entry))
    # Search doc removed.
    results = LocalSearch.search(store.search_store, "secret bravo"; limit = 10)
    @test !any(r -> r.id == "session:entry:s2", results)
end

@testset "queued evaluations persist distinctly and stay scrubbable ($label)" for (label, make_store) in SESSION_STORE_FACTORIES
    store = make_store()
    message_queue = Channel{Agentif.AgentTurnInput}(1)
    put!(message_queue, "second message")
    # Same channel object for both evaluations → same platform entry id.
    ch = SessionTestChannel("chan:queued", nothing, "post-shared")
    result = Agentif.evaluate(
        make_agent(), "first message";
        session_store = store, channel = ch, message_queue = message_queue,
        base_handler = make_base_handler(), compaction_config = nothing,
    )

    # Invariant 6: both evaluations persisted (no UNIQUE violation, no clobber).
    @test length(result.messages) == 4
    loaded = load_branch(store, "chan:queued")
    @test message_signatures(loaded) == message_signatures(result)
    @test count(m -> m isa UserMessage && message_text(m) == "first message", loaded.messages) == 1
    @test count(m -> m isa UserMessage && message_text(m) == "second message", loaded.messages) == 1

    # …and scrubbing by the shared platform post id still clears both.
    scrub_post!(store, "post-shared")
    @test isempty(load_branch(store, "chan:queued").messages)
end

@testset "proactive response entries stay scrubbable ($label)" for (label, make_store) in SESSION_STORE_FACTORIES
    store = make_store()
    message_queue = Channel{Agentif.AgentTurnInput}(1)
    put!(message_queue, "second proactive message")
    ch = ProactiveSessionTestChannel("chan:proactive", "response-shared")
    result = Agentif.evaluate(
        make_agent(), "first proactive message";
        session_store = store, channel = ch, message_queue = message_queue,
        base_handler = make_base_handler(), compaction_config = nothing,
    )

    @test length(result.messages) == 4
    @test message_signatures(load_branch(store, "chan:proactive")) == message_signatures(result)
    scrub_post!(store, "response-shared")
    @test isempty(load_branch(store, "chan:proactive").messages)
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

@testset "openai_codex helpers" begin
    @test Agentif.clamp_reasoning_effort("gpt-5.3-codex-spark", "minimal") == "low"
    @test Agentif.clamp_reasoning_effort("gpt-5.3-codex-spark", "xhigh") == "xhigh"
    @test Agentif.clamp_reasoning_effort("gpt-5.2-codex", "minimal") == "low"
    @test Agentif.clamp_reasoning_effort("gpt-5.4", "minimal") == "low"
    @test Agentif.clamp_reasoning_effort("gpt-5.1", "xhigh") == "high"
    @test Agentif.clamp_reasoning_effort("gpt-5.1-codex-mini", "low") == "medium"
    @test Agentif.clamp_reasoning_effort("gpt-5.1-codex-mini", "xhigh") == "high"

    token = fake_jwt(Dict("https://api.openai.com/auth" => Dict("chatgpt_account_id" => "acct-123")))
    @test Agentif.codex_account_id_from_access_token(token) == "acct-123"
    @test Agentif.resolve_codex_account_id(nothing, token) == "acct-123"
    @test Agentif.resolve_codex_account_id("explicit-1", token) == "explicit-1"
    @test Agentif.codex_account_id_from_access_token("invalid-token") === nothing

    headers = Agentif.create_codex_headers(nothing, "acct-123", "tok", "sess-1")
    @test headers["chatgpt-account-id"] == "acct-123"
    @test headers["OpenAI-Beta"] == "responses=experimental"
    @test headers["originator"] == "pi"
    @test headers["session_id"] == "sess-1"
    @test headers["conversation_id"] == "sess-1"
    @test headers["Accept"] == "text/event-stream"
    ws_headers = Agentif.create_codex_websocket_headers(headers)
    @test ws_headers["OpenAI-Beta"] == "responses_websockets=2026-02-06"
    @test Agentif.codex_websocket_pool_key("wss://example.test/codex", headers) == (
        "wss://example.test/codex",
        "acct-123",
        "sess-1",
    )

    no_session_headers = Agentif.create_codex_headers(nothing, "acct-123", "tok", nothing)
    @test !haskey(no_session_headers, "session_id")
    @test !haskey(no_session_headers, "conversation_id")
    @test Agentif.codex_websocket_pool_key("wss://example.test/codex", no_session_headers) === nothing
    @test Agentif.normalize_codex_transport(nothing) == :sse
    @test Agentif.normalize_codex_transport("sse") == :sse
    @test Agentif.normalize_codex_transport("websocket") == :websocket
    @test Agentif.normalize_codex_transport("auto") == :auto
    @test Agentif.normalize_codex_transport(true) == :websocket
    @test_throws ArgumentError Agentif.normalize_codex_transport("bogus")
end

@testset "oauth apikey resolution" begin
    @test Base.get_extension(Agentif, :AgentifLLMOAuthExt) !== nothing
    @test Agentif.resolve_oauth_apikey(:codex, "explicit-token") == "explicit-token"
    @test with_oauth_backend(MockOAuthBackend(), () -> Agentif.resolve_oauth_apikey(:codex, "OAUTH")) == CODEX_OAUTH_TEST_TOKEN
    @test with_oauth_backend(MockOAuthBackend(), () -> Agentif.resolve_oauth_apikey(:anthropic, "OAUTH")) == "anthropic-token"
    @test_throws ArgumentError Agentif.resolve_oauth_apikey(:unknown, "OAUTH")
end

@testset "responses/codex history normalization" begin
    openai_model = Model(
        id = "gpt-5.2",
        name = "gpt-5.2",
        api = "openai-responses",
        provider = "openai",
        baseUrl = "https://api.openai.com/v1",
        reasoning = true,
        input = ["text"],
        cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
        contextWindow = 128000,
        maxTokens = 32000,
    )
    codex_model = Model(
        id = "gpt-5.2-codex",
        name = "gpt-5.2-codex",
        api = "openai-codex-responses",
        provider = "openai-codex",
        baseUrl = "https://chatgpt.com/backend-api",
        reasoning = true,
        input = ["text"],
        cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
        contextWindow = 128000,
        maxTokens = 32000,
    )

    let
        prior = AssistantMessage(
            provider = "openai",
            api = "openai-responses",
            model = "gpt-5.1",
        )
        push!(prior.content, Agentif.ToolCallContent(; id = "bad+call|item/with=chars__", name = "read", arguments = Dict("path" => "README.md")))
        state = AgentState(messages = AgentMessage[prior])
        items = Agentif.openai_responses_build_full_input(make_agent(), state, "continue", openai_model)

        function_calls = [item for item in items if item isa AbstractDict && get(() -> nothing, item, "type") == "function_call"]
        tool_outputs = [item for item in items if item isa AbstractDict && get(() -> nothing, item, "type") == "function_call_output"]

        @test length(function_calls) == 1
        @test get(() -> nothing, function_calls[1], "call_id") == "bad_call"
        @test !haskey(function_calls[1], "id")
        @test length(tool_outputs) == 1
        @test get(() -> nothing, tool_outputs[1], "call_id") == "bad_call"
        parsed_output = JSON.parse(get(() -> "{}", tool_outputs[1], "output"))
        @test get(() -> nothing, parsed_output, "message") == "No result provided"
        @test get(() -> nothing, parsed_output, "tool_error") == true
    end

    @test Agentif._responses_split_compound_id("café|élément") == ("café", "élément")
    @test Agentif._responses_split_compound_id("appel-é|élément") == ("appel-é", "élément")
    @test Agentif._responses_split_compound_id("|élément") == ("", "élément")
    @test Agentif._responses_split_compound_id("appel|") == ("appel", "")

    let
        prior = AssistantMessage(
            provider = "openai-codex",
            api = "openai-codex-responses",
            model = "gpt-5.1-codex",
        )
        push!(prior.content, Agentif.ToolCallContent(; id = "bad+call|item/with=chars__", name = "read", arguments = Dict("path" => "README.md")))
        state = AgentState(messages = AgentMessage[prior])
        items = Agentif.openai_responses_build_full_input(make_agent(), state, "continue", codex_model)

        function_calls = [item for item in items if item isa AbstractDict && get(() -> nothing, item, "type") == "function_call"]
        tool_outputs = [item for item in items if item isa AbstractDict && get(() -> nothing, item, "type") == "function_call_output"]

        @test length(function_calls) == 1
        @test get(() -> nothing, function_calls[1], "call_id") == "bad_call"
        @test !haskey(function_calls[1], "id")
        @test length(tool_outputs) == 1
        @test get(() -> nothing, tool_outputs[1], "call_id") == "bad_call"
        parsed_output = JSON.parse(get(() -> "{}", tool_outputs[1], "output"))
        @test get(() -> nothing, parsed_output, "message") == "No result provided"
        @test get(() -> nothing, parsed_output, "tool_error") == true
    end

    let
        prior = AssistantMessage(
            provider = "anthropic",
            api = "anthropic-messages",
            model = "claude-sonnet",
        )
        push!(prior.content, Agentif.ThinkingContent(; thinking = "cross-provider reasoning"))
        state = AgentState(messages = AgentMessage[prior])
        items = Agentif.openai_responses_build_full_input(make_agent(), state, "continue", codex_model)

        assistant_messages = [item for item in items if item isa AbstractDict && get(() -> nothing, item, "role") == "assistant"]
        reasoning_items = [item for item in items if item isa AbstractDict && get(() -> nothing, item, "type") == "reasoning"]

        @test isempty(reasoning_items)
        @test length(assistant_messages) == 1
        content = get(() -> Any[], assistant_messages[1], "content")
        @test content isa AbstractVector
        @test get(() -> nothing, content[1], "type") == "output_text"
        @test get(() -> nothing, content[1], "text") == "cross-provider reasoning"
    end
end

@testset "skill metadata unquoting is UTF-8 safe" begin
    @test Agentif.unquote("\"café\"") == "café"
    @test Agentif.unquote("'😀'") == "😀"
    @test Agentif.unquote("\"\"") == ""
end

@testset "openai request shaping and usage parity" begin
    @test Agentif.resolve_openai_cache_retention("none") == "none"
    @test Agentif.resolve_openai_cache_retention("long") == "long"
    @test Agentif.openai_prompt_cache_retention("https://api.openai.com/v1", "long") == "24h"
    @test Agentif.openai_prompt_cache_retention("http://127.0.0.1:8080/v1", "long") === nothing

    responses_usage = Agentif.openai_responses_usage_from_response(
        LLMProviders.OpenAIResponses.Usage(
            input_tokens = 10,
            input_tokens_details = (cached_tokens = 3,),
            output_tokens = 4,
            total_tokens = 14,
        ),
    )
    @test responses_usage.input == 7
    @test responses_usage.cacheRead == 3
    @test responses_usage.output == 4
    @test responses_usage.total == 14

    completions_usage = Agentif.openai_completions_usage_from_response(
        LLMProviders.OpenAICompletions.Usage(
            prompt_tokens = 10,
            completion_tokens = 4,
            total_tokens = 14,
            prompt_tokens_details = (cached_tokens = 3,),
            completion_tokens_details = (reasoning_tokens = 2,),
        ),
    )
    @test completions_usage.input == 7
    @test completions_usage.cacheRead == 3
    @test completions_usage.output == 6
    @test completions_usage.total == 16
end

@testset "completions message builder terminates on empty messages" begin
    model = Model(
        id = "test-model", name = "test-model", api = "openai-completions",
        provider = "test", baseUrl = "http://localhost", reasoning = false,
        input = ["text"],
        cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
        contextWindow = 100000, maxTokens = 4096,
    )
    agent = Agent(; id = "a", prompt = "p", model, apikey = "k")
    state = AgentState()
    # Empty assistant message (routinely produced by an errored/aborted turn) and
    # an image-only user message to a text-only model: both used to `continue`
    # without advancing the loop index, hanging the builder forever.
    push!(state.messages, AssistantMessage(; provider = "test", api = "openai-completions", model = "test-model"))
    push!(state.messages, UserMessage(Agentif.UserContentBlock[Agentif.ImageContent("aGk=", "image/png")]))
    result = Ref{Any}(nothing)
    t = @async (result[] = Agentif.openai_completions_build_messages(agent, state, "hi", model))
    timedwait(() -> istaskdone(t), 30.0)
    @test istaskdone(t)
    if istaskdone(t)
        msgs, _ = result[]
        @test !any(m -> m.role == "assistant", msgs)
        @test count(m -> m.role == "user", msgs) == 1
    end
end

@testset "utf8-safe truncation previews" begin
    s = repeat("é", 400)  # 2-byte chars: byte-index slicing throws StringIndexError
    p = Agentif.toolcall_preview(s; limit = 300)
    @test endswith(p, "...(truncated)")
    @test startswith(p, repeat("é", 300))
    t = Agentif.truncate_text(repeat("🐳", 50), 10)  # 4-byte chars
    @test startswith(t, repeat("🐳", 10))
    @test occursin("[truncated 40]", t)
end

@testset "openai_responses stream shapes GPT-5 requests and keeps incomplete as length" begin
    request_body = Ref(Dict{String, Any}())
    seen_events = Agentif.AgentEvent[]

    server = HTTP.serve!("127.0.0.1", 0) do req
        request_body[] = JSON.parse(String(req.body))
        sse = join([
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[]}}",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial\"}",
            "data: {\"type\":\"response.incomplete\",\"response\":{\"id\":\"resp_1\",\"model\":\"gpt-5.2\",\"status\":\"incomplete\",\"usage\":{\"input_tokens\":10,\"input_tokens_details\":{\"cached_tokens\":3},\"output_tokens\":4,\"total_tokens\":14}}}",
            "data: [DONE]",
        ], "\n\n") * "\n\n"
        return HTTP.Response(200, ["Content-Type" => "text/event-stream"], sse)
    end

    try
        port = test_server_port(server)
        model = Model(
            id = "gpt-5.2",
            name = "gpt-5.2",
            api = "openai-responses",
            provider = "openai",
            baseUrl = "http://127.0.0.1:$port",
            reasoning = true,
            input = ["text"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 128000,
            maxTokens = 32000,
        )
        agent = Agent(
            id = "responses-gpt5-test",
            prompt = "You are helpful.",
            model = model,
            apikey = "test-key",
            tools = AgentTool[],
        )

        result = stream(ev -> (push!(seen_events, ev); ev), agent, AgentState(), "Say hello", Abort(); sessionId = "sess-42")
        @test result.most_recent_stop_reason == :length
        errors = [sprint(showerror, ev.error) for ev in seen_events if ev isa Agentif.AgentErrorEvent]
        @test errors == String[]
        @test get(() -> nothing, request_body[], "prompt_cache_key") == "sess-42"
        @test !haskey(request_body[], "sessionId")
        input_items = get(() -> Any[], request_body[], "input")
        @test input_items isa AbstractVector
        @test get(() -> nothing, input_items[1], "role") == "developer"
        dev_content = get(() -> Any[], input_items[1], "content")
        @test dev_content isa AbstractVector
        @test get(() -> nothing, dev_content[1], "text") == "# Juice: 0 !important"
    finally
        close(server)
    end
end

@testset "openai_responses stream ends message once on response.completed" begin
    seen_events = Agentif.AgentEvent[]

    server = HTTP.serve!("127.0.0.1", 0) do req
        sse = join([
            "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"Think\",\"item_id\":\"rs_1\"}",
            # Arrives before the message item begins; must NOT end the message.
            "data: {\"type\":\"response.reasoning_summary_text.done\",\"text\":\"Think\",\"item_id\":\"rs_1\"}",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\",\"item_id\":\"msg_1\"}",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\" world\",\"item_id\":\"msg_1\"}",
            "data: {\"type\":\"response.output_text.done\",\"text\":\"Hello world\",\"item_id\":\"msg_1\"}",
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"model\":\"gpt-5.2\",\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":4,\"total_tokens\":14}}}",
            "data: [DONE]",
        ], "\n\n") * "\n\n"
        return HTTP.Response(200, ["Content-Type" => "text/event-stream"], sse)
    end

    try
        port = test_server_port(server)
        model = Model(
            id = "gpt-5.2",
            name = "gpt-5.2",
            api = "openai-responses",
            provider = "openai",
            baseUrl = "http://127.0.0.1:$port",
            reasoning = true,
            input = ["text"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 128000,
            maxTokens = 32000,
        )
        agent = Agent(
            id = "responses-end-once-test",
            prompt = "You are helpful.",
            model = model,
            apikey = "test-key",
            tools = AgentTool[],
        )

        result = stream(ev -> (push!(seen_events, ev); ev), agent, AgentState(), "Say hello", Abort())
        @test result.most_recent_stop_reason == :stop
        @test !any(ev -> ev isa Agentif.AgentErrorEvent, seen_events)
        end_indices = findall(ev -> ev isa Agentif.MessageEndEvent, seen_events)
        @test length(end_indices) == 1
        last_update = findlast(ev -> ev isa Agentif.MessageUpdateEvent, seen_events)
        @test last_update !== nothing && end_indices[1] > last_update
        assistant = result.messages[end]
        @test assistant isa AssistantMessage
        @test Agentif.message_text(assistant) == "Hello world"
        @test Agentif.message_thinking(assistant) == "Think"
    finally
        close(server)
    end
end

@testset "anthropic stream error event maps to error" begin
    seen_events = Agentif.AgentEvent[]

    server = HTTP.serve!("127.0.0.1", 0) do req
        sse = join([
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_e\",\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}",
            "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}",
        ], "\n\n") * "\n\n"
        return HTTP.Response(200, ["Content-Type" => "text/event-stream"], sse)
    end

    try
        port = test_server_port(server)
        model = Model(
            id = "claude-test",
            name = "claude-test",
            api = "anthropic-messages",
            provider = "anthropic",
            baseUrl = "http://127.0.0.1:$port",
            reasoning = false,
            input = ["text"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 200000,
            maxTokens = 8192,
        )
        agent = Agent(
            id = "anthropic-error-test",
            prompt = "You are helpful.",
            model = model,
            apikey = "test-key",
            tools = AgentTool[],
        )

        result = stream(ev -> (push!(seen_events, ev); ev), agent, AgentState(), "Hello", Abort())
        @test result.most_recent_stop_reason == :error
        @test count(ev -> ev isa Agentif.AgentErrorEvent, seen_events) == 1
        @test count(ev -> ev isa Agentif.MessageStartEvent, seen_events) == 1
        @test count(ev -> ev isa Agentif.MessageEndEvent, seen_events) == 1
    finally
        close(server)
    end
end

@testset "anthropic stream redacted thinking, unknown blocks, and usage merge" begin
    seen_events = Agentif.AgentEvent[]

    server = HTTP.serve!("127.0.0.1", 0) do req
        sse = join([
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_a\",\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":100,\"output_tokens\":1,\"cache_read_input_tokens\":40,\"cache_creation_input_tokens\":7}}}",
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"redacted_thinking\",\"data\":\"opaque-blob\"}}",
            "data: {\"type\":\"content_block_stop\",\"index\":0}",
            "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"server_tool_use\",\"id\":\"srvtoolu_1\",\"name\":\"web_search\",\"input\":{}}}",
            "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"citations_delta\",\"citation\":{\"url\":\"https://example.com\"}}}",
            "data: {\"type\":\"content_block_stop\",\"index\":1}",
            "data: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
            "data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}",
            "data: {\"type\":\"content_block_stop\",\"index\":2}",
            # Delta usage only carries output_tokens; input/cache from message_start must survive.
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":9}}",
            "data: {\"type\":\"message_stop\"}",
        ], "\n\n") * "\n\n"
        return HTTP.Response(200, ["Content-Type" => "text/event-stream"], sse)
    end

    try
        port = test_server_port(server)
        model = Model(
            id = "claude-test",
            name = "claude-test",
            api = "anthropic-messages",
            provider = "anthropic",
            baseUrl = "http://127.0.0.1:$port",
            reasoning = true,
            input = ["text"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 200000,
            maxTokens = 8192,
        )
        agent = Agent(
            id = "anthropic-redacted-test",
            prompt = "You are helpful.",
            model = model,
            apikey = "test-key",
            tools = AgentTool[],
        )

        result = stream(ev -> (push!(seen_events, ev); ev), agent, AgentState(), "Say hello", Abort())
        @test result.most_recent_stop_reason == :stop
        @test !any(ev -> ev isa Agentif.AgentErrorEvent, seen_events)

        assistant = result.messages[end]
        @test assistant isa AssistantMessage
        thinking_blocks = [b for b in assistant.content if b isa Agentif.ThinkingContent]
        @test length(thinking_blocks) == 1
        @test thinking_blocks[1].redacted
        @test thinking_blocks[1].thinking == ""
        @test thinking_blocks[1].thinkingSignature == "opaque-blob"
        @test Agentif.message_text(assistant) == "Hello"

        # Usage from message_start survives a delta that only carries output_tokens.
        @test result.usage.input == 100
        @test result.usage.output == 9
        @test result.usage.cacheRead == 40
        @test result.usage.cacheWrite == 7

        # Replay: redacted thinking converts back to a redacted_thinking wire block.
        replayed = Agentif.anthropic_message_from_agent(assistant, Dict{String, String}(), model)
        @test replayed !== nothing
        lowered = JSON.parse(JSON.json(replayed))
        content = lowered["content"]
        @test content[1]["type"] == "redacted_thinking"
        @test content[1]["data"] == "opaque-blob"
        @test content[end]["type"] == "text"
        @test content[end]["text"] == "Hello"

        # Session persistence round-trip keeps the redacted flag; legacy JSON
        # without the field still loads with redacted = false.
        roundtrip = JSON.parse(JSON.json(assistant), Agentif.AgentMessage)
        @test roundtrip isa AssistantMessage
        rt_thinking = [b for b in roundtrip.content if b isa Agentif.ThinkingContent]
        @test length(rt_thinking) == 1 && rt_thinking[1].redacted
        legacy = JSON.parse("{\"type\":\"thinking\",\"thinking\":\"t\",\"thinkingSignature\":null}", Agentif.ContentBlock)
        @test legacy isa Agentif.ThinkingContent
        @test legacy.redacted == false
    finally
        close(server)
    end
end

@testset "anthropic stream maps refusal to error stop reason" begin
    seen_events = Agentif.AgentEvent[]

    server = HTTP.serve!("127.0.0.1", 0) do req
        sse = join([
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_r\",\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":5,\"output_tokens\":1}}}",
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I can't help with that.\"}}",
            "data: {\"type\":\"content_block_stop\",\"index\":0}",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\"},\"usage\":{\"output_tokens\":6}}",
            "data: {\"type\":\"message_stop\"}",
        ], "\n\n") * "\n\n"
        return HTTP.Response(200, ["Content-Type" => "text/event-stream"], sse)
    end

    try
        port = test_server_port(server)
        model = Model(
            id = "claude-test",
            name = "claude-test",
            api = "anthropic-messages",
            provider = "anthropic",
            baseUrl = "http://127.0.0.1:$port",
            reasoning = false,
            input = ["text"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 200000,
            maxTokens = 8192,
        )
        agent = Agent(
            id = "anthropic-refusal-test",
            prompt = "You are helpful.",
            model = model,
            apikey = "test-key",
            tools = AgentTool[],
        )

        result = stream(ev -> (push!(seen_events, ev); ev), agent, AgentState(), "Do the thing", Abort())
        @test result.most_recent_stop_reason == :error
        @test !any(ev -> ev isa Agentif.AgentErrorEvent, seen_events)
    finally
        close(server)
    end
end

function anthropic_test_model(;
        id = "claude-opus-5",
        reasoning = true,
        maxTokens = 32000,
        baseUrl = "http://127.0.0.1:1",
        compat = nothing,
        thinkingLevelMap = nothing,
        kw = (;),
    )
    return Model(
        id = id,
        name = id,
        api = "anthropic-messages",
        provider = "anthropic",
        baseUrl = baseUrl,
        reasoning = reasoning,
        input = ["text"],
        cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
        contextWindow = 200000,
        maxTokens = maxTokens,
        compat = compat,
        thinkingLevelMap = thinkingLevelMap,
        kw = kw,
    )
end

@testset "anthropic per-model thinking capabilities" begin
    @test Agentif.anthropic_stop_reason(
        "model_context_window_exceeded", Agentif.AgentToolCall[]) == :length

    # Adaptive thinking: 4.6 family and newer
    @test Agentif.anthropic_supports_adaptive_thinking("claude-opus-4-6")
    @test Agentif.anthropic_supports_adaptive_thinking("claude-sonnet-4-6")
    @test Agentif.anthropic_supports_adaptive_thinking("claude-opus-5")
    @test Agentif.anthropic_supports_adaptive_thinking("claude-sonnet-5")
    @test Agentif.anthropic_supports_adaptive_thinking("claude-fable-5")
    @test Agentif.anthropic_supports_adaptive_thinking("claude-mythos-preview")
    @test !Agentif.anthropic_supports_adaptive_thinking("claude-opus-4-5")
    @test !Agentif.anthropic_supports_adaptive_thinking("claude-haiku-4-5-20251001")

    # Extended thinking (budget_tokens): everything except the adaptive-only models
    @test Agentif.anthropic_supports_extended_thinking("claude-haiku-4-5-20251001")
    @test Agentif.anthropic_supports_extended_thinking("claude-sonnet-4-5")
    @test Agentif.anthropic_supports_extended_thinking("claude-opus-4-6")   # deprecated but accepted
    @test !Agentif.anthropic_supports_extended_thinking("claude-opus-4-7")
    @test !Agentif.anthropic_supports_extended_thinking("claude-opus-5")
    @test !Agentif.anthropic_supports_extended_thinking("claude-sonnet-5")
    @test !Agentif.anthropic_supports_extended_thinking("claude-fable-5")
    @test Agentif.anthropic_supports_extended_thinking("claude-mythos-preview")

    # Thinking cannot be turned off on the always-thinking models
    @test Agentif.anthropic_thinking_always_on("claude-fable-5")
    @test Agentif.anthropic_thinking_always_on("claude-mythos-5")
    @test Agentif.anthropic_thinking_always_on("claude-mythos-preview")
    @test !Agentif.anthropic_thinking_always_on("claude-opus-5")

    # effort: 4.6 family and newer, plus Opus 4.5 (the one extended-only model with effort)
    @test Agentif.anthropic_supports_effort("claude-opus-4-5")
    @test Agentif.anthropic_supports_effort("claude-sonnet-4-6")
    @test !Agentif.anthropic_supports_effort("claude-haiku-4-5-20251001")
    @test !Agentif.anthropic_supports_effort("claude-sonnet-4-5")
    # max: 4.6 family and newer; xhigh: Opus 4.7+ / Sonnet 5 / Fable 5 only
    @test Agentif.anthropic_supports_max_effort("claude-sonnet-4-6")
    @test !Agentif.anthropic_supports_max_effort("claude-opus-4-5")
    @test Agentif.anthropic_supports_xhigh_effort("claude-opus-4-7")
    @test Agentif.anthropic_supports_xhigh_effort("claude-sonnet-5")
    @test !Agentif.anthropic_supports_xhigh_effort("claude-opus-4-6")
    @test !Agentif.anthropic_supports_xhigh_effort("claude-sonnet-4-6")

    # Sampling params are rejected outright on the adaptive-only models
    @test Agentif.anthropic_rejects_sampling_params("claude-opus-5")
    @test Agentif.anthropic_rejects_sampling_params("claude-sonnet-5")
    @test Agentif.anthropic_rejects_sampling_params("claude-mythos-preview")
    @test !Agentif.anthropic_rejects_sampling_params("claude-opus-4-6")
    @test !Agentif.anthropic_rejects_sampling_params("claude-haiku-4-5-20251001")

    # Interleaved thinking depends on the selected mode, not only model capability.
    adaptive = LLMProviders.AnthropicMessages.ThinkingConfig(; type = "adaptive")
    enabled = LLMProviders.AnthropicMessages.ThinkingConfig(; type = "enabled", budget_tokens = 2048)
    @test !Agentif.anthropic_needs_interleaved_thinking_beta(
        anthropic_test_model(id = "claude-opus-5"), adaptive)
    @test !Agentif.anthropic_needs_interleaved_thinking_beta(
        anthropic_test_model(id = "claude-haiku-4-5-20251001"), enabled)
    @test Agentif.anthropic_needs_interleaved_thinking_beta(
        anthropic_test_model(id = "claude-sonnet-4-5"), enabled)
    @test Agentif.anthropic_needs_interleaved_thinking_beta(
        anthropic_test_model(id = "claude-sonnet-4-6"), enabled)
    @test !Agentif.anthropic_needs_interleaved_thinking_beta(
        anthropic_test_model(id = "claude-opus-4-6"), enabled)
end

@testset "anthropic thinking config, effort mapping, and budget clamping" begin
    # Effort levels step down to the highest rung the model actually supports
    @test Agentif.anthropic_effort_for_level("minimal", "claude-opus-5") == "low"
    @test Agentif.anthropic_effort_for_level("low", "claude-opus-5") == "low"
    @test Agentif.anthropic_effort_for_level("medium", "claude-opus-5") == "medium"
    @test Agentif.anthropic_effort_for_level("high", "claude-opus-5") == "high"
    @test Agentif.anthropic_effort_for_level("max", "claude-sonnet-5") == "max"
    @test Agentif.anthropic_effort_for_level("xhigh", "claude-opus-5") == "xhigh"
    @test Agentif.anthropic_effort_for_level("xhigh", "claude-opus-4-7") == "xhigh"
    # 4.6 family has max but not xhigh
    @test Agentif.anthropic_effort_for_level("xhigh", "claude-opus-4-6") == "max"
    @test Agentif.anthropic_effort_for_level("xhigh", "claude-sonnet-4-6") == "max"
    # Opus 4.5 has neither xhigh nor max
    @test Agentif.anthropic_effort_for_level("xhigh", "claude-opus-4-5") == "high"
    @test Agentif.anthropic_effort_for_level("max", "claude-opus-4-5") == "high"
    @test Agentif.anthropic_effort_for_level("bogus", "claude-opus-5") == "high"

    # budget_tokens must stay strictly below max_tokens (pi's adjustMaxTokensForThinking)
    grown = Agentif.anthropic_adjust_max_tokens_for_thinking(4096, 64000, "medium")
    @test grown.max_tokens == 12288
    @test grown.thinking_budget == 8192
    @test grown.thinking_budget < grown.max_tokens
    clamped = Agentif.anthropic_adjust_max_tokens_for_thinking(1000, 8192, "high")
    @test clamped.max_tokens == 8192
    @test clamped.thinking_budget == 8192 - 1024
    @test clamped.thinking_budget < clamped.max_tokens
    @test Agentif.anthropic_adjust_max_tokens_for_thinking(4096, 64000, "xhigh") ==
        Agentif.anthropic_adjust_max_tokens_for_thinking(4096, 64000, "high")

    # Adaptive path: {type: adaptive} + output_config.effort, max_tokens untouched
    adaptive_model = anthropic_test_model()
    cfg = Agentif.anthropic_thinking_request(adaptive_model, "xhigh", 8192)
    @test cfg.thinking.type == "adaptive"
    @test cfg.thinking.budget_tokens === nothing
    @test cfg.thinking.display == "summarized"
    @test cfg.output_config.effort == "xhigh"
    @test cfg.max_tokens == 8192

    # Extended path: {type: enabled, budget_tokens} and a grown max_tokens, no effort
    # (Haiku 4.5 has a 64k output ceiling and does not support the effort parameter)
    budget_model = anthropic_test_model(id = "claude-haiku-4-5-20251001", maxTokens = 64000)
    bcfg = Agentif.anthropic_thinking_request(budget_model, "medium", 4096)
    @test bcfg.thinking.type == "enabled"
    @test bcfg.thinking.budget_tokens == 8192
    @test bcfg.thinking.display === nothing
    @test bcfg.output_config === nothing
    @test bcfg.max_tokens == 12288
    @test bcfg.thinking.budget_tokens < bcfg.max_tokens

    # Opus 4.5 is extended-thinking-only but supports effort: both ride along
    both_model = anthropic_test_model(id = "claude-opus-4-5", maxTokens = 64000)
    both = Agentif.anthropic_thinking_request(both_model, "high", 8192)
    @test both.thinking.type == "enabled"
    @test both.thinking.budget_tokens == 16384
    @test both.output_config.effort == "high"

    # No effort requested, or a non-reasoning model: no thinking config at all
    @test Agentif.anthropic_thinking_request(adaptive_model, nothing, 8192).thinking === nothing
    @test Agentif.anthropic_thinking_request(anthropic_test_model(reasoning = false), "high", 8192).thinking === nothing

    # Registry metadata wins over model-name inference.
    metadata_model = anthropic_test_model(
        id = "custom-anthropic-model",
        compat = Dict{String, Any}("forceAdaptiveThinking" => true),
        thinkingLevelMap = Dict{String, Any}(
            "off" => "disabled",
            "high" => "medium",
            "max" => "high",
        ),
    )
    metadata_cfg = Agentif.anthropic_thinking_request(metadata_model, "max", 8192)
    @test metadata_cfg.thinking.type == "adaptive"
    @test metadata_cfg.output_config.effort == "high"

    opt_out_model = anthropic_test_model(
        id = "claude-opus-4-8",
        maxTokens = 64000,
        compat = Dict{String, Any}(
            "forceAdaptiveThinking" => false,
            "supportsTemperature" => true,
        ),
    )
    opt_out_cfg = Agentif.anthropic_thinking_request(opt_out_model, "medium", 4096)
    @test opt_out_cfg.thinking.type == "enabled"
    @test opt_out_cfg.output_config === nothing
    @test Agentif.anthropic_supports_extended_thinking(opt_out_model)
    @test !Agentif.anthropic_rejects_sampling_params(opt_out_model)

    @test Agentif.anthropic_thinking_is_enabled(nothing) == false
    @test Agentif.anthropic_thinking_is_enabled(Dict("type" => "disabled")) == false
    @test Agentif.anthropic_thinking_is_enabled(Dict("type" => "adaptive")) == true
    @test Agentif.anthropic_thinking_is_enabled((; type = "enabled")) == true
    @test Agentif.anthropic_thinking_is_enabled(LLMProviders.AnthropicMessages.ThinkingConfig(; type = "disabled")) == false
end

@testset "anthropic clamps unsupported thinking configs to model capability" begin
    # Extended thinking on an adaptive-only model would 400: fall back to adaptive
    opus5 = anthropic_test_model(id = "claude-opus-5", maxTokens = 128000)
    fallback = @test_logs (:warn,) match_mode = :any Agentif.anthropic_normalize_thinking(
        Dict("type" => "enabled", "budget_tokens" => 8192), opus5, 32000,
    )
    @test fallback.thinking.type == "adaptive"
    @test fallback.thinking.budget_tokens === nothing
    @test fallback.max_tokens == 32000

    # Adaptive on an extended-only model: fall back to a token budget below max_tokens
    haiku = anthropic_test_model(id = "claude-haiku-4-5-20251001", maxTokens = 64000)
    downgraded = @test_logs (:warn,) match_mode = :any Agentif.anthropic_normalize_thinking(
        Dict("type" => "adaptive"), haiku, 4096,
    )
    @test downgraded.thinking.type == "enabled"
    @test downgraded.thinking.budget_tokens == 16384
    @test downgraded.thinking.budget_tokens < downgraded.max_tokens

    # Thinking cannot be disabled on Fable 5: drop the field instead of sending a 400
    fable = anthropic_test_model(id = "claude-fable-5", maxTokens = 128000)
    dropped = @test_logs (:warn,) match_mode = :any Agentif.anthropic_normalize_thinking(
        Dict("type" => "disabled"), fable, 32000,
    )
    @test dropped.thinking === nothing

    # Supported configs are converted to validated typed values.
    supported = Agentif.anthropic_normalize_thinking(Dict("type" => "adaptive"), opus5, 32000)
    @test supported.thinking.type == "adaptive"
    @test Agentif.anthropic_normalize_thinking(
        Dict("type" => "disabled"), opus5, 32000).thinking.type == "disabled"
    @test Agentif.anthropic_normalize_thinking(
        Dict("type" => "enabled", "budget_tokens" => 2048), haiku, 32000,
    ).thinking.budget_tokens == 2048
    minimum = @test_logs (:warn,) match_mode = :any Agentif.anthropic_normalize_thinking(
        Dict("type" => "enabled", "budget_tokens" => 10), haiku, 32000,
    )
    @test minimum.thinking.budget_tokens == 1024
    below_max = @test_logs (:warn,) match_mode = :any Agentif.anthropic_normalize_thinking(
        Dict("type" => "enabled", "budget_tokens" => 64000), haiku, 32000,
    )
    @test below_max.thinking.budget_tokens < below_max.max_tokens
    @test_throws ArgumentError Agentif.anthropic_normalize_thinking(
        Dict("type" => "enabled", "budget_tokens" => "many"), haiku, 32000,
    )
    @test Agentif.anthropic_normalize_thinking(nothing, opus5, 32000).thinking === nothing
end

@testset "anthropic cache_control placement" begin
    A = LLMProviders.AnthropicMessages
    ephemeral = A.CacheControl(; type = "ephemeral")

    # retention resolution: none disables breakpoints, long only gets 1h on Anthropic's host
    @test Agentif.anthropic_cache_control("https://api.anthropic.com", "none") === nothing
    @test Agentif.anthropic_cache_control("https://api.anthropic.com", "short").ttl === nothing
    @test Agentif.anthropic_cache_control("https://api.anthropic.com", "long").ttl == "1h"
    @test Agentif.anthropic_cache_control("https://api.anthropic.com.example.test", "long").ttl === nothing
    @test Agentif.anthropic_cache_control("http://127.0.0.1:8080", "long").ttl === nothing

    # a string user turn is promoted to a block array carrying the breakpoint
    msgs = A.Message[A.Message(; role = "user", content = "hello")]
    Agentif.anthropic_apply_cache_control!(msgs, ephemeral)
    @test msgs[end].content isa AbstractVector
    @test msgs[end].content[end].cache_control !== nothing

    # the breakpoint lands on the last block of the last user message
    blocks = A.ContentBlock[A.TextBlock(; text = "a"), A.TextBlock(; text = "b")]
    msgs2 = A.Message[A.Message(; role = "user", content = blocks)]
    Agentif.anthropic_apply_cache_control!(msgs2, ephemeral)
    @test msgs2[end].content[1].cache_control === nothing
    @test msgs2[end].content[2].cache_control !== nothing

    # tool results are cacheable blocks too
    msgs3 = A.Message[A.Message(; role = "user", content = A.ContentBlock[A.ToolResultBlock(; tool_use_id = "t1", content = "ok")])]
    Agentif.anthropic_apply_cache_control!(msgs3, ephemeral)
    @test msgs3[end].content[end].cache_control !== nothing

    # trailing assistant turns and retention=none are left untouched
    msgs4 = A.Message[A.Message(; role = "assistant", content = A.ContentBlock[A.TextBlock(; text = "a")])]
    Agentif.anthropic_apply_cache_control!(msgs4, ephemeral)
    @test msgs4[end].content[end].cache_control === nothing
    msgs5 = A.Message[A.Message(; role = "user", content = A.ContentBlock[A.TextBlock(; text = "a")])]
    Agentif.anthropic_apply_cache_control!(msgs5, nothing)
    @test msgs5[end].content[end].cache_control === nothing

    # system blocks: plain API key gets one breakpoint, the OAuth spoof keeps its two
    system_blocks = Agentif.anthropic_system_blocks("You are helpful.", ephemeral)
    @test length(system_blocks) == 1
    @test system_blocks[1].cache_control !== nothing
    @test Agentif.anthropic_system_blocks("", ephemeral) === nothing
    @test Agentif.anthropic_system_blocks("You are helpful.", nothing)[1].cache_control === nothing
    oauth_blocks = Agentif.anthropic_oauth_system_blocks("You are helpful.", ephemeral)
    @test length(oauth_blocks) == 2
    @test all(b -> b.cache_control !== nothing, oauth_blocks)
    @test all(b -> b.cache_control === nothing, Agentif.anthropic_oauth_system_blocks("You are helpful.", nothing))
end

@testset "anthropic request shaping: thinking, effort, caching, and API guards" begin
    bodies = Vector{Any}()
    beta_headers = String[]

    server = HTTP.serve!("127.0.0.1", 0) do req
        push!(bodies, JSON.parse(String(req.body)))
        push!(beta_headers, something(HTTP.header(req, "anthropic-beta"), ""))
        sse = join([
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_s\",\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":5,\"output_tokens\":1}}}",
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}",
            "data: {\"type\":\"content_block_stop\",\"index\":0}",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}",
            "data: {\"type\":\"message_stop\"}",
        ], "\n\n") * "\n\n"
        return HTTP.Response(200, ["Content-Type" => "text/event-stream"], sse)
    end

    try
        port = test_server_port(server)
        base_url = "http://127.0.0.1:$port"
        # Sampling controls come from model.kw; the newest-model guard strips all three.
        model = anthropic_test_model(
            baseUrl = base_url,
            maxTokens = 128000,
            kw = (; temperature = 0.7, top_p = 0.8, top_k = 20),
        )
        agent = Agent(id = "anthropic-shape-test", prompt = "You are helpful.", model = model, apikey = "test-key", tools = AgentTool[])

        stream(ev -> ev, agent, AgentState(), "Say hello", Abort(); reasoning_effort = "xhigh")
        body = bodies[end]
        @test body["thinking"]["type"] == "adaptive"
        @test !haskey(body["thinking"], "budget_tokens")
        @test body["thinking"]["display"] == "summarized"
        @test body["output_config"]["effort"] == "xhigh"
        # Claude Opus 5 rejects non-default sampling params outright
        @test !haskey(body, "temperature")
        @test !haskey(body, "top_p")
        @test !haskey(body, "top_k")
        # the effort kwarg is consumed, never forwarded as an unknown request field
        @test !haskey(body, "reasoning_effort")
        @test body["max_tokens"] == 128000
        @test body["system"][1]["cache_control"]["type"] == "ephemeral"
        @test !haskey(body["system"][1]["cache_control"], "ttl")
        last_msg = body["messages"][end]
        @test last_msg["role"] == "user"
        @test last_msg["content"][end]["cache_control"]["type"] == "ephemeral"

        # ...even with no thinking at all, since the restriction is unconditional there
        stream(ev -> ev, agent, AgentState(), "Say hello", Abort())
        plain = bodies[end]
        @test !haskey(plain, "thinking")
        @test !haskey(plain, "output_config")
        @test !haskey(plain, "temperature")
        @test !haskey(plain, "top_p")
        @test !haskey(plain, "top_k")

        # Older models only reject temperature/top_k while thinking is on. Their
        # top_p value must be in the 0.95–1.0 interval.
        legacy_agent = Agent(
            id = "anthropic-legacy-test", prompt = "You are helpful.",
            model = anthropic_test_model(
                id = "claude-opus-4-6",
                baseUrl = base_url,
                kw = (; temperature = 0.7, top_p = 0.8, top_k = 20),
            ),
            apikey = "test-key", tools = AgentTool[],
        )
        stream(ev -> ev, legacy_agent, AgentState(), "Say hello", Abort())
        @test bodies[end]["temperature"] == 0.7
        @test bodies[end]["top_p"] == 0.8
        @test bodies[end]["top_k"] == 20
        stream(ev -> ev, legacy_agent, AgentState(), "Say hello", Abort(); reasoning_effort = "xhigh")
        legacy_thinking = bodies[end]
        @test !haskey(legacy_thinking, "temperature")
        @test !haskey(legacy_thinking, "top_p")
        @test !haskey(legacy_thinking, "top_k")
        @test legacy_thinking["thinking"]["type"] == "adaptive"
        # Opus 4.6 has max but not xhigh
        @test legacy_thinking["output_config"]["effort"] == "max"

        # extended-thinking models get {type: enabled, budget_tokens} and a grown max_tokens
        budget_agent = Agent(
            id = "anthropic-budget-test", prompt = "You are helpful.",
            model = anthropic_test_model(id = "claude-haiku-4-5-20251001", maxTokens = 64000, baseUrl = base_url),
            apikey = "test-key", tools = AgentTool[],
        )
        stream(ev -> ev, budget_agent, AgentState(), "Say hello", Abort(); reasoning_effort = "medium", max_tokens = 4096)
        budget_body = bodies[end]
        @test budget_body["thinking"]["type"] == "enabled"
        @test budget_body["thinking"]["budget_tokens"] == 8192
        @test budget_body["thinking"]["budget_tokens"] < budget_body["max_tokens"]
        @test budget_body["max_tokens"] == 12288
        # Haiku 4.5 does not support the effort parameter
        @test !haskey(budget_body, "output_config")

        valid_top_p_agent = Agent(
            id = "anthropic-valid-top-p-test", prompt = "You are helpful.",
            model = anthropic_test_model(
                id = "claude-haiku-4-5-20251001",
                maxTokens = 64000,
                baseUrl = base_url,
                kw = (; top_p = 0.97),
            ),
            apikey = "test-key", tools = AgentTool[],
        )
        stream(ev -> ev, valid_top_p_agent, AgentState(), "Say hello", Abort();
            reasoning_effort = "medium", max_tokens = 4096)
        @test bodies[end]["top_p"] == 0.97

        # cache_retention="none" drops every breakpoint
        stream(ev -> ev, agent, AgentState(), "Say hello", Abort(); cache_retention = "none")
        uncached = bodies[end]
        @test !haskey(uncached["system"][1], "cache_control")
        @test !haskey(uncached, "cache_retention")
        uncached_last = uncached["messages"][end]
        @test uncached_last["content"] == "Say hello" || !haskey(uncached_last["content"][end], "cache_control")

        # an explicit thinking kwarg wins over the derived config
        stream(ev -> ev, legacy_agent, AgentState(), "Say hello", Abort(); reasoning_effort = "high", thinking = Dict("type" => "disabled"))
        explicit = bodies[end]
        @test explicit["thinking"]["type"] == "disabled"
        @test !haskey(explicit, "output_config")
        # thinking disabled => the temperature guard stays out of the way
        @test explicit["temperature"] == 0.7

        # ...but an unsupported explicit config is clamped instead of 400ing
        stream(ev -> ev, agent, AgentState(), "Say hello", Abort(); thinking = Dict("type" => "enabled", "budget_tokens" => 4096))
        clamped = bodies[end]
        @test clamped["thinking"]["type"] == "adaptive"
        @test !haskey(clamped["thinking"], "budget_tokens")

        # Opus 5 rejects disabled thinking with xhigh/max effort.
        stream(ev -> ev, agent, AgentState(), "Say hello", Abort();
            thinking = Dict("type" => "disabled"),
            output_config = Dict("effort" => "max"))
        effort_conflict = bodies[end]
        @test effort_conflict["thinking"]["type"] == "adaptive"
        @test effort_conflict["thinking"]["display"] == "summarized"

        # Manual thinking rejects forced tool selection. Sonnet 4.6 still needs
        # the interleaved-thinking beta when manual thinking is selected.
        shape_tool = @tool "Echo text." anthropic_shape_echo(text::String) = text
        manual_agent = Agent(
            id = "anthropic-manual-tool-test", prompt = "You are helpful.",
            model = anthropic_test_model(
                id = "claude-sonnet-4-6",
                maxTokens = 64000,
                baseUrl = base_url,
            ),
            apikey = "test-key", tools = [shape_tool],
        )
        stream(ev -> ev, manual_agent, AgentState(), "Say hello", Abort();
            thinking = Dict("type" => "enabled", "budget_tokens" => 2048),
            tool_choice = Dict("type" => "tool", "name" => "anthropic_shape_echo"))
        manual = bodies[end]
        @test !haskey(manual, "tool_choice")
        @test occursin("interleaved-thinking-2025-05-14", beta_headers[end])

        # OAuth keeps its two system breakpoints and still caches the conversation tail
        oauth_agent = Agent(
            id = "anthropic-oauth-test", prompt = "You are helpful.",
            model = anthropic_test_model(baseUrl = base_url), apikey = "sk-ant-oat01-test", tools = AgentTool[],
        )
        stream(ev -> ev, oauth_agent, AgentState(), "Say hello", Abort())
        oauth_body = bodies[end]
        @test length(oauth_body["system"]) == 2
        @test all(b -> b["cache_control"]["type"] == "ephemeral", oauth_body["system"])
        @test oauth_body["messages"][end]["content"][end]["cache_control"]["type"] == "ephemeral"
        # Anthropic allows at most four breakpoints per request
        @test length(oauth_body["system"]) + 1 <= 4
    finally
        close(server)
    end
end

@testset "anthropic stream captures thinking blocks with signatures" begin
    seen_events = Agentif.AgentEvent[]
    bodies = Vector{Any}()

    server = HTTP.serve!("127.0.0.1", 0) do req
        push!(bodies, JSON.parse(String(req.body)))
        sse = join([
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_t\",\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":11,\"output_tokens\":1}}}",
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"step one \"}}",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"step two\"}}",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig-\"}}",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"abc\"}}",
            "data: {\"type\":\"content_block_stop\",\"index\":0}",
            "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
            "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"Answer\"}}",
            "data: {\"type\":\"content_block_stop\",\"index\":1}",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":13}}",
            "data: {\"type\":\"message_stop\"}",
        ], "\n\n") * "\n\n"
        return HTTP.Response(200, ["Content-Type" => "text/event-stream"], sse)
    end

    try
        port = test_server_port(server)
        model = anthropic_test_model(baseUrl = "http://127.0.0.1:$port")
        agent = Agent(id = "anthropic-thinking-test", prompt = "You are helpful.", model = model, apikey = "test-key", tools = AgentTool[])

        result = stream(ev -> (push!(seen_events, ev); ev), agent, AgentState(), "Think it through", Abort(); reasoning_effort = "high")
        @test result.most_recent_stop_reason == :stop
        @test !any(ev -> ev isa Agentif.AgentErrorEvent, seen_events)
        @test bodies[end]["thinking"]["type"] == "adaptive"
        @test bodies[end]["output_config"]["effort"] == "high"

        assistant = result.messages[end]
        thinking_blocks = [b for b in assistant.content if b isa Agentif.ThinkingContent]
        @test length(thinking_blocks) == 1
        @test thinking_blocks[1].thinking == "step one step two"
        @test thinking_blocks[1].thinkingSignature == "sig-abc"
        @test !thinking_blocks[1].redacted
        @test Agentif.message_thinking(assistant) == "step one step two"
        @test Agentif.message_text(assistant) == "Answer"
        @test any(ev -> ev isa Agentif.MessageUpdateEvent && ev.kind == :reasoning, seen_events)

        # signed thinking replays as a thinking block rather than being downgraded to text
        replayed = Agentif.anthropic_message_from_agent(assistant, Dict{String, String}(), model)
        lowered = JSON.parse(JSON.json(replayed))
        @test lowered["content"][1]["type"] == "thinking"
        @test lowered["content"][1]["signature"] == "sig-abc"
    finally
        close(server)
    end
end

@testset "anthropic stream resubmits paused turns" begin
    seen_events = Agentif.AgentEvent[]
    bodies = Vector{Any}()

    function pause_sse(text, stop_reason, id)
        return join([
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"$id\",\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":100,\"output_tokens\":1}}}",
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"$text\"}}",
            "data: {\"type\":\"content_block_stop\",\"index\":0}",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"$stop_reason\"},\"usage\":{\"output_tokens\":5}}",
            "data: {\"type\":\"message_stop\"}",
        ], "\n\n") * "\n\n"
    end

    server = HTTP.serve!("127.0.0.1", 0) do req
        push!(bodies, JSON.parse(String(req.body)))
        sse = length(bodies) == 1 ? pause_sse("Part one ", "pause_turn", "msg_p1") : pause_sse("Part two", "end_turn", "msg_p2")
        return HTTP.Response(200, ["Content-Type" => "text/event-stream"], sse)
    end

    try
        port = test_server_port(server)
        model = anthropic_test_model(baseUrl = "http://127.0.0.1:$port")
        agent = Agent(id = "anthropic-pause-test", prompt = "You are helpful.", model = model, apikey = "test-key", tools = AgentTool[])

        result = stream(ev -> (push!(seen_events, ev); ev), agent, AgentState(), "Do the long thing", Abort())
        @test result.most_recent_stop_reason == :stop
        @test !any(ev -> ev isa Agentif.AgentErrorEvent, seen_events)
        # exactly one resubmit
        @test length(bodies) == 2

        assistant = result.messages[end]
        @test Agentif.message_text(assistant) == "Part one Part two"
        # the paused turn is one logical assistant message: one start, one end
        @test count(ev -> ev isa Agentif.MessageStartEvent, seen_events) == 1
        @test count(ev -> ev isa Agentif.MessageEndEvent, seen_events) == 1
        @test findlast(ev -> ev isa Agentif.MessageEndEvent, seen_events) >
            findlast(ev -> ev isa Agentif.MessageUpdateEvent, seen_events)

        # the continuation replays the paused assistant content verbatim, with no extra user turn
        @test length(bodies[2]["messages"]) == length(bodies[1]["messages"]) + 1
        resumed = bodies[2]["messages"][end]
        @test resumed["role"] == "assistant"
        @test resumed["content"][1]["type"] == "text"
        @test resumed["content"][1]["text"] == "Part one "
        @test bodies[2]["messages"][end - 1]["role"] == "user"

        # usage is summed across both requests
        @test result.usage.input == 200
        @test result.usage.output == 10
    finally
        close(server)
    end
end

@testset "anthropic pause_turn preserves raw server-tool state" begin
    seen_events = Agentif.AgentEvent[]
    bodies = Vector{Any}()
    expected_server_tool = Dict{String, Any}(
        "type" => "server_tool_use",
        "id" => "srvtoolu_01",
        "name" => "web_search",
        "input" => Dict{String, Any}("query" => "Julia language"),
    )
    expected_server_result = Dict{String, Any}(
        "type" => "web_search_tool_result",
        "tool_use_id" => "srvtoolu_01",
        "content" => Any[
            Dict{String, Any}(
                "type" => "web_search_result",
                "url" => "https://julialang.org",
                "title" => "The Julia Programming Language",
                "encrypted_content" => "opaque-result",
            ),
        ],
    )

    server = HTTP.serve!("127.0.0.1", 0) do req
        push!(bodies, JSON.parse(String(req.body)))
        sse = if length(bodies) == 1
            join([
                "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_srv_1\",\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":20,\"output_tokens\":1}}}",
                "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"server_tool_use\",\"id\":\"srvtoolu_01\",\"name\":\"web_search\",\"input\":{}}}",
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"query\\\":\\\"Julia language\\\"}\"}}",
                "data: {\"type\":\"content_block_stop\",\"index\":0}",
                "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"web_search_tool_result\",\"tool_use_id\":\"srvtoolu_01\",\"content\":[{\"type\":\"web_search_result\",\"url\":\"https://julialang.org\",\"title\":\"The Julia Programming Language\",\"encrypted_content\":\"opaque-result\"}]}}",
                "data: {\"type\":\"content_block_stop\",\"index\":1}",
                "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"pause_turn\"},\"usage\":{\"output_tokens\":8}}",
                "data: {\"type\":\"message_stop\"}",
            ], "\n\n") * "\n\n"
        else
            join([
                "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_srv_2\",\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":30,\"output_tokens\":1}}}",
                "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Julia found.\"}}",
                "data: {\"type\":\"content_block_stop\",\"index\":0}",
                "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}",
                "data: {\"type\":\"message_stop\"}",
            ], "\n\n") * "\n\n"
        end
        return HTTP.Response(200, ["Content-Type" => "text/event-stream"], sse)
    end

    try
        port = test_server_port(server)
        model = anthropic_test_model(baseUrl = "http://127.0.0.1:$port")
        agent = Agent(
            id = "anthropic-server-pause-test",
            prompt = "You are helpful.",
            model = model,
            apikey = "test-key",
            tools = AgentTool[],
        )

        result = stream(
            ev -> (push!(seen_events, ev); ev),
            agent,
            AgentState(),
            "Search the web",
            Abort(),
        )
        @test result.most_recent_stop_reason == :stop
        @test length(bodies) == 2
        @test !any(ev -> ev isa Agentif.AgentErrorEvent, seen_events)
        resumed = bodies[2]["messages"][end]
        @test resumed["role"] == "assistant"
        @test resumed["content"] == Any[expected_server_tool, expected_server_result]
        @test Agentif.message_text(result.messages[end]) == "Julia found."
    finally
        close(server)
    end
end

@testset "anthropic non-streaming pause_turn preserves raw content" begin
    bodies = Vector{Any}()
    paused_content = Any[
        Dict{String, Any}(
            "type" => "server_tool_use",
            "id" => "srvtoolu_nonstream",
            "name" => "web_fetch",
            "input" => Dict{String, Any}("url" => "https://julialang.org"),
        ),
        Dict{String, Any}(
            "type" => "web_fetch_tool_result",
            "tool_use_id" => "srvtoolu_nonstream",
            "content" => Dict{String, Any}(
                "type" => "web_fetch_result",
                "url" => "https://julialang.org",
                "content" => "opaque",
            ),
        ),
    ]

    server = HTTP.serve!("127.0.0.1", 0) do req
        push!(bodies, JSON.parse(String(req.body)))
        response = if length(bodies) == 1
            Dict{String, Any}(
                "id" => "msg_ns_1",
                "model" => "claude-opus-5",
                "role" => "assistant",
                "content" => paused_content,
                "stop_reason" => "pause_turn",
                "usage" => Dict("input_tokens" => 4, "output_tokens" => 2),
            )
        else
            Dict{String, Any}(
                "id" => "msg_ns_2",
                "model" => "claude-opus-5",
                "role" => "assistant",
                "content" => Any[Dict("type" => "text", "text" => "Done.")],
                "stop_reason" => "end_turn",
                "usage" => Dict("input_tokens" => 6, "output_tokens" => 1),
            )
        end
        return HTTP.Response(
            200,
            ["Content-Type" => "application/json"],
            JSON.json(response),
        )
    end

    try
        port = test_server_port(server)
        model = anthropic_test_model(baseUrl = "http://127.0.0.1:$port")
        agent = Agent(
            id = "anthropic-nonstream-pause-test",
            prompt = "You are helpful.",
            model = model,
            apikey = "test-key",
            tools = AgentTool[],
        )
        result = withenv("AGENTIF_DISABLE_STREAMING" => "1") do
            stream(identity, agent, AgentState(), "Fetch the page", Abort())
        end

        @test length(bodies) == 2
        @test bodies[2]["messages"][end]["content"] == paused_content
        @test Agentif.message_text(result.messages[end]) == "Done."
        @test result.most_recent_stop_reason == :stop
        @test result.usage.input == 10
        @test result.usage.output == 3
    finally
        close(server)
    end
end

@testset "anthropic pause_turn resubmits are bounded" begin
    bodies = Vector{Any}()

    server = HTTP.serve!("127.0.0.1", 0) do req
        push!(bodies, JSON.parse(String(req.body)))
        sse = join([
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_b\",\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}",
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"x\"}}",
            "data: {\"type\":\"content_block_stop\",\"index\":0}",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"pause_turn\"},\"usage\":{\"output_tokens\":1}}",
            "data: {\"type\":\"message_stop\"}",
        ], "\n\n") * "\n\n"
        return HTTP.Response(200, ["Content-Type" => "text/event-stream"], sse)
    end

    try
        port = test_server_port(server)
        model = anthropic_test_model(baseUrl = "http://127.0.0.1:$port")
        agent = Agent(id = "anthropic-pause-bound-test", prompt = "You are helpful.", model = model, apikey = "test-key", tools = AgentTool[])

        seen_events = Agentif.AgentEvent[]
        result = stream(ev -> (push!(seen_events, ev); ev), agent, AgentState(), "Loop forever", Abort())
        # one original request plus ANTHROPIC_MAX_PAUSE_TURN_RESUBMITS continuations
        @test length(bodies) == 1 + Agentif.ANTHROPIC_MAX_PAUSE_TURN_RESUBMITS
        @test result.most_recent_stop_reason == :length
        @test Agentif.message_text(result.messages[end]) == "xxxx"
        @test all(body -> begin
            replay = body["messages"][end]["content"]
            length(replay) == 1 && replay[1]["text"] == "x"
        end, bodies[2:end])
        @test count(ev -> ev isa Agentif.MessageEndEvent, seen_events) == 1
    finally
        close(server)
    end
end

@testset "openai_codex stream keeps incomplete as length" begin
    seen_events = Agentif.AgentEvent[]

    server = HTTP.serve!("127.0.0.1", 0) do req
        sse = join([
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[]}}",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial codex\"}",
            "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"usage\":{\"input_tokens\":10,\"input_tokens_details\":{\"cached_tokens\":3},\"output_tokens\":4,\"total_tokens\":14}}}",
            "data: [DONE]",
        ], "\n\n") * "\n\n"
        return HTTP.Response(200, ["Content-Type" => "text/event-stream"], sse)
    end

    try
        port = test_server_port(server)
        model = Model(
            id = "gpt-5.2-codex",
            name = "gpt-5.2-codex",
            api = "openai-codex-responses",
            provider = "openai-codex",
            baseUrl = "http://127.0.0.1:$port",
            reasoning = true,
            input = ["text"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 128000,
            maxTokens = 32000,
        )
        token = fake_jwt(Dict("https://api.openai.com/auth" => Dict("chatgpt_account_id" => "acct-jwt-incomplete")))
        agent = Agent(
            id = "codex-incomplete-test",
            prompt = "You are helpful.",
            model = model,
            apikey = token,
            tools = AgentTool[],
        )

        result = stream(ev -> (push!(seen_events, ev); ev), agent, AgentState(), "Say hello", Abort())
        @test result.most_recent_stop_reason == :length
        @test !any(ev -> ev isa Agentif.AgentErrorEvent, seen_events)
    finally
        close(server)
    end
end

@testset "openai_codex stream infers account_id from JWT" begin
    request_headers = Ref(Dict{String, String}())
    request_body = Ref(Dict{String, Any}())

    server = HTTP.serve!("127.0.0.1", 0) do req
        request_headers[] = Dict{String, String}(lowercase(String(k)) => String(v) for (k, v) in req.headers)
        request_body[] = JSON.parse(String(req.body))
        sse = join([
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[]}}",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}",
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"}]}}",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}",
            "data: [DONE]",
        ], "\n\n") * "\n\n"
        return HTTP.Response(200, ["Content-Type" => "text/event-stream"], sse)
    end

    try
        port = test_server_port(server)
        model = Model(
            id = "gpt-5.3-codex-spark",
            name = "gpt-5.3-codex-spark",
            api = "openai-codex-responses",
            provider = "openai-codex",
            baseUrl = "http://127.0.0.1:$port",
            reasoning = true,
            input = ["text"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 128000,
            maxTokens = 32000,
        )
        agent = Agent(
            id = "codex-jwt-test",
            prompt = "You are helpful.",
            model = model,
            apikey = "OAUTH",
            tools = AgentTool[],
        )

        state = AgentState()
        result = with_oauth_backend(MockOAuthBackend()) do
            stream(identity, agent, state, "Say hello", Abort(); session_id = "sess-123", reasoning = "minimal")
        end
        @test result isa AgentState
        @test request_headers[]["chatgpt-account-id"] == "acct-jwt-1"
        @test request_headers[]["session_id"] == "sess-123"
        @test request_headers[]["conversation_id"] == "sess-123"
        @test get(() -> nothing, request_body[], "prompt_cache_key") == "sess-123"
        reasoning = get(() -> nothing, request_body[], "reasoning")
        @test reasoning !== nothing
        @test get(() -> nothing, reasoning, "effort") == "low"
    finally
        close(server)
    end
end

@testset "openai_codex stream retries transient SSE failures" begin
    request_count = Ref(0)

    server = HTTP.serve!("127.0.0.1", 0) do req
        request_count[] += 1
        if request_count[] == 1
            return HTTP.Response(
                503,
                ["Content-Type" => "application/json", "Retry-After" => "0"],
                "{\"error\":{\"code\":\"service_unavailable\",\"message\":\"temporary outage\"}}",
            )
        end
        sse = join([
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[]}}",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}",
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"}]}}",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}",
            "data: [DONE]",
        ], "\n\n") * "\n\n"
        return HTTP.Response(200, ["Content-Type" => "text/event-stream"], sse)
    end

    try
        port = test_server_port(server)
        model = Model(
            id = "gpt-5.3-codex",
            name = "gpt-5.3-codex",
            api = "openai-codex-responses",
            provider = "openai-codex",
            baseUrl = "http://127.0.0.1:$port",
            reasoning = true,
            input = ["text"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 128000,
            maxTokens = 32000,
        )
        payload = Dict("https://api.openai.com/auth" => Dict("chatgpt_account_id" => "acct-jwt-2"))
        token = fake_jwt(payload)
        agent = Agent(
            id = "codex-retry-test",
            prompt = "You are helpful.",
            model = model,
            apikey = token,
            tools = AgentTool[],
        )

        state = AgentState()
        result = stream(
            identity,
            agent,
            state,
            "Say hello",
            Abort();
            max_retries = 2,
            retry_base_ms = 1,
            retry_max_ms = 2,
        )
        @test result isa AgentState
        @test request_count[] == 2
        @test length(result.messages) >= 2
        @test result.messages[end] isa AssistantMessage
        @test Agentif.message_text(result.messages[end]) == "Hello"
    finally
        close(server)
    end
end

@testset "openai_codex stream replays SSE body when content-type is missing" begin
    server = HTTP.serve!("127.0.0.1", 0) do req
        sse = join([
            "event: response.created",
            "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"status\":\"in_progress\"}}",
            "event: response.output_item.added",
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[]}}",
            "event: response.output_text.delta",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello from body\"}",
            "event: response.output_item.done",
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello from body\"}]}}",
            "event: response.completed",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2,\"total_tokens\":3}}}",
            "data: [DONE]",
        ], "\n\n") * "\n\n"
        return HTTP.Response(200, String[], sse)
    end

    try
        port = test_server_port(server)
        model = Model(
            id = "gpt-5.3-codex",
            name = "gpt-5.3-codex",
            api = "openai-codex-responses",
            provider = "openai-codex",
            baseUrl = "http://127.0.0.1:$port",
            reasoning = true,
            input = ["text"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 128000,
            maxTokens = 32000,
        )
        payload = Dict("https://api.openai.com/auth" => Dict("chatgpt_account_id" => "acct-jwt-4"))
        token = fake_jwt(payload)
        agent = Agent(
            id = "codex-sse-body-replay-test",
            prompt = "You are helpful.",
            model = model,
            apikey = token,
            tools = AgentTool[],
        )

        result = stream(identity, agent, AgentState(), "Say hello", Abort())
        @test result isa AgentState
        @test result.messages[end] isa AssistantMessage
        @test Agentif.message_text(result.messages[end]) == "Hello from body"
    finally
        close(server)
    end
end

@testset "sse retry helpers" begin
    @test Agentif.sse_retryable_status(503)
    @test Agentif.sse_retryable_status(429)
    @test !Agentif.sse_retryable_status(400)
    @test !Agentif.sse_retryable_status(401)

    @test Agentif.sse_recoverable_connection_error(EOFError())
    @test Agentif.sse_recoverable_connection_error(Base.IOError("connection reset", -104))
    @test Agentif.sse_recoverable_connection_error(HTTP.ConnectError("http://x", EOFError()))
    @test !Agentif.sse_recoverable_connection_error(InterruptException())
    @test !Agentif.sse_recoverable_connection_error(Agentif.StopStreaming())
    @test !Agentif.sse_recoverable_connection_error(ArgumentError("bad input"))
    failed_task = @async throw(EOFError())
    task_error = try
        wait(failed_task)
        nothing
    catch err
        err
    end
    @test task_error isa TaskFailedException
    @test Agentif.sse_recoverable_connection_error(task_error)
    failed_parse_task = @async throw(test_parse_error("unexpected EOF while reading HTTP data"))
    parse_task_error = try
        wait(failed_parse_task)
        nothing
    catch err
        err
    end
    @test parse_task_error isa TaskFailedException
    @test Agentif.sse_recoverable_connection_error(parse_task_error)

    # HTTP.StatusError routes through status-based retryability, not connection recovery
    status_err = test_status_error(503)
    @test !Agentif.sse_recoverable_connection_error(status_err)
    @test Agentif.sse_retryable_error(status_err)
    @test !Agentif.sse_retryable_error(test_status_error(400))

    # http_kw overrides are respected
    @test Agentif.sse_retry_attempts(Agentif.DEFAULT_HTTP_KW) == 6
    @test Agentif.sse_retry_attempts((; retry = false, retries = 5)) == 1
    @test Agentif.sse_retry_attempts((; retry = true, retries = 2)) == 3
    @test Agentif.sse_retry_attempts((; retry = true, retries = 0)) == 1

    # Retry-After honored and capped by max_delay_ms
    retry_after_resp = HTTP.Response(429, ["Retry-After" => "3"], "")
    @test Agentif.codex_retry_delay_seconds(1, 1000, 60000; response = retry_after_resp) == 3.0
    capped_resp = HTTP.Response(503, ["Retry-After" => "500"], "")
    @test Agentif.codex_retry_delay_seconds(1, 1000, 60000; response = capped_resp) == 60.0

    # Retries transient failures while no SSE event has been delivered
    events_seen = Ref(false)
    calls = Ref(0)
    result = Agentif.sse_request_with_retry(events_seen, Abort(); max_attempts = 3, base_delay_ms = 1, max_delay_ms = 2) do
        calls[] += 1
        calls[] < 3 && throw(EOFError())
        return :ok
    end
    @test result == :ok
    @test calls[] == 3

    # Never retries once an event has been delivered
    events_seen[] = true
    calls[] = 0
    @test_throws EOFError Agentif.sse_request_with_retry(events_seen, Abort(); max_attempts = 3, base_delay_ms = 1, max_delay_ms = 2) do
        calls[] += 1
        throw(EOFError())
    end
    @test calls[] == 1

    # Never retries non-transient errors
    events_seen[] = false
    calls[] = 0
    @test_throws ArgumentError Agentif.sse_request_with_retry(events_seen, Abort(); max_attempts = 3, base_delay_ms = 1, max_delay_ms = 2) do
        calls[] += 1
        throw(ArgumentError("nope"))
    end
    @test calls[] == 1
end

@testset "openai_responses stream retries pre-stream 503 then succeeds" begin
    request_count = Ref(0)
    seen_events = Agentif.AgentEvent[]

    server = HTTP.serve!("127.0.0.1", 0) do req
        request_count[] += 1
        if request_count[] == 1
            return HTTP.Response(
                503,
                ["Content-Type" => "application/json", "Retry-After" => "0"],
                "{\"error\":{\"message\":\"temporary outage\"}}",
            )
        end
        sse = join([
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[]}}",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}",
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"model\":\"gpt-4.1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":1,\"total_tokens\":2}}}",
            "data: [DONE]",
        ], "\n\n") * "\n\n"
        return HTTP.Response(200, ["Content-Type" => "text/event-stream"], sse)
    end

    try
        port = test_server_port(server)
        model = Model(
            id = "gpt-4.1",
            name = "gpt-4.1",
            api = "openai-responses",
            provider = "openai",
            baseUrl = "http://127.0.0.1:$port",
            reasoning = false,
            input = ["text"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 128000,
            maxTokens = 32000,
        )
        agent = Agent(
            id = "responses-503-retry-test",
            prompt = "You are helpful.",
            model = model,
            apikey = "test-key",
            tools = AgentTool[],
        )

        result = stream(ev -> (push!(seen_events, ev); ev), agent, AgentState(), "Say hello", Abort())
        @test request_count[] == 2
        @test !any(ev -> ev isa Agentif.AgentErrorEvent, seen_events)
        @test result.most_recent_stop_reason == :stop
        @test result.messages[end] isa AssistantMessage
        @test Agentif.message_text(result.messages[end]) == "Hello"
    finally
        close(server)
    end
end

@testset "openai_responses stream surfaces mid-stream disconnect without duplicating deltas" begin
    request_count = Ref(0)
    seen_events = Agentif.AgentEvent[]

    server = HTTP.listen!("127.0.0.1", 0) do http
        request_count[] += 1
        read(http)
        sse = join([
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[]}}",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"MARKER_ONCE\"}",
        ], "\n\n") * "\n\n"
        HTTP.setstatus(http, 200)
        HTTP.setheader(http, "Content-Type" => "text/event-stream")
        HTTP.startwrite(http)
        write(http, sse)
        flush(http)
        sleep(0.2)
        test_force_close_stream(http)  # drop before the terminating chunk/end-stream
    end

    try
        port = test_server_port(server)
        model = Model(
            id = "gpt-4.1",
            name = "gpt-4.1",
            api = "openai-responses",
            provider = "openai",
            baseUrl = "http://127.0.0.1:$port",
            reasoning = false,
            input = ["text"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 128000,
            maxTokens = 32000,
        )
        agent = Agent(
            id = "responses-disconnect-test",
            prompt = "You are helpful.",
            model = model,
            apikey = "test-key",
            tools = AgentTool[],
        )

        result = stream(ev -> (push!(seen_events, ev); ev), agent, AgentState(), "Say hello", Abort())
        # Events already flowed, so the request must NOT be replayed
        @test request_count[] == 1
        @test result.most_recent_stop_reason == :error
        @test any(ev -> ev isa Agentif.AgentErrorEvent, seen_events)
        @test result.messages[end] isa AssistantMessage
        delivered = Agentif.message_text(result.messages[end])
        @test length(collect(eachmatch(r"MARKER_ONCE", delivered))) == 1
        @test count(ev -> ev isa Agentif.MessageUpdateEvent && occursin("MARKER_ONCE", ev.delta), seen_events) == 1
        @test count(ev -> ev isa Agentif.MessageEndEvent, seen_events) == 1
    finally
        close(server)
    end
end

@testset "openai_codex stream does not re-POST after mid-stream disconnect" begin
    request_count = Ref(0)
    seen_events = Agentif.AgentEvent[]

    server = HTTP.listen!("127.0.0.1", 0) do http
        request_count[] += 1
        read(http)
        sse = join([
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[]}}",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"CODEX_MARKER\"}",
        ], "\n\n") * "\n\n"
        HTTP.setstatus(http, 200)
        HTTP.setheader(http, "Content-Type" => "text/event-stream")
        HTTP.startwrite(http)
        write(http, sse)
        flush(http)
        sleep(0.2)
        test_force_close_stream(http)  # drop before the terminating chunk/end-stream
    end

    try
        port = test_server_port(server)
        model = Model(
            id = "gpt-5.3-codex",
            name = "gpt-5.3-codex",
            api = "openai-codex-responses",
            provider = "openai-codex",
            baseUrl = "http://127.0.0.1:$port",
            reasoning = true,
            input = ["text"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 128000,
            maxTokens = 32000,
        )
        token = fake_jwt(Dict("https://api.openai.com/auth" => Dict("chatgpt_account_id" => "acct-jwt-disconnect")))
        agent = Agent(
            id = "codex-disconnect-test",
            prompt = "You are helpful.",
            model = model,
            apikey = token,
            tools = AgentTool[],
        )

        err = try
            stream(
                ev -> (push!(seen_events, ev); ev),
                agent,
                AgentState(),
                "Say hello",
                Abort();
                max_retries = 3,
                retry_base_ms = 1,
                retry_max_ms = 5,
            )
            nothing
        catch e
            e
        end
        @test err isa Exception
        @test !(err isa Agentif.StopStreaming)
        # The delivered events must not be replayed by a re-POST
        @test request_count[] == 1
        @test count(ev -> ev isa Agentif.MessageUpdateEvent && occursin("CODEX_MARKER", ev.delta), seen_events) == 1
    finally
        close(server)
    end
end

@testset "google_generative stream surfaces HTTP status errors" begin
    seen_events = Agentif.AgentEvent[]

    server = HTTP.serve!("127.0.0.1", 0) do req
        return HTTP.Response(
            400,
            ["Content-Type" => "application/json"],
            "{\"error\":{\"code\":400,\"message\":\"Invalid request\",\"status\":\"INVALID_ARGUMENT\"}}",
        )
    end

    try
        port = test_server_port(server)
        model = Model(
            id = "gemini-2.5-flash",
            name = "gemini-2.5-flash",
            api = "google-generative-ai",
            provider = "google",
            baseUrl = "http://127.0.0.1:$port",
            reasoning = false,
            input = ["text"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 128000,
            maxTokens = 32000,
        )
        agent = Agent(
            id = "google-status-error-test",
            prompt = "You are helpful.",
            model = model,
            apikey = "test-key",
            tools = AgentTool[],
        )

        result = stream(ev -> (push!(seen_events, ev); ev), agent, AgentState(), "Say hello", Abort())
        @test result.most_recent_stop_reason == :error
        error_events = filter(ev -> ev isa Agentif.AgentErrorEvent, seen_events)
        @test length(error_events) == 1
        @test occursin("Invalid request", sprint(showerror, error_events[1].error))
        # The assistant message is still started/finalized like the openai branches
        @test count(ev -> ev isa Agentif.MessageStartEvent, seen_events) == 1
        @test count(ev -> ev isa Agentif.MessageEndEvent, seen_events) == 1
        @test result.messages[end] isa AssistantMessage
    finally
        close(server)
    end
end

@testset "openai_codex websocket transport" begin
    Agentif.close_codex_websocket_pool!()
    request_headers = Ref(Dict{String, String}())
    request_body = Ref(Dict{String, Any}())

    ws_server = HTTP.WebSockets.listen!("127.0.0.1", 0) do ws
        request = test_websocket_request(ws)
        request_headers[] = Dict{String, String}(lowercase(String(k)) => String(v) for (k, v) in request.headers)
        msg = HTTP.WebSockets.receive(ws)
        data = msg isa AbstractString ? String(msg) : String(msg)
        request_body[] = JSON.parse(data)
        events = Any[
            Dict("type" => "response.output_item.added", "item" => Dict("type" => "message", "id" => "msg_1", "role" => "assistant", "content" => Any[])),
            Dict("type" => "response.output_text.delta", "delta" => "Hello over ws"),
            Dict("type" => "response.output_item.done", "item" => Dict("type" => "message", "id" => "msg_1", "role" => "assistant", "content" => Any[Dict("type" => "output_text", "text" => "Hello over ws")])),
            Dict("type" => "response.completed", "response" => Dict("status" => "completed", "usage" => Dict("input_tokens" => 1, "output_tokens" => 2, "total_tokens" => 3))),
        ]
        for event in events
            HTTP.WebSockets.send(ws, JSON.json(event))
        end
        close(ws)
    end

    try
        port = test_server_port(ws_server)
        model = Model(
            id = "gpt-5.3-codex",
            name = "gpt-5.3-codex",
            api = "openai-codex-responses",
            provider = "openai-codex",
            baseUrl = "http://127.0.0.1:$port",
            reasoning = true,
            input = ["text"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 128000,
            maxTokens = 32000,
        )
        payload = Dict("https://api.openai.com/auth" => Dict("chatgpt_account_id" => "acct-jwt-3"))
        token = fake_jwt(payload)
        agent = Agent(
            id = "codex-ws-test",
            prompt = "You are helpful.",
            model = model,
            apikey = token,
            tools = AgentTool[],
        )

        state = AgentState()
        result = stream(identity, agent, state, "Say hello", Abort(); transport = "websocket", session_id = "ws-123")
        @test result isa AgentState
        @test result.messages[end] isa AssistantMessage
        @test Agentif.message_text(result.messages[end]) == "Hello over ws"
        @test get(() -> nothing, request_body[], "type") == "response.create"
        @test get(() -> nothing, request_body[], "prompt_cache_key") == "ws-123"
        @test request_headers[]["openai-beta"] == "responses_websockets=2026-02-06"
        @test request_headers[]["chatgpt-account-id"] == "acct-jwt-3"
    finally
        Agentif.close_codex_websocket_pool!()
        close(ws_server)
    end
end

@testset "openai_codex websocket pooling isolates sessions" begin
    Agentif.close_codex_websocket_pool!()
    connection_count = Ref(0)
    request_count = Ref(0)
    seen_session_headers = String[]

    ws_server = HTTP.WebSockets.listen!("127.0.0.1", 0) do ws
        connection_count[] += 1
        request = test_websocket_request(ws)
        headers = Dict{String, String}(lowercase(String(k)) => String(v) for (k, v) in request.headers)
        push!(seen_session_headers, get(() -> "", headers, "session_id"))
        try
            while true
                msg = HTTP.WebSockets.receive(ws)
                data = msg isa AbstractString ? String(msg) : String(msg)
                body = JSON.parse(data)
                request_count[] += 1
                text = "Hello ws $(request_count[])"
                events = Any[
                    Dict("type" => "response.output_item.added", "item" => Dict("type" => "message", "id" => "msg_$(request_count[])", "role" => "assistant", "content" => Any[])),
                    Dict("type" => "response.output_text.delta", "delta" => text),
                    Dict("type" => "response.output_item.done", "item" => Dict("type" => "message", "id" => "msg_$(request_count[])", "role" => "assistant", "content" => Any[Dict("type" => "output_text", "text" => text)])),
                    Dict(
                        "type" => "response.completed",
                        "response" => Dict(
                            "status" => "completed",
                            "usage" => Dict("input_tokens" => 1, "output_tokens" => 2, "total_tokens" => 3),
                            "id" => get(() -> "resp_$(request_count[])", body, "prompt_cache_key"),
                        ),
                    ),
                ]
                for event in events
                    HTTP.WebSockets.send(ws, JSON.json(event))
                end
            end
        catch err
            if !(err isa HTTP.WebSockets.WebSocketError && HTTP.WebSockets.isok(err))
                rethrow()
            end
        finally
            try
                close(ws)
            catch
            end
        end
    end

    try
        port = test_server_port(ws_server)
        model = Model(
            id = "gpt-5.3-codex",
            name = "gpt-5.3-codex",
            api = "openai-codex-responses",
            provider = "openai-codex",
            baseUrl = "http://127.0.0.1:$port",
            reasoning = true,
            input = ["text"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 128000,
            maxTokens = 32000,
        )
        payload = Dict("https://api.openai.com/auth" => Dict("chatgpt_account_id" => "acct-jwt-pooled"))
        token = fake_jwt(payload)
        agent = Agent(
            id = "codex-ws-pool-test",
            prompt = "You are helpful.",
            model = model,
            apikey = token,
            tools = AgentTool[],
        )

        same_a = stream(identity, agent, AgentState(), "Say hello", Abort(); transport = "websocket", session_id = "pool-1")
        same_b = stream(identity, agent, AgentState(), "Say hello again", Abort(); transport = "websocket", session_id = "pool-1")
        diff = stream(identity, agent, AgentState(), "Different session", Abort(); transport = "websocket", session_id = "pool-2")
        no_session_a = stream(identity, agent, AgentState(), "No session A", Abort(); transport = "websocket")
        no_session_b = stream(identity, agent, AgentState(), "No session B", Abort(); transport = "websocket")

        @test Agentif.message_text(same_a.messages[end]) == "Hello ws 1"
        @test Agentif.message_text(same_b.messages[end]) == "Hello ws 2"
        @test Agentif.message_text(diff.messages[end]) == "Hello ws 3"
        @test Agentif.message_text(no_session_a.messages[end]) == "Hello ws 4"
        @test Agentif.message_text(no_session_b.messages[end]) == "Hello ws 5"

        @test connection_count[] == 4
        @test seen_session_headers == ["pool-1", "pool-2", "", ""]
    finally
        Agentif.close_codex_websocket_pool!()
        close(ws_server)
    end
end

@testset "openrouter reasoning_details deltas are not double-appended" begin
    # OpenRouter mirrors each reasoning token into BOTH delta.reasoning and
    # delta.reasoning_details[].text. The details stream is canonical; the
    # plain field must be skipped for those deltas or every token doubles.
    chunks = String[]
    for tok in ("Let", " me", " think")
        push!(chunks, "data: " * JSON.json((; choices = [(; index = 0,
            delta = (; reasoning = tok,
                reasoning_details = [Dict("type" => "reasoning.text", "text" => tok)]),
            finish_reason = nothing)])))
    end
    # Details without usable text must not suppress the plain reasoning fallback.
    push!(chunks, "data: " * JSON.json((; choices = [(; index = 0,
        delta = (; reasoning = " fallback",
            reasoning_details = [Dict("type" => "reasoning.text", "text" => "")]),
        finish_reason = nothing)])))
    push!(chunks, "data: " * JSON.json((; choices = [(; index = 0,
        delta = (; content = "42"), finish_reason = nothing)])))
    push!(chunks, "data: " * JSON.json((; choices = [(; index = 0, delta = (;), finish_reason = "stop")])))
    push!(chunks, "data: [DONE]")
    body = join(chunks, "\n\n") * "\n\n"

    server = HTTP.serve!("127.0.0.1", 0) do req
        return HTTP.Response(200, ["Content-Type" => "text/event-stream"], body)
    end
    try
        port = test_server_port(server)
        model = Model(
            id = "test-reasoning", name = "test-reasoning", api = "openai-completions",
            provider = "openrouter", baseUrl = "http://127.0.0.1:$port", reasoning = true,
            input = ["text"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 128000, maxTokens = 4096,
            compat = Dict{String, Any}("thinkingFormat" => "openrouter"),
        )
        agent = Agent(prompt = "p", model = model, apikey = "k")
        reasoning_deltas = String[]
        state = stream(agent, AgentState(), "q", Abort()) do event
            if event isa MessageUpdateEvent && event.kind == :reasoning
                push!(reasoning_deltas, event.delta)
            end
        end
        msg = state.messages[end]
        thinking_blocks = [b for b in msg.content if b isa Agentif.ThinkingContent]
        thinking = join((b.thinking for b in thinking_blocks), "")
        @test thinking == "Let me think fallback"
        @test join(reasoning_deltas, "") == "Let me think fallback"
        @test Agentif.message_text(msg) == "42"
        details = JSON.parse(only(thinking_blocks).thinkingSignature)
        @test [get(d, "text", nothing) for d in details] == ["Let", " me", " think", ""]
    finally
        close(server)
    end
end

@testset "openrouter non-streaming reasoning falls back from metadata-only details" begin
    body = JSON.json((;
        id = "chatcmpl-test", object = "chat.completion", created = 0,
        model = "test-reasoning",
        choices = [(; index = 0,
            message = (; role = "assistant", content = "42", reasoning = "fallback",
                reasoning_details = [Dict("type" => "reasoning.encrypted", "data" => "sig")]),
            finish_reason = "stop")],
        usage = (; prompt_tokens = 1, completion_tokens = 2, total_tokens = 3),
    ))
    server = HTTP.serve!("127.0.0.1", 0) do req
        return HTTP.Response(200, ["Content-Type" => "application/json"], body)
    end
    try
        port = test_server_port(server)
        model = Model(
            id = "test-reasoning", name = "test-reasoning", api = "openai-completions",
            provider = "openrouter", baseUrl = "http://127.0.0.1:$port", reasoning = true,
            input = ["text"],
            cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
            contextWindow = 128000, maxTokens = 4096,
            compat = Dict{String, Any}("thinkingFormat" => "openrouter"),
        )
        agent = Agent(prompt = "p", model = model, apikey = "k")
        state = stream(_ -> nothing, agent, AgentState(), "q", Abort(); stream = false)
        msg = state.messages[end]
        thinking_blocks = [b for b in msg.content if b isa Agentif.ThinkingContent]
        thinking = join((b.thinking for b in thinking_blocks), "")
        @test thinking == "fallback"
        @test Agentif.message_text(msg) == "42"
        @test JSON.parse(only(thinking_blocks).thinkingSignature) ==
            [Dict("type" => "reasoning.encrypted", "data" => "sig")]
    finally
        close(server)
    end
end

@testset "openrouter reasoning replay is round-scoped" begin
    model = Model(
        id = "test-rr", name = "test-rr", api = "openai-completions",
        provider = "openrouter", baseUrl = "http://localhost", reasoning = true,
        input = ["text"],
        cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
        contextWindow = 128000, maxTokens = 4096,
        compat = Dict{String, Any}("thinkingFormat" => "openrouter"),
    )
    agent = Agent(prompt = "p", model = model, apikey = "k")
    old_details = [Dict("type" => "reasoning.text", "text" => "old thinking")]
    current_details = [Dict("type" => "reasoning.encrypted", "data" => "current-sig")]
    state = AgentState()
    push!(state.messages, Agentif.UserMessage([Agentif.TextContent(; text = "round one")]))
    push!(state.messages, AssistantMessage(;
        provider = "other", api = "openai-completions", model = "other-model",
        content = Agentif.AssistantContentBlock[
            # Cross-model and unsigned thinking becomes text in transform_messages;
            # round scoping must remove it before that conversion.
            Agentif.ThinkingContent(; thinking = "old unsigned thinking"),
            Agentif.TextContent(; text = "answer one"),
            Agentif.ToolCallContent(; id = "old-call", name = "bash", arguments = Dict("command" => "true"),
                thoughtSignature = JSON.json(only(old_details))),
        ]))
    push!(state.messages, Agentif.ToolResultMessage(;
        call_id = "old-call", name = "bash", content = [Agentif.TextContent(; text = "ok")], is_error = false))
    push!(state.messages, Agentif.UserMessage([Agentif.TextContent(; text = "round two")]))
    push!(state.messages, AssistantMessage(;
        provider = "openrouter", api = "openai-completions", model = "test-rr",
        content = Agentif.AssistantContentBlock[
            Agentif.ThinkingContent(; thinking = "current thinking",
                thinkingSignature = JSON.json(current_details)),
            Agentif.ToolCallContent(; id = "current-call", name = "bash",
                arguments = Dict("command" => "true")),
        ]))

    messages, _ = Agentif.openai_completions_build_messages(agent, state, [Agentif.ToolResultMessage(;
        call_id = "current-call", name = "bash", content = [Agentif.TextContent(; text = "ok")], is_error = false)], model)
    assistants = [m for m in messages if m.role == "assistant"]
    @test length(assistants) == 2
    # prior-round reasoning dropped; current-round reasoning replayed
    first_content = assistants[1].content
    @test !occursin("old unsigned thinking", JSON.json(first_content))
    @test assistants[1].reasoning_details === nothing
    @test assistants[2].reasoning_details == current_details

    compacted = AgentState(messages = Agentif.StoredAgentMessage[
        Agentif.CompactionSummaryMessage(; summary = "summary", tokens_before = 100, compacted_at = time()),
        AssistantMessage(;
            provider = "openrouter", api = "openai-completions", model = "test-rr",
            content = Agentif.AssistantContentBlock[
                Agentif.ThinkingContent(; thinking = "after summary",
                    thinkingSignature = JSON.json(current_details)),
                Agentif.ToolCallContent(; id = "summary-call", name = "bash",
                    arguments = Dict("command" => "true")),
            ]),
    ])
    compacted_messages, _ = Agentif.openai_completions_build_messages(
        agent, compacted, [Agentif.ToolResultMessage(;
            call_id = "summary-call", name = "bash",
            content = [Agentif.TextContent(; text = "ok")], is_error = false)], model)
    @test only(m.reasoning_details for m in compacted_messages if m.role == "assistant") == current_details
end
