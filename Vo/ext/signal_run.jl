using Vo, Signal

const VoSignalExt = Base.get_extension(Vo, :VoSignalExt)

source = VoSignalExt.SignalEventSource()
Vo.run(; event_sources=Vo.EventSource[source])
