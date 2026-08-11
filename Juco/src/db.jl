# Single SQLite database holding everything Juco persists:
#   - session_entries / session_branches (Agentif.SQLiteSessionStore, via AgentifSQLiteExt)
#   - LocalSearch FTS tables (used by the session store for session search)
#   - juco_memories: append-only agent memory, auto-injected into the system prompt
#   - juco_sessions: session metadata for listing/resuming

struct JucoDB
    db::SQLite.DB
    session_store::Agentif.SessionStore
end

const DEFAULT_DB_PATH = joinpath(homedir(), ".juco", "juco.sqlite")

function opendb(path::AbstractString = DEFAULT_DB_PATH)
    mkpath(dirname(abspath(path)))
    db = SQLite.DB(path)
    search_store = LocalSearch.Store(db)
    session_store = Agentif.SQLiteSessionStore(db, search_store)
    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS juco_memories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            content TEXT NOT NULL
        )
    """)
    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS juco_sessions (
            id TEXT PRIMARY KEY,
            title TEXT,
            cwd TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
    """)
    return JucoDB(db, session_store)
end

# ─── Memories ───

function remember!(jdb::JucoDB, content::AbstractString)
    SQLite.execute(jdb.db,
        "INSERT INTO juco_memories (created_at, content) VALUES (?, ?)",
        (time(), String(content)))
    return nothing
end

function memories(jdb::JucoDB; limit::Int = 50)
    rows = SQLite.DBInterface.execute(jdb.db,
        "SELECT content FROM juco_memories ORDER BY id DESC LIMIT ?", (limit,))
    out = String[String(r.content) for r in rows]
    return reverse!(out)  # oldest first for prompt injection
end

# ─── Sessions ───

function touch_session!(jdb::JucoDB, id::AbstractString; title::Union{Nothing, AbstractString} = nothing, cwd::AbstractString = pwd())
    now = time()
    SQLite.execute(jdb.db, """
        INSERT INTO juco_sessions (id, title, cwd, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            updated_at = excluded.updated_at,
            title = COALESCE(juco_sessions.title, excluded.title)
    """, (String(id), title === nothing ? nothing : String(title), String(cwd), now, now))
    return nothing
end

function list_sessions(jdb::JucoDB; limit::Int = 20)
    rows = SQLite.DBInterface.execute(jdb.db,
        "SELECT id, title, cwd, updated_at FROM juco_sessions ORDER BY updated_at DESC LIMIT ?", (limit,))
    return [(id = String(r.id),
             title = r.title === missing ? "" : String(r.title),
             cwd = r.cwd === missing ? "" : String(r.cwd),
             updated_at = Float64(r.updated_at)) for r in rows]
end

function latest_session(jdb::JucoDB)
    sessions = list_sessions(jdb; limit = 1)
    return isempty(sessions) ? nothing : sessions[1].id
end
