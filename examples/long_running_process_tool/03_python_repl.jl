using Agentif
using PtySessions

println("Example 3: Python REPL Interaction")
println("="^80)

tools = create_long_running_process_tool()
agent = Agent(
    prompt = "You are a helpful assistant that can interact with Python REPLs.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

result = evaluate(
    agent, """
    Execute a Python one-liner that demonstrates multiple operations:
    python3 -c "x = 10 + 25; print(f'Result: {x}'); y = 42; print(f'Variable y: {y}')"

    Show all the output.
    """
)

println("\n" * "="^80)
println("Test completed!")
