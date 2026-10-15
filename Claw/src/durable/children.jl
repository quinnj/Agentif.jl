# Durable contracts for Claw's built-in tools, keyed by tool object: the
# `ToolSpec` keywords (`version`, `replay`, `effect`, `capabilities`, `invoke`)
# that `register_profile!` uses instead of the unsafe legacy default.
const DURABLE_TOOL_ADAPTERS = IdDict{Any, NamedTuple}()

function _register_coding_adapters!(tools)
    for (operation, tool) in zip((:read, :edit, :write), tools[1:3])
        DURABLE_TOOL_ADAPTERS[tool] = (;
            version = "durable-file-v1", replay = operation === :read ? :safe : :unsafe, effect = :file,
            capabilities = [String(operation)], invoke = (t, args, ctx) -> begin
                env = execution_environment(ctx)
                output = operation === :read ? LLMTools.env_read(env, args.path; offset = args.offset, limit = args.limit, abort = ctx.abort, deadline = ctx.deadline) :
                    operation === :edit ? LLMTools.env_edit(env, args.path, args.oldText, args.newText; abort = ctx.abort, deadline = ctx.deadline) :
                    LLMTools.env_write(env, args.path, args.content; abort = ctx.abort, deadline = ctx.deadline)
                return Agentif.ToolOutcome(output)
            end,
        )
    end
    # The terminal tools run native commands: they need the shell capability.
    for tool in tools[4:end]
        DURABLE_TOOL_ADAPTERS[tool] = (; version = "durable-shell-v1", capabilities = ["shell"])
    end
    return tools
end
struct OwnedToolWait
    task::String
    output::String
end

function _register_resource_adapters!(tools, kind)
    for (operation, tool) in enumerate(tools)
        DURABLE_TOOL_ADAPTERS[tool] = (;
            version = "durable-resource-v1", replay = operation == 3 ? :safe : :unsafe, effect = :resource,
            capabilities = ["shell"], invoke = (t, args, ctx) -> _resource_operation!(kind, operation, t, args, ctx),
        )
    end
    return tools
end

function _resource_operation!(kind, operation, tool, args, ctx)
    h = ctx.harness
    t = _task_row(h, ctx.task_id)
    resources = _on_writer(db -> _fetch_all(db, "SELECT * FROM claw_managed_resources WHERE conversation_id=? AND kind=?", (t.conversation_id, kind)), h)
    if operation == 3
        output = Agentif.invoke_parsed_tool(tool, args)
        interrupted = [JSON.parse(r.details)["name"] for r in resources if r.state == "interrupted"]
        isempty(interrupted) || (output *= "\nInterrupted after restart (process state unavailable): " * join(interrupted, ", "))
        return Agentif.ToolOutcome(output)
    end
    name = args.name
    old = findlast(r -> get(JSON.parse(r.details), "name", nothing) == name, resources)
    if operation == 2 && old !== nothing && resources[old].state == "interrupted"
        return Agentif.ToolOutcome("Resource '$name' was interrupted by restart; start a new resource explicitly."; is_error = true)
    end
    resource = operation == 1 ? record_managed_resource!(ctx; kind, key = "resource:$(ctx.task_id)", details = Dict("name" => name)) : nothing
    output = try
        Agentif.invoke_parsed_tool(tool, args)
    catch
        # A launch that failed leaves no running resource behind.
        resource === nothing || _transition!(h; context = ctx, point = :resource_failed) do db, seq
            _exec!(db, "UPDATE claw_managed_resources SET state='failed' WHERE id=?", (resource,))
        end
        rethrow()
    end
    if operation in (1, 4)
        _transition!(h; context = ctx, point = :resource_receipt) do db, seq
            if operation == 1
                _exec!(db, "UPDATE claw_managed_resources SET state='running' WHERE id=?", (resource,))
            else
                for r in resources
                    get(JSON.parse(r.details), "name", nothing) == name || continue
                    _exec!(db, "UPDATE claw_managed_resources SET state='closed' WHERE id=?", (r.id,))
                end
            end
        end
    end
    return Agentif.ToolOutcome(output)
end

function _register_subagent_adapters!(tools)
    for (index, tool) in enumerate(tools)
        DURABLE_TOOL_ADAPTERS[tool] = (;
            version = "durable-child-v1", replay = :safe, effect = :child,
            invoke = (t, args, ctx) -> _subagent_operation!(index, args, ctx),
        )
    end
    return tools
end

function _child_notification!(h, parent, resolved, name, prompt)
    h.assistant === nothing && return nothing
    event_type = "subagent:$(parent.conversation_id):$name"
    route = _on_writer(db -> JSON.parse(_fetch_one(db, "SELECT routing FROM claw_conversations WHERE id=?", (parent.conversation_id,)).routing), h)
    _on_writer(h) do db
        _exec!(db, "INSERT OR IGNORE INTO claw_event_types(name,description) VALUES(?,?)", (event_type, "Durable child completion: $name"))
    end
    register_event_handler!(
        h.assistant, EventHandler(
            event_type, [event_type], prompt, get(route, "channel_id", nothing);
            trust = Symbol(resolved.profile["trust"]), tools = String[m["name"] for m in resolved.profile["tools"]]
        )
    )
    return event_type
end

function _restore_child_event_types!(h)
    return _on_writer(h) do db
        for a in _fetch_all(db, "SELECT name,event_type FROM claw_child_aliases WHERE event_type IS NOT NULL")
            _exec!(db, "INSERT OR IGNORE INTO claw_event_types(name,description) VALUES(?,?)", (a.event_type, "Durable child completion: $(a.name)"))
        end
    end
end

function _subagent_operation!(operation, args, ctx)
    h = ctx.harness
    parent = _task_row(h, ctx.task_id)
    resolved, reason = _resolve_profile(h, JSON.parse(parent.input_json)["profile"])
    reason === nothing || error(reason)
    if operation == 1
        occursin(r"^[a-z0-9]+(-[a-z0-9]+)*$", args.name) || throw(ArgumentError("invalid child alias"))
        child = Agentif.with_prompt(resolved.agent, args.system_prompt)
        specs = ToolSpec[h.specs[(m["name"], m["version"])] for m in resolved.profile["tools"]]
        profile = register_profile!(
            h, child; specs, environment = resolved.env, trust = Symbol(resolved.profile["trust"]),
            credential_ref = resolved.profile["credential_ref"]
        )
        sync = args.run_sync === true
        event_type = sync ? nothing : _child_notification!(h, parent, resolved, args.name, something(args.prompt, "Sub-agent '$(args.name)' output"))
        # An asynchronous child is background work: it must not hold the parent's
        # run open (or block the parent conversation's next input) until it ends.
        created = create_owned_child!(
            ctx; creation_key = "launch:$(ctx.task_id)", name = args.name, profile, input = args.input_message,
            event_type = sync ? nothing : event_type, background = !sync
        )
        return sync ? OwnedToolWait(created.task, "Sub-agent '$(args.name)' completed.") :
            Agentif.ToolOutcome("Sub-agent '$(args.name)' started as durable conversation $(created.conversation).")
    elseif operation == 2
        alias = _on_writer(db -> _fetch_one(db, "SELECT * FROM claw_child_aliases WHERE conversation_id=? AND name=?", (parent.conversation_id, args.name)), h)
        alias === nothing && throw(ArgumentError("unknown child alias"))
        sync = args.run_sync === true
        mode = Symbol(args.mode)
        mode in (:followup, :steer) || throw(ArgumentError("child message mode must be followup or steer"))
        event_type = sync ? nothing : _child_notification!(h, parent, resolved, args.name, "Sub-agent '$(args.name)' output")
        wrapper = _transition!(h; context = ctx, point = :child_followup) do db, seq
            c = _fetch_one(db, "SELECT * FROM claw_conversations WHERE id=?", (alias.child_id,))
            receipt = _admit!(db, seq, c, Agentif.UserMessage(args.input_message), "message:$(ctx.task_id)", mode, Dict("owner" => ctx.task_id), c.profile_id)
            wrapper = _task_create!(
                db, seq, parent.conversation_id, "child", "message:$(ctx.task_id)"; owner = sync ? ctx.task_id : nothing,
                background = !sync, input = Dict("profile" => c.profile_id, "child" => c.id, "event_type" => event_type, "name" => args.name),
                checkpoint = Dict("phase" => "join", "submission" => receipt)
            )
            _exec!(db, "UPDATE claw_conversations SET owner_task=? WHERE id=?", (wrapper, c.id))
            _exec!(db, "UPDATE claw_child_aliases SET task_id=?,event_type=? WHERE conversation_id=? AND name=?", (wrapper, event_type, parent.conversation_id, args.name))
            wrapper
        end
        return sync ? OwnedToolWait(wrapper, "Sub-agent '$(args.name)' responded.") : Agentif.ToolOutcome("Message queued for durable sub-agent '$(args.name)'.")
    elseif operation == 3
        aliases = _on_writer(db -> _fetch_all(db, "SELECT a.name,a.child_id,t.status,t.outcome FROM claw_child_aliases a JOIN claw_tasks t ON t.id=a.task_id WHERE a.conversation_id=? ORDER BY a.name", (parent.conversation_id,)), h)
        return Agentif.ToolOutcome(JSON.json(aliases))
    else
        alias = _on_writer(db -> _fetch_one(db, "SELECT * FROM claw_child_aliases WHERE conversation_id=? AND name=?", (parent.conversation_id, args.name)), h)
        alias === nothing && return Agentif.ToolOutcome("No sub-agent named '$(args.name)'")
        abort_conversation!(h, alias.child_id; include_background = true)
        _transition!(h; context = ctx, point = :child_alias_remove) do db, seq
            _exec!(db, "DELETE FROM claw_child_aliases WHERE conversation_id=? AND name=?", (parent.conversation_id, args.name))
        end
        return Agentif.ToolOutcome("Sub-agent '$(args.name)' aborted")
    end
end

function _owned_tool_join!(ctx, t, e)
    h = ctx.harness
    cp = JSON.parse(t.checkpoint)
    child = _task_row(h, cp["child"])
    outcome = JSON.parse(child.outcome)
    output = cp["output"]
    if get(outcome, "entry", nothing) !== nothing
        entry = Agentif.get_entry(h.history, outcome["entry"])
        entry === nothing || isempty(entry.messages) || (output = Agentif.message_text(last(entry.messages)))
    end
    result = Agentif.ToolOutcome(output; is_error = get(outcome, "status", "") != "completed")
    return _transition!(h; context = ctx, point = :tool_result) do db, seq
        _tool_result!(db, h, seq, t, e, result)
    end
end

function record_managed_resource!(ctx::InvocationContext; kind::String, key::String, details = Dict{String, Any}())
    kind in ("pty", "worker") || throw(ArgumentError("unsupported managed resource"))
    return _transition!(ctx.harness; context = ctx, point = :resource_intent) do db, seq
        t = _fetch_one(db, "SELECT conversation_id FROM claw_tasks WHERE id=?", (ctx.task_id,))
        id = _new_id()
        _exec!(
            db, "INSERT OR IGNORE INTO claw_managed_resources VALUES(?,?,?,?,?,'running',?)",
            (id, t.conversation_id, ctx.task_id, kind, key, JSON.json(_sanitize_integration_value(details)))
        )
        _fetch_one(db, "SELECT id FROM claw_managed_resources WHERE correlation_key=?", (key,)).id
    end
end
