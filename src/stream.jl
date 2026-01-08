using HTTP
using JSON
using UUIDs

# Default HTTP.jl kwargs for retry behavior
const DEFAULT_HTTP_KW = (;
    retry = true,
    retries = 5,
    retry_non_idempotent = true,  # Retry POST requests
)

mutable struct ToolCallAccumulator
    id::Union{Nothing,String}
    name::Union{Nothing,String}
    arguments::String
end

new_call_id(prefix::String) = string(prefix, "-", UUIDs.uuid4())

function parse_tool_arguments(arguments::String)
    try
        return JSON.parse(arguments)
    catch
        return Dict{String,Any}()
    end
end

function openai_responses_build_tools(tools::Vector{AgentTool})
    isempty(tools) && return nothing
    provider_tools = OpenAIResponses.Tool[]
    for tool in tools
        push!(provider_tools, OpenAIResponses.FunctionTool(
            name=tool.name,
            description=tool.description,
            strict=tool.strict,
            parameters=OpenAIResponses.schema(parameters(tool)),
        ))
    end
    return provider_tools
end

function openai_responses_build_input(input::AgentTurnInput)
    if input isa String
        return input
    elseif input isa Vector{ToolResultMessage}
        outputs = OpenAIResponses.FunctionToolCallOutput[]
        for result in input
            push!(outputs, OpenAIResponses.FunctionToolCallOutput(; call_id=result.call_id, output=result.output))
        end
        return OpenAIResponses.InputItem[outputs...]
    end
    throw(ArgumentError("unsupported turn input: $(typeof(input))"))
end

function openai_responses_usage_from_response(u::Union{Nothing,OpenAIResponses.Usage})
    u === nothing && return Usage()
    input = something(u.input_tokens, 0)
    output = something(u.output_tokens, 0)
    total = something(u.total_tokens, input + output)
    cached = 0
    if u.input_tokens_details !== nothing
        cached = something(u.input_tokens_details.cached_tokens, 0)
    end
    return Usage(; input, output, cacheRead=cached, total)
end

function openai_responses_stop_reason(status::Union{Nothing,String}, tool_calls::Vector{AgentToolCall})
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

function openai_completions_supports_reasoning_effort(model::Model)
    return !occursin("api.x.ai", model.baseUrl)
end

function openai_completions_build_tools(tools::Vector{AgentTool})
    isempty(tools) && return nothing
    provider_tools = OpenAICompletions.Tool[]
    for tool in tools
        push!(provider_tools, OpenAICompletions.FunctionTool(
            var"function"=OpenAICompletions.ToolFunction(
                name=tool.name,
                description=tool.description,
                parameters=OpenAICompletions.schema(parameters(tool)),
                strict=tool.strict,
            )
        ))
    end
    return provider_tools
end

function openai_completions_tool_call_from_agent(call::AgentToolCall)
    return OpenAICompletions.ToolCall(
        id=call.call_id,
        var"function"=OpenAICompletions.ToolCallFunction(
            name=call.name,
            arguments=call.arguments,
        )
    )
end

function openai_completions_message_from_agent(msg::AgentMessage)
    if msg isa UserMessage
        return OpenAICompletions.Message(; role="user", content=msg.text)
    elseif msg isa AssistantMessage
        content = isempty(msg.text) ? nothing : msg.text
        tool_calls = isempty(msg.tool_calls) ? nothing : OpenAICompletions.ToolCall[
            openai_completions_tool_call_from_agent(tc) for tc in msg.tool_calls
        ]
        kwargs = (; role="assistant", content, tool_calls)
        if !isempty(msg.reasoning)
            kwargs = (; kwargs..., reasoning=msg.reasoning)
        end
        return OpenAICompletions.Message(; kwargs...)
    elseif msg isa ToolResultMessage
        return OpenAICompletions.Message(;
            role="tool",
            content=msg.output,
            tool_call_id=msg.call_id,
            name=msg.name,
        )
    end
    throw(ArgumentError("unsupported message: $(typeof(msg))"))
end

function openai_completions_build_messages(agent::Agent, state::AgentState, input::AgentTurnInput)
    messages = OpenAICompletions.Message[]
    push!(messages, OpenAICompletions.Message(; role="system", content=agent.prompt))
    for msg in state.messages
        include_in_context(msg) || continue
        push!(messages, openai_completions_message_from_agent(msg))
    end
    if input isa String
        push!(messages, OpenAICompletions.Message(; role="user", content=input))
    elseif input isa Vector{ToolResultMessage}
        for result in input
            push!(messages, OpenAICompletions.Message(; role="tool", content=result.output, tool_call_id=result.call_id))
        end
    end
    return messages
end

function openai_completions_usage_from_response(u::Union{Nothing,OpenAICompletions.Usage})
    u === nothing && return Usage()
    input = something(u.prompt_tokens, 0)
    output = something(u.completion_tokens, 0)
    total = something(u.total_tokens, input + output)
    return Usage(; input, output, total)
end

function openai_completions_stop_reason(reason::Union{Nothing,String}, tool_calls::Vector{AgentToolCall})
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
        latest_usage::Base.RefValue{Union{Nothing,OpenAICompletions.Usage}},
        latest_finish::Base.RefValue{Union{Nothing,String}},
        tool_call_accumulators::Dict{Int,ToolCallAccumulator},
    )
    return function (http_stream, event::HTTP.SSEEvent)
        data = String(event.data)
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
        if delta.content !== nothing
            if !started[]
                started[] = true
                f(MessageStartEvent(:assistant, assistant_message))
            end
            assistant_message.text *= delta.content
            f(MessageUpdateEvent(:assistant, assistant_message, :text, delta.content, nothing))
        end
        for field in (:reasoning_content, :reasoning, :reasoning_text)
            value = getfield(delta, field)
            if value !== nothing && !isempty(value)
                if !started[]
                    started[] = true
                    f(MessageStartEvent(:assistant, assistant_message))
                end
                assistant_message.reasoning *= value
                f(MessageUpdateEvent(:assistant, assistant_message, :reasoning, value, nothing))
            end
        end
        if delta.tool_calls !== nothing
            if !started[]
                started[] = true
                f(MessageStartEvent(:assistant, assistant_message))
            end
            for tool_delta in delta.tool_calls
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
                    f(MessageUpdateEvent(:assistant, assistant_message, :tool_arguments, tool_delta.function.arguments, acc.id))
                end
            end
        end
        choice.finish_reason !== nothing && (latest_finish[] = choice.finish_reason)
    end
end

function anthropic_build_tools(tools::Vector{AgentTool})
    isempty(tools) && return nothing
    provider_tools = AnthropicMessages.Tool[]
    for tool in tools
        push!(provider_tools, AnthropicMessages.Tool(
            name=tool.name,
            description=tool.description,
            input_schema=AnthropicMessages.schema(parameters(tool)),
        ))
    end
    return provider_tools
end

function anthropic_message_from_agent(msg::AgentMessage)
    if msg isa UserMessage
        return AnthropicMessages.Message(; role="user", content=msg.text)
    elseif msg isa AssistantMessage
        has_tool_calls = !isempty(msg.tool_calls)
        has_text = !isempty(msg.text)
        if !has_tool_calls
            return AnthropicMessages.Message(; role="assistant", content=msg.text)
        end
        blocks = AnthropicMessages.ContentBlock[]
        if has_text
            push!(blocks, AnthropicMessages.TextBlock(; text=msg.text))
        end
        for call in msg.tool_calls
            args = parse_tool_arguments(call.arguments)
            push!(blocks, AnthropicMessages.ToolUseBlock(; id=call.call_id, name=call.name, input=args))
        end
        return AnthropicMessages.Message(; role="assistant", content=blocks)
    elseif msg isa ToolResultMessage
        block = AnthropicMessages.ToolResultBlock(;
            tool_use_id=msg.call_id,
            content=msg.output,
            is_error=msg.is_error,
        )
        return AnthropicMessages.Message(; role="user", content=AnthropicMessages.ContentBlock[block])
    end
    throw(ArgumentError("unsupported message: $(typeof(msg))"))
end

function anthropic_build_messages(agent::Agent, state::AgentState, input::AgentTurnInput)
    messages = AnthropicMessages.Message[]
    for msg in state.messages
        include_in_context(msg) || continue
        push!(messages, anthropic_message_from_agent(msg))
    end
    if input isa String
        push!(messages, AnthropicMessages.Message(; role="user", content=input))
    elseif input isa Vector{ToolResultMessage}
        blocks = AnthropicMessages.ContentBlock[]
        for result in input
            push!(blocks, AnthropicMessages.ToolResultBlock(
                ; tool_use_id=result.call_id, content=result.output, is_error=result.is_error
            ))
        end
        if !isempty(blocks)
            push!(messages, AnthropicMessages.Message(; role="user", content=blocks))
        end
    end
    return messages
end

function anthropic_usage_from_response(u::Union{Nothing,AnthropicMessages.Usage})
    u === nothing && return Usage()
    input = something(u.input_tokens, 0)
    output = something(u.output_tokens, 0)
    cache_write = something(u.cache_creation_input_tokens, 0)
    cache_read = something(u.cache_read_input_tokens, 0)
    total = input + output + cache_write + cache_read
    return Usage(; input, output, cacheRead=cache_read, cacheWrite=cache_write, total)
end

function anthropic_stop_reason(reason::Union{Nothing,String}, tool_calls::Vector{AgentToolCall})
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
        stop_reason::Base.RefValue{Union{Nothing,String}},
        latest_usage::Base.RefValue{Union{Nothing,AnthropicMessages.Usage}},
        blocks_by_index::Dict{Int,AnthropicMessages.ContentBlock},
        partial_json_by_index::Dict{Int,String},
    )
    return function (http_stream, event::HTTP.SSEEvent)
        local parsed
        try
            parsed = JSON.parse(String(event.data), AnthropicMessages.StreamEvent)
        catch e
            f(AgentErrorEvent(ErrorException(sprint(showerror, e))))
            return
        end

        if parsed isa AnthropicMessages.StreamMessageStartEvent
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
                block = AnthropicMessages.TextBlock(; text=parsed.content_block.text)
                blocks_by_index[parsed.index] = block
            elseif parsed.content_block isa AnthropicMessages.ToolUseBlock
                block = parsed.content_block
                blocks_by_index[parsed.index] = block
                partial_json_by_index[parsed.index] = ""
            end
        elseif parsed isa AnthropicMessages.StreamContentBlockDeltaEvent
            if parsed.delta isa AnthropicMessages.TextDelta
                block = get(() -> nothing, blocks_by_index, parsed.index)
                block isa AnthropicMessages.TextBlock || return
                block.text *= parsed.delta.text
                if !started[]
                    started[] = true
                    f(MessageStartEvent(:assistant, assistant_message))
                end
                assistant_message.text *= parsed.delta.text
                f(MessageUpdateEvent(:assistant, assistant_message, :text, parsed.delta.text, nothing))
            elseif parsed.delta isa AnthropicMessages.InputJsonDelta
                block = get(() -> nothing, blocks_by_index, parsed.index)
                block isa AnthropicMessages.ToolUseBlock || return
                partial = get(() -> "", partial_json_by_index, parsed.index)
                partial *= parsed.delta.partial_json
                partial_json_by_index[parsed.index] = partial
                f(MessageUpdateEvent(:assistant, assistant_message, :tool_arguments, parsed.delta.partial_json, block.id))
            end
        elseif parsed isa AnthropicMessages.StreamContentBlockStopEvent
            block = get(() -> nothing, blocks_by_index, parsed.index)
            if block isa AnthropicMessages.ToolUseBlock
                partial = get(() -> "", partial_json_by_index, parsed.index)
                args_json = isempty(partial) ? "{}" : partial
                args = parse_tool_arguments(args_json)
                call = AgentToolCall(; call_id=block.id, name=block.name, arguments=JSON.json(args))
                push!(assistant_message.tool_calls, call)
                tool = findtool(agent.tools, call.name)
                ptc = PendingToolCall(; call_id=call.call_id, name=call.name, arguments=call.arguments)
                f(ToolCallRequestEvent(ptc, tool.requires_approval))
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

function google_generative_build_tools(tools::Vector{AgentTool})
    isempty(tools) && return nothing
    decls = GoogleGenerativeAI.FunctionDeclaration[]
    for tool in tools
        push!(decls, GoogleGenerativeAI.FunctionDeclaration(
            ; name=tool.name, description=tool.description, parameters=GoogleGenerativeAI.schema(parameters(tool))
        ))
    end
    return [GoogleGenerativeAI.Tool(; functionDeclarations=decls)]
end

function google_generative_message_from_agent(msg::AgentMessage)
    if msg isa UserMessage
        return GoogleGenerativeAI.Content(; role="user", parts=[GoogleGenerativeAI.Part(; text=msg.text)])
    elseif msg isa AssistantMessage
        parts = GoogleGenerativeAI.Part[]
        if !isempty(msg.text)
            push!(parts, GoogleGenerativeAI.Part(; text=msg.text))
        end
        for call in msg.tool_calls
            args = parse_tool_arguments(call.arguments)
            push!(parts, GoogleGenerativeAI.Part(
                ; functionCall=GoogleGenerativeAI.FunctionCall(; id=call.call_id, name=call.name, args)
            ))
        end
        return GoogleGenerativeAI.Content(; role="model", parts)
    elseif msg isa ToolResultMessage
        response_payload = msg.is_error ? Dict("error" => msg.output) : Dict("result" => msg.output)
        part = GoogleGenerativeAI.Part(;
            functionResponse=GoogleGenerativeAI.FunctionResponse(; name=msg.name, response=response_payload),
        )
        return GoogleGenerativeAI.Content(; role="user", parts=[part])
    end
    throw(ArgumentError("unsupported message: $(typeof(msg))"))
end

function google_generative_build_contents(agent::Agent, state::AgentState, input::AgentTurnInput)
    contents = GoogleGenerativeAI.Content[]
    for msg in state.messages
        include_in_context(msg) || continue
        push!(contents, google_generative_message_from_agent(msg))
    end
    if input isa String
        push!(contents, GoogleGenerativeAI.Content(; role="user", parts=[GoogleGenerativeAI.Part(; text=input)]))
    elseif input isa Vector{ToolResultMessage}
        parts = GoogleGenerativeAI.Part[]
        for result in input
            response_payload = result.is_error ? Dict("error" => result.output) : Dict("result" => result.output)
            push!(parts, GoogleGenerativeAI.Part(
                ; functionResponse=GoogleGenerativeAI.FunctionResponse(; name=result.name, response=response_payload)
            ))
        end
        if !isempty(parts)
            push!(contents, GoogleGenerativeAI.Content(; role="user", parts))
        end
    end
    return contents
end

function google_generative_usage_from_response(u::Union{Nothing,GoogleGenerativeAI.UsageMetadata})
    u === nothing && return Usage()
    input = something(u.promptTokenCount, 0)
    output = something(u.candidatesTokenCount, 0)
    total = something(u.totalTokenCount, input + output)
    return Usage(; input, output, total)
end

function google_generative_stop_reason(reason::Union{Nothing,String}, tool_calls::Vector{AgentToolCall})
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

function google_generative_event_callback(
        f::Function,
        agent::Agent,
        assistant_message::AssistantMessage,
        started::Base.RefValue{Bool},
        ended::Base.RefValue{Bool},
        latest_usage::Base.RefValue{Union{Nothing,GoogleGenerativeAI.UsageMetadata}},
        latest_finish::Base.RefValue{Union{Nothing,String}},
        seen_call_ids::Set{String},
    )
    return function (http_stream, event::HTTP.SSEEvent)
        data = String(event.data)
        if data == "[DONE]"
            if started[] && !ended[]
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end
            return
        end
        local parsed
        try
            parsed = JSON.parse(data, GoogleGenerativeAI.GenerateContentResponse)
        catch e
            f(AgentErrorEvent(ErrorException(sprint(showerror, e))))
            return
        end

        if parsed.responseId !== nothing
            assistant_message.response_id = parsed.responseId
        end
        parsed.usageMetadata !== nothing && (latest_usage[] = parsed.usageMetadata)
        parsed.candidates === nothing && return
        isempty(parsed.candidates) && return
        candidate = parsed.candidates[1]
        candidate.finishReason !== nothing && (latest_finish[] = candidate.finishReason)
        candidate.content === nothing && return
        candidate.content.parts === nothing && return
        for part in candidate.content.parts
            if part.text !== nothing
                if !started[]
                    started[] = true
                    f(MessageStartEvent(:assistant, assistant_message))
                end
                assistant_message.text *= part.text
                f(MessageUpdateEvent(:assistant, assistant_message, :text, part.text, nothing))
            elseif part.functionCall !== nothing
                if !started[]
                    started[] = true
                    f(MessageStartEvent(:assistant, assistant_message))
                end
                fc = part.functionCall
                fc.name === nothing && throw(ArgumentError("function call missing name"))
                call_id = fc.id === nothing ? new_call_id("gemini") : fc.id
                call_id in seen_call_ids && continue
                push!(seen_call_ids, call_id)
                args_json = fc.args === nothing ? "{}" : JSON.json(fc.args)
                call = AgentToolCall(; call_id=call_id, name=fc.name, arguments=args_json)
                push!(assistant_message.tool_calls, call)
                tool = findtool(agent.tools, call.name)
                ptc = PendingToolCall(; call_id=call.call_id, name=call.name, arguments=call.arguments)
                f(ToolCallRequestEvent(ptc, tool.requires_approval))
            end
        end
    end
end

function google_gemini_cli_build_tools(tools::Vector{AgentTool})
    isempty(tools) && return nothing
    decls = GoogleGeminiCli.FunctionDeclaration[]
    for tool in tools
        push!(decls, GoogleGeminiCli.FunctionDeclaration(
            ; name=tool.name, description=tool.description, parameters=GoogleGeminiCli.schema(parameters(tool))
        ))
    end
    return [GoogleGeminiCli.Tool(; functionDeclarations=decls)]
end

function google_gemini_cli_message_from_agent(msg::AgentMessage)
    if msg isa UserMessage
        return GoogleGeminiCli.Content(; role="user", parts=[GoogleGeminiCli.Part(; text=msg.text)])
    elseif msg isa AssistantMessage
        parts = GoogleGeminiCli.Part[]
        if !isempty(msg.reasoning)
            push!(parts, GoogleGeminiCli.Part(; text=msg.reasoning, thought=true))
        end
        if !isempty(msg.text)
            push!(parts, GoogleGeminiCli.Part(; text=msg.text))
        end
        for call in msg.tool_calls
            args = parse_tool_arguments(call.arguments)
            push!(parts, GoogleGeminiCli.Part(
                ; functionCall=GoogleGeminiCli.FunctionCall(; id=call.call_id, name=call.name, args)
            ))
        end
        return GoogleGeminiCli.Content(; role="model", parts)
    elseif msg isa ToolResultMessage
        response_payload = msg.is_error ? Dict("error" => msg.output) : Dict("output" => msg.output)
        part = GoogleGeminiCli.Part(;
            functionResponse=GoogleGeminiCli.FunctionResponse(;
                id=msg.call_id,
                name=msg.name,
                response=response_payload,
            ),
        )
        return GoogleGeminiCli.Content(; role="user", parts=[part])
    end
    throw(ArgumentError("unsupported message: $(typeof(msg))"))
end

function google_gemini_cli_build_contents(agent::Agent, state::AgentState, input::AgentTurnInput)
    contents = GoogleGeminiCli.Content[]
    for msg in state.messages
        include_in_context(msg) || continue
        push!(contents, google_gemini_cli_message_from_agent(msg))
    end
    if input isa String
        push!(contents, GoogleGeminiCli.Content(; role="user", parts=[GoogleGeminiCli.Part(; text=input)]))
    elseif input isa Vector{ToolResultMessage}
        parts = GoogleGeminiCli.Part[]
        for result in input
            response_payload = result.is_error ? Dict("error" => result.output) : Dict("output" => result.output)
            push!(parts, GoogleGeminiCli.Part(
                ; functionResponse=GoogleGeminiCli.FunctionResponse(; id=result.call_id, name=result.name, response=response_payload)
            ))
        end
        if !isempty(parts)
            push!(contents, GoogleGeminiCli.Content(; role="user", parts))
        end
    end
    return contents
end

function google_gemini_cli_usage_from_response(u::Union{Nothing,GoogleGeminiCli.UsageMetadata})
    u === nothing && return Usage()
    input = something(u.promptTokenCount, 0)
    candidates = something(u.candidatesTokenCount, 0)
    thoughts = something(u.thoughtsTokenCount, 0)
    output = candidates + thoughts
    total = something(u.totalTokenCount, input + output)
    cache_read = something(u.cachedContentTokenCount, 0)
    return Usage(; input, output, cacheRead=cache_read, total)
end

function google_gemini_cli_stop_reason(reason::Union{Nothing,String}, tool_calls::Vector{AgentToolCall})
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
        latest_usage::Base.RefValue{Union{Nothing,GoogleGeminiCli.UsageMetadata}},
        latest_finish::Base.RefValue{Union{Nothing,String}},
        seen_call_ids::Set{String},
        debug_stream::Bool,
    )
    return function (http_stream, event::HTTP.SSEEvent)
        data = String(event.data)
        debug_stream && @info "gemini-cli stream event" length=length(data)
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
        for part in candidate.content.parts
            if part.text !== nothing && part.thought === true
                if !started[]
                    started[] = true
                    f(MessageStartEvent(:assistant, assistant_message))
                end
                assistant_message.reasoning *= part.text
                f(MessageUpdateEvent(:assistant, assistant_message, :reasoning, part.text, nothing))
            elseif part.text !== nothing
                if !started[]
                    started[] = true
                    f(MessageStartEvent(:assistant, assistant_message))
                end
                assistant_message.text *= part.text
                f(MessageUpdateEvent(:assistant, assistant_message, :text, part.text, nothing))
            elseif part.functionCall !== nothing
                if !started[]
                    started[] = true
                    f(MessageStartEvent(:assistant, assistant_message))
                end
                fc = part.functionCall
                fc.name === nothing && throw(ArgumentError("function call missing name"))
                call_id = fc.id === nothing ? new_call_id("gemini") : fc.id
                call_id in seen_call_ids && continue
                push!(seen_call_ids, call_id)
                args_json = fc.args === nothing ? "{}" : JSON.json(fc.args)
                call = AgentToolCall(; call_id=call_id, name=fc.name, arguments=args_json)
                push!(assistant_message.tool_calls, call)
                tool = findtool(agent.tools, call.name)
                ptc = PendingToolCall(; call_id=call.call_id, name=call.name, arguments=call.arguments)
                f(ToolCallRequestEvent(ptc, tool.requires_approval))
            end
        end
    end
end

function stream(f::Function, agent::Agent, state::AgentState, input::AgentTurnInput, apikey::String;
        model::Union{Nothing,Model}=nothing, http_kw=(;), kw...)
    model = model === nothing ? agent.model : model
    model === nothing && throw(ArgumentError("no model specified with which agent can evaluate input"))

    # Merge HTTP kwargs: defaults < agent.http_kw < per-call http_kw
    merged_http_kw = merge(DEFAULT_HTTP_KW, NamedTuple(agent.http_kw), NamedTuple(http_kw))

    if model.api == "openai-responses"
        tools = openai_responses_build_tools(agent.tools)
        current_input = openai_responses_build_input(input)
        assistant_message = AssistantMessage(; response_id=state.response_id)
        started = Ref(false)
        ended = Ref(false)
        response_usage = Ref{Union{Nothing,OpenAIResponses.Usage}}(nothing)
        response_status = Ref{Union{Nothing,String}}(nothing)

        stream_kw = haskey(kw, :instructions) ? Base.structdiff(kw, (; instructions=nothing)) : kw
        request_kw = merge(
            (; tools, previous_response_id=state.response_id, instructions=agent.prompt),
            stream_kw,
        )
        req = OpenAIResponses.Request(
            ; model=model.id,
            input=current_input,
            stream=true,
            model.kw...,
            request_kw...,
        )
        headers = Dict(
            "Authorization" => "Bearer $apikey",
            "Content-Type" => "application/json",
        )
        model.headers !== nothing && merge!(headers, model.headers)
        url = joinpath(model.baseUrl, "responses")
        HTTP.post(
            url,
            headers;
            body=JSON.json(req),
            sse_callback=openai_responses_event_callback(
                f,
                agent,
                assistant_message,
                started,
                ended,
                response_usage,
                response_status,
            ),
            merged_http_kw...,
        )

        if started[] && !ended[]
            ended[] = true
            f(MessageEndEvent(:assistant, assistant_message))
        end

        usage = openai_responses_usage_from_response(response_usage[])
        stop_reason = openai_responses_stop_reason(response_status[], assistant_message.tool_calls)
        return AgentResponse(; message=assistant_message, usage, stop_reason)
    elseif model.api == "openai-completions"
        tools = openai_completions_build_tools(agent.tools)
        messages = openai_completions_build_messages(agent, state, input)
        assistant_message = AssistantMessage(; response_id=state.response_id)
        started = Ref(false)
        ended = Ref(false)
        latest_usage = Ref{Union{Nothing,OpenAICompletions.Usage}}(nothing)
        latest_finish = Ref{Union{Nothing,String}}(nothing)
        tool_call_accumulators = Dict{Int,ToolCallAccumulator}()

        stream_kw = haskey(kw, :instructions) ? Base.structdiff(kw, (; instructions=nothing)) : kw
        if haskey(stream_kw, :reasoning)
            reasoning_effort = stream_kw[:reasoning]
            stream_kw = Base.structdiff(stream_kw, (; reasoning=nothing))
            if !haskey(stream_kw, :reasoning_effort)
                stream_kw = (; stream_kw..., reasoning_effort=reasoning_effort)
            end
        end
        if haskey(stream_kw, :reasoning_effort) && !openai_completions_supports_reasoning_effort(model)
            stream_kw = Base.structdiff(stream_kw, (; reasoning_effort=nothing))
        end

        request_kw = merge((; tools), stream_kw)
        req = OpenAICompletions.Request(
            ; model=model.id,
            messages,
            stream=true,
            model.kw...,
            request_kw...,
        )
        headers = Dict(
            "Authorization" => "Bearer $apikey",
            "Content-Type" => "application/json",
        )
        model.headers !== nothing && merge!(headers, model.headers)
        url = joinpath(model.baseUrl, "chat", "completions")
        HTTP.post(
            url,
            headers;
            body=JSON.json(req),
            sse_callback=openai_completions_event_callback(
                f,
                assistant_message,
                started,
                ended,
                latest_usage,
                latest_finish,
                tool_call_accumulators,
            ),
            merged_http_kw...,
        )

        if started[] && !ended[]
            ended[] = true
            f(MessageEndEvent(:assistant, assistant_message))
        end

        for idx in sort(collect(keys(tool_call_accumulators)))
            acc = tool_call_accumulators[idx]
            acc.name === nothing && throw(ArgumentError("tool call missing name for index $(idx)"))
            call_id = acc.id === nothing ? new_call_id("openai") : acc.id
            args = isempty(acc.arguments) ? "{}" : acc.arguments
            call = AgentToolCall(; call_id, name=acc.name, arguments=args)
            push!(assistant_message.tool_calls, call)
            tool = findtool(agent.tools, call.name)
            ptc = PendingToolCall(; call_id=call.call_id, name=call.name, arguments=call.arguments)
            f(ToolCallRequestEvent(ptc, tool.requires_approval))
        end

        usage = openai_completions_usage_from_response(latest_usage[])
        stop_reason = openai_completions_stop_reason(latest_finish[], assistant_message.tool_calls)
        return AgentResponse(; message=assistant_message, usage, stop_reason)
    elseif model.api == "anthropic-messages"
        tools = anthropic_build_tools(agent.tools)
        messages = anthropic_build_messages(agent, state, input)
        assistant_message = AssistantMessage(; response_id=state.response_id)
        started = Ref(false)
        ended = Ref(false)
        stop_reason = Ref{Union{Nothing,String}}(nothing)
        latest_usage = Ref{Union{Nothing,AnthropicMessages.Usage}}(nothing)
        blocks_by_index = Dict{Int,AnthropicMessages.ContentBlock}()
        partial_json_by_index = Dict{Int,String}()

        max_tokens = haskey(kw, :max_tokens) ? kw[:max_tokens] : model.maxTokens
        stream_kw = haskey(kw, :max_tokens) ? Base.structdiff(kw, (; max_tokens=0)) : kw
        stream_kw = haskey(stream_kw, :system) ? Base.structdiff(stream_kw, (; system=nothing)) : stream_kw

        request_kw = merge((; tools, system=agent.prompt), stream_kw)
        req = AnthropicMessages.Request(
            ; model=model.id,
            messages,
            max_tokens,
            stream=true,
            model.kw...,
            request_kw...,
        )
        headers = Dict(
            "x-api-key" => apikey,
            "anthropic-version" => "2023-06-01",
            "Content-Type" => "application/json",
        )
        model.headers !== nothing && merge!(headers, model.headers)
        url = joinpath(model.baseUrl, "v1", "messages")
        HTTP.post(
            url,
            headers;
            body=JSON.json(req),
            sse_callback=anthropic_event_callback(
                f,
                agent,
                assistant_message,
                started,
                ended,
                stop_reason,
                latest_usage,
                blocks_by_index,
                partial_json_by_index,
            ),
            merged_http_kw...,
        )

        if started[] && !ended[]
            ended[] = true
            f(MessageEndEvent(:assistant, assistant_message))
        end

        usage = anthropic_usage_from_response(latest_usage[])
        final_stop = anthropic_stop_reason(stop_reason[], assistant_message.tool_calls)
        return AgentResponse(; message=assistant_message, usage, stop_reason=final_stop)
    elseif model.api == "google-generative-ai"
        tools = google_generative_build_tools(agent.tools)
        contents = google_generative_build_contents(agent, state, input)
        assistant_message = AssistantMessage(; response_id=state.response_id)
        started = Ref(false)
        ended = Ref(false)
        latest_usage = Ref{Union{Nothing,GoogleGenerativeAI.UsageMetadata}}(nothing)
        latest_finish = Ref{Union{Nothing,String}}(nothing)
        seen_call_ids = Set{String}()

        stream_kw = haskey(kw, :systemInstruction) ? Base.structdiff(kw, (; systemInstruction=nothing)) : kw
        system_instruction = GoogleGenerativeAI.Content(; parts=[GoogleGenerativeAI.Part(; text=agent.prompt)])
        request_kw = merge((; tools, systemInstruction=system_instruction), stream_kw)
        req = GoogleGenerativeAI.Request(
            ; contents,
            model.kw...,
            request_kw...,
        )
        headers = Dict(
            "x-goog-api-key" => apikey,
            "Content-Type" => "application/json",
        )
        model.headers !== nothing && merge!(headers, model.headers)
        url = joinpath(model.baseUrl, "models", "$(model.id):streamGenerateContent")
        HTTP.post(
            url * "?alt=sse",
            headers;
            body=JSON.json(req),
            sse_callback=google_generative_event_callback(
                f,
                agent,
                assistant_message,
                started,
                ended,
                latest_usage,
                latest_finish,
                seen_call_ids,
            ),
            merged_http_kw...,
        )

        if started[] && !ended[]
            ended[] = true
            f(MessageEndEvent(:assistant, assistant_message))
        end

        usage = google_generative_usage_from_response(latest_usage[])
        stop_reason = google_generative_stop_reason(latest_finish[], assistant_message.tool_calls)
        return AgentResponse(; message=assistant_message, usage, stop_reason)
    elseif model.api == "google-gemini-cli"
        tools = google_gemini_cli_build_tools(agent.tools)
        contents = google_gemini_cli_build_contents(agent, state, input)
        assistant_message = AssistantMessage(; response_id=state.response_id)
        started = Ref(false)
        ended = Ref(false)
        latest_usage = Ref{Union{Nothing,GoogleGeminiCli.UsageMetadata}}(nothing)
        latest_finish = Ref{Union{Nothing,String}}(nothing)
        seen_call_ids = Set{String}()

        token, project_id = GoogleGeminiCli.parse_oauth_credentials(apikey)
        token === nothing && throw(ArgumentError("Missing `token` in google-gemini-cli credentials JSON"))
        project_id === nothing && throw(ArgumentError("Missing `projectId` in google-gemini-cli credentials JSON"))

        tool_choice = haskey(kw, :toolChoice) ? kw[:toolChoice] : nothing
        max_tokens = haskey(kw, :maxTokens) ? kw[:maxTokens] : nothing
        temperature = haskey(kw, :temperature) ? kw[:temperature] : nothing
        thinking = haskey(kw, :thinking) ? kw[:thinking] : nothing
        debug_stream = haskey(kw, :debug_stream) ? kw[:debug_stream] : false

        system_instruction = GoogleGeminiCli.Content(; parts=[GoogleGeminiCli.Part(; text=agent.prompt)])
        req = GoogleGeminiCli.build_request(
            model,
            contents,
            project_id;
            systemInstruction=system_instruction,
            tools=tools,
            toolChoice=tool_choice,
            maxTokens=max_tokens,
            temperature=temperature,
            thinking=thinking,
        )

        endpoint = isempty(model.baseUrl) ? GoogleGeminiCli.DEFAULT_ENDPOINT : model.baseUrl
        url = string(endpoint, "/v1internal:streamGenerateContent?alt=sse")
        headers = occursin("sandbox.googleapis.com", endpoint) ? copy(GoogleGeminiCli.ANTIGRAVITY_HEADERS) : copy(GoogleGeminiCli.GEMINI_CLI_HEADERS)
        headers["Authorization"] = "Bearer $token"
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "text/event-stream"
        model.headers !== nothing && merge!(headers, model.headers)

        HTTP.post(
            url,
            headers;
            body=JSON.json(req),
            sse_callback=google_gemini_cli_event_callback(
                f,
                agent,
                assistant_message,
                started,
                ended,
                latest_usage,
                latest_finish,
                seen_call_ids,
                debug_stream,
            ),
            merged_http_kw...,
        )

        if started[] && !ended[]
            ended[] = true
            f(MessageEndEvent(:assistant, assistant_message))
        end

        usage = google_gemini_cli_usage_from_response(latest_usage[])
        stop_reason = google_gemini_cli_stop_reason(latest_finish[], assistant_message.tool_calls)
        return AgentResponse(; message=assistant_message, usage, stop_reason)
    else
        throw(ArgumentError("$(model.name) using $(model.api) api currently unsupported"))
    end
end
