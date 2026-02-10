function google_gemini_cli_build_tools(tools::Vector{AgentTool})
    isempty(tools) && return nothing
    decls = GoogleGeminiCli.FunctionDeclaration[]
    for tool in tools
        push!(
            decls, GoogleGeminiCli.FunctionDeclaration(
                ; name = tool.name, description = tool.description, parameters = GoogleGeminiCli.schema(parameters(tool))
            )
        )
    end
    return [GoogleGeminiCli.Tool(; functionDeclarations = decls)]
end

function google_gemini_cli_build_contents(agent::Agent, state::AgentState, input::AgentTurnInput, model::Model)
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

    normalize_tool_call_id = id -> google_normalize_tool_call_id(model.id, id)
    normalized = transform_messages(context, model; normalize_tool_call_id = normalize_tool_call_id)

    contents = GoogleGeminiCli.Content[]
    for msg in normalized
        if msg isa CompactionSummaryMessage
            push!(contents, GoogleGeminiCli.Content(; role = "user", parts = [GoogleGeminiCli.Part(; text = "[Previous conversation summary]\n\n$(msg.summary)")]))
            continue
        elseif msg isa UserMessage
            parts = GoogleGeminiCli.Part[]
            for block in msg.content
                if block isa TextContent
                    isempty(strip(block.text)) && continue
                    push!(parts, GoogleGeminiCli.Part(; text = block.text))
                elseif block isa ImageContent
                    "image" in model.input || continue
                    push!(parts, GoogleGeminiCli.Part(; inlineData = GoogleGeminiCli.InlineData(; mimeType = block.mimeType, data = block.data)))
                end
            end
            isempty(parts) && continue
            push!(contents, GoogleGeminiCli.Content(; role = "user", parts))
        elseif msg isa AssistantMessage
            parts = GoogleGeminiCli.Part[]
            is_same = msg.provider == model.provider && msg.model == model.id
            blocks = copy(msg.content)
            if !any(b -> b isa ToolCallContent, blocks) && !isempty(msg.tool_calls)
                for call in msg.tool_calls
                    push!(blocks, ToolCallContent(; id = call.call_id, name = call.name, arguments = parse_tool_arguments(call.arguments)))
                end
            end
            for block in blocks
                if block isa TextContent
                    isempty(strip(block.text)) && continue
                    signature = google_resolve_thought_signature(is_same, block.textSignature)
                    push!(parts, GoogleGeminiCli.Part(; text = block.text, thoughtSignature = signature))
                elseif block isa ThinkingContent
                    isempty(strip(block.thinking)) && continue
                    if is_same
                        signature = google_resolve_thought_signature(is_same, block.thinkingSignature)
                        push!(parts, GoogleGeminiCli.Part(; text = block.thinking, thought = true, thoughtSignature = signature))
                    else
                        push!(parts, GoogleGeminiCli.Part(; text = block.thinking))
                    end
                elseif block isa ToolCallContent
                    signature = google_resolve_thought_signature(is_same, block.thoughtSignature)
                    is_gemini3 = occursin("gemini-3", lowercase(model.id))
                    if is_gemini3 && signature === nothing
                        args_str = JSON.json(block.arguments)
                        push!(
                            parts,
                            GoogleGeminiCli.Part(;
                                text = "[Historical context: a different model called tool \"$(block.name)\" with arguments: $(args_str). Do not mimic this format - use proper function calling.]",
                            ),
                        )
                    else
                        call = GoogleGeminiCli.FunctionCall(;
                            name = block.name,
                            args = block.arguments,
                            id = google_requires_tool_call_id(model.id) ? block.id : nothing,
                        )
                        push!(parts, GoogleGeminiCli.Part(; functionCall = call, thoughtSignature = signature))
                    end
                end
            end
            isempty(parts) && continue
            push!(contents, GoogleGeminiCli.Content(; role = "model", parts))
        elseif msg isa ToolResultMessage
            text_blocks = String[]
            image_blocks = ImageContent[]
            for block in msg.content
                if block isa TextContent
                    push!(text_blocks, block.text)
                elseif block isa ImageContent && "image" in model.input
                    push!(image_blocks, block)
                end
            end
            text_result = join(text_blocks, "\n")
            has_text = !isempty(text_result)
            has_images = !isempty(image_blocks)
            response_value = has_text ? text_result : (has_images ? "(see attached image)" : "")
            image_parts = GoogleGeminiCli.Part[
                GoogleGeminiCli.Part(; inlineData = GoogleGeminiCli.InlineData(; mimeType = block.mimeType, data = block.data)) for block in image_blocks
            ]
            include_id = google_requires_tool_call_id(model.id)
            supports_multimodal = google_supports_multimodal_function_response(model.id)
            response_payload = msg.is_error ? Dict("error" => response_value) : Dict("output" => response_value)
            response = GoogleGeminiCli.FunctionResponse(;
                id = include_id ? msg.call_id : nothing,
                name = msg.name,
                response = response_payload,
                parts = (has_images && supports_multimodal) ? image_parts : nothing,
            )
            part = GoogleGeminiCli.Part(; functionResponse = response)
            last_content = isempty(contents) ? nothing : contents[end]
            if last_content !== nothing && last_content.role == "user" && last_content.parts !== nothing &&
                    any(p -> p.functionResponse !== nothing, last_content.parts)
                push!(last_content.parts, part)
            else
                push!(contents, GoogleGeminiCli.Content(; role = "user", parts = [part]))
            end
            if has_images && !supports_multimodal
                push!(contents, GoogleGeminiCli.Content(; role = "user", parts = [GoogleGeminiCli.Part(; text = "Tool result image:"), image_parts...]))
            end
        end
    end
    return contents
end

function google_gemini_cli_usage_from_response(u::Union{Nothing, GoogleGeminiCli.UsageMetadata})
    u === nothing && return Usage()
    input = something(u.promptTokenCount, 0)
    candidates = something(u.candidatesTokenCount, 0)
    thoughts = something(u.thoughtsTokenCount, 0)
    output = candidates + thoughts
    total = something(u.totalTokenCount, input + output)
    cache_read = something(u.cachedContentTokenCount, 0)
    return Usage(; input, output, cacheRead = cache_read, total)
end

function google_gemini_cli_stop_reason(reason::Union{Nothing, String}, tool_calls::Vector{AgentToolCall})
    if !isempty(tool_calls)
        return :tool_calls
    end
    if reason == "STOP"
        return :stop
    elseif reason == "MAX_TOKENS"
        return :length
    elseif reason == "RECITATION"
        return :content_filter
    elseif reason == "SAFETY" || reason == "BLOCKLIST" || reason == "PROHIBITED_CONTENT"
        return :safety
    elseif reason == "OTHER"
        return :other
    end
    return :stop
end

function google_gemini_cli_event_callback(
        f::Function,
        agent::Agent,
        assistant_message::AssistantMessage,
        started::Base.RefValue{Bool},
        ended::Base.RefValue{Bool},
        latest_usage::Base.RefValue{Union{Nothing, GoogleGeminiCli.UsageMetadata}},
        latest_finish::Base.RefValue{Union{Nothing, String}},
        seen_call_ids::Set{String},
        debug_stream::Bool,
        abort::Abort,
    )
    return function (stream, event)
        maybe_abort!(abort, stream)
        data = String(event.data)
        debug_stream && @info "gemini-cli stream event" length = length(data)
        if data == "[DONE]"
            if started[] && !ended[]
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end
            return
        end
        local parsed
        try
            parsed = JSON.parse(data, GoogleGeminiCli.StreamChunk)
        catch e
            f(AgentErrorEvent(ErrorException(sprint(showerror, e))))
            return
        end

        response = parsed.response
        response === nothing && return
        response.responseId !== nothing && (assistant_message.response_id = response.responseId)
        response.usageMetadata !== nothing && (latest_usage[] = response.usageMetadata)
        response.candidates === nothing && return
        isempty(response.candidates) && return
        candidate = response.candidates[1]
        candidate.finishReason !== nothing && (latest_finish[] = candidate.finishReason)
        candidate.content === nothing && return
        candidate.content.parts === nothing && return

        function append_text_with_signature!(delta::String, signature::Union{Nothing, String})
            if isempty(assistant_message.content) || !(assistant_message.content[end] isa TextContent)
                push!(assistant_message.content, TextContent(; text = delta, textSignature = signature))
            else
                block = assistant_message.content[end]
                block.text *= delta
                if block.textSignature === nothing && signature !== nothing
                    block.textSignature = signature
                end
            end
        end

        function append_thinking_with_signature!(delta::String, signature::Union{Nothing, String})
            if isempty(assistant_message.content) || !(assistant_message.content[end] isa ThinkingContent)
                push!(assistant_message.content, ThinkingContent(; thinking = delta, thinkingSignature = signature))
            else
                block = assistant_message.content[end]
                block.thinking *= delta
                if block.thinkingSignature === nothing && signature !== nothing
                    block.thinkingSignature = signature
                end
            end
        end

        for part in candidate.content.parts
            if part.text !== nothing && part.thought === true
                if !started[]
                    started[] = true
                    f(MessageStartEvent(:assistant, assistant_message))
                end
                append_thinking_with_signature!(part.text, part.thoughtSignature)
                f(MessageUpdateEvent(:assistant, assistant_message, :reasoning, part.text, nothing))
            elseif part.text !== nothing
                if !started[]
                    started[] = true
                    f(MessageStartEvent(:assistant, assistant_message))
                end
                append_text_with_signature!(part.text, part.thoughtSignature)
                f(MessageUpdateEvent(:assistant, assistant_message, :text, part.text, nothing))
            elseif part.functionCall !== nothing
                if !started[]
                    started[] = true
                    f(MessageStartEvent(:assistant, assistant_message))
                end
                fc = part.functionCall
                fc.name === nothing && throw(ArgumentError("function call missing name"))
                call_id = fc.id === nothing ? new_call_id("gemini") : google_normalize_tool_call_id(assistant_message.model, fc.id)
                call_id in seen_call_ids && continue
                push!(seen_call_ids, call_id)
                args_json = fc.args === nothing ? "{}" : JSON.json(fc.args)
                call = AgentToolCall(; call_id = call_id, name = fc.name, arguments = args_json)
                push!(assistant_message.tool_calls, call)
                args_dict = fc.args isa AbstractDict ? Dict{String, Any}(fc.args) : Dict{String, Any}()
                push!(assistant_message.content, ToolCallContent(; id = call_id, name = fc.name, arguments = args_dict, thoughtSignature = part.thoughtSignature))
                findtool(agent.tools, call.name)
                ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                f(ToolCallRequestEvent(ptc))
            end
        end
        return
    end
end
