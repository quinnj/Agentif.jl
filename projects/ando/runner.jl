using LLMOAuth
using Mattermost
using Vo

const VoMattermostExt = Base.get_extension(Vo, :VoMattermostExt)
VoMattermostExt === nothing && error("VoMattermostExt did not load; ensure Mattermost is available in this project")

# Ensures we have valid/refreshable Codex OAuth credentials before starting.
_, account_id = LLMOAuth.codex_login()
@info "Codex OAuth ready" account_id

provider = get(ENV, "VO_AGENT_PROVIDER", "openai-codex")
model_id = get(ENV, "VO_AGENT_MODEL", "gpt-5-codex")
assistant_name = get(ENV, "VO_ASSISTANT_NAME", "ando")
base_dir = get(ENV, "VO_BASE_DIR", abspath(joinpath(@__DIR__, "..", "..")))
db_path = joinpath(@__DIR__, "ando.sqlite")

sources = Vo.EventSource[
    VoMattermostExt.MattermostEventSource(),
]

@info "Starting Ando project runner" assistant_name provider model_id db_path source_count=length(sources)
Vo.init!(db_path;
    event_sources=sources,
    name=assistant_name,
    provider=provider,
    model_id=model_id,
    apikey="OAUTH",
    base_dir=base_dir,
)

# Vo currently has no blocking run loop, so keep process alive.
wait(Base.Event())
