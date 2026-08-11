# Agent construction, terminal channel, one-shot evaluation, and the REPL/CLI.

default_provider() = get(ENV, "JUCO_MODEL_PROVIDER", "anthropic")
default_model() = get(ENV, "JUCO_MODEL", "claude-sonnet-4-5")
default_reasoning() = let v = get(ENV, "JUCO_REASONING", ""); isempty(v) ? nothing : v end
const DEFAULT_MAX_TURNS = 50

const PROVIDER_KEY_ENV = Dict(
    "anthropic" => "ANTHROPIC_API_KEY",
    "openai" => "OPENAI_API_KEY",
    "openrouter" => "OPENROUTER_API_KEY",
    "google" => "GEMINI_API_KEY",
    "groq" => "GROQ_API_KEY",
    "xai" => "XAI_API_KEY",
)

function resolve_apikey(provider::String)
    env_var = get(PROVIDER_KEY_ENV, provider, "")
    !isempty(env_var) && !isempty(get(ENV, env_var, "")) && return ENV[env_var]
    key = get(ENV, "JUCO_API_KEY", "")
    isempty(key) || return key
    error("No API key found: set JUCO_API_KEY$(isempty(env_var) ? "" : " or $env_var")")
end

# ─── Terminal channel: routes streamed assistant text to an IO, and gives the
# session middleware a stable branch id (= the Juco session id). ───

struct TerminalChannel <: Agentif.AbstractChannel
    session_id::String
    io::IO
end

Agentif.channel_id(ch::TerminalChannel) = ch.session_id
Agentif.start_streaming(::TerminalChannel) = nothing
Agentif.append_to_stream(ch::TerminalChannel, delta) = (print(ch.io, delta); flush(ch.io))
Agentif.finish_streaming(ch::TerminalChannel) = println(ch.io)
Agentif.send_message(ch::TerminalChannel, msg) = println(ch.io, msg)
Agentif.close_channel(::TerminalChannel) = nothing

# ─── Agent construction ───

function build_agent(;
        base_dir::AbstractString = pwd(),
        jdb::Union{Nothing, JucoDB} = nothing,
        preset::Symbol = :juco,
        provider::String = default_provider(),
        model_id::String = default_model(),
        apikey::String = "",
        memory_limit::Int = 50,
    )
    model = getModel(provider, model_id)
    model === nothing && error("Unknown model: provider=$(repr(provider)) model_id=$(repr(model_id))")
    isempty(apikey) && (apikey = resolve_apikey(provider))
    mems = (jdb !== nothing && preset === :juco) ? memories(jdb; limit = memory_limit) : String[]
    return Agentif.Agent(
        prompt = build_prompt(base_dir, preset; memories = mems),
        model = model,
        apikey = apikey,
        tools = toolset(preset, base_dir, jdb),
    )
end

# Warn the model inside tool results when the tool-call budget runs low, so it
# wraps up instead of being cut off mid-flight (SWE-agent's cost-limit pattern).
const BUDGET_WARN_MARGIN = 5

function with_budget_notice(tool::Agentif.AgentTool{F, T}, counter::Threads.Atomic{Int}, max_turns::Int) where {F, T}
    wrapped = function (args...)
        result = tool.func(args...)
        used = counter[]
        if result isa String && used >= max_turns - BUDGET_WARN_MARGIN
            remaining = max(0, max_turns - used)
            result *= "\n\n[harness: only $(remaining) tool calls remain — wrap up now: make your final change and verify]"
        end
        return result
    end
    return Agentif.AgentTool{typeof(wrapped), T}(;
        name = tool.name, description = tool.description, strict = tool.strict, func = wrapped)
end

# ─── One-shot evaluation (used by the REPL per turn, and by the eval harness) ───

"""
    Juco.evaluate(input; kw...) -> (; state, session_id, tool_calls, aborted)

Run one agent turn. Session history is persisted to (and reloaded from) the
SQLite db under `session_id`, so repeated calls with the same `session_id`
continue the conversation.
"""
function evaluate(input::AbstractString;
        base_dir::AbstractString = pwd(),
        db_path::AbstractString = DEFAULT_DB_PATH,
        jdb::JucoDB = opendb(db_path),
        session_id::Union{Nothing, AbstractString} = nothing,
        io::IO = stdout,
        show_tools::Bool = true,
        max_turns::Int = DEFAULT_MAX_TURNS,
        reasoning_effort::Union{Nothing, String} = default_reasoning(),
        on_event::Union{Nothing, Function} = nothing,
        level = nothing,
        kw...,
    )
    sid = session_id === nothing ? "juco-" * string(Agentif.UID8()) : String(session_id)
    touch_session!(jdb, sid; title = first(String(input), 80), cwd = abspath(base_dir))
    agent = build_agent(; base_dir, jdb, kw...)
    ch = TerminalChannel(sid, io)
    abort = Agentif.Abort()
    # tool executions run on concurrent tasks, so the counter must be atomic
    tool_calls = Threads.Atomic{Int}(0)
    agent = Agentif.with_tools(agent,
        Agentif.AgentTool[with_budget_notice(t, tool_calls, max_turns) for t in agent.tools])
    handler = function (event)
        if event isa Agentif.ToolExecutionStartEvent
            n = Threads.atomic_add!(tool_calls, 1) + 1
            if n > max_turns
                Agentif.abort!(abort)
            elseif show_tools
                args = replace(event.tool_call.arguments, '\n' => "\\n")
                println(io, "\e[2m[$(event.tool_call.name)] $(first(args, 160))\e[0m")
            end
        elseif event isa Agentif.AgentErrorEvent && show_tools
            println(io, "\e[31m[error] $(event.error)\e[0m")
        end
        on_event === nothing || on_event(event)
        return nothing
    end
    # OpenRouter-style models take {"reasoning": {"effort": ...}}; native OpenAI
    # reasoning models take reasoning_effort. Send the shape the model expects.
    eval_kw = if reasoning_effort === nothing
        (;)
    elseif get(agent.model.compat, "thinkingFormat", "") == "openrouter"
        (; reasoning = Dict("effort" => reasoning_effort))
    else
        (; reasoning_effort)
    end
    state = Agentif.evaluate(handler, agent, String(input);
        session_store = jdb.session_store, channel = ch, abort, level, eval_kw...)
    return (; state, session_id = sid, tool_calls = tool_calls[], aborted = Agentif.isaborted(abort))
end

# ─── REPL / CLI ───

function repl(;
        db_path::AbstractString = DEFAULT_DB_PATH,
        continue_last::Bool = false,
        kw...,
    )
    jdb = opendb(db_path)
    session_id = continue_last ? latest_session(jdb) : nothing
    continue_last && session_id === nothing && println("No previous session found; starting a new one.")
    session_id === nothing && (session_id = "juco-" * string(Agentif.UID8()))
    println("juco · session $(session_id) · db $(abspath(db_path)) · type 'exit' to quit")
    while true
        print("\e[1mjuco>\e[0m ")
        # keep=true distinguishes an empty line ("\n") from EOF ("")
        raw = try
            readline(stdin; keep = true)
        catch e
            e isa InterruptException ? "\n" : rethrow()
        end
        isempty(raw) && break  # EOF (ctrl-d)
        input = strip(raw)
        isempty(input) && continue
        input in ("exit", "quit") && break
        try
            evaluate(input; jdb, session_id, kw...)
        catch e
            e isa InterruptException || showerror(stderr, e, catch_backtrace())
            println(stderr)
        end
        println()
    end
    return nothing
end

function print_sessions(db_path::AbstractString)
    jdb = opendb(db_path)
    sessions = list_sessions(jdb)
    isempty(sessions) && return println("No sessions.")
    for s in sessions
        ts = Dates.format(Dates.unix2datetime(s.updated_at), "yyyy-mm-dd HH:MM")
        println("$(s.id)  $(ts)  $(s.cwd)  $(s.title)")
    end
end

const CLI_HELP = """
juco — a minimal Julia coding agent

Usage:
  juco [flags]              interactive session
  juco -p "prompt" [flags]  one-shot: run a single turn and exit

Flags:
  -c, --continue            resume the most recent session
  -l, --list                list sessions and exit
  -p, --prompt <text>       one-shot prompt
  --db <path>               sqlite db path (default: ~/.juco/juco.sqlite)
  --dir <path>              working directory for tools (default: pwd)
  --provider <name>         model provider (default: \$JUCO_MODEL_PROVIDER or anthropic)
  --model <id>              model id (default: \$JUCO_MODEL or claude-sonnet-4-5)
  --preset <name>           toolset preset: juco | pi | bash (default: juco)
  -h, --help                show this help
"""

function main(args::Vector{String} = ARGS)
    db_path = DEFAULT_DB_PATH
    base_dir = pwd()
    provider = default_provider()
    model_id = default_model()
    preset = :juco
    continue_last = false
    prompt = nothing
    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("-h", "--help")
            return print(CLI_HELP)
        elseif a in ("-c", "--continue")
            continue_last = true
        elseif a in ("-l", "--list")
            return print_sessions(db_path)
        elseif a in ("-p", "--prompt")
            i += 1; prompt = args[i]
        elseif a == "--db"
            i += 1; db_path = args[i]
        elseif a == "--dir"
            i += 1; base_dir = args[i]
        elseif a == "--provider"
            i += 1; provider = args[i]
        elseif a == "--model"
            i += 1; model_id = args[i]
        elseif a == "--preset"
            i += 1; preset = Symbol(args[i])
        else
            error("Unknown flag: $a (see juco --help)")
        end
        i += 1
    end
    if prompt !== nothing
        jdb = opendb(db_path)
        session_id = continue_last ? latest_session(jdb) : nothing
        evaluate(prompt; jdb, session_id, base_dir, provider, model_id, preset)
    else
        repl(; db_path, continue_last, base_dir, provider, model_id, preset)
    end
    return nothing
end
