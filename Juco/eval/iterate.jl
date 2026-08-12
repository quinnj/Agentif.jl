# Iteration driver: runs the full task suite on the :juco preset with the
# pinned DeepSeek eval model and writes transcripts for close analysis.
#
#   julia --project=. Juco/eval/iterate.jl <label> [task ...]
#
# Transcripts + a results summary land in <transcript_root>/<label>/.
using Dates

include(joinpath(@__DIR__, "env.jl"))
load_eval_env!()
include(joinpath(@__DIR__, "run.jl"))

function iterate_main(args)
    isempty(args) && error("usage: iterate.jl <label> [task ...]")
    label = args[1]
    root = get(ENV, "JUCO_EVAL_DIR", joinpath(tempdir(), "juco-evals"))
    transcript_dir = joinpath(root, label)
    mkpath(transcript_dir)
    tasks = length(args) > 1 ? filter(t -> t.name in args[2:end], TASKS) : TASKS
    results = run_eval(; presets = [:juco], tasks, transcript_dir)
    open(joinpath(transcript_dir, "results.txt"), "w") do io
        for r in results
            println(io, r.task, " ", r.passed ? "PASS" : "FAIL",
                " calls=", r.tool_calls, " in=", r.tokens_in, " out=", r.tokens_out,
                " cached=", get(r, :tokens_cached, 0),
                " s=", r.seconds, r.aborted ? " ABORTED" : "")
        end
    end
    println("transcripts: ", transcript_dir)
    record_history(label, results)
    return results
end

# Append this run's aggregates to eval/HISTORY.md so the iteration record
# lives in the repo, not in ephemeral terminal scrollback.
function record_history(label::AbstractString, results)
    passed = count(r -> r.passed, results)
    calls = sum(r -> r.tool_calls, results; init = 0)
    tin = sum(r -> r.tokens_in, results; init = 0)
    tout = sum(r -> r.tokens_out, results; init = 0)
    cached = sum(r -> get(r, :tokens_cached, 0), results; init = 0)
    secs = round(sum(r -> r.seconds, results; init = 0.0); digits = 1)
    path = joinpath(@__DIR__, "HISTORY.md")
    fresh = !isfile(path)
    open(path, "a") do io
        fresh && println(io, "# Eval run history\n\n| when | label | pass | calls | tokens in (cached) | tokens out | s |\n|---|---|---|---|---|---|---|")
        ts = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM")
        println(io, "| $(ts) | $(label) | $(passed)/$(length(results)) | $(calls) | $(round(Int, tin / 1000))k ($(round(Int, cached / 1000))k) | $(round(Int, tout / 1000))k | $(secs) |")
    end
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    iterate_main(ARGS)
end
