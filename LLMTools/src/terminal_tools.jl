# terminal_tools.jl — PTY-specific terminal session tools
# Uses shared infrastructure from session_utils.jl

# --- PTY session metadata ---

mutable struct PtySessionMetadata
    session::Any  # PtySessions.PtySession
    created_at::Float64
    last_used::Float64
    command::String
    workdir::String
    status::String
    last_exit_code::Union{Nothing, Int}
end

# SessionRegistry interface implementation
function resolve_status(meta::PtySessionMetadata)
    meta.status == SESSION_STATUS_KILLED && return SESSION_STATUS_KILLED
    status = try
        PtySessions.isactive(meta.session) ? SESSION_STATUS_RUNNING : SESSION_STATUS_EXITED
    catch
        SESSION_STATUS_UNKNOWN
    end
    meta.status = status
    return status
end

function close_quietly(meta::PtySessionMetadata)
    try
        close(meta.session)
    catch
    end
    return nothing
end

session_command(meta::PtySessionMetadata) = meta.command
session_workdir(meta::PtySessionMetadata) = meta.workdir
session_created_at(meta::PtySessionMetadata) = meta.created_at
session_last_used(meta::PtySessionMetadata) = meta.last_used
set_last_used!(meta::PtySessionMetadata, t::Float64) = (meta.last_used = t)
set_status!(meta::PtySessionMetadata, s::String) = (meta.status = s)

# --- PTY registry ---

const PTY_REGISTRY = SessionRegistry{PtySessionMetadata}(
    SessionRegistryConfig(20, 15, 0.5, 1),
)

# --- Terminal tools ---

function create_terminal_tools(base_dir::AbstractString = pwd())
    base = ensure_base_dir(base_dir)
    ensure_cleanup_task_running!(PTY_REGISTRY)

    function readavailable_nonblocking(session::PtySessions.PtySession)
        session.master_fd < 0 && return ""
        return PtySessions.readavailable(session)
    end

    function readavailable_with_timeout(session::PtySessions.PtySession, timeout_s::Real)
        deadline = time() + timeout_s
        output = ""
        while time() < deadline
            output = readavailable_nonblocking(session)
            !isempty(output) && return output
            sleep(0.01)
        end
        return ""
    end

    exec_command = @tool(
        """Execute a shell command in a new PTY (pseudo-terminal) session.

Use this to run any shell command. If the command finishes within `yield_time_ms`, the session auto-closes and no `session_id` is returned. If the command is still running after `yield_time_ms`, a `session_id` IS returned — use `write_stdin` to send further input or read more output, and `kill_session` to stop it.

Arguments:
- `cmd` (String, required): The shell command to execute.
- `workdir` (String, optional): Working directory. Defaults to the agent's base directory.
- `shell` (String, optional): Shell to use. Defaults to "bash" (or "powershell" on Windows).
- `yield_time_ms` (Int, optional): How long (in ms) to wait for initial output before returning. Default: 10000 (10s). Minimum: 100.
- `max_output_lines` (Int, optional): Truncate output beyond this many lines.
- `max_output_tokens` (Int, optional): Truncate output beyond this many tokens.

Examples:
- Quick command: `exec_command(cmd="ls -la")` — finishes fast, no session_id returned.
- Long-running: `exec_command(cmd="tail -f /var/log/syslog")` — returns a session_id for follow-up via `write_stdin`.

Limits: Maximum 20 concurrent sessions. Old exited sessions are auto-cleaned. Output is truncated by both line count and token count.""",
        exec_command(
            cmd::String,
            workdir::Union{Nothing, String} = nothing,
            shell::Union{Nothing, String} = nothing,
            yield_time_ms::Union{Nothing, Int} = nothing,
            max_output_lines::Union{Nothing, Int} = nothing,
            max_output_tokens::Union{Nothing, Int} = nothing,
        ) = begin
            @debug "exec_command start" cmd workdir shell
            cleanup_exited_sessions!(PTY_REGISTRY)
            check_session_limit_and_warn(PTY_REGISTRY)

            work_dir = workdir === nothing ? base : resolve_relative_path(base, workdir)
            if !isdir(work_dir)
                return render_process_response(
                    "exec_command";
                    ok = false,
                    status = SESSION_STATUS_ERROR,
                    error_kind = "invalid_workdir",
                    message = "working directory not found: $(workdir === nothing ? "." : workdir)",
                    active_sessions = active_session_count(PTY_REGISTRY),
                )
            end

            shell_cmd = if shell !== nothing
                shell
            elseif Sys.iswindows()
                "powershell"
            else
                "bash"
            end

            yield_ms = yield_time_ms === nothing ? 10_000 : max(100, yield_time_ms)
            max_lines = max_output_lines === nothing ? DEFAULT_MAX_OUTPUT_LINES : max(10, max_output_lines)
            max_tokens = max_output_tokens === nothing ? DEFAULT_MAX_OUTPUT_TOKENS : max(16, max_output_tokens)

            full_cmd = subprocess_shell_command(shell_cmd, cmd)

            session_id = next_session_id!(PTY_REGISTRY)
            events = Dict{String, Any}[
                make_event(
                    PTY_REGISTRY,
                    "begin";
                    session_id,
                    payload = Dict("command" => cmd, "workdir" => work_dir, "yield_time_ms" => yield_ms),
                ),
            ]

            start_time = time()
            try
                # Allowlisted environment only (§2.4). Without this the shell the model
                # chose inherits every credential in the parent process.
                pty_session = PtySessions.PtySession(full_cmd; dir = work_dir, env = subprocess_env())
                now = time()
                register_session!(PTY_REGISTRY, session_id, PtySessionMetadata(
                    pty_session,
                    now,
                    now,
                    cmd,
                    work_dir,
                    SESSION_STATUS_RUNNING,
                    nothing,
                ))

                sleep(yield_ms / 1000.0)
                output = readavailable_with_timeout(pty_session, max(0.2, min(1.0, yield_ms / 1000.0)))
                is_running = try
                    PtySessions.isactive(pty_session)
                catch
                    false
                end
                if !is_running
                    sleep(0.05)
                    output *= readavailable_with_timeout(pty_session, 0.2)
                end

                if is_running
                    lock(PTY_REGISTRY.lock) do
                        meta = get(() -> nothing, PTY_REGISTRY.sessions, session_id)
                        meta === nothing || set_last_used!(meta, time())
                    end
                else
                    remove_session!(PTY_REGISTRY, session_id; mark_status = SESSION_STATUS_EXITED, close_session = true)
                end

                projection = project_output(output, max_lines, max_tokens)
                project_output_events!(PTY_REGISTRY, events, session_id, projection.raw_output)
                if !is_running
                    push!(events, make_event(PTY_REGISTRY, "end"; session_id, payload = Dict("status" => SESSION_STATUS_EXITED)))
                end

                wall_time = time() - start_time
                return render_process_response(
                    "exec_command";
                    ok = true,
                    status = is_running ? SESSION_STATUS_RUNNING : SESSION_STATUS_EXITED,
                    session_id = is_running ? session_id : nothing,
                    command = cmd,
                    workdir = work_dir,
                    wall_time_s = wall_time,
                    output_projection = projection,
                    active_sessions = active_session_count(PTY_REGISTRY),
                    events = events,
                )
            catch err
                bt = catch_backtrace()
                @warn "exec_command failed" cmd work_dir exception = (err, bt)
                remove_session!(PTY_REGISTRY, session_id; mark_status = SESSION_STATUS_ERROR, close_session = true)
                push!(events, make_event(PTY_REGISTRY, "error"; session_id, payload = Dict("message" => string(err))))
                return render_process_response(
                    "exec_command";
                    ok = false,
                    status = SESSION_STATUS_ERROR,
                    session_id = nothing,
                    command = cmd,
                    workdir = work_dir,
                    wall_time_s = time() - start_time,
                    active_sessions = active_session_count(PTY_REGISTRY),
                    events = events,
                    error_kind = "spawn_failed",
                    message = string(err),
                )
            end
        end,
    )

    write_stdin = @tool(
        """Send input to a running PTY session and read new output.

Use this to interact with a long-running process started by `exec_command`. Only works when `exec_command` returned a `session_id` (meaning the process is still running). Do NOT use this to start new commands — use `exec_command` instead.

Arguments:
- `session_id` (Int, required): The session ID returned by `exec_command`.
- `chars` (String, optional): Characters to send to the process. Include "\\n" to submit a command. Default: "" (empty — just reads pending output without sending anything).
- `yield_time_ms` (Int, optional): How long (in ms) to wait for output after writing. Default: 250. Minimum: 50.
- `max_output_lines` (Int, optional): Truncate output beyond this many lines.
- `max_output_tokens` (Int, optional): Truncate output beyond this many tokens.

Examples:
- Send a command: `write_stdin(session_id=1, chars="yes\\n")`
- Just read output: `write_stdin(session_id=1)` — sends nothing, returns any pending output.

Gotchas: If the session has exited, returns an error. The `chars` value is sent raw — you almost always want to append "\\n" to execute a line.""",
        write_stdin(
            session_id::Int,
            chars::String = "",
            yield_time_ms::Union{Nothing, Int} = nothing,
            max_output_lines::Union{Nothing, Int} = nothing,
            max_output_tokens::Union{Nothing, Int} = nothing,
        ) = begin
            @debug "write_stdin start" session_id chars_length = ncodeunits(chars)

            meta = get_session(PTY_REGISTRY, session_id)
            if meta === nothing
                return render_process_response(
                    "write_stdin";
                    ok = false,
                    status = SESSION_STATUS_UNKNOWN,
                    session_id = session_id,
                    active_sessions = active_session_count(PTY_REGISTRY),
                    error_kind = "session_not_found",
                    message = "session_id $session_id not found - it may have exited",
                )
            end

            pty_session = meta.session
            lock(PTY_REGISTRY.lock) do
                current = get(() -> nothing, PTY_REGISTRY.sessions, session_id)
                current === nothing || set_last_used!(current, time())
            end

            yield_ms = yield_time_ms === nothing ? 250 : max(50, yield_time_ms)
            max_lines = max_output_lines === nothing ? DEFAULT_MAX_OUTPUT_LINES : max(10, max_output_lines)
            max_tokens = max_output_tokens === nothing ? DEFAULT_MAX_OUTPUT_TOKENS : max(16, max_output_tokens)

            events = Dict{String, Any}[]
            if !isempty(chars)
                push!(events, make_event(PTY_REGISTRY, "stdin"; session_id, payload = Dict("chars" => chars)))
            end

            start_time = time()
            try
                if !isempty(chars)
                    write_timeout_s = max(1.0, min(5.0, yield_ms / 1000.0))
                    written = PtySessions.write_with_timeout(pty_session, chars; timeout_s = write_timeout_s)
                    if written < ncodeunits(chars)
                        push!(events, make_event(
                            PTY_REGISTRY,
                            "warning";
                            session_id,
                            payload = Dict(
                                "kind" => "partial_write",
                                "written" => written,
                                "requested" => ncodeunits(chars),
                            ),
                        ))
                    end
                    sleep(0.1)
                end

                sleep(yield_ms / 1000.0)
                output = readavailable_with_timeout(pty_session, max(1.0, min(2.0, yield_ms / 1000.0)))
                is_running = try
                    PtySessions.isactive(pty_session)
                catch
                    false
                end

                if !is_running
                    remove_session!(PTY_REGISTRY, session_id; mark_status = SESSION_STATUS_EXITED, close_session = true)
                    push!(events, make_event(PTY_REGISTRY, "end"; session_id, payload = Dict("status" => SESSION_STATUS_EXITED)))
                end

                projection = project_output(output, max_lines, max_tokens)
                project_output_events!(PTY_REGISTRY, events, session_id, projection.raw_output)

                return render_process_response(
                    "write_stdin";
                    ok = true,
                    status = is_running ? SESSION_STATUS_RUNNING : SESSION_STATUS_EXITED,
                    session_id = is_running ? session_id : nothing,
                    command = meta.command,
                    workdir = meta.workdir,
                    wall_time_s = time() - start_time,
                    output_projection = projection,
                    active_sessions = active_session_count(PTY_REGISTRY),
                    events = events,
                )
            catch err
                bt = catch_backtrace()
                @warn "write_stdin failed" session_id exception = (err, bt)
                remove_session!(PTY_REGISTRY, session_id; mark_status = SESSION_STATUS_UNKNOWN, close_session = true)
                push!(events, make_event(PTY_REGISTRY, "error"; session_id, payload = Dict("message" => string(err))))
                return render_process_response(
                    "write_stdin";
                    ok = false,
                    status = SESSION_STATUS_UNKNOWN,
                    session_id = session_id,
                    command = meta.command,
                    workdir = meta.workdir,
                    wall_time_s = time() - start_time,
                    active_sessions = active_session_count(PTY_REGISTRY),
                    events = events,
                    error_kind = "session_io_error",
                    message = string(err),
                )
            end
        end,
    )

    kill_session = @tool(
        """Terminate a running PTY session.

Use this to stop a long-running process that was started by `exec_command`. Safe to call on sessions that have already exited (returns a not-found status).

Arguments:
- `session_id` (Int, required): The session ID to terminate.

Example: `kill_session(session_id=1)`""",
        kill_session(session_id::Int) = begin
            start_time = time()
            meta = remove_session!(PTY_REGISTRY, session_id; mark_status = SESSION_STATUS_KILLED, close_session = true)
            if meta === nothing
                return render_process_response(
                    "kill_session";
                    ok = false,
                    status = SESSION_STATUS_UNKNOWN,
                    session_id = session_id,
                    wall_time_s = time() - start_time,
                    active_sessions = active_session_count(PTY_REGISTRY),
                    error_kind = "session_not_found",
                    message = "Session $session_id not found (may have already exited)",
                )
            end

            events = Dict{String, Any}[
                make_event(
                    PTY_REGISTRY,
                    "end";
                    session_id,
                    payload = Dict("status" => SESSION_STATUS_KILLED, "reason" => "kill_session"),
                ),
            ]
            return render_process_response(
                "kill_session";
                ok = true,
                status = SESSION_STATUS_KILLED,
                session_id = session_id,
                command = meta.command,
                workdir = meta.workdir,
                wall_time_s = time() - start_time,
                active_sessions = active_session_count(PTY_REGISTRY),
                events = events,
                message = "Session $session_id terminated",
            )
        end
    )

    list_sessions = @tool(
        """List all active PTY sessions with their status and metadata.

Use this to check which sessions are still running, find session IDs for `write_stdin` or `kill_session`, or diagnose session limits. Takes no arguments.

Returns for each session: session_id, status (running/exited/killed), command, workdir, age (seconds since creation), and idle time (seconds since last interaction).

Example: `list_sessions()`""",
        list_sessions() = begin
            cleanup_exited_sessions!(PTY_REGISTRY)
            sessions_snapshot = lock(PTY_REGISTRY.lock) do
                sort(collect(PTY_REGISTRY.sessions), by = first)
            end

            sessions = Dict{String, Any}[]
            now = time()
            for (id, meta) in sessions_snapshot
                status = resolve_status(meta)
                push!(sessions, Dict{String, Any}(
                    "session_id" => id,
                    "status" => status,
                    "command" => meta.command,
                    "workdir" => meta.workdir,
                    "age_s" => round(now - meta.created_at, digits = 3),
                    "idle_s" => round(now - meta.last_used, digits = 3),
                    "created_at" => meta.created_at,
                    "last_used" => meta.last_used,
                ))
            end

            summary = isempty(sessions) ? "No active PTY sessions" : "Active PTY sessions: $(length(sessions))"
            payload = Dict{String, Any}(
                "schema_version" => RESPONSE_SCHEMA_VERSION,
                "tool" => "list_sessions",
                "ok" => true,
                "status" => SESSION_STATUS_OK,
                "active_sessions" => length(sessions),
                "max_sessions" => PTY_REGISTRY.config.max_sessions,
                "warning_threshold" => PTY_REGISTRY.config.warning_threshold,
                "sessions" => sessions,
                "summary" => summary,
            )
            return JSON.json(payload)
        end
    )

    return [exec_command, write_stdin, kill_session, list_sessions]
end
