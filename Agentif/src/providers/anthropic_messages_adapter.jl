function anthropic_build_tools(
        tools::Vector{<:AgentTool}, tool_name_map::Dict{String, String})
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

function anthropic_tool_name_maps(tools::Vector{<:AgentTool}, is_oauth::Bool)
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

# Prompt caching, mirroring pi-mono's anthropic provider (getCacheControl,
# packages/ai/src/providers/anthropic.ts): a breakpoint on the system prompt and one
# on the last user message, so the whole conversation prefix is served from cache
# instead of being re-billed at uncached rates every turn.
# `resolve_openai_cache_retention` is the shared none/short/long resolver.
function anthropic_cache_control(base_url::AbstractString, cache_retention)
    retention = resolve_openai_cache_retention(cache_retention)
    retention == "none" && return nothing
    # The 1h TTL is only enabled for Anthropic's own endpoint. Compare the parsed
    # host exactly; a substring check also matches proxy or attacker-controlled hosts
    # such as `api.anthropic.com.example.test`.
    native_host = try
        rstrip(lowercase(HTTP.URI(String(base_url)).host), '.') == "api.anthropic.com"
    catch
        false
    end
    ttl = retention == "long" && native_host ? "1h" : nothing
    return AnthropicMessages.CacheControl(; type = "ephemeral", ttl)
end

function anthropic_system_blocks(prompt::String, cache_control::Union{Nothing, AnthropicMessages.CacheControl})
    isempty(strip(prompt)) && return nothing
    return AnthropicMessages.TextBlock[AnthropicMessages.TextBlock(; text = prompt, cache_control)]
end

function anthropic_oauth_system_blocks(prompt::String, cache_control::Union{Nothing, AnthropicMessages.CacheControl} = AnthropicMessages.CacheControl(; type = "ephemeral"))
    blocks = AnthropicMessages.TextBlock[]
    push!(blocks, AnthropicMessages.TextBlock(; text = "You are Claude Code, Anthropic's official CLI for Claude.", cache_control))
    isempty(prompt) || push!(blocks, AnthropicMessages.TextBlock(; text = prompt, cache_control))
    return blocks
end

# Breakpoint on the last block of the trailing user message. Anthropic allows at most
# four; the OAuth spoof path already spends two on its system blocks, so this one is
# additive rather than a second pass over the system prompt.
function anthropic_apply_cache_control!(messages::Vector{AnthropicMessages.Message}, cache_control::Union{Nothing, AnthropicMessages.CacheControl})
    (cache_control === nothing || isempty(messages)) && return messages
    last_message = messages[end]
    last_message.role == "user" || return messages
    content = last_message.content
    if content isa AbstractString
        block = AnthropicMessages.TextBlock(; text = content, cache_control)
        messages[end] = AnthropicMessages.Message(; role = "user", content = AnthropicMessages.ContentBlock[block])
    elseif content isa AbstractVector && !isempty(content)
        block = content[end]
        if block isa AnthropicMessages.TextBlock || block isa AnthropicMessages.ImageBlock || block isa AnthropicMessages.ToolResultBlock
            block.cache_control = cache_control
        end
    end
    return messages
end

# --- Per-model thinking/effort capabilities -----------------------------------------
# Prefer the registry's `compat` and `thinkingLevelMap` metadata. The model-name
# fallbacks keep manually constructed models and older snapshots working.

anthropic_model_matches(model_id::AbstractString, patterns) =
    any(p -> occursin(p, lowercase(String(model_id))), patterns)

# Mythos Preview is intentionally absent. It supports both adaptive thinking and
# manual `budget_tokens`; classifying it as adaptive-only corrupts explicit requests.
const ANTHROPIC_ADAPTIVE_ONLY_MODELS = (
    "opus-4-7", "opus-4.7", "opus-4-8", "opus-4.8",
    "opus-5", "sonnet-5", "fable-5", "mythos-5",
)

const ANTHROPIC_ADAPTIVE_THINKING_MODELS = (
    ANTHROPIC_ADAPTIVE_ONLY_MODELS..., "mythos-preview",
    "opus-4-6", "opus-4.6", "sonnet-4-6", "sonnet-4.6",
)

const ANTHROPIC_ALWAYS_THINKING_MODELS = ("fable-5", "mythos-5", "mythos-preview")
const ANTHROPIC_EFFORT_MODELS = (ANTHROPIC_ADAPTIVE_THINKING_MODELS..., "opus-4-5", "opus-4.5")
const ANTHROPIC_MAX_EFFORT_MODELS = ANTHROPIC_ADAPTIVE_THINKING_MODELS
const ANTHROPIC_XHIGH_EFFORT_MODELS = (
    "opus-4-7", "opus-4.7", "opus-4-8", "opus-4.8", "opus-5", "sonnet-5", "fable-5", "mythos-5",
)
const ANTHROPIC_REJECTS_SAMPLING_MODELS = (
    ANTHROPIC_ADAPTIVE_ONLY_MODELS..., "mythos-preview",
)

anthropic_supports_adaptive_thinking(model_id::AbstractString) = anthropic_model_matches(model_id, ANTHROPIC_ADAPTIVE_THINKING_MODELS)
anthropic_supports_extended_thinking(model_id::AbstractString) = !anthropic_model_matches(model_id, ANTHROPIC_ADAPTIVE_ONLY_MODELS)
anthropic_thinking_always_on(model_id::AbstractString) = anthropic_model_matches(model_id, ANTHROPIC_ALWAYS_THINKING_MODELS)
anthropic_supports_effort(model_id::AbstractString) = anthropic_model_matches(model_id, ANTHROPIC_EFFORT_MODELS)
anthropic_supports_max_effort(model_id::AbstractString) = anthropic_model_matches(model_id, ANTHROPIC_MAX_EFFORT_MODELS)
anthropic_supports_xhigh_effort(model_id::AbstractString) = anthropic_model_matches(model_id, ANTHROPIC_XHIGH_EFFORT_MODELS)
anthropic_rejects_sampling_params(model_id::AbstractString) = anthropic_model_matches(model_id, ANTHROPIC_REJECTS_SAMPLING_MODELS)

function anthropic_compat_flag(model::Model, key::AbstractString)
    model.compat === nothing && return nothing
    value = get(() -> nothing, model.compat, String(key))
    return value isa Bool ? value : nothing
end

function anthropic_supports_adaptive_thinking(model::Model)
    override = anthropic_compat_flag(model, "forceAdaptiveThinking")
    return override === nothing ? anthropic_supports_adaptive_thinking(model.id) : override
end
function anthropic_supports_extended_thinking(model::Model)
    override = anthropic_compat_flag(model, "forceAdaptiveThinking")
    override === false && return true
    return anthropic_supports_extended_thinking(model.id)
end
function anthropic_thinking_always_on(model::Model)
    level_map = model.thinkingLevelMap
    if level_map !== nothing && haskey(level_map, "off")
        return level_map["off"] === nothing
    end
    return anthropic_thinking_always_on(model.id)
end
function anthropic_supports_effort(model::Model)
    override = anthropic_compat_flag(model, "forceAdaptiveThinking")
    override !== nothing && return override
    return anthropic_supports_effort(model.id)
end
function anthropic_rejects_sampling_params(model::Model)
    supports_temperature = anthropic_compat_flag(model, "supportsTemperature")
    return supports_temperature === nothing ?
        anthropic_rejects_sampling_params(model.id) : !supports_temperature
end

# Interleaved thinking is automatic in adaptive mode. In manual mode it needs a
# beta header except on Haiku 4.5 (unsupported) and Opus 4.6 (no manual-mode
# interleaving). Sonnet 4.6 still accepts the header in manual mode.
function anthropic_needs_interleaved_thinking_beta(model::Model, thinking)
    anthropic_thinking_type(thinking) == "enabled" || return false
    anthropic_model_matches(model.id, ("haiku-4-5", "haiku-4.5")) && return false
    anthropic_model_matches(model.id, ("opus-4-6", "opus-4.6")) && return false
    return true
end

function anthropic_effort_for_level(level::AbstractString, model_id::AbstractString)
    lvl = lowercase(strip(String(level)))
    lvl == "minimal" && (lvl = "low")
    lvl in ("low", "medium", "high") && return lvl
    if lvl in ("xhigh", "max")
        lvl == "xhigh" && anthropic_supports_xhigh_effort(model_id) && return "xhigh"
        anthropic_supports_max_effort(model_id) && return "max"
        return "high"
    end
    return "high"
end

function anthropic_effort_for_level(level::AbstractString, model::Model)
    lvl = lowercase(strip(String(level)))
    lvl == "minimal" && (lvl = "low")
    level_map = model.thinkingLevelMap
    if level_map !== nothing
        mapped = get(() -> nothing, level_map, lvl)
        mapped isa AbstractString && return String(mapped)
        if lvl == "xhigh"
            max_mapped = get(() -> nothing, level_map, "max")
            max_mapped isa AbstractString && return String(max_mapped)
        end
    end
    return anthropic_effort_for_level(lvl, model.id)
end

const ANTHROPIC_DEFAULT_THINKING_BUDGETS = Dict("minimal" => 1024, "low" => 2048, "medium" => 8192, "high" => 16384)
const ANTHROPIC_MIN_OUTPUT_TOKENS = 1024

# pi-mono's adjustMaxTokensForThinking: grow max_tokens to make room for the thinking
# budget, clamp to the model ceiling, and keep budget_tokens strictly below max_tokens
# (the API rejects budget_tokens >= max_tokens).
function anthropic_adjust_max_tokens_for_thinking(base_max_tokens::Int, model_max_tokens::Int, level::AbstractString)
    base_max_tokens > 0 || throw(ArgumentError("max_tokens must be positive"))
    model_max_tokens > ANTHROPIC_MIN_OUTPUT_TOKENS ||
        throw(ArgumentError("model maxTokens must exceed $ANTHROPIC_MIN_OUTPUT_TOKENS for extended thinking"))
    lvl = lowercase(strip(String(level)))
    lvl in ("xhigh", "max") && (lvl = "high")
    budget = get(() -> ANTHROPIC_DEFAULT_THINKING_BUDGETS["high"], ANTHROPIC_DEFAULT_THINKING_BUDGETS, lvl)
    max_tokens = min(base_max_tokens + budget, model_max_tokens)
    if max_tokens <= budget
        budget = max_tokens - ANTHROPIC_MIN_OUTPUT_TOKENS
    end
    budget >= 1024 ||
        throw(ArgumentError("max_tokens is too small for the minimum 1,024-token thinking budget"))
    return (; max_tokens, thinking_budget = budget)
end

# Maps a reasoning-effort level onto the request fields, picking the mechanism the model
# actually supports: adaptive thinking where available, extended thinking (budget_tokens)
# otherwise. `output_config.effort` rides along on every model that supports effort,
# including Opus 4.5 where it composes with a token budget.
function anthropic_thinking_request(model::Model, level, base_max_tokens::Int)
    (level === nothing || !model.reasoning) && return (; thinking = nothing, output_config = nothing, max_tokens = base_max_tokens)
    lvl = string(level)
    output_config = anthropic_supports_effort(model) ?
        AnthropicMessages.OutputConfig(; effort = anthropic_effort_for_level(lvl, model)) : nothing
    if anthropic_supports_adaptive_thinking(model)
        # `display` defaults to "omitted" on the 5-generation models, which would stream
        # empty thinking blocks; Agentif surfaces reasoning, so ask for summaries.
        return (;
            thinking = AnthropicMessages.ThinkingConfig(; type = "adaptive", display = "summarized"),
            output_config,
            max_tokens = base_max_tokens,
        )
    end
    adjusted = anthropic_adjust_max_tokens_for_thinking(base_max_tokens, model.maxTokens, lvl)
    return (;
        thinking = AnthropicMessages.ThinkingConfig(; type = "enabled", budget_tokens = adjusted.thinking_budget),
        output_config,
        max_tokens = adjusted.max_tokens,
    )
end

function anthropic_thinking_type(thinking)
    thinking isa AnthropicMessages.ThinkingConfig && return thinking.type
    thinking isa AbstractDict && return get(() -> get(() -> nothing, thinking, :type), thinking, "type")
    thinking isa NamedTuple && return get(() -> nothing, thinking, :type)
    return nothing
end

function anthropic_thinking_field(thinking, key::Symbol)
    thinking isa AnthropicMessages.ThinkingConfig && return getproperty(thinking, key)
    if thinking isa AbstractDict
        value = get(() -> nothing, thinking, String(key))
        return value === nothing ? get(() -> nothing, thinking, key) : value
    end
    thinking isa NamedTuple && return get(() -> nothing, thinking, key)
    return nothing
end

function anthropic_output_effort(output_config)
    output_config isa AnthropicMessages.OutputConfig && return output_config.effort
    if output_config isa AbstractDict
        value = get(() -> nothing, output_config, "effort")
        return value === nothing ? get(() -> nothing, output_config, :effort) : value
    end
    output_config isa NamedTuple && return get(() -> nothing, output_config, :effort)
    return nothing
end

function anthropic_disabled_effort_conflict(model::Model, thinking, output_config)
    anthropic_thinking_type(thinking) == "disabled" || return false
    anthropic_model_matches(model.id, ("opus-5",)) || return false
    effort = anthropic_output_effort(output_config)
    return effort !== nothing && lowercase(String(effort)) in ("xhigh", "max")
end

function anthropic_tool_choice_type(tool_choice)
    if tool_choice isa AbstractDict
        value = get(() -> nothing, tool_choice, "type")
        return value === nothing ? get(() -> nothing, tool_choice, :type) : value
    end
    tool_choice isa NamedTuple && return get(() -> nothing, tool_choice, :type)
    tool_choice isa AbstractString && return tool_choice
    return nothing
end

# Caller-supplied `thinking` kwargs win over the derived config; we still need to know
# whether thinking ends up on so the sampling guard and beta header stay correct.
function anthropic_thinking_is_enabled(thinking)
    thinking === nothing && return false
    type = anthropic_thinking_type(thinking)
    type === nothing && return true
    return String(type) != "disabled"
end

function anthropic_normalize_extended_thinking(thinking, model::Model, base_max_tokens::Int)
    raw_budget = anthropic_thinking_field(thinking, :budget_tokens)
    budget = raw_budget === nothing ? 1024 : try
        Int(raw_budget)
    catch
        throw(ArgumentError("thinking.budget_tokens must be an integer"))
    end
    if budget < 1024
        @warn "Anthropic requires a minimum 1,024-token thinking budget; clamping" requested = budget
        budget = 1024
    end
    model.maxTokens > ANTHROPIC_MIN_OUTPUT_TOKENS ||
        throw(ArgumentError("model maxTokens must exceed $ANTHROPIC_MIN_OUTPUT_TOKENS for extended thinking"))
    max_tokens = min(max(base_max_tokens, budget + ANTHROPIC_MIN_OUTPUT_TOKENS), model.maxTokens)
    if budget >= max_tokens
        clamped = max_tokens - ANTHROPIC_MIN_OUTPUT_TOKENS
        clamped >= 1024 ||
            throw(ArgumentError("max_tokens is too small for the minimum 1,024-token thinking budget"))
        @warn "thinking.budget_tokens must be below max_tokens; clamping" requested = budget clamped max_tokens
        budget = clamped
    end
    display = anthropic_thinking_field(thinking, :display)
    if display !== nothing && !(String(display) in ("omitted", "summarized"))
        @warn "Ignoring unsupported Anthropic thinking display" display
        display = nothing
    end
    config = AnthropicMessages.ThinkingConfig(;
        type = "enabled",
        budget_tokens = budget,
        display = display === nothing ? nothing : String(display),
    )
    return (; thinking = config, max_tokens)
end

# Reconcile a caller-supplied thinking config with model capabilities. Invalid
# configurations are normalized before they reach the API.
function anthropic_normalize_thinking(thinking, model::Model, base_max_tokens::Int)
    thinking === nothing && return (; thinking = nothing, max_tokens = base_max_tokens)
    type = anthropic_thinking_type(thinking)
    type === nothing && throw(ArgumentError("thinking.type is required"))
    type = lowercase(String(type))
    type in ("adaptive", "enabled", "disabled") ||
        throw(ArgumentError("unsupported thinking.type: $type"))
    if type == "disabled" && anthropic_thinking_always_on(model)
        @warn "Thinking cannot be disabled on this model; ignoring thinking=disabled" model = model.id
        return (; thinking = nothing, max_tokens = base_max_tokens)
    elseif type == "enabled" && !anthropic_supports_extended_thinking(model)
        @warn "Extended thinking (budget_tokens) is not supported on this model; falling back to adaptive thinking" model = model.id
        return (; thinking = AnthropicMessages.ThinkingConfig(; type = "adaptive", display = "summarized"), max_tokens = base_max_tokens)
    elseif type == "enabled"
        return anthropic_normalize_extended_thinking(thinking, model, base_max_tokens)
    elseif type == "adaptive" && !anthropic_supports_adaptive_thinking(model)
        @warn "Adaptive thinking is not supported on this model; falling back to extended thinking" model = model.id
        adjusted = anthropic_adjust_max_tokens_for_thinking(base_max_tokens, model.maxTokens, "high")
        return (; thinking = AnthropicMessages.ThinkingConfig(; type = "enabled", budget_tokens = adjusted.thinking_budget), max_tokens = adjusted.max_tokens)
    elseif type == "adaptive"
        display = anthropic_thinking_field(thinking, :display)
        if display !== nothing && !(String(display) in ("omitted", "summarized"))
            @warn "Ignoring unsupported Anthropic thinking display" display
            display = nothing
        end
        return (;
            thinking = AnthropicMessages.ThinkingConfig(;
                type = "adaptive",
                display = display === nothing ? nothing : String(display),
            ),
            max_tokens = base_max_tokens,
        )
    end
    return (;
        thinking = AnthropicMessages.ThinkingConfig(; type = "disabled"),
        max_tokens = base_max_tokens,
    )
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
                if block.redacted
                    # Replay redacted thinking as-is; the opaque data lives in the signature slot.
                    data = block.thinkingSignature
                    (data === nothing || isempty(data)) && continue
                    push!(blocks, AnthropicMessages.RedactedThinkingBlock(; data))
                    continue
                end
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
    elseif msg isa CompactionSummaryMessage
        return AnthropicMessages.Message(; role = "user", content = "[Previous conversation summary]\n\n$(msg.summary)")
    end
    throw(ArgumentError("unsupported message: $(typeof(msg))"))
end

function anthropic_build_messages(agent::Agent, state::AgentState, input::AgentTurnInput, tool_name_map::Dict{String, String}, model::Model)
    context = StoredAgentMessage[]
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

# Merge a message_delta usage into the usage captured at message_start: only fields
# present in the delta overwrite, so input/cache counts survive backends that only
# send output_tokens in deltas.
function anthropic_merge_usage(base::Union{Nothing, AnthropicMessages.Usage}, delta::AnthropicMessages.Usage)
    base === nothing && return delta
    return AnthropicMessages.Usage(;
        input_tokens = delta.input_tokens === nothing ? base.input_tokens : delta.input_tokens,
        output_tokens = delta.output_tokens === nothing ? base.output_tokens : delta.output_tokens,
        cache_creation_input_tokens = delta.cache_creation_input_tokens === nothing ? base.cache_creation_input_tokens : delta.cache_creation_input_tokens,
        cache_read_input_tokens = delta.cache_read_input_tokens === nothing ? base.cache_read_input_tokens : delta.cache_read_input_tokens,
    )
end

# Anthropic pauses long-running turns with stop_reason "pause_turn". The documented
# continuation is to re-send the same request with the paused assistant content
# appended verbatim and *no* extra user turn; the server resumes where it left off.
# https://platform.claude.com/docs/en/build-with-claude/handling-stop-reasons
const ANTHROPIC_MAX_PAUSE_TURN_RESUBMITS = 3

function anthropic_should_resubmit_paused(reason::Union{Nothing, String}, attempt::Int, assistant_message::AssistantMessage)
    reason == "pause_turn" || return false
    attempt <= ANTHROPIC_MAX_PAUSE_TURN_RESUBMITS || return false
    # A pending client tool call outranks the pause: the caller owes us a tool result
    # before the turn can continue.
    return isempty(assistant_message.tool_calls)
end

# Truncation and failure outrank tool calls: a cut-off turn can carry cut-off
# arguments, so its calls must not look executable.
function anthropic_stop_reason(reason::Union{Nothing, String}, tool_calls::Vector{AgentToolCall})
    if reason == "max_tokens" || reason == "model_context_window_exceeded"
        return :length
    elseif reason == "refusal"
        # The model declined: an answer, not a failure to retry.
        return :refusal
    elseif reason == "error"
        # Synthesized by the stream driver on HTTP errors.
        return :error
    elseif !isempty(tool_calls) || reason == "tool_use"
        # A paused turn with client tool calls still owes us their results.
        return :tool_calls
    elseif reason == "stop_sequence"
        return :stop
    elseif reason == "end_turn"
        return :stop
    elseif reason == "pause_turn"
        # The stream driver resubmits paused turns (bounded). Reaching here means the
        # turn is still incomplete, so never report it as a successful stop.
        return :length
    end
    return :stop
end

function anthropic_event_callback(
        f::F,
        agent::Agent,
        assistant_message::AssistantMessage,
        started::Base.RefValue{Bool},
        ended::Base.RefValue{Bool},
        stop_reason::Base.RefValue{Union{Nothing, String}},
        latest_usage::Base.RefValue{Union{Nothing, AnthropicMessages.Usage}},
        blocks_by_index::Dict{Int, AssistantContentBlock},
        partial_json_by_index::Dict{Int, String},
        wire_blocks_by_index::Dict{Int, Dict{String, Any}},
        wire_partial_json_by_index::Dict{Int, String},
        wire_replay_safe::Base.RefValue{Bool},
        tool_name_reverse_map::Dict{String, String},
        abort::Abort,
    ) where {F <: Function}
    stop_on_tool_call = get(ENV, "AGENTIF_STOP_ON_TOOL_CALL", "") != ""
    return function (stream, event)
        maybe_abort!(abort, stream)
        local parsed, wire_event
        try
            data = String(event.data)
            wire_event = JSON.parse(data)
            parsed = JSON.parse(data, AnthropicMessages.StreamEvent)
        catch e
            wire_replay_safe[] = false
            f(AgentErrorEvent(ErrorException(sprint(showerror, e))))
            return
        end

        return if parsed isa AnthropicMessages.StreamMessageStartEvent
            if parsed.message.id !== nothing
                assistant_message.response_id = parsed.message.id
            end
            parsed.message.stop_reason !== nothing && (stop_reason[] = parsed.message.stop_reason)
            parsed.message.usage !== nothing && (latest_usage[] = parsed.message.usage)
            if !started[]
                started[] = true
                f(MessageStartEvent(:assistant, assistant_message))
            end
        elseif parsed isa AnthropicMessages.StreamContentBlockStartEvent
            wire_block = get(() -> nothing, wire_event, "content_block")
            if wire_block isa AbstractDict
                wire_blocks_by_index[parsed.index] =
                    Dict{String, Any}(String(key) => value for (key, value) in wire_block)
            else
                wire_replay_safe[] = false
            end
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
            elseif parsed.content_block isa AnthropicMessages.RedactedThinkingBlock
                # Store the opaque data in the signature slot so it can be replayed verbatim.
                block = ThinkingContent(;
                    thinking = "",
                    thinkingSignature = parsed.content_block.data,
                    redacted = true,
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
            elseif parsed.content_block isa AnthropicMessages.UnknownContentBlock
                @debug "Ignoring unknown Anthropic content block" type = parsed.content_block.type index = parsed.index
            end
        elseif parsed isa AnthropicMessages.StreamContentBlockDeltaEvent
            wire_delta = get(() -> nothing, wire_event, "delta")
            wire_block = get(() -> nothing, wire_blocks_by_index, parsed.index)
            if wire_delta isa AbstractDict && wire_block isa AbstractDict
                delta_type = get(() -> nothing, wire_delta, "type")
                if delta_type == "text_delta"
                    wire_block["text"] = string(get(() -> "", wire_block, "text"),
                        get(() -> "", wire_delta, "text"))
                elseif delta_type == "thinking_delta"
                    wire_block["thinking"] = string(get(() -> "", wire_block, "thinking"),
                        get(() -> "", wire_delta, "thinking"))
                elseif delta_type == "signature_delta"
                    wire_block["signature"] = string(get(() -> "", wire_block, "signature"),
                        get(() -> "", wire_delta, "signature"))
                elseif delta_type == "input_json_delta"
                    partial = get(() -> "", wire_partial_json_by_index, parsed.index)
                    wire_partial_json_by_index[parsed.index] =
                        partial * string(get(() -> "", wire_delta, "partial_json"))
                else
                    # Unknown deltas cannot be applied to a final content block
                    # without knowing their merge semantics. Do not replay a
                    # potentially corrupted paused turn.
                    wire_replay_safe[] = false
                end
            else
                wire_replay_safe[] = false
            end
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
            elseif parsed.delta isa AnthropicMessages.UnknownContentBlockDelta
                @debug "Ignoring unknown Anthropic content block delta" type = parsed.delta.type index = parsed.index
            end
        elseif parsed isa AnthropicMessages.StreamContentBlockStopEvent
            wire_partial = get(() -> nothing, wire_partial_json_by_index, parsed.index)
            if wire_partial !== nothing
                wire_block = get(() -> nothing, wire_blocks_by_index, parsed.index)
                if wire_block isa AbstractDict
                    try
                        wire_block["input"] = isempty(wire_partial) ?
                            get(() -> Dict{String, Any}(), wire_block, "input") :
                            JSON.parse(wire_partial)
                    catch
                        wire_replay_safe[] = false
                    end
                else
                    wire_replay_safe[] = false
                end
            end
            block = get(() -> nothing, blocks_by_index, parsed.index)
            if block isa ToolCallContent
                partial = get(() -> "", partial_json_by_index, parsed.index)
                args = isempty(partial) ? (block.arguments isa AbstractDict ? block.arguments : Dict{String, Any}()) : parse_tool_arguments(partial)
                block.arguments = args
                call = AgentToolCall(; call_id = block.id, name = block.name, arguments = JSON.json(args))
                push!(assistant_message.tool_calls, call)
                ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                f(ToolCallRequestEvent(ptc))
                stop_on_tool_call && throw(StopStreaming("tool call arguments complete"))
            end
        elseif parsed isa AnthropicMessages.StreamMessageDeltaEvent
            parsed.usage !== nothing && (latest_usage[] = anthropic_merge_usage(latest_usage[], parsed.usage))
            delta = parsed.delta
            if delta isa AbstractDict
                sr = get(delta, "stop_reason", nothing)
                sr isa AbstractString && !isempty(sr) && (stop_reason[] = sr)
            end
        elseif parsed isa AnthropicMessages.StreamMessageStopEvent
            # A paused turn is resumed by the driver into this same assistant message,
            # so hold the end event back until the continuation finishes.
            if started[] && !ended[] && stop_reason[] != "pause_turn"
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end
        elseif parsed isa AnthropicMessages.StreamErrorEvent
            stop_reason[] = "error"
            if !started[]
                started[] = true
                f(MessageStartEvent(:assistant, assistant_message))
            end
            if !ended[]
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end
            error_msg = if parsed.error isa AbstractDict
                get(() -> "anthropic stream error", parsed.error, "message")
            else
                "anthropic stream error"
            end
            f(AgentErrorEvent(ErrorException(error_msg)))
        end
    end
end
