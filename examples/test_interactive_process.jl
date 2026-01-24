using Agentif
using PtySessions

# Create a more interactive example - start a Python REPL and interact with it
tools = create_long_running_process_tool()

agent = Agent(
    prompt = "You are a helpful assistant that can run long-running shell commands and interact with them.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

println("Testing interactive process with write_stdin...")
println("="^80)
println()

result = evaluate(
    agent, """
    Start a Python REPL in interactive mode using: python3 -i

    Then:
    1. Send it the command to calculate 2+2 (use write_stdin with: "2+2\\n")
    2. Send it the command to print "Hello from PTY!" (use write_stdin with: "print('Hello from PTY!')\\n")
    3. Finally exit the REPL (use write_stdin with: "exit()\\n")

    Show me the outputs at each step.
    """
)

println()
println("="^80)
println("Test completed!")
println()
