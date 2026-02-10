@kwarg struct CompactionConfig
    enabled::Bool = true
    reserve_tokens::Int = 16384
    keep_recent_tokens::Int = 20000
end

const COMPACTION_SUMMARY_PROMPT = """
You are summarizing a conversation between a user and an AI assistant for context continuity.
The assistant may have used tools during the conversation.
Produce a structured summary in the following format:

## Goal
[What is the user trying to accomplish?]

## Constraints & Preferences
- [Listed constraints or preferences, or "(none)"]

## Progress
### Done
- [x] [Completed tasks]
### In Progress
- [ ] [Current work]
### Blocked
- [Issues preventing progress, if any]

## Key Decisions
- **[Decision]**: [Brief rationale]

## Next Steps
1. [Ordered list for continuation]

## Critical Context
- [Any data, references, file paths, or constraints needed to continue]
"""

const COMPACTION_UPDATE_PROMPT = """
You are updating a conversation summary for context continuity.
The assistant may have used tools during the conversation.
A previous summary exists. Merge new information while preserving all previous content.
Move items from "In Progress" to "Done" as appropriate. Add new decisions and next steps.

<previous-summary>
%s
</previous-summary>

Produce the updated summary in the same structured format:

## Goal
## Constraints & Preferences
## Progress
### Done
### In Progress
### Blocked
## Key Decisions
## Next Steps
## Critical Context
"""

"""
    estimate_message_tokens(msg::AgentMessage) -> Int

Rough token estimate for a message (~4 chars per token).
Used only for cut-point finding, not for threshold checks.
"""
function estimate_message_tokens(msg::AgentMessage)
    text = message_text(msg)
    # Include tool call arguments in estimate for AssistantMessage
    extra = 0
    if msg isa AssistantMessage
        for tc in msg.tool_calls
            extra += sizeof(tc.arguments)
        end
    elseif msg isa ToolResultMessage
        # Tool results can be large; count full content
        for block in msg.content
            if block isa ImageContent
                extra += 1000  # rough estimate for image tokens
            end
        end
    end
    return cld(sizeof(text) + extra, 4)
end

"""
    find_cut_point(messages::Vector{AgentMessage}, keep_recent_tokens::Int) -> Int

Walk backwards from the end of messages, accumulating token estimates.
Returns the index of the first message to KEEP (messages[1:idx-1] get compacted).
Returns 0 if no valid cut point found.
Cut points are always at UserMessage boundaries to avoid splitting tool-call/result pairs.
"""
function find_cut_point(messages::Vector{AgentMessage}, keep_recent_tokens::Int)
    length(messages) <= 1 && return 0

    accumulated = 0
    candidate = 0

    for i in length(messages):-1:1
        accumulated += estimate_message_tokens(messages[i])
        if accumulated >= keep_recent_tokens
            candidate = i
            break
        end
    end

    # If we never hit the threshold, nothing to compact
    candidate == 0 && return 0

    # Walk forward to nearest UserMessage (valid cut boundary)
    for i in candidate:length(messages)
        messages[i] isa UserMessage && return i
    end

    return 0  # no valid cut point found
end

"""
    format_messages_for_summary(messages::Vector{AgentMessage}) -> String

Format discarded messages as readable text for the summarization prompt.
"""
function format_messages_for_summary(messages::Vector{AgentMessage})
    parts = String[]
    for msg in messages
        if msg isa UserMessage
            push!(parts, "User: $(message_text(msg))")
        elseif msg isa AssistantMessage
            text = message_text(msg)
            isempty(text) || push!(parts, "Assistant: $text")
            for tc in msg.tool_calls
                push!(parts, "Assistant called tool: $(tc.name)($(tc.arguments))")
            end
        elseif msg isa ToolResultMessage
            result_text = message_text(msg)
            if length(result_text) > 500
                result_text = result_text[1:500] * "... (truncated)"
            end
            prefix = msg.is_error ? "Tool $(msg.name) error" : "Tool $(msg.name) result"
            push!(parts, "$prefix: $result_text")
        elseif msg isa CompactionSummaryMessage
            push!(parts, "Previous summary:\n$(msg.summary)")
        end
    end
    return join(parts, "\n\n")
end

"""
    generate_summary(agent, to_discard, existing_summary, config, model) -> String

Use the agent's model to generate a structured summary of discarded messages.
"""
function generate_summary(
        agent::Agent, to_discard::Vector{AgentMessage},
        existing_summary::Union{Nothing, CompactionSummaryMessage},
        config::CompactionConfig, model::Model,
    )
    prompt = if existing_summary !== nothing
        replace(COMPACTION_UPDATE_PROMPT, "%s" => existing_summary.summary)
    else
        COMPACTION_SUMMARY_PROMPT
    end

    conversation_text = format_messages_for_summary(to_discard)
    summary_input = "Summarize this conversation:\n\n$conversation_text"

    summary_agent = Agent(; prompt, model, apikey = agent.apikey, tools = AgentTool[])
    result = stream(identity, summary_agent, AgentState(), summary_input, Abort())
    return message_text(last_assistant_message(result))
end

"""
    compact!(agent, state, config, model)

Perform compaction on the agent state: summarize old messages and replace them
with a CompactionSummaryMessage. Sets `state.last_compaction` to signal
session_middleware to write a compaction entry.
"""
function compact!(agent::Agent, state::AgentState, config::CompactionConfig, model::Model)
    messages = state.messages

    cut_idx = find_cut_point(messages, config.keep_recent_tokens)
    cut_idx <= 1 && return

    # Check for existing compaction summary at the front
    existing_summary = !isempty(messages) && messages[1] isa CompactionSummaryMessage ? messages[1] : nothing
    discard_start = existing_summary !== nothing ? 2 : 1

    to_discard = messages[discard_start:cut_idx-1]
    isempty(to_discard) && return

    to_keep = messages[cut_idx:end]

    summary_text = try
        generate_summary(agent, to_discard, existing_summary, config, model)
    catch e
        @warn "Compaction summary generation failed, skipping compaction" exception = (e, catch_backtrace())
        return
    end

    tokens_before = sum(estimate_message_tokens(m) for m in to_discard)
    if existing_summary !== nothing
        tokens_before += existing_summary.tokens_before
    end

    compaction_msg = CompactionSummaryMessage(;
        summary = summary_text,
        tokens_before,
        compacted_at = time(),
    )

    # Replace state.messages in-place
    empty!(state.messages)
    push!(state.messages, compaction_msg)
    append!(state.messages, to_keep)

    # Signal to session_middleware
    state.last_compaction = compaction_msg

    return
end

"""
    compaction_middleware(agent_handler, config) -> middleware

Middleware that checks if context is approaching the model's context window
and compacts old messages into a summary before calling the LLM.

Sits directly above `stream` in the middleware stack so it runs before each
individual LLM API call (including within tool-call loops).

Uses `state.usage.input` from the previous API call to determine if compaction
is needed. On the first call (no previous usage data), compaction is skipped.
"""
function compaction_middleware(agent_handler::AgentHandler, config::CompactionConfig)
    last_input_tokens = Ref(0)

    return function (f, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort;
            model::Union{Nothing, Model} = nothing, kw...)
        if !config.enabled
            return agent_handler(f, agent, state, current_input, abort; model, kw...)
        end

        resolved_model = model === nothing ? agent.model : model
        if resolved_model === nothing
            return agent_handler(f, agent, state, current_input, abort; model, kw...)
        end

        threshold = resolved_model.contextWindow - config.reserve_tokens

        # Compact if previous call's input tokens exceeded threshold
        if last_input_tokens[] > 0 && last_input_tokens[] > threshold
            compact!(agent, state, config, resolved_model)
        end

        usage_before = state.usage.input
        result = agent_handler(f, agent, state, current_input, abort; model, kw...)
        last_input_tokens[] = result.usage.input - usage_before

        return result
    end
end
