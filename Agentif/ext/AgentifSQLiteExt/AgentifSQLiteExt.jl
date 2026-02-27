module AgentifSQLiteExt

using Agentif
using Agentif: UID8
using JSON
using LocalSearch
using SQLite

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
    SQLite.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_entries_parent
        ON session_entries(parent_id)
    """)
    SQLite.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_entries_entry_id
        ON session_entries(entry_id)
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
            is_deleted, user_id, channel_id, search_channel_id, channel_flags)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
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

# ─── Lineage walk via recursive CTE ───

function Agentif.load_branch(store::SQLiteSessionStore, branch_id::String)
    leaf_id = Agentif.get_branch_leaf(store, branch_id)
    leaf_id === nothing && return Agentif.AgentState()
    return _load_lineage(store, leaf_id)
end

function Agentif.load_branch_with_boundaries(store::SQLiteSessionStore, branch_id::String)
    leaf_id = Agentif.get_branch_leaf(store, branch_id)
    if leaf_id === nothing
        return Agentif.AgentState(), Agentif.EntryBoundary[]
    end
    return _load_lineage_with_boundaries(store, leaf_id)
end

const LINEAGE_CTE_SQL = """
    WITH RECURSIVE lineage AS (
        SELECT entry_id, parent_id, is_compaction, first_kept_entry_id, entry,
               0 as depth, 0 as stop_after_this
        FROM session_entries WHERE entry_id = ?

        UNION ALL

        SELECT e.entry_id, e.parent_id, e.is_compaction, e.first_kept_entry_id, e.entry,
               l.depth + 1,
               CASE WHEN e.is_compaction THEN 1 ELSE 0 END
        FROM session_entries e
        JOIN lineage l ON e.entry_id = l.parent_id
        WHERE l.stop_after_this = 0
    )
    SELECT entry_id, is_compaction, first_kept_entry_id, entry
    FROM lineage ORDER BY depth DESC
"""

function _parse_lineage_rows(store::SQLiteSessionStore, leaf_id::String)
    rows = SQLite.DBInterface.execute(store.db, LINEAGE_CTE_SQL, (leaf_id,))
    entries = Agentif.SessionEntry[]
    compaction_idx = 0
    for row in rows
        entry = JSON.parse(String(row.entry), Agentif.SessionEntry)
        push!(entries, entry)
        if row.is_compaction == 1 && compaction_idx == 0
            compaction_idx = length(entries)
        end
    end

    # CTE returns root→leaf order. If compaction found, reorder:
    # compaction entry FIRST, then kept entries, then post-compaction entries
    if compaction_idx > 0
        compaction_entry = entries[compaction_idx]
        kept = entries[1:compaction_idx-1]
        post_compaction = entries[compaction_idx+1:end]
        entries = vcat([compaction_entry], kept, post_compaction)
    end

    return entries
end

function _load_lineage(store::SQLiteSessionStore, leaf_id::String)
    entries = _parse_lineage_rows(store, leaf_id)
    state = Agentif.AgentState()
    for entry in entries
        Agentif.apply_session_entry!(state, entry)
    end
    return state
end

function _load_lineage_with_boundaries(store::SQLiteSessionStore, leaf_id::String)
    entries = _parse_lineage_rows(store, leaf_id)
    state = Agentif.AgentState()
    boundaries = Agentif.EntryBoundary[]
    for entry in entries
        start_idx = length(state.messages) + 1
        Agentif.apply_session_entry!(state, entry)
        end_idx = length(state.messages)
        if end_idx >= start_idx
            push!(boundaries, Agentif.EntryBoundary(entry.id, start_idx, end_idx))
        end
    end
    return state, boundaries
end

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
    # entry_id IS the platform message ID, so look up by entry_id
    entries = SQLite.DBInterface.execute(store.db,
        "SELECT entry_id FROM session_entries WHERE entry_id = ? AND is_deleted = 0",
        (post_id,)) |> SQLite.rowtable
    isempty(entries) && return nothing
    for row in entries
        doc_id = "session:entry:$(row.entry_id)"
        try
            Base.delete!(store.search_store, doc_id)
        catch
        end
    end
    SQLite.execute(store.db,
        "UPDATE session_entries SET is_deleted = 1 WHERE entry_id = ?",
        (post_id,))
    @info "scrub_post!: marked session entry as deleted" entry_id=post_id
    return nothing
end

end
