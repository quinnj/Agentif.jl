#!/usr/bin/env julia

using JMAP
using Claw

const IDLE_SECONDS = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 45
const SETTLE_SECONDS = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 4

# The event queue now carries persisted `claw_events` rowids as wakeups; the event
# object itself lives in the assistant's live-event map until the dispatcher takes it.
function _take_event!(assistant::Claw.AgentAssistant)
    id = take!(assistant.event_queue)
    ev = get(assistant._live_events, id, nothing)
    ev === nothing && return nothing
    Claw._forget_live_event!(assistant, id)
    return ev
end

function _drain_events!(assistant::Claw.AgentAssistant)
    drained = Claw.Event[]
    while isready(assistant.event_queue)
        ev = _take_event!(assistant)
        ev === nothing || push!(drained, ev)
    end
    return drained
end

function _collect_events_for!(assistant::Claw.AgentAssistant, source, duration_s::Int)
    deadline = time() + duration_s
    seen = Vector{Tuple{String, String}}()
    while time() < deadline
        if isready(assistant.event_queue)
            ev = _take_event!(assistant)
            ev === nothing && continue
            name = Claw.get_name(ev)
            desc = ev isa source.JMAPNewEmailEvent ? "new_email:$(ev.email_id)" : string(typeof(ev))
            push!(seen, (name, desc))
            println("  event: ", name, " (", desc, ")")
        else
            sleep(0.2)
        end
    end
    return seen
end

function _latest_mutation_target_id(session::JMAP.Session, inbox_ids::Vector{String})
    if !isempty(inbox_ids)
        ids = JMAP.email_query_ids(session;
            filter=Dict{String,Any}("inMailbox" => inbox_ids[1]),
            sort=[Dict{String,Any}("property" => "receivedAt", "isAscending" => false)],
            limit=1)
        !isempty(ids) && return ids[1]
    end

    ids = JMAP.email_query_ids(session;
        sort=[Dict{String,Any}("property" => "receivedAt", "isAscending" => false)],
        limit=1)
    isempty(ids) && return nothing
    return ids[1]
end

function _run_mutation_smoke!(assistant::Claw.AgentAssistant, source)
    session = source._session
    session === nothing && error("No JMAP session available")
    account_id = session.mailAccountId
    account_id === nothing && error("No JMAP mail account ID available")

    inbox_ids = collect(get(() -> Set{String}(), source._inbox_mailbox_ids, account_id))
    target_id = _latest_mutation_target_id(session, inbox_ids)
    target_id === nothing && error("No email available for reversible mutation smoke")

    email = JMAP.fetch_emails(session, [target_id]; properties=["id", "keywords"])[1]
    orig_flagged = haskey(email.keywords, "\$flagged")

    println("Mutation target: ", target_id, " (orig_flagged=", orig_flagged, ")")

    # Toggle then restore $flagged; this should not generate new-email events.
    toggled_value = orig_flagged ? nothing : true
    JMAP.email_set(session;
        update=Dict{String,Dict{String,Any}}(
            target_id => Dict{String,Any}("keywords/\$flagged" => toggled_value),
        ))
    sleep(SETTLE_SECONDS)
    first_phase = _drain_events!(assistant)

    restored_value = orig_flagged ? true : nothing
    JMAP.email_set(session;
        update=Dict{String,Dict{String,Any}}(
            target_id => Dict{String,Any}("keywords/\$flagged" => restored_value),
        ))
    sleep(SETTLE_SECONDS)
    second_phase = _drain_events!(assistant)

    return vcat(first_phase, second_phase)
end

function _names(events)
    return [Claw.get_name(ev) for ev in events]
end

function main()
    token = get(ENV, "JMAP_API_TOKEN", get(ENV, "FASTMAIL_API_KEY", ""))
    isempty(token) && error("Set JMAP_API_TOKEN or FASTMAIL_API_KEY")

    ext = Base.get_extension(Claw, :ClawJMAPExt)
    ext === nothing && error("ClawJMAPExt not loaded; ensure JMAP is in project deps")

    println("=== ClawJMAPExt Readiness Smoke ===")
    println("Idle phase: ", IDLE_SECONDS, "s")
    println("Mutation settle per step: ", SETTLE_SECONDS, "s")

    assistant = Claw.AgentAssistant(":memory:";
        provider="openai-completions",
        model_id="gpt-4o-mini",
        apikey="test-key",
    )

    source = ext.FastmailEventSource(; token=token)
    Claw.start!(source, assistant)

    try
        sleep(2)
        _drain_events!(assistant)

        println("\n[1/2] Idle event watch...")
        idle_seen = _collect_events_for!(assistant, ext, IDLE_SECONDS)

        idle_unexpected = [(name, desc) for (name, desc) in idle_seen if name != "jmap_new_email"]

        println("\n[2/2] Reversible local-mutation check...")
        mutation_events = _run_mutation_smoke!(assistant, source)
        mutation_names = _names(mutation_events)
        mutation_unexpected = [name for name in mutation_names if name != "jmap_new_email"]

        println("\n=== Summary ===")
        println("Idle events: ", length(idle_seen))
        println("Mutation-phase events: ", length(mutation_events))
        println("Idle unexpected event types: ", isempty(idle_unexpected) ? "none" : join([x[1] for x in idle_unexpected], ", "))
        println("Mutation unexpected event types: ", isempty(mutation_unexpected) ? "none" : join(mutation_unexpected, ", "))

        ok = isempty(idle_unexpected) && isempty(mutation_unexpected) && isempty(mutation_events)
        if ok
            println("\nPASS: only `jmap_new_email` is observable and local mutations emitted no events.")
            return 0
        end

        println("\nFAIL: smoke checks did not meet readiness criteria.")
        return 1
    finally
        close(assistant.db)
    end
end

exit(main())
