using Agentif, LLMTools
using PtySessions

println("Example 1: Simple Echo Command")
println("="^80)

tools = LLMTools.create_terminal_tools()
agent = Agent(
    prompt = "You are a helpful assistant with shell command execution capabilities.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

result = evaluate(
    agent, """
    Execute a simple echo command that prints 'Hello from PTY!'
    """
)

println("\n" * "="^80)
println("Test completed!")
