using Agentif
using PtySessions

println("="^80)
println("Phase 2 Test: list_sessions Tool")
println("="^80)
println()

tools = create_long_running_process_tool()
agent = Agent(
    prompt = "You are a helpful assistant testing the list_sessions visibility tool.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

println("Testing session visibility with list_sessions...")
println()

result = evaluate(
    agent, """
    Test list_sessions:
    1. Call list_sessions when no sessions exist - verify it says "No active PTY sessions"
    2. Create 3 different sessions with different commands:
       - sleep 100
       - for i in 1 2 3; do echo \$i; sleep 1; done
       - cat
    3. Use list_sessions to see all sessions
    4. Verify it shows:
       - Session IDs
       - Status (RUNNING/EXITED)
       - Commands
       - Created time ago
       - Last used time ago
       - Working directory
       - Total count
    5. Interact with the middle session using write_stdin
    6. Use list_sessions again to verify "last used" time updated for that session
    7. Clean up all sessions with kill_session
    """
)

println("\n" * "="^80)
println("Test completed!")
println("="^80)
