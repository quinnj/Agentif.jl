using Agentif, Vo, Telegram

const VoTelegramExt = Base.get_extension(Vo, :VoTelegramExt)

source = VoTelegramExt.TelegramTriggerSource()
Vo.run(; event_sources=Vo.EventSource[source])
