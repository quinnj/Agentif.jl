using Agentif, LLMTools
using PtySessions

println("="^80)
println("Phase 3 Test: max_output_lines Parameter")
println("="^80)
println()

tools = LLMTools.create_terminal_tools()
agent = Agent(
    prompt = "You are a helpful assistant testing output limiting functionality.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

println("Testing max_output_lines parameter limits output size...")
println()

result = evaluate(
    agent, """
    Test max_output_lines:
    1. Run a command that produces 100 lines: for i in {1..100}; do echo "Line \$i"; done
       WITHOUT max_output_lines - verify you see all 100 lines
    2. Run the same command WITH max_output_lines=20
    3. Verify the output shows:
       - First 10 lines
       - A truncation message like "[truncated X lines]"
       - Last 10 lines
    4. This demonstrates the HeadTailBuffer smart truncation feature
    """
)

println("\n" * "="^80)
println("Test completed!")
println("="^80)
