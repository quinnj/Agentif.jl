using HTTP
using JSON

function openai_responses_build_tools(tools::Vector{AgentTool})
    isempty(tools) && return nothing
    provider_tools = OpenAIResponses.Tool[]
    for tool in tools
        push!(
            provider_tools, OpenAIResponses.FunctionTool(
                name = tool.name,
                description = tool.description,
                strict = tool.strict,
                parameters = OpenAIResponses.schema(parameters(tool)),
            )
        )
    end
    return provider_tools
end

function openai_responses_input_content(blocks::Vector{UserContentBlock})
    content = OpenAIResponses.InputContent[]
    for block in blocks
        if block isa TextContent
            push!(content, OpenAIResponses.InputTextContent(; text = block.text))
        elseif block isa ImageContent
            url = "data:$(block.mimeType);base64,$(block.data)"
            push!(content, OpenAIResponses.InputImageContent(; image_url = url))
        end
    end
    return content
end

function openai_responses_tool_output_content(blocks::Vector{ToolResultContentBlock})
    content = OpenAIResponses.InputContent[]
    for block in blocks
        if block isa TextContent
            push!(content, OpenAIResponses.InputTextContent(; text = block.text))
        elseif block isa ImageContent
            url = "data:$(block.mimeType);base64,$(block.data)"
            push!(content, OpenAIResponses.InputImageContent(; image_url = url))
        end
    end
    return content
end

function openai_responses_build_input(input::AgentTurnInput)
    if input isa String
        return input
    elseif input isa UserMessage
        content = openai_responses_input_content(input.content)
        return OpenAIResponses.InputItem[OpenAIResponses.Message(; role = "user", content = content)]
    elseif input isa Vector{UserContentBlock}
        content = openai_responses_input_content(input)
        return OpenAIResponses.InputItem[OpenAIResponses.Message(; role = "user", content = content)]
    elseif input isa Vector{ToolResultMessage}
        outputs = OpenAIResponses.FunctionToolCallOutput[]
        for result in input
            output_blocks = openai_responses_tool_output_content(result.content)
            if isempty(output_blocks)
                push!(outputs, OpenAIResponses.FunctionToolCallOutput(; call_id = result.call_id, output = ""))
            elseif length(output_blocks) == 1 && output_blocks[1] isa OpenAIResponses.InputTextContent
                push!(outputs, OpenAIResponses.FunctionToolCallOutput(; call_id = result.call_id, output = output_blocks[1].text))
            else
                push!(outputs, OpenAIResponses.FunctionToolCallOutput(; call_id = result.call_id, output = output_blocks))
            end
        end
        return OpenAIResponses.InputItem[outputs...]
    end
    throw(ArgumentError("unsupported turn input: $(typeof(input))"))
end

function openai_responses_usage_from_response(u::Union{Nothing, OpenAIResponses.Usage})
    u === nothing && return Usage()
    input = something(u.input_tokens, 0)
    output = something(u.output_tokens, 0)
    total = something(u.total_tokens, input + output)
    cached = 0
    if u.input_tokens_details !== nothing
        cached = something(u.input_tokens_details.cached_tokens, 0)
    end
    return Usage(; input, output, cacheRead = cached, total)
end

function openai_responses_stop_reason(status::Union{Nothing, String}, tool_calls::Vector{AgentToolCall})
    if status == "failed"
        return :error
    elseif status == "incomplete"
        return :length
    elseif status == "cancelled"
        return :error
    elseif status == "completed"
        return isempty(tool_calls) ? :stop : :tool_calls
    end
    return isempty(tool_calls) ? :stop : :tool_calls
end

function openai_responses_event_callback(
        f::Function,
        agent::Agent,
        assistant_message::AssistantMessage,
        started::Base.RefValue{Bool},
        ended::Base.RefValue{Bool},
        response_usage::Base.RefValue{Union{Nothing, OpenAIResponses.Usage}},
        response_status::Base.RefValue{Union{Nothing, String}},
        abort::Abort,
    )
    return function (stream, event)
        maybe_abort!(abort, stream)
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
                findtool(agent.tools, call.name)
                ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                f(ToolCallRequestEvent(ptc))
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
