function _schedule_compaction!(ctx, t, c, messages, cp)
    h = ctx.harness
    cut = Agentif.find_cut_point(messages, h.compaction.keep_recent_tokens)
    return _transition!(h; context = ctx, point = :compaction_prepare) do db, seq
        if cut <= 1
            return _generation_settle!(db, h, seq, t, c; reason = "context_overflow")
        end
        discarded = messages[1:(cut - 1)]
        prompt = Agentif.COMPACTION_SUMMARY_PROMPT
        if discarded[1] isa Agentif.CompactionSummaryMessage
            prompt = replace(Agentif.COMPACTION_UPDATE_PROMPT, "%s" => discarded[1].summary)
            discarded = discarded[2:end]
        end
        text = "Summarize this conversation:\n\n" * Agentif.format_messages_for_summary(discarded)
        # Capture kept messages explicitly; the summary entry replaces context
        # without changing the underlying immutable historical lineage.
        child = _task_create!(
            db, seq, c.id, "compaction", "compact:$(c.context_revision)"; run = t.run_id, owner = t.id,
            input = JSON.parse(t.input_json), checkpoint = Dict(
                "phase" => "request", "prompt" => prompt,
                "messages" => JSON.parse(JSON.json([Agentif.UserMessage(text)])), "kept" => JSON.parse(JSON.json(messages[cut:end])),
                "context_revision" => c.context_revision, "tokens" => sum(Agentif.estimate_message_tokens, discarded; init = 0)
            )
        )
        _exec!(db, "UPDATE claw_tasks SET checkpoint=? WHERE id=?", (JSON.json(Dict("phase" => "post_compaction", "child" => child, "overflow" => get(cp, "overflow", 0))), t.id))
        _wait_tasks!(db, t.id, [child])
    end
end

function _compaction_settle!(db, h, seq, t, cp, outcome)
    c = _fetch_one(db, "SELECT * FROM claw_conversations WHERE id=?", (t.conversation_id,))
    if !Agentif.valid_summary(outcome) || c.context_revision != cp["context_revision"]
        _entry!(db, h, seq, c, []; task = t.id, run = t.run_id, audit = outcome.message, stop = "invalid_summary")
        return _finish_task!(db, t, Dict("status" => "failed", "reason" => c.context_revision != cp["context_revision"] ? "stale_context" : "invalid_summary"))
    end
    kept = JSON.parse(JSON.json(cp["kept"]), Vector{Agentif.StoredAgentMessage})
    summary = Agentif.CompactionSummaryMessage(; summary = Agentif.message_text(outcome.message), tokens_before = Int(cp["tokens"]), compacted_at = h.clock())
    # An empty first-kept boundary makes the compaction entry authoritative for
    # model context. All retained complete messages are stored in that entry.
    entry = _entry!(db, h, seq, c, [summary;kept]; task = t.id, run = t.run_id, compaction = true, stop = "stop")
    return _finish_task!(db, t, Dict("status" => "completed", "entry" => entry))
end
