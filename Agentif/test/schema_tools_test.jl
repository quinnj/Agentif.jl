module SchemaToolsTests
using Test, Agentif, JSON

@testset "tools with runtime JSON Schemas" begin
    schema = Dict{String, Any}(
        "type" => "object", "properties" => Dict(
            "text" => Dict("type" => "string"),
            "options" => Dict("type" => "object", "properties" => Dict("count" => Dict("type" => "integer"))),
        ), "required" => ["text"], "additionalProperties" => false,
    )
    calls = Ref(0)
    tool = Agentif.AgentTool(; name = "remote_echo", input_schema = schema) do args
        calls[] += 1
        Agentif.ToolOutcome(JSON.json(args); is_error = args["text"] == "fail", details = args)
    end
    @test !tool.strict
    @test JSON.parse(JSON.json(Agentif.tool_schema(tool))) == schema
    schema["required"] = ["text", "options"]
    @test Agentif.parse_tool_arguments("{\"text\":\"hello\"}", tool) == Dict("text" => "hello")
    for raw in ("{}", "{\"text\":1}", "{\"text\":\"ok\",\"extra\":true}", "[]", "null", "{", "{\"text\":\"ok\",\"options\":{\"count\":\"bad\"}}")
        @test_throws Agentif.ToolArgumentError Agentif.parse_tool_arguments(raw, tool)
        result = wait(Agentif.call_function_tool!(identity, tool, Agentif.PendingToolCall(; name = tool.name, call_id = "bad", arguments = raw)))
        @test result.is_error
    end
    @test calls[] == 0
    for text in ("hello", "fail")
        result = wait(Agentif.call_function_tool!(identity, tool, Agentif.PendingToolCall(; name = tool.name, call_id = text, arguments = JSON.json(Dict("text" => text)))))
        @test result.is_error == (text == "fail")
        @test JSON.parse(Agentif.message_text(result))["text"] == text
    end
    @test calls[] == 2
    @test JSON.parse(JSON.json(Agentif.openai_completions_build_tools([tool])))[1]["function"]["parameters"]["required"] == ["text"]
    @test JSON.parse(JSON.json(Agentif.openai_responses_build_tools([tool])))[1]["parameters"]["required"] == ["text"]
    @test JSON.parse(JSON.json(Agentif.anthropic_build_tools([tool], Dict{String, String}())))[1]["input_schema"]["required"] == ["text"]
    @test JSON.parse(JSON.json(Agentif.build_codex_tools([tool])))[1]["parameters"]["required"] == ["text"]
    for provider in (Agentif.GoogleGenerativeAI, Agentif.GoogleGeminiCli)
        @test Agentif.google_build_tools(provider, [tool])[1].functionDeclarations[1].parameters["required"] == ["text"]
    end
    for reference in ("file:///private.json", "https://example.invalid/schema.json", "relative.json", "#unsupported-anchor")
        @test_throws ArgumentError Agentif.AgentTool(identity; name = "external", input_schema = Dict("\$ref" => reference))
    end
    local_ref = Agentif.AgentTool(identity; name = "local", input_schema = Dict(
        "type" => "object", "properties" => Dict("text" => Dict("\$ref" => "#/\$defs/text")),
        "\$defs" => Dict("text" => Dict("type" => "string")), "required" => ["text"],
    ))
    @test Agentif.parse_tool_arguments("{\"text\":\"hi\"}", local_ref)["text"] == "hi"
    @test_throws Agentif.ToolArgumentError Agentif.parse_tool_arguments("{\"text\":false}", local_ref)
    wire = JSON.parse(JSON.json(Agentif.openai_completions_build_tools([local_ref])))
    @test wire[1]["function"]["parameters"]["properties"]["text"]["\$ref"] == "#/\$defs/text"
    legacy = Agentif.AgentTool{typeof(identity), @NamedTuple{}}("legacy", nothing, true, identity)
    @test legacy.input_schema === nothing
end
end
