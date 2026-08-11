module ExtensionTests

using Test
using Agentif
using Mattermost
using MSTeams
using Signal
using Slack
using Telegram
using Claw

# Events are now persisted before dispatch, and the in-memory channel carries only
# rowids as wakeups. Tests still want the event object, which lives in the
# assistant's live-event map until the dispatcher consumes it.
function pop_event!(assistant)
    id = take!(assistant.event_queue)
    ev = get(assistant._live_events, id, nothing)
    ev === nothing && error("no live event registered for claw_events id $id")
    return ev
end

count_events(assistant, sql, params = ()) =
    Int(Claw._fetch_one(
        assistant.db,
        "SELECT COUNT(*) AS n FROM claw_events " * sql,
        params,
    ).n)

mutable struct LockAwareCloser
    lock::ReentrantLock
    closed::Threads.Atomic{Bool}
end

function Base.close(closer::LockAwareCloser)
    task = Threads.@spawn lock(closer.lock) do
        closer.closed[] = true
    end
    timedwait(() -> istaskdone(task), 1.0) == :ok ||
        error("close called while the source lock was held")
    fetch(task)
    return nothing
end

const HAS_GITHUB = try
    @eval using GitHub
    true
catch
    false
end

const HAS_JMAP = try
    @eval using JMAP
    true
catch
    false
end

if HAS_GITHUB
@testset "ClawGitHubExt event mapping" begin
    ext = Base.get_extension(Claw, :ClawGitHubExt)
    @test ext !== nothing

    source = ext.GitHubEventSource(; secret="test-secret", port=19876)
    @test which(Claw.stop!, (typeof(source),)).module === ext
    @test Claw.stop!(source) === nothing
    @test source._stopping[]
    lock_aware = ext.GitHubEventSource(; secret="test-secret", port=19877)
    closer = LockAwareCloser(lock_aware._lock, Threads.Atomic{Bool}(false))
    lock_aware._server = closer
    @test Claw.stop!(lock_aware) === nothing
    @test closer.closed[]
    event_types = Claw.get_event_types(source)
    et_names = Set(et.name for et in event_types)

    # One event type per webhook kind
    @test "github_push" in et_names
    @test "github_fork" in et_names
    @test "github_ping" in et_names
    @test "github_pull_request" in et_names
    @test "github_issues" in et_names
    @test "github_issue_comment" in et_names
    @test "github_release" in et_names
    @test "github_workflow_run" in et_names
    @test "github_star" in et_names
    @test length(event_types) == length(ext.GITHUB_WEBHOOK_KINDS)

    # No default handlers (non-channel event source)
    @test isempty(Claw.get_event_handlers(source))
    @test isempty(Claw.get_channels(source))
    @test isempty(Claw.get_tools(source))

    # Event name is always per-kind (action is in event_content, not name)
    ev_push = ext.GitHubWebhookEvent("push", "", Dict{String,Any}("ref" => "refs/heads/main"), "owner/repo", "alice")
    @test Claw.get_name(ev_push) == "github_push"

    ev_pr = ext.GitHubWebhookEvent("pull_request", "opened",
        Dict{String,Any}("action" => "opened", "pull_request" => Dict{String,Any}(
            "title" => "Add feature", "body" => "Description here",
            "html_url" => "https://github.com/owner/repo/pull/42",
            "number" => 42, "base" => Dict("ref" => "main"), "head" => Dict("ref" => "feature"),
        )),
        "owner/repo", "bob")
    @test Claw.get_name(ev_pr) == "github_pull_request"

    # Event content formatting
    content_pr = Claw.event_content(ev_pr)
    @test occursin("owner/repo", content_pr)
    @test occursin("Add feature", content_pr)
    @test occursin("opened", content_pr)

    content_push = Claw.event_content(ev_push)
    @test occursin("push", content_push)
    @test occursin("refs/heads/main", content_push)

    # Push with commits
    ev_push_commits = ext.GitHubWebhookEvent("push", "",
        Dict{String,Any}(
            "ref" => "refs/heads/main",
            "commits" => [
                Dict{String,Any}("id" => "abc1234567890", "message" => "Fix bug"),
                Dict{String,Any}("id" => "def4567890123", "message" => "Update docs"),
            ],
        ),
        "owner/repo", "dave")
    content_commits = Claw.event_content(ev_push_commits)
    @test occursin("abc1234", content_commits)
    @test occursin("Fix bug", content_commits)
    @test occursin("Commits (2)", content_commits)

    # Issue comment event
    ev_comment = ext.GitHubWebhookEvent("issue_comment", "created",
        Dict{String,Any}("action" => "created",
            "comment" => Dict{String,Any}("body" => "LGTM!", "html_url" => "https://github.com/owner/repo/issues/7#issuecomment-1"),
            "issue" => Dict{String,Any}("title" => "Bug report", "number" => 7),
        ),
        "owner/repo", "eve")
    content_comment = Claw.event_content(ev_comment)
    @test occursin("LGTM!", content_comment)
    @test occursin("Bug report", content_comment)

    # Generic event fallback
    ev_star = ext.GitHubWebhookEvent("star", "created", Dict{String,Any}("action" => "created"), "owner/repo", "fan")
    @test Claw.get_name(ev_star) == "github_star"
    content_star = Claw.event_content(ev_star)
    @test occursin("star", content_star)
    @test occursin("fan", content_star)
end
else
    @info "Skipping ClawGitHubExt tests: GitHub package unavailable in test environment"
end

if HAS_JMAP
@testset "ClawJMAPExt new email events" begin
    ext = Base.get_extension(Claw, :ClawJMAPExt)
    @test ext !== nothing

    source = ext.FastmailEventSource(; token="test-token")
    @test which(Claw.stop!, (typeof(source),)).module === ext
    @test Claw.stop!(source) === nothing
    @test source._stopping[]
    assistant = Claw.AgentAssistant(":memory:";
        provider="openai-completions",
        model_id="gpt-4o-mini",
        apikey="test-key",
    )

    session = JMAP.Session("https://example.invalid")
    session.mailAccountId = "acct-1"
    source._session = session
    source._inbox_mailbox_ids["acct-1"] = Set(["mb-inbox"])

    function drain_events!()
        while isready(assistant.event_queue)
            pop_event!(assistant)
        end
    end

    event_types = Claw.get_event_types(source)
    @test length(event_types) == 1
    @test event_types[1].name == "jmap_new_email"
    @test occursin("inbox", lowercase(event_types[1].description))

    original_email_changes_fn = ext.EMAIL_CHANGES_FN[]
    original_fetch_emails_fn = ext.FETCH_EMAILS_FN[]
    try
        ext.EMAIL_CHANGES_FN[] = (_session, _since_state; account_id) -> JMAP.ChangesResponse(
            accountId=account_id,
            oldState="E1",
            newState="E2",
            hasMoreChanges=false,
            created=["m1"],
            updated=String[],
            destroyed=String[],
        )
        ext.FETCH_EMAILS_FN[] = (_session, ids; account_id, properties) -> begin
            @test ids == ["m1"]
            @test account_id == "acct-1"
            @test "mailboxIds" in properties
            return JMAP.Email[
                JMAP.Email(
                    id="m1",
                    threadId="t1",
                    mailboxIds=Dict("mb-inbox" => true),
                    keywords=Dict{String,Bool}(),
                    from=[JMAP.EmailAddress(name="Alice", email="alice@example.com")],
                    subject="Hello",
                    receivedAt="2026-02-22T12:00:00Z",
                    preview="Test preview",
                ),
            ]
        end

        # First observation seeds baseline and emits nothing.
        sc_seed = JMAP.StateChange("StateChange", Dict("acct-1" => Dict("Email" => "E1")))
        ext._handle_state_change!(source, assistant, sc_seed)
        @test source._states["acct-1"]["Email"] == "E1"
        @test !isready(assistant.event_queue)

        # Email created in inbox emits one high-level new-email event.
        sc_new = JMAP.StateChange("StateChange", Dict("acct-1" => Dict("Email" => "E2")))
        ext._handle_state_change!(source, assistant, sc_new)
        @test isready(assistant.event_queue)
        ev = pop_event!(assistant)
        @test ev isa ext.JMAPNewEmailEvent
        @test Claw.get_name(ev) == "jmap_new_email"
        @test ev.email_id == "m1"
        @test ev.thread_id == "t1"
        @test ev.unread
        @test !ev.has_attachment
        @test occursin("new email arrived", lowercase(Claw.event_content(ev)))

        # Updates without creates do not emit events.
        drain_events!()
        ext.EMAIL_CHANGES_FN[] = (_session, _since_state; account_id) -> JMAP.ChangesResponse(
            accountId=account_id,
            oldState="E2",
            newState="E3",
            hasMoreChanges=false,
            created=String[],
            updated=["m1"],
            destroyed=String[],
        )
        sc_update = JMAP.StateChange("StateChange", Dict("acct-1" => Dict("Email" => "E3")))
        ext._handle_state_change!(source, assistant, sc_update)
        @test source._states["acct-1"]["Email"] == "E3"
        @test !isready(assistant.event_queue)

        # Created email outside inbox is ignored.
        ext.EMAIL_CHANGES_FN[] = (_session, _since_state; account_id) -> JMAP.ChangesResponse(
            accountId=account_id,
            oldState="E3",
            newState="E4",
            hasMoreChanges=false,
            created=["m2"],
            updated=String[],
            destroyed=String[],
        )
        ext.FETCH_EMAILS_FN[] = (_session, ids; account_id, properties) -> begin
            @test ids == ["m2"]
            return JMAP.Email[
                JMAP.Email(
                    id="m2",
                    threadId="t2",
                    mailboxIds=Dict("mb-sent" => true),
                    keywords=Dict("\$seen" => true),
                    from=[JMAP.EmailAddress(name="Me", email="me@example.com")],
                    subject="Sent message",
                ),
            ]
        end
        sc_non_inbox = JMAP.StateChange("StateChange", Dict("acct-1" => Dict("Email" => "E4")))
        ext._handle_state_change!(source, assistant, sc_non_inbox)
        @test source._states["acct-1"]["Email"] == "E4"
        @test !isready(assistant.event_queue)

        # If Email/changes fails, retain the old cursor. Advancing would lose
        # changes that were never fetched.
        ext.EMAIL_CHANGES_FN[] = (_session, _since_state; account_id) -> error("boom for $account_id")
        sc_error = JMAP.StateChange("StateChange", Dict("acct-1" => Dict("Email" => "E5")))
        ext._handle_state_change!(source, assistant, sc_error)
        @test source._states["acct-1"]["Email"] == "E4"
        @test !isready(assistant.event_queue)

        # The same rule applies when Email/get fails after changes were listed.
        ext.EMAIL_CHANGES_FN[] = (_session, _since_state; account_id) -> JMAP.ChangesResponse(
            accountId=account_id,
            oldState="E4",
            newState="E5",
            hasMoreChanges=false,
            created=["m3"],
            updated=String[],
            destroyed=String[],
        )
        ext.FETCH_EMAILS_FN[] = (_session, ids; account_id, properties) ->
            error("email fetch failed")
        ext._handle_state_change!(source, assistant, sc_error)
        @test source._states["acct-1"]["Email"] == "E4"
        @test !isready(assistant.event_queue)

        # A capped page walk is incomplete. It must not acknowledge the
        # intermediate state because later pages would then be lost.
        page_count = Ref(0)
        ext.EMAIL_CHANGES_FN[] = (_session, since_state; account_id) -> begin
            page_count[] += 1
            JMAP.ChangesResponse(
                accountId=account_id,
                oldState=since_state,
                newState="E-page-$(page_count[])",
                hasMoreChanges=true,
                created=["page-$(page_count[])"],
                updated=String[],
                destroyed=String[],
            )
        end
        ext._handle_state_change!(source, assistant, sc_error)
        @test page_count[] == 20
        @test source._states["acct-1"]["Email"] == "E4"
        @test !isready(assistant.event_queue)

        # Persisting the upstream cursor is the acknowledgement boundary. If the
        # durable writer fails, the callback must throw and retain the old state.
        ext.EMAIL_CHANGES_FN[] = (_session, _since_state; account_id) -> JMAP.ChangesResponse(
            accountId=account_id,
            oldState="E4",
            newState="E5",
            hasMoreChanges=false,
            created=String[],
            updated=["m2"],
            destroyed=String[],
        )
        Claw.close_writer!(assistant._writer)
        @test_throws ErrorException ext._handle_state_change!(source, assistant, sc_error)
        @test source._states["acct-1"]["Email"] == "E4"
    finally
        ext.EMAIL_CHANGES_FN[] = original_email_changes_fn
        ext.FETCH_EMAILS_FN[] = original_fetch_emails_fn
    end

    Claw.shutdown!(assistant; timeout_s=5)
end
else
    @info "Skipping ClawJMAPExt tests: JMAP package unavailable in test environment"
end

@testset "ClawSlackExt event mapping" begin
    ext = Base.get_extension(Claw, :ClawSlackExt)
    @test ext !== nothing

    source = ext.SlackEventSource(; app_token="xapp-test", bot_token="xoxb-test")
    @test which(Claw.stop!, (typeof(source),)).module === ext
    @test Claw.stop!(source) === nothing
    @test source._stopping[]
    event_types = Set(et.name for et in Claw.get_event_types(source))
    @test "slack_message" in event_types
    @test "slack_reaction" in event_types
    handlers = Claw.get_event_handlers(source)
    @test any(h -> h.id == "slack_message_default", handlers)
    @test any(h -> h.id == "slack_reaction_default", handlers)

    web_client = Slack.WebClient(; token="xoxb-test")
    channel_type_cache = Dict("C123" => "channel", "C555" => "group", "C999" => "group")

    msg = Slack.SlackMessageEvent(
        type="message",
        channel="C123",
        channel_type="channel",
        user="U123",
        text="hello",
        ts="1700000000.123",
    )
    msg_event = ext._extract_message_event(msg, web_client, "", "", nothing, nothing, channel_type_cache)
    @test msg_event !== nothing
    @test Claw.get_name(msg_event) == "slack_message"
    # Top-level messages map to the base channel branch (not a fresh per-message
    # thread branch) so a conversation stays continuous across messages.
    @test Agentif.channel_id(Claw.get_channel(msg_event)) == "slack:C123"
    @test !msg_event.direct_ping
    @test Agentif.entry_id(Claw.get_channel(msg_event)) == "1700000000.123"
    @test Claw.event_content(msg_event) == "[U123]: hello"

    # Durable replay keeps the source message as the reply root while retaining
    # the base conversation branch.
    source.web_client = web_client
    slack_row = Claw.EventRow(
        1, "slack", "slack_message", nothing,
        Agentif.channel_id(Claw.get_channel(msg_event)),
        Claw.event_content(msg_event),
        Claw.event_extra(msg_event),
        Agentif.channel_id(Claw.get_channel(msg_event)),
        1, nothing,
    )
    replayed_slack = ext._rehydrate_slack_channel(source, slack_row)
    @test replayed_slack !== nothing
    @test replayed_slack.thread_ts == "1700000000.123"
    @test replayed_slack.source_ts == "1700000000.123"
    @test Agentif.channel_id(replayed_slack) == "slack:C123"
    @test Agentif.entry_id(replayed_slack) == "1700000000.123"

    private_msg = Slack.SlackMessageEvent(
        type="message",
        channel="C555",
        channel_type="private_channel",
        user="U555",
        text="private hello",
        ts="1700000000.777",
    )
    private_msg_event = ext._extract_message_event(private_msg, web_client, "", "", nothing, nothing, channel_type_cache)
    @test private_msg_event !== nothing
    @test Agentif.is_group(Claw.get_channel(private_msg_event))
    @test Agentif.is_private(Claw.get_channel(private_msg_event))

    mention = Slack.SlackAppMentionEvent(
        type="app_mention",
        channel="C123",
        user="U123",
        text="<@UBOT> hi",
        ts="1700000001.456",
    )
    mention_event = ext._extract_message_event(mention, web_client, "UBOT", "claw", nothing, nothing, channel_type_cache)
    @test mention_event !== nothing
    @test mention_event.direct_ping

    bot_msg = Slack.SlackMessageEvent(
        type="message",
        channel="C123",
        channel_type="channel",
        bot_id="B999",
        text="ignore me",
        ts="1700000002.789",
    )
    @test ext._extract_message_event(bot_msg, web_client, "", "", nothing, nothing, channel_type_cache) === nothing

    reaction_payload = Slack.JSON.Object(
        "type" => "reaction_added",
        "user" => "U234",
        "reaction" => "thumbsup",
        "item" => Slack.JSON.Object(
            "type" => "message",
            "channel" => "C123",
            "ts" => "1700000000.123",
        ),
    )
    reaction_event = ext._extract_reaction_event(reaction_payload, web_client, "", nothing, nothing, channel_type_cache)
    @test reaction_event !== nothing
    @test Claw.get_name(reaction_event) == "slack_reaction"
    @test occursin("thumbsup", Claw.event_content(reaction_event))
    @test !Agentif.is_private(Claw.get_channel(reaction_event))

    private_reaction_payload = Slack.JSON.Object(
        "type" => "reaction_added",
        "user" => "U333",
        "reaction" => "eyes",
        "item" => Slack.JSON.Object(
            "type" => "message",
            "channel" => "C999",
            "ts" => "1700000010.999",
        ),
    )
    private_reaction = ext._extract_reaction_event(private_reaction_payload, web_client, "", nothing, nothing, channel_type_cache)
    @test private_reaction !== nothing
    @test Agentif.is_group(Claw.get_channel(private_reaction))
    @test Agentif.is_private(Claw.get_channel(private_reaction))

    @test ext._channel_type_from_info(Dict("is_im" => true)) == "im"
    @test ext._channel_type_from_info(Dict("is_channel" => true, "is_private" => false)) == "channel"
    @test ext._channel_type_from_info(Dict("is_channel" => true, "is_private" => true)) == "group"
    @test ext._channel_type_from_info(Dict("is_mpim" => true)) == "mpim"
    @test ext._channel_type_from_info(Dict("is_group" => true)) == "group"
    @test ext._channel_type_from_info(nothing) === nothing

    # Streaming should be allowed for IM without recipient IDs, but not for channel/group.
    stream_im = ext.SlackChannel("D111", "1700000000.500", "", "", web_client, nothing, nothing, "", "", "im", nothing, nothing, "")
    Agentif.start_streaming(stream_im)
    @test stream_im.sm !== nothing
    @test stream_im.io === nothing

    stream_channel_missing_recipients = ext.SlackChannel("C111", "1700000000.600", "", "", web_client, nothing, nothing, "", "", "channel", nothing, nothing, "")
    Agentif.start_streaming(stream_channel_missing_recipients)
    @test stream_channel_missing_recipients.sm === nothing
    @test stream_channel_missing_recipients.io !== nothing

    # Outgoing message path should prefer markdown blocks and preserve markdown text.
    original_api_call_fn = ext.API_CALL_FN[]
    original_chat_post_message_fn = ext.CHAT_POST_MESSAGE_FN[]
    try
        api_calls = NamedTuple[]
        fallback_calls = NamedTuple[]
        ext.API_CALL_FN[] = function (_client, api_method; json=nothing, kwargs...)
            push!(api_calls, (api_method=String(api_method), json=json))
            return Dict{String, Any}("ok" => true, "channel" => json["channel"], "ts" => "1700000009.111")
        end
        ext.CHAT_POST_MESSAGE_FN[] = function (_client; channel, text=nothing, thread_ts=nothing, mrkdwn=nothing, parse=nothing, kwargs...)
            push!(fallback_calls, (
                channel=String(channel),
                text=text === nothing ? nothing : String(text),
                thread_ts=thread_ts === nothing ? nothing : String(thread_ts),
                mrkdwn=mrkdwn,
                parse=parse === nothing ? nothing : String(parse),
            ))
            return Dict{String, Any}("ok" => true, "channel" => String(channel), "ts" => "1700000010.222")
        end

        markdown = "# Heading\n- item\n```julia\nx = 1\n```"
        out_ch = ext.SlackChannel("C123", "", "", "", web_client, nothing, nothing, "", "", "channel", nothing, nothing, "")
        Agentif.send_message(out_ch, markdown)
        @test length(api_calls) == 1
        @test isempty(fallback_calls)
        @test api_calls[1].api_method == "chat.postMessage"
        @test api_calls[1].json["channel"] == "C123"
        @test api_calls[1].json["text"] == markdown
        @test api_calls[1].json["blocks"][1]["type"] == "markdown"
        @test api_calls[1].json["blocks"][1]["text"] == markdown
        @test out_ch.post_ts == "1700000009.111"
        @test Agentif.response_entry_id(out_ch) == "1700000009.111"

        # If markdown blocks are rejected, fallback to classic mrkdwn text.
        ext.API_CALL_FN[] = function (client, _api_method; json=nothing, kwargs...)
            resp = Slack.SlackResponse(
                client,
                "POST",
                "https://slack.com/api/chat.postMessage",
                Dict{String,Any}(),
                Slack.JSON.Object("ok" => false, "error" => "invalid_blocks"),
                Dict{String,String}(),
                200,
            )
            throw(Slack.SlackApiError("invalid blocks", resp))
        end
        threaded_ch = ext.SlackChannel("C123", "1700000000.999", "", "", web_client, nothing, nothing, "", "", "channel", nothing, nothing, "")
        Agentif.send_message(threaded_ch, markdown)
        @test length(fallback_calls) == 1
        @test fallback_calls[1].channel == "C123"
        @test fallback_calls[1].thread_ts == "1700000000.999"
        @test fallback_calls[1].text == markdown
        @test fallback_calls[1].mrkdwn == true
        @test fallback_calls[1].parse == "none"
        @test threaded_ch.post_ts == "1700000010.222"
        @test Agentif.response_entry_id(threaded_ch) == "1700000010.222"
    finally
        ext.API_CALL_FN[] = original_api_call_fn
        ext.CHAT_POST_MESSAGE_FN[] = original_chat_post_message_fn
    end

    assistant = Claw.AgentAssistant(":memory:";
        provider="openai-completions",
        model_id="gpt-4o-mini",
        apikey="test-key",
    )

    # Group non-mention message should enqueue; group prompt decides whether to stay silent.
    group_request = Slack.SocketModeRequest(
        type="events_api",
        envelope_id="env-1",
        payload=Slack.SlackEventsApiPayload(
            type="event_callback",
            event_id="evt-group-1",
            event=Slack.SlackMessageEvent(
                type="message",
                channel="C123",
                channel_type="channel",
                user="U123",
                text="hello everyone",
                ts="1700000003.111",
            ),
        ),
    )
    ext._handle_request(group_request, web_client, "", "", nothing, nothing, assistant, channel_type_cache)
    @test isready(assistant.event_queue)
    ev_group = pop_event!(assistant)
    @test ev_group isa ext.SlackMessageEvent
    @test !ev_group.direct_ping

    # app_mention callbacks are ignored to avoid duplicate processing.
    mention_request = Slack.SocketModeRequest(
        type="events_api",
        envelope_id="env-2",
        payload=Slack.SlackEventsApiPayload(
            type="event_callback",
            event_id="evt-mention-1",
            event=Slack.SlackAppMentionEvent(
                type="app_mention",
                channel="C123",
                user="U123",
                text="<@UBOT> hi",
                ts="1700000004.222",
            ),
        ),
    )
    ext._handle_request(mention_request, web_client, "UBOT", "", nothing, nothing, assistant, channel_type_cache)
    @test !isready(assistant.event_queue)

    # Mention text in a message event still triggers direct_ping.
    mention_message_request = Slack.SocketModeRequest(
        type="events_api",
        envelope_id="env-3",
        payload=Slack.SlackEventsApiPayload(
            type="event_callback",
            event_id="evt-message-mention-1",
            event=Slack.SlackMessageEvent(
                type="message",
                channel="C123",
                channel_type="channel",
                user="U123",
                text="<@UBOT> hi",
                ts="1700000005.333",
            ),
        ),
    )
    ext._handle_request(mention_message_request, web_client, "UBOT", "", nothing, nothing, assistant, channel_type_cache)
    @test isready(assistant.event_queue)
    ev = pop_event!(assistant)
    @test ev isa ext.SlackMessageEvent
    @test ev.direct_ping

    # Re-delivery of the same Slack event_id is a no-op: the durable inbox has a
    # UNIQUE dedup_key, so the second delivery inserts nothing and never wakes the
    # dispatcher. (This assertion previously encoded the redelivery bug as intent.)
    ext._handle_request(mention_message_request, web_client, "UBOT", "", nothing, nothing, assistant, channel_type_cache)
    @test !isready(assistant.event_queue)
    @test count_events(assistant, "WHERE dedup_key = ?", ("slack:evt-message-mention-1:message",)) == 1

    # Two sequential top-level messages in the same channel share one branch.
    function top_level_request(event_id, ts, text)
        return Slack.SocketModeRequest(
            type="events_api",
            envelope_id="env-$(event_id)",
            payload=Slack.SlackEventsApiPayload(
                type="event_callback",
                event_id=event_id,
                event=Slack.SlackMessageEvent(
                    type="message", channel="D777", channel_type="im",
                    user="U777", text=text, ts=ts,
                ),
            ),
        )
    end
    dm_cache = Dict("D777" => "im")
    ext._handle_request(top_level_request("evt-dm-1", "1700000100.111", "my name is Jacob"),
        web_client, "UBOT", "", nothing, nothing, assistant, dm_cache)
    first_dm = pop_event!(assistant)
    ext._handle_request(top_level_request("evt-dm-2", "1700000200.222", "what's my name?"),
        web_client, "UBOT", "", nothing, nothing, assistant, dm_cache)
    second_dm = pop_event!(assistant)
    @test Agentif.branch_id(Claw.get_channel(first_dm)) == Agentif.branch_id(Claw.get_channel(second_dm))
    @test Agentif.branch_id(Claw.get_channel(first_dm)) == "slack:D777"
    @test Agentif.parent_branch_id(Claw.get_channel(first_dm)) === nothing

    # A genuine thread reply still gets its own branch.
    thread_reply = Slack.SlackMessageEvent(
        type="message", channel="D777", channel_type="im", user="U777",
        text="in thread", ts="1700000300.333", thread_ts="1700000100.111",
    )
    thread_event = ext._extract_message_event(thread_reply, web_client, "", "", nothing, nothing, dm_cache)
    @test Agentif.channel_id(Claw.get_channel(thread_event)) == "slack:D777:1700000100.111"
    @test Agentif.parent_branch_id(Claw.get_channel(thread_event)) == "slack:D777"
    thread_row = Claw.EventRow(
        2, "slack", "slack_message", nothing,
        Agentif.channel_id(Claw.get_channel(thread_event)),
        Claw.event_content(thread_event),
        Claw.event_extra(thread_event),
        Agentif.channel_id(Claw.get_channel(thread_event)),
        1, nothing,
    )
    replayed_thread = ext._rehydrate_slack_channel(source, thread_row)
    @test replayed_thread.thread_ts == "1700000100.111"
    @test replayed_thread.source_ts == "1700000300.333"
    @test Agentif.channel_id(replayed_thread) == "slack:D777:1700000100.111"
    @test Agentif.entry_id(replayed_thread) == "1700000300.333"

    Claw.shutdown!(assistant; timeout_s=5)
end

@testset "ClawMattermostExt channel + event mapping" begin
    ext = Base.get_extension(Claw, :ClawMattermostExt)
    @test ext !== nothing
    withenv("MATTERMOST_TOKEN" => "mattermost-journal-secret") do
        detail = Claw._source_error_detail(ext.MattermostEventSource(),
            ErrorException("request used mattermost-journal-secret"))
        @test !occursin("mattermost-journal-secret", detail)
        @test occursin("[REDACTED]", detail)
    end

    source = ext.MattermostEventSource()
    @test which(Claw.stop!, (typeof(source),)).module === ext
    @test Claw.stop!(source) === nothing
    @test source._stopping[]
    event_types = Set(et.name for et in Claw.get_event_types(source))
    @test "mattermost_message" in event_types
    @test "mattermost_reaction" in event_types
    handlers = Claw.get_event_handlers(source)
    @test any(h -> h.id == "mattermost_message_default", handlers)
    @test any(h -> h.id == "mattermost_reaction_default", handlers)

    client = Mattermost.Client("test-token", "https://example.invalid/api/v4/")
    ch = ext.MattermostChannel("chan-1", "root-1", "post-1", "post-1", client, nothing, nothing, "user-1", "alice", "D", "Test Channel")

    @test Agentif.channel_id(ch) == "mattermost:chan-1:root-1"
    @test Agentif.entry_id(ch) == "post-1"
    @test !Agentif.is_group(ch)
    @test Agentif.is_private(ch)
    user = Agentif.get_current_user(ch)
    @test user !== nothing
    @test user.id == "user-1"
    @test user.name == "alice"

    # A replayed top-level event still replies under its source post. The source
    # post remains the entry id, but it does not create a separate branch.
    source.client = client
    top_ch = ext.MattermostChannel(
        "chan-top", "post-top", "post-top", "post-top", client,
        nothing, nothing, "user-top", "bob", "D", "Direct",
    )
    top_event = ext.MattermostMessageEvent(top_ch, "hello", true)
    mattermost_row = Claw.EventRow(
        1, "mattermost", "mattermost_message", nothing,
        Agentif.channel_id(top_ch),
        Claw.event_content(top_event),
        Claw.event_extra(top_event),
        Agentif.channel_id(top_ch),
        1, nothing,
    )
    replayed_mattermost = ext._rehydrate_mattermost_channel(source, mattermost_row)
    @test replayed_mattermost !== nothing
    @test replayed_mattermost.root_id == "post-top"
    @test replayed_mattermost.source_post_id == "post-top"
    @test Agentif.channel_id(replayed_mattermost) == "mattermost:chan-top"
    @test Agentif.entry_id(replayed_mattermost) == "post-top"

    assistant = Claw.AgentAssistant(":memory:";
        provider="openai-completions",
        model_id="gpt-4o-mini",
        apikey="test-key",
    )
    function drain_events!()
        while isready(assistant.event_queue)
            pop_event!(assistant)
        end
    end

    original_create_post_fn = ext.CREATE_POST_FN[]
    original_get_post_fn = ext.GET_POST_FN[]
    original_send_streaming_message_fn = ext.SEND_STREAMING_MESSAGE_FN[]
    original_stream_append_fn = ext.STREAM_APPEND_FN[]
    original_stream_flush_fn = ext.STREAM_FLUSH_FN[]
    original_stream_finish_fn = ext.STREAM_FINISH_FN[]
    try
        create_post_calls = NamedTuple[]
        stream_starts = NamedTuple[]
        ext.CREATE_POST_FN[] = function (channel_id::String, message::String; root_id=nothing, kwargs...)
            push!(create_post_calls, (
                channel_id=String(channel_id),
                message=String(message),
                root_id=root_id === nothing ? nothing : String(root_id),
            ))
            return (id="post-$(length(create_post_calls))", root_id=root_id, message=message)
        end
        ext.GET_POST_FN[] = function (_post_id::String)
            return (root_id="root-from-post", message="Original post")
        end
        ext.SEND_STREAMING_MESSAGE_FN[] = function (channel_id::String, initial_text::String="..."; min_interval::Float64=1.0, root_id=nothing, kwargs...)
            push!(stream_starts, (
                channel_id=String(channel_id),
                initial_text=String(initial_text),
                root_id=root_id === nothing ? nothing : String(root_id),
                min_interval=min_interval,
            ))
            return Mattermost.StreamingMessage(
                String(channel_id),
                "stream-post-1",
                String(initial_text),
                String(initial_text),
                time(),
                min_interval,
                false,
            )
        end
        ext.STREAM_APPEND_FN[] = function (sm, delta)
            sm.buffer *= String(delta)
            sm.pending = true
            return sm
        end
        ext.STREAM_FLUSH_FN[] = function (sm)
            sm.last_sent = sm.buffer
            sm.pending = false
            return sm
        end
        ext.STREAM_FINISH_FN[] = function (sm)
            sm.last_sent = sm.buffer
            sm.pending = false
            return sm
        end

        # Streaming uses Mattermost's streaming API, not plain IO buffering.
        stream_ch = ext.MattermostChannel("chan-stream", "root-stream", "", "", client, nothing, nothing, "", "", "D", "")
        Mattermost.with_client(client) do
            Agentif.start_streaming(stream_ch)
            Agentif.append_to_stream(stream_ch, "Hello")
            Agentif.append_to_stream(stream_ch, " world")
            Agentif.finish_streaming(stream_ch)
            Agentif.close_channel(stream_ch)
        end
        @test length(stream_starts) == 1
        @test stream_starts[1].channel_id == "chan-stream"
        @test stream_starts[1].root_id == "root-stream"
        @test stream_ch.sm === nothing
        @test stream_ch.io === nothing
        @test stream_ch.post_id == "stream-post-1"
        @test Agentif.response_entry_id(stream_ch) == "stream-post-1"

        # Outgoing send should preserve markdown text and record post_id.
        markdown = "# Heading\n- item\n```julia\nx = 1\n```"
        out_ch = ext.MattermostChannel("chan-out", "", "", "", client, nothing, nothing, "", "", "O", "")
        Mattermost.with_client(client) do
            Agentif.send_message(out_ch, markdown)
        end
        @test create_post_calls[end].channel_id == "chan-out"
        @test create_post_calls[end].message == markdown
        @test create_post_calls[end].root_id === nothing
        @test out_ch.post_id == "post-1"
        @test Agentif.response_entry_id(out_ch) == "post-1"

        threaded_out = ext.MattermostChannel("chan-out", "root-123", "", "", client, nothing, nothing, "", "", "O", "")
        Mattermost.with_client(client) do
            Agentif.send_message(threaded_out, markdown)
        end
        @test create_post_calls[end].root_id == "root-123"
        @test Agentif.response_entry_id(threaded_out) == "post-2"

        function posted_event(; user_id="U1", message="hello", channel_id="chan-top", root_id="", post_id="post-top", post_type="", sender_name="alice", channel_type="O")
            post_payload = Mattermost.JSON.Object(
                "user_id" => user_id,
                "message" => message,
                "channel_id" => channel_id,
                "root_id" => root_id,
                "id" => post_id,
                "type" => post_type,
            )
            return Mattermost.WebSocketEvent(
                "posted",
                Mattermost.JSON.Object(
                    "post" => Mattermost.JSON.json(post_payload),
                    "sender_name" => sender_name,
                    "channel_type" => channel_type,
                ),
                Mattermost.JSON.Object(),
                1,
            )
        end

        # Top-level post maps to base channel (no thread suffix).
        Mattermost.with_client(client) do
            ext._handle_posted(posted_event(), "UBOT", "claw", assistant)
        end
        @test isready(assistant.event_queue)
        ev_post = pop_event!(assistant)
        @test ev_post isa ext.MattermostMessageEvent
        @test !ev_post.direct_ping
        @test Agentif.channel_id(Claw.get_channel(ev_post)) == "mattermost:chan-top"

        # Mention in a group channel should direct-ping.
        Mattermost.with_client(client) do
            ext._handle_posted(posted_event(; message="hey @Claw please check", post_id="post-mention", sender_name="@bob"), "UBOT", "claw", assistant)
        end
        @test isready(assistant.event_queue)
        ev_mention = pop_event!(assistant)
        @test ev_mention isa ext.MattermostMessageEvent
        @test ev_mention.direct_ping
        @test Claw.event_content(ev_mention) == "[bob]: hey @Claw please check"

        # DMs always count as direct_ping.
        Mattermost.with_client(client) do
            ext._handle_posted(posted_event(; channel_type="D", post_id="post-dm"), "UBOT", "claw", assistant)
        end
        @test isready(assistant.event_queue)
        ev_dm = pop_event!(assistant)
        @test ev_dm isa ext.MattermostMessageEvent
        @test ev_dm.direct_ping

        # System posts and bot-self posts should be ignored.
        drain_events!()
        Mattermost.with_client(client) do
            ext._handle_posted(posted_event(; post_type="system_join_channel", post_id="post-system"), "UBOT", "claw", assistant)
            ext._handle_posted(posted_event(; user_id="UBOT", post_id="post-self"), "UBOT", "claw", assistant)
        end
        @test !isready(assistant.event_queue)

        # Single posted event should emit exactly one message event.
        Mattermost.with_client(client) do
            ext._handle_event(posted_event(; message="@claw hi", post_id="post-once"), "UBOT", "claw", assistant)
        end
        count = 0
        while isready(assistant.event_queue)
            pop_event!(assistant)
            count += 1
        end
        @test count == 1

        reaction_payload = Mattermost.JSON.Object(
            "user_id" => "U2",
            "emoji_name" => "thumbsup",
            "post_id" => "post-target",
        )
        reaction_event = Mattermost.WebSocketEvent(
            "reaction_added",
            Mattermost.JSON.Object("reaction" => Mattermost.JSON.json(reaction_payload)),
            Mattermost.JSON.Object("channel_id" => "chan-react"),
            2,
        )
        Mattermost.with_client(client) do
            ext._handle_reaction(reaction_event, "UBOT", assistant)
        end
        @test isready(assistant.event_queue)
        ev_reaction = pop_event!(assistant)
        @test ev_reaction isa ext.MattermostReactionEvent
        @test Agentif.channel_id(Claw.get_channel(ev_reaction)) == "mattermost:chan-react:root-from-post"
        @test occursin("thumbsup", Claw.event_content(ev_reaction))
    finally
        ext.CREATE_POST_FN[] = original_create_post_fn
        ext.GET_POST_FN[] = original_get_post_fn
        ext.SEND_STREAMING_MESSAGE_FN[] = original_send_streaming_message_fn
        ext.STREAM_APPEND_FN[] = original_stream_append_fn
        ext.STREAM_FLUSH_FN[] = original_stream_flush_fn
        ext.STREAM_FINISH_FN[] = original_stream_finish_fn
    end

    Claw.shutdown!(assistant; timeout_s=5)
end

@testset "ClawSignalExt event mapping" begin
    ext = Base.get_extension(Claw, :ClawSignalExt)
    @test ext !== nothing

    source = ext.SignalEventSource(; number="+15550000000", base_url="http://127.0.0.1:8080", auto_reconnect=false)
    @test which(Claw.stop!, (typeof(source),)).module === ext
    @test Claw.stop!(source) === nothing
    @test source._stopping[]
    event_types = Set(et.name for et in Claw.get_event_types(source))
    @test event_types == Set(["signal_message"])
    handlers = Claw.get_event_handlers(source)
    @test any(h -> h.id == "signal_message_default", handlers)

    client = Signal.Client("+15550000000", "http://127.0.0.1:8080")

    dm = Signal.DataMessage(message="hello signal", timestamp=Int64(1700000000000))
    envelope = Signal.Envelope(sourceNumber="+12223334444", sourceName="Alice", dataMessage=dm)
    msg_event = ext._envelope_to_message_event(envelope, client, "+15550000000")
    @test msg_event !== nothing
    @test Claw.get_name(msg_event) == "signal_message"
    @test Claw.event_content(msg_event) == "hello signal"
    ch = Claw.get_channel(msg_event)
    @test Agentif.channel_id(ch) == "signal:+12223334444"
    @test Agentif.entry_id(ch) == "1700000000000"
    @test Claw.event_dedup_key(msg_event) ==
        "signal:+12223334444:+12223334444:1700000000000"
    @test !Agentif.is_group(ch)
    @test Agentif.is_private(ch)
    tools = Agentif.create_channel_tools(ch)
    @test length(tools) == 1
    @test tools[1].name == "react_to_message"

    group_dm = Signal.DataMessage(
        message="group hello",
        timestamp=Int64(1700000001000),
        groupInfo=Signal.GroupInfo(groupId="abc123"),
    )
    group_envelope = Signal.Envelope(sourceNumber="+19998887777", sourceName="Bob", dataMessage=group_dm)
    group_event = ext._envelope_to_message_event(group_envelope, client, "+15550000000")
    @test group_event !== nothing
    group_channel = Claw.get_channel(group_event)
    @test startswith(group_channel.recipient, "group.")
    @test Agentif.is_group(group_channel)
    @test Claw.event_content(group_event) == "[Bob]: group hello"
    @test occursin("+19998887777:1700000001000", Claw.event_dedup_key(group_event))
    encoded = Claw._encode_payload(
        Agentif.channel_id(group_channel),
        Claw.event_content(group_event),
        Claw.event_extra(group_event),
    )
    cid, content, extra = Claw._decode_payload(encoded)
    replayed = ext._rehydrate_signal_event(
        client,
        (; channel_id=cid, content, extra, name="signal_message"),
    )
    @test replayed isa Claw.ReplayedChannelEvent
    replayed_channel = Claw.get_channel(replayed)
    @test Agentif.channel_id(replayed_channel) == Agentif.channel_id(group_channel)
    @test Agentif.is_group(replayed_channel)
    @test Agentif.get_current_user(replayed_channel).id == "+19998887777"

    no_timestamp = ext._envelope_to_message_event(
        Signal.Envelope(
            sourceNumber="+12223334444",
            dataMessage=Signal.DataMessage(message="no timestamp"),
        ),
        client,
        "+15550000000",
    )
    @test no_timestamp !== nothing
    @test Claw.event_dedup_key(no_timestamp) === nothing

    self_dm = Signal.DataMessage(message="self", timestamp=Int64(1700000002000))
    self_envelope = Signal.Envelope(sourceNumber="+15550000000", dataMessage=self_dm)
    @test ext._envelope_to_message_event(self_envelope, client, "+15550000000") === nothing
end

@testset "ClawMSTeamsExt event mapping" begin
    ext = Base.get_extension(Claw, :ClawMSTeamsExt)
    @test ext !== nothing

    source = ext.MSTeamsEventSource(; app_id="app-id", app_password="secret")
    @test which(Claw.stop!, (typeof(source),)).module === ext
    @test Claw.stop!(source) === nothing
    @test source._stopping[]
    event_types = Set(et.name for et in Claw.get_event_types(source))
    @test "msteams_message" in event_types
    @test "msteams_reaction" in event_types
    handlers = Claw.get_event_handlers(source)
    @test any(h -> h.id == "msteams_message_default", handlers)
    @test any(h -> h.id == "msteams_reaction_default", handlers)

    client = MSTeams.BotClient(; app_id="app-id", app_password="secret")

    message_activity = Dict{String, Any}(
        "type" => "message",
        "id" => "activity-1",
        "text" => "hello teams",
        "from" => Dict("id" => "user-1", "name" => "Alice"),
        "recipient" => Dict("id" => "bot-1", "name" => "Claw"),
        "conversation" => Dict("id" => "conv-1", "conversationType" => "channel"),
    )
    message_events = ext._activity_to_events(message_activity, client)
    @test length(message_events) == 1
    msg_event = only(message_events)
    @test msg_event isa ext.MSTeamsMessageEvent
    msg_channel = Claw.get_channel(msg_event)
    @test Agentif.channel_id(msg_channel) == "msteams:conv-1"
    @test Agentif.is_group(msg_channel)
    @test !Agentif.is_private(msg_channel)
    @test Agentif.entry_id(msg_channel) == "activity-1"
    @test Claw.event_content(msg_event) == "[Alice]: hello teams"
    encoded = Claw._encode_payload(
        Agentif.channel_id(msg_channel),
        Claw.event_content(msg_event),
        Claw.event_extra(msg_event),
    )
    cid, content, extra = Claw._decode_payload(encoded)
    replayed = ext._rehydrate_msteams_event(
        client,
        (; channel_id=cid, content, extra, name="msteams_message"),
    )
    @test replayed isa Claw.ReplayedChannelEvent
    replayed_channel = Claw.get_channel(replayed)
    @test Agentif.channel_id(replayed_channel) == "msteams:conv-1"
    @test Agentif.entry_id(replayed_channel) == "activity-1"
    @test Agentif.get_current_user(replayed_channel).name == "Alice"

    dm_activity = Dict{String, Any}(
        "type" => "message",
        "id" => "activity-2",
        "text" => "dm ping",
        "from" => Dict("id" => "user-2", "name" => "Dana"),
        "recipient" => Dict("id" => "bot-1", "name" => "Claw"),
        "conversation" => Dict("id" => "conv-2", "conversationType" => "personal"),
    )
    dm_event = only(ext._activity_to_events(dm_activity, client))
    @test dm_event.direct_ping

    mention_activity = Dict{String, Any}(
        "type" => "message",
        "id" => "activity-3",
        "text" => "<at>Claw</at> hello",
        "from" => Dict("id" => "user-3", "name" => "Morgan"),
        "recipient" => Dict("id" => "bot-1", "name" => "Claw"),
        "conversation" => Dict("id" => "conv-3", "conversationType" => "channel"),
        "entities" => [Dict(
            "type" => "mention",
            "mentioned" => Dict("id" => "bot-1"),
        )],
    )
    mention_event = only(ext._activity_to_events(mention_activity, client))
    @test mention_event.direct_ping

    reaction_activity = Dict{String, Any}(
        "type" => "messageReaction",
        "id" => "reaction-1",
        "replyToId" => "activity-1",
        "from" => Dict("id" => "user-4", "name" => "Riley"),
        "conversation" => Dict("id" => "conv-1", "conversationType" => "channel"),
        "reactionsAdded" => [Dict("type" => "like")],
        "reactionsRemoved" => [Dict("type" => "sad")],
    )
    reaction_events = ext._activity_to_events(reaction_activity, client)
    @test length(reaction_events) == 2
    @test count(ev -> ev isa ext.MSTeamsReactionEvent, reaction_events) == 2
    @test any(ev -> ev.action == "added" && ev.reaction == "like", reaction_events)
    @test any(ev -> ev.action == "removed" && ev.reaction == "sad", reaction_events)

    bot_message = Dict{String, Any}(
        "type" => "message",
        "id" => "activity-4",
        "text" => "bot text",
        "from" => Dict("id" => "bot-1", "name" => "Claw"),
        "recipient" => Dict("id" => "bot-1", "name" => "Claw"),
        "conversation" => Dict("id" => "conv-4", "conversationType" => "channel"),
    )
    @test isempty(ext._activity_to_events(bot_message, client))
end

@testset "ClawTelegramExt durable replay" begin
    ext = Base.get_extension(Claw, :ClawTelegramExt)
    @test ext !== nothing
    withenv("TELEGRAM_BOT_TOKEN" => "telegram-journal-secret") do
        source = ext.TelegramEventSource()
        detail = Claw._source_error_detail(source,
            ErrorException("GET https://api.telegram.org/bottelegram-journal-secret/getMe"))
        @test !occursin("telegram-journal-secret", detail)
        @test occursin("[REDACTED]", detail)
    end

    client = Telegram.Client("test-token", "https://example.invalid/")
    source = ext.TelegramEventSource(; client)
    @test which(Claw.stop!, (typeof(source),)).module === ext
    @test Claw.stop!(source) === nothing
    @test source._stopping[]
    ch = ext.TelegramChannel(
        -100123,
        Int64(42),
        client,
        IOBuffer(),
        "user-1",
        "Alice",
        "supergroup",
    )
    ev = ext.TelegramMessageEvent(ch, "hello", true)
    row = Claw.EventRow(
        1, "telegram", "telegram_message", nothing,
        Agentif.channel_id(ch),
        Claw.event_content(ev),
        Claw.event_extra(ev),
        Agentif.channel_id(ch),
        1, nothing,
    )

    replayed = ext._rehydrate_telegram_event(source, row)
    @test replayed isa Claw.ReplayedChannelEvent
    replayed_channel = Claw.get_channel(replayed)
    @test replayed_channel.chat_id == -100123
    @test replayed_channel.message_id == 42
    @test replayed_channel.user_id == "user-1"
    @test replayed_channel.user_name == "Alice"
    @test replayed_channel.chat_type == "supergroup"
    @test Agentif.entry_id(replayed_channel) == "42"
    @test !isempty(Agentif.create_channel_tools(replayed_channel))
end

end # module ExtensionTests
