module LLMTools

using Agentif
using Agentif: Agent, AgentTool, AssistantMessage, message_text, evaluate
using HTTP, JSON, PtySessions, UUIDs
using GitIgnore: IgnoreMatcher, walkfiltered
using ConcurrentUtilities: Workers, Worker, remote_eval, remote_fetch
using ScopedValues: ScopedValue, @with

# Shared session management infrastructure
include("session_utils.jl")

# Minimal allowlisted environment for child processes (§2.4)
include("subprocess_env.jl")

# Outbound network policy for web_fetch (§2.3)
include("egress.jl")

# File/search/subagent/web tools and tool aggregation
include("predefined_tools.jl")

# Terminal tools (PTY sessions)
include("terminal_tools.jl")

# Worker tools (Julia Workers via ConcurrentUtilities)
include("worker_tools.jl")

# Exports
export create_read_tool, create_write_tool, create_edit_tool
export create_grep_tool, create_find_tool, create_ls_tool
export create_subagent_tool, create_terminal_tools
export create_worker_tools
export coding_tools, read_only_tools, all_tools, web_tools
export create_web_fetch_tool, create_web_search_tool
export WebFetchPolicy, BlockedEgressError
export web_fetch_policy, set_web_fetch_policy!, with_web_fetch_policy
export subprocess_env, set_subprocess_env_allowlist!

end
