# llmtools.jl — Claw-level async wrapper for LLMTools (sub-agents, PTY, workers)
# Provides EventSource integration so async operations notify the parent via events.
# PtySessions and ConcurrentUtilities accessed through LLMTools (already a dep).

# ─── AsyncSessionChannel ───
# Captures the originating channel at spawn time and delegates sends to it, while
# keeping a per-session `channel_id` so each async session gets its own branch.

mutable struct AsyncSessionChannel <: Agentif.AbstractChannel
    session_name::String
    origin_channel_id::Union{Nothing, String}
    io::Union{Nothing, IOBuffer}
end

AsyncSessionChannel(name::String, origin::Union{Nothing, String}) = AsyncSessionChannel(name, origin, nothing)

async_channel_id(name::AbstractString) = "async:$(name)"

Agentif.channel_id(ch::AsyncSessionChannel) = async_channel_id(ch.session_name)
Agentif.channel_name(ch::AsyncSessionChannel) = "Async session $(ch.session_name)"

function _async_origin(ch::AsyncSessionChannel)
    ch.origin_channel_id === nothing && return nothing
    a = get_current_assistant()
    a === nothing && return nothing
    origin = _channel_get(a, ch.origin_channel_id)
    origin isa AsyncSessionChannel && return nothing   # never chain async channels
    return origin
end

# Buffer rather than stream: the origin channel object is shared, and a rehydrated
# or long-idle channel has lost its streaming context anyway.
Agentif.start_streaming(ch::AsyncSessionChannel) = (ch.io === nothing && (ch.io = IOBuffer()); nothing)
function Agentif.append_to_stream(ch::AsyncSessionChannel, delta::AbstractString)
    ch.io === nothing && (ch.io = IOBuffer())
    write(ch.io, String(delta))
    return nothing
end
Agentif.finish_streaming(::AsyncSessionChannel) = nothing

function Agentif.send_message(ch::AsyncSessionChannel, msg)
    origin = _async_origin(ch)
    if origin === nothing
        @debug "Claw: async session has no reachable origin channel; dropping message" session = ch.session_name origin = ch.origin_channel_id
        return nothing
    end
    return Agentif.send_message(origin, msg)
end

function Agentif.close_channel(ch::AsyncSessionChannel)
    io = ch.io
    ch.io = nothing
    io === nothing && return nothing
    text = String(take!(io))
    isempty(strip(text)) && return nothing
    Agentif.send_message(ch, text)
    return nothing
end

function Agentif.is_group(ch::AsyncSessionChannel)
    origin = _async_origin(ch)
    return origin === nothing ? false : Agentif.is_group(origin)
end

function Agentif.is_private(ch::AsyncSessionChannel)
    origin = _async_origin(ch)
    return origin === nothing ? true : Agentif.is_private(origin)
end

# Session entries for async completions belong to the async session's own branch,
# not the originating conversation's.
Agentif.search_channel_id(ch::AsyncSessionChannel) =
    ch.origin_channel_id === nothing ? Agentif.channel_id(ch) : ch.origin_channel_id

# ─── Session tracking ───

mutable struct ClawLLMSession
    name::String
    kind::Symbol            # :subagent, :pty, :worker
    registry_id::Int        # LLMTools registry ID (PTY/worker); 0 for subagent
    agent::Union{Nothing, Agentif.Agent}       # subagent only
    state::Union{Nothing, Agentif.AgentState}  # subagent only
    task::Union{Nothing, Task}                 # async background task
    event_type::String      # "subagent:<name>", "pty:<name>", "worker:<name>"
    handler_prompt::String
    created_at::Float64
    last_used::Float64
    status::String          # "running", "completed", "exited", "error", "killed"
end

# ─── Event types ───

struct SubagentOutputEvent <: Event
    event_type::String
    name::String
    output::String
end
get_name(ev::SubagentOutputEvent) = ev.event_type
event_content(ev::SubagentOutputEvent) = ev.output

struct PtyOutputEvent <: Event
    event_type::String
    name::String
    output::String
    exit_code::Union{Nothing, Int}
    exited::Bool
end
PtyOutputEvent(event_type, name, output, exit_code) =
    PtyOutputEvent(event_type, name, output, exit_code, exit_code !== nothing)
get_name(ev::PtyOutputEvent) = ev.event_type
function event_content(ev::PtyOutputEvent)
    parts = [ev.output]
    if ev.exited
        # Report the *real* status: telling the agent a failing build exited 0 is
        # worse than telling it the status could not be read.
        push!(parts, ev.exit_code === nothing ?
            "\n[Process exited (status unavailable)]" :
            "\n[Process exited with code $(ev.exit_code)]")
    end
    return join(parts)
end

struct WorkerOutputEvent <: Event
    event_type::String
    name::String
    output::String
end
get_name(ev::WorkerOutputEvent) = ev.event_type
event_content(ev::WorkerOutputEvent) = ev.output

# Async completions all share one lane so a chatty process produces a queue, not
# 1200 concurrent LLM calls (§1.4).
event_source_tag(::SubagentOutputEvent) = "llmtools"
event_source_tag(::PtyOutputEvent) = "llmtools"
event_source_tag(::WorkerOutputEvent) = "llmtools"

# Output of the agent's own subagents/processes/workers — self-initiated local
# work, presented like any other tool output, not third-party event payloads.
is_trusted_content(::SubagentOutputEvent) = true
is_trusted_content(::PtyOutputEvent) = true
is_trusted_content(::WorkerOutputEvent) = true
event_lane(::SubagentOutputEvent) = "async"
event_lane(::PtyOutputEvent) = "async"
event_lane(::WorkerOutputEvent) = "async"

function _async_event_extra(name::String)
    extra = Dict{String, Any}("session" => name)
    assistant = get_current_assistant()
    assistant === nothing && return extra
    ch = _channel_get(assistant, async_channel_id(name))
    if ch isa AsyncSessionChannel && ch.origin_channel_id !== nothing
        extra["origin_channel_id"] = ch.origin_channel_id
    end
    return extra
end

function event_extra(ev::PtyOutputEvent)
    extra = _async_event_extra(ev.name)
    extra["exit_code"] = ev.exit_code
    extra["exited"] = ev.exited
    return extra
end
event_extra(ev::SubagentOutputEvent) = _async_event_extra(ev.name)
event_extra(ev::WorkerOutputEvent) = _async_event_extra(ev.name)

function _rehydrate_llmtools_event(row)
    name = get(() -> "", row.extra, "session")
    origin = get(() -> nothing, row.extra, "origin_channel_id")
    if name isa AbstractString && !isempty(name) && origin isa AbstractString
        ch = AsyncSessionChannel(String(name), String(origin))
        _channel_set!(row.assistant, Agentif.channel_id(ch), ch)
    end
    return ReplayedEvent(row.name, row.content)
end

# ─── LLMToolsEventSource ───

mutable struct LLMToolsEventSource <: EventSource
    config::AgentConfig
    sessions::Dict{String, ClawLLMSession}
    lock::ReentrantLock
end

LLMToolsEventSource(config::AgentConfig) = LLMToolsEventSource(config, Dict{String, ClawLLMSession}(), ReentrantLock())

get_channels(::LLMToolsEventSource) = Agentif.AbstractChannel[]
get_event_types(::LLMToolsEventSource) = EventType[]
get_event_handlers(::LLMToolsEventSource) = EventHandler[]

function get_tools(es::LLMToolsEventSource)
    tools = Agentif.AgentTool[]
    append!(tools, _create_subagent_tools(es))
    append!(tools, _create_pty_tools(es))
    append!(tools, _create_worker_tools(es))
    cfg = es.config
    cfg.enable_coding && append!(tools, LLMTools.coding_tools(cfg.base_dir))
    cfg.enable_web && append!(tools, LLMTools.web_tools())
    return tools
end

start!(::LLMToolsEventSource, ::AgentAssistant) = nothing

function stop!(es::LLMToolsEventSource)
    sessions = lock(es.lock) do
        snapshot = collect(values(es.sessions))
        empty!(es.sessions)
        snapshot
    end
    for session in sessions
        session.status = "killed"
        if session.kind === :pty && session.registry_id > 0
            LLMTools.remove_session!(LLMTools.PTY_REGISTRY, session.registry_id;
                mark_status = LLMTools.SESSION_STATUS_KILLED, close_session = true)
        elseif session.kind === :worker && session.registry_id > 0
            LLMTools.remove_session!(LLMTools.WORKER_REGISTRY, session.registry_id;
                mark_status = LLMTools.SESSION_STATUS_KILLED, close_session = true)
        end
        task = session.task
        if task !== nothing && !istaskdone(task)
            try
                schedule(task, InterruptException(); error = true)
            catch
            end
        end
    end
    tasks = Task[s.task for s in sessions if s.task !== nothing]
    isempty(tasks) || timedwait(() -> all(istaskdone, tasks), 5.0; pollint = 0.05)
    return nothing
end

# ─── Helpers ───

const _NAME_RE = r"^[a-z0-9]+(-[a-z0-9]+)*$"

function _assistant_log_level()
    assistant = get_current_assistant()
    assistant === nothing && return nothing
    return assistant.log_level
end

function _async_tool_error_json(
        ;
        tool::String,
        session_name::String,
        operation::String,
        error_kind::String,
        err::Exception,
        bt = nothing,
        suggested_fix::Union{Nothing, String} = nothing,
    )
    return Agentif.render_tool_error_json(
        ;
        error_kind,
        message = sprint(showerror, err),
        tool,
        call_id = session_name,
        exception = err,
        backtrace = bt,
        suggested_fix,
        extra = Dict(
            "operation" => operation,
            "session_name" => session_name,
        ),
    )
end

function _validate_name(es::LLMToolsEventSource, name::String)
    occursin(_NAME_RE, name) || error("Invalid name '$name': must be lowercase alphanumeric with hyphens (e.g. 'my-agent')")
    lock(es.lock) do
        haskey(es.sessions, name) && error("Session '$name' already exists. Use the corresponding kill command first or choose a different name.")
    end
end

function _get_session(es::LLMToolsEventSource, name::String, kind::Symbol)
    session = lock(es.lock) do
        get(es.sessions, name, nothing)
    end
    session === nothing && error("No $kind session named '$name'. Use the list command to see active sessions.")
    session.kind == kind || error("Session '$name' is a $(session.kind), not a $kind.")
    return session
end

function _async_session_cancelled(
        es::LLMToolsEventSource,
        assistant::AgentAssistant,
        name::String,
        err::Union{Nothing, Exception} = nothing,
    )
    err isa InterruptException && return true
    assistant._state[] in (:stopping, :stopped) && return true
    return lock(es.lock) do
        session = get(es.sessions, name, nothing)
        session === nothing || session.status == "killed"
    end
end

function _current_channel_id()
    ch = Agentif.CURRENT_CHANNEL[]
    ch === nothing && return nothing
    ch isa AsyncSessionChannel && return ch.origin_channel_id
    return Agentif.channel_id(ch)
end

function _register_async_session!(
    es::LLMToolsEventSource,
    name::String,
    kind::Symbol,
    event_type::String,
    prompt::String;
    registry_id::Int = 0,
    agent::Union{Nothing, Agentif.Agent} = nothing,
    state::Union{Nothing, Agentif.AgentState} = nothing,
    origin_channel_id::Union{Nothing, String} = _current_channel_id(),
)
    a = get_current_assistant()
    a === nothing && error("No assistant initialized")
    _with_busy_retry() do
        _exec!(a.db,
            "INSERT OR IGNORE INTO claw_event_types (name, description) VALUES (?, ?)",
            (event_type, "LLMTools $kind: $name"))
    end
    # Capture the originating channel at spawn time so the completion actually
    # reaches the human who asked for it, on this session's own branch.
    session_channel = AsyncSessionChannel(name, origin_channel_id)
    channel_id = Agentif.channel_id(session_channel)
    _channel_set!(a, channel_id, session_channel)
    eh = EventHandler(event_type, [event_type], prompt, channel_id)
    register_event_handler!(a, eh)
    now = time()
    session = ClawLLMSession(name, kind, registry_id, agent, state, nothing, event_type, prompt, now, now, "running")
    lock(es.lock) do
        es.sessions[name] = session
    end
    @info "LLMTools async session registered" name kind registry_id event_type origin_channel_id
    return session
end

function _cleanup_session!(es::LLMToolsEventSource, name::String)
    session = lock(es.lock) do
        pop!(es.sessions, name, nothing)
    end
    session === nothing && return
    a = get_current_assistant()
    if a !== nothing
        try
            unregister_event_handler!(a, session.event_type)
            _channel_delete!(a, async_channel_id(name))
            _with_busy_retry() do
                _exec!(a.db, "DELETE FROM claw_event_types WHERE name = ?", (session.event_type,))
            end
        catch
        end
    end
    @info "LLMTools async session cleaned up" name kind = session.kind status = session.status
    return session
end

# ─── PTY output coalescing helpers (§1.4) ───

"""
    _truncate_pty_output(text, max_bytes) -> String

Keep the tail (the part a caller actually needs) and cut on a valid character
boundary so a truncated multi-byte sequence never reaches the model.
"""
function _truncate_pty_output(text::String, max_bytes::Int)
    # PTY output is arbitrary bytes, but it lands in event payloads that are
    # JSON-encoded for the model and persisted to SQLite, so it must be valid
    # UTF-8. Repairing here also keeps the index arithmetic below well-defined.
    # This is the point at which the captured output is complete, so a character
    # split across two reads is already rejoined.
    text = LLMTools.repair_utf8(text)
    max_bytes <= 0 && return text
    ncodeunits(text) <= max_bytes && return text
    dropped = ncodeunits(text) - max_bytes
    idx = thisind(text, min(lastindex(text), dropped + 1))
    idx < firstindex(text) && (idx = firstindex(text))
    idx = nextind(text, idx, 0)
    tail = SubString(text, idx)
    return string("[... ", ncodeunits(text) - ncodeunits(tail), " bytes of earlier output truncated ...]\n", tail)
end

function _drain_pty_buffer!(buffer::IOBuffer, max_bytes::Int)
    text = String(take!(buffer))
    return _truncate_pty_output(text, max_bytes)
end

"""
    _pty_exit_code(session) -> Union{Nothing, Int}

Real exit status of the PTY's process, or `nothing` when it cannot be read. The
previous code hardcoded `0`, which told the agent a failing build had succeeded.
"""
function _pty_exit_code(session)
    try
        proc = session.process
        Base.process_exited(proc) || return nothing
        return Int(proc.exitcode)
    catch e
        @debug "Claw: could not read PTY exit code" exception = (e,)
        return nothing
    end
end

function _pty_shell_command(shell::AbstractString, cmd::AbstractString)
    command = LLMTools.subprocess_shell_command(shell, cmd)
    Sys.iswindows() && return (command, nothing)

    # PtySessions starts the child before its constructor returns. A command such
    # as `printf x; exit` can therefore finish before Claw can start its reader,
    # and macOS can discard those unread master-side bytes when the slave closes.
    # The outer non-login shell waits for one silent input line. The capture task
    # sends that line only after the PTY is fully constructed.
    gate = "IFS= read -r -s _; exec \"\$@\""
    gated = Cmd(vcat(
        String[String(shell), "-c", gate, "claw-pty-gate"],
        String[String(arg) for arg in command.exec],
    ))
    return (gated, "\n")
end

function _start_pty_capture(session; release::Union{Nothing, String} = nothing)
    buffer = IOBuffer()
    buffer_lock = ReentrantLock()
    stop = Threads.Atomic{Bool}(false)
    started = Channel{Any}(1)
    task = errormonitor(Threads.@spawn begin
        try
            release === nothing || LLMTools.PtySessions.write(session, release)
            put!(started, nothing)
        catch e
            put!(started, e)
            return
        end
        while !stop[]
            # Bounded wait keeps stop[] responsive; at_eof is a deterministic
            # completion signal (process exited AND every output byte drained),
            # which replaces the old EAGAIN-vs-EOF quiescence heuristic that the
            # pre-Base.TTY PtySessions forced on this loop.
            output, at_eof = LLMTools.read_pty_output(session, 0.25)
            if !isempty(output)
                lock(buffer_lock) do
                    write(buffer, output)
                end
            end
            at_eof && break
        end
    end)
    start_error = take!(started)
    start_error === nothing || begin
        wait(task)
        throw(start_error)
    end
    return buffer, buffer_lock, stop, task
end

function _take_pty_capture!(buffer::IOBuffer, buffer_lock::ReentrantLock)
    return lock(buffer_lock) do
        String(take!(buffer))
    end
end

function _build_subagent_tools(config::AgentConfig)
    tools = Agentif.AgentTool[]
    append!(tools, LLMTools.coding_tools(config.base_dir))
    append!(tools, LLMTools.create_worker_tools())
    append!(tools, LLMTools.web_tools())
    return tools
end

# ─── Sub-agent tools ───

function _create_subagent_tools(es::LLMToolsEventSource)

    start_tool = @tool(
        """Spawn an independent child agent with its own system prompt, tools, and context to perform a delegated task.

Use this to delegate complex, self-contained tasks (research, code generation, analysis) that benefit from a separate instruction set and tool access. The child agent gets coding tools, worker tools, and web tools. Prefer start_worker for pure Julia computation or start_pty for shell commands.

Runs ASYNC by default: returns immediately, you receive a notification event when the sub-agent finishes. Set run_sync=true to block and return the result directly (only for tasks you expect to complete quickly).

Arguments:
- name (String, required): Unique session identifier. MUST be kebab-case matching ^[a-z0-9]+(-[a-z0-9]+)*\$ — e.g. "code-review", "data-fetch", "analyze3". No uppercase, spaces, or underscores.
- system_prompt (String, required): The child agent's system instructions. This defines the sub-agent's role and behavior.
- input_message (String, required): The task or question to send to the child agent.
- prompt (String, optional): Notification context prepended to the async completion event. Use it to remind yourself what you delegated — e.g. "Summary of error logs from service X". Ignored when run_sync=true.
- run_sync (Bool, optional): If true, blocks until the sub-agent finishes and returns its output directly. Default: false (async).

Examples:
- start_subagent("refactor-auth", "You are a senior Julia developer...", "Refactor the auth module to use token-based sessions")
- start_subagent("quick-check", "You are a code reviewer.", "Is this function type-stable?", run_sync=true)""",
        start_subagent(
            name::String,
            system_prompt::String,
            input_message::String,
            prompt::Union{Nothing, String} = nothing,
            run_sync::Union{Nothing, Bool} = nothing,
        ) = begin
            sync = run_sync === nothing ? false : run_sync
            _validate_name(es, name)
            a = get_current_assistant()
            a === nothing && return "No assistant initialized"
            @info "Starting worker session" name sync
            cfg = es.config
            model = Agentif.getModel(cfg.provider, cfg.model_id)
            model === nothing && error("Unknown model: provider=$(cfg.provider) model_id=$(cfg.model_id)")
            child_tools = _build_subagent_tools(cfg)
            child = Agentif.Agent(;
                prompt = system_prompt,
                model = model,
                apikey = cfg.apikey,
                tools = child_tools,
            )
            level = _assistant_log_level()
            if sync
                result_state = Agentif.evaluate(child, input_message; level)
                msg = Agentif.last_assistant_message(result_state)
                output = msg === nothing ? "" : string(Agentif.message_text(msg))
                return LLMTools.truncate_tool_output(output; label = "Subagent output")
            end
            event_type = "subagent:$name"
            handler_prompt = something(prompt, "")
            session = _register_async_session!(es, name, :subagent, event_type, handler_prompt;
                agent = child, state = Agentif.AgentState())
            session.task = Threads.@spawn begin
                try
                    result_state = Agentif.evaluate(child, input_message; level)
                    msg = Agentif.last_assistant_message(result_state)
                    output = msg === nothing ? "" : string(Agentif.message_text(msg))
                    lock(es.lock) do
                        s = get(es.sessions, name, nothing)
                        if s !== nothing
                            s.state = result_state
                            s.last_used = time()
                            s.status = "completed"
                        end
                    end
                    _async_session_cancelled(es, a, name) && return nothing
                    submit_event!(a, SubagentOutputEvent(event_type, name, output))
                catch e
                    _async_session_cancelled(es, a, name, e) && return nothing
                    bt = catch_backtrace()
                    lock(es.lock) do
                        s = get(es.sessions, name, nothing)
                        s !== nothing && (s.status = "error")
                    end
                    @error "Sub-agent execution failed" name event_type exception = (e, bt)
                    payload = _async_tool_error_json(
                        ;
                        tool = "subagent",
                        session_name = name,
                        operation = "start_subagent",
                        error_kind = "subagent_execution_failed",
                        err = e,
                        bt,
                        suggested_fix = "Inspect message/error_kind and retry by adjusting the prompt or input_message.",
                    )
                    submit_event!(a, SubagentOutputEvent(event_type, name, payload))
                end
            end
            return "Sub-agent '$name' started asynchronously. You'll be notified when it completes."
        end,
    )

    message_tool = @tool(
        """Send a follow-up message to a previously started sub-agent, continuing its conversation with full prior context.

Use this to ask follow-up questions, request refinements, or give the sub-agent additional instructions after its initial task completes. The sub-agent retains all state from prior interactions.

The sub-agent must be in "completed" status — it cannot receive messages while still running. Use list_subagents to check status. Runs ASYNC by default; set run_sync=true to block and get the response directly.

Arguments:
- name (String, required): The name of an existing sub-agent session (as given to start_subagent).
- input_message (String, required): The follow-up message or question to send.
- run_sync (Bool, optional): If true, blocks until the sub-agent responds. Default: false (async).

Example:
- message_subagent("refactor-auth", "Now add unit tests for the new token validation function")""",
        message_subagent(
            name::String,
            input_message::String,
            run_sync::Union{Nothing, Bool} = nothing,
        ) = begin
            sync = run_sync === nothing ? false : run_sync
            session = _get_session(es, name, :subagent)
            session.agent === nothing && error("Sub-agent '$name' has no agent instance")
            session.state === nothing && error("Sub-agent '$name' has no state")
            session.status in ("running",) && error("Sub-agent '$name' is still processing. Wait for it to complete before sending another message.")
            a = get_current_assistant()
            a === nothing && return "No assistant initialized"
            level = _assistant_log_level()
            if sync
                result_state = Agentif.evaluate(session.agent, input_message; state = session.state, level)
                lock(es.lock) do
                    s = get(es.sessions, name, nothing)
                    if s !== nothing
                        s.state = result_state
                        s.last_used = time()
                    end
                end
                msg = Agentif.last_assistant_message(result_state)
                output = msg === nothing ? "" : string(Agentif.message_text(msg))
                return LLMTools.truncate_tool_output(output; label = "Subagent output")
            end
            event_type = session.event_type
            lock(es.lock) do
                session.status = "running"
                session.last_used = time()
            end
            session.task = Threads.@spawn begin
                try
                    result_state = Agentif.evaluate(session.agent, input_message; state = session.state, level)
                    msg = Agentif.last_assistant_message(result_state)
                    output = msg === nothing ? "" : string(Agentif.message_text(msg))
                    lock(es.lock) do
                        s = get(es.sessions, name, nothing)
                        if s !== nothing
                            s.state = result_state
                            s.last_used = time()
                            s.status = "completed"
                        end
                    end
                    _async_session_cancelled(es, a, name) && return nothing
                    submit_event!(a, SubagentOutputEvent(event_type, name, output))
                catch e
                    _async_session_cancelled(es, a, name, e) && return nothing
                    bt = catch_backtrace()
                    lock(es.lock) do
                        s = get(es.sessions, name, nothing)
                        s !== nothing && (s.status = "error")
                    end
                    @error "Sub-agent follow-up failed" name event_type exception = (e, bt)
                    payload = _async_tool_error_json(
                        ;
                        tool = "subagent",
                        session_name = name,
                        operation = "message_subagent",
                        error_kind = "subagent_followup_failed",
                        err = e,
                        bt,
                        suggested_fix = "Inspect session status and the error payload, then retry with corrected input or create a fresh sub-agent.",
                    )
                    submit_event!(a, SubagentOutputEvent(event_type, name, payload))
                end
            end
            return "Message sent to sub-agent '$name'. You'll be notified when it responds."
        end,
    )

    list_tool = @tool(
        """List all active sub-agent sessions with their current status and timing info.

Returns each sub-agent's name, status (running/completed/error/killed), age since creation, and idle time since last activity. Returns "No active sub-agents" if none exist. Use this to check if a sub-agent has finished before calling message_subagent, or to find sessions to kill.""",
        list_subagents() = begin
            lines = String[]
            lock(es.lock) do
                for (name, s) in sort!(collect(es.sessions); by = first)
                    s.kind == :subagent || continue
                    age_s = round(time() - s.created_at; digits = 1)
                    idle_s = round(time() - s.last_used; digits = 1)
                    push!(lines, "- $name [$(s.status)] age=$(age_s)s idle=$(idle_s)s")
                end
            end
            isempty(lines) ? "No active sub-agents" : join(lines, "\n")
        end,
    )

    kill_tool = @tool(
        """Terminate and remove a sub-agent session, freeing its name for reuse.

Interrupts the sub-agent if still running and unregisters its event handler. Use this to clean up finished sub-agents you no longer need, or to force-stop a stuck/runaway sub-agent.

Arguments:
- name (String, required): The name of the sub-agent session to kill.""",
        kill_subagent(name::String) = begin
            session = _cleanup_session!(es, name)
            session === nothing && return "No sub-agent named '$name'"
            if session.task !== nothing && !istaskdone(session.task)
                try; schedule(session.task, InterruptException(); error = true); catch; end
            end
            return "Sub-agent '$name' killed and removed."
        end,
    )

    return Agentif.AgentTool[start_tool, message_tool, list_tool, kill_tool]
end

# ─── PTY tools ───

function _create_pty_tools(es::LLMToolsEventSource)

    start_tool = @tool(
        """Start a persistent terminal (PTY) session and run a shell command in it.

Use this for shell commands, especially long-running ones like servers, builds, test suites, or interactive processes. For quick one-shot commands, set run_sync=true. For pure Julia computation, prefer start_worker. For tasks needing LLM reasoning, prefer start_subagent.

Runs ASYNC by default: returns immediately, you receive coalesced notification events as terminal output becomes available. When the process exits, you get a final notification with the exit code. Set run_sync=true to block ~0.5s and return the initial output directly.

Arguments:
- name (String, required): Unique session identifier. MUST be kebab-case matching ^[a-z0-9]+(-[a-z0-9]+)*\$ — e.g. "test-run", "dev-server", "build1". No uppercase, spaces, or underscores.
- cmd (String, required): The shell command to execute (run via a non-login bash shell on Unix, or PowerShell with profiles disabled on Windows).
- prompt (String, optional): Notification context prepended to async output events. Use to label what this terminal is doing — e.g. "Test suite output". Ignored when run_sync=true.
- workdir (String, optional): Working directory for the command. Defaults to the agent's configured base_dir.
- run_sync (Bool, optional): If true, blocks ~0.5s and returns initial output. Default: false (async).

Examples:
- start_pty("test-run", "julia --project -e 'using Pkg; Pkg.test()'", "Test results")
- start_pty("quick-ls", "ls -la /tmp", run_sync=true)""",
        start_pty(
            name::String,
            cmd::String,
            prompt::Union{Nothing, String} = nothing,
            workdir::Union{Nothing, String} = nothing,
            run_sync::Union{Nothing, Bool} = nothing,
        ) = begin
            sync = run_sync === nothing ? false : run_sync
            _validate_name(es, name)
            a = get_current_assistant()
            a === nothing && return "No assistant initialized"
            cfg = es.config
            work_dir = workdir === nothing ? cfg.base_dir : workdir
            isdir(work_dir) || error("Working directory not found: $work_dir")
            @info "Starting PTY session" name cmd work_dir sync

            shell_cmd = Sys.iswindows() ? "powershell" : "bash"
            full_cmd, release = _pty_shell_command(shell_cmd, cmd)

            LLMTools.ensure_cleanup_task_running!(LLMTools.PTY_REGISTRY)
            LLMTools.cleanup_exited_sessions!(LLMTools.PTY_REGISTRY)
            registry_id = LLMTools.next_session_id!(LLMTools.PTY_REGISTRY)
            # Allowlisted environment only (§2.4): this PTY is reachable from an
            # inbound message, so it must not carry the assistant's own API keys.
            pty_session = LLMTools.PtySessions.PtySession(full_cmd; dir = work_dir,
                env = LLMTools.subprocess_env())
            capture_buffer, capture_lock, capture_stop, capture_task = try
                _start_pty_capture(pty_session; release)
            catch
                try; close(pty_session); catch; end
                rethrow()
            end

            if sync
                # Start draining before the process can exit. On macOS, unread
                # PTY bytes can disappear when the slave closes, so sleeping
                # first loses output from short commands.
                timedwait(() -> istaskdone(capture_task), 0.5; pollint = 0.01)
                is_running = try; LLMTools.PtySessions.isactive(pty_session); catch; false; end
                if is_running
                    # A synchronous call returns after its initial window. Stop
                    # its private reader, then leave the live process available
                    # to the normal registry cleanup path.
                    capture_stop[] = true
                    wait(capture_task)
                else
                    wait(capture_task)
                end
                output = _take_pty_capture!(capture_buffer, capture_lock)
                if is_running
                    now = time()
                    LLMTools.register_session!(LLMTools.PTY_REGISTRY, registry_id,
                        LLMTools.PtySessionMetadata(
                            pty_session,
                            now,
                            now,
                            cmd,
                            work_dir,
                            LLMTools.SESSION_STATUS_RUNNING,
                            nothing,
                            true,
                        ))
                else
                    try; close(pty_session); catch; end
                end
                return LLMTools.truncate_tool_output(output; label = "PTY output")
            end

            now = time()
            # Claw owns the polling lifecycle. The generic LLMTools cleanup task
            # must not close the PTY after process exit but before this task drains
            # its final bytes.
            meta = LLMTools.PtySessionMetadata(
                pty_session,
                now,
                now,
                cmd,
                work_dir,
                LLMTools.SESSION_STATUS_RUNNING,
                nothing,
                false,
            )
            LLMTools.register_session!(LLMTools.PTY_REGISTRY, registry_id, meta)
            event_type = "pty:$name"
            handler_prompt = something(prompt, "")
            session = _register_async_session!(es, name, :pty, event_type, handler_prompt;
                registry_id = registry_id)
            notify_interval = a.pipeline.pty_notify_interval_s
            max_event_bytes = a.pipeline.pty_max_event_bytes
            session.task = Threads.@spawn begin
                try
                    # Coalesce output: a 0.5s poll used to trigger a full LLM
                    # evaluation per chunk. Accumulate instead and emit at most one
                    # event per `pty_notify_interval`, capped in size.
                    buffer = IOBuffer()
                    last_emit = time()
                    last_output = ""
                    while true
                        # A dedicated reader starts before handler registration and
                        # owns PTY reads. This loop only drains its capture buffer
                        # and coalesces model-facing events.
                        pty_meta = LLMTools.get_session(LLMTools.PTY_REGISTRY, registry_id)
                        live = pty_meta === nothing ? pty_session : pty_meta.session
                        output = _take_pty_capture!(capture_buffer, capture_lock)
                        if !isempty(output)
                            write(buffer, output)
                            last_output = _truncate_pty_output(output, max_event_bytes)
                        end
                        is_active = try; LLMTools.PtySessions.isactive(live); catch; false; end
                        if !is_active && istaskdone(capture_task)
                            # The reader is the completion signal. Drain once more
                            # after it stops so no captured bytes remain behind.
                            remaining = _take_pty_capture!(capture_buffer, capture_lock)
                            if !isempty(remaining)
                                write(buffer, remaining)
                                last_output = _truncate_pty_output(remaining, max_event_bytes)
                            end
                            lock(es.lock) do
                                s = get(es.sessions, name, nothing)
                                s !== nothing && (s.status = "exited")
                            end
                            exit_code = _pty_exit_code(live)
                            final_output = _drain_pty_buffer!(buffer, max_event_bytes)
                            # The process can exit just after an active poll flushed
                            # its final chunk. Repeat that bounded tail so the
                            # terminal event always carries the output that led to
                            # the reported exit status.
                            isempty(final_output) && (final_output = last_output)
                            submit_event!(a, PtyOutputEvent(event_type, name,
                                final_output, exit_code, true))
                            pty_meta === nothing || LLMTools.remove_session!(LLMTools.PTY_REGISTRY, registry_id;
                                mark_status = LLMTools.SESSION_STATUS_EXITED, close_session = true)
                            break
                        end
                        now = time()
                        if buffer.size > 0 && now - last_emit >= notify_interval
                            submit_event!(a, PtyOutputEvent(event_type, name,
                                _drain_pty_buffer!(buffer, max_event_bytes), nothing, false))
                            last_emit = now
                        end
                        # This is only the transport drain cadence. Model-facing
                        # events still obey `pty_notify_interval_s`.
                        sleep(0.05)
                    end
                catch e
                    if e isa InterruptException || a._state[] in (:stopping, :stopped)
                        LLMTools.remove_session!(LLMTools.PTY_REGISTRY, registry_id;
                            mark_status = LLMTools.SESSION_STATUS_KILLED, close_session = true)
                        return nothing
                    end
                    bt = catch_backtrace()
                    lock(es.lock) do
                        s = get(es.sessions, name, nothing)
                        s !== nothing && (s.status = "error")
                    end
                    @error "PTY polling error" name exception = (e, bt)
                    payload = _async_tool_error_json(
                        ;
                        tool = "pty",
                        session_name = name,
                        operation = "pty_poll",
                        error_kind = "pty_polling_failed",
                        err = e,
                        bt,
                        suggested_fix = "List PTY sessions, then restart or kill/recreate this PTY session.",
                    )
                    LLMTools.remove_session!(LLMTools.PTY_REGISTRY, registry_id;
                        mark_status = LLMTools.SESSION_STATUS_ERROR, close_session = true)
                    submit_event!(a, PtyOutputEvent(event_type, name, payload, nothing, false))
                end
            end
            return "PTY '$name' started asynchronously (cmd: $cmd). You'll be notified when output is available."
        end,
    )

    write_tool = @tool(
        """Send raw input to an existing PTY terminal session.

Use this to type commands, answer interactive prompts, send Ctrl-C (via "\\x03"), or provide stdin data to a running process. The PTY must be in "running" status — use list_ptys to check.

IMPORTANT: Input is sent raw to the terminal. You MUST include "\\n" at the end to execute a command (e.g. "ls -la\\n"). Without "\\n", the text is typed but not submitted.

Runs ASYNC by default: the background polling task will send you a notification when output appears. Set run_sync=true to block ~0.5s and return any immediate output.

Arguments:
- name (String, required): The name of an existing PTY session (as given to start_pty).
- input (String, required): Raw text to send to the terminal. Include "\\n" to execute. Use "\\x03" for Ctrl-C.
- run_sync (Bool, optional): If true, blocks ~0.5s and returns immediate output. Default: false (async).

Example:
- write_pty("dev-server", "curl localhost:8080/health\\n", run_sync=true)""",
        write_pty(
            name::String,
            input::String,
            run_sync::Union{Nothing, Bool} = nothing,
        ) = begin
            sync = run_sync === nothing ? false : run_sync
            session = _get_session(es, name, :pty)
            pty_meta = LLMTools.get_session(LLMTools.PTY_REGISTRY, session.registry_id)
            pty_meta === nothing && error("PTY session '$name' no longer exists in registry")
            LLMTools.PtySessions.write(pty_meta.session, input)
            lock(es.lock) do
                session.last_used = time()
            end
            if sync
                output = LLMTools.read_pty_output(pty_meta.session, 0.5)[1]
                return LLMTools.truncate_tool_output(output; label = "PTY output")
            end
            return "Input sent to PTY '$name'. You'll be notified when output is available."
        end,
    )

    list_tool = @tool(
        """List all active PTY terminal sessions with their current status and timing info.

Returns each PTY's name, status (running/exited/error/killed), age since creation, and idle time since last activity. Returns "No active PTY sessions" if none exist. Use this to check if a PTY is still running before calling write_pty, or to find sessions to kill.""",
        list_ptys() = begin
            lines = String[]
            lock(es.lock) do
                for (name, s) in sort!(collect(es.sessions); by = first)
                    s.kind == :pty || continue
                    age_s = round(time() - s.created_at; digits = 1)
                    idle_s = round(time() - s.last_used; digits = 1)
                    push!(lines, "- $name [$(s.status)] age=$(age_s)s idle=$(idle_s)s")
                end
            end
            isempty(lines) ? "No active PTY sessions" : join(lines, "\n")
        end,
    )

    kill_tool = @tool(
        """Terminate and remove a PTY terminal session, freeing its name for reuse.

Kills the underlying process, stops output polling, and unregisters the event handler. Use this to clean up finished sessions or force-stop a running process.

Arguments:
- name (String, required): The name of the PTY session to kill.""",
        kill_pty(name::String) = begin
            session = _cleanup_session!(es, name)
            session === nothing && return "No PTY session named '$name'"
            if session.task !== nothing && !istaskdone(session.task)
                try; schedule(session.task, InterruptException(); error = true); catch; end
            end
            if session.registry_id > 0
                LLMTools.remove_session!(LLMTools.PTY_REGISTRY, session.registry_id;
                    mark_status = LLMTools.SESSION_STATUS_KILLED, close_session = true)
            end
            return "PTY '$name' killed and removed."
        end,
    )

    return Agentif.AgentTool[start_tool, write_tool, list_tool, kill_tool]
end

# ─── Worker tools ───

function _create_worker_tools(es::LLMToolsEventSource)

    start_tool = @tool(
        """Spawn a persistent Julia worker process and execute initial Julia code on it.

Use this for Julia computations, data processing, package operations, or any task that benefits from a persistent Julia environment. Variables, loaded packages, and defined functions persist across subsequent eval_worker calls. For shell commands, prefer start_pty. For tasks needing LLM reasoning, prefer start_subagent.

Runs ASYNC by default: returns immediately, you receive a notification event when the code finishes executing. Set run_sync=true to block and return the result directly (for quick computations).

Arguments:
- name (String, required): Unique session identifier. MUST be kebab-case matching ^[a-z0-9]+(-[a-z0-9]+)*\$ — e.g. "data-proc", "analysis1", "pkg-test". No uppercase, spaces, or underscores.
- code (String, required): Julia code to evaluate. Runs in a fresh worker process. Output includes both the return value and any stdout/stderr.
- prompt (String, optional): Notification context prepended to the async completion event. Use to label what this worker is computing — e.g. "CSV parsing results". Ignored when run_sync=true.
- run_sync (Bool, optional): If true, blocks until execution completes and returns the output. Default: false (async).
- timeout_s (Int, optional): Timeout in seconds for the initial evaluation. On timeout the worker process is terminated and a timeout error is reported. Default: no timeout.

Examples:
- start_worker("data-proc", "using CSV, DataFrames; df = CSV.read(\\"data.csv\\", DataFrame); describe(df)", "Data summary")
- start_worker("quick-calc", "sum(1:1_000_000)", run_sync=true)""",
        start_worker(
            name::String,
            code::String,
            prompt::Union{Nothing, String} = nothing,
            run_sync::Union{Nothing, Bool} = nothing,
            timeout_s::Union{Nothing, Int} = nothing,
        ) = begin
            sync = run_sync === nothing ? false : run_sync
            _validate_name(es, name)
            a = get_current_assistant()
            a === nothing && return "No assistant initialized"

            LLMTools.ensure_cleanup_task_running!(LLMTools.WORKER_REGISTRY)
            LLMTools.cleanup_exited_sessions!(LLMTools.WORKER_REGISTRY)
            registry_id = LLMTools.next_session_id!(LLMTools.WORKER_REGISTRY)
            output_io = IOBuffer()
            w = LLMTools.Worker(;
                env = LLMTools._worker_env(),
                worker_redirect_io = output_io,
                worker_redirect_fn = (io, pid, line) -> println(io, line),
            )
            now = time()
            desc = LLMTools.truncate_description(code)
            worker_meta = LLMTools.WorkerSessionMetadata(w, output_io, now, now, desc, LLMTools.SESSION_STATUS_RUNNING)
            LLMTools.register_session!(LLMTools.WORKER_REGISTRY, registry_id, worker_meta)

            if sync
                try
                    combined, _ = LLMTools.eval_on_worker(worker_meta, code; timeout_s)
                    return LLMTools.truncate_tool_output(combined; label = "Worker output")
                catch e
                    LLMTools.remove_session!(LLMTools.WORKER_REGISTRY, registry_id;
                        mark_status = LLMTools.SESSION_STATUS_ERROR)
                    rethrow()
                end
            end

            event_type = "worker:$name"
            handler_prompt = something(prompt, "")
            session = _register_async_session!(es, name, :worker, event_type, handler_prompt;
                registry_id = registry_id)
            session.task = Threads.@spawn begin
                try
                    combined, _ = LLMTools.eval_on_worker(worker_meta, code; timeout_s)
                    lock(es.lock) do
                        s = get(es.sessions, name, nothing)
                        if s !== nothing
                            s.last_used = time()
                            s.status = "completed"
                        end
                    end
                    _async_session_cancelled(es, a, name) && return nothing
                    submit_event!(a, WorkerOutputEvent(event_type, name, combined))
                catch e
                    _async_session_cancelled(es, a, name, e) && return nothing
                    bt = catch_backtrace()
                    if e isa LLMTools.WorkerEvalTimeout
                        LLMTools.remove_session!(LLMTools.WORKER_REGISTRY, registry_id;
                            mark_status = LLMTools.SESSION_STATUS_ERROR)
                    end
                    lock(es.lock) do
                        s = get(es.sessions, name, nothing)
                        s !== nothing && (s.status = "error")
                    end
                    @error "Worker execution failed" name event_type exception = (e, bt)
                    payload = _async_tool_error_json(
                        ;
                        tool = "worker",
                        session_name = name,
                        operation = "start_worker",
                        error_kind = "worker_execution_failed",
                        err = e,
                        bt,
                        suggested_fix = "Inspect worker output/error payload and retry with corrected Julia code.",
                    )
                    submit_event!(a, WorkerOutputEvent(event_type, name, payload))
                end
            end
            return "Worker '$name' started asynchronously. You'll be notified when execution completes."
        end,
    )

    eval_tool = @tool(
        """Evaluate Julia code on an existing worker process, with all prior state (variables, packages, functions) preserved.

Use this to run follow-up computations on a worker created by start_worker. All state from previous start_worker and eval_worker calls persists — you can reference variables and functions defined earlier. The worker must not be in "running" status; use list_workers to check.

Runs ASYNC by default: returns immediately, you receive a notification when execution completes. Set run_sync=true to block and return the result directly.

Arguments:
- name (String, required): The name of an existing worker session (as given to start_worker).
- code (String, required): Julia code to evaluate. Can reference variables/functions from prior calls.
- run_sync (Bool, optional): If true, blocks until execution completes. Default: false (async).
- timeout_s (Int, optional): Timeout in seconds for the evaluation. On timeout the worker process is terminated (all its state is lost) and a timeout error is reported. Default: no timeout.

Example:
- eval_worker("data-proc", "filter(row -> row.age > 30, df) |> nrow", run_sync=true)""",
        eval_worker(
            name::String,
            code::String,
            run_sync::Union{Nothing, Bool} = nothing,
            timeout_s::Union{Nothing, Int} = nothing,
        ) = begin
            sync = run_sync === nothing ? false : run_sync
            session = _get_session(es, name, :worker)
            a = get_current_assistant()
            a === nothing && return "No assistant initialized"
            worker_meta = LLMTools.get_session(LLMTools.WORKER_REGISTRY, session.registry_id)
            worker_meta === nothing && error("Worker session '$name' no longer exists in registry")

            if sync
                try
                    combined, _ = LLMTools.eval_on_worker(worker_meta, code; timeout_s)
                    lock(es.lock) do
                        session.last_used = time()
                        session.status = "completed"
                    end
                    return LLMTools.truncate_tool_output(combined; label = "Worker output")
                catch e
                    if e isa LLMTools.WorkerEvalTimeout
                        LLMTools.remove_session!(LLMTools.WORKER_REGISTRY, session.registry_id;
                            mark_status = LLMTools.SESSION_STATUS_ERROR)
                    end
                    lock(es.lock) do
                        session.last_used = time()
                        session.status = "error"
                    end
                    rethrow()
                end
            end

            event_type = session.event_type
            lock(es.lock) do
                session.status = "running"
                session.last_used = time()
            end
            session.task = Threads.@spawn begin
                try
                    combined, _ = LLMTools.eval_on_worker(worker_meta, code; timeout_s = timeout_s)
                    lock(es.lock) do
                        s = get(es.sessions, name, nothing)
                        if s !== nothing
                            s.last_used = time()
                            s.status = "completed"
                        end
                    end
                    _async_session_cancelled(es, a, name) && return nothing
                    submit_event!(a, WorkerOutputEvent(event_type, name, combined))
                catch e
                    _async_session_cancelled(es, a, name, e) && return nothing
                    bt = catch_backtrace()
                    if e isa LLMTools.WorkerEvalTimeout
                        LLMTools.remove_session!(LLMTools.WORKER_REGISTRY, session.registry_id;
                            mark_status = LLMTools.SESSION_STATUS_ERROR)
                    end
                    lock(es.lock) do
                        s = get(es.sessions, name, nothing)
                        s !== nothing && (s.status = "error")
                    end
                    @error "Worker follow-up execution failed" name event_type exception = (e, bt)
                    payload = _async_tool_error_json(
                        ;
                        tool = "worker",
                        session_name = name,
                        operation = "eval_worker",
                        error_kind = "worker_followup_failed",
                        err = e,
                        bt,
                        suggested_fix = "Inspect the error payload and retry with syntactically-valid Julia code that matches the worker's current state.",
                    )
                    submit_event!(a, WorkerOutputEvent(event_type, name, payload))
                end
            end
            return "Code sent to worker '$name'. You'll be notified when execution completes."
        end,
    )

    list_tool = @tool(
        """List all active Julia worker sessions with their current status and timing info.

Returns each worker's name, status (running/completed/error/killed), age since creation, and idle time since last activity. Returns "No active worker sessions" if none exist. Use this to check if a worker has finished before calling eval_worker, or to find sessions to kill.""",
        list_workers() = begin
            lines = String[]
            lock(es.lock) do
                for (name, s) in sort!(collect(es.sessions); by = first)
                    s.kind == :worker || continue
                    age_s = round(time() - s.created_at; digits = 1)
                    idle_s = round(time() - s.last_used; digits = 1)
                    push!(lines, "- $name [$(s.status)] age=$(age_s)s idle=$(idle_s)s")
                end
            end
            isempty(lines) ? "No active worker sessions" : join(lines, "\n")
        end,
    )

    kill_tool = @tool(
        """Terminate and remove a Julia worker session, freeing its name for reuse.

Kills the underlying worker process and unregisters the event handler. Use this to clean up finished workers you no longer need, or to force-stop a stuck computation.

Arguments:
- name (String, required): The name of the worker session to kill.""",
        kill_worker(name::String) = begin
            session = _cleanup_session!(es, name)
            session === nothing && return "No worker session named '$name'"
            if session.task !== nothing && !istaskdone(session.task)
                try; schedule(session.task, InterruptException(); error = true); catch; end
            end
            if session.registry_id > 0
                LLMTools.remove_session!(LLMTools.WORKER_REGISTRY, session.registry_id;
                    mark_status = LLMTools.SESSION_STATUS_KILLED, close_session = true)
            end
            return "Worker '$name' killed and removed."
        end,
    )

    return Agentif.AgentTool[start_tool, eval_tool, list_tool, kill_tool]
end
