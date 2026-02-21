using Test
using JSON
using Base64
using LLMOAuth

function fake_jwt(payload::AbstractDict)
    encoded = Base64.base64encode(JSON.json(payload))
    encoded = replace(encoded, '+' => '-', '/' => '_')
    encoded = replace(encoded, "=" => "")
    return "header.$encoded.signature"
end

@testset "Codex JWT parsing" begin
    token = fake_jwt(Dict("https://api.openai.com/auth" => Dict("chatgpt_account_id" => "acct-123")))
    payload = LLMOAuth.codex_decode_jwt(token)
    claims = get(() -> nothing, payload, "https://api.openai.com/auth")
    @test claims !== nothing
    @test get(() -> nothing, claims, "chatgpt_account_id") == "acct-123"
    @test LLMOAuth.codex_get_account_id(token) == "acct-123"

    bad = fake_jwt(Dict("sub" => "user"))
    @test_throws ErrorException LLMOAuth.codex_get_account_id(bad)
end
