using Vo, MSTeams

const VoMSTeamsExt = Base.get_extension(Vo, :VoMSTeamsExt)

source = VoMSTeamsExt.MSTeamsEventSource()
Vo.run(; event_sources=Vo.EventSource[source])
