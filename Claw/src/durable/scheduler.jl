function _recover_harness!(h)
    _transition!(h;point=:recovery) do db,seq
        for t in _drows(db,"SELECT * FROM claw_tasks WHERE status='running'")
            if t.kind in ("generation","compaction","filter","watcher")
                _exec!(db,"UPDATE claw_task_attempts SET unknown_spend=1,ended_seq=?,failure='process_interrupted' WHERE task_id=? AND ended_seq IS NULL",(seq,t.id))
                if _dnull(t.progress)!==nothing
                    c=_done(db,"SELECT * FROM claw_conversations WHERE id=?",(t.conversation_id,))
                    _entry!(db,h,seq,c,[];run=_dnull(t.run_id),task=t.id,audit=JSON.parse(t.progress),stop="interrupted")
                end
            elseif t.kind=="tool"
                e=_done(db,"SELECT * FROM claw_tool_executions WHERE task_id=?",(t.id,))
                if e!==nothing && e.effect_state=="executing"
                    manifest=JSON.parse(e.manifest)
                    state=manifest["replay"]=="safe" ? "ready" : "uncertain"
                    _exec!(db,"UPDATE claw_tool_executions SET effect_state=? WHERE task_id=?",(state,t.id))
                end
            end
            _exec!(db,"UPDATE claw_tasks SET status='pending',token=NULL,revision=revision+1,progress=NULL WHERE id=?",(t.id,))
        end
        _exec!(db,"UPDATE claw_managed_resources SET state='interrupted' WHERE state='running'")
        _exec!(db,raw"""UPDATE claw_evals SET status='running',failure_class=NULL,finished_at=NULL WHERE id IN
            (SELECT json_extract(input_json,'$.supervision.eval_id') FROM claw_tasks WHERE kind='generation' AND status!='terminal')""")
        _reconcile_ownership!(db,h,seq)
    end
end

function _block_invocation!(ctx,reason)
    _transition!(ctx.harness;context=ctx,point=:blocked) do db,seq
        _exec!(db,"UPDATE claw_tasks SET status='pending',token=NULL,blocked=? WHERE id=?",(reason,ctx.task_id))
    end
end

function _eligibility(h,t)
    t.version==1 && t.codec==1 || return nothing,"unsupported task definition or codec version"
    t.kind in ("generation","compaction","filter","watcher","tool","delivery","child") || return nothing,"unknown task definition $(t.kind)"
    cp=try JSON.parse(t.checkpoint) catch; return nothing,"corrupt task checkpoint" end
    input=try JSON.parse(t.input_json) catch; return nothing,"corrupt task input" end
    cp isa AbstractDict || return nothing,"corrupt task checkpoint"
    input isa AbstractDict || return nothing,"corrupt task input"
    t.kind=="watcher" && _watcher_expired!(h,t) && return (;),nothing
    if t.kind=="delivery"
        o=_dread(db->_done(db,"SELECT * FROM claw_outbox WHERE id=?",(get(input,"outbox",""),)),h)
        o===nothing && return nothing,"missing outbox intent"
        a=JSON.parse(o.address)
        adapter=lock(()->get(h.adapters,a["adapter"],nothing),h.lock)
        adapter===nothing && return nothing,"delivery adapter unavailable"
        adapter.version==a["version"] || return nothing,"delivery version incompatible"
        String(adapter.capability)==get(a,"capability","unsafe") || return nothing,"delivery capability incompatible"
        o.state=="sent" && return (;),nothing
        o.state=="redacted" && return nothing,"redacted delivery"
        available=try adapter.available(a["routing"]) catch err; return nothing,"delivery source/credentials unavailable: "*_diagnostic(h,err) end
        available || return nothing,"delivery source/credentials unavailable"
        o.state=="uncertain" && adapter.capability==:unsafe && return nothing,"uncertain delivery"
        return (;),nothing
    end
    resolved,reason=_resolve_profile(h,get(input,"profile",""))
    reason===nothing || return nothing,reason
    if t.kind=="tool"
        e=_dread(db->_done(db,"SELECT * FROM claw_tool_executions WHERE task_id=?",(t.id,)),h)
        e===nothing && return nothing,"missing tool intent"
        manifest=JSON.parse(e.manifest)
        spec=get(h.specs,(e.tool_name,manifest["version"]),nothing)
        spec===nothing && return nothing,"tool version unavailable"
        e.effect_state=="uncertain" && spec.reconcile===nothing && return nothing,"uncertain effect: $(e.effect_key)"
        if haskey(cp,"after")
            previous=_task_row(h,cp["after"])
            previous.status=="terminal" || return nothing,"waiting for sequential predecessor"
        end
    end
    return resolved,nothing
end

function _reserve!(h,t)
    lock(()->haskey(h.live,t.id),h.lock) && return nothing
    group=t.kind in ("tool","delivery") ? :tool : t.kind in ("generation","compaction","filter","watcher") && get(JSON.parse(t.checkpoint),"phase","")=="request" ? :model : :local
    t.kind=="watcher" && _watcher_expired!(h,t) && (group=:local)
    active=lock(()->count(x->x.group==group,values(h.live)),h.lock)
    group==:model && active>=h.limits.models && return nothing
    group==:tool && active>=h.limits.tools && return nothing
    token=_did()
    revision=_transition!(h;point=:reserve) do db,seq
        _exec!(db,"UPDATE claw_tasks SET status='running',epoch=?,token=?,revision=revision+1,blocked=NULL WHERE id=? AND status='pending' AND revision=? AND cancel=0",
            (h.epoch,token,t.id,t.revision))
        Int(_scalar(db,"SELECT changes()"))==1 || throw(StaleInvocation())
        Int(t.revision)+1
    end
    timeout=group==:tool ? h.limits.tool_timeout : h.limits.request_timeout
    issued=JSON.parse(t.input_json)
    run_key="deadline:"*something(_dnull(t.run_id),t.id)
    maximum=t.kind=="watcher" ? get(issued,"timeout",h.limits.request_timeout) : h.limits.run_timeout
    end_at=_deadline_timer!(h,run_key,get(issued,"deadline",h.clock()+timeout),maximum)
    remaining=min(timeout,max(0,end_at-_dmono()))
    ctx=InvocationContext(h,t.id,h.epoch,token,Ref(revision),Agentif.Abort(),time()+remaining,_dmono()+remaining,
        ReentrantLock(),Ref(-Inf),Ref(_dmono()))
    return ctx,group
end

function _phase_fault!(ctx,error)
    h=ctx.harness
    h.state===:open || return
    _transition!(h;point=:phase_fault) do db,seq
        t=_done(db,"SELECT * FROM claw_tasks WHERE id=?",(ctx.task_id,))
        t.status=="running" && t.token==ctx.token || return
        if t.cancel==1
            reason=get(JSON.parse(t.input_json),"abort_reason","user_abort")
            _exec!(db,"UPDATE claw_task_attempts SET unknown_spend=1,ended_seq=?,failure=? WHERE task_id=? AND ended_seq IS NULL",(seq,reason,t.id))
            t.kind=="tool" && _exec!(db,"UPDATE claw_tool_executions SET effect_state='uncertain' WHERE task_id=? AND effect_state='executing'",(t.id,))
            _finish_task!(db,t,Dict("status"=>"aborted","reason"=>reason))
            if t.kind=="generation"
                _exec!(db,"UPDATE claw_runs SET status='aborted',reason=? WHERE id=?",(reason,t.run_id))
                _exec!(db,"UPDATE claw_submissions SET state='unanswered',reason=? WHERE run_id=? AND state='placed'",(reason,t.run_id))
            end
        elseif t.kind=="tool"
            _exec!(db,"UPDATE claw_tool_executions SET effect_state='uncertain' WHERE task_id=? AND effect_state='executing'",(t.id,))
            _exec!(db,"UPDATE claw_tasks SET status='pending',token=NULL,blocked=? WHERE id=?",("uncertain effect: "*_diagnostic(h,error),t.id))
        elseif t.kind=="generation"
            _exec!(db,"UPDATE claw_task_attempts SET unknown_spend=1,ended_seq=?,failure='phase_fault' WHERE task_id=? AND ended_seq IS NULL",(seq,t.id))
            c=_done(db,"SELECT * FROM claw_conversations WHERE id=?",(t.conversation_id,))
            _generation_settle!(db,h,seq,t,c;reason="phase_fault",audit=Dict("error"=>_diagnostic(h,error)))
        elseif t.kind=="delivery"
            id=JSON.parse(t.input_json)["outbox"]
            _exec!(db,"UPDATE claw_outbox SET state='uncertain',error=? WHERE id=?",(_diagnostic(h,error),id))
            _exec!(db,"UPDATE claw_tasks SET status='pending',token=NULL,blocked='uncertain delivery' WHERE id=?",(t.id,))
        elseif t.kind=="watcher"
            _watcher_settle!(db,h,seq,t,nothing)
        else
            _exec!(db,"UPDATE claw_task_attempts SET unknown_spend=1,ended_seq=?,failure='phase_fault' WHERE task_id=? AND ended_seq IS NULL",(seq,t.id))
            _finish_task!(db,t,Dict("status"=>"faulted","error"=>_diagnostic(h,error)))
        end
    end
end

function _child_phase!(ctx,t)
    h=ctx.harness
    cp=JSON.parse(t.checkpoint)
    _transition!(h;context=ctx,point=:child_join) do db,seq
        s=_done(db,"SELECT * FROM claw_submissions WHERE id=?",(cp["submission"],))
        if s.state in ("queued","placed")
            run=_dnull(s.run_id)===nothing ? nothing : _done(db,"SELECT task_id FROM claw_runs WHERE id=?",(s.run_id,))
            if run===nothing
                _exec!(db,"UPDATE claw_tasks SET status='pending',token=NULL,due_at=? WHERE id=?",(h.clock()+.02,t.id))
            else
                _wait_tasks!(db,t.id,[run.task_id])
            end
            return
        end
        status=s.state=="answered" ? "completed" : "failed"
        _finish_task!(db,t,Dict("status"=>status,"submission"=>s.id,"entry"=>_dnull(s.answer_entry)))
        alias=_done(db,"SELECT * FROM claw_child_aliases WHERE task_id=?",(t.id,))
        if alias!==nothing && _dnull(alias.event_type)!==nothing
            oid=_did();key="child-completion:$(t.id)"
            address=JSON.json(DeliveryAddress("claw-child-event",1,Dict("event_type"=>alias.event_type,"name"=>alias.name)))
            issued=JSON.parse(address);issued["capability"]="idempotent";address=JSON.json(issued)
            _exec!(db,"INSERT OR IGNORE INTO claw_outbox(id,conversation_id,entry_id,logical_key,address,body,state) VALUES(?,?,?,?,?,?,'pending')",
                (oid,t.conversation_id,_dnull(s.answer_entry),key,address,
                    s.answer_entry===missing || s.answer_entry===nothing ? JSON.json(Dict("submission"=>s.id,"state"=>s.state)) :
                    join(Agentif.message_text.(JSON.parse(_done(db,"SELECT entry FROM session_entries WHERE entry_id=?",(s.answer_entry,)).entry,Agentif.SessionEntry).messages),"\n")))
            _task_create!(db,seq,t.conversation_id,"delivery",key;background=true,input=Dict("outbox"=>oid),checkpoint=Dict("phase"=>"send"))
        end
    end
end

function _invoke_phase!(ctx,resolved)
    h=ctx.harness
    try
        t=_task_row(h,ctx.task_id)
        t.kind=="generation" ? _generation_phase!(ctx,t,resolved) :
            t.kind=="compaction" ? _model_request!(ctx,t,resolved;summary=true) :
            t.kind in ("filter","watcher") ? _model_request!(ctx,t,resolved;purpose=true) :
            t.kind=="tool" ? _tool_phase!(ctx,t,resolved) :
            t.kind=="delivery" ? _delivery_phase!(ctx,t) : _child_phase!(ctx,t)
        current=_task_row(h,t.id)
        current.status=="running" && current.token==ctx.token && error("phase returned without checkpoint, wait, or outcome")
    catch err
        if !(err isa StaleInvocation) && h.state!==:poisoned
            try _phase_fault!(ctx,err) catch; h.state=:poisoned end
        end
    finally
        lock(h.lock) do
            current=get(h.live,ctx.task_id,nothing)
            current===nothing || current.context!==ctx || delete!(h.live,ctx.task_id)
        end
        notify(h.wake)
    end
end

function _deadline_timer!(h,key,due,maximum_delay)
    wall=Float64(due)
    lock(h.lock) do
        saved=get(h.due_timers,key,nothing)
        if saved===nothing || saved[1]!=wall
            saved=(wall,_dmono()+clamp(wall-h.clock(),0,maximum_delay))
            h.due_timers[key]=saved
        end
        saved[2]
    end
end
function _is_due!(h,key,due)
    end_at=_deadline_timer!(h,key,due,h.limits.max_retry_delay)
    # UTC is the restart record; a live monotonic timer prevents a wall-clock
    # correction from extending a retry indefinitely. Overdue timers run now.
    h.clock()>=due || _dmono()>=end_at
end
function _watcher_expired!(h,t)
    issued=JSON.parse(t.input_json)
    due=get(issued,"deadline",Inf)
    _dmono()>=_deadline_timer!(h,"deadline:"*t.id,due,get(issued,"timeout",h.limits.request_timeout))
end

function _ownership_ready(db,h)
    live=lock(()->collect(keys(h.live)),h.lock)
    for t in _drows(db,"SELECT id,status,cancel FROM claw_tasks WHERE status IN ('waiting','completing') OR (cancel=1 AND status!='terminal')")
        t.cancel==1 && t.status!="completing" && !(t.id in live) && return true
        if t.status=="completing"
            _done(db,"SELECT id FROM claw_tasks WHERE owner_task=? AND background=0 AND status!='terminal' LIMIT 1",(t.id,))===nothing && return true
        elseif t.status=="waiting"
            waits=_drows(db,"SELECT t.status,t.cancel,t.outcome,w.policy FROM claw_task_waits w JOIN claw_tasks t ON t.id=w.awaited WHERE w.waiter=?",(t.id,))
            all(w->w.status=="terminal",waits) && return true
            failed=any(w->w.policy=="failFast" && w.status=="terminal" && get(JSON.parse(something(_dnull(w.outcome),"{}")),"status","")!="completed",waits)
            failed && any(w->w.status!="terminal" && w.cancel==0,waits) && return true
        end
    end
    false
end

function _scheduler_loop(h)
    while h.state===:open
        try
            _start_runs!(h)
            _dmono()>=h.supervision_due && _supervise_durable!(h)
            needs_join=_dread(db->_ownership_ready(db,h),h)
            needs_dispatch=_dread(db->_done(db,"""SELECT e.id FROM claw_events e WHERE e.status='dispatched' AND NOT EXISTS
                (SELECT 1 FROM claw_dispatch_members m JOIN claw_event_dispatches d ON d.id=m.dispatch_id
                 LEFT JOIN claw_submissions s ON s.id=d.submission_id WHERE m.event_id=e.id AND d.result IS NULL
                 AND (s.state IS NULL OR s.state NOT IN ('answered','unanswered','withdrawn'))) LIMIT 1"""),h)
            if needs_join || needs_dispatch!==nothing
                _transition!(h;point=:joins) do db,seq
                    _reconcile_ownership!(db,h,seq)
                    _aggregate_dispatches!(db,h)
                end
            end
            tasks=_dread(db->_drows(db,"SELECT * FROM claw_tasks WHERE status='pending' AND cancel=0 ORDER BY created_seq,rowid"),h)
            if length(h.due_timers)>256
                ongoing=_dread(db->_drows(db,"SELECT id,run_id FROM claw_tasks WHERE status!='terminal'"),h)
                keep=Set{String}()
                for t in ongoing
                    push!(keep,t.id,"deadline:"*something(_dnull(t.run_id),t.id),"supervision:"*t.id,"abort:"*t.id)
                end
                lock(h.lock) do
                    filter!(p->p.first in keep,h.due_timers)
                end
            end
            for t in tasks
                h.state===:open || break
                _is_due!(h,t.id,t.due_at) || continue
                resolved,reason=_eligibility(h,t)
                if reason!==nothing
                    if _dnull(t.blocked)!=reason
                        _transition!(h;point=:compatibility) do db,seq
                            _exec!(db,"UPDATE claw_tasks SET blocked=? WHERE id=? AND status='pending'",(reason,t.id))
                        end
                    end
                    continue
                end
                reserved=_reserve!(h,t)
                reserved===nothing && continue
                ctx,group=reserved
                gate=Threads.Event()
                worker=Threads.@spawn begin
                    wait(gate)
                    _invoke_phase!(ctx,resolved)
                end
                lock(h.lock) do
                    h.live[t.id]=(;context=ctx,task=worker,group)
                end
                notify(gate)
            end
            for live in lock(()->collect(values(h.live)),h.lock)
                _dmono()>live.context.monotonic_deadline && Agentif.abort!(live.context.abort)
            end
            if h.assistant!==nothing && (h.indexer===nothing || istaskdone(h.indexer))
                job=_dread(db->_done(db,"SELECT entry_id FROM claw_index_jobs WHERE state IN ('pending','redacted') AND due_at<=? LIMIT 1",(h.clock(),)),h)
                job===nothing || (h.indexer=Threads.@spawn drain_index_jobs!(h))
            end
        catch err
            if !(err isa StaleInvocation)
                @error "durable scheduler stopped" error=_diagnostic(h,err)
                h.state=:poisoned
            end
        end
        sleep(.02)
    end
end

function resume!(h::Harness)
    h.state===:open || error("cannot resume a closed or poisoned harness")
    lock(h.lock) do
        if h.scheduler===nothing || istaskdone(h.scheduler)
            h.scheduler=Threads.@spawn _scheduler_loop(h)
        end
    end
    notify(h.wake)
    h
end
