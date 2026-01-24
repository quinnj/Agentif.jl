using Agentif
using PtySessions

println("Example 10: Error Handling")
println("="^80)

tools = create_long_running_process_tool()
agent = Agent(
    prompt = "You are a helpful assistant that can handle both successful and failing commands.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

result = evaluate(
    agent, """
    Execute these commands and observe the results:
    1. A successful command: echo "This works"
    2. A command that will fail: ls /nonexistent-directory-12345
    3. Show both stdout and stderr output

    Note: The PTY session captures both stdout and stderr.
    """
)

println("\n" * "="^80)
println("Test completed!")
