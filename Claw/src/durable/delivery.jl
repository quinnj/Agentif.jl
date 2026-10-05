function register_delivery_adapter!(h::Harness,name::String,adapter::DeliveryAdapter)
    lock(h.lock) do
        old=get(h.adapters,name,nothing)
        old===nothing || old.version!=adapter.version || old.capability==adapter.capability ||
            throw(ArgumentError("delivery version reused with a changed capability"))
        h.adapters[name]=adapter
    end
    notify(h.wake)
    nothing
end

function _delivery_phase!(ctx,t)
    h=ctx.harness
    id=JSON.parse(t.input_json)["outbox"]
    row=_dread(db->_done(db,"SELECT * FROM claw_outbox WHERE id=?",(id,)),h)
    address=JSON.parse(row.address)
    adapter=lock(()->get(h.adapters,address["adapter"],nothing),h.lock)
    adapter===nothing && return _block_invocation!(ctx,"delivery adapter unavailable")
    adapter.version==address["version"] || return _block_invocation!(ctx,"delivery adapter version mismatch")
    String(adapter.capability)==get(address,"capability","unsafe") || return _block_invocation!(ctx,"delivery capability mismatch")
    if row.state=="sent"
        return _transition!(h;context=ctx,point=:delivery_already_sent) do db,seq
            _finish_task!(db,t,Dict("status"=>"completed","outbox"=>id))
        end
    end
    remote=nothing
    if row.state in ("sending","uncertain")
        if adapter.capability==:unsafe
            return _transition!(h;context=ctx,point=:delivery_uncertain) do db,seq
                _exec!(db,"UPDATE claw_outbox SET state='uncertain' WHERE id=?",(id,))
                _exec!(db,"UPDATE claw_tasks SET status='pending',token=NULL,blocked='uncertain delivery' WHERE id=?",(t.id,))
            end
        elseif adapter.capability==:reconcile
            remote=adapter.reconcile(address,row.logical_key,_dnull(row.receipt))
            remote===nothing && return _block_invocation!(ctx,"uncertain delivery")
            remote===:retry && (remote=nothing)
        end
    end
    if remote===nothing
        row.attempt<h.limits.attempts || return _block_invocation!(ctx,"delivery attempt budget exhausted")
        _transition!(h;context=ctx,point=:delivery_intent) do db,seq
            _exec!(db,"UPDATE claw_outbox SET state='sending',attempt=attempt+1 WHERE id=?",(id,))
        end
        _verify_invocation!(ctx)
        try
            remote=adapter.send(address["routing"],row.body,row.logical_key)
        catch err
            return _transition!(h;context=ctx,point=:delivery_failure) do db,seq
                _exec!(db,"UPDATE claw_outbox SET state='uncertain',error=? WHERE id=?",(_diagnostic(h,err),id))
                delay=h.limits.retry_delays[min(Int(row.attempt)+1,length(h.limits.retry_delays))]
                _exec!(db,"UPDATE claw_tasks SET status='pending',token=NULL,due_at=?,blocked='uncertain delivery' WHERE id=?",
                    (h.clock()+min(delay,h.limits.max_retry_delay),t.id))
            end
        end
        h.fault(:after_remote_send,h)
    end
    _transition!(h;context=ctx,point=:delivery_receipt) do db,seq
        _exec!(db,"UPDATE claw_outbox SET state='sent',receipt=?,error=NULL WHERE id=?",(JSON.json(_sanitize_integration_value(remote)),id))
        _exec!(db,raw"""UPDATE claw_evals SET fallback_sent=1 WHERE id IN
            (SELECT json_extract(input_json,'$.supervision.eval_id') FROM claw_tasks WHERE ?='watcher-failure:' || id)""",(row.logical_key,))
        post=remote isa AbstractDict ? get(remote,"_claw_response_post",nothing) : nothing
        channel=get(address["routing"],"channel_id",nothing)
        if post!==nothing && channel!==nothing && _dnull(row.entry_id)!==nothing
            _exec!(db,"INSERT INTO claw_platform_entries VALUES(?,?,?) ON CONFLICT(channel_id,platform_id) DO UPDATE SET entry_id=excluded.entry_id",
                (channel,string(post),row.entry_id))
        end
        _finish_task!(db,t,Dict("status"=>"completed","outbox"=>id))
    end
end

function resolve_delivery!(h::Harness,id::String;receipt,note::String)
    isempty(strip(note)) && throw(ArgumentError("resolution evidence required"))
    _transition!(h;point=:delivery_resolution) do db,seq
        o=_done(db,"SELECT * FROM claw_outbox WHERE id=?",(id,))
        o.state=="uncertain" || throw(ArgumentError("delivery is not uncertain"))
        _exec!(db,"UPDATE claw_outbox SET state='sent',receipt=?,error=? WHERE id=?",(JSON.json(receipt),first(note,2000),id))
        for t in _drows(db,"SELECT * FROM claw_tasks WHERE kind='delivery' AND status='pending'")
            get(JSON.parse(t.input_json),"outbox",nothing)==id || continue
            _finish_task!(db,t,Dict("status"=>"completed","outbox"=>id,"operator"=>true))
        end
    end
end

"""Indexing runs after history/receipts commit. Failure leaves a retryable job.
Authoritative SQL deletion masks must also be applied by search readers.
"""
# Compute embeddings and tokenizer work outside the SQLite writer. LocalSearch's
# native loader is then reused with pure memoized callbacks inside the index-only
# transaction. No shared Store callback is temporarily swapped.
function _prepare_index_store(store,text)
    store.embed===nothing && return store
    counts=Dict{String,Int}()
    counter=value->get!(counts,String(value)) do
        Int(store.token_count(value))
    end
    prepared=LocalSearch.Store(store.db,store.embed,store.embed_model,store.dimensions,store.vec_initialized,
        counter,store.chunk_max_tokens,store.chunk_overlap_tokens)
    chunks=LocalSearch.chunk_text_by_tokens(prepared,text)
    texts=[LocalSearch.Embed.format_document_for_embedding(c.text;title="session",model=store.embed_model) for c in chunks]
    embeddings=store.embed(texts)
    LocalSearch.Store(store.db,values->begin
            values==texts || error("index preparation changed before commit")
            embeddings
        end,store.embed_model,store.dimensions,store.vec_initialized,value->counts[String(value)],
        store.chunk_max_tokens,store.chunk_overlap_tokens)
end

function drain_index_jobs!(h::Harness;limit::Int=16)
    h.assistant===nothing && return 0
    store=h.assistant.session_store
    jobs=_dread(db->_drows(db,"SELECT * FROM claw_index_jobs WHERE state IN ('pending','redacted') AND due_at<=? LIMIT ?",(h.clock(),limit)),h)
    done=0
    for job in jobs
        h.state===:open || break
        try
            captured=_dread(db->_done(db,"SELECT entry,is_deleted FROM session_entries WHERE entry_id=?",(job.entry_id,)),h)
            captured===nothing && continue
            original=store.write_search_store
            prepared=job.state=="redacted" || captured.is_deleted==1 ? original : _prepare_index_store(original,captured.entry)
            applied=Agentif.with_session_write(store) do db,search_store
                h.state===:open || return false
                _done(db,"SELECT owner_epoch FROM claw_runtime_meta WHERE id=1").owner_epoch==h.epoch || throw(StaleInvocation())
                current=_done(db,"SELECT * FROM claw_index_jobs WHERE entry_id=?",(job.entry_id,))
                current.revision==job.revision || return false
                entry=_done(db,"SELECT entry,is_deleted FROM session_entries WHERE entry_id=?",(job.entry_id,))
                if current.state=="redacted" || entry.is_deleted==1
                    LocalSearch.delete!(search_store,"session:entry:$(job.entry_id)")
                else
                    entry.entry==captured.entry || return false
                    decoded=JSON.parse(entry.entry,Agentif.SessionEntry)
                    tags=String["session_entry"]
                    (decoded.channel_flags===nothing || decoded.channel_flags & 0x01 == 0) && push!(tags,"session:public")
                    decoded.search_channel_id===nothing || push!(tags,"session:ch:$(decoded.search_channel_id)")
                    LocalSearch.load!(prepared,entry.entry;id="session:entry:$(job.entry_id)",title="session",tags)
                end
                _exec!(db,"UPDATE claw_index_jobs SET state='done',attempts=attempts+1,error=NULL WHERE entry_id=?",(job.entry_id,))
                true
            end
            applied && (done+=1)
        catch err
            delay=min(h.limits.max_retry_delay,h.limits.retry_delays[min(Int(job.attempts)+1,length(h.limits.retry_delays))])
            execute_write(h.writer,"UPDATE claw_index_jobs SET attempts=attempts+1,error=?,due_at=? WHERE entry_id=?",(_diagnostic(h,err),h.clock()+delay,job.entry_id))
        end
    end
    done
end
