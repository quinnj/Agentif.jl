using JSON
using HTTP

const CODEX_BASE_URL = "https://chatgpt.com/backend-api"

const OPENAI_HEADERS = (
    beta = "OpenAI-Beta",
    account_id = "chatgpt-account-id",
    originator = "originator",
    session_id = "session_id",
)

const OPENAI_HEADER_VALUES = (
    beta_responses = "responses=experimental",
    originator_codex = "pi",
)

const CODEX_DEBUG = true

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
    if model_id == "gpt-5.1" && effort == "xhigh"
        return "high"
    elseif model_id == "gpt-5.1-codex-mini"
        return (effort == "high" || effort == "xhigh") ? "high" : "medium"
    end
    return effort
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
    else
        delete!(headers, OPENAI_HEADERS.session_id)
    end

    headers["Accept"] = "text/event-stream"
    headers["Content-Type"] = "application/json"
    return headers
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
