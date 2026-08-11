# System prompt construction. Deliberately tiny, in the spirit of pi's default
# prompt: name the tools, give a few guidelines, inject memories, state the cwd.

const PRESET_TOOL_LINES = Dict{Symbol, String}(
    :juco => """
- bash: run shell commands (also your ls/grep/find — use ls, rg, find, git via bash)
- read: read file contents (offset/limit for large files)
- edit: replace exact text in a file; empty oldText creates a new file
- remember: save a durable memory shown to you in future sessions""",
    :pi => """
- bash: run shell commands (also your ls/grep/find — use ls, rg, find, git via bash)
- read: read file contents (offset/limit for large files)
- edit: replace exact text in a file
- write: write full file contents""",
    :bash => """
- bash: run shell commands — your only tool. Explore with ls/rg/find/cat, edit files with heredocs, python, or ed/sed""",
)

# One entry per line, directories marked with '/'. Capped so a huge directory
# can't blow up the prompt.
function dir_snapshot(base_dir::AbstractString; limit::Int = 50)
    entries = try
        sort(readdir(base_dir))
    catch
        return ""
    end
    isempty(entries) && return "(empty)"
    shown = first(entries, limit)
    lines = [isdir(joinpath(base_dir, e)) ? e * "/" : e for e in shown]
    length(entries) > limit && push!(lines, "... ($(length(entries) - limit) more entries)")
    return join(lines, "\n")
end

function build_prompt(base_dir::AbstractString, preset::Symbol; memories::Vector{String} = String[])
    tool_lines = get(PRESET_TOOL_LINES, preset) do
        throw(ArgumentError("unknown toolset preset: $preset"))
    end
    prompt = """You are Juco, a minimal coding agent. You help by exploring code, running commands, and making precise edits.

Available tools:
$tool_lines

Guidelines:
- When fixing a bug or failing test, REPRODUCE it first: run the failing command and read the actual error before reading or changing code.
- Explore before editing; verify your changes (run tests or the code) before declaring success.
- Keep edits surgical: change only what the task requires.
- Be concise. When done, summarize what changed in a sentence or two.

Working directory: $(abspath(base_dir))
Top-level contents (snapshot at session start):
$(dir_snapshot(base_dir))"""
    if !isempty(memories)
        memory_lines = join(("- " * m for m in memories), "\n")
        prompt *= """


Memories you saved in previous sessions:
$memory_lines"""
    end
    return prompt
end
