module LLMTools

using Agentif
using Agentif: Agent, AgentState, AgentTool, AgentToolCall, PendingToolCall
using Agentif: UserMessage, AssistantMessage, ToolResultMessage, ToolCallContent
using Agentif: message_text, evaluate
using Base64, Dates, HTTP, JSON, Logging, PtySessions, UUIDs

# Include predefined tools (defines ensure_base_dir, resolve_relative_path, etc.)
include("predefined_tools.jl")

# Exports - File tools
export create_read_tool, create_write_tool, create_edit_tool
export create_grep_tool, create_find_tool, create_ls_tool
export create_codex_tool, create_subagent_tool, create_long_running_process_tool
export coding_tools, read_only_tools, all_tools, web_tools
export create_web_fetch_tool, create_web_search_tool

end
