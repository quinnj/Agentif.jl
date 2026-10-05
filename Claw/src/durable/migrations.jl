function _check_future_writer!(db)
    _get_user_version(db)<=CLAW_SCHEMA_VERSION || error("Claw: future database schema; use a capable writer")
    if _done(db,"SELECT name FROM sqlite_master WHERE name='claw_runtime_meta'")!==nothing
        meta=_done(db,"SELECT min_writer FROM claw_runtime_meta WHERE id=1")
        meta===nothing || meta.min_writer<=CLAW_SCHEMA_VERSION || error("Claw: future minimum writer")
    end
end

function _validate_shared_database!(db)
    for (table,required) in (
            ("session_entries",("entry_id","parent_id","entry","created_at")),
            ("session_branches",("branch_id","leaf_entry_id")),
            ("content",("hash","body")), ("documents",("id","key","hash")),
            ("document_tags",("document_id","tag")), ("chunks",("hash","seq","pos")),
            ("tempus_state",("store_key","store_value","token")),
            ("claw_agent_data",("key","value")),("claw_evals",("id","status","started_at")))
        _done(db,"SELECT name FROM sqlite_master WHERE type='table' AND name=?",(table,))===nothing && continue
        columns=Set(String(r.name) for r in _drows(db,"PRAGMA table_info($table)"))
        all(in(columns),required) || error("Claw: incompatible shared $table schema; missing required columns")
    end
    check=_drows(db,"PRAGMA quick_check")
    all(r->first(r)=="ok",check) || error("Claw: database integrity check failed")
    isempty(_drows(db,"PRAGMA foreign_key_check")) || error("Claw: shared database foreign-key violations")
    nothing
end

function _backup_database!(db,path::String)
    ispath(path) && throw(ArgumentError("backup destination already exists"))
    SQLite.backup(db,path)
    backup=SQLite.DB(path)
    try
        _validate_shared_database!(backup)
    finally
        close(backup)
    end
    path
end

"""Create a consistent SQLite backup, including WAL state, at a new destination.
This runs on the writer line. A backup is a snapshot, not a live standby runtime.
"""
backup_harness!(h::Harness,path::String)=_dread(db->_backup_database!(db,path),h)

function _prepare_database!(db;backup_path=nothing)
    _check_future_writer!(db)
    _validate_shared_database!(db)
    backup_path===nothing || _backup_database!(db,String(backup_path))
    _init_claw_schema!(db)
end
