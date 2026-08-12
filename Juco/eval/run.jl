# Juco eval runner: measures toolset presets against the tasks in tasks.jl.
#
# Usage (from the monorepo root):
#   julia --project=. Juco/eval/run.jl                       # all presets, all tasks
#   julia --project=. Juco/eval/run.jl --preset juco         # one preset
#   julia --project=. Juco/eval/run.jl --task fix-bug -v     # one task, verbose
#
# Model selection: JUCO_PROVIDER / JUCO_MODEL / JUCO_API_KEY (or provider key env).
#
# Each run gets a fresh temp working directory and a fresh temp sqlite db, so
# runs are independent (no memory/session bleed between tasks).

using Juco
using Agentif

include(joinpath(@__DIR__, "tasks.jl"))

# Transcript writer: records assistant reasoning/text/tool calls and tool
# results to a plain-text file so eval runs can be analyzed closely.
# Tool events fire from concurrent tasks, so writes are serialized by a lock.
function transcript_recorder(io::IO)
    lk = ReentrantLock()
    return function (event)
        lock(lk) do
            _record_event(io, event)
        end
    end
end

function _record_event(io::IO, event)
        if event isa Agentif.MessageEndEvent && event.message isa Agentif.AssistantMessage
            for block in event.message.content
                if block isa Agentif.ThinkingContent && !isempty(block.thinking)
                    println(io, "--- reasoning ---\n", block.thinking)
                elseif block isa Agentif.TextContent && !isempty(block.text)
                    println(io, "--- assistant ---\n", block.text)
                end
            end
        elseif event isa Agentif.ToolExecutionStartEvent
            println(io, "--- tool call: ", event.tool_call.name, " ---\n", event.tool_call.arguments)
        elseif event isa Agentif.ToolExecutionEndEvent
            text = join((b.text for b in event.result.content if b isa Agentif.TextContent), "\n")
            length(text) > 3000 && (text = first(text, 3000) * "\n...[transcript-truncated]")
            println(io, "--- tool result", event.result.is_error ? " (ERROR)" : "",
                " (", event.duration_ms, "ms) ---\n", text)
    elseif event isa Agentif.AgentErrorEvent
        println(io, "--- agent error ---\n", event.error)
    end
    flush(io)
    return nothing
end

function run_one(task, preset::Symbol; verbose::Bool = false, max_turns::Int = 25,
        transcript_dir::Union{Nothing, String} = nothing, kw...)
    mktempdir() do dir
        task.setup(dir)
        io = verbose ? stdout : devnull
        tio = transcript_dir === nothing ? nothing :
            open(joinpath(transcript_dir, "$(preset)-$(task.name).txt"), "w")
        t0 = time()
        result = try
            mktempdir() do db_dir
                Juco.with_jdb(joinpath(db_dir, "eval.sqlite")) do jdb
                    Juco.evaluate(task.prompt;
                        base_dir = dir, jdb, preset, io, show_tools = verbose, max_turns,
                        on_event = tio === nothing ? nothing : transcript_recorder(tio), kw...)
                end
            end
        catch e
            verbose && showerror(stderr, e, catch_backtrace())
            tio === nothing || println(tio, "--- runner exception ---\n", sprint(showerror, e))
            nothing
        finally
            tio === nothing || close(tio)
        end
        elapsed = time() - t0
        passed = try
            task.check(dir)
        catch
            false
        end
        usage = result === nothing ? nothing : result.state.usage
        return (;
            task = task.name, preset, passed,
            tool_calls = result === nothing ? 0 : result.tool_calls,
            aborted = result === nothing ? true : result.aborted,
            tokens_in = usage === nothing ? 0 : usage.input + usage.cacheRead + usage.cacheWrite,
            tokens_out = usage === nothing ? 0 : usage.output,
            tokens_cached = usage === nothing ? 0 : usage.cacheRead,
            seconds = round(elapsed; digits = 1),
        )
    end
end

function run_eval(; presets = [:bash, :juco, :pi], tasks = TASKS, verbose::Bool = false,
        transcript_dir::Union{Nothing, String} = nothing, kw...)
    transcript_dir === nothing || mkpath(transcript_dir)
    results = []
    for preset in presets, task in tasks
        print(stderr, "running $(preset)/$(task.name) ... ")
        r = run_one(task, preset; verbose, transcript_dir, kw...)
        println(stderr, r.passed ? "PASS" : "FAIL", " ($(r.tool_calls) calls, $(r.seconds)s)")
        push!(results, r)
    end
    print_report(results)
    return results
end

function print_report(results)
    println()
    header = rpad("task", 16) * join((rpad(String(p), 20) for p in unique(r.preset for r in results)), "")
    println(header)
    println("-"^length(header))
    presets = unique(r.preset for r in results)
    for task in unique(r.task for r in results)
        row = rpad(task, 16)
        for preset in presets
            i = findfirst(r -> r.task == task && r.preset == preset, results)
            cell = i === nothing ? "-" :
                (results[i].passed ? "pass" : "FAIL") * " $(results[i].tool_calls)c/$(round(Int, (results[i].tokens_in + results[i].tokens_out) / 1000))kt"
            row *= rpad(cell, 20)
        end
        println(row)
    end
    println()
    for preset in presets
        rs = filter(r -> r.preset == preset, results)
        npass = count(r -> r.passed, rs)
        println("$(rpad(String(preset), 8)) $(npass)/$(length(rs)) passed, " *
                "$(sum(r.tool_calls for r in rs)) tool calls, " *
                "$(round(Int, sum(r.tokens_in + r.tokens_out for r in rs) / 1000))k tokens, " *
                "$(round(sum(r.seconds for r in rs); digits = 1))s total")
    end
end

function cli(args::Vector{String})
    presets = [:bash, :juco, :pi]
    tasks = TASKS
    verbose = false
    args = copy(args)
    while !isempty(args)
        a = popfirst!(args)
        if a == "--preset"
            presets = [Symbol(popfirst!(args))]
        elseif a == "--task"
            name = popfirst!(args)
            tasks = filter(t -> t.name == name, TASKS)
            isempty(tasks) && error("unknown task: $name (have: $(join((t.name for t in TASKS), ", ")))")
        elseif a in ("-v", "--verbose")
            verbose = true
        else
            error("unknown flag: $a")
        end
    end
    return run_eval(; presets, tasks, verbose)
end

if abspath(PROGRAM_FILE) == @__FILE__
    cli(ARGS)
end
