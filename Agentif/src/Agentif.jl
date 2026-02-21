module Agentif

using Base64, Dates, HTTP, InteractiveUtils, JSON, JSONSchema, Logging, PtySessions, ScopedValues, StructUtils
using Encid: UID8
using LLMProviders
using LLMProviders: Model, getModel, getProviders, getModels, calculateCost, registerModel!, discover_models!
using LLMProviders: OpenAIResponses, OpenAICompletions, AnthropicMessages, GoogleGenerativeAI, GoogleGeminiCli

const CURRENT_EVALUATION_ID = ScopedValue{Union{Nothing, UID8}}(nothing)

# Include core modules
include("util.jl")
include("tools.jl")  # Must come before messages.jl (PendingToolCall used in AgentState)
include("messages.jl")
include("events.jl")
include("skills.jl")
include("agent.jl")
include("session.jl")
include("input_guardrail.jl")
include("output_guardrail.jl")
include("stream.jl")
include("compaction.jl")
include("channels.jl")
include("middleware.jl")

# Exports
export Agent, Abort, abort!, isaborted, AgentHandler, AgentMiddleware
export evaluate, stream, build_default_handler
export steer_middleware, tool_call_middleware, queue_middleware, evaluate_middleware, session_middleware
export input_guardrail_middleware, skills_middleware, compaction_middleware, channel_middleware
export AbstractChannel, CURRENT_CHANNEL, with_channel, ChannelUser
export start_streaming, append_to_stream, finish_streaming, send_message, close_channel, channel_id
export is_group, is_private, get_current_user, source_message_id
export OutputGuardrailAgent, DEFAULT_OUTPUT_GUARDRAIL_AGENT
export build_output_guardrail_input, materialize_output_guardrail_agent
export CompactionConfig, CompactionSummaryMessage, compact!
export with_prompt, with_tools
export CURRENT_EVALUATION_ID, CURRENT_TURN_ID
export Model, getModel, getProviders, getModels, calculateCost, registerModel!, discover_models!
export OpenAIResponses, OpenAICompletions, AnthropicMessages, GoogleGenerativeAI, GoogleGeminiCli
export @tool, tool_name, AgentTool
export SkillMetadata, SkillRegistry, default_skill_dirs, discover_skills, create_skill_registry, reload_skills!
export load_skill, build_available_skills_xml, append_available_skills, create_skill_loader_tool
export AgentEvent
export AgentEvaluateStartEvent, AgentEvaluateEndEvent, AgentErrorEvent
export TurnStartEvent, TurnEndEvent
export MessageStartEvent, MessageUpdateEvent, MessageEndEvent
export ToolCallRequestEvent, ToolExecutionStartEvent, ToolExecutionEndEvent
export AgentMessage, UserMessage, AssistantMessage, AgentToolCall, ToolResultMessage, CompactionSummaryMessage
export message_text, message_thinking
export AgentState, Usage
export SessionStore, InMemorySessionStore, FileSessionStore, SQLiteSessionStore, init_sqlite_session_schema!
export SessionEntry, session_entries, session_entry_count, append_session_entry!
export load_session, save_session!, new_session_id
export SessionSearchResult, search_sessions, scrub_post!

end
