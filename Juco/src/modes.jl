# Model modes: named provider configurations the user switches between with
# /model. Selection (mode, model, reasoning) is persistent REPL state stored in
# the sqlite config table — not environment variables.

const MODEL_MODES = ["openrouter", "codex"]

mode_provider(mode::AbstractString) = mode == "codex" ? "openai-codex" : "openrouter"

# codex authenticates via the LLMOAuth ChatGPT flow (apikey sentinel "OAUTH")
mode_apikey(mode::AbstractString) = mode == "codex" ? "OAUTH" : resolve_apikey("openrouter")

const MODE_DEFAULT_MODEL = Dict(
    "openrouter" => "deepseek/deepseek-v4-flash-0731",
    "codex" => "gpt-5.3-codex",
)

mode_models(mode::AbstractString) =
    sort!([m.id for m in getModels(mode_provider(mode))])

function reasoning_levels(mode::AbstractString, model_id::AbstractString)
    m = getModel(mode_provider(mode), model_id)
    (m === nothing || !m.reasoning) && return ["none"]
    mode == "codex" && return ["none", "minimal", "low", "medium", "high", "xhigh"]
    return ["none", "low", "medium", "high"]
end

# ─── Persistent model selection ───

function load_model_state(jdb::JucoDB)
    stored_mode = get_config(jdb, "model_mode")
    stored_model = get_config(jdb, "model_id")
    stored_reasoning = get_config(jdb, "reasoning")
    mode = something(stored_mode, "openrouter")
    mode in MODEL_MODES || (mode = "openrouter")
    model_id = something(stored_model, MODE_DEFAULT_MODEL[mode])
    getModel(mode_provider(mode), model_id) === nothing &&
        (model_id = MODE_DEFAULT_MODEL[mode])
    reasoning = stored_reasoning == "none" ? nothing : stored_reasoning
    levels = reasoning_levels(mode, model_id)
    reasoning === nothing || reasoning in levels || (reasoning = nothing)
    if (mode, model_id, reasoning) != (stored_mode, stored_model, stored_reasoning)
        save_model_state!(jdb, mode, model_id, reasoning)
    end
    return mode, model_id, reasoning
end

function save_model_state!(jdb::JucoDB, mode::AbstractString, model_id::AbstractString, reasoning::Union{Nothing, AbstractString})
    SQLite.DBInterface.transaction(jdb.db) do
        set_config!(jdb, "model_mode", mode)
        set_config!(jdb, "model_id", model_id)
        set_config!(jdb, "reasoning", reasoning)
    end
    return nothing
end

# ─── Menus (TerminalMenus on a TTY, numbered fallback otherwise) ───

# TerminalMenus writes its initial frame without flushing. Some terminal
# emulators therefore do not show the choices until the first key press.
struct FlushingIO <: IO
    io::IO
end

Base.isopen(io::FlushingIO) = isopen(io.io)
Base.displaysize(io::FlushingIO) = displaysize(io.io)
Base.get(io::FlushingIO, key, default) = get(io.io, key, default)
Base.flush(io::FlushingIO) = flush(io.io)

function Base.unsafe_write(io::FlushingIO, data::Ptr{UInt8}, n::UInt)
    written = unsafe_write(io.io, data, n)
    flush(io.io)
    return written
end

function Base.write(io::FlushingIO, byte::UInt8)
    written = write(io.io, byte)
    flush(io.io)
    return written
end

function flushing_terminal()
    term = TerminalMenus.default_terminal()
    return REPL.Terminals.TTYTerminal(
        term.term_type, term.in_stream, FlushingIO(term.out_stream), term.err_stream)
end

function choose(io::IO, title::AbstractString, options::Vector{String}; default::Int = 1,
        input::IO = stdin)
    isempty(options) && return nothing
    if input === stdin && input isa Base.TTY && io === stdout
        menu = TerminalMenus.RadioMenu(options; pagesize = min(12, length(options)))
        term = flushing_terminal()
        idx = TerminalMenus.request(term, String(title), menu;
            cursor = clamp(default, 1, length(options)))
        return idx == -1 ? nothing : idx
    end
    println(io, title)
    for (i, o) in enumerate(options)
        println(io, "  $(i). $(o)")
    end
    print(io, "choice [$(default)]: ")
    eof(input) && return nothing
    raw = try
        strip(readline(input))
    catch e
        e isa EOFError || rethrow()
        return nothing
    end
    isempty(raw) && return default
    n = tryparse(Int, raw)
    return (n === nothing || !(1 <= n <= length(options))) ? nothing : n
end

# The /model flow: mode -> model (with substring filter for huge lists) -> reasoning.
function model_menu!(st, io::IO; input::IO = stdin)
    mode_i = choose(io, "Model mode:", MODEL_MODES;
        default = something(findfirst(==(st.mode), MODEL_MODES), 1), input)
    mode_i === nothing && return println(io, dim(io, "cancelled"))
    mode = MODEL_MODES[mode_i]
    models = mode_models(mode)
    if length(models) > 30
        print(io, "filter (substring, empty for all): ")
        eof(input) && return println(io, dim(io, "cancelled"))
        pat = lowercase(strip(readline(input)))
        isempty(pat) || (models = filter(m -> occursin(pat, lowercase(m)), models))
        isempty(models) && return println(io, red(io, "no models match \"$(pat)\""))
    end
    default_model = something(findfirst(==(st.model_id), models), 1)
    model_i = choose(io, "Model:", models; default = default_model, input)
    model_i === nothing && return println(io, dim(io, "cancelled"))
    model_id = models[model_i]
    levels = reasoning_levels(mode, model_id)
    current_level = something(st.reasoning, "none")
    level_i = choose(io, "Reasoning:", levels;
        default = something(findfirst(==(current_level), levels), 1), input)
    level_i === nothing && return println(io, dim(io, "cancelled"))
    reasoning = levels[level_i] == "none" ? nothing : levels[level_i]
    st.mode, st.model_id, st.reasoning = mode, model_id, reasoning
    save_model_state!(st.jdb, mode, model_id, reasoning)
    println(io, dim(io, "model set: $(mode) · $(model_id) · reasoning $(something(reasoning, "none"))"))
    return nothing
end

session_age(updated_at::Real) = begin
    s = time() - updated_at
    s < 90 ? "just now" :
    s < 3600 ? "$(round(Int, s / 60))m ago" :
    s < 86400 ? "$(round(Int, s / 3600))h ago" : "$(round(Int, s / 86400))d ago"
end

# The /resume flow: pick a past session from a menu.
function resume_menu!(st, io::IO; input::IO = stdin)
    sessions = list_sessions(st.jdb; limit = 15)
    isempty(sessions) && return println(io, "No sessions to resume.")
    options = ["$(s.id)  ($(session_age(s.updated_at)))  $(first(s.title, 50))" for s in sessions]
    i = choose(io, "Resume session:", options; input)
    i === nothing && return println(io, dim(io, "cancelled"))
    switch_session!(st, sessions[i].id)
    println(io, dim(io, "resumed $(st.session_id)"))
    return nothing
end
