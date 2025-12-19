@kwarg struct Agent{F}
    prompt::String
    model::Union{Nothing, Model} = nothing
    input_guardrail::F = nothing
    tools::Vector{AgentTool} = AgentTool[]
end

struct InvalidInputError <: Exception
    input::String
end

@kwarg struct Result
    previous_response_id::String
    pending_tool_calls::Vector{PendingToolCall} # for tool calls that are waiting for approval
end

function evaluate!(agent::Agent, input::Union{String,Vector{PendingToolCall}}, apikey::String; model::Union{Nothing, Model} = nothing, previous_response_id::Union{Nothing, String} = nothing, stream_output::Bool = isinteractive(), kw...)
    return evaluate!(agent, input, apikey; model, previous_response_id, kw...) do event
        if event isa MessageUpdateEvent
            stream_output && print(event.delta)
        elseif event isa MessageEndEvent
            stream_output && println()
        end
    end
end

function evaluate!(f::Function, agent::Agent, input::Union{String,Vector{PendingToolCall}}, apikey::String; model::Union{Nothing, Model} = nothing, previous_response_id::Union{Nothing, String} = nothing, http_kw=(;), kw...)
    model = model === nothing ? agent.model : model
    model === nothing && throw(ArgumentError("no model specified with which agent can evaluate input"))
    if model.api == "openai-responses"
        return Future{Result}() do
            tools = [OpenAIResponses.FunctionTool(t) for t in agent.tools]
            input_valid = Future{Bool}(() -> (agent.input_guardrail === nothing || !(input isa String)) ? true : agent.input_guardrail(agent.prompt, input, apikey))
            f(AgentEvaluateStartEvent())
            turn = 1
            f(TurnStartEvent(turn))
            local current_input, pending_decisions
            if input isa Vector{PendingToolCall}
                # when the user passes back approved or rejected tool calls, we fetch the full previous response
                # (which should include these tool calls, along with any others that didn't require approval)
                # we do this to avoid needing to validate or trust tool calls and arguments provided by the user
                previous_response_id === nothing && throw(ArgumentError("previous_response_id is required when input is Vector{PendingToolCall}"))
                any(x -> x.approved === nothing, input) && throw(ArgumentError("pending tool calls must be approved or rejected before continuing"))
                prev_response = OpenAIResponses.get_response(model, previous_response_id, apikey; http_kw)
                tool_results = Future{ToolResultMessage}[]
                provided_call_ids = Set([x.call_id for x in input])
                for item in prev_response.output
                    if item isa OpenAIResponses.FunctionToolCall
                        tc = PendingToolCall(; call_id=item.call_id, name=item.name, arguments=item.arguments)
                        tool = findtool(agent.tools, tc.name)
                        f(ToolExecutionStartEvent(tc))
                        if tool.requires_approval
                            pending = findpendingtool(input, tc.call_id)
                            @assert pending !== nothing "Missing tool call requiring approval: $(tc.name)"
                            if pending.approved
                                push!(tool_results, call_function_tool!(f, tool, tc))
                            else
                                push!(tool_results, reject_function_tool!(f, tc, pending))
                            end
                        else
                            push!(tool_results, call_function_tool!(f, tool, tc))
                        end
                        delete!(provided_call_ids, tc.call_id)
                    end
                end
                if length(provided_call_ids) > 0
                    # user provided tool calls that didn't match any in the previous response
                    @warn "The previous response didn't match provided tool calls: $provided_call_ids"
                end
                current_input = OpenAIResponses.InputItem[OpenAIResponses.FunctionToolCallOutput(wait(x)) for x in tool_results]
            else
                current_input = input
            end
            pending_tool_calls = PendingToolCall[]
            # core agent loop; continue until no more tool calls or we have pending tool calls that need to be resolved
            while true
                assistant_message = AssistantTextMessage(; response_id=previous_response_id)
                assistant_started = false
                assistant_ended = false
                empty!(pending_tool_calls)
                OpenAIResponses.stream(model, current_input, apikey; tools, previous_response_id, http_kw, kw...) do http_stream, event
                    if !wait(input_valid)
                        close(http_stream)
                        f(AgentErrorEvent(InvalidInputError(input isa String ? input : "<non-string input>")))
                        return
                    end
                    if event isa OpenAIResponses.StreamResponseCreatedEvent
                        previous_response_id = event.response.id
                        assistant_message.response_id = previous_response_id
                        if !assistant_started
                            assistant_started = true
                            f(MessageStartEvent(:assistant, assistant_message))
                        end
                    elseif event isa OpenAIResponses.StreamOutputTextDeltaEvent
                        if !assistant_started
                            assistant_started = true
                            f(MessageStartEvent(:assistant, assistant_message))
                        end
                        assistant_message.text *= event.delta
                        f(MessageUpdateEvent(:assistant, assistant_message, :text, event.delta, event.item_id))
                    elseif event isa OpenAIResponses.StreamReasoningSummaryTextDeltaEvent
                        if !assistant_started
                            assistant_started = true
                            f(MessageStartEvent(:assistant, assistant_message))
                        end
                        assistant_message.reasoning *= event.delta
                        f(MessageUpdateEvent(:assistant, assistant_message, :reasoning, event.delta, event.item_id))
                    elseif event isa OpenAIResponses.StreamReasoningTextDeltaEvent
                        if !assistant_started
                            assistant_started = true
                            f(MessageStartEvent(:assistant, assistant_message))
                        end
                        assistant_message.reasoning *= event.delta
                        f(MessageUpdateEvent(:assistant, assistant_message, :reasoning, event.delta, event.item_id))
                    elseif event isa OpenAIResponses.StreamRefusalDeltaEvent
                        if !assistant_started
                            assistant_started = true
                            f(MessageStartEvent(:assistant, assistant_message))
                        end
                        assistant_message.refusal *= event.delta
                        f(MessageUpdateEvent(:assistant, assistant_message, :refusal, event.delta, event.item_id))
                    elseif event isa OpenAIResponses.StreamFunctionCallArgumentsDeltaEvent
                        f(MessageUpdateEvent(:assistant, assistant_message, :tool_arguments, event.delta, event.item_id))
                    elseif event isa OpenAIResponses.StreamOutputDoneEvent
                        f(MessageEndEvent(:assistant, assistant_message))
                    elseif event isa OpenAIResponses.StreamOutputItemDoneEvent
                        item_type = event.item.type
                        if item_type == "function_call"
                            ptc = PendingToolCall(; call_id=event.item.call_id, name=event.item.name, arguments=event.item.arguments)
                            push!(pending_tool_calls, ptc)
                            at = findtool(agent.tools, ptc.name)
                            f(ToolCallRequestEvent(ptc, at.requires_approval))
                        end
                    elseif event isa OpenAIResponses.StreamDoneEvent
                        if assistant_started && !assistant_ended
                            assistant_ended = true
                            f(MessageEndEvent(:assistant, assistant_message))
                        end
                    elseif event isa OpenAIResponses.StreamErrorEvent
                        if assistant_started && !assistant_ended
                            assistant_ended = true
                            f(MessageEndEvent(:assistant, assistant_message))
                        end
                        f(AgentErrorEvent(ErrorException(event.message)))
                    end
                end
                if assistant_started && !assistant_ended
                    f(MessageEndEvent(:assistant, assistant_message))
                end
                if !wait(input_valid)
                    throw(ArgumentError("input_guardrail check failed for input: `$input`"))
                elseif isempty(pending_tool_calls) || any(ptc -> findtool(agent.tools, ptc.name).requires_approval, pending_tool_calls)
                    result = Result(; previous_response_id, pending_tool_calls=filter!(x -> findtool(agent.tools, x.name).requires_approval, pending_tool_calls))
                    f(AgentEvaluateEndEvent(result))
                    return result
                end
                tool_results = Future{ToolResultMessage}[]
                for tc in pending_tool_calls
                    tool = findtool(agent.tools, tc.name)
                    f(ToolExecutionStartEvent(tc))
                    push!(tool_results, call_function_tool!(f, tool, tc))
                end
                current_input = OpenAIResponses.InputItem[OpenAIResponses.FunctionToolCallOutput(wait(x)) for x in tool_results]
                f(TurnEndEvent(turn, assistant_started ? assistant_message : nothing, pending_tool_calls))
                turn += 1
                f(TurnStartEvent(turn))
            end
        end
    else
        throw(ArgumentError("$(model.name) using $(model.api) api currently unsupported"))
    end
end

evaluate(args...; kw...) = wait(evaluate!(args...; kw...))

function call_function_tool!(f, tool::AgentTool, tc::PendingToolCall)
    return Future{ToolResultMessage}() do
        args = JSON.parse(tc.arguments, parameters(tool))
        is_error = false
        output = ""
        try
            output = string(tool.func(args...))
        catch
            is_error = true
        end
        trm = ToolResultMessage(; output, is_error, call_id=tc.call_id, name=tc.name, arguments=tc.arguments)
        f(ToolExecutionEndEvent(tc, trm))
        return trm
    end
end

function reject_function_tool!(f, tc::PendingToolCall, pending::PendingToolCall)
    trm = ToolResultMessage(; output=pending.rejected_reason, is_error=true, call_id=tc.call_id, name=tc.name, arguments=tc.arguments)
    f(ToolExecutionEndEvent(tc, trm))
    return trm
end
