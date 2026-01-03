module Agentif

using StructUtils, JSON, Logging, UUIDs

include("util.jl")
include("models.jl")
include("tools.jl")
include("messages.jl")
include("predefined_tools.jl")
include("events.jl")
include("agent.jl")
include("providers/openai_responses.jl"); using .OpenAIResponses
include("providers/openai_completions.jl"); using .OpenAICompletions
include("providers/anthropic_messages.jl"); using .AnthropicMessages
include("providers/google_generative_ai.jl"); using .GoogleGenerativeAI
include("providers/google_gemini_cli.jl"); using .GoogleGeminiCli
include("providers/openai_responses_adapter.jl")
include("stream.jl")
include("session.jl")
include("input_guardrail.jl")

export Agent, evaluate, evaluate!, stream
export Model, getModel, getProviders, getModels, calculateCost
export OpenAIResponses, OpenAICompletions, AnthropicMessages, GoogleGenerativeAI, GoogleGeminiCli
export @tool, tool_name, AgentTool
export create_bash_tool, create_read_tool, create_write_tool, create_edit_tool
export create_grep_tool, create_find_tool, create_ls_tool
export create_codex_tool
export create_subagent_tool
export create_sandboxed_bash_tool, create_sandboxed_read_tool, create_sandboxed_write_tool, create_sandboxed_edit_tool
export create_sandboxed_grep_tool, create_sandboxed_find_tool, create_sandboxed_ls_tool
export coding_tools, read_only_tools, all_tools
export sandboxed_coding_tools, sandboxed_read_only_tools, sandboxed_all_tools
export AgentEvent
export AgentEvaluateStartEvent, AgentEvaluateEndEvent, AgentErrorEvent
export TurnStartEvent, TurnEndEvent
export MessageStartEvent, MessageUpdateEvent, MessageEndEvent
export ToolCallRequestEvent, ToolExecutionStartEvent, ToolExecutionEndEvent
export AgentMessage, UserMessage, AssistantMessage, AgentToolCall, ToolResultMessage
export AgentState, AgentResponse, AgentResult, Usage
export AgentSession, SessionStore, InMemorySessionStore, FileSessionStore
export load_session, save_session!

end
