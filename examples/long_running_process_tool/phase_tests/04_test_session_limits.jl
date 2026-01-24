using Agentif
using PtySessions

println("="^80)
println("Phase 1 Test: Session Limits and LRU Pruning")
println("="^80)
println()

tools = create_long_running_process_tool()
agent = Agent(
    prompt = "You are a helpful assistant testing session limit enforcement.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

println("Testing session limit warnings and LRU pruning...")
println()

result = evaluate(
    agent, """
    Test session limits:
    1. Create 16 long-running sessions (sleep 300) to trigger the warning at 15
    2. Use list_sessions to see all active sessions
    3. Verify you get a warning about approaching the limit
    4. Create 5 more sessions to exceed the limit (total would be 21, max is 20)
    5. Verify that the oldest session gets pruned automatically
    6. Use list_sessions to confirm we stay at or under 20 sessions

    Note: The warning threshold is 15, the max is 20.
    """
)

println("\n" * "="^80)
println("Test completed!")
println("="^80)
