using Claw, Telegram

const ClawTelegramExt = Base.get_extension(Claw, :ClawTelegramExt)

source = ClawTelegramExt.TelegramEventSource()
assistant = Claw.run(; event_sources=Claw.EventSource[source])

# Claw.run is non-blocking. Block on shutdown-complete so SIGTERM/SIGINT drains
# in-flight evaluations instead of vanishing mid-eval.
Claw.wait_for_shutdown(assistant)
