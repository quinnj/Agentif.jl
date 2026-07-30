# worker_tools.jl — Julia Worker tools backed by ConcurrentUtilities.Workers
# Uses shared infrastructure from session_utils.jl

# --- Worker session metadata ---

mutable struct WorkerSessionMetadata
    worker::Any  # Workers.Worker
    output_io::IOBuffer
    created_at::Float64
    last_used::Float64
    description::String
    status::String
end

# SessionRegistry interface implementation
function resolve_status(meta::WorkerSessionMetadata)
    meta.status == SESSION_STATUS_KILLED && return SESSION_STATUS_KILLED
    try
        Workers.terminated(meta.worker) ? SESSION_STATUS_EXITED : SESSION_STATUS_RUNNING
    catch
        SESSION_STATUS_UNKNOWN
    end
end

function close_quietly(meta::WorkerSessionMetadata)
    try
        close(meta.worker)
    catch
    end
    return nothing
end

session_command(meta::WorkerSessionMetadata) = meta.description
session_workdir(meta::WorkerSessionMetadata) = ""
session_created_at(meta::WorkerSessionMetadata) = meta.created_at
session_last_used(meta::WorkerSessionMetadata) = meta.last_used
set_last_used!(meta::WorkerSessionMetadata, t::Float64) = (meta.last_used = t)
set_status!(meta::WorkerSessionMetadata, s::String) = (meta.status = s)

# --- Worker registry ---

const WORKER_REGISTRY = SessionRegistry{WorkerSessionMetadata}(
    SessionRegistryConfig(10, 8, 1.0, 1),
)

# --- Helpers ---

function _worker_env()
    env = Dict{String, String}(k => v for (k, v) in ENV)
    # Ensure @stdlib is in the load path (Pkg.test() sandboxes may omit it)
    sep = Sys.iswindows() ? ";" : ":"
    lp = get(env, "JULIA_LOAD_PATH", "")
    if !isempty(lp) && !occursin("@stdlib", lp)
        env["JULIA_LOAD_PATH"] = lp * sep * "@stdlib"
    end
    # Ensure the worker inherits the active project, not a stale JULIA_PROJECT
    # from the OS environment (e.g. JULIA_PROJECT=. in .zshrc). The Worker
    # constructor only sets JULIA_PROJECT when the env key is absent, so an
    # inherited "." would point the worker at the wrong project.
    project = Base.ACTIVE_PROJECT[]
    if project !== nothing
        env["JULIA_PROJECT"] = project
    end
    return env
end

function truncate_description(code::String, max_len::Int = 80)
    s = replace(strip(code), r"\s+" => " ")
    # first() is char-safe; s[1:max_len] is byte indexing and throws on
    # multi-byte code content
    return length(s) > max_len ? first(s, max_len) * "..." : s
end

"""
    WorkerEvalTimeout

Thrown by [`eval_on_worker`](@ref) when an evaluation exceeds its `timeout_s`
deadline. The wedged worker process is force-terminated before this is thrown.
"""
struct WorkerEvalTimeout <: Exception
    timeout_s::Int
end

function Base.showerror(io::IO, e::WorkerEvalTimeout)
    print(io, "worker evaluation timed out after $(e.timeout_s)s; the worker process was terminated")
end

function eval_on_worker(meta::WorkerSessionMetadata, code::String; timeout_s::Union{Nothing, Int} = nothing)
    expr = Meta.parseall(code)
    result = if timeout_s === nothing
        remote_fetch(meta.worker, expr)
    else
        fut = remote_eval(meta.worker, expr)
        # fut.value is ready on success and closed (with the remote exception or
        # a WorkerTerminatedException) on failure; poll until one or the deadline.
        status = timedwait(() -> isready(fut.value) || !isopen(fut.value), Float64(max(timeout_s, 0)))
        if status === :timed_out
            # A wedged worker (e.g. `while true end`) never processes a graceful
            # shutdown request, so force-terminate the process.
            try
                Workers.terminate!(meta.worker, :eval_timeout)
            catch
            end
            throw(WorkerEvalTimeout(timeout_s))
        end
        fetch(fut)
    end
    # Small yield to let any worker stdout flush through the redirect task
    yield()
    # Read captured stdout (non-destructive peek then take)
    stdout_output = String(take!(meta.output_io))
    result_str = result === nothing ? "" : sprint(show, result)
    combined = if isempty(stdout_output) && isempty(result_str)
        "(no output)"
    elseif isempty(stdout_output)
        result_str
    elseif isempty(result_str) || result_str == "nothing"
        stdout_output
    else
        stdout_output * "\n" * result_str
    end
    return combined, result_str
end

# --- Worker tools ---

function create_worker_tools()
    ensure_cleanup_task_running!(WORKER_REGISTRY)

    exec_code = @tool(
        """Launch a NEW Julia worker process and evaluate code in it.
Use this to start a fresh execution environment. The worker process persists after this call — use the returned `worker_id` with `eval_code` for follow-up evaluations in the same process.
Do NOT call this for follow-up work on an existing worker; use `eval_code` instead.

Arguments:
- `code::String` — Julia code to evaluate. All expressions are executed; stdout and the return value of the last expression are captured.
- `timeout_s::Union{Nothing, Int}` (default: nothing) — Optional timeout in seconds. `nothing` means no timeout. On timeout the worker process is terminated and a structured error with `error_kind: "timeout"` is returned.

Behavior:
- Spawns a new Julia process (~1-2s startup latency). The worker inherits the parent's active Julia project/environment.
- All state (variables, loaded packages, module definitions) persists in the worker for subsequent `eval_code` calls.
- Output combines captured stdout with the string representation of the last expression's return value.
- Max 10 concurrent workers. Old exited workers are auto-cleaned, but prefer `kill_worker` to free resources explicitly.

Examples:
- `exec_code("x = 42; println(x)")` → creates worker, prints "42", returns worker_id for reuse.
- `exec_code("using Statistics; mean([1,2,3])")` → loads Statistics (persists), returns 2.0.

Returns structured JSON with `ok`, `status`, `session_id` (the worker_id), `output`, and `result`.""",
        exec_code(
            code::String,
            timeout_s::Union{Nothing, Int} = nothing,
        ) = begin
            @debug "exec_code start" code_preview = truncate_description(code)
            cleanup_exited_sessions!(WORKER_REGISTRY)
            check_session_limit_and_warn(WORKER_REGISTRY)

            worker_id = next_session_id!(WORKER_REGISTRY)
            desc = truncate_description(code)
            events = Dict{String, Any}[
                make_event(WORKER_REGISTRY, "begin"; session_id = worker_id,
                    payload = Dict("code" => code)),
            ]

            start_time = time()
            try
                output_io = IOBuffer()
                w = Worker(;
                    env = _worker_env(),
                    worker_redirect_io = output_io,
                    worker_redirect_fn = (io, pid, line) -> println(io, line),
                )
                now = time()
                meta = WorkerSessionMetadata(w, output_io, now, now, desc, SESSION_STATUS_RUNNING)
                register_session!(WORKER_REGISTRY, worker_id, meta)

                combined, result_str = eval_on_worker(meta, code; timeout_s = timeout_s)

                is_alive = !Workers.terminated(w)
                if !is_alive
                    remove_session!(WORKER_REGISTRY, worker_id; mark_status = SESSION_STATUS_EXITED)
                else
                    lock(WORKER_REGISTRY.lock) do
                        m = get(() -> nothing, WORKER_REGISTRY.sessions, worker_id)
                        m === nothing || set_last_used!(m, time())
                    end
                end

                projection = project_output(combined, DEFAULT_MAX_OUTPUT_LINES, DEFAULT_MAX_OUTPUT_TOKENS)
                project_output_events!(WORKER_REGISTRY, events, worker_id, projection.raw_output)
                if !is_alive
                    push!(events, make_event(WORKER_REGISTRY, "end"; session_id = worker_id,
                        payload = Dict("status" => SESSION_STATUS_EXITED)))
                end

                return render_process_response("exec_code";
                    ok = true,
                    status = is_alive ? SESSION_STATUS_RUNNING : SESSION_STATUS_EXITED,
                    session_id = is_alive ? worker_id : nothing,
                    command = desc,
                    wall_time_s = time() - start_time,
                    output_projection = projection,
                    active_sessions = active_session_count(WORKER_REGISTRY),
                    events = events,
                    extra = Dict{String, Any}("result" => result_str),
                )
            catch err
                bt = catch_backtrace()
                @warn "exec_code failed" worker_id exception = (err, bt)
                remove_session!(WORKER_REGISTRY, worker_id; mark_status = SESSION_STATUS_ERROR)
                errmsg = err isa CapturedException ? sprint(showerror, err.ex) :
                    err isa WorkerEvalTimeout ? sprint(showerror, err) : string(err)
                push!(events, make_event(WORKER_REGISTRY, "error"; session_id = worker_id,
                    payload = Dict("message" => errmsg)))
                return render_process_response("exec_code";
                    ok = false,
                    status = SESSION_STATUS_ERROR,
                    command = desc,
                    wall_time_s = time() - start_time,
                    active_sessions = active_session_count(WORKER_REGISTRY),
                    events = events,
                    error_kind = err isa WorkerEvalTimeout ? "timeout" : "eval_failed",
                    message = errmsg,
                )
            end
        end,
    )

    eval_code = @tool(
        """Evaluate Julia code in an EXISTING worker process.
Use this for follow-up evaluations on a worker previously created by `exec_code`. All state from prior calls (variables, loaded packages, module definitions) persists.
Do NOT use this to start a new worker — use `exec_code` instead.

Arguments:
- `worker_id::Int` — ID of an existing worker, as returned by `exec_code` in the `session_id` field.
- `code::String` — Julia code to evaluate. All expressions are executed; stdout and the return value of the last expression are captured.
- `timeout_s::Union{Nothing, Int}` (default: nothing) — Optional timeout in seconds. `nothing` means no timeout. On timeout the worker process is terminated (all its state is lost) and a structured error with `error_kind: "timeout"` is returned.

Gotchas:
- Returns an error if the worker_id does not exist or the worker has exited. Use `list_workers` to check.
- If the worker exits during evaluation (e.g. `exit()`), it is removed from the registry automatically.

Examples:
- After `exec_code("x = 10")` returns worker_id=1: `eval_code(1, "x + 5")` → returns 15.
- `eval_code(1, "push!(results, new_data); length(results)")` → mutates and queries persistent state.

Returns structured JSON with `ok`, `status`, `session_id`, `output`, and `result`.""",
        eval_code(
            worker_id::Int,
            code::String,
            timeout_s::Union{Nothing, Int} = nothing,
        ) = begin
            @debug "eval_code start" worker_id code_preview = truncate_description(code)
            meta = get_session(WORKER_REGISTRY, worker_id)
            if meta === nothing
                return render_process_response("eval_code";
                    ok = false,
                    status = SESSION_STATUS_UNKNOWN,
                    session_id = worker_id,
                    active_sessions = active_session_count(WORKER_REGISTRY),
                    error_kind = "session_not_found",
                    message = "worker_id $worker_id not found - it may have exited",
                )
            end

            desc = truncate_description(code)
            events = Dict{String, Any}[
                make_event(WORKER_REGISTRY, "begin"; session_id = worker_id,
                    payload = Dict("code" => code)),
            ]

            start_time = time()
            try
                lock(WORKER_REGISTRY.lock) do
                    current = get(() -> nothing, WORKER_REGISTRY.sessions, worker_id)
                    current === nothing || set_last_used!(current, time())
                end

                combined, result_str = eval_on_worker(meta, code; timeout_s = timeout_s)

                is_alive = !Workers.terminated(meta.worker)
                if !is_alive
                    remove_session!(WORKER_REGISTRY, worker_id; mark_status = SESSION_STATUS_EXITED)
                    push!(events, make_event(WORKER_REGISTRY, "end"; session_id = worker_id,
                        payload = Dict("status" => SESSION_STATUS_EXITED)))
                end

                projection = project_output(combined, DEFAULT_MAX_OUTPUT_LINES, DEFAULT_MAX_OUTPUT_TOKENS)
                project_output_events!(WORKER_REGISTRY, events, worker_id, projection.raw_output)

                return render_process_response("eval_code";
                    ok = true,
                    status = is_alive ? SESSION_STATUS_RUNNING : SESSION_STATUS_EXITED,
                    session_id = is_alive ? worker_id : nothing,
                    command = desc,
                    wall_time_s = time() - start_time,
                    output_projection = projection,
                    active_sessions = active_session_count(WORKER_REGISTRY),
                    events = events,
                    extra = Dict{String, Any}("result" => result_str),
                )
            catch err
                bt = catch_backtrace()
                @warn "eval_code failed" worker_id exception = (err, bt)
                remove_session!(WORKER_REGISTRY, worker_id; mark_status = SESSION_STATUS_ERROR)
                errmsg = err isa CapturedException ? sprint(showerror, err.ex) :
                    err isa WorkerEvalTimeout ? sprint(showerror, err) : string(err)
                push!(events, make_event(WORKER_REGISTRY, "error"; session_id = worker_id,
                    payload = Dict("message" => errmsg)))
                return render_process_response("eval_code";
                    ok = false,
                    status = SESSION_STATUS_ERROR,
                    session_id = worker_id,
                    command = desc,
                    wall_time_s = time() - start_time,
                    active_sessions = active_session_count(WORKER_REGISTRY),
                    events = events,
                    error_kind = err isa WorkerEvalTimeout ? "timeout" : "eval_failed",
                    message = errmsg,
                )
            end
        end,
    )

    kill_worker = @tool(
        """Terminate a worker process and free its resources.
Use this to explicitly shut down a worker you no longer need. Prefer this over letting workers idle, especially when approaching the 10-worker limit.

Arguments:
- `worker_id::Int` — ID of the worker to terminate, as returned by `exec_code`.

Behavior:
- Immediately kills the worker process. All in-process state is lost.
- Returns an error if the worker_id is not found (it may have already exited).
- Idempotent in effect: calling on an already-exited worker simply returns a not-found error.

Returns structured JSON with `ok`, `status`, and confirmation message.""",
        kill_worker(worker_id::Int) = begin
            start_time = time()
            meta = remove_session!(WORKER_REGISTRY, worker_id; mark_status = SESSION_STATUS_KILLED, close_session = true)
            if meta === nothing
                return render_process_response("kill_worker";
                    ok = false,
                    status = SESSION_STATUS_UNKNOWN,
                    session_id = worker_id,
                    wall_time_s = time() - start_time,
                    active_sessions = active_session_count(WORKER_REGISTRY),
                    error_kind = "session_not_found",
                    message = "Worker $worker_id not found (may have already exited)",
                )
            end

            events = Dict{String, Any}[
                make_event(WORKER_REGISTRY, "end"; session_id = worker_id,
                    payload = Dict("status" => SESSION_STATUS_KILLED, "reason" => "kill_worker")),
            ]
            return render_process_response("kill_worker";
                ok = true,
                status = SESSION_STATUS_KILLED,
                session_id = worker_id,
                command = meta.description,
                wall_time_s = time() - start_time,
                active_sessions = active_session_count(WORKER_REGISTRY),
                events = events,
                message = "Worker $worker_id terminated",
            )
        end
    )

    list_workers = @tool(
        """List all active worker processes and their current state.
Use this to discover available worker_ids, check worker status, or diagnose capacity issues before creating new workers.

Arguments: none.

Returns structured JSON with:
- `active_workers` — count of live workers.
- `max_workers` — the 10-worker concurrency limit.
- `workers` — array of objects, each with `worker_id`, `status` ("running"/"exited"/"killed"), `description` (truncated initial code), `age_s`, and `idle_s`.

Automatically cleans up exited workers before reporting.""",
        list_workers() = begin
            cleanup_exited_sessions!(WORKER_REGISTRY)
            sessions_snapshot = lock(WORKER_REGISTRY.lock) do
                sort(collect(WORKER_REGISTRY.sessions), by = first)
            end

            workers = Dict{String, Any}[]
            now = time()
            for (id, meta) in sessions_snapshot
                status = resolve_status(meta)
                push!(workers, Dict{String, Any}(
                    "worker_id" => id,
                    "status" => status,
                    "description" => meta.description,
                    "age_s" => round(now - meta.created_at, digits = 3),
                    "idle_s" => round(now - meta.last_used, digits = 3),
                    "created_at" => meta.created_at,
                    "last_used" => meta.last_used,
                ))
            end

            summary = isempty(workers) ? "No active workers" : "Active workers: $(length(workers))"
            payload = Dict{String, Any}(
                "schema_version" => RESPONSE_SCHEMA_VERSION,
                "tool" => "list_workers",
                "ok" => true,
                "status" => SESSION_STATUS_OK,
                "active_workers" => length(workers),
                "max_workers" => WORKER_REGISTRY.config.max_sessions,
                "workers" => workers,
                "summary" => summary,
            )
            return JSON.json(payload)
        end
    )

    return [exec_code, eval_code, kill_worker, list_workers]
end
