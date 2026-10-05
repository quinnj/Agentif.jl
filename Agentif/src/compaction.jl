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
    find_cut_point(messages::Vector{StoredAgentMessage}, keep_recent_tokens::Int) -> Int

Walk backwards from the end of messages, accumulating token estimates.
Returns the index of the first message to KEEP (messages[1:idx-1] get compacted).
Returns 0 if no valid cut point found.
Cut points must be at turn boundaries: before a UserMessage or before an
AssistantMessage that is not preceded by an unresolved tool call. This avoids
splitting tool-call/result pairs while still allowing compaction in long
tool-call loops that have no intermediate UserMessages.
"""
function find_cut_point(messages::Vector{StoredAgentMessage}, keep_recent_tokens::Int)
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

    # Walk forward to the nearest turn boundary. When the newest messages alone
    # fill the budget (e.g. large tool results that a tool round just
    # appended), there is none ahead: walk back to the turn that produced them.
    for i in candidate:length(messages)
        is_turn_boundary(messages, i) && return i
    end
    for i in (candidate - 1):-1:2
        is_turn_boundary(messages, i) && return i
    end
    return 0  # no valid cut point found
end

# A UserMessage, or an AssistantMessage not preceded by an AssistantMessage
# with tool calls (cutting there would split the calls from their results).
function is_turn_boundary(messages::Vector{StoredAgentMessage}, i::Int)
    msg = messages[i]
    msg isa UserMessage && return true
    msg isa AssistantMessage || return false
    i == 1 && return true
    previous = messages[i - 1]
    return !(previous isa AssistantMessage && !isempty(previous.tool_calls))
end

"""
    format_messages_for_summary(messages::Vector{StoredAgentMessage}) -> String

Format discarded messages as readable text for the summarization prompt.
"""
function format_messages_for_summary(messages::Vector{StoredAgentMessage})
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
                # first() is char-safe; result_text[1:500] is byte indexing and
                # throws on multi-byte tool output right when compaction runs
                result_text = first(result_text, 500) * "... (truncated)"
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
    generate_summary(agent, to_discard, existing_summary, config, model, abort) -> Union{Nothing, String}

Use the agent's model to generate a structured summary of discarded messages.
Returns `nothing` when the summarization call failed (provider error, abort, or
an empty response) so callers can skip compaction instead of trading real
history for an empty summary.
"""
function generate_summary(
        agent::Agent, to_discard::Vector{StoredAgentMessage},
        existing_summary::Union{Nothing, CompactionSummaryMessage},
        config::CompactionConfig, model::Model, abort::Abort = Abort(),
    )
    prompt = if existing_summary !== nothing
        replace(COMPACTION_UPDATE_PROMPT, "%s" => existing_summary.summary)
    else
        COMPACTION_SUMMARY_PROMPT
    end

    conversation_text = format_messages_for_summary(to_discard)
    summary_input = "Summarize this conversation:\n\n$conversation_text"

    summary_agent = Agent(;
        prompt,
        model,
        apikey = agent.apikey,
        tools = empty_agent_tools(),
        http_kw = agent.http_kw,
        api = Val(Symbol(model.api)),
    )
    result = stream(identity, summary_agent, AgentState(), summary_input, abort)
    stop_reason = result.most_recent_stop_reason
    if stop_reason === :error || stop_reason === :aborted || stop_reason === :refusal
        @warn "Compaction summary call did not complete, skipping compaction" stop_reason
        return nothing
    end
    msg = last_assistant_message(result)
    summary_text = msg === nothing ? "" : message_text(msg)
    if isempty(strip(summary_text))
        @warn "Compaction summary was empty, skipping compaction" stop_reason
        return nothing
    end
    return summary_text
end

"""
    compact!(agent, state, config, model; abort) -> Bool

Perform compaction on the agent state: summarize old messages and replace them
with a CompactionSummaryMessage. Sets `state.last_compaction` to signal
session_middleware to write a compaction entry, and updates the persisted-prefix
provenance so persistence knows which kept messages the store already holds.

Returns `true` when the state was compacted, `false` when compaction was skipped
(nothing to compact, or summarization failed) — in which case `state` is
untouched.
"""
function compact!(agent::Agent, state::AgentState, config::CompactionConfig, model::Model; abort::Abort = Abort())
    messages = state.messages

    cut_idx = find_cut_point(messages, config.keep_recent_tokens)
    cut_idx <= 1 && return false

    # Check for existing compaction summary at the front
    existing_summary = !isempty(messages) && messages[1] isa CompactionSummaryMessage ? messages[1] : nothing
    discard_start = existing_summary !== nothing ? 2 : 1

    to_discard = messages[discard_start:cut_idx-1]
    isempty(to_discard) && return false

    to_keep = messages[cut_idx:end]

    summary_text = try
        generate_summary(agent, to_discard, existing_summary, config, model, abort)
    catch e
        @warn "Compaction summary generation failed, skipping compaction" exception = (e, catch_backtrace())
        nothing
    end
    summary_text === nothing && return false

    tokens_before = 0
    for message in to_discard
        tokens_before += estimate_message_tokens(message)
    end
    if existing_summary !== nothing
        tokens_before += existing_summary.tokens_before
    end

    compaction_msg = CompactionSummaryMessage(;
        summary = summary_text,
        tokens_before,
        compacted_at = time(),
    )

    # The already-persisted prefix occupies positions
    # discard_start .. discard_start + persisted_prefix_count - 1; whatever part
    # of it survives the cut stays persisted, the rest is now summarized.
    prefix_end = discard_start + state.persisted_prefix_count - 1
    surviving_prefix = max(0, prefix_end - max(cut_idx, discard_start) + 1)
    state.persisted_prefix_start += max(0, min(cut_idx, discard_start + state.persisted_prefix_count) - discard_start)
    state.persisted_prefix_count = surviving_prefix

    # Replace state.messages in-place
    empty!(state.messages)
    push!(state.messages, compaction_msg)
    append!(state.messages, to_keep)

    # Signal to session_middleware
    state.last_compaction = compaction_msg

    return true
end

function compaction_threshold(context_window::Int, reserve_tokens::Int)
    context_window <= 0 && return 0
    reserve_tokens <= 0 && return context_window
    if reserve_tokens >= context_window
        # Fallback for undersized context windows to avoid compacting every turn.
        return max(1, floor(Int, context_window * 0.8))
    end
    return context_window - reserve_tokens
end

compaction_threshold(config::CompactionConfig, model::Model) = compaction_threshold(model.contextWindow, config.reserve_tokens)

"""
    estimate_context_tokens(messages) -> Int

Rough token estimate for a whole conversation. Used as the compaction trigger
when no measured token count is available (e.g. the first call of an evaluation
whose state was just restored from a session store).
"""
function estimate_context_tokens(messages::AbstractVector{<:AgentMessage})
    total = 0
    for msg in messages
        total += estimate_message_tokens(msg)
    end
    return total
end

"""
    current_context_tokens(state) -> Int

Best available estimate of how many input tokens the next API call will carry:
the measured input tokens of the most recent call (`state.context_tokens`), or
the message estimate when that is larger or unknown. Taking the larger of the
two catches context that grew after the last measurement (a long tool-call loop)
and restored sessions that were already over the limit.
"""
function current_context_tokens(state::AgentState)
    return max(state.context_tokens, estimate_context_tokens(state.messages))
end

const CONTEXT_OVERFLOW_PATTERNS = [
    "context length",
    "context_length",
    "context window",
    "maximum context",
    "too many tokens",
    "prompt is too long",
    "input is too long",
    "reduce the length of the messages",
]

"""
    is_context_overflow_error(text) -> Bool

Whether a provider error message looks like "the request exceeded the model's
context window". Matching is textual because providers report overflow as a
generic 400 with a prose message.
"""
function is_context_overflow_error(text::AbstractString)
    lowered = lowercase(text)
    return any(pat -> occursin(pat, lowered), CONTEXT_OVERFLOW_PATTERNS)
end

is_context_overflow_error(e::Exception) = is_context_overflow_error(sprint(showerror, e))

function is_context_overflow_error(e::HTTP.StatusError)
    400 <= e.status < 500 || return false
    body = try
        String(copy(e.response.body))
    catch
        ""
    end
    return is_context_overflow_error(body) || is_context_overflow_error(sprint(showerror, e))
end

_context_input_tokens(usage::Usage) = usage.input + usage.cacheRead + usage.cacheWrite

function _record_context_tokens!(state::AgentState, total_before::Int)
    # Track every input token that occupies the context window. Providers can
    # report uncached, cache-read, and newly cache-written tokens separately.
    total_after = _context_input_tokens(state.usage)
    state.context_tokens = max(0, total_after - total_before)
    return state
end

"""
    compaction_middleware(agent_handler, config) -> middleware

Middleware that checks if context is approaching the model's context window
and compacts old messages into a summary before calling the LLM.

Sits directly above `stream` in the middleware stack so it runs before each
individual LLM API call (including within tool-call loops).

The trigger comes from the state itself — the measured input tokens of the most
recent API call, or an estimate over `state.messages` — so a session restored
over the limit compacts before its first call rather than failing forever.

If the provider still rejects the request as a context overflow, the middleware
compacts once and retries the call once.
"""
function compaction_middleware(agent_handler::AgentHandler, config::CompactionConfig)
    return function (f::F, agent::Agent, state::AgentState, current_input::AgentTurnInput, abort::Abort;
            model::Union{Nothing, Model} = nothing, kw...) where {F <: Function}
        if !config.enabled
            return agent_handler(f, agent, state, current_input, abort; model, kw...)
        end

        resolved_model = model === nothing ? agent.model : model
        if resolved_model === nothing
            return agent_handler(f, agent, state, current_input, abort; model, kw...)
        end

        threshold = compaction_threshold(config, resolved_model)
        threshold <= 0 && return agent_handler(f, agent, state, current_input, abort; model, kw...)

        if current_context_tokens(state) > threshold
            compact!(agent, state, config, resolved_model; abort) && (state.context_tokens = 0)
        end

        # Hold back an empty response lifecycle and a context-overflow error. A
        # rejected HTTP call can emit start/end before its error; those events
        # must not close the consumer's stream before a successful retry.
        # Once substantive output is visible, retrying would duplicate it, so
        # an overflow after progress is forwarded without a retry.
        overflow_event = Ref{Union{Nothing, AgentErrorEvent}}(nothing)
        pending_lifecycle = AgentEvent[]
        stream_progressed = Ref(false)
        flush_pending! = function ()
            for pending_event in pending_lifecycle
                f(pending_event)
            end
            empty!(pending_lifecycle)
            return nothing
        end
        guarded_f = function (event)
            overflow_event[] === nothing || return nothing
            if event isa MessageStartEvent ||
                    (event isa MessageEndEvent && !stream_progressed[])
                if !stream_progressed[]
                    push!(pending_lifecycle, event)
                    return nothing
                end
                return f(event)
            elseif event isa AgentErrorEvent
                if !stream_progressed[] && is_context_overflow_error(event.error)
                    overflow_event[] = event
                    return nothing
                end
                flush_pending!()
                return f(event)
            else
                flush_pending!()
                stream_progressed[] = true
                return f(event)
            end
        end

        msg_count_before = length(state.messages)
        total_before = _context_input_tokens(state.usage)
        overflow_thrown = Ref{Union{Nothing, Exception}}(nothing)
        result = try
            agent_handler(guarded_f, agent, state, current_input, abort; model, kw...)
        catch e
            if !(e isa Exception && !isaborted(abort) &&
                    !stream_progressed[] && is_context_overflow_error(e))
                flush_pending!()
                rethrow()
            end
            overflow_event[] = AgentErrorEvent(e)
            overflow_thrown[] = e
            state
        end
        overflow_event[] === nothing && flush_pending!()
        _record_context_tokens!(result, total_before)

        if overflow_event[] !== nothing
            compacted = false
            if !isaborted(abort)
                # Drop the messages the rejected call appended so the retry does
                # not duplicate the turn, and put them back if compaction fails.
                failed_tail = AgentMessage[]
                if length(result.messages) > msg_count_before
                    append!(failed_tail, result.messages[msg_count_before + 1:end])
                    Base.resize!(result.messages, msg_count_before)
                end
                compacted = compact!(agent, result, config, resolved_model; abort)
                compacted || append!(result.messages, failed_tail)
            end
            if compacted
                empty!(pending_lifecycle)
                result.context_tokens = 0
                total_before = _context_input_tokens(result.usage)
                result = agent_handler(f, agent, result, current_input, abort; model, kw...)
                _record_context_tokens!(result, total_before)
            else
                # Compaction cannot help: leave the failed call exactly as it
                # was, error and all.
                flush_pending!()
                overflow_thrown[] === nothing || throw(overflow_thrown[])
                f(overflow_event[])
            end
        end

        return result
    end
end
