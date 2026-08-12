function drain_channel!(channel::Channel{AgentTurnInput})
    inputs = AgentTurnInput[]
    while isready(channel)
        push!(inputs, take!(channel))
    end
    return inputs
end

function steer_middleware(agent_handler::AgentHandler, steer_queue::Union{Nothing, Channel{AgentTurnInput}})
    return function (f::F, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort; kw...) where {F <: Function}
        steer_queue === nothing && return agent_handler(f, agent, state, current_input, abort; kw...)
        isready(steer_queue) || return agent_handler(f, agent, state, current_input, abort; kw...)
        steer_inputs = drain_channel!(steer_queue)
        isempty(steer_inputs) && return agent_handler(f, agent, state, current_input, abort; kw...)
        append_turn_input!(state, current_input)
        if length(steer_inputs) > 1
            for input in steer_inputs[1:(end - 1)]
                append_turn_input!(state, input)
            end
        end
        return agent_handler(f, agent, state, steer_inputs[end], abort; kw...)
    end
end

function tool_call_middleware(agent_handler::AgentHandler)
    return function (f::F, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort; kw...) where {F <: Function}
        next_input = current_input
        current_state = state
        futures = Future{ToolResultMessage}[]
        tool_results = ToolResultMessage[]
        while true
            check_abort(abort)
            turn_id = UID8()
            @debug "Agent turn started" turn_id model = agent.model.id pending_calls = length(current_state.pending_tool_calls)
            f(TurnStartEvent(turn_id))
            try
                current_state = agent_handler(f, agent, current_state, next_input, abort; kw...)

                if isempty(current_state.pending_tool_calls)
                    # Warn on empty responses (no text, no tool calls) which may indicate API issues
                    am = last_assistant_message(current_state)
                    if am !== nothing && isempty(message_text(am)) && isempty(am.tool_calls)
                        @warn "Model returned empty response (no text, no tool calls)" stop_reason=current_state.most_recent_stop_reason
                    end
                    return current_state
                end

                empty!(futures) # empty futures before we push new tool call evals
                @debug "Agent requested tool calls" turn_id tool_call_count = length(current_state.pending_tool_calls) tool_names = [tc.name for tc in current_state.pending_tool_calls]
                for tc in current_state.pending_tool_calls
                    check_abort(abort)
                    tool = findtool(agent.tools, tc.name)
                    push!(futures, call_function_tool!(f, tool, tc))
                end
                empty!(current_state.pending_tool_calls) # pending have been moved to futures, empty
                empty!(tool_results) # empty tool_results before we wait on futures
                for fut in futures
                    check_abort(abort)
                    push!(tool_results, wait(fut))
                end
                check_abort(abort)
                @debug "Tool calls completed" turn_id tool_result_count = length(tool_results) error_count = count(trm -> trm.is_error, tool_results)
                next_input = tool_results
            finally
                f(TurnEndEvent(turn_id, last_assistant_message(current_state), nothing))
            end
        end
    end
end

function queue_middleware(agent_handler::AgentHandler, message_queue::Union{Nothing, Channel{AgentTurnInput}})
    return function (f::F, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort; kw...) where {F <: Function}
        current_state = agent_handler(f, agent, state, current_input, abort; kw...)
        check_abort(abort)
        message_queue === nothing && return current_state
        while isready(message_queue)
            next_input = take!(message_queue)
            current_state = agent_handler(f, agent, current_state, next_input, abort; kw...)
            check_abort(abort)
        end
        return current_state
    end
end

function evaluate_middleware(agent_handler::AgentHandler)
    return function (f::F, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort; kw...) where {F <: Function}
        evaluate_id = UID8()
        @debug "Agent evaluate started" evaluate_id model = agent.model.id tool_count = length(agent.tools) input_type = string(typeof(current_input))
        f(AgentEvaluateStartEvent(evaluate_id))
        result_state = nothing
        try
            result_state = @with CURRENT_EVALUATION_ID => evaluate_id begin
                agent_handler(f, agent, state, current_input, abort; kw...)
            end
            return result_state
        catch e
            if e isa AbortEvaluation
                return result_state === nothing ? state : result_state
            end
            if e isa CapturedException && e.ex isa AbortEvaluation
                return result_state === nothing ? state : result_state
            end
            if e isa InterruptException || (e isa CapturedException && e.ex isa InterruptException)
                rethrow()
            end
            @debug "Agent evaluate failed" evaluate_id model = agent.model.id exception = (e, catch_backtrace())
            rethrow()
        finally
            if result_state !== nothing
                @debug "Agent evaluate completed" evaluate_id stop_reason = result_state.most_recent_stop_reason message_count = length(result_state.messages)
            else
                @debug "Agent evaluate completed without state" evaluate_id
            end
            f(AgentEvaluateEndEvent(evaluate_id, result_state))
        end
    end
end

function _entry_metadata(ch::Union{Nothing, AbstractChannel})
    ch === nothing && return nothing, nothing, nothing, nothing
    user = get_current_user(ch)
    user_id = user === nothing ? nothing : user.id
    ch_id = channel_id(ch)
    sch_id = search_channel_id(ch)
    flags = Int((is_private(ch) ? 0x01 : 0x00) | (is_group(ch) ? 0x02 : 0x00))
    return user_id, ch_id, sch_id, flags
end

function current_session_entry_metadata()
    return _entry_metadata(CURRENT_CHANNEL[])
end

function _create_search_session_tool(store::SessionStore)
    return @tool(
        """Search past session history for relevant context from previous conversations.

Use this tool to recall past decisions, find previous instructions, or look up what was discussed in earlier sessions. Only searches PAST sessions — not the current conversation.

Arguments:
- `query::String` (required): Natural-language search query. Uses hybrid semantic search (BM25 + vector similarity), so phrase your query descriptively rather than as exact keywords.
- `limit::Union{Nothing, Int}` (default: 10): Maximum number of results to return.

Returns matching snippets with entry IDs and relevance scores. Each result is truncated to 4000 characters.

Results are scoped by channel — conversations from private channels are never leaked to other channels.

Examples:
- `search_session_history("what deployment strategy did we decide on")` — find a past decision
- `search_session_history("error handling guidelines", 5)` — find up to 5 results about a topic""",
        search_session_history(query::String, limit::Union{Nothing, Int}=nothing) = begin
            n = limit === nothing ? 10 : limit
            ch = CURRENT_CHANNEL[]
            sch_id = ch !== nothing ? search_channel_id(ch) : nothing
            results = search_sessions(store, query; limit=n, current_search_channel_id=sch_id)
            isempty(results) && return "No matching session history found for: $query"
            lines = String[]
            max_chars = 4000
            for (i, r) in enumerate(results)
                push!(lines, "--- Result $i [entry: $(r.entry_id), score: $(round(r.score; digits=2))] ---")
                text = r.entry_text
                if length(text) > max_chars
                    text = first(text, max_chars) * "\n... [truncated, $(length(r.entry_text)) chars total]"
                end
                push!(lines, text)
            end
            return join(lines, "\n\n")
        end,
    )
end

function _maybe_fork_branch!(store::SessionStore, ch::AbstractChannel, bid::String)
    get_branch_leaf(store, bid) !== nothing && return  # already seeded
    fork_eid = branch_entry_id(ch)
    if fork_eid !== nothing && get_entry(store, fork_eid) !== nothing
        set_branch_leaf!(store, bid, fork_eid)
        return
    end
    pbid = parent_branch_id(ch)
    if pbid !== nothing
        parent_leaf = get_branch_leaf(store, pbid)
        parent_leaf !== nothing && set_branch_leaf!(store, bid, parent_leaf)
    end
    return
end

# Entry ids must be unique: a single incoming message can drive several
# evaluations (queue_middleware), and each needs its own entry. Keep the
# platform id when it is still free, otherwise suffix it — `post_id` carries the
# platform id either way, so scrubbing keeps working.
function _unique_entry_id(store::SessionStore, base_id::String)
    get_entry(store, base_id) === nothing && return base_id
    while true
        candidate = string(base_id, "#", UID8())
        get_entry(store, candidate) === nothing && return candidate
    end
end

function _reset_persisted_prefix!(state::AgentState)
    has_summary = !isempty(state.messages) && state.messages[1] isa CompactionSummaryMessage
    state.persisted_prefix_start = has_summary ? 2 : 1
    state.persisted_prefix_count = length(state.messages) - (has_summary ? 1 : 0)
    return state
end

function session_middleware(agent_handler::AgentHandler, store::Union{Nothing, SessionStore}; channel::Union{Nothing, AbstractChannel} = nothing)
    search_tool = store === nothing ? nothing : _create_search_session_tool(store)
    return function (f::F, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort; kw...) where {F <: Function}
        store === nothing && return agent_handler(f, agent, state, current_input, abort; kw...)
        current_channel = channel === nothing ? CURRENT_CHANNEL[] : channel
        current_channel === nothing && return agent_handler(f, agent, state, current_input, abort; kw...)

        bid = branch_id(current_channel)
        # Capture entry_id BEFORE eval (post_ts gets mutated during streaming)
        captured_eid = entry_id(current_channel)

        return lock_branch(store, bid) do
            _maybe_fork_branch!(store, current_channel, bid)
            current_state, entry_boundaries = load_branch_with_boundaries(store, bid)
            pre_eval_msg_count = length(current_state.messages)
            # Everything we just loaded is already persisted; compact! keeps this
            # provenance up to date if it runs mid-evaluation.
            _reset_persisted_prefix!(current_state)
            current_leaf = get_branch_leaf(store, bid)

            agent = search_tool === nothing ? agent : with_tools(agent, vcat(agent.tools, [search_tool]))
            current_state = agent_handler(f, agent, current_state, current_input, abort; kw...)

            # Resolve final entry ID
            response_eid = response_entry_id(current_channel)
            platform_post_id = captured_eid === nothing ? response_eid : captured_eid
            base_eid = platform_post_id === nothing ? string(UID8()) : platform_post_id
            final_eid = _unique_entry_id(store, base_eid)
            user_id, ch_id, sch_id, ch_flags = _entry_metadata(current_channel)

            if current_state.last_compaction !== nothing
                # Compaction happened, possibly mid-evaluation. `persisted_prefix_*`
                # says exactly which kept messages the store already holds; every
                # other message goes into this evaluation's entry, which hangs off
                # the compaction entry so the lineage walk replays
                # [summary, kept…, new…] in order.
                # messages[1] is the summary, so at most length-1 can be kept.
                kept_persisted = clamp(current_state.persisted_prefix_count, 0, max(0, length(current_state.messages) - 1))
                first_kept_eid = nothing
                if kept_persisted > 0
                    first_kept_idx = current_state.persisted_prefix_start
                    for b in entry_boundaries
                        if b.message_start <= first_kept_idx <= b.message_end
                            # Lineage pointers operate at entry granularity. If
                            # the cut lands inside an entry, persist the kept
                            # suffix again under the new compaction instead of
                            # replaying the entry's already-summarized prefix.
                            if first_kept_idx == b.message_start
                                first_kept_eid = b.entry_id
                            else
                                kept_persisted = 0
                            end
                            break
                        end
                    end
                    # No entry to point at: persist the kept messages here instead
                    # of leaving them unreachable.
                    first_kept_eid === nothing && (kept_persisted = 0)
                end

                compaction_entry = SessionEntry(;
                    id = _unique_entry_id(store, string(UID8())),
                    parent_id = current_leaf,
                    messages = AgentMessage[current_state.last_compaction],
                    is_compaction = true,
                    first_kept_entry_id = first_kept_eid,
                    user_id = user_id,
                    channel_id = ch_id,
                    search_channel_id = sch_id,
                    channel_flags = ch_flags,
                )
                append_entry!(store, compaction_entry)

                # Skip the summary (1) plus the kept messages the store already has.
                new_messages = current_state.messages[kept_persisted + 2:end]
                if !isempty(new_messages)
                    eval_entry = SessionEntry(;
                        id = final_eid,
                        parent_id = compaction_entry.id,
                        messages = new_messages,
                        user_id = user_id,
                        channel_id = ch_id,
                        search_channel_id = sch_id,
                        channel_flags = ch_flags,
                        post_id = platform_post_id,
                    )
                    append_entry!(store, eval_entry)
                    set_branch_leaf!(store, bid, eval_entry.id)
                else
                    set_branch_leaf!(store, bid, compaction_entry.id)
                end
                current_state.last_compaction = nothing
                _reset_persisted_prefix!(current_state)
            elseif length(current_state.messages) > pre_eval_msg_count
                # No compaction: save new messages as a single entry
                new_messages = current_state.messages[pre_eval_msg_count + 1:end]
                eval_entry = SessionEntry(;
                    id = final_eid,
                    parent_id = current_leaf,
                    messages = new_messages,
                    user_id = user_id,
                    channel_id = ch_id,
                    search_channel_id = sch_id,
                    channel_flags = ch_flags,
                    post_id = platform_post_id,
                )
                append_entry!(store, eval_entry)
                set_branch_leaf!(store, bid, eval_entry.id)
                _reset_persisted_prefix!(current_state)
            end

            return current_state
        end
    end
end

function guardrail_input_text(input::AgentTurnInput)
    if input isa String
        return input
    elseif input isa UserMessage
        return message_text(input)
    elseif input isa Vector{UserContentBlock}
        return content_text(input)
    end
    return nothing
end

function input_guardrail_middleware(agent_handler::AgentHandler, guardrail::Union{Nothing, Bool, Function})
    return function (f::F, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort; input_guardrail_model::Union{Nothing, Model} = nothing, input_guardrail_apikey::Union{Nothing, String} = nothing, kw...) where {F <: Function}
        (guardrail === nothing || guardrail === false) && return agent_handler(f, agent, state, current_input, abort; kw...)
        text = guardrail_input_text(current_input)
        text === nothing && return agent_handler(f, agent, state, current_input, abort; kw...)
        apikey_override = input_guardrail_apikey === nothing ? agent.apikey : input_guardrail_apikey

        guardrail_future = Future{Bool}() do
            # should we try-catch this block and @warn + return false?
            if guardrail isa Function
                return guardrail(agent.prompt, text, apikey_override)::Bool
            else
                guardrail_agent = materialize_guardrail_agent(agent, DEFAULT_INPUT_GUARDRAIL_AGENT; model=input_guardrail_model, apikey=input_guardrail_apikey)
                result_state = stream(identity, guardrail_agent, AgentState(), build_guardrail_input(agent.prompt, text), abort)
                return try
                    msg = last_assistant_message(result_state)
                    msg === nothing && error("input guardrail produced no assistant message")
                    JSON.parse(message_text(msg), ValidUserInput).valid_user_input
                catch e
                    @warn "Input guardrail evaluation failed; rejecting input" exception = (e, catch_backtrace())
                    false
                end
            end
        end
        result_state = agent_handler(function (event)
            wait(guardrail_future) || throw(InvalidInputError(text))
            f(event)
        end, agent, state, current_input, abort; kw...)
        wait(guardrail_future) || throw(InvalidInputError(text))
        return result_state
    end
end

function skills_middleware(agent_handler::AgentHandler, registry::Union{Nothing, SkillRegistry}; include_location::Bool = true)
    return function (f::F, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort; kw...) where {F <: Function}
        registry === nothing && return agent_handler(f, agent, state, current_input, abort; kw...)
        isempty(registry.skills) && return agent_handler(f, agent, state, current_input, abort; kw...)
        prompt = append_available_skills(agent.prompt, values(registry.skills); include_location)
        return agent_handler(f, with_prompt(agent, prompt), state, current_input, abort; kw...)
    end
end

function build_default_handler(
        ;
        base_handler::AgentHandler = stream,
        compaction_config::Union{Nothing, CompactionConfig} = nothing,
        steer_queue::Union{Nothing, Channel{AgentTurnInput}} = nothing,
        message_queue::Union{Nothing, Channel{AgentTurnInput}} = nothing,
        session_store::Union{Nothing, SessionStore} = nothing,
        input_guardrail::Union{Nothing, Bool, Function} = nothing,
        skill_registry::Union{Nothing, SkillRegistry} = nothing,
        channel::Union{Nothing, AbstractChannel} = nothing,
    )
    compaction_handler = compaction_config === nothing ?
        base_handler : compaction_middleware(base_handler, compaction_config)
    steer_handler = steer_middleware(compaction_handler, steer_queue)
    channel_handler = channel_middleware(steer_handler, channel)
    tool_handler = tool_call_middleware(channel_handler)
    # Inject channel-specific tools (e.g. emoji reactions) outside the tool_call
    # loop so that findtool can resolve them when the model calls them.
    channel_tools_handler = if channel === nothing
        tool_handler
    else
        ch_tools = create_channel_tools(channel)
        if isempty(ch_tools)
            tool_handler
        else
            function (f::F, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort; kw...) where {F <: Function}
                return tool_handler(f, with_tools(agent, vcat(agent.tools, ch_tools)), state, current_input, abort; kw...)
            end
        end
    end
    session_handler = session_store === nothing ?
        channel_tools_handler :
        session_middleware(channel_tools_handler, session_store; channel)
    guardrail_handler = input_guardrail_middleware(session_handler, input_guardrail)
    skills_handler = skills_middleware(guardrail_handler, skill_registry)
    evaluate_handler = evaluate_middleware(skills_handler)
    return queue_middleware(evaluate_handler, message_queue)
end

evaluate(
    agent::Agent,
    input::AgentTurnInput;
    abort::Abort = Abort(),
    level::Union{Nothing, LogLevel, Int, Symbol, AbstractString} = nothing,
    kw...,
) = evaluate(identity, agent, input; abort, level, kw...)

function evaluate(
        f::F,
        agent::Agent,
        input::AgentTurnInput;
        state::AgentState = AgentState(),
        base_handler::AgentHandler = stream,
        compaction_config::Union{Nothing, CompactionConfig} = CompactionConfig(),
        steer_queue::Union{Nothing, Channel{AgentTurnInput}} = nothing,
        message_queue::Union{Nothing, Channel{AgentTurnInput}} = nothing,
        session_store::Union{Nothing, SessionStore} = nothing,
        input_guardrail::Union{Nothing, Bool, Function} = nothing,
        skill_registry::Union{Nothing, SkillRegistry} = nothing,
        channel::Union{Nothing, AbstractChannel} = nothing,
        abort::Abort = Abort(),
        level::Union{Nothing, LogLevel, Int, Symbol, AbstractString} = nothing,
        kw...,
    ) where {F <: Function}
    handler = build_default_handler(; base_handler, compaction_config, steer_queue, message_queue, session_store, input_guardrail, skill_registry, channel)
    return with_log_level(level) do
        handler(f, agent, state, input, abort; kw...)
    end
end
