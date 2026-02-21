using Agentif, Vo, Mattermost

include(joinpath(dirname(pathof(Vo)), "..", "examples", "heartbeat_poll_source.jl"))

const VoMMExt = Base.get_extension(Vo, :VoMattermostExt)

hb = HeartbeatPollSource(interval_minutes=30)
mm = VoMMExt.MattermostTriggerSource(;
    on_delete = post_id -> Vo.scrub_post_id!(Vo.get_current_assistant(), post_id),
)
Vo.run(; name="ando", event_sources=Vo.EventSource[hb, mm])
