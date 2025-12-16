using Test, Agentif

apikey = "***REDACTED_OPENAI_KEY***"

model = Agentif.getModel("openai", "gpt-5-nano")

tools = Agentif.AgentTool[
    Agentif.@tool("can be used to add 2 integers together", add(x::Int, y::Int) = x + y),
    Agentif.@tool_requires_approval("can be used to multiply 2 integers together", multiply(x::Int, y::Int) = x * y)
]

agent = Agentif.Agent(;
    prompt="You are a math assistant soley purposed to help with math questions",
    model,
    input_guardrail=Agentif.default_input_guardrail(model),
    tools
)

# resp = Agentif.evaluate(agent, "What's the weather like in Paris?", apikey)
resp = Agentif.evaluate(agent, "Please use the add and multiply tools to compute: 1) 2 + 4 and 2) 55 * 45", apikey)
