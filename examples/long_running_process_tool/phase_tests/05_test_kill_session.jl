using Agentif
using PtySessions

println("="^80)
println("Phase 2 Test: kill_session Tool")
println("="^80)
println()

tools = create_long_running_process_tool()
agent = Agent(
    prompt = "You are a helpful assistant testing the kill_session functionality.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

println("Testing explicit session termination with kill_session...")
println()

result = evaluate(
    agent, """
    Test kill_session:
    1. Start 3 long-running processes: sleep 300 (run this 3 times)
    2. Use list_sessions to see all 3 sessions
    3. Use kill_session to terminate the middle session
    4. Use list_sessions to verify it's gone
    5. Try kill_session on a non-existent session ID (like 9999)
    6. Verify it returns a helpful message
    7. Kill the remaining sessions to clean up
    """
)

println("\n" * "="^80)
println("Test completed!")
println("="^80)
