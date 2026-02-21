# HeartbeatPollSource — canonical PollSource example
#
# Usage:
#   include("path/to/heartbeat_poll_source.jl")
#   hb = HeartbeatPollSource(interval_minutes=30)
#   Vo.run(; name="ando", event_sources=Vo.EventSource[hb])

using Dates

const HEARTBEAT_START_HOUR = 6
const HEARTBEAT_END_HOUR = 23
const HEARTBEAT_MINUTE = 0
const DEFAULT_HEARTBEAT_INTERVAL = 30

mutable struct HeartbeatPollSource <: Vo.PollSource
    name::String
    interval_minutes::Int
    start_hour::Int
    end_hour::Int
    last_response_hash::UInt64
    last_response_time::Float64
end

function HeartbeatPollSource(;
        name::String = "heartbeat",
        interval_minutes::Int = DEFAULT_HEARTBEAT_INTERVAL,
        start_hour::Int = HEARTBEAT_START_HOUR,
        end_hour::Int = HEARTBEAT_END_HOUR,
    )
    HeartbeatPollSource(name, interval_minutes, start_hour, end_hour, UInt64(0), 0.0)
end

function Vo.get_schedule(h::HeartbeatPollSource)
    offset_minutes = Vo.local_utc_offset_minutes()
    heartbeat_schedule(offset_minutes, h.interval_minutes)
end

function Vo.get_system_prompt(h::HeartbeatPollSource)
    a = Vo.get_current_assistant()
    a === nothing && return ""
    Vo.kv_get(a.db, "heartbeat_tasks", "")
end

function Vo.update_system_prompt!(h::HeartbeatPollSource, prompt::String)
    a = Vo.get_current_assistant()
    a === nothing && return nothing
    Vo.kv_set!(a.db, "heartbeat_tasks", prompt)
    return nothing
end

function Vo.scheduled_evaluate(h::HeartbeatPollSource)
    local_time = Dates.now()
    local_hour = Dates.hour(local_time)
    if local_hour < h.start_hour || local_hour > h.end_hour
        return nothing
    end
    first_heartbeat = local_hour == h.start_hour
    last_heartbeat = local_hour == h.end_hour
    tasks = Vo.get_system_prompt(h)
    has_tasks = _has_tasks(tasks)
    if !first_heartbeat && !last_heartbeat && !has_tasks
        return nothing
    end
    a = Vo.get_current_assistant()
    a === nothing && return nothing
    skill_names = try
        skills = Vo.getSkills(a.db)
        [s.name for s in skills]
    catch
        String[]
    end
    return heartbeat_prompt(local_time, Vo.local_utc_offset_minutes(local_time), tasks, skill_names, h)
end

# --- Helpers ---

function heartbeat_schedule(offset_minutes::Int, interval_minutes::Int=DEFAULT_HEARTBEAT_INTERVAL)
    interval_minutes = clamp(interval_minutes, 1, 60)
    base = mod(HEARTBEAT_MINUTE - offset_minutes, 60)
    minutes = Int[]
    m = base
    while true
        push!(minutes, mod(m, 60))
        m += interval_minutes
        mod(m, 60) == mod(base, 60) && break
        length(minutes) >= 60 && break
    end
    sort!(unique!(minutes))
    return join(minutes, ",") * " * * * *"
end

function _has_tasks(tasks::String)
    for line in split(tasks, "\n")
        stripped = strip(line)
        isempty(stripped) && continue
        startswith(stripped, "#") && continue
        return true
    end
    return false
end

function heartbeat_prompt(local_time::DateTime, offset_minutes::Int, heartbeat_tasks::String, skill_names::Vector{String}, h::HeartbeatPollSource)
    offset_str = Vo.format_utc_offset(offset_minutes)
    time_str = Dates.format(local_time, "yyyy-mm-dd HH:MM")
    first_heartbeat = Dates.hour(local_time) == h.start_hour
    last_heartbeat = Dates.hour(local_time) == h.end_hour
    has_tasks = !isempty(strip(heartbeat_tasks))

    skill_section = if !isempty(skill_names)
        skill_list = join(["  - `$(s)`" for s in skill_names], "\n")
        """
        - Run relevant skills to surface recent or upcoming items. Available skills:
        $(skill_list)
          Use these to catch todos, events, messages, or content relevant to the user."""
    else
        "- Check for any available skills that surface recent or upcoming items (email, calendar, messaging, news)."
    end

    tasks_section = if has_tasks
        """

        Pending heartbeat tasks (from HEARTBEAT.md — process these):
        $(heartbeat_tasks)

        After processing tasks, update HEARTBEAT.md to remove completed items."""
    else
        ""
    end

    return """
    Heartbeat check-in.
    Current local time: $(time_str) (UTC$(offset_str)).
    First heartbeat of day: $(first_heartbeat ? "yes" : "no"). Last heartbeat of day: $(last_heartbeat ? "yes" : "no").
    $(tasks_section)
    Rules:
    - Always respond on the first heartbeat (hour $(h.start_hour)): greet with a concise good morning and offer a short plan or priorities for the day.
    - Always respond on the last heartbeat (hour $(h.end_hour)): say goodnight and provide a brief look-back + look-forward summary.
    - If there are pending heartbeat tasks above, always respond (process them).
    - For other heartbeats with no pending tasks, only respond if you find something useful; otherwise respond exactly with HEARTBEAT_OK.

    Checklist:
    - Review recent session entries and memories for events, lessons, or follow-ups worth acting on.
    $(skill_section)
    - Use memories about user interests to find or propose noteworthy content, refining interest/topics over time.
    - If responding outside the first/last heartbeat, be concise — only meaningful updates or actions.

    Learnings (#20):
    - If you discover any stable facts, patterns, or insights during this heartbeat, store them with addNewMemory.
    - On the last heartbeat of the day, briefly review recent memories for any that are stale or redundant — propose pruning if needed.
    """
end
