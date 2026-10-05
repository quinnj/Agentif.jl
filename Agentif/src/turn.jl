"""One logical provider turn. No tools, sessions, input queues, or compaction run here.

`usage` is known received usage; an interrupted request can have additional unknown
provider spend. Anthropic's bounded pause-turn continuation remains one turn.
"""
struct ModelTurnOutcome
    message::Union{Nothing, AssistantMessage}
    stop_reason::Symbol
    pending_calls::Vector{PendingToolCall}
    usage::Usage
    error::Union{Nothing, Exception}
    response_id::Union{Nothing, String}
end

eligible_tool_calls(outcome::ModelTurnOutcome) =
    outcome.error === nothing && outcome.stop_reason in (:stop, :tool_calls) ?
        deepcopy(outcome.pending_calls) : PendingToolCall[]

"""Execute a single turn from copied prepared context. Progress events are copies.

Transport retries are disabled by default so a durable host owns the total attempt
budget. Ordinary `stream` and `evaluate` defaults are unchanged. `request_options`
are provider request keywords. `stream_fn` supports deterministic provider fixtures.
"""
function model_turn(progress::Function, agent::Agent, prepared::AgentState, abort::Abort = Abort();
        request_options = (;), stream_fn = stream, transport_retries::Int = 0)
    state = deepcopy(prepared)
    state.usage = Usage()
    empty!(state.pending_tool_calls)
    state.most_recent_stop_reason = nothing
    start_count = length(state.messages)
    failure = Ref{Union{Nothing, Exception}}(nothing)
    sink = event -> begin
        event isa AgentErrorEvent && (failure[] = event.error)
        progress(deepcopy(event))
        nothing
    end
    try
        check_abort(abort)
        stream_fn(sink, agent, state, ToolResultMessage[], abort;
            http_kw = (; agent.http_kw..., retry = transport_retries > 0, retries = transport_retries), request_options...)
    catch err
        failure[] = err isa Exception ? err : ErrorException(string(err))
        state.most_recent_stop_reason = isaborted(abort) || err isa AbortEvaluation ? :aborted : :error
    end
    message = length(state.messages) > start_count ? last_assistant_message(state) : nothing
    reason = isaborted(abort) ? :aborted : failure[] !== nothing ? :error :
        something(state.most_recent_stop_reason, :invalid_response)
    calls = message === nothing ? PendingToolCall[] : pending_tool_calls_from_message(message)
    return ModelTurnOutcome(deepcopy(message), reason, deepcopy(calls), deepcopy(state.usage),
        failure[], state.response_id)
end

struct ToolOutcome
    output::String
    is_error::Bool
    details::Any
end
ToolOutcome(output::AbstractString; is_error::Bool = false, details = nothing) =
    ToolOutcome(MAX_TOOL_RESULT_BYTES[] > 0 ? _truncate_tool_result(String(output), MAX_TOOL_RESULT_BYTES[]) : String(output), is_error, details)

"""Invoke one already parsed tool. Legacy functions have no cooperative cancellation.

Throws distinguish infrastructure/interruption from a returned application error.
Context-aware hosts can install an explicitly versioned invocation adapter.
"""
function invoke_tool(tool::AgentTool, parsed_args, context)
    hasproperty(context, :abort) && check_abort(context.abort)
    hasproperty(context, :deadline) && time() >= context.deadline && throw(AbortEvaluation())
    ToolOutcome(invoke_parsed_tool(tool, parsed_args))
end

valid_summary(outcome::ModelTurnOutcome) = outcome.error === nothing && outcome.stop_reason === :stop &&
    isempty(outcome.pending_calls) && outcome.message !== nothing && !isempty(strip(message_text(outcome.message)))
