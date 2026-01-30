#!/usr/bin/env julia
"""
Smoke test for Qmd tools with a live agent.

Run with: julia test/smoke_test.jl
"""

# Setup: activate the project
using Pkg
Pkg.activate(dirname(@__DIR__))

# Now load packages
println("Loading packages...")
using Agentif, LLMTools, LLMProviders

# Get credentials from environment
apikey = get(ENV, "MINIMAX_API_KEY", "")
provider = get(ENV, "MINIMAX_PROVIDER", "openrouter")
model_id = get(ENV, "MINIMAX_MODEL_ID", "minimax/minimax-m2.1")

if isempty(apikey)
    println("ERROR: MINIMAX_API_KEY not set")
    exit(1)
end

println("="^60)
println("Qmd Tools Smoke Test")
println("="^60)
println()

# Create temporary test directory with sample files
println("📁 Creating test directory with sample files...")
test_dir = mktempdir()

# Create a sample Julia file
write(joinpath(test_dir, "calculator.jl"), """
# Calculator module
module Calculator

"""
    add(x, y)

Add two numbers together.
"""
function add(x::Number, y::Number)
    return x + y
end

"""
    subtract(x, y)

Subtract y from x.
"""
function subtract(x::Number, y::Number)
    return x - y
end

"""
    divide(x, y)

Divide x by y. Throws an error if y is zero.
"""
function divide(x::Number, y::Number)
    y == 0 && throw(DivideError())
    return x / y
end

export add, subtract, divide

end # module
""")

# Create a sample README
write(joinpath(test_dir, "README.md"), """
# Test Project

This is a test project for Qmd search functionality.

## Features

- Calculator module with basic arithmetic
- Error handling for division by zero
- Type-safe function signatures

## Usage

```julia
using Calculator
result = add(1, 2)  # Returns 3
```
""")

println("   Created: $test_dir")
println("   Files: calculator.jl, README.md")
println()

# Get model
println("🔍 Getting model: $provider/$model_id...")
model = getModel(provider, model_id)
if model === nothing
    println("ERROR: Model not found")
    exit(1)
end
println("   Model: $(model.name)")
println()

# Create tools
println("🔧 Creating tools...")
index_tool = create_qmd_index_tool(test_dir)
search_tool = create_qmd_search_tool(test_dir)
println("   Created: $(index_tool.name), $(search_tool.name)")
println()

# Create agent
println("🤖 Creating agent...")
agent = Agent(
    prompt = """You are a helpful assistant that can search through code.
    Use the qmd_index tool to index files before searching.
    Use the qmd_search_tool to find relevant code.
    Always respond with what you found.""",
    model = model,
    apikey = apikey,
    tools = AgentTool[index_tool, search_tool],
    skills = nothing,
    input_guardrail = nothing
)
println("   Agent created with $(length(agent.tools)) tools")
println()

# Test 1: Index files
println("📚 Test 1: Indexing files...")
result = index_tool.func(".", "**/*", nothing, true)
println("   Result:")
for line in split(result, '\n')
    println("      $line")
end
println()

# Test 2: Search for division error handling
println("🔎 Test 2: Searching for 'divide by zero error'...")
result = search_tool.func("divide by zero error", true, 5, 0.0)
println("   Result:")
for line in split(result, '\n')
    println("      $line")
end
println()

# Test 3: Search for calculator functions
println("🔎 Test 3: Searching for 'add numbers'...")
result = search_tool.func("add numbers", true, 5, 0.0)
println("   Result:")
for line in split(result, '\n')
    println("      $line")
end
println()

# Test 4: Agent evaluation with search
println("🧠 Test 4: Agent evaluating search query...")
eval_result = evaluate(agent, "Find the function that handles division by zero")

# Get the last assistant message
last_message = ""
for msg in reverse(eval_result.state.messages)
    if msg isa Agentif.AssistantMessage
        last_message = Agentif.message_text(msg)
        break
    end
end

if !isempty(last_message)
    println("   Agent response:")
    for line in split(last_message, '\n')
        println("      $line")
    end
else
    println("   (No assistant message found)")
end
println()

# Cleanup
println("🧹 Cleaning up...")
rm(test_dir, recursive=true)
println("   Removed: $test_dir")
println()

println("="^60)
println("✓ Smoke test completed successfully!")
println("="^60)
