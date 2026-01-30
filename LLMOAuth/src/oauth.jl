using OAuth, Dates, HTTP, Base64

const ANTHROPIC_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
const ANTHROPIC_AUTHORIZE_URL = "https://claude.ai/oauth/authorize"
const ANTHROPIC_TOKEN_URL = "https://console.anthropic.com/v1/oauth/token"
const ANTHROPIC_REDIRECT_URI = "https://console.anthropic.com/oauth/code/callback"
const ANTHROPIC_SCOPES = "org:create_api_key user:profile user:inference"

function agentif_dir()
    return joinpath(homedir(), ".agentif")
end

function anthropic_auth_path()
    return joinpath(agentif_dir(), "auth.json")
end

function ensure_agentif_dir()
    dir = agentif_dir()
    isdir(dir) || mkpath(dir)
    return dir
end

function anthropic_client_config()
    ensure_agentif_dir()
    store = OAuth.FileBasedRefreshTokenStore(anthropic_auth_path())
    config = OAuth.PublicClientConfig(
        client_id = ANTHROPIC_CLIENT_ID,
        redirect_uri = ANTHROPIC_REDIRECT_URI,
        scopes = split(ANTHROPIC_SCOPES),
        refresh_token_store = store,
    )
    return config
end

function anthropic_authorization_metadata()
    payload = Dict(
        "issuer" => "https://console.anthropic.com",
        "authorization_endpoint" => ANTHROPIC_AUTHORIZE_URL,
        "token_endpoint" => ANTHROPIC_TOKEN_URL,
        "response_types_supported" => ["code"],
        "grant_types_supported" => ["authorization_code", "refresh_token"],
        "code_challenge_methods_supported" => ["S256"],
    )
    data = JSON.parse(Vector{UInt8}(codeunits(JSON.json(payload))))
    return OAuth.AuthorizationServerMetadata(data)
end

function parse_anthropic_code(input::String)
    parts = split(strip(input), "#"; limit = 2)
    code = isempty(parts) ? "" : strip(parts[1])
    state = length(parts) == 2 ? strip(parts[2]) : ""
    return code, state
end

function anthropic_exchange_code(code::AbstractString, state::AbstractString, verifier::OAuth.PKCEVerifier)
    payload = Dict(
        "grant_type" => "authorization_code",
        "client_id" => ANTHROPIC_CLIENT_ID,
        "code" => code,
        "state" => state,
        "redirect_uri" => ANTHROPIC_REDIRECT_URI,
        "code_verifier" => verifier.verifier,
    )
    resp = HTTP.post(
        ANTHROPIC_TOKEN_URL,
        ["Content-Type" => "application/json"],
        JSON.json(payload),
    )
    resp.status in 200:299 || throw(ErrorException("Anthropic token exchange failed: $(String(resp.body))"))
    data = JSON.parse(resp.body)
    token = OAuth.TokenResponse(data; issued_at = Dates.now(Dates.UTC))
    return token
end

function anthropic_login(; open_browser::Bool = true)
    try
        return anthropic_access_token()
    catch
        # Fall back to interactive login when no stored token is available.
    end
    config = anthropic_client_config()
    verifier = OAuth.generate_pkce_verifier()
    challenge = OAuth.pkce_challenge(verifier)
    state = verifier.verifier
    request = OAuth.AuthorizationRequest(
        authorization_endpoint = ANTHROPIC_AUTHORIZE_URL,
        response_type = "code",
        client_id = ANTHROPIC_CLIENT_ID,
        redirect_uri = ANTHROPIC_REDIRECT_URI,
        scope = ANTHROPIC_SCOPES,
        state = state,
        code_challenge = challenge,
        code_challenge_method = "S256",
        resources = String[],
        authorization_details = nothing,
        request = nothing,
        request_uri = nothing,
        extra = Dict("code" => "true"),
    )
    url = OAuth.build_authorization_url(request)
    open_browser && OAuth.launch_browser(url)
    println("Open this URL in your browser:\n$(url)")
    print("Paste the authorization code (code#state): ")
    code_input = readline()
    code, returned_state = parse_anthropic_code(code_input)
    isempty(code) && throw(ArgumentError("Authorization code is required"))
    returned_state == state || throw(ArgumentError("Authorization state mismatch"))
    token = anthropic_exchange_code(code, returned_state, verifier)
    OAuth.save_token_response!(config, token)
    return token.access_token
end

function anthropic_access_token(; skew_seconds::Integer = 60)
    config = anthropic_client_config()
    metadata = anthropic_authorization_metadata()
    token = OAuth.load_or_refresh_token(metadata, config; skew_seconds = skew_seconds)
    return token.access_token
end

# OpenAI Codex OAuth constants
const CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
const CODEX_AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize"
const CODEX_TOKEN_URL = "https://auth.openai.com/oauth/token"
const CODEX_LOOPBACK_HOST = "localhost"
const CODEX_LOOPBACK_PORT = 1455
const CODEX_LOOPBACK_PATH = "/auth/callback"
const CODEX_REDIRECT_URI = "http://$(CODEX_LOOPBACK_HOST):$(CODEX_LOOPBACK_PORT)$(CODEX_LOOPBACK_PATH)"
const CODEX_SCOPES = "openid profile email offline_access"
const CODEX_JWT_CLAIM_PATH = "https://api.openai.com/auth"

"""
    CodexCredentials

Stores OAuth credentials for OpenAI Codex, including the account ID extracted from the JWT.
"""
struct CodexCredentials
    access_token::String
    refresh_token::String
    expires_at::DateTime
    account_id::String
end

function codex_auth_path()
    return joinpath(agentif_dir(), "codex_auth.json")
end

function codex_client_config()
    ensure_agentif_dir()
    store = OAuth.FileBasedRefreshTokenStore(codex_auth_path())
    config = OAuth.PublicClientConfig(
        client_id = CODEX_CLIENT_ID,
        redirect_uri = CODEX_REDIRECT_URI,
        scopes = split(CODEX_SCOPES),
        refresh_token_store = store,
    )
    return config
end

function codex_authorization_metadata()
    payload = Dict(
        "issuer" => "https://auth.openai.com",
        "authorization_endpoint" => CODEX_AUTHORIZE_URL,
        "token_endpoint" => CODEX_TOKEN_URL,
        "response_types_supported" => ["code"],
        "grant_types_supported" => ["authorization_code", "refresh_token"],
        "code_challenge_methods_supported" => ["S256"],
    )
    data = JSON.parse(Vector{UInt8}(codeunits(JSON.json(payload))))
    return OAuth.AuthorizationServerMetadata(data)
end

"""
    codex_decode_jwt(token::String) -> Dict{String,Any}

Decode a JWT token and return the payload as a Dict.
Returns an empty Dict if decoding fails.
"""
function codex_decode_jwt(token::String)
    parts = split(token, ".")
    length(parts) == 3 || return Dict{String, Any}()
    try
        # Add padding if needed for base64 decoding
        payload = parts[2]
        padding = mod(4 - mod(length(payload), 4), 4)
        payload = payload * repeat("=", padding)
        decoded = String(Base64.base64decode(payload))
        return JSON.parse(decoded)
    catch
        return Dict{String, Any}()
    end
end

"""
    codex_get_account_id(access_token::String) -> String

Extract the ChatGPT account ID from the JWT access token.
Throws an error if the account ID cannot be extracted.
"""
function codex_get_account_id(access_token::String)
    payload = codex_decode_jwt(access_token)
    auth_claims = get(payload, CODEX_JWT_CLAIM_PATH, nothing)
    if auth_claims === nothing
        throw(ErrorException("Failed to extract account ID from Codex token: missing auth claims"))
    end
    account_id = get(auth_claims, "chatgpt_account_id", nothing)
    if account_id === nothing || isempty(account_id)
        throw(ErrorException("Failed to extract account ID from Codex token: missing chatgpt_account_id"))
    end
    return string(account_id)
end

function codex_exchange_code(code::AbstractString, verifier::OAuth.PKCEVerifier)
    resp = HTTP.post(
        CODEX_TOKEN_URL,
        ["Content-Type" => "application/x-www-form-urlencoded"],
        HTTP.URIs.escapeuri(
            Dict(
                "grant_type" => "authorization_code",
                "client_id" => CODEX_CLIENT_ID,
                "code" => code,
                "code_verifier" => verifier.verifier,
                "redirect_uri" => CODEX_REDIRECT_URI,
            )
        ),
    )
    resp.status in 200:299 || throw(ErrorException("Codex token exchange failed: $(String(resp.body))"))
    data = JSON.parse(resp.body)
    token = OAuth.TokenResponse(data; issued_at = Dates.now(Dates.UTC))
    return token
end

function codex_refresh_token(refresh_token::String)
    resp = HTTP.post(
        CODEX_TOKEN_URL,
        ["Content-Type" => "application/x-www-form-urlencoded"],
        HTTP.URIs.escapeuri(
            Dict(
                "grant_type" => "refresh_token",
                "refresh_token" => refresh_token,
                "client_id" => CODEX_CLIENT_ID,
            )
        ),
    )
    resp.status in 200:299 || throw(ErrorException("Codex token refresh failed: $(String(resp.body))"))
    data = JSON.parse(resp.body)
    token = OAuth.TokenResponse(data; issued_at = Dates.now(Dates.UTC))
    return token
end

"""
    codex_save_credentials(creds::CodexCredentials)

Save Codex credentials to the auth file, including the account ID.
"""
function codex_save_credentials(creds::CodexCredentials)
    ensure_agentif_dir()
    data = Dict(
        "access_token" => creds.access_token,
        "refresh_token" => creds.refresh_token,
        "expires_at" => Dates.format(creds.expires_at, Dates.ISODateTimeFormat),
        "account_id" => creds.account_id,
    )
    return open(codex_auth_path(), "w") do io
        write(io, JSON.json(data))
    end
end

"""
    codex_load_credentials() -> CodexCredentials

Load Codex credentials from the auth file.
Throws an error if the file doesn't exist or is invalid.
"""
function codex_load_credentials()
    path = codex_auth_path()
    isfile(path) || throw(ErrorException("No stored Codex credentials found"))
    data = JSON.parse(read(path, String))
    expires_at = Dates.DateTime(data["expires_at"], Dates.ISODateTimeFormat)
    return CodexCredentials(
        data["access_token"],
        data["refresh_token"],
        expires_at,
        data["account_id"],
    )
end

"""
    codex_login(; open_browser::Bool=true, timeout::Real=180) -> CodexCredentials

Perform OAuth login for OpenAI Codex using a local loopback server.
Returns credentials including the access token and account ID.

If valid stored credentials exist, returns those. Otherwise, initiates the OAuth flow
by starting a local HTTP server on port 1455 to receive the authorization callback.
"""
function codex_login(; open_browser::Bool = true, timeout::Real = 180)
    # Try to use existing credentials
    try
        return codex_credentials()
    catch
        # Fall back to interactive login
    end

    verifier = OAuth.generate_pkce_verifier()
    challenge = OAuth.pkce_challenge(verifier)
    state = bytes2hex(rand(UInt8, 16))

    # Start the loopback listener to receive the OAuth callback
    listener = OAuth.start_loopback_listener("127.0.0.1", CODEX_LOOPBACK_PORT, CODEX_LOOPBACK_PATH)

    try
        # Build authorization URL with Codex-specific parameters
        url = string(
            CODEX_AUTHORIZE_URL,
            "?response_type=code",
            "&client_id=", HTTP.URIs.escapeuri(CODEX_CLIENT_ID),
            "&redirect_uri=", HTTP.URIs.escapeuri(CODEX_REDIRECT_URI),
            "&scope=", HTTP.URIs.escapeuri(CODEX_SCOPES),
            "&code_challenge=", HTTP.URIs.escapeuri(challenge),
            "&code_challenge_method=S256",
            "&state=", HTTP.URIs.escapeuri(state),
            "&id_token_add_organizations=true",
            "&codex_cli_simplified_flow=true",
            "&originator=Agentif.jl",
        )

        println("Opening browser for Codex authentication...")
        println("If the browser doesn't open, visit this URL:\n$(url)")
        open_browser && OAuth.launch_browser(url)

        # Wait for the callback with the authorization code
        println("Waiting for authorization callback...")
        params = OAuth.take_with_timeout(listener.result_channel, timeout)

        # Check for errors in the callback
        if haskey(params, "error")
            description = get(params, "error_description", "")
            message = isempty(description) ? params["error"] : "$(params["error"]): $description"
            throw(ErrorException("Authorization failed: $message"))
        end

        # Extract and validate the code and state
        code = get(params, "code", nothing)
        code === nothing && throw(ErrorException("Authorization response missing code parameter"))

        returned_state = get(params, "state", nothing)
        returned_state === nothing && throw(ErrorException("Authorization response missing state parameter"))
        returned_state == state || throw(ErrorException("Authorization state mismatch"))

        # Exchange the code for tokens
        token = codex_exchange_code(code, verifier)
        account_id = codex_get_account_id(token.access_token)

        # Calculate expiration time
        expires_at = something(token.expires_at, Dates.now(Dates.UTC) + Dates.Second(3600))

        creds = CodexCredentials(token.access_token, token.refresh_token, expires_at, account_id)
        codex_save_credentials(creds)

        println("Successfully authenticated with Codex!")
        return creds
    finally
        # Always stop the listener
        OAuth.stop_loopback_listener(listener)
    end
end

"""
    codex_credentials(; skew_seconds::Integer=60) -> CodexCredentials

Get valid Codex credentials, refreshing the token if necessary.

Throws an error if no stored credentials exist or refresh fails.
"""
function codex_credentials(; skew_seconds::Integer = 60)
    creds = codex_load_credentials()

    # Check if token is expired or about to expire
    if Dates.now(Dates.UTC) + Dates.Second(skew_seconds) >= creds.expires_at
        # Refresh the token
        token = codex_refresh_token(creds.refresh_token)
        account_id = codex_get_account_id(token.access_token)

        expires_at = something(token.expires_at, Dates.now(Dates.UTC) + Dates.Second(3600))

        creds = CodexCredentials(token.access_token, token.refresh_token, expires_at, account_id)
        codex_save_credentials(creds)
    end

    return creds
end

"""
    codex_access_token(; skew_seconds::Integer=60) -> String

Get a valid Codex access token, refreshing if necessary.
This is a convenience function that returns just the access token string.
"""
function codex_access_token(; skew_seconds::Integer = 60)
    return codex_credentials(; skew_seconds).access_token
end
