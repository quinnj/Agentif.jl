using Agentif, LLMTools
using PtySessions

println("="^80)
println("Phase 1 Test: 50ms Grace Period for Fast Commands")
println("="^80)
println()

tools = LLMTools.create_terminal_tools()
agent = Agent(
    prompt = "You are a helpful assistant testing output capture for fast commands.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

println("Testing 50ms grace period captures output from fast-exiting commands...")
println()

result = evaluate(
    agent, """
    Test grace period:
    1. Run a fast command with very short yield time: echo "FAST-OUTPUT" with yield_time_ms=100
    2. Verify the output "FAST-OUTPUT" is captured despite the quick exit
    3. Run another fast command: for i in 1 2 3; do echo \$i; done with yield_time_ms=200
    4. Verify all output (1, 2, 3) is captured

    The 50ms grace period should ensure we don't lose output from commands that exit quickly.
    """
)

println("\n" * "="^80)
println("Test completed!")
println("="^80)
