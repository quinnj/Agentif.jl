using Claw, Mattermost

const ClawMattermostExt = Base.get_extension(Claw, :ClawMattermostExt)

source = ClawMattermostExt.MattermostEventSource()
Claw.run(; event_sources=Claw.EventSource[source])

# Claw.run is non-blocking; keep the process alive so source tasks stay up.
wait(Base.Event())
