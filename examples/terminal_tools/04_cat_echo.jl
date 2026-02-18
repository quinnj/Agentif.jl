using Agentif, LLMTools
using PtySessions

println("Example 4: Interactive cat (echo test)")
println("="^80)

tools = LLMTools.create_terminal_tools()
agent = Agent(
    prompt = "You are a helpful assistant that can interact with interactive shell commands.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

result = evaluate(
    agent, """
    Use echo with a heredoc to demonstrate multi-line text processing:

    cat << 'EOF'
    Hello from Julia
    Testing PTY sessions
    Multiple lines work great!
    EOF

    Show all the output.
    """
)

println("\n" * "="^80)
println("Test completed!")
