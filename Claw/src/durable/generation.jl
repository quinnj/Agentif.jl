function _ordered_context(messages)
    result = Agentif.StoredAgentMessage[]
    i = 1
    while i <= length(messages)
        message = messages[i]
        push!(result, message)
        i += 1
        if message isa Agentif.AssistantMessage
            calls = Agentif.pending_tool_calls_from_message(message)
            isempty(calls) && continue
            results = Dict{String, Agentif.ToolResultMessage}()
            while i <= length(messages) && messages[i] isa Agentif.ToolResultMessage
                results[messages[i].call_id] = messages[i]
                i += 1
            end
            for call in calls
                haskey(results, call.call_id) && push!(result, results[call.call_id])
            end
        end
    end
    return result
end

function _complete_tool_context(messages)
    pending = Set{String}()
    for message in messages
        if message isa Agentif.AssistantMessage
            calls = Agentif.pending_tool_calls_from_message(message)
            isempty(calls) || isempty(pending) || return false
            union!(pending, (call.call_id for call in calls))
        elseif message isa Agentif.ToolResultMessage
            delete!(pending, message.call_id)
        end
    end
    return isempty(pending)
end

function _prepared_budget(messages, agent)
    schemas = [Dict("name" => tool.name, "description" => tool.description, "parameters" => Agentif.OpenAICompletions.schema(Agentif.parameters(tool))) for tool in agent.tools]
    # Includes opaque signatures, images, tool arguments and schema descriptions.
    # This is a conservative byte estimate, not a provider tokenizer guarantee.
    return cld(sizeof(JSON.json(messages)) + sizeof(agent.prompt) + sizeof(JSON.json(schemas)), 4)
end

function _generation_settle!(db, h, seq, t, c; answer = nothing, reason = nothing, stop = nothing, audit = nothing)
    entry = _entry!(db, h, seq, c, answer === nothing ? [] : [answer]; run = t.run_id, task = t.id, audit, stop)
    state = answer === nothing ? "unanswered" : "answered"
    _exec!(
        db, "UPDATE claw_submissions SET state=?,answer_entry=?,reason=? WHERE run_id=? AND state='placed'",
        (state, answer === nothing ? nothing : entry, reason, t.run_id)
    )
    _exec!(
        db, "UPDATE claw_runs SET status=?,answer_entry=?,reason=?,revision=revision+1 WHERE id=?",
        (answer === nothing ? "failed" : "completed", answer === nothing ? nothing : entry, reason, t.run_id)
    )
    _finish_task!(db, t, Dict("status" => answer === nothing ? "failed" : "completed", "entry" => entry, "reason" => reason))
    if answer !== nothing
        route = JSON.parse(_fetch_one(db, "SELECT routing FROM claw_runs WHERE id=?", (t.run_id,)).routing)
        for s in _fetch_all(db, "SELECT origin FROM claw_submissions WHERE run_id=? AND state='answered'", (t.run_id,))
            post = get(JSON.parse(s.origin), "post_id", nothing)
            channel = get(route, "channel_id", nothing)
            if post !== nothing && channel !== nothing
                _exec!(
                    db, "INSERT INTO claw_platform_entries VALUES(?,?,?) ON CONFLICT(channel_id,platform_id) DO UPDATE SET entry_id=excluded.entry_id",
                    (channel, string(post), entry)
                )
            end
        end
    end
    issued = _fetch_one(db, "SELECT delivery FROM claw_runs WHERE id=?", (t.run_id,))
    delivery = issued === nothing ? nothing : _or_nothing(issued.delivery)
    return if answer !== nothing && delivery !== nothing
        address = JSON.parse(delivery)
        key = "$entry:" * _digest(address)
        oid = _new_id()
        _exec!(
            db, "INSERT INTO claw_outbox(id,conversation_id,run_id,entry_id,logical_key,address,body,state) VALUES(?,?,?,?,?,?,?,'pending')",
            (oid, c.id, t.run_id, entry, key, JSON.json(address), Agentif.message_text(answer))
        )
        _task_create!(
            db, seq, c.id, "delivery", "delivery:$key"; background = true,
            input = Dict("outbox" => oid, "profile" => JSON.parse(t.input_json)["profile"]), checkpoint = Dict("phase" => "send")
        )
    end
end

function _generation_prepare!(ctx, t, resolved)
    h = ctx.harness
    c = _on_writer(db -> _fetch_one(db, "SELECT * FROM claw_conversations WHERE id=?", (t.conversation_id,)), h)
    cp = JSON.parse(t.checkpoint)
    _transition!(h; context = ctx, point = :boundary) do db, seq
        _place_boundary!(db, h, seq, c, t.run_id)
    end
    c = _on_writer(db -> _fetch_one(db, "SELECT * FROM claw_conversations WHERE id=?", (t.conversation_id,)), h)
    leaf = Agentif.get_branch_leaf(h.history, c.branch_id)
    messages = _context_at(h, leaf)
    _complete_tool_context(messages) || return _block_invocation!(ctx, "incomplete historical tool context; fork/reset at a reviewed completed cutoff")
    threshold = Agentif.compaction_threshold(h.compaction, resolved.agent.model)
    compacted = get(cp, "compacted", false)
    # The byte estimate can be low when the provider still overflows: after a
    # reported overflow, compact before the one retry instead of resending.
    needs_room = threshold > 0 && _prepared_budget(messages, resolved.agent) >= threshold ||
        get(cp, "overflow", 0) > 0 && !compacted
    if needs_room
        h.compaction.enabled && !compacted && return _schedule_compaction!(ctx, t, c, messages, cp)
        return _transition!(h; context = ctx, point = :context_budget) do db, seq
            _generation_settle!(db, h, seq, t, c; reason = "context_overflow")
        end
    end
    return _transition!(h; context = ctx, point = :request_prepare) do db, seq
        current = _fetch_one(db, "SELECT context_revision FROM claw_conversations WHERE id=?", (c.id,))
        current.context_revision == c.context_revision || throw(StaleInvocation())
        # History entries are immutable (redaction only masks them), so the
        # request is rebuilt from this leaf rather than copied into the task.
        next = Dict(
            "phase" => "request", "leaf" => leaf, "context_revision" => c.context_revision,
            "overflow" => get(cp, "overflow", 0), "compacted" => compacted, "failures" => get(cp, "failures", 0)
        )
        _exec!(db, "UPDATE claw_tasks SET checkpoint=?,status='pending',token=NULL,progress=NULL WHERE id=?", (JSON.json(next), t.id))
    end
end

# The model context of a history leaf, with tool results in call order.
function _context_at(h, leaf)
    leaf === nothing && return Agentif.StoredAgentMessage[]
    state = Agentif.AgentState()
    foreach(e -> Agentif.apply_session_entry!(state, e), Agentif._collect_lineage(h.history, leaf))
    return _ordered_context(state.messages)
end

function _model_progress!(ctx, event, last_write)
    h = ctx.harness
    ctx.heartbeat[] = _monotonic_s()
    _monotonic_s() - last_write[] >= h.limits.progress_interval || event isa Agentif.MessageEndEvent || return
    event isa Union{Agentif.MessageUpdateEvent, Agentif.MessageEndEvent} || return
    message = hasproperty(event, :message) ? getproperty(event, :message) : nothing
    message isa Agentif.AssistantMessage || return
    text = Agentif.message_text(message)
    _transition!(h; context = ctx, point = :partial) do db, seq
        _exec!(db, "UPDATE claw_tasks SET progress=? WHERE id=?", (_bounded_json(Dict("text" => text), h.limits.progress_bytes), ctx.task_id))
    end
    return last_write[] = _monotonic_s()
end

function _model_request!(ctx, t, resolved; summary = false, purpose = false)
    h = ctx.harness
    cp = JSON.parse(t.checkpoint)
    # `attempts` bounds consecutive failed requests (a crash counts as one), not
    # the number of turns; the run deadline bounds the whole run.
    failures = get(cp, "failures", 0)
    expired = _monotonic_s() > ctx.monotonic_deadline
    if failures >= h.limits.attempts || expired
        return _transition!(h; context = ctx, point = :attempt_exhausted) do db, seq
            c = _fetch_one(db, "SELECT * FROM claw_conversations WHERE id=?", (t.conversation_id,))
            reason = expired ? "deadline" : "attempt_budget"
            t.kind == "watcher" ? _watcher_settle!(db, h, seq, t, nothing) :
                (summary || purpose) ? _finish_task!(db, t, Dict("status" => "failed", "reason" => reason)) :
                _generation_settle!(db, h, seq, t, c; reason)
        end
    end
    if summary || purpose
        budget_agent = Agentif.Agent(; model = resolved.agent.model, apikey = resolved.agent.apikey, prompt = cp["prompt"], tools = Agentif.AgentTool[])
        if _prepared_budget(cp["messages"], budget_agent) >= resolved.agent.model.contextWindow > 0
            return _transition!(h; context = ctx, point = :purpose_budget) do db, seq
                t.kind == "watcher" ? _watcher_settle!(db, h, seq, t, nothing) :
                    _finish_task!(db, t, Dict("status" => "failed", "reason" => "context_overflow"))
            end
        end
    end
    attempt = Int(t.attempt) + 1
    _transition!(h; context = ctx, point = :request_intent) do db, seq
        _exec!(db, "UPDATE claw_tasks SET attempt=? WHERE id=?", (attempt, t.id))
        _exec!(db, "INSERT INTO claw_task_attempts VALUES(?,?,?,?,?,NULL,0,NULL)", (t.id, attempt, ctx.token, "$(t.id):$attempt", seq))
    end
    messages = haskey(cp, "messages") ? JSON.parse(JSON.json(cp["messages"]), Vector{Agentif.StoredAgentMessage}) : _context_at(h, cp["leaf"])
    prepared = Agentif.AgentState(; messages)
    for message in prepared.messages
        message isa Agentif.AssistantMessage && message.response_id !== nothing && (prepared.response_id = message.response_id)
    end
    agent = (summary || purpose) ? Agentif.Agent(;
            model = resolved.agent.model, apikey = resolved.agent.apikey,
            prompt = cp["prompt"], tools = Agentif.AgentTool[]
        ) : resolved.agent
    last_write = Ref(-Inf)
    outcome = Agentif.model_turn(e -> _model_progress!(ctx, e, last_write), agent, prepared, ctx.abort; stream_fn = h.stream_fn)
    h.fault(:after_model_response, h)
    # Suspending aborts in-flight requests; they are repeated after reopening,
    # never settled as aborted runs.
    outcome.stop_reason === :aborted && h.state !== :open && throw(StaleInvocation())
    return _transition!(h; context = ctx, point = summary ? :summary_result : outcome.stop_reason === :stop && isempty(outcome.pending_calls) ? :answer : :model_result) do db, seq
        current = _fetch_one(db, "SELECT * FROM claw_tasks WHERE id=?", (t.id,))
        _exec!(
            db, "UPDATE claw_task_attempts SET ended_seq=?,failure=? WHERE task_id=? AND attempt=?",
            (seq, outcome.error === nothing ? nothing : _diagnostic(h, outcome.error), t.id, attempt)
        )
        _exec!(db, "INSERT OR IGNORE INTO claw_usage VALUES(?,?,?,?,?)", (t.id, attempt, summary ? "compaction" : t.kind == "watcher" ? "watcher" : purpose ? "filter" : "model", JSON.json(outcome.usage), seq))
        c = _fetch_one(db, "SELECT * FROM claw_conversations WHERE id=?", (t.conversation_id,))
        audit = outcome.message === nothing ? Dict("stop" => String(outcome.stop_reason)) : JSON.parse(JSON.json(outcome.message))
        if outcome.error !== nothing
            class = Agentif.is_context_overflow_error(outcome.error) ? :context_overflow : classify_eval_failure(outcome.error)
            if class in (:network, :rate_limit, :overloaded) && failures + 1 < h.limits.attempts
                _entry!(db, h, seq, c, []; run = t.run_id, task = t.id, audit, stop = "error")
                delay = h.limits.retry_delays[min(failures + 1, length(h.limits.retry_delays))]
                if outcome.error isa HTTP.StatusError
                    delay = max(delay, Agentif.codex_retry_delay_seconds(failures + 1, 0, Int(1000 * h.limits.max_retry_delay); response = outcome.error.response))
                end
                due = h.clock() + min(h.limits.max_retry_delay, delay)
                cp["failures"] = failures + 1
                _exec!(db, "UPDATE claw_tasks SET status='pending',token=NULL,due_at=?,progress=NULL,checkpoint=? WHERE id=?", (due, JSON.json(cp), t.id))
                return
            elseif !summary && !purpose && class == :context_overflow && get(cp, "overflow", 0) < 1 &&
                    (outcome.message === nothing || (isempty(outcome.message.content) && isempty(outcome.pending_calls)))
                cp["phase"] = "prepare";cp["overflow"] = 1;cp["compacted"] = false
                _entry!(db, h, seq, c, []; run = t.run_id, task = t.id, audit, stop = "context_overflow")
                _exec!(db, "UPDATE claw_tasks SET status='pending',token=NULL,checkpoint=? WHERE id=?", (JSON.json(cp), t.id))
                return
            end
            purpose && return _purpose_settle!(db, h, seq, current, outcome)
            return summary ? _compaction_settle!(db, h, seq, current, cp, outcome) :
                _generation_settle!(db, h, seq, current, c; reason = String(class), stop = "error", audit)
        end
        summary && return _compaction_settle!(db, h, seq, current, cp, outcome)
        purpose && return _purpose_settle!(db, h, seq, current, outcome)
        if outcome.stop_reason in (:length, :error, :refusal, :aborted, :content_filter, :invalid_response)
            return _generation_settle!(db, h, seq, current, c; reason = outcome.stop_reason == :length ? "token_limit" : String(outcome.stop_reason), stop = String(outcome.stop_reason), audit)
        end
        calls = Agentif.eligible_tool_calls(outcome)
        if !isempty(calls)
            entry = _entry!(db, h, seq, c, [outcome.message]; run = t.run_id, task = t.id, stop = String(outcome.stop_reason))
            children = _tool_intents!(db, h, seq, current, c, entry, calls, resolved)
            _exec!(db, "UPDATE claw_tasks SET checkpoint=? WHERE id=?", (JSON.json(Dict("phase" => "post_tools", "children" => children, "overflow" => get(cp, "overflow", 0))), t.id))
            _wait_tasks!(db, t.id, children)
        elseif outcome.stop_reason == :stop && outcome.message !== nothing && !isempty(strip(Agentif.message_text(outcome.message)))
            steer = _fetch_one(db, "SELECT id FROM claw_submissions WHERE conversation_id=? AND mode='steer' AND state='queued' LIMIT 1", (c.id,))
            if steer !== nothing
                # The next prepare places exactly one steer (and queued writes).
                _entry!(db, h, seq, c, [outcome.message]; run = t.run_id, task = t.id, stop = "stop")
                _exec!(db, "UPDATE claw_tasks SET status='pending',token=NULL,checkpoint=? WHERE id=?", (JSON.json(Dict("phase" => "prepare", "overflow" => 0)), t.id))
            else
                _generation_settle!(db, h, seq, current, c; answer = outcome.message, stop = "stop")
                _place_boundary!(db, h, seq, c, t.run_id)
            end
        else
            _generation_settle!(db, h, seq, current, c; reason = "invalid_response", stop = String(outcome.stop_reason), audit)
        end
    end
end

function _generation_phase!(ctx, t, resolved)
    cp = JSON.parse(t.checkpoint)
    phase = get(cp, "phase", "")
    phase == "prepare" && return _generation_prepare!(ctx, t, resolved)
    phase == "request" && return _model_request!(ctx, t, resolved)
    if phase in ("post_tools", "post_compaction")
        return _transition!(ctx.harness; context = ctx, point = :post_children) do db, seq
            if phase == "post_compaction"
                child = _fetch_one(db, "SELECT outcome FROM claw_tasks WHERE id=?", (cp["child"],))
                result = JSON.parse(child.outcome)
                if get(result, "status", "") != "completed"
                    c = _fetch_one(db, "SELECT * FROM claw_conversations WHERE id=?", (t.conversation_id,))
                    return _generation_settle!(db, ctx.harness, seq, t, c; reason = "compaction_failed")
                end
            end
            next = Dict("phase" => "prepare", "overflow" => get(cp, "overflow", 0), "compacted" => phase == "post_compaction")
            _exec!(db, "UPDATE claw_tasks SET status='pending',token=NULL,checkpoint=? WHERE id=?", (JSON.json(next), t.id))
        end
    end
    error("invalid generation checkpoint phase")
end
