using Agentif, LLMTools
using PtySessions

println("="^80)
println("Phase 1 Test: Session Metadata Tracking")
println("="^80)
println()

tools = LLMTools.create_terminal_tools()
agent = Agent(
    prompt = "You are a helpful assistant testing PTY session metadata tracking.",
    model = getModel("anthropic", "claude-sonnet-4-5"),
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
    stream_output = true
)

println("Testing that session metadata is tracked correctly...")
println()

result = evaluate(
    agent, """
    Test session metadata tracking:
    1. Start a long-running process with: sleep 60
    2. Use list_sessions to see the metadata
    3. Verify it shows created time, last used time, command, and workdir
    """
)

println("\n" * "="^80)
println("Test completed!")
println("="^80)
