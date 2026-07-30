using Claw, Signal

const ClawSignalExt = Base.get_extension(Claw, :ClawSignalExt)

source = ClawSignalExt.SignalEventSource()
assistant = Claw.run(; event_sources=Claw.EventSource[source])

# Claw.run is non-blocking. Block on shutdown-complete so SIGTERM/SIGINT drains
# in-flight evaluations instead of vanishing mid-eval.
Claw.wait_for_shutdown(assistant)
