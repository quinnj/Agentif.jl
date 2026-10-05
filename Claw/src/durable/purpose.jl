function _purpose_settle!(db,h,seq,t,outcome)
    t.kind=="watcher" && return _watcher_settle!(db,h,seq,t,outcome)
    if !Agentif.valid_summary(outcome)
        c=_done(db,"SELECT * FROM claw_conversations WHERE id=?",(t.conversation_id,))
        _entry!(db,h,seq,c,[];task=t.id,audit=outcome.message,stop=String(outcome.stop_reason))
        return _finish_task!(db,t,Dict("status"=>"failed","reason"=>String(outcome.stop_reason)))
    end
    match=try
        JSON.parse(Agentif.message_text(outcome.message),EventFilterVerdict).match
    catch
        c=_done(db,"SELECT * FROM claw_conversations WHERE id=?",(t.conversation_id,))
        _entry!(db,h,seq,c,[];task=t.id,audit=outcome.message,stop="invalid_filter_verdict")
        return _finish_task!(db,t,Dict("status"=>"failed","reason"=>"invalid_filter_verdict"))
    end
    _finish_task!(db,t,Dict("status"=>"completed","match"=>match))
end

# A prompt classifier is a durable model-purpose task. Its operation identity,
# attempt budget, usage and unknown spend survive dispatch retries and restart.
function _durable_filter!(h,handler,ev,row,hash)
    filter=handler.filter
    filter===nothing && return true
    filter.kind===:prompt || return passes_filter(h.assistant,handler,ev,row.extra)
    a=h.assistant
    model=Agentif.getModel(a.config.provider,a.config.model_id)
    model===nothing && throw(DurableBlocked("prompt classifier model unavailable"))
    agent=Agentif.Agent(;model,apikey=a.config.apikey,prompt=EVENT_FILTER_PROMPT,tools=Agentif.AgentTool[])
    profile=register_profile!(h,agent;trust=:untrusted)
    key="filter:$(row.id):$hash"
    conversation=ensure_conversation!(h;branch_id=key,profile,routing=Dict("post_id"=>get(row.extra,"source_id",nothing)))
    input="CRITERIA: `$(filter.expr)`\n\nEVENT CONTENT:\n"*wrap_untrusted_event_content(event_content(ev))
    id=_transition!(h;point=:filter_prepare) do db,seq
        _task_create!(db,seq,conversation.id,"filter",key;input=Dict("profile"=>profile.id,"deadline"=>h.clock()+h.limits.run_timeout),
            checkpoint=Dict("phase"=>"request","prompt"=>EVENT_FILTER_PROMPT,"messages"=>JSON.parse(JSON.json([Agentif.UserMessage(input)]))))
    end
    resume!(h)
    while h.state===:open
        t=_task_row(h,id)
        if t.status=="terminal"
            outcome=JSON.parse(t.outcome)
            get(outcome,"status","")=="completed" || error("durable prompt classifier failed: $(get(outcome,"reason","unknown"))")
            return outcome["match"]::Bool
        end
        _dnull(t.blocked)===nothing || throw(DurableBlocked("durable prompt classifier blocked: $(t.blocked)"))
        sleep(.01)
    end
    throw(HarnessPoisoned())
end
