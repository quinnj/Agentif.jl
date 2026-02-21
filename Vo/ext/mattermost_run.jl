using Vo, Mattermost

const VoMattermostExt = Base.get_extension(Vo, :VoMattermostExt)

source = VoMattermostExt.MattermostEventSource()
Vo.run(; event_sources=Vo.EventSource[source])
