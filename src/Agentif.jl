module Agentif

using StructUtils, JSON, JSONSchema, Logging, UUIDs, Encid, PtySessions

include("util.jl")
include("models.jl")
include("tools.jl")
include("messages.jl")
include("events.jl")
include("skills.jl")
include("agent.jl")
include("predefined_tools.jl")
include("providers/openai_responses.jl"); using .OpenAIResponses
include("providers/openai_codex.jl"); using .OpenAICodex
include("providers/openai_completions.jl"); using .OpenAICompletions
include("providers/anthropic_messages.jl"); using .AnthropicMessages
include("providers/google_generative_ai.jl"); using .GoogleGenerativeAI
include("providers/google_gemini_cli.jl"); using .GoogleGeminiCli
include("providers/openai_responses_adapter.jl")
include("stream.jl")
include("session.jl")
include("input_guardrail.jl")
include("oauth.jl")

export Agent, evaluate, evaluate!, stream
export Model, getModel, getProviders, getModels, calculateCost
export OpenAIResponses, OpenAICompletions, AnthropicMessages, GoogleGenerativeAI, GoogleGeminiCli
export @tool, tool_name, AgentTool
export create_read_tool, create_write_tool, create_edit_tool
export create_grep_tool, create_find_tool, create_ls_tool
export SkillMetadata, SkillRegistry, default_skill_dirs, discover_skills, create_skill_registry, reload_skills!
export load_skill, build_available_skills_xml, append_available_skills, create_skill_loader_tool
export create_codex_tool
export create_subagent_tool
export create_long_running_process_tool
export coding_tools, read_only_tools, all_tools, web_tools
export create_web_fetch_tool, create_web_search_tool
export AgentEvent
export AgentEvaluateStartEvent, AgentEvaluateEndEvent, AgentErrorEvent
export TurnStartEvent, TurnEndEvent
export MessageStartEvent, MessageUpdateEvent, MessageEndEvent
export ToolCallRequestEvent, ToolExecutionStartEvent, ToolExecutionEndEvent
export AgentMessage, UserMessage, AssistantMessage, AgentToolCall, ToolResultMessage
export AgentState, AgentResponse, AgentResult, Usage
export AgentSession, SessionStore, InMemorySessionStore, FileSessionStore
export load_session, save_session!
export anthropic_login, anthropic_access_token
export codex_login, codex_credentials, codex_access_token, CodexCredentials

end
