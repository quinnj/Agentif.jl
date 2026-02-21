using JSON
using HTTP

const CODEX_BASE_URL = "https://chatgpt.com/backend-api"

const OPENAI_HEADERS = (
    beta = "OpenAI-Beta",
    account_id = "chatgpt-account-id",
    originator = "originator",
    session_id = "session_id",
    conversation_id = "conversation_id",
)

const OPENAI_HEADER_VALUES = (
    beta_responses = "responses=experimental",
    beta_responses_websocket = "responses_websockets=2026-02-06",
    originator_codex = "pi",
)

const CODEX_JWT_CLAIM_PATH = "https://api.openai.com/auth"
const CODEX_DEBUG = lowercase(get(ENV, "AGENTIF_CODEX_DEBUG", "false")) in ("1", "true", "yes", "on")
const CODEX_DEFAULT_MAX_RETRIES = 3
const CODEX_DEFAULT_RETRY_BASE_MS = 1000
const CODEX_DEFAULT_RETRY_MAX_MS = 60000
const CODEX_RETRYABLE_ERROR_REGEX = r"rate.?limit|overloaded|service.?unavailable|upstream.?connect|connection.?refused|connection.?reset|reset.?before.?headers|terminated|temporar"i

function resolve_codex_url(base_url::AbstractString)
    raw = strip(String(base_url))
    raw = isempty(raw) ? CODEX_BASE_URL : raw
    normalized = replace(raw, r"/+$" => "")
    if endswith(normalized, "/codex/responses")
        return normalized
    elseif endswith(normalized, "/codex")
        return normalized * "/responses"
    end
    return normalized * "/codex/responses"
end

function resolve_codex_websocket_url(base_url::AbstractString)
    url = resolve_codex_url(base_url)
    if startswith(url, "https://")
        return "wss://" * url[9:end]
    elseif startswith(url, "http://")
        return "ws://" * url[8:end]
    end
    return url
end

function normalize_codex_transport(value)::Symbol
    value === nothing && return :sse
    value isa Bool && return value ? :websocket : :sse

    text = lowercase(strip(string(value)))
    text in ("", "sse") && return :sse
    text in ("ws", "websocket") && return :websocket
    text == "auto" && return :auto
    throw(ArgumentError("Unsupported codex transport: $(value). Expected one of: sse, websocket, auto."))
end

function codex_pop_option!(kw::Dict{Symbol, Any}, key::Symbol, aliases::Symbol...; default = nothing)
    if haskey(kw, key)
        return pop!(kw, key)
    end
    for alias in aliases
        if haskey(kw, alias)
            return pop!(kw, alias)
        end
    end
    return default
end

function codex_env_int(name::String, default::Int)
    raw = strip(get(ENV, name, ""))
    isempty(raw) && return default
    parsed = tryparse(Int, raw)
    parsed === nothing && return default
    return max(0, parsed)
end

function codex_parse_nonnegative_int(value, default::Int, label::String)
    value === nothing && return default
    parsed = parse_int(value)
    parsed === nothing && throw(ArgumentError("Invalid $label value: $(value)"))
    return max(0, parsed)
end

function codex_retry_settings!(kw::Dict{Symbol, Any})
    max_retries = codex_parse_nonnegative_int(
        codex_pop_option!(kw, :max_retries, :maxRetries, :codex_max_retries, :codexMaxRetries),
        codex_env_int("AGENTIF_CODEX_MAX_RETRIES", CODEX_DEFAULT_MAX_RETRIES),
        "max_retries",
    )
    retry_base_ms = codex_parse_nonnegative_int(
        codex_pop_option!(kw, :retry_base_ms, :retryBaseMs, :codex_retry_base_ms, :codexRetryBaseMs),
        codex_env_int("AGENTIF_CODEX_RETRY_BASE_MS", CODEX_DEFAULT_RETRY_BASE_MS),
        "retry_base_ms",
    )
    retry_max_ms = codex_parse_nonnegative_int(
        codex_pop_option!(kw, :retry_max_ms, :retryMaxMs, :codex_retry_max_ms, :codexRetryMaxMs),
        codex_env_int("AGENTIF_CODEX_RETRY_MAX_MS", CODEX_DEFAULT_RETRY_MAX_MS),
        "retry_max_ms",
    )
    return (; max_retries, retry_base_ms, retry_max_ms)
end

function build_codex_tools(tools::Vector{AgentTool})
    isempty(tools) && return nothing
    provider_tools = Vector{Dict{String, Any}}()
    for tool in tools
        push!(
            provider_tools, Dict(
                "type" => "function",
                "name" => tool.name,
                "description" => something(tool.description, "Custom tool"),
                "parameters" => OpenAIResponses.schema(parameters(tool)),
                "strict" => nothing,
            )
        )
    end
    return provider_tools
end

function clamp_reasoning_effort(model::String, effort::String)
    model_id = occursin("/", model) ? split(model, "/")[end] : model
    if (startswith(model_id, "gpt-5.2") || startswith(model_id, "gpt-5.3")) && effort == "minimal"
        return "low"
    end
    if model_id == "gpt-5.1" && effort == "xhigh"
        return "high"
    elseif model_id == "gpt-5.1-codex-mini"
        return (effort == "high" || effort == "xhigh") ? "high" : "medium"
    end
    return effort
end

function decode_base64url(data::AbstractString)
    payload = replace(String(data), '-' => '+', '_' => '/')
    padding = mod(4 - mod(length(payload), 4), 4)
    padding > 0 && (payload *= repeat("=", padding))
    return String(Base64.base64decode(payload))
end

function codex_account_id_from_access_token(access_token::AbstractString)
    parts = split(String(access_token), ".")
    length(parts) == 3 || return nothing
    try
        payload = JSON.parse(Vector{UInt8}(codeunits(decode_base64url(parts[2]))))
        auth_claims = get(() -> nothing, payload, CODEX_JWT_CLAIM_PATH)
        auth_claims isa AbstractDict || return nothing
        account_id = get(() -> nothing, auth_claims, "chatgpt_account_id")
        return (account_id isa AbstractString && !isempty(account_id)) ? String(account_id) : nothing
    catch
        return nothing
    end
end

function resolve_codex_account_id(account_id::Union{Nothing, Any}, access_token::AbstractString)
    if account_id !== nothing
        explicit = strip(string(account_id))
        !isempty(explicit) && return explicit
    end
    return codex_account_id_from_access_token(access_token)
end

function transform_request_body!(
        body::Dict{String, Any};
        reasoning_effort::Union{Nothing, String} = nothing,
        reasoning_summary::Union{Nothing, String} = nothing,
        text_verbosity::Union{Nothing, String} = nothing,
        include::Union{Nothing, Vector{String}} = nothing,
        developer_messages::Vector{String} = String[],
    )
    body["store"] = false
    body["stream"] = true

    if haskey(body, "input") && body["input"] isa Vector
        filtered = Any[]
        function_call_ids = Set{String}()
        for item in body["input"]
            if !(item isa Dict)
                push!(filtered, item)
                continue
            end
            item_type = get(item, "type", nothing)
            if item_type == "item_reference"
                continue
            end
            if haskey(item, "id")
                delete!(item, "id")
            end
            if item_type == "function_call"
                call_id = get(item, "call_id", nothing)
                call_id isa String && push!(function_call_ids, call_id)
            end
            push!(filtered, item)
        end

        mapped = Any[]
        for item in filtered
            if item isa Dict && get(item, "type", nothing) == "function_call_output"
                call_id = get(item, "call_id", nothing)
                if !(call_id isa String) || !(call_id in function_call_ids)
                    tool_name = get(item, "name", "tool")
                    output = get(item, "output", "")
                    text = try
                        output isa String ? output : JSON.json(output)
                    catch
                        string(output)
                    end
                    if length(text) > 16000
                        text = string(text[1:16000], "\n...[truncated]")
                    end
                    push!(
                        mapped, Dict(
                            "type" => "message",
                            "role" => "assistant",
                            "content" => "[Previous $(tool_name) result; call_id=$(get(item, "call_id", ""))]: $(text)",
                        )
                    )
                    continue
                end
            end
            push!(mapped, item)
        end

        if !isempty(developer_messages)
            dev_items = [
                Dict(
                        "type" => "message",
                        "role" => "developer",
                        "content" => [Dict("type" => "input_text", "text" => msg)],
                    ) for msg in developer_messages
            ]
            body["input"] = vcat(dev_items, mapped)
        else
            body["input"] = mapped
        end
    end

    if reasoning_effort !== nothing
        body["reasoning"] = Dict(
            "effort" => clamp_reasoning_effort(string(body["model"]), reasoning_effort),
            "summary" => something(reasoning_summary, "auto"),
        )
    else
        haskey(body, "reasoning") && delete!(body, "reasoning")
    end

    body["text"] = merge(get(body, "text", Dict{String, Any}()), Dict("verbosity" => something(text_verbosity, "medium")))

    includes = Vector{String}()
    if include !== nothing
        append!(includes, include)
    end
    push!(includes, "reasoning.encrypted_content")
    body["include"] = unique(includes)

    haskey(body, "max_output_tokens") && delete!(body, "max_output_tokens")
    haskey(body, "max_completion_tokens") && delete!(body, "max_completion_tokens")
    return body
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
    elseif msg isa CompactionSummaryMessage
        return Any[Dict("role" => "user", "content" => [Dict("type" => "input_text", "text" => "[Previous conversation summary]\n\n$(msg.summary)")])]
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
    reason = map_stop_reason(status)
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
        abort::Abort,
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

    return function (stream, event)
        maybe_abort!(abort, stream)
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
            raw = JSON.parse(Vector{UInt8}(codeunits(data)))
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
                findtool(agent.tools, call.name)
                ptc = PendingToolCall(; call_id = call.call_id, name = call.name, arguments = call.arguments)
                f(ToolCallRequestEvent(ptc))
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
            error_text = format_codex_error_event(raw, code, msg)
            if started[] && !ended[]
                ended[] = true
                f(MessageEndEvent(:assistant, assistant_message))
            end
            response_status[] = "failed"
            f(AgentErrorEvent(ErrorException(error_text)))
        end
    end
end

function create_codex_headers(
        init_headers::Union{Nothing, Dict{String, String}},
        account_id::String,
        access_token::String,
        session_id::Union{Nothing, String} = nothing,
    )
    headers = init_headers === nothing ? Dict{String, String}() : copy(init_headers)
    haskey(headers, "x-api-key") && delete!(headers, "x-api-key")
    headers["Authorization"] = "Bearer $(access_token)"
    headers[OPENAI_HEADERS.account_id] = account_id
    headers[OPENAI_HEADERS.beta] = OPENAI_HEADER_VALUES.beta_responses
    headers[OPENAI_HEADERS.originator] = OPENAI_HEADER_VALUES.originator_codex
    headers["User-Agent"] = "pi"

    if session_id !== nothing
        headers[OPENAI_HEADERS.session_id] = session_id
        headers[OPENAI_HEADERS.conversation_id] = session_id
    else
        delete!(headers, OPENAI_HEADERS.session_id)
        delete!(headers, OPENAI_HEADERS.conversation_id)
    end

    headers["Accept"] = "text/event-stream"
    headers["Content-Type"] = "application/json"
    return headers
end

function create_codex_websocket_headers(headers::Dict{String, String})
    ws_headers = copy(headers)
    ws_headers[OPENAI_HEADERS.beta] = OPENAI_HEADER_VALUES.beta_responses_websocket
    ws_headers["Accept"] = "application/json"
    return ws_headers
end

function codex_event_type_from_payload(data::AbstractString)
    raw = try
        JSON.parse(Vector{UInt8}(codeunits(data)))
    catch
        return nothing
    end
    event_type = get(() -> nothing, raw, "type")
    return event_type isa AbstractString ? String(event_type) : nothing
end

function codex_terminal_event_type(event_type::Union{Nothing, String})
    event_type === nothing && return false
    return event_type in ("response.completed", "response.done", "response.failed", "response.incomplete", "error")
end

function map_stop_reason(status::Union{Nothing, String})
    status === nothing && return :stop
    if status == "completed"
        return :stop
    elseif status == "incomplete"
        return :length
    elseif status == "failed" || status == "cancelled"
        return :error
    elseif status == "in_progress" || status == "queued"
        return :stop
    end
    return :stop
end

function as_record(value)
    return value isa AbstractDict ? value : nothing
end

function get_string(value)
    return value isa AbstractString ? String(value) : nothing
end

function truncate_text(text::String, limit::Int)
    length(text) <= limit && return text
    return string(text[1:limit], "...[truncated $(length(text) - limit)]")
end

function format_codex_failure(raw_event::Dict{String, Any})
    response = as_record(get(raw_event, "response", nothing))
    error = as_record(get(raw_event, "error", nothing))
    if error === nothing && response !== nothing
        error = as_record(get(response, "error", nothing))
    end

    message = get_string(get(error, "message", nothing))
    message === nothing && (message = get_string(get(raw_event, "message", nothing)))
    if message === nothing && response !== nothing
        message = get_string(get(response, "message", nothing))
    end
    code = get_string(get(error, "code", nothing))
    code === nothing && (code = get_string(get(error, "type", nothing)))
    code === nothing && (code = get_string(get(raw_event, "code", nothing)))
    status = response === nothing ? nothing : get_string(get(response, "status", nothing))
    status === nothing && (status = get_string(get(raw_event, "status", nothing)))

    meta = String[]
    code !== nothing && push!(meta, "code=$(code)")
    status !== nothing && push!(meta, "status=$(status)")

    if message !== nothing
        meta_text = isempty(meta) ? "" : " ($(join(meta, ", ")))"
        return "Codex response failed: $(message)$(meta_text)"
    end
    if !isempty(meta)
        return "Codex response failed ($(join(meta, ", ")))"
    end
    try
        return "Codex response failed: $(truncate_text(JSON.json(raw_event), 800))"
    catch
        return "Codex response failed"
    end
end

function format_codex_error_event(raw_event::Dict{String, Any}, code::String, message::String)
    detail = format_codex_failure(raw_event)
    if detail !== nothing
        return replace(detail, "response failed" => "error event")
    end

    meta = String[]
    !isempty(code) && push!(meta, "code=$(code)")
    !isempty(message) && push!(meta, "message=$(message)")
    if !isempty(meta)
        return "Codex error event ($(join(meta, ", ")))"
    end

    try
        return "Codex error event: $(truncate_text(JSON.json(raw_event), 800))"
    catch
        return "Codex error event"
    end
end

function parse_number(val)
    val === nothing && return nothing
    if val isa Number
        return Float64(val)
    elseif val isa AbstractString
        parsed = tryparse(Float64, val)
        return parsed === nothing ? nothing : parsed
    end
    return nothing
end

function parse_int(val)
    val === nothing && return nothing
    if val isa Integer
        return Int(val)
    elseif val isa AbstractString
        parsed = tryparse(Int, val)
        return parsed === nothing ? nothing : parsed
    end
    return nothing
end

function parse_codex_error(resp::HTTP.Response)
    raw = String(resp.body)
    message = isempty(raw) ? (resp.status == 0 ? "Request failed" : "Request failed ($(resp.status))") : raw
    friendly = nothing

    try
        parsed = JSON.parse(raw)
        err = get(parsed, "error", Dict{String, Any}())
        primary = (
            used_percent = parse_number(HTTP.header(resp, "x-codex-primary-used-percent")),
            window_minutes = parse_int(HTTP.header(resp, "x-codex-primary-window-minutes")),
            resets_at = parse_int(HTTP.header(resp, "x-codex-primary-reset-at")),
        )
        secondary = (
            used_percent = parse_number(HTTP.header(resp, "x-codex-secondary-used-percent")),
            window_minutes = parse_int(HTTP.header(resp, "x-codex-secondary-window-minutes")),
            resets_at = parse_int(HTTP.header(resp, "x-codex-secondary-reset-at")),
        )
        code = string(get(err, "code", get(err, "type", "")))
        resets_at = get(err, "resets_at", something(primary.resets_at, secondary.resets_at))
        mins = resets_at === nothing ? nothing : max(0, round(Int, (resets_at * 1000 - time() * 1000) / 60000))

        if occursin(r"usage_limit_reached|usage_not_included|rate_limit_exceeded"i, code) || resp.status == 429
            plan_type = get(err, "plan_type", nothing)
            plan = plan_type === nothing ? "" : " ($(lowercase(string(plan_type))) plan)"
            when = mins === nothing ? "" : " Try again in ~$(mins) min."
            friendly = strip("You have hit your ChatGPT usage limit$(plan).$(when)")
        end

        err_message = get(err, "message", nothing)
        if err_message isa AbstractString && !isempty(err_message)
            message = String(err_message)
        elseif friendly !== nothing
            message = friendly
        end
    catch
    end

    return (;
        message,
        friendly_message = friendly,
        status = resp.status,
    )
end

codex_retryable_status(status::Integer) = Int(status) in (408, 409, 429, 500, 502, 503, 504, 599)

function codex_retryable_message(message::AbstractString)
    isempty(message) && return false
    return occursin(CODEX_RETRYABLE_ERROR_REGEX, lowercase(message))
end

function codex_retryable_exception(err::Exception)
    if err isa HTTP.ConnectError
        return true
    elseif err isa HTTP.RequestError
        inner = err.error
        inner isa Exception && return codex_retryable_exception(inner)
        return codex_retryable_message(string(inner))
    elseif err isa EOFError || err isa Base.IOError || err isa InterruptException
        return true
    end
    return codex_retryable_message(sprint(showerror, err))
end

function codex_retry_after_seconds(resp::HTTP.Response)
    raw = strip(HTTP.header(resp, "retry-after"))
    isempty(raw) && return nothing
    parsed = tryparse(Float64, raw)
    parsed === nothing && return nothing
    return max(0.0, parsed)
end

function codex_retry_delay_seconds(attempt::Int, retry_base_ms::Int, retry_max_ms::Int; response::Union{Nothing, HTTP.Response} = nothing)
    retry_after = response === nothing ? nothing : codex_retry_after_seconds(response)
    if retry_after !== nothing
        return min(retry_after, retry_max_ms / 1000)
    end
    exp_ms = retry_base_ms * (2.0^(max(attempt - 1, 0)))
    delay_ms = min(retry_max_ms, exp_ms)
    # Keep jitter small to avoid long/erratic delays for interactive usage.
    jitter_ms = delay_ms * 0.1 * rand()
    return max(0.0, (delay_ms + jitter_ms) / 1000)
end

function codex_sleep_with_abort!(delay_s::Real, abort::Abort)
    delay_s <= 0 && return
    deadline = time() + delay_s
    while true
        isaborted(abort) && throw(StopStreaming("aborted"))
        remaining = deadline - time()
        remaining <= 0 && return
        sleep(min(remaining, 0.05))
    end
end

function codex_stream_sse_with_retry!(
        callback::Function,
        url::String,
        headers::Dict{String, String},
        request_body::Dict{String, Any},
        abort::Abort;
        http_kw = (;),
        max_retries::Int = CODEX_DEFAULT_MAX_RETRIES,
        retry_base_ms::Int = CODEX_DEFAULT_RETRY_BASE_MS,
        retry_max_ms::Int = CODEX_DEFAULT_RETRY_MAX_MS,
    )
    http_nt = http_kw isa NamedTuple ? http_kw : (; http_kw...)
    request_http_kw = merge(http_nt, (; retry = false, status_exception = false))
    payload = JSON.json(request_body)
    attempt = 0

    while true
        isaborted(abort) && throw(StopStreaming("aborted"))

        local resp
        try
            resp = HTTP.post(
                url,
                headers;
                body = payload,
                sse_callback = callback,
                request_http_kw...,
            )
        catch err
            err isa StopStreaming && rethrow()
            if attempt < max_retries && codex_retryable_exception(err)
                attempt += 1
                delay_s = codex_retry_delay_seconds(attempt, retry_base_ms, retry_max_ms)
                log_codex_debug(
                    "codex sse retry",
                    Dict(
                        "attempt" => attempt,
                        "max_retries" => max_retries,
                        "delay_s" => delay_s,
                        "error" => sprint(showerror, err),
                    ),
                )
                codex_sleep_with_abort!(delay_s, abort)
                continue
            end
            rethrow()
        end

        if resp.status in 200:299
            return resp
        end

        info = parse_codex_error(resp)
        info_msg = String(get(() -> "", info, :message))
        retryable = codex_retryable_status(resp.status) || codex_retryable_message(info_msg)
        if attempt < max_retries && retryable
            attempt += 1
            delay_s = codex_retry_delay_seconds(attempt, retry_base_ms, retry_max_ms; response = resp)
            log_codex_debug(
                "codex sse retry",
                Dict(
                    "attempt" => attempt,
                    "max_retries" => max_retries,
                    "delay_s" => delay_s,
                    "status" => resp.status,
                    "message" => info_msg,
                ),
            )
            codex_sleep_with_abort!(delay_s, abort)
            continue
        end

        msg = info.friendly_message === nothing ? info.message : info.friendly_message
        throw(ErrorException(msg))
    end
end

function codex_stream_websocket!(
        callback::Function,
        ws_url::String,
        headers::Dict{String, String},
        request_body::Dict{String, Any},
        abort::Abort;
        http_kw = (;),
    )
    http_nt = http_kw isa NamedTuple ? http_kw : (; http_kw...)
    ws_open_kw = merge(http_nt, (; retry = false))
    ws_headers = create_codex_websocket_headers(headers)
    start_request = copy(request_body)
    start_request["type"] = "response.create"
    saw_terminal = false

    HTTP.WebSockets.open(ws_url; headers = collect(pairs(ws_headers)), suppress_close_error = true, ws_open_kw...) do ws
        maybe_abort!(abort, ws)
        HTTP.WebSockets.send(ws, JSON.json(start_request))
        while true
            maybe_abort!(abort, ws)
            msg = try
                HTTP.WebSockets.receive(ws)
            catch err
                if err isa HTTP.WebSockets.WebSocketError && HTTP.WebSockets.isok(err)
                    break
                end
                rethrow()
            end
            data = msg isa AbstractString ? String(msg) : String(msg)
            callback(ws, (; data))
            event_type = codex_event_type_from_payload(data)
            if codex_terminal_event_type(event_type)
                saw_terminal = true
                break
            end
        end
    end

    saw_terminal || throw(ErrorException("Codex websocket stream closed before response completion"))
    return nothing
end

function codex_replay_sse_body!(callback::Function, body::AbstractVector{UInt8})
    isempty(body) && return false
    text = replace(String(body), "\r\n" => "\n")
    isempty(strip(text)) && return false
    saw_payload = false
    for block in split(text, "\n\n")
        stripped = strip(block)
        isempty(stripped) && continue
        data_lines = String[]
        for line in split(stripped, '\n')
            startswith(line, "data:") || continue
            push!(data_lines, strip(line[6:end]))
        end
        isempty(data_lines) && continue
        payload = join(data_lines, "\n")
        isempty(strip(payload)) && continue
        callback(nothing, (; data = payload))
        saw_payload = true
    end
    return saw_payload
end

function redact_headers(headers::AbstractDict)
    redacted = Dict{Any, Any}()
    for (k, v) in headers
        key_str = String(k)
        lower = lowercase(key_str)
        if lower == "authorization"
            redacted[key_str] = "Bearer [redacted]"
        elseif occursin("account", lower) || occursin("session", lower) || occursin("conversation", lower) || lower == "cookie"
            redacted[key_str] = "[redacted]"
        else
            redacted[key_str] = v
        end
    end
    return redacted
end

function log_codex_debug(message::AbstractString, details = nothing)
    CODEX_DEBUG || return
    return if details === nothing
        println("[codex] ", message)
    else
        println("[codex] ", message, " ", details)
    end
end
