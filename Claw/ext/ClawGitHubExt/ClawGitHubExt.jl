module ClawGitHubExt

using GitHub
using GitHub: HTTP, Sockets, JSON
import Agentif
import Claw

export GitHubEventSource

# ─── Event ───

struct GitHubWebhookEvent <: Claw.Event
    kind::String
    action::String
    payload::AbstractDict
    repo_name::String
    sender_login::String
end

Claw.get_name(ev::GitHubWebhookEvent) = "github_$(ev.kind)"

function Claw.event_content(ev::GitHubWebhookEvent)
    p = ev.payload
    lines = String["[GitHub $(ev.kind) event on $(ev.repo_name)]"]
    !isempty(ev.action) && push!(lines, "Action: $(ev.action)")
    !isempty(ev.sender_login) && push!(lines, "By: $(ev.sender_login)")

    if ev.kind == "push"
        _format_push!(lines, p)
    elseif ev.kind == "pull_request"
        _format_pull_request!(lines, p)
    elseif ev.kind == "issues"
        _format_issue!(lines, p)
    elseif ev.kind == "issue_comment"
        _format_issue_comment!(lines, p)
    elseif ev.kind == "pull_request_review"
        _format_pr_review!(lines, p)
    elseif ev.kind == "pull_request_review_comment"
        _format_pr_review_comment!(lines, p)
    elseif ev.kind == "release"
        _format_release!(lines, p)
    elseif ev.kind == "create" || ev.kind == "delete"
        _format_ref!(lines, p)
    elseif ev.kind == "commit_comment"
        _format_commit_comment!(lines, p)
    elseif ev.kind == "discussion"
        _format_discussion!(lines, p)
    elseif ev.kind == "discussion_comment"
        _format_discussion_comment!(lines, p)
    elseif ev.kind in ("star", "watch", "fork")
        # minimal; the header lines are sufficient
    elseif ev.kind in ("check_run", "check_suite")
        _format_check!(lines, p, ev.kind)
    elseif ev.kind in ("workflow_run", "workflow_job")
        _format_workflow!(lines, p, ev.kind)
    elseif ev.kind == "deployment_status"
        _format_deployment_status!(lines, p)
    else
        _format_generic!(lines, p)
    end

    return join(lines, "\n")
end

# ─── Content formatters ───

_get(p, keys...) = _get(String, p, keys...)
function _get(::Type{T}, p, keys...) where {T}
    v = p
    for k in keys
        v isa AbstractDict || return nothing
        v = get(() -> nothing, v, k)
    end
    v === nothing ? nothing : T == String ? string(v) : v
end

function _format_push!(lines, p)
    ref = _get(p, "ref")
    ref !== nothing && push!(lines, "Ref: $ref")
    forced = _get(Bool, p, "forced")
    forced === true && push!(lines, "Force push: yes")
    commits = get(() -> [], p, "commits")
    if !isempty(commits)
        push!(lines, "Commits ($(length(commits))):")
        for c in commits[1:min(length(commits), 10)]
            sha = _get(c, "id")
            msg = _get(c, "message")
            sha_short = sha !== nothing ? first(sha, 7) : "?"
            push!(lines, "  $sha_short $(something(msg, ""))")
        end
        length(commits) > 10 && push!(lines, "  ... and $(length(commits) - 10) more")
    end
end

function _format_pull_request!(lines, p)
    pr = get(() -> nothing, p, "pull_request")
    pr isa AbstractDict || return
    title = _get(pr, "title")
    title !== nothing && push!(lines, "Title: $title")
    url = _get(pr, "html_url")
    url !== nothing && push!(lines, "URL: $url")
    body = _get(pr, "body")
    if body !== nothing && !isempty(body)
        truncated = length(body) > 500 ? first(body, 500) * "..." : body
        push!(lines, "Body:\n$truncated")
    end
    base = _get(pr, "base", "ref")
    head = _get(pr, "head", "ref")
    base !== nothing && head !== nothing && push!(lines, "Base: $base ← Head: $head")
    merged = _get(Bool, pr, "merged")
    merged === true && push!(lines, "Merged: yes")
    draft = _get(Bool, pr, "draft")
    draft === true && push!(lines, "Draft: yes")
end

function _format_issue!(lines, p)
    issue = get(() -> nothing, p, "issue")
    issue isa AbstractDict || return
    title = _get(issue, "title")
    title !== nothing && push!(lines, "Title: $title")
    url = _get(issue, "html_url")
    url !== nothing && push!(lines, "URL: $url")
    body = _get(issue, "body")
    if body !== nothing && !isempty(body)
        truncated = length(body) > 500 ? first(body, 500) * "..." : body
        push!(lines, "Body:\n$truncated")
    end
    labels = get(() -> [], issue, "labels")
    if !isempty(labels)
        names = [_get(l, "name") for l in labels]
        push!(lines, "Labels: $(join(filter(!isnothing, names), ", "))")
    end
end

function _format_issue_comment!(lines, p)
    comment = get(() -> nothing, p, "comment")
    comment isa AbstractDict || return
    body = _get(comment, "body")
    if body !== nothing && !isempty(body)
        truncated = length(body) > 500 ? first(body, 500) * "..." : body
        push!(lines, "Comment:\n$truncated")
    end
    url = _get(comment, "html_url")
    url !== nothing && push!(lines, "Comment URL: $url")
    issue = get(() -> nothing, p, "issue")
    if issue isa AbstractDict
        title = _get(issue, "title")
        title !== nothing && push!(lines, "Issue: $title")
        number = _get(issue, "number")
        number !== nothing && push!(lines, "Issue #$number")
    end
end

function _format_pr_review!(lines, p)
    review = get(() -> nothing, p, "review")
    review isa AbstractDict || return
    state = _get(review, "state")
    state !== nothing && push!(lines, "Review state: $state")
    body = _get(review, "body")
    if body !== nothing && !isempty(body)
        truncated = length(body) > 500 ? first(body, 500) * "..." : body
        push!(lines, "Review:\n$truncated")
    end
    pr = get(() -> nothing, p, "pull_request")
    if pr isa AbstractDict
        title = _get(pr, "title")
        title !== nothing && push!(lines, "PR: $title")
    end
end

function _format_pr_review_comment!(lines, p)
    comment = get(() -> nothing, p, "comment")
    comment isa AbstractDict || return
    body = _get(comment, "body")
    if body !== nothing && !isempty(body)
        truncated = length(body) > 500 ? first(body, 500) * "..." : body
        push!(lines, "Comment:\n$truncated")
    end
    path = _get(comment, "path")
    path !== nothing && push!(lines, "File: $path")
    pr = get(() -> nothing, p, "pull_request")
    if pr isa AbstractDict
        title = _get(pr, "title")
        title !== nothing && push!(lines, "PR: $title")
    end
end

function _format_release!(lines, p)
    release = get(() -> nothing, p, "release")
    release isa AbstractDict || return
    tag = _get(release, "tag_name")
    tag !== nothing && push!(lines, "Tag: $tag")
    name = _get(release, "name")
    name !== nothing && push!(lines, "Name: $name")
    body = _get(release, "body")
    if body !== nothing && !isempty(body)
        truncated = length(body) > 500 ? first(body, 500) * "..." : body
        push!(lines, "Notes:\n$truncated")
    end
    prerelease = _get(Bool, release, "prerelease")
    prerelease === true && push!(lines, "Pre-release: yes")
    draft = _get(Bool, release, "draft")
    draft === true && push!(lines, "Draft: yes")
end

function _format_ref!(lines, p)
    ref = _get(p, "ref")
    ref_type = _get(p, "ref_type")
    ref !== nothing && push!(lines, "Ref: $ref")
    ref_type !== nothing && push!(lines, "Type: $ref_type")
end

function _format_commit_comment!(lines, p)
    comment = get(() -> nothing, p, "comment")
    comment isa AbstractDict || return
    body = _get(comment, "body")
    if body !== nothing && !isempty(body)
        truncated = length(body) > 500 ? first(body, 500) * "..." : body
        push!(lines, "Comment:\n$truncated")
    end
    commit_id = _get(comment, "commit_id")
    commit_id !== nothing && push!(lines, "Commit: $(first(commit_id, 7))")
    path = _get(comment, "path")
    path !== nothing && push!(lines, "File: $path")
end

function _format_discussion!(lines, p)
    disc = get(() -> nothing, p, "discussion")
    disc isa AbstractDict || return
    title = _get(disc, "title")
    title !== nothing && push!(lines, "Title: $title")
    body = _get(disc, "body")
    if body !== nothing && !isempty(body)
        truncated = length(body) > 500 ? first(body, 500) * "..." : body
        push!(lines, "Body:\n$truncated")
    end
    url = _get(disc, "html_url")
    url !== nothing && push!(lines, "URL: $url")
end

function _format_discussion_comment!(lines, p)
    comment = get(() -> nothing, p, "comment")
    comment isa AbstractDict || return
    body = _get(comment, "body")
    if body !== nothing && !isempty(body)
        truncated = length(body) > 500 ? first(body, 500) * "..." : body
        push!(lines, "Comment:\n$truncated")
    end
    disc = get(() -> nothing, p, "discussion")
    if disc isa AbstractDict
        title = _get(disc, "title")
        title !== nothing && push!(lines, "Discussion: $title")
    end
end

function _format_check!(lines, p, kind)
    obj = get(() -> nothing, p, kind == "check_run" ? "check_run" : "check_suite")
    obj isa AbstractDict || return
    name = _get(obj, "name")
    name !== nothing && push!(lines, "Name: $name")
    status = _get(obj, "status")
    status !== nothing && push!(lines, "Status: $status")
    conclusion = _get(obj, "conclusion")
    conclusion !== nothing && push!(lines, "Conclusion: $conclusion")
end

function _format_workflow!(lines, p, kind)
    obj = get(() -> nothing, p, kind)
    obj isa AbstractDict || return
    name = _get(obj, "name")
    name !== nothing && push!(lines, "Name: $name")
    status = _get(obj, "status")
    status !== nothing && push!(lines, "Status: $status")
    conclusion = _get(obj, "conclusion")
    conclusion !== nothing && push!(lines, "Conclusion: $conclusion")
    url = _get(obj, "html_url")
    url !== nothing && push!(lines, "URL: $url")
end

function _format_deployment_status!(lines, p)
    ds = get(() -> nothing, p, "deployment_status")
    ds isa AbstractDict || return
    state = _get(ds, "state")
    state !== nothing && push!(lines, "State: $state")
    env = _get(ds, "environment")
    env !== nothing && push!(lines, "Environment: $env")
    url = _get(ds, "target_url")
    url !== nothing && push!(lines, "URL: $url")
end

function _format_generic!(lines, p)
    action = _get(p, "action")
    action !== nothing && push!(lines, "Action: $action")
end

# ─── Event types (one per webhook kind) ───

const GITHUB_WEBHOOK_KINDS = [
    "branch_protection_configuration",
    "branch_protection_rule",
    "check_run",
    "check_suite",
    "code_scanning_alert",
    "commit_comment",
    "create",
    "custom_property",
    "custom_property_values",
    "delete",
    "dependabot_alert",
    "deploy_key",
    "deployment",
    "deployment_protection_rule",
    "deployment_review",
    "deployment_status",
    "discussion",
    "discussion_comment",
    "fork",
    "github_app_authorization",
    "gollum",
    "installation",
    "installation_repositories",
    "installation_target",
    "issue_comment",
    "issues",
    "label",
    "marketplace_purchase",
    "member",
    "membership",
    "merge_group",
    "meta",
    "milestone",
    "org_block",
    "organization",
    "package",
    "page_build",
    "personal_access_token_request",
    "ping",
    "project",
    "project_card",
    "project_column",
    "projects_v2",
    "projects_v2_item",
    "projects_v2_status_update",
    "public",
    "pull_request",
    "pull_request_review",
    "pull_request_review_comment",
    "pull_request_review_thread",
    "push",
    "registry_package",
    "release",
    "repository",
    "repository_advisory",
    "repository_dispatch",
    "repository_import",
    "repository_ruleset",
    "repository_vulnerability_alert",
    "secret_scanning_alert",
    "secret_scanning_alert_location",
    "security_advisory",
    "security_and_analysis",
    "sponsorship",
    "star",
    "status",
    "sub_issues",
    "team",
    "team_add",
    "watch",
    "workflow_dispatch",
    "workflow_job",
    "workflow_run",
]

const ALL_EVENT_TYPES = [Claw.EventType("github_$k", "GitHub $k webhook event") for k in GITHUB_WEBHOOK_KINDS]

# ─── EventSource ───

Base.@kwdef mutable struct GitHubEventSource <: Claw.EventSource
    secret::String = get(ENV, "GITHUB_WEBHOOK_SECRET", "")
    host::String = get(ENV, "GITHUB_WEBHOOK_HOST", "0.0.0.0")
    port::Int = parse(Int, get(ENV, "GITHUB_WEBHOOK_PORT", "8080"))
    app_id::Union{Nothing, Int} = let v = get(ENV, "GITHUB_APP_ID", ""); isempty(v) ? nothing : parse(Int, v) end
    private_key_path::Union{Nothing, String} = let v = get(ENV, "GITHUB_PRIVATE_KEY_PATH", ""); isempty(v) ? nothing : v end
    repos::Union{Nothing, Vector{String}} = nothing
    events::Union{Nothing, Vector{String}} = nothing
    # populated lazily by _get_jwt_auth
    _jwt_auth::Any = nothing
end

function _get_jwt_auth(source::GitHubEventSource)
    source._jwt_auth !== nothing && return source._jwt_auth::GitHub.JWTAuth
    source.app_id === nothing && return nothing
    source.private_key_path === nothing && return nothing
    auth = GitHub.JWTAuth(source.app_id, source.private_key_path)
    source._jwt_auth = auth
    return auth
end

function _get_installation_auth(source::GitHubEventSource, payload::AbstractDict)
    jwt = _get_jwt_auth(source)
    jwt === nothing && return nothing
    inst_data = get(() -> nothing, payload, "installation")
    inst_data isa AbstractDict || return nothing
    inst_id = get(() -> nothing, inst_data, "id")
    inst_id === nothing && return nothing
    try
        return GitHub.create_access_token(GitHub.Installation(; id=inst_id); auth=jwt)
    catch e
        @warn "ClawGitHubExt: failed to create installation access token" exception=(e, catch_backtrace())
        return nothing
    end
end

Claw.get_event_types(::GitHubEventSource) = ALL_EVENT_TYPES

function Claw.start!(source::GitHubEventSource, assistant::Claw.AgentAssistant)
    secret = strip(source.secret)
    # Fail closed: without a secret GitHub.jl skips HMAC verification entirely,
    # so anyone who can reach the port can inject forged webhook events (which
    # get evaluated as trusted agent input).
    isempty(secret) && error(
        "GitHubEventSource requires a webhook secret. Set GITHUB_WEBHOOK_SECRET " *
        "(and configure the same secret on the GitHub webhook) before starting.")
    webhook_secret = String(secret)
    repos = source.repos !== nothing ? map(GitHub.Repo, source.repos) : nothing
    host = Sockets.IPv4(source.host)
    port = source.port

    errormonitor(Threads.@spawn begin
        listener = GitHub.EventListener(;
            secret=webhook_secret,
            events=source.events,
            repos=repos,
        ) do event::GitHub.WebhookEvent
            kind = event.kind
            payload = event.payload
            repo_name = try
                GitHub.name(event.repository)
            catch
                ""
            end
            sender_login = try
                GitHub.name(event.sender)
            catch
                ""
            end
            action = get(() -> "", payload, "action")
            action = action === nothing ? "" : string(action)

            ghev = GitHubWebhookEvent(kind, action, payload, repo_name, sender_login)
            @info "ClawGitHubExt: event" kind action repo=repo_name sender=sender_login name=Claw.get_name(ghev)
            put!(assistant.event_queue, ghev)
            return HTTP.Response(200, "OK")
        end
        @info "ClawGitHubExt: listening on $(source.host):$(source.port)"
        Base.run(listener, host, port)
    end)
end

end # module ClawGitHubExt
