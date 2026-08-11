# Iteration driver: runs the full task suite on the :juco preset with the
# pinned DeepSeek eval model and writes transcripts for close analysis.
#
#   julia --project=. Juco/eval/iterate.jl <label> [task ...]
#
# Transcripts + a results summary land in <transcript_root>/<label>/.
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
    return results
end

if abspath(PROGRAM_FILE) == @__FILE__
    iterate_main(ARGS)
end
