#!/usr/bin/env julia
"""
Unit tests for new terminal_tools features.
These tests don't require AI agents - they test the implementation directly.
"""

using LLMTools
using PtySessions
using Test

println("="^80)
println("Unit Tests for terminal_tools Enhancements")
println("="^80)
println()

@testset "HeadTailBuffer Tests" begin
    # Test no truncation for small output
    small_text = join(["Line $i" for i in 1:10], "\n")
    buffer = LLMTools.create_head_tail_buffer(small_text, 20)
    @test buffer.truncated == false
    @test buffer.total_lines == 10
    formatted = LLMTools.format_head_tail_buffer(buffer)
    @test occursin("Line 1", formatted)
    @test occursin("Line 10", formatted)
    @test !occursin("truncated", formatted)
    println("✅ Small output - no truncation")

    # Test truncation for large output
    large_text = join(["Line $i" for i in 1:100], "\n")
    buffer = LLMTools.create_head_tail_buffer(large_text, 20)
    @test buffer.truncated == true
    @test buffer.total_lines == 100
    @test buffer.head_lines == 10
    @test buffer.tail_lines == 10
    formatted = LLMTools.format_head_tail_buffer(buffer)
    @test occursin("Line 1", formatted)  # Head present
    @test occursin("Line 100", formatted)  # Tail present
    @test occursin("truncated", formatted)  # Truncation message
    @test !occursin("Line 50", formatted)  # Middle missing
    println("✅ Large output - truncation with head + tail")

    # Test exact boundary
    exact_text = join(["Line $i" for i in 1:20], "\n")
    buffer = LLMTools.create_head_tail_buffer(exact_text, 20)
    @test buffer.truncated == false
    println("✅ Exact boundary - no truncation")

    # Test single line
    single = "Single line"
    buffer = LLMTools.create_head_tail_buffer(single, 10)
    @test buffer.truncated == false
    @test buffer.total_lines == 1
    println("✅ Single line - no truncation")
end

@testset "Session Metadata Tests" begin
    # Test metadata struct creation
    now = time()
    cmd = "sleep 10"
    workdir = "/tmp"

    # Create mock session (we won't actually use it)
    meta = LLMTools.PtySessionMetadata(nothing, now, now, cmd, workdir, LLMTools.SESSION_STATUS_RUNNING, nothing)

    @test meta.created_at == now
    @test meta.last_used == now
    @test meta.command == cmd
    @test meta.workdir == workdir
    println("✅ PtySessionMetadata struct works")

    # Test metadata update
    later = now + 5.0
    meta2 = LLMTools.PtySessionMetadata(nothing, now, later, cmd, workdir, LLMTools.SESSION_STATUS_RUNNING, nothing)
    @test meta2.created_at == now
    @test meta2.last_used == later
    @test meta2.last_used > meta2.created_at
    println("✅ Metadata timestamps update correctly")
end

@testset "Session Constants" begin
    @test LLMTools.PTY_REGISTRY.config.max_sessions == 20
    @test LLMTools.PTY_REGISTRY.config.warning_threshold == 15
    @test LLMTools.PTY_REGISTRY.config.warning_threshold < LLMTools.PTY_REGISTRY.config.max_sessions
    println("✅ Session limits configured correctly")
end

println()
println("="^80)
println("All unit tests passed!")
println("="^80)
println()
println("Summary:")
println("  ✅ HeadTailBuffer: truncation works correctly")
println("  ✅ PtySessionMetadata: tracking works correctly")
println("  ✅ Session limits: constants configured correctly")
println()
println("Next: Run integration tests with AI agents to verify full functionality")
