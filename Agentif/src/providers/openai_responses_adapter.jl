using HTTP
using JSON

const OPENAI_RESPONSES_TOOL_CALL_PROVIDERS = Set(["openai", "openai-codex", "opencode"])

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

function _responses_split_compound_id(id::AbstractString)
    idx = findfirst('|', id)
    if idx === nothing
        return (String(id), nothing)
    end
    return (String(id[1:idx-1]), String(id[idx+1:end]))
end

function openai_responses_normalize_tool_call_id(id::String, model::Model)
    model.provider in OPENAI_RESPONSES_TOOL_CALL_PROVIDERS || return id
    call_id, item_id = _responses_split_compound_id(id)
    item_id === nothing && return id

    normalized_call_id = replace(call_id, r"[^A-Za-z0-9_-]" => "_")
    normalized_item_id = replace(item_id, r"[^A-Za-z0-9_-]" => "_")
    startswith(normalized_item_id, "fc") || (normalized_item_id = "fc_" * normalized_item_id)

    length(normalized_call_id) > 64 && (normalized_call_id = first(normalized_call_id, 64))
    length(normalized_item_id) > 64 && (normalized_item_id = first(normalized_item_id, 64))

    normalized_call_id = replace(normalized_call_id, r"_+$" => "")
    normalized_item_id = replace(normalized_item_id, r"_+$" => "")

    isempty(normalized_call_id) && (normalized_call_id = "call")
    isempty(normalized_item_id) && (normalized_item_id = "fc")
    return "$(normalized_call_id)|$(normalized_item_id)"
end

function openai_responses_transformed_messages(state::AgentState, input::AgentTurnInput, model::Model)
    raw_messages = StoredAgentMessage[]
    for msg in state.messages
        include_in_context(msg) || continue
        push!(raw_messages, msg)
    end
    if input isa String
        push!(raw_messages, UserMessage(input))
    elseif input isa UserMessage
        push!(raw_messages, input)
    elseif input isa Vector{UserContentBlock}
        push!(raw_messages, UserMessage(input))
    elseif input isa Vector{ToolResultMessage}
        append!(raw_messages, input)
    end
    return transform_messages(raw_messages, model; normalize_tool_call_id = id -> openai_responses_normalize_tool_call_id(id, model))
end

function openai_responses_is_different_model(msg::AssistantMessage, model::Model)
    return msg.provider == model.provider && msg.api == model.api && msg.model != model.id
end

function openai_responses_input_from_message(msg::AgentMessage, model::Model)
    if msg isa UserMessage
        content = Any[]
        for block in msg.content
            if block isa TextContent
                push!(content, Dict("type" => "input_text", "text" => block.text))
            elseif block isa ImageContent
                push!(content, Dict("type" => "input_image", "image_url" => "data:$(block.mimeType);base64,$(block.data)"))
            end
        end
        isempty(content) && return Any[]
        return Any[Dict("role" => "user", "content" => content)]
    elseif msg isa AssistantMessage
        different_model = openai_responses_is_different_model(msg, model)
        parts = Any[]
        for block in msg.content
            if block isa ThinkingContent
                if block.thinkingSignature !== nothing
                    # Send back the entire opaque reasoning item (includes encrypted_content)
                    try
                        push!(parts, JSON.parse(block.thinkingSignature))
                        continue
                    catch
                    end
                end
                # Fallback: reconstruct from summary text (no encrypted_content)
                !isempty(block.thinking) && push!(
                    parts, Dict(
                        "type" => "reasoning",
                        "summary" => [Dict("type" => "summary_text", "text" => block.thinking)],
                        "status" => "completed",
                    )
                )
            elseif block isa TextContent
                !isempty(block.text) || continue
                msg_item = Dict{String, Any}(
                    "type" => "message",
                    "role" => "assistant",
                    "content" => [Dict("type" => "output_text", "text" => block.text)],
                    "status" => "completed",
                )
                if block.textSignature !== nothing
                    sig = block.textSignature
                    msg_item["id"] = length(sig) > 64 ? first(sig, 64) : sig
                end
                push!(parts, msg_item)
            elseif block isa ToolCallContent
                call_id_raw, item_id = _responses_split_compound_id(block.id)
                if different_model && item_id !== nothing && startswith(item_id, "fc_")
                    item_id = nothing
                end
                fc = Dict{String, Any}(
                    "type" => "function_call",
                    "call_id" => call_id_raw,
                    "name" => block.name,
                    "arguments" => JSON.json(block.arguments),
                )
                item_id !== nothing && (fc["id"] = item_id)
                push!(parts, fc)
            end
        end
        # Fallback: if no ToolCallContent blocks, use tool_calls field
        has_tc_blocks = any(b -> b isa ToolCallContent, msg.content)
        if !has_tc_blocks
            for tc in msg.tool_calls
                call_id_raw, item_id = _responses_split_compound_id(tc.call_id)
                if different_model && item_id !== nothing && startswith(item_id, "fc_")
                    item_id = nothing
                end
                fc = Dict{String, Any}(
                    "type" => "function_call",
                    "call_id" => call_id_raw,
                    "name" => tc.name,
                    "arguments" => tc.arguments,
                )
                item_id !== nothing && (fc["id"] = item_id)
                push!(parts, fc)
            end
        end
        return parts
    elseif msg isa ToolResultMessage
        output = provider_tool_result_output(msg)
        call_id_raw, _ = _responses_split_compound_id(msg.call_id)
        return Any[
            Dict(
                "type" => "function_call_output",
                "call_id" => call_id_raw,
                "output" => output,
            ),
        ]
    elseif msg isa CompactionSummaryMessage
        return Any[Dict("role" => "user", "content" => [Dict("type" => "input_text", "text" => "[Previous conversation summary]\n\n$(msg.summary)")])]
    end
    return Any[]
end

function openai_responses_build_full_input(agent::Agent, state::AgentState, input::AgentTurnInput, model::Model)
    items = Any[]
    for msg in openai_responses_transformed_messages(state, input, model)
        append!(items, openai_responses_input_from_message(msg, model))
    end
    return items
end

function openai_responses_usage_from_response(u::Union{Nothing, OpenAIResponses.Usage})
    u === nothing && return Usage()
    input = something(u.input_tokens, 0)
    output = something(u.output_tokens, 0)
    cached = 0
    if u.input_tokens_details !== nothing
        cached = something(u.input_tokens_details.cached_tokens, 0)
    end
    billable_input = max(0, input - cached)
    total = something(u.total_tokens, billable_input + output + cached)
    return Usage(; input = billable_input, output, cacheRead = cached, total)
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
        f::F,
        agent::Agent,
        assistant_message::AssistantMessage,
        started::Base.RefValue{Bool},
        ended::Base.RefValue{Bool},
        response_usage::Base.RefValue{Union{Nothing, OpenAIResponses.Usage}},
        response_status::Base.RefValue{Union{Nothing, String}},
        abort::Abort,
    ) where {F <: Function}
    return function (stream, event)
        maybe_abort!(abort, stream)
        data = String(event.data)
        if strip(data) == "[DONE]"
            if started[] && !ended[]
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end
            return
        end
        local parsed
        try
            parsed = JSON.parse(data, OpenAIResponses.StreamEvent)
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
                item = parsed.item::OpenAIResponses.FunctionToolCall
                raw_call_id = item.call_id
                item_id = item.id
                # Compound callId|itemId format (matching pi-mono)
                compound_id = item_id !== nothing ? "$(raw_call_id)|$(item_id)" : raw_call_id
                args = parse_tool_arguments(item.arguments)
                call = AgentToolCall(
                    call_id = compound_id,
                    name = item.name,
                    arguments = item.arguments,
                )
                push!(assistant_message.tool_calls, call)
                push!(assistant_message.content, ToolCallContent(; id = compound_id, name = item.name, arguments = args))
                findtool(agent.tools, call.name)
                ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                f(ToolCallRequestEvent(ptc))
            elseif item_type == "reasoning"
                item = parsed.item::OpenAIResponses.ReasoningOutput
                # Build final thinking text from summary
                if item.summary !== nothing
                    text = join([something(s.text, "") for s in item.summary], "\n\n")
                    set_last_thinking!(assistant_message, text)
                end
                # Store entire opaque reasoning item (includes encrypted_content) for roundtripping
                for idx in length(assistant_message.content):-1:1
                    block = assistant_message.content[idx]
                    if block isa ThinkingContent
                        block.thinkingSignature = JSON.json(item)
                        break
                    end
                end
            elseif item_type == "message"
                item = parsed.item::OpenAIResponses.Message
                # Build final text from content
                if item.content isa Vector
                    io = IOBuffer()
                    for part in item.content
                        if part isa OpenAIResponses.OutputTextContent
                            print(io, something(part.text, ""))
                        elseif part isa OpenAIResponses.Refusal
                            print(io, something(part.refusal, ""))
                        end
                    end
                    set_last_text!(assistant_message, String(take!(io)))
                end
                # Store item.id as textSignature for prompt cache pairing
                if item.id !== nothing
                    for idx in length(assistant_message.content):-1:1
                        block = assistant_message.content[idx]
                        if block isa TextContent
                            block.textSignature = string(item.id)
                            break
                        end
                    end
                end
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
            already_ended = ended[]
            if started[] && !ended[]
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end
            # Only emit error if not already reported (e.g. by a preceding StreamErrorEvent)
            if !already_ended
                error_obj = parsed.response.error
                error_msg = if error_obj !== nothing && error_obj.message !== nothing
                    String(error_obj.message)
                else
                    "Response failed"
                end
                f(AgentErrorEvent(ErrorException(error_msg)))
            end
        elseif parsed isa OpenAIResponses.StreamResponseIncompleteEvent
            response_status[] = parsed.response.status
            response_usage[] = parsed.response.usage
            if started[] && !ended[]
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end
        elseif parsed isa OpenAIResponses.StreamOutputDoneEvent || parsed isa OpenAIResponses.StreamDoneEvent
            if started[] && !ended[]
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end
        elseif parsed isa OpenAIResponses.StreamErrorEvent
            response_status[] = "failed"
            if started[] && !ended[]
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end
            # Extract message from top-level or nested error object
            error_msg = if parsed.message !== nothing
                parsed.message
            elseif parsed.error !== nothing && parsed.error.message !== nothing
                parsed.error.message
            else
                "Unknown error"
            end
            f(AgentErrorEvent(ErrorException(error_msg)))
        end
    end
end
