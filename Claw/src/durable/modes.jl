function _guard_legacy_runtime!(a)
    a._durable_parked[] && return
    work=execute_write(a._writer) do db
        _done(db,"SELECT id FROM claw_tasks WHERE status!='terminal' UNION ALL SELECT id FROM claw_submissions WHERE state IN ('queued','placed') UNION ALL SELECT id FROM claw_events WHERE status='dispatched' OR (durable=1 AND status IN ('pending','running')) LIMIT 1")
    end
    work===nothing || error("unfinished durable work is present; enable durable=true, settle it, or explicitly park it with park_durable=true on this capable binary")
end
