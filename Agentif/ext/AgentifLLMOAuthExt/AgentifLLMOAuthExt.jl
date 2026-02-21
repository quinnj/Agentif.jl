module AgentifLLMOAuthExt

using Agentif
using LLMOAuth

struct LLMOAuthBackend <: Agentif.AbstractOAuthBackend end

Agentif.get_codex_token(::LLMOAuthBackend) = LLMOAuth.codex_access_token()
Agentif.get_anthropic_token(::LLMOAuthBackend) = LLMOAuth.anthropic_login()

function __init__()
    Agentif.OAUTH_BACKEND[] = LLMOAuthBackend()
end

end
