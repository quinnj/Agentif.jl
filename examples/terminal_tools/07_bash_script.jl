using Agentif, LLMTools
using PtySessions

println("Example 7: Multi-line Bash Script")
println("="^80)

tools = LLMTools.create_terminal_tools()
agent = Agent(
    prompt = "You are a helpful assistant that can execute bash scripts.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

result = evaluate(
    agent, """
    Execute this bash script that demonstrates variables and functions:

    bash -c '
    greet() {
        echo "Hello, \$1!"
    }

    NAME="PTY User"
    greet "\$NAME"
    echo "Today is: \$(date +%Y-%m-%d)"
    for i in 1 2 3; do
        echo "Count: \$i"
    done
    '

    Show all the output.
    """
)

println("\n" * "="^80)
println("Test completed!")
