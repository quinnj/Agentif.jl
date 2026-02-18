# session_utils.jl — Generic session management infrastructure
# Shared by terminal tools (PTY) and worker tools (ConcurrentUtilities.Workers)

# --- Status constants ---
const SESSION_STATUS_RUNNING = "RUNNING"
const SESSION_STATUS_EXITED  = "EXITED"
const SESSION_STATUS_UNKNOWN = "UNKNOWN"
const SESSION_STATUS_KILLED  = "KILLED"
const SESSION_STATUS_ERROR   = "ERROR"
const SESSION_STATUS_OK      = "OK"

# --- Output projection types ---

struct HeadTailBuffer
    head::Vector{String}
    tail::Vector{String}
    head_lines::Int
    tail_lines::Int
    total_lines::Int
    truncated::Bool
end

struct OutputProjection
    output::String
    raw_output::String
    truncated::Bool
    line_truncated::Bool
    byte_truncated::Bool
    token_truncated::Bool
    original_line_count::Int
    original_byte_count::Int
    original_token_count_est::Int
    output_line_count::Int
    output_token_count_est::Int
end

# --- Output limit constants ---
const DEFAULT_MAX_OUTPUT_LINES = 1000
const DEFAULT_MAX_OUTPUT_TOKENS = 10_000
const TRANSCRIPT_MAX_BYTES = 1024 * 1024
const EVENT_DELTA_MAX_BYTES = 8 * 1024
const RESPONSE_SCHEMA_VERSION = 1

# --- Output utility functions ---

approx_token_count(text::String) = isempty(text) ? 0 : cld(ncodeunits(text), 4)
line_count(text::String) = length(split(text, '\n'; keepempty = true))

function create_head_tail_buffer(text::String, max_lines::Int = DEFAULT_MAX_OUTPUT_LINES)
    lines = split(text, '\n'; keepempty = true)
    total = length(lines)

    if total <= max_lines
        return HeadTailBuffer(collect(lines), String[], total, 0, total, false)
    end

    head_count = div(max_lines, 2)
    tail_count = max_lines - head_count
    return HeadTailBuffer(
        collect(lines[1:head_count]),
        collect(lines[(end - tail_count + 1):end]),
        head_count,
        tail_count,
        total,
        true,
    )
end

function format_head_tail_buffer(buffer::HeadTailBuffer)::String
    if !buffer.truncated
        return join(buffer.head, '\n')
    end

    parts = String[]
    push!(parts, join(buffer.head, '\n'))
    push!(parts, "\n... [truncated $(buffer.total_lines - buffer.head_lines - buffer.tail_lines) lines] ...\n")
    push!(parts, join(buffer.tail, '\n'))
    return join(parts, "")
end

function truncate_text_head_tail_bytes(text::String, max_bytes::Int)
    ncodeunits(text) <= max_bytes && return (text = text, truncated = false)
    chars = collect(text)
    isempty(chars) && return (text = "", truncated = true)

    head_budget = div(max_bytes, 2)
    tail_budget = max_bytes - head_budget

    head = Char[]
    used = 0
    for c in chars
        cbytes = ncodeunits(string(c))
        used + cbytes > head_budget && break
        push!(head, c)
        used += cbytes
    end

    tail = Char[]
    used = 0
    for c in reverse(chars)
        cbytes = ncodeunits(string(c))
        used + cbytes > tail_budget && break
        pushfirst!(tail, c)
        used += cbytes
    end

    marker = "\n... [truncated bytes] ...\n"
    return (text = string(String(head), marker, String(tail)), truncated = true)
end

function truncate_text_head_tail_tokens(text::String, max_tokens::Int)
    max_tokens <= 0 && return (text = "", truncated = !isempty(text))
    approx_token_count(text) <= max_tokens && return (text = text, truncated = false)
    return truncate_text_head_tail_bytes(text, max_tokens * 4)
end

function chunk_text_by_bytes(text::String, max_bytes::Int)
    isempty(text) && return String[]
    max_bytes <= 0 && return [text]

    chunks = String[]
    io = IOBuffer()
    used = 0
    for c in text
        cstr = string(c)
        cbytes = ncodeunits(cstr)
        if used > 0 && used + cbytes > max_bytes
            push!(chunks, String(take!(io)))
            used = 0
        end
        print(io, cstr)
        used += cbytes
    end
    used > 0 && push!(chunks, String(take!(io)))
    return chunks
end

function project_output(raw_output::String, max_lines::Int, max_output_tokens::Int)
    original_lines = line_count(raw_output)
    original_bytes = ncodeunits(raw_output)
    original_tokens = approx_token_count(raw_output)

    byte_projection = truncate_text_head_tail_bytes(raw_output, TRANSCRIPT_MAX_BYTES)
    stored_raw = byte_projection.text

    line_truncated = false
    output_after_lines = stored_raw
    if max_lines < 1_000_000
        buffer = create_head_tail_buffer(stored_raw, max_lines)
        line_truncated = buffer.truncated
        output_after_lines = format_head_tail_buffer(buffer)
    end

    token_projection = truncate_text_head_tail_tokens(output_after_lines, max_output_tokens)
    output_final = token_projection.text
    token_truncated = token_projection.truncated

    return OutputProjection(
        output_final,
        stored_raw,
        byte_projection.truncated || line_truncated || token_truncated,
        line_truncated,
        byte_projection.truncated,
        token_truncated,
        original_lines,
        original_bytes,
        original_tokens,
        line_count(output_final),
        approx_token_count(output_final),
    )
end

# --- Session registry ---

struct SessionRegistryConfig
    max_sessions::Int
    warning_threshold::Int
    cleanup_interval_s::Float64
    schema_version::Int
end

mutable struct SessionRegistry{M}
    const sessions::Dict{Int, M}
    const lock::ReentrantLock
    next_session_id::Int
    next_event_id::Int
    cleanup_task::Union{Nothing, Task}
    cleanup_stop::Bool
    const config::SessionRegistryConfig
end

function SessionRegistry{M}(config::SessionRegistryConfig) where {M}
    return SessionRegistry{M}(
        Dict{Int, M}(), ReentrantLock(), 1, 1,
        nothing, false, config,
    )
end

# --- Required interface for metadata type M ---
# Concrete types must implement:
#   resolve_status(meta::M)::String
#   close_quietly(meta::M)::Nothing
#   session_command(meta::M)::String
#   session_workdir(meta::M)::String
#   session_created_at(meta::M)::Float64
#   session_last_used(meta::M)::Float64
#   set_last_used!(meta::M, t::Float64)
#   set_status!(meta::M, s::String)

# --- Registry operations ---

function active_session_count(reg::SessionRegistry)
    return lock(reg.lock) do
        length(reg.sessions)
    end
end

function next_session_id!(reg::SessionRegistry)
    return lock(reg.lock) do
        id = reg.next_session_id
        reg.next_session_id += 1
        id
    end
end

function register_session!(reg::SessionRegistry{M}, id::Int, meta::M) where {M}
    lock(reg.lock) do
        reg.sessions[id] = meta
    end
    return nothing
end

function get_session(reg::SessionRegistry, id::Int)
    return lock(reg.lock) do
        get(() -> nothing, reg.sessions, id)
    end
end

function remove_session!(reg::SessionRegistry, id::Int; mark_status::Union{Nothing, String} = nothing, close_session::Bool = true)
    meta = lock(reg.lock) do
        pop!(reg.sessions, id, nothing)
    end
    meta === nothing && return nothing
    mark_status === nothing || set_status!(meta, mark_status)
    close_session && close_quietly(meta)
    return meta
end

function cleanup_exited_sessions!(reg::SessionRegistry)
    to_remove = lock(reg.lock) do
        ids = Int[]
        for (id, meta) in reg.sessions
            status = resolve_status(meta)
            status == SESSION_STATUS_RUNNING && continue
            push!(ids, id)
        end
        ids
    end
    for id in to_remove
        remove_session!(reg, id; close_session = true)
    end
    return length(to_remove)
end

function ensure_cleanup_task_running!(reg::SessionRegistry)
    lock(reg.lock) do
        existing = reg.cleanup_task
        if existing !== nothing && !istaskdone(existing)
            return nothing
        end
        reg.cleanup_stop = false
        reg.cleanup_task = @async begin
            while !reg.cleanup_stop
                sleep(reg.config.cleanup_interval_s)
                reg.cleanup_stop && break
                try
                    cleanup_exited_sessions!(reg)
                catch err
                    @warn "Session cleanup sweep failed" error = err
                end
            end
        end
    end
    return nothing
end

function prune_oldest_session!(reg::SessionRegistry)
    config = reg.config
    prune_id = lock(reg.lock) do
        length(reg.sessions) < config.max_sessions && return nothing

        sorted = sort(collect(reg.sessions), by = p -> session_last_used(p[2]), rev = true)
        protected = Set(p[1] for p in sorted[1:min(8, length(sorted))])

        for (id, meta) in sorted
            status = resolve_status(meta)
            if id ∉ protected && status != SESSION_STATUS_RUNNING
                return id
            end
        end

        for (id, _) in reverse(sorted)
            id ∉ protected && return id
        end
        return nothing
    end

    prune_id === nothing && return false
    removed = remove_session!(reg, prune_id; close_session = true)
    removed === nothing && return false
    @warn "Pruned session $prune_id (command: $(session_command(removed)))"
    return true
end

function check_session_limit_and_warn(reg::SessionRegistry)
    config = reg.config
    n_sessions = active_session_count(reg)
    if n_sessions >= config.warning_threshold
        @warn """
        You currently have $n_sessions sessions open.
        The maximum is $(config.max_sessions).
        Consider reusing existing sessions or closing unused ones to prevent automatic pruning.
        """
    end
    if n_sessions >= config.max_sessions
        @warn "Maximum sessions reached ($(config.max_sessions)). Pruning oldest session..."
        return prune_oldest_session!(reg)
    end
    return false
end

function reset_sessions_for_tests!(reg::SessionRegistry)
    ids = lock(reg.lock) do
        collect(keys(reg.sessions))
    end
    for id in ids
        remove_session!(reg, id; mark_status = SESSION_STATUS_KILLED, close_session = true)
    end
    lock(reg.lock) do
        empty!(reg.sessions)
        reg.next_session_id = 1
        reg.next_event_id = 1
    end
    return nothing
end

# --- Event system ---

function next_event_id!(reg::SessionRegistry)
    return lock(reg.lock) do
        id = reg.next_event_id
        reg.next_event_id += 1
        id
    end
end

function make_event(reg::SessionRegistry, kind::String; session_id::Union{Nothing, Int} = nothing, payload = Dict{String, Any}())
    event = Dict{String, Any}(
        "id" => next_event_id!(reg),
        "kind" => kind,
        "timestamp" => time(),
    )
    session_id === nothing || (event["session_id"] = session_id)
    for (k, v) in pairs(payload)
        event[string(k)] = v
    end
    return event
end

function project_output_events!(reg::SessionRegistry, events::Vector{Dict{String, Any}}, session_id::Int, output::String)
    chunks = chunk_text_by_bytes(output, EVENT_DELTA_MAX_BYTES)
    for chunk in chunks
        push!(events, make_event(
            reg,
            "output_delta";
            session_id,
            payload = Dict(
                "delta" => chunk,
                "token_count_est" => approx_token_count(chunk),
            ),
        ))
    end
    return nothing
end

# --- Response rendering ---

function build_process_summary(
    status::String,
    wall_time_s::Float64,
    session_id::Union{Nothing, Int},
    active_sessions::Int,
    output::String,
)
    lines = String[]
    push!(lines, "Wall time: $(round(wall_time_s, digits = 4)) seconds")
    push!(lines, "Status: $status")
    if session_id !== nothing && status == SESSION_STATUS_RUNNING
        push!(lines, "Session ID: $session_id")
    end
    push!(lines, "Active sessions: $active_sessions")
    push!(lines, "Output:")
    push!(lines, isempty(output) ? "(no output)" : output)
    return join(lines, "\n")
end

function render_process_response(
    tool::String;
    ok::Bool = true,
    status::String = SESSION_STATUS_OK,
    session_id::Union{Nothing, Int} = nothing,
    command::Union{Nothing, String} = nothing,
    workdir::Union{Nothing, String} = nothing,
    wall_time_s::Float64 = 0.0,
    output_projection::OutputProjection = OutputProjection("", "", false, false, false, false, 0, 0, 0, 0, 0),
    active_sessions::Int = 0,
    exit_code::Union{Nothing, Int} = nothing,
    events::Vector{Dict{String, Any}} = Dict{String, Any}[],
    error_kind::Union{Nothing, String} = nothing,
    message::Union{Nothing, String} = nothing,
    extra::Dict{String, Any} = Dict{String, Any}(),
)
    payload = Dict{String, Any}(
        "schema_version" => RESPONSE_SCHEMA_VERSION,
        "tool" => tool,
        "ok" => ok,
        "status" => status,
        "session_id" => session_id,
        "command" => command,
        "workdir" => workdir,
        "wall_time_s" => wall_time_s,
        "active_sessions" => active_sessions,
        "output" => output_projection.output,
        "raw_output" => output_projection.raw_output,
        "truncated" => output_projection.truncated,
        "line_truncated" => output_projection.line_truncated,
        "byte_truncated" => output_projection.byte_truncated,
        "token_truncated" => output_projection.token_truncated,
        "original_line_count" => output_projection.original_line_count,
        "original_byte_count" => output_projection.original_byte_count,
        "original_token_count_est" => output_projection.original_token_count_est,
        "output_line_count" => output_projection.output_line_count,
        "output_token_count_est" => output_projection.output_token_count_est,
        "exit_code" => exit_code,
        "events" => events,
        "error_kind" => error_kind,
        "message" => message,
        "summary" => build_process_summary(status, wall_time_s, session_id, active_sessions, output_projection.output),
    )
    for (k, v) in pairs(extra)
        payload[string(k)] = v
    end
    return JSON.json(payload)
end
