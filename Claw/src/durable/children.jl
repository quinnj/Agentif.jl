const DURABLE_NATIVE_ADAPTERS=IdDict{Any,Function}()
const DURABLE_RESOURCE_ADAPTERS=IdDict{Any,NamedTuple}()
const DURABLE_FILE_ADAPTERS=IdDict{Any,NamedTuple}()

function _register_coding_adapters!(tools)
    for (operation,tool) in zip((:read,:edit,:write),tools[1:3])
        DURABLE_FILE_ADAPTERS[tool]=(;replay=operation===:read ? :safe : :unsafe,capabilities=[String(operation)],
            invoke=(t,args,ctx)->begin
                task=_task_row(ctx.harness,ctx.task_id)
                resolved,reason=_resolve_profile(ctx.harness,JSON.parse(task.input_json)["profile"])
                reason===nothing || error(reason)
                env=resolved.env
                output=operation===:read ? LLMTools.env_read(env,args.path;offset=args.offset,limit=args.limit,abort=ctx.abort,deadline=ctx.deadline) :
                    operation===:edit ? LLMTools.env_edit(env,args.path,args.oldText,args.newText;abort=ctx.abort,deadline=ctx.deadline) :
                    LLMTools.env_write(env,args.path,args.content;abort=ctx.abort,deadline=ctx.deadline)
                Agentif.ToolOutcome(output)
            end)
    end
    tools
end
struct OwnedToolWait
    task::String
    output::String
end

function _register_resource_adapters!(tools,kind)
    for (operation,tool) in enumerate(tools)
        DURABLE_RESOURCE_ADAPTERS[tool]=(;replay=operation==3 ? :safe : :unsafe,
            invoke=(t,args,ctx)->_resource_operation!(kind,operation,t,args,ctx))
    end
    tools
end

function _resource_operation!(kind,operation,tool,args,ctx)
    h=ctx.harness
    t=_task_row(h,ctx.task_id)
    resources=_dread(db->_drows(db,"SELECT * FROM claw_managed_resources WHERE conversation_id=? AND kind=?",(t.conversation_id,kind)),h)
    if operation==3
        output=Agentif.invoke_parsed_tool(tool,args)
        interrupted=[JSON.parse(r.details)["name"] for r in resources if r.state=="interrupted"]
        isempty(interrupted) || (output*= "\nInterrupted after restart (process state unavailable): "*join(interrupted,", "))
        return Agentif.ToolOutcome(output)
    end
    name=args.name
    old=findlast(r->get(JSON.parse(r.details),"name",nothing)==name,resources)
    if operation==2 && old!==nothing && resources[old].state=="interrupted"
        return Agentif.ToolOutcome("Resource '$name' was interrupted by restart; start a new resource explicitly.";is_error=true)
    end
    resource=operation==1 ? record_managed_resource!(ctx;kind,key="resource:$(ctx.task_id)",details=Dict("name"=>name)) : nothing
    output=Agentif.invoke_parsed_tool(tool,args)
    if operation in (1,4)
        _transition!(h;context=ctx,point=:resource_receipt) do db,seq
            if operation==1
                _exec!(db,"UPDATE claw_managed_resources SET state='running' WHERE id=?",(resource,))
            else
                for r in resources
                    get(JSON.parse(r.details),"name",nothing)==name || continue
                    _exec!(db,"UPDATE claw_managed_resources SET state='closed' WHERE id=?",(r.id,))
                end
            end
        end
    end
    Agentif.ToolOutcome(output)
end

function _register_subagent_adapters!(tools)
    for (index,tool) in enumerate(tools)
        DURABLE_NATIVE_ADAPTERS[tool]=(t,args,ctx)->_subagent_operation!(index,args,ctx)
    end
    tools
end

function _subagent_operation!(operation,args,ctx)
    h=ctx.harness
    parent=_task_row(h,ctx.task_id)
    resolved,reason=_resolve_profile(h,JSON.parse(parent.input_json)["profile"])
    reason===nothing || error(reason)
    if operation==1
        occursin(r"^[a-z0-9]+(-[a-z0-9]+)*$",args.name) || throw(ArgumentError("invalid child alias"))
        child=Agentif.with_prompt(resolved.agent,args.system_prompt)
        specs=ToolSpec[h.specs[(m["name"],m["version"])] for m in resolved.profile["tools"]]
        profile=register_profile!(h,child;specs,environment=resolved.env,trust=Symbol(resolved.profile["trust"]),
            credential_ref=resolved.profile["credential_ref"])
        sync=args.run_sync===true
        event_type=h.assistant===nothing ? nothing : "subagent:$(parent.conversation_id):$(args.name)"
        if event_type!==nothing && !sync
            route=_dread(db->JSON.parse(_done(db,"SELECT routing FROM claw_conversations WHERE id=?",(parent.conversation_id,)).routing),h)
            prompt=something(args.prompt,"Sub-agent '$(args.name)' output")
            handler=EventHandler(event_type,[event_type],prompt,get(route,"channel_id",nothing);
                trust=Symbol(resolved.profile["trust"]),tools=String[m["name"] for m in resolved.profile["tools"]])
            register_event_handler!(h.assistant,handler)
        end
        created=create_owned_child!(ctx;creation_key="launch:$(ctx.task_id)",name=args.name,profile,input=args.input_message,
            event_type=sync ? nothing : event_type,owner_task=sync ? nothing : _dnull(parent.owner_task))
        return sync ? OwnedToolWait(created.task,"Sub-agent '$(args.name)' completed.") :
            Agentif.ToolOutcome("Sub-agent '$(args.name)' started as durable conversation $(created.conversation).")
    elseif operation==2
        alias=_dread(db->_done(db,"SELECT * FROM claw_child_aliases WHERE conversation_id=? AND name=?",(parent.conversation_id,args.name)),h)
        alias===nothing && throw(ArgumentError("unknown child alias"))
        sync=args.run_sync===true
        wrapper=_transition!(h;context=ctx,point=:child_followup) do db,seq
            c=_done(db,"SELECT * FROM claw_conversations WHERE id=?",(alias.child_id,))
            receipt=_admit!(db,seq,c,Agentif.UserMessage(args.input_message),"message:$(ctx.task_id)",:followup,Dict("owner"=>ctx.task_id),c.profile_id)
            wrapper=_task_create!(db,seq,parent.conversation_id,"child","message:$(ctx.task_id)";owner=sync ? ctx.task_id : _dnull(parent.owner_task),
                input=Dict("profile"=>c.profile_id,"child"=>c.id),checkpoint=Dict("phase"=>"join","submission"=>receipt))
            _exec!(db,"UPDATE claw_conversations SET owner_task=? WHERE id=?",(wrapper,c.id))
            _exec!(db,"UPDATE claw_child_aliases SET task_id=? WHERE conversation_id=? AND name=?",(wrapper,parent.conversation_id,args.name))
            wrapper
        end
        return sync ? OwnedToolWait(wrapper,"Sub-agent '$(args.name)' responded.") : Agentif.ToolOutcome("Message queued for durable sub-agent '$(args.name)'.")
    elseif operation==3
        aliases=_dread(db->_drows(db,"SELECT a.name,a.child_id,t.status,t.outcome FROM claw_child_aliases a JOIN claw_tasks t ON t.id=a.task_id WHERE a.conversation_id=? ORDER BY a.name",(parent.conversation_id,)),h)
        return Agentif.ToolOutcome(JSON.json(aliases))
    else
        alias=_dread(db->_done(db,"SELECT * FROM claw_child_aliases WHERE conversation_id=? AND name=?",(parent.conversation_id,args.name)),h)
        alias===nothing && return Agentif.ToolOutcome("No sub-agent named '$(args.name)'")
        abort_conversation!(h,alias.child_id)
        _transition!(h;context=ctx,point=:child_alias_remove) do db,seq
            _exec!(db,"DELETE FROM claw_child_aliases WHERE conversation_id=? AND name=?",(parent.conversation_id,args.name))
        end
        return Agentif.ToolOutcome("Sub-agent '$(args.name)' aborted")
    end
end

function _owned_tool_join!(ctx,t,e)
    h=ctx.harness
    cp=JSON.parse(t.checkpoint)
    child=_task_row(h,cp["child"])
    outcome=JSON.parse(child.outcome)
    output=cp["output"]
    if get(outcome,"entry",nothing)!==nothing
        entry=Agentif.get_entry(h.history,outcome["entry"])
        entry===nothing || isempty(entry.messages) || (output=Agentif.message_text(last(entry.messages)))
    end
    result=Agentif.ToolOutcome(output;is_error=get(outcome,"status","")!="completed")
    _transition!(h;context=ctx,point=:tool_result) do db,seq
        _tool_result!(db,h,seq,t,e,result)
    end
end

function record_managed_resource!(ctx::InvocationContext;kind::String,key::String,details=Dict{String,Any}())
    kind in ("pty","worker") || throw(ArgumentError("unsupported managed resource"))
    _transition!(ctx.harness;context=ctx,point=:resource_intent) do db,seq
        t=_done(db,"SELECT conversation_id FROM claw_tasks WHERE id=?",(ctx.task_id,))
        id=_did()
        _exec!(db,"INSERT OR IGNORE INTO claw_managed_resources VALUES(?,?,?,?,?,'running',?)",
            (id,t.conversation_id,ctx.task_id,kind,key,JSON.json(_sanitize_integration_value(details))))
        _done(db,"SELECT id FROM claw_managed_resources WHERE correlation_key=?",(key,)).id
    end
end
