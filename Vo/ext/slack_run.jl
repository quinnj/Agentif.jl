using Vo, Slack

const VoSlackExt = Base.get_extension(Vo, :VoSlackExt)

source = VoSlackExt.SlackEventSource()
Vo.run(; event_sources=Vo.EventSource[source])
