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

                isempty(current_state.pending_tool_calls) && return current_state

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

function session_middleware(agent_handler::AgentHandler, store::Union{Nothing, SessionStore}; session_id::Union{Nothing, String} = nothing)
    sid_ref = Ref{Union{Nothing, String}}(session_id)
    return function (f, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort; session_id::Union{Nothing, String} = nothing, kw...)
        store === nothing && return agent_handler(f, agent, state, current_input, abort; kw...)
        sid = session_id === nothing ? sid_ref[] : ensure_session_id(session_id)
        sid === nothing && (sid = new_session_id())
        sid_ref[] = sid
        current_state = load_session(store, sid)
        current_state.session_id = sid
        start_idx = length(current_state.messages)
        current_state = agent_handler(f, agent, current_state, current_input, abort; kw...)
        eval_id = CURRENT_EVALUATION_ID[]
        entry_id = eval_id === nothing ? nothing : string(eval_id)
        if current_state.last_compaction !== nothing
            # Compaction happened: write full state as compaction entry
            entry = SessionEntry(;
                id = entry_id,
                created_at = time(),
                messages = copy(current_state.messages),
                is_compaction = true,
            )
            append_session_entry!(store, sid, entry)
            current_state.last_compaction = nothing
        elseif length(current_state.messages) > start_idx
            new_messages = current_state.messages[(start_idx + 1):end]
            entry = SessionEntry(; id = entry_id, created_at = time(), messages = new_messages)
            append_session_entry!(store, sid, entry)
        end
        return current_state
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
        session_id::Union{Nothing, String} = nothing,
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
    handler = session_middleware(handler, session_store; session_id)
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
        compaction_config::Union{Nothing, CompactionConfig} = nothing,
        steer_queue::Union{Nothing, Channel{AgentTurnInput}} = nothing,
        message_queue::Union{Nothing, Channel{AgentTurnInput}} = nothing,
        session_store::Union{Nothing, SessionStore} = nothing,
        session_id::Union{Nothing, String} = nothing,
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
    handler = build_default_handler(; base_handler, compaction_config, steer_queue, message_queue, session_store, session_id, input_guardrail, skill_registry, channel)
    return handler(f, agent, state, input, abort; kw...)
end
