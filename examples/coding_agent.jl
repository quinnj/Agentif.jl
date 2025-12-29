#!/usr/bin/env julia
using Agentif
using Dates

const DEFAULT_PROVIDER = "openai"
const DEFAULT_MODEL = "gpt-4.1-mini"
const TOOL_DESCRIPTIONS = Dict(
    "read" => "Read file contents",
    "bash" => "Execute bash commands (ls, grep, find, etc.)",
    "edit" => "Make surgical edits to files (find exact text and replace)",
    "write" => "Create or overwrite files",
    "grep" => "Search file contents for patterns (respects .gitignore)",
    "find" => "Find files by glob pattern (respects .gitignore)",
    "ls" => "List directory contents",
)

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
                push!(context, (path=path, content=read(path, String)))
                push!(seen, path)
                break
            end
        end
    end
    return context
end

function build_system_prompt(; selected_tools, readme_path, docs_path, append_prompt=nothing, context_files=NamedTuple[])
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

function handle_event(event)
    if event isa Agentif.MessageUpdateEvent
        if event.role == :assistant && event.kind == :text
            print(event.delta)
            flush(stdout)
        end
    elseif event isa Agentif.MessageEndEvent
        event.role == :assistant && println()
    elseif event isa Agentif.ToolExecutionStartEvent
        println("\n[tool start] $(event.tool_call.name) $(event.tool_call.arguments)")
    elseif event isa Agentif.ToolExecutionEndEvent
        println("\n[tool done] $(event.tool_call.name)")
        println(event.result.output)
    elseif event isa Agentif.AgentErrorEvent
        println("\n[error] $(event.error)")
    end
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
    selected_tools = [tool.name for tool in tools]
    system_prompt = build_system_prompt(;
        selected_tools,
        readme_path=abspath("README.md"),
        docs_path=abspath("docs"),
        context_files=load_context_files(base_dir),
    )

    agent = Agentif.Agent(;
        prompt=system_prompt,
        model,
        input_guardrail=nothing,
        tools,
    )

    println("Agentif coding agent ready. Type 'exit' to quit.")
    while true
        print("> ")
        input = readline()
        input = String(strip(input))
        isempty(input) && continue
        input in ("exit", "quit") && break

        result = Agentif.evaluate(handle_event, agent, input, apikey)
        if !isempty(result.pending_tool_calls)
            for ptc in result.pending_tool_calls
                Agentif.approve!(ptc)
            end
            Agentif.evaluate(handle_event, agent, result.pending_tool_calls, apikey; previous_response_id=result.previous_response_id)
        end
    end
end

main()
