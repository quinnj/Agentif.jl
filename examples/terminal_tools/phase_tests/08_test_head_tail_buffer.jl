using Agentif, LLMTools
using PtySessions

println("="^80)
println("Phase 3 Test: HeadTailBuffer Smart Truncation")
println("="^80)
println()

tools = LLMTools.create_terminal_tools()
agent = Agent(
    prompt = "You are a helpful assistant testing smart output truncation.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

println("Testing HeadTailBuffer preserves start and end of large output...")
println()

result = evaluate(
    agent, """
    Test HeadTailBuffer:
    1. Generate a large output with 500 lines where each line has its number:
       seq 1 500
    2. Use max_output_lines=50 to truncate
    3. Verify you can see:
       - Lines 1-25 (the head)
       - A truncation indicator
       - Lines 476-500 (the tail)
    4. This shows you can see both the beginning and end of large outputs,
       which is useful for debugging when you need to see how a process started
       and how it ended, without all the middle content.

    Also test with write_stdin:
    5. Start a long-running cat process
    6. Send 100 lines to it
    7. Use write_stdin with max_output_lines=30 to poll
    8. Verify head+tail truncation works in write_stdin too
    """
)

println("\n" * "="^80)
println("Test completed!")
println("="^80)
