module LLMTools

using Agentif
using Agentif: Agent, AgentContext, AgentState, AgentTool, AgentToolCall, PendingToolCall
using Agentif: UserMessage, AssistantMessage, ToolResultMessage, ToolCallContent
using Agentif: message_text, evaluate
import Agentif: get_agent
using Base64, Dates, HTTP, JSON, Logging, PtySessions, UUIDs
using Qmd

# Include predefined tools (defines ensure_base_dir, resolve_relative_path, etc.)
include("predefined_tools.jl")

# Include Qmd tools (uses functions from predefined_tools.jl)
include("qmd_tools.jl")

# Exports - File tools
export create_read_tool, create_write_tool, create_edit_tool
export create_grep_tool, create_find_tool, create_ls_tool
export create_codex_tool, create_subagent_tool, create_long_running_process_tool
export coding_tools, read_only_tools, all_tools, web_tools
export create_web_fetch_tool, create_web_search_tool

# Exports - Qmd search tools
export qmd_index_files, qmd_search, qmd_list_collections
export qmd_get_current_collection, qmd_set_current_collection
export qmd_set_store_path, qmd_get_store_path
export create_qmd_index_tool, create_qmd_search_tool, qmd_tools

end
