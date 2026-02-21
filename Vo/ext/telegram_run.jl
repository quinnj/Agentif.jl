using Vo, Telegram

const VoTelegramExt = Base.get_extension(Vo, :VoTelegramExt)

source = VoTelegramExt.TelegramEventSource()
Vo.run(; event_sources=Vo.EventSource[source])
