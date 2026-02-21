using Test, LLMTools

@testset "LLMTools.jl" begin
    include("test_utils.jl")
    include("codex_tool_test.jl")
    include("file_tools_test.jl")
    include("qmd_tools_test.jl")
    include("session_utils_test.jl")
    include("terminal_tools_test.jl")
    include("web_tools_test.jl")
    include("worker_tools_test.jl")
end
