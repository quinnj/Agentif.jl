module Agentif

using StructUtils, JSON, Logging, UUIDs

include("util.jl")
include("models.jl")
include("tools.jl")
include("cache.jl")
include("events.jl")
include("providers/openai_responses.jl"); using .OpenAIResponses
include("providers/openai_completions.jl"); using .OpenAICompletions
include("providers/anthropic_messages.jl"); using .AnthropicMessages
include("providers/google_generative_ai.jl"); using .GoogleGenerativeAI
include("agent.jl")
include("input_guardrail.jl")

export Model, getModel, getProviders, getModels, calculateCost
export OpenAIResponses, OpenAICompletions, AnthropicMessages, GoogleGenerativeAI
export @tool, tool_name, AgentTool
export AgentEvent
export AgentEvaluateStartEvent, AgentEvaluateEndEvent, AgentErrorEvent
export TurnStartEvent, TurnEndEvent
export MessageStartEvent, MessageUpdateEvent, MessageEndEvent
export ToolCallRequestEvent, ToolExecutionStartEvent, ToolExecutionEndEvent
export UserTextMessage, AssistantTextMessage, ToolCall, ToolResultMessage

end
