function openai_completions_detect_compat(model::Model)
    provider = model.provider
    base_url = model.baseUrl
    is_minimax = provider == "minimax" || occursin("minimax.io", base_url)
    is_zai = provider == "zai" || occursin("api.z.ai", base_url)
    is_nonstandard = provider == "cerebras" ||
        occursin("cerebras.ai", base_url) ||
        provider == "xai" ||
        occursin("api.x.ai", base_url) ||
        provider == "mistral" ||
        occursin("mistral.ai", base_url) ||
        occursin("chutes.ai", base_url) ||
        is_zai ||
        provider == "opencode" ||
        occursin("opencode.ai", base_url)
    use_max_tokens = provider == "mistral" || occursin("mistral.ai", base_url) || occursin("chutes.ai", base_url)
    is_grok = provider == "xai" || occursin("api.x.ai", base_url)
    is_mistral = provider == "mistral" || occursin("mistral.ai", base_url)
    return (;
        supportsStore = !is_nonstandard,
        supportsDeveloperRole = !is_nonstandard && !is_minimax,
        supportsReasoningEffort = !is_grok && !is_zai,
        supportsUsageInStreaming = true,
        maxTokensField = use_max_tokens ? "max_tokens" : "max_completion_tokens",
        requiresToolResultName = is_mistral,
        requiresAssistantAfterToolResult = false,
        requiresThinkingAsText = is_mistral,
        requiresMistralToolIds = is_mistral,
        thinkingFormat = is_zai ? "zai" : "openai",
    )
end

function openai_completions_resolve_compat(model::Model)
    detected = openai_completions_detect_compat(model)
    compat = model.compat
    compat === nothing && return detected
    return (;
        supportsStore = get(() -> detected.supportsStore, compat, "supportsStore"),
        supportsDeveloperRole = get(() -> detected.supportsDeveloperRole, compat, "supportsDeveloperRole"),
        supportsReasoningEffort = get(() -> detected.supportsReasoningEffort, compat, "supportsReasoningEffort"),
        supportsUsageInStreaming = get(() -> detected.supportsUsageInStreaming, compat, "supportsUsageInStreaming"),
        maxTokensField = get(() -> detected.maxTokensField, compat, "maxTokensField"),
        requiresToolResultName = get(() -> detected.requiresToolResultName, compat, "requiresToolResultName"),
        requiresAssistantAfterToolResult = get(() -> detected.requiresAssistantAfterToolResult, compat, "requiresAssistantAfterToolResult"),
        requiresThinkingAsText = get(() -> detected.requiresThinkingAsText, compat, "requiresThinkingAsText"),
        requiresMistralToolIds = get(() -> detected.requiresMistralToolIds, compat, "requiresMistralToolIds"),
        thinkingFormat = get(() -> detected.thinkingFormat, compat, "thinkingFormat"),
    )
end

function openai_completions_has_tool_history(messages::Vector{AgentMessage})
    for msg in messages
        if msg isa ToolResultMessage
            return true
        elseif msg isa AssistantMessage
            !isempty(msg.tool_calls) && return true
            for block in msg.content
                block isa ToolCallContent && return true
            end
        end
    end
    return false
end

function openai_completions_is_zai(model::Model)
    compat = openai_completions_resolve_compat(model)
    return compat.thinkingFormat == "zai"
end

function openai_completions_supports_reasoning_effort(model::Model)
    compat = openai_completions_resolve_compat(model)
    return compat.supportsReasoningEffort
end

function openai_completions_use_reasoning_split(model::Model)
    base_url = model.baseUrl
    return model.provider == "minimax" || occursin("minimax.io", base_url) || occursin("minimaxi.com", base_url)
end

function openai_completions_reasoning_details_from_signature(signature::Union{Nothing, String})
    signature === nothing && return nothing
    isempty(signature) && return nothing
    parsed = try
        JSON.parse(signature)
    catch
        nothing
    end
    return parsed isa AbstractVector ? parsed : nothing
end

function openai_completions_reasoning_details_from_blocks(blocks::Vector{ThinkingContent})
    signature = blocks[1].thinkingSignature
    parsed = openai_completions_reasoning_details_from_signature(signature)
    parsed !== nothing && return parsed
    text = join((b.thinking for b in blocks), "\n\n")
    return [Dict("text" => text)]
end

function openai_completions_reasoning_text(details)
    if details isa AbstractVector
        parts = String[]
        for item in details
            if item isa AbstractDict
                text = get(item, "text", nothing)
                text isa AbstractString && push!(parts, String(text))
            elseif item isa AbstractString
                push!(parts, String(item))
            end
        end
        return join(parts, "")
    elseif details isa AbstractDict
        text = get(details, "text", nothing)
        return text isa AbstractString ? String(text) : ""
    end
    return ""
end

function openai_completions_append_thinking_with_details!(assistant_message::AssistantMessage, details)
    text = openai_completions_reasoning_text(details)
    isempty(text) && return
    signature = JSON.json(details)
    if isempty(assistant_message.content) || !(assistant_message.content[end] isa ThinkingContent)
        push!(assistant_message.content, ThinkingContent(; thinking = text, thinkingSignature = signature))
    else
        block = assistant_message.content[end]
        block.thinking *= text
        block.thinkingSignature = signature
    end
    return
end

function openai_completions_build_tools(tools::Vector{AgentTool}; force_empty::Bool = false)
    isempty(tools) && return force_empty ? OpenAICompletions.Tool[] : nothing
    provider_tools = OpenAICompletions.Tool[]
    for tool in tools
        push!(
            provider_tools, OpenAICompletions.FunctionTool(
                var"function" = OpenAICompletions.ToolFunction(
                    name = tool.name,
                    description = tool.description,
                    parameters = OpenAICompletions.schema(parameters(tool)),
                    strict = tool.strict,
                )
            )
        )
    end
    return provider_tools
end

function openai_completions_tool_call_from_content(call::ToolCallContent)
    return OpenAICompletions.ToolCall(
        id = call.id,
        var"function" = OpenAICompletions.ToolCallFunction(
            name = call.name,
            arguments = JSON.json(call.arguments),
        )
    )
end

function openai_completions_build_messages(agent::Agent, state::AgentState, input::AgentTurnInput, model::Model)
    compat = openai_completions_resolve_compat(model)
    raw_messages = AgentMessage[]
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

    normalize_tool_call_id = function (id::String)
        if compat.requiresMistralToolIds
            return normalize_mistral_tool_id(id)
        end
        if model.provider == "openai"
            return length(id) > 40 ? id[1:40] : id
        end
        if model.provider == "github-copilot" && occursin("claude", lowercase(model.id))
            normalized = replace(id, r"[^A-Za-z0-9_-]" => "_")
            return normalized[1:min(length(normalized), 64)]
        end
        return id
    end

    messages = OpenAICompletions.Message[]
    system_prompt = agent_system_prompt(agent)
    if !isempty(system_prompt)
        role = model.reasoning && compat.supportsDeveloperRole ? "developer" : "system"
        push!(messages, OpenAICompletions.Message(; role, content = system_prompt))
    end

    transformed = transform_messages(raw_messages, model; normalize_tool_call_id = normalize_tool_call_id)
    last_role = nothing

    i = 1
    while i <= length(transformed)
        msg = transformed[i]
        if compat.requiresAssistantAfterToolResult && last_role == "toolResult" && msg isa UserMessage
            push!(messages, OpenAICompletions.Message(; role = "assistant", content = "I have processed the tool results."))
        end

        if msg isa CompactionSummaryMessage
            push!(messages, OpenAICompletions.Message(; role = "user", content = "[Previous conversation summary]\n\n$(msg.summary)"))
            last_role = "user"
            i += 1
            continue
        elseif msg isa UserMessage
            parts = OpenAICompletions.ContentPart[]
            for block in msg.content
                if block isa TextContent
                    push!(parts, OpenAICompletions.ContentPart(; type = "text", text = block.text))
                elseif block isa ImageContent
                    url = "data:$(block.mimeType);base64,$(block.data)"
                    push!(parts, OpenAICompletions.ContentPart(; type = "image_url", image_url = OpenAICompletions.ImageURL(; url)))
                end
            end
            if !("image" in model.input)
                parts = OpenAICompletions.ContentPart[part for part in parts if part.type != "image_url"]
            end
            isempty(parts) && continue
            push!(messages, OpenAICompletions.Message(; role = "user", content = parts))
            last_role = "user"
        elseif msg isa AssistantMessage
            assistant_msg = OpenAICompletions.Message(; role = "assistant", content = compat.requiresAssistantAfterToolResult ? "" : nothing)
            text_blocks = TextContent[]
            thinking_blocks = ThinkingContent[]
            tool_calls = ToolCallContent[]
            for block in msg.content
                block isa TextContent && push!(text_blocks, block)
                block isa ThinkingContent && push!(thinking_blocks, block)
                block isa ToolCallContent && push!(tool_calls, block)
            end
            if isempty(tool_calls) && !isempty(msg.tool_calls)
                for call in msg.tool_calls
                    push!(tool_calls, ToolCallContent(; id = call.call_id, name = call.name, arguments = parse_tool_arguments(call.arguments)))
                end
            end

            non_empty_text = [b for b in text_blocks if !isempty(strip(b.text))]
            if !isempty(non_empty_text)
                if model.provider == "github-copilot"
                    assistant_msg.content = join((b.text for b in non_empty_text), "")
                else
                    assistant_msg.content = OpenAICompletions.ContentPart[
                        OpenAICompletions.ContentPart(; type = "text", text = b.text) for b in non_empty_text
                    ]
                end
            end

            non_empty_thinking = [b for b in thinking_blocks if !isempty(strip(b.thinking))]
            if !isempty(non_empty_thinking)
                if openai_completions_use_reasoning_split(model)
                    assistant_msg.reasoning_details = openai_completions_reasoning_details_from_blocks(non_empty_thinking)
                elseif compat.requiresThinkingAsText
                    thinking_text = join((b.thinking for b in non_empty_thinking), "\n\n")
                    if assistant_msg.content === nothing || assistant_msg.content === ""
                        assistant_msg.content = OpenAICompletions.ContentPart[OpenAICompletions.ContentPart(; type = "text", text = thinking_text)]
                    elseif assistant_msg.content isa String
                        assistant_msg.content = thinking_text * assistant_msg.content
                    else
                        pushfirst!(assistant_msg.content, OpenAICompletions.ContentPart(; type = "text", text = thinking_text))
                    end
                else
                    signature = non_empty_thinking[1].thinkingSignature
                    if signature !== nothing && !isempty(signature)
                        extra = assistant_msg.extra === nothing ? Dict{String, Any}() : assistant_msg.extra
                        extra[signature] = join((b.thinking for b in non_empty_thinking), "\n")
                        assistant_msg.extra = extra
                    end
                end
            end

            if !isempty(tool_calls)
                assistant_msg.tool_calls = OpenAICompletions.ToolCall[openai_completions_tool_call_from_content(tc) for tc in tool_calls]
                reasoning_details = Any[]
                for tc in tool_calls
                    tc.thoughtSignature === nothing && continue
                    isempty(tc.thoughtSignature) && continue
                    try
                        push!(reasoning_details, JSON.parse(tc.thoughtSignature))
                    catch
                    end
                end
                isempty(reasoning_details) || (assistant_msg.reasoning_details = reasoning_details)
            end

            content = assistant_msg.content
            has_content = content !== nothing && !(content isa String && isempty(content)) && !(content isa Vector && isempty(content))
            has_extra = assistant_msg.extra !== nothing && !isempty(assistant_msg.extra)
            has_reasoning = assistant_msg.reasoning_details !== nothing
            if !has_content && assistant_msg.tool_calls === nothing && !has_extra && !has_reasoning
                continue
            end
            push!(messages, assistant_msg)
            last_role = "assistant"
            i += 1
            continue
        elseif msg isa ToolResultMessage
            image_blocks = OpenAICompletions.ContentPart[]
            j = i
            while j <= length(transformed) && transformed[j] isa ToolResultMessage
                tool_msg = transformed[j]::ToolResultMessage
                text_result = message_text(tool_msg)
                has_text = !isempty(text_result)
                tool_result_msg = OpenAICompletions.Message(;
                    role = "tool",
                    content = has_text ? text_result : "(see attached image)",
                    tool_call_id = tool_msg.call_id,
                )
                if compat.requiresToolResultName
                    tool_result_msg = OpenAICompletions.Message(;
                        role = "tool",
                        content = has_text ? text_result : "(see attached image)",
                        tool_call_id = tool_msg.call_id,
                        name = tool_msg.name,
                    )
                end
                push!(messages, tool_result_msg)

                for block in tool_msg.content
                    if block isa ImageContent && "image" in model.input
                        url = "data:$(block.mimeType);base64,$(block.data)"
                        push!(image_blocks, OpenAICompletions.ContentPart(; type = "image_url", image_url = OpenAICompletions.ImageURL(; url)))
                    end
                end
                j += 1
            end
            if !isempty(image_blocks)
                if compat.requiresAssistantAfterToolResult
                    push!(messages, OpenAICompletions.Message(; role = "assistant", content = "I have processed the tool results."))
                end
                push!(
                    messages,
                    OpenAICompletions.Message(;
                        role = "user",
                        content = OpenAICompletions.ContentPart[
                            OpenAICompletions.ContentPart(; type = "text", text = "Attached image(s) from tool result:"),
                            image_blocks...,
                        ],
                    ),
                )
                last_role = "user"
            else
                last_role = "toolResult"
            end
            i = j
            continue
        end
        i += 1
    end

    return messages, openai_completions_has_tool_history(raw_messages)
end

function openai_completions_usage_from_response(u::Union{Nothing, OpenAICompletions.Usage})
    u === nothing && return Usage()
    input = something(u.prompt_tokens, 0)
    output = something(u.completion_tokens, 0)
    total = something(u.total_tokens, input + output)
    return Usage(; input, output, total)
end

function openai_completions_stop_reason(reason::Union{Nothing, String}, tool_calls::Vector{AgentToolCall})
    if !isempty(tool_calls)
        return :tool_calls
    end
    if reason == "tool_calls" || reason == "function_call"
        return :tool_calls
    elseif reason == "length"
        return :length
    elseif reason == "stop"
        return :stop
    elseif reason == "content_filter"
        return :content_filter
    end
    return :stop
end

function openai_completions_event_callback(
        f::Function,
        assistant_message::AssistantMessage,
        started::Base.RefValue{Bool},
        ended::Base.RefValue{Bool},
        latest_usage::Base.RefValue{Union{Nothing, OpenAICompletions.Usage}},
        latest_finish::Base.RefValue{Union{Nothing, String}},
        tool_call_accumulators::Dict{Int, ToolCallAccumulator},
        abort::Abort,
    )
    reasoning_buffer = ""
    leading_whitespace = ""
    saw_text = false
    return function (stream, event)
        maybe_abort!(abort, stream)
        data = String(event.data)
        if toolcall_debug_enabled() && (occursin("tool_call", data) || occursin("tool_calls", data))
            toolcall_debug("openai-completions sse raw tool chunk"; preview = toolcall_preview(data, limit = 500))
        end
        if data == "[DONE]"
            if started[] && !ended[]
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end
            return
        end
        local chunk
        try
            chunk = JSON.parse(data, OpenAICompletions.StreamChunk)
        catch e
            f(AgentErrorEvent(ErrorException(sprint(showerror, e))))
            return
        end

        if chunk.id !== nothing
            assistant_message.response_id = chunk.id
        end
        chunk.usage !== nothing && (latest_usage[] = chunk.usage)
        isempty(chunk.choices) && return
        choice = chunk.choices[1]
        delta = choice.delta
        if delta.content !== nothing && !isempty(delta.content)
            content_str = delta.content
            if all(isspace, content_str)
                if !saw_text
                    leading_whitespace *= content_str
                    return
                end
            else
                if !isempty(leading_whitespace)
                    if !started[]
                        started[] = true
                        f(MessageStartEvent(:assistant, assistant_message))
                    end
                    append_text!(assistant_message, leading_whitespace)
                    f(MessageUpdateEvent(:assistant, assistant_message, :text, leading_whitespace, nothing))
                    leading_whitespace = ""
                    saw_text = true
                end
            end
            if !started[]
                started[] = true
                f(MessageStartEvent(:assistant, assistant_message))
            end
            append_text!(assistant_message, content_str)
            f(MessageUpdateEvent(:assistant, assistant_message, :text, content_str, nothing))
            saw_text = true
        end
        if delta.reasoning_details !== nothing
            if !started[]
                started[] = true
                f(MessageStartEvent(:assistant, assistant_message))
            end
            details = delta.reasoning_details
            details_vec = details isa AbstractVector ? details : Any[details]
            new_text_parts = String[]
            for detail in details_vec
                detail isa AbstractDict || continue
                text = get(detail, "text", nothing)
                text isa AbstractString || continue
                text_str = String(text)
                if startswith(text_str, reasoning_buffer)
                    if isempty(reasoning_buffer)
                        push!(new_text_parts, text_str)
                    else
                        start_idx = lastindex(reasoning_buffer) + 1
                        start_idx <= lastindex(text_str) && push!(new_text_parts, text_str[start_idx:end])
                    end
                else
                    push!(new_text_parts, text_str)
                end
                reasoning_buffer = text_str
            end
            new_text = join(new_text_parts, "")
            if !isempty(new_text)
                if isempty(assistant_message.content) || !(assistant_message.content[end] isa ThinkingContent)
                    push!(assistant_message.content, ThinkingContent(; thinking = new_text, thinkingSignature = JSON.json(details_vec)))
                else
                    block = assistant_message.content[end]
                    block.thinking *= new_text
                    block.thinkingSignature = JSON.json(details_vec)
                end
                f(MessageUpdateEvent(:assistant, assistant_message, :reasoning, new_text, nothing))
            elseif !isempty(assistant_message.content) && assistant_message.content[end] isa ThinkingContent
                assistant_message.content[end].thinkingSignature = JSON.json(details_vec)
            end
        end
        for field in (:reasoning_content, :reasoning, :reasoning_text)
            value = getfield(delta, field)
            if value !== nothing && !isempty(value)
                if !started[]
                    started[] = true
                    f(MessageStartEvent(:assistant, assistant_message))
                end
                append_thinking!(assistant_message, value)
                f(MessageUpdateEvent(:assistant, assistant_message, :reasoning, value, nothing))
            end
        end
        if delta.tool_calls !== nothing
            if !started[]
                started[] = true
                f(MessageStartEvent(:assistant, assistant_message))
            end
            for tool_delta in delta.tool_calls
                toolcall_debug(
                    "openai-completions tool delta";
                    index = tool_delta.index,
                    id = tool_delta.id,
                    name = tool_delta.function.name,
                    arg_chunk = toolcall_preview(tool_delta.function.arguments, limit = 200),
                )
                acc = get(
                    () -> ToolCallAccumulator(tool_delta.id, tool_delta.function.name, ""),
                    tool_call_accumulators,
                    tool_delta.index,
                )
                tool_call_accumulators[tool_delta.index] = acc
                tool_delta.id !== nothing && (acc.id = tool_delta.id)
                tool_delta.function.name !== nothing && (acc.name = tool_delta.function.name)
                if tool_delta.function.arguments !== nothing
                    acc.arguments *= tool_delta.function.arguments
                    toolcall_debug(
                        "openai-completions tool accumulator update";
                        index = tool_delta.index,
                        id = acc.id,
                        name = acc.name,
                        arg_length = length(acc.arguments),
                    )
                    f(MessageUpdateEvent(:assistant, assistant_message, :tool_arguments, tool_delta.function.arguments, acc.id))
                    if get(ENV, "AGENTIF_STOP_ON_TOOL_CALL", "") != "" && acc.name !== nothing && !isempty(acc.arguments)
                        try
                            parsed = JSON.parse(acc.arguments)
                            parsed isa AbstractDict || throw(ArgumentError("tool arguments not object"))
                            throw(StopStreaming("tool call arguments complete"))
                        catch
                        end
                    end
                end
            end
        end
        return choice.finish_reason !== nothing && (latest_finish[] = choice.finish_reason)
    end
end
