using Agentif, Vo, Signal

const SignalExt = Base.get_extension(Agentif, :AgentifSignalExt)

Vo.init!()
SignalExt.run_signal_bot() do msg
    Vo.evaluate(Vo.get_current_assistant(), msg)
end
