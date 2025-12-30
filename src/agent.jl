@kwarg struct Agent{F}
    prompt::String
    model::Union{Nothing, Model} = nothing
    input_guardrail::F = nothing
    tools::Vector{AgentTool} = AgentTool[]
end

struct InvalidInputError <: Exception
    input::String
end

function evaluate!(agent::Agent, input::Union{String,Vector{PendingToolCall}}, apikey::String;
        model::Union{Nothing, Model} = nothing, state::AgentState = AgentState(),
        stream_output::Bool = isinteractive(), stream_reasoning::Bool = true, kw...)
    return evaluate!(agent, input, apikey; model, state, kw...) do event
        if event isa MessageUpdateEvent
            if event.kind == :text || (stream_reasoning && event.kind == :reasoning)
                if stream_output
                    print(event.delta)
                    flush(stdout)
                end
            end
        elseif event isa MessageEndEvent
            if stream_output
                println()
                flush(stdout)
            end
        end
    end
end

function validate_guardrail(agent::Agent, input::AgentTurnInput, apikey::String)
    if input isa String && agent.input_guardrail !== nothing
        return agent.input_guardrail(agent.prompt, input, apikey)
    end
    return true
end

function resolve_tool_results!(f::Function, agent::Agent, pending_tool_calls::Vector{PendingToolCall})
    tool_results = Future{ToolResultMessage}[]
    for tc in pending_tool_calls
        tool = findtool(agent.tools, tc.name)
        f(ToolExecutionStartEvent(tc))
        if tc.approved === false
            push!(tool_results, reject_function_tool!(f, tc))
        else
            push!(tool_results, call_function_tool!(f, tool, tc))
        end
    end
    return ToolResultMessage[wait(x) for x in tool_results]
end

function merge_pending_tool_calls!(state::AgentState, approvals::Vector{PendingToolCall})
    isempty(state.pending_tool_calls) && throw(ArgumentError("no pending tool calls in state"))
    by_id = Dict{String,PendingToolCall}()
    for ptc in state.pending_tool_calls
        by_id[ptc.call_id] = ptc
    end
    for approval in approvals
        stored = get(() -> nothing, by_id, approval.call_id)
        stored === nothing && throw(ArgumentError("unknown tool call id: $(approval.call_id)"))
        stored.approved = approval.approved
        stored.rejected_reason = approval.rejected_reason
    end
    for ptc in state.pending_tool_calls
        ptc.approved === nothing && throw(ArgumentError("pending tool calls must be approved or rejected before continuing"))
    end
    return state.pending_tool_calls
end

function append_state!(state::AgentState, input::AgentTurnInput, message::AssistantMessage, usage::Usage)
    if input isa String
        push!(state.messages, UserMessage(input))
    end
    push!(state.messages, message)
    if message.response_id !== nothing
        state.response_id = message.response_id
    end
    add_usage!(state.usage, usage)
    return state
end

function evaluate!(f::Function, agent::Agent, input::Union{String,Vector{PendingToolCall}}, apikey::String;
        model::Union{Nothing, Model} = nothing, state::AgentState = AgentState(),
        http_kw=(;), kw...)
    return Future{AgentResult}() do
        model = model === nothing ? agent.model : model
        model === nothing && throw(ArgumentError("no model specified with which agent can evaluate input"))
        f(AgentEvaluateStartEvent())
        turn = 1
        f(TurnStartEvent(turn))
        local current_input
        if input isa Vector{PendingToolCall}
            isempty(state.messages) && state.response_id === nothing && throw(ArgumentError("tool result input requires prior state"))
            pending = isempty(state.pending_tool_calls) ? input : merge_pending_tool_calls!(state, input)
            tool_results = resolve_tool_results!(f, agent, pending)
            state.pending_tool_calls = PendingToolCall[]
            current_input = tool_results
        else
            current_input = input
        end
        validate_guardrail(agent, current_input, apikey) || begin
            f(AgentErrorEvent(InvalidInputError(input isa String ? input : "<non-string input>")))
            throw(ArgumentError("input_guardrail check failed for input: `$input`"))
        end

        usage = Usage()
        while true
            response = stream(f, agent, state, current_input, apikey; model, http_kw, kw...)
            add_usage!(usage, response.usage)
            append_state!(state, current_input, response.message, response.usage)

            pending_tool_calls = PendingToolCall[]
            for call in response.message.tool_calls
                push!(pending_tool_calls, PendingToolCall(; call_id=call.call_id, name=call.name, arguments=call.arguments))
            end
            f(TurnEndEvent(turn, response.message, pending_tool_calls))

            requires_approval = PendingToolCall[]
            for ptc in pending_tool_calls
                tool = findtool(agent.tools, ptc.name)
                if tool.requires_approval
                    push!(requires_approval, ptc)
                end
            end

            if isempty(pending_tool_calls) || !isempty(requires_approval)
                state.pending_tool_calls = requires_approval
                result = AgentResult(
                    ; message=response.message,
                    usage,
                    pending_tool_calls=requires_approval,
                    stop_reason=response.stop_reason,
                )
                f(AgentEvaluateEndEvent(result))
                return result
            end

            state.pending_tool_calls = PendingToolCall[]
            current_input = resolve_tool_results!(f, agent, pending_tool_calls)
            turn += 1
            f(TurnStartEvent(turn))
        end
    end
end

function call_function_tool!(f, tool::AgentTool, tc::PendingToolCall)
    return Future{ToolResultMessage}() do
        args = JSON.parse(tc.arguments, parameters(tool))
        is_error = false
        output = ""
        try
            output = string(tool.func(args...))
        catch e
            is_error = true
            output = sprint(showerror, e)
        end
        trm = ToolResultMessage(; output, is_error, call_id=tc.call_id, name=tc.name, arguments=tc.arguments)
        f(ToolExecutionEndEvent(tc, trm))
        return trm
    end
end

function reject_function_tool!(f, tc::PendingToolCall)
    reason = tc.rejected_reason === nothing ? "tool call rejected by user" : tc.rejected_reason
    trm = ToolResultMessage(; output=reason, is_error=true, call_id=tc.call_id, name=tc.name, arguments=tc.arguments)
    f(ToolExecutionEndEvent(tc, trm))
    return Future{ToolResultMessage}(() -> trm)
end
