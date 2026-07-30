module AgentifSQLiteExt

using Agentif
using Agentif: UID8
using JSON
using LocalSearch
using SQLite

function _ensure_column!(db::SQLite.DB, table::String, column::String, declaration::String)
    for row in SQLite.DBInterface.execute(db, "PRAGMA table_info($table)")
        String(row.name) == column && return false
    end
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
    branch_locks::Dict{String, ReentrantLock}
    branch_locks_lock::ReentrantLock
end

function Agentif.SQLiteSessionStore(db::SQLite.DB, search_store::LocalSearch.Store)
    Agentif.init_sqlite_session_schema!(db)
    return SQLiteSessionStore(db, search_store, Dict{String, ReentrantLock}(), ReentrantLock())
end

function Agentif.SQLiteSessionStore(db_path::String; kw...)
    db = SQLite.DB(db_path)
    Agentif.init_sqlite_session_schema!(db)
    store = LocalSearch.Store(db; kw...)
    return SQLiteSessionStore(db, store, Dict{String, ReentrantLock}(), ReentrantLock())
end

# ─── Store method implementations ───

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

function Agentif.append_entry!(store::SQLiteSessionStore, entry::Agentif.SessionEntry)
    entry_json = JSON.json(entry)
    SQLite.execute(
        store.db,
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
    doc_id = "session:entry:$(entry.id)"
    tags = session_entry_tags(entry)
    LocalSearch.load!(store.search_store, entry_json; id=doc_id, title="session", tags=tags)
    return nothing
end

function Agentif.get_entry(store::SQLiteSessionStore, entry_id::String)
    rows = SQLite.DBInterface.execute(
        store.db,
        "SELECT entry FROM session_entries WHERE entry_id = ?",
        (entry_id,),
    )
    row = iterate(rows)
    row === nothing && return nothing
    return JSON.parse(String(row[1].entry), Agentif.SessionEntry)
end

function Agentif.get_branch_leaf(store::SQLiteSessionStore, branch_id::String)
    rows = SQLite.DBInterface.execute(
        store.db,
        "SELECT leaf_entry_id FROM session_branches WHERE branch_id = ?",
        (branch_id,),
    )
    row = iterate(rows)
    row === nothing && return nothing
    val = row[1].leaf_entry_id
    return val === missing ? nothing : String(val)
end

function Agentif.set_branch_leaf!(store::SQLiteSessionStore, branch_id::String, entry_id::String)
    SQLite.execute(
        store.db,
        "INSERT OR REPLACE INTO session_branches (branch_id, leaf_entry_id) VALUES (?, ?)",
        (branch_id, entry_id),
    )
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
    # `post_id` is the platform message id. Entries written before the column
    # existed used it as the entry id, so match either.
    rows = SQLite.DBInterface.execute(
        store.db,
        """SELECT entry_id, entry FROM session_entries
           WHERE (post_id = ? OR (post_id IS NULL AND entry_id = ?)) AND is_deleted = 0""",
        (post_id, post_id),
    ) |> SQLite.rowtable
    isempty(rows) && return nothing
    for row in rows
        entry = JSON.parse(String(row.entry), Agentif.SessionEntry)
        # Rewrite the stored entry without its messages: flagging is_deleted is
        # not enough, the lineage walk replays whatever the entry JSON holds.
        scrubbed = Agentif.scrubbed_entry(entry)
        SQLite.execute(
            store.db,
            "UPDATE session_entries SET entry = ?, is_deleted = 1, user_id = NULL WHERE entry_id = ?",
            (JSON.json(scrubbed), row.entry_id),
        )
        try
            Base.delete!(store.search_store, "session:entry:$(row.entry_id)")
        catch
        end
    end
    @info "scrub_post!: scrubbed session entries" post_id count = length(rows)
    return nothing
end

end
