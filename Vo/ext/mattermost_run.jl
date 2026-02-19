using Agentif, Vo, Mattermost, Telegram, Dates

const MattermostExt = Base.get_extension(Agentif, :AgentifMattermostExt)

Vo.init!(; name="ando")
Mattermost.with_mattermost(ENV["MATTERMOST_TOKEN"], ENV["MATTERMOST_URL"]) do
    MattermostExt.run_mattermost_bot(;
        on_delete = post_id -> Vo.scrub_post_id!(Vo.get_current_assistant(), post_id),
    ) do msg
        Vo.evaluate(Vo.get_current_assistant(), msg)
    end
end
