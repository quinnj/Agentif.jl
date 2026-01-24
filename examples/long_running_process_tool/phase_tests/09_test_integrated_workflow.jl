using Agentif
using PtySessions

println("="^80)
println("Integrated Test: All Features Working Together")
println("="^80)
println()

tools = create_long_running_process_tool()
agent = Agent(
    prompt = "You are a helpful assistant demonstrating all PTY session management features.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

println("Testing all features in a realistic workflow...")
println()

result = evaluate(
    agent, """
    Demonstrate a complete workflow using all new features:

    SCENARIO: Managing multiple development processes

    1. SESSION CREATION:
       - Start a development server: sleep 120 (simulating a server)
       - Start a file watcher: sleep 120 (simulating file watching)
       - Start a test runner: for i in {1..50}; do echo "Test \$i"; sleep 0.1; done

    2. SESSION VISIBILITY:
       - Use list_sessions to see all active processes
       - Note their IDs, commands, and ages

    3. SESSION INTERACTION:
       - Poll the test runner session with write_stdin to see progress
       - Use max_output_lines=20 to limit the output

    4. SESSION MANAGEMENT:
       - The test runner should complete - verify auto-cleanup removes it
       - Use list_sessions to confirm it's gone
       - Keep the server and watcher running

    5. CLEANUP:
       - Use kill_session to stop the server
       - Use kill_session to stop the watcher
       - Use list_sessions to verify all cleaned up

    6. LIMITS:
       - Create 5 quick sessions to demonstrate session tracking
       - Show that list_sessions displays all metadata correctly

    This workflow demonstrates:
    - ✅ Session metadata tracking
    - ✅ Auto-cleanup of exited processes
    - ✅ Output truncation with HeadTailBuffer
    - ✅ Manual session termination
    - ✅ Session visibility and monitoring
    - ✅ Multiple concurrent sessions
    """
)

println("\n" * "="^80)
println("Test completed!")
println("="^80)
