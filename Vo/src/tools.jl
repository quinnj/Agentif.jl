function getIdentityAndPurpose(store::FileStore)
    return lock(store.lock) do
        isfile(store.identity_path) || return DEFAULT_IDENTITY
        content = read(store.identity_path, String)
        cleaned = normalize_text(content)
        cleaned === nothing && return DEFAULT_IDENTITY
        return cleaned
    end
end

function getIdentityAndPurpose(store::InMemoryStore)
    return lock(store.lock) do
        cleaned = normalize_text(store.identity)
        cleaned === nothing && return DEFAULT_IDENTITY
        return cleaned
    end
end

function setIdentityAndPurpose!(store::FileStore, text::String)
    lock(store.lock) do
        write_atomic(store.identity_path, text)
    end
    return nothing
end

function setIdentityAndPurpose!(store::InMemoryStore, text::String)
    lock(store.lock) do
        store.identity = text
    end
    return nothing
end

function getUserProfile(store::FileStore)
    return lock(store.lock) do
        isfile(store.user_profile_path) || return DEFAULT_USER_PROFILE
        content = read(store.user_profile_path, String)
        cleaned = normalize_text(content)
        cleaned === nothing && return DEFAULT_USER_PROFILE
        return cleaned
    end
end

function getUserProfile(store::InMemoryStore)
    return lock(store.lock) do
        cleaned = normalize_text(store.user_profile)
        cleaned === nothing && return DEFAULT_USER_PROFILE
        return cleaned
    end
end

function setUserProfile!(store::FileStore, text::String)
    lock(store.lock) do
        write_atomic(store.user_profile_path, text)
    end
    return nothing
end

function setUserProfile!(store::InMemoryStore, text::String)
    lock(store.lock) do
        store.user_profile = text
    end
    return nothing
end

function getBootstrap(store::FileStore)
    return lock(store.lock) do
        isfile(store.bootstrap_path) || return DEFAULT_BOOTSTRAP
        content = read(store.bootstrap_path, String)
        cleaned = normalize_text(content)
        cleaned === nothing && return DEFAULT_BOOTSTRAP
        return cleaned
    end
end

function getBootstrap(store::InMemoryStore)
    return lock(store.lock) do
        cleaned = normalize_text(store.bootstrap)
        cleaned === nothing && return DEFAULT_BOOTSTRAP
        return cleaned
    end
end

function setBootstrap!(store::FileStore, text::String)
    lock(store.lock) do
        write_atomic(store.bootstrap_path, text)
    end
    return nothing
end

function setBootstrap!(store::InMemoryStore, text::String)
    lock(store.lock) do
        store.bootstrap = text
    end
    return nothing
end

function getToolsGuide(store::FileStore)
    return lock(store.lock) do
        isfile(store.tools_guide_path) || return DEFAULT_TOOLS_GUIDE
        content = read(store.tools_guide_path, String)
        cleaned = normalize_text(content)
        cleaned === nothing && return DEFAULT_TOOLS_GUIDE
        return cleaned
    end
end

function getToolsGuide(store::InMemoryStore)
    return lock(store.lock) do
        cleaned = normalize_text(store.tools_guide)
        cleaned === nothing && return DEFAULT_TOOLS_GUIDE
        return cleaned
    end
end

function setToolsGuide!(store::FileStore, text::String)
    lock(store.lock) do
        write_atomic(store.tools_guide_path, text)
    end
    return nothing
end

function setToolsGuide!(store::InMemoryStore, text::String)
    lock(store.lock) do
        store.tools_guide = text
    end
    return nothing
end

function getHeartbeatTasks(store::FileStore)
    return lock(store.lock) do
        isfile(store.heartbeat_tasks_path) || return DEFAULT_HEARTBEAT_TASKS
        content = read(store.heartbeat_tasks_path, String)
        return content
    end
end

function getHeartbeatTasks(store::InMemoryStore)
    return lock(store.lock) do
        return store.heartbeat_tasks
    end
end

function setHeartbeatTasks!(store::FileStore, text::String)
    lock(store.lock) do
        write_atomic(store.heartbeat_tasks_path, text)
    end
    return nothing
end

function setHeartbeatTasks!(store::InMemoryStore, text::String)
    lock(store.lock) do
        store.heartbeat_tasks = text
    end
    return nothing
end

function addPersonalityMode!(store::AbstractAssistantStore, content::String)
    text = strip(content)
    isempty(text) && throw(ArgumentError("mode content cannot be empty"))
    # Parse to validate and get name
    tmp = joinpath(tempdir(), "mode_validate_$(UUIDs.uuid4()).md")
    try
        write(tmp, text)
        mode = parse_personality_mode(tmp)
        mode === nothing && throw(ArgumentError("invalid mode format: needs frontmatter with name, chance, and content"))
        # Write to modes dir
        dir = store isa FileStore ? store.modes_dir : store.modes_dir
        isdir(dir) || mkpath(dir)
        dest = joinpath(dir, mode.name * ".md")
        write_atomic(dest, text)
        return mode
    finally
        isfile(tmp) && rm(tmp; force=true)
    end
end

function removePersonalityMode!(store::AbstractAssistantStore, name::String)
    dir = store isa FileStore ? store.modes_dir : store.modes_dir
    path = joinpath(dir, name * ".md")
    if isfile(path)
        rm(path; force=true)
        return 1
    end
    return 0
end

function addNewMemory(store::FileStore, memory::String; eval_id::Union{Nothing, String} = nothing)
    eval_id_str = eval_id === nothing ? nothing : string(eval_id)
    mem = Memory(memory, time(), eval_id_str)
    lock(store.lock) do
        append_jsonl(store.memories_path, mem)
    end
    return mem
end

function addNewMemory(store::InMemoryStore, memory::String; eval_id::Union{Nothing, String} = nothing)
    eval_id_str = eval_id === nothing ? nothing : string(eval_id)
    mem = Memory(memory, time(), eval_id_str)
    lock(store.lock) do
        push!(store.memories, mem)
    end
    return mem
end

"""
Search memories using semantic search (via Qmd) if available, falling back to keyword search.
"""
function searchMemories(store::FileStore, keywords::String; limit::Union{Nothing,Int}=nothing, semantic::Bool=true)
    limit_value = limit === nothing ? 10 : limit

    # Try semantic search first if enabled and Qmd is configured
    if semantic
        try
            db_path = get_database_path(store)
            if db_path !== nothing && isfile(db_path)
                # Use Qmd semantic search
                result = LLMTools.qmd_search(keywords; limit=limit_value, search_mode=:combined)
                if result["success"] && !isempty(result["results"])
                    # Convert Qmd results back to Memory objects by loading from JSONL
                    # For now, just return all memories that match the semantic results
                    # This is a simplification - in future we could store memories directly in Qmd
                    all_memories = load_all_memories(store)
                    memory_texts = Set(r["snippet"] for r in result["results"])

                    # Filter memories that appear in semantic results
                    matched = Memory[]
                    for mem in all_memories
                        # Check if memory content is similar to any result
                        for snippet in memory_texts
                            if occursin(lowercase(mem.memory), lowercase(snippet)) ||
                               occursin(lowercase(snippet), lowercase(mem.memory))
                                push!(matched, mem)
                                break
                            end
                        end
                    end

                    if !isempty(matched)
                        sort!(matched, by=m -> m.createdAt, rev=true)
                        return apply_limit(matched, limit)
                    end
                end
            end
        catch err
            @debug "Semantic search failed, falling back to keyword search" exception=err
        end
    end

    # Fall back to keyword search
    keywords_list = parse_keywords(keywords)
    results = Memory[]
    lock(store.lock) do
        isfile(store.memories_path) || return results
        open(store.memories_path, "r") do io
            for line in eachline(io)
                isempty(strip(line)) && continue
                mem = JSON.parse(line, Memory)
                matches_keywords(mem.memory, keywords_list) && push!(results, mem)
            end
        end
    end
    sort!(results, by=m -> m.createdAt, rev=true)
    return apply_limit(results, limit)
end

function load_all_memories(store::FileStore)
    results = Memory[]
    lock(store.lock) do
        isfile(store.memories_path) || return results
        open(store.memories_path, "r") do io
            for line in eachline(io)
                isempty(strip(line)) && continue
                push!(results, JSON.parse(line, Memory))
            end
        end
    end
    return results
end

function searchMemories(store::InMemoryStore, keywords::String; limit::Union{Nothing,Int}=nothing, semantic::Bool=true)
    # InMemoryStore doesn't support semantic search (no SQLite database)
    keywords_list = parse_keywords(keywords)
    results = Memory[]
    lock(store.lock) do
        for mem in store.memories
            matches_keywords(mem.memory, keywords_list) && push!(results, mem)
        end
    end
    sort!(results, by=m -> m.createdAt, rev=true)
    return apply_limit(results, limit)
end

function forgetMemory(store::FileStore, memory::String)
    removed = 0
    lock(store.lock) do
        isfile(store.memories_path) || return removed
        kept = Memory[]
        open(store.memories_path, "r") do io
            for line in eachline(io)
                isempty(strip(line)) && continue
                mem = JSON.parse(line, Memory)
                if mem.memory == memory
                    removed += 1
                else
                    push!(kept, mem)
                end
            end
        end
        write_jsonl_atomic(store.memories_path, kept)
    end
    return removed
end

function forgetMemory(store::InMemoryStore, memory::String)
    removed = 0
    lock(store.lock) do
        kept = Memory[]
        for mem in store.memories
            if mem.memory == memory
                removed += 1
            else
                push!(kept, mem)
            end
        end
        store.memories = kept
    end
    return removed
end

function get_skills_registry(store::FileStore)
    return lock(store.lock) do
        isdir(store.skills_dir) || mkpath(store.skills_dir)
        return Agentif.create_skill_registry([store.skills_dir]; warn=false)
    end
end

function get_skills_registry(store::InMemoryStore)
    return lock(store.lock) do
        return store.skills_registry
    end
end

function getSkills(store::FileStore)
    return lock(store.lock) do
        isdir(store.skills_dir) || return SkillMetadata[]
        skills = Agentif.discover_skills([store.skills_dir]; warn=false)
        sort!(skills, by=s -> s.name)
        return skills
    end
end

function getSkills(store::InMemoryStore)
    return lock(store.lock) do
        return collect(values(store.skills_registry.skills))
    end
end

function parse_skill_metadata(content::AbstractString)
    fields = Agentif.parse_frontmatter(content)
    name = get(() -> nothing, fields, "name")
    description = get(() -> nothing, fields, "description")
    name === nothing && throw(ArgumentError("skill content missing name"))
    description === nothing && throw(ArgumentError("skill content missing description"))
    Agentif.validate_skill_name(name)
    return String(name), String(description)
end

function addNewSkill(store::FileStore, content::AbstractString)
    text = String(content)
    isempty(strip(text)) && throw(ArgumentError("skill content cannot be empty"))
    name, _ = parse_skill_metadata(text)
    return lock(store.lock) do
        isdir(store.skills_dir) || mkpath(store.skills_dir)
        skill_dir = joinpath(store.skills_dir, name)
        isdir(skill_dir) && rm(skill_dir; recursive=true, force=true)
        mkpath(skill_dir)
        skill_file = joinpath(skill_dir, "SKILL.md")
        write_atomic(skill_file, text)
        return Agentif.parse_skill_metadata(skill_file)
    end
end

function addNewSkill(store::InMemoryStore, content::AbstractString)
    text = String(content)
    isempty(strip(text)) && throw(ArgumentError("skill content cannot be empty"))
    name, _ = parse_skill_metadata(text)
    return lock(store.lock) do
        isdir(store.skills_dir) || mkpath(store.skills_dir)
        skill_dir = joinpath(store.skills_dir, name)
        isdir(skill_dir) && rm(skill_dir; recursive = true, force = true)
        mkpath(skill_dir)
        skill_file = joinpath(skill_dir, "SKILL.md")
        write_atomic(skill_file, text)
        meta = Agentif.parse_skill_metadata(skill_file)
        store.skills_registry.skills[meta.name] = meta
        return meta
    end
end

function forgetSkill(store::FileStore, name::AbstractString)
    removed = 0
    lock(store.lock) do
        skill_dir = joinpath(store.skills_dir, String(name))
        if isdir(skill_dir)
            rm(skill_dir; recursive=true, force=true)
            removed = 1
        end
    end
    return removed
end

function forgetSkill(store::InMemoryStore, name::AbstractString)
    removed = 0
    lock(store.lock) do
        skill_name = String(name)
        if haskey(store.skills_registry.skills, skill_name)
            delete!(store.skills_registry.skills, skill_name)
            removed = 1
        end
        skill_dir = joinpath(store.skills_dir, skill_name)
        isdir(skill_dir) && rm(skill_dir; recursive = true, force = true)
    end
    return removed
end

function forgetSkill(store::AbstractAssistantStore, skill::SkillMetadata)
    return forgetSkill(store, skill.name)
end

function listJobs(scheduler::Tempus.Scheduler)
    jobs = collect(Tempus.getJobs(scheduler.store))
    sort!(jobs, by=j -> j.name)
    return jobs
end

"""
Convert a DateTime to a cron expression that matches that specific time.
Cron format: second minute hour day month day_of_week
"""
function datetime_to_cron(dt::DateTime)
    second = Dates.second(dt)
    minute = Dates.minute(dt)
    hour = Dates.hour(dt)
    day = Dates.day(dt)
    month = Dates.month(dt)
    # day_of_week = * (matches any day)
    return "$second $minute $hour $day $month *"
end

"""
Parse an ISO 8601 DateTime string and return a UTC DateTime.
Accepts "Z" or timezone offsets like "+02:00" or "-0500".
If no timezone is provided, the value is interpreted as UTC.
"""
function parse_iso8601_utc(s::AbstractString)
    s_str = String(strip(s))
    isempty(s_str) && throw(ArgumentError("DateTime string cannot be empty"))
    m = match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?)(Z|[+-]\d{2}:?\d{2})?$", s_str)
    m === nothing && throw(ArgumentError("Invalid DateTime format: $(s_str). Use ISO 8601 format (e.g., '2026-02-02T20:00:00Z' or '2026-02-02T20:00:00+02:00')."))
    base = m.captures[1]
    tz = m.captures[2]
    dt = Dates.DateTime(base)
    if tz === nothing || tz == "" || tz == "Z"
        return dt
    end
    sign = tz[1] == '-' ? -1 : 1
    if occursin(':', tz)
        hours = parse(Int, tz[2:3])
        minutes = parse(Int, tz[5:6])
    else
        hours = parse(Int, tz[2:3])
        minutes = parse(Int, tz[4:5])
    end
    (0 <= hours <= 23 && 0 <= minutes <= 59) || throw(ArgumentError("Invalid timezone offset in DateTime: $(s_str)."))
    offset = Dates.Hour(hours) + Dates.Minute(minutes)
    return dt - sign * offset
end

function addJob!(
        assistant,
        job_name,
        prompt,
        schedule;
        enabled::Bool = true,
        expires_at::Union{Nothing, DateTime} = nothing,
        max_executions::Union{Nothing, Int} = nothing,
        run_once::Bool = false,
        evaluate_fn::Function = Vo.evaluate,
    )
    isempty(strip(prompt)) && throw(ArgumentError("prompt cannot be empty"))
    schedule_str = String(strip(schedule))
    isempty(schedule_str) && throw(ArgumentError("schedule cannot be empty"))
    cron_schedule = nothing
    schedule_dt = nothing
    now_utc = Dates.now(Dates.UTC)
    # Check if schedule is a DateTime string or cron expression
    if occursin('T', schedule_str)
        # Schedule is a DateTime - parse it and convert to cron
        try
            schedule_dt = parse_iso8601_utc(schedule_str)
        catch e
            throw(ArgumentError("Invalid schedule DateTime format: $(schedule_str). Use ISO 8601 (e.g., '2026-02-02T20:00:00Z' or '2026-02-02T20:00:00+02:00'): $(sprint(showerror, e))"))
        end
        schedule_dt <= now_utc && throw(ArgumentError("schedule must be in the future (UTC); got $(schedule_str)"))
        cron_schedule = datetime_to_cron(schedule_dt)
        # For DateTime schedules, automatically set max_executions=1 (one-time)
        if max_executions === nothing
            max_executions = 1
        end
    else
        # Schedule is a cron expression
        cron_schedule = schedule_str
        # If run_once is true, set max_executions=1
        if run_once && max_executions === nothing
            max_executions = 1
        end
    end
    # Validate expires_at is in the future if provided
    if expires_at !== nothing && expires_at <= now_utc
        throw(ArgumentError("expires_at must be in the future"))
    end
    if schedule_dt !== nothing && expires_at !== nothing && expires_at <= schedule_dt
        throw(ArgumentError("expires_at must be after the scheduled execution time"))
    end
    # If schedule_dt was provided and expires_at wasn't, set expires_at slightly after execution
    if schedule_dt !== nothing && expires_at === nothing
        expires_at = schedule_dt + Dates.Minute(5)
    end
    job = Tempus.Job(
        () -> begin
            a = get_current_assistant()
            a === nothing && return nothing  # Assistant was closed
            evaluate_fn(a, prompt)
        end,
        job_name,
        cron_schedule;
        max_executions=max_executions,
        expires_at=expires_at
    )
    push!(assistant.scheduler, job)
    enabled || Tempus.disableJob!(assistant.scheduler.store, job)
    return job
end

function removeJob!(assistant, job_name)
    jobs = collect(Tempus.getJobs(assistant.scheduler.store))
    count = sum(j -> j.name == job_name, jobs; init=0)
    Tempus.purgeJob!(assistant.scheduler.store, job_name)
    return count
end

function build_scheduler_tools(assistant::AgentAssistant; evaluate_fn::Function = Vo.evaluate)
    listJobs_tool = @tool(
        "List scheduled jobs and their status.",
        listJobs() = begin
            jobs = Vo.listJobs(assistant.scheduler)
            return JSON.json([job_summary(job) for job in jobs])
        end,
    )
    addJob_tool = @tool(
        "Schedule a prompt to run at a specific time or cron schedule. Use ISO 8601 timestamps (UTC) or cron expressions.",
        addJob(name::String, prompt::String, schedule::String; enabled::Bool=true, expires_at::Union{Nothing, String}=nothing, max_executions::Union{Nothing, Int}=nothing, run_once::Bool=false) = begin
            expires_at_dt = expires_at === nothing ? nothing : parse_iso8601_utc(expires_at)
            job = Vo.addJob!(assistant, name, prompt, schedule; enabled=enabled, expires_at=expires_at_dt, max_executions=max_executions, run_once=run_once, evaluate_fn=evaluate_fn)
            return JSON.json(job_summary(job))
        end,
    )
    removeJob_tool = @tool(
        "Remove a scheduled job by name.",
        removeJob(name::String) = begin
            removed = Vo.removeJob!(assistant, name)
            return string(removed)
        end,
    )
    return Agentif.AgentTool[listJobs_tool, addJob_tool, removeJob_tool]
end

function build_tools(assistant::AgentAssistant; include_scheduler::Bool = true)
    setIdentityAndPurpose_tool = @tool(
        "Update Vo's identity and purpose with new content.",
        setIdentityAndPurpose(content::String) = begin
            setIdentityAndPurpose!(assistant.store, content)
            return "updated"
        end,
    )
    getIdentityAndPurpose_tool = @tool(
        "Get Vo's current identity and purpose.",
        getIdentityAndPurpose() = begin
            return Vo.getIdentityAndPurpose(assistant.store)
        end,
    )
    setUserProfile_tool = @tool(
        "Update the user profile document with new content. Use this to maintain a structured model of the user (goals, preferences, projects, constraints, etc.).",
        setUserProfile(content::String) = begin
            setUserProfile!(assistant.store, content)
            return "updated"
        end,
    )
    getUserProfile_tool = @tool(
        "Get the current user profile document.",
        getUserProfile() = begin
            return Vo.getUserProfile(assistant.store)
        end,
    )
    setBootstrap_tool = @tool(
        "Update the onboarding checklist. Check off items as you learn about the user (change `- [ ]` to `- [x]`). When all items are checked, onboarding is complete.",
        setBootstrap(content::String) = begin
            setBootstrap!(assistant.store, content)
            return "updated"
        end,
    )
    getBootstrap_tool = @tool(
        "Get the current onboarding checklist to see what Vo still needs to learn about the user.",
        getBootstrap() = begin
            return Vo.getBootstrap(assistant.store)
        end,
    )
    getHeartbeatTasks_tool = @tool(
        "Get the current heartbeat task list. These are pending items that will be processed on the next heartbeat check-in.",
        getHeartbeatTasks() = begin
            return Vo.getHeartbeatTasks(assistant.store)
        end,
    )
    setHeartbeatTasks_tool = @tool(
        "Update the heartbeat task list. Add items you want to process on a future heartbeat (follow-ups, reminders to check on things, deferred tasks). Remove items after processing them.",
        setHeartbeatTasks(content::String) = begin
            setHeartbeatTasks!(assistant.store, content)
            return "updated"
        end,
    )
    listPersonalityModes_tool = @tool(
        "List available personality modes with their activation settings (chance, active hours).",
        listPersonalityModes() = begin
            modes = Vo.list_personality_modes(assistant.store)
            summaries = [(; name=m.name, chance=m.chance, active_start=m.active_start, active_end=m.active_end) for m in modes]
            return JSON.json(summaries)
        end,
    )
    addPersonalityMode_tool = @tool(
        "Add or replace a personality mode. Content must be a markdown file with frontmatter (name, chance, active_start, active_end) and mode overlay text.",
        addPersonalityMode(content::String) = begin
            mode = Vo.addPersonalityMode!(assistant.store, content)
            return mode.name
        end,
    )
    removePersonalityMode_tool = @tool(
        "Remove a personality mode by name.",
        removePersonalityMode(name::String) = begin
            removed = Vo.removePersonalityMode!(assistant.store, name)
            return string(removed)
        end,
    )
    addNewMemory_tool = @tool(
        "Store a new memory (lesson learned, insight, observation, rule, pattern, etc.) tied to the current evaluation.",
        addNewMemory(memory::String) = begin
            eval_id = Agentif.CURRENT_EVALUATION_ID[]
            eval_id_str = eval_id === nothing ? nothing : string(eval_id)
            mem = Vo.addNewMemory(assistant.store, memory; eval_id=eval_id_str)
            return JSON.json(mem)
        end,
    )
    searchMemories_tool = @tool(
        "Search memories (lesson learned, insight, observation, rule, pattern, etc.) by keywords (space-separated) and return matching memories. Matches if any keyword is found.",
        searchMemories(keywords::String, limit::Union{Nothing, Int}=nothing) = begin
            limit_value = limit === nothing ? 10 : limit
            results = Vo.searchMemories(assistant.store, keywords; limit=limit_value)
            return JSON.json(results)
        end,
    )
    forgetMemory_tool = @tool(
        "Forget a memory (lesson learned, insight, observation, rule, pattern, etc.) by exact match.",
        forgetMemory(memory::String) = begin
            removed = Vo.forgetMemory(assistant.store, memory)
            return string(removed)
        end,
    )
    search_session_tool = @tool(
        "Search session entries (past turns between Vo and the user) by keywords (space-separated) and return matching entries. Matches if any keyword is found.",
        search_session(keywords::String, limit::Union{Nothing, Int}=nothing, offset::Union{Nothing, Int}=nothing) = begin
            limit_value = limit === nothing ? 10 : limit
            offset_value = offset === nothing ? 0 : offset
            results = Vo.search_session(assistant, keywords; limit=limit_value, offset=offset_value)
            return JSON.json(results)
        end,
    )
    getSkills_tool = @tool(
        "List known skills (sets of instructions for how to accomplish tasks).",
        getSkills() = begin
            skills = Vo.getSkills(assistant.store)
            return JSON.json(skills)
        end,
    )
    addNewSkill_tool = @tool(
        "Add or replace a skill from full SKILL.md content, including frontmatter name and description, and the skill's instructional content.",
        addNewSkill(content::String) = begin
            meta = Vo.addNewSkill(assistant.store, content)
            return meta.name
        end,
    )
    forgetSkill_tool = @tool(
        "Forget a skill by name.",
        forgetSkill(name::String) = begin
            removed = Vo.forgetSkill(assistant.store, name)
            return string(removed)
        end,
    )
    getToolsGuide_tool = @tool(
        "Get the current tool usage guide (best practices and patterns for using tools effectively).",
        getToolsGuide() = begin
            return Vo.getToolsGuide(assistant.store)
        end,
    )
    setToolsGuide_tool = @tool(
        "Update the tool usage guide with new best practices or patterns discovered while using tools.",
        setToolsGuide(content::String) = begin
            setToolsGuide!(assistant.store, content)
            return "updated"
        end,
    )
    sendMessage_tool = @tool(
        "Send a proactive message to the user. Use this to push notifications, alerts, or follow-up messages outside the normal request-response flow. Messages are written to the output stream and logged.",
        sendMessage(content::String, channel::Union{Nothing, String}=nothing) = begin
            # Write to the assistant's output stream
            println(assistant.output, "\n[Vo] ", content)
            # Log as a proactive message
            @info "[vo] Proactive message sent" channel content_length=length(content)
            return "sent"
        end,
    )
    analyzeImage_tool = @tool(
        "Analyze an image file. Reads the image from disk, encodes it, and returns it as image content for the model to process. Supports PNG, JPEG, GIF, WEBP.",
        analyzeImage(path::String, prompt::Union{Nothing, String}=nothing) = begin
            abspath_val = isabspath(path) ? path : joinpath(assistant.config.base_dir, path)
            isfile(abspath_val) || throw(ArgumentError("File not found: $abspath_val"))
            ext = lowercase(splitext(abspath_val)[2])
            mime = if ext in (".png",)
                "image/png"
            elseif ext in (".jpg", ".jpeg")
                "image/jpeg"
            elseif ext in (".gif",)
                "image/gif"
            elseif ext in (".webp",)
                "image/webp"
            else
                throw(ArgumentError("Unsupported image format: $ext (use PNG, JPEG, GIF, or WEBP)"))
            end
            data = Base.base64encode(read(abspath_val))
            img = Agentif.ImageContent(data, mime)
            # Return image content block so the model can see it
            return img
        end,
    )
    reloadConfig_tool = @tool(
        "Reload Vo's configuration from disk. Refreshes identity, user profile, bootstrap, tools guide, and heartbeat tasks from their files. Use after manual edits to workspace files.",
        reloadConfig() = begin
            store = assistant.store
            # Refresh skill registry
            registry = get_skills_registry(store)
            return "reloaded"
        end,
    )
    tools = Agentif.AgentTool[
        setIdentityAndPurpose_tool,
        getIdentityAndPurpose_tool,
        setUserProfile_tool,
        getUserProfile_tool,
        setBootstrap_tool,
        getBootstrap_tool,
        getHeartbeatTasks_tool,
        setHeartbeatTasks_tool,
        getToolsGuide_tool,
        setToolsGuide_tool,
        sendMessage_tool,
        analyzeImage_tool,
        reloadConfig_tool,
        listPersonalityModes_tool,
        addPersonalityMode_tool,
        removePersonalityMode_tool,
        addNewMemory_tool,
        searchMemories_tool,
        forgetMemory_tool,
        search_session_tool,
        getSkills_tool,
        addNewSkill_tool,
        forgetSkill_tool,
    ]
    include_scheduler && append!(tools, build_scheduler_tools(assistant))
    append!(tools, LLMTools.create_long_running_process_tool(assistant.config.base_dir))
    append!(tools, LLMTools.web_tools())  # web_fetch and web_search
    append!(tools, LLMTools.qmd_tools(assistant.config.base_dir))  # qmd_index and qmd_search for semantic search
    registry = get_skills_registry(assistant.store)
    !isempty(registry.skills) && push!(tools, Agentif.create_skill_loader_tool(registry))
    return tools
end
