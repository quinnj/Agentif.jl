module Agentif

using Base64, Dates, HTTP, InteractiveUtils, JSON, JSONSchema, Logging, PtySessions, StructUtils, UUIDs
using Encid: UID8
using LLMProviders
using LLMProviders: Model, getModel, getProviders, getModels, calculateCost
using LLMProviders: OpenAIResponses, OpenAICompletions, AnthropicMessages, GoogleGenerativeAI, GoogleGeminiCli

# Include core modules
include("util.jl")
include("tools.jl")  # Must come before messages.jl (PendingToolCall used in AgentState)
include("messages.jl")
include("events.jl")
include("skills.jl")  # Must come before agent.jl (SkillRegistry used in Agent)
include("agent.jl")
include("session.jl")
include("input_guardrail.jl")
include("stream.jl")

# Include provider adapters that depend on Agent types
include("providers/openai_responses_adapter.jl")

# Exports
export Agent, evaluate, evaluate!, stream
export Model, getModel, getProviders, getModels, calculateCost
export OpenAIResponses, OpenAICompletions, AnthropicMessages, GoogleGenerativeAI, GoogleGeminiCli
export @tool, tool_name, AgentTool
export SkillMetadata, SkillRegistry, default_skill_dirs, discover_skills, create_skill_registry, reload_skills!
export load_skill, build_available_skills_xml, append_available_skills, create_skill_loader_tool
export AgentEvent
export AgentEvaluateStartEvent, AgentEvaluateEndEvent, AgentErrorEvent
export TurnStartEvent, TurnEndEvent
export MessageStartEvent, MessageUpdateEvent, MessageEndEvent
export ToolCallRequestEvent, ToolExecutionStartEvent, ToolExecutionEndEvent
export AgentMessage, UserMessage, AssistantMessage, AgentToolCall, ToolResultMessage
export message_text, message_thinking
export AgentState, AgentResponse, AgentResult, Usage
export AgentSession, SessionStore, InMemorySessionStore, FileSessionStore
export load_session, save_session!

end
