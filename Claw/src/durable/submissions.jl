function _admit!(db,seq,c,input,request_id,mode,origin,profile)
    payload = JSON.json(input)
    hash = _digest(Dict("input"=>JSON.parse(payload),"origin"=>origin,"mode"=>String(mode),"profile"=>profile))
    old = _done(db,"SELECT id,hash FROM claw_submissions WHERE conversation_id=? AND request_id=?",(c.id,request_id))
    old === nothing || (old.hash == hash ? (return String(old.id)) : throw(SubmissionConflict(request_id)))
    id = _did()
    _exec!(db,"""INSERT INTO claw_submissions(id,conversation_id,request_id,mode,input_json,hash,origin,profile_id,admitted_seq,state)
        VALUES(?,?,?,?,?,?,?,?,?,'queued')""",(id,c.id,request_id,String(mode),payload,hash,JSON.json(origin),profile,seq))
    _exec!(db,"UPDATE claw_submissions SET routing=?,delivery=? WHERE id=?",(c.routing,_dnull(c.delivery),id))
    return id
end

function submit!(h::Harness,conversation::Union{String,ConversationRef},input::Union{String,Agentif.UserMessage};
        request_id::String,mode::Symbol=:followup,origin=Dict{String,Any}(),profile::Union{Nothing,AgentProfileRef}=nothing)
    mode in (:followup,:steer,:write) || throw(ArgumentError("invalid submission mode"))
    h.state===:poisoned && throw(HarnessPoisoned())
    h.state === :open || error("harness is not accepting submissions")
    cid = conversation isa String ? conversation : conversation.id
    message = input isa String ? Agentif.UserMessage(input) : input
    safe_origin = _sanitize_integration_value(origin)
    safe_origin == origin || throw(ArgumentError("origin must contain references, not credentials"))
    id = _transition!(h;point=:intake) do db,seq
        c = _done(db,"SELECT * FROM claw_conversations WHERE id=?",(cid,))
        c === nothing && throw(ArgumentError("unknown conversation"))
        pid = profile === nothing ? _dnull(c.profile_id) : profile.id
        pid === nothing && throw(ArgumentError("conversation has no profile"))
        _admit!(db,seq,c,message,request_id,mode,safe_origin,pid)
    end
    resume!(h)
    return SubmissionReceipt(h,id)
end

function submission(r::SubmissionReceipt)
    _dread(r.harness) do db
        _done(db,"SELECT * FROM claw_submissions WHERE id=?",(r.id,))
    end
end
function lookup_submission(h,conversation_id,request_id)
    row = _dread(db -> _done(db,"SELECT id FROM claw_submissions WHERE conversation_id=? AND request_id=?",(conversation_id,request_id)),h)
    row === nothing ? nothing : SubmissionReceipt(h,String(row.id))
end
function withdraw!(r::SubmissionReceipt)
    _transition!(r.harness;point=:withdraw) do db,seq
        _exec!(db,"UPDATE claw_submissions SET state='withdrawn',reason='withdrawn' WHERE id=? AND state='queued'",(r.id,))
        Int(_scalar(db,"SELECT changes()")) == 1
    end
end
"""Wait timeout or caller abort only stops waiting. It never withdraws admitted work."""
function wait_submission(r::SubmissionReceipt;timeout_s::Real=Inf,abort::Agentif.Abort=Agentif.Abort())
    resume!(r.harness)
    start = time_ns()
    while true
        row = submission(r)
        row.state in ("answered","unanswered","withdrawn") && return row
        Agentif.isaborted(abort) && return nothing
        (time_ns()-start)/1e9 >= timeout_s && return nothing
        r.harness.state === :poisoned && throw(HarnessPoisoned())
        sleep(.01)
    end
end

function _place!(db,h,seq,c,s,run)
    origin=JSON.parse(s.origin)
    _entry!(db,h,seq,c,[JSON.parse(s.input_json,Agentif.UserMessage)];run,post_id=get(origin,"post_id",nothing))
    _exec!(db,"UPDATE claw_submissions SET state='placed',placed_seq=?,run_id=? WHERE id=?",(seq,run,s.id))
end

function _place_boundary!(db,h,seq,c,run)
    for s in _drows(db,"SELECT * FROM claw_submissions WHERE conversation_id=? AND mode='write' AND state='queued' ORDER BY admitted_seq,rowid",(c.id,))
        _place!(db,h,seq,c,s,run)
        _exec!(db,"UPDATE claw_submissions SET state='unanswered',reason='passive_write' WHERE id=?",(s.id,))
    end
    steer = _done(db,"SELECT * FROM claw_submissions WHERE conversation_id=? AND mode='steer' AND state='queued' ORDER BY admitted_seq,rowid LIMIT 1",(c.id,))
    steer === nothing || _place!(db,h,seq,c,steer,run)
    return steer !== nothing
end

function _start_runs!(h)
    _dread(db->_done(db,"""SELECT s.id FROM claw_submissions s WHERE s.state='queued'
        AND NOT EXISTS(SELECT 1 FROM claw_tasks t WHERE t.conversation_id=s.conversation_id AND t.kind='generation' AND t.status!='terminal')
        AND NOT EXISTS(SELECT 1 FROM claw_runs r WHERE r.conversation_id=s.conversation_id AND r.status='active') LIMIT 1"""),h)===nothing && return
    _transition!(h;point=:placement) do db,seq
        for c in _drows(db,"SELECT * FROM claw_conversations WHERE EXISTS(SELECT 1 FROM claw_submissions s WHERE s.conversation_id=claw_conversations.id AND s.state='queued')")
            _done(db,"SELECT id FROM claw_tasks WHERE conversation_id=? AND kind='generation' AND status!='terminal' LIMIT 1",(c.id,))===nothing || continue
            _done(db,"SELECT id FROM claw_runs WHERE conversation_id=? AND status='active'",(c.id,)) === nothing || continue
            for s in _drows(db,"SELECT * FROM claw_submissions WHERE conversation_id=? AND mode='write' AND state='queued' ORDER BY admitted_seq,rowid",(c.id,))
                _place!(db,h,seq,c,s,nothing)
                _exec!(db,"UPDATE claw_submissions SET state='unanswered',reason='passive_write' WHERE id=?",(s.id,))
            end
            s = _done(db,"SELECT * FROM claw_submissions WHERE conversation_id=? AND state='queued' ORDER BY admitted_seq,rowid LIMIT 1",(c.id,))
            s === nothing && continue
            rid = _did()
            owner=_dnull(c.owner_task)
            if owner!==nothing
                parent=_done(db,"SELECT status FROM claw_tasks WHERE id=?",(owner,))
                parent===nothing || parent.status!="terminal" || (owner=nothing)
            end
            issued=Dict{String,Any}("profile"=>s.profile_id,"deadline"=>h.clock()+h.limits.run_timeout)
            supervision=get(JSON.parse(s.origin),"supervision",nothing)
            if supervision!==nothing
                _exec!(db,"INSERT INTO claw_evals(event_name,handler_id,channel_id,status,started_at,last_activity_at) VALUES(?,?,?,'running',?,?)",
                    (supervision["event_name"],supervision["handler_id"],get(JSON.parse(s.routing),"channel_id",nothing),h.clock(),h.clock()))
                supervision["eval_id"]=Int(_scalar(db,"SELECT last_insert_rowid()"))
                supervision["started"]=h.clock()
                issued["supervision"]=supervision
            end
            task = _task_create!(db,seq,c.id,"generation","run:$rid";run=rid,owner,background=c.background==1,
                input=issued,checkpoint=Dict("phase"=>"prepare","overflow"=>0))
            _exec!(db,"INSERT INTO claw_runs(id,conversation_id,profile_id,status,task_id,routing,delivery) VALUES(?,?,?,'active',?,?,?)",
                (rid,c.id,s.profile_id,task,s.routing,_dnull(s.delivery)))
            _place!(db,h,seq,c,s,rid)
        end
    end
end
