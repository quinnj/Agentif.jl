using Vo, Telegram

Vo.init!()
Telegram.with_telegram(ENV["TELEGRAM_BOT_TOKEN"]) do
    Vo.run_telegram_bot()
end