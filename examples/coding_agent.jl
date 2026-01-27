#!/usr/bin/env julia
using Agentif
using Dates
using JSON

const DEFAULT_PROVIDER = "openai"
const DEFAULT_MODEL = "gpt-4.1-mini"
const USE_COLOR = get(ENV, "NO_COLOR", "") == "" && (stdout isa Base.TTY)
const ANSI_DIM = "\e[90m"
const ANSI_ITALIC = "\e[3m"
const ANSI_RESET = "\e[0m"
const TOOL_DESCRIPTIONS = Dict(
    "read" => "Read file contents",
    "bash" => "Execute bash commands (ls, grep, find, etc.)",
    "edit" => "Make surgical edits to files (find exact text and replace)",
    "write" => "Create or overwrite files",
    "grep" => "Search file contents for patterns (respects .gitignore)",
    "find" => "Find files by glob pattern (respects .gitignore)",
    "ls" => "List directory contents",
)

function style_thinking(text::String)
    USE_COLOR || return text
    return string(ANSI_DIM, ANSI_ITALIC, text, ANSI_RESET)
end

function style_tool(text::String)
    USE_COLOR || return text
    return string(ANSI_DIM, text, ANSI_RESET)
end

function shorten_string(text::AbstractString; max_len::Int = 60)
    length(text) <= max_len && return text
    return first(text, max_len) * "..."
end

function format_value(value; max_len::Int = 60)
    if value === nothing
        return "null"
    elseif value isa Bool || value isa Number
        return string(value)
    elseif value isa AbstractString
        sanitized = replace(value, "\n" => "\\n")
        return shorten_string(sanitized; max_len)
    elseif value isa AbstractVector
        return "[$(length(value)) items]"
    elseif value isa AbstractDict
        return "{...}"
    end
    return shorten_string(string(value); max_len)
end

function summarize_tool_args(name::String, args_json::String)
    parsed = try
        JSON.parse(args_json)
    catch
        return shorten_string(args_json; max_len = 80)
    end
    parsed isa AbstractDict || return shorten_string(args_json; max_len = 80)
    keys_list = collect(keys(parsed))
    ordered = String[]
    if "path" in keys_list
        push!(ordered, "path")
    end
    for key in sort(String.(keys_list))
        key == "path" && continue
        push!(ordered, key)
    end
    parts = String[]
    for key in ordered
        value = parsed[key]
        if key in ("content", "oldText", "newText")
            if value isa AbstractString
                push!(parts, "$(key)=<$(ncodeunits(value)) bytes>")
            else
                push!(parts, "$(key)=<...>")
            end
        else
            push!(parts, "$(key)=$(format_value(value))")
        end
    end
    return join(parts, " ")
end

function summarize_tool_output(name::String, output::String, is_error::Bool)
    text = strip(output)
    isempty(text) && return is_error ? "error" : "ok"
    if is_error
        return shorten_string(text; max_len = 200)
    end
    if name in ("write", "edit")
        return shorten_string(text; max_len = 160)
    end
    lines = count(==('\n'), text) + 1
    bytes = ncodeunits(text)
    if lines == 1 && length(text) <= 120
        return text
    end
    return "$(lines) lines, $(bytes) bytes"
end

function load_context_files(cwd::AbstractString = pwd())
    root = abspath("/")
    current = abspath(cwd)
    dirs = String[]
    while true
        push!(dirs, current)
        current == root && break
        parent = dirname(current)
        parent == current && break
        current = parent
    end

    seen = Set{String}()
    context = NamedTuple[]
    for dir in reverse(dirs)
        for name in ("AGENTS.md", "CLAUDE.md")
            path = joinpath(dir, name)
            if isfile(path) && !(path in seen)
                push!(context, (path = path, content = read(path, String)))
                push!(seen, path)
                break
            end
        end
    end
    return context
end

function build_system_prompt(; selected_tools, readme_path, docs_path, append_prompt = nothing, context_files = NamedTuple[])
    tools_list = join(["- $(name): $(get(() -> "Tool", TOOL_DESCRIPTIONS, name))" for name in selected_tools], "\n")

    has_read = "read" in selected_tools
    has_bash = "bash" in selected_tools
    has_edit = "edit" in selected_tools
    has_write = "write" in selected_tools
    has_grep = "grep" in selected_tools
    has_find = "find" in selected_tools
    has_ls = "ls" in selected_tools

    guidelines = String[]
    if !has_bash && !has_edit && !has_write
        push!(guidelines, "You are in READ-ONLY mode - you cannot modify files or execute arbitrary commands")
    end
    if has_bash && !has_edit && !has_write
        push!(guidelines, "Use bash ONLY for read-only operations (git log, gh issue view, curl, etc.) - do NOT modify any files")
    end
    if has_bash && !has_grep && !has_find && !has_ls
        push!(guidelines, "Use bash for file operations like ls, grep, find")
    elseif has_bash && (has_grep || has_find || has_ls)
        push!(guidelines, "Prefer grep/find/ls tools over bash for file exploration (faster, respects .gitignore)")
    end
    if has_read && has_edit
        push!(guidelines, "Use read to examine files before editing. You must use this tool instead of cat or sed.")
    end
    if has_edit
        push!(guidelines, "Use edit for precise changes (old text must match exactly)")
    end
    if has_write
        push!(guidelines, "Use write only for new files or complete rewrites")
    end
    if has_edit || has_write
        push!(guidelines, "When summarizing your actions, output plain text directly - do NOT use cat or bash to display what you did")
    end
    push!(guidelines, "Be concise in your responses")
    push!(guidelines, "Show file paths clearly when working with files")

    prompt = """You are an expert coding assistant. You help users with coding tasks by reading files, executing commands, editing code, and writing new files.

    Available tools:
    $(tools_list)

    Guidelines:
    $(join(["- $(g)" for g in guidelines], "\n"))

    Documentation:
    - Main documentation: $(readme_path)
    - Additional docs: $(docs_path)
    - When asked about: providers/models (README.md), tools (src/predefined_tools.jl), guardrails (src/input_guardrail.jl)
    """

    if append_prompt !== nothing && !isempty(strip(append_prompt))
        prompt *= "\n\n" * append_prompt
    end

    if !isempty(context_files)
        prompt *= "\n\n# Project Context\n\n"
        prompt *= "The following project context files have been loaded:\n\n"
        for ctx in context_files
            prompt *= "## $(ctx.path)\n\n$(ctx.content)\n\n"
        end
    end

    prompt *= "\nCurrent date and time: $(Dates.format(Dates.now(), dateformat"yyyy-mm-dd HH:MM:SS"))"
    prompt *= "\nCurrent working directory: $(abspath(pwd()))"
    return prompt
end

function make_event_handler()
    tool_started = Dict{String, Float64}()
    assistant_in_progress = false
    function handle_event(event)
        return if event isa Agentif.MessageStartEvent
            if event.role == :assistant
                assistant_in_progress = true
            end
        elseif event isa Agentif.MessageUpdateEvent
            if event.role == :assistant && event.kind == :text
                print(event.delta)
                flush(stdout)
            elseif event.role == :assistant && event.kind == :reasoning
                print(style_thinking(event.delta))
                flush(stdout)
            end
        elseif event isa Agentif.MessageEndEvent
            if event.role == :assistant
                assistant_in_progress = false
                println()
            end
        elseif event isa Agentif.ToolExecutionStartEvent
            assistant_in_progress && println()
            tool_started[event.tool_call.call_id] = time()
            args_summary = summarize_tool_args(event.tool_call.name, event.tool_call.arguments)
            suffix = isempty(args_summary) ? "" : " " * args_summary
            println(style_tool("[tool] $(event.tool_call.name)$(suffix)"))
        elseif event isa Agentif.ToolExecutionEndEvent
            assistant_in_progress && println()
            started = get(() -> nothing, tool_started, event.tool_call.call_id)
            started !== nothing && delete!(tool_started, event.tool_call.call_id)
            elapsed = started === nothing ? "" : " ($(round(time() - started; digits = 2))s)"
            summary = summarize_tool_output(event.tool_call.name, message_text(event.result), event.result.is_error)
            status = event.result.is_error ? "error" : "done"
            println(style_tool("[tool] $(event.tool_call.name) $(status)$(elapsed): $(summary)"))
        elseif event isa Agentif.AgentErrorEvent
            assistant_in_progress && println()
            println("[error] $(event.error)")
        end
    end
    return handle_event
end

function main()
    apikey = get(() -> nothing, ENV, "AGENTIF_API_KEY")
    apikey === nothing && error("Set AGENTIF_API_KEY to run this example.")

    provider = get(() -> DEFAULT_PROVIDER, ENV, "AGENTIF_PROVIDER")
    model_id = get(() -> DEFAULT_MODEL, ENV, "AGENTIF_MODEL")
    model = Agentif.getModel(provider, model_id)
    model === nothing && error("Unknown model: provider=$(repr(provider)) model_id=$(repr(model_id))")

    base_dir = pwd()
    tools = Agentif.coding_tools(base_dir)
    skill_registry = Agentif.create_skill_registry(Agentif.default_skill_dirs(base_dir))
    if !isempty(skill_registry.skills)
        push!(tools, Agentif.create_skill_loader_tool(skill_registry))
    end
    selected_tools = [tool.name for tool in tools]
    system_prompt = build_system_prompt(;
        selected_tools,
        readme_path = abspath("README.md"),
        docs_path = abspath("docs"),
        context_files = load_context_files(base_dir),
    )

    agent = Agentif.Agent(;
        prompt = system_prompt,
        model,
        input_guardrail = nothing,
        tools,
        skills = skill_registry,
    )

    handle_event = make_event_handler()
    session = Agentif.AgentSession(agent)

    println("Agentif coding agent ready. Type 'exit' to quit.")
    while true
        print("> ")
        input = readline()
        input = String(strip(input))
        isempty(input) && continue
        input in ("exit", "quit") && break

        result = Agentif.evaluate(handle_event, session, input, apikey)
        if !isempty(result.pending_tool_calls)
            for ptc in result.pending_tool_calls
                Agentif.approve!(ptc)
            end
            Agentif.evaluate(handle_event, session, result.pending_tool_calls, apikey)
        end
    end
    return
end

main()
