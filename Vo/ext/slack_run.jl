using Agentif, Vo, Slack

const VoSlackExt = Base.get_extension(Vo, :VoSlackExt)

source = VoSlackExt.SlackTriggerSource()
Vo.run(; event_sources=Vo.EventSource[source])
