using Test, Agentif, JSON

@testset "OpenAI Responses tool schema requires all fields" begin
    schema = Agentif.OpenAIResponses.schema(
        @NamedTuple{path::String, offset::Union{Nothing, Int}, limit::Union{Nothing, Int}}
    )
    raw = JSON.parse(JSON.json(schema))
    properties = sort(collect(keys(raw["properties"])))
    required = sort(raw["required"])
    @test required == properties
end

function get_env_first(keys::Vector{String})
    for key in keys
        value = get(() -> nothing, ENV, key)
        if value !== nothing && !isempty(value)
            return value, key
        end
    end
    return nothing, nothing
end

function resolve_api_key()
    value, key = get_env_first(
        [
            "AGENTIF_API_KEY",
            "MINIMAX_API_KEY",
            "OPENROUTER_API_KEY",
            "VO_OPENROUTER_API_KEY",
            "VO_OPENROUTER_KEY",
            "VO_AGENT_API_KEY",
        ]
    )
    value !== nothing && return value, key
    for (env_key, env_value) in ENV
        if startswith(env_key, "VO_") && occursin("OPENROUTER", env_key) && !isempty(env_value)
            return env_value, env_key
        end
    end
    vo_keys = String[]
    for (env_key, env_value) in ENV
        startswith(env_key, "VO_") || continue
        isempty(env_value) && continue
        push!(vo_keys, env_key)
    end
    if length(vo_keys) == 1
        return ENV[vo_keys[1]], vo_keys[1]
    end
    return nothing, nothing
end

function tool_choice_kwargs(model::Agentif.Model, tool_name::String; disable::Bool = false)
    disable && return (;)
    if model.api == "openai-responses"
        return (; tool_choice = "required")
    elseif model.api == "openai-completions"
        return (; tool_choice = Dict("type" => "function", "function" => Dict("name" => tool_name)))
    elseif model.api == "anthropic-messages"
        return (; tool_choice = Dict("type" => "tool", "name" => tool_name))
    elseif model.api == "google-generative-ai"
        return (; toolConfig = Dict("functionCallingConfig" => Dict("mode" => "ANY")))
    elseif model.api == "google-gemini-cli"
        return (; toolChoice = "any")
    end
    return (;)
end

function has_tool_call(events, tool_name::String)
    return any(e -> e isa Agentif.ToolCallRequestEvent && e.tool_call.name == tool_name, events)
end

function run_tool_call(model::Agentif.Model, apikey::String, tool::Agentif.AgentTool, prompt::String; force_tool_choice::Bool = true, retries::Int = 1, abort_after_tool::Bool = true)
    manual_tools = Set(["exec_command", "write_stdin", "kill_session", "list_sessions"])
    function run_once_stream(prompt_text::String; use_stream::Bool = true)
        tools = Agentif.AgentTool[]
        push!(tools, tool)
        agent = Agentif.Agent(
            ; prompt = "Function calling is enabled. You must call the requested tool and respond with tool calls only. Do not refuse or ask questions.",
            model,
            apikey,
            skills = nothing,
            input_guardrail = nothing,
            tools = tools,
        )
        events = Agentif.AgentEvent[]
        f = event -> push!(events, event)
        kwargs = tool_choice_kwargs(model, tool.name; disable = !force_tool_choice)
        response = Agentif.stream(
            f,
            agent,
            agent.state,
            prompt_text,
            apikey;
            agent.model,
            kwargs...,
            temperature = 0.0,
            stream = use_stream,
            http_kw = (; readtimeout = 30, connect_timeout = 15, retries = 1),
        )
        return response, events
    end
    if tool.name in manual_tools
        response, events = run_once_stream(prompt; use_stream = false)
        if !has_tool_call(events, tool.name) && retries > 0
            retry_prompt = prompt * " You must call the tool now. Respond with a tool call only and no additional text."
            response, events = run_once_stream(retry_prompt; use_stream = false)
        end
        tool_calls = response.message.tool_calls
        if tool_calls !== nothing
            for call in tool_calls
                call.name == tool.name || continue
                ptc = Agentif.PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                push!(events, Agentif.ToolExecutionStartEvent(ptc))
                output = ""
                is_error = false
                try
                    args = Agentif.parse_tool_arguments(call.arguments, Agentif.parameters(tool))
                    output = string(tool.func(args...))
                catch e
                    is_error = true
                    output = sprint(showerror, e)
                end
                trm = Agentif.ToolResultMessage(call.call_id, call.name, output; is_error)
                push!(events, Agentif.ToolExecutionEndEvent(ptc, trm, 0))
            end
        end
        return response, events
    end
    function run_once(prompt_text::String)
        tools = Agentif.AgentTool[]
        push!(tools, tool)
        agent = Agentif.Agent(
            ; prompt = "Function calling is enabled. You must call the requested tool and respond with tool calls only. Do not refuse or ask questions.",
            model,
            apikey,
            skills = nothing,
            input_guardrail = nothing,
            tools = tools,
        )
        events = Agentif.AgentEvent[]
        f = event -> begin
            push!(events, event)
            if abort_after_tool && event isa Agentif.ToolExecutionEndEvent && event.result.name == tool.name
                throw(Agentif.AbortEvaluation("stop after tool execution"))
            end
        end
        kwargs = tool_choice_kwargs(model, tool.name; disable = !force_tool_choice)
        result = Agentif.evaluate(
            f,
            agent,
            prompt_text;
            kwargs...,
            temperature = 0.0,
            http_kw = (; readtimeout = 30, connect_timeout = 15, retries = 1),
        )
        for event in events
            if event isa Agentif.AgentErrorEvent
                @info "Agent error during tool call: $(sprint(showerror, event.error))"
            end
        end
        return result, events
    end
    result, events = run_once(prompt)
    if !has_tool_call(events, tool.name) && retries > 0
        retry_prompt = prompt * " You must call the tool now. Respond with a tool call only and no additional text."
        result, events = run_once(retry_prompt)
    end
    return result, events
end

function tool_exec_results(events, tool_name::String)
    results = Agentif.ToolResultMessage[]
    for event in events
        if event isa Agentif.ToolExecutionEndEvent && event.result.name == tool_name
            push!(results, event.result)
        end
    end
    return results
end

function assert_tool_called(events, tool_name::String)
    called = any(e -> e isa Agentif.ToolCallRequestEvent && e.tool_call.name == tool_name, events)
    if !called
        last_msg = nothing
        for event in reverse(events)
            if event isa Agentif.MessageEndEvent && event.role == :assistant
                last_msg = event.message
                break
            end
        end
        last_msg !== nothing && @info "No tool call for $(tool_name). Assistant text: $(message_text(last_msg))"
    end
    @test called
    results = tool_exec_results(events, tool_name)
    @test !isempty(results)
    isempty(results) && return ""
    results[end].is_error && @info "Tool error output for $(tool_name): $(message_text(results[end]))"
    @test results[end].is_error == false
    return message_text(results[end])
end

function run_tool_call_with_timeout(model::Agentif.Model, apikey::String, tool::Agentif.AgentTool, prompt::String; timeout_s::Real = 45, kwargs...)
    task = errormonitor(Threads.@spawn run_tool_call(model, apikey, tool, prompt; kwargs...))
    status = Base.timedwait(() -> istaskdone(task), timeout_s)
    status === :ok || return :timeout, nothing, Agentif.AgentEvent[]
    result, events = fetch(task)
    return :ok, result, events
end

function setup_workspace()
    base_dir = mktempdir()
    write(joinpath(base_dir, "alpha.txt"), "Hello Alpha\nSecond line\n")
    write(joinpath(base_dir, "edit.txt"), "before=1\n")
    mkpath(joinpath(base_dir, "docs"))
    write(joinpath(base_dir, "docs", "readme.md"), "Doc Title\nMAGIC_TOKEN\n")
    mkpath(joinpath(base_dir, "notes"))
    write(joinpath(base_dir, "notes", "note.txt"), "Some notes\nMAGIC_TOKEN present\n")
    mkpath(joinpath(base_dir, "nested"))
    write(joinpath(base_dir, "nested", "data.json"), """{"hello": "world"}""")
    write(joinpath(base_dir, "echo.py"), "import sys\nprint(\"READY\")\nfor line in sys.stdin:\n    print(line.strip())\n")
    return base_dir
end

function parse_session_id(output::String)
    m = match(r"session ID (\d+)"i, output)
    m === nothing && return nothing
    return parse(Int, m.captures[1])
end

function start_session(exec_tool::Agentif.AgentTool, cmd::String)
    output = exec_tool.func(cmd)
    session_id = parse_session_id(output)
    session_id === nothing && error("could not parse session id from exec_command output: $(output)")
    return session_id
end

@testset "Predefined Tools (Live)" begin
    ENV["AGENTIF_STOP_ON_TOOL_CALL"] = "1"
    @info "Julia threads" Threads.nthreads()
    provider = get(() -> nothing, ENV, "MINIMAX_PROVIDER")
    provider = provider == "minimax" ? provider : "minimax"
    model_id = get(() -> nothing, ENV, "MINIMAX_MODEL_ID")
    model_id === nothing && (model_id = "minimax/minimax-m2.1")
    apikey, apikey_name = resolve_api_key()
    if apikey === nothing
        @info "Skipping predefined tools live tests; set AGENTIF_API_KEY or OPENROUTER_API_KEY (or VO_OPENROUTER_API_KEY)."
    else
        model = Agentif.getModel(provider, model_id)
        if model === nothing && provider != "openrouter"
            provider = "openrouter"
            model = Agentif.getModel(provider, model_id)
        end
        model === nothing && error("unknown model: provider=$(repr(provider)) model_id=$(repr(model_id))")
        @info "Running live tool tests with provider=$(provider) model=$(model_id) apikey=$(apikey_name) baseUrl=$(model.baseUrl)"
        base_dir = setup_workspace()
        @testset "read" begin
            @info "Tool test: read"
            tool = Agentif.create_read_tool(base_dir)
            prompt = "Tool calling is enabled. Call the read tool now with path=\"alpha.txt\". Return a tool call only."
            _, events = run_tool_call(model, apikey, tool, prompt)
            output = assert_tool_called(events, "read")
            @test occursin("Hello Alpha", output)
        end
        @testset "write" begin
            @info "Tool test: write"
            tool = Agentif.create_write_tool(base_dir)
            prompt = "Tool calling is enabled. Call the write tool now with path=\"out/new.txt\" and content=\"written ok\". Return a tool call only."
            _, events = run_tool_call(model, apikey, tool, prompt)
            output = assert_tool_called(events, "write")
            @test occursin("Successfully wrote", output)
            @test read(joinpath(base_dir, "out", "new.txt"), String) == "written ok"
        end
        @testset "edit" begin
            @info "Tool test: edit"
            tool = Agentif.create_edit_tool(base_dir)
            prompt = "Tool calling is enabled. Call the edit tool now with path=\"edit.txt\", oldText=\"before=1\" and newText=\"after=2\". Return a tool call only."
            _, events = run_tool_call(model, apikey, tool, prompt)
            output = assert_tool_called(events, "edit")
            @test occursin("Successfully replaced text", output)
            @test occursin("after=2", read(joinpath(base_dir, "edit.txt"), String))
        end
        @testset "ls" begin
            @info "Tool test: ls"
            tool = Agentif.create_ls_tool(base_dir)
            prompt = "Tool calling is enabled. Call the ls tool now with path=\".\" and limit=20. Return a tool call only."
            _, events = run_tool_call(model, apikey, tool, prompt)
            output = assert_tool_called(events, "ls")
            @test occursin("alpha.txt", output)
            @test occursin("docs/", output)
        end
        @testset "find" begin
            @info "Tool test: find"
            tool = Agentif.create_find_tool(base_dir)
            prompt = "Tool calling is enabled. Call the find tool now with pattern=\"*.md\" and path=\"docs\". Return a tool call only."
            _, events = run_tool_call(model, apikey, tool, prompt)
            output = assert_tool_called(events, "find")
            @test occursin("readme.md", output)
        end
        @testset "grep" begin
            @info "Tool test: grep"
            tool = Agentif.create_grep_tool(base_dir)
            prompt = "Tool calling is enabled. Call the grep tool now with pattern=\"MAGIC_TOKEN\" and path=\".\". Return a tool call only."
            _, events = run_tool_call(model, apikey, tool, prompt)
            output = assert_tool_called(events, "grep")
            @test occursin("MAGIC_TOKEN", output)
            @test occursin("readme.md", output) || occursin("note.txt", output)
        end
        @testset "subagent" begin
            @info "Tool test: subagent"
            tool = Agentif.create_subagent_tool(Agentif.Agent(; prompt = "parent", model, apikey))
            prompt = "Tool calling is enabled. Call the subagent tool now with system_prompt=\"Reply briefly to the user\" and input_message=\"ping\". Return a tool call only."
            _, events = run_tool_call(model, apikey, tool, prompt)
            output = assert_tool_called(events, "subagent")
            @test !isempty(strip(output))
        end
        @testset "exec_command" begin
            @info "Tool test: exec_command"
            tool = Agentif.create_long_running_process_tool(base_dir)[1]
            prompt = "Tool calling is enabled. Call the exec_command tool now with cmd=\"echo tool-ok\", yield_time_ms=500, max_output_lines=50. Return a tool call only."
            status, _, events = run_tool_call_with_timeout(model, apikey, tool, prompt; timeout_s = 45, force_tool_choice = false)
            if status == :timeout
                @info "exec_command timed out on minimax/m2.1; retrying with minimax/m2.1-lightning"
                fallback = Agentif.getModel("minimax", "minimax/minimax-m2.1-lightning")
                fallback === nothing && error("minimax/m2.1-lightning not available in registry")
                status, _, events = run_tool_call_with_timeout(fallback, apikey, tool, prompt; timeout_s = 45, force_tool_choice = false)
            end
            @test status == :ok
            output = assert_tool_called(events, "exec_command")
            @test occursin("tool-ok", output)
        end
        @testset "write_stdin" begin
            @info "Tool test: write_stdin"
            tools = Agentif.create_long_running_process_tool(base_dir)
            exec_tool = tools[1]
            write_tool = tools[2]
            session_id = start_session(exec_tool, "cat")
            prompt = "Tool calling is enabled. Call the write_stdin tool now with session_id=$(session_id), chars=\"ping\\n\", yield_time_ms=500, max_output_lines=50. Return a tool call only."
            status, _, events = run_tool_call_with_timeout(model, apikey, write_tool, prompt; timeout_s = 45)
            if status == :timeout
                @info "write_stdin timed out on minimax/m2.1; retrying with minimax/m2.1-lightning"
                fallback = Agentif.getModel("minimax", "minimax/minimax-m2.1-lightning")
                fallback === nothing && error("minimax/m2.1-lightning not available in registry")
                status, _, events = run_tool_call_with_timeout(fallback, apikey, write_tool, prompt; timeout_s = 45)
            end
            @test status == :ok
            output = assert_tool_called(events, "write_stdin")
            @test occursin("Output:", output)
            kill_tool = tools[3]
            kill_tool.func(session_id)
        end
        @testset "list_sessions" begin
            @info "Tool test: list_sessions"
            tools = Agentif.create_long_running_process_tool(base_dir)
            exec_tool = tools[1]
            list_tool = tools[4]
            session_id = start_session(exec_tool, "sleep 60")
            prompt = "Tool calling is enabled. Call the list_sessions tool now. Return a tool call only."
            status, _, events = run_tool_call_with_timeout(model, apikey, list_tool, prompt; timeout_s = 45)
            if status == :timeout
                @info "list_sessions timed out on minimax/m2.1; retrying with minimax/m2.1-lightning"
                fallback = Agentif.getModel("minimax", "minimax/minimax-m2.1-lightning")
                fallback === nothing && error("minimax/m2.1-lightning not available in registry")
                status, _, events = run_tool_call_with_timeout(fallback, apikey, list_tool, prompt; timeout_s = 45)
            end
            @test status == :ok
            output = assert_tool_called(events, "list_sessions")
            @test occursin("Active PTY Sessions", output)
            @test occursin(string(session_id), output)
            kill_tool = tools[3]
            kill_tool.func(session_id)
        end
        @testset "kill_session" begin
            @info "Tool test: kill_session"
            tools = Agentif.create_long_running_process_tool(base_dir)
            exec_tool = tools[1]
            kill_tool = tools[3]
            session_id = start_session(exec_tool, "sleep 60")
            prompt = "Tool calling is enabled. Call the kill_session tool now with session_id=$(session_id). Return a tool call only."
            status, _, events = run_tool_call_with_timeout(model, apikey, kill_tool, prompt; timeout_s = 45)
            if status == :timeout
                @info "kill_session timed out on minimax/m2.1; retrying with minimax/m2.1-lightning"
                fallback = Agentif.getModel("minimax", "minimax/minimax-m2.1-lightning")
                fallback === nothing && error("minimax/m2.1-lightning not available in registry")
                status, _, events = run_tool_call_with_timeout(fallback, apikey, kill_tool, prompt; timeout_s = 45)
            end
            @test status == :ok
            output = assert_tool_called(events, "kill_session")
            @test occursin("Session $(session_id)", output)
        end
        @testset "web_fetch" begin
            @info "Tool test: web_fetch"
            tool = Agentif.create_web_fetch_tool()
            prompt = "Tool calling is enabled. Call web_fetch now with url=\"https://example.com\" and extract_text=true. Return a tool call only."
            _, events = run_tool_call(model, apikey, tool, prompt)
            output = assert_tool_called(events, "web_fetch")
            @test occursin("Status:", output)
            @test occursin("Example Domain", output)
        end
        @testset "web_search" begin
            @info "Tool test: web_search"
            tool = Agentif.create_web_search_tool()
            prompt = "Tool calling is enabled. Call web_search now with query=\"Julia programming language\" and num_results=3. Return a tool call only."
            _, events = run_tool_call(model, apikey, tool, prompt)
            output = assert_tool_called(events, "web_search")
            @test occursin("Search results for", output)
            @test occursin("URL:", output)
        end
    end
end
