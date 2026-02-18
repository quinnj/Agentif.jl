const DEFAULT_MAX_LINES = 2000
const DEFAULT_MAX_BYTES = 50 * 1024
const GREP_MAX_LINE_LENGTH = 500
const DEFAULT_LS_LIMIT = 500
const DEFAULT_FIND_LIMIT = 1000
const DEFAULT_GREP_LIMIT = 100

struct TruncationResult
    content::String
    truncated::Bool
    truncated_by::Union{Nothing, Symbol}
    total_lines::Int
    total_bytes::Int
    output_lines::Int
    output_bytes::Int
    last_line_partial::Bool
    first_line_exceeds_limit::Bool
    max_lines::Int
    max_bytes::Int
end

function format_size(bytes::Int)
    if bytes < 1024
        return "$(bytes)B"
    elseif bytes < 1024 * 1024
        return "$(round(bytes / 1024; digits = 1))KB"
    end
    return "$(round(bytes / (1024 * 1024); digits = 1))MB"
end

function truncate_head(content::String; max_lines::Int = DEFAULT_MAX_LINES, max_bytes::Int = DEFAULT_MAX_BYTES)
    total_bytes = ncodeunits(content)
    lines = split(content, "\n"; keepempty = true)
    total_lines = length(lines)
    if total_lines <= max_lines && total_bytes <= max_bytes
        return TruncationResult(content, false, nothing, total_lines, total_bytes, total_lines, total_bytes, false, false, max_lines, max_bytes)
    end

    first_line_bytes = ncodeunits(lines[1])
    if first_line_bytes > max_bytes
        return TruncationResult("", true, :bytes, total_lines, total_bytes, 0, 0, false, true, max_lines, max_bytes)
    end

    output_lines = String[]
    output_bytes = 0
    truncated_by = :lines

    for (idx, line) in enumerate(lines)
        idx > max_lines && break
        line_bytes = ncodeunits(line) + (idx > 1 ? 1 : 0)
        if output_bytes + line_bytes > max_bytes
            truncated_by = :bytes
            break
        end
        push!(output_lines, line)
        output_bytes += line_bytes
    end

    output_content = join(output_lines, "\n")
    return TruncationResult(
        output_content,
        true,
        truncated_by,
        total_lines,
        total_bytes,
        length(output_lines),
        ncodeunits(output_content),
        false,
        false,
        max_lines,
        max_bytes,
    )
end

function truncate_tail(content::String; max_lines::Int = DEFAULT_MAX_LINES, max_bytes::Int = DEFAULT_MAX_BYTES)
    total_bytes = ncodeunits(content)
    lines = split(content, "\n"; keepempty = true)
    total_lines = length(lines)
    if total_lines <= max_lines && total_bytes <= max_bytes
        return TruncationResult(content, false, nothing, total_lines, total_bytes, total_lines, total_bytes, false, false, max_lines, max_bytes)
    end

    output_lines = String[]
    output_bytes = 0
    truncated_by = :lines
    last_line_partial = false

    for idx in length(lines):-1:1
        length(output_lines) >= max_lines && break
        line = lines[idx]
        line_bytes = ncodeunits(line) + (!isempty(output_lines) ? 1 : 0)
        if output_bytes + line_bytes > max_bytes
            truncated_by = :bytes
            if isempty(output_lines)
                truncated_line = truncate_string_to_bytes_from_end(line, max_bytes)
                push!(output_lines, truncated_line)
                output_bytes = ncodeunits(truncated_line)
                last_line_partial = true
            end
            break
        end
        pushfirst!(output_lines, line)
        output_bytes += line_bytes
    end

    output_content = join(output_lines, "\n")
    return TruncationResult(
        output_content,
        true,
        truncated_by,
        total_lines,
        total_bytes,
        length(output_lines),
        ncodeunits(output_content),
        last_line_partial,
        false,
        max_lines,
        max_bytes,
    )
end

function truncate_tool_output(content::String; label::String = "Output", hint::Union{Nothing, String} = nothing)
    truncation = truncate_head(content)
    output = truncation.content
    hint_value = hint === nothing ? "" : " " * String(hint)
    if truncation.first_line_exceeds_limit
        first_line = split(content, "\n"; limit = 2)[1]
        line_size = format_size(ncodeunits(first_line))
        return "[$(label) first line is $(line_size), exceeds $(format_size(DEFAULT_MAX_BYTES)) limit.$(hint_value)]"
    elseif truncation.truncated
        end_display = truncation.output_lines
        if truncation.truncated_by == :lines
            output *= "\n\n[$(label) truncated: showing lines 1-$(end_display) of $(truncation.total_lines).$(hint_value)]"
        else
            output *= "\n\n[$(label) truncated: showing lines 1-$(end_display) of $(truncation.total_lines) ($(format_size(DEFAULT_MAX_BYTES)) limit).$(hint_value)]"
        end
    end
    return output
end

function truncate_string_to_bytes_from_end(text::String, max_bytes::Int)
    bytes = Vector{UInt8}(codeunits(text))
    length(bytes) <= max_bytes && return text
    start = length(bytes) - max_bytes + 1
    while start <= length(bytes) && (bytes[start] & 0xc0) == 0x80
        start += 1
    end
    return String(bytes[start:end])
end

function truncate_line(line::AbstractString; max_chars::Int = GREP_MAX_LINE_LENGTH)
    length(line) <= max_chars && return (text = String(line), was_truncated = false)
    return (text = String(first(line, max_chars)) * " [truncated]", was_truncated = true)
end

function ensure_base_dir(base_dir::AbstractString)
    base = abspath(base_dir)
    isdir(base) || throw(ArgumentError("base directory does not exist: $base"))
    return base
end

function ensure_relative_path(path::String)
    isempty(path) && throw(ArgumentError("path is required"))
    isabspath(path) && throw(ArgumentError("absolute paths are not allowed: $path"))
    startswith(path, "~") && throw(ArgumentError("home paths are not allowed: $path"))
    return nothing
end

function is_within_base(path::AbstractString, base::AbstractString)
    base_norm = normpath(base)
    path_norm = normpath(path)
    if path_norm == base_norm
        return true
    end
    sep = Base.Filesystem.path_separator
    return startswith(path_norm, base_norm * string(sep))
end

function resolve_relative_path(base_dir::AbstractString, path::String)
    ensure_relative_path(path)
    base = abspath(base_dir)
    resolved = abspath(joinpath(base, path))
    is_within_base(resolved, base) || throw(ArgumentError("path resolves outside base directory: $path"))
    return resolved
end

function resolve_search_path(base_dir::AbstractString, path::Union{Nothing, String})
    local_path = (path === nothing || isempty(path)) ? "." : path
    return resolve_relative_path(base_dir, local_path)
end

function normalize_relpath(path::AbstractString)
    return replace(path, '\\' => '/')
end

function glob_to_regex(pattern::String)
    normalized = replace(pattern, '\\' => '/')
    out = IOBuffer()
    print(out, "^")
    idx = 1
    while idx <= lastindex(normalized)
        char = normalized[idx]
        if char == '*'
            if idx < lastindex(normalized) && normalized[idx + 1] == '*'
                print(out, ".*")
                idx += 2
            else
                print(out, "[^/]*")
                idx += 1
            end
            continue
        elseif char == '?'
            print(out, "[^/]")
            idx += 1
            continue
        elseif char in ('\\', '.', '+', '(', ')', '[', ']', '{', '}', '^', '$', '|')
            print(out, "\\", char)
            idx += 1
            continue
        end
        print(out, char)
        idx += 1
    end
    print(out, "\$")
    return Regex(String(take!(out)))
end

function command_has_absolute_path(command::String)
    return occursin(r"(^|\s)(/|~)", command)
end

function shell_escape(text::AbstractString)
    return "'" * replace(text, "'" => raw"'\''") * "'"
end


function strip_dir_suffix(entry::String)
    return endswith(entry, "/") ? entry[1:(end - 1)] : entry
end

function create_read_tool(base_dir::AbstractString)
    base = ensure_base_dir(base_dir)
    return @tool(
        "Read the contents of a file. Output is truncated to 2000 lines or 50KB (whichever is hit first). Use offset and limit for large files.",
        read(path::String, offset::Union{Nothing, Int} = nothing, limit::Union{Nothing, Int} = nothing) = begin
            resolved = resolve_relative_path(base, path)
            isfile(resolved) || throw(ArgumentError("file not found: $path"))
            content = Base.read(resolved, String)
            lines = split(content, "\n"; keepempty = true)
            total_lines = length(lines)
            start_line = offset === nothing ? 1 : max(1, offset)
            start_line > total_lines && throw(ArgumentError("offset $(offset) is beyond end of file ($(total_lines) lines total)"))
            effective_limit = limit === nothing ? nothing : max(1, limit)
            end_line = effective_limit === nothing ? total_lines : min(start_line + effective_limit - 1, total_lines)
            selected = join(lines[start_line:end_line], "\n")
            truncation = truncate_head(selected)
            output = truncation.content
            if truncation.first_line_exceeds_limit
                line_size = format_size(ncodeunits(lines[start_line]))
                return "[Line $(start_line) is $(line_size), exceeds $(format_size(DEFAULT_MAX_BYTES)) limit. Use bash: sed -n '$(start_line)p' $(path) | head -c $(DEFAULT_MAX_BYTES)]"
            elseif truncation.truncated
                end_display = start_line + truncation.output_lines - 1
                next_offset = end_display + 1
                if truncation.truncated_by == :lines
                    output *= "\n\n[Showing lines $(start_line)-$(end_display) of $(total_lines). Use offset=$(next_offset) to continue]"
                else
                    output *= "\n\n[Showing lines $(start_line)-$(end_display) of $(total_lines) ($(format_size(DEFAULT_MAX_BYTES)) limit). Use offset=$(next_offset) to continue]"
                end
            elseif limit !== nothing && end_line < total_lines
                remaining = total_lines - end_line
                next_offset = end_line + 1
                output *= "\n\n[$(remaining) more lines in file. Use offset=$(next_offset) to continue]"
            end
            return output
        end,
    )
end


function create_write_tool(base_dir::AbstractString)
    base = ensure_base_dir(base_dir)
    return @tool(
        "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories.",
        write(path::String, content::String) = begin
            resolved = resolve_relative_path(base, path)
            mkpath(dirname(resolved))
            open(resolved, "w") do io
                Base.write(io, content)
            end
            return "Successfully wrote $(ncodeunits(content)) bytes to $(path)"
        end,
    )
end


function create_edit_tool(base_dir::AbstractString)
    base = ensure_base_dir(base_dir)
    return @tool(
        "Edit a file by replacing exact text. The oldText must match exactly (including whitespace). Use this for precise, surgical edits.",
        edit(path::String, oldText::String, newText::String) = begin
            resolved = resolve_relative_path(base, path)
            isfile(resolved) || throw(ArgumentError("file not found: $path"))
            content = read(resolved, String)
            occursin(oldText, content) || throw(ArgumentError("could not find the exact text in $(path)"))
            occurrences = length(findall(oldText, content))
            occurrences > 1 && throw(ArgumentError("found $(occurrences) occurrences in $(path); provide more context to make it unique"))
            idx = findfirst(oldText, content)
            idx === nothing && throw(ArgumentError("could not find the exact text in $(path)"))
            new_content = content[1:(idx.start - 1)] * newText * content[(idx.stop + 1):end]
            new_content == content && throw(ArgumentError("replacement produced identical content for $(path)"))
            open(resolved, "w") do io
                write(io, new_content)
            end
            return "Successfully replaced text in $(path). Changed $(ncodeunits(oldText)) bytes to $(ncodeunits(newText)) bytes."
        end,
    )
end


function create_ls_tool(base_dir::AbstractString)
    base = ensure_base_dir(base_dir)
    return @tool(
        "List directory contents. Returns entries sorted alphabetically, with '/' suffix for directories. Includes dotfiles. Output is truncated to 500 entries or 50KB (whichever is hit first).",
        ls(path::Union{Nothing, String}, limit::Union{Nothing, Int} = nothing) = begin
            dir_path = resolve_search_path(base, path)
            isdir(dir_path) || throw(ArgumentError("not a directory: $(path === nothing ? "." : path)"))
            entries = readdir(dir_path)
            sort!(entries, lt = (a, b) -> lowercase(a) < lowercase(b))
            effective_limit = limit === nothing ? DEFAULT_LS_LIMIT : max(1, limit)
            results = String[]
            entry_limit_reached = false
            for entry in entries
                if length(results) >= effective_limit
                    entry_limit_reached = true
                    break
                end
                full_path = joinpath(dir_path, entry)
                suffix = isdir(full_path) ? "/" : ""
                push!(results, entry * suffix)
            end
            isempty(results) && return "(empty directory)"
            raw_output = join(results, "\n")
            truncation = truncate_head(raw_output; max_lines = typemax(Int))
            output = truncation.content
            notices = String[]
            entry_limit_reached && push!(notices, "$(effective_limit) entries limit reached. Use limit=$(effective_limit * 2) for more")
            truncation.truncated && push!(notices, "$(format_size(DEFAULT_MAX_BYTES)) limit reached")
            if !isempty(notices)
                output *= "\n\n[$(join(notices, ". "))]"
            end
            return output
        end,
    )
end


function create_codex_tool()
    return @tool(
        "Run Codex CLI in exec mode on a directory. Prepends worktree requirements (default-branch checkout, create `/worktrees/<branch>`, work there, push, remove worktree). Research the package, evaluate the prompt, use the GitHub CLI tool to make code changes, commit to a branch, and push the branch (without opening a PR). Returns session_id, summary of work done, and branch name if created.",
        codex(prompt::String, directory::String, timeout::Union{Nothing, Int} = nothing) = begin
            isempty(prompt) && throw(ArgumentError("prompt is required"))
            isempty(directory) && throw(ArgumentError("directory is required"))
            isdir(directory) || throw(ArgumentError("directory not found: $(directory)"))
            codex_preamble = join(
                (
                    "Workflow requirements:",
                    "1) Identify the repo default branch (main/master) via `git symbolic-ref --short refs/remotes/origin/HEAD` (strip `origin/`; fallback to `git remote show origin`).",
                    "2) Check out the default branch in the main repo.",
                    "3) Create `/worktrees` if needed and add a worktree named after the new branch: `git worktree add -b <branch> /worktrees/<branch> <default-branch>`.",
                    "4) Do all work inside `/worktrees/<branch>`.",
                    "5) Push the branch to the remote, then remove the worktree: `git worktree remove /worktrees/<branch>`.",
                ), "\n"
            )
            full_prompt = codex_preamble * "\n\n" * prompt
            cmd_str = "codex exec --json --enable skills --yolo --cd $(shell_escape(directory)) --skip-git-repo-check $(shell_escape(full_prompt))"
            cmd = Cmd(`bash -lc $cmd_str`, ignorestatus = true)
            stderr_buf = IOBuffer()
            process = open(pipeline(cmd, stderr = stderr_buf))
            output_task = @async read(process, String)
            timed_out = false
            prompt_lower = lowercase(String(prompt))
            apply_timeout = timeout !== nothing && timeout > 0 && (occursin("timeout", prompt_lower) || occursin("time limit", prompt_lower) || occursin("time-limit", prompt_lower))
            if apply_timeout
                status = timedwait(() -> istaskdone(output_task), timeout)
                status == :timed_out && (
                    timed_out = true; try
                        Base.kill(process)
                    catch
                    end
                )
            end
            stdout_text = fetch(output_task)
            close(process)
            stderr_text = String(take!(stderr_buf))
            timed_out && error("Codex timed out after $(timeout) seconds")

            session_id = nothing
            agent_messages = String[]
            branch_name = nothing
            errors = String[]

            for line in split(stdout_text, "\n"; keepempty = false)
                try
                    parsed = JSON.parse(line)
                    event_type = get(() -> nothing, parsed, "type")
                    if event_type == "thread.started"
                        session_id = get(() -> nothing, parsed, "thread_id")
                        session_id !== nothing && (session_id = String(session_id))
                    elseif event_type == "item.completed"
                        item = get(() -> nothing, parsed, "item")
                        item isa AbstractDict || continue
                        item_type = get(() -> nothing, item, "type")
                        if item_type == "agent_message"
                            msg = get(() -> nothing, item, "text")
                            msg !== nothing && push!(agent_messages, String(msg))
                        elseif item_type == "command_execution"
                            cmd = get(() -> nothing, item, "command")
                            output = get(() -> "", item, "aggregated_output")
                            exit_code = get(() -> nothing, item, "exit_code")
                            if exit_code !== nothing && exit_code != 0
                                err = "Command failed: $(cmd)\nExit code: $(exit_code)\nOutput: $(output)"
                                push!(errors, err)
                            end
                        end
                    end
                catch
                end
            end

            !isempty(stderr_text) && push!(errors, "Codex stderr: $(stderr_text)")

            summary = join(agent_messages, "\n\n")
            summary = truncate_tool_output(summary; label = "Summary")
            if !isempty(errors)
                truncated_errors = String[]
                for err in errors
                    push!(truncated_errors, truncate_tool_output(String(err); label = "Error"))
                end
                errors = truncated_errors
            end
            result = Dict{String, Any}(
                "session_id" => session_id,
                "directory" => directory,
                "summary" => summary,
                "branch" => branch_name,
                "success" => isempty(errors),
            )
            !isempty(errors) && (result["errors"] = errors)
            return result
        end,
    )
end

function subagent_evaluate(child::Agent, input_message::String)
    return evaluate(child, input_message)
end

function create_subagent_tool(parent::Agent)
    return create_subagent_tool(() -> parent)
end

function create_subagent_tool(parent_provider::Function)
    return @tool(
        "Create and run a subagent with an independent prompt and input. Returns the subagent's response text. Useful for well-defined, isolatable tasks where the subagent can be specialized for the task and the parent agent can avoid unnecessary context pollution.",
        subagent(system_prompt::String, input_message::String) = begin
            parent_agent = parent_provider()
            parent_agent === nothing && throw(ArgumentError("parent agent not initialized for subagent"))
            child_tools = AgentTool[]
            allow_tools = get(ENV, "AGENTIF_SUBAGENT_ALLOW_TOOLS", "1") != "0"
            allow_nested = get(ENV, "AGENTIF_SUBAGENT_ALLOW_NESTED", "1") != "0"
            child_ref = Ref{Union{Nothing, Agent}}(nothing)
            if allow_tools
                for tool in parent_agent.tools
                    tool.name == "subagent" && continue
                    push!(child_tools, tool)
                end
                allow_nested && push!(child_tools, create_subagent_tool(() -> child_ref[]))
            end
            child = Agent(
                ; prompt = system_prompt,
                model = parent_agent.model,
                apikey = parent_agent.apikey,
                tools = child_tools,
            )
            allow_tools && allow_nested && (child_ref[] = child)
            result_state = subagent_evaluate(child, input_message)
            message = nothing
            for msg in reverse(result_state.messages)
                msg isa AssistantMessage || continue
                message = msg
                break
            end
            message === nothing && return ""
            output = string(message_text(message))
            return truncate_tool_output(output; label = "Subagent output")
        end,
    )
end

function create_find_tool(base_dir::AbstractString)
    base = ensure_base_dir(base_dir)
    return @tool(
        "Search for files by glob pattern. Returns matching file paths relative to the search directory. Output is truncated to 1000 results or 50KB (whichever is hit first).",
        find(pattern::String, path::Union{Nothing, String} = nothing, limit::Union{Nothing, Int} = nothing) = begin
            isempty(pattern) && throw(ArgumentError("pattern is required"))
            search_dir = resolve_search_path(base, path)
            isdir(search_dir) || throw(ArgumentError("not a directory: $(path === nothing ? "." : path)"))
            regex = glob_to_regex(pattern)
            effective_limit = limit === nothing ? DEFAULT_FIND_LIMIT : max(1, limit)
            results = String[]
            limit_reached = false
            for (root, dirs, files) in walkdir(search_dir)
                rel_root = relpath(root, search_dir)
                rel_root = rel_root == "." ? "" : normalize_relpath(rel_root)
                for dir in dirs
                    rel = rel_root == "" ? dir : "$(rel_root)/$(dir)"
                    if occursin(regex, rel)
                        push!(results, rel * "/")
                        if length(results) >= effective_limit
                            limit_reached = true
                            break
                        end
                    end
                end
                limit_reached && break
                for file in files
                    rel = rel_root == "" ? file : "$(rel_root)/$(file)"
                    if occursin(regex, rel)
                        push!(results, rel)
                        if length(results) >= effective_limit
                            limit_reached = true
                            break
                        end
                    end
                end
                limit_reached && break
            end
            isempty(results) && return "No files found matching pattern"
            raw_output = join(results, "\n")
            truncation = truncate_head(raw_output; max_lines = typemax(Int))
            output = truncation.content
            notices = String[]
            limit_reached && push!(notices, "$(effective_limit) results limit reached. Use limit=$(effective_limit * 2) for more, or refine pattern")
            truncation.truncated && push!(notices, "$(format_size(DEFAULT_MAX_BYTES)) limit reached")
            if !isempty(notices)
                output *= "\n\n[$(join(notices, ". "))]"
            end
            return output
        end,
    )
end


function create_grep_tool(base_dir::AbstractString)
    base = ensure_base_dir(base_dir)
    return @tool(
        "Search file contents for a pattern. Returns matching lines with file paths and line numbers. Output is truncated to 100 matches or 50KB (whichever is hit first). Long lines are truncated to 500 chars.",
        grep(
            pattern::String,
            path::Union{Nothing, String} = nothing,
            glob::Union{Nothing, String} = nothing,
            ignoreCase::Union{Nothing, Bool} = nothing,
            literal::Union{Nothing, Bool} = nothing,
            context::Union{Nothing, Int} = nothing,
            limit::Union{Nothing, Int} = nothing,
        ) = begin
            isempty(pattern) && throw(ArgumentError("pattern is required"))
            search_path = resolve_search_path(base, path)
            isdir(search_path) || isfile(search_path) || throw(ArgumentError("path not found: $(path === nothing ? "." : path)"))
            effective_limit = limit === nothing ? DEFAULT_GREP_LIMIT : max(1, limit)
            context_value = context === nothing ? 0 : max(0, context)
            glob_regex = glob === nothing ? nothing : glob_to_regex(glob)
            match_count = 0
            match_limit_reached = false
            lines_truncated = false
            output_lines = String[]
            search_root = isdir(search_path) ? search_path : dirname(search_path)
            file_list = isdir(search_path) ? collect(walkdir(search_path)) : [(search_root, String[], [basename(search_path)])]
            regex = nothing
            if literal !== true
                try
                    flags = ignoreCase === true ? "i" : ""
                    regex = Regex(pattern, flags)
                catch
                    throw(ArgumentError("invalid regex pattern"))
                end
            end
            for (root, _dirs, files) in file_list
                for file in files
                    file_path = joinpath(root, file)
                    rel_path = normalize_relpath(relpath(file_path, search_root))
                    glob_regex !== nothing && !occursin(glob_regex, rel_path) && continue
                    content = try
                        read(file_path, String)
                    catch
                        continue
                    end
                    occursin('\0', content) && continue
                    lines = split(content, "\n"; keepempty = true)
                    match_lines = Int[]
                    for (idx, line) in enumerate(lines)
                        is_match = if literal === true
                            if ignoreCase === true
                                occursin(lowercase(pattern), lowercase(line))
                            else
                                occursin(pattern, line)
                            end
                        else
                            regex !== nothing && occursin(regex, line)
                        end
                        if is_match
                            push!(match_lines, idx)
                            match_count += 1
                            if match_count >= effective_limit
                                match_limit_reached = true
                                break
                            end
                        end
                    end
                    isempty(match_lines) && continue
                    match_set = Set(match_lines)
                    last_printed = 0
                    for match_line in match_lines
                        start_line = max(1, match_line - context_value)
                        end_line = min(length(lines), match_line + context_value)
                        start_line = max(start_line, last_printed + 1)
                        for line_idx in start_line:end_line
                            line_text = lines[line_idx]
                            truncated = truncate_line(line_text)
                            truncated.was_truncated && (lines_truncated = true)
                            if line_idx in match_set
                                push!(output_lines, "$(rel_path):$(line_idx): $(truncated.text)")
                            else
                                push!(output_lines, "$(rel_path)-$(line_idx)- $(truncated.text)")
                            end
                        end
                        last_printed = max(last_printed, end_line)
                    end
                    match_limit_reached && break
                end
                match_limit_reached && break
            end
            isempty(output_lines) && return "No matches found"
            raw_output = join(output_lines, "\n")
            truncation = truncate_head(raw_output; max_lines = typemax(Int))
            output = truncation.content
            notices = String[]
            match_limit_reached && push!(notices, "$(effective_limit) matches limit reached. Use limit=$(effective_limit * 2) for more, or refine pattern")
            lines_truncated && push!(notices, "some lines were truncated")
            truncation.truncated && push!(notices, "$(format_size(DEFAULT_MAX_BYTES)) limit reached")
            if !isempty(notices)
                output *= "\n\n[$(join(notices, ". "))]"
            end
            return output
        end,
    )
end


function append_terminal_tools!(tools::Vector{AgentTool}, base_dir::AbstractString)
    append!(tools, create_terminal_tools(base_dir))
    return tools
end

function insert_terminal_tools!(tools::Dict{String, AgentTool}, base_dir::AbstractString)
    for tool in create_terminal_tools(base_dir)
        tools[tool.name] = tool
    end
    return tools
end

function coding_tools(base_dir::AbstractString = pwd())
    tools = AgentTool[
        create_read_tool(base_dir),
        create_edit_tool(base_dir),
        create_write_tool(base_dir),
    ]
    return append_terminal_tools!(tools, base_dir)
end

function read_only_tools(base_dir::AbstractString = pwd())
    return AgentTool[
        create_read_tool(base_dir),
        create_grep_tool(base_dir),
        create_find_tool(base_dir),
        create_ls_tool(base_dir),
    ]
end

function all_tools(base_dir::AbstractString = pwd(); parent::Union{Nothing, Agent, Function} = nothing, workers::Bool = false)
    tools = Dict(
        "read" => create_read_tool(base_dir),
        "edit" => create_edit_tool(base_dir),
        "write" => create_write_tool(base_dir),
        "grep" => create_grep_tool(base_dir),
        "find" => create_find_tool(base_dir),
        "ls" => create_ls_tool(base_dir),
        "codex" => create_codex_tool(),
    )
    parent !== nothing && (tools["subagent"] = create_subagent_tool(parent))
    insert_terminal_tools!(tools, base_dir)
    workers && insert_worker_tools!(tools)
    return tools
end

function append_worker_tools!(tools::Vector{AgentTool})
    append!(tools, create_worker_tools())
    return tools
end

function insert_worker_tools!(tools::Dict{String, AgentTool})
    for tool in create_worker_tools()
        tools[tool.name] = tool
    end
    return tools
end


#==============================================================================#
# Web Tools: web_fetch and web_search
#==============================================================================#

using HTTP

# Constants for web tools
const WEB_FETCH_CONNECT_TIMEOUT = 10  # seconds
const WEB_FETCH_READ_TIMEOUT = 30     # seconds
const WEB_FETCH_MAX_SIZE = 10 * 1024 * 1024  # 10MB max download
const WEB_FETCH_USER_AGENT = "Mozilla/5.0 (compatible; AgentifBot/1.0)"

# Thread-safe storage for temp files (maps file_id to path)
const WEB_TEMP_FILES = Dict{String, String}()
const WEB_TEMP_FILES_LOCK = ReentrantLock()

# Create a temp directory that persists for the session
const WEB_TEMP_DIR = Ref{Union{Nothing, String}}(nothing)

function get_web_temp_dir()
    return lock(WEB_TEMP_FILES_LOCK) do
        if WEB_TEMP_DIR[] === nothing || !isdir(WEB_TEMP_DIR[])
            WEB_TEMP_DIR[] = mktempdir(; cleanup = true)
        end
        return WEB_TEMP_DIR[]
    end
end

function register_temp_file(path::String)::String
    file_id = string(UUIDs.uuid4())[1:8]  # Short ID
    lock(WEB_TEMP_FILES_LOCK) do
        WEB_TEMP_FILES[file_id] = path
    end
    return file_id
end

function get_temp_file(file_id::String)::Union{Nothing, String}
    return lock(WEB_TEMP_FILES_LOCK) do
        get(WEB_TEMP_FILES, file_id, nothing)
    end
end

"""
    extract_text_from_html(html::String) -> String

Extract readable text from HTML, stripping tags and decoding entities.
Preserves basic structure with newlines for block elements.
"""
function extract_text_from_html(html::String)
    # Remove script and style blocks entirely
    text = replace(html, r"<script[^>]*>.*?</script>"si => "")
    text = replace(text, r"<style[^>]*>.*?</style>"si => "")
    text = replace(text, r"<!--.*?-->"s => "")

    # Add newlines before block elements
    block_tags = r"<(p|div|br|hr|h[1-6]|li|tr|td|th|blockquote|pre|section|article|header|footer|nav|aside)[^>]*>"i
    text = replace(text, block_tags => s"\n<\1>")

    # Strip all HTML tags
    text = replace(text, r"<[^>]+>" => "")

    # Decode common HTML entities
    entities = [
        "&nbsp;" => " ",
        "&amp;" => "&",
        "&lt;" => "<",
        "&gt;" => ">",
        "&quot;" => "\"",
        "&apos;" => "'",
        "&#39;" => "'",
        "&mdash;" => "—",
        "&ndash;" => "–",
        "&copy;" => "©",
        "&reg;" => "®",
        "&trade;" => "™",
        "&hellip;" => "…",
    ]
    for (entity, char) in entities
        text = replace(text, entity => char)
    end

    # Decode numeric entities (&#123; and &#x7B;)
    text = replace(text, r"&#(\d+);" => m -> string(Char(parse(Int, m.captures[1]))))
    text = replace(text, r"&#x([0-9a-fA-F]+);" => m -> string(Char(parse(Int, m.captures[1], base = 16))))

    # Normalize whitespace: collapse multiple spaces/newlines
    text = replace(text, r"[ \t]+" => " ")
    text = replace(text, r"\n[ \t]+" => "\n")
    text = replace(text, r"[ \t]+\n" => "\n")
    text = replace(text, r"\n{3,}" => "\n\n")

    return String(strip(text))
end

"""
    is_binary_content_type(content_type::String) -> Bool

Check if the content type indicates binary content.
"""
function is_binary_content_type(content_type::AbstractString)
    ct_lower = lowercase(content_type)
    # Text types we can handle
    text_patterns = [
        "text/",
        "application/json",
        "application/xml",
        "application/javascript",
        "application/x-javascript",
        "+json",
        "+xml",
    ]
    for pattern in text_patterns
        occursin(pattern, ct_lower) && return false
    end
    # Everything else is binary
    return true
end

"""
    parse_content_type(header::String) -> (mime_type::String, charset::Union{Nothing,String})

Parse Content-Type header into MIME type and charset.
"""
function parse_content_type(header::AbstractString)
    parts = split(header, ";")
    mime_type = strip(parts[1])
    charset = nothing
    for part in parts[2:end]
        kv = split(strip(part), "=", limit = 2)
        if length(kv) == 2 && lowercase(strip(kv[1])) == "charset"
            charset = strip(kv[2], ['"', '\'', ' '])
        end
    end
    return mime_type, charset
end

"""
    validate_url(url::String) -> String

Validate and normalize a URL. Throws ArgumentError for invalid URLs.
Returns the normalized URL.
"""
function validate_url(url::String)
    url = strip(url)
    isempty(url) && throw(ArgumentError("URL cannot be empty"))

    # Add https:// if no scheme
    if !startswith(url, "http://") && !startswith(url, "https://")
        url = "https://" * url
    end

    # Basic URL validation
    try
        uri = HTTP.URI(url)
        isempty(uri.host) && throw(ArgumentError("URL must have a host: $url"))
        return string(uri)
    catch e
        if e isa ArgumentError
            rethrow()
        end
        throw(ArgumentError("Invalid URL format: $url"))
    end
end

"""
    format_http_error(e::Exception, url::String) -> String

Format HTTP errors into user-friendly messages.
"""
function format_http_error(e::Exception, url::String)
    if e isa HTTP.ConnectError
        msg = string(e)
        if occursin("getaddrinfo", msg) || occursin("DNS", msg)
            return "DNS resolution failed for $(HTTP.URI(url).host). Check the hostname is correct."
        elseif occursin("Connection refused", msg)
            return "Connection refused by $(HTTP.URI(url).host). The server may be down or not accepting connections."
        elseif occursin("timed out", msg) || occursin("timeout", msg)
            return "Connection timed out to $(HTTP.URI(url).host). The server may be slow or unreachable."
        else
            return "Failed to connect to $(HTTP.URI(url).host): $(msg)"
        end
    elseif e isa HTTP.TimeoutError
        return "Request timed out after $(WEB_FETCH_READ_TIMEOUT) seconds. The server is too slow to respond."
    elseif e isa HTTP.StatusError
        status = e.status
        return "HTTP $(status) error from server"
    elseif occursin("SSL", string(typeof(e))) || occursin("ssl", lowercase(string(e))) || occursin("tls", lowercase(string(e)))
        msg = string(e)
        if occursin("certificate", lowercase(msg))
            return "SSL certificate error: The server's certificate could not be verified. This may indicate a security issue."
        else
            return "SSL/TLS error connecting to $(HTTP.URI(url).host): $(msg)"
        end
    else
        return "HTTP request failed: $(sprint(showerror, e))"
    end
end

function create_web_fetch_tool()
    return @tool(
        """Fetch content from a URL. Streams response to a temp file and returns truncated preview.

        Parameters:
        - url: The URL to fetch (required). Supports http:// and https://.
        - method: HTTP method (default: GET). Supports GET, POST, PUT, DELETE, HEAD, OPTIONS.
        - headers: JSON object of request headers (optional). Example: {"Authorization": "Bearer token"}
        - body: Request body for POST/PUT (optional).
        - extract_text: If true, strips HTML tags and returns readable text (default: false).
        - timeout: Request timeout in seconds (default: 30).
        - file_id: If provided, reads from a previously fetched file instead of making a new request.
        - offset: Line offset for reading (default: 1). Use with file_id to continue reading.

        Returns: Status code, content type, file location, and truncated content preview.""",
        web_fetch(
            url::String,
            method::String = "GET",
            headers::Union{Nothing, String} = nothing,
            body::Union{Nothing, String} = nothing,
            extract_text::Bool = false,
            timeout::Int = WEB_FETCH_READ_TIMEOUT,
            file_id::Union{Nothing, String} = nothing,
            offset::Union{Nothing, Int} = nothing
        ) = begin
            # If file_id is provided, read from existing temp file
            if file_id !== nothing
                return read_cached_web_content(file_id, offset, extract_text)
            end

            # Validate URL
            url = validate_url(url)

            # Validate method
            method = uppercase(strip(method))
            valid_methods = ["GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH"]
            method in valid_methods || throw(ArgumentError("Invalid HTTP method: $method. Use one of: $(join(valid_methods, ", "))"))

            # Parse headers if provided
            request_headers = [
                "User-Agent" => WEB_FETCH_USER_AGENT,
                "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language" => "en-US,en;q=0.5",
            ]
            if headers !== nothing
                try
                    parsed = JSON.parse(headers)
                    # JSON.Object acts like a Dict but isn't a subtype
                    if !(parsed isa AbstractDict || hasmethod(keys, (typeof(parsed),)))
                        throw(ArgumentError("headers must be a JSON object, got $(typeof(parsed))"))
                    end
                    for (k, v) in pairs(parsed)
                        push!(request_headers, string(k) => string(v))
                    end
                catch e
                    if e isa ArgumentError
                        rethrow()
                    end
                    throw(ArgumentError("Invalid headers JSON: $(sprint(showerror, e))"))
                end
            end

            # Create temp file for response
            temp_dir = get_web_temp_dir()
            temp_file = joinpath(temp_dir, "fetch_" * string(UUIDs.uuid4())[1:8] * ".txt")

            # Make the request
            response = nothing
            final_url = url
            status_code = 0
            content_type = "unknown"
            content_length = 0
            is_binary = false
            error_message = nothing

            try
                # Build request kwargs
                request_kw = (;
                    headers = request_headers,
                    connect_timeout = WEB_FETCH_CONNECT_TIMEOUT,
                    readtimeout = timeout,
                    retry = true,
                    retries = 2,
                    redirect = true,
                    redirect_limit = 5,
                    status_exception = false,  # Don't throw on 4xx/5xx
                )

                if body !== nothing && method in ["POST", "PUT", "PATCH"]
                    response = HTTP.request(method, url, request_headers, body; request_kw...)
                else
                    response = HTTP.request(method, url; request_kw...)
                end

                status_code = response.status
                final_url = string(response.request.target)

                # Get content type
                ct_header = HTTP.header(response, "Content-Type", "application/octet-stream")
                content_type, charset = parse_content_type(ct_header)
                is_binary = is_binary_content_type(content_type)

                # Get content length if available
                cl_header = HTTP.header(response, "Content-Length", "")
                if !isempty(cl_header)
                    content_length = tryparse(Int, cl_header)
                    if content_length !== nothing && content_length > WEB_FETCH_MAX_SIZE
                        throw(ArgumentError("Response too large: $(format_size(content_length)). Maximum is $(format_size(WEB_FETCH_MAX_SIZE))."))
                    end
                end

                # Write response body to temp file
                response_body = response.body
                actual_size = length(response_body)

                if actual_size > WEB_FETCH_MAX_SIZE
                    # Truncate to max size
                    response_body = response_body[1:WEB_FETCH_MAX_SIZE]
                end

                content_length = actual_size

                # Convert to string if text content
                if !is_binary
                    # Try to decode with detected charset, fallback to UTF-8
                    try
                        body_str = String(copy(response_body))
                        open(temp_file, "w") do io
                            write(io, body_str)
                        end
                    catch
                        # Binary fallback - write raw bytes
                        is_binary = true
                        open(temp_file, "w") do io
                            write(io, response_body)
                        end
                    end
                else
                    open(temp_file, "w") do io
                        write(io, response_body)
                    end
                end

            catch e
                error_message = format_http_error(e, url)
                # Clean up temp file if created
                isfile(temp_file) && rm(temp_file; force = true)
            end

            # Handle errors
            if error_message !== nothing
                return """
                Fetch failed: $url

                Error: $error_message

                Troubleshooting:
                - Check the URL is correct and accessible
                - Try a different URL or check if the site is up
                - For HTTPS issues, the site may have certificate problems"""
            end

            # Register the temp file
            new_file_id = register_temp_file(temp_file)

            # Build response
            output = IOBuffer()

            # Status line
            status_text = status_code >= 400 ? " (Error)" : ""
            println(output, "Fetched: $url")
            final_url != url && println(output, "Redirected to: $final_url")
            println(output, "Status: $status_code$status_text")
            println(output, "Content-Type: $content_type")
            println(output, "Size: $(format_size(content_length))")
            println(output, "Saved to: file_id=\"$new_file_id\"")
            println(output)

            # Content preview
            if is_binary
                println(output, "[Binary content - use file_id to access raw data]")
            else
                # Read and optionally extract text
                raw_content = read(temp_file, String)

                if extract_text && (occursin("text/html", lowercase(content_type)) || occursin("application/xhtml", lowercase(content_type)))
                    display_content = extract_text_from_html(raw_content)
                else
                    display_content = raw_content
                end

                # Truncate for display
                lines = split(display_content, "\n"; keepempty = true)
                total_lines = length(lines)
                start_line = offset === nothing ? 1 : max(1, offset)

                if start_line > total_lines
                    println(output, "[No content at offset $start_line - file has $total_lines lines]")
                else
                    truncation = truncate_head(display_content)

                    println(output, "--- Content Preview ---")
                    println(output, truncation.content)

                    if truncation.truncated
                        end_line = truncation.output_lines
                        next_offset = end_line + 1
                        println(output)
                        println(output, "[Showing lines 1-$end_line of $total_lines. Use file_id=\"$new_file_id\" offset=$next_offset to continue]")
                    end
                end
            end

            return String(take!(output))
        end,
    )
end

"""
Read content from a previously fetched file.
"""
function read_cached_web_content(file_id::String, offset::Union{Nothing, Int}, extract_text::Bool)
    path = get_temp_file(file_id)
    path === nothing && throw(ArgumentError("Unknown file_id: $file_id. The file may have been cleaned up."))
    !isfile(path) && throw(ArgumentError("Cached file no longer exists for file_id: $file_id"))

    content = read(path, String)

    # Optionally extract text (guess HTML from content)
    if extract_text && (startswith(strip(content), "<") || occursin("<!DOCTYPE", content))
        content = extract_text_from_html(content)
    end

    lines = split(content, "\n"; keepempty = true)
    total_lines = length(lines)
    start_line = offset === nothing ? 1 : max(1, offset)

    start_line > total_lines && throw(ArgumentError("offset $offset is beyond end of file ($total_lines lines total)"))

    # Select lines from offset
    selected = join(lines[start_line:end], "\n")
    truncation = truncate_head(selected)

    output = IOBuffer()
    println(output, "Reading file_id=\"$file_id\" from line $start_line:")
    println(output)
    println(output, truncation.content)

    if truncation.truncated
        end_line = start_line + truncation.output_lines - 1
        next_offset = end_line + 1
        println(output)
        println(output, "[Showing lines $start_line-$end_line of $total_lines. Use file_id=\"$file_id\" offset=$next_offset to continue]")
    elseif start_line > 1
        println(output)
        println(output, "[Showing lines $start_line-$total_lines of $total_lines (end of file)]")
    end

    return String(take!(output))
end


#==============================================================================#
# Web Search Tool
#==============================================================================#

const SEARCH_MAX_RESULTS = 20

"""
Parse DuckDuckGo HTML search results from html.duckduckgo.com.
Returns a vector of (title, url, snippet) tuples.
Filters out ads (URLs containing duckduckgo.com/y.js).
"""
function parse_duckduckgo_html_results(html::String)
    results = Tuple{String, String, String}[]

    # Find result__a links (title + URL)
    result_links = collect(eachmatch(r"class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>([^<]+)</a>"si, html))

    # Find result__snippet elements
    snippets = collect(eachmatch(r"class=\"result__snippet\"[^>]*>([^<]*(?:<[^>]+>[^<]*)*)</a>"si, html))

    for (i, link_match) in enumerate(result_links)
        url = String(link_match.captures[1])
        title = String(link_match.captures[2])

        # Skip ads (DDG ad URLs contain /y.js or go through duckduckgo.com redirect)
        occursin("duckduckgo.com/y.js", url) && continue
        occursin("/y.js?", url) && continue

        # Decode HTML entities in URL
        url = replace(url, "&amp;" => "&")

        # Clean title
        title = strip(replace(title, r"\s+" => " "))

        # Get snippet if available
        snippet = ""
        if i <= length(snippets)
            raw_snippet = snippets[i].captures[1]
            snippet = replace(raw_snippet, r"<[^>]+>" => "")  # Strip HTML tags
            snippet = strip(replace(snippet, r"\s+" => " "))
        end

        push!(results, (title, url, snippet))
    end

    return results
end

"""
Parse DuckDuckGo HTML search results (legacy parser).
Returns a vector of (title, url, snippet) tuples.
"""
function parse_duckduckgo_results(html::String)
    results = Tuple{String, String, String}[]

    # DuckDuckGo uses class="result" for each result
    # This is a simplified parser - DDG's HTML structure can vary
    result_blocks = eachmatch(r"<div[^>]*class=\"[^\"]*result[^\"]*\"[^>]*>(.*?)</div>\s*(?=<div[^>]*class=\"[^\"]*result|$)"si, html)

    for m in result_blocks
        block = m.captures[1]

        # Extract title and URL from the result link
        title_match = match(r"<a[^>]*class=\"[^\"]*result__a[^\"]*\"[^>]*href=\"([^\"]+)\"[^>]*>([^<]*(?:<[^>]+>[^<]*)*)</a>"si, block)
        if title_match === nothing
            # Alternative pattern
            title_match = match(r"<a[^>]*href=\"([^\"]+)\"[^>]*class=\"[^\"]*result[^\"]*\"[^>]*>([^<]*(?:<[^>]+>[^<]*)*)</a>"si, block)
        end

        title_match === nothing && continue

        url = title_match.captures[1]
        title = replace(title_match.captures[2], r"<[^>]+>" => "")  # Strip HTML tags

        # Skip DDG internal links
        startswith(url, "/") && continue
        occursin("duckduckgo.com", url) && continue

        # Extract snippet
        snippet = ""
        snippet_match = match(r"<a[^>]*class=\"[^\"]*result__snippet[^\"]*\"[^>]*>([^<]*(?:<[^>]+>[^<]*)*)</a>"si, block)
        if snippet_match !== nothing
            snippet = replace(snippet_match.captures[1], r"<[^>]+>" => "")
        end

        # Clean up text
        title = strip(replace(title, r"\s+" => " "))
        snippet = strip(replace(snippet, r"\s+" => " "))

        # Decode URL if needed (DDG sometimes encodes URLs)
        if startswith(url, "//duckduckgo.com/l/?uddg=")
            # Extract actual URL from DDG redirect
            url_match = match(r"uddg=([^&]+)", url)
            if url_match !== nothing
                url = HTTP.unescapeuri(url_match.captures[1])
            end
        end

        push!(results, (title, url, snippet))
    end

    return results
end

"""
Parse DuckDuckGo Lite results (simpler HTML structure).
Returns a vector of (title, url, snippet) tuples.

DDG Lite uses class='result-link' for links and class='result-snippet' for descriptions.
URLs are wrapped in DDG redirects like //duckduckgo.com/l/?uddg=<encoded_url>&...
"""
function parse_duckduckgo_lite_results(html::String)
    results = Tuple{String, String, String}[]

    # Match link+snippet as unified blocks to ensure proper alignment
    # Pattern: href="..." class='result-link'>Title</a> ... class='result-snippet'>Snippet</td>
    block_pattern = r"<a[^>]*href=\"([^\"]+)\"[^>]*class=['\"]result-link['\"][^>]*>([^<]+)</a>.*?class=['\"]result-snippet['\"][^>]*>\s*(.*?)\s*</td>"s

    blocks = collect(eachmatch(block_pattern, html))

    for block_match in blocks
        raw_url = strip(block_match.captures[1])
        title = strip(block_match.captures[2])
        raw_snippet = block_match.captures[3]

        # Skip ads - they use y.js or have ad_ parameters in the redirect URL
        if occursin("/y.js", raw_url) || occursin("ad_provider", raw_url) || occursin("ad_domain", raw_url)
            continue
        end

        # Skip "more info" links about DDG ads
        if title == "more info" && occursin("duckduckgo-help-pages", raw_url)
            continue
        end

        # Extract actual URL from DDG redirect
        # Format: //duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com&rut=...
        url = raw_url
        if occursin("uddg=", raw_url)
            uddg_match = match(r"uddg=([^&]+)", raw_url)
            if uddg_match !== nothing
                url = HTTP.unescapeuri(uddg_match.captures[1])
            end
        elseif startswith(raw_url, "//")
            # Handle protocol-relative URLs
            url = "https:" * raw_url
        end

        # Skip internal DDG links that didn't have uddg parameter
        if occursin("duckduckgo.com", url) && !occursin("uddg=", raw_url)
            continue
        end

        # Clean title - decode HTML entities
        title = replace(title, "&amp;" => "&")
        title = replace(title, "&lt;" => "<")
        title = replace(title, "&gt;" => ">")
        title = replace(title, "&quot;" => "\"")
        title = replace(title, "&#39;" => "'")

        # Clean snippet - strip HTML tags and decode entities
        snippet = replace(raw_snippet, r"<[^>]+>" => "")
        snippet = replace(snippet, "&amp;" => "&")
        snippet = replace(snippet, "&lt;" => "<")
        snippet = replace(snippet, "&gt;" => ">")
        snippet = replace(snippet, "&nbsp;" => " ")
        snippet = replace(snippet, "&#x27;" => "'")
        snippet = replace(snippet, "&quot;" => "\"")
        snippet = strip(replace(snippet, r"\s+" => " "))

        push!(results, (title, url, snippet))
    end

    return results
end

function create_web_search_tool()
    return @tool(
        """Search the web using DuckDuckGo. Returns a list of search results with titles, URLs, and snippets.

        Parameters:
        - query: The search query (required).
        - num_results: Maximum number of results to return (default: 10, max: 20).
        - timeout: Request timeout in seconds (default: 30).

        Returns: List of search results with title, URL, and description snippet.""",
        web_search(
            query::String,
            num_results::Int = 10,
            timeout::Int = WEB_FETCH_READ_TIMEOUT
        ) = begin
            query = strip(query)
            isempty(query) && throw(ArgumentError("Search query cannot be empty"))

            num_results = clamp(num_results, 1, SEARCH_MAX_RESULTS)
            timeout_s = max(1, timeout)

            # Use DuckDuckGo Lite - more reliable than html.duckduckgo.com
            # which returns 202 bot detection responses
            search_url = "https://lite.duckduckgo.com/lite/?q=" * HTTP.escapeuri(query)

            request_headers = [
                # Use a realistic browser User-Agent
                "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language" => "en-US,en;q=0.5",
            ]

            response = nothing
            error_message = nothing

            # Retry logic for transient errors
            max_retries = 3
            base_delay = 1.0  # seconds

            for attempt in 1:max_retries
                try
                    response = HTTP.get(
                        search_url,
                        request_headers;
                        connect_timeout = WEB_FETCH_CONNECT_TIMEOUT,
                        readtimeout = timeout_s,
                        redirect = true,
                        status_exception = false,
                    )

                    # If we got 200, we're done
                    if response.status == 200
                        error_message = nothing
                        break
                    end

                    # Retry on 5xx errors or rate limiting
                    if (response.status >= 500 || response.status == 202 || response.status == 429) && attempt < max_retries
                        delay = base_delay * (2.0^(attempt - 1)) * (0.8 + 0.4 * rand())
                        sleep(delay)
                        continue
                    end

                    # For other non-200 statuses, don't retry
                    break
                catch e
                    error_message = format_http_error(e, search_url)
                    if attempt < max_retries
                        delay = base_delay * (2.0^(attempt - 1)) * (0.8 + 0.4 * rand())
                        sleep(delay)
                        continue
                    end
                end
            end

            if error_message !== nothing
                return """
                Search failed for: "$query"

                Error: $error_message

                Try:
                - Check your internet connection
                - Simplify the search query
                - Try again in a moment"""
            end

            if response === nothing || response.status != 200
                status_code = response === nothing ? "unknown" : string(response.status)
                return "Search returned HTTP $status_code. The search service may be temporarily unavailable."
            end

            html = String(response.body)
            results = parse_duckduckgo_lite_results(html)

            if isempty(results)
                return """
                No results found for: "$query"

                Try:
                - Using different keywords
                - Checking spelling
                - Using more general terms"""
            end

            # Limit results
            results = results[1:min(length(results), num_results)]

            # Format output
            output = IOBuffer()
            println(output, "Search results for: \"$query\"")
            println(output, "Found $(length(results)) results")
            println(output)

            for (i, (title, url, snippet)) in enumerate(results)
                println(output, "$i. $title")
                println(output, "   URL: $url")
                if !isempty(snippet)
                    # Truncate long snippets
                    if length(snippet) > 200
                        snippet = snippet[1:197] * "..."
                    end
                    println(output, "   $snippet")
                end
                println(output)
            end

            println(output, "[Use web_fetch(url) to get the full content of any result]")

            return String(take!(output))
        end,
    )
end


"""
    web_tools() -> Vector{AgentTool}

Returns both web_fetch and web_search tools.
"""
function web_tools()
    return [create_web_fetch_tool(), create_web_search_tool()]
end
