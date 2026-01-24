using Agentif
using PtySessions

println("Example 9: Environment Variables")
println("="^80)

tools = create_long_running_process_tool()
agent = Agent(
    prompt = "You are a helpful assistant that can work with environment variables.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

result = evaluate(
    agent, """
    Execute commands that show environment variables:
    1. Print the HOME environment variable with: echo \$HOME
    2. Print the PATH variable with: echo \$PATH | head -c 100
    3. Set a custom variable and print it: MY_VAR="test123" && echo \$MY_VAR
    """
)

println("\n" * "="^80)
println("Test completed!")
