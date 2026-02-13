using Agentif, Vo, Telegram

const TelegramExt = Base.get_extension(Agentif, :AgentifTelegramExt)

Vo.init!()
Telegram.with_telegram(ENV["TELEGRAM_BOT_TOKEN"]) do
    TelegramExt.run_telegram_bot() do msg
        Vo.evaluate(Vo.get_current_assistant(), msg)
    end
end
