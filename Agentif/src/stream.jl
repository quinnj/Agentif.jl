using HTTP
using JSON

# HTTP.jl provides HTTP.SSE.SSEEvent with data::String field
# SSE callbacks receive (stream, event) for access to the underlying stream

toolcall_debug_enabled() = get(ENV, "AGENTIF_DEBUG_TOOLCALLS", "") != ""

struct StopStreaming <: Exception
    reason::String
end

StopStreaming() = StopStreaming("stop streaming early")

function maybe_abort!(abort::Abort, stream)
    isaborted(abort) || return
    try
        close(stream)
    catch
    end
    throw(StopStreaming("aborted"))
end

toolcall_preview(::Nothing; limit::Int = 300) = "(nothing)"
function toolcall_preview(s::AbstractString; limit::Int = 300)
    return length(s) > limit ? string(first(s, limit), "...(truncated)") : s
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

# ── SSE-safe retry ────────────────────────────────────────────────────────────
# HTTP.jl's transport-level retry sits above the layer that feeds SSE events to
# `sse_callback`, so a connection drop mid-stream would replay the entire
# response into the same stateful callback closures (doubling text/thinking
# deltas and corrupting tool-call accumulators). For SSE requests we therefore
# disable transport retry (`retry = false`) and retry at this level instead,
# but only while no SSE event has been delivered yet.

# Transient statuses worth retrying before any event has been delivered.
const SSE_RETRYABLE_STATUSES = (408, 429, 500, 502, 503, 504, 599)

sse_retryable_status(status::Integer) = Int(status) in SSE_RETRYABLE_STATUSES

# Recoverable connection-level failures (EOF/IO errors, connect failures, TLS
# errors) — never StatusError (handled separately) and never interrupts.
function sse_recoverable_connection_error(err)
    (err isa InterruptException || err isa StopStreaming || err isa HTTP.StatusError) && return false
    err isa Exception || return false
    return codex_retryable_exception(err) || http_recoverable_error(err)
end

function sse_retryable_error(err)
    err isa HTTP.StatusError && return sse_retryable_status(err.status)
    return sse_recoverable_connection_error(err)
end

# Wrap a provider `sse_callback` so the very first delivered event flips
# `events_seen` (before the provider closure runs, so even a callback that
# throws still counts as delivery).
function sse_tracking_callback(callback::Function, events_seen::Base.RefValue{Bool})
    return function (stream, event)
        events_seen[] = true
        return callback(stream, event)
    end
end

# Respect caller-provided `http_kw` retry overrides: `retry = false` disables
# our retry loop entirely, and `retries = N` bounds it at N + 1 attempts.
function sse_retry_attempts(http_kw::NamedTuple)
    get(http_kw, :retry, true) === true || return 1
    return max(1, Int(get(http_kw, :retries, DEFAULT_HTTP_KW.retries)) + 1)
end

"""
    sse_request_with_retry(do_request, events_seen, abort; max_attempts, ...)

Run `do_request` (an `HTTP.post` with transport-level retry disabled), retrying
transient failures (recoverable connection errors, or `HTTP.StatusError` with a
status in `$(SSE_RETRYABLE_STATUSES)`) with bounded exponential backoff. A
`Retry-After` header on the failed response is honored (capped at
`max_delay_ms`). Once any SSE event has been delivered (`events_seen[]`),
errors are rethrown instead of retried — replaying the response would corrupt
the stateful callback accumulators.
"""
function sse_request_with_retry(
        do_request::Function,
        events_seen::Base.RefValue{Bool},
        abort::Abort;
        max_attempts::Int,
        base_delay_ms::Int = CODEX_DEFAULT_RETRY_BASE_MS,
        max_delay_ms::Int = CODEX_DEFAULT_RETRY_MAX_MS,
    )
    attempt = 1
    while true
        isaborted(abort) && throw(StopStreaming("aborted"))
        try
            return do_request()
        catch err
            (err isa StopStreaming || err isa InterruptException) && rethrow()
            (events_seen[] || attempt >= max_attempts || !sse_retryable_error(err)) && rethrow()
            response = err isa HTTP.StatusError ? err.response : nothing
            delay_s = codex_retry_delay_seconds(attempt, base_delay_ms, max_delay_ms; response)
            attempt += 1
            codex_sleep_with_abort!(delay_s, abort)
        end
    end
end

# Shared handling for a connection dropped after SSE events already flowed:
# keep the partial message, surface the failure as an AgentErrorEvent.
function sse_emit_stream_interrupted!(
        f::Function,
        assistant_message::AssistantMessage,
        started::Base.RefValue{Bool},
        ended::Base.RefValue{Bool},
        err,
    )
    if !started[]
        started[] = true
        f(MessageStartEvent(:assistant, assistant_message))
    end
    if !ended[]
        ended[] = true
        f(MessageEndEvent(:assistant, assistant_message))
    end
    f(AgentErrorEvent(ErrorException("SSE stream interrupted: $(sprint(showerror, err))")))
    return
end

# Shared catch-block handling for a failed SSE stream request: expected aborts
# are swallowed, an HTTP.StatusError is surfaced as an AgentErrorEvent carrying
# the provider's error message, a recoverable connection drop after events
# already flowed keeps the partial message, and anything else rethrows (this
# helper must be called from inside the catch block). The per-arm failure
# bookkeeping is injected via the two thunks.
function handle_sse_stream_error(
        e,
        f::Function,
        assistant_message::AssistantMessage,
        started::Base.RefValue{Bool},
        ended::Base.RefValue{Bool},
        events_seen::Base.RefValue{Bool};
        on_status_error::Function,
        on_interrupted::Function,
    )
    if e isa StopStreaming
        # Expected abort
    elseif e isa HTTP.StatusError
        if !started[]
            started[] = true
            f(MessageStartEvent(:assistant, assistant_message))
        end
        if !ended[]
            ended[] = true
            f(MessageEndEvent(:assistant, assistant_message))
        end
        error_body = String(e.response.body)
        error_msg = try
            err_json = JSON.parse(error_body)
            get(get(() -> Dict(), err_json, "error"), "message", "HTTP $(e.status)")
        catch
            "HTTP $(e.status): $error_body"
        end
        f(AgentErrorEvent(ErrorException(error_msg)))
        on_status_error()
    elseif events_seen[] && sse_recoverable_connection_error(e)
        sse_emit_stream_interrupted!(f, assistant_message, started, ended, e)
        on_interrupted()
    else
        rethrow()
    end
    return
end

mutable struct ToolCallAccumulator
    id::Union{Nothing, String}
    name::Union{Nothing, String}
    arguments::String
end

new_call_id(prefix::String) = string(prefix, "-", string(UID8()))

function parse_tool_arguments(arguments::String)::ToolArguments
    try
        return JSON.parse(arguments, ToolArguments)
    catch
        return ToolArguments()
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

function flush_pending_tool_results!(
        normalized::Vector{StoredAgentMessage},
        pending::Vector{ToolCallContent},
        resolved::Set{String},
    )
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

function transform_messages(
        messages::Vector{StoredAgentMessage}, model::Model;
        normalize_tool_call_id::F = identity,
    )::Vector{StoredAgentMessage} where {F}
    tool_call_id_map = Dict{String, String}()
    transformed = StoredAgentMessage[]
    for msg in messages
        if msg isa CompactionSummaryMessage
            push!(transformed, msg)
        elseif msg isa UserMessage
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
                    has_signature = block.thinkingSignature !== nothing && !isempty(block.thinkingSignature)
                    if is_same && has_signature
                        # Keep signed blocks even when the visible thinking text is
                        # empty: redacted_thinking and encrypted reasoning items
                        # (e.g. Responses with no summary) round-trip through the
                        # signature and must be replayed for continuity.
                        push!(blocks, ThinkingContent(; thinking = block.thinking, thinkingSignature = block.thinkingSignature, redacted = block.redacted))
                    else
                        isempty(block.thinking) && continue
                        block.redacted && continue
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

    normalized = StoredAgentMessage[]
    pending = ToolCallContent[]
    resolved = Set{String}()

    for msg in transformed
        if msg isa AssistantMessage
            flush_pending_tool_results!(normalized, pending, resolved)
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
            flush_pending_tool_results!(normalized, pending, resolved)
            push!(normalized, msg)
        end
    end
    flush_pending_tool_results!(normalized, pending, resolved)
    return normalized
end


agent_system_prompt(agent::Agent) = agent.prompt

function resolve_openai_cache_retention(cache_retention)
    if cache_retention === nothing
        return lowercase(strip(get(ENV, "PI_CACHE_RETENTION", ""))) == "long" ? "long" : "short"
    end
    value = lowercase(strip(string(cache_retention)))
    return value in ("none", "short", "long") ? value : "short"
end

function openai_prompt_cache_retention(base_url::AbstractString, cache_retention::AbstractString)
    cache_retention == "long" || return nothing
    return occursin("api.openai.com", lowercase(String(base_url))) ? "24h" : nothing
end

function openai_responses_zero_juice_item()
    return Dict(
        "role" => "developer",
        "content" => [Dict("type" => "input_text", "text" => "# Juice: 0 !important")],
    )
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


include("providers/openai_responses_adapter.jl")
include("providers/openai_completions_adapter.jl")
include("providers/anthropic_messages_adapter.jl")
include("providers/google_adapter.jl")
include("providers/openai_codex.jl")


function finalize_stream!(
        state::AgentState,
        input::AgentTurnInput,
        assistant_message::AssistantMessage,
        usage::Usage,
        stop_reason::Symbol,
    )
    append_state!(state, input, assistant_message, usage)
    state.pending_tool_calls = pending_tool_calls_from_message(assistant_message)
    state.most_recent_stop_reason = stop_reason
    return state
end

abstract type AbstractOAuthBackend end
struct MissingOAuthBackend <: AbstractOAuthBackend end

const OAUTH_BACKEND = Ref{AbstractOAuthBackend}(MissingOAuthBackend())

get_codex_token(::AbstractOAuthBackend) = throw(ArgumentError("Codex OAuth token provider unavailable; load `LLMOAuth` and run `LLMOAuth.codex_login()` first, or pass an explicit `apikey`"))
get_anthropic_token(::AbstractOAuthBackend) = throw(ArgumentError("Anthropic OAuth token provider unavailable; load `LLMOAuth` and run `LLMOAuth.anthropic_login()` first, or pass an explicit `apikey`"))

model_request_kw(model::Model) = model.kw

function resolve_oauth_apikey(provider::Symbol, apikey::AbstractString; backend::AbstractOAuthBackend = OAUTH_BACKEND[])
    apikey != "OAUTH" && return apikey
    if provider == :codex
        token = get_codex_token(backend)
    elseif provider == :anthropic
        token = get_anthropic_token(backend)
    else
        throw(ArgumentError("Unsupported OAuth provider: $(provider)"))
    end
    token isa AbstractString && !isempty(token) || throw(ArgumentError("OAuth token provider for $(provider) must return a non-empty String token"))
    return token
end

function stream(
        f::F, agent::Agent, state::AgentState, input::AgentTurnInput, abort::Abort;
        model::Union{Nothing, Model} = nothing, http_kw = (;), kw...
    ) where {F <: Function}
    api = model === nothing ? agent.api : Val(Symbol(model.api))
    model = model === nothing ? agent.model : model
    model === nothing && throw(ArgumentError("no model specified with which agent can evaluate input"))

    if isaborted(abort)
        state.most_recent_stop_reason = :aborted
        return state
    end

    # Merge HTTP kwargs: defaults < agent.http_kw < per-call http_kw
    merged_http_kw = merge(DEFAULT_HTTP_KW, NamedTuple(agent.http_kw), NamedTuple(http_kw))
    kw_nt = kw isa NamedTuple ? kw : (; kw...)
    apikey_override = get(() -> nothing, kw_nt, :apikey)
    if apikey_override !== nothing
        kw_nt = Base.structdiff(kw_nt, (; apikey = nothing))
    end
    apikey = apikey_override === nothing ? agent.apikey : apikey_override

    if api isa Val{Symbol("openai-responses")}
        apikey isa AbstractString || throw(ArgumentError("apikey must be a String for provider $(model.provider)"))
        assistant_message = assistant_message_for_model(model; response_id = state.response_id)
        started = Ref(false)
        ended = Ref(false)
        response_usage = Ref{Union{Nothing, OpenAIResponses.Usage}}(nothing)
        response_status = Ref{Union{Nothing, String}}(nothing)

        system_prompt = agent_system_prompt(agent)
        full_input = openai_responses_build_full_input(agent, state, input, model)
        session_id = get(() -> nothing, kw_nt, :session_id)
        session_id === nothing && (session_id = get(() -> nothing, kw_nt, :sessionId))
        cache_retention = get(() -> nothing, kw_nt, :cache_retention)
        cache_retention === nothing && (cache_retention = get(() -> nothing, kw_nt, :cacheRetention))
        cache_retention = resolve_openai_cache_retention(cache_retention)

        # Build Dict-based request body (allows raw Dict items for opaque reasoning roundtripping)
        body = Dict{String, Any}(
            "model" => model.id,
            "input" => full_input,
            "stream" => true,
            "store" => false,
        )
        system_prompt !== nothing && !isempty(system_prompt) && (body["instructions"] = system_prompt)

        # Tools
        tools = openai_responses_build_tools(agent.tools)
        if tools !== nothing
            body["tools"] = tools
            body["tool_choice"] = "auto"
            body["parallel_tool_calls"] = true
        end

        # Reasoning config (for reasoning models)
        reasoning_effort = get(() -> nothing, kw_nt, :reasoning_effort)
        reasoning_effort === nothing && (reasoning_effort = get(() -> nothing, kw_nt, :reasoningEffort))
        reasoning_summary = get(() -> nothing, kw_nt, :reasoning_summary)
        reasoning_summary === nothing && (reasoning_summary = get(() -> nothing, kw_nt, :reasoningSummary))
        if model.reasoning
            if reasoning_effort !== nothing || reasoning_summary !== nothing
                body["reasoning"] = Dict(
                    "effort" => something(reasoning_effort, "medium"),
                    "summary" => something(reasoning_summary, "auto"),
                )
            elseif startswith(lowercase(model.name), "gpt-5")
                body["input"] = Any[openai_responses_zero_juice_item(), body["input"]...]
            end
            body["include"] = ["reasoning.encrypted_content"]
        end

        if session_id !== nothing && cache_retention != "none"
            body["prompt_cache_key"] = string(session_id)
        end
        prompt_cache_retention = openai_prompt_cache_retention(model.baseUrl, cache_retention)
        prompt_cache_retention !== nothing && (body["prompt_cache_retention"] = prompt_cache_retention)

        # Pass through model.kw (temperature, max_output_tokens, etc.)
        for (k, v) in pairs(model_request_kw(model))
            k_str = string(k)
            # Skip fields we already set or that don't belong in the body
            k_str in ("api", "provider", "baseUrl", "reasoning", "input", "cost", "contextWindow", "maxTokens", "headers", "compat", "name", "id") && continue
            body[k_str] = v
        end

        # Pass through stream kwargs (except ones we handle specially)
        for k in keys(kw_nt)
            k in (
                :instructions,
                :apikey,
                :reasoning_effort,
                :reasoningEffort,
                :reasoning_summary,
                :reasoningSummary,
                :model,
                :http_kw,
                :session_id,
                :sessionId,
                :cache_retention,
                :cacheRetention,
            ) && continue
            k_str = string(k)
            haskey(body, k_str) || (body[k_str] = kw_nt[k])
        end

        headers = Dict(
            "Authorization" => "Bearer $apikey",
            "Content-Type" => "application/json",
        )
        model.headers !== nothing && merge!(headers, model.headers)
        url = joinpath(model.baseUrl, "responses")
        events_seen = Ref(false)
        sse_cb = sse_tracking_callback(
            openai_responses_event_callback(
                f,
                agent,
                assistant_message,
                started,
                ended,
                response_usage,
                response_status,
                abort,
            ),
            events_seen,
        )
        request_http_kw = merge(merged_http_kw, (; retry = false))
        try
            sse_request_with_retry(events_seen, abort; max_attempts = sse_retry_attempts(merged_http_kw)) do
                HTTP.post(
                    url,
                    headers;
                    body = JSON.json(body),
                    sse_callback = sse_cb,
                    request_http_kw...,
                )
            end
        catch e
            handle_sse_stream_error(
                e, f, assistant_message, started, ended, events_seen;
                on_status_error = () -> (response_status[] = "failed"),
                on_interrupted = () -> (response_status[] = "failed"),
            )
        end

        if started[] && !ended[]
            ended[] = true
            f(MessageEndEvent(:assistant, assistant_message))
        end

        usage = openai_responses_usage_from_response(response_usage[])
        stop_reason = openai_responses_stop_reason(response_status[], assistant_message.tool_calls)
        isaborted(abort) && (stop_reason = :aborted)
        return finalize_stream!(state, input, assistant_message, usage, stop_reason)
    elseif api isa Val{Symbol("openai-completions")}
        apikey isa AbstractString || throw(ArgumentError("apikey must be a String for provider $(model.provider)"))
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
            reasoning_value = stream_kw[:reasoning]
            if reasoning_value isa AbstractString || reasoning_value isa Symbol
                reasoning_effort_value = string(reasoning_value)
                stream_kw = Base.structdiff(stream_kw, (; reasoning = nothing))
                if !haskey(stream_kw, :reasoning_effort)
                    stream_kw = merge(stream_kw, (; reasoning_effort = reasoning_effort_value))
                end
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
        if openai_completions_use_reasoning_split(model)
            if haskey(stream_kw, :reasoningSplit) && !haskey(stream_kw, :reasoning_split)
                reasoning_split_value = stream_kw[:reasoningSplit]
                stream_kw = merge(Base.structdiff(stream_kw, (; reasoningSplit = nothing)), (; reasoning_split = reasoning_split_value))
            end
            if !haskey(stream_kw, :reasoning_split)
                stream_kw = merge(stream_kw, (; reasoning_split = true))
            end
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

        if !compat.supportsTools
            tools = nothing
        end
        request_kw = merge((; tools), stream_kw)
        req = OpenAICompletions.Request(
            ; model = model.id,
            messages,
            stream = use_stream,
            model_request_kw(model)...,
            request_kw...,
        )
        headers = Dict(
            "Authorization" => "Bearer $apikey",
            "Content-Type" => "application/json",
        )
        model.headers !== nothing && merge!(headers, model.headers)
        url = joinpath(model.baseUrl, "chat", "completions")
        stream_failed = Ref(false)
        if use_stream
            events_seen = Ref(false)
            sse_cb = sse_tracking_callback(
                openai_completions_event_callback(
                    f,
                    assistant_message,
                    started,
                    ended,
                    latest_usage,
                    latest_finish,
                    tool_call_accumulators,
                    abort;
                    think_tag_state = compat.stripThinkTags ? ThinkTagStreamState() : nothing,
                ),
                events_seen,
            )
            request_http_kw = merge(merged_http_kw, (; retry = false))
            try
                sse_request_with_retry(events_seen, abort; max_attempts = sse_retry_attempts(merged_http_kw)) do
                    HTTP.post(
                        url,
                        headers;
                        body = JSON.json(req),
                        sse_callback = sse_cb,
                        request_http_kw...,
                    )
                end
            catch e
                handle_sse_stream_error(
                    e, f, assistant_message, started, ended, events_seen;
                    on_status_error = () -> (latest_finish[] = "error"),
                    on_interrupted = () -> (stream_failed[] = true),
                )
            end

            if started[] && !ended[]
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end

            if !isaborted(abort) && !stream_failed[]
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
                    findtool(agent.tools, call.name)
                    ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                    f(ToolCallRequestEvent(ptc))
                end
            end
        else
            response = JSON.parse(HTTP.post(url, headers; body = JSON.json(req), merged_http_kw...).body, OpenAICompletions.Response)
            isempty(response.choices) && return finalize_stream!(state, input, assistant_message, Usage(), :stop)
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
            if compat.stripThinkTags
                full_text = message_text(assistant_message)
                if occursin("</think>", full_text)
                    thinking, cleaned = strip_think_tags(full_text)
                    filter!(b -> !(b isa TextContent), assistant_message.content)
                    !isempty(cleaned) && pushfirst!(assistant_message.content, TextContent(; text = cleaned))
                    !isempty(thinking) && append_thinking!(assistant_message, thinking)
                end
            end
            # reasoning_details is canonical when present: providers (e.g.
            # OpenRouter) mirror the same text into the plain reasoning fields,
            # so appending both would duplicate the thinking content.
            details_text = choice.message.reasoning_details === nothing ? "" :
                openai_completions_reasoning_text(choice.message.reasoning_details)
            if choice.message.reasoning_details !== nothing
                openai_completions_append_thinking_with_details!(assistant_message, choice.message.reasoning_details)
            end
            if isempty(details_text)
                reasoning_parts = String[]
                for field in (:reasoning_content, :reasoning, :reasoning_text)
                    value = getfield(choice.message, field)
                    value === nothing && continue
                    isempty(value) && continue
                    push!(reasoning_parts, value)
                end
                isempty(reasoning_parts) || append_thinking!(assistant_message, join(reasoning_parts, "\n\n"))
            end
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
                    findtool(agent.tools, call.name)
                    ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                    f(ToolCallRequestEvent(ptc))
                end
            end
            latest_usage[] = response.usage
            latest_finish[] = choice.finish_reason
        end

        usage = openai_completions_usage_from_response(latest_usage[])
        stop_reason = openai_completions_stop_reason(latest_finish[], assistant_message.tool_calls)
        stream_failed[] && (stop_reason = :error)
        isaborted(abort) && (stop_reason = :aborted)
        return finalize_stream!(state, input, assistant_message, usage, stop_reason)
    elseif api isa Val{Symbol("anthropic-messages")}
        apikey isa AbstractString || throw(ArgumentError("apikey must be a String for provider $(model.provider)"))
        apikey = resolve_oauth_apikey(:anthropic, apikey)
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

        base_max_tokens = haskey(kw_nt, :max_tokens) ? kw_nt[:max_tokens] : model.maxTokens
        stream_kw = haskey(kw_nt, :max_tokens) ? Base.structdiff(kw_nt, (; max_tokens = 0)) : kw_nt
        stream_kw = haskey(stream_kw, :system) ? Base.structdiff(stream_kw, (; system = nothing)) : stream_kw

        # Reasoning effort uses the same kwarg surface as the openai/codex branches.
        reasoning_effort = get(() -> nothing, stream_kw, :reasoning_effort)
        reasoning_effort === nothing && (reasoning_effort = get(() -> nothing, stream_kw, :reasoningEffort))
        reasoning_effort === nothing && (reasoning_effort = get(() -> nothing, stream_kw, :reasoning))
        stream_kw = Base.structdiff(stream_kw, (; reasoning_effort = nothing, reasoningEffort = nothing, reasoning = nothing))

        cache_retention = get(() -> nothing, stream_kw, :cache_retention)
        cache_retention === nothing && (cache_retention = get(() -> nothing, stream_kw, :cacheRetention))
        stream_kw = Base.structdiff(stream_kw, (; cache_retention = nothing, cacheRetention = nothing))
        cache_control = anthropic_cache_control(model.baseUrl, cache_retention)
        anthropic_apply_cache_control!(messages, cache_control)

        system_prompt = agent_system_prompt(agent)
        system_value = is_oauth ? anthropic_oauth_system_blocks(system_prompt, cache_control) :
            anthropic_system_blocks(system_prompt, cache_control)
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

        # Thinking: a caller-supplied `thinking` kwarg wins, but is still clamped to what
        # the model supports; otherwise derive the config from the reasoning-effort level.
        max_tokens = base_max_tokens
        thinking_enabled = false
        if haskey(stream_kw, :thinking)
            normalized = anthropic_normalize_thinking(stream_kw[:thinking], model, base_max_tokens)
            max_tokens = normalized.max_tokens
            thinking_enabled = anthropic_thinking_is_enabled(normalized.thinking)
            request_kw = merge(request_kw, (; thinking = normalized.thinking))
        else
            thinking_request = anthropic_thinking_request(model, reasoning_effort, base_max_tokens)
            thinking_enabled = thinking_request.thinking !== nothing
            if thinking_enabled
                max_tokens = thinking_request.max_tokens
                request_kw = merge(request_kw, (; thinking = thinking_request.thinking))
                if thinking_request.output_config !== nothing && !haskey(stream_kw, :output_config)
                    request_kw = merge(request_kw, (; output_config = thinking_request.output_config))
                end
            end
        end

        thinking_value = get(() -> nothing, request_kw, :thinking)
        output_config = get(() -> nothing, request_kw, :output_config)
        if anthropic_disabled_effort_conflict(model, thinking_value, output_config)
            @warn "Anthropic rejects xhigh/max effort with thinking disabled; enabling adaptive thinking" model = model.id
            thinking_value = AnthropicMessages.ThinkingConfig(; type = "adaptive", display = "summarized")
            thinking_enabled = true
            request_kw = merge(request_kw, (; thinking = thinking_value))
        end

        # Manual extended thinking rejects forced tool selection. Keep the tools,
        # but let Anthropic select them with its default `auto` behavior.
        tool_choice = get(() -> nothing, request_kw, :tool_choice)
        tool_choice_type = anthropic_tool_choice_type(tool_choice)
        if anthropic_thinking_type(thinking_value) == "enabled" &&
                tool_choice_type !== nothing &&
                lowercase(String(tool_choice_type)) in ("any", "tool")
            @warn "Anthropic extended thinking does not support forced tool choice; using auto" model = model.id
            request_kw = merge(request_kw, (; tool_choice = nothing))
        end

        # The newest models reject all sampling controls. Older models reject
        # temperature and top_k while thinking is enabled. Their top_p value, when
        # supplied, must stay in the documented 0.95–1.0 interval.
        if anthropic_rejects_sampling_params(model)
            request_kw = merge(request_kw, (; temperature = nothing, top_p = nothing, top_k = nothing))
        elseif thinking_enabled
            request_kw = merge(request_kw, (; temperature = nothing, top_k = nothing))
            model_kw = model_request_kw(model)
            top_p = get(() -> get(() -> nothing, model_kw, :top_p), request_kw, :top_p)
            if top_p !== nothing && (!(top_p isa Real) || !(0.95 <= top_p <= 1.0))
                @warn "Anthropic thinking requires top_p between 0.95 and 1.0; omitting top_p" requested = top_p
                request_kw = merge(request_kw, (; top_p = nothing))
            end
        end

        disable_streaming = get(ENV, "AGENTIF_DISABLE_STREAMING", "") != ""
        typed_request = AnthropicMessages.Request(
            ; model = model.id,
            messages,
            max_tokens,
            stream = !disable_streaming,
            model_request_kw(model)...,
            request_kw...,
        )
        # A raw request template is required for `pause_turn`. Server-tool blocks
        # are intentionally unknown to the typed public content model, but Anthropic
        # requires every response field to be sent back unchanged.
        request_template = JSON.parse(JSON.json(typed_request))
        original_request_messages = deepcopy(request_template["messages"])
        function anthropic_request(msgs)
            req = deepcopy(request_template)
            req["messages"] = deepcopy(msgs)
            return req
        end
        headers = Dict(
            "anthropic-version" => "2023-06-01",
            "Content-Type" => "application/json",
            "Accept" => "application/json",
            "anthropic-dangerous-direct-browser-access" => "true",
        )
        # Add beta features for tool streaming
        beta_features = ["fine-grained-tool-streaming-2025-05-14"]
        # Interleaved thinking only does anything when the model reasons between tool
        # calls, and it is automatic (no header) under adaptive thinking.
        if thinking_enabled && !isempty(agent.tools) &&
                anthropic_needs_interleaved_thinking_beta(model, thinking_value)
            push!(beta_features, "interleaved-thinking-2025-05-14")
        end

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
            request_messages = original_request_messages
            total_usage = Usage()
            attempt = 0
            while true
                attempt += 1
                stop_reason[] = nothing
                req = anthropic_request(request_messages)
                response_body = String(HTTP.post(
                    url,
                    headers;
                    body = JSON.json(req),
                    merged_http_kw...,
                ).body)
                wire_response = JSON.parse(response_body)
                response = JSON.parse(response_body, AnthropicMessages.Response)
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
                    elseif block isa AnthropicMessages.RedactedThinkingBlock
                        push!(assistant_message.content, ThinkingContent(;
                            thinking = "",
                            thinkingSignature = block.data,
                            redacted = true,
                        ))
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
                        findtool(agent.tools, call.name)
                        ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                        f(ToolCallRequestEvent(ptc))
                    end
                end

                latest_usage[] = response.usage
                add_usage!(total_usage, anthropic_usage_from_response(response.usage))
                anthropic_should_resubmit_paused(stop_reason[], attempt, assistant_message) || break
                wire_content = get(() -> nothing, wire_response, "content")
                if !(wire_content isa AbstractVector) || isempty(wire_content)
                    @warn "Cannot safely replay an Anthropic pause_turn response without raw content"
                    break
                end
                # Docs: on every continuation, replace the message list with the
                # original turns plus the current paused response.
                request_messages = vcat(
                    deepcopy(original_request_messages),
                    Any[Dict{String, Any}(
                        "role" => "assistant",
                        "content" => deepcopy(wire_content),
                    )],
                )
            end

            text = message_text(assistant_message)
            if !isempty(text)
                f(MessageStartEvent(:assistant, assistant_message))
                f(MessageUpdateEvent(:assistant, assistant_message, :text, text, nothing))
                f(MessageEndEvent(:assistant, assistant_message))
            end

            final_stop = anthropic_stop_reason(stop_reason[], assistant_message.tool_calls)
            return finalize_stream!(state, input, assistant_message, total_usage, final_stop)
        else
            events_seen = Ref(false)
            stream_failed = Ref(false)
            request_http_kw = merge(merged_http_kw, (; retry = false))
            request_messages = original_request_messages
            wire_blocks_by_index = Dict{Int, Dict{String, Any}}()
            wire_partial_json_by_index = Dict{Int, String}()
            wire_replay_safe = Ref(true)
            total_usage = Usage()
            attempt = 0
            while true
                attempt += 1
                # Fresh accumulator state per attempt (stream indices restart at 0), while
                # `assistant_message` and the started/ended refs persist so a resumed turn
                # keeps appending to the same message and emits one start/end pair.
                stop_reason[] = nothing
                latest_usage[] = nothing
                empty!(blocks_by_index)
                empty!(partial_json_by_index)
                empty!(wire_blocks_by_index)
                empty!(wire_partial_json_by_index)
                wire_replay_safe[] = true
                events_seen[] = false
                sse_cb = sse_tracking_callback(
                    anthropic_event_callback(
                        f,
                        agent,
                        assistant_message,
                        started,
                        ended,
                        stop_reason,
                        latest_usage,
                        blocks_by_index,
                        partial_json_by_index,
                        wire_blocks_by_index,
                        wire_partial_json_by_index,
                        wire_replay_safe,
                        tool_name_reverse_map,
                        abort,
                    ),
                    events_seen,
                )
                req = anthropic_request(request_messages)
                try
                    sse_request_with_retry(events_seen, abort; max_attempts = sse_retry_attempts(merged_http_kw)) do
                        HTTP.post(
                            url,
                            headers;
                            body = JSON.json(req),
                            sse_callback = sse_cb,
                            request_http_kw...,
                        )
                    end
                catch e
                    handle_sse_stream_error(
                        e, f, assistant_message, started, ended, events_seen;
                        on_status_error = () -> (stop_reason[] = "error"),
                        on_interrupted = () -> (stream_failed[] = true),
                    )
                end

                add_usage!(total_usage, anthropic_usage_from_response(latest_usage[]))
                (stream_failed[] || isaborted(abort)) && break
                anthropic_should_resubmit_paused(stop_reason[], attempt, assistant_message) || break
                attempt_wire_content = [
                    deepcopy(wire_blocks_by_index[index])
                    for index in sort!(collect(keys(wire_blocks_by_index)))
                ]
                if !wire_replay_safe[] || isempty(attempt_wire_content)
                    @warn "Cannot safely replay an Anthropic pause_turn stream with incomplete raw content"
                    break
                end
                # Docs: on every continuation, replace the message list with the
                # original turns plus the current paused response.
                request_messages = vcat(
                    deepcopy(original_request_messages),
                    Any[Dict{String, Any}(
                        "role" => "assistant",
                        "content" => attempt_wire_content,
                    )],
                )
            end

            if started[] && !ended[]
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end

            final_stop = anthropic_stop_reason(stop_reason[], assistant_message.tool_calls)
            stream_failed[] && (final_stop = :error)
            isaborted(abort) && (final_stop = :aborted)
            return finalize_stream!(state, input, assistant_message, total_usage, final_stop)
        end
    elseif api isa Val{Symbol("google-generative-ai")}
        apikey isa AbstractString || throw(ArgumentError("apikey must be a String for provider $(model.provider)"))
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
            model_request_kw(model)...,
            request_kw...,
        )
        headers = Dict(
            "x-goog-api-key" => apikey,
            "Content-Type" => "application/json",
        )
        model.headers !== nothing && merge!(headers, model.headers)
        url = joinpath(model.baseUrl, "models", "$(model.id):streamGenerateContent")
        events_seen = Ref(false)
        stream_failed = Ref(false)
        sse_cb = sse_tracking_callback(
            google_generative_event_callback(
                f,
                agent,
                assistant_message,
                started,
                ended,
                latest_usage,
                latest_finish,
                seen_call_ids,
                abort,
            ),
            events_seen,
        )
        request_http_kw = merge(merged_http_kw, (; retry = false))
        try
            sse_request_with_retry(events_seen, abort; max_attempts = sse_retry_attempts(merged_http_kw)) do
                HTTP.post(
                    url * "?alt=sse",
                    headers;
                    body = JSON.json(req),
                    sse_callback = sse_cb,
                    request_http_kw...,
                )
            end
        catch e
            handle_sse_stream_error(
                e, f, assistant_message, started, ended, events_seen;
                on_status_error = () -> (stream_failed[] = true),
                on_interrupted = () -> (stream_failed[] = true),
            )
        end

        if started[] && !ended[]
            ended[] = true
            f(MessageEndEvent(:assistant, assistant_message))
        end

        usage = google_generative_usage_from_response(latest_usage[])
        stop_reason = google_generative_stop_reason(latest_finish[], assistant_message.tool_calls)
        stream_failed[] && (stop_reason = :error)
        isaborted(abort) && (stop_reason = :aborted)
        return finalize_stream!(state, input, assistant_message, usage, stop_reason)
    elseif api isa Val{Symbol("google-gemini-cli")}
        apikey isa AbstractString || throw(ArgumentError("apikey must be a String for provider $(model.provider)"))
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

        debug_stream = get(ENV, "AGENTIF_DEBUG_GEMINI_STREAM", "") != ""
        events_seen = Ref(false)
        stream_failed = Ref(false)
        sse_cb = sse_tracking_callback(
            google_gemini_cli_event_callback(
                f,
                agent,
                assistant_message,
                started,
                ended,
                latest_usage,
                latest_finish,
                seen_call_ids,
                debug_stream,
                abort,
            ),
            events_seen,
        )
        request_http_kw = merge(merged_http_kw, (; retry = false))
        try
            sse_request_with_retry(events_seen, abort; max_attempts = sse_retry_attempts(merged_http_kw)) do
                HTTP.post(
                    url,
                    headers;
                    body = JSON.json(req),
                    sse_callback = sse_cb,
                    request_http_kw...,
                )
            end
        catch e
            handle_sse_stream_error(
                e, f, assistant_message, started, ended, events_seen;
                on_status_error = () -> (stream_failed[] = true),
                on_interrupted = () -> (stream_failed[] = true),
            )
        end

        if started[] && !ended[]
            ended[] = true
            f(MessageEndEvent(:assistant, assistant_message))
        end

        usage = google_gemini_cli_usage_from_response(latest_usage[])
        stop_reason = google_gemini_cli_stop_reason(latest_finish[], assistant_message.tool_calls)
        stream_failed[] && (stop_reason = :error)
        isaborted(abort) && (stop_reason = :aborted)
        return finalize_stream!(state, input, assistant_message, usage, stop_reason)
    elseif api isa Val{Symbol("openai-codex-responses")}
        apikey isa AbstractString || throw(ArgumentError("apikey must be a String for provider $(model.provider)"))
        apikey = resolve_oauth_apikey(:codex, apikey)
        account_id = get(() -> nothing, kw_nt, :account_id)
        account_id === nothing &&
            (account_id = get(() -> nothing, kw_nt, :accountId))
        account_id = resolve_codex_account_id(account_id, String(apikey))
        account_id === nothing && throw(ArgumentError("Missing `account_id` for openai-codex provider and unable to infer it from access token"))

        assistant_message = assistant_message_for_model(model; response_id = state.response_id)
        started = Ref(false)
        ended = Ref(false)
        response_usage = Ref{Any}(nothing)
        response_status = Ref{Union{Nothing, String}}(nothing)
        tool_call_accumulators = Dict{String, ToolCallAccumulator}()

        codex_kw = Dict{Symbol, Any}(pairs(kw_nt))
        haskey(codex_kw, :instructions) && delete!(codex_kw, :instructions)
        haskey(codex_kw, :account_id) && delete!(codex_kw, :account_id)
        haskey(codex_kw, :accountId) && delete!(codex_kw, :accountId)

        session_id = pop!(codex_kw, :session_id, nothing)
        session_id === nothing &&
            (session_id = pop!(codex_kw, :sessionId, nothing))

        reasoning_effort = pop!(codex_kw, :reasoning_effort, nothing)
        reasoning_effort === nothing &&
            (reasoning_effort = pop!(codex_kw, :reasoningEffort, nothing))
        if reasoning_effort === nothing && haskey(codex_kw, :reasoning)
            reasoning_effort = pop!(codex_kw, :reasoning, nothing)
        end
        reasoning_summary = pop!(codex_kw, :reasoning_summary, nothing)
        reasoning_summary === nothing &&
            (reasoning_summary = pop!(codex_kw, :reasoningSummary, nothing))
        text_verbosity = pop!(codex_kw, :textVerbosity, nothing)
        text_verbosity === nothing &&
            (text_verbosity = pop!(codex_kw, :text_verbosity, nothing))
        include_opt = pop!(codex_kw, :include, nothing)
        max_tokens = pop!(codex_kw, :maxTokens, nothing)
        transport = normalize_codex_transport(codex_pop_option!(
            codex_kw, :transport, :transportMode, :websocket, :websockets))
        retry_settings = codex_retry_settings!(codex_kw)

        tools = build_codex_tools(agent.tools)
        current_input = openai_responses_build_full_input(agent, state, input, model)
        system_prompt = agent_system_prompt(agent)

        request_body = Dict{String, Any}(
            "model" => model.id,
            "input" => current_input,
            "stream" => true,
            "instructions" => system_prompt,
            "tool_choice" => "auto",
            "parallel_tool_calls" => true,
        )
        tools !== nothing && (request_body["tools"] = tools)
        session_id !== nothing && (request_body["prompt_cache_key"] = session_id)
        max_tokens !== nothing && (request_body["max_output_tokens"] = max_tokens)

        provider_kw = model_request_kw(model)
        if provider_kw !== nothing
            for (k, v) in pairs(provider_kw)
                request_body[string(k)] = v
            end
        end
        for (k, v) in codex_kw
            request_body[string(k)] = v
        end

        transform_request_body!(
            request_body;
            reasoning_effort = reasoning_effort === nothing ? nothing : string(reasoning_effort),
            reasoning_summary = reasoning_summary === nothing ? nothing : string(reasoning_summary),
            text_verbosity = text_verbosity === nothing ? nothing : string(text_verbosity),
            include = include_opt,
        )

        headers = create_codex_headers(
            model.headers === nothing ? nothing : Dict(model.headers),
            string(account_id),
            String(apikey),
            session_id,
        )

        url = resolve_codex_url(model.baseUrl)

        log_codex_debug(
            "codex request", Dict(
                "url" => url,
                "model" => model.id,
                "reasoningEffort" => reasoning_effort,
                "reasoningSummary" => reasoning_summary,
                "textVerbosity" => text_verbosity,
                "include" => include_opt,
                "transport" => string(transport),
                "maxRetries" => retry_settings.max_retries,
                "retryBaseMs" => retry_settings.retry_base_ms,
                "retryMaxMs" => retry_settings.retry_max_ms,
                "instructions_length" => length(string(get(request_body, "instructions", ""))),
                "instructions_preview" => first(string(get(request_body, "instructions", "")), min(200, length(string(get(request_body, "instructions", ""))))),
                "headers" => redact_headers(headers),
            )
        )

        callback = openai_codex_event_callback(
            f,
            agent,
            assistant_message,
            started,
            ended,
            response_usage,
            response_status,
            tool_call_accumulators,
            abort,
        )

        request_http_kw = merge(merged_http_kw, (; retry = false, read_idle_timeout = 300))
        resp = nothing
        used_websocket = false

        if transport != :sse
            ws_url = resolve_codex_websocket_url(model.baseUrl)
            try
                codex_stream_websocket!(
                    callback,
                    ws_url,
                    headers,
                    request_body,
                    abort;
                    http_kw = request_http_kw,
                )
                used_websocket = true
            catch e
                if e isa StopStreaming
                    rethrow()
                end
                if transport == :websocket || started[] || ended[]
                    rethrow()
                end
                log_codex_debug(
                    "codex websocket fallback", Dict(
                        "error" => sprint(showerror, e),
                        "fallback_transport" => "sse",
                    )
                )
            end
        end

        if !used_websocket
            try
                resp = codex_stream_sse_with_retry!(
                    callback,
                    url,
                    headers,
                    request_body,
                    abort;
                    http_kw = request_http_kw,
                    max_retries = retry_settings.max_retries,
                    retry_base_ms = retry_settings.retry_base_ms,
                    retry_max_ms = retry_settings.retry_max_ms,
                )
            catch e
                if !(e isa StopStreaming)
                    rethrow()
                end
            end
        end

        if resp !== nothing
            if !started[] && !isempty(resp.body)
                replayed = codex_replay_sse_body!(callback, resp.body)
                replayed && log_codex_debug(
                    "codex sse replayed body events",
                    Dict("body_bytes" => length(resp.body)),
                )
            end
            log_codex_debug(
                "codex response", Dict(
                    "url" => url,
                    "status" => resp.status,
                    "content_type" => HTTP.header(resp, "content-type"),
                    "cf_ray" => HTTP.header(resp, "cf-ray"),
                )
            )
        end

        if started[] && !ended[]
            ended[] = true
            f(MessageEndEvent(:assistant, assistant_message))
        end

        if !isaborted(abort)
            for (call_id, acc) in tool_call_accumulators
                acc.name === nothing && continue
                args = isempty(acc.arguments) ? "{}" : acc.arguments
                call = AgentToolCall(; call_id = call_id, name = acc.name, arguments = args)
                if !any(tc -> tc.call_id == call_id, assistant_message.tool_calls)
                    push!(assistant_message.tool_calls, call)
                    findtool(agent.tools, call.name)
                    ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                    f(ToolCallRequestEvent(ptc))
                end
            end
        end

        usage = codex_usage_from_response(response_usage[])
        stop_reason = codex_stop_reason(response_status[], assistant_message.tool_calls)
        isaborted(abort) && (stop_reason = :aborted)
        return finalize_stream!(state, input, assistant_message, usage, stop_reason)
    else
        throw(ArgumentError("$(model.name) using $(model.api) api currently unsupported"))
    end
end
