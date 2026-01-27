using Test

@testset "Agentif.jl" begin
    using Agentif
    @test Agentif isa Module
    include("content_blocks.jl")
end
