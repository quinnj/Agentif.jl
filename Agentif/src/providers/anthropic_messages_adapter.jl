function anthropic_build_tools(tools::Vector{AgentTool}, tool_name_map::Dict{String, String})
    isempty(tools) && return nothing
    provider_tools = AnthropicMessages.Tool[]
    for tool in tools
        tool_name = get(() -> tool.name, tool_name_map, tool.name)
        push!(
            provider_tools, AnthropicMessages.Tool(
                name = tool_name,
                description = tool.description,
                input_schema = AnthropicMessages.schema(parameters(tool)),
            )
        )
    end
    return provider_tools
end

const ANTHROPIC_TOOL_RESULT_PLACEHOLDER = "No result provided"

function anthropic_sanitize_tool_call_id(id::String)
    return replace(id, r"[^A-Za-z0-9_-]" => "_")
end

function anthropic_tool_result_content(blocks::Vector{ToolResultContentBlock})
    has_images = any(block -> block isa ImageContent, blocks)
    if !has_images
        parts = String[]
        for block in blocks
            block isa TextContent && push!(parts, block.text)
        end
        return join(parts, "\n")
    end
    content = AnthropicMessages.ToolResultContentBlock[]
    for block in blocks
        if block isa TextContent
            push!(content, AnthropicMessages.TextBlock(; text = block.text))
        elseif block isa ImageContent
            source = AnthropicMessages.ImageSource(; media_type = block.mimeType, data = block.data)
            push!(content, AnthropicMessages.ImageBlock(; source))
        end
    end
    has_text = any(block -> block isa AnthropicMessages.TextBlock, content)
    has_text || pushfirst!(content, AnthropicMessages.TextBlock(; text = "(see attached image)"))
    return content
end

function anthropic_tool_result_block(result::ToolResultMessage)
    return AnthropicMessages.ToolResultBlock(;
        tool_use_id = anthropic_sanitize_tool_call_id(result.call_id),
        content = anthropic_tool_result_content(result.content),
        is_error = result.is_error,
    )
end

function anthropic_insert_missing_tool_results(messages::Vector{AgentMessage})
    normalized = AgentMessage[]
    pending = ToolCallContent[]
    resolved = Set{String}()
    function flush_pending!()
        isempty(pending) && return
        for call in pending
            if !(call.id in resolved)
                @warn "Inserted synthetic tool_result for orphaned tool_use" tool_name = call.name call_id = call.id
                push!(
                    normalized, ToolResultMessage(call.id, call.name, ANTHROPIC_TOOL_RESULT_PLACEHOLDER; is_error = true)
                )
            end
        end
        empty!(pending)
        empty!(resolved)
        return
    end
    for msg in messages
        if msg isa AssistantMessage
            flush_pending!()
            push!(normalized, msg)
            if !isempty(msg.content)
                empty!(pending)
                empty!(resolved)
                for block in msg.content
                    block isa ToolCallContent && push!(pending, block)
                end
            end
        elseif msg isa ToolResultMessage
            !isempty(pending) && push!(resolved, msg.call_id)
            push!(normalized, msg)
        else
            flush_pending!()
            push!(normalized, msg)
        end
    end
    flush_pending!()
    return normalized
end

function anthropic_tool_name_maps(tools::Vector{AgentTool}, is_oauth::Bool)
    tool_name_map = Dict{String, String}()
    tool_name_reverse_map = Dict{String, String}()
    is_oauth || return tool_name_map, tool_name_reverse_map
    for tool in tools
        external = "agentif_" * tool.name
        tool_name_map[tool.name] = external
        tool_name_reverse_map[external] = tool.name
    end
    return tool_name_map, tool_name_reverse_map
end

function anthropic_external_tool_name(tool_name_map::Dict{String, String}, name::String)
    return get(() -> name, tool_name_map, name)
end

function anthropic_internal_tool_name(tool_name_reverse_map::Dict{String, String}, name::String)
    return get(() -> name, tool_name_reverse_map, name)
end

function anthropic_oauth_system_blocks(prompt::String)
    blocks = AnthropicMessages.TextBlock[]
    cache_control = AnthropicMessages.CacheControl(; type = "ephemeral")
    push!(blocks, AnthropicMessages.TextBlock(; text = "You are Claude Code, Anthropic's official CLI for Claude.", cache_control))
    isempty(prompt) || push!(blocks, AnthropicMessages.TextBlock(; text = prompt, cache_control))
    return blocks
end

function anthropic_message_from_agent(msg::AgentMessage, tool_name_map::Dict{String, String}, model::Model)
    if msg isa UserMessage
        blocks = AnthropicMessages.ContentBlock[]
        for block in msg.content
            if block isa TextContent
                isempty(strip(block.text)) && continue
                push!(blocks, AnthropicMessages.TextBlock(; text = block.text))
            elseif block isa ImageContent
                "image" in model.input || continue
                source = AnthropicMessages.ImageSource(; media_type = block.mimeType, data = block.data)
                push!(blocks, AnthropicMessages.ImageBlock(; source))
            end
        end
        isempty(blocks) && return nothing
        has_images = any(block -> block isa AnthropicMessages.ImageBlock, blocks)
        if !has_images
            text = join((b.text for b in blocks if b isa AnthropicMessages.TextBlock), "")
            isempty(strip(text)) && return nothing
            return AnthropicMessages.Message(; role = "user", content = text)
        end
        return AnthropicMessages.Message(; role = "user", content = blocks)
    elseif msg isa AssistantMessage
        blocks = AnthropicMessages.ContentBlock[]
        saw_tool_calls = false
        for block in msg.content
            if block isa TextContent
                isempty(strip(block.text)) && continue
                push!(blocks, AnthropicMessages.TextBlock(; text = block.text))
            elseif block isa ThinkingContent
                isempty(strip(block.thinking)) && continue
                if block.thinkingSignature === nothing || isempty(block.thinkingSignature)
                    push!(blocks, AnthropicMessages.TextBlock(; text = block.thinking))
                else
                    push!(blocks, AnthropicMessages.ThinkingBlock(; thinking = block.thinking, signature = block.thinkingSignature))
                end
            elseif block isa ToolCallContent
                saw_tool_calls = true
                call_id = anthropic_sanitize_tool_call_id(block.id)
                tool_name = anthropic_external_tool_name(tool_name_map, block.name)
                push!(blocks, AnthropicMessages.ToolUseBlock(; id = call_id, name = tool_name, input = block.arguments))
            end
        end
        if !saw_tool_calls && !isempty(msg.tool_calls)
            for call in msg.tool_calls
                call_id = anthropic_sanitize_tool_call_id(call.call_id)
                tool_name = anthropic_external_tool_name(tool_name_map, call.name)
                push!(blocks, AnthropicMessages.ToolUseBlock(; id = call_id, name = tool_name, input = parse_tool_arguments(call.arguments)))
            end
        end
        isempty(blocks) && return nothing
        return AnthropicMessages.Message(; role = "assistant", content = blocks)
    elseif msg isa ToolResultMessage
        block = anthropic_tool_result_block(msg)
        return AnthropicMessages.Message(; role = "user", content = AnthropicMessages.ContentBlock[block])
    end
    throw(ArgumentError("unsupported message: $(typeof(msg))"))
end

function anthropic_build_messages(agent::Agent, state::AgentState, input::AgentTurnInput, tool_name_map::Dict{String, String}, model::Model)
    context = AgentMessage[]
    for msg in state.messages
        include_in_context(msg) || continue
        push!(context, msg)
    end
    if input isa String
        push!(context, UserMessage(input))
    elseif input isa UserMessage
        push!(context, input)
    elseif input isa Vector{UserContentBlock}
        push!(context, UserMessage(input))
    elseif input isa Vector{ToolResultMessage}
        append!(context, input)
    end
    normalized = transform_messages(context, model; normalize_tool_call_id = anthropic_sanitize_tool_call_id)
    messages = AnthropicMessages.Message[]
    i = 1
    while i <= length(normalized)
        msg = normalized[i]
        if msg isa ToolResultMessage
            blocks = AnthropicMessages.ContentBlock[]
            while i <= length(normalized) && normalized[i] isa ToolResultMessage
                result = normalized[i]
                push!(blocks, anthropic_tool_result_block(result))
                i += 1
            end
            isempty(blocks) || push!(messages, AnthropicMessages.Message(; role = "user", content = blocks))
        else
            converted = anthropic_message_from_agent(msg, tool_name_map, model)
            converted === nothing || push!(messages, converted)
            i += 1
        end
    end
    return messages
end

function anthropic_usage_from_response(u::Union{Nothing, AnthropicMessages.Usage})
    u === nothing && return Usage()
    input = something(u.input_tokens, 0)
    output = something(u.output_tokens, 0)
    cache_write = something(u.cache_creation_input_tokens, 0)
    cache_read = something(u.cache_read_input_tokens, 0)
    total = input + output + cache_write + cache_read
    return Usage(; input, output, cacheRead = cache_read, cacheWrite = cache_write, total)
end

function anthropic_stop_reason(reason::Union{Nothing, String}, tool_calls::Vector{AgentToolCall})
    if !isempty(tool_calls)
        return :tool_calls
    end
    if reason == "tool_use"
        return :tool_calls
    elseif reason == "max_tokens"
        return :length
    elseif reason == "stop_sequence"
        return :stop
    elseif reason == "end_turn"
        return :stop
    end
    return :stop
end

function anthropic_event_callback(
        f::Function,
        agent::Agent,
        assistant_message::AssistantMessage,
        started::Base.RefValue{Bool},
        ended::Base.RefValue{Bool},
        stop_reason::Base.RefValue{Union{Nothing, String}},
        latest_usage::Base.RefValue{Union{Nothing, AnthropicMessages.Usage}},
        blocks_by_index::Dict{Int, AssistantContentBlock},
        partial_json_by_index::Dict{Int, String},
        tool_name_reverse_map::Dict{String, String},
        abort::Abort,
    )
    stop_on_tool_call = get(ENV, "AGENTIF_STOP_ON_TOOL_CALL", "") != ""
    return function (stream, event)
        maybe_abort!(abort, stream)
        local parsed
        try
            parsed = JSON.parse(String(event.data), AnthropicMessages.StreamEvent)
        catch e
            f(AgentErrorEvent(ErrorException(sprint(showerror, e))))
            return
        end

        return if parsed isa AnthropicMessages.StreamMessageStartEvent
            if parsed.message.id !== nothing
                assistant_message.response_id = parsed.message.id
            end
            parsed.message.stop_reason !== nothing && (stop_reason[] = parsed.message.stop_reason)
            if !started[]
                started[] = true
                f(MessageStartEvent(:assistant, assistant_message))
            end
        elseif parsed isa AnthropicMessages.StreamContentBlockStartEvent
            if parsed.content_block isa AnthropicMessages.TextBlock
                block = TextContent(; text = parsed.content_block.text)
                push!(assistant_message.content, block)
                blocks_by_index[parsed.index] = block
            elseif parsed.content_block isa AnthropicMessages.ThinkingBlock
                block = ThinkingContent(;
                    thinking = parsed.content_block.thinking,
                    thinkingSignature = parsed.content_block.signature,
                )
                push!(assistant_message.content, block)
                blocks_by_index[parsed.index] = block
            elseif parsed.content_block isa AnthropicMessages.ToolUseBlock
                tool_name = anthropic_internal_tool_name(tool_name_reverse_map, parsed.content_block.name)
                args = parsed.content_block.input isa AbstractDict ? Dict{String, Any}(parsed.content_block.input) : Dict{String, Any}()
                block = ToolCallContent(;
                    id = parsed.content_block.id,
                    name = tool_name,
                    arguments = args,
                )
                push!(assistant_message.content, block)
                blocks_by_index[parsed.index] = block
                partial_json_by_index[parsed.index] = ""
            end
        elseif parsed isa AnthropicMessages.StreamContentBlockDeltaEvent
            if parsed.delta isa AnthropicMessages.TextDelta
                block = get(() -> nothing, blocks_by_index, parsed.index)
                block isa TextContent || return
                block.text *= parsed.delta.text
                if !started[]
                    started[] = true
                    f(MessageStartEvent(:assistant, assistant_message))
                end
                f(MessageUpdateEvent(:assistant, assistant_message, :text, parsed.delta.text, nothing))
            elseif parsed.delta isa AnthropicMessages.ThinkingDelta
                block = get(() -> nothing, blocks_by_index, parsed.index)
                block isa ThinkingContent || return
                block.thinking *= parsed.delta.thinking
                if !started[]
                    started[] = true
                    f(MessageStartEvent(:assistant, assistant_message))
                end
                f(MessageUpdateEvent(:assistant, assistant_message, :reasoning, parsed.delta.thinking, nothing))
            elseif parsed.delta isa AnthropicMessages.SignatureDelta
                block = get(() -> nothing, blocks_by_index, parsed.index)
                block isa ThinkingContent || return
                sig = block.thinkingSignature === nothing ? "" : block.thinkingSignature
                block.thinkingSignature = sig * parsed.delta.signature
            elseif parsed.delta isa AnthropicMessages.InputJsonDelta
                block = get(() -> nothing, blocks_by_index, parsed.index)
                block isa ToolCallContent || return
                partial = get(() -> "", partial_json_by_index, parsed.index)
                partial *= parsed.delta.partial_json
                partial_json_by_index[parsed.index] = partial
                f(MessageUpdateEvent(:assistant, assistant_message, :tool_arguments, parsed.delta.partial_json, block.id))
            end
        elseif parsed isa AnthropicMessages.StreamContentBlockStopEvent
            block = get(() -> nothing, blocks_by_index, parsed.index)
            if block isa ToolCallContent
                partial = get(() -> "", partial_json_by_index, parsed.index)
                args = isempty(partial) ? (block.arguments isa AbstractDict ? block.arguments : Dict{String, Any}()) : parse_tool_arguments(partial)
                block.arguments = args
                call = AgentToolCall(; call_id = block.id, name = block.name, arguments = JSON.json(args))
                push!(assistant_message.tool_calls, call)
                findtool(agent.tools, call.name)
                ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                f(ToolCallRequestEvent(ptc))
                stop_on_tool_call && throw(StopStreaming("tool call arguments complete"))
            end
        elseif parsed isa AnthropicMessages.StreamMessageDeltaEvent
            parsed.usage !== nothing && (latest_usage[] = parsed.usage)
        elseif parsed isa AnthropicMessages.StreamMessageStopEvent
            if started[] && !ended[]
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end
        elseif parsed isa AnthropicMessages.StreamErrorEvent
            if started[] && !ended[]
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end
            f(AgentErrorEvent(ErrorException("anthropic stream error")))
        end
    end
end
