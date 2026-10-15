"""
    LLMTools.mcp_tools(client; prefix="mcp_")

Discover all pages of an initialized ModelContextProtocol.jl client's tools and
return an `Agentif.AgentTool` snapshot. Load the JuliaServices ModelContextProtocol
package to activate this extension. HTTP and stdio clients use the same API.

Names use `prefix` plus the remote name with unsupported characters replaced by
underscores. Names must be unique and at most 64 ASCII letters, digits, underscores
or hyphens. Use a different prefix for each server when combining tool sets.

Calls validate the discovered JSON Schema and return the complete MCP result as
JSON text, including structured content and the remote error flag, subject to
Agentif's tool result size limit. An
`input_required` response is an error requiring host handling; calls are never
automatically replayed. The caller owns initialization, authentication, input
handlers, timeouts, refresh and client shutdown. Rediscover to refresh tools;
existing snapshots retain their schemas. Remote tools can perform side effects.
"""
function mcp_tools end
