module AgentifSQLiteExt

using Agentif
using Agentif: UID8
using JSON
using LocalSearch
using SQLite

function _fetch_one_copy(db::SQLite.DB, sql::AbstractString, params = ())
    cursor = SQLite.DBInterface.execute(db, sql, params)
    try
        state = iterate(cursor)
        state === nothing && return nothing
        row = state[1]
        names = Tuple(propertynames(row))
        return NamedTuple{names}(map(name -> getproperty(row, name), names))
    finally
        SQLite.DBInterface.close!(cursor)
    end
end

function _ensure_column!(db::SQLite.DB, table::String, column::String, declaration::String)
    found = false
    for row in SQLite.DBInterface.execute(db, "PRAGMA table_info($table)")
        found |= String(row.name) == column
    end
    found && return false
    SQLite.execute(db, "ALTER TABLE $table ADD COLUMN $declaration")
    return true
end

function Agentif.init_sqlite_session_schema!(db::SQLite.DB)
    SQLite.execute(db, "PRAGMA journal_mode=WAL")
    SQLite.execute(db, "PRAGMA synchronous=NORMAL")
    SQLite.execute(db, "PRAGMA foreign_keys=ON")
    SQLite.execute(db, "PRAGMA busy_timeout=5000")

    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS session_entries (
            rowid INTEGER PRIMARY KEY AUTOINCREMENT,
            entry_id TEXT NOT NULL UNIQUE,
            parent_id TEXT,
            created_at REAL NOT NULL,
            entry TEXT NOT NULL,
            is_compaction INTEGER NOT NULL DEFAULT 0,
            first_kept_entry_id TEXT,
            is_deleted INTEGER NOT NULL DEFAULT 0,
            user_id TEXT,
            channel_id TEXT,
            search_channel_id TEXT,
            channel_flags INTEGER
        )
    """)
    # Added after the initial schema: existing databases need the column too.
    _ensure_column!(db, "session_entries", "post_id", "post_id TEXT")
    SQLite.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_entries_parent
        ON session_entries(parent_id)
    """)
    SQLite.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_entries_entry_id
        ON session_entries(entry_id)
    """)
    SQLite.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_entries_post_id
        ON session_entries(post_id)
    """)
    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS session_branches (
            branch_id TEXT PRIMARY KEY,
            leaf_entry_id TEXT
        )
    """)
    return nothing
end

mutable struct SQLiteSessionStore <: Agentif.SessionStore
    db::SQLite.DB
    search_store::LocalSearch.Store
    write_search_store::LocalSearch.Store
    execute_write::Function
    write_lock::ReentrantLock
    branch_locks::Dict{String, ReentrantLock}
    branch_locks_lock::ReentrantLock
end

function Agentif.SQLiteSessionStore(
        db::SQLite.DB,
        search_store::LocalSearch.Store;
        write_search_store::LocalSearch.Store = search_store,
        execute_write::Union{Nothing, Function} = nothing,
    )
    Agentif.init_sqlite_session_schema!(db)
    executor = execute_write === nothing ? (f -> f(write_search_store.db)) : execute_write
    return SQLiteSessionStore(
        db,
        search_store,
        write_search_store,
        executor,
        ReentrantLock(),
        Dict{String, ReentrantLock}(),
        ReentrantLock(),
    )
end

function Agentif.SQLiteSessionStore(db_path::String; kw...)
    db = SQLite.DB(db_path)
    store = LocalSearch.Store(db; kw...)
    return Agentif.SQLiteSessionStore(db, store)
end

# ─── Store method implementations ───

function _write_transaction(f::Function, store::SQLiteSessionStore)
    return lock(store.write_lock) do
        return store.execute_write() do db
            db === store.write_search_store.db || error("SQLiteSessionStore write executor returned the wrong connection")
            SQLite.execute(db, "BEGIN IMMEDIATE")
            try
                result = f(db, store.write_search_store)
                SQLite.execute(db, "COMMIT")
                return result
            catch
                if SQLite.intransaction(db)
                    try
                        SQLite.execute(db, "ROLLBACK")
                    catch
                    end
                end
                rethrow()
            end
        end
    end
end

function Agentif.with_session_write(f::Function, store::SQLiteSessionStore)
    return _write_transaction(f, store)
end

function session_entry_tags(entry::Agentif.SessionEntry)
    tags = ["session_entry"]
    if entry.channel_flags === nothing || (entry.channel_flags & 0x01) == 0
        push!(tags, "session:public")
    end
    if entry.search_channel_id !== nothing
        push!(tags, "session:ch:$(entry.search_channel_id)")
    end
    return tags
end

Agentif.append_entry!(store::SQLiteSessionStore, entry::Agentif.SessionEntry) =
    _append_entry!(store, entry, nothing)

# The entry and its branch leaf commit in one transaction, so a crash can never
# leave the entry outside its branch.
Agentif.append_branch_entry!(store::SQLiteSessionStore, branch_id::String, entry::Agentif.SessionEntry) =
    _append_entry!(store, entry, branch_id)

function _append_entry!(store::SQLiteSessionStore, entry::Agentif.SessionEntry, branch_id::Union{Nothing, String})
    entry_json = JSON.json(entry)
    _write_transaction(store) do db, search_store
        SQLite.execute(
            db,
            """INSERT INTO session_entries
               (entry_id, parent_id, created_at, entry, is_compaction, first_kept_entry_id,
                is_deleted, user_id, channel_id, search_channel_id, channel_flags, post_id)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                entry.id,
                entry.parent_id,
                entry.created_at,
                entry_json,
                entry.is_compaction ? 1 : 0,
                entry.first_kept_entry_id,
                entry.is_deleted ? 1 : 0,
                entry.user_id,
                entry.channel_id,
                entry.search_channel_id,
                entry.channel_flags,
                entry.post_id,
            ),
        )
        branch_id === nothing || _set_branch_leaf!(db, branch_id, entry.id)
        doc_id = "session:entry:$(entry.id)"
        tags = session_entry_tags(entry)
        LocalSearch.load!(search_store, entry_json; id=doc_id, title="session", tags=tags)
    end
    return nothing
end

_set_branch_leaf!(db::SQLite.DB, branch_id::String, entry_id::String) = SQLite.execute(db,
    "INSERT OR REPLACE INTO session_branches (branch_id, leaf_entry_id) VALUES (?, ?)",
    (branch_id, entry_id))

function Agentif.get_entry(store::SQLiteSessionStore, entry_id::String)
    row = _fetch_one_copy(
        store.db,
        "SELECT entry FROM session_entries WHERE entry_id = ?",
        (entry_id,),
    )
    row === nothing && return nothing
    return JSON.parse(String(row.entry), Agentif.SessionEntry)
end

function Agentif.get_branch_leaf(store::SQLiteSessionStore, branch_id::String)
    row = _fetch_one_copy(
        store.db,
        "SELECT leaf_entry_id FROM session_branches WHERE branch_id = ?",
        (branch_id,),
    )
    row === nothing && return nothing
    val = row.leaf_entry_id
    return val === missing ? nothing : String(val)
end

function Agentif.set_branch_leaf!(store::SQLiteSessionStore, branch_id::String, entry_id::String)
    _write_transaction(store) do db, _
        _set_branch_leaf!(db, branch_id, entry_id)
    end
    return nothing
end

function Agentif.lock_branch(f::Function, store::SQLiteSessionStore, branch_id::String)
    branch_lock = lock(store.branch_locks_lock) do
        get!(store.branch_locks, branch_id) do
            ReentrantLock()
        end
    end
    return lock(branch_lock) do
        f()
    end
end

# ─── Lineage walk ───
#
# `Agentif.load_branch` / `load_branch_with_boundaries` walk parents through
# `get_entry`, which this store implements, so the SQLite store inherits exactly
# the in-memory lineage semantics (stop at the first compaction ancestor, but
# keep walking to `first_kept_entry_id`). A recursive CTE cannot express the
# `first_kept_entry_id` hand-off, so the walk stays in Julia.

# ─── Search ───

function Agentif.search_sessions(store::SQLiteSessionStore, query::String; limit::Int=10, current_search_channel_id::Union{Nothing, String}=nothing)
    tags = if current_search_channel_id === nothing
        ["session_entry"]
    else
        ["session:public", "session:ch:$current_search_channel_id"]
    end
    results = LocalSearch.search(store.search_store, query; tags=tags, limit=limit)
    out = Agentif.SessionSearchResult[]
    for r in results
        # doc_id format: "session:entry:{entry_id}"
        parts = split(r.id, ":"; limit=3)
        eid = length(parts) >= 3 ? parts[3] : ""
        push!(out, Agentif.SessionSearchResult(eid, r.text, r.score))
    end
    return out
end

# ─── Scrub ───

function Agentif.scrub_post!(store::SQLiteSessionStore, post_id::String)
    count = _write_transaction(store) do db, search_store
        # `post_id` is the platform message id. Entries written before the column
        # existed used it as the entry id, so match either.
        rows = SQLite.DBInterface.execute(
            db,
            """SELECT entry_id, entry FROM session_entries
               WHERE (post_id = ? OR (post_id IS NULL AND entry_id = ?)) AND is_deleted = 0""",
            (post_id, post_id),
        ) |> SQLite.rowtable
        lookup = id -> begin
            row = _fetch_one_copy(db, "SELECT entry FROM session_entries WHERE entry_id = ?", (id,))
            row === nothing ? nothing : JSON.parse(String(row.entry), Agentif.SessionEntry)
        end
        count = 0
        for row in rows
            matched = JSON.parse(String(row.entry), Agentif.SessionEntry)
            for entry in Agentif.same_run_chain(lookup, matched)
                entry.is_deleted && continue
                # Rewrite the stored entry without its messages: flagging is_deleted is
                # not enough, the lineage walk replays whatever the entry JSON holds.
                scrubbed = Agentif.scrubbed_entry(entry)
                Base.delete!(search_store, "session:entry:$(entry.id)")
                SQLite.execute(
                    db,
                    "UPDATE session_entries SET entry = ?, is_deleted = 1, user_id = NULL WHERE entry_id = ?",
                    (JSON.json(scrubbed), entry.id),
                )
                count += 1
            end
        end
        return count
    end
    count == 0 && return nothing
    @info "scrub_post!: scrubbed session entries" post_id count
    return nothing
end

end
