struct SkillMetadata
    name::String
    description::String
    license::Union{Nothing, String}
    compatibility::Union{Nothing, String}
    metadata::Dict{String, String}
    allowed_tools::Union{Nothing, String}
    path::String
    skill_file::String
end

mutable struct SkillRegistry
    skills::Dict{String, SkillMetadata}
    loaded::Dict{String, String}
end

function default_skill_dirs(cwd::AbstractString = pwd())
    project_dir = joinpath(abspath(cwd), ".agentif", "skills")
    user_dir = joinpath(homedir(), ".agentif", "skills")
    return [project_dir, user_dir]
end

function create_skill_registry(paths::Vector{String} = default_skill_dirs(); warn::Bool = true)
    skills = discover_skills(paths; warn)
    skill_map = Dict{String, SkillMetadata}()
    for skill in skills
        skill_map[skill.name] = skill
    end
    return SkillRegistry(skill_map, Dict{String, String}())
end

function reload_skills!(registry::SkillRegistry, paths::Vector{String} = default_skill_dirs(); warn::Bool = true)
    skills = discover_skills(paths; warn)
    empty!(registry.skills)
    for skill in skills
        registry.skills[skill.name] = skill
    end
    empty!(registry.loaded)
    return registry
end

function discover_skills(paths::Vector{String} = default_skill_dirs(); warn::Bool = true)
    skills = SkillMetadata[]
    seen = Dict{String, SkillMetadata}()
    for base in paths
        isdir(base) || continue
        for entry in sort(readdir(base; join = true))
            isdir(entry) || continue
            skill_file = joinpath(entry, "SKILL.md")
            isfile(skill_file) || continue
            meta = try
                parse_skill_metadata(skill_file)
            catch e
                warn && @warn "Skipping invalid skill" skill_dir = entry error = sprint(showerror, e)
                continue
            end
            if haskey(seen, meta.name)
                warn && @warn "Skipping duplicate skill name" name = meta.name first_path = seen[meta.name].path skipped_path = entry
                continue
            end
            seen[meta.name] = meta
            push!(skills, meta)
        end
    end
    return skills
end

function load_skill(registry::SkillRegistry, name::String; refresh::Bool = false)
    meta = get(() -> nothing, registry.skills, name)
    meta === nothing && throw(ArgumentError("unknown skill: $name"))
    if !refresh
        cached = get(() -> nothing, registry.loaded, name)
        cached !== nothing && return cached
    end
    content = read(meta.skill_file, String)
    registry.loaded[name] = content
    return content
end

function create_skill_loader_tool(registry::SkillRegistry)
    return @tool(
        """Load the full SKILL.md instructions for a skill by name.

Use this tool when you see a relevant skill listed in <available_skills> in the system prompt and need its complete instructions before executing. This is a two-step pattern: (1) identify the skill from the system prompt listing, (2) call this tool to load its full instructions.

Arguments:
- `name::String` (required): Exact skill name in kebab-case (e.g., "code-review", "my-skill"). Must match a name from <available_skills> exactly — case-sensitive.

Throws `ArgumentError` if the skill name is not found. Output may be truncated for very large skill files; if so, the response includes a hint for loading more content via the read tool with offset/limit.

Examples:
- `skill_loader("code-review")` — load full instructions for the code-review skill
- `skill_loader("deploy-staging")` — load instructions before executing a deployment skill""",
        skill_loader(name::String) = begin
            content = load_skill(registry, name)
            meta = get(() -> nothing, registry.skills, name)
            max_bytes = MAX_TOOL_RESULT_BYTES[]
            if max_bytes > 0 && sizeof(content) > max_bytes
                hint = meta === nothing ? "" :
                    " Use read path=$(meta.skill_file) with offset/limit to load more."
                idx = prevind(content, max_bytes + 1)
                content = string(content[1:idx], "\n\n[Skill truncated: showing first ~$(_format_byte_size(max_bytes)) of $(_format_byte_size(sizeof(content))) total.$(hint)]")
            end
            return content
        end,
    )
end

function build_available_skills_xml(skills; include_location::Bool = true)
    skill_list = skills isa AbstractDict ? collect(values(skills)) : collect(skills)
    sort!(skill_list, by = skill -> skill.name)
    lines = String["<available_skills>"]
    for skill in skill_list
        push!(lines, "  <skill>")
        push!(lines, "    <name>$(escape_xml(skill.name))</name>")
        push!(lines, "    <description>$(escape_xml(skill.description))</description>")
        if include_location
            push!(lines, "    <location>$(escape_xml(skill.skill_file))</location>")
        end
        push!(lines, "  </skill>")
    end
    push!(lines, "</available_skills>")
    return join(lines, "\n")
end

function append_available_skills(prompt::String, skills; include_location::Bool = true)
    xml = build_available_skills_xml(skills; include_location)
    return prompt * "\n\n" * xml
end

function escape_xml(value::AbstractString)
    escaped = replace(value, "&" => "&amp;")
    escaped = replace(escaped, "<" => "&lt;")
    escaped = replace(escaped, ">" => "&gt;")
    escaped = replace(escaped, "\"" => "&quot;")
    escaped = replace(escaped, "'" => "&apos;")
    return escaped
end

function parse_skill_metadata(skill_file::AbstractString)
    content = read(skill_file, String)
    fields = parse_frontmatter(content)
    skill_dir = dirname(skill_file)
    name = get(() -> nothing, fields, "name")
    description = get(() -> nothing, fields, "description")
    name === nothing && throw(ArgumentError("missing required field: name"))
    description === nothing && throw(ArgumentError("missing required field: description"))
    validate_skill_name(name)
    if length(description) < 1 || length(description) > 1024
        throw(ArgumentError("description must be 1-1024 characters"))
    end
    if basename(skill_dir) != name
        throw(ArgumentError("skill name must match directory name: $(basename(skill_dir))"))
    end
    license = get(() -> nothing, fields, "license")
    compatibility = get(() -> nothing, fields, "compatibility")
    if compatibility !== nothing && (length(compatibility) < 1 || length(compatibility) > 500)
        throw(ArgumentError("compatibility must be 1-500 characters"))
    end
    allowed_tools = get(() -> nothing, fields, "allowed-tools")
    metadata = get(() -> Dict{String, String}(), fields, "metadata")
    metadata_dict = Dict{String, String}()
    if metadata isa AbstractDict
        for (k, v) in metadata
            metadata_dict[string(k)] = string(v)
        end
    end
    return SkillMetadata(
        name,
        description,
        license === nothing ? nothing : string(license),
        compatibility === nothing ? nothing : string(compatibility),
        metadata_dict,
        allowed_tools === nothing ? nothing : string(allowed_tools),
        skill_dir,
        skill_file,
    )
end

function parse_frontmatter(content::AbstractString)
    lines = split(content, "\n"; keepempty = true)
    isempty(lines) && throw(ArgumentError("missing frontmatter"))
    strip(lines[1]) == "---" || throw(ArgumentError("missing frontmatter start delimiter"))
    end_idx = nothing
    for i in 2:length(lines)
        if strip(lines[i]) == "---"
            end_idx = i
            break
        end
    end
    end_idx === nothing && throw(ArgumentError("missing frontmatter end delimiter"))
    front_lines = lines[2:(end_idx - 1)]
    return parse_frontmatter_lines(front_lines)
end

function parse_frontmatter_lines(lines::AbstractVector{<:AbstractString})
    fields = Dict{String, Any}()
    metadata = Dict{String, String}()
    i = 1
    while i <= length(lines)
        line = lines[i]
        stripped = strip(line)
        if isempty(stripped) || startswith(stripped, "#")
            i += 1
            continue
        end
        if stripped == "metadata:"
            i += 1
            while i <= length(lines)
                meta_line = lines[i]
                isempty(strip(meta_line)) && (i += 1; continue)
                indent = length(meta_line) - length(lstrip(meta_line))
                indent < 2 && break
                meta_str = strip(meta_line)
                m = match(r"^([A-Za-z0-9_.-]+)\s*:\s*(.*)$", meta_str)
                if m !== nothing
                    metadata[m.captures[1]] = unquote(m.captures[2])
                end
                i += 1
            end
            continue
        end
        m = match(r"^([A-Za-z0-9_-]+)\s*:\s*(.*)$", stripped)
        if m !== nothing
            fields[m.captures[1]] = unquote(m.captures[2])
        end
        i += 1
    end
    if !isempty(metadata)
        fields["metadata"] = metadata
    end
    return fields
end

function unquote(value::AbstractString)
    stripped = strip(value)
    if length(stripped) >= 2
        first_char = stripped[1]
        last_char = stripped[end]
        if (first_char == '"' && last_char == '"') || (first_char == '\'' && last_char == '\'')
            return stripped[2:(end - 1)]
        end
    end
    return stripped
end

function validate_skill_name(name::AbstractString)
    (length(name) >= 1 && length(name) <= 64) || throw(ArgumentError("skill name must be 1-64 characters"))
    occursin(r"^[a-z0-9]+(-[a-z0-9]+)*$", name) || throw(ArgumentError("invalid skill name: $name"))
    return true
end
