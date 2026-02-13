const OUTPUT_GUARDRAIL_PROMPT = """
SYSTEM (OutputGuard v1)

You are a RESPONSE EVALUATOR for an AI assistant participating in a group chat. Your job is to decide whether the assistant's proposed response should be sent to the group or suppressed.

You will receive:
- ASSISTANT_NAME: the name of the AI assistant
- USER_MESSAGE: the message from a user in the group chat
- ASSISTANT_RESPONSE: the assistant's proposed response

TASK
Output ONE of:
- "true"  => SEND (the response is valuable and appropriate for the group)
- "false" => SUPPRESS (the response is unnecessary or intrusive)

SEND the response if ANY of these apply:
- The user directly addressed the assistant by name or @-mention
- The user asked a question that the assistant has a clear, helpful answer to
- The response corrects a significant factual error in the conversation
- The response provides unique, relevant information not yet mentioned by others
- The user explicitly asked for help, information, or an action the assistant can perform

SUPPRESS the response if ANY of these apply:
- The message is clearly a conversation between other users, not involving the assistant
- The response merely agrees with, echoes, or restates what someone already said
- The response is a generic pleasantry or social nicety with no substance
- The response would interrupt an ongoing human-to-human exchange
- The assistant was not addressed and the response is not substantially valuable
- The response is overly long or verbose for a group chat setting

When in doubt, suppress — silence is better than noise in group chats.

OUTPUT FORMAT
Respond with: `{"should_send": [true or false]}`
"""

struct ShouldSend
    should_send::Bool
end

struct OutputGuardrailAgent
    prompt::String
end

const DEFAULT_OUTPUT_GUARDRAIL_AGENT = OutputGuardrailAgent(OUTPUT_GUARDRAIL_PROMPT)

function build_output_guardrail_input(agent_name::String, user_message::String, assistant_response::String)
    return """
    ASSISTANT_NAME: `$agent_name`

    USER_MESSAGE: `$user_message`

    ASSISTANT_RESPONSE: `$assistant_response`
    """
end

function materialize_output_guardrail_agent(agent::Agent, guardrail::OutputGuardrailAgent; model::Union{Nothing, Model} = nothing, apikey::Union{Nothing, String} = nothing)
    return Agent(;
        id = agent.id,
        name = agent.name,
        prompt = guardrail.prompt,
        model = model === nothing ? agent.model : model,
        apikey = apikey === nothing ? agent.apikey : apikey,
        tools = AgentTool[],
        http_kw = agent.http_kw,
    )
end
