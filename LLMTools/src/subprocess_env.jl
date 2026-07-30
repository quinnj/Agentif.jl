# subprocess_env.jl — minimal allowlisted environment for child processes (§2.4)
#
# PTY sessions, Julia workers and the codex CLI used to inherit the *whole* parent
# environment, which for an always-on assistant means every provider API key, every
# OAuth refresh token and every database password. A prompt-injected `echo
# $ANTHROPIC_API_KEY` therefore exfiltrated the key through ordinary tool output.
#
# Children now get an explicit allowlist instead: enough to run a shell (PATH, HOME,
# TERM, locale, TMPDIR) plus whatever the operator opts into. Everything else is
# dropped.

"""
Base allowlist handed to every child process. Deliberately boring: enough for a
shell and a Julia process to behave normally, nothing that carries a credential.
"""
const SUBPROCESS_ENV_ALLOWLIST = String[
    "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM", "TERM_PROGRAM",
    "TMPDIR", "TEMP", "TMP", "TZ", "LANG", "LANGUAGE", "PWD", "COLUMNS", "LINES",
]

"Prefix rules applied on top of the exact-name allowlist (locale categories)."
const SUBPROCESS_ENV_ALLOW_PREFIXES = String["LC_"]

"""
Extra names a Julia child needs to find its depot/project. Applied only to worker
processes, never to shell commands.
"""
const WORKER_ENV_ALLOWLIST = String[
    "JULIA_DEPOT_PATH", "JULIA_LOAD_PATH", "JULIA_PROJECT", "JULIA_NUM_THREADS",
    "JULIA_PKG_SERVER", "JULIA_SSL_CA_ROOTS_PATH", "JULIA_CPU_TARGET",
    "JULIA_NUM_PRECOMPILE_TASKS", "JULIA_PKG_PRECOMPILE_AUTO", "JULIA_DEBUG",
]

"Operator-configurable additions, set programmatically (see `set_subprocess_env_allowlist!`)."
const SUBPROCESS_ENV_EXTRA = Ref{Vector{String}}(String[])

"""
    set_subprocess_env_allowlist!(names) -> Vector{String}

Replace the operator-configured extra allowlist. These names are passed through to
every child process *in addition* to [`SUBPROCESS_ENV_ALLOWLIST`](@ref). Use it to
deliberately hand a subprocess something it needs (`GITHUB_TOKEN`, a proxy setting)
rather than restoring blanket inheritance.

`LLMTOOLS_ENV_ALLOWLIST` (comma-separated) does the same thing from the environment
and is read on every call, so it works without touching code.
"""
function set_subprocess_env_allowlist!(names)
    SUBPROCESS_ENV_EXTRA[] = String[String(strip(String(n))) for n in names if !isempty(strip(String(n)))]
    return SUBPROCESS_ENV_EXTRA[]
end

function _configured_env_allowlist()
    raw = get(ENV, "LLMTOOLS_ENV_ALLOWLIST", "")
    isempty(strip(raw)) && return String[]
    return String[String(strip(s)) for s in split(raw, ",") if !isempty(strip(s))]
end

function _env_name_allowed(name::AbstractString, allow::AbstractSet{String})
    String(name) in allow && return true
    for prefix in SUBPROCESS_ENV_ALLOW_PREFIXES
        startswith(name, prefix) && return true
    end
    return false
end

"""
    subprocess_env(; extra_allow = String[], overrides = Dict(), blank_denied = false)
        -> Dict{String, String}

The environment to hand a child process: the allowlist intersected with the parent
environment, plus `overrides`. Nothing outside the allowlist is inherited, so a
credential the parent holds is not reachable from a shell command the model wrote.

`blank_denied = true` additionally maps every *denied* parent variable to the empty
string. That is for callers whose spawn path **merges** rather than replaces:
`ConcurrentUtilities.Worker` builds its command with `addenv(cmd, env)`, which
inherits the full parent environment and then overlays what you passed — so handing
it an allowlist alone changes nothing. Shadowing each denied name with `""` is the
only way to blank it out without an upstream change. `setenv`-based spawns
(`PtySessions`, the codex `Cmd`) replace the environment outright and do not need it.

Caveat worth knowing: a *login* shell (`bash -l`) re-sources the user's profile,
which can re-export the very variables scrubbed here. Set
`LLMTOOLS_SUBPROCESS_LOGIN_SHELL=0` to drop `-l` if your profile exports secrets.
"""
function subprocess_env(; extra_allow = String[], overrides = Dict{String, String}(),
        blank_denied::Bool = false)
    allow = Set{String}(SUBPROCESS_ENV_ALLOWLIST)
    union!(allow, SUBPROCESS_ENV_EXTRA[])
    union!(allow, _configured_env_allowlist())
    for name in extra_allow
        push!(allow, String(name))
    end
    env = Dict{String, String}()
    for (k, v) in ENV
        if _env_name_allowed(k, allow)
            env[String(k)] = String(v)
        elseif blank_denied
            env[String(k)] = ""
        end
    end
    for (k, v) in overrides
        env[String(k)] = String(v)
    end
    return env
end

"""
    subprocess_shell_command(shell, cmd) -> Cmd

Build the shell invocation for a model-supplied command string. Login shells
(`-l`) are the historical default because they give the command the user's normal
PATH; `LLMTOOLS_SUBPROCESS_LOGIN_SHELL=0` turns that off for deployments whose
profile re-exports credentials that §2.4 is trying to withhold.
"""
function subprocess_shell_command(shell::AbstractString, cmd::AbstractString)
    Sys.iswindows() && return Cmd([String(shell), "-Command", String(cmd)])
    login = get(ENV, "LLMTOOLS_SUBPROCESS_LOGIN_SHELL", "1") != "0"
    return login ? Cmd([String(shell), "-l", "-c", String(cmd)]) : Cmd([String(shell), "-c", String(cmd)])
end
