const AgentHandler = Function
const AgentMiddleware = Function

@kwarg struct Agent
    id::Union{Nothing, String} = nothing
    name::Union{Nothing, String} = nothing
    prompt::String
    model::Model
    apikey::String
    tools::Vector{AgentTool} = AgentTool[]
    http_kw::Any = (;)  # HTTP.jl kwargs (retries, retry_delays, etc.)
end

with_prompt(agent::Agent, prompt::String) = Agent(
    ;
    id = agent.id,
    name = agent.name,
    prompt,
    model = agent.model,
    apikey = agent.apikey,
    tools = agent.tools,
    http_kw = agent.http_kw,
)

with_tools(agent::Agent, tools::Vector{AgentTool}) = Agent(
    ;
    id = agent.id,
    name = agent.name,
    prompt = agent.prompt,
    model = agent.model,
    apikey = agent.apikey,
    tools,
    http_kw = agent.http_kw,
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

function call_function_tool!(f, tool::AgentTool, tc::PendingToolCall)
    return Future{ToolResultMessage}() do
        f(ToolExecutionStartEvent(tc))
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
