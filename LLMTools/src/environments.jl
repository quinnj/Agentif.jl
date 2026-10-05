"""A versioned native execution resource. It describes containment, not an OS sandbox.

Credentials and live process handles must never be included in this reference.
"""
struct EnvRef
    kind::String
    id::String
    version::Int
    root::String
    capabilities::Vector{String}
end
EnvRef(root::AbstractString; id::String = "local", version::Int = 1,
    capabilities = ["read", "write", "edit", "stat", "list", "shell"]) =
    EnvRef("local", id, version, realpath(ensure_base_dir(root)), sort!(unique(String.(capabilities))))

struct LocalExecutionEnv
    ref::EnvRef
end

# A process-local guard also covers separate LocalExecutionEnv instances referring
# to the same resource. Shell and other processes can bypass this guard.
const ENV_FILE_LOCK = ReentrantLock()
const ENV_FILE_GUARDS = Dict{Tuple{String, String}, ReentrantLock}()

function _env_check(env::LocalExecutionEnv, capability::String, abort, deadline)
    capability in env.ref.capabilities || throw(ArgumentError("environment denies $capability"))
    Agentif.check_abort(abort)
    time() <= deadline || throw(Agentif.AbortEvaluation())
    isdir(env.ref.root) && realpath(env.ref.root) == env.ref.root || error("recorded environment root is unavailable")
end

function env_read(env::LocalExecutionEnv, path::String; offset = nothing, limit = nothing,
        abort = Agentif.Abort(), deadline = Inf)
    _env_check(env, "read", abort, deadline)
    tool=create_read_tool(env.ref.root)
    return Agentif.invoke_parsed_tool(tool, convert(Agentif.parameters(tool), (; path, offset, limit)))
end

function _env_mutate(f, env, path, abort, deadline)
    resolved = resolve_relative_path(env.ref.root, path)
    guard = lock(ENV_FILE_LOCK) do
        get!(ENV_FILE_GUARDS, (env.ref.root, resolved), ReentrantLock())
    end
    lock(guard) do
        Agentif.check_abort(abort)
        time() <= deadline || throw(Agentif.AbortEvaluation())
        f()
    end
end

function env_write(env::LocalExecutionEnv, path::String, content::String;
        abort = Agentif.Abort(), deadline = Inf)
    _env_check(env, "write", abort, deadline)
    return _env_mutate(env, path, abort, deadline) do
        Agentif.invoke_parsed_tool(create_write_tool(env.ref.root), (; path, content))
    end
end

function env_edit(env::LocalExecutionEnv, path::String, oldText::String, newText::String;
        abort = Agentif.Abort(), deadline = Inf)
    _env_check(env, "edit", abort, deadline)
    return _env_mutate(env, path, abort, deadline) do
        Agentif.invoke_parsed_tool(create_edit_tool(env.ref.root), (; path, oldText, newText))
    end
end

function env_stat(env::LocalExecutionEnv, path::String; abort = Agentif.Abort(), deadline = Inf)
    _env_check(env, "stat", abort, deadline)
    s = stat(resolve_relative_path(env.ref.root, path))
    return (; size = s.size, mtime = s.mtime, mode = s.mode)
end

function env_list(env::LocalExecutionEnv, path::String = "."; abort = Agentif.Abort(), deadline = Inf)
    _env_check(env, "list", abort, deadline)
    return readdir(resolve_relative_path(env.ref.root, path))
end

"""Run native shell with scrubbed environment, bounded output, and cancellation.

The shell can access paths outside cwd. This interface provides no OS isolation.
"""
function env_shell(env::LocalExecutionEnv, command::String; abort = Agentif.Abort(),
        deadline = time() + 60, max_bytes::Int = DEFAULT_MAX_BYTES)
    _env_check(env, "shell", abort, deadline)
    max_bytes>0 || throw(ArgumentError("max_bytes must be positive"))
    mktemp() do path, output
        cmd = setenv(Cmd(Cmd(["/bin/sh", "-c", command]); dir = env.ref.root), subprocess_env())
        proc = run(pipeline(cmd; stdout = output, stderr = output); wait = false)
        try
            while process_running(proc)
                if Agentif.isaborted(abort) || time() > deadline || filesize(path) > max_bytes
                    kill(proc)
                    wait(proc)
                    Agentif.isaborted(abort) && throw(Agentif.AbortEvaluation())
                    break
                end
                sleep(0.02)
            end
            wait(proc)
            flush(output)
            seekstart(output)
            text = repair_utf8(String(Base.read(output, min(filesize(path), max_bytes))))
            return (; output = text, exitcode = proc.exitcode, truncated = filesize(path) > max_bytes)
        finally
            process_running(proc) && kill(proc)
        end
    end
end
