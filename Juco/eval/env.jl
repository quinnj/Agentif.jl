# Loads OPENROUTER_API_KEY from ~/league-easy/.env into ENV (if not already set)
# and applies the eval model configuration.
function load_eval_env!()
    if !haskey(ENV, "OPENROUTER_API_KEY")
        envfile = joinpath(homedir(), "league-easy", ".env")
        if isfile(envfile)
            for line in eachline(envfile)
                m = match(r"^\s*(?:export\s+)?OPENROUTER_API_KEY\s*=\s*\"?([^\"\s]+)\"?", line)
                m === nothing && continue
                ENV["OPENROUTER_API_KEY"] = m.captures[1]
                break
            end
        end
    end
    ENV["JUCO_MODEL_PROVIDER"] = "openrouter"
    ENV["JUCO_MODEL"] = "deepseek/deepseek-v4-flash-0731"
    ENV["JUCO_REASONING"] = "medium"
    # pin the eval to one endpoint: stable routing keeps upstream prompt caches
    # warm and makes cost/latency comparable across runs (fp8 — the fp4
    # endpoint was observed mangling tool calls)
    ENV["JUCO_OPENROUTER_ORDER"] = "siliconflow/fp8"
    return nothing
end
