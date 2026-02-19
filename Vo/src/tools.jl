# --- Job scheduling tools ---

function listJobs(scheduler::Tempus.Scheduler)
    jobs = collect(Tempus.getJobs(scheduler.store))
    sort!(jobs, by=j -> j.name)
    return jobs
end

function datetime_to_cron(dt::DateTime)
    second = Dates.second(dt)
    minute = Dates.minute(dt)
    hour = Dates.hour(dt)
    day = Dates.day(dt)
    month = Dates.month(dt)
    return "$second $minute $hour $day $month *"
end

function parse_iso8601_utc(s::AbstractString)
    s_str = String(strip(s))
    isempty(s_str) && throw(ArgumentError("DateTime string cannot be empty"))
    m = match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?)(Z|[+-]\d{2}:?\d{2})?$", s_str)
    m === nothing && throw(ArgumentError("Invalid DateTime format: $(s_str). Use ISO 8601 format."))
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
        channel::Union{Nothing, Agentif.AbstractChannel} = nothing,
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
    if occursin('T', schedule_str)
        try
            schedule_dt = parse_iso8601_utc(schedule_str)
        catch e
            throw(ArgumentError("Invalid schedule DateTime format: $(schedule_str): $(sprint(showerror, e))"))
        end
        schedule_dt <= now_utc && throw(ArgumentError("schedule must be in the future (UTC); got $(schedule_str)"))
        cron_schedule = datetime_to_cron(schedule_dt)
        if max_executions === nothing
            max_executions = 1
        end
    else
        cron_schedule = schedule_str
        if run_once && max_executions === nothing
            max_executions = 1
        end
    end
    if expires_at !== nothing && expires_at <= now_utc
        throw(ArgumentError("expires_at must be in the future"))
    end
    if schedule_dt !== nothing && expires_at !== nothing && expires_at <= schedule_dt
        throw(ArgumentError("expires_at must be after the scheduled execution time"))
    end
    if schedule_dt !== nothing && expires_at === nothing
        expires_at = schedule_dt + Dates.Minute(5)
    end
    job = Tempus.Job(
        () -> begin
            a = get_current_assistant()
            a === nothing && return nothing
            if channel !== nothing
                Agentif.with_channel(channel) do
                    evaluate_fn(a, prompt; channel=channel)
                end
            else
                evaluate_fn(a, prompt)
            end
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

# --- Tool builders ---

function build_scheduler_tools(assistant::AgentAssistant; evaluate_fn::Function = Vo.evaluate)
    listJobs_tool = @tool(
        "List scheduled jobs and their status.",
        listJobs() = begin
            jobs = Vo.listJobs(assistant.scheduler)
            return JSON.json([job_summary(job) for job in jobs])
        end,
    )
    addJob_tool = @tool(
        """Schedule a prompt to run at a specific time or on a recurring cron schedule.

For one-time execution, pass an ISO 8601 UTC timestamp as the schedule (e.g. "2026-03-15T14:30:00Z"). This automatically sets max_executions=1.

For recurring execution, pass a 6-field cron expression: "second minute hour day month weekday" (e.g. "0 0 8 * * *" = daily at 8:00 AM UTC, "0 30 */2 * * *" = every 2 hours at :30).

The 6-field cron format is: second(0-59) minute(0-59) hour(0-23) day(1-31) month(1-12) weekday(0-6, 0=Sun). Use * for any, */N for every N, and comma-separated values.""",
        addJob(name::String, prompt::String, schedule::String, enabled::Union{Nothing, Bool}=nothing, expires_at::Union{Nothing, String}=nothing, max_executions::Union{Nothing, Int}=nothing, run_once::Union{Nothing, Bool}=nothing) = begin
            enabled_val = enabled === nothing ? true : enabled
            run_once_val = run_once === nothing ? false : run_once
            expires_at_dt = expires_at === nothing ? nothing : parse_iso8601_utc(expires_at)
            ch = Agentif.CURRENT_CHANNEL[]
            job = Vo.addJob!(assistant, name, prompt, schedule; channel=ch, enabled=enabled_val, expires_at=expires_at_dt, max_executions=max_executions, run_once=run_once_val, evaluate_fn=evaluate_fn)
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

function build_memory_tools(assistant::AgentAssistant)
    addNewMemory_tool = @tool(
        """Store a new memory. Use this AGGRESSIVELY — any time you learn something about the user, their preferences, projects, people, decisions, constraints, or context that could be useful later, store it immediately. Don't wait to be asked.

Priority levels:
- "high": core facts, strong preferences, important decisions, key people, active goals
- "medium": useful context, project details, patterns, moderate preferences
- "low": minor observations, one-off details, things that may become irrelevant

Use referenced_at for temporal anchoring when the memory references a specific time (e.g. "2025-06-15", "next Tuesday", "Q3 2025"). This helps with temporal reasoning later.""",
        addNewMemory(memory::String, priority::Union{Nothing, String}=nothing, referenced_at::Union{Nothing, String}=nothing) = begin
            eval_id = Agentif.CURRENT_EVALUATION_ID[]
            eval_id_str = eval_id === nothing ? nothing : string(eval_id)
            ch = Agentif.CURRENT_CHANNEL[]
            chan_id = ch !== nothing ? Agentif.channel_id(ch) : nothing
            post_id = ch !== nothing ? Agentif.source_message_id(ch) : nothing
            mem = Vo.addNewMemory(assistant.db, memory; eval_id=eval_id_str, priority=priority, referenced_at=referenced_at, search_store=assistant.search_store, channel_id=chan_id, post_id=post_id)
            return JSON.json(mem)
        end,
    )
    searchMemories_tool = @tool(
        "Search memories by keywords (space-separated). Use this PROACTIVELY at the start of conversations and whenever a topic comes up that you might have prior context on. Don't ask the user to repeat themselves — search first.",
        searchMemories(keywords::String, limit::Union{Nothing, Int}=nothing) = begin
            limit_value = limit === nothing ? 10 : limit
            ch = Agentif.CURRENT_CHANNEL[]
            ac = if ch !== nothing
                chan_id = Agentif.channel_id(ch)
                Vo.accessible_channel_ids(assistant.db, chan_id)
            else
                nothing
            end
            results = Vo.searchMemories(assistant.db, keywords; limit=limit_value, search_store=assistant.search_store, accessible_channels=ac)
            return JSON.json(results)
        end,
    )
    forgetMemory_tool = @tool(
        "Forget a memory by its exact text. Use searchMemories first to find the exact text of the memory you want to remove.",
        forgetMemory(memory::String) = begin
            removed = Vo.forgetMemory(assistant.db, memory; search_store=assistant.search_store)
            return string(removed)
        end,
    )
    return Agentif.AgentTool[addNewMemory_tool, searchMemories_tool, forgetMemory_tool]
end

function build_manage_skills_tools(assistant::AgentAssistant)
    addNewSkill_tool = @tool(
        """Add or replace a skill from full SKILL.md content. The content must start with YAML frontmatter containing `name` and `description` fields, followed by the skill's instructional content. Skill names must be lowercase kebab-case (e.g. "daily-summary", "email-checker"). Example:
---
name: my-skill
description: What this skill does
---
# Skill instructions here...""",
        addNewSkill(content::String) = begin
            meta = Vo.addNewSkill(assistant.db, content)
            return meta.name
        end,
    )
    forgetSkill_tool = @tool(
        "Forget a skill by name.",
        forgetSkill(name::String) = begin
            removed = Vo.forgetSkill(assistant.db, name)
            return string(removed)
        end,
    )
    return Agentif.AgentTool[addNewSkill_tool, forgetSkill_tool]
end

function build_document_tools(assistant::AgentAssistant)
    addDocument_tool = @tool(
        "Add or update a document in the knowledge base for future search/reference.",
        addDocument(id::String, title::String, text::String) = begin
            search_store = assistant.search_store
            search_store === nothing && return "error: search not available"
            doc_id = "doc:$(id)"
            LocalSearch.load!(search_store, text; id=doc_id, title=title)
            return "added"
        end,
    )
    listDocuments_tool = @tool(
        "List documents in the knowledge base. Returns up to `limit` documents (default 50).",
        listDocuments(limit::Union{Nothing, Int}=nothing) = begin
            limit = limit === nothing ? 50 : limit
            search_store = assistant.search_store
            search_store === nothing && return "[]"
            rows = SQLite.DBInterface.execute(search_store.db,
                "SELECT key, title FROM documents WHERE active = 1 AND key LIKE 'doc:%' ORDER BY created_at DESC LIMIT ?", (limit,))
            docs = [Dict("id" => replace(String(r.key), "doc:" => ""), "title" => String(r.title)) for r in rows]
            return JSON.json(docs)
        end,
    )
    deleteDocument_tool = @tool(
        "Delete a document from the knowledge base by id.",
        deleteDocument(id::String) = begin
            search_store = assistant.search_store
            search_store === nothing && return "error: search not available"
            Base.delete!(search_store, "doc:$(id)")
            return "deleted"
        end,
    )
    searchDocuments_tool = @tool(
        "Search documents in the knowledge base by keyword query. Returns up to `limit` results (default 10).",
        searchDocuments(query::String, limit::Union{Nothing, Int}=nothing) = begin
            limit = limit === nothing ? 10 : limit
            search_store = assistant.search_store
            search_store === nothing && return "[]"
            results = LocalSearch.search(search_store, query; limit=limit)
            doc_results = filter(r -> startswith(r.id, "doc:"), results)
            return JSON.json([Dict("id" => replace(r.id, "doc:" => ""), "title" => r.title, "score" => r.score, "text" => length(r.text) > 500 ? r.text[1:500] * "..." : r.text) for r in doc_results])
        end,
    )
    return Agentif.AgentTool[addDocument_tool, listDocuments_tool, deleteDocument_tool, searchDocuments_tool]
end

function build_assistant_tools(assistant::AgentAssistant)
    setIdentityAndPurpose_tool = @tool(
        "Update the assistant's identity and purpose with new content.",
        setIdentityAndPurpose(content::String) = begin
            setIdentityAndPurpose!(assistant, content)
            return "updated"
        end,
    )
    getIdentityAndPurpose_tool = @tool(
        "Get the assistant's current identity and purpose.",
        getIdentityAndPurpose() = begin
            return Vo.getIdentityAndPurpose(assistant)
        end,
    )
    getHeartbeatTasks_tool = @tool(
        "Get the current heartbeat task list.",
        getHeartbeatTasks() = begin
            return Vo.getHeartbeatTasks(assistant)
        end,
    )
    setHeartbeatTasks_tool = @tool(
        "Update the heartbeat task list.",
        setHeartbeatTasks(content::String) = begin
            setHeartbeatTasks!(assistant, content)
            return "updated"
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
            return img
        end,
    )
    search_session_tool = @tool(
        "Search session entries (past conversations) using semantic search and return matching snippets.",
        search_session(keywords::String, limit::Union{Nothing, Int}=nothing, offset::Union{Nothing, Int}=nothing) = begin
            limit_value = limit === nothing ? 10 : limit
            offset_value = offset === nothing ? 0 : offset
            ch = Agentif.CURRENT_CHANNEL[]
            ac = if ch !== nothing
                chan_id = Agentif.channel_id(ch)
                Vo.accessible_channel_ids(assistant.db, chan_id)
            else
                nothing
            end
            results = Vo.search_session(assistant, keywords; limit=limit_value, offset=offset_value, accessible_channels=ac)
            return JSON.json(results)
        end,
    )
    get_date_and_time_tool = @tool(
        "Get the current date and time in local and UTC.",
        get_date_and_time() = begin
            local_time = Dates.now()
            utc_time = Dates.now(Dates.UTC)
            offset_minutes = local_utc_offset_minutes(local_time)
            offset_str = format_utc_offset(offset_minutes)
            return JSON.json(Dict(
                "local" => Dates.format(local_time, "yyyy-mm-dd HH:MM:SS") * " ($(Dates.dayname(local_time)), UTC$(offset_str))",
                "utc" => Dates.format(utc_time, "yyyy-mm-dd HH:MM:SS") * " ($(Dates.dayname(utc_time)))",
            ))
        end,
    )
    tools = Agentif.AgentTool[
        analyzeImage_tool,
        search_session_tool,
        get_date_and_time_tool,
    ]
    # Admin-gated tools: identity/purpose/heartbeat only available to admins (or when no admins configured)
    cfg = assistant.config
    is_admin = if isempty(cfg.admins)
        true  # No admin list = everyone is admin
    else
        ch = Agentif.CURRENT_CHANNEL[]
        user = ch !== nothing ? Agentif.get_current_user(ch) : nothing
        if user !== nothing
            user.id in cfg.admins
        else
            # No user identity: admin if not in a group chat (REPL, DM without identity)
            ch === nothing || !Agentif.is_group(ch)
        end
    end
    if is_admin
        push!(tools, setIdentityAndPurpose_tool)
        push!(tools, getIdentityAndPurpose_tool)
        push!(tools, getHeartbeatTasks_tool)
        push!(tools, setHeartbeatTasks_tool)
    end
    cfg.documents && append!(tools, build_document_tools(assistant))
    cfg.terminal_tools && append!(tools, LLMTools.create_terminal_tools(cfg.base_dir))
    cfg.worker_tools && append!(tools, LLMTools.create_worker_tools())
    cfg.web_tools && append!(tools, LLMTools.web_tools())
    return tools
end
