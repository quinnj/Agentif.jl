using HTTP
using JSON
using UUIDs

toolcall_debug_enabled() = get(ENV, "AGENTIF_DEBUG_TOOLCALLS", "") != ""

struct StopStreaming <: Exception
    reason::String
end

StopStreaming() = StopStreaming("stop streaming early")

toolcall_preview(::Nothing; limit::Int = 300) = "(nothing)"
function toolcall_preview(s::AbstractString; limit::Int = 300)
    return length(s) > limit ? string(s[1:limit], "...(truncated)") : s
end

function toolcall_debug(msg::AbstractString; kw...)
    toolcall_debug_enabled() || return
    return @info msg kw...
end

# Default HTTP.jl kwargs for retry behavior
const DEFAULT_HTTP_KW = (;
    retry = true,
    retries = 5,
    retry_non_idempotent = true,  # Retry POST requests
)

mutable struct ToolCallAccumulator
    id::Union{Nothing, String}
    name::Union{Nothing, String}
    arguments::String
end

new_call_id(prefix::String) = string(prefix, "-", UUIDs.uuid4())

function parse_tool_arguments(arguments::String)
    try
        return JSON.parse(arguments)
    catch
        return Dict{String, Any}()
    end
end

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

function openai_responses_build_input(input::AgentTurnInput)
    if input isa String
        return input
    elseif input isa Vector{ToolResultMessage}
        outputs = OpenAIResponses.FunctionToolCallOutput[]
        for result in input
            push!(outputs, OpenAIResponses.FunctionToolCallOutput(; call_id = result.call_id, output = result.output))
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

function codex_input_from_message(msg::AgentMessage)
    if msg isa UserMessage
        return Any[Dict("role" => "user", "content" => [Dict("type" => "input_text", "text" => msg.text)])]
    elseif msg isa AssistantMessage
        parts = Any[]
        if !isempty(msg.reasoning)
            push!(
                parts, Dict(
                    "type" => "reasoning",
                    "summary" => [Dict("type" => "summary_text", "text" => msg.reasoning)],
                    "status" => "completed",
                )
            )
        end
        if !isempty(msg.text)
            push!(
                parts, Dict(
                    "type" => "message",
                    "role" => "assistant",
                    "content" => [Dict("type" => "output_text", "text" => msg.text)],
                    "status" => "completed",
                )
            )
        end
        for tc in msg.tool_calls
            push!(
                parts, Dict(
                    "type" => "function_call",
                    "call_id" => tc.call_id,
                    "name" => tc.name,
                    "arguments" => tc.arguments,
                )
            )
        end
        return parts
    elseif msg isa ToolResultMessage
        return Any[
            Dict(
                "type" => "function_call_output",
                "call_id" => msg.call_id,
                "output" => msg.output,
            ),
        ]
    end
    return Any[]
end

function codex_build_input(agent::Agent, state::AgentState, input::AgentTurnInput)
    items = Any[]
    for msg in state.messages
        include_in_context(msg) || continue
        append!(items, codex_input_from_message(msg))
    end
    if input isa String
        push!(items, Dict("role" => "user", "content" => [Dict("type" => "input_text", "text" => input)]))
    elseif input isa Vector{ToolResultMessage}
        for result in input
            push!(items, Dict("type" => "function_call_output", "call_id" => result.call_id, "output" => result.output))
        end
    end
    return items
end

function codex_usage_from_response(u)
    u === nothing && return Usage()
    input_tokens = get(() -> 0, u, "input_tokens")
    output_tokens = get(() -> 0, u, "output_tokens")
    total_tokens = get(() -> input_tokens + output_tokens, u, "total_tokens")
    cached_tokens = 0
    details = get(() -> nothing, u, "input_tokens_details")
    if details isa AbstractDict
        cached_tokens = get(() -> 0, details, "cached_tokens")
    end
    return Usage(; input = input_tokens - cached_tokens, output = output_tokens, cacheRead = cached_tokens, cacheWrite = 0, total = total_tokens)
end

function codex_stop_reason(status::Union{Nothing, String}, tool_calls::Vector{AgentToolCall})
    reason = OpenAICodex.map_stop_reason(status)
    if !isempty(tool_calls) && reason == :stop
        return :tool_calls
    end
    return reason
end

function openai_codex_event_callback(
        f::Function,
        agent::Agent,
        assistant_message::AssistantMessage,
        started::Base.RefValue{Bool},
        ended::Base.RefValue{Bool},
        response_usage::Base.RefValue{Any},
        response_status::Base.RefValue{Union{Nothing, String}},
        tool_call_accumulators::Dict{String, ToolCallAccumulator},
    )
    ensure_started() = begin
        if !started[]
            started[] = true
            f(MessageStartEvent(:assistant, assistant_message))
        end
    end

    function update_reasoning(delta::String, item_id)
        ensure_started()
        assistant_message.reasoning *= delta
        return f(MessageUpdateEvent(:assistant, assistant_message, :reasoning, delta, item_id))
    end

    function update_text(delta::String, item_id)
        ensure_started()
        assistant_message.text *= delta
        return f(MessageUpdateEvent(:assistant, assistant_message, :text, delta, item_id))
    end

    return function (http_stream, event::HTTP.SSEEvent)
        data = String(event.data)
        strip_data = strip(data)
        isempty(strip_data) && return
        if strip_data == "[DONE]"
            if started[] && !ended[]
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end
            return
        end

        local raw
        try
            raw = JSON.parse(data)
        catch e
            f(AgentErrorEvent(ErrorException("Failed to parse Codex SSE event: $(sprint(showerror, e))")))
            return
        end

        event_type = get(() -> "", raw, "type")
        isempty(event_type) && return

        if event_type == "response.created"
            response = get(() -> nothing, raw, "response")
            if response isa AbstractDict
                rid = get(() -> nothing, response, "id")
                rid !== nothing && (assistant_message.response_id = string(rid))
            end
            return
        elseif event_type == "response.output_item.added"
            ensure_started()
            item = get(() -> nothing, raw, "item")
            item isa AbstractDict || return
            item_type = get(() -> "", item, "type")
            if item_type == "function_call"
                call_id = string(get(() -> get(() -> new_call_id("codex"), item, "id"), item, "call_id"))
                name = string(get(() -> "", item, "name"))
                tool_call_accumulators[call_id] = ToolCallAccumulator(get(() -> nothing, item, "id"), name, "")
            end
        elseif event_type == "response.reasoning_summary_part.added"
            ensure_started()
        elseif event_type == "response.reasoning_summary_text.delta" || event_type == "response.reasoning_text.delta"
            delta = String(get(() -> "", raw, "delta"))
            update_reasoning(delta, get(() -> nothing, raw, "item_id"))
        elseif event_type == "response.reasoning_summary_part.done"
            update_reasoning("\n\n", get(() -> nothing, raw, "item_id"))
        elseif event_type == "response.content_part.added"
            ensure_started()
        elseif event_type == "response.output_text.delta"
            delta = String(get(() -> "", raw, "delta"))
            update_text(delta, get(() -> nothing, raw, "item_id"))
        elseif event_type == "response.refusal.delta"
            ensure_started()
            delta = String(get(() -> "", raw, "delta"))
            assistant_message.refusal *= delta
            f(MessageUpdateEvent(:assistant, assistant_message, :refusal, delta, get(() -> nothing, raw, "item_id")))
        elseif event_type == "response.function_call_arguments.delta"
            ensure_started()
            delta = String(get(() -> "", raw, "delta"))
            item_id = get(() -> nothing, raw, "item_id")
            call_id = string(get(() -> something(item_id, "codex_call"), raw, "call_id"))
            acc = get(() -> ToolCallAccumulator(item_id, get(() -> nothing, raw, "name"), ""), tool_call_accumulators, call_id)
            acc.arguments *= delta
            tool_call_accumulators[call_id] = acc
            f(MessageUpdateEvent(:assistant, assistant_message, :tool_arguments, delta, item_id))
        elseif event_type == "response.output_item.done"
            ensure_started()
            item = get(() -> nothing, raw, "item")
            item isa AbstractDict || return
            item_type = get(() -> "", item, "type")
            if item_type == "reasoning"
                summary = get(() -> nothing, item, "summary")
                if summary isa AbstractVector
                    text_parts = String[]
                    for s in summary
                        s isa AbstractDict || continue
                        push!(text_parts, String(get(() -> "", s, "text")))
                    end
                    assistant_message.reasoning = join(text_parts, "\n\n")
                end
            elseif item_type == "message"
                content = get(() -> nothing, item, "content")
                if content isa AbstractVector
                    io = IOBuffer()
                    for part in content
                        part isa AbstractDict || continue
                        part_type = get(() -> "", part, "type")
                        if part_type == "output_text"
                            print(io, get(() -> "", part, "text"))
                        elseif part_type == "refusal"
                            print(io, get(() -> "", part, "refusal"))
                        end
                    end
                    assistant_message.text = String(take!(io))
                end
            elseif item_type == "function_call"
                call_id = string(get(() -> get(() -> new_call_id("codex"), item, "id"), item, "call_id"))
                name = String(get(() -> "", item, "name"))
                args = String(get(() -> "{}", item, "arguments"))
                acc = get(() -> nothing, tool_call_accumulators, call_id)
                if acc !== nothing && !isempty(acc.arguments)
                    args = acc.arguments
                end
                call = AgentToolCall(; call_id = call_id, name = name, arguments = args)
                push!(assistant_message.tool_calls, call)
                tool = findtool(agent.tools, call.name)
                ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                f(ToolCallRequestEvent(ptc, tool.requires_approval))
            end
        elseif event_type == "response.completed" || event_type == "response.done"
            response = get(() -> nothing, raw, "response")
            if response isa AbstractDict
                usage = get(() -> nothing, response, "usage")
                usage !== nothing && (response_usage[] = usage)
                status = get(() -> nothing, response, "status")
                status !== nothing && (response_status[] = String(status))
                rid = get(() -> nothing, response, "id")
                rid !== nothing && (assistant_message.response_id = string(rid))
            end
        elseif event_type == "response.failed" || event_type == "response.incomplete"
            response = get(() -> nothing, raw, "response")
            if response isa AbstractDict
                usage = get(() -> nothing, response, "usage")
                usage !== nothing && (response_usage[] = usage)
                status = get(() -> nothing, response, "status")
                status !== nothing && (response_status[] = String(status))
            end
        elseif event_type == "error"
            code = String(get(() -> "", raw, "code"))
            msg = String(get(() -> "", raw, "message"))
            error_text = OpenAICodex.format_codex_error_event(raw, code, msg)
            if started[] && !ended[]
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end
            response_status[] = "failed"
            f(AgentErrorEvent(ErrorException(error_text)))
        end
    end
end

function openai_completions_is_zai(model::Model)
    return model.provider == "zai" || occursin("api.z.ai", model.baseUrl)
end

function openai_completions_supports_reasoning_effort(model::Model)
    return !occursin("api.x.ai", model.baseUrl) && !openai_completions_is_zai(model)
end

function openai_completions_build_tools(tools::Vector{AgentTool})
    isempty(tools) && return nothing
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

function openai_completions_tool_call_from_agent(call::AgentToolCall)
    return OpenAICompletions.ToolCall(
        id = call.call_id,
        var"function" = OpenAICompletions.ToolCallFunction(
            name = call.name,
            arguments = call.arguments,
        )
    )
end

function agent_system_prompt(agent::Agent)
    registry = agent.skills
    if registry === nothing || isempty(registry.skills)
        return agent.prompt
    end
    return append_available_skills(agent.prompt, values(registry.skills))
end

function openai_completions_message_from_agent(msg::AgentMessage)
    if msg isa UserMessage
        return OpenAICompletions.Message(; role = "user", content = msg.text)
    elseif msg isa AssistantMessage
        content = isempty(msg.text) ? nothing : msg.text
        tool_calls = isempty(msg.tool_calls) ? nothing : OpenAICompletions.ToolCall[
                openai_completions_tool_call_from_agent(tc) for tc in msg.tool_calls
            ]
        kwargs = (; role = "assistant", content, tool_calls)
        if !isempty(msg.reasoning)
            kwargs = (; kwargs..., reasoning = msg.reasoning)
        end
        return OpenAICompletions.Message(; kwargs...)
    elseif msg isa ToolResultMessage
        return OpenAICompletions.Message(;
            role = "tool",
            content = msg.output,
            tool_call_id = msg.call_id,
            name = msg.name,
        )
    end
    throw(ArgumentError("unsupported message: $(typeof(msg))"))
end

function openai_completions_build_messages(agent::Agent, state::AgentState, input::AgentTurnInput)
    messages = OpenAICompletions.Message[]
    system_prompt = agent_system_prompt(agent)
    push!(messages, OpenAICompletions.Message(; role = "system", content = system_prompt))
    for msg in state.messages
        include_in_context(msg) || continue
        push!(messages, openai_completions_message_from_agent(msg))
    end
    if input isa String
        push!(messages, OpenAICompletions.Message(; role = "user", content = input))
    elseif input isa Vector{ToolResultMessage}
        for result in input
            push!(messages, OpenAICompletions.Message(; role = "tool", content = result.output, tool_call_id = result.call_id))
        end
    end
    return messages
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
    )
    return function (http_stream, event::HTTP.SSEEvent)
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

function anthropic_tool_result_block(result::ToolResultMessage)
    return AnthropicMessages.ToolResultBlock(;
        tool_use_id = anthropic_sanitize_tool_call_id(result.call_id),
        content = result.output,
        is_error = result.is_error,
    )
end

function anthropic_insert_missing_tool_results(messages::Vector{AgentMessage})
    normalized = AgentMessage[]
    pending = AgentToolCall[]
    resolved = Set{String}()
    function flush_pending!()
        isempty(pending) && return
        for call in pending
            if !(call.call_id in resolved)
                @warn "Inserted synthetic tool_result for orphaned tool_use" tool_name = call.name call_id = call.call_id
                push!(
                    normalized, ToolResultMessage(;
                        call_id = call.call_id,
                        name = call.name,
                        arguments = call.arguments,
                        output = ANTHROPIC_TOOL_RESULT_PLACEHOLDER,
                        is_error = true,
                    )
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
            if !isempty(msg.tool_calls)
                empty!(pending)
                empty!(resolved)
                append!(pending, msg.tool_calls)
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

function anthropic_message_from_agent(msg::AgentMessage, tool_name_map::Dict{String, String})
    if msg isa UserMessage
        return AnthropicMessages.Message(; role = "user", content = msg.text)
    elseif msg isa AssistantMessage
        has_tool_calls = !isempty(msg.tool_calls)
        has_text = !isempty(msg.text)
        if !has_tool_calls
            return AnthropicMessages.Message(; role = "assistant", content = msg.text)
        end
        blocks = AnthropicMessages.ContentBlock[]
        if has_text
            push!(blocks, AnthropicMessages.TextBlock(; text = msg.text))
        end
        for call in msg.tool_calls
            args = parse_tool_arguments(call.arguments)
            call_id = anthropic_sanitize_tool_call_id(call.call_id)
            tool_name = anthropic_external_tool_name(tool_name_map, call.name)
            push!(blocks, AnthropicMessages.ToolUseBlock(; id = call_id, name = tool_name, input = args))
        end
        return AnthropicMessages.Message(; role = "assistant", content = blocks)
    elseif msg isa ToolResultMessage
        block = anthropic_tool_result_block(msg)
        return AnthropicMessages.Message(; role = "user", content = AnthropicMessages.ContentBlock[block])
    end
    throw(ArgumentError("unsupported message: $(typeof(msg))"))
end

function anthropic_build_messages(agent::Agent, state::AgentState, input::AgentTurnInput, tool_name_map::Dict{String, String})
    context = AgentMessage[]
    for msg in state.messages
        include_in_context(msg) || continue
        push!(context, msg)
    end
    if input isa String
        push!(context, UserMessage(input))
    elseif input isa Vector{ToolResultMessage}
        append!(context, input)
    end
    normalized = anthropic_insert_missing_tool_results(context)
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
            push!(messages, anthropic_message_from_agent(msg, tool_name_map))
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
        blocks_by_index::Dict{Int, AnthropicMessages.ContentBlock},
        partial_json_by_index::Dict{Int, String},
        tool_name_reverse_map::Dict{String, String},
    )
    return function (http_stream, event::HTTP.SSEEvent)
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
                block = AnthropicMessages.TextBlock(; text = parsed.content_block.text)
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
                tool_name = anthropic_internal_tool_name(tool_name_reverse_map, block.name)
                call = AgentToolCall(; call_id = block.id, name = tool_name, arguments = JSON.json(args))
                push!(assistant_message.tool_calls, call)
                tool = findtool(agent.tools, call.name)
                ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
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
        push!(
            decls, GoogleGenerativeAI.FunctionDeclaration(
                ; name = tool.name, description = tool.description, parameters = GoogleGenerativeAI.schema(parameters(tool))
            )
        )
    end
    return [GoogleGenerativeAI.Tool(; functionDeclarations = decls)]
end

function google_generative_message_from_agent(msg::AgentMessage)
    if msg isa UserMessage
        return GoogleGenerativeAI.Content(; role = "user", parts = [GoogleGenerativeAI.Part(; text = msg.text)])
    elseif msg isa AssistantMessage
        parts = GoogleGenerativeAI.Part[]
        if !isempty(msg.text)
            push!(parts, GoogleGenerativeAI.Part(; text = msg.text))
        end
        for call in msg.tool_calls
            args = parse_tool_arguments(call.arguments)
            push!(
                parts, GoogleGenerativeAI.Part(
                    ; functionCall = GoogleGenerativeAI.FunctionCall(; id = call.call_id, name = call.name, args)
                )
            )
        end
        return GoogleGenerativeAI.Content(; role = "model", parts)
    elseif msg isa ToolResultMessage
        response_payload = msg.is_error ? Dict("error" => msg.output) : Dict("result" => msg.output)
        part = GoogleGenerativeAI.Part(;
            functionResponse = GoogleGenerativeAI.FunctionResponse(; name = msg.name, response = response_payload),
        )
        return GoogleGenerativeAI.Content(; role = "user", parts = [part])
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
        push!(contents, GoogleGenerativeAI.Content(; role = "user", parts = [GoogleGenerativeAI.Part(; text = input)]))
    elseif input isa Vector{ToolResultMessage}
        parts = GoogleGenerativeAI.Part[]
        for result in input
            response_payload = result.is_error ? Dict("error" => result.output) : Dict("result" => result.output)
            push!(
                parts, GoogleGenerativeAI.Part(
                    ; functionResponse = GoogleGenerativeAI.FunctionResponse(; name = result.name, response = response_payload)
                )
            )
        end
        if !isempty(parts)
            push!(contents, GoogleGenerativeAI.Content(; role = "user", parts))
        end
    end
    return contents
end

function google_generative_usage_from_response(u::Union{Nothing, GoogleGenerativeAI.UsageMetadata})
    u === nothing && return Usage()
    input = something(u.promptTokenCount, 0)
    output = something(u.candidatesTokenCount, 0)
    total = something(u.totalTokenCount, input + output)
    return Usage(; input, output, total)
end

function google_generative_stop_reason(reason::Union{Nothing, String}, tool_calls::Vector{AgentToolCall})
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
        latest_usage::Base.RefValue{Union{Nothing, GoogleGenerativeAI.UsageMetadata}},
        latest_finish::Base.RefValue{Union{Nothing, String}},
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
                call = AgentToolCall(; call_id = call_id, name = fc.name, arguments = args_json)
                push!(assistant_message.tool_calls, call)
                tool = findtool(agent.tools, call.name)
                ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                f(ToolCallRequestEvent(ptc, tool.requires_approval))
            end
        end
        return
    end
end

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

function google_gemini_cli_message_from_agent(msg::AgentMessage)
    if msg isa UserMessage
        return GoogleGeminiCli.Content(; role = "user", parts = [GoogleGeminiCli.Part(; text = msg.text)])
    elseif msg isa AssistantMessage
        parts = GoogleGeminiCli.Part[]
        if !isempty(msg.reasoning)
            push!(parts, GoogleGeminiCli.Part(; text = msg.reasoning, thought = true))
        end
        if !isempty(msg.text)
            push!(parts, GoogleGeminiCli.Part(; text = msg.text))
        end
        for call in msg.tool_calls
            args = parse_tool_arguments(call.arguments)
            push!(
                parts, GoogleGeminiCli.Part(
                    ; functionCall = GoogleGeminiCli.FunctionCall(; id = call.call_id, name = call.name, args)
                )
            )
        end
        return GoogleGeminiCli.Content(; role = "model", parts)
    elseif msg isa ToolResultMessage
        response_payload = msg.is_error ? Dict("error" => msg.output) : Dict("output" => msg.output)
        part = GoogleGeminiCli.Part(;
            functionResponse = GoogleGeminiCli.FunctionResponse(;
                id = msg.call_id,
                name = msg.name,
                response = response_payload,
            ),
        )
        return GoogleGeminiCli.Content(; role = "user", parts = [part])
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
        push!(contents, GoogleGeminiCli.Content(; role = "user", parts = [GoogleGeminiCli.Part(; text = input)]))
    elseif input isa Vector{ToolResultMessage}
        parts = GoogleGeminiCli.Part[]
        for result in input
            response_payload = result.is_error ? Dict("error" => result.output) : Dict("output" => result.output)
            push!(
                parts, GoogleGeminiCli.Part(
                    ; functionResponse = GoogleGeminiCli.FunctionResponse(; id = result.call_id, name = result.name, response = response_payload)
                )
            )
        end
        if !isempty(parts)
            push!(contents, GoogleGeminiCli.Content(; role = "user", parts))
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
    )
    return function (http_stream, event::HTTP.SSEEvent)
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
                call = AgentToolCall(; call_id = call_id, name = fc.name, arguments = args_json)
                push!(assistant_message.tool_calls, call)
                tool = findtool(agent.tools, call.name)
                ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                f(ToolCallRequestEvent(ptc, tool.requires_approval))
            end
        end
        return
    end
end

function stream(
        f::Function, agent::Agent, state::AgentState, input::AgentTurnInput, apikey::String;
        model::Union{Nothing, Model} = nothing, http_kw = (;), kw...
    )
    model = model === nothing ? agent.model : model
    model === nothing && throw(ArgumentError("no model specified with which agent can evaluate input"))

    # Merge HTTP kwargs: defaults < agent.http_kw < per-call http_kw
    merged_http_kw = merge(DEFAULT_HTTP_KW, NamedTuple(agent.http_kw), NamedTuple(http_kw))
    kw_nt = kw isa NamedTuple ? kw : (; kw...)

    if model.api == "openai-responses"
        tools = openai_responses_build_tools(agent.tools)
        current_input = openai_responses_build_input(input)
        assistant_message = AssistantMessage(; response_id = state.response_id)
        started = Ref(false)
        ended = Ref(false)
        response_usage = Ref{Union{Nothing, OpenAIResponses.Usage}}(nothing)
        response_status = Ref{Union{Nothing, String}}(nothing)

        stream_kw = haskey(kw_nt, :instructions) ? Base.structdiff(kw_nt, (; instructions = nothing)) : kw_nt
        system_prompt = agent_system_prompt(agent)
        request_kw = merge(
            (; tools, previous_response_id = state.response_id, instructions = system_prompt),
            stream_kw,
        )
        req = OpenAIResponses.Request(
            ; model = model.id,
            input = current_input,
            stream = true,
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
            body = JSON.json(req),
            sse_callback = openai_responses_event_callback(
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
        return AgentResponse(; message = assistant_message, usage, stop_reason)
    elseif model.api == "openai-completions"
        tools = openai_completions_build_tools(agent.tools)
        messages = openai_completions_build_messages(agent, state, input)
        assistant_message = AssistantMessage(; response_id = state.response_id)
        started = Ref(false)
        ended = Ref(false)
        latest_usage = Ref{Union{Nothing, OpenAICompletions.Usage}}(nothing)
        latest_finish = Ref{Union{Nothing, String}}(nothing)
        tool_call_accumulators = Dict{Int, ToolCallAccumulator}()

        stream_kw = haskey(kw_nt, :instructions) ? Base.structdiff(kw_nt, (; instructions = nothing)) : kw_nt
        use_stream = true
        if haskey(stream_kw, :stream)
            use_stream = stream_kw[:stream]
            stream_kw = Base.structdiff(stream_kw, (; stream = false))
        end
        reasoning_effort_value = nothing
        if haskey(stream_kw, :reasoning)
            reasoning_effort_value = stream_kw[:reasoning]
            stream_kw = Base.structdiff(stream_kw, (; reasoning = nothing))
            if !haskey(stream_kw, :reasoning_effort)
                stream_kw = merge(stream_kw, (; reasoning_effort = reasoning_effort_value))
            end
        end
        if haskey(stream_kw, :reasoning_effort)
            reasoning_effort_value = stream_kw[:reasoning_effort]
        end
        if haskey(stream_kw, :reasoning_effort) && !openai_completions_supports_reasoning_effort(model)
            stream_kw = Base.structdiff(stream_kw, (; reasoning_effort = nothing))
        end
        if openai_completions_is_zai(model) && model.reasoning && !haskey(stream_kw, :thinking)
            thinking_type = reasoning_effort_value === nothing ? "disabled" : "enabled"
            stream_kw = merge(stream_kw, (; thinking = Dict("type" => thinking_type)))
        end

        request_kw = merge((; tools), stream_kw)
        req = OpenAICompletions.Request(
            ; model = model.id,
            messages,
            stream = use_stream,
            model.kw...,
            request_kw...,
        )
        headers = Dict(
            "Authorization" => "Bearer $apikey",
            "Content-Type" => "application/json",
        )
        model.headers !== nothing && merge!(headers, model.headers)
        url = joinpath(model.baseUrl, "chat", "completions")
        if use_stream
            try
                HTTP.post(
                    url,
                    headers;
                    body = JSON.json(req),
                    sse_callback = openai_completions_event_callback(
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
            catch e
                if !(e isa StopStreaming)
                    rethrow()
                end
            end

            if started[] && !ended[]
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end

            for idx in sort(collect(keys(tool_call_accumulators)))
                acc = tool_call_accumulators[idx]
                toolcall_debug(
                    "openai-completions tool accumulator finalized";
                    index = idx,
                    id = acc.id,
                    name = acc.name,
                    arg_length = length(acc.arguments),
                    args_preview = toolcall_preview(acc.arguments, limit = 300),
                )
                acc.name === nothing && throw(ArgumentError("tool call missing name for index $(idx)"))
                call_id = acc.id === nothing ? new_call_id("openai") : acc.id
                args = isempty(acc.arguments) ? "{}" : acc.arguments
                call = AgentToolCall(; call_id, name = acc.name, arguments = args)
                push!(assistant_message.tool_calls, call)
                tool = findtool(agent.tools, call.name)
                ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                f(ToolCallRequestEvent(ptc, tool.requires_approval))
            end
        else
            response = JSON.parse(HTTP.post(url, headers; body = JSON.json(req), merged_http_kw...).body, OpenAICompletions.Response)
            isempty(response.choices) && return AgentResponse(; message = assistant_message, usage = Usage(), stop_reason = :stop)
            choice = response.choices[1]
            if choice.message.content !== nothing
                assistant_message.text = choice.message.content
            end
            if !isempty(assistant_message.text)
                f(MessageStartEvent(:assistant, assistant_message))
                f(MessageUpdateEvent(:assistant, assistant_message, :text, assistant_message.text, nothing))
                f(MessageEndEvent(:assistant, assistant_message))
            end
            if choice.message.tool_calls !== nothing
                for tc in choice.message.tool_calls
                    call_id = tc.id === nothing ? new_call_id("openai") : tc.id
                    args = tc.function.arguments === nothing ? "{}" : tc.function.arguments
                    call = AgentToolCall(; call_id, name = tc.function.name, arguments = args)
                    push!(assistant_message.tool_calls, call)
                    tool = findtool(agent.tools, call.name)
                    ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                    f(ToolCallRequestEvent(ptc, tool.requires_approval))
                end
            end
            latest_usage[] = response.usage
            latest_finish[] = choice.finish_reason
        end

        usage = openai_completions_usage_from_response(latest_usage[])
        stop_reason = openai_completions_stop_reason(latest_finish[], assistant_message.tool_calls)
        return AgentResponse(; message = assistant_message, usage, stop_reason)
    elseif model.api == "anthropic-messages"
        if apikey == "OAUTH"
            apikey = anthropic_login()
        end
        is_oauth = startswith(apikey, "sk-ant-oat")
        tool_name_map, tool_name_reverse_map = anthropic_tool_name_maps(agent.tools, is_oauth)
        tools = anthropic_build_tools(agent.tools, tool_name_map)
        messages = anthropic_build_messages(agent, state, input, tool_name_map)
        assistant_message = AssistantMessage(; response_id = state.response_id)
        started = Ref(false)
        ended = Ref(false)
        stop_reason = Ref{Union{Nothing, String}}(nothing)
        latest_usage = Ref{Union{Nothing, AnthropicMessages.Usage}}(nothing)
        blocks_by_index = Dict{Int, AnthropicMessages.ContentBlock}()
        partial_json_by_index = Dict{Int, String}()

        max_tokens = haskey(kw_nt, :max_tokens) ? kw_nt[:max_tokens] : model.maxTokens
        stream_kw = haskey(kw_nt, :max_tokens) ? Base.structdiff(kw_nt, (; max_tokens = 0)) : kw_nt
        stream_kw = haskey(stream_kw, :system) ? Base.structdiff(stream_kw, (; system = nothing)) : stream_kw
        system_prompt = agent_system_prompt(agent)
        system_value = is_oauth ? anthropic_oauth_system_blocks(system_prompt) : system_prompt
        if haskey(stream_kw, :tool_choice)
            tool_choice = stream_kw[:tool_choice]
            if tool_choice isa AbstractDict
                choice_type = get(() -> nothing, tool_choice, "type")
                if choice_type == "tool"
                    choice_name = get(() -> nothing, tool_choice, "name")
                    if choice_name !== nothing
                        tool_choice = copy(tool_choice)
                        tool_choice["name"] = anthropic_external_tool_name(tool_name_map, string(choice_name))
                    end
                end
            elseif tool_choice isa NamedTuple
                choice_type = get(() -> nothing, tool_choice, :type)
                if choice_type == "tool"
                    choice_name = get(() -> nothing, tool_choice, :name)
                    if choice_name !== nothing
                        mapped_name = anthropic_external_tool_name(tool_name_map, string(choice_name))
                        tool_choice = merge(tool_choice, (; name = mapped_name))
                    end
                end
            end
            stream_kw = merge(Base.structdiff(stream_kw, (; tool_choice = nothing)), (; tool_choice))
        end
        request_kw = merge((; tools, system = system_value), stream_kw)
        req = AnthropicMessages.Request(
            ; model = model.id,
            messages,
            max_tokens,
            stream = true,
            model.kw...,
            request_kw...,
        )
        headers = Dict(
            "anthropic-version" => "2023-06-01",
            "Content-Type" => "application/json",
            "Accept" => "application/json",
            "anthropic-dangerous-direct-browser-access" => "true",
        )
        # Add beta features for tool streaming
        beta_features = ["fine-grained-tool-streaming-2025-05-14"]

        if is_oauth
            headers["Authorization"] = "Bearer $apikey"
            headers["anthropic-beta"] = "oauth-2025-04-20,$(join(beta_features, ","))"
        else
            headers["x-api-key"] = apikey
            headers["anthropic-beta"] = join(beta_features, ",")
        end
        model.headers !== nothing && merge!(headers, model.headers)
        url = joinpath(model.baseUrl, "v1", "messages")
        HTTP.post(
            url,
            headers;
            body = JSON.json(req),
            sse_callback = anthropic_event_callback(
                f,
                agent,
                assistant_message,
                started,
                ended,
                stop_reason,
                latest_usage,
                blocks_by_index,
                partial_json_by_index,
                tool_name_reverse_map,
            ),
            merged_http_kw...,
        )

        if started[] && !ended[]
            ended[] = true
            f(MessageEndEvent(:assistant, assistant_message))
        end

        usage = anthropic_usage_from_response(latest_usage[])
        final_stop = anthropic_stop_reason(stop_reason[], assistant_message.tool_calls)
        return AgentResponse(; message = assistant_message, usage, stop_reason = final_stop)
    elseif model.api == "google-generative-ai"
        tools = google_generative_build_tools(agent.tools)
        contents = google_generative_build_contents(agent, state, input)
        assistant_message = AssistantMessage(; response_id = state.response_id)
        started = Ref(false)
        ended = Ref(false)
        latest_usage = Ref{Union{Nothing, GoogleGenerativeAI.UsageMetadata}}(nothing)
        latest_finish = Ref{Union{Nothing, String}}(nothing)
        seen_call_ids = Set{String}()

        stream_kw = haskey(kw_nt, :systemInstruction) ? Base.structdiff(kw_nt, (; systemInstruction = nothing)) : kw_nt
        system_prompt = agent_system_prompt(agent)
        system_instruction = GoogleGenerativeAI.Content(; parts = [GoogleGenerativeAI.Part(; text = system_prompt)])
        request_kw = merge((; tools, systemInstruction = system_instruction), stream_kw)
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
            body = JSON.json(req),
            sse_callback = google_generative_event_callback(
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
        return AgentResponse(; message = assistant_message, usage, stop_reason)
    elseif model.api == "google-gemini-cli"
        tools = google_gemini_cli_build_tools(agent.tools)
        contents = google_gemini_cli_build_contents(agent, state, input)
        assistant_message = AssistantMessage(; response_id = state.response_id)
        started = Ref(false)
        ended = Ref(false)
        latest_usage = Ref{Union{Nothing, GoogleGeminiCli.UsageMetadata}}(nothing)
        latest_finish = Ref{Union{Nothing, String}}(nothing)
        seen_call_ids = Set{String}()

        token, project_id = GoogleGeminiCli.parse_oauth_credentials(apikey)
        token === nothing && throw(ArgumentError("Missing `token` in google-gemini-cli credentials JSON"))
        project_id === nothing && throw(ArgumentError("Missing `projectId` in google-gemini-cli credentials JSON"))

        tool_choice = haskey(kw_nt, :toolChoice) ? kw_nt[:toolChoice] : nothing
        max_tokens = haskey(kw_nt, :maxTokens) ? kw_nt[:maxTokens] : nothing
        temperature = haskey(kw_nt, :temperature) ? kw_nt[:temperature] : nothing
        thinking = haskey(kw_nt, :thinking) ? kw_nt[:thinking] : nothing
        system_prompt = agent_system_prompt(agent)
        system_instruction = GoogleGeminiCli.Content(; parts = [GoogleGeminiCli.Part(; text = system_prompt)])
        req = GoogleGeminiCli.build_request(
            model,
            contents,
            project_id;
            systemInstruction = system_instruction,
            tools = tools,
            toolChoice = tool_choice,
            maxTokens = max_tokens,
            temperature = temperature,
            thinking = thinking,
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
            body = JSON.json(req),
            sse_callback = google_gemini_cli_event_callback(
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
        return AgentResponse(; message = assistant_message, usage, stop_reason)
    elseif model.api == "openai-codex-responses"
        creds = codex_login()

        assistant_message = AssistantMessage(; response_id = state.response_id)
        started = Ref(false)
        ended = Ref(false)
        response_usage = Ref{Any}(nothing)
        response_status = Ref{Union{Nothing, String}}(nothing)
        tool_call_accumulators = Dict{String, ToolCallAccumulator}()

        codex_kw = Dict{Symbol, Any}(pairs(kw_nt))
        haskey(codex_kw, :instructions) && delete!(codex_kw, :instructions)

        session_id = pop!(codex_kw, :session_id, nothing)
        session_id === nothing && (session_id = pop!(codex_kw, :sessionId, nothing))

        reasoning_effort = pop!(codex_kw, :reasoning_effort, nothing)
        reasoning_effort === nothing && (reasoning_effort = pop!(codex_kw, :reasoningEffort, nothing))
        if reasoning_effort === nothing && haskey(codex_kw, :reasoning)
            reasoning_effort = pop!(codex_kw, :reasoning, nothing)
        end
        reasoning_summary = pop!(codex_kw, :reasoning_summary, nothing)
        reasoning_summary === nothing && (reasoning_summary = pop!(codex_kw, :reasoningSummary, nothing))
        text_verbosity = pop!(codex_kw, :textVerbosity, nothing)
        text_verbosity === nothing && (text_verbosity = pop!(codex_kw, :text_verbosity, nothing))
        include_opt = pop!(codex_kw, :include, nothing)
        max_tokens = pop!(codex_kw, :maxTokens, nothing)

        tools = OpenAICodex.build_codex_tools(agent.tools)
        current_input = codex_build_input(agent, state, input)

        codex_instr = OpenAICodex.codex_instructions()
        bridge_text = OpenAICodex.build_codex_pi_bridge(agent.tools)
        user_system_prompt = agent.prompt
        system_prompt = OpenAICodex.build_codex_system_prompt(
            ; codex_instructions = codex_instr,
            bridge_text = bridge_text,
            user_system_prompt = user_system_prompt,
        )

        request_body = Dict{String, Any}(
            "model" => model.id,
            "input" => current_input,
            "stream" => true,
            "instructions" => system_prompt.instructions,
        )
        tools !== nothing && (request_body["tools"] = tools)
        session_id !== nothing && (request_body["prompt_cache_key"] = session_id)
        max_tokens !== nothing && (request_body["max_output_tokens"] = max_tokens)

        if model.kw !== nothing
            for (k, v) in pairs(model.kw)
                request_body[string(k)] = v
            end
        end
        for (k, v) in codex_kw
            request_body[string(k)] = v
        end

        OpenAICodex.transform_request_body!(
            request_body;
            reasoning_effort = reasoning_effort === nothing ? nothing : string(reasoning_effort),
            reasoning_summary = reasoning_summary === nothing ? nothing : string(reasoning_summary),
            text_verbosity = text_verbosity === nothing ? nothing : string(text_verbosity),
            include = include_opt,
            developer_messages = system_prompt.developer_messages,
        )

        headers = OpenAICodex.create_codex_headers(
            model.headers === nothing ? nothing : Dict(model.headers),
            creds.account_id,
            creds.access_token,
            session_id,
        )

        base_url = isempty(model.baseUrl) ? OpenAICodex.CODEX_BASE_URL : model.baseUrl
        base_with_slash = endswith(base_url, "/") ? base_url : string(base_url, "/")
        url = OpenAICodex.rewrite_url_for_codex(string(base_with_slash, "responses"))

        OpenAICodex.log_codex_debug(
            "codex request", Dict(
                "url" => url,
                "model" => model.id,
                "reasoningEffort" => reasoning_effort,
                "reasoningSummary" => reasoning_summary,
                "textVerbosity" => text_verbosity,
                "include" => include_opt,
                "instructions_length" => length(string(get(request_body, "instructions", ""))),
                "instructions_preview" => first(string(get(request_body, "instructions", "")), min(200, length(string(get(request_body, "instructions", ""))))),
                "developer_messages" => system_prompt.developer_messages,
                "headers" => OpenAICodex.redact_headers(headers),
            )
        )

        resp = HTTP.post(
            url,
            headers;
            body = JSON.json(request_body),
            sse_callback = openai_codex_event_callback(
                f,
                agent,
                assistant_message,
                started,
                ended,
                response_usage,
                response_status,
                tool_call_accumulators,
            ),
            merged_http_kw...,
        )

        if !(resp.status in 200:299)
            info = OpenAICodex.parse_codex_error(resp)
            msg = info.friendly_message === nothing ? info.message : info.friendly_message
            throw(ErrorException(msg))
        end

        OpenAICodex.log_codex_debug(
            "codex response", Dict(
                "url" => resp.request.url,
                "status" => resp.status,
                "content_type" => HTTP.header(resp, "content-type"),
                "cf_ray" => HTTP.header(resp, "cf-ray"),
            )
        )

        if started[] && !ended[]
            ended[] = true
            f(MessageEndEvent(:assistant, assistant_message))
        end

        for (call_id, acc) in tool_call_accumulators
            acc.name === nothing && continue
            args = isempty(acc.arguments) ? "{}" : acc.arguments
            call = AgentToolCall(; call_id = call_id, name = acc.name, arguments = args)
            if !any(tc -> tc.call_id == call_id, assistant_message.tool_calls)
                push!(assistant_message.tool_calls, call)
                tool = findtool(agent.tools, call.name)
                ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                f(ToolCallRequestEvent(ptc, tool.requires_approval))
            end
        end

        usage = codex_usage_from_response(response_usage[])
        stop_reason = codex_stop_reason(response_status[], assistant_message.tool_calls)
        return AgentResponse(; message = assistant_message, usage, stop_reason)
    else
        throw(ArgumentError("$(model.name) using $(model.api) api currently unsupported"))
    end
end
