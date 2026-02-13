using Agentif, Vo, MSTeams

const MSTeamsExt = Base.get_extension(Agentif, :AgentifMSTeamsExt)

Vo.init!()
MSTeamsExt.run_msteams_bot() do msg
    Vo.evaluate(Vo.get_current_assistant(), msg)
end
