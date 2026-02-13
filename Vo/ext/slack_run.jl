using Agentif, Vo, Slack

const SlackExt = Base.get_extension(Agentif, :AgentifSlackExt)

Vo.init!()
SlackExt.run_slack_bot() do msg
    Vo.evaluate(Vo.get_current_assistant(), msg)
end
