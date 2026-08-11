module ClawGitHubExt

using GitHub
using GitHub: HTTP, Sockets, JSON
import Agentif
import Claw

export GitHubEventSource

_get(p, keys...) = _get(String, p, keys...)
function _get(::Type{T}, p, keys...) where {T}
    v = p
    for k in keys
        v isa AbstractDict || return nothing
        v = get(() -> nothing, v, k)
    end
    v === nothing ? nothing : T == String ? string(v) : v
end

_string_or_empty(v) = v === nothing ? "" : string(v)

function _int_or_nothing(v)
    if v === nothing
        return nothing
    elseif v isa Integer
        return Int(v)
    end
    try
        return parse(Int, string(v))
    catch
        return nothing
    end
end

function _github_headers(auth)
    headers = Dict{String, String}(
        "Accept" => "application/vnd.github+json",
        "User-Agent" => "ClawGitHubExt",
        "X-GitHub-Api-Version" => "2022-11-28",
    )
    auth === nothing || GitHub.authenticate_headers!(headers, auth)
    return headers
end

function _github_request(method::String, endpoint::String; auth = nothing, params = nothing)
    headers = _github_headers(auth)
    response = if params === nothing
        HTTP.request(method, "https://api.github.com$endpoint", headers;
            status_exception=false, retry=false, idle_timeout=30)
    else
        HTTP.request(method, "https://api.github.com$endpoint", headers, JSON.json(params);
            status_exception=false, retry=false, idle_timeout=30)
    end
    if !(200 <= response.status < 300)
        body = String(HTTP.payload(response))
        error("GitHub API request failed ($(response.status)) for $method $endpoint: $body")
    end
    return response
end

function _github_json(method::String, endpoint::String; auth = nothing, params = nothing)
    response = _github_request(method, endpoint; auth, params)
    payload = HTTP.payload(response)
    isempty(payload) && return nothing
    return JSON.parse(payload)
end

function _create_issue_comment(repo_name::String, issue_number::Int, body::String, auth)
    return _github_json("POST", "/repos/$repo_name/issues/$issue_number/comments";
        auth, params=Dict("body" => body))
end

const CREATE_COMMENT_FN = Ref{Function}(_create_issue_comment)

# ─── Channel ───

mutable struct GitHubChannel <: Agentif.AbstractChannel
    repo_name::String
    issue_number::Union{Nothing, Int}
    pull_request_number::Union{Nothing, Int}
    source_kind::String
    source_id::Union{Nothing, Int}
    source_reaction_path::Union{Nothing, String}
    auth::Any
    io::Union{Nothing, IOBuffer}
    response_id::Union{Nothing, Int}
    user_login::String
    display_name::String
end

function _channel_display_name(repo_name::String, issue_number::Union{Nothing, Int}, pull_request_number::Union{Nothing, Int})
    if pull_request_number !== nothing
        return "GitHub PR $repo_name#$pull_request_number"
    elseif issue_number !== nothing
        return "GitHub Issue $repo_name#$issue_number"
    elseif !isempty(repo_name)
        return "GitHub $repo_name"
    else
        return "GitHub"
    end
end

function _comment_target_number(ch::GitHubChannel)
    ch.pull_request_number !== nothing && return ch.pull_request_number
    return ch.issue_number
end

function Agentif.start_streaming(ch::GitHubChannel)
    ch.io = IOBuffer()
    return nothing
end

function Agentif.append_to_stream(ch::GitHubChannel, delta::AbstractString)
    io = ch.io
    if io === nothing
        io = IOBuffer()
        ch.io = io
    end
    write(io, String(delta))
    return nothing
end

Agentif.finish_streaming(::GitHubChannel) = nothing

function Agentif.close_channel(ch::GitHubChannel)
    io = ch.io
    io === nothing && return nothing
    text = String(take!(io))
    ch.io = nothing
    isempty(text) && return nothing
    Agentif.send_message(ch, text)
    return nothing
end

function Agentif.send_message(ch::GitHubChannel, msg)
    auth = ch.auth
    auth === nothing && error("GitHub installation auth is unavailable for this event; cannot post a comment.")
    issue_number = _comment_target_number(ch)
    issue_number === nothing && error("This GitHub event has no issue or pull request target for comments.")
    response = CREATE_COMMENT_FN[](ch.repo_name, issue_number, string(msg), auth)
    if response isa AbstractDict
        ch.response_id = _int_or_nothing(get(() -> nothing, response, "id"))
    end
    return response
end

function Agentif.channel_id(ch::GitHubChannel)
    if ch.pull_request_number !== nothing
        return "github:$(ch.repo_name):pr:$(ch.pull_request_number)"
    elseif ch.issue_number !== nothing
        return "github:$(ch.repo_name):issue:$(ch.issue_number)"
    elseif !isempty(ch.repo_name)
        return "github:$(ch.repo_name)"
    end
    return "github"
end

Agentif.channel_name(ch::GitHubChannel) = ch.display_name
Agentif.is_group(::GitHubChannel) = true
Agentif.is_private(::GitHubChannel) = true

function Agentif.get_current_user(ch::GitHubChannel)
    isempty(ch.user_login) && return nothing
    return Agentif.ChannelUser(ch.user_login, ch.user_login)
end

Agentif.entry_id(ch::GitHubChannel) = ch.source_id === nothing ? nothing : string(ch.source_id)
Agentif.response_entry_id(ch::GitHubChannel) = ch.response_id === nothing ? nothing : string(ch.response_id)

# PR metadata, file lists, and reactions are left to the GitHub CLI (`gh`) in the agent environment.

function Agentif.create_channel_tools(::GitHubChannel)
    return Agentif.AgentTool[]
end

function _issue_number(payload::AbstractDict)
    issue = get(() -> nothing, payload, "issue")
    issue isa AbstractDict && return _int_or_nothing(get(() -> nothing, issue, "number"))
    return nothing
end

function _pull_request_number(kind::String, payload::AbstractDict)
    if kind == "pull_request"
        number = _int_or_nothing(get(() -> nothing, payload, "number"))
        number !== nothing && return number
    end
    issue = get(() -> nothing, payload, "issue")
    if issue isa AbstractDict
        pr_ref = get(() -> nothing, issue, "pull_request")
        if pr_ref isa AbstractDict
            return _int_or_nothing(get(() -> nothing, issue, "number"))
        end
    end
    pr = get(() -> nothing, payload, "pull_request")
    pr isa AbstractDict || return nothing
    return _int_or_nothing(get(() -> nothing, pr, "number"))
end

function _reaction_path(kind::String, repo_name::String, payload::AbstractDict)
    if kind == "pull_request"
        number = _pull_request_number(kind, payload)
        number === nothing && return nothing
        return "/repos/$repo_name/issues/$number/reactions"
    elseif kind == "issues"
        number = _issue_number(payload)
        number === nothing && return nothing
        return "/repos/$repo_name/issues/$number/reactions"
    elseif kind == "issue_comment"
        comment = get(() -> nothing, payload, "comment")
        comment isa AbstractDict || return nothing
        comment_id = _int_or_nothing(get(() -> nothing, comment, "id"))
        comment_id === nothing && return nothing
        return "/repos/$repo_name/issues/comments/$comment_id/reactions"
    elseif kind == "pull_request_review_comment"
        comment = get(() -> nothing, payload, "comment")
        comment isa AbstractDict || return nothing
        comment_id = _int_or_nothing(get(() -> nothing, comment, "id"))
        comment_id === nothing && return nothing
        return "/repos/$repo_name/pulls/comments/$comment_id/reactions"
    end
    return nothing
end

function _build_channel(kind::String, payload::AbstractDict, repo_name::String, sender_login::String, auth)
    issue_number = _issue_number(payload)
    pull_request_number = _pull_request_number(kind, payload)
    source_id = if kind == "pull_request"
        _int_or_nothing(_get(payload, "pull_request", "id"))
    elseif kind == "issues"
        _int_or_nothing(_get(payload, "issue", "id"))
    elseif kind == "pull_request_review"
        _int_or_nothing(_get(payload, "review", "id"))
    else
        _int_or_nothing(_get(payload, "comment", "id"))
    end
    reaction_path = isempty(repo_name) ? nothing : _reaction_path(kind, repo_name, payload)
    display_name = _channel_display_name(repo_name, issue_number, pull_request_number)
    return GitHubChannel(
        repo_name,
        issue_number,
        pull_request_number,
        kind,
        source_id,
        reaction_path,
        auth,
        nothing,
        nothing,
        sender_login,
        display_name,
    )
end

function _comment_body(kind::String, payload::AbstractDict)
    if kind == "pull_request"
        return _get(payload, "pull_request", "body")
    elseif kind == "issues"
        return _get(payload, "issue", "body")
    elseif kind == "pull_request_review"
        return _get(payload, "review", "body")
    end
    return _get(payload, "comment", "body")
end

function _normalize_mention_aliases(aliases::Vector{String})
    normalized = String[]
    seen = Set{String}()
    for alias in aliases
        clean = lowercase(strip(alias))
        isempty(clean) && continue
        clean in seen && continue
        push!(normalized, clean)
        push!(seen, clean)
    end
    return normalized
end

function _has_direct_ping(kind::String, payload::AbstractDict, mention_aliases::Vector{String})
    isempty(mention_aliases) && return false
    body = _comment_body(kind, payload)
    body === nothing && return false
    text = lowercase(string(body))
    for alias in mention_aliases
        occursin("@" * alias, text) && return true
    end
    return false
end

"""Map `pull_request` webhook actions to a Claw event name, or `nothing` to skip enqueueing."""
function _pull_request_claw_event_name(action::String, payload::AbstractDict)
    pr = get(() -> nothing, payload, "pull_request")
    pr isa AbstractDict || return nothing
    if action == "closed"
        return "GitHubPRDone"
    elseif action == "ready_for_review"
        return "GitHubPRReady"
    elseif action == "opened"
        _get(Bool, pr, "draft") === true && return nothing
        return "GitHubPRReady"
    elseif action == "reopened"
        _get(Bool, pr, "draft") === true && return nothing
        return "GitHubPRReady"
    end
    return nothing
end

"""Claw-registered event name for this delivery (`GitHubPRReady` / `GitHubPRDone` replace `github_pull_request`)."""
function _github_webhook_claw_name(kind::String, action::String, payload::AbstractDict)
    if kind == "pull_request"
        return _pull_request_claw_event_name(action, payload)
    end
    return "github_$kind"
end

# ─── Event ───

struct GitHubWebhookEvent <: Claw.ChannelEvent
    name::String
    kind::String
    action::String
    payload::AbstractDict
    repo_name::String
    sender_login::String
    channel::GitHubChannel
    direct_ping::Bool
end

function GitHubWebhookEvent(name::String, kind::String, action::String, payload::AbstractDict, repo_name::String, sender_login::String;
        auth = nothing,
        mention_aliases::Vector{String} = String[],
    )
    channel = _build_channel(kind, payload, repo_name, sender_login, auth)
    direct_ping = _has_direct_ping(kind, payload, mention_aliases)
    return GitHubWebhookEvent(name, kind, action, payload, repo_name, sender_login, channel, direct_ping)
end

Claw.get_name(ev::GitHubWebhookEvent) = ev.name
Claw.get_channel(ev::GitHubWebhookEvent) = ev.channel

function Claw.event_content(ev::GitHubWebhookEvent)
    p = ev.payload
    lines = String["[$(ev.name) — GitHub $(ev.kind) on $(ev.repo_name)]"]
    !isempty(ev.action) && push!(lines, "Action: $(ev.action)")
    !isempty(ev.sender_login) && push!(lines, "By: $(ev.sender_login)")
    ev.direct_ping && push!(lines, "Direct mention: yes")

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
    number = _int_or_nothing(get(() -> nothing, p, "number"))
    number === nothing && (number = _int_or_nothing(get(() -> nothing, pr, "number")))
    number !== nothing && push!(lines, "PR #$number")
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
    number = _int_or_nothing(get(() -> nothing, issue, "number"))
    number !== nothing && push!(lines, "Issue #$number")
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
        number = _int_or_nothing(get(() -> nothing, pr, "number"))
        number !== nothing && push!(lines, "PR #$number")
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
        number = _int_or_nothing(get(() -> nothing, pr, "number"))
        number !== nothing && push!(lines, "PR #$number")
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

# `pull_request` is split into synthetic types `GitHubPRReady` and `GitHubPRDone` (not `github_pull_request`).
const GITHUB_WEBHOOK_KINDS_WITHOUT_PULL_REQUEST =
    [k for k in GITHUB_WEBHOOK_KINDS if k != "pull_request"]

const GITHUB_PR_SYNTHETIC_EVENT_TYPES = Claw.EventType[
    Claw.EventType("GitHubPRReady", "Pull request ready for review: non-draft open, reopened when not draft, or ready_for_review."),
    Claw.EventType("GitHubPRDone", "Pull request closed (merged or unmerged)."),
]

const ALL_EVENT_TYPES = vcat(
    [Claw.EventType("github_$k", "GitHub $k webhook event") for k in GITHUB_WEBHOOK_KINDS_WITHOUT_PULL_REQUEST],
    GITHUB_PR_SYNTHETIC_EVENT_TYPES,
)

# ─── EventSource ───

Base.@kwdef mutable struct GitHubEventSource <: Claw.EventSource
    secret::String = get(ENV, "GITHUB_WEBHOOK_SECRET", "")
    # Loopback by default (§2.1): the safe deployment is behind a proxy, and an
    # HTTP listener that defaults to every interface is one misconfigured firewall
    # away from being the internet's event source.
    host::String = get(ENV, "GITHUB_WEBHOOK_HOST", "127.0.0.1")
    port::Int = parse(Int, get(ENV, "GITHUB_WEBHOOK_PORT", "8080"))
    app_id::Union{Nothing, Int} = let v = get(ENV, "GITHUB_APP_ID", ""); isempty(v) ? nothing : parse(Int, v) end
    private_key_path::Union{Nothing, String} = let v = get(ENV, "GITHUB_PRIVATE_KEY_PATH", ""); isempty(v) ? nothing : v end
    app_slug::Union{Nothing, String} = let v = strip(get(ENV, "GITHUB_APP_SLUG", "")); isempty(v) ? nothing : v end
    mention_aliases::Vector{String} = let
        v = get(ENV, "GITHUB_MENTION_ALIASES", "")
        isempty(v) ? String[] : filter(x -> !isempty(x), strip.(split(v, ",")))
    end
    repos::Union{Nothing, Vector{String}} = nothing
    events::Union{Nothing, Vector{String}} = nothing
    # populated lazily by _get_jwt_auth
    _jwt_auth::Any = nothing
    _server::Any = nothing
    _stopping::Threads.Atomic{Bool} = Threads.Atomic{Bool}(false)
    _lock::ReentrantLock = ReentrantLock()
end

# Issue bodies, PR descriptions and comments are written by anyone with a GitHub
# account (§2.2).
Claw.third_party_content(::GitHubEventSource) = true

Claw.event_source_tag(::GitHubWebhookEvent) = "github"
function Claw.event_extra(ev::GitHubWebhookEvent)
    ch = ev.channel
    installation = get(() -> nothing, ev.payload, "installation")
    installation_id = installation isa AbstractDict ?
        _int_or_nothing(get(() -> nothing, installation, "id")) : nothing
    return Dict{String, Any}(
        "kind" => ev.kind,
        "action" => ev.action,
        "repo" => ev.repo_name,
        "sender" => ev.sender_login,
        "issue_number" => ch.issue_number,
        "pull_request_number" => ch.pull_request_number,
        "source_id" => ch.source_id,
        "source_reaction_path" => ch.source_reaction_path,
        "installation_id" => installation_id,
    )
end

_extra_string(extra::AbstractDict, key::String) =
    (value = get(() -> nothing, extra, key); value === nothing ? "" : string(value))

function _rehydrate_github_event(source::GitHubEventSource, row)
    extra = row.extra
    repo_name = _extra_string(extra, "repo")
    kind = _extra_string(extra, "kind")
    sender = _extra_string(extra, "sender")
    issue_number = _int_or_nothing(get(() -> nothing, extra, "issue_number"))
    pull_request_number = _int_or_nothing(get(() -> nothing, extra, "pull_request_number"))
    source_id = _int_or_nothing(get(() -> nothing, extra, "source_id"))
    reaction_value = get(() -> nothing, extra, "source_reaction_path")
    reaction_path = reaction_value === nothing ? nothing : string(reaction_value)
    installation_id = _int_or_nothing(get(() -> nothing, extra, "installation_id"))
    auth = installation_id === nothing ? nothing :
        _get_installation_auth(source, Dict{String, Any}(
            "installation" => Dict{String, Any}("id" => installation_id)))
    channel = GitHubChannel(
        repo_name,
        issue_number,
        pull_request_number,
        kind,
        source_id,
        reaction_path,
        auth,
        nothing,
        nothing,
        sender,
        _channel_display_name(repo_name, issue_number, pull_request_number),
    )
    return Claw.ReplayedChannelEvent(row.name, row.content, channel)
end

function _register_github_rehydrator!(source::GitHubEventSource)
    Claw.register_rehydrator!("github", row -> _rehydrate_github_event(source, row))
    return nothing
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

function _mention_aliases(source::GitHubEventSource)
    aliases = copy(source.mention_aliases)
    slug = source.app_slug
    if slug !== nothing && !isempty(strip(slug))
        push!(aliases, slug)
        push!(aliases, "$slug[bot]")
    end
    return _normalize_mention_aliases(aliases)
end

function Claw.validate_source(source::GitHubEventSource)
    isempty(strip(source.secret)) && error(
        "GitHubEventSource requires a webhook secret. Set GITHUB_WEBHOOK_SECRET " *
        "(and configure the same secret on the GitHub webhook) before starting.")
    return nothing
end

function Claw.start!(source::GitHubEventSource, assistant::Claw.AgentAssistant)
    secret = strip(source.secret)
    # Fail closed: without a secret GitHub.jl skips HMAC verification entirely,
    # so anyone who can reach the port can inject forged webhook events (which
    # get evaluated as trusted agent input).
    isempty(secret) && error(
        "GitHubEventSource requires a webhook secret. Set GITHUB_WEBHOOK_SECRET " *
        "(and configure the same secret on the GitHub webhook) before starting.")
    webhook_secret = String(secret)
    _register_github_rehydrator!(source)
    repos = source.repos !== nothing ? map(GitHub.Repo, source.repos) : nothing
    host = Sockets.IPv4(source.host)
    port = source.port
    mention_aliases = _mention_aliases(source)
    lock(source._lock) do
        source._server = nothing
        source._stopping[] = false
    end

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
            auth = _get_installation_auth(source, payload)

            claw_name = _github_webhook_claw_name(kind, action, payload)
            if claw_name === nothing
                @info "ClawGitHubExt: ignored pull_request delivery" action repo=repo_name
                return HTTP.Response(200, "OK")
            end

            ghev = GitHubWebhookEvent(claw_name, kind, action, payload, repo_name, sender_login;
                auth, mention_aliases)
            @info "ClawGitHubExt: event" kind action repo=repo_name sender=sender_login direct_ping=ghev.direct_ping name=Claw.get_name(ghev)
            # Persist before returning 200. A crash after the response is covered
            # by Claw's durable inbox; a failure before it lets GitHub redeliver.
            #
            # NOTE: no dedup key yet. GitHub's delivery id arrives as the
            # `X-GitHub-Delivery` *header*, and GitHub.jl's `WebhookEvent` only
            # carries (kind, payload, repository, sender) — the header never reaches
            # this callback. Plumbing it through is Stage 2 (§2.1); until then a
            # GitHub redelivery is processed twice, which is the at-least-once
            # behavior this stage explicitly accepts.
            Claw.submit_event!(assistant, ghev)
            return HTTP.Response(200, "OK")
        end
        @info "ClawGitHubExt: listening on $(source.host):$(source.port)"
        server = HTTP.serve!(listener.handle_request, string(host), port)
        should_stop = lock(source._lock) do
            source._server = server
            source._stopping[]
        end
        should_stop && close(server)
        try
            wait(server)
        finally
            lock(source._lock) do
                source._server === server && (source._server = nothing)
            end
            try
                close(server)
            catch
            end
        end
    end)
end

function Claw.stop!(source::GitHubEventSource)
    server = lock(source._lock) do
        source._stopping[] = true
        source._server
    end
    server === nothing || close(server)
    return nothing
end

# Loading the trigger package makes this integration enable-able by name
# (list_integrations / enable_integration!).
__init__() = Claw.register_integration!("github", GitHubEventSource)

end # module ClawGitHubExt
