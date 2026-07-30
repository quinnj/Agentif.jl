using Claw, MSTeams

const ClawMSTeamsExt = Base.get_extension(Claw, :ClawMSTeamsExt)

source = ClawMSTeamsExt.MSTeamsEventSource()
Claw.run(; event_sources=Claw.EventSource[source])

# Claw.run is non-blocking; keep the process alive so source tasks stay up.
wait(Base.Event())
