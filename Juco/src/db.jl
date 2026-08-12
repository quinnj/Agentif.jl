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
    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS juco_config (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
    """)
    return JucoDB(db, session_store)
end

# ─── Config (persistent key/value state, e.g. the selected model) ───

function get_config(jdb::JucoDB, key::AbstractString, default = nothing)
    return SQLite.DBInterface.execute(jdb.db,
            "SELECT value FROM juco_config WHERE key = ?", (String(key),)) do rows
        row = iterate(rows)
        row === nothing ? default : String(row[1].value)
    end
end

function set_config!(jdb::JucoDB, key::AbstractString, value::Union{Nothing, AbstractString})
    if value === nothing
        SQLite.execute(jdb.db, "DELETE FROM juco_config WHERE key = ?", (String(key),))
    else
        SQLite.execute(jdb.db,
            "INSERT OR REPLACE INTO juco_config (key, value) VALUES (?, ?)",
            (String(key), String(value)))
    end
    return nothing
end

# ─── Memories ───

function remember!(jdb::JucoDB, content::AbstractString)
    SQLite.execute(jdb.db,
        "INSERT INTO juco_memories (created_at, content) VALUES (?, ?)",
        (time(), String(content)))
    return nothing
end

function memories(jdb::JucoDB; limit::Int = 50)
    return SQLite.DBInterface.execute(jdb.db,
            "SELECT content FROM juco_memories ORDER BY id DESC LIMIT ?", (limit,)) do rows
        out = String[String(r.content) for r in rows]
        reverse!(out)  # oldest first for prompt injection
    end
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
    return SQLite.DBInterface.execute(jdb.db,
            "SELECT id, title, cwd, updated_at FROM juco_sessions ORDER BY updated_at DESC LIMIT ?", (limit,)) do rows
        [(id = String(r.id),
          title = r.title === missing ? "" : String(r.title),
          cwd = r.cwd === missing ? "" : String(r.cwd),
          updated_at = Float64(r.updated_at)) for r in rows]
    end
end

function latest_session(jdb::JucoDB)
    sessions = list_sessions(jdb; limit = 1)
    return isempty(sessions) ? nothing : sessions[1].id
end
