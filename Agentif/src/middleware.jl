function drain_channel!(channel::Channel{AgentTurnInput})
    inputs = AgentTurnInput[]
    while isready(channel)
        push!(inputs, take!(channel))
    end
    return inputs
end

function steer_middleware(agent_handler::AgentHandler, steer_queue::Union{Nothing, Channel{AgentTurnInput}})
    return function (f, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort; kw...)
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
    return function (f, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort; kw...)
        next_input = current_input
        current_state = state
        futures = Future{ToolResultMessage}[]
        tool_results = ToolResultMessage[]
        while true
            check_abort(abort)
            turn_id = UID8()
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
                next_input = tool_results
            finally
                f(TurnEndEvent(turn_id, last_assistant_message(current_state), nothing))
            end
        end
    end
end

function queue_middleware(agent_handler::AgentHandler, message_queue::Union{Nothing, Channel{AgentTurnInput}})
    return function (f, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort; kw...)
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
    return function (f, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort; kw...)
        evaluate_id = UID8()
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
            rethrow()
        finally
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
        "Search past session history (previous conversations) for relevant context. Returns matching snippets from past interactions.",
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

function session_middleware(agent_handler::AgentHandler, store::Union{Nothing, SessionStore}; channel::Union{Nothing, AbstractChannel} = nothing)
    search_tool = store === nothing ? nothing : _create_search_session_tool(store)
    return function (f, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort; kw...)
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
            current_leaf = get_branch_leaf(store, bid)

            agent = search_tool === nothing ? agent : with_tools(agent, vcat(agent.tools, [search_tool]))
            current_state = agent_handler(f, agent, current_state, current_input, abort; kw...)

            # Resolve final entry ID
            final_eid = something(captured_eid, response_entry_id(current_channel), string(UID8()))
            user_id, ch_id, sch_id, ch_flags = _entry_metadata(current_channel)

            if current_state.last_compaction !== nothing
                # Compaction happened: create compaction entry + eval entry
                kept_count = current_state.compaction_kept_count
                first_kept_eid = nothing
                if kept_count > 0 && pre_eval_msg_count > 0
                    first_kept_original_idx = pre_eval_msg_count - kept_count + 1
                    for b in entry_boundaries
                        if b.message_start <= first_kept_original_idx <= b.message_end
                            first_kept_eid = b.entry_id
                            break
                        end
                    end
                end

                compaction_entry = SessionEntry(;
                    id = string(UID8()),
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

                # New messages added after compaction: skip summary (1) + kept (N)
                new_messages = current_state.messages[kept_count + 2:end]
                if !isempty(new_messages)
                    eval_entry = SessionEntry(;
                        id = final_eid,
                        parent_id = compaction_entry.id,
                        messages = new_messages,
                        user_id = user_id,
                        channel_id = ch_id,
                        search_channel_id = sch_id,
                        channel_flags = ch_flags,
                    )
                    append_entry!(store, eval_entry)
                    set_branch_leaf!(store, bid, final_eid)
                else
                    set_branch_leaf!(store, bid, compaction_entry.id)
                end
                current_state.last_compaction = nothing
                current_state.compaction_kept_count = 0
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
                )
                append_entry!(store, eval_entry)
                set_branch_leaf!(store, bid, final_eid)
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
    return function (f, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort; input_guardrail_model::Union{Nothing, Model} = nothing, input_guardrail_apikey::Union{Nothing, String} = nothing, kw...)
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
                return try; JSON.parse(last_assistant_message(result_state).text, ValidUserInput).valid_user_input; catch; false; end
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
    return function (f, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort; kw...)
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
    handler = base_handler
    if compaction_config !== nothing
        handler = compaction_middleware(handler, compaction_config)
    end
    handler = steer_middleware(handler, steer_queue)
    handler = channel_middleware(handler, channel)
    handler = tool_call_middleware(handler)
    # Inject channel-specific tools (e.g. emoji reactions) outside the tool_call
    # loop so that findtool can resolve them when the model calls them.
    if channel !== nothing
        ch_tools = create_channel_tools(channel)
        if !isempty(ch_tools)
            inner_handler = handler
            handler = (f, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort; kw...) ->
                inner_handler(f, with_tools(agent, vcat(agent.tools, ch_tools)), state, current_input, abort; kw...)
        end
    end
    handler = session_middleware(handler, session_store; channel)
    handler = input_guardrail_middleware(handler, input_guardrail)
    handler = skills_middleware(handler, skill_registry)
    handler = evaluate_middleware(handler)
    handler = queue_middleware(handler, message_queue)
    return handler
end

evaluate(agent::Agent, input::AgentTurnInput; abort::Abort = Abort(), kw...) = evaluate(identity, agent, input; abort, kw...)

function evaluate(
        f::Function,
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
        repeat_input::Bool = false,
        kw...,
    )
    if repeat_input && input isa String
        input = input * "\n\n" * input
    end
    handler = build_default_handler(; base_handler, compaction_config, steer_queue, message_queue, session_store, input_guardrail, skill_registry, channel)
    return handler(f, agent, state, input, abort; kw...)
end
