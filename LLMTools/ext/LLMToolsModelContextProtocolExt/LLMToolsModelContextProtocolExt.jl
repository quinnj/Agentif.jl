module LLMToolsModelContextProtocolExt

using Agentif, JSON, LLMTools, ModelContextProtocol
const MCP = ModelContextProtocol

function LLMTools.mcp_tools(client::MCP.MCPClient; prefix::AbstractString = "mcp_")
    client.initialized || throw(ArgumentError("initialize the MCP client before discovering tools"))
    tools = Agentif.AgentTool[]
    names = Set{String}()
    cursors = Set{String}()
    cursor = nothing
    while true
        page = MCP.list_tools(client; cursor)
        for remote in page["tools"]
            remote_name = String(remote["name"])
            name = prefix * replace(remote_name, r"[^A-Za-z0-9_-]" => "_")
            occursin(r"^[A-Za-z0-9_-]{1,64}$", name) || throw(ArgumentError("MCP tool name must fit 64 ASCII characters: $name"))
            name in names && throw(ArgumentError("MCP tool name collision: $name"))
            push!(names, name)
            invoke = args -> begin
                result = MCP.call_tool(client, remote_name; arguments = args)
                incomplete = MCP.is_input_required(result)
                return Agentif.ToolOutcome(JSON.json(result); is_error = incomplete || get(result, "isError", false) === true, details = result)
            end
            push!(tools, Agentif.AgentTool(invoke; name, description = get(remote, "description", nothing), input_schema = remote["inputSchema"]))
        end
        cursor = get(page, "nextCursor", nothing)
        cursor === nothing && return tools
        cursor = String(cursor)
        cursor in cursors && throw(ArgumentError("MCP tool pagination repeated a cursor"))
        push!(cursors, cursor)
    end
end

end
