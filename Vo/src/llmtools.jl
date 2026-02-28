# llmtools.jl — Vo-level async wrapper for LLMTools (sub-agents, PTY, workers)
# Provides EventSource integration so async operations notify the parent via events.
# PtySessions and ConcurrentUtilities accessed through LLMTools (already a dep).

# ─── ParentAgentChannel ───
# Sink channel for event handler evaluations. The parent's response
# is captured in session (via session middleware) but not streamed externally.

struct ParentAgentChannel <: Agentif.AbstractChannel end

Agentif.channel_id(::ParentAgentChannel) = "parent"
Agentif.channel_name(::ParentAgentChannel) = "Parent Agent (internal)"
Agentif.start_streaming(::ParentAgentChannel) = nothing
Agentif.append_to_stream(::ParentAgentChannel, ::AbstractString) = nothing
Agentif.finish_streaming(::ParentAgentChannel) = nothing
Agentif.send_message(::ParentAgentChannel, _) = nothing
Agentif.close_channel(::ParentAgentChannel) = nothing
Agentif.is_group(::ParentAgentChannel) = false
Agentif.is_private(::ParentAgentChannel) = true

# ─── Session tracking ───

mutable struct VoLLMSession
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
end
get_name(ev::PtyOutputEvent) = ev.event_type
function event_content(ev::PtyOutputEvent)
    parts = [ev.output]
    ev.exit_code !== nothing && push!(parts, "\n[Process exited with code $(ev.exit_code)]")
    return join(parts)
end

struct WorkerOutputEvent <: Event
    event_type::String
    name::String
    output::String
end
get_name(ev::WorkerOutputEvent) = ev.event_type
event_content(ev::WorkerOutputEvent) = ev.output

# ─── LLMToolsEventSource ───

mutable struct LLMToolsEventSource <: EventSource
    config::AgentConfig
    sessions::Dict{String, VoLLMSession}
    lock::ReentrantLock
end

LLMToolsEventSource(config::AgentConfig) = LLMToolsEventSource(config, Dict{String, VoLLMSession}(), ReentrantLock())

get_channels(::LLMToolsEventSource) = Agentif.AbstractChannel[ParentAgentChannel()]
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

function _register_async_session!(
    es::LLMToolsEventSource,
    name::String,
    kind::Symbol,
    event_type::String,
    prompt::String;
    registry_id::Int = 0,
    agent::Union{Nothing, Agentif.Agent} = nothing,
    state::Union{Nothing, Agentif.AgentState} = nothing,
)
    a = get_current_assistant()
    a === nothing && error("No assistant initialized")
    _with_busy_retry() do
        SQLite.DBInterface.execute(a.db,
            "INSERT OR IGNORE INTO vo_event_types (name, description) VALUES (?, ?)",
            (event_type, "LLMTools $kind: $name"))
    end
    eh = EventHandler(event_type, [event_type], prompt, "parent")
    register_event_handler!(a, eh)
    now = time()
    session = VoLLMSession(name, kind, registry_id, agent, state, nothing, event_type, prompt, now, now, "running")
    lock(es.lock) do
        es.sessions[name] = session
    end
    @info "LLMTools async session registered" name kind registry_id event_type
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
            _with_busy_retry() do
                SQLite.DBInterface.execute(a.db, "DELETE FROM vo_event_types WHERE name = ?", (session.event_type,))
            end
        catch
        end
    end
    @info "LLMTools async session cleaned up" name kind = session.kind status = session.status
    return session
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
        """Start a new sub-agent with its own system prompt and initial message. By default runs asynchronously — returns immediately and you'll be notified when the sub-agent completes. Set run_sync=true to block and get the result directly (use when confident the task will complete quickly). The 'prompt' parameter describes what you'll receive back when notified (only used in async mode).""",
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
                    put!(a.event_queue, SubagentOutputEvent(event_type, name, output))
                catch e
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
                    put!(a.event_queue, SubagentOutputEvent(event_type, name, payload))
                end
            end
            return "Sub-agent '$name' started asynchronously. You'll be notified when it completes."
        end,
    )

    message_tool = @tool(
        """Send a follow-up message to an existing sub-agent. By default runs asynchronously — returns immediately and you'll be notified when the sub-agent responds. Set run_sync=true to block and get the result directly.""",
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
                    put!(a.event_queue, SubagentOutputEvent(event_type, name, output))
                catch e
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
                    put!(a.event_queue, SubagentOutputEvent(event_type, name, payload))
                end
            end
            return "Message sent to sub-agent '$name'. You'll be notified when it responds."
        end,
    )

    list_tool = @tool(
        "List all active sub-agent sessions with their status and age.",
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
        "Kill and remove a sub-agent session by name.",
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
        """Start a new PTY (terminal) session with a shell command. By default runs asynchronously — returns immediately and you'll be notified when output is available. Set run_sync=true to block and get the initial output directly (use for quick commands).""",
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
            full_cmd = Sys.iswindows() ? Cmd([shell_cmd, "-Command", cmd]) : Cmd([shell_cmd, "-l", "-c", cmd])

            LLMTools.ensure_cleanup_task_running!(LLMTools.PTY_REGISTRY)
            LLMTools.cleanup_exited_sessions!(LLMTools.PTY_REGISTRY)
            registry_id = LLMTools.next_session_id!(LLMTools.PTY_REGISTRY)
            pty_session = LLMTools.PtySessions.PtySession(full_cmd; dir = work_dir)
            now = time()
            meta = LLMTools.PtySessionMetadata(pty_session, now, now, cmd, work_dir, LLMTools.SESSION_STATUS_RUNNING, nothing)
            LLMTools.register_session!(LLMTools.PTY_REGISTRY, registry_id, meta)

            if sync
                sleep(0.5)
                output = try; LLMTools.PtySessions.readavailable(pty_session); catch; ""; end
                is_running = try; LLMTools.PtySessions.isactive(pty_session); catch; false; end
                if !is_running
                    sleep(0.05)
                    output *= try; LLMTools.PtySessions.readavailable(pty_session); catch; ""; end
                    LLMTools.remove_session!(LLMTools.PTY_REGISTRY, registry_id;
                        mark_status = LLMTools.SESSION_STATUS_EXITED, close_session = true)
                end
                return LLMTools.truncate_tool_output(output; label = "PTY output")
            end

            event_type = "pty:$name"
            handler_prompt = something(prompt, "")
            session = _register_async_session!(es, name, :pty, event_type, handler_prompt;
                registry_id = registry_id)
            session.task = Threads.@spawn begin
                try
                    while true
                        sleep(0.5)
                        pty_meta = LLMTools.get_session(LLMTools.PTY_REGISTRY, registry_id)
                        pty_meta === nothing && break
                        is_active = try; LLMTools.PtySessions.isactive(pty_meta.session); catch; false; end
                        output = try; LLMTools.PtySessions.readavailable(pty_meta.session); catch; ""; end
                        if !isempty(output)
                            put!(a.event_queue, PtyOutputEvent(event_type, name, output, nothing))
                        end
                        if !is_active
                            lock(es.lock) do
                                s = get(es.sessions, name, nothing)
                                s !== nothing && (s.status = "exited")
                            end
                            remaining = try; LLMTools.PtySessions.readavailable(pty_meta.session); catch; ""; end
                            if !isempty(remaining)
                                put!(a.event_queue, PtyOutputEvent(event_type, name, remaining, 0))
                            else
                                put!(a.event_queue, PtyOutputEvent(event_type, name, "", 0))
                            end
                            LLMTools.remove_session!(LLMTools.PTY_REGISTRY, registry_id;
                                mark_status = LLMTools.SESSION_STATUS_EXITED, close_session = true)
                            break
                        end
                    end
                catch e
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
                    put!(a.event_queue, PtyOutputEvent(event_type, name, payload, nothing))
                end
            end
            return "PTY '$name' started asynchronously (cmd: $cmd). You'll be notified when output is available."
        end,
    )

    write_tool = @tool(
        """Write input to an existing PTY session. By default runs asynchronously — the polling task will notify you when output is available. Set run_sync=true to block briefly and return any immediate output.""",
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
                sleep(0.5)
                output = try; LLMTools.PtySessions.readavailable(pty_meta.session); catch; ""; end
                return LLMTools.truncate_tool_output(output; label = "PTY output")
            end
            return "Input sent to PTY '$name'. You'll be notified when output is available."
        end,
    )

    list_tool = @tool(
        "List all active PTY sessions with their status, command, and age.",
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
        "Kill and remove a PTY session by name.",
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
        """Start a new Julia worker process and execute initial code. By default runs asynchronously — returns immediately and you'll be notified when execution completes. Set run_sync=true to block and get the result directly (use for quick computations).""",
        start_worker(
            name::String,
            code::String,
            prompt::Union{Nothing, String} = nothing,
            run_sync::Union{Nothing, Bool} = nothing,
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
                    combined, _ = LLMTools.eval_on_worker(worker_meta, code)
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
                    combined, _ = LLMTools.eval_on_worker(worker_meta, code)
                    lock(es.lock) do
                        s = get(es.sessions, name, nothing)
                        if s !== nothing
                            s.last_used = time()
                            s.status = "completed"
                        end
                    end
                    put!(a.event_queue, WorkerOutputEvent(event_type, name, combined))
                catch e
                    bt = catch_backtrace()
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
                    put!(a.event_queue, WorkerOutputEvent(event_type, name, payload))
                end
            end
            return "Worker '$name' started asynchronously. You'll be notified when execution completes."
        end,
    )

    eval_tool = @tool(
        """Evaluate Julia code on an existing worker process. State from previous calls persists. By default runs asynchronously — returns immediately and you'll be notified when execution completes. Set run_sync=true to block and get the result directly.""",
        eval_worker(
            name::String,
            code::String,
            run_sync::Union{Nothing, Bool} = nothing,
        ) = begin
            sync = run_sync === nothing ? false : run_sync
            session = _get_session(es, name, :worker)
            a = get_current_assistant()
            a === nothing && return "No assistant initialized"
            worker_meta = LLMTools.get_session(LLMTools.WORKER_REGISTRY, session.registry_id)
            worker_meta === nothing && error("Worker session '$name' no longer exists in registry")

            if sync
                combined, _ = LLMTools.eval_on_worker(worker_meta, code)
                lock(es.lock) do
                    session.last_used = time()
                end
                return LLMTools.truncate_tool_output(combined; label = "Worker output")
            end

            event_type = session.event_type
            lock(es.lock) do
                session.status = "running"
                session.last_used = time()
            end
            session.task = Threads.@spawn begin
                try
                    combined, _ = LLMTools.eval_on_worker(worker_meta, code)
                    lock(es.lock) do
                        s = get(es.sessions, name, nothing)
                        if s !== nothing
                            s.last_used = time()
                            s.status = "completed"
                        end
                    end
                    put!(a.event_queue, WorkerOutputEvent(event_type, name, combined))
                catch e
                    bt = catch_backtrace()
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
                    put!(a.event_queue, WorkerOutputEvent(event_type, name, payload))
                end
            end
            return "Code sent to worker '$name'. You'll be notified when execution completes."
        end,
    )

    list_tool = @tool(
        "List all active worker sessions with their status and age.",
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
        "Kill and remove a worker session by name.",
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
