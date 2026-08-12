# Juco's uber-minimal toolset: bash + read + edit (+ remember).
#
# Compared to pi's default set (read, bash, edit, write), Juco drops `write`:
# `edit` with an empty `oldText` creates a new file. Exploration tools
# (grep/find/ls) are deliberately absent — bash covers them via rg/find/ls.
# `read` is reused from LLMTools (head-truncation with offset continuation).

const DEFAULT_BASH_TIMEOUT_S = 120
const MAX_BASH_TIMEOUT_S = 600
const MAX_BASH_LINE_CHARS = 2000
const MAX_BASH_OUTPUT_BYTES = 16 * 1024
const BASH_HEAD_LINES = 10

# Large outputs are sampled instead of tail-truncated wholesale: keep the first
# few lines (schema/first records) plus the tail (recent output, errors), with
# an explicit skip marker teaching the model to slice next time. A truncated
# result would otherwise ride along in the context of every later turn.
function sample_output(output::String; max_bytes::Int = MAX_BASH_OUTPUT_BYTES, head_lines::Int = BASH_HEAD_LINES)
    ncodeunits(output) <= max_bytes && return output, false
    lines = split(output, '\n'; keepempty = true)
    total_lines = length(lines)
    # keep whole head lines while under a quarter of the budget
    head_budget = max_bytes ÷ 4
    kept = String[]
    bytes = 0
    for l in first(lines, head_lines)
        lb = ncodeunits(l) + (isempty(kept) ? 0 : 1)
        bytes + lb > head_budget && break
        push!(kept, String(l))
        bytes += lb
    end
    head = join(kept, "\n")
    tail_budget = max(1024, max_bytes - ncodeunits(head))
    tail = truncate_tail(output; max_lines = typemax(Int) ÷ 2, max_bytes = tail_budget)
    skipped = total_lines - length(kept) - tail.output_lines
    marker = "\n…[skipped $(max(skipped, 0)) of $(total_lines) lines ($(round(Int, ncodeunits(output) / 1024))KB total) — for large outputs, slice with rg/head/awk instead of dumping them]\n"
    return head * marker * tail.content, true
end

# A single enormous line (a minified file, a dumped data structure) can eat the
# whole 50KB output budget; cap lines the way grep output caps match lines.
function cap_line_lengths(content::String; max_chars::Int = MAX_BASH_LINE_CHARS)
    any(l -> length(l) > max_chars, eachsplit(content, '\n')) || return content
    capped = map(split(content, '\n'; keepempty = true)) do line
        length(line) > max_chars ? first(line, max_chars) * " …[line truncated]" : line
    end
    return join(capped, "\n")
end

# Keep the LAST max_lines/max_bytes of content (LLMTools only ships head
# truncation; bash output wants the tail, where errors and results live).
function truncate_tail(content::String;
        max_lines::Int = LLMTools.DEFAULT_MAX_LINES, max_bytes::Int = LLMTools.DEFAULT_MAX_BYTES)
    lines = split(content, "\n"; keepempty = true)
    total_lines = length(lines)
    if total_lines <= max_lines && ncodeunits(content) <= max_bytes
        return (content = content, truncated = false, output_lines = total_lines, total_lines = total_lines)
    end
    kept = String[]
    bytes = 0
    for idx in total_lines:-1:1
        length(kept) >= max_lines && break
        line_bytes = ncodeunits(lines[idx]) + (isempty(kept) ? 0 : 1)
        bytes + line_bytes > max_bytes && break
        pushfirst!(kept, lines[idx])
        bytes += line_bytes
    end
    if isempty(kept)
        line = lines[total_lines]
        if max_bytes <= 0
            push!(kept, "")
        else
            first_byte = max(1, ncodeunits(line) - max_bytes + 1)
            start = thisind(line, first_byte)
            start < first_byte && (start = nextind(line, start))
            push!(kept, String(line[start:end]))
        end
    end
    return (content = join(kept, "\n"), truncated = true, output_lines = length(kept), total_lines = total_lines)
end

function run_bash(base::AbstractString, command::String, timeout_s::Real)
    out = Pipe()
    cmd = Cmd(`bash -c $command`; dir = base, ignorestatus = true)
    proc = run(pipeline(cmd; stdout = out, stderr = out); wait = false)
    close(out.in)
    # Accumulate incrementally so output survives a forced pipe close (below).
    acc = IOBuffer()
    reader = @async try
        while !eof(out)
            Base.write(acc, readavailable(out))
        end
    catch
    end
    timedout = timedwait(() -> process_exited(proc), float(timeout_s); pollint = 0.05) === :timed_out
    if timedout
        kill(proc)
        timedwait(() -> process_exited(proc), 5.0; pollint = 0.05) === :timed_out && kill(proc, Base.SIGKILL)
    end
    wait(proc)
    # An orphaned background child (e.g. `bash("./server &")`) can hold the pipe's
    # write end open after the parent exits; force EOF rather than hang.
    if timedwait(() -> istaskdone(reader), 2.0; pollint = 0.05) === :timed_out
        close(out)
        wait(reader)
    end
    return String(take!(acc)), proc.exitcode, timedout
end

function create_bash_tool(base_dir::AbstractString)
    base = LLMTools.ensure_base_dir(base_dir)
    return Agentif.@tool(
        """Execute a bash command and return its combined stdout/stderr.

The command already runs in the working directory shown in your system prompt — never prefix commands with `cd`; use relative paths.

This is your tool for everything except reading and editing files: listing directories (ls), searching file contents (rg), finding files (find, rg --files), git, running tests, etc.

Arguments:
- command (String, required): The bash command to execute.
- timeout (Int, optional): Seconds before the command is killed. Default 120, max 600.

Output over 16KB is sampled (first lines + tail, middle skipped) — slice large outputs with rg/head/awk instead of dumping whole files.

Examples:
- `bash("rg -n 'function parse' src/")` — search code
- `bash("julia --project=. -e 'using Pkg; Pkg.test()'", 300)` — run tests with a longer timeout""",
        bash(command::String, timeout::Union{Nothing, Int} = nothing) = begin
            timeout_s = clamp(something(timeout, DEFAULT_BASH_TIMEOUT_S), 1, MAX_BASH_TIMEOUT_S)
            output, exitcode, timedout = run_bash(base, command, timeout_s)
            result, was_sampled = sample_output(cap_line_lengths(output))
            timedout && (result *= "\n[Command timed out after $(timeout_s)s and was killed]")
            !timedout && exitcode != 0 && (result *= "\n[exit code $(exitcode)]")
            return result
        end,
    )
end

# When an exact match fails, point the model at the closest candidates (lines
# containing the first line of its oldText) so it can re-anchor without a
# read + guess round trip.
function nearest_match_hint(content::String, oldText::String; max_hits::Int = 3)
    anchor = ""
    for line in eachsplit(oldText, '\n')
        s = strip(line)
        isempty(s) || (anchor = String(s); break)
    end
    isempty(anchor) && return ""
    lines = split(content, "\n"; keepempty = true)
    hits = [i for (i, l) in enumerate(lines) if occursin(anchor, l)]
    if isempty(hits)
        # the whole line missed (that's often why the edit failed) — fall back
        # to its first word to find near-miss regions
        word = first(eachsplit(anchor, r"\s+"))
        isempty(word) && return ""
        hits = [i for (i, l) in enumerate(lines) if occursin(word, l)]
        isempty(hits) && return ""
    end
    sections = String[]
    for i in first(hits, max_hits)
        lo, hi = max(1, i - 2), min(length(lines), i + 2)
        push!(sections, join(("$(lpad(j, 5)) | $(lines[j])" for j in lo:hi), "\n"))
    end
    plural = length(hits) > max_hits ? " (showing $(max_hits) of $(length(hits)))" : ""
    return "\nClosest candidates$(plural) — check exact whitespace/quoting against these:\n" * join(sections, "\n  ...\n")
end

# Show the edited region (with numbered context lines) so the model can verify
# the change without a follow-up read.
function edited_region(new_content::String, replace_start::Int, new_text::String; context::Int = 3)
    prefix = new_content[1:prevind(new_content, replace_start)]
    first_changed = count(==('\n'), prefix) + 1
    last_changed = first_changed + count(==('\n'), new_text)
    lines = split(new_content, "\n"; keepempty = true)
    lo = max(1, first_changed - context)
    hi = min(length(lines), last_changed + context)
    numbered = ["$(lpad(i, 5)) | $(lines[i])" for i in lo:hi]
    return "lines $(lo)-$(hi) now:\n" * join(numbered, "\n")
end

function overlapping_matches(needle::String, haystack::String)
    matches = UnitRange{Int}[]
    from = firstindex(haystack)
    while from <= lastindex(haystack)
        match = findnext(needle, haystack, from)
        match === nothing && break
        push!(matches, match)
        from = nextind(haystack, first(match))
    end
    return matches
end

function create_edit_tool(base_dir::AbstractString)
    base = LLMTools.ensure_base_dir(base_dir)
    return Agentif.@tool(
        """Edit a file by replacing an exact text match, or create a new file. Returns the edited region so you can verify the change without re-reading the file.

To EDIT: `oldText` must match exactly one location in the file (whitespace-sensitive). Include enough surrounding lines to make the match unique, but keep it as small as possible.

To CREATE a new file: pass an empty `oldText` (""). The file must not already exist; parent directories are created automatically.

Arguments:
- path (String, required): File path: relative to the working directory, or absolute within it.
- oldText (String, required): Exact text to find, or "" to create a new file.
- newText (String, required): Replacement text, or the full content of the new file.

Examples:
- `edit("src/app.jl", "timeout = 30", "timeout = 60")` — change a value
- `edit("notes.md", "", "# Notes\\n")` — create a new file

Errors if: oldText not found or not unique, file missing when editing, or file already exists when creating.""",
        edit(path::String, oldText::String, newText::String) = begin
            resolved = LLMTools.resolve_relative_path(base, path)
            if isempty(oldText)
                isfile(resolved) && throw(ArgumentError("$(path) already exists; provide oldText to edit it (read it first if needed)"))
                mkpath(dirname(resolved))
                Base.write(resolved, newText)
                return "Created $(path) ($(ncodeunits(newText)) bytes)"
            end
            isfile(resolved) || throw(ArgumentError("file not found: $(path) (to create it, pass oldText = \"\")"))
            content = Base.read(resolved, String)
            matches = overlapping_matches(oldText, content)
            isempty(matches) && throw(ArgumentError(
                "could not find the exact text in $(path)." * nearest_match_hint(content, oldText)))
            if length(matches) > 1
                match_lines = [count(==('\n'), content[1:prevind(content, first(m))]) + 1 for m in matches]
                throw(ArgumentError("found $(length(matches)) occurrences in $(path) (at lines $(join(match_lines, ", "))); include more surrounding context to make oldText unique"))
            end
            idx = matches[1]
            replace_start = first(idx)
            new_content = content[1:prevind(content, replace_start)] * newText * content[nextind(content, last(idx)):end]
            new_content == content && throw(ArgumentError("replacement produced identical content for $(path)"))
            Base.write(resolved, new_content)
            return "Edited $(path), " * edited_region(new_content, replace_start, newText)
        end,
    )
end

function create_remember_tool(jdb::JucoDB)
    return Agentif.@tool(
        """Save a durable memory that will be shown to you at the start of every future session.

Use this for things worth carrying across sessions: user preferences, project conventions, gotchas you discovered, decisions that were made. Keep each memory to one or two sentences. Do NOT save things already recorded in the project (code, docs, git history) or details only relevant to the current task.

Arguments:
- content (String, required): The fact to remember, stated so it makes sense without this session's context.""",
        remember(content::String) = begin
            remember!(jdb, content)
            return "Saved."
        end,
    )
end

"""
    toolset(preset, base_dir, jdb) -> Vector{AgentTool}

Tool presets, primarily for eval comparison:
- `:juco` (default): bash, read, edit (create-capable), remember — 3 coding tools + memory
- `:pi`: bash, read, edit, write — pi's default 4 coding tools, no memory
- `:bash`: bash only — the mini-swe-agent-style extreme
"""
function toolset(preset::Symbol, base_dir::AbstractString, jdb::Union{Nothing, JucoDB} = nothing)
    if preset === :juco
        tools = Agentif.AgentTool[
            create_bash_tool(base_dir),
            LLMTools.create_read_tool(base_dir),
            create_edit_tool(base_dir),
        ]
        jdb !== nothing && push!(tools, create_remember_tool(jdb))
        return tools
    elseif preset === :pi
        return Agentif.AgentTool[
            create_bash_tool(base_dir),
            LLMTools.create_read_tool(base_dir),
            LLMTools.create_edit_tool(base_dir),
            LLMTools.create_write_tool(base_dir),
        ]
    elseif preset === :bash
        return Agentif.AgentTool[create_bash_tool(base_dir)]
    else
        throw(ArgumentError("unknown toolset preset: $preset (expected :juco, :pi, or :bash)"))
    end
end
