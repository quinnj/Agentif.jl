abstract type AgentContext end

# we need to be able to get the agent from any context
function get_agent end

@kwarg struct Agent{F} <: AgentContext
    prompt::String
    model::Model
    apikey::String
    state::AgentState = AgentState()
    skills::Union{Nothing, SkillRegistry} = create_skill_registry()
    input_guardrail::F = nothing
    tools::Vector{AgentTool} = AgentTool[]
    stream_output::Bool = false
    http_kw::Any = (;)  # HTTP.jl kwargs (retries, retry_delays, etc.)
end

get_agent(x::Agent) = x

function handle_event(agent::Agent, event)
    return if event isa MessageUpdateEvent && agent.stream_output
        print(event.delta)
    elseif event isa MessageEndEvent && agent.stream_output
        println()
    end
end

struct InvalidInputError <: Exception
    input::String
end

struct AbortEvaluation <: Exception
    reason::String
end

AbortEvaluation() = AbortEvaluation("aborted")

const PENDING_TOOL_CALL_REJECTION_MESSAGE = "User skipped or otherwise chose not to allow this tool call to run. Proceed assuming you can't call this tool with these arguments again."

function auto_reject_pending_tool_calls!(f::Function, state::AgentState)
    isempty(state.pending_tool_calls) && return ToolResultMessage[]
    tool_results = ToolResultMessage[]
    for ptc in state.pending_tool_calls
        f(ToolExecutionStartEvent(ptc))
        reject!(ptc, PENDING_TOOL_CALL_REJECTION_MESSAGE)
        trm = wait(reject_function_tool!(f, ptc))
        push!(tool_results, trm)
        push!(state.messages, trm)
    end
    state.pending_tool_calls = PendingToolCall[]
    return tool_results
end

function validate_guardrail(agent::Agent, input::AgentTurnInput)
    agent.input_guardrail === nothing && return true
    if input isa String
        return agent.input_guardrail(agent.prompt, input, agent.apikey)
    elseif input isa UserMessage
        return agent.input_guardrail(agent.prompt, message_text(input), agent.apikey)
    elseif input isa Vector{UserContentBlock}
        return agent.input_guardrail(agent.prompt, content_text(input), agent.apikey)
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
    by_id = Dict{String, PendingToolCall}()
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

function append_state!(state::AgentState, input::AgentTurnInput, message::AssistantMessage, usage::Usage; append_input::Bool = true)
    if input isa String
        append_input && push!(state.messages, UserMessage(input))
    elseif input isa UserMessage
        append_input && push!(state.messages, input)
    elseif input isa Vector{UserContentBlock}
        append_input && push!(state.messages, UserMessage(input))
    elseif input isa Vector{ToolResultMessage}
        for result in input
            push!(state.messages, result)
        end
    end
    push!(state.messages, message)
    if message.response_id !== nothing
        state.response_id = message.response_id
    end
    add_usage!(state.usage, usage)
    return state
end

evaluate(args...; kw...) = wait(evaluate!(args...; kw...))

evaluate!(ctx::AgentContext, input; kw...) = evaluate!(identity, ctx, input; kw...)

function evaluate!(f::Function, ctx::AgentContext, input::Union{String, Vector{PendingToolCall}}; kw...)
    return _evaluate!(ctx, input; kw...) do event
        handle_event(ctx, event)
        f(event)
    end
end

function _evaluate!(f::Function, ctx::AgentContext, input::Union{String, Vector{PendingToolCall}}; append_input::Bool = true, kw...)
    return Future{AgentResult}() do
        evaluate_id = UID8()
        f(AgentEvaluateStartEvent(evaluate_id))
        agent = get_agent(ctx)
        state = agent.state
        turn = 1
        turn_id = UID8()
        usage = Usage()
        result::Union{Nothing, AgentResult} = nothing
        try
            f(TurnStartEvent(turn_id, turn))
            turn_ended = false
            try
                local current_input
                if input isa Vector{PendingToolCall}
                    isempty(state.messages) && state.response_id === nothing && throw(ArgumentError("tool result input requires prior state"))
                    pending = isempty(state.pending_tool_calls) ? input : merge_pending_tool_calls!(state, input)
                    tool_results = resolve_tool_results!(f, agent, pending)
                    state.pending_tool_calls = PendingToolCall[]
                    current_input = tool_results
                else
                    isempty(state.pending_tool_calls) || auto_reject_pending_tool_calls!(f, state)
                    current_input = input
                end
                validate_guardrail(agent, current_input) || begin
                    f(AgentErrorEvent(InvalidInputError(input isa String ? input : "<non-string input>")))
                    throw(ArgumentError("input_guardrail check failed for input: `$input`"))
                end

                while true
                    response = stream(f, agent, state, current_input, agent.apikey; agent.model, kw...)
                    add_usage!(usage, response.usage)
                    append_state!(state, current_input, response.message, response.usage; append_input = append_input)

                    pending_tool_calls = PendingToolCall[]
                    for call in response.message.tool_calls
                        push!(pending_tool_calls, PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments))
                    end
                    f(TurnEndEvent(turn_id, turn, response.message, pending_tool_calls))
                    turn_ended = true

                    requires_approval = PendingToolCall[]
                    for ptc in pending_tool_calls
                        tool = findtool(agent.tools, ptc.name)
                        if tool.requires_approval
                            push!(requires_approval, ptc)
                        end
                    end

                    if isempty(pending_tool_calls) || !isempty(requires_approval)
                        state.pending_tool_calls = requires_approval
                        result = AgentResult(; state)
                        return result
                    end

                    state.pending_tool_calls = PendingToolCall[]
                    current_input = resolve_tool_results!(f, agent, pending_tool_calls)
                    turn += 1
                    turn_id = UID8()
                    f(TurnStartEvent(turn_id, turn))
                    turn_ended = false
                end
            finally
                if !turn_ended
                    f(TurnEndEvent(turn_id, turn, nothing, PendingToolCall[]))
                end
            end
        catch e
            if e isa AbortEvaluation
                result = AgentResult(; state)
                return result
            end
            if e isa CapturedException && e.ex isa AbortEvaluation
                result = AgentResult(; state)
                return result
            end
            rethrow()
        finally
            f(AgentEvaluateEndEvent(evaluate_id, result))
        end
    end
end

function call_function_tool!(f, tool::AgentTool, tc::PendingToolCall)
    return Future{ToolResultMessage}() do
        start_ns = time_ns()
        is_error = false
        output = ""
        args = nothing
        parse_error = nothing
        try
            args = parse_tool_arguments(tc.arguments, parameters(tool))
        catch e
            parse_error = e
        end

        if parse_error !== nothing
            is_error = true
            raw = tc.arguments
            raw_preview = length(raw) > 500 ? string(raw[1:500], "... (truncated, length=$(length(raw)))") : raw
            output = "Failed to parse tool arguments: $(sprint(showerror, parse_error))\nRaw arguments: $(raw_preview)"
        else
            try
                output = string(tool.func(args...))
            catch e
                is_error = true
                output = sprint(showerror, e)
            end
        end
        trm = ToolResultMessage(tc.call_id, tc.name, output; is_error)
        duration_ms = Int64(div(time_ns() - start_ns, 1_000_000))
        f(ToolExecutionEndEvent(tc, trm, duration_ms))
        return trm
    end
end

function coerce_tool_arg(value, typ)
    typ === Any && return value
    if typ isa Union
        value === nothing && (Nothing <: typ) && return nothing
        for candidate in Base.uniontypes(typ)
            candidate === Nothing && continue
            try
                return convert(candidate, value)
            catch
            end
        end
        return value
    end
    return convert(typ, value)
end

function parse_tool_arguments(arguments::String, params_type::Type)
    parsed = JSON.parse(arguments)
    parsed isa AbstractDict || throw(ArgumentError("tool arguments must be a JSON object"))
    names = fieldnames(params_type)
    types = fieldtypes(params_type)
    values = Vector{Any}(undef, length(names))
    for (idx, (name, typ)) in enumerate(zip(names, types))
        key = String(name)
        if haskey(parsed, key)
            values[idx] = coerce_tool_arg(get(() -> nothing, parsed, key), typ)
        else
            if Nothing <: typ
                values[idx] = nothing
            else
                throw(ArgumentError("missing required tool argument: $(key)"))
            end
        end
    end
    return NamedTuple{names}(Tuple(values))
end

function reject_function_tool!(f, tc::PendingToolCall)
    reason = tc.rejected_reason === nothing ? "tool call rejected by user" : tc.rejected_reason
    trm = ToolResultMessage(tc.call_id, tc.name, reason; is_error = true)
    f(ToolExecutionEndEvent(tc, trm, Int64(0)))
    return Future{ToolResultMessage}(() -> trm)
end
