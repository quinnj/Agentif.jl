using Claw, Slack

const ClawSlackExt = Base.get_extension(Claw, :ClawSlackExt)

source = ClawSlackExt.SlackEventSource()
Claw.run(; event_sources=Claw.EventSource[source])

# Claw.run is non-blocking; keep the process alive so source tasks stay up.
wait(Base.Event())
