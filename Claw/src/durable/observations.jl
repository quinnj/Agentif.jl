mutable struct ConversationWatch
    harness::Harness
    conversation::String
    frames::Vector{Any}
    capacity::Int
    closed::Bool
end

_checkpoint_phase(value)=try
    parsed=JSON.parse(value)
    parsed isa AbstractDict ? get(parsed,"phase","unknown") : "corrupt"
catch
    "corrupt"
end

function _snapshot(db,cid)
    c = _done(db,"SELECT * FROM claw_conversations WHERE id=?",(cid,))
    c === nothing && throw(ArgumentError("unknown conversation"))
    seq = _done(db,"SELECT seq FROM claw_runtime_meta WHERE id=1").seq
    tasks = _drows(db,"SELECT id,owner_task,kind,status,checkpoint,blocked,due_at,cancel,outcome,progress FROM claw_tasks WHERE conversation_id=? ORDER BY created_seq,rowid",(cid,))
    graph = [(;id=t.id,owner=_dnull(t.owner_task),kind=t.kind,status=t.status,
        phase=_checkpoint_phase(t.checkpoint),blocked=_dnull(t.blocked),due_at=t.due_at,
        cancel=t.cancel==1,outcome=_dnull(t.outcome),progress=_dnull(t.progress)) for t in tasks]
    receipts = _drows(db,"SELECT id,request_id,mode,state,run_id,answer_entry,reason FROM claw_submissions WHERE conversation_id=? ORDER BY admitted_seq,rowid",(cid,))
    deliveries = _drows(db,"SELECT id,state,receipt,error FROM claw_outbox WHERE conversation_id=?",(cid,))
    usage = _drows(db,"SELECT u.* FROM claw_usage u JOIN claw_tasks t ON t.id=u.task_id WHERE t.conversation_id=?",(cid,))
    effects = _drows(db,"SELECT task_id,tool_name,effect_key,effect_state,result_entry FROM claw_tool_executions WHERE conversation_id=?",(cid,))
    resources = _drows(db,"SELECT id,kind,state,details FROM claw_managed_resources WHERE conversation_id=?",(cid,))
    indexing = Int(_scalar(db,"SELECT COUNT(*) FROM claw_index_jobs WHERE state!='done'"))
    unknown = Int(_scalar(db,"SELECT COUNT(*) FROM claw_task_attempts a JOIN claw_tasks t ON t.id=a.task_id WHERE t.conversation_id=? AND a.unknown_spend=1",(cid,)))
    return (;seq,conversation=cid,branch=c.branch_id,context_revision=c.context_revision,tasks=graph,submissions=receipts,
        deliveries,usage,effects,resources,pending_index_jobs=indexing,unknown_spend_attempts=unknown)
end
snapshot(h::Harness,cid::String) = _dread(db -> _snapshot(db,cid),h)
snapshot(h::Harness,c::ConversationRef) = snapshot(h,c.id)
"""Live heartbeat diagnostics, separate from the committed snapshot cursor.
Overdue workers retain their capacity and owner lock until they actually exit.
"""
function live_activity(h::Harness,cid::Union{String,ConversationRef})
    s=snapshot(h,cid)
    ids=Set(t.id for t in s.tasks)
    lock(h.lock) do
        [(;task=id,group=x.group,idle_s=max(0,_dmono()-x.context.heartbeat[]),
            overdue=_dmono()>x.context.monotonic_deadline,abort_requested=Agentif.isaborted(x.context.abort)) for (id,x) in h.live if id in ids]
    end
end
_task_row(h::Harness,id::String) = _dread(db -> _done(db,"SELECT * FROM claw_tasks WHERE id=?",(id,)),h)
"""Inspect committed status and phase. Payloads are hidden by default; an owner
can explicitly request `include_payload=true` for checkpoint diagnosis.
"""
function inspect_task(h::Harness,id::String;include_payload::Bool=false)
    t=_task_row(h,id)
    t===nothing && return nothing
    include_payload && return t
    merge(t,(;input_json="{}",checkpoint=JSON.json(Dict("phase"=>_checkpoint_phase(t.checkpoint))),progress=nothing))
end

"""Committed snapshot subscription. Frames are snapshots, with explicit overflow
reset and sequence. Subscription and initial read share the writer line.
"""
function watch(h::Harness,cid::String;after_seq::Int=-1,capacity::Int=h.limits.observer_frames)
    capacity > 0 || throw(ArgumentError("watch capacity must be positive"))
    _dread(h) do db
        s = _snapshot(db,cid)
        w = ConversationWatch(h,cid,Any[],capacity,false)
        after_seq < s.seq && push!(w.frames,(;reset=true,snapshot=s))
        lock(h.lock) do
            push!(h.observers,w)
        end
        w
    end
end
function _publish!(h,seq)
    lock(()->all(w->w.closed,h.observers),h.lock) && return
    _dread(h) do db
        lock(h.lock) do
            for w in h.observers
                w.closed && continue
                try
                    s = _snapshot(db,w.conversation)
                    # A publish queued behind another mutation delivers its latest
                    # committed snapshot. Cursor semantics never claim every delta.
                    isempty(w.frames) || last(w.frames).snapshot.seq < s.seq || continue
                    reset = length(w.frames) >= w.capacity || any(t->t.blocked=="redacted",s.tasks)
                    reset && empty!(w.frames)
                    push!(w.frames,(;reset,snapshot=s))
                catch
                    w.closed = true
                end
            end
        end
    end
end

"""Explicit checkpoint migration for parked work. The deterministic transform
returns `(input, checkpoint)` for the built-in v1 codec. It cannot authorize replay
of an already executing effect or bypass its separate receipt.
"""
function migrate_task_checkpoint!(transform::Function,h::Harness,id::String;
        expected_revision::Int,from_version::Int,from_codec::Int,note::String)
    isempty(strip(note)) && throw(ArgumentError("migration evidence required"))
    _transition!(h;point=:checkpoint_migration) do db,seq
        t=_done(db,"SELECT * FROM claw_tasks WHERE id=?",(id,))
        t.status=="pending" && t.revision==expected_revision && t.version==from_version && t.codec==from_codec || throw(StaleInvocation())
        e=_done(db,"SELECT effect_state FROM claw_tool_executions WHERE task_id=?",(id,))
        e===nothing || e.effect_state!="executing" || throw(ArgumentError("executing effects cannot be migrated"))
        input,checkpoint=transform(JSON.parse(t.input_json),JSON.parse(t.checkpoint))
        input isa AbstractDict && checkpoint isa AbstractDict && haskey(checkpoint,"phase") || throw(ArgumentError("invalid migrated checkpoint"))
        _exec!(db,"UPDATE claw_tasks SET version=1,codec=1,input_json=?,checkpoint=?,blocked=NULL,revision=revision+1,progress=? WHERE id=?",
            (JSON.json(input),JSON.json(checkpoint),JSON.json(Dict("migration"=>first(note,2000))),id))
    end
end
function next_frame!(w::ConversationWatch)
    lock(w.harness.lock) do
        isempty(w.frames) ? nothing : popfirst!(w.frames)
    end
end
Base.close(w::ConversationWatch) = lock(w.harness.lock) do
    w.closed=true
    empty!(w.frames)
    filter!(x->x!==w,w.harness.observers)
    nothing
end

"""Mask every durable copy associated with a post's submission or history lineage.
Affected work is cancelled before context required for execution is erased.
"""
function scrub_durable_post!(h::Harness,post_id::String)
    erased_profiles=String[]
    affected=Set{String}()
    erased_events=Set{Int}()
    _transition!(h;point=:redaction) do db,seq
        entries=_drows(db,"SELECT entry_id,parent_id,post_id,entry FROM session_entries")
        tainted=Set(String(e.entry_id) for e in entries if _dnull(e.post_id)==post_id)
        union!(tainted,[r.entry_id for r in _drows(db,"SELECT entry_id FROM claw_platform_entries WHERE platform_id=?",(post_id,))])
        conversations=_drows(db,"SELECT c.*,b.leaf_entry_id,t.conversation_id AS owner_conversation FROM claw_conversations c LEFT JOIN session_branches b ON b.branch_id=c.branch_id LEFT JOIN claw_tasks t ON t.id=c.owner_task")
        submissions=_drows(db,"SELECT * FROM claw_submissions")
        events=_drows(db,"SELECT id,dedup_key,payload FROM claw_events")
        links=_drows(db,"SELECT m.event_id,d.submission_id FROM claw_dispatch_members m JOIN claw_event_dispatches d ON d.id=m.dispatch_id")
        outbox=_drows(db,"SELECT conversation_id,logical_key FROM claw_outbox")
        for c in conversations
            string(get(JSON.parse(c.routing),"post_id",""))==post_id && push!(affected,c.id)
        end
        for e in events
            _,_,extra=_decode_payload(e.payload)
            string(get(extra,"source_id",""))==post_id && push!(erased_events,Int(e.id))
        end
        # Descendant entries used the source context, including summary entries
        # and forks. Owned-child notifications are source events too, so follow
        # their committed outbox/dispatch links before removing payloads.
        derived=Set{String}()
        changed=true
        while changed
            before=(length(tainted),length(affected),length(derived),length(erased_events))
            keys=Set(o.logical_key for o in outbox if o.conversation_id in affected)
            union!(erased_events,[Int(e.id) for e in events if _dnull(e.dedup_key) in keys])
            selected=Set(l.submission_id for l in links if l.event_id in erased_events)
            for s in submissions
                get(JSON.parse(s.origin),"post_id",nothing)==post_id || s.id in selected || s.conversation_id in derived || continue
                push!(affected,s.conversation_id)
                for e in _drows(db,"SELECT entry_id FROM claw_entry_runtime WHERE seq=? AND (run_id=? OR run_id IS NULL)",(_dnull(s.placed_seq),_dnull(s.run_id)))
                    push!(tainted,e.entry_id)
                end
            end
            for e in entries
                copied=get(JSON.parse(e.entry),"copied_from",nothing)
                if (_dnull(e.parent_id) in tainted || copied in tainted) && !(e.entry_id in tainted)
                    push!(tainted,e.entry_id)
                end
            end
            for c in conversations
                _dnull(c.leaf_entry_id) in tainted && push!(affected,c.id)
                if _dnull(c.owner_conversation) in affected
                    push!(affected,c.id);push!(derived,c.id)
                end
            end
            changed=before!=(length(tainted),length(affected),length(derived),length(erased_events))
        end
        for cid in derived
            for e in _drows(db,"SELECT e.entry_id FROM claw_entry_runtime e JOIN claw_runs r ON r.id=e.run_id WHERE r.conversation_id=?",(cid,))
                push!(tainted,e.entry_id)
            end
            for p in _drows(db,"SELECT DISTINCT profile_id FROM claw_submissions WHERE conversation_id=?",(cid,))
                profile=_done(db,"SELECT payload FROM claw_agent_profiles WHERE id=?",(p.profile_id,))
                profile===nothing && continue
                payload=JSON.parse(profile.payload);payload["prompt"]="[redacted derived profile]"
                _exec!(db,"UPDATE claw_agent_profiles SET payload=? WHERE id=?",(JSON.json(payload),p.profile_id))
                push!(erased_profiles,p.profile_id)
            end
        end
        for cid in affected
            _cancel_conversation!(db,h,cid,true)
            _exec!(db,"UPDATE claw_submissions SET input_json=?,origin='{}',routing='{}',reason='redacted' WHERE conversation_id=?",
                (JSON.json(Agentif.UserMessage("[redacted]")),cid))
            _exec!(db,"UPDATE claw_conversations SET routing='{}',context_revision=context_revision+1 WHERE id=?",(cid,))
            _exec!(db,"UPDATE claw_runs SET routing='{}' WHERE conversation_id=?",(cid,))
            _exec!(db,"UPDATE claw_tasks SET input_json='{}',checkpoint='{}',progress=NULL,outcome=NULL,blocked='redacted' WHERE conversation_id=?",(cid,))
            _exec!(db,"UPDATE claw_tool_executions SET args='{}',result=NULL,effect_state='redacted' WHERE conversation_id=?",(cid,))
            _exec!(db,"UPDATE claw_outbox SET body='',error=NULL,receipt=NULL,state='redacted' WHERE conversation_id=?",(cid,))
            _exec!(db,"UPDATE claw_managed_resources SET details='{}' WHERE conversation_id=?",(cid,))
            for alias in _drows(db,"SELECT event_type FROM claw_child_aliases WHERE conversation_id=? OR child_id=?",(cid,cid))
                _dnull(alias.event_type)===nothing && continue
                _exec!(db,"UPDATE claw_event_handlers SET prompt='[redacted child completion]' WHERE id=?",(alias.event_type,))
                for g in _drows(db,"SELECT * FROM claw_dispatch_groups")
                    handlers=JSON.parse(g.handlers)
                    any(r->r["id"]==alias.event_type,handlers) || continue
                    for raw in handlers
                        raw["id"]==alias.event_type && (raw["prompt"]="[redacted child completion]")
                    end
                    _exec!(db,"UPDATE claw_dispatch_groups SET handlers=? WHERE group_key=?",(JSON.json(handlers),g.group_key))
                end
                for d in _drows(db,"SELECT id,handler_snapshot FROM claw_event_dispatches WHERE handler_id=?",(alias.event_type,))
                    raw=JSON.parse(d.handler_snapshot);raw["prompt"]="[redacted child completion]"
                    _exec!(db,"UPDATE claw_event_dispatches SET handler_snapshot=? WHERE id=?",(JSON.json(raw),d.id))
                end
            end
        end
        for id in tainted
            old=JSON.parse(_done(db,"SELECT entry FROM session_entries WHERE entry_id=?",(id,)).entry,Agentif.SessionEntry)
            mask=Agentif.SessionEntry(;id=old.id,parent_id=old.parent_id,is_deleted=true,run_id=old.run_id)
            _exec!(db,"UPDATE session_entries SET is_deleted=1,entry=? WHERE entry_id=?",(JSON.json(mask),id))
            _exec!(db,"UPDATE claw_entry_runtime SET audit=NULL,eligible=0 WHERE entry_id=?",(id,))
            _exec!(db,"INSERT INTO claw_index_jobs(entry_id,revision,state) VALUES(?,1,'redacted') ON CONFLICT(entry_id) DO UPDATE SET revision=revision+1,state='redacted'",(id,))
        end
        # Frozen source payloads and classifier contexts are also durable copies.
        for e in events
            e.id in erased_events || continue
            cid,content,extra=_decode_payload(e.payload)
            minimal=Dict{String,Any}("redacted"=>true)
            haskey(extra,"source_id") && (minimal["source_id"]=extra["source_id"])
            _exec!(db,"UPDATE claw_events SET payload=?,status='dead',last_error='redacted',claim_token=NULL,claim_revision=claim_revision+1 WHERE id=?",
                (JSON.json(Dict("channel_id"=>cid,"content"=>"[redacted]","extra"=>minimal)),e.id))
        end
    end
    live=lock(h.lock) do
        foreach(id->delete!(h.agents,id),erased_profiles)
        collect(values(h.live))
    end
    for x in live
        _task_row(h,x.context.task_id).conversation_id in affected && Agentif.abort!(x.context.abort)
    end
    if h.assistant!==nothing
        a=h.assistant
        lock(a._live_lock) do
            foreach(id->delete!(a._live_events,id),erased_events)
        end
        lock(a._inflight_lock) do
            for id in erased_events
                abort=get(a._inflight,id,nothing)
                abort===nothing || Agentif.abort!(abort)
            end
        end
    end
    nothing
end
