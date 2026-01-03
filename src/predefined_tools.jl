const DEFAULT_MAX_LINES = 2000
const DEFAULT_MAX_BYTES = 50 * 1024
const GREP_MAX_LINE_LENGTH = 500
const DEFAULT_LS_LIMIT = 500
const DEFAULT_FIND_LIMIT = 1000
const DEFAULT_GREP_LIMIT = 100

struct TruncationResult
    content::String
    truncated::Bool
    truncated_by::Union{Nothing,Symbol}
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
        return "$(round(bytes / 1024; digits=1))KB"
    end
    return "$(round(bytes / (1024 * 1024); digits=1))MB"
end

function truncate_head(content::String; max_lines::Int = DEFAULT_MAX_LINES, max_bytes::Int = DEFAULT_MAX_BYTES)
    total_bytes = ncodeunits(content)
    lines = split(content, "\n"; keepempty=true)
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
    lines = split(content, "\n"; keepempty=true)
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

function truncate_string_to_bytes_from_end(text::String, max_bytes::Int)
    bytes = Vector{UInt8}(codeunits(text))
    length(bytes) <= max_bytes && return text
    start = length(bytes) - max_bytes + 1
    while start <= length(bytes) && (bytes[start] & 0xc0) == 0x80
        start += 1
    end
    return String(bytes[start:end])
end

function truncate_line(line::String; max_chars::Int = GREP_MAX_LINE_LENGTH)
    length(line) <= max_chars && return (text=line, was_truncated=false)
    return (text=first(line, max_chars) * " [truncated]", was_truncated=true)
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

function resolve_search_path(base_dir::AbstractString, path::Union{Nothing,String})
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

struct DockerExecResult
    stdout::String
    stderr::String
    exitcode::Int
    timed_out::Bool
end

function shell_escape(text::AbstractString)
    return "'" * replace(text, "'" => raw"'\''") * "'"
end

function ensure_container_name(container::AbstractString)
    isempty(container) && throw(ArgumentError("container name is required"))
    return container
end

function ensure_container_base_dir(base_dir::AbstractString)
    isempty(base_dir) && throw(ArgumentError("base directory is required"))
    startswith(base_dir, "~") && throw(ArgumentError("home paths are not allowed: $base_dir"))
    isabspath(base_dir) || throw(ArgumentError("base directory must be absolute: $base_dir"))
    return base_dir
end

function docker_exec(container::AbstractString, command::AbstractString; timeout::Union{Nothing,Int} = nothing)
    cmd = Cmd(`docker exec $container sh -c $command`, ignorestatus=true)
    stderr_buf = IOBuffer()
    process = open(pipeline(cmd, stderr=stderr_buf))
    output_task = @async read(process, String)
    timed_out = false
    if timeout !== nothing && timeout > 0
        status = timedwait(() -> istaskdone(output_task), timeout)
        if status == :timed_out
            timed_out = true
            try
                Base.kill(process)
            catch
            end
        end
    end
    stdout_text = fetch(output_task)
    close(process)
    stderr_text = String(take!(stderr_buf))
    return DockerExecResult(stdout_text, stderr_text, process.exitcode, timed_out)
end

function docker_exec_in_dir(container::AbstractString, base_dir::AbstractString, command::AbstractString; timeout::Union{Nothing,Int} = nothing)
    full_command = "cd $(shell_escape(base_dir)) && $command"
    return docker_exec(container, full_command; timeout)
end

function container_is_dir(container::AbstractString, path::AbstractString)
    result = docker_exec(container, "test -d $(shell_escape(path))")
    result.exitcode != 0 && !isempty(result.stderr) && error(strip(result.stderr))
    return result.exitcode == 0
end

function container_is_file(container::AbstractString, path::AbstractString)
    result = docker_exec(container, "test -f $(shell_escape(path))")
    result.exitcode != 0 && !isempty(result.stderr) && error(strip(result.stderr))
    return result.exitcode == 0
end

function strip_dir_suffix(entry::String)
    endswith(entry, "/") ? entry[1:end-1] : entry
end

function create_bash_tool(base_dir::AbstractString)
    base = ensure_base_dir(base_dir)
    return @tool(
        "Execute a bash command in the base directory. Returns stdout and stderr. Output is truncated to last 2000 lines or 50KB (whichever is hit first). Optionally provide a timeout in seconds.",
        bash(command::String, timeout::Union{Nothing,Int}) = begin
            command_has_absolute_path(command) && throw(ArgumentError("absolute paths are not allowed in bash commands"))
            cmd = Cmd(`bash -lc $command`, dir=base, ignorestatus=true)
            stderr_buf = IOBuffer()
            process = open(pipeline(cmd, stderr=stderr_buf))
            output_task = @async read(process, String)
            timed_out = false
            if timeout !== nothing && timeout > 0
                status = timedwait(() -> istaskdone(output_task), timeout)
                if status == :timed_out
                    timed_out = true
                    try
                        Base.kill(process)
                    catch
                    end
                end
            end
            stdout_text = fetch(output_task)
            close(process)
            stderr_text = String(take!(stderr_buf))
            combined = stdout_text
            if !isempty(stderr_text)
                combined = isempty(combined) ? stderr_text : combined * "\n" * stderr_text
            end
            truncation = truncate_tail(combined)
            output = truncation.content
            if truncation.truncated
                start_line = truncation.total_lines - truncation.output_lines + 1
                end_line = truncation.total_lines
                if truncation.last_line_partial
                    combined_lines = split(combined, "\n"; keepempty=true)
                    last_line_size = format_size(ncodeunits(combined_lines[end]))
                    output *= "\n\n[Showing last $(format_size(truncation.output_bytes)) of line $(end_line) ($(last_line_size)).]"
                elseif truncation.truncated_by == :lines
                    output *= "\n\n[Showing lines $(start_line)-$(end_line) of $(truncation.total_lines).]"
                else
                    output *= "\n\n[Showing lines $(start_line)-$(end_line) of $(truncation.total_lines) ($(format_size(DEFAULT_MAX_BYTES)) limit).]"
                end
            end
            if timed_out
                message = isempty(output) ? "(no output)" : output
                error(message * "\n\nCommand timed out after $(timeout) seconds.")
            end
            if process.exitcode != 0
                message = isempty(output) ? "(no output)" : output
                error(message * "\n\nCommand exited with code $(process.exitcode).")
            end
            return isempty(output) ? "(no output)" : output
        end,
    )
end

function create_sandboxed_bash_tool(container::AbstractString, base_dir::AbstractString)
    container_name = ensure_container_name(container)
    base = ensure_container_base_dir(base_dir)
    return @tool(
        "Execute a bash command in the container base directory. Returns stdout and stderr. Output is truncated to last 2000 lines or 50KB (whichever is hit first). Optionally provide a timeout in seconds.",
        bash(command::String, timeout::Union{Nothing,Int}) = begin
            command_has_absolute_path(command) && throw(ArgumentError("absolute paths are not allowed in bash commands"))
            result = docker_exec_in_dir(container_name, base, command; timeout)
            combined = result.stdout
            if !isempty(result.stderr)
                combined = isempty(combined) ? result.stderr : combined * "\n" * result.stderr
            end
            truncation = truncate_tail(combined)
            output = truncation.content
            if truncation.truncated
                start_line = truncation.total_lines - truncation.output_lines + 1
                end_line = truncation.total_lines
                if truncation.last_line_partial
                    combined_lines = split(combined, "\n"; keepempty=true)
                    last_line_size = format_size(ncodeunits(combined_lines[end]))
                    output *= "\n\n[Showing last $(format_size(truncation.output_bytes)) of line $(end_line) ($(last_line_size)).]"
                elseif truncation.truncated_by == :lines
                    output *= "\n\n[Showing lines $(start_line)-$(end_line) of $(truncation.total_lines).]"
                else
                    output *= "\n\n[Showing lines $(start_line)-$(end_line) of $(truncation.total_lines) ($(format_size(DEFAULT_MAX_BYTES)) limit).]"
                end
            end
            if result.timed_out
                message = isempty(output) ? "(no output)" : output
                error(message * "\n\nCommand timed out after $(timeout) seconds.")
            end
            if result.exitcode != 0
                message = isempty(output) ? "(no output)" : output
                error(message * "\n\nCommand exited with code $(result.exitcode).")
            end
            return isempty(output) ? "(no output)" : output
        end,
    )
end

function create_read_tool(base_dir::AbstractString)
    base = ensure_base_dir(base_dir)
    return @tool(
        "Read the contents of a file. Output is truncated to 2000 lines or 50KB (whichever is hit first). Use offset and limit for large files.",
        read(path::String, offset::Union{Nothing,Int}, limit::Union{Nothing,Int}) = begin
            resolved = resolve_relative_path(base, path)
            isfile(resolved) || throw(ArgumentError("file not found: $path"))
            content = Base.read(resolved, String)
            lines = split(content, "\n"; keepempty=true)
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

function create_sandboxed_read_tool(container::AbstractString, base_dir::AbstractString)
    container_name = ensure_container_name(container)
    base = ensure_container_base_dir(base_dir)
    return @tool(
        "Read the contents of a file in the container. Output is truncated to 2000 lines or 50KB (whichever is hit first). Use offset and limit for large files.",
        read(path::String, offset::Union{Nothing,Int}, limit::Union{Nothing,Int}) = begin
            resolved = resolve_relative_path(base, path)
            container_is_file(container_name, resolved) || throw(ArgumentError("file not found: $path"))
            count_result = docker_exec(container_name, "wc -l < $(shell_escape(resolved))")
            count_result.exitcode != 0 && error(isempty(count_result.stderr) ? "failed to read file: $path" : strip(count_result.stderr))
            total_lines = parse(Int, strip(count_result.stdout)) + 1
            start_line = offset === nothing ? 1 : max(1, offset)
            start_line > total_lines && throw(ArgumentError("offset $(offset) is beyond end of file ($(total_lines) lines total)"))
            effective_limit = limit === nothing ? nothing : max(1, limit)
            end_line = effective_limit === nothing ? total_lines : min(start_line + effective_limit - 1, total_lines)
            cmd = if start_line == 1
                "cat $(shell_escape(resolved))"
            else
                "tail -n +$(start_line) $(shell_escape(resolved))"
            end
            read_result = docker_exec(container_name, cmd)
            read_result.exitcode != 0 && error(isempty(read_result.stderr) ? "failed to read file: $path" : strip(read_result.stderr))
            selected = read_result.stdout
            if effective_limit !== nothing
                lines = split(selected, "\n"; keepempty=true)
                selected = join(lines[1:min(effective_limit, length(lines))], "\n")
            end
            truncation = truncate_head(selected)
            output = truncation.content
            if truncation.first_line_exceeds_limit
                line_size = format_size(ncodeunits(split(selected, "\n"; keepempty=true)[1]))
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

function create_sandboxed_write_tool(container::AbstractString, base_dir::AbstractString)
    container_name = ensure_container_name(container)
    base = ensure_container_base_dir(base_dir)
    return @tool(
        "Write content to a file in the container. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories.",
        write(path::String, content::String) = begin
            resolved = resolve_relative_path(base, path)
            dir_path = dirname(resolved)
            cmd = "mkdir -p $(shell_escape(dir_path)) && printf '%s' $(shell_escape(content)) > $(shell_escape(resolved))"
            result = docker_exec(container_name, cmd)
            result.exitcode != 0 && error(isempty(result.stderr) ? "failed to write file: $path" : strip(result.stderr))
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
            new_content = content[1:idx.start-1] * newText * content[idx.stop+1:end]
            new_content == content && throw(ArgumentError("replacement produced identical content for $(path)"))
            open(resolved, "w") do io
                write(io, new_content)
            end
            return "Successfully replaced text in $(path). Changed $(ncodeunits(oldText)) bytes to $(ncodeunits(newText)) bytes."
        end,
    )
end

function create_sandboxed_edit_tool(container::AbstractString, base_dir::AbstractString)
    container_name = ensure_container_name(container)
    base = ensure_container_base_dir(base_dir)
    return @tool(
        "Edit a file in the container by replacing exact text. The oldText must match exactly (including whitespace). Use this for precise, surgical edits.",
        edit(path::String, oldText::String, newText::String) = begin
            resolved = resolve_relative_path(base, path)
            container_is_file(container_name, resolved) || throw(ArgumentError("file not found: $path"))
            read_result = docker_exec(container_name, "cat $(shell_escape(resolved))")
            read_result.exitcode != 0 && error(isempty(read_result.stderr) ? "failed to read file: $path" : strip(read_result.stderr))
            content = read_result.stdout
            occursin(oldText, content) || throw(ArgumentError("could not find the exact text in $(path)"))
            occurrences = length(findall(oldText, content))
            occurrences > 1 && throw(ArgumentError("found $(occurrences) occurrences in $(path); provide more context to make it unique"))
            idx = findfirst(oldText, content)
            idx === nothing && throw(ArgumentError("could not find the exact text in $(path)"))
            new_content = content[1:idx.start-1] * newText * content[idx.stop+1:end]
            new_content == content && throw(ArgumentError("replacement produced identical content for $(path)"))
            write_result = docker_exec(container_name, "printf '%s' $(shell_escape(new_content)) > $(shell_escape(resolved))")
            write_result.exitcode != 0 && error(isempty(write_result.stderr) ? "failed to write file: $path" : strip(write_result.stderr))
            return "Successfully replaced text in $(path). Changed $(ncodeunits(oldText)) bytes to $(ncodeunits(newText)) bytes."
        end,
    )
end

function create_ls_tool(base_dir::AbstractString)
    base = ensure_base_dir(base_dir)
    return @tool(
        "List directory contents. Returns entries sorted alphabetically, with '/' suffix for directories. Includes dotfiles. Output is truncated to 500 entries or 50KB (whichever is hit first).",
        ls(path::Union{Nothing,String}, limit::Union{Nothing,Int}) = begin
            dir_path = resolve_search_path(base, path)
            isdir(dir_path) || throw(ArgumentError("not a directory: $(path === nothing ? "." : path)"))
            entries = readdir(dir_path)
            sort!(entries, lt=(a, b) -> lowercase(a) < lowercase(b))
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
            truncation = truncate_head(raw_output; max_lines=typemax(Int))
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

function create_sandboxed_ls_tool(container::AbstractString, base_dir::AbstractString)
    container_name = ensure_container_name(container)
    base = ensure_container_base_dir(base_dir)
    return @tool(
        "List directory contents in the container. Returns entries sorted alphabetically, with '/' suffix for directories. Includes dotfiles. Output is truncated to 500 entries or 50KB (whichever is hit first).",
        ls(path::Union{Nothing,String}, limit::Union{Nothing,Int}) = begin
            dir_path = resolve_search_path(base, path)
            container_is_dir(container_name, dir_path) || throw(ArgumentError("not a directory: $(path === nothing ? "." : path)"))
            result = docker_exec(container_name, "ls -ap $(shell_escape(dir_path))")
            result.exitcode != 0 && error(isempty(result.stderr) ? "failed to list directory: $(path === nothing ? "." : path)" : strip(result.stderr))
            entries = split(result.stdout, "\n"; keepempty=false)
            filter!(entry -> !(entry in (".", "..", "./", "../")), entries)
            isempty(entries) && return "(empty directory)"
            sort!(entries, by=entry -> lowercase(strip_dir_suffix(entry)))
            effective_limit = limit === nothing ? DEFAULT_LS_LIMIT : max(1, limit)
            results = String[]
            entry_limit_reached = false
            for entry in entries
                if length(results) >= effective_limit
                    entry_limit_reached = true
                    break
                end
                push!(results, entry)
            end
            raw_output = join(results, "\n")
            truncation = truncate_head(raw_output; max_lines=typemax(Int))
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
        "Run Codex CLI in exec mode on a directory. Research the package, evaluate the prompt, use the GitHub CLI tool to make code changes, commit to a branch, and push the branch (without opening a PR). Returns session_id, summary of work done, and branch name if created.",
        codex(prompt::String, directory::String, timeout::Union{Nothing,Int}) = begin
            isempty(prompt) && throw(ArgumentError("prompt is required"))
            isempty(directory) && throw(ArgumentError("directory is required"))
            isdir(directory) || throw(ArgumentError("directory not found: $(directory)"))

            cmd_str = "codex exec --json --enable skills --yolo --cd $(shell_escape(directory)) --skip-git-repo-check $(shell_escape(prompt))"
            cmd = Cmd(`bash -lc $cmd_str`, ignorestatus=true)
            stderr_buf = IOBuffer()
            process = open(pipeline(cmd, stderr=stderr_buf))
            output_task = @async read(process, String)
            timed_out = false
            prompt_lower = lowercase(String(prompt))
            apply_timeout = timeout !== nothing && timeout > 0 && (occursin("timeout", prompt_lower) || occursin("time limit", prompt_lower) || occursin("time-limit", prompt_lower))
            if apply_timeout
                status = timedwait(() -> istaskdone(output_task), timeout)
                status == :timed_out && (timed_out = true; try
                    Base.kill(process)
                catch
                end)
            end
            stdout_text = fetch(output_task)
            close(process)
            stderr_text = String(take!(stderr_buf))
            timed_out && error("Codex timed out after $(timeout) seconds")

            session_id = nothing
            agent_messages = String[]
            branch_name = nothing
            errors = String[]

            for line in split(stdout_text, "\n"; keepempty=false)
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
            result = Dict{String,Any}(
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

function subagent_evaluate(parent::AgentContext, child::Agent, input_message::String)
    return evaluate(child, input_message)
end

function create_subagent_tool(parent::AgentContext)
    return @tool(
        "Create and run a nested subagent with its own system prompt and input. Returns the subagent's response text.",
        subagent(system_prompt::String, input_message::String) = begin
            parent_agent = get_agent(parent)
            child = Agent(
                ; prompt=system_prompt,
                model=parent_agent.model,
                apikey=parent_agent.apikey,
                state=AgentState(),
                input_guardrail=parent_agent.input_guardrail,
                tools=AgentTool[],
                stream_output=false,
            )
            child_tools = AgentTool[]
            for tool in parent_agent.tools
                tool.name == "subagent" && continue
                push!(child_tools, tool)
            end
            push!(child_tools, create_subagent_tool(child))
            child.tools = child_tools

            result = subagent_evaluate(parent, child, input_message)
            message = result.message
            message === nothing && return ""
            return message.text |> string
        end,
    )
end

function create_find_tool(base_dir::AbstractString)
    base = ensure_base_dir(base_dir)
    return @tool(
        "Search for files by glob pattern. Returns matching file paths relative to the search directory. Output is truncated to 1000 results or 50KB (whichever is hit first).",
        find(pattern::String, path::Union{Nothing,String}, limit::Union{Nothing,Int}) = begin
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
            truncation = truncate_head(raw_output; max_lines=typemax(Int))
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

function create_sandboxed_find_tool(container::AbstractString, base_dir::AbstractString)
    container_name = ensure_container_name(container)
    base = ensure_container_base_dir(base_dir)
    return @tool(
        "Search for files by glob pattern in the container. Returns matching file paths relative to the search directory. Output is truncated to 1000 results or 50KB (whichever is hit first).",
        find(pattern::String, path::Union{Nothing,String}, limit::Union{Nothing,Int}) = begin
            isempty(pattern) && throw(ArgumentError("pattern is required"))
            search_dir = resolve_search_path(base, path)
            container_is_dir(container_name, search_dir) || throw(ArgumentError("not a directory: $(path === nothing ? "." : path)"))
            regex = glob_to_regex(pattern)
            effective_limit = limit === nothing ? DEFAULT_FIND_LIMIT : max(1, limit)
            results = String[]
            limit_reached = false
            dir_result = docker_exec(container_name, "find $(shell_escape(search_dir)) -mindepth 1 -type d -print")
            dir_result.exitcode != 0 && error(isempty(dir_result.stderr) ? "failed to search directory: $(path === nothing ? "." : path)" : strip(dir_result.stderr))
            for full_path in split(dir_result.stdout, "\n"; keepempty=false)
                rel = normalize_relpath(relpath(full_path, search_dir))
                if occursin(regex, rel)
                    push!(results, rel * "/")
                    if length(results) >= effective_limit
                        limit_reached = true
                        break
                    end
                end
            end
            if !limit_reached
                file_result = docker_exec(container_name, "find $(shell_escape(search_dir)) -mindepth 1 -type f -print")
                file_result.exitcode != 0 && error(isempty(file_result.stderr) ? "failed to search directory: $(path === nothing ? "." : path)" : strip(file_result.stderr))
                for full_path in split(file_result.stdout, "\n"; keepempty=false)
                    rel = normalize_relpath(relpath(full_path, search_dir))
                    if occursin(regex, rel)
                        push!(results, rel)
                        if length(results) >= effective_limit
                            limit_reached = true
                            break
                        end
                    end
                end
            end
            isempty(results) && return "No files found matching pattern"
            raw_output = join(results, "\n")
            truncation = truncate_head(raw_output; max_lines=typemax(Int))
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
            path::Union{Nothing,String},
            glob::Union{Nothing,String},
            ignoreCase::Union{Nothing,Bool},
            literal::Union{Nothing,Bool},
            context::Union{Nothing,Int},
            limit::Union{Nothing,Int},
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
                    lines = split(content, "\n"; keepempty=true)
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
            truncation = truncate_head(raw_output; max_lines=typemax(Int))
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

function create_sandboxed_grep_tool(container::AbstractString, base_dir::AbstractString)
    container_name = ensure_container_name(container)
    base = ensure_container_base_dir(base_dir)
    return @tool(
        "Search file contents for a pattern in the container. Returns matching lines with file paths and line numbers. Output is truncated to 100 matches or 50KB (whichever is hit first). Long lines are truncated to 500 chars.",
        grep(
            pattern::String,
            path::Union{Nothing,String},
            glob::Union{Nothing,String},
            ignoreCase::Union{Nothing,Bool},
            literal::Union{Nothing,Bool},
            context::Union{Nothing,Int},
            limit::Union{Nothing,Int},
        ) = begin
            isempty(pattern) && throw(ArgumentError("pattern is required"))
            search_path = resolve_search_path(base, path)
            is_dir = container_is_dir(container_name, search_path)
            is_file = !is_dir && container_is_file(container_name, search_path)
            is_dir || is_file || throw(ArgumentError("path not found: $(path === nothing ? "." : path)"))
            effective_limit = limit === nothing ? DEFAULT_GREP_LIMIT : max(1, limit)
            context_value = context === nothing ? 0 : max(0, context)
            glob_regex = glob === nothing ? nothing : glob_to_regex(glob)
            match_count = 0
            match_limit_reached = false
            lines_truncated = false
            output_lines = String[]
            search_root = is_dir ? search_path : dirname(search_path)
            file_list = String[]
            if is_dir
                file_result = docker_exec(container_name, "find $(shell_escape(search_path)) -type f -print")
                file_result.exitcode != 0 && error(isempty(file_result.stderr) ? "failed to search files: $(path === nothing ? "." : path)" : strip(file_result.stderr))
                file_list = split(file_result.stdout, "\n"; keepempty=false)
            else
                push!(file_list, search_path)
            end
            regex = nothing
            if literal !== true
                try
                    flags = ignoreCase === true ? "i" : ""
                    regex = Regex(pattern, flags)
                catch
                    throw(ArgumentError("invalid regex pattern"))
                end
            end
            for file_path in file_list
                rel_path = normalize_relpath(relpath(file_path, search_root))
                glob_regex !== nothing && !occursin(glob_regex, rel_path) && continue
                read_result = docker_exec(container_name, "cat $(shell_escape(file_path))")
                read_result.exitcode != 0 && continue
                content = read_result.stdout
                occursin('\0', content) && continue
                lines = split(content, "\n"; keepempty=true)
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
            isempty(output_lines) && return "No matches found"
            raw_output = join(output_lines, "\n")
            truncation = truncate_head(raw_output; max_lines=typemax(Int))
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

function coding_tools(base_dir::AbstractString = pwd())
    return AgentTool[
        create_read_tool(base_dir),
        create_bash_tool(base_dir),
        create_edit_tool(base_dir),
        create_write_tool(base_dir),
    ]
end

function read_only_tools(base_dir::AbstractString = pwd())
    return AgentTool[
        create_read_tool(base_dir),
        create_grep_tool(base_dir),
        create_find_tool(base_dir),
        create_ls_tool(base_dir),
    ]
end

function all_tools(base_dir::AbstractString = pwd())
    return Dict(
        "read" => create_read_tool(base_dir),
        "bash" => create_bash_tool(base_dir),
        "edit" => create_edit_tool(base_dir),
        "write" => create_write_tool(base_dir),
        "grep" => create_grep_tool(base_dir),
        "find" => create_find_tool(base_dir),
        "ls" => create_ls_tool(base_dir),
    )
end

function sandboxed_coding_tools(container::AbstractString, base_dir::AbstractString)
    return AgentTool[
        create_sandboxed_read_tool(container, base_dir),
        create_sandboxed_bash_tool(container, base_dir),
        create_sandboxed_edit_tool(container, base_dir),
        create_sandboxed_write_tool(container, base_dir),
    ]
end

function sandboxed_read_only_tools(container::AbstractString, base_dir::AbstractString)
    return AgentTool[
        create_sandboxed_read_tool(container, base_dir),
        create_sandboxed_grep_tool(container, base_dir),
        create_sandboxed_find_tool(container, base_dir),
        create_sandboxed_ls_tool(container, base_dir),
    ]
end

function sandboxed_all_tools(container::AbstractString, base_dir::AbstractString)
    return Dict(
        "read" => create_sandboxed_read_tool(container, base_dir),
        "bash" => create_sandboxed_bash_tool(container, base_dir),
        "edit" => create_sandboxed_edit_tool(container, base_dir),
        "write" => create_sandboxed_write_tool(container, base_dir),
        "grep" => create_sandboxed_grep_tool(container, base_dir),
        "find" => create_sandboxed_find_tool(container, base_dir),
        "ls" => create_sandboxed_ls_tool(container, base_dir),
    )
end
