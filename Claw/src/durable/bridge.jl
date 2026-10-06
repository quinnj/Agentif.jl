function _handler_snapshot(handler)
    return Dict(
        "id" => handler.id, "prompt" => handler.prompt, "channel_id" => handler.channel_id,
        "trust" => String(_handler_trust(handler)), "tools" => _handler_tool_names(handler),
        "filter" => handler.filter === nothing ? nothing : JSON.parse(JSON.json(handler.filter)),
        "relevance" => hasproperty(handler, :relevance) && handler.relevance !== nothing ?
            JSON.parse(JSON.json(_relevance_spec(handler.relevance))) : nothing
    )
end
function _restore_handler(value)
    f = value["filter"]
    filter = f === nothing ? nothing : _decode_filter(f["kind"], get(f, "expr", nothing), get(f, "pattern", nothing))
    return (;
        id = value["id"], prompt = value["prompt"], channel_id = value["channel_id"], trust = Symbol(value["trust"]),
        tools = value["tools"] === nothing ? nothing : String.(value["tools"]), filter,
        relevance = _decode_relevance(get(value, "relevance", nothing)),
    )
end

function _guard_source_claims!(db, members, abort = nothing)
    abort === nothing || Agentif.check_abort(abort)
    for (row, ev) in members
        current = _fetch_one(db, "SELECT status,claim_token,claim_revision,owner_epoch FROM claw_events WHERE id=?", (row.id,))
        current !== nothing && current.status == "running" && current.claim_token == row.claim_token &&
            current.claim_revision == row.claim_revision && current.owner_epoch == row.owner_epoch || throw(StaleInvocation())
    end
    return
end

function _bridge_profile(h, handler, ch)
    a = h.assistant
    model = Agentif.getModel(a.config.provider, a.config.model_id)
    model === nothing && throw(DurableBlocked("configured model unavailable"))
    tools = resolve_handler_tools(a, handler)
    agent = Agentif.Agent(; model, apikey = a.config.apikey, prompt = build_system_prompt(a; channel = ch), tools)
    return register_profile!(h, agent; trust = _handler_trust(handler))
end

function _route(ch, row)
    flags = (Agentif.is_private(ch) ? 1 : 0) | (Agentif.is_group(ch) ? 2 : 0)
    user = Agentif.get_current_user(ch)
    return Dict{String, Any}(
        "channel_id" => Agentif.channel_id(ch), "channel_flags" => flags,
        "search_channel_id" => Agentif.search_channel_id(ch), "user_id" => user === nothing ? nothing : user.id,
        "post_id" => Agentif.entry_id(ch), "source" => row.source, "event_id" => row.id
    )
end

"""Admit a frozen source batch. Optional `verdicts[(handler_id,event_id)]` is the
seam for a source relevance policy. Decisions and exact handler revisions persist
before submissions; coalescing changes cannot reinterpret an existing batch.
"""
function _durable_dispatch_group!(a, group, handlers; verdicts = nothing, abort = Agentif.Abort())
    Agentif.check_abort(abort)
    h = a._harness[]
    h === nothing && error("durable runtime is not attached")
    # Divide newly claimed rows by their existing frozen batches. Newly arriving
    # rows create a separate batch instead of widening an interrupted one.
    partitions = Dict{String, Vector{Any}}()
    new = Any[]
    for member in group
        row = member[1]
        frozen = _on_writer(db -> _fetch_one(db, "SELECT g.* FROM claw_dispatch_groups g JOIN claw_frozen_members m ON m.group_key=g.group_key WHERE m.event_id=?", (row.id,)), h)
        if frozen === nothing
            push!(new, member)
        else
            push!(get!(partitions, String(frozen.group_key), Any[]), member)
        end
    end
    if !isempty(new)
        key = join((x[1].id for x in new), ",")
        frozen = _transition!(h; point = :dispatch_freeze) do db, seq
            _guard_source_claims!(db, new, abort)
            snapshots = [_handler_snapshot(x) for x in handlers]
            for snapshot in snapshots
                snapshot["context_prefix"] = build_context_prefix(a.config)
            end
            payload = JSON.json(snapshots)
            _exec!(db, "INSERT OR IGNORE INTO claw_dispatch_groups VALUES(?,?)", (key, payload))
            for (ordinal, (row, ev)) in enumerate(new)
                _exec!(db, "INSERT OR IGNORE INTO claw_frozen_members VALUES(?,?,?)", (key, row.id, ordinal))
            end
            _fetch_one(db, "SELECT * FROM claw_dispatch_groups WHERE group_key=?", (key,))
        end
        partitions[key] = new
    end
    for (key, members) in partitions
        freeze = _on_writer(db -> _fetch_one(db, "SELECT * FROM claw_dispatch_groups WHERE group_key=?", (key,)), h)
        frozen_ids = _on_writer(db -> _fetch_all(db, "SELECT event_id FROM claw_frozen_members WHERE group_key=? ORDER BY ordinal", (key,)), h)
        present = Set(x[1].id for x in members)
        for id in (r.event_id for r in frozen_ids if !(r.event_id in present))
            row = _claim_event!(a, Int(id))
            if row === nothing
                # A member that already ended (dead-lettered, redacted or done) is
                # left out; only one still being processed elsewhere blocks.
                status = _on_writer(db -> _fetch_one(db, "SELECT status FROM claw_events WHERE id=?", (id,)), h)
                status !== nothing && status.status in ("dead", "done", "failed") && continue
                throw(DurableBlocked("frozen batch member is unavailable: $id"))
            end
            ev = _live_event(a, Int(id))
            ev === nothing && (ev = rehydrate_event(row.source, row))
            if ev === nothing
                _release_claim!(a, row; delay = 60.0, last_error = "frozen batch source unavailable")
                throw(DurableBlocked("frozen batch source unavailable"))
            end
            push!(members, (row, ev))
            if !any(x -> x[1].id == row.id, group)
                push!(group, (row, ev))
                lock(a._inflight_lock) do
                    a._inflight[row.id] = abort
                end
            end
        end
        sort!(members; by = x -> findfirst(r -> r.event_id == x[1].id, frozen_ids))
        prepared = Any[]
        delivering = Set{Int}()
        for raw in JSON.parse(freeze.handlers)
            handler = _restore_handler(raw)
            hash = _digest(raw)
            kept = Any[];decisions = Dict{String, Bool}()
            for (row, ev) in members
                receipt = _on_writer(db -> _fetch_one(db, "SELECT verdict FROM claw_filter_receipts WHERE event_id=? AND handler_hash=?", (row.id, hash)), h)
                pass = receipt === nothing ? (verdicts === nothing ? _durable_filter!(h, handler, ev, row, hash; abort) : verdicts[(handler.id, row.id)]) : receipt.verdict == 1
                if receipt === nothing
                    _transition!(h; point = :filter_receipt) do db, seq
                        _guard_source_claims!(db, members, abort)
                        _exec!(db, "INSERT OR IGNORE INTO claw_filter_receipts VALUES(?,?,?)", (row.id, hash, Int(pass)))
                    end
                end
                decisions[string(row.id)] = pass
                pass && push!(kept, (row, ev))
            end
            if verdicts === nothing && !isempty(kept)
                persist_selection = write -> _transition!(h; point = :relevance_receipt) do db, seq
                    # Fence the source claim as well as the runtime owner. A
                    # lease can be reclaimed within the same runtime epoch.
                    _guard_source_claims!(db, members, abort)
                    write(db)
                end
                kept = _select_relevant_events!(a, handler, kept, abort; persist! = persist_selection)
                selected = Set(row.id for (row, ev) in kept)
                for (row, ev) in members
                    decisions[string(row.id)] = row.id in selected
                end
            end
            if isempty(kept)
                push!(prepared, (; handler, hash, decisions, submission = nothing))
                continue
            end
            ev = length(kept) == 1 ? kept[1][2] : _make_event_batch(kept[1][1].name, Event[x[2] for x in kept])
            ch = _resolve_event_channel(a, ev, handler.channel_id)
            ch === nothing && handler.channel_id !== nothing && throw(DurableBlocked("recorded handler delivery channel unavailable"))
            ch === nothing && (ch = SinkChannel("handler:$(handler.id)"))
            profile = _bridge_profile(h, handler, ch)
            route = _route(ch, kept[1][1])
            supervision = _supervision_spec(h, handler, ev)
            supervision === nothing || (route["supervision"] = supervision)
            # A channel that cannot deliver (e.g. a GitHub event with no comment
            # target) keeps the answer local instead of queueing a send that can
            # never succeed.
            deliverable = !(ch isa SinkChannel) && delivery_available(ch)
            delivery = deliverable ? DeliveryAddress("claw-event-channel", 1, Dict("event_id" => kept[1][1].id, "channel_id" => Agentif.channel_id(ch))) : nothing
            deliverable && push!(delivering, kept[1][1].id)
            c = _channel_conversation!(h, ch, profile, route, delivery)
            input = Agentif.UserMessage(raw["context_prefix"] * "\n\n" * make_prompt(handler.prompt, ev))
            push!(prepared, (; handler, hash, decisions, submission = (c, profile, input, route)))
        end
        Agentif.check_abort(abort)
        _transition!(h; point = :dispatch) do db, seq
            _guard_source_claims!(db, members, abort)
            for p in prepared
                id = _new_id();sid = nothing
                if p.submission !== nothing
                    ref, profile, input, origin = p.submission
                    c = _fetch_one(db, "SELECT * FROM claw_conversations WHERE id=?", (ref.id,))
                    sid = _admit!(db, seq, c, input, "dispatch:$key:$(p.handler.id):$(p.hash)", :followup, origin, profile.id)
                end
                _exec!(
                    db, "INSERT OR IGNORE INTO claw_event_dispatches VALUES(?,?,?,?,?,?,?)",
                    (id, key, p.handler.id, JSON.json(_handler_snapshot(p.handler)), JSON.json(p.decisions), sid, sid === nothing ? "skipped" : nothing)
                )
                saved = _fetch_one(db, "SELECT id FROM claw_event_dispatches WHERE group_key=? AND handler_id=?", (key, p.handler.id))
                for (ordinal, (row, ev)) in enumerate(members)
                    _exec!(db, "INSERT OR IGNORE INTO claw_dispatch_members VALUES(?,?,?)", (saved.id, row.id, ordinal))
                end
            end
            for (row, ev) in members
                _exec!(
                    db, "UPDATE claw_events SET status='dispatched',claim_token=NULL,claim_revision=claim_revision+1,lease_expires_at=NULL WHERE id=? AND claim_token=? AND claim_revision=? AND owner_epoch=?",
                    (row.id, row.claim_token, row.claim_revision, row.owner_epoch)
                )
                Int(_scalar(db, "SELECT changes()")) == 1 || throw(StaleInvocation())
            end
            _aggregate_dispatches!(db, h)
        end
        # Events whose answer is not delivered through their own live channel are
        # done with it: release the channel and the live event now, as the
        # default path does. Delivery targets are released after their send.
        for (row, ev) in members
            row.id in delivering && continue
            if ev isa ChannelEvent
                try
                    Agentif.close_channel(get_channel(ev))
                catch err
                    @debug "Claw: failed to release a durable member's channel" exception = (err,)
                end
            end
            _forget_live_event!(a, row.id)
        end
    end
    resume!(h)
    return nothing
end

function _aggregate_dispatches!(db, h)
    for d in _fetch_all(db, "SELECT * FROM claw_event_dispatches WHERE result IS NULL")
        s = _fetch_one(db, "SELECT state,reason FROM claw_submissions WHERE id=?", (d.submission_id,))
        s === nothing && continue
        s.state in ("answered", "unanswered", "withdrawn") || continue
        _exec!(db, "UPDATE claw_event_dispatches SET result=? WHERE id=?", (s.state, d.id))
    end
    for e in _fetch_all(db, "SELECT id FROM claw_events WHERE status='dispatched'")
        ds = _fetch_all(db, "SELECT d.result FROM claw_dispatch_members m JOIN claw_event_dispatches d ON d.id=m.dispatch_id WHERE m.event_id=?", (e.id,))
        any(d -> _or_nothing(d.result) === nothing, ds) && continue
        failed = any(d -> d.result in ("unanswered", "withdrawn"), ds)
        _exec!(
            db, "UPDATE claw_events SET status=?,last_error=? WHERE id=? AND status='dispatched'",
            (failed ? "dead" : "done", failed ? "durable_handler_unanswered" : nothing, e.id)
        )
    end
    return
end

function _register_native_delivery!(h, a)
    register_delivery_adapter!(
        h, "claw-event-channel", DeliveryAdapter(
            (address, body, key) -> begin
                id = Int(address["event_id"])
                row = _event_row_for_delivery(a, id)
                ev = _live_event(a, id)
                ev === nothing && (ev = rehydrate_event(row.source, row))
                ev === nothing && error("delivery source/credentials unavailable")
                ch = _resolve_event_channel(a, ev, address["channel_id"])
                ch === nothing && error("delivery channel unavailable")
                result = Agentif.send_message(ch, body)
                post = Agentif.response_entry_id(ch)
                Agentif.close_channel(ch)
                # Keep the live event while another answer for it is still queued.
                others = _on_writer(
                    db -> _scalar(
                        db, """SELECT COUNT(*) FROM claw_outbox WHERE state='pending'
                        AND json_extract(address,'\$.routing.event_id')=?""", (id,)
                    ), h
                )
                others == 0 && _forget_live_event!(a, id)
                Dict("sent" => true, "remote" => _sanitize_integration_value(result), "_claw_response_post" => post)
            end; available = address -> begin
                row = _event_row_for_delivery(a, Int(address["event_id"]))
                ev = _live_event(a, Int(address["event_id"]))
                ev === nothing && (ev = rehydrate_event(row.source, row))
                ev === nothing && return false
                ch = _resolve_event_channel(a, ev, address["channel_id"])
                ch !== nothing && delivery_available(ch)
            end
        )
    )
    return register_delivery_adapter!(
        h, "claw-child-event", DeliveryAdapter(
            (address, body, key) ->
            submit_event!(a, SubagentOutputEvent(address["event_type"], address["name"], body); dedup_key = key); capability = :idempotent
        )
    )
end

function _event_row_for_delivery(a, id)
    return with_read(a._readers) do db
        r = _fetch_one(db, "SELECT * FROM claw_events WHERE id=?", (id,))
        cid, content, extra = _decode_payload(r.payload)
        EventRow(Int(r.id), r.source, r.name, _or_nothing(r.dedup_key), cid, content, extra, r.lane, Int(r.attempts), a)
    end
end

_live_event(a, id) = lock(() -> get(a._live_events, id, nothing), a._live_lock)

function _register_default_profile!(h, a)
    model = Agentif.getModel(a.config.provider, a.config.model_id)
    model === nothing && return nothing
    agent = Agentif.Agent(; model, apikey = a.config.apikey, prompt = build_system_prompt(a), tools = _tool_snapshot(a))
    if a.watcher !== nothing
        try
            register_profile!(h, _watcher_agent(a.watcher, WATCHER_SYSTEM_PROMPT); trust = :untrusted)
        catch err
            @warn "durable watcher profile unavailable; bounded default note will be used" error = _diagnostic(h, err)
        end
    end
    return register_profile!(h, agent)
end
function _durable_evaluate(a, input; channel = nothing, tools = nothing, request_id = _new_id(), input_key = nothing, kwargs...)
    h = a._harness[]
    ch = channel === nothing ? SinkChannel("internal") : channel
    handler = (; id = "direct", prompt = "", channel_id = Agentif.channel_id(ch), trust = :owner, tools = tools === nothing ? nothing : [t.name for t in tools], filter = nothing)
    profile = _bridge_profile(h, handler, ch)
    route = Dict(
        "channel_id" => Agentif.channel_id(ch), "search_channel_id" => Agentif.search_channel_id(ch),
        "channel_flags" => (Agentif.is_private(ch) ? 1 : 0), "post_id" => Agentif.entry_id(ch)
    )
    _channel_set!(a, Agentif.channel_id(ch), ch)
    if !(ch isa SinkChannel)
        register_delivery_adapter!(
            h, "claw-direct-channel", DeliveryAdapter(
                (address, body, key) -> begin
                    target = _channel_get(a, address["channel_id"])
                    target === nothing && error("direct delivery channel unavailable")
                    Agentif.send_message(target, body)
                    post = Agentif.response_entry_id(target)
                    Agentif.close_channel(target)
                    Dict("sent" => true, "_claw_response_post" => post)
                end
            )
        )
    end
    delivery = ch isa SinkChannel ? nothing : DeliveryAddress("claw-direct-channel", 1, Dict("channel_id" => Agentif.channel_id(ch)))
    c = _channel_conversation!(h, ch, profile, route, delivery)
    key = something(input_key, request_id)
    route["input_digest"] = _digest(input)
    old = lookup_submission(h, c.id, key)
    if old !== nothing
        saved = submission(old)
        get(JSON.parse(saved.origin), "input_digest", nothing) == route["input_digest"] || throw(SubmissionConflict(key))
        r = old
    else
        message = input isa String ? build_context_prefix(a.config) * "\n\n" * input : input
        r = submit!(h, c, message; request_id = key, origin = route)
    end
    outcome = wait_submission(r)
    state = Agentif.load_branch(h.history, String(Agentif.branch_id(ch)))
    state.most_recent_stop_reason = outcome.state == "answered" ? :stop : :error
    return state
end

function _channel_conversation!(h, ch, profile, route, delivery)
    branch = String(Agentif.branch_id(ch))
    parent = Agentif.parent_branch_id(ch)
    existing = _on_writer(db -> _fetch_one(db, "SELECT id FROM claw_conversations WHERE branch_id=?", (branch,)), h)
    if existing === nothing && parent !== nothing
        source = _on_writer(db -> _fetch_one(db, "SELECT * FROM claw_conversations WHERE branch_id=?", (String(parent),)), h)
        if source !== nothing
            oldroute = JSON.parse(source.routing)
            private = get(oldroute, "channel_flags", 1) & 1 == 1
            private && !Agentif.is_private(ch) && throw(ArgumentError("private parent history cannot seed a public thread"))
            platform = Agentif.branch_entry_id(ch)
            cutoff = platform === nothing ? nothing : _on_writer(
                    db -> _fetch_one(
                        db, "SELECT entry_id FROM claw_platform_entries WHERE channel_id=? AND platform_id=?",
                        (get(oldroute, "channel_id", String(parent)), string(platform))
                    ), h
                )
            fork_conversation!(h, source.id; branch_id = branch, entry_id = cutoff === nothing ? nothing : String(cutoff.entry_id))
        end
    end
    return ensure_conversation!(h; branch_id = branch, profile, routing = route, delivery)
end

delivery_available(::Agentif.AbstractChannel) = true
