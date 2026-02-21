using LLMOAuth
using Slack
using Telegram
using Vo

const VoSlackExt = Base.get_extension(Vo, :VoSlackExt)
const VoTelegramExt = Base.get_extension(Vo, :VoTelegramExt)
VoSlackExt === nothing && error("VoSlackExt did not load; ensure Slack is available in this project")
VoTelegramExt === nothing && error("VoTelegramExt did not load; ensure Telegram is available in this project")

# Ensures we have valid/refreshable Codex OAuth credentials before starting.
_, account_id = LLMOAuth.codex_login()
@info "Codex OAuth ready" account_id

provider = get(ENV, "VO_AGENT_PROVIDER", "openai-codex")
model_id = get(ENV, "VO_AGENT_MODEL", "gpt-5-codex")
assistant_name = get(ENV, "VO_ASSISTANT_NAME", "vo")
base_dir = get(ENV, "VO_BASE_DIR", abspath(joinpath(@__DIR__, "..", "..")))
db_path = joinpath(@__DIR__, "vo.sqlite")

sources = Vo.EventSource[
    VoSlackExt.SlackEventSource(),
    VoTelegramExt.TelegramEventSource(),
]

@info "Starting Vo project runner" assistant_name provider model_id db_path source_count=length(sources)
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
