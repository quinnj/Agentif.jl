include("durable_test.jl")
include("durable_behavior_test.jl")
include("durable_kernel_test.jl")
include("durable_integration_test.jl")
include("durable_supervision_test.jl")
# These spawn fresh processes and SIGKILL only the fixture processes they own.
get(ENV,"CLAW_SKIP_CRASH_TESTS","false")=="true" || include("durable_crash_test.jl")
