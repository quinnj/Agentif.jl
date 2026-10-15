module MCPToolsTests
using Test, Agentif, JSON, LLMTools, ModelContextProtocol
const MCP = ModelContextProtocol

function call(tool, args)
    tc = Agentif.PendingToolCall(; name = tool.name, call_id = "test", arguments = JSON.json(args))
    return wait(Agentif.call_function_tool!(identity, tool, tc))
end

function check_tools(client)
    tools = LLMTools.mcp_tools(client)
    @test Set(t.name for t in tools) == Set(["mcp_echo", "mcp_fail", "mcp_input"])
    echo = only(t for t in tools if t.name == "mcp_echo")
    result = call(echo, Dict("text" => "hello"))
    @test !result.is_error
    body = JSON.parse(Agentif.message_text(result))
    @test body["structuredContent"]["text"] == "hello"
    @test body["content"][1]["text"] == "echo"
    @test call(echo, Dict("text" => 1)).is_error
    failure = call(only(t for t in tools if t.name == "mcp_fail"), Dict("text" => "bad"))
    @test failure.is_error
    @test JSON.parse(Agentif.message_text(failure))["isError"]
    incomplete = call(only(t for t in tools if t.name == "mcp_input"), Dict("text" => "permission"))
    @test incomplete.is_error
    @test JSON.parse(Agentif.message_text(incomplete))["resultType"] == "input_required"
    @test first(LLMTools.mcp_tools(client; prefix = "other_")).name == "other_echo"
    @test_throws ArgumentError LLMTools.mcp_tools(client; prefix = repeat("x", 65))
    @test !(:mcp_tools in names(LLMTools))
end

@testset "MCP tools over owned stdio" begin
    for protocol in ("2025-11-25", "2026-07-28"), mode in ("normal", "collision", "cycle")
        command = `$(Base.julia_cmd()) --startup-file=no --threads=1 --project=$(dirname(Base.active_project())) $(joinpath(@__DIR__, "mcp_peer.jl")) $mode`
        MCP.prepare_stdio_client(command; config = MCP.MCPClientConfig(; protocol_version = protocol, timeout = (; readtimeout = 20))) do client
            @test_throws ArgumentError LLMTools.mcp_tools(client)
            MCP.initialize_client!(client)
            mode == "normal" ? check_tools(client) : @test_throws(ArgumentError, LLMTools.mcp_tools(client))
        end
    end
end

@testset "MCP tools over HTTP" begin
    server = MCP.MCPServer(MCP.MCPServerConfig(; name = "Agentif client fixture", version = "1"))
    schema = Dict("type" => "object", "properties" => Dict("text" => Dict("type" => "string")), "required" => ["text"])
    for name in ("echo", "fail", "input")
        MCP.register_tool!(server; name, input_schema = schema, handler = (_, args) ->
            name == "input" ? Dict("resultType" => "input_required", "inputRequests" => Dict()) :
            Dict("content" => [Dict("type" => "text", "text" => name)], "structuredContent" => args, "isError" => name == "fail"))
    end
    http = MCP.serve_mcp_http(server; host = "127.0.0.1", port = 0)
    try
        for protocol in ("2025-11-25", "2026-07-28")
            discovery = MCP.discover_server(MCP.base_url(http))
            client = MCP.prepare_manual_client(discovery; config = MCP.MCPClientConfig(; protocol_version = protocol))
            try
                MCP.initialize_client!(client)
                # HTTP servers sort the catalog; discovery order is not part of the contract.
                tools = LLMTools.mcp_tools(client)
                @test length(tools) == 3
                echo = only(t for t in tools if t.name == "mcp_echo")
                result = call(echo, Dict("text" => "over HTTP"))
                @test !result.is_error
                @test JSON.parse(Agentif.message_text(result))["structuredContent"]["text"] == "over HTTP"
                @test call(only(t for t in tools if t.name == "mcp_fail"), Dict("text" => "bad")).is_error
            finally
                MCP.terminate_session!(client)
            end
        end
    finally
        MCP.stop_mcp_server(http)
    end
end
end
