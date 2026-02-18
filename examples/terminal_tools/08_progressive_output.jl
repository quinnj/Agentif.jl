using Agentif, LLMTools
using PtySessions

println("Example 8: Progressive Output (Watching Process Progress)")
println("="^80)

tools = LLMTools.create_terminal_tools()
agent = Agent(
    prompt = "You are a helpful assistant that can monitor long-running processes and poll for updates.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

result = evaluate(
    agent, """
    Execute a command that outputs progress markers with delays:
    for i in 1 2 3 4 5; do echo "Progress: \$i/5"; sleep 0.2; done; echo "COMPLETE"

    Use a yield time of 1500ms to capture all the progress output.
    """
)

println("\n" * "="^80)
println("Test completed!")
