using Claw, MSTeams

const ClawMSTeamsExt = Base.get_extension(Claw, :ClawMSTeamsExt)

source = ClawMSTeamsExt.MSTeamsEventSource()
assistant = Claw.run(; event_sources=Claw.EventSource[source])

# Claw.run is non-blocking. Block on shutdown-complete so SIGTERM/SIGINT drains
# in-flight evaluations instead of vanishing mid-eval.
Claw.wait_for_shutdown(assistant)
