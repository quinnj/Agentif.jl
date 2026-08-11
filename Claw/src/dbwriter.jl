# dbwriter.jl — SQLite ownership discipline (hardening §1.7)
#
# The historical design shared one `SQLite.DB` handle across the event loop, tool
# threads (Agentif runs every tool via `Threads.@spawn`), the Tempus scheduler and
# every source thread. That is safe from corruption (serialized mode) but makes
# multi-statement sequences interleave, and savepoint transactions fail outright
# ("SQL statements in progress") whenever another cursor is live.
#
# This file introduces a single writer task owning a dedicated write connection,
# fed by a request channel, plus a small pool of read connections (safe under WAL).
# Agentif's session store can submit its complete entry-and-index transaction to
# this writer. Tempus keeps its own compatibility store on the main handle. Claw's
# durable pipeline and session persistence therefore have one write owner.

# ─── Pipeline configuration ───

"""
    PipelineConfig

Tunables for the durable event pipeline. Defaults match the hardening design;
tests override the timing knobs so failure-injection runs in milliseconds.
"""
Base.@kwdef struct PipelineConfig
    "Global cap on concurrently running handler evaluations."
    max_concurrent_evals::Int = 4
    "Backoff ladder (seconds) for retryable failures."
    retry_backoff_s::Vector{Float64} = [30.0, 60.0, 300.0, 900.0]
    "Total attempts allowed for retryable classes (`:rate_limit`, `:overloaded`, `:network`)."
    max_attempts::Int = 5
    "Total attempts allowed for `:unknown` (initial attempt + 2 retries)."
    unknown_max_attempts::Int = 3
    "Minimum gap before an event can fire again; prevents spin."
    min_refire_gap_s::Float64 = 2.0
    "How long a claim is valid before another worker may steal it."
    lease_duration_s::Float64 = 900.0
    "How often the recovery scanner looks for due/expired rows."
    scan_interval_s::Float64 = 1.0
    "Log lane wait time + depth once an item waited longer than this."
    lane_backlog_warn_s::Float64 = 2.0
    "Max events one lane drain coalesces into a single evaluation (1 disables)."
    max_coalesce::Int = 8
    "Retire an idle lane (and its worker task) after this long with no work."
    lane_idle_timeout_s::Float64 = 300.0
    "Emit at most one PTY output event per this interval."
    pty_notify_interval_s::Float64 = 5.0
    "Per-event byte cap for coalesced PTY output."
    pty_max_event_bytes::Int = 16_000
    "Max source restarts inside `source_restart_window_s`."
    source_restart_cap::Int = 3
    "Sliding window for the source restart budget."
    source_restart_window_s::Float64 = 3600.0
    "Base restart backoff; doubles per consecutive failure, capped at 60s."
    source_restart_backoff_s::Float64 = 1.0
    "How often `is_healthy` is polled per source."
    source_health_interval_s::Float64 = 300.0
    "How long runtime disable waits for a source to finish cooperative cleanup."
    source_stop_timeout_s::Float64 = 5.0
    "Default `shutdown!` drain budget."
    shutdown_timeout_s::Float64 = 30.0
    "Send a best-effort apology on the originating channel when an event dies."
    dead_letter_notify::Bool = true
end

# ─── Runtime structures referenced by AgentAssistant ───

"""
    Lane

Per-conversation serialization queue (§1.4). One worker task per lane, so two
messages in the same channel can no longer race the same session.
"""
mutable struct Lane
    key::String
    queue::Base.Channel{Tuple{Int, Float64}}   # (event rowid, enqueued_at)
    task::Union{Nothing, Task}
    depth::Threads.Atomic{Int}
    busy::Threads.Atomic{Bool}
    last_active::Threads.Atomic{Float64}
end

Lane(key::String) = Lane(key, Base.Channel{Tuple{Int, Float64}}(Inf), nothing,
    Threads.Atomic{Int}(0), Threads.Atomic{Bool}(false), Threads.Atomic{Float64}(time()))

"""
    SupervisedSource

Bookkeeping for one supervised `EventSource` (§1.6): the supervisor task, the task
`start!` returned (if any), and the sliding restart window.
"""
mutable struct SupervisedSource
    source::EventSource
    tag::String
    task::Union{Nothing, Task}          # supervisor task
    inner::Union{Nothing, Task}         # task returned by start!, if any
    restarts::Vector{Float64}
    stopped::Threads.Atomic{Bool}
    healthy::Threads.Atomic{Bool}
    restart_requested::Threads.Atomic{Bool}
    lock::ReentrantLock
end

SupervisedSource(es::EventSource, tag::String) = SupervisedSource(
    es, tag, nothing, nothing, Float64[],
    Threads.Atomic{Bool}(false), Threads.Atomic{Bool}(true), Threads.Atomic{Bool}(false),
    ReentrantLock(),
)

"""
    IntegrationState

Runtime bookkeeping for one enabled integration: the live source, its supervisor
(when the pipeline is running), and exactly what `register_event_source!` added on
its behalf — so `disable_integration!` can remove precisely that and nothing else.
"""
mutable struct IntegrationState
    name::String
    source::EventSource
    supervised::Union{Nothing, SupervisedSource}
    channel_ids::Vector{String}
    event_type_names::Vector{String}
    tool_names::Vector{String}
end

# ─── Single writer task ───

struct WriteRequest
    f::Function                    # (db::SQLite.DB) -> Any
    reply::Base.Channel{Any}
end

mutable struct SQLiteWriter
    db::SQLite.DB
    owns_db::Bool                  # false when sharing the caller's handle (:memory:)
    requests::Base.Channel{WriteRequest}
    task::Union{Nothing, Task}
end

# In-memory databases are per-connection: a second `SQLite.DB(":memory:")` is a
# *different* database, so the writer has to share the caller's handle there. It
# still serializes every write through one task, which is the point.
_is_private_memory_path(path::AbstractString) = isempty(path) || path == ":memory:"

# `journal_mode` is a property of the database *file*, and switching it needs a
# brief exclusive lock — which a secondary connection cannot get while the primary
# one has live cursors ("database is locked"). The primary connection already put
# the file in WAL, so secondaries only set their per-connection pragmas, with
# busy_timeout first so the rest wait rather than fail.
function _apply_connection_pragmas!(db::SQLite.DB; set_journal_mode::Bool = false)
    # `SQLite.execute` steps and resets the statement. `DBInterface.execute` returns
    # a lazy cursor, and an unconsumed `PRAGMA journal_mode=WAL` cursor holds the
    # exclusive lock it took — which is why a second connection to the same file
    # used to fail with "database is locked" forever.
    SQLite.execute(db, "PRAGMA busy_timeout=5000")
    set_journal_mode && SQLite.execute(db, "PRAGMA journal_mode=WAL")
    SQLite.execute(db, "PRAGMA synchronous=NORMAL")
    SQLite.execute(db, "PRAGMA foreign_keys=ON")
    return db
end

function SQLiteWriter(db_path::String, shared::SQLite.DB)
    owns = !_is_private_memory_path(db_path)
    wdb = shared
    if owns
        try
            wdb = _apply_connection_pragmas!(SQLite.DB(db_path))
        catch e
            @warn "Claw: failed to open dedicated write connection; sharing the main handle" db_path exception = (e, catch_backtrace())
            wdb = shared
            owns = false
        end
    end
    writer = SQLiteWriter(wdb, owns, Base.Channel{WriteRequest}(Inf), nothing)
    writer.task = errormonitor(Threads.@spawn _writer_loop(writer))
    return writer
end

function _writer_loop(w::SQLiteWriter)
    for req in w.requests
        result = try
            # The writer task can outlive methods defined by extensions, Revise,
            # or a caller at the REPL. Run each submitted closure in the current
            # world so a long-lived writer does not reject newer write code.
            (:ok, Base.invokelatest(req.f, w.db))
        catch e
            (:error, e)
        end
        try
            put!(req.reply, result)
        catch
            # Requester vanished; nothing to report to.
        end
    end
    return nothing
end

"""
    execute_write(f, writer) -> Any
    execute_write(writer, sql, params = ()) -> Nothing

Run a write on the writer task's dedicated connection and wait for it. The
function form receives the connection, so multi-statement sequences (including
`BEGIN`/`COMMIT`) execute with no other cursor live on that connection.
"""
function execute_write(f::Function, w::SQLiteWriter)
    isopen(w.requests) || error("Claw: SQLite writer is closed")
    reply = Base.Channel{Any}(1)
    put!(w.requests, WriteRequest(f, reply))
    status, value = take!(reply)
    status === :error && throw(value)
    return value
end

function execute_write(w::SQLiteWriter, sql::AbstractString, params = ())
    return execute_write(w) do db
        _with_busy_retry() do
            _exec!(db, sql, params)
            return nothing
        end
    end
end

function close_writer!(w::SQLiteWriter)
    isopen(w.requests) && close(w.requests)
    t = w.task
    t === nothing || timedwait(() -> istaskdone(t), 5.0)
    if w.owns_db
        try
            close(w.db)
        catch
        end
    end
    return nothing
end

# ─── Reader connections ───

mutable struct ReaderPool
    path::String
    shared::SQLite.DB
    owns::Bool
    pool::Vector{SQLite.DB}
    lock::ReentrantLock
    max_size::Int
end

function ReaderPool(db_path::String, shared::SQLite.DB; max_size::Int = 4)
    owns = !_is_private_memory_path(db_path)
    return ReaderPool(db_path, shared, owns, SQLite.DB[], ReentrantLock(), max_size)
end

function _acquire_reader(p::ReaderPool)
    p.owns || return p.shared
    conn = lock(p.lock) do
        isempty(p.pool) ? nothing : pop!(p.pool)
    end
    conn !== nothing && return conn
    try
        db = SQLite.DB(p.path)
        SQLite.execute(db, "PRAGMA busy_timeout=5000")
        return db
    catch e
        @warn "Claw: failed to open read connection; falling back to the shared handle" exception = (e,)
        return p.shared
    end
end

function _release_reader(p::ReaderPool, db::SQLite.DB)
    (p.owns && db !== p.shared) || return nothing
    keep = lock(p.lock) do
        if length(p.pool) < p.max_size
            push!(p.pool, db)
            return true
        end
        return false
    end
    keep || try
        close(db)
    catch
    end
    return nothing
end

"""
    with_read(f, pool) -> Any

Run `f(db)` on a reader connection. Readers never block writers under WAL.
"""
function with_read(f::Function, p::ReaderPool)
    db = _acquire_reader(p)
    try
        return f(db)
    finally
        _release_reader(p, db)
    end
end

function close_readers!(p::ReaderPool)
    lock(p.lock) do
        for db in p.pool
            try
                close(db)
            catch
            end
        end
        empty!(p.pool)
    end
    return nothing
end

# ─── Schema migrations (PRAGMA user_version) ───
#
# Version 1 == the implicit schema that shipped before this file existed. Any
# database opened by an older Claw is at user_version 0 and is stamped to 1 after
# the baseline tables are (idempotently) created, so the ladder below is the only
# thing that ever has to change a live database.

const CLAW_SCHEMA_VERSION = 5

function _is_sensitive_integration_key(key)
    normalized = replace(lowercase(String(key)), r"[^a-z0-9]" => "")
    normalized in ("key", "auth", "authorization", "cookie", "credentials") && return true
    occursin("apikey", normalized) && return true
    occursin("privatekey", normalized) && return true
    occursin("accesskey", normalized) && return true
    return any(suffix -> endswith(normalized, suffix),
        ("token", "secret", "password", "passphrase", "credential"))
end

function _sanitize_integration_value(value)
    if value isa AbstractDict
        return Dict{String, Any}(String(k) => _sanitize_integration_value(v) for (k, v) in value
            if !_is_sensitive_integration_key(k))
    elseif value isa AbstractVector
        return Any[_sanitize_integration_value(v) for v in value]
    end
    return value
end

_sanitize_integration_config(config::AbstractDict) = _sanitize_integration_value(config)

function _get_user_version(db::SQLite.DB)
    version = 0
    for row in SQLite.DBInterface.execute(db, "PRAGMA user_version")
        version = Int(row[1])
    end
    return version
end

function _set_user_version!(db::SQLite.DB, v::Int)
    SQLite.execute(db, "PRAGMA user_version = $(v)")
    return nothing
end

function _migration_2!(db::SQLite.DB)
    _exec!(db, """
        CREATE TABLE IF NOT EXISTS claw_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            dedup_key TEXT UNIQUE,
            source TEXT NOT NULL,
            name TEXT NOT NULL,
            payload TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('pending','running','done','failed','dead')),
            attempts INTEGER NOT NULL DEFAULT 0,
            lane TEXT NOT NULL,
            created_at REAL NOT NULL,
            next_attempt_at REAL NOT NULL DEFAULT 0,
            lease_expires_at REAL,
            last_error TEXT
        )
    """)
    _exec!(db, "CREATE INDEX IF NOT EXISTS idx_claw_events_claim ON claw_events(status, next_attempt_at)")
    _exec!(db, "CREATE INDEX IF NOT EXISTS idx_claw_events_lane ON claw_events(lane, status)")
    _exec!(db, """
        CREATE TABLE IF NOT EXISTS claw_source_journal (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL,
            source TEXT NOT NULL,
            action TEXT NOT NULL,
            detail TEXT
        )
    """)
    _exec!(db, "CREATE INDEX IF NOT EXISTS idx_claw_source_journal_source ON claw_source_journal(source, ts)")
    return nothing
end

"""
    _column_exists(db, table, column) -> Bool

Iterates `PRAGMA table_info` to exhaustion on purpose: an early `return true` would
leave the cursor mid-step, and an unconsumed cursor holds its statement open — the
exact failure mode §1.7 documents.
"""
function _column_exists(db::SQLite.DB, table::AbstractString, column::AbstractString)
    found = false
    for row in SQLite.DBInterface.execute(db, "PRAGMA table_info($(table))")
        String(row.name) == column && (found = true)
    end
    return found
end

# §2.2: per-handler trust tier and tool subset. `DEFAULT 'owner'` is what backfills
# existing rows, which is the schema-level half of the no-regression guarantee — a
# database written by the previous version comes back with every handler still at
# full trust.
function _migration_3!(db::SQLite.DB)
    _column_exists(db, "claw_event_handlers", "trust") ||
        _exec!(db, "ALTER TABLE claw_event_handlers ADD COLUMN trust TEXT NOT NULL DEFAULT 'owner'")
    _column_exists(db, "claw_event_handlers", "tools") ||
        _exec!(db, "ALTER TABLE claw_event_handlers ADD COLUMN tools TEXT")
    return nothing
end

# Subscription filters (per-handler event matchers) and the persisted integration
# enabled-set. The filter columns are NULL for existing rows, which decodes to "no
# filter" — the exact pre-migration behavior.
function _migration_4!(db::SQLite.DB)
    _column_exists(db, "claw_event_handlers", "filter_kind") ||
        _exec!(db, "ALTER TABLE claw_event_handlers ADD COLUMN filter_kind TEXT")
    _column_exists(db, "claw_event_handlers", "filter_expr") ||
        _exec!(db, "ALTER TABLE claw_event_handlers ADD COLUMN filter_expr TEXT")
    _column_exists(db, "claw_event_handlers", "filter_pattern") ||
        _exec!(db, "ALTER TABLE claw_event_handlers ADD COLUMN filter_pattern TEXT")
    _exec!(db, """
        CREATE TABLE IF NOT EXISTS claw_integrations (
            name TEXT PRIMARY KEY,
            enabled INTEGER NOT NULL DEFAULT 0,
            config TEXT,
            status TEXT,
            updated_at REAL NOT NULL DEFAULT 0
        )
    """)
    return nothing
end

# Version 4 persisted constructor config verbatim. Remove credential-like keys
# from existing rows and discard old error text, which may quote those values.
function _migration_5!(db::SQLite.DB)
    rows = Tuple{String, Union{Nothing, String}}[]
    for row in SQLite.DBInterface.execute(db, "SELECT name, config FROM claw_integrations")
        config = (row.config === missing || row.config === nothing) ? nothing : String(row.config)
        push!(rows, (String(row.name), config))
    end
    for (name, raw) in rows
        sanitized = if raw === nothing || isempty(strip(raw))
            nothing
        else
            parsed = try
                JSON.parse(raw)
            catch
                nothing
            end
            parsed isa AbstractDict ? JSON.json(_sanitize_integration_config(parsed)) : nothing
        end
        _exec!(db, "UPDATE claw_integrations SET config = ?, status = NULL WHERE name = ?",
            (sanitized, name))
    end
    return nothing
end

const CLAW_MIGRATIONS = Dict{Int, Function}(
    2 => _migration_2!, 3 => _migration_3!, 4 => _migration_4!, 5 => _migration_5!)

"""
    _migrate_claw_schema!(db)

Apply the `PRAGMA user_version` ladder. Idempotent; safe on a fresh database and
on one written by an older Claw.
"""
function _migrate_claw_schema!(db::SQLite.DB)
    current = _get_user_version(db)
    if current == 0
        current = 1
        _set_user_version!(db, current)
    end
    while current < CLAW_SCHEMA_VERSION
        next = current + 1
        migration = get(CLAW_MIGRATIONS, next, nothing)
        migration === nothing && error("Claw: missing schema migration for version $next")
        migration(db)
        _set_user_version!(db, next)
        current = next
        @debug "Claw: applied schema migration" version = next
    end
    return current
end
