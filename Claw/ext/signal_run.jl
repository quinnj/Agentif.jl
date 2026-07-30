using Claw, Signal

const ClawSignalExt = Base.get_extension(Claw, :ClawSignalExt)

source = ClawSignalExt.SignalEventSource()
Claw.run(; event_sources=Claw.EventSource[source])

# Claw.run is non-blocking; keep the process alive so source tasks stay up.
wait(Base.Event())
