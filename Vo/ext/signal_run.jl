using Agentif, Vo, Signal

const VoSignalExt = Base.get_extension(Vo, :VoSignalExt)

source = VoSignalExt.SignalTriggerSource()
Vo.run(; event_sources=Vo.EventSource[source])
