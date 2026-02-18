module LLMTools

using Agentif
using Agentif: Agent, AgentState, AgentTool, AgentToolCall, PendingToolCall
using Agentif: UserMessage, AssistantMessage, ToolResultMessage, ToolCallContent
using Agentif: message_text, evaluate
using Base64, Dates, HTTP, JSON, Logging, PtySessions, UUIDs
using ConcurrentUtilities: Workers, Worker, remote_eval, remote_fetch

# Shared session management infrastructure
include("session_utils.jl")

# File/search/codex/subagent/web tools and tool aggregation
include("predefined_tools.jl")

# Terminal tools (PTY sessions)
include("terminal_tools.jl")

# Worker tools (Julia Workers via ConcurrentUtilities)
include("worker_tools.jl")

# Exports
export create_read_tool, create_write_tool, create_edit_tool
export create_grep_tool, create_find_tool, create_ls_tool
export create_codex_tool, create_subagent_tool, create_terminal_tools
export create_worker_tools
export coding_tools, read_only_tools, all_tools, web_tools
export create_web_fetch_tool, create_web_search_tool

end
