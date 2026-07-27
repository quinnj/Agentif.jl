const _LOG_LEVEL_ALIASES = Dict{String, LogLevel}(
    "DEBUG" => Debug,
    "INFO" => Info,
    "WARN" => Warn,
    "WARNING" => Warn,
    "ERROR" => Error,
)

function resolve_log_level(level::Union{Nothing, LogLevel, Int, Symbol, AbstractString} = nothing)
    level === nothing && return nothing
    level isa LogLevel && return level
    level isa Int && return LogLevel(level)
    key = uppercase(level isa Symbol ? String(level) : strip(String(level)))
    parsed = get(() -> nothing, _LOG_LEVEL_ALIASES, key)
    parsed === nothing && throw(ArgumentError("Invalid log level: $(level). Expected one of DEBUG, INFO, WARN, ERROR."))
    return parsed
end

function with_log_level(f::F, level::Union{Nothing, LogLevel, Int, Symbol, AbstractString} = nothing) where {F <: Function}
    resolved = resolve_log_level(level)
    resolved === nothing && return f()
    return LoggingExtras.withlevel(f, resolved)
end

function debug_logging_enabled()
    return Logging.min_enabled_level(Logging.current_logger()) <= Debug
end

function _format_stacktrace(bt; max_chars::Int = 16_000)
    bt === nothing && return nothing
    io = IOBuffer()
    try
        Base.show_backtrace(io, bt)
    catch
        show(io, bt)
    end
    stack = String(take!(io))
    length(stack) <= max_chars && return stack
    return stack[1:max_chars] * "\n... [stacktrace truncated]"
end

function render_tool_error_json(
        ;
        error_kind::String,
        message::String,
        tool::Union{Nothing, String} = nothing,
        call_id::Union{Nothing, String} = nothing,
        exception::Union{Nothing, Exception} = nothing,
        backtrace = nothing,
        suggested_fix::Union{Nothing, String} = nothing,
        raw_arguments::Union{Nothing, String} = nothing,
        extra = Dict{String, Any}(),
    )
    if TRIMMED_BUILD
        return JSON.json((
            ok = false,
            error_kind,
            message,
            tool,
            call_id,
            suggested_fix,
            raw_arguments,
        ))
    end
    payload = JSON.Object(
        "ok" => false,
        "error_kind" => error_kind,
        "message" => message,
    )
    tool === nothing || (payload["tool"] = tool)
    call_id === nothing || (payload["call_id"] = call_id)
    exception === nothing || (payload["exception_type"] = string(typeof(exception)))
    suggested_fix === nothing || (payload["suggested_fix"] = suggested_fix)
    raw_arguments === nothing || (payload["raw_arguments"] = raw_arguments)
    if debug_logging_enabled()
        stack = _format_stacktrace(backtrace)
        stack === nothing || (payload["stacktrace"] = stack)
    end
    for (k, v) in pairs(extra)
        payload[string(k)] = v
    end
    return JSON.json(payload)
end

function provider_tool_result_output(result::ToolResultMessage)
    output = message_text(result)
    result.is_error || return output
    parsed_output = try
        JSON.parse(output)
    catch
        nothing
    end
    wrapped = JSON.Object(
        "ok" => false,
        "tool_error" => true,
        "tool" => result.name,
        "call_id" => result.call_id,
    )
    if parsed_output === nothing
        wrapped["message"] = output
    else
        wrapped["error"] = parsed_output
        wrapped["message"] = string(get(() -> output, parsed_output, "message"))
    end
    return JSON.json(wrapped)
end
