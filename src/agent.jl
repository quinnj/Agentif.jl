@kwarg struct Agent{F}
    prompt::String
    model::Union{Nothing, Model} = nothing
    input_guardrail::F = nothing
    tools::Vector{AgentTool} = AgentTool[]
end

struct InvalidInputError <: Exception
    input::String
end

@kwarg mutable struct PendingToolCall
    const tool::AgentTool
    const tool_call::OpenAIResponses.FunctionToolCall
    approved::Union{Nothing,Bool} = nothing
    rejected_reason::Union{Nothing,String} = nothing
end

approve!(pending_tool_call::PendingToolCall) = pending_tool_call.approved = true
function reject!(pending_tool_call::PendingToolCall, reason::String="the user has explicitly rejected the tool call request with arguments: $(pending_tool_call.tool_call.arguments); don't attempt to call this tool again")
    pending_tool_call.approved = false
    pending_tool_call.rejected_reason = reason
end

@kwarg struct Result
    previous_response_id::String
    tool_call_results # for tool calls that have been resolved, but not sent back to model
    pending_tool_calls::Vector{PendingToolCall} # for tool calls that are waiting for approval
end

function findtool(tools, name)
    for tool in tools
        tool.name == name && return tool
    end
    throw(ArgumentError("invalid tool for agent: `$name`"))
end

function evaluate!(agent::Agent, input::Union{String,Result}, apikey::String; model::Union{Nothing, Model} = nothing, previous_response_id::Union{Nothing, String} = nothing, stream_output::Bool = isinteractive(), kw...)
    return evaluate!(agent, input, apikey; model, previous_response_id, kw...) do event
        if event isa OpenAIResponses.StreamDeltaEvent
            stream_output && print(event.delta)
        elseif event isa OpenAIResponses.StreamOutputItemDoneEvent
            stream_output && println()
        end
    end
end

function evaluate!(f::Function, agent::Agent, input::Union{String,Result}, apikey::String; model::Union{Nothing, Model} = nothing, previous_response_id::Union{Nothing, String} = nothing, kw...)
    model = model === nothing ? agent.model : model
    model === nothing && throw(ArgumentError("no model specified with which agent can evaluate input"))
    if input isa Result
        any(x -> x.approved === nothing, input.pending_tool_calls) && throw(ArgumentError("pending tool calls must be approved or rejected before continuing"))
        previous_response_id = input.previous_response_id
        for tool_call in input.pending_tool_calls
            if tool_call.approved
                push!(input.tool_call_results, call_function_tool!(OpenAIResponses.FunctionToolCallOutput, tool_call.tool, tool_call.tool_call.call_id, tool_call.tool_call.arguments))
            else
                push!(input.tool_call_results, Future{OpenAIResponses.FunctionToolCallOutput}() do
                    return OpenAIResponses.FunctionToolCallOutput(;
                        output = tool_call.rejected_reason,
                        call_id = tool_call.tool_call.call_id
                    )
                end)
            end
        end
        input = OpenAIResponses.InputItem[wait(x) for x in input.tool_call_results]
    end
    if model.api == "openai-responses"
        return Future{Result}() do
            tools = [OpenAIResponses.FunctionTool(t) for t in agent.tools]
            tool_call_results = Future{OpenAIResponses.FunctionToolCallOutput}[]
            pending_tool_calls = []
            input_valid = Future{Bool}(() -> (agent.input_guardrail === nothing || !(input isa String)) ? true : agent.input_guardrail(agent.prompt, input, apikey))

            # core agent loop; continue until no more tool calls or we have pending tool calls that need to be resolved
            while true
                OpenAIResponses.stream(model, input, apikey; tools, previous_response_id, kw...) do (http_stream, event)
                    if event isa OpenAIResponses.StreamResponseCreatedEvent
                        previous_response_id = event.response.id
                    elseif event isa OpenAIResponses.StreamDeltaEvent
                        if !wait(input_valid)
                            close(http_stream)
                            f(InvalidInputError(input))
                            return
                        end
                    elseif event isa OpenAIResponses.StreamOutputItemDoneEvent
                        item_type = event.item.type
                        if item_type == "function_call"
                            if !wait(input_valid)
                                close(http_stream)
                                f(InvalidInputError(input))
                                return
                            end
                            tool = findtool(agent.tools, event.item.name)
                            if tool.requiresApproval
                                push!(pending_tool_calls, PendingToolCall(; tool, tool_call=event.item))
                            else
                                push!(tool_call_results, call_function_tool!(OpenAIResponses.FunctionToolCallOutput, tool, event.item.call_id, event.item.arguments))
                            end
                        end
                    end
                    f(event)
                end
                if !wait(input_valid)
                    throw(ArgumentError("input_guardrail check failed for input: `$input`"))
                elseif isempty(tool_call_results) || !isempty(pending_tool_calls)
                    return Result(; previous_response_id, tool_call_results, pending_tool_calls)
                end
                # input is valid and we have tool calls to resolve
                input = OpenAIResponses.InputItem[wait(x) for x in tool_call_results]
                empty!(tool_call_results)
            end
        end
    else
        throw(ArgumentError("$(model.name) using $(model.api) api currently unsupported"))
    end
end

evaluate(args...; kw...) = wait(evaluate!(args...; kw...))

function call_function_tool!(::Type{T}, tool::AgentTool, call_id, arguments::String) where {T}
    return Future{T}() do
        args = JSON.parse(arguments, parameters(tool))
        return T(;
            output = JSON.json(tool.func(args...)),
            call_id
        )
    end
end
