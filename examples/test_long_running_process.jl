using Agentif
using PtySessions

# Create a simple agent with the long_running_process tool
tools = create_long_running_process_tool()

agent = Agent(
    prompt = "You are a helpful assistant that can run long-running shell commands and interact with them.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

# Test with a simple long-running process (counting to 5 with sleep)
println("Testing long_running_process tool...")
println("="^80)
println()

result = evaluate(
    agent, """
    Start a long-running process that counts from 1 to 5, with a 1-second delay between each number.
    Use a bash command like: for i in 1 2 3 4 5; do echo \$i; sleep 1; done

    After starting it, wait a bit and check the output to see the progress.
    """
)

println()
println("="^80)
println("Test completed!")
println()
println("Result:")
println(message_text(result.message))
