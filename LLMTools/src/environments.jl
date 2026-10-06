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
EnvRef(
    root::AbstractString; id::String = "local", version::Int = 1,
    capabilities = ["read", "write", "edit", "shell"]
) =
    EnvRef("local", id, version, realpath(ensure_base_dir(root)), sort!(unique(String.(capabilities))))

struct LocalExecutionEnv
    ref::EnvRef
end

# Process-local guards serialize mutations of the same file across every
# LocalExecutionEnv. They are keyed by the canonical (symlink-resolved,
# case-folded) path, striped over a fixed set so they never accumulate. Shell
# commands and other processes bypass them.
const ENV_FILE_GUARDS = [ReentrantLock() for _ in 1:64]

function _env_check(env::LocalExecutionEnv, capability::String, abort, deadline)
    capability in env.ref.capabilities || throw(ArgumentError("environment denies $capability"))
    Agentif.check_abort(abort)
    time() <= deadline || throw(Agentif.AbortEvaluation())
    return isdir(env.ref.root) && realpath(env.ref.root) == env.ref.root || error("recorded environment root is unavailable")
end

function env_read(
        env::LocalExecutionEnv, path::String; offset = nothing, limit = nothing,
        abort = Agentif.Abort(), deadline = Inf
    )
    _env_check(env, "read", abort, deadline)
    tool = create_read_tool(env.ref.root)
    return Agentif.invoke_parsed_tool(tool, convert(Agentif.parameters(tool), (; path, offset, limit)))
end

function _env_mutate(f, env, path, abort, deadline)
    resolved = canonical_path(resolve_relative_path(env.ref.root, path))
    guard = ENV_FILE_GUARDS[mod1(hash(lowercase(resolved)), length(ENV_FILE_GUARDS))]
    return lock(guard) do
        Agentif.check_abort(abort)
        time() <= deadline || throw(Agentif.AbortEvaluation())
        f()
    end
end

function env_write(
        env::LocalExecutionEnv, path::String, content::String;
        abort = Agentif.Abort(), deadline = Inf
    )
    _env_check(env, "write", abort, deadline)
    return _env_mutate(env, path, abort, deadline) do
        Agentif.invoke_parsed_tool(create_write_tool(env.ref.root), (; path, content))
    end
end

function env_edit(
        env::LocalExecutionEnv, path::String, oldText::String, newText::String;
        abort = Agentif.Abort(), deadline = Inf
    )
    _env_check(env, "edit", abort, deadline)
    return _env_mutate(env, path, abort, deadline) do
        Agentif.invoke_parsed_tool(create_edit_tool(env.ref.root), (; path, oldText, newText))
    end
end
