using HTTP
using JSON
using UUIDs

# HTTP.jl provides HTTP.SSE.SSEEvent with data::String field
# SSE callbacks receive (event) — HTTP.jl's wrap_callback handles the stream argument

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
        parsed = JSON.parse(arguments)
        parsed isa AbstractDict || return Dict{String, Any}()
        return Dict{String, Any}(parsed)
    catch
        return Dict{String, Any}()
    end
end

function assistant_message_for_model(model::Model; response_id::Union{Nothing, String} = nothing)
    return AssistantMessage(;
        response_id = response_id,
        provider = model.provider,
        api = model.api,
        model = model.id,
    )
end

function normalize_mistral_tool_id(id::String)
    normalized = replace(id, r"[^A-Za-z0-9]" => "")
    if length(normalized) < 9
        padding = "ABCDEFGHI"
        normalized *= padding[1:(9 - length(normalized))]
    elseif length(normalized) > 9
        normalized = normalized[1:9]
    end
    return normalized
end

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

function transform_messages(messages::Vector{AgentMessage}, model::Model; normalize_tool_call_id::Function = identity)
    tool_call_id_map = Dict{String, String}()
    transformed = AgentMessage[]
    for msg in messages
        if msg isa UserMessage
            push!(transformed, msg)
        elseif msg isa ToolResultMessage
            call_id = get(() -> msg.call_id, tool_call_id_map, msg.call_id)
            if call_id != msg.call_id
                push!(transformed, ToolResultMessage(; call_id, name = msg.name, content = msg.content, is_error = msg.is_error))
            else
                push!(transformed, msg)
            end
        elseif msg isa AssistantMessage
            is_same = msg.provider == model.provider && msg.api == model.api && msg.model == model.id
            blocks = AssistantContentBlock[]
            for block in msg.content
                if block isa TextContent
                    isempty(block.text) && continue
                    push!(blocks, TextContent(; text = block.text, textSignature = is_same ? block.textSignature : nothing))
                elseif block isa ThinkingContent
                    isempty(block.thinking) && continue
                    if is_same && block.thinkingSignature !== nothing && !isempty(block.thinkingSignature)
                        push!(blocks, ThinkingContent(; thinking = block.thinking, thinkingSignature = block.thinkingSignature))
                    else
                        push!(blocks, TextContent(; text = block.thinking))
                    end
                elseif block isa ToolCallContent
                    normalized = normalize_tool_call_id(block.id)
                    if normalized != block.id
                        tool_call_id_map[block.id] = normalized
                    end
                    thought_sig = is_same ? block.thoughtSignature : nothing
                    push!(blocks, ToolCallContent(; id = normalized, name = block.name, arguments = block.arguments, thoughtSignature = thought_sig))
                end
            end
            push!(transformed, AssistantMessage(;
                response_id = msg.response_id,
                provider = msg.provider,
                api = msg.api,
                model = msg.model,
                content = blocks,
                tool_calls = msg.tool_calls,
            ))
        end
    end

    normalized = AgentMessage[]
    pending = ToolCallContent[]
    resolved = Set{String}()

    function flush_pending!()
        isempty(pending) && return
        for call in pending
            if !(call.id in resolved)
                push!(normalized, ToolResultMessage(;
                    call_id = call.id,
                    name = call.name,
                    content = ToolResultContentBlock[TextContent("No result provided")],
                    is_error = true,
                ))
            end
        end
        empty!(pending)
        empty!(resolved)
        return
    end

    for msg in transformed
        if msg isa AssistantMessage
            flush_pending!()
            push!(normalized, msg)
            empty!(pending)
            empty!(resolved)
            for block in msg.content
                block isa ToolCallContent && push!(pending, block)
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

function codex_input_from_message(msg::AgentMessage)
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
        parts = Any[]
        thinking = message_thinking(msg)
        if !isempty(thinking)
            push!(
                parts, Dict(
                    "type" => "reasoning",
                    "summary" => [Dict("type" => "summary_text", "text" => thinking)],
                    "status" => "completed",
                )
            )
        end
        text = message_text(msg)
        if !isempty(text)
            push!(
                parts, Dict(
                    "type" => "message",
                    "role" => "assistant",
                    "content" => [Dict("type" => "output_text", "text" => text)],
                    "status" => "completed",
                )
            )
        end
        tool_blocks = ToolCallContent[]
        for block in msg.content
            block isa ToolCallContent && push!(tool_blocks, block)
        end
        if isempty(tool_blocks)
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
        else
            for block in tool_blocks
                push!(
                    parts, Dict(
                        "type" => "function_call",
                        "call_id" => block.id,
                        "name" => block.name,
                        "arguments" => JSON.json(block.arguments),
                    )
                )
            end
        end
        return parts
    elseif msg isa ToolResultMessage
        output = message_text(msg)
        return Any[
            Dict(
                "type" => "function_call_output",
                "call_id" => msg.call_id,
                "output" => output,
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
    elseif input isa UserMessage
        append!(items, codex_input_from_message(input))
    elseif input isa Vector{UserContentBlock}
        append!(items, codex_input_from_message(UserMessage(input)))
    elseif input isa Vector{ToolResultMessage}
        for result in input
            push!(items, Dict("type" => "function_call_output", "call_id" => result.call_id, "output" => message_text(result)))
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
        append_thinking!(assistant_message, delta)
        return f(MessageUpdateEvent(:assistant, assistant_message, :reasoning, delta, item_id))
    end

    function update_text(delta::String, item_id)
        ensure_started()
        append_text!(assistant_message, delta)
        return f(MessageUpdateEvent(:assistant, assistant_message, :text, delta, item_id))
    end

    return function (event)
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
            append_text!(assistant_message, delta)
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
                    set_last_thinking!(assistant_message, join(text_parts, "\n\n"))
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
                    set_last_text!(assistant_message, String(take!(io)))
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
                push!(assistant_message.content, ToolCallContent(; id = call_id, name, arguments = parse_tool_arguments(args)))
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
    compat = openai_completions_resolve_compat(model)
    return compat.thinkingFormat == "zai"
end

function openai_completions_supports_reasoning_effort(model::Model)
    compat = openai_completions_resolve_compat(model)
    return compat.supportsReasoningEffort
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

function agent_system_prompt(agent::Agent)
    registry = agent.skills
    if registry === nothing || isempty(registry.skills)
        return agent.prompt
    end
    return append_available_skills(agent.prompt, values(registry.skills))
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

        if msg isa UserMessage
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
            if !isempty(non_empty_thinking) && compat.requiresThinkingAsText
                thinking_text = join((b.thinking for b in non_empty_thinking), "\n\n")
                if assistant_msg.content === nothing || assistant_msg.content === ""
                    assistant_msg.content = OpenAICompletions.ContentPart[OpenAICompletions.ContentPart(; type = "text", text = thinking_text)]
                elseif assistant_msg.content isa String
                    assistant_msg.content = thinking_text * assistant_msg.content
                else
                    pushfirst!(assistant_msg.content, OpenAICompletions.ContentPart(; type = "text", text = thinking_text))
                end
            elseif !isempty(non_empty_thinking)
                signature = non_empty_thinking[1].thinkingSignature
                if signature !== nothing && !isempty(signature)
                    extra = assistant_msg.extra === nothing ? Dict{String, Any}() : assistant_msg.extra
                    extra[signature] = join((b.thinking for b in non_empty_thinking), "\n")
                    assistant_msg.extra = extra
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
    )
    return function (event)
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
            append_text!(assistant_message, delta.content)
            f(MessageUpdateEvent(:assistant, assistant_message, :text, delta.content, nothing))
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
    )
    stop_on_tool_call = get(ENV, "AGENTIF_STOP_ON_TOOL_CALL", "") != ""
    return function (event)
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
                tool = findtool(agent.tools, call.name)
                ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                f(ToolCallRequestEvent(ptc, tool.requires_approval))
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

const GOOGLE_THOUGHT_SIGNATURE_REGEX = r"^[A-Za-z0-9+/]+={0,2}$"

function google_requires_tool_call_id(model_id::String)
    return startswith(model_id, "claude-") || startswith(model_id, "gpt-oss-")
end

function google_normalize_tool_call_id(model_id::String, id::String)
    google_requires_tool_call_id(model_id) || return id
    normalized = replace(id, r"[^A-Za-z0-9_-]" => "_")
    return normalized[1:min(length(normalized), 64)]
end

function google_valid_thought_signature(signature::Union{Nothing, String})
    signature === nothing && return false
    isempty(signature) && return false
    length(signature) % 4 == 0 || return false
    return occursin(GOOGLE_THOUGHT_SIGNATURE_REGEX, signature)
end

function google_resolve_thought_signature(is_same::Bool, signature::Union{Nothing, String})
    return is_same && google_valid_thought_signature(signature) ? signature : nothing
end

google_supports_multimodal_function_response(model_id::String) = occursin("gemini-3", lowercase(model_id))

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

function google_generative_build_contents(agent::Agent, state::AgentState, input::AgentTurnInput, model::Model)
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

    contents = GoogleGenerativeAI.Content[]
    for msg in normalized
        if msg isa UserMessage
            parts = GoogleGenerativeAI.Part[]
            for block in msg.content
                if block isa TextContent
                    isempty(strip(block.text)) && continue
                    push!(parts, GoogleGenerativeAI.Part(; text = block.text))
                elseif block isa ImageContent
                    "image" in model.input || continue
                    push!(parts, GoogleGenerativeAI.Part(; inlineData = GoogleGenerativeAI.InlineData(; mimeType = block.mimeType, data = block.data)))
                end
            end
            isempty(parts) && continue
            push!(contents, GoogleGenerativeAI.Content(; role = "user", parts))
        elseif msg isa AssistantMessage
            parts = GoogleGenerativeAI.Part[]
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
                    push!(parts, GoogleGenerativeAI.Part(; text = block.text, thoughtSignature = signature))
                elseif block isa ThinkingContent
                    isempty(strip(block.thinking)) && continue
                    if is_same
                        signature = google_resolve_thought_signature(is_same, block.thinkingSignature)
                        push!(parts, GoogleGenerativeAI.Part(; text = block.thinking, thought = true, thoughtSignature = signature))
                    else
                        push!(parts, GoogleGenerativeAI.Part(; text = block.thinking))
                    end
                elseif block isa ToolCallContent
                    signature = google_resolve_thought_signature(is_same, block.thoughtSignature)
                    is_gemini3 = occursin("gemini-3", lowercase(model.id))
                    if is_gemini3 && signature === nothing
                        args_str = JSON.json(block.arguments)
                        push!(
                            parts,
                            GoogleGenerativeAI.Part(;
                                text = "[Historical context: a different model called tool \"$(block.name)\" with arguments: $(args_str). Do not mimic this format - use proper function calling.]",
                            ),
                        )
                    else
                        call = GoogleGenerativeAI.FunctionCall(;
                            name = block.name,
                            args = block.arguments,
                            id = google_requires_tool_call_id(model.id) ? block.id : nothing,
                        )
                        push!(parts, GoogleGenerativeAI.Part(; functionCall = call, thoughtSignature = signature))
                    end
                end
            end
            isempty(parts) && continue
            push!(contents, GoogleGenerativeAI.Content(; role = "model", parts))
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
            image_parts = GoogleGenerativeAI.Part[
                GoogleGenerativeAI.Part(; inlineData = GoogleGenerativeAI.InlineData(; mimeType = block.mimeType, data = block.data)) for block in image_blocks
            ]
            include_id = google_requires_tool_call_id(model.id)
            supports_multimodal = google_supports_multimodal_function_response(model.id)
            response_payload = msg.is_error ? Dict("error" => response_value) : Dict("output" => response_value)
            response = GoogleGenerativeAI.FunctionResponse(;
                name = msg.name,
                response = response_payload,
                id = include_id ? msg.call_id : nothing,
                parts = (has_images && supports_multimodal) ? image_parts : nothing,
            )
            part = GoogleGenerativeAI.Part(; functionResponse = response)
            last_content = isempty(contents) ? nothing : contents[end]
            if last_content !== nothing && last_content.role == "user" && last_content.parts !== nothing &&
                    any(p -> p.functionResponse !== nothing, last_content.parts)
                push!(last_content.parts, part)
            else
                push!(contents, GoogleGenerativeAI.Content(; role = "user", parts = [part]))
            end
            if has_images && !supports_multimodal
                push!(contents, GoogleGenerativeAI.Content(; role = "user", parts = [GoogleGenerativeAI.Part(; text = "Tool result image:"), image_parts...]))
            end
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
    return function (event)
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
        if msg isa UserMessage
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
    )
    return function (event)
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
        assistant_message = assistant_message_for_model(model; response_id = state.response_id)
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
        compat = openai_completions_resolve_compat(model)
        messages, has_tool_history = openai_completions_build_messages(agent, state, input, model)
        tools = openai_completions_build_tools(agent.tools; force_empty = isempty(agent.tools) && has_tool_history)
        assistant_message = assistant_message_for_model(model; response_id = state.response_id)
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
        if haskey(stream_kw, :reasoning_effort) && !compat.supportsReasoningEffort
            stream_kw = Base.structdiff(stream_kw, (; reasoning_effort = nothing))
        end
        if compat.thinkingFormat == "zai" && model.reasoning && !haskey(stream_kw, :thinking)
            thinking_type = reasoning_effort_value === nothing ? "disabled" : "enabled"
            stream_kw = merge(stream_kw, (; thinking = Dict("type" => thinking_type)))
        end

        max_tokens_value = nothing
        if haskey(stream_kw, :maxTokens)
            max_tokens_value = stream_kw[:maxTokens]
            stream_kw = Base.structdiff(stream_kw, (; maxTokens = nothing))
        elseif haskey(stream_kw, :max_tokens)
            max_tokens_value = stream_kw[:max_tokens]
            stream_kw = Base.structdiff(stream_kw, (; max_tokens = nothing))
        elseif haskey(stream_kw, :max_completion_tokens)
            max_tokens_value = stream_kw[:max_completion_tokens]
            stream_kw = Base.structdiff(stream_kw, (; max_completion_tokens = nothing))
        end

        if max_tokens_value !== nothing
            if compat.maxTokensField == "max_tokens"
                stream_kw = merge(stream_kw, (; max_tokens = max_tokens_value))
            else
                stream_kw = merge(stream_kw, (; max_completion_tokens = max_tokens_value))
            end
        end

        if compat.supportsUsageInStreaming && use_stream && !haskey(stream_kw, :stream_options)
            stream_kw = merge(stream_kw, (; stream_options = Dict("include_usage" => true)))
        end
        if compat.supportsStore && !haskey(stream_kw, :store)
            stream_kw = merge(stream_kw, (; store = false))
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
                push!(assistant_message.content, ToolCallContent(; id = call_id, name = acc.name, arguments = parse_tool_arguments(args)))
                tool = findtool(agent.tools, call.name)
                ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                f(ToolCallRequestEvent(ptc, tool.requires_approval))
            end
        else
            response = JSON.parse(HTTP.post(url, headers; body = JSON.json(req), merged_http_kw...).body, OpenAICompletions.Response)
            isempty(response.choices) && return AgentResponse(; message = assistant_message, usage = Usage(), stop_reason = :stop)
            choice = response.choices[1]
            if choice.message.content !== nothing
                if choice.message.content isa String
                    append_text!(assistant_message, choice.message.content)
                else
                    for part in choice.message.content
                        part.type == "text" || continue
                        part.text === nothing && continue
                        append_text!(assistant_message, part.text)
                    end
                end
            end
            reasoning_parts = String[]
            for field in (:reasoning_content, :reasoning, :reasoning_text)
                value = getfield(choice.message, field)
                value === nothing && continue
                isempty(value) && continue
                push!(reasoning_parts, value)
            end
            isempty(reasoning_parts) || append_thinking!(assistant_message, join(reasoning_parts, "\n\n"))
            text = message_text(assistant_message)
            if !isempty(text)
                f(MessageStartEvent(:assistant, assistant_message))
                f(MessageUpdateEvent(:assistant, assistant_message, :text, text, nothing))
                f(MessageEndEvent(:assistant, assistant_message))
            end
            if choice.message.tool_calls !== nothing
                for tc in choice.message.tool_calls
                    call_id = tc.id === nothing ? new_call_id("openai") : tc.id
                    args = tc.function.arguments === nothing ? "{}" : tc.function.arguments
                    call = AgentToolCall(; call_id, name = tc.function.name, arguments = args)
                    push!(assistant_message.tool_calls, call)
                    push!(assistant_message.content, ToolCallContent(; id = call_id, name = tc.function.name, arguments = parse_tool_arguments(args)))
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
        messages = anthropic_build_messages(agent, state, input, tool_name_map, model)
        assistant_message = assistant_message_for_model(model; response_id = state.response_id)
        started = Ref(false)
        ended = Ref(false)
        stop_reason = Ref{Union{Nothing, String}}(nothing)
        latest_usage = Ref{Union{Nothing, AnthropicMessages.Usage}}(nothing)
        blocks_by_index = Dict{Int, AssistantContentBlock}()
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
        disable_streaming = get(ENV, "AGENTIF_DISABLE_STREAMING", "") != ""
        req = AnthropicMessages.Request(
            ; model = model.id,
            messages,
            max_tokens,
            stream = !disable_streaming,
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
        if disable_streaming
            response = JSON.parse(HTTP.post(url, headers; body = JSON.json(req), merged_http_kw...).body, AnthropicMessages.Response)
            response.id !== nothing && (assistant_message.response_id = response.id)
            response.stop_reason !== nothing && (stop_reason[] = response.stop_reason)

            for block in response.content
                if block isa AnthropicMessages.TextBlock
                    append_text!(assistant_message, block.text)
                elseif block isa AnthropicMessages.ThinkingBlock
                    thinking = ThinkingContent(;
                        thinking = block.thinking,
                        thinkingSignature = block.signature,
                    )
                    push!(assistant_message.content, thinking)
                elseif block isa AnthropicMessages.ToolUseBlock
                    tool_name = anthropic_internal_tool_name(tool_name_reverse_map, block.name)
                    args = block.input isa AbstractDict ? Dict{String, Any}(block.input) : Dict{String, Any}()
                    tool_block = ToolCallContent(;
                        id = block.id,
                        name = tool_name,
                        arguments = args,
                    )
                    push!(assistant_message.content, tool_block)
                    call = AgentToolCall(; call_id = block.id, name = tool_name, arguments = JSON.json(args))
                    push!(assistant_message.tool_calls, call)
                    tool = findtool(agent.tools, call.name)
                    ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                    f(ToolCallRequestEvent(ptc, tool.requires_approval))
                end
            end

            text = message_text(assistant_message)
            if !isempty(text)
                f(MessageStartEvent(:assistant, assistant_message))
                f(MessageUpdateEvent(:assistant, assistant_message, :text, text, nothing))
                f(MessageEndEvent(:assistant, assistant_message))
            end

            latest_usage[] = response.usage
            usage = anthropic_usage_from_response(latest_usage[])
            final_stop = anthropic_stop_reason(stop_reason[], assistant_message.tool_calls)
            return AgentResponse(; message = assistant_message, usage, stop_reason = final_stop)
        else
            try
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
            catch e
                if !(e isa StopStreaming)
                    rethrow()
                end
            end

            if started[] && !ended[]
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end

            usage = anthropic_usage_from_response(latest_usage[])
            final_stop = anthropic_stop_reason(stop_reason[], assistant_message.tool_calls)
            return AgentResponse(; message = assistant_message, usage, stop_reason = final_stop)
        end
    elseif model.api == "google-generative-ai"
        tools = google_generative_build_tools(agent.tools)
        contents = google_generative_build_contents(agent, state, input, model)
        assistant_message = assistant_message_for_model(model; response_id = state.response_id)
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
        contents = google_gemini_cli_build_contents(agent, state, input, model)
        assistant_message = assistant_message_for_model(model; response_id = state.response_id)
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

        assistant_message = assistant_message_for_model(model; response_id = state.response_id)
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
