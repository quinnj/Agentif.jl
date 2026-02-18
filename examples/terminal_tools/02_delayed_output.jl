using Agentif, LLMTools
using PtySessions

println("Example 2: Delayed Output with Polling")
println("="^80)

tools = LLMTools.create_terminal_tools()
agent = Agent(
    prompt = "You are a helpful assistant that can handle long-running processes and poll for output.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

result = evaluate(
    agent, """
    Start a command that sleeps for 2 seconds then prints "DELAYED-MARKER".
    Use a short yield time (500ms) to see it start, then poll with write_stdin to get the final output.
    Command: sleep 2 && echo "DELAYED-MARKER"
    """
)

println("\n" * "="^80)
println("Test completed!")
