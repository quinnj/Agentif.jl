function _finish_task!(db,t,outcome)
    owned=Int(_scalar(db,"SELECT COUNT(*) FROM claw_tasks WHERE owner_task=? AND background=0 AND status!='terminal'",(t.id,)))
    _exec!(db,"UPDATE claw_tasks SET status=?,outcome=?,token=NULL,blocked=NULL WHERE id=?",
        (owned==0 ? "terminal" : "completing",JSON.json(outcome),t.id))
end

function _cancel_task!(db,id)
    _exec!(db,"UPDATE claw_tasks SET cancel=1,revision=revision+1 WHERE id=? AND status!='terminal'",(id,))
    for child in _drows(db,"SELECT id FROM claw_tasks WHERE owner_task=? AND background=0",(id,))
        _cancel_task!(db,child.id)
    end
    for c in _drows(db,"SELECT id FROM claw_conversations WHERE owner_task=? AND background=0",(id,))
        _exec!(db,"UPDATE claw_submissions SET state='withdrawn',reason='aborted' WHERE conversation_id=? AND state='queued'",(c.id,))
    end
end
function _cancel_conversation!(db,h,cid,background)
    _exec!(db,"UPDATE claw_submissions SET state='withdrawn',reason='aborted' WHERE conversation_id=? AND state='queued'",(cid,))
    for t in _drows(db,"SELECT id FROM claw_tasks WHERE conversation_id=? AND (?=1 OR background=0)",(cid,Int(background)))
        _cancel_task!(db,t.id)
    end
end
function abort_conversation!(h::Harness,cid::String;include_background::Bool=false)
    _transition!(h;point=:abort) do db,seq
        _cancel_conversation!(db,h,cid,include_background)
    end
    for x in lock(()->collect(values(h.live)),h.lock)
        row=_task_row(h,x.context.task_id)
        row.cancel==1 && Agentif.abort!(x.context.abort)
    end
    notify(h.wake)
    nothing
end
abort_conversation!(h::Harness,c::ConversationRef;kwargs...)=abort_conversation!(h,c.id;kwargs...)

function _wait_tasks!(db,waiter,children,policy="allSettled")
    policy in ("allSettled","failFast") || throw(ArgumentError("unknown join policy"))
    for id in children
        child=_done(db,"SELECT * FROM claw_tasks WHERE id=?",(id,))
        child===nothing && throw(ArgumentError("missing awaited task"))
        policy=="failFast" && _dnull(child.owner_task)!=waiter && throw(ArgumentError("failFast requires owned children"))
        owner=_done(db,"SELECT owner_task FROM claw_tasks WHERE id=?",(waiter,))
        ancestor=owner===nothing ? nothing : _dnull(owner.owner_task)
        while ancestor!==nothing
            ancestor==id && throw(ArgumentError("cannot await an ancestor"))
            row=_done(db,"SELECT owner_task FROM claw_tasks WHERE id=?",(ancestor,))
            ancestor=row===nothing ? nothing : _dnull(row.owner_task)
        end
        # Traverse dependency edges to reject cross-task cycles.
        todo=[id];seen=Set{String}()
        while !isempty(todo)
            current=pop!(todo)
            current==waiter && throw(ArgumentError("task dependency cycle"))
            current in seen && continue
            push!(seen,current)
            append!(todo,[r.awaited for r in _drows(db,"SELECT awaited FROM claw_task_waits WHERE waiter=?",(current,))])

        end
        _exec!(db,"INSERT OR IGNORE INTO claw_task_waits VALUES(?,?,?)",(waiter,id,policy))
    end
    _exec!(db,"UPDATE claw_tasks SET status='waiting',token=NULL WHERE id=?",(waiter,))
end

function _reconcile_ownership!(db,h,seq)
    for t in _drows(db,"SELECT * FROM claw_tasks WHERE cancel=1 AND status!='terminal' ORDER BY created_seq DESC")
        lock(() -> haskey(h.live,t.id),h.lock) && continue
        if t.kind=="tool"
            e=_done(db,"SELECT effect_state FROM claw_tool_executions WHERE task_id=?",(t.id,))
            e===nothing || e.effect_state!="executing" || _exec!(db,"UPDATE claw_tool_executions SET effect_state='uncertain' WHERE task_id=?",(t.id,))
        end
        reason=get(JSON.parse(t.input_json),"abort_reason","user_abort")
        _finish_task!(db,t,Dict("status"=>"aborted","reason"=>reason))
        if t.kind=="generation"
            _exec!(db,"UPDATE claw_runs SET status='aborted',reason=? WHERE id=?",(reason,t.run_id))
            _exec!(db,"UPDATE claw_submissions SET state='unanswered',reason=? WHERE run_id=? AND state='placed'",(reason,t.run_id))
        end
    end
    for t in _drows(db,"SELECT * FROM claw_tasks WHERE status='waiting'")
        waits=_drows(db,"SELECT t.*,w.policy FROM claw_task_waits w JOIN claw_tasks t ON t.id=w.awaited WHERE w.waiter=?",(t.id,))
        failed=any(w -> w.status=="terminal" && get(JSON.parse(something(_dnull(w.outcome),"{}")),"status","")!="completed",waits)
        if failed && any(w -> w.policy=="failFast",waits)
            foreach(w -> w.status=="terminal" || _cancel_task!(db,w.id),waits)
        end
        all(w -> w.status=="terminal",waits) || continue
        _exec!(db,"DELETE FROM claw_task_waits WHERE waiter=?",(t.id,))
        _exec!(db,"UPDATE claw_tasks SET status='pending',revision=revision+1 WHERE id=?",(t.id,))
    end
    for t in _drows(db,"SELECT * FROM claw_tasks WHERE status='completing' ORDER BY created_seq DESC")
        live=Int(_scalar(db,"SELECT COUNT(*) FROM claw_tasks WHERE owner_task=? AND background=0 AND status!='terminal'",(t.id,)))
        live==0 && _exec!(db,"UPDATE claw_tasks SET status='terminal',revision=revision+1 WHERE id=?",(t.id,))
    end
end

"""Keyed child admission and ownership are one commit. Requested policy can only
attenuate the parent's profile. Call through a live invocation context.
"""
function create_owned_child!(ctx::InvocationContext;creation_key::String,name::String,profile::AgentProfileRef,input::String,
        event_type::Union{Nothing,String}=nothing,background::Bool=false,owner_task::Union{Nothing,String}=nothing)
    h=ctx.harness
    _transition!(h;context=ctx,point=:child_creation) do db,seq
        owner=_done(db,"SELECT * FROM claw_tasks WHERE id=?",(ctx.task_id,))
        target=background ? nothing : something(owner_task,owner.id)
        if target!==nothing && target!=owner.id
            ancestor=_dnull(owner.owner_task)
            while ancestor!==nothing && ancestor!=target
                ancestor=_dnull(_done(db,"SELECT owner_task FROM claw_tasks WHERE id=?",(ancestor,)).owner_task)
            end
            ancestor==target || throw(ArgumentError("child owner must be this task or an ancestor"))
        end
        parent=JSON.parse(_done(db,"SELECT payload FROM claw_agent_profiles WHERE id=?",(JSON.parse(owner.input_json)["profile"],)).payload)
        child=JSON.parse(_done(db,"SELECT payload FROM claw_agent_profiles WHERE id=?",(profile.id,)).payload)
        all(t -> any(p->p==t,parent["tools"]),child["tools"]) || throw(ArgumentError("child tool contracts exceed inherited policy"))
        parent["trust"]=="owner" || child["trust"]=="untrusted" || throw(ArgumentError("child trust exceeds parent"))
        child["env"]==parent["env"] || throw(ArgumentError("child environment exceeds inherited policy"))
        old=_done(db,"SELECT * FROM claw_child_aliases WHERE conversation_id=? AND name=?",(owner.conversation_id,name))
        if old!==nothing
            previous=_done(db,"SELECT creation_key,owner_task FROM claw_tasks WHERE id=?",(old.task_id,))
            previous.creation_key==creation_key && _dnull(previous.owner_task)==target ||
                throw(ArgumentError("child alias already belongs to a different creation"))
            initial=_done(db,"SELECT input_json,profile_id FROM claw_submissions WHERE conversation_id=? AND request_id=?",(old.child_id,"initial:$creation_key"))
            initial.profile_id==profile.id && initial.input_json==JSON.json(Agentif.UserMessage(input)) || throw(SubmissionConflict(creation_key))
            return (;conversation=String(old.child_id),task=String(old.task_id))
        end
        cid=_did()
        wrapper=_task_create!(db,seq,owner.conversation_id,"child",creation_key;owner=target,
            background,input=Dict("profile"=>profile.id,"child"=>cid),checkpoint=Dict("phase"=>"join"))
        parent_c=_done(db,"SELECT * FROM claw_conversations WHERE id=?",(owner.conversation_id,))
        _exec!(db,"INSERT INTO claw_conversations(id,branch_id,profile_id,owner_task,background,routing,created_seq) VALUES(?,?,?,?,?,?,?)",
            (cid,"child:$cid",profile.id,wrapper,Int(background),parent_c.routing,seq))
        c=_done(db,"SELECT * FROM claw_conversations WHERE id=?",(cid,))
        receipt=_admit!(db,seq,c,Agentif.UserMessage(input),"initial:$creation_key",:followup,Dict("owner"=>owner.id),profile.id)
        _exec!(db,"UPDATE claw_tasks SET checkpoint=? WHERE id=?",(JSON.json(Dict("phase"=>"join","submission"=>receipt)),wrapper))
        _exec!(db,"INSERT INTO claw_child_aliases VALUES(?,?,?,?,?)",(owner.conversation_id,name,cid,wrapper,event_type))
        return (;conversation=cid,task=wrapper)
    end
end

function fork_conversation!(h::Harness,cid::String;branch_id::String,entry_id::Union{Nothing,String}=nothing)
    _transition!(h;point=:fork) do db,seq
        c=_done(db,"SELECT * FROM claw_conversations WHERE id=?",(cid,))
        leaf=_done(db,"SELECT leaf_entry_id FROM session_branches WHERE branch_id=?",(c.branch_id,))
        cutoff=entry_id===nothing ? Agentif._last_finished_entry(h.history,leaf===nothing ? nothing : _dnull(leaf.leaf_entry_id)) : entry_id
        # Validate lineage; callers cannot fork arbitrary private branch history.
        current=leaf===nothing ? nothing : _dnull(leaf.leaf_entry_id)
        seen=Set{String}()
        while current!==nothing
            push!(seen,current)
            e=_done(db,"SELECT parent_id FROM session_entries WHERE entry_id=?",(current,))
            current=e===nothing ? nothing : _dnull(e.parent_id)
        end
        cutoff===nothing || cutoff in seen || throw(ArgumentError("fork cutoff outside conversation"))
        if cutoff!==nothing
            state=Agentif.AgentState()
            foreach(e->Agentif.apply_session_entry!(state,e),Agentif._collect_lineage(h.history,cutoff))
            pending=Set{String}()
            for message in state.messages
                if message isa Agentif.AssistantMessage
                    union!(pending,(call.call_id for call in Agentif.pending_tool_calls_from_message(message)))
                elseif message isa Agentif.ToolResultMessage
                    delete!(pending,message.call_id)
                end
            end
            isempty(pending) || throw(ArgumentError("fork cutoff contains unfinished tool calls"))
        end
        id=_did()
        _exec!(db,"INSERT INTO session_branches VALUES(?,?)",(branch_id,cutoff))
        _exec!(db,"INSERT INTO claw_conversations(id,branch_id,profile_id,fork_parent,fork_cutoff,routing,created_seq) VALUES(?,?,?,?,?,?,?)",
            (id,branch_id,c.profile_id,cid,cutoff,c.routing,seq))
        ConversationRef(id)
    end
end

function reset_conversation!(h::Harness,cid::String;expected_revision::Int)
    _transition!(h;point=:reset) do db,seq
        c=_done(db,"SELECT * FROM claw_conversations WHERE id=?",(cid,))
        c.context_revision==expected_revision || throw(StaleInvocation())
        _cancel_conversation!(db,h,cid,false)
        _exec!(db,"UPDATE session_branches SET leaf_entry_id=NULL WHERE branch_id=?",(c.branch_id,))
        _exec!(db,"UPDATE claw_conversations SET context_revision=context_revision+1 WHERE id=?",(cid,))
    end
end
