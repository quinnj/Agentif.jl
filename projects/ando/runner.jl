using LLMOAuth
using GitHub
using Mattermost
using Claw

const ClawMattermostExt = Base.get_extension(Claw, :ClawMattermostExt)
const ClawGitHubExt = Base.get_extension(Claw, :ClawGitHubExt)
ClawMattermostExt === nothing && error("ClawMattermostExt did not load; ensure Mattermost is available in this project")
ClawGitHubExt === nothing && error("ClawGitHubExt did not load; ensure GitHub is available in this project")

function env_bool(name::String, default::Bool = false)
    value = lowercase(strip(get(ENV, name, default ? "true" : "false")))
    return value in ("1", "true", "yes", "on")
end

has_env_value(name::String) = !isempty(strip(get(ENV, name, "")))

function split_env_list(name::String)
    value = strip(get(ENV, name, ""))
    isempty(value) && return nothing
    entries = filter(x -> !isempty(x), strip.(split(value, ",")))
    return isempty(entries) ? nothing : entries
end

function load_prompt_file(path::String)
    isfile(path) || error("Prompt file not found: $path")
    prompt = strip(read(path, String))
    isempty(prompt) && error("Prompt file is empty: $path")
    return prompt
end

function register_handler_from_file!(assistant::Claw.AgentAssistant, id::String, event_types::Vector{String}, path::String)
    prompt = load_prompt_file(path)
    handler = Claw.EventHandler(id, event_types, prompt, nothing)
    Claw.register_event_handler!(assistant, handler)
    @info "Registered Ando event handler" id event_types path
    return handler
end

# Ensures we have valid/refreshable Codex OAuth credentials before starting.
_, account_id = LLMOAuth.codex_login()
@info "Codex OAuth ready" account_id

provider = get(ENV, "CLAW_AGENT_PROVIDER", "openai-codex")
model_id = get(ENV, "CLAW_AGENT_MODEL", "gpt-5-codex")
assistant_name = get(ENV, "CLAW_ASSISTANT_NAME", "ando")
base_dir = get(ENV, "CLAW_BASE_DIR", abspath(joinpath(@__DIR__, "..", "..")))
db_path = joinpath(@__DIR__, "ando.sqlite")
enable_web = env_bool("CLAW_ENABLE_WEB", false)
enable_coding = env_bool("CLAW_ENABLE_CODING", true)

sources = Claw.EventSource[]

mattermost_enabled = env_bool("ANDO_ENABLE_MATTERMOST", has_env_value("MATTERMOST_TOKEN") && has_env_value("MATTERMOST_URL"))
if mattermost_enabled
    push!(sources, ClawMattermostExt.MattermostEventSource())
end

github_enabled = env_bool("ANDO_ENABLE_GITHUB", has_env_value("GITHUB_WEBHOOK_SECRET") || has_env_value("GITHUB_APP_ID"))
if github_enabled
    github_repos = split_env_list("GITHUB_WEBHOOK_REPOS")
    github_events = split_env_list("GITHUB_WEBHOOK_EVENTS")
    if github_events === nothing
        github_events = ["pull_request", "issue_comment", "pull_request_review", "pull_request_review_comment"]
    end
    push!(sources, ClawGitHubExt.GitHubEventSource(; repos=github_repos, events=github_events))
end

isempty(sources) && error("No Ando event sources enabled. Configure Mattermost or GitHub environment variables first.")

@info "Starting Ando project runner" assistant_name provider model_id db_path source_count=length(sources) enable_web enable_coding
assistant = Claw.init!(db_path;
    event_sources=sources,
    name=assistant_name,
    provider=provider,
    model_id=model_id,
    apikey="OAUTH",
    base_dir=base_dir,
    enable_web=enable_web,
    enable_coding=enable_coding,
)

if github_enabled
    pr_prompt_path = get(ENV, "ANDO_GITHUB_PR_HANDLER_PROMPT_FILE", joinpath(@__DIR__, "github_pull_request_prompt.md"))
    if env_bool("ANDO_ENABLE_GITHUB_PR_HANDLER", true)
        register_handler_from_file!(assistant, "ando_github_pull_request_default", ["github_pull_request"], pr_prompt_path)
    end

    mention_prompt_path = strip(get(ENV, "ANDO_GITHUB_MENTION_HANDLER_PROMPT_FILE", ""))
    if !isempty(mention_prompt_path)
        register_handler_from_file!(assistant, "ando_github_mentions", ["github_issue_comment", "github_pull_request_review_comment"], mention_prompt_path)
    end
end

# Claw currently has no blocking run loop, so keep process alive.
wait(Base.Event())
