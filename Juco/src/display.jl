# Terminal display for the Juco REPL: compact tool-call lines, streamed
# reasoning, and per-turn usage. Deliberately plain — no TUI, just careful
# use of ANSI style on a scrolling terminal.

use_color(io::IO) = get(io, :color, false) || (io === stdout && !haskey(ENV, "NO_COLOR") && stdout isa Base.TTY)

dim(io::IO, s) = use_color(io) ? "\e[2m$(s)\e[0m" : String(s)
red(io::IO, s) = use_color(io) ? "\e[31m$(s)\e[0m" : String(s)
green(io::IO, s) = use_color(io) ? "\e[32m$(s)\e[0m" : String(s)
yellow(io::IO, s) = use_color(io) ? "\e[33m$(s)\e[0m" : String(s)
bold(io::IO, s) = use_color(io) ? "\e[1m$(s)\e[22m" : String(s)

# One-line preview of a bash result so the user can scan without expanding:
# the first non-empty line of output.
function result_preview(result::Agentif.ToolResultMessage)
    text = join((b.text for b in result.content if b isa Agentif.TextContent), "\n")
    for line in eachsplit(text, '\n')
        s = strip(line)
        isempty(s) && continue
        startswith(s, "…[skipped") && continue
        p = String(s)
        length(p) > 80 && (p = first(p, 80) * "…")
        return p
    end
    return ""
end

# Compact ±diff for an edit call (from its arguments), aider-style.
function edit_diff_lines(arguments::AbstractString; max_each::Int = 3)
    args = try
        JSON.parse(String(arguments))
    catch
        return String[], String[]
    end
    args isa AbstractDict || return String[], String[]
    old = get(args, "oldText", "")
    new = get(args, "newText", "")
    (old isa AbstractString && new isa AbstractString) || return String[], String[]
    olds = [String(l) for l in eachsplit(old, '\n') if !isempty(strip(l))]
    news = [String(l) for l in eachsplit(new, '\n') if !isempty(strip(l))]
    # drop common prefix/suffix lines so the diff shows only what changed
    while !isempty(olds) && !isempty(news) && olds[1] == news[1]
        popfirst!(olds); popfirst!(news)
    end
    while !isempty(olds) && !isempty(news) && olds[end] == news[end]
        pop!(olds); pop!(news)
    end
    clip(v) = length(v) > max_each ? vcat(first(v, max_each), ["…"]) : v
    return clip(olds), clip(news)
end

# One-line summary of a tool call, e.g.:
#   ▸ bash julia test_stats.jl
#   ▸ edit src/stats.jl
#   ▸ read src/stats.jl:100
function format_tool_call(name::AbstractString, arguments::AbstractString)
    args = try
        JSON.parse(String(arguments))
    catch
        nothing
    end
    detail = if args isa AbstractDict
        if name == "bash"
            replace(string(get(args, "command", "")), r"\s+" => " ")
        elseif name == "read"
            path = string(get(args, "path", ""))
            offset = get(args, "offset", nothing)
            offset === nothing ? path : "$(path):$(offset)"
        elseif name == "edit"
            path = string(get(args, "path", ""))
            old_text = get(args, "oldText", " ")
            old_text isa AbstractString && isempty(old_text) ? "$(path) (new file)" : path
        elseif name == "write"
            string(get(args, "path", ""))
        elseif name == "remember"
            "\"" * string(get(args, "content", "")) * "\""
        else
            join((string(v) for v in values(args)), " ")
        end
    else
        String(arguments)
    end
    detail = replace(detail, '\n' => "\\n")
    length(detail) > 100 && (detail = first(detail, 100) * "…")
    return "▸ $(name) $(detail)"
end

format_duration(ms::Integer) = ms < 1000 ? "$(ms)ms" : "$(round(ms / 1000; digits = 1))s"

# First line of an error result, for the ✗ status.
function error_summary(result::Agentif.ToolResultMessage)
    text = join((b.text for b in result.content if b isa Agentif.TextContent), " ")
    msg = try
        parsed = JSON.parse(text)
        parsed isa AbstractDict ? string(get(parsed, "message", text)) : text
    catch
        text
    end
    line = first(split(msg, '\n'))
    length(line) > 120 && (line = first(line, 120) * "…")
    return String(line)
end

format_tokens(n::Integer) = n < 1000 ? string(n) : "$(round(n / 1000; digits = 1))k"

# One dim line after a turn: elapsed, tool calls, tokens (with cache share),
# cost, and estimated context-window usage.
function usage_line(usage::Agentif.Usage, model, tool_calls::Int, elapsed_s::Real;
        ctx_pct::Union{Nothing, Int} = nothing)
    tokens_in = usage.input + usage.cacheRead + usage.cacheWrite
    cached = tokens_in > 0 && usage.cacheRead > 0 ? " ($(round(Int, 100 * usage.cacheRead / tokens_in))% cached)" : ""
    cost = try
        c = LLMProviders.calculateCost(model, usage)
        total = get(c, "total", 0.0)
        total > 0 ? " · \$$(round(total; sigdigits = 2))" : ""
    catch
        ""
    end
    tools = tool_calls > 0 ? " · $(tool_calls) tool$(tool_calls == 1 ? "" : "s")" : ""
    ctx = ctx_pct === nothing ? "" :
        " · ctx $(ctx_pct)%" * (ctx_pct >= 80 ? " (compaction soon)" : "")
    return "⏱ $(round(elapsed_s; digits = 1))s$(tools) · $(format_tokens(tokens_in)) in$(cached) / $(format_tokens(usage.output)) out$(cost)$(ctx)"
end

# Steering visuals: a message is shown queued the moment the user presses
# enter, then again — promoted — at the moment a completed tool call actually
# delivers it to the model (codex-style).
steer_preview(text) = (t = replace(String(text), '\n' => " "); length(t) > 60 ? first(t, 60) * "…" : t)
steer_queued_line(io::IO, text) = dim(io, "↳ queued (steers at next tool boundary): \"$(steer_preview(text))\"")
steer_active_line(io::IO, text) =
    (use_color(io) ? "\e[36m" : "") * "↳ steering now: \"$(steer_preview(text))\"" * (use_color(io) ? "\e[0m" : "")

"""
    display_handler(io; show_tools = true, show_reasoning = true) -> Function

Event handler that renders agent activity to `io`: tool calls as compact
one-liners completed in place with ✓/✗ + duration, and (optionally) streamed
reasoning as dim text.
"""
function display_handler(io::IO; show_tools::Bool = true, show_reasoning::Bool = true,
        show_previews::Bool = true, io_lock::ReentrantLock = ReentrantLock())
    open_call_id = Ref{Union{Nothing, String}}(nothing)  # call whose ▸ line is still open
    reasoning_open = Ref(false)
    waiting_open = Ref(false)  # "…" placeholder shown while the model is silent
    finish_open_line() = begin
        open_call_id[] === nothing || print(io, "\n")
        open_call_id[] = nothing
    end
    finish_reasoning() = begin
        reasoning_open[] && print(io, "\n\n")
        reasoning_open[] = false
    end
    clear_waiting() = begin
        # erase the placeholder line so real output takes its place
        waiting_open[] && use_color(io) && print(io, "\e[2K\r")
        waiting_open[] = false
    end
    return function (event)
        lock(io_lock) do
            if event isa Agentif.TurnStartEvent && use_color(io)
                # a blank gap before the first token reads as frozen — show a
                # placeholder that the first real output erases
                if !waiting_open[] && open_call_id[] === nothing && !reasoning_open[]
                    print(io, dim(io, "… thinking"))
                    waiting_open[] = true
                    flush(io)
                end
            elseif event isa Agentif.ToolExecutionStartEvent && show_tools
                clear_waiting()
                finish_reasoning()
                finish_open_line()
                print(io, dim(io, format_tool_call(event.tool_call.name, event.tool_call.arguments)))
                open_call_id[] = event.tool_call.call_id
                flush(io)
            elseif event isa Agentif.ToolExecutionEndEvent && show_tools
                clear_waiting()
                status = event.result.is_error ?
                    red(io, "✗ " * error_summary(event.result)) :
                    dim(io, "✓ " * format_duration(event.duration_ms))
                if open_call_id[] == event.tool_call.call_id
                    # complete the line we just opened
                    println(io, dim(io, " "), status)
                    open_call_id[] = nothing
                else
                    finish_open_line()
                    println(io, dim(io, "  " * event.tool_call.name * " "), status)
                end
                if show_previews && !event.result.is_error
                    if event.tool_call.name == "bash"
                        preview = result_preview(event.result)
                        isempty(preview) || println(io, dim(io, "  ⋮ " * preview))
                    elseif event.tool_call.name == "edit"
                        removed, added = edit_diff_lines(event.tool_call.arguments)
                        for l in removed
                            println(io, red(io, "  - " * first(l, 80)))
                        end
                        for l in added
                            println(io, green(io, "  + " * first(l, 80)))
                        end
                    end
                end
                flush(io)
            elseif event isa Agentif.MessageUpdateEvent && event.kind == :reasoning && show_reasoning
                clear_waiting()
                finish_open_line()
                reasoning_open[] || print(io, dim(io, "· "))
                reasoning_open[] = true
                print(io, dim(io, replace(event.delta, "\n\n" => "\n", '\n' => "\n  ")))
                flush(io)
            elseif event isa Agentif.MessageUpdateEvent && event.kind == :text
                # text is buffered by the channel and rendered at message end;
                # close any open reasoning/tool line before that happens
                clear_waiting()
                finish_reasoning()
                finish_open_line()
            elseif event isa Agentif.MessageEndEvent && event.message isa Agentif.CompactionSummaryMessage
                clear_waiting()
                finish_reasoning()
                finish_open_line()
                println(io, dim(io, "⇣ context compacted — earlier conversation folded into a summary"))
            elseif event isa Agentif.TurnEndEvent
                clear_waiting()
                finish_reasoning()
                finish_open_line()
            elseif event isa Agentif.AgentErrorEvent
                clear_waiting()
                finish_reasoning()
                finish_open_line()
                msg = first(string(event.error), 200)
                if occursin("SSE stream interrupted", msg)
                    # transient connection drop: the partial message was kept
                    println(io, yellow(io, "⚡ connection dropped mid-response — continuing with what arrived"))
                else
                    println(io, red(io, "error: " * msg))
                end
            end
        end
        return nothing
    end
end
