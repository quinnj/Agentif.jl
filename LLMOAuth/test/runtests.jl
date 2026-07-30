using Test
using JSON
using Base64
using Dates
using LLMOAuth
using OAuth

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

@testset "Codex auth input parsing" begin
    @test LLMOAuth.parse_codex_authorization_input("abc123") == ("abc123", "")
    @test LLMOAuth.parse_codex_authorization_input("abc123#state-1") == ("abc123", "state-1")
    @test LLMOAuth.parse_codex_authorization_input("code=abc123&state=state-1") == ("abc123", "state-1")
    @test LLMOAuth.parse_codex_authorization_input(
        "http://localhost:1455/auth/callback?code=abc123&state=state-1",
    ) == ("abc123", "state-1")
end

@testset "Codex manual auth fallback helpers" begin
    @test LLMOAuth.codex_manual_authorization_code(
        "http://localhost:1455/auth/callback?code=abc123&state=state-1",
        "state-1";
        input_provider = () -> "http://localhost:1455/auth/callback?code=abc123&state=state-1",
    ) == "abc123"

    @test_throws ArgumentError LLMOAuth.codex_manual_authorization_code(
        "http://localhost:1455/auth/callback?code=abc123&state=state-1",
        "state-1";
        input_provider = () -> "abc123#wrong-state",
    )
end

@testset "Codex refresh token preservation" begin
    access = fake_jwt(Dict("https://api.openai.com/auth" => Dict("chatgpt_account_id" => "acct-xyz")))
    issued_at = Dates.now(Dates.UTC)
    token = OAuth.TokenResponse(
        access_token = access,
        token_type = "Bearer",
        expires_at = issued_at + Dates.Second(3600),
        refresh_token = nothing,
        scope = nothing,
        id_token = nothing,
        dpop_jkt = nothing,
        dpop_nonce = nothing,
        authorization_details = nothing,
        resource = String[],
        issued_token_type = nothing,
        extra = Dict{String, Any}(),
        raw = JSON.parse("{}"),
    )
    creds = LLMOAuth.codex_credentials_from_token(token; existing_refresh_token = "refresh-old")
    @test creds.refresh_token == "refresh-old"
    @test creds.account_id == "acct-xyz"
end

@testset "Codex credential file atomic save and permissions" begin
    dir = joinpath(mktempdir(), "agentif")
    withenv("AGENTIF_DIR" => dir) do
        creds = LLMOAuth.CodexCredentials(
            "access-token",
            "refresh-token",
            DateTime(2030, 1, 1),
            "acct-123",
        )
        LLMOAuth.codex_save_credentials(creds)
        path = LLMOAuth.codex_auth_path()
        @test path == joinpath(dir, "codex_auth.json")
        @test isfile(path)
        @test filemode(path) & 0o777 == 0o600
        @test filemode(dir) & 0o777 == 0o700
        loaded = LLMOAuth.codex_load_credentials()
        @test loaded.access_token == creds.access_token
        @test loaded.refresh_token == creds.refresh_token
        @test loaded.expires_at == creds.expires_at
        @test loaded.account_id == creds.account_id

        # Overwriting keeps tight permissions and leaves no temp files behind.
        creds2 = LLMOAuth.CodexCredentials("access-2", "refresh-2", DateTime(2031, 1, 1), "acct-456")
        LLMOAuth.codex_save_credentials(creds2)
        @test filemode(path) & 0o777 == 0o600
        @test LLMOAuth.codex_load_credentials().refresh_token == "refresh-2"
        @test readdir(dir) == ["codex_auth.json"]
    end
end

@testset "Codex invalid_grant classification" begin
    @test !LLMOAuth.codex_is_invalid_grant(200, "{\"access_token\": \"ok\"}")
    @test LLMOAuth.codex_is_invalid_grant(400, "{\"error\": \"invalid_grant\"}")
    @test LLMOAuth.codex_is_invalid_grant(401, "{\"error\": \"invalid_grant\", \"error_description\": \"revoked\"}")
    # A 401 from the token endpoint always means the refresh token was rejected.
    @test LLMOAuth.codex_is_invalid_grant(401, "{\"error\": \"invalid_token\"}")
    # Real-world shape when another client rotates the token out from under us:
    # 401, no `invalid_grant` string anywhere in the body.
    @test LLMOAuth.codex_is_invalid_grant(401,
        "{\"error\": {\"message\": \"Your refresh token has already been used to generate a new access token. Please try signing in again.\", \"type\": \"invalid_request_error\"}}")
    @test LLMOAuth.codex_is_invalid_grant(400, "{\"error\": {\"message\": \"refresh token expired\"}}")
    @test !LLMOAuth.codex_is_invalid_grant(500, "{\"error\": \"invalid_grant\"}")
    @test !LLMOAuth.codex_is_invalid_grant(400, "{\"error\": \"invalid_request\"}")
end

@testset "Codex refresh failure clears revoked credentials" begin
    dir = joinpath(mktempdir(), "agentif")
    withenv("AGENTIF_DIR" => dir) do
        creds = LLMOAuth.CodexCredentials("access", "refresh", DateTime(2030, 1, 1), "acct-123")
        LLMOAuth.codex_save_credentials(creds)
        path = LLMOAuth.codex_auth_path()

        # A non-invalid_grant failure keeps the stored credentials.
        err = LLMOAuth.codex_refresh_failure(500, "{\"error\": \"server_error\"}")
        @test err isa ErrorException
        @test occursin("status 500", err.msg)
        @test occursin("server_error", err.msg)
        @test isfile(path)

        # invalid_grant deletes the stored credentials and points at codex_login().
        err = LLMOAuth.codex_refresh_failure(400, "{\"error\": \"invalid_grant\"}")
        @test err isa ErrorException
        @test occursin("re-run codex_login()", err.msg)
        @test !isfile(path)
    end
end

@testset "Response body snippet" begin
    @test LLMOAuth.response_body_snippet("short") == "short"
    @test LLMOAuth.response_body_snippet("   ") == "<empty response body>"
    snippet = LLMOAuth.response_body_snippet(repeat("x", 500))
    @test length(snippet) == 203
    @test startswith(snippet, repeat("x", 200))
    @test endswith(snippet, "...")
end
