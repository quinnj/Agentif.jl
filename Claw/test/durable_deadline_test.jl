module DurableDeadlineTests
include("durable_fixtures.jl")

@testset "cancelled overdue workers do not spin the scheduler" begin
    mktempdir() do dir
        h, _, _ = durable_fixture(joinpath(dir, "deadline.sqlite"))
        abort = Agentif.Abort()
        try
            h.supervision_due = Claw._monotonic_s() + 60
            h.live["overdue"] = (; context = (; abort, monotonic_deadline = Claw._monotonic_s() - 1), group = :tool)
            @test Claw._next_wakeup_s(h) == 0
            Agentif.abort!(abort)
            @test 0 < Claw._next_wakeup_s(h) <= 1
            @test haskey(h.live, "overdue")
        finally
            empty!(h.live)
            Claw.close_harness!(h)
        end
    end
end
end
