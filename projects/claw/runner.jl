using JMAP
using LLMOAuth
using Slack
using Telegram
using Claw

const ClawJMAPExt = Base.get_extension(Claw, :ClawJMAPExt)
const ClawSlackExt = Base.get_extension(Claw, :ClawSlackExt)
const ClawTelegramExt = Base.get_extension(Claw, :ClawTelegramExt)
ClawJMAPExt === nothing && error("ClawJMAPExt did not load; ensure JMAP is available in this project")
ClawSlackExt === nothing && error("ClawSlackExt did not load; ensure Slack is available in this project")
ClawTelegramExt === nothing && error("ClawTelegramExt did not load; ensure Telegram is available in this project")

# Ensures we have valid/refreshable Codex OAuth credentials before starting.
_, account_id = LLMOAuth.codex_login()
@info "Codex OAuth ready" account_id

provider = get(ENV, "CLAW_AGENT_PROVIDER", "openai-codex")
model_id = get(ENV, "CLAW_AGENT_MODEL", "gpt-5-codex")
assistant_name = get(ENV, "CLAW_ASSISTANT_NAME", "vo")
base_dir = get(ENV, "CLAW_BASE_DIR", abspath(joinpath(@__DIR__, "..", "..")))
db_path = joinpath(@__DIR__, "vo.sqlite")

sources = Claw.EventSource[
    ClawJMAPExt.FastmailEventSource(),
    ClawSlackExt.SlackEventSource(),
    ClawTelegramExt.TelegramEventSource(),
]

@info "Starting Claw project runner" assistant_name provider model_id db_path source_count=length(sources)
assistant = Claw.init!(db_path;
    event_sources=sources,
    name=assistant_name,
    provider=provider,
    model_id=model_id,
    apikey="OAUTH",
    base_dir=base_dir,
)

# Block until the SIGTERM/SIGINT-installed shutdown handler has drained the
# pipeline, rather than parking forever on an event that is never notified.
Claw.wait_for_shutdown(assistant)
