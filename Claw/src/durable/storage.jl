function _durable_migration_7!(db)
    for (column, definition) in (
            ("claim_token", "TEXT"), ("claim_revision", "INTEGER NOT NULL DEFAULT 0"),
            ("owner_epoch", "INTEGER NOT NULL DEFAULT 0"), ("durable", "INTEGER NOT NULL DEFAULT 0"),
        )
        _column_exists(db, "claw_events", column) || _exec!(db, "ALTER TABLE claw_events ADD COLUMN $column $definition")
    end
    _exec!(
        db, """CREATE TABLE IF NOT EXISTS claw_runtime_meta
        (id INTEGER PRIMARY KEY CHECK(id=1), schema_version INTEGER NOT NULL, min_writer INTEGER NOT NULL,
         owner_epoch INTEGER NOT NULL DEFAULT 0, seq INTEGER NOT NULL DEFAULT 0, durability TEXT NOT NULL)"""
    )
    return _exec!(db, "INSERT OR IGNORE INTO claw_runtime_meta VALUES(1,10,10,0,0,'process_crash')")
end

function _durable_migration_8!(db)
    _exec!(
        db, """CREATE TABLE claw_events_new (
        id INTEGER PRIMARY KEY AUTOINCREMENT, dedup_key TEXT UNIQUE,source TEXT NOT NULL,name TEXT NOT NULL,
        payload TEXT NOT NULL,status TEXT NOT NULL CHECK(status IN ('pending','running','dispatched','done','failed','dead')),
        attempts INTEGER NOT NULL DEFAULT 0,lane TEXT NOT NULL,created_at REAL NOT NULL,
        next_attempt_at REAL NOT NULL DEFAULT 0,lease_expires_at REAL,last_error TEXT,
        claim_token TEXT,claim_revision INTEGER NOT NULL DEFAULT 0,owner_epoch INTEGER NOT NULL DEFAULT 0,batch INTEGER,durable INTEGER NOT NULL DEFAULT 0)"""
    )
    _exec!(db, "INSERT INTO claw_events_new(id,dedup_key,source,name,payload,status,attempts,lane,created_at,next_attempt_at,lease_expires_at,last_error,claim_token,claim_revision,owner_epoch,batch,durable) SELECT id,dedup_key,source,name,payload,status,attempts,lane,created_at,next_attempt_at,lease_expires_at,last_error,claim_token,claim_revision,owner_epoch,batch,durable FROM claw_events")
    _exec!(db, "DROP TABLE claw_events")
    _exec!(db, "ALTER TABLE claw_events_new RENAME TO claw_events")
    _exec!(db, "CREATE INDEX idx_claw_events_claim ON claw_events(status,next_attempt_at)")
    _exec!(db, "CREATE INDEX idx_claw_events_lane ON claw_events(lane,status)")
    _exec!(db, "CREATE INDEX IF NOT EXISTS idx_claw_events_batch ON claw_events(batch)")
    for ddl in (
            "CREATE TABLE IF NOT EXISTS claw_dispatch_groups(group_key TEXT PRIMARY KEY,handlers TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS claw_frozen_members(group_key TEXT NOT NULL,event_id INTEGER NOT NULL UNIQUE,ordinal INTEGER NOT NULL,PRIMARY KEY(group_key,event_id))",
            "CREATE TABLE IF NOT EXISTS claw_filter_receipts(event_id INTEGER NOT NULL,handler_hash TEXT NOT NULL,verdict INTEGER NOT NULL,PRIMARY KEY(event_id,handler_hash))",
            """CREATE TABLE IF NOT EXISTS claw_agent_profiles(id TEXT PRIMARY KEY,version INTEGER NOT NULL,payload TEXT NOT NULL,hash TEXT NOT NULL)""",
            """CREATE TABLE IF NOT EXISTS claw_conversations(id TEXT PRIMARY KEY,branch_id TEXT NOT NULL UNIQUE,profile_id TEXT,
            fork_parent TEXT,fork_cutoff TEXT,owner_task TEXT,background INTEGER NOT NULL DEFAULT 0,
            routing TEXT NOT NULL DEFAULT '{}',delivery TEXT,context_revision INTEGER NOT NULL DEFAULT 0,created_seq INTEGER NOT NULL)""",
            """CREATE TABLE IF NOT EXISTS claw_submissions(id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL REFERENCES claw_conversations(id),
            request_id TEXT NOT NULL,mode TEXT NOT NULL CHECK(mode IN ('followup','steer','write')),input_json TEXT NOT NULL,
            hash TEXT NOT NULL,origin TEXT NOT NULL,profile_id TEXT,admitted_seq INTEGER NOT NULL,placed_seq INTEGER,
            state TEXT NOT NULL CHECK(state IN ('queued','placed','answered','unanswered','withdrawn')),run_id TEXT,
            answer_entry TEXT,reason TEXT,routing TEXT NOT NULL DEFAULT '{}',delivery TEXT,UNIQUE(conversation_id,request_id))""",
            """CREATE TABLE IF NOT EXISTS claw_runs(id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL REFERENCES claw_conversations(id),
            profile_id TEXT NOT NULL,status TEXT NOT NULL,task_id TEXT,answer_entry TEXT,reason TEXT,revision INTEGER NOT NULL DEFAULT 0,
            routing TEXT NOT NULL DEFAULT '{}',delivery TEXT)""",
            """CREATE UNIQUE INDEX IF NOT EXISTS claw_one_active_run ON claw_runs(conversation_id) WHERE status='active'""",
            """CREATE TABLE IF NOT EXISTS claw_tasks(id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL REFERENCES claw_conversations(id),run_id TEXT,
            owner_task TEXT,creation_key TEXT NOT NULL,background INTEGER NOT NULL DEFAULT 0,kind TEXT NOT NULL,
            version INTEGER NOT NULL DEFAULT 1,codec INTEGER NOT NULL DEFAULT 1,input_json TEXT NOT NULL,checkpoint TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('pending','running','waiting','completing','terminal')),due_at REAL NOT NULL DEFAULT 0,
            attempt INTEGER NOT NULL DEFAULT 0,epoch INTEGER NOT NULL DEFAULT 0,token TEXT,revision INTEGER NOT NULL DEFAULT 0,
            cancel INTEGER NOT NULL DEFAULT 0,outcome TEXT,blocked TEXT,progress TEXT,created_seq INTEGER NOT NULL)""",
            """CREATE UNIQUE INDEX IF NOT EXISTS claw_creation_key ON claw_tasks(conversation_id,COALESCE(owner_task,''),creation_key)""",
            """CREATE TABLE IF NOT EXISTS claw_task_waits(waiter TEXT NOT NULL REFERENCES claw_tasks(id),awaited TEXT NOT NULL REFERENCES claw_tasks(id),
            PRIMARY KEY(waiter,awaited))""",
            """CREATE TABLE IF NOT EXISTS claw_task_attempts(task_id TEXT NOT NULL,attempt INTEGER NOT NULL,token TEXT NOT NULL,
            request_key TEXT NOT NULL,started_seq INTEGER NOT NULL,ended_seq INTEGER,unknown_spend INTEGER NOT NULL DEFAULT 0,
            failure TEXT,PRIMARY KEY(task_id,attempt))""",
            """CREATE TABLE IF NOT EXISTS claw_entry_runtime(entry_id TEXT PRIMARY KEY REFERENCES session_entries(entry_id),run_id TEXT,task_id TEXT,
            stop_reason TEXT,audit TEXT,eligible INTEGER NOT NULL,codec INTEGER NOT NULL DEFAULT 1,seq INTEGER NOT NULL)""",
            """CREATE TABLE IF NOT EXISTS claw_usage(task_id TEXT NOT NULL,attempt INTEGER NOT NULL,category TEXT NOT NULL,usage TEXT NOT NULL,
            seq INTEGER NOT NULL,PRIMARY KEY(task_id,attempt,category))""",
            """CREATE TABLE IF NOT EXISTS claw_event_dispatches(id TEXT PRIMARY KEY,group_key TEXT NOT NULL,handler_id TEXT NOT NULL,handler_snapshot TEXT NOT NULL,
            verdicts TEXT NOT NULL,submission_id TEXT,result TEXT,UNIQUE(group_key,handler_id))""",
            """CREATE TABLE IF NOT EXISTS claw_dispatch_members(dispatch_id TEXT NOT NULL REFERENCES claw_event_dispatches(id),event_id INTEGER NOT NULL,
            ordinal INTEGER NOT NULL,PRIMARY KEY(dispatch_id,event_id))""",
        )
        _exec!(db, ddl)
    end
    return
end

function _durable_migration_9!(db)
    for ddl in (
            """CREATE TABLE IF NOT EXISTS claw_tool_executions(task_id TEXT PRIMARY KEY REFERENCES claw_tasks(id),conversation_id TEXT NOT NULL,
            assistant_entry TEXT NOT NULL,call_id TEXT NOT NULL,ordinal INTEGER NOT NULL,tool_name TEXT NOT NULL,manifest TEXT NOT NULL,
            args TEXT NOT NULL,args_hash TEXT NOT NULL,env TEXT NOT NULL,profile_id TEXT NOT NULL,effect_key TEXT NOT NULL UNIQUE,
            effect_state TEXT NOT NULL,result_entry TEXT,result TEXT,UNIQUE(conversation_id,assistant_entry,call_id))""",
            """CREATE TABLE IF NOT EXISTS claw_outbox(id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL,run_id TEXT,entry_id TEXT,
            logical_key TEXT NOT NULL UNIQUE,address TEXT NOT NULL,body TEXT NOT NULL,state TEXT NOT NULL,
            attempt INTEGER NOT NULL DEFAULT 0,receipt TEXT,error TEXT,due_at REAL NOT NULL DEFAULT 0)""",
            """CREATE TABLE IF NOT EXISTS claw_index_jobs(entry_id TEXT PRIMARY KEY,revision INTEGER NOT NULL DEFAULT 0,state TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,error TEXT,due_at REAL NOT NULL DEFAULT 0)""",
        )
        _exec!(db, ddl)
    end
    return
end

function _durable_migration_10!(db)
    _exec!(db, "CREATE TABLE IF NOT EXISTS claw_platform_entries(channel_id TEXT NOT NULL,platform_id TEXT NOT NULL,entry_id TEXT NOT NULL,PRIMARY KEY(channel_id,platform_id))")
    _exec!(
        db, """CREATE TABLE IF NOT EXISTS claw_child_aliases(conversation_id TEXT NOT NULL,name TEXT NOT NULL,child_id TEXT NOT NULL,
        task_id TEXT NOT NULL,event_type TEXT,PRIMARY KEY(conversation_id,name))"""
    )
    return _exec!(
        db, """CREATE TABLE IF NOT EXISTS claw_managed_resources(id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL,owner_task TEXT,
        kind TEXT NOT NULL,correlation_key TEXT NOT NULL UNIQUE,state TEXT NOT NULL,details TEXT NOT NULL)"""
    )
end
merge!(CLAW_MIGRATIONS, Dict(7 => _durable_migration_7!, 8 => _durable_migration_8!, 9 => _durable_migration_9!, 10 => _durable_migration_10!))

# The invocation still owns its task: same owner epoch, token and revision, not
# cancelled, and the harness still accepts results (a closing harness records
# the results of work it lets finish).
function _check_fence(db, ctx)
    h = ctx.harness
    t = _fetch_one(db, "SELECT status, token, epoch, revision, cancel FROM claw_tasks WHERE id=?", (ctx.task_id,))
    epoch = _fetch_one(db, "SELECT owner_epoch FROM claw_runtime_meta WHERE id=1").owner_epoch
    ok = h.state in (:open, :closing) && epoch == ctx.epoch && t !== nothing && t.status == "running" &&
        t.token == ctx.token && t.epoch == ctx.epoch && t.revision == ctx.revision[] && t.cancel == 0
    ok || throw(StaleInvocation())
    return nothing
end

function _notify_commit!(h)
    notify(h.wake)
    lock(h.commits) do
        notify(h.commits)
    end
    return nothing
end

"""
    _await(f, h; timeout_s = Inf, abort = nothing)

Wait until `f()` returns something other than `nothing` and return it, re-checking
after every commit (and at least once a second), or return `nothing` on timeout or
abort. Waiting never changes durable state.
"""
function _await(f::Function, h; timeout_s::Real = Inf, abort = nothing)
    deadline = _monotonic_s() + timeout_s
    while true
        value = f()
        value === nothing || return value
        h.state === :poisoned && throw(HarnessPoisoned())
        abort !== nothing && Agentif.isaborted(abort) && return nothing
        remaining = deadline - _monotonic_s()
        remaining <= 0 && return nothing
        lock(h.commits) do
            timer = Timer(_ -> lock(() -> notify(h.commits), h.commits), min(1.0, remaining))
            try
                wait(h.commits)
            finally
                close(timer)
            end
        end
    end
    return
end

"""Internal mutation boundary. Only deterministic SQL belongs in its callback.

Commit outcome/adoption uncertainty poisons the harness. A known rolled-back
precommit rejection can be retried. Progress/final callbacks share the same fence.
"""
function _transition!(f::Function, h::Harness; context = nothing, point::Symbol = :transition)
    context === nothing || return lock(context.lock) do
        _transition_unlocked!(f, h, context, point)
    end
    return _transition_unlocked!(f, h, context, point)
end

function _transition_unlocked!(f, h, ctx, point)
    h.state === :poisoned && throw(HarnessPoisoned())
    h.state === :closed && error("harness is closed")
    committed = Ref(false)
    commit_started = Ref(false)
    try
        result, seq, revision = execute_write(h.writer) do db
            meta = _fetch_one(db, "SELECT * FROM claw_runtime_meta WHERE id=1")
            meta.owner_epoch == h.epoch || throw(StaleInvocation())
            ctx === nothing || _check_fence(db, ctx)
            SQLite.execute(db, "BEGIN IMMEDIATE")
            try
                seq = Int(meta.seq) + 1
                value = f(db, seq)
                revision = ctx === nothing ? 0 : ctx.revision[] + 1
                ctx === nothing || _exec!(db, "UPDATE claw_tasks SET revision=? WHERE id=?", (revision, ctx.task_id))
                _exec!(db, "UPDATE claw_runtime_meta SET seq=? WHERE id=1", (seq,))
                h.fault(Symbol("before_", point), h)
                commit_started[] = true
                SQLite.execute(db, "COMMIT")
                committed[] = true
                return value, seq, revision
            catch
                SQLite.intransaction(db) && SQLite.execute(db, "ROLLBACK")
                rethrow()
            end
        end
        ctx === nothing || (ctx.revision[] = revision)
        h.fault(Symbol("after_", point), h)
        _publish!(h, seq)
        _notify_commit!(h)
        return result
    catch
        (committed[] || commit_started[]) && (h.state = :poisoned)
        rethrow()
    end
end

function _task_create!(
        db, seq, conversation, kind, key; run = nothing, owner = nothing,
        background = false, input = Dict(), checkpoint = Dict("phase" => "prepare")
    )
    old = _fetch_one(
        db, "SELECT id FROM claw_tasks WHERE conversation_id=? AND COALESCE(owner_task,'')=? AND creation_key=?",
        (conversation, something(owner, ""), key)
    )
    old === nothing || return String(old.id)
    id = _new_id()
    _exec!(
        db, """INSERT INTO claw_tasks(id,conversation_id,run_id,owner_task,creation_key,background,kind,input_json,checkpoint,status,created_seq)
        VALUES(?,?,?,?,?,?,?,?,?,'pending',?)""", (id, conversation, run, owner, key, Int(background), kind, JSON.json(input), JSON.json(checkpoint), seq)
    )
    return id
end

function _entry!(
        db, h, seq, c, messages; run = nothing, task = nothing, audit = nothing, stop = nothing,
        compaction = false, first_kept = nothing, post_id = nothing
    )
    leaf = _fetch_one(db, "SELECT leaf_entry_id FROM session_branches WHERE branch_id=?", (c.branch_id,))
    issued = run === nothing ? nothing : _fetch_one(db, "SELECT routing FROM claw_runs WHERE id=?", (run,))
    route = JSON.parse(issued === nothing ? c.routing : issued.routing)
    entry = Agentif.SessionEntry(;
        id = _new_id(), parent_id = leaf === nothing ? nothing : _or_nothing(leaf.leaf_entry_id),
        messages = Agentif.StoredAgentMessage[messages...], run_id = run, is_compaction = compaction,
        first_kept_entry_id = first_kept, channel_id = get(route, "channel_id", nothing), user_id = get(route, "user_id", nothing),
        search_channel_id = get(route, "search_channel_id", nothing), channel_flags = get(route, "channel_flags", nothing),
        post_id = something(post_id, get(route, "post_id", nothing), "")
    )
    Agentif.append_session_batch!(db, c.branch_id, [entry])
    # Audit-only entries (no messages) leave the model context unchanged.
    isempty(messages) || _exec!(db, "UPDATE claw_conversations SET context_revision=context_revision+1 WHERE id=?", (c.id,))
    _exec!(
        db, "INSERT INTO claw_entry_runtime(entry_id,run_id,task_id,stop_reason,audit,eligible,seq) VALUES(?,?,?,?,?,?,?)",
        (entry.id, run, task, stop, audit === nothing ? nothing : JSON.json(audit), isempty(messages) ? 0 : 1, seq)
    )
    _exec!(db, "INSERT INTO claw_index_jobs(entry_id,state) VALUES(?,'pending')", (entry.id,))
    return entry.id
end
