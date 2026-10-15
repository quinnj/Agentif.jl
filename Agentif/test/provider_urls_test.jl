using Test, Agentif, HTTP, JSON, Sockets

@testset "provider endpoints use URL paths" begin
    fixtures = [
        ("openai-completions", "/chat/completions", [
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}",
            "data: [DONE]",
        ]),
        ("openai-responses", "/responses", [
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[]}}",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}",
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"model\":\"test-model\",\"status\":\"completed\"}}",
            "data: [DONE]",
        ]),
        ("anthropic-messages", "/v1/messages", [
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"test-model\",\"content\":[]}}",
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}",
            "data: {\"type\":\"content_block_stop\",\"index\":0}",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}",
            "data: {\"type\":\"message_stop\"}",
        ]),
        ("google-generative-ai", "/models/test-model:streamGenerateContent?alt=sse", [
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"ok\"}],\"role\":\"model\"},\"finishReason\":\"STOP\",\"index\":0}]}",
        ]),
    ]
    @testset "$api, trailing slashes '$suffix'" for (api, endpoint, events) in fixtures, suffix in ("", "/", "///")
        targets = String[]
        server = HTTP.serve!("127.0.0.1", 0) do req
            push!(targets, req.target)
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], join(events, "\n\n") * "\n\n")
        end
        try
            port = applicable(HTTP.port, server) ? HTTP.port(server) : Sockets.getsockname(server.listener.server)[2]
            model = Agentif.Model(;
                id = "test-model", name = "test-model", api, provider = "test",
                baseUrl = "http://127.0.0.1:$port/proxy/api" * suffix,
                reasoning = false, input = ["text"],
                cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
                contextWindow = 4096, maxTokens = 1024,
            )
            errors = Agentif.AgentErrorEvent[]
            result = Agentif.stream(Agentif.Agent(; model, prompt = "test", apikey = "test"), Agentif.AgentState(), "hello", Agentif.Abort()) do event
                event isa Agentif.AgentErrorEvent && push!(errors, event)
            end
            @test isempty(errors)
            @test targets == ["/proxy/api" * endpoint]
            @test result.most_recent_stop_reason == :stop
            @test Agentif.message_text(result.messages[end]) == "ok"
        finally
            close(server)
        end
    end
end
