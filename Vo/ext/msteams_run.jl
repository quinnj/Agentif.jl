using Agentif, Vo, MSTeams

const VoMSTeamsExt = Base.get_extension(Vo, :VoMSTeamsExt)

source = VoMSTeamsExt.MSTeamsTriggerSource()
Vo.run(; event_sources=Vo.EventSource[source])
