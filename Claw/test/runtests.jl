using Test

include("smoke_test.jl")
include("db_tools_test.jl")
include("pipeline_test.jl")
include("filters_test.jl")
include("relevance_test.jl")
include("batch_window_test.jl")
include("integrations_test.jl")
include("trust_test.jl")
include("msteams_auth_test.jl")
include("extensions_test.jl")
include("pty_output_test.jl")
include("watcher_test.jl")
if Sys.iswindows()
    # Durable ownership requires POSIX flock; legacy tests still run on Windows.
    @test_skip "POSIX durable ownership and owned-process SIGKILL recovery"
else
    include("durable_all_test.jl")
end
