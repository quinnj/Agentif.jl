# Agent construction, terminal channel, one-shot evaluation, and the REPL/CLI.

default_provider() = get(ENV, "JUCO_MODEL_PROVIDER", "anthropic")
default_model() = get(ENV, "JUCO_MODEL", "claude-sonnet-4-5")
default_reasoning() = let v = get(ENV, "JUCO_REASONING", ""); isempty(v) ? nothing : v end
const DEFAULT_MAX_TURNS = 50

# OpenRouter routing preferences. Sorting by price keeps routing stable so
# upstream prompt caches stay warm across a session's turns (round-robin
# routing defeats them) — but with a quality floor: endpoints must support all
# request parameters (tools!) and fp4-class quantizations are excluded, since
# an fp4 endpoint was observed emitting raw tool-call markup as text.
# JUCO_OPENROUTER_ORDER pins specific endpoint tags, comma-separated.
function openrouter_provider_prefs()
    order = get(ENV, "JUCO_OPENROUTER_ORDER", "")
    isempty(order) || return Dict{String, Any}("order" => strip.(split(order, ",")), "allow_fallbacks" => true)
    return Dict{String, Any}(
        "sort" => "price",
        "require_parameters" => true,
        "quantizations" => ["fp8", "int8", "fp16", "bf16", "unknown"],
    )
end

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

# ─── Terminal channel: collects streamed assistant text and gives the session
# middleware a stable branch id (= the Juco session id). Text is buffered per
# assistant message and rendered as Markdown when the message completes — tool
# activity and reasoning stream live in between (see display.jl), so the
# terminal stays responsive while answers come out cleanly formatted. ───

struct TerminalChannel <: Agentif.AbstractChannel
    session_id::String
    io::IO
    buf::IOBuffer
    markdown::Bool
    io_lock::ReentrantLock
end

TerminalChannel(session_id::String, io::IO; markdown::Bool = true,
        io_lock::ReentrantLock = ReentrantLock()) =
    TerminalChannel(session_id, io, IOBuffer(), markdown, io_lock)

Agentif.channel_id(ch::TerminalChannel) = ch.session_id
Agentif.start_streaming(::TerminalChannel) = nothing
Agentif.append_to_stream(ch::TerminalChannel, delta) = lock(ch.io_lock) do
    write(ch.buf, delta)
end

function render_text(ch::TerminalChannel)
    lock(ch.io_lock) do
        text = strip(String(take!(ch.buf)))
        isempty(text) && return
        if ch.markdown && use_color(ch.io)
            try
                show(IOContext(ch.io, :color => true), MIME("text/plain"), Markdown.parse(String(text)))
                println(ch.io)
            catch
                println(ch.io, text)
            end
        else
            println(ch.io, text)
        end
        flush(ch.io)
    end
    return
end

Agentif.finish_streaming(ch::TerminalChannel) = render_text(ch)
Agentif.send_message(ch::TerminalChannel, msg) = lock(ch.io_lock) do
    println(ch.io, msg)
end
Agentif.close_channel(ch::TerminalChannel) = render_text(ch)  # flush any tail text

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

# Tool instrumentation: appended to each tool result as needed —
#   - budget notice: warn the model when the tool-call budget runs low, so it
#     wraps up instead of being cut off mid-flight (SWE-agent's pattern)
#   - steering: user messages typed while the model works are delivered with
#     the next completed tool result (`on_steer` fires at delivery, so the UI
#     can show exactly when a queued message became active)
const BUDGET_WARN_MARGIN = 5

function instrument_tool(tool::Agentif.AgentTool{F, T}, counter::Threads.Atomic{Int}, max_turns::Int,
        steer::Union{Nothing, Channel{String}}, on_steer::Union{Nothing, Function},
        steer_lock::ReentrantLock = ReentrantLock()) where {F, T}
    wrapped = function (args...)
        result = tool.func(args...)
        result isa String || return result
        if steer !== nothing
            texts = drain_steering!(steer, steer_lock)
            if !isempty(texts)
                on_steer === nothing || foreach(on_steer, texts)
                result *= "\n\n[the user interjected with new instructions — take them into account now]:\n" *
                    join(texts, "\n")
            end
        end
        used = counter[]
        if used >= max_turns - BUDGET_WARN_MARGIN
            remaining = max(0, max_turns - used)
            result *= "\n\n[harness: only $(remaining) tool calls remain — wrap up now: make your final change and verify]"
        end
        return result
    end
    return Agentif.AgentTool{typeof(wrapped), T}(;
        name = tool.name, description = tool.description, strict = tool.strict, func = wrapped)
end

function drain_steering!(steer::Channel{String}, steer_lock::ReentrantLock)
    return lock(steer_lock) do
        texts = String[]
        while isready(steer)
            push!(texts, take!(steer))
        end
        texts
    end
end

# kept for API/tests compatibility: budget-only instrumentation
with_budget_notice(tool::Agentif.AgentTool, counter::Threads.Atomic{Int}, max_turns::Int) =
    instrument_tool(tool, counter, max_turns, nothing, nothing)

# ─── One-shot evaluation (used by the REPL per turn, and by the eval harness) ───

"""
    Juco.evaluate(input; kw...) -> (; state, session_id, tool_calls, aborted)

Run one agent turn. Session history is persisted to (and reloaded from) the
SQLite db under `session_id`, so repeated calls with the same `session_id`
continue the conversation.
"""
function evaluate(input::AbstractString;
        db_path::AbstractString = DEFAULT_DB_PATH,
        jdb::Union{Nothing, JucoDB} = nothing,
        kw...,
    )
    jdb === nothing && return with_jdb(db_path) do owned_jdb
        _evaluate(input; jdb = owned_jdb, kw...)
    end
    return _evaluate(input; jdb, kw...)
end

function _evaluate(input::AbstractString;
        base_dir::AbstractString = pwd(),
        jdb::JucoDB,
        session_id::Union{Nothing, AbstractString} = nothing,
        io::IO = stdout,
        show_tools::Bool = true,
        show_reasoning::Bool = true,
        show_usage::Bool = false,
        max_turns::Int = DEFAULT_MAX_TURNS,
        reasoning_effort::Union{Nothing, String} = default_reasoning(),
        on_event::Union{Nothing, Function} = nothing,
        abort::Agentif.Abort = Agentif.Abort(),
        steer::Union{Nothing, Channel{String}} = nothing,
        on_steer::Union{Nothing, Function} = nothing,
        io_lock::ReentrantLock = ReentrantLock(),
        level = nothing,
        kw...,
    )
    sid = session_id === nothing ? "juco-" * string(Agentif.UID8()) : String(session_id)
    agent = build_agent(; base_dir, jdb, kw...)
    ch = TerminalChannel(sid, io; io_lock)
    # tool executions run on concurrent tasks, so the counter must be atomic
    tool_calls = Threads.Atomic{Int}(0)
    steer_lock = ReentrantLock()
    agent = Agentif.with_tools(agent,
        Agentif.AgentTool[instrument_tool(t, tool_calls, max_turns, steer, on_steer, steer_lock) for t in agent.tools])
    disp = show_tools ? display_handler(io; show_reasoning, io_lock) : nothing
    handler = function (event)
        if event isa Agentif.ToolExecutionStartEvent
            n = Threads.atomic_add!(tool_calls, 1) + 1
            n > max_turns && Agentif.abort!(abort)
        end
        disp === nothing || disp(event)
        on_event === nothing || on_event(event)
        return nothing
    end
    # Reasoning config shape differs per API: OpenRouter-style models take
    # {"reasoning": {"effort": ...}}, codex takes a plain reasoning string, and
    # native OpenAI reasoning models take reasoning_effort.
    is_openrouter = get(agent.model.compat, "thinkingFormat", "") == "openrouter"
    eval_kw = if reasoning_effort === nothing
        (;)
    elseif is_openrouter
        (; reasoning = Dict("effort" => reasoning_effort))
    elseif agent.model.api == "openai-codex"
        (; reasoning = reasoning_effort)
    else
        (; reasoning_effort)
    end
    is_openrouter && (eval_kw = merge(eval_kw, (; provider = openrouter_provider_prefs())))
    t0 = time()
    state = Agentif.evaluate(handler, agent, String(input);
        session_store = jdb.session_store, channel = ch, abort, level, eval_kw...)
    touch_session!(jdb, sid; title = first(String(input), 80), cwd = abspath(base_dir))
    if show_usage
        ctx_pct = context_percent(agent, state)
        lock(io_lock) do
            println(io, dim(io, usage_line(state.usage, agent.model, tool_calls[], time() - t0; ctx_pct)))
        end
    end
    return (; state, session_id = sid, tool_calls = tool_calls[], aborted = Agentif.isaborted(abort))
end

# Estimated share of the model's context window occupied by the conversation.
function context_percent(agent::Agentif.Agent, state::Agentif.AgentState)
    cw = agent.model.contextWindow
    cw > 0 || return nothing
    est = Agentif.estimate_context_tokens(state.messages) + cld(ncodeunits(agent.prompt), 4)
    return clamp(round(Int, 100 * est / cw), 0, 100)
end

# ─── REPL / CLI ───

const REPL_HELP = """
/help                 show this help
/new                  start a new session
/sessions             list recent sessions
/resume [id]          pick a past session to resume (menu when no id)
/model [mode] [id]    choose model mode, model, and reasoning (menus when no args)
/skills               list \$skills discovered from ~/.agent/skills and ./.agent/skills
/memories             list saved memories
/quit                 exit (also: exit, quit, ctrl-d)
Use \$skill-name in a prompt to inject a skill (tab-completes in juco> mode).
Typing while the model works queues a steering message for the next tool boundary.
End a line with \\ to continue typing on the next line.
Ctrl-C during a response interrupts that response, not the REPL."""

# Mutable REPL state threaded through slash commands. Model selection is
# persistent (sqlite config); skills are re-discovered each launch.
mutable struct ReplState
    jdb::JucoDB
    session_id::String
    mode::String
    model_id::String
    reasoning::Union{Nothing, String}
    skills::Vector{Skill}
    base_dir::String
    quit::Bool
end

function ReplState(jdb::JucoDB, session_id::String; base_dir::AbstractString = pwd())
    mode, model_id, reasoning = load_model_state(jdb)
    return ReplState(jdb, session_id, mode, model_id, reasoning,
        discover_skills(base_dir), String(abspath(base_dir)), false)
end

model_label(st::ReplState) =
    "$(st.mode) · $(st.model_id)" * (st.reasoning === nothing ? "" : " · $(st.reasoning)")

function handle_command(st::ReplState, input::AbstractString, io::IO)
    parts = split(strip(input))
    cmd = parts[1]
    if cmd == "/help"
        println(io, REPL_HELP)
    elseif cmd == "/new"
        st.session_id = "juco-" * string(Agentif.UID8())
        println(io, dim(io, "new session $(st.session_id)"))
    elseif cmd == "/sessions"
        sessions = list_sessions(st.jdb)
        isempty(sessions) && return println(io, "No sessions.")
        for s in sessions
            ts = Dates.format(Dates.unix2datetime(s.updated_at), "yyyy-mm-dd HH:MM")
            marker = s.id == st.session_id ? "* " : "  "
            println(io, marker, s.id, dim(io, "  $(ts)  $(first(s.title, 60))"))
        end
    elseif cmd == "/resume"
        if length(parts) >= 2
            st.session_id = String(parts[2])
            println(io, dim(io, "resumed $(st.session_id)"))
        else
            resume_menu!(st, io)
        end
    elseif cmd == "/model"
        if length(parts) == 1
            model_menu!(st, io)
        else
            length(parts) <= 3 || return println(io, red(io,
                "usage: /model [mode] [model-id]"))
            mode, mid = if length(parts) == 3
                String(parts[2]), String(parts[3])
            elseif parts[2] in MODEL_MODES
                String(parts[2]), MODE_DEFAULT_MODEL[String(parts[2])]
            else
                st.mode, String(parts[2])
            end
            mode in MODEL_MODES || return println(io, red(io, "unknown mode: $(mode) (expected $(join(MODEL_MODES, " or ")))"))
            getModel(mode_provider(mode), mid) === nothing && return println(io, red(io, "unknown model: $(mode)/$(mid)"))
            st.mode, st.model_id = mode, mid
            st.reasoning in reasoning_levels(mode, mid) || (st.reasoning = nothing)
            save_model_state!(st.jdb, st.mode, st.model_id, st.reasoning)
            println(io, dim(io, "model set: $(model_label(st))"))
        end
    elseif cmd == "/skills"
        isempty(st.skills) && return println(io, "No skills found in $(join(skill_dirs(st.base_dir), " or ")).")
        for s in st.skills
            println(io, "\$", s.name, dim(io, isempty(s.description) ? "" : "  — $(s.description)"))
        end
    elseif cmd == "/memories"
        mems = memories(st.jdb)
        isempty(mems) && return println(io, "No memories.")
        foreach(m -> println(io, "- ", m), mems)
    elseif cmd == "/quit"
        st.quit = true
    else
        println(io, red(io, "unknown command $(cmd)"), " — /help for commands")
    end
    return nothing
end

# Read one logical input: trailing backslash continues on the next line.
# Returns nothing on EOF.
function read_input(io::IO)
    print(io, bold(io, "juco> "))
    raw = readline(stdin; keep = true)
    isempty(raw) && return nothing
    input = String(strip(raw))
    while endswith(input, "\\")
        input = chop(input; tail = 1)
        print(io, bold(io, "  ..> "))
        raw = readline(stdin; keep = true)
        isempty(raw) && break
        input *= "\n" * strip(raw)
    end
    return String(strip(input))
end

# Run one turn on a worker task so ctrl-c aborts the TURN (via Abort), not the
# REPL. A second ctrl-c while aborting force-detaches.
#
# While the turn runs, a pump task reads stdin lines into the steering channel:
# each line is shown as queued immediately, then echoed again (via on_steer)
# at the moment a completed tool call actually delivers it to the model.
function root_task_exception(e)
    while e isa TaskFailedException
        inner = e.task.exception
        inner === e && break
        e = inner
    end
    return e
end

function locked_println(io::IO, io_lock::ReentrantLock, xs...)
    lock(io_lock) do
        println(io, xs...)
        flush(io)
    end
    return nothing
end

function turn_error_summary(e)
    first_line = first(split(sprint(showerror, e), '\n'))
    if occursin("No stored Codex credentials", first_line) ||
            occursin("Stored Codex credentials were rejected", first_line)
        return "Codex login required: run `using LLMOAuth; LLMOAuth.codex_login()`"
    end
    return first_line
end

function wait_turn(turn::Task, abort::Agentif.Abort, io::IO;
        io_lock::ReentrantLock = ReentrantLock())
    while true
        try
            return fetch(turn)
        catch e
            if e isa InterruptException
                Agentif.abort!(abort)
                locked_println(io, io_lock,
                    "\n^C interrupting — waiting for the turn to stop (ctrl-c again to detach)")
                status = try
                    timedwait(() -> istaskdone(turn), 10.0; pollint = 0.1)
                catch wait_error
                    wait_error isa InterruptException || rethrow()
                    locked_println(io, io_lock, "^C detached from the running turn")
                    return nothing
                end
                status === :ok || return nothing
            elseif e isa TaskFailedException
                inner = root_task_exception(e)
                inner isa InterruptException && return nothing
                locked_println(io, io_lock, red(io, "error: " * turn_error_summary(inner)))
                locked_println(io, io_lock, dim(io, "the session is intact — try again or rephrase"))
                return nothing
            else
                rethrow()
            end
        end
    end
end

function run_turn(st::ReplState, input::String, io::IO; steering::Bool = stdin isa Base.TTY, kw...)
    expanded, used = expand_skills(input, st.skills)
    isempty(used) || println(io, dim(io, "⚡ skills: " * join(used, ", ")))
    abort = Agentif.Abort()
    io_lock = ReentrantLock()
    steer = steering ? Channel{String}(32) : nothing
    on_steer = steer === nothing ? nothing :
        text -> locked_println(io, io_lock, steer_active_line(io, text))
    turn = @async evaluate(expanded; jdb = st.jdb, session_id = st.session_id,
        provider = mode_provider(st.mode), model_id = st.model_id,
        apikey = mode_apikey(st.mode), reasoning_effort = st.reasoning,
        io, show_usage = true, abort, steer, on_steer, io_lock, kw...)
    pump = steer === nothing ? nothing : @async begin
        try
            while !istaskdone(turn)
                raw = readline(stdin; keep = true)
                isempty(raw) && break  # EOF
                s = strip(raw)
                isempty(s) && continue
                put!(steer, String(s))
                locked_println(io, io_lock, steer_queued_line(io, s))
            end
        catch
            # interrupted at turn end, or stdin closed — either way we're done
        end
    end
    try
        return wait_turn(turn, abort, io; io_lock)
    finally
        steer === nothing || !isopen(steer) || close(steer)
        if pump !== nothing
            if !istaskdone(pump)
                try
                    schedule(pump, InterruptException(); error = true)
                catch
                end
            end
            try
                wait(pump)
            catch
            end
        end
    end
end

function repl(;
        db_path::AbstractString = DEFAULT_DB_PATH,
        continue_last::Bool = false,
        base_dir::AbstractString = pwd(),
        io::IO = stdout,
        kw...,
    )
    return with_jdb(db_path) do jdb
        _repl(jdb; db_path, continue_last, base_dir, io, kw...)
    end
end

function _repl(jdb::JucoDB;
        db_path::AbstractString,
        continue_last::Bool,
        base_dir::AbstractString,
        io::IO,
        kw...,
    )
    session_id = continue_last ? latest_session(jdb) : nothing
    continue_last && session_id === nothing && println(io, "No previous session found; starting a new one.")
    session_id === nothing && (session_id = "juco-" * string(Agentif.UID8()))
    st = ReplState(jdb, session_id; base_dir)
    println(io, bold(io, "juco"), dim(io, " · $(model_label(st)) · session $(session_id)"))
    skills_note = isempty(st.skills) ? "" : " · $(length(st.skills)) skill$(length(st.skills) == 1 ? "" : "s")"
    println(io, dim(io, "db $(abspath(db_path))$(skills_note) · /help for commands · exit to quit"))
    isa(stdin, Base.TTY) && Base.exit_on_sigint(false)
    try
        while !st.quit
            input = try
                read_input(io)
            catch e
                e isa InterruptException ? "" : rethrow()
            end
            input === nothing && break  # EOF (ctrl-d)
            isempty(input) && continue
            input in ("exit", "quit") && break
            if startswith(input, "/")
                handle_command(st, input, io)
            else
                run_turn(st, input, io; kw...)
                println(io)
            end
        end
    finally
        isa(stdin, Base.TTY) && Base.exit_on_sigint(true)
    end
    return nothing
end

# ─── In-REPL mode (implemented in the ReplMaker package extension) ───

"""
    Juco.repl_mode!(; db_path = DEFAULT_DB_PATH, start_key = '}')

Register a `juco>` mode in the current Julia REPL (like Pkg's `]`): press
`}` at an empty `julia>` prompt to talk to Juco, backspace to leave. Slash
commands (`/help`, `/sessions`, ...) work inside the mode.

Requires ReplMaker: `using Juco, ReplMaker; Juco.repl_mode!()`.
"""
function repl_mode! end

mode_state(db_path::AbstractString = DEFAULT_DB_PATH; base_dir::AbstractString = pwd()) =
    ReplState(opendb(db_path), "juco-" * string(Agentif.UID8()); base_dir)

function mode_eval(st::ReplState, input::AbstractString; kw...)
    s = String(strip(input))
    isempty(s) && return nothing
    if startswith(s, "/")
        handle_command(st, s, stdout)
    else
        run_turn(st, s, stdout; kw...)
    end
    return nothing
end

function print_sessions(db_path::AbstractString)
    return with_jdb(db_path) do jdb
        sessions = list_sessions(jdb)
        isempty(sessions) && return println("No sessions.")
        for s in sessions
            ts = Dates.format(Dates.unix2datetime(s.updated_at), "yyyy-mm-dd HH:MM")
            println("$(s.id)  $(ts)  $(s.cwd)  $(s.title)")
        end
    end
end

"""
    Juco.install_cli(; dir = joinpath(homedir(), ".local", "bin"))

Write a `juco` launcher script to `dir` so the agent can be started from any
shell. The script runs this monorepo's environment.
"""
function install_cli(; dir::AbstractString = joinpath(homedir(), ".local", "bin"))
    project = dirname(pkgdir(Juco))
    mkpath(dir)
    path = joinpath(dir, "juco")
    write(path, """
        #!/bin/sh
        exec julia --project=$(project) --startup-file=no -e 'using Juco; Juco.main(ARGS)' -- "\$@"
        """)
    chmod(path, 0o755)
    occursin(abspath(dir), get(ENV, "PATH", "")) ||
        @info "add $(dir) to your PATH to use `juco` directly"
    return path
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
  --provider <name>         one-shot only: model provider override
  --model <id>              one-shot only: model id override
  --preset <name>           toolset preset: juco | pi | bash (default: juco)
  -h, --help                show this help

The interactive session uses the persisted model selection (see /model).
"""

function parse_cli_args(args::Vector{String})
    db_path = DEFAULT_DB_PATH
    base_dir = pwd()
    provider = default_provider()
    model_id = default_model()
    preset = :juco
    continue_last = false
    prompt = nothing
    list = false
    help = false
    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("-h", "--help")
            help = true
            break
        elseif a in ("-c", "--continue")
            continue_last = true
        elseif a in ("-l", "--list")
            list = true
        elseif a in ("-p", "--prompt")
            i < length(args) || throw(ArgumentError("$a requires a value"))
            i += 1; prompt = args[i]
        elseif a == "--db"
            i < length(args) || throw(ArgumentError("$a requires a value"))
            i += 1; db_path = args[i]
        elseif a == "--dir"
            i < length(args) || throw(ArgumentError("$a requires a value"))
            i += 1; base_dir = args[i]
        elseif a == "--provider"
            i < length(args) || throw(ArgumentError("$a requires a value"))
            i += 1; provider = args[i]
        elseif a == "--model"
            i < length(args) || throw(ArgumentError("$a requires a value"))
            i += 1; model_id = args[i]
        elseif a == "--preset"
            i < length(args) || throw(ArgumentError("$a requires a value"))
            i += 1; preset = Symbol(args[i])
        else
            throw(ArgumentError("Unknown flag: $a (see juco --help)"))
        end
        i += 1
    end
    preset in (:juco, :pi, :bash) ||
        throw(ArgumentError("unknown preset: $preset (expected juco, pi, or bash)"))
    list && prompt !== nothing && throw(ArgumentError("--list and --prompt cannot be used together"))
    return (; db_path, base_dir, provider, model_id, preset, continue_last, prompt, list, help)
end

function main(args::Vector{String} = ARGS)
    opts = parse_cli_args(args)
    opts.help && return print(CLI_HELP)
    opts.list && return print_sessions(opts.db_path)
    if opts.prompt !== nothing
        (; db_path, base_dir, provider, model_id, preset, continue_last, prompt) = opts
        with_jdb(db_path) do jdb
            session_id = continue_last ? latest_session(jdb) : nothing
            evaluate(prompt; jdb, session_id, base_dir, provider, model_id, preset)
        end
    else
        repl(; db_path = opts.db_path, continue_last = opts.continue_last,
            base_dir = opts.base_dir, preset = opts.preset)
    end
    return nothing
end

# Entry point for `julia -m Juco` and the Pkg app shim (`pkg> app add Juco`).
(@main)(args) = (main(collect(String, args)); Cint(0))
