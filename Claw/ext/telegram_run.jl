using Claw, Telegram

const ClawTelegramExt = Base.get_extension(Claw, :ClawTelegramExt)

source = ClawTelegramExt.TelegramEventSource()
Claw.run(; event_sources=Claw.EventSource[source])

# Claw.run is non-blocking; keep the process alive so source tasks stay up.
wait(Base.Event())
