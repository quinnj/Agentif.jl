using Agentif, LLMTools
using PtySessions

println("Example 6: Multi-line Output Processing")
println("="^80)

tools = LLMTools.create_terminal_tools()
agent = Agent(
    prompt = "You are a helpful assistant that can handle commands with multi-line output.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

result = evaluate(
    agent, """
    Execute a command that produces multiple lines of output.
    Use a bash for loop to print numbers 1 through 10, each on a new line:
    for i in {1..10}; do echo "Line \$i"; done

    Show all the output.
    """
)

println("\n" * "="^80)
println("Test completed!")
