function _tool_result!(db,h,seq,t,e,outcome;effect_state="completed")
    details=outcome.details===nothing ? nothing : JSON.parse(_bounded_json(_sanitize_integration_value(outcome.details),h.limits.progress_bytes))
    outcome=Agentif.ToolOutcome(outcome.output;is_error=outcome.is_error,details)
    c=_done(db,"SELECT * FROM claw_conversations WHERE id=?",(t.conversation_id,))
    message=Agentif.ToolResultMessage(e.call_id,e.tool_name,outcome.output;is_error=outcome.is_error)
    entry=_entry!(db,h,seq,c,[message];run=t.run_id,task=t.id,stop=outcome.is_error ? "tool_error" : "tool_result")
    _exec!(db,"UPDATE claw_tool_executions SET effect_state=?,result_entry=?,result=? WHERE task_id=?",
        (effect_state,entry,JSON.json(outcome),t.id))
    _finish_task!(db,t,Dict("status"=>"completed","is_error"=>outcome.is_error,"entry"=>entry))
end

function _tool_intents!(db,h,seq,t,c,entry,calls,resolved)
    children=String[]
    sequential=any(call -> begin
        s=findfirst(m->m["name"]==call.name,resolved.profile["tools"])
        s!==nothing && resolved.profile["tools"][s]["execution"]=="sequential"
    end,calls)
    for (ordinal,call) in enumerate(calls)
        index=findfirst(m->m["name"]==call.name,resolved.profile["tools"])
        manifest=index===nothing ? nothing : resolved.profile["tools"][index]
        args=nothing;failure=nothing
        if manifest===nothing
            failure="unknown_tool"
        else
            spec=h.specs[(call.name,manifest["version"])]
            try
                args=Agentif.parse_tool_arguments(call.arguments,Agentif.parameters(spec.tool))
                all(cap->cap in resolved.env.ref.capabilities,spec.capabilities) || throw(ArgumentError("environment capability denied"))
            catch err
                failure="tool_argument_parse_failed: "*_diagnostic(h,err)
            end
        end
        id=_task_create!(db,seq,c.id,"tool","$entry:$(call.call_id)";run=t.run_id,owner=t.id,
            input=Dict("profile"=>JSON.parse(t.input_json)["profile"]),checkpoint=Dict("phase"=>"execute"))
        push!(children,id)
        if failure!==nothing
            result=Agentif.ToolResultMessage(call.call_id,call.name,JSON.json(Dict("error_kind"=>failure));is_error=true)
            _entry!(db,h,seq,c,[result];run=t.run_id,task=id)
            _exec!(db,"UPDATE claw_tasks SET status='terminal',outcome=? WHERE id=?",(JSON.json(Dict("status"=>"completed","is_error"=>true)),id))
            continue
        end
        raw=JSON.json(args)
        _exec!(db,"""INSERT INTO claw_tool_executions(task_id,conversation_id,assistant_entry,call_id,ordinal,tool_name,manifest,
            args,args_hash,env,profile_id,effect_key,effect_state) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,'ready')""",
            (id,c.id,entry,call.call_id,ordinal,call.name,JSON.json(manifest),raw,_digest(JSON.parse(raw)),JSON.json(resolved.profile["env"]),
             JSON.parse(t.input_json)["profile"],"tool:$id"))
        if sequential && ordinal>1
            previous=children[ordinal-1]
            _exec!(db,"UPDATE claw_tasks SET checkpoint=? WHERE id=?",(JSON.json(Dict("phase"=>"execute","after"=>previous)),id))
        end
    end
    return children
end

function report_progress!(ctx::InvocationContext,value)
    lock(ctx.lock) do
        _dread(ctx.harness) do db
            task=_done(db,"SELECT status,token,revision,cancel FROM claw_tasks WHERE id=?",(ctx.task_id,))
            epoch=_done(db,"SELECT owner_epoch FROM claw_runtime_meta WHERE id=1").owner_epoch
            ctx.harness.state===:open && epoch==ctx.epoch && task!==nothing && task.status=="running" && task.token==ctx.token && task.revision==ctx.revision[] && task.cancel==0 || throw(StaleInvocation())
        end
        ctx.heartbeat[]=time()
        ctx.harness.clock()-ctx.last_progress[] >= ctx.harness.limits.progress_interval || return
        text=_bounded_json(_sanitize_integration_value(value),ctx.harness.limits.progress_bytes)
        _transition!(ctx.harness;context=ctx,point=:tool_progress) do db,seq
            _exec!(db,"UPDATE claw_tasks SET progress=? WHERE id=?",(text,ctx.task_id))
        end
        ctx.last_progress[]=ctx.harness.clock()
    end
end

function _tool_phase!(ctx,t,resolved)
    h=ctx.harness
    e=_dread(db->_done(db,"SELECT * FROM claw_tool_executions WHERE task_id=?",(t.id,)),h)
    e===nothing && error("missing tool execution intent")
    get(JSON.parse(t.checkpoint),"phase","")=="child_join" && return _owned_tool_join!(ctx,t,e)
    manifest=JSON.parse(e.manifest)
    spec=h.specs[(e.tool_name,manifest["version"])]
    _spec_data(spec)==manifest && resolved.profile["env"]==JSON.parse(e.env) || error("tool intent compatibility mismatch")
    _digest(JSON.parse(e.args))==e.args_hash || error("corrupt final tool arguments")
    if e.effect_state=="uncertain"
        spec.reconcile===nothing && return _block_invocation!(ctx,"uncertain effect: $(e.effect_key)")
        result=spec.reconcile(e)
        result===nothing && return _block_invocation!(ctx,"uncertain effect: $(e.effect_key)")
        if result isa Agentif.ToolOutcome
            return _transition!(h;context=ctx,point=:tool_result) do db,seq
                _tool_result!(db,h,seq,t,e,result;effect_state="reconciled")
            end
        end
        result===:retry || error("invalid effect reconciliation result")
    end
    args=Agentif.parse_tool_arguments(e.args,Agentif.parameters(spec.tool))
    _transition!(h;context=ctx,point=:tool_intent) do db,seq
        _exec!(db,"UPDATE claw_tool_executions SET effect_state='executing' WHERE task_id=?",(t.id,))
    end
    h.fault(:before_effect_body,h)
    _verify_invocation!(ctx)
    outcome=try
        result=spec.invoke(spec.tool,args,ctx)
        if result isa OwnedToolWait
            return _transition!(h;context=ctx,point=:tool_child_wait) do db,seq
                _exec!(db,"UPDATE claw_tool_executions SET effect_state='owned_child' WHERE task_id=?",(t.id,))
                _exec!(db,"UPDATE claw_tasks SET checkpoint=? WHERE id=?",(JSON.json(Dict("phase"=>"child_join","child"=>result.task,"output"=>result.output)),t.id))
                _wait_tasks!(db,t.id,[result.task])
            end
        end
        result isa Agentif.ToolOutcome ? result : Agentif.ToolOutcome(string(result))
    catch err
        if spec.replay===:unsafe
            return _transition!(h;context=ctx,point=:tool_uncertain) do db,seq
                _exec!(db,"UPDATE claw_tool_executions SET effect_state='uncertain' WHERE task_id=?",(t.id,))
                _exec!(db,"UPDATE claw_tasks SET status='pending',token=NULL,blocked=? WHERE id=?",("uncertain effect: "*_diagnostic(h,err),t.id))
            end
        end
        Agentif.ToolOutcome(JSON.json(Dict("error_kind"=>"tool_fault","message"=>_diagnostic(h,err)));is_error=true)
    end
    h.fault(:after_effect_body,h)
    _transition!(h;context=ctx,point=:tool_result) do db,seq
        _tool_result!(db,h,seq,t,e,outcome)
    end
end

function _verify_invocation!(ctx)
    Agentif.check_abort(ctx.abort)
    time()<=ctx.deadline || throw(Agentif.AbortEvaluation())
    _dread(ctx.harness) do db
        t=_done(db,"SELECT status,token,epoch,revision,cancel FROM claw_tasks WHERE id=?",(ctx.task_id,))
        epoch=_done(db,"SELECT owner_epoch FROM claw_runtime_meta WHERE id=1").owner_epoch
        ctx.harness.state===:open && epoch==ctx.epoch && t!==nothing && t.status=="running" && t.token==ctx.token &&
            t.epoch==ctx.epoch && t.revision==ctx.revision[] && t.cancel==0 || throw(StaleInvocation())
    end
    nothing
end

execution_intent(ctx::InvocationContext)=_dread(db->_done(db,"SELECT * FROM claw_tool_executions WHERE task_id=?",(ctx.task_id,)),ctx.harness)
function execution_environment(ctx::InvocationContext)
    t=_task_row(ctx.harness,ctx.task_id)
    resolved,reason=_resolve_profile(ctx.harness,JSON.parse(t.input_json)["profile"])
    reason===nothing || error(reason)
    resolved.env
end

"""Resolve an uncertain effect from operator evidence. This never silently retries
an unsafe body. `result` records the operator's selected model-visible outcome.
"""
function resolve_effect!(h::Harness,id::String,result::Agentif.ToolOutcome;note::String)
    isempty(strip(note)) && throw(ArgumentError("resolution evidence is required"))
    _transition!(h;point=:effect_resolution) do db,seq
        t=_done(db,"SELECT * FROM claw_tasks WHERE id=?",(id,))
        e=_done(db,"SELECT * FROM claw_tool_executions WHERE task_id=?",(id,))
        e!==nothing && e.effect_state=="uncertain" && t.status=="pending" || throw(ArgumentError("effect is not parked uncertain"))
        _exec!(db,"UPDATE claw_tasks SET progress=? WHERE id=?",(JSON.json(Dict("resolution"=>first(note,2000))),id))
        _tool_result!(db,h,seq,t,e,result;effect_state="operator_resolved")
    end
    notify(h.wake)
end
