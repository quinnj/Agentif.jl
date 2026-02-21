module AgentifSQLiteExt

using Agentif
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
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            entry_id TEXT,
            created_at REAL NOT NULL,
            entry TEXT NOT NULL,
            is_compaction INTEGER NOT NULL DEFAULT 0,
            is_deleted INTEGER NOT NULL DEFAULT 0,
            user_id TEXT,
            post_id TEXT,
            channel_id TEXT,
            channel_flags INTEGER
        )
    """)
    SQLite.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_session_entries_session
        ON session_entries(session_id, id)
    """)
    return nothing
end

struct SQLiteSessionStore <: Agentif.SessionStore
    db::SQLite.DB
    search_store::LocalSearch.Store
end

function Agentif.SQLiteSessionStore(db::SQLite.DB, search_store::LocalSearch.Store)
    Agentif.init_sqlite_session_schema!(db)
    return SQLiteSessionStore(db, search_store)
end

function Agentif.SQLiteSessionStore(db_path::String; kw...)
    db = SQLite.DB(db_path)
    Agentif.init_sqlite_session_schema!(db)
    store = LocalSearch.Store(db; kw...)
    return SQLiteSessionStore(db, store)
end

function session_doc_id(session_id::String, entry::Agentif.SessionEntry)
    return "session:$(session_id):$(something(entry.id, string(entry.created_at)))"
end

function Agentif.session_entry_count(store::SQLiteSessionStore, session_id::String)
    rows = SQLite.DBInterface.execute(store.db, "SELECT COUNT(*) as n FROM session_entries WHERE session_id = ?", (session_id,))
    row = iterate(rows)
    return row === nothing ? 0 : Int(row[1].n)
end

function Agentif.session_entries(store::SQLiteSessionStore, session_id::String; start::Int = 1, limit::Union{Nothing, Int} = nothing)
    offset = max(0, start - 1)
    entries = Agentif.SessionEntry[]
    rows = if limit === nothing
        SQLite.DBInterface.execute(
            store.db,
            "SELECT entry FROM session_entries WHERE session_id = ? ORDER BY id ASC LIMIT -1 OFFSET ?",
            (session_id, offset),
        )
    else
        lim = max(0, limit)
        lim == 0 && return entries
        SQLite.DBInterface.execute(
            store.db,
            "SELECT entry FROM session_entries WHERE session_id = ? ORDER BY id ASC LIMIT ? OFFSET ?",
            (session_id, lim, offset),
        )
    end
    for row in rows
        push!(entries, JSON.parse(String(row.entry), Agentif.SessionEntry))
    end
    return entries
end

function Agentif.load_session(store::SQLiteSessionStore, session_id::String)
    state = Agentif.AgentState()
    state.session_id = session_id
    for entry in Agentif.session_entries(store, session_id)
        Agentif.apply_session_entry!(state, entry)
    end
    return state
end

function session_entry_tags(entry::Agentif.SessionEntry)
    tags = ["session_entry"]
    if entry.channel_id === nothing || entry.channel_flags === nothing || (entry.channel_flags & 0x01) == 0
        # No channel context, no flags, or public channel → visible to everyone
        push!(tags, "session:public")
    end
    if entry.channel_id !== nothing
        push!(tags, "session:ch:$(entry.channel_id)")
    end
    return tags
end

function Agentif.append_session_entry!(store::SQLiteSessionStore, session_id::String, entry::Agentif.SessionEntry)
    entry_json = JSON.json(entry)
    SQLite.execute(
        store.db,
        "INSERT INTO session_entries (session_id, entry_id, created_at, entry, is_compaction, user_id, post_id, channel_id, channel_flags) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            session_id,
            entry.id,
            entry.created_at,
            entry_json,
            entry.is_compaction ? 1 : 0,
            entry.user_id,
            entry.post_id,
            entry.channel_id,
            entry.channel_flags,
        ),
    )
    doc_id = session_doc_id(session_id, entry)
    tags = session_entry_tags(entry)
    LocalSearch.load!(store.search_store, entry_json; id = doc_id, title = "session", tags = tags)
    return nothing
end

function Agentif.search_sessions(store::SQLiteSessionStore, query::String; limit::Int=10, current_channel_id::Union{Nothing, String}=nothing)
    tags = if current_channel_id === nothing
        ["session_entry"]  # no channel context → all session entries
    else
        ["session:public", "session:ch:$current_channel_id"]  # public + own channel
    end
    results = LocalSearch.search(store.search_store, query; tags=tags, limit=limit)
    out = Agentif.SessionSearchResult[]
    for r in results
        parts = split(r.id, ":"; limit=3)
        sid = length(parts) >= 2 ? parts[2] : ""
        push!(out, Agentif.SessionSearchResult(sid, r.text, r.score))
    end
    return out
end

function Agentif.scrub_post!(store::SQLiteSessionStore, post_id::String)
    # Mark session entries as deleted and remove from search index.
    # The entries remain in the DB so load_session still returns the full
    # AgentState (preserving LLM prompt cache), but search skips them.
    rows = SQLite.DBInterface.execute(store.db,
        "SELECT id, session_id, entry FROM session_entries WHERE post_id = ? AND is_deleted = 0",
        (post_id,))
    entries = collect(rows)
    isempty(entries) && return nothing
    for row in entries
        # Remove from search index
        entry = try
            JSON.parse(String(row.entry), Agentif.SessionEntry)
        catch
            nothing
        end
        if entry !== nothing
            doc_id = session_doc_id(String(row.session_id), entry)
            try
                Base.delete!(store.search_store, doc_id)
            catch
            end
        end
    end
    # Batch mark as deleted
    SQLite.execute(store.db,
        "UPDATE session_entries SET is_deleted = 1 WHERE post_id = ?",
        (post_id,))
    @info "scrub_post!: marked session entries as deleted" post_id count=length(entries)
    return nothing
end

end
