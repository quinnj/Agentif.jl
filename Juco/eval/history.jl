using Dates

function validate_eval_label(label::AbstractString)
    value = String(label)
    occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", value) ||
        throw(ArgumentError("eval label must use only letters, digits, '.', '_', or '-'"))
    return value
end

# Append this run's aggregates to eval/HISTORY.md so the iteration record
# lives in the repo, not in ephemeral terminal scrollback.
function record_history(label::AbstractString, results;
        path::AbstractString = joinpath(@__DIR__, "HISTORY.md"))
    label = validate_eval_label(label)
    passed = count(r -> r.passed, results)
    calls = sum(r -> r.tool_calls, results; init = 0)
    tin = sum(r -> r.tokens_in, results; init = 0)
    tout = sum(r -> r.tokens_out, results; init = 0)
    cached = sum(r -> get(r, :tokens_cached, 0), results; init = 0)
    secs = round(sum(r -> r.seconds, results; init = 0.0); digits = 1)
    fresh = !isfile(path)
    open(path, "a") do io
        fresh && println(io, "# Eval run history\n\n| when | label | pass | calls | tokens in (cached) | tokens out | s |\n|---|---|---|---|---|---|---|")
        ts = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM")
        println(io, "| $(ts) | $(label) | $(passed)/$(length(results)) | $(calls) | $(round(Int, tin / 1000))k ($(round(Int, cached / 1000))k) | $(round(Int, tout / 1000))k | $(secs) |")
    end
    return nothing
end
