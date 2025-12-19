module Agentif

using StructUtils, JSON, Logging

include("util.jl")
include("models.jl")
include("tools.jl")
include("events.jl")
include("providers/openai_responses.jl"); using .OpenAIResponses
include("agent.jl")
include("input_guardrail.jl")

export Model, getModel, getProviders, getModels, calculateCost
export OpenAIResponses
export @tool, tool_name, AgentTool
export AgentEvent
export AgentEvaluateStartEvent, AgentEvaluateEndEvent, AgentErrorEvent
export TurnStartEvent, TurnEndEvent
export MessageStartEvent, MessageUpdateEvent, MessageEndEvent
export ToolCallRequestEvent, ToolExecutionStartEvent, ToolExecutionEndEvent
export UserTextMessage, AssistantTextMessage, ToolCall, ToolResultMessage

end
