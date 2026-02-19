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
    return length(s) > max_len ? s[1:max_len] * "..." : s
end

function eval_on_worker(meta::WorkerSessionMetadata, code::String)
    expr = Meta.parseall(code)
    result = remote_fetch(meta.worker, expr)
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
        "Execute Julia code in a new persistent Worker process. Returns structured JSON with the result. The worker stays alive for follow-up eval_code calls using the returned worker_id.",
        exec_code(
            code::String,
            timeout_s::Union{Nothing, Int} = nothing,
        ) = begin
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

                combined, result_str = eval_on_worker(meta, code)

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
                remove_session!(WORKER_REGISTRY, worker_id; mark_status = SESSION_STATUS_ERROR)
                errmsg = err isa CapturedException ? sprint(showerror, err.ex) : string(err)
                push!(events, make_event(WORKER_REGISTRY, "error"; session_id = worker_id,
                    payload = Dict("message" => errmsg)))
                return render_process_response("exec_code";
                    ok = false,
                    status = SESSION_STATUS_ERROR,
                    command = desc,
                    wall_time_s = time() - start_time,
                    active_sessions = active_session_count(WORKER_REGISTRY),
                    events = events,
                    error_kind = "eval_failed",
                    message = errmsg,
                )
            end
        end,
    )

    eval_code = @tool(
        "Evaluate Julia code in an existing Worker process by worker_id. State from previous eval/exec calls persists (variables, loaded packages). Returns structured JSON with the result.",
        eval_code(
            worker_id::Int,
            code::String,
            timeout_s::Union{Nothing, Int} = nothing,
        ) = begin
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

                combined, result_str = eval_on_worker(meta, code)

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
                remove_session!(WORKER_REGISTRY, worker_id; mark_status = SESSION_STATUS_ERROR)
                errmsg = err isa CapturedException ? sprint(showerror, err.ex) : string(err)
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
                    error_kind = "eval_failed",
                    message = errmsg,
                )
            end
        end,
    )

    kill_worker = @tool(
        "Terminate a Worker process by worker_id and return structured JSON status.",
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
        "List all active Worker processes with their IDs, status, and metadata.",
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
