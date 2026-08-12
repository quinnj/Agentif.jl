# Validates OPENROUTER_API_KEY and applies the pinned eval model configuration.
function load_eval_env!()
    isempty(get(ENV, "OPENROUTER_API_KEY", "")) &&
        throw(ArgumentError("OPENROUTER_API_KEY must be set to run Juco evals"))
    ENV["JUCO_MODEL_PROVIDER"] = "openrouter"
    ENV["JUCO_MODEL"] = "deepseek/deepseek-v4-flash-0731"
    ENV["JUCO_REASONING"] = "medium"
    # pin the eval to one endpoint: stable routing keeps upstream prompt caches
    # warm and makes cost/latency comparable across runs (fp8 — the fp4
    # endpoint was observed mangling tool calls)
    ENV["JUCO_OPENROUTER_ORDER"] = "siliconflow/fp8"
    return nothing
end
