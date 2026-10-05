function _advance_owner!(db)
    _exec!(db, "UPDATE claw_runtime_meta SET owner_epoch=owner_epoch+1 WHERE id=1")
    return Int(_done(db, "SELECT owner_epoch FROM claw_runtime_meta WHERE id=1").owner_epoch)
end

function _make_harness(assistant, writer, readers, history, epoch, owner, owns;
        limits = HarnessLimits(), compaction = Agentif.CompactionConfig(), stream_fn = Agentif.stream,
        clock = time, fault = (point, harness) -> nothing, durability = :process_crash)
    limits.models > 0 && limits.tools > 0 && limits.attempts > 0 || throw(ArgumentError("capacities and attempts must be positive"))
    !isempty(limits.retry_delays) && all(x->isfinite(x) && x>=0,limits.retry_delays) || throw(ArgumentError("invalid retry budget"))
    all(x->isfinite(x) && x>0,(limits.max_retry_delay,limits.tool_timeout,limits.request_timeout,limits.run_timeout)) || throw(ArgumentError("timeouts must be finite and positive"))
    isfinite(limits.progress_interval) && limits.progress_interval>=0 && limits.progress_bytes>=32 && limits.observer_frames>0 || throw(ArgumentError("invalid progress or observation limits"))
    durability in (:process_crash, :acknowledged_write) || throw(ArgumentError("invalid durability mode"))
    execute_write(writer) do db
        SQLite.execute(db, durability === :process_crash ? "PRAGMA synchronous=NORMAL" : "PRAGMA synchronous=FULL")
        _exec!(db,"UPDATE claw_runtime_meta SET durability=? WHERE id=1",(String(durability),))
    end
    h = Harness(assistant,writer,readers,history,epoch,owner,owns,Dict{String,Agentif.Agent}(),
        Dict{Tuple{String,String},ToolSpec}(),Dict{String,LLMTools.LocalExecutionEnv}(),Dict{String,DeliveryAdapter}(),
        limits,compaction,stream_fn,clock,fault,:open,ReentrantLock(),Dict{String,Any}(),Any[],nothing,Threads.Event(),nothing,0.0)
    _recover_harness!(h)
    return h
end

"""Open a file-backed, single-host runtime. Opening recovers records; `resume!`,
submission, or wait activates scheduling after manifests have been registered.
"""
function open_harness(path::String; backup_path::Union{Nothing,String}=nothing, kwargs...)
    _is_private_memory_path(path) && throw(ArgumentError("durable runtime requires a file-backed database"))
    Sys.iswindows() && error("durable ownership requires a supported OS advisory lock")
    owner = _acquire_owner_lock(path)
    db = SQLite.DB(path)
    writer = nothing
    try
        _prepare_database!(db;backup_path)
        Agentif.init_sqlite_session_schema!(db)
        _validate_shared_database!(db)
        epoch = _advance_owner!(db)
        writer = SQLiteWriter(path, db)
        readers = ReaderPool(path, db)
        h = _make_harness(nothing,writer,readers,DurableSessionReader(readers),epoch,owner,true;kwargs...)
        _backfill_conversations!(h)
        return h
    catch
        writer === nothing || close_writer!(writer)
        close(db)
        owner === nothing || close(owner)
        rethrow()
    end
end

function open_harness(assistant::AgentAssistant; limits = HarnessLimits(models = assistant.pipeline.max_concurrent_evals), kwargs...)
    old = assistant._harness[]
    old === nothing || return old
    _is_private_memory_path(assistant.db_path) && throw(ArgumentError("durable runtime requires a file-backed database"))
    assistant._owner_lock[] === nothing && error("assistant must hold the database owner lock")
    h = _make_harness(assistant,assistant._writer,assistant._readers,assistant.session_store,
        assistant._owner_epoch, nothing, false;limits,kwargs...)
    assistant._harness[] = h
    _backfill_conversations!(h)
    return h
end

function _backfill_conversations!(h)
    _transition!(h; point = :backfill) do db,seq
        for branch in _drows(db,"SELECT branch_id FROM session_branches")
            _exec!(db,"INSERT OR IGNORE INTO claw_conversations(id,branch_id,created_seq) VALUES(?,?,?)",(_did(),branch.branch_id,seq))
        end
    end
end

"""Register an immutable effective configuration, retaining credentials only live.

The profile ID is a canonical configuration digest. A new prompt, tool contract,
policy, model, or environment creates a different ID. Reload the same ID before
resuming issued work. Untrusted tool intersections are enforced here and on use.
"""
function register_profile!(h::Harness, agent::Agentif.Agent; specs = nothing,
        environment = LLMTools.LocalExecutionEnv(LLMTools.EnvRef(h.assistant === nothing ? pwd() : h.assistant.config.base_dir)),
        trust::Symbol = :owner, credential_ref::String = agent.model.provider, version::Int = 1)
    trust in (:owner,:untrusted) || throw(ArgumentError("invalid trust"))
    specs === nothing && (specs = ToolSpec[
        haskey(DURABLE_NATIVE_ADAPTERS,t) ? ToolSpec(t;version="durable-child-v1",replay=:safe,effect=:child,invoke=DURABLE_NATIVE_ADAPTERS[t]) :
        haskey(DURABLE_RESOURCE_ADAPTERS,t) ? ToolSpec(t;version="durable-resource-v1",replay=DURABLE_RESOURCE_ADAPTERS[t].replay,
            effect=:resource,invoke=DURABLE_RESOURCE_ADAPTERS[t].invoke) :
        haskey(DURABLE_FILE_ADAPTERS,t) ? ToolSpec(t;version="durable-file-v1",replay=DURABLE_FILE_ADAPTERS[t].replay,
            effect=:file,capabilities=DURABLE_FILE_ADAPTERS[t].capabilities,invoke=DURABLE_FILE_ADAPTERS[t].invoke) : ToolSpec(t) for t in agent.tools])
    wanted = Set(t.name for t in agent.tools)
    chosen = ToolSpec[s for s in specs if s.tool.name in wanted && (trust === :owner || s.tool.name in UNTRUSTED_ALLOWED_TOOLS)]
    length(unique(s.tool.name for s in chosen)) == length(chosen) || throw(ArgumentError("duplicate tool names"))
    payload = Dict("version"=>version,"model"=>_profile_model(agent.model),"http_options"=>_profile_config(JSON.parse(JSON.json(agent.http_kw))),"prompt"=>agent.prompt,
        "tools"=>[_spec_data(s) for s in chosen],"env"=>_env_data(environment.ref),"trust"=>String(trust),"credential_ref"=>credential_ref)
    id = _digest(payload)
    lock(h.lock) do
        for s in chosen
            old=get(h.specs,(s.tool.name,s.version),nothing)
            old===nothing || _spec_data(old)==_spec_data(s) || error("tool version reused with a changed manifest")
        end
        old=get(h.environments,environment.ref.id,nothing)
        old===nothing || _env_data(old.ref)==_env_data(environment.ref) || error("environment ID reused with a changed revision")
    end
    _transition!(h;point=:profile) do db,seq
        _exec!(db,"INSERT OR IGNORE INTO claw_agent_profiles VALUES(?,?,?,?)",(id,version,JSON.json(payload),id))
    end
    lock(h.lock) do
        h.agents[id] = Agentif.with_tools(agent, Agentif.AgentTool[s.tool for s in chosen])
        for s in chosen
            old = get(h.specs,(s.tool.name,s.version),nothing)
            old === nothing || _spec_data(old) == _spec_data(s) || error("tool version reused with a changed manifest")
            h.specs[(s.tool.name,s.version)] = s
        end
        old = get(h.environments,environment.ref.id,nothing)
        old === nothing || _env_data(old.ref) == _env_data(environment.ref) || error("environment ID reused with a changed revision")
        h.environments[environment.ref.id] = environment
    end
    notify(h.wake)
    return AgentProfileRef(id)
end

function _resolve_profile(h, id)
    agent = lock(() -> get(h.agents,id,nothing),h.lock)
    p = _dread(h) do db
        row = _done(db,"SELECT * FROM claw_agent_profiles WHERE id=?",(id,))
        row === nothing ? nothing : JSON.parse(row.payload)
    end
    p === nothing && return nothing,"missing profile $id"
    _digest(p) == id && p["version"] == 1 || return nothing,"profile codec/version mismatch"
    if agent === nothing
        # Resolve the exact recorded model and credential reference from a live
        # host registration. This reconstructs derived child profiles without
        # changing their recorded prompt, tools, environment, or policy.
        candidates=lock(()->collect(h.agents),h.lock)
        for (other_id,other) in candidates
            other_profile=_dread(db->JSON.parse(_done(db,"SELECT payload FROM claw_agent_profiles WHERE id=?",(other_id,)).payload),h)
            other_profile["model"]==p["model"] && other_profile["credential_ref"]==p["credential_ref"] &&
                get(other_profile,"http_options",Dict())==get(p,"http_options",Dict()) || continue
            chosen=Agentif.AgentTool[]
            for manifest in p["tools"]
                spec=get(h.specs,(manifest["name"],manifest["version"]),nothing)
                spec===nothing && break
                push!(chosen,spec.tool)
            end
            length(chosen)==length(p["tools"]) || continue
            agent=Agentif.Agent(;prompt=p["prompt"],model=other.model,apikey=other.apikey,tools=chosen,http_kw=other.http_kw)
            lock(h.lock) do
                h.agents[id]=agent
            end
            break
        end
    end
    agent===nothing && return nothing,"profile/model credentials unavailable: $id"
    env = lock(() -> get(h.environments,p["env"]["id"],nothing),h.lock)
    env === nothing && return nothing,"missing recorded environment"
    _env_data(env.ref) == p["env"] && isdir(env.ref.root) && realpath(env.ref.root) == env.ref.root ||
        return nothing,"incompatible recorded environment"
    for manifest in p["tools"]
        s = lock(() -> get(h.specs,(manifest["name"],manifest["version"]),nothing),h.lock)
        s === nothing && return nothing,"missing tool $(manifest["name"]) version $(manifest["version"])"
        _spec_data(s) == manifest || return nothing,"incompatible tool manifest"
        p["trust"] == "owner" || s.tool.name in UNTRUSTED_ALLOWED_TOOLS || return nothing,"policy denies tool"
    end
    return (;agent,profile=p,env),nothing
end

function ensure_conversation!(h::Harness; branch_id::String, profile::Union{Nothing,AgentProfileRef}=nothing,
        delivery::Union{Nothing,DeliveryAddress}=nothing, routing = Dict{String,Any}())
    issued=delivery===nothing ? nothing : JSON.parse(JSON.json(delivery))
    if issued!==nothing
        adapter=lock(()->get(h.adapters,delivery.adapter,nothing),h.lock)
        issued["capability"]=adapter===nothing ? "unsafe" : String(adapter.capability)
    end
    id = _transition!(h;point=:conversation) do db,seq
        old = _done(db,"SELECT * FROM claw_conversations WHERE branch_id=?",(branch_id,))
        if old !== nothing
            if profile !== nothing
                _exec!(db,"UPDATE claw_conversations SET profile_id=?,delivery=?,routing=? WHERE id=?",
                    (profile.id,issued===nothing ? nothing : JSON.json(issued),JSON.json(_sanitize_integration_value(routing)),old.id))
            end
            return String(old.id)
        end
        id = _did()
        _exec!(db,"INSERT INTO claw_conversations(id,branch_id,profile_id,routing,delivery,created_seq) VALUES(?,?,?,?,?,?)",
            (id,branch_id,profile === nothing ? nothing : profile.id,JSON.json(_sanitize_integration_value(routing)),
             issued===nothing ? nothing : JSON.json(issued),seq))
        _exec!(db,"INSERT OR IGNORE INTO session_branches(branch_id) VALUES(?)",(branch_id,))
        return id
    end
    ConversationRef(id)
end

function close_harness!(h::Harness; mode::Symbol=:suspend,grace_s::Real=30)
    deadline=time()+grace_s
    mode in (:suspend,:abort) || throw(ArgumentError("invalid close mode"))
    mode === :abort && foreach(c -> abort_conversation!(h,c.id;include_background=true),
        _dread(db -> _drows(db,"SELECT id FROM claw_conversations"),h))
    h.state = :closing
    notify(h.wake)
    live = lock(() -> collect(values(h.live)),h.lock)
    foreach(x -> Agentif.abort!(x.context.abort),live)
    drained = timedwait(() -> lock(() -> isempty(h.live),h.lock),max(0.0,deadline-time());pollint=.02) === :ok
    drained || return (;status=:draining,reason=:noncooperative_invocation)
    indexed=h.indexer===nothing || timedwait(()->istaskdone(h.indexer),max(0.0,deadline-time());pollint=.02)===:ok
    indexed || return (;status=:draining,reason=:indexer_draining)
    stopped=h.scheduler === nothing || timedwait(() -> istaskdone(h.scheduler),1.0;pollint=.01)===:ok
    stopped || return (;status=:draining,reason=:scheduler_draining)
    # Reopening, rather than a shutdown callback, makes recovery decisions for
    # execute intents. It preserves unsafe-effect ambiguity at suspend boundaries.
    h.state = :closed
    if h.owns_connections
        close_readers!(h.readers)
        close_writer!(h.writer)
        close(h.readers.shared)
        h.owner === nothing || close(h.owner)
    end
    return (;status=:closed,mode)
end
