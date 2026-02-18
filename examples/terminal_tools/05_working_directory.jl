using Agentif, LLMTools
using PtySessions

println("Example 5: Working Directory Test")
println("="^80)

tools = LLMTools.create_terminal_tools()
agent = Agent(
    prompt = "You are a helpful assistant that can execute commands in different directories.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

result = evaluate(
    agent, """
    Run 'pwd' command in two different working directories:
    1. First run it in the /tmp directory
    2. Then run it in the /var directory (or /private/var on macOS)

    Compare the outputs to confirm the working directory was respected.
    """
)

println("\n" * "="^80)
println("Test completed!")
