using HTTP
using JSON

function openai_responses_event_callback(
        f::Function,
        agent::Agent,
        assistant_message::AssistantMessage,
        started::Base.RefValue{Bool},
        ended::Base.RefValue{Bool},
        response_usage::Base.RefValue{Union{Nothing, OpenAIResponses.Usage}},
        response_status::Base.RefValue{Union{Nothing, String}},
    )
    return function (event)
        local parsed
        try
            parsed = JSON.parse(String(event.data), OpenAIResponses.StreamEvent)
        catch e
            f(AgentErrorEvent(ErrorException(sprint(showerror, e))))
            return
        end

        function append_text_with_signature!(delta::String, item_id)
            if isempty(assistant_message.content) || !(assistant_message.content[end] isa TextContent)
                sig = item_id === nothing ? nothing : string(item_id)
                push!(assistant_message.content, TextContent(; text = delta, textSignature = sig))
            else
                block = assistant_message.content[end]
                block.text *= delta
                if block.textSignature === nothing && item_id !== nothing
                    block.textSignature = string(item_id)
                end
            end
        end

        function append_thinking_with_signature!(delta::String, item_id)
            if isempty(assistant_message.content) || !(assistant_message.content[end] isa ThinkingContent)
                sig = item_id === nothing ? nothing : string(item_id)
                push!(assistant_message.content, ThinkingContent(; thinking = delta, thinkingSignature = sig))
            else
                block = assistant_message.content[end]
                block.thinking *= delta
                if block.thinkingSignature === nothing && item_id !== nothing
                    block.thinkingSignature = string(item_id)
                end
            end
        end

        return if parsed isa OpenAIResponses.StreamResponseCreatedEvent
            response_id = parsed.response.id
            if response_id !== nothing
                assistant_message.response_id = response_id
            end
            if !started[]
                started[] = true
                f(MessageStartEvent(:assistant, assistant_message))
            end
        elseif parsed isa OpenAIResponses.StreamOutputTextDeltaEvent
            if !started[]
                started[] = true
                f(MessageStartEvent(:assistant, assistant_message))
            end
            append_text_with_signature!(parsed.delta, parsed.item_id)
            f(MessageUpdateEvent(:assistant, assistant_message, :text, parsed.delta, parsed.item_id))
        elseif parsed isa OpenAIResponses.StreamReasoningSummaryTextDeltaEvent
            if !started[]
                started[] = true
                f(MessageStartEvent(:assistant, assistant_message))
            end
            append_thinking_with_signature!(parsed.delta, parsed.item_id)
            f(MessageUpdateEvent(:assistant, assistant_message, :reasoning, parsed.delta, parsed.item_id))
        elseif parsed isa OpenAIResponses.StreamReasoningTextDeltaEvent
            if !started[]
                started[] = true
                f(MessageStartEvent(:assistant, assistant_message))
            end
            append_thinking_with_signature!(parsed.delta, parsed.item_id)
            f(MessageUpdateEvent(:assistant, assistant_message, :reasoning, parsed.delta, parsed.item_id))
        elseif parsed isa OpenAIResponses.StreamRefusalDeltaEvent
            if !started[]
                started[] = true
                f(MessageStartEvent(:assistant, assistant_message))
            end
            append_text_with_signature!(parsed.delta, parsed.item_id)
            f(MessageUpdateEvent(:assistant, assistant_message, :text, parsed.delta, parsed.item_id))
        elseif parsed isa OpenAIResponses.StreamFunctionCallArgumentsDeltaEvent
            if !started[]
                started[] = true
                f(MessageStartEvent(:assistant, assistant_message))
            end
            f(MessageUpdateEvent(:assistant, assistant_message, :tool_arguments, parsed.delta, parsed.item_id))
        elseif parsed isa OpenAIResponses.StreamOutputItemDoneEvent
            item_type = parsed.item.type
            if item_type == "function_call"
                args = parse_tool_arguments(parsed.item.arguments)
                call = AgentToolCall(
                    call_id = parsed.item.call_id,
                    name = parsed.item.name,
                    arguments = parsed.item.arguments,
                )
                push!(assistant_message.tool_calls, call)
                push!(assistant_message.content, ToolCallContent(; id = parsed.item.call_id, name = parsed.item.name, arguments = args))
                tool = findtool(agent.tools, call.name)
                ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                f(ToolCallRequestEvent(ptc, tool.requires_approval))
            end
        elseif parsed isa OpenAIResponses.StreamResponseCompletedEvent
            response_status[] = parsed.response.status
            response_usage[] = parsed.response.usage
            response_id = parsed.response.id
            if response_id !== nothing
                assistant_message.response_id = response_id
            end
        elseif parsed isa OpenAIResponses.StreamResponseFailedEvent
            response_status[] = parsed.response.status
            response_usage[] = parsed.response.usage
        elseif parsed isa OpenAIResponses.StreamResponseIncompleteEvent
            response_status[] = parsed.response.status
            response_usage[] = parsed.response.usage
        elseif parsed isa OpenAIResponses.StreamOutputDoneEvent || parsed isa OpenAIResponses.StreamDoneEvent
            if started[] && !ended[]
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end
        elseif parsed isa OpenAIResponses.StreamErrorEvent
            if started[] && !ended[]
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end
            f(AgentErrorEvent(ErrorException(parsed.message)))
        end
    end
end
