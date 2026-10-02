const AgentHandler = Function

const DEFAULT_MAX_TOOL_RESULT_BYTES = 1_048_576  # 1MB
const MAX_TOOL_RESULT_BYTES = Ref(DEFAULT_MAX_TOOL_RESULT_BYTES)

function _format_byte_size(bytes::Int)
    if bytes < 1024
        return "$(bytes)B"
    elseif bytes < 1_048_576
        return "$(round(bytes / 1024; digits=1))KB"
    end
    return "$(round(bytes / 1_048_576; digits=1))MB"
end

function _truncate_tool_result(output::String, max_bytes::Int)
    sizeof(output) <= max_bytes && return output
    original_size = sizeof(output)
    idx = prevind(output, max_bytes + 1)
    truncated = output[1:idx]
    return truncated * "\n\n[Tool result truncated: showing first ~$(_format_byte_size(max_bytes)) of $(_format_byte_size(original_size)) total]"
end

@kwarg struct Agent{T<:AgentTool, H, A}
    id::Union{Nothing, String} = nothing
    prompt::String
    model::Model
    apikey::String
    tools::Vector{T} = empty_agent_tools()
    http_kw::H = (;)  # HTTP.jl kwargs (retries, retry_delays, etc.)
    api::Val{A} = Val(Symbol(model.api))
end

with_prompt(agent::Agent, prompt::String) = Agent(
    ;
    id = agent.id,
    prompt,
    model = agent.model,
    apikey = agent.apikey,
    tools = agent.tools,
    http_kw = agent.http_kw,
    api = agent.api,
)

with_tools(agent::Agent, tools::Vector{T}) where {T<:AgentTool} = Agent(
    ;
    id = agent.id,
    prompt = agent.prompt,
    model = agent.model,
    apikey = agent.apikey,
    tools,
    http_kw = agent.http_kw,
    api = agent.api,
)

mutable struct Abort
    @atomic aborted::Bool
    Abort() = new(false)
end

abort!(x::Abort) = @atomic x.aborted = true
isaborted(x::Abort) = @atomic x.aborted

struct InvalidInputError <: Exception
    input::String
end

struct AbortEvaluation <: Exception
end

check_abort(abort::Abort) = isaborted(abort) && throw(AbortEvaluation())

function last_assistant_message(state::AgentState)
    for idx in length(state.messages):-1:1
        msg = state.messages[idx]
        msg isa AssistantMessage && return msg
    end
    return nothing
end

function append_turn_input!(state::AgentState, input::AgentTurnInput)
    if input isa String
        push!(state.messages, UserMessage(input))
    elseif input isa UserMessage
        push!(state.messages, input)
    elseif input isa Vector{UserContentBlock}
        push!(state.messages, UserMessage(input))
    elseif input isa Vector{ToolResultMessage}
        for result in input
            push!(state.messages, result)
        end
    end
    return state
end

function append_state!(state::AgentState, input::AgentTurnInput, message::AssistantMessage, usage::Usage)
    append_turn_input!(state, input)
    push!(state.messages, message)
    if message.response_id !== nothing
        state.response_id = message.response_id
    end
    add_usage!(state.usage, usage)
    return state
end

function pending_tool_calls_from_message(message::AssistantMessage)
    pending_tool_calls = PendingToolCall[]
    if !isempty(message.tool_calls)
        for call in message.tool_calls
            push!(pending_tool_calls, PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments))
        end
        return pending_tool_calls
    end
    for block in message.content
        block isa ToolCallContent || continue
        args = JSON.json(block.arguments)
        push!(pending_tool_calls, PendingToolCall(; call_id = block.id, name = block.name, arguments = args))
    end
    return pending_tool_calls
end

# Tool calls run only after a turn that ended normally. A truncated or filtered
# turn can carry cut-off arguments, and a model can name a tool it was never
# given; both get an error result the model can act on instead of running.
function start_tool_call!(f, tools, tc::PendingToolCall, stop_reason::Union{Nothing, Symbol})
    if !(stop_reason === nothing || stop_reason === :tool_calls || stop_reason === :stop)
        return tool_error_future(f, tc;
            error_kind = "tool_call_not_executed",
            message = "Tool call `$(tc.name)` was not executed: the response ended with stop reason `$(stop_reason)`, so its arguments may be incomplete.",
            suggested_fix = "Re-issue the tool call with complete arguments.")
    end
    tool = findtool(tools, tc.name)
    if tool === nothing
        @warn "Model called an unknown tool" tool = tc.name call_id = tc.call_id
        return tool_error_future(f, tc;
            error_kind = "unknown_tool",
            message = "Unknown tool `$(tc.name)`.",
            suggested_fix = "Call one of the available tools: $(join((t.name for t in tools), ", ")).")
    end
    return call_function_tool!(f, tool, tc)
end

function tool_error_future(f, tc::PendingToolCall; error_kind::String, message::String, suggested_fix::String)
    f(ToolExecutionStartEvent(tc))
    output = render_tool_error_json(; error_kind, message, tool = tc.name, call_id = tc.call_id, suggested_fix)
    trm = ToolResultMessage(tc.call_id, tc.name, output; is_error = true)
    f(ToolExecutionEndEvent(tc, trm))
    fut = Future{ToolResultMessage}()
    notify(fut, trm)
    return fut
end

function call_function_tool!(f, tool::AgentTool, tc::PendingToolCall)
    return Future{ToolResultMessage}() do
        f(ToolExecutionStartEvent(tc))
        @debug "Tool execution started" tool = tc.name call_id = tc.call_id
        start_ns = time_ns()
        is_error = false
        output = ""
        args = nothing
        parse_error = nothing
        parse_bt = nothing
        try
            args = parse_tool_arguments(tc.arguments, parameters(tool))
        catch e
            parse_error = caught_exception(e, "Tool arguments are invalid.")
            parse_bt = caught_backtrace()
        end

        if parse_error !== nothing
            is_error = true
            raw = tc.arguments
            raw_preview = length(raw) > 500 ? string(first(raw, 500), "... (truncated, length=$(length(raw)))") : raw
            parse_msg = caught_exception_message(
                parse_error, "Tool arguments are invalid.")
            @warn "Tool argument parsing failed" tool = tc.name call_id = tc.call_id exception = (parse_error, parse_bt)
            output = render_tool_error_json(
                ;
                error_kind = "tool_argument_parse_failed",
                message = "Failed to parse tool arguments: $(parse_msg)",
                tool = tc.name,
                call_id = tc.call_id,
                exception = parse_error,
                backtrace = parse_bt,
                raw_arguments = raw_preview,
                suggested_fix = "Provide a valid JSON object matching the tool schema and include all required arguments.",
            )
        else
            try
                output = invoke_parsed_tool(tool, args)
            catch e
                normalized_error =
                    caught_exception(e, "The tool could not complete the request.")
                bt = caught_backtrace()
                is_error = true
                error_msg = caught_exception_message(
                    normalized_error, "The tool could not complete the request.")
                @error "Tool execution failed" tool = tc.name call_id = tc.call_id exception = (normalized_error, bt)
                output = render_tool_error_json(
                    ;
                    error_kind = "tool_execution_failed",
                    message = error_msg,
                    tool = tc.name,
                    call_id = tc.call_id,
                    exception = normalized_error,
                    backtrace = bt,
                    suggested_fix = "Inspect error_kind/message and call the tool again with corrected arguments or preconditions.",
                )
            end
        end
        max_bytes = MAX_TOOL_RESULT_BYTES[]
        if max_bytes > 0 && sizeof(output) > max_bytes
            @warn "Tool result exceeds size limit, truncating" tool=tc.name original_size=sizeof(output) limit=max_bytes
            output = _truncate_tool_result(output, max_bytes)
        end
        trm = ToolResultMessage(tc.call_id, tc.name, output; is_error)
        duration_ms = Int64(div(time_ns() - start_ns, 1_000_000))
        @debug "Tool execution completed" tool = tc.name call_id = tc.call_id duration_ms is_error output_bytes = sizeof(output)
        f(ToolExecutionEndEvent(tc, trm, duration_ms))
        return trm
    end
end

function invoke_parsed_tool(tool::AgentTool{F,T}, args)::String where {F,T<:NamedTuple}
    return invoke_tool_function(tool, args::T)
end

@generated function invoke_tool_function(
        tool::AgentTool{F,T}, args::T,
    ) where {F,T<:NamedTuple}
    call_args = [:(getfield(args, $idx)) for idx in 1:fieldcount(T)]
    return :(string(getfield(tool, :func)($(call_args...))))
end

# Raised when a tool call's argument JSON does not match the tool's parameter
# schema. `call_function_tool!` renders it back to the model, so the message has
# to name the offending field in JSON vocabulary the model can act on, not the
# Julia conversion error JSON.jl raises.
struct ToolArgumentError <: Exception
    message::String
end

Base.showerror(io::IO, e::ToolArgumentError) = print(io, e.message)

function _expected_json_type(::Type{T}) where {T}
    T isa Union && Nothing <: T &&
        return string(_expected_json_type(Base.nonnothingtype(T)), " or null")
    T === Nothing && return "null"
    T <: AbstractString && return "a string"
    T === Bool && return "a boolean"
    T <: Integer && return "an integer"
    T <: Real && return "a number"
    T <: AbstractVector && return "an array"
    T <: Union{AbstractDict, NamedTuple} && return "an object"
    return "a value of type $(T)"
end

_received_json_type(x) = "a value of type $(typeof(x))"
_received_json_type(::Nothing) = "null"
_received_json_type(::AbstractString) = "a string"
_received_json_type(::Bool) = "a boolean"
_received_json_type(::Integer) = "an integer"
_received_json_type(::Real) = "a number"
_received_json_type(::AbstractVector) = "an array"
_received_json_type(::AbstractDict) = "an object"

# Ask JSON.jl itself whether a value is usable for a field, so the diagnosis
# always agrees with the parse that just failed.
function _accepts_json_value(::Type{T}, value) where {T}
    try
        JSON.parse(JSON.json(value), T)
        return true
    catch
        return false
    end
end

function _tool_argument_problems(obj::AbstractDict, ::Type{T}) where {T<:NamedTuple}
    problems = String[]
    for (name, FT) in zip(fieldnames(T), fieldtypes(T))
        key = String(name)
        if !haskey(obj, key)
            FT >: Nothing || push!(problems, "missing required argument `$(key)` (expected $(_expected_json_type(FT)))")
            continue
        end
        value = obj[key]
        _accepts_json_value(FT, value) && continue
        push!(problems, "argument `$(key)` expects $(_expected_json_type(FT)), but received $(_received_json_type(value))")
    end
    return problems
end

function _describe_tool_argument_error(arguments::String, ::Type{T}, err) where {T<:NamedTuple}
    parsed = try
        JSON.parse(arguments)
    catch parse_err
        # JSON.jl v1.7.1 throws a BoundsError out of its own error-reporting path
        # when the input ends mid-token, so only its ArgumentError carries a
        # message worth forwarding; anything else means the input ran out.
        reason = parse_err isa ArgumentError ? parse_err.msg :
            "the input ends unexpectedly (truncated or malformed)"
        return "the arguments are not valid JSON: $(reason)"
    end
    parsed isa AbstractDict ||
        return "expected a JSON object of arguments, but received $(_received_json_type(parsed))"
    problems = _tool_argument_problems(parsed, T)
    isempty(problems) && return caught_exception_message(err, "the arguments do not match the tool schema")
    return join(problems, "; ")
end

function parse_tool_arguments(arguments::String, ::Type{T})::T where {T<:NamedTuple}
    try
        return JSON.parse(arguments, T)
    catch e
        throw(ToolArgumentError(_describe_tool_argument_error(arguments, T, e)))
    end
end
