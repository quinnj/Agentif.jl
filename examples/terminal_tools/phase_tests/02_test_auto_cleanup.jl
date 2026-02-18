using Agentif, LLMTools
using PtySessions

println("="^80)
println("Phase 1 Test: Auto-Cleanup of Exited Sessions")
println("="^80)
println()

tools = LLMTools.create_terminal_tools()
agent = Agent(
    prompt = "You are a helpful assistant testing auto-cleanup functionality.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

println("Testing automatic cleanup of exited sessions...")
println()

result = evaluate(
    agent, """
    Test auto-cleanup:
    1. Start a short-lived process: echo "Hello World"
    2. Verify the process exited immediately (no session ID returned)
    3. Use list_sessions to confirm no lingering sessions

    Then test cleanup via write_stdin:
    4. Start a process: sleep 2
    5. Wait 3 seconds (let it exit)
    6. Try write_stdin to that session
    7. Verify it auto-removes the dead session and notifies you
    8. Use list_sessions to confirm it's gone
    """
)

println("\n" * "="^80)
println("Test completed!")
println("="^80)
