function _handler_snapshot(handler)
    Dict("id"=>handler.id,"prompt"=>handler.prompt,"channel_id"=>handler.channel_id,
        "trust"=>String(_handler_trust(handler)),"tools"=>_handler_tool_names(handler),
        "filter"=>handler.filter===nothing ? nothing : JSON.parse(JSON.json(handler.filter)))
end
function _restore_handler(value)
    f=value["filter"]
    filter=f===nothing ? nothing : _decode_filter(f["kind"],get(f,"expr",nothing),get(f,"pattern",nothing))
    (;id=value["id"],prompt=value["prompt"],channel_id=value["channel_id"],trust=Symbol(value["trust"]),
        tools=value["tools"]===nothing ? nothing : String.(value["tools"]),filter)
end

function _bridge_profile(h,handler,ch)
    a=h.assistant
    model=Agentif.getModel(a.config.provider,a.config.model_id)
    model===nothing && throw(DurableBlocked("configured model unavailable"))
    tools=resolve_handler_tools(a,handler)
    agent=Agentif.Agent(;model,apikey=a.config.apikey,prompt=build_system_prompt(a;channel=ch),tools)
    register_profile!(h,agent;trust=_handler_trust(handler))
end

function _route(ch,row)
    flags=(Agentif.is_private(ch) ? 1 : 0) | (Agentif.is_group(ch) ? 2 : 0)
    user=Agentif.get_current_user(ch)
    Dict{String,Any}("channel_id"=>Agentif.channel_id(ch),"channel_flags"=>flags,
        "search_channel_id"=>Agentif.search_channel_id(ch),"user_id"=>user===nothing ? nothing : user.id,
        "post_id"=>Agentif.entry_id(ch),"source"=>row.source,"event_id"=>row.id)
end

"""Admit a frozen source batch. Optional `verdicts[(handler_id,event_id)]` is the
seam for a source relevance policy. Decisions and exact handler revisions persist
before submissions; coalescing changes cannot reinterpret an existing batch.
"""
function _durable_dispatch_group!(a,group,handlers;verdicts=nothing)
    h=a._harness[]
    h===nothing && error("durable runtime is not attached")
    # Divide newly claimed rows by their existing frozen batches. Newly arriving
    # rows create a separate batch instead of widening an interrupted one.
    partitions=Dict{String,Vector{Any}}()
    new=Any[]
    for member in group
        row=member[1]
        frozen=_dread(db->_done(db,"SELECT g.* FROM claw_dispatch_groups g JOIN claw_frozen_members m ON m.group_key=g.group_key WHERE m.event_id=?",(row.id,)),h)
        if frozen===nothing
            push!(new,member)
        else
            push!(get!(partitions,String(frozen.group_key),Any[]),member)
        end
    end
    if !isempty(new)
        key=join((x[1].id for x in new),",")
        frozen=_transition!(h;point=:dispatch_freeze) do db,seq
            snapshots=[_handler_snapshot(x) for x in handlers]
            for snapshot in snapshots
                snapshot["context_prefix"]=build_context_prefix(a.config)
            end
            payload=JSON.json(snapshots)
            _exec!(db,"INSERT OR IGNORE INTO claw_dispatch_groups VALUES(?,?)",(key,payload))
            for (ordinal,(row,ev)) in enumerate(new)
                _exec!(db,"INSERT OR IGNORE INTO claw_frozen_members VALUES(?,?,?)",(key,row.id,ordinal))
            end
            _done(db,"SELECT * FROM claw_dispatch_groups WHERE group_key=?",(key,))
        end
        partitions[key]=new
    end
    for (key,members) in partitions
        freeze=_dread(db->_done(db,"SELECT * FROM claw_dispatch_groups WHERE group_key=?",(key,)),h)
        frozen_ids=_dread(db->_drows(db,"SELECT event_id FROM claw_frozen_members WHERE group_key=? ORDER BY ordinal",(key,)),h)
        present=Set(x[1].id for x in members)
        for id in (r.event_id for r in frozen_ids if !(r.event_id in present))
            row=_claim_event!(a,Int(id))
            row===nothing && throw(DurableBlocked("frozen batch member is unavailable: $id"))
            ev=_live_event(a,Int(id))
            ev===nothing && (ev=rehydrate_event(row.source,row))
            if ev===nothing
                _release_claim!(a,row;delay=60.0,last_error="frozen batch source unavailable")
                throw(DurableBlocked("frozen batch source unavailable"))
            end
            push!(members,(row,ev))
            if !any(x->x[1].id==row.id,group)
                push!(group,(row,ev))
                lock(a._inflight_lock) do
                    a._inflight[row.id]=Agentif.Abort()
                end
            end
        end
        sort!(members;by=x->findfirst(r->r.event_id==x[1].id,frozen_ids))
        prepared=Any[]
        for raw in JSON.parse(freeze.handlers)
            handler=_restore_handler(raw)
            hash=_digest(raw)
            kept=Any[];decisions=Dict{String,Bool}()
            for (row,ev) in members
                receipt=_dread(db->_done(db,"SELECT verdict FROM claw_filter_receipts WHERE event_id=? AND handler_hash=?",(row.id,hash)),h)
                pass=receipt===nothing ? (verdicts===nothing ? _durable_filter!(h,handler,ev,row,hash) : verdicts[(handler.id,row.id)]) : receipt.verdict==1
                if receipt===nothing
                    _transition!(h;point=:filter_receipt) do db,seq
                        _exec!(db,"INSERT OR IGNORE INTO claw_filter_receipts VALUES(?,?,?)",(row.id,hash,Int(pass)))
                    end
                end
                decisions[string(row.id)]=pass
                pass && push!(kept,(row,ev))
            end
            if isempty(kept)
                push!(prepared,(;handler,hash,decisions,submission=nothing))
                continue
            end
            ev=length(kept)==1 ? kept[1][2] : _make_event_batch(kept[1][1].name,Event[x[2] for x in kept])
            ch=_resolve_event_channel(a,ev,handler.channel_id)
            ch===nothing && handler.channel_id!==nothing && throw(DurableBlocked("recorded handler delivery channel unavailable"))
            ch===nothing && (ch=SinkChannel("handler:$(handler.id)"))
            profile=_bridge_profile(h,handler,ch)
            route=_route(ch,kept[1][1])
            supervision=_supervision_spec(h,handler,ev)
            supervision===nothing || (route["supervision"]=supervision)
            delivery=ch isa SinkChannel ? nothing : DeliveryAddress("claw-event-channel",1,Dict("event_id"=>kept[1][1].id,"channel_id"=>Agentif.channel_id(ch)))
            c=_channel_conversation!(h,ch,profile,route,delivery)
            input=Agentif.UserMessage(raw["context_prefix"]*"\n\n"*make_prompt(handler.prompt,ev))
            push!(prepared,(;handler,hash,decisions,submission=(c,profile,input,route)))
        end
        _transition!(h;point=:dispatch) do db,seq
            for p in prepared
                id=_did();sid=nothing
                if p.submission!==nothing
                    ref,profile,input,origin=p.submission
                    c=_done(db,"SELECT * FROM claw_conversations WHERE id=?",(ref.id,))
                    sid=_admit!(db,seq,c,input,"dispatch:$key:$(p.handler.id):$(p.hash)",:followup,origin,profile.id)
                end
                _exec!(db,"INSERT OR IGNORE INTO claw_event_dispatches VALUES(?,?,?,?,?,?,?)",
                    (id,key,p.handler.id,JSON.json(_handler_snapshot(p.handler)),JSON.json(p.decisions),sid,sid===nothing ? "skipped" : nothing))
                saved=_done(db,"SELECT id FROM claw_event_dispatches WHERE group_key=? AND handler_id=?",(key,p.handler.id))
                for (ordinal,(row,ev)) in enumerate(members)
                    _exec!(db,"INSERT OR IGNORE INTO claw_dispatch_members VALUES(?,?,?)",(saved.id,row.id,ordinal))
                end
            end
            for (row,ev) in members
                _exec!(db,"UPDATE claw_events SET status='dispatched',claim_token=NULL,claim_revision=claim_revision+1,lease_expires_at=NULL WHERE id=? AND claim_token=? AND claim_revision=? AND owner_epoch=?",
                    (row.id,row.claim_token,row.claim_revision,row.owner_epoch))
                Int(_scalar(db,"SELECT changes()"))==1 || throw(StaleInvocation())
            end
            _aggregate_dispatches!(db,h)
        end
    end
    resume!(h)
    nothing
end

function _aggregate_dispatches!(db,h)
    for d in _drows(db,"SELECT * FROM claw_event_dispatches WHERE result IS NULL")
        s=_done(db,"SELECT state,reason FROM claw_submissions WHERE id=?",(d.submission_id,))
        s===nothing && continue
        s.state in ("answered","unanswered","withdrawn") || continue
        _exec!(db,"UPDATE claw_event_dispatches SET result=? WHERE id=?",(s.state,d.id))
    end
    for e in _drows(db,"SELECT id FROM claw_events WHERE status='dispatched'")
        ds=_drows(db,"SELECT d.result FROM claw_dispatch_members m JOIN claw_event_dispatches d ON d.id=m.dispatch_id WHERE m.event_id=?",(e.id,))
        any(d->_dnull(d.result)===nothing,ds) && continue
        failed=any(d->d.result in ("unanswered","withdrawn"),ds)
        _exec!(db,"UPDATE claw_events SET status=?,last_error=? WHERE id=? AND status='dispatched'",
            (failed ? "dead" : "done",failed ? "durable_handler_unanswered" : nothing,e.id))
    end
end

function _register_native_delivery!(h,a)
    register_delivery_adapter!(h,"claw-event-channel",DeliveryAdapter((address,body,key)->begin
        id=Int(address["event_id"])
        row=_event_row_for_delivery(a,id)
        ev=_live_event(a,id)
        ev===nothing && (ev=rehydrate_event(row.source,row))
        ev===nothing && error("delivery source/credentials unavailable")
        ch=_resolve_event_channel(a,ev,address["channel_id"])
        ch===nothing && error("delivery channel unavailable")
        result=Agentif.send_message(ch,body)
        post=Agentif.response_entry_id(ch)
        Agentif.close_channel(ch)
        Dict("sent"=>true,"remote"=>_sanitize_integration_value(result),"_claw_response_post"=>post)
    end;available=address->begin
        row=_event_row_for_delivery(a,Int(address["event_id"]))
        ev=_live_event(a,Int(address["event_id"]))
        ev===nothing && (ev=rehydrate_event(row.source,row))
        ev===nothing && return false
        ch=_resolve_event_channel(a,ev,address["channel_id"])
        ch!==nothing && delivery_available(ch)
    end))
    register_delivery_adapter!(h,"claw-child-event",DeliveryAdapter((address,body,key)->
        submit_event!(a,SubagentOutputEvent(address["event_type"],address["name"],body);dedup_key=key);capability=:idempotent))
end

function _event_row_for_delivery(a,id)
    with_read(a._readers) do db
        r=_done(db,"SELECT * FROM claw_events WHERE id=?",(id,))
        cid,content,extra=_decode_payload(r.payload)
        EventRow(Int(r.id),r.source,r.name,_dnull(r.dedup_key),cid,content,extra,r.lane,Int(r.attempts),a)
    end
end

_live_event(a,id)=lock(()->get(a._live_events,id,nothing),a._live_lock)

function _register_default_profile!(h,a)
    model=Agentif.getModel(a.config.provider,a.config.model_id)
    model===nothing && return nothing
    agent=Agentif.Agent(;model,apikey=a.config.apikey,prompt=build_system_prompt(a),tools=_tool_snapshot(a))
    if a.watcher!==nothing
        try
            register_profile!(h,_watcher_agent(a.watcher,WATCHER_SYSTEM_PROMPT);trust=:untrusted)
        catch err
            @warn "durable watcher profile unavailable; bounded default note will be used" error=_diagnostic(h,err)
        end
    end
    register_profile!(h,agent)
end
function _durable_evaluate(a,input;channel=nothing,tools=nothing,request_id=_did(),input_key=nothing,kwargs...)
    h=a._harness[]
    ch=channel===nothing ? SinkChannel("internal") : channel
    handler=(;id="direct",prompt="",channel_id=Agentif.channel_id(ch),trust=:owner,tools=tools===nothing ? nothing : [t.name for t in tools],filter=nothing)
    profile=_bridge_profile(h,handler,ch)
    route=Dict("channel_id"=>Agentif.channel_id(ch),"search_channel_id"=>Agentif.search_channel_id(ch),
        "channel_flags"=>(Agentif.is_private(ch) ? 1 : 0),"post_id"=>Agentif.entry_id(ch))
    _channel_set!(a,Agentif.channel_id(ch),ch)
    if !(ch isa SinkChannel)
        register_delivery_adapter!(h,"claw-direct-channel",DeliveryAdapter((address,body,key)->begin
            target=_channel_get(a,address["channel_id"])
            target===nothing && error("direct delivery channel unavailable")
            Agentif.send_message(target,body)
            post=Agentif.response_entry_id(target)
            Agentif.close_channel(target)
            Dict("sent"=>true,"_claw_response_post"=>post)
        end))
    end
    delivery=ch isa SinkChannel ? nothing : DeliveryAddress("claw-direct-channel",1,Dict("channel_id"=>Agentif.channel_id(ch)))
    c=_channel_conversation!(h,ch,profile,route,delivery)
    key=something(input_key,request_id)
    route["input_digest"]=_digest(input)
    old=lookup_submission(h,c.id,key)
    if old!==nothing
        saved=submission(old)
        get(JSON.parse(saved.origin),"input_digest",nothing)==route["input_digest"] || throw(SubmissionConflict(key))
        r=old
    else
        message=input isa String ? build_context_prefix(a.config)*"\n\n"*input : input
        r=submit!(h,c,message;request_id=key,origin=route)
    end
    outcome=wait_submission(r)
    state=Agentif.load_branch(h.history,String(Agentif.branch_id(ch)))
    state.most_recent_stop_reason=outcome.state=="answered" ? :stop : :error
    state
end

function _channel_conversation!(h,ch,profile,route,delivery)
    branch=String(Agentif.branch_id(ch))
    parent=Agentif.parent_branch_id(ch)
    existing=_dread(db->_done(db,"SELECT id FROM claw_conversations WHERE branch_id=?",(branch,)),h)
    if existing===nothing && parent!==nothing
        source=_dread(db->_done(db,"SELECT * FROM claw_conversations WHERE branch_id=?",(String(parent),)),h)
        if source!==nothing
            oldroute=JSON.parse(source.routing)
            private=get(oldroute,"channel_flags",1)&1==1
            private && !Agentif.is_private(ch) && throw(ArgumentError("private parent history cannot seed a public thread"))
            platform=Agentif.branch_entry_id(ch)
            cutoff=platform===nothing ? nothing : _dread(db->_done(db,"SELECT entry_id FROM claw_platform_entries WHERE channel_id=? AND platform_id=?",
                (get(oldroute,"channel_id",String(parent)),string(platform))),h)
            fork_conversation!(h,source.id;branch_id=branch,entry_id=cutoff===nothing ? nothing : String(cutoff.entry_id))
        end
    end
    ensure_conversation!(h;branch_id=branch,profile,routing=route,delivery)
end

delivery_available(::Agentif.AbstractChannel)=true
