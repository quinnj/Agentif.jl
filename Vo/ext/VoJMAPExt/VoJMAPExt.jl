module VoJMAPExt

using JMAP
import Agentif
import Vo

export FastmailEventSource

# ─── Helpers ───

function _fmt_addrs(addrs)
    addrs === nothing && return ""
    parts = String[]
    for a in addrs
        push!(parts, a.name !== nothing && !isempty(a.name) ? "$(a.name) <$(a.email)>" : a.email)
    end
    return join(parts, ", ")
end

function _parse_addrs(s::String)
    return [Dict{String,Any}("email" => strip(a)) for a in split(s, ",") if !isempty(strip(a))]
end

# ─── Event ───

struct JMAPNewEmailEvent <: Vo.Event
    account_id::String
    email_id::String
    thread_id::Union{Nothing, String}
    mailbox_ids::Vector{String}
    from::String
    subject::String
    received_at::String
    preview::String
    unread::Bool
    has_attachment::Bool
end

Vo.get_name(::JMAPNewEmailEvent) = "jmap_new_email"

function Vo.event_content(ev::JMAPNewEmailEvent)
    lines = String[
        "[JMAP new email arrived]",
        "Account: $(ev.account_id)",
        "Email ID: $(ev.email_id)",
        "Thread ID: $(something(ev.thread_id, "(none)"))",
        "From: $(ev.from)",
        "Subject: $(ev.subject)",
        "Received: $(ev.received_at)",
    ]
    !isempty(ev.mailbox_ids) && push!(lines, "Mailbox IDs: $(join(ev.mailbox_ids, ", "))")
    flags = String[]
    ev.unread && push!(flags, "UNREAD")
    ev.has_attachment && push!(flags, "ATTACHMENT")
    !isempty(flags) && push!(lines, "Flags: $(join(flags, ", "))")
    !isempty(ev.preview) && push!(lines, "Preview: $(ev.preview)")
    return join(lines, "\n")
end

# ─── Event types ───

const NEW_EMAIL_EVENT_TYPE = Vo.EventType(
    "jmap_new_email",
    "A new email arrived in the inbox",
)

# ─── Session holder (set during start!) ───

const JMAP_SESSION = Ref{Union{Nothing, JMAP.Session}}(nothing)

function _get_session()
    s = JMAP_SESSION[]
    s === nothing && error("No JMAP session initialized. Is FastmailEventSource started?")
    return s
end

# ─── EventSource ───

Base.@kwdef mutable struct FastmailEventSource <: Vo.EventSource
    token::String = get(ENV, "JMAP_API_TOKEN", "")
    session_url::String = get(ENV, "JMAP_SESSION_URL", "")
    types::String = "*"
    ping::Int = 30
    _states::Dict{String, Dict{String, String}} = Dict{String, Dict{String, String}}()
    _inbox_mailbox_ids::Dict{String, Set{String}} = Dict{String, Set{String}}()
    _lock::ReentrantLock = ReentrantLock()
    _session::Union{Nothing, JMAP.Session} = nothing
end

Vo.get_event_types(::FastmailEventSource) = Vo.EventType[NEW_EMAIL_EVENT_TYPE]
Vo.get_channels(::FastmailEventSource) = Agentif.AbstractChannel[]
Vo.get_event_handlers(::FastmailEventSource) = Vo.EventHandler[]
Vo.get_tools(::FastmailEventSource) = JMAP_TOOLS

# ─── Changes dispatch ───

const EMAIL_CHANGES_FN = Ref{Function}(JMAP.email_changes)
const FETCH_EMAILS_FN = Ref{Function}(JMAP.fetch_emails)
const LIST_MAILBOXES_FN = Ref{Function}(JMAP.list_mailboxes)

function _mailbox_ids(email::JMAP.Email)
    ids = String[]
    for (mailbox_id, present) in email.mailboxIds
        present && push!(ids, mailbox_id)
    end
    return ids
end

function _refresh_mailbox_cache!(source::FastmailEventSource, session::JMAP.Session, account_id::String)
    try
        mailboxes = LIST_MAILBOXES_FN[](session; account_id=account_id)
        inbox_ids = Set{String}()
        for mb in mailboxes
            role = something(mb.role, "")
            role == "inbox" && push!(inbox_ids, mb.id)
        end
        lock(source._lock) do
            source._inbox_mailbox_ids[account_id] = inbox_ids
        end
        isempty(inbox_ids) && @warn "VoJMAPExt: no inbox mailbox role found; new-email events will be skipped until resolved" account=account_id
    catch e
        @warn "VoJMAPExt: failed to refresh mailbox cache" account=account_id exception=(e, catch_backtrace())
    end
    return
end

function _ensure_inbox_mailboxes!(source::FastmailEventSource, session::JMAP.Session, account_id::String)
    has_inbox = lock(source._lock) do
        haskey(source._inbox_mailbox_ids, account_id) && !isempty(source._inbox_mailbox_ids[account_id])
    end
    has_inbox && return
    _refresh_mailbox_cache!(source, session, account_id)
    return
end

function _is_in_inbox(source::FastmailEventSource, account_id::String, mailbox_ids::Vector{String})
    lock(source._lock) do
        inbox_ids = get(() -> Set{String}(), source._inbox_mailbox_ids, account_id)
        isempty(inbox_ids) && return false
        for mailbox_id in mailbox_ids
            mailbox_id in inbox_ids && return true
        end
        return false
    end
end

function _dedupe_ids(ids::Vector{String})
    seen = Set{String}()
    out = String[]
    for id in ids
        id in seen && continue
        push!(seen, id)
        push!(out, id)
    end
    return out
end

function _fetch_created_email_ids(session::JMAP.Session, since_state::String, account_id::String)
    created = String[]
    cursor = since_state
    final_state = since_state
    max_pages = 20

    for page in 1:max_pages
        resp = EMAIL_CHANGES_FN[](session, cursor; account_id=account_id)
        append!(created, resp.created)
        final_state = resp.newState
        cursor = resp.newState
        !resp.hasMoreChanges && return _dedupe_ids(created), final_state
        page == max_pages && @warn "VoJMAPExt: reached max Email/changes pages while collecting created IDs" account=account_id pages=max_pages
    end

    return _dedupe_ids(created), final_state
end

function _fetch_created_emails(session::JMAP.Session, account_id::String, ids::Vector{String})
    isempty(ids) && return JMAP.Email[]
    return FETCH_EMAILS_FN[](session, ids;
        account_id=account_id,
        properties=["id", "threadId", "mailboxIds", "keywords", "from", "subject", "receivedAt", "preview", "hasAttachment"])
end

function _handle_state_change!(source::FastmailEventSource, assistant::Vo.AgentAssistant, sc::JMAP.StateChange)
    session = source._session
    session === nothing && return

    for (account_id, type_states) in sc.changed
        email_state = get(() -> "", type_states, "Email")
        isempty(email_state) && continue

        account_states = get!(() -> Dict{String,String}(), source._states, account_id)
        old_state = get(() -> "", account_states, "Email")
        email_state == old_state && continue

        # First observation is baseline seeding, not an event.
        if isempty(old_state)
            account_states["Email"] = email_state
            continue
        end

        created_ids, resolved_state = try
            _fetch_created_email_ids(session, old_state, account_id)
        catch e
            @warn "VoJMAPExt: failed to fetch Email/changes" account=account_id exception=(e, catch_backtrace())
            account_states["Email"] = email_state
            continue
        end

        account_states["Email"] = resolved_state
        isempty(created_ids) && continue

        _ensure_inbox_mailboxes!(source, session, account_id)
        emails = try
            _fetch_created_emails(session, account_id, created_ids)
        catch e
            @warn "VoJMAPExt: failed to fetch created email details" account=account_id count=length(created_ids) exception=(e, catch_backtrace())
            JMAP.Email[]
        end

        for email in emails
            mailbox_ids = _mailbox_ids(email)
            _is_in_inbox(source, account_id, mailbox_ids) || continue

            from_str = _fmt_addrs(email.from)
            isempty(from_str) && (from_str = "(unknown)")
            ev = JMAPNewEmailEvent(
                account_id,
                email.id,
                email.threadId,
                mailbox_ids,
                from_str,
                something(email.subject, "(no subject)"),
                something(email.receivedAt, "(unknown)"),
                something(email.preview, ""),
                !haskey(email.keywords, "\$seen"),
                email.hasAttachment === true,
            )
            @info "VoJMAPExt: new email arrived" account=account_id email_id=email.id thread_id=email.threadId
            put!(assistant.event_queue, ev)
        end
    end
end

# ─── SSE loop ───

function _sse_loop(source::FastmailEventSource, assistant::Vo.AgentAssistant)
    session = source._session
    session === nothing && error("VoJMAPExt: no JMAP session")

    backoff = 1.0
    max_backoff = 60.0

    while true
        try
            @info "VoJMAPExt: connecting to SSE" types=source.types ping=source.ping
            JMAP.listen_events(session; types=source.types, ping=source.ping) do sc::JMAP.StateChange
                backoff = 1.0  # reset on successful event
                _handle_state_change!(source, assistant, sc)
            end
        catch e
            if e isa InterruptException
                @info "VoJMAPExt: SSE interrupted"
                break
            end
            @warn "VoJMAPExt: SSE connection error, reconnecting in $(backoff)s" exception=(e, catch_backtrace())
            sleep(backoff)
            backoff = min(backoff * 2, max_backoff)
        end
    end
end

# ─── Initial state seeding ───

function _seed_initial_states!(source::FastmailEventSource)
    session = source._session
    session === nothing && return
    account_id = session.mailAccountId
    account_id === nothing && return

    account_states = get!(() -> Dict{String,String}(), source._states, account_id)

    try
        resp = JMAP.email_get(session; account_id=account_id, ids=String[])
        account_states["Email"] = resp.state
    catch e
        @warn "VoJMAPExt: failed to seed Email state" exception=(e, catch_backtrace())
    end

    _refresh_mailbox_cache!(source, session, account_id)

    inbox_count = lock(source._lock) do
        length(get(() -> Set{String}(), source._inbox_mailbox_ids, account_id))
    end
    @info "VoJMAPExt: seeded initial state" account=account_id email_state_seeded=haskey(account_states, "Email") inbox_mailbox_count=inbox_count
end

# ─── start! ───

function Vo.start!(source::FastmailEventSource, assistant::Vo.AgentAssistant)
    token = String(strip(source.token))
    isempty(token) && error("VoJMAPExt: JMAP_API_TOKEN not set")

    session_url = String(strip(source.session_url))
    session = if isempty(session_url)
        JMAP.Session(token=token)
    else
        JMAP.Session(token=token, session_url=session_url)
    end

    source._session = session
    JMAP_SESSION[] = session
    lock(source._lock) do
        empty!(source._states)
        empty!(source._inbox_mailbox_ids)
    end

    _seed_initial_states!(source)

    errormonitor(Threads.@spawn begin
        _sse_loop(source, assistant)
    end)
end
# ═══════════════════════════════════════════════════════════
# Tools
# ═══════════════════════════════════════════════════════════

# ─── email_search ───

const EMAIL_SEARCH_TOOL = Agentif.@tool "Search emails by text query, sender, subject, date range, mailbox, or keywords. Returns matching email summaries sorted by date." function email_search(
        query::Union{Nothing, String} = nothing,
        from::Union{Nothing, String} = nothing,
        to::Union{Nothing, String} = nothing,
        subject::Union{Nothing, String} = nothing,
        in_mailbox::Union{Nothing, String} = nothing,
        after::Union{Nothing, String} = nothing,
        before::Union{Nothing, String} = nothing,
        has_keyword::Union{Nothing, String} = nothing,
        not_keyword::Union{Nothing, String} = nothing,
        limit::Union{Nothing, Int} = nothing
    )
    session = _get_session()
    n = limit === nothing ? 20 : min(limit, 50)

    filter = Dict{String,Any}()
    query !== nothing && (filter["text"] = query)
    from !== nothing && (filter["from"] = from)
    to !== nothing && (filter["to"] = to)
    subject !== nothing && (filter["subject"] = subject)
    in_mailbox !== nothing && (filter["inMailbox"] = in_mailbox)
    after !== nothing && (filter["after"] = after)
    before !== nothing && (filter["before"] = before)
    has_keyword !== nothing && (filter["hasKeyword"] = has_keyword)
    not_keyword !== nothing && (filter["notKeyword"] = not_keyword)

    sort = [Dict{String,Any}("property" => "receivedAt", "isAscending" => false)]
    ids = JMAP.email_query_ids(session; filter=isempty(filter) ? nothing : filter, sort=sort, limit=n)
    isempty(ids) && return "No emails found matching the search criteria."

    emails = JMAP.fetch_emails(session, ids;
        properties=["id", "threadId", "mailboxIds", "keywords", "from", "to", "subject", "receivedAt", "preview", "hasAttachment"])

    lines = String[]
    for e in emails
        from_str = _fmt_addrs(e.from)
        isempty(from_str) && (from_str = "(unknown)")
        flags = String[]
        haskey(e.keywords, "\$seen") || push!(flags, "UNREAD")
        haskey(e.keywords, "\$flagged") && push!(flags, "FLAGGED")
        haskey(e.keywords, "\$muted") && push!(flags, "MUTED")
        e.hasAttachment === true && push!(flags, "ATTACHMENT")
        flag_str = isempty(flags) ? "" : " [$(join(flags, ", "))]"

        push!(lines, "ID: $(e.id) | Thread: $(something(e.threadId, "?"))$flag_str")
        push!(lines, "  From: $from_str")
        push!(lines, "  Subject: $(something(e.subject, "(no subject)"))")
        push!(lines, "  Date: $(something(e.receivedAt, "?"))")
        push!(lines, "  Preview: $(something(e.preview, ""))")
        push!(lines, "")
    end
    return join(lines, "\n")
end

# ─── email_read ───

const EMAIL_READ_TOOL = Agentif.@tool "Read the full content of an email by its ID. Returns headers, body text, and attachment info." function email_read(email_id::String)
    session = _get_session()
    emails = JMAP.fetch_emails(session, [email_id];
        properties=["id", "threadId", "mailboxIds", "keywords", "from", "to", "cc", "bcc",
                     "replyTo", "subject", "sentAt", "receivedAt", "messageId", "inReplyTo",
                     "references", "hasAttachment", "preview", "textBody", "htmlBody",
                     "attachments", "bodyValues"],
        fetch_text_body_values=true,
        max_body_value_bytes=256_000)
    isempty(emails) && return "Email not found: $email_id"
    e = emails[1]

    lines = String[]
    push!(lines, "ID: $(e.id)")
    push!(lines, "Thread: $(something(e.threadId, "?"))")
    push!(lines, "From: $(_fmt_addrs(e.from))")
    push!(lines, "To: $(_fmt_addrs(e.to))")
    e.cc !== nothing && !isempty(e.cc) && push!(lines, "Cc: $(_fmt_addrs(e.cc))")
    push!(lines, "Subject: $(something(e.subject, "(no subject)"))")
    push!(lines, "Date: $(something(e.sentAt, something(e.receivedAt, "?")))")

    flags = String[]
    haskey(e.keywords, "\$seen") || push!(flags, "UNREAD")
    haskey(e.keywords, "\$flagged") && push!(flags, "FLAGGED")
    haskey(e.keywords, "\$answered") && push!(flags, "ANSWERED")
    haskey(e.keywords, "\$draft") && push!(flags, "DRAFT")
    haskey(e.keywords, "\$muted") && push!(flags, "MUTED")
    !isempty(flags) && push!(lines, "Flags: $(join(flags, ", "))")
    push!(lines, "")

    if !isempty(e.textBody)
        for part in e.textBody
            bv = get(e.bodyValues, part.partId, nothing)
            if bv !== nothing
                push!(lines, bv.value)
                bv.isTruncated && push!(lines, "[body truncated]")
            end
        end
    else
        push!(lines, "(no text body)")
    end

    if !isempty(e.attachments)
        push!(lines, "")
        push!(lines, "Attachments:")
        for att in e.attachments
            name = something(att.name, "(unnamed)")
            size_str = att.size !== nothing ? " ($(att.size) bytes)" : ""
            push!(lines, "  - $name$size_str [$(something(att.type, "?"))]")
        end
    end

    return join(lines, "\n")
end

# ─── email_send ───

const EMAIL_SEND_TOOL = Agentif.@tool "Compose and send a new email. Provide to address(es) comma-separated, subject, and body text." function email_send(
        to::String,
        subject::String,
        body::String,
        cc::Union{Nothing, String} = nothing,
        bcc::Union{Nothing, String} = nothing
    )
    session = _get_session()

    identities = JMAP.list_identities(session)
    isempty(identities) && return "Error: no sending identities configured"
    identity = identities[1]

    mailboxes = JMAP.list_mailboxes(session)
    drafts_mb = nothing
    sent_mb = nothing
    for mb in mailboxes
        mb.role == "drafts" && (drafts_mb = mb)
        mb.role == "sent" && (sent_mb = mb)
    end
    drafts_mb === nothing && return "Error: no Drafts mailbox found"

    draft = Dict{String,Any}(
        "from" => [Dict{String,Any}("name" => identity.name, "email" => identity.email)],
        "to" => _parse_addrs(to),
        "subject" => subject,
        "textBody" => [Dict{String,Any}("partId" => "body", "type" => "text/plain")],
        "bodyValues" => Dict{String,Any}("body" => Dict{String,Any}("value" => body)),
        "mailboxIds" => Dict{String,Any}(drafts_mb.id => true),
        "keywords" => Dict{String,Any}("\$seen" => true),
    )
    cc !== nothing && (draft["cc"] = _parse_addrs(cc))
    bcc !== nothing && (draft["bcc"] = _parse_addrs(bcc))

    create_id = "draft1"
    set_resp = JMAP.email_set(session; create=Dict{String,Any}(create_id => draft))
    created = set_resp.created
    (created === nothing || !haskey(created, create_id)) && return "Error: failed to create draft — $(something(set_resp.notCreated, "unknown error"))"
    email_id = created[create_id].id

    submission = Dict{String,Any}(
        "sub1" => Dict{String,Any}(
            "emailId" => email_id,
            "identityId" => identity.id,
        )
    )
    on_success = if sent_mb !== nothing
        Dict{String,Any}("#sub1" => Dict{String,Any}(
            "mailboxIds/$(drafts_mb.id)" => nothing,
            "mailboxIds/$(sent_mb.id)" => true,
            "keywords/\$draft" => nothing,
        ))
    else
        nothing
    end

    JMAP.email_submission_set(session; create=submission, on_success_update_email=on_success)
    return "Email sent to $to (subject: $subject)"
end

# ─── email_reply ───

const EMAIL_REPLY_TOOL = Agentif.@tool "Reply to an email by its ID. Automatically threads the reply and sets In-Reply-To headers. Set reply_all to 'true' to reply to all recipients." function email_reply(
        email_id::String,
        body::String,
        reply_all::Union{Nothing, String} = nothing
    )
    session = _get_session()
    originals = JMAP.fetch_emails(session, [email_id];
        properties=["id", "from", "to", "cc", "replyTo", "subject", "messageId", "references", "threadId"])
    isempty(originals) && return "Email not found: $email_id"
    orig = originals[1]

    identities = JMAP.list_identities(session)
    isempty(identities) && return "Error: no sending identities configured"
    identity = identities[1]
    my_email = lowercase(identity.email)

    reply_to = orig.replyTo !== nothing && !isempty(orig.replyTo) ? orig.replyTo : orig.from
    to_addrs = reply_to !== nothing ? join([a.email for a in reply_to], ",") : ""
    isempty(to_addrs) && return "Error: cannot determine reply address"

    cc_addrs = nothing
    if reply_all == "true" || reply_all == "yes"
        all_ccs = String[]
        for addrs in [orig.to, orig.cc]
            addrs === nothing && continue
            for a in addrs
                lowercase(a.email) == my_email && continue
                push!(all_ccs, a.email)
            end
        end
        !isempty(all_ccs) && (cc_addrs = join(all_ccs, ","))
    end

    subj = something(orig.subject, "")
    startswith(lowercase(subj), "re:") || (subj = "Re: $subj")

    # Build threaded draft
    mailboxes = JMAP.list_mailboxes(session)
    drafts_mb = nothing
    sent_mb = nothing
    for mb in mailboxes
        mb.role == "drafts" && (drafts_mb = mb)
        mb.role == "sent" && (sent_mb = mb)
    end
    drafts_mb === nothing && return "Error: no Drafts mailbox found"

    draft = Dict{String,Any}(
        "from" => [Dict{String,Any}("name" => identity.name, "email" => identity.email)],
        "to" => _parse_addrs(to_addrs),
        "subject" => subj,
        "textBody" => [Dict{String,Any}("partId" => "body", "type" => "text/plain")],
        "bodyValues" => Dict{String,Any}("body" => Dict{String,Any}("value" => body)),
        "mailboxIds" => Dict{String,Any}(drafts_mb.id => true),
        "keywords" => Dict{String,Any}("\$seen" => true),
    )
    cc_addrs !== nothing && (draft["cc"] = _parse_addrs(cc_addrs))

    # Threading headers
    if orig.messageId !== nothing
        draft["inReplyTo"] = orig.messageId
        refs = String[]
        orig.references !== nothing && append!(refs, orig.references)
        append!(refs, orig.messageId)
        draft["references"] = refs
    end

    create_id = "reply1"
    set_resp = JMAP.email_set(session; create=Dict{String,Any}(create_id => draft))
    created = set_resp.created
    (created === nothing || !haskey(created, create_id)) && return "Error: failed to create reply draft"
    new_email_id = created[create_id].id

    submission = Dict{String,Any}(
        "sub1" => Dict{String,Any}(
            "emailId" => new_email_id,
            "identityId" => identity.id,
        )
    )
    on_success = if sent_mb !== nothing
        Dict{String,Any}("#sub1" => Dict{String,Any}(
            "mailboxIds/$(drafts_mb.id)" => nothing,
            "mailboxIds/$(sent_mb.id)" => true,
            "keywords/\$draft" => nothing,
        ))
    else
        nothing
    end

    JMAP.email_submission_set(session; create=submission, on_success_update_email=on_success)
    return "Reply sent (subject: $subj)"
end

# ─── email_forward ───

const EMAIL_FORWARD_TOOL = Agentif.@tool "Forward an email to new recipients. Optionally add a comment above the forwarded content." function email_forward(
        email_id::String,
        to::String,
        comment::Union{Nothing, String} = nothing
    )
    session = _get_session()
    originals = JMAP.fetch_emails(session, [email_id];
        properties=["id", "from", "to", "subject", "sentAt", "textBody", "bodyValues"],
        fetch_text_body_values=true,
        max_body_value_bytes=256_000)
    isempty(originals) && return "Email not found: $email_id"
    orig = originals[1]

    orig_body = ""
    if !isempty(orig.textBody)
        for part in orig.textBody
            bv = get(orig.bodyValues, part.partId, nothing)
            bv !== nothing && (orig_body *= bv.value)
        end
    end

    fwd_body = string(
        comment !== nothing ? "$comment\n\n" : "",
        "---------- Forwarded message ----------\n",
        "From: $(_fmt_addrs(orig.from))\n",
        "Date: $(something(orig.sentAt, "?"))\n",
        "Subject: $(something(orig.subject, "(no subject)"))\n",
        "To: $(_fmt_addrs(orig.to))\n\n",
        orig_body
    )

    subj = something(orig.subject, "")
    startswith(lowercase(subj), "fwd:") || (subj = "Fwd: $subj")

    return email_send(to, subj, fwd_body, nothing, nothing)
end

# ─── email_move ───

const EMAIL_MOVE_TOOL = Agentif.@tool "Move an email to a different mailbox. Use list_mailboxes to find mailbox IDs." function email_move(email_id::String, target_mailbox_id::String)
    session = _get_session()
    JMAP.email_set(session;
        update=Dict{String,Dict{String,Any}}(email_id => Dict{String,Any}("mailboxIds" => Dict{String,Any}(target_mailbox_id => true))))
    return "Moved email $email_id to mailbox $target_mailbox_id"
end

# ─── email_archive ───

const EMAIL_ARCHIVE_TOOL = Agentif.@tool "Archive an email by moving it to the Archive mailbox." function email_archive(email_id::String)
    session = _get_session()
    mailboxes = JMAP.list_mailboxes(session)
    archive_mb = nothing
    for mb in mailboxes
        mb.role == "archive" && (archive_mb = mb; break)
    end
    archive_mb === nothing && return "Error: no Archive mailbox found"
    JMAP.email_set(session;
        update=Dict{String,Dict{String,Any}}(email_id => Dict{String,Any}("mailboxIds" => Dict{String,Any}(archive_mb.id => true))))
    return "Archived email $email_id"
end

# ─── email_trash ───

const EMAIL_TRASH_TOOL = Agentif.@tool "Move an email to the Trash mailbox." function email_trash(email_id::String)
    session = _get_session()
    mailboxes = JMAP.list_mailboxes(session)
    trash_mb = nothing
    for mb in mailboxes
        mb.role == "trash" && (trash_mb = mb; break)
    end
    trash_mb === nothing && return "Error: no Trash mailbox found"
    JMAP.email_set(session;
        update=Dict{String,Dict{String,Any}}(email_id => Dict{String,Any}("mailboxIds" => Dict{String,Any}(trash_mb.id => true))))
    return "Trashed email $email_id"
end

# ─── email_flag ───

const EMAIL_FLAG_TOOL = Agentif.@tool "Set or clear a keyword flag on an email. Common keywords: \$seen (read), \$flagged (starred), \$answered, \$draft. Set action to 'set' or 'clear'." function email_flag(email_id::String, keyword::String, action::String)
    session = _get_session()
    value = lowercase(action) == "set" ? true : nothing
    JMAP.email_set(session;
        update=Dict{String,Dict{String,Any}}(email_id => Dict{String,Any}("keywords/$keyword" => value)))
    act_past = lowercase(action) == "set" ? "Set" : "Cleared"
    return "$act_past keyword '$keyword' on email $email_id"
end

# ─── email_mark_read ───

const EMAIL_MARK_READ_TOOL = Agentif.@tool "Mark one or more emails as read. Provide comma-separated email IDs." function email_mark_read(email_ids::String)
    session = _get_session()
    ids = strip.(split(email_ids, ","))
    updates = Dict{String,Dict{String,Any}}()
    for id in ids
        updates[id] = Dict{String,Any}("keywords/\$seen" => true)
    end
    JMAP.email_set(session; update=updates)
    return "Marked $(length(ids)) email(s) as read"
end

# ─── list_mailboxes ───

const LIST_MAILBOXES_TOOL = Agentif.@tool "List all email mailboxes (folders) with their IDs, names, roles, and unread counts." function jmap_list_mailboxes()
    session = _get_session()
    mailboxes = JMAP.list_mailboxes(session)
    lines = String[]
    for mb in sort(mailboxes; by=m -> something(m.sortOrder, 999))
        role_str = mb.role !== nothing ? " ($(mb.role))" : ""
        unread = something(mb.unreadEmails, 0)
        total = something(mb.totalEmails, 0)
        push!(lines, "- $(mb.name)$role_str [id: $(mb.id)] ($unread unread / $total total)")
    end
    isempty(lines) ? "No mailboxes found" : join(lines, "\n")
end

# ─── email_thread ───

const EMAIL_THREAD_TOOL = Agentif.@tool "Get all emails in a thread by thread ID. Returns the full conversation." function email_thread(thread_id::String)
    session = _get_session()
    thread_resp = JMAP.thread_get(session; ids=[thread_id])
    isempty(thread_resp.list) && return "Thread not found: $thread_id"
    email_ids = thread_resp.list[1].emailIds
    isempty(email_ids) && return "Thread has no emails"

    emails = JMAP.fetch_emails(session, email_ids;
        properties=["id", "from", "to", "subject", "receivedAt", "preview", "keywords"])

    lines = String["Thread $thread_id ($(length(emails)) emails):", ""]
    for e in emails
        from_str = _fmt_addrs(e.from)
        isempty(from_str) && (from_str = "?")
        push!(lines, "[$from_str] $(something(e.subject, "(no subject)")) — $(something(e.receivedAt, "?"))")
        push!(lines, "  ID: $(e.id)")
        push!(lines, "  Preview: $(something(e.preview, ""))")
        push!(lines, "")
    end
    return join(lines, "\n")
end

# ─── email_mute_thread ───

const EMAIL_MUTE_THREAD_TOOL = Agentif.@tool "Mute an email thread. New replies will be auto-archived and marked as read by Fastmail." function email_mute_thread(thread_id::String)
    session = _get_session()
    thread_resp = JMAP.thread_get(session; ids=[thread_id])
    isempty(thread_resp.list) && return "Thread not found: $thread_id"
    email_ids = thread_resp.list[1].emailIds
    isempty(email_ids) && return "Thread has no emails"

    updates = Dict{String,Dict{String,Any}}()
    for id in email_ids
        updates[id] = Dict{String,Any}("keywords/\$muted" => true)
    end
    JMAP.email_set(session; update=updates)
    return "Muted thread $thread_id ($(length(email_ids)) emails). New replies will be auto-archived."
end

# ─── email_unmute_thread ───

const EMAIL_UNMUTE_THREAD_TOOL = Agentif.@tool "Unmute an email thread. New replies will arrive in inbox normally." function email_unmute_thread(thread_id::String)
    session = _get_session()
    thread_resp = JMAP.thread_get(session; ids=[thread_id])
    isempty(thread_resp.list) && return "Thread not found: $thread_id"
    email_ids = thread_resp.list[1].emailIds
    isempty(email_ids) && return "Thread has no emails"

    updates = Dict{String,Dict{String,Any}}()
    for id in email_ids
        updates[id] = Dict{String,Any}("keywords/\$muted" => nothing)
    end
    JMAP.email_set(session; update=updates)
    return "Unmuted thread $thread_id ($(length(email_ids)) emails)"
end

# ─── Tools vector ───

const JMAP_TOOLS = Agentif.AgentTool[
    EMAIL_SEARCH_TOOL,
    EMAIL_READ_TOOL,
    EMAIL_SEND_TOOL,
    EMAIL_REPLY_TOOL,
    EMAIL_FORWARD_TOOL,
    EMAIL_MOVE_TOOL,
    EMAIL_ARCHIVE_TOOL,
    EMAIL_TRASH_TOOL,
    EMAIL_FLAG_TOOL,
    EMAIL_MARK_READ_TOOL,
    LIST_MAILBOXES_TOOL,
    EMAIL_THREAD_TOOL,
    EMAIL_MUTE_THREAD_TOOL,
    EMAIL_UNMUTE_THREAD_TOOL,
]

end # module VoJMAPExt
