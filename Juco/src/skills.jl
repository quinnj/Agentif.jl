# Skills: reusable prompt fragments the user injects with `$name`.
#
# Discovered dynamically at launch from `~/.agent/skills/<name>/SKILL.md` and
# `<cwd>/.agent/skills/<name>/SKILL.md` (project-local wins on name clashes).
# In the Julia-REPL juco mode, `$` tab-completes against the discovered names;
# any `$name` tokens in a submitted prompt inject the skill contents as
# `<skill>` blocks appended to the message.

struct Skill
    name::String
    path::String
    description::String
end

skill_dirs(base_dir::AbstractString = pwd()) = [
    joinpath(homedir(), ".agent", "skills"),
    joinpath(abspath(base_dir), ".agent", "skills"),
]

# First sentence-ish line that isn't a heading or frontmatter, as the description.
function skill_description(content::AbstractString)
    in_frontmatter = false
    for (i, line) in enumerate(eachsplit(content, '\n'))
        s = strip(line)
        if i == 1 && s == "---"
            in_frontmatter = true
            continue
        end
        if in_frontmatter
            s == "---" && (in_frontmatter = false)
            m = match(r"^description:\s*(.+)$", s)
            m === nothing || return String(strip(m.captures[1]))
            continue
        end
        isempty(s) && continue
        startswith(s, "#") && continue
        return String(first(s, 100))
    end
    return ""
end

function discover_skills(base_dir::AbstractString = pwd())
    skills = Dict{String, Skill}()
    for dir in skill_dirs(base_dir)  # later dirs (project-local) override
        isdir(dir) || continue
        for entry in sort(readdir(dir))
            path = joinpath(dir, entry, "SKILL.md")
            isfile(path) || continue
            desc = try
                skill_description(read(path, String))
            catch
                ""
            end
            skills[entry] = Skill(entry, path, desc)
        end
    end
    return sort!(collect(values(skills)); by = s -> s.name)
end

# ─── `$name` completion (pure logic; LineEdit wiring lives in the ReplMaker ext) ───

"""
    skill_completions(full, cursor, skills) -> (names, byte_range, should_complete)

If the text before `cursor` (a byte position) ends in `\$partial`, return skill
names completing `partial` and the byte range of `partial` to replace.
"""
function skill_completions(full::AbstractString, cursor::Int, skills::Vector{Skill})
    cursor = clamp(cursor, 0, ncodeunits(full))
    prefix = cursor == 0 ? "" : full[1:thisind(full, cursor)]
    m = match(r"\$([A-Za-z0-9_\-]*)$", prefix)
    m === nothing && return String[], 1:0, false
    word = m.captures[1]
    names = [s.name for s in skills if startswith(s.name, word)]
    range = m.offsets[1]:(m.offsets[1] + ncodeunits(word) - 1)
    return names, range, !isempty(names)
end

# ─── Prompt expansion ───

"""
    expand_skills(input, skills) -> (expanded_input, used_names)

Find `\$name` tokens matching discovered skills and append each skill's
contents as a `<skill>` block. Unknown `\$words` are left untouched.
"""
function expand_skills(input::AbstractString, skills::Vector{Skill})
    isempty(skills) && return String(input), String[]
    by_name = Dict(s.name => s for s in skills)
    used = String[]
    for m in eachmatch(r"\$([A-Za-z0-9][A-Za-z0-9_\-]*)", input)
        name = m.captures[1]
        haskey(by_name, name) && !(name in used) && push!(used, String(name))
    end
    isempty(used) && return String(input), used
    blocks = map(used) do name
        content = try
            strip(read(by_name[name].path, String))
        catch
            ""
        end
        "<skill name=\"$(name)\">\n$(content)\n</skill>"
    end
    return String(input) * "\n\n" * join(blocks, "\n\n"), used
end
