using Test, LLMTools

@testset "LLMTools.jl" begin
    include("test_utils.jl")
    include("file_tools_test.jl")
    include("session_utils_test.jl")
    include("subprocess_env_test.jl")
    include("terminal_tools_test.jl")
    include("egress_test.jl")
    include("web_tools_test.jl")
    include("optional_args_test.jl")
    include("hostile_output_test.jl")
    include("worker_tools_test.jl")
    include("mcp_test.jl")
end
