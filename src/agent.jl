@kwarg struct Agent{F}
    prompt::String
    model::Union{Nothing, Model} = nothing
    input_guardrail::F = nothing
    tools::Vector{AgentTool} = AgentTool[]
end

struct InvalidInputError <: Exception
    input::String
end

@kwarg struct Result
    previous_response_id::String
    pending_tool_calls::Vector{PendingToolCall} # for tool calls that are waiting for approval
end

function evaluate!(agent::Agent, input::Union{String,Vector{PendingToolCall}}, apikey::String; model::Union{Nothing, Model} = nothing, previous_response_id::Union{Nothing, String} = nothing, stream_output::Bool = isinteractive(), kw...)
    return evaluate!(agent, input, apikey; model, previous_response_id, kw...) do event
        if event isa MessageUpdateEvent
            stream_output && print(event.delta)
        elseif event isa MessageEndEvent
            stream_output && println()
        end
    end
end

function evaluate!(f::Function, agent::Agent, input::Union{String,Vector{PendingToolCall}}, apikey::String; model::Union{Nothing, Model} = nothing, previous_response_id::Union{Nothing, String} = nothing, http_kw=(;), kw...)
    model = model === nothing ? agent.model : model
    model === nothing && throw(ArgumentError("no model specified with which agent can evaluate input"))
    if model.api == "openai-responses"
        return evaluate_openai_responses!(f, agent, input, apikey; model, previous_response_id, http_kw, kw...)
    elseif model.api == "openai-completions"
        return evaluate_openai_completions!(f, agent, input, apikey; model, previous_response_id, http_kw, kw...)
    elseif model.api == "anthropic-messages"
        return evaluate_anthropic_messages!(f, agent, input, apikey; model, previous_response_id, http_kw, kw...)
    elseif model.api == "google-generative-ai"
        return evaluate_google_generative_ai!(f, agent, input, apikey; model, previous_response_id, http_kw, kw...)
    elseif model.api == "google-gemini-cli"
        return evaluate_google_gemini_cli!(f, agent, input, apikey; model, previous_response_id, http_kw, kw...)
    else
        throw(ArgumentError("$(model.name) using $(model.api) api currently unsupported"))
    end
end

mutable struct ToolCallAccumulator
    id::Union{Nothing,String}
    name::Union{Nothing,String}
    arguments::String
end

ensure_response_id(response_id::Union{Nothing,String}) = (response_id === nothing || isempty(response_id)) ? string(UUIDs.uuid4()) : response_id
new_call_id(prefix::String) = string(prefix, "-", UUIDs.uuid4())
supports_completions_reasoning_effort(model::Model) = model.api != "openai-completions" ? true : !occursin("api.x.ai", model.baseUrl)

function evaluate_openai_responses!(f::Function, agent::Agent, input::Union{String,Vector{PendingToolCall}}, apikey::String; model::Model, previous_response_id::Union{Nothing, String} = nothing, http_kw=(;), kw...)
    return Future{Result}() do
        tools = [OpenAIResponses.FunctionTool(t) for t in agent.tools]
        input_valid = Future{Bool}(() -> (agent.input_guardrail === nothing || !(input isa String)) ? true : agent.input_guardrail(agent.prompt, input, apikey))
        f(AgentEvaluateStartEvent())
        turn = 1
        f(TurnStartEvent(turn))
        local current_input
        if input isa Vector{PendingToolCall}
            resolved_calls, context = resolve_cached_tool_calls!(input)
            context.provider != model.api && throw(ArgumentError("pending tool calls are cached for $(context.provider), not $(model.api)"))
            previous_response_id = context.response_id
            tool_results = Future{ToolResultMessage}[]
            for tc in resolved_calls
                tool = findtool(agent.tools, tc.name)
                f(ToolExecutionStartEvent(tc))
                if tc.approved
                    push!(tool_results, call_function_tool!(f, tool, tc))
                else
                    push!(tool_results, reject_function_tool!(f, tc, tc))
                end
            end
            clear_cached_tool_calls!([tc.call_id for tc in resolved_calls])
            current_input = OpenAIResponses.InputItem[OpenAIResponses.FunctionToolCallOutput(wait(x)) for x in tool_results]
        else
            current_input = input
        end
        pending_tool_calls = PendingToolCall[]
        while true
            assistant_message = AssistantTextMessage(; response_id=previous_response_id)
            assistant_started = false
            assistant_ended = false
            empty!(pending_tool_calls)
            stream_fn = haskey(kw, :instructions) ? OpenAIResponses.stream : (args...; kwargs...) -> OpenAIResponses.stream(args...; instructions=agent.prompt, kwargs...)
            stream_fn(model, current_input, apikey; tools, previous_response_id, http_kw, kw...) do http_stream, event
                if !wait(input_valid)
                    close(http_stream)
                    f(AgentErrorEvent(InvalidInputError(input isa String ? input : "<non-string input>")))
                    return
                end
                if event isa OpenAIResponses.StreamResponseCreatedEvent
                    previous_response_id = event.response.id
                    assistant_message.response_id = previous_response_id
                    if !assistant_started
                        assistant_started = true
                        f(MessageStartEvent(:assistant, assistant_message))
                    end
                elseif event isa OpenAIResponses.StreamOutputTextDeltaEvent
                    if !assistant_started
                        assistant_started = true
                        f(MessageStartEvent(:assistant, assistant_message))
                    end
                    assistant_message.text *= event.delta
                    f(MessageUpdateEvent(:assistant, assistant_message, :text, event.delta, event.item_id))
                elseif event isa OpenAIResponses.StreamReasoningSummaryTextDeltaEvent
                    if !assistant_started
                        assistant_started = true
                        f(MessageStartEvent(:assistant, assistant_message))
                    end
                    assistant_message.reasoning *= event.delta
                    f(MessageUpdateEvent(:assistant, assistant_message, :reasoning, event.delta, event.item_id))
                elseif event isa OpenAIResponses.StreamReasoningTextDeltaEvent
                    if !assistant_started
                        assistant_started = true
                        f(MessageStartEvent(:assistant, assistant_message))
                    end
                    assistant_message.reasoning *= event.delta
                    f(MessageUpdateEvent(:assistant, assistant_message, :reasoning, event.delta, event.item_id))
                elseif event isa OpenAIResponses.StreamRefusalDeltaEvent
                    if !assistant_started
                        assistant_started = true
                        f(MessageStartEvent(:assistant, assistant_message))
                    end
                    assistant_message.refusal *= event.delta
                    f(MessageUpdateEvent(:assistant, assistant_message, :refusal, event.delta, event.item_id))
                elseif event isa OpenAIResponses.StreamFunctionCallArgumentsDeltaEvent
                    if !assistant_started
                        assistant_started = true
                        f(MessageStartEvent(:assistant, assistant_message))
                    end
                    f(MessageUpdateEvent(:assistant, assistant_message, :tool_arguments, event.delta, event.item_id))
                elseif event isa OpenAIResponses.StreamOutputItemDoneEvent
                    item_type = event.item.type
                    if item_type == "function_call"
                        ptc = PendingToolCall(; call_id=event.item.call_id, name=event.item.name, arguments=event.item.arguments)
                        push!(pending_tool_calls, ptc)
                        at = findtool(agent.tools, ptc.name)
                        f(ToolCallRequestEvent(ptc, at.requires_approval))
                    end
                elseif event isa OpenAIResponses.StreamOutputDoneEvent || event isa OpenAIResponses.StreamDoneEvent
                    if assistant_started && !assistant_ended
                        assistant_ended = true
                        f(MessageEndEvent(:assistant, assistant_message))
                    end
                elseif event isa OpenAIResponses.StreamErrorEvent
                    if assistant_started && !assistant_ended
                        assistant_ended = true
                        f(MessageEndEvent(:assistant, assistant_message))
                    end
                    f(AgentErrorEvent(ErrorException(event.message)))
                end
            end
            if assistant_started && !assistant_ended
                f(MessageEndEvent(:assistant, assistant_message))
            end
            if !wait(input_valid)
                throw(ArgumentError("input_guardrail check failed for input: `$input`"))
            end
            requires_approval = PendingToolCall[]
            for ptc in pending_tool_calls
                tool = findtool(agent.tools, ptc.name)
                if tool.requires_approval
                    push!(requires_approval, ptc)
                end
            end
            if isempty(pending_tool_calls) || !isempty(requires_approval)
                response_id = ensure_response_id(previous_response_id)
                if !isempty(requires_approval)
                    cache_tool_calls!(requires_approval, CachedToolCallContext(model.api, response_id, nothing))
                end
                result = Result(; previous_response_id=response_id, pending_tool_calls=requires_approval)
                f(AgentEvaluateEndEvent(result))
                return result
            end
            tool_results = Future{ToolResultMessage}[]
            for tc in pending_tool_calls
                tool = findtool(agent.tools, tc.name)
                f(ToolExecutionStartEvent(tc))
                push!(tool_results, call_function_tool!(f, tool, tc))
            end
            current_input = OpenAIResponses.InputItem[OpenAIResponses.FunctionToolCallOutput(wait(x)) for x in tool_results]
            f(TurnEndEvent(turn, assistant_started ? assistant_message : nothing, pending_tool_calls))
            turn += 1
            f(TurnStartEvent(turn))
        end
    end
end

function evaluate_openai_completions!(f::Function, agent::Agent, input::Union{String,Vector{PendingToolCall}}, apikey::String; model::Model, previous_response_id::Union{Nothing, String} = nothing, http_kw=(;), kw...)
    return Future{Result}() do
        tools = isempty(agent.tools) ? nothing : OpenAICompletions.Tool[OpenAICompletions.FunctionTool(t) for t in agent.tools]
        input_valid = Future{Bool}(() -> (agent.input_guardrail === nothing || !(input isa String)) ? true : agent.input_guardrail(agent.prompt, input, apikey))
        f(AgentEvaluateStartEvent())
        turn = 1
        f(TurnStartEvent(turn))
        local messages
        if input isa Vector{PendingToolCall}
            resolved_calls, context = resolve_cached_tool_calls!(input)
            context.provider != model.api && throw(ArgumentError("pending tool calls are cached for $(context.provider), not $(model.api)"))
            previous_response_id = context.response_id
            state = context.state
            state === nothing && throw(ArgumentError("missing cached state for openai-completions"))
            messages = state.messages
            tool_results = Future{ToolResultMessage}[]
            for tc in resolved_calls
                tool = findtool(agent.tools, tc.name)
                f(ToolExecutionStartEvent(tc))
                if tc.approved
                    push!(tool_results, call_function_tool!(f, tool, tc))
                else
                    push!(tool_results, reject_function_tool!(f, tc, tc))
                end
            end
            clear_cached_tool_calls!([tc.call_id for tc in resolved_calls])
            for trm in tool_results
                result = wait(trm)
                push!(messages, OpenAICompletions.Message(; role="tool", content=result.output, tool_call_id=result.call_id))
            end
        else
            messages = OpenAICompletions.Message[]
            push!(messages, OpenAICompletions.Message(; role="system", content=agent.prompt))
            push!(messages, OpenAICompletions.Message(; role="user", content=input))
        end
        pending_tool_calls = PendingToolCall[]
        while true
            assistant_message = AssistantTextMessage(; response_id=previous_response_id)
            assistant_started = false
            assistant_ended = false
            reasoning_signature = nothing
            empty!(pending_tool_calls)
            tool_call_accumulators = Dict{Int,ToolCallAccumulator}()
            stream_kw = haskey(kw, :instructions) ? Base.structdiff(kw, (; instructions=nothing)) : kw
            if haskey(stream_kw, :reasoning)
                reasoning_effort = stream_kw[:reasoning]
                stream_kw = Base.structdiff(stream_kw, (; reasoning=nothing))
                if !haskey(stream_kw, :reasoning_effort)
                    stream_kw = (; stream_kw..., reasoning_effort=reasoning_effort)
                end
            end
            if haskey(stream_kw, :reasoning_effort) && !supports_completions_reasoning_effort(model)
                stream_kw = Base.structdiff(stream_kw, (; reasoning_effort=nothing))
            end
            OpenAICompletions.stream(model, messages, apikey; tools, http_kw, stream_kw...) do http_stream, event
                if !wait(input_valid)
                    close(http_stream)
                    f(AgentErrorEvent(InvalidInputError(input isa String ? input : "<non-string input>")))
                    return
                end
                if event isa OpenAICompletions.StreamChunk
                    if event.id !== nothing
                        previous_response_id = event.id
                        assistant_message.response_id = previous_response_id
                    end
                    isempty(event.choices) && return
                    choice = event.choices[1]
                    delta = choice.delta
                    if delta.content !== nothing
                        if !assistant_started
                            assistant_started = true
                            f(MessageStartEvent(:assistant, assistant_message))
                        end
                        assistant_message.text *= delta.content
                        f(MessageUpdateEvent(:assistant, assistant_message, :text, delta.content, nothing))
                    end
                    for field in (:reasoning_content, :reasoning, :reasoning_text)
                        value = getfield(delta, field)
                        if value !== nothing && !isempty(value)
                            if !assistant_started
                                assistant_started = true
                                f(MessageStartEvent(:assistant, assistant_message))
                            end
                            assistant_message.reasoning *= value
                            f(MessageUpdateEvent(:assistant, assistant_message, :reasoning, value, nothing))
                            reasoning_signature === nothing && (reasoning_signature = field)
                        end
                    end
                    if delta.tool_calls !== nothing
                        if !assistant_started
                            assistant_started = true
                            f(MessageStartEvent(:assistant, assistant_message))
                        end
                        for tool_delta in delta.tool_calls
                            acc = get(() -> nothing, tool_call_accumulators, tool_delta.index)
                            if acc === nothing
                                acc = ToolCallAccumulator(tool_delta.id, tool_delta.function.name, "")
                                tool_call_accumulators[tool_delta.index] = acc
                            end
                            tool_delta.id !== nothing && (acc.id = tool_delta.id)
                            tool_delta.function.name !== nothing && (acc.name = tool_delta.function.name)
                            if tool_delta.function.arguments !== nothing
                                acc.arguments *= tool_delta.function.arguments
                                f(MessageUpdateEvent(:assistant, assistant_message, :tool_arguments, tool_delta.function.arguments, acc.id))
                            end
                        end
                    end
                elseif event isa OpenAICompletions.StreamDoneEvent
                    if assistant_started && !assistant_ended
                        assistant_ended = true
                        f(MessageEndEvent(:assistant, assistant_message))
                    end
                elseif event isa OpenAICompletions.StreamErrorEvent
                    if assistant_started && !assistant_ended
                        assistant_ended = true
                        f(MessageEndEvent(:assistant, assistant_message))
                    end
                    f(AgentErrorEvent(ErrorException(event.message)))
                end
            end
            if assistant_started && !assistant_ended
                f(MessageEndEvent(:assistant, assistant_message))
            end
            if !wait(input_valid)
                throw(ArgumentError("input_guardrail check failed for input: `$input`"))
            end
            tool_calls = OpenAICompletions.ToolCall[]
            for idx in sort(collect(keys(tool_call_accumulators)))
                acc = tool_call_accumulators[idx]
                acc.name === nothing && throw(ArgumentError("tool call missing name for index $(idx)"))
                call_id = acc.id === nothing ? new_call_id("openai") : acc.id
                args = isempty(acc.arguments) ? "{}" : acc.arguments
                push!(tool_calls, OpenAICompletions.ToolCall(; id=call_id, var"function"=OpenAICompletions.ToolCallFunction(; name=acc.name, arguments=args)))
                ptc = PendingToolCall(; call_id=call_id, name=acc.name, arguments=args)
                push!(pending_tool_calls, ptc)
                tool = findtool(agent.tools, ptc.name)
                f(ToolCallRequestEvent(ptc, tool.requires_approval))
            end
            assistant_content = isempty(assistant_message.text) ? nothing : assistant_message.text
            assistant_tool_calls = isempty(tool_calls) ? nothing : tool_calls
            assistant_reasoning = isempty(assistant_message.reasoning) ? nothing : assistant_message.reasoning
            msg_kwargs = (; role="assistant", content=assistant_content, tool_calls=assistant_tool_calls)
            if assistant_reasoning !== nothing
                if reasoning_signature === :reasoning_content
                    msg_kwargs = (; msg_kwargs..., reasoning_content=assistant_reasoning)
                elseif reasoning_signature === :reasoning_text
                    msg_kwargs = (; msg_kwargs..., reasoning_text=assistant_reasoning)
                else
                    msg_kwargs = (; msg_kwargs..., reasoning=assistant_reasoning)
                end
            end
            push!(messages, OpenAICompletions.Message(; msg_kwargs...))
            requires_approval = PendingToolCall[]
            for ptc in pending_tool_calls
                tool = findtool(agent.tools, ptc.name)
                if tool.requires_approval
                    push!(requires_approval, ptc)
                end
            end
            if isempty(pending_tool_calls) || !isempty(requires_approval)
                response_id = ensure_response_id(previous_response_id)
                if !isempty(requires_approval)
                    cache_tool_calls!(requires_approval, CachedToolCallContext(model.api, response_id, (; messages=copy(messages))))
                end
                result = Result(; previous_response_id=response_id, pending_tool_calls=requires_approval)
                f(AgentEvaluateEndEvent(result))
                return result
            end
            tool_results = Future{ToolResultMessage}[]
            for tc in pending_tool_calls
                tool = findtool(agent.tools, tc.name)
                f(ToolExecutionStartEvent(tc))
                push!(tool_results, call_function_tool!(f, tool, tc))
            end
            for trm in tool_results
                result = wait(trm)
                push!(messages, OpenAICompletions.Message(; role="tool", content=result.output, tool_call_id=result.call_id))
            end
            f(TurnEndEvent(turn, assistant_started ? assistant_message : nothing, pending_tool_calls))
            turn += 1
            f(TurnStartEvent(turn))
        end
    end
end

function evaluate_anthropic_messages!(f::Function, agent::Agent, input::Union{String,Vector{PendingToolCall}}, apikey::String; model::Model, previous_response_id::Union{Nothing, String} = nothing, http_kw=(;), kw...)
    return Future{Result}() do
        tools = isempty(agent.tools) ? nothing : [AnthropicMessages.Tool(t) for t in agent.tools]
        input_valid = Future{Bool}(() -> (agent.input_guardrail === nothing || !(input isa String)) ? true : agent.input_guardrail(agent.prompt, input, apikey))
        f(AgentEvaluateStartEvent())
        turn = 1
        f(TurnStartEvent(turn))
        system_prompt = haskey(kw, :system) ? kw[:system] : agent.prompt
        local messages
        if input isa Vector{PendingToolCall}
            resolved_calls, context = resolve_cached_tool_calls!(input)
            context.provider != model.api && throw(ArgumentError("pending tool calls are cached for $(context.provider), not $(model.api)"))
            previous_response_id = context.response_id
            state = context.state
            state === nothing && throw(ArgumentError("missing cached state for anthropic-messages"))
            system_prompt = state.system
            messages = state.messages
            tool_results = Future{ToolResultMessage}[]
            for tc in resolved_calls
                tool = findtool(agent.tools, tc.name)
                f(ToolExecutionStartEvent(tc))
                if tc.approved
                    push!(tool_results, call_function_tool!(f, tool, tc))
                else
                    push!(tool_results, reject_function_tool!(f, tc, tc))
                end
            end
            clear_cached_tool_calls!([tc.call_id for tc in resolved_calls])
            tool_blocks = AnthropicMessages.ContentBlock[]
            for trm in tool_results
                result = wait(trm)
                push!(tool_blocks, AnthropicMessages.ToolResultBlock(; tool_use_id=result.call_id, content=result.output, is_error=result.is_error))
            end
            if !isempty(tool_blocks)
                push!(messages, AnthropicMessages.Message(; role="user", content=tool_blocks))
            end
        else
            messages = AnthropicMessages.Message[]
            push!(messages, AnthropicMessages.Message(; role="user", content=input))
        end
        pending_tool_calls = PendingToolCall[]
        while true
            assistant_message = AssistantTextMessage(; response_id=previous_response_id)
            assistant_started = false
            assistant_ended = false
            empty!(pending_tool_calls)
            blocks_by_index = Dict{Int,AnthropicMessages.ContentBlock}()
            partial_json_by_index = Dict{Int,String}()
            stream_kw = haskey(kw, :instructions) ? Base.structdiff(kw, (; instructions=nothing)) : kw
            if haskey(stream_kw, :system)
                AnthropicMessages.stream(model, messages, apikey; tools, http_kw, stream_kw...) do http_stream, event
                    if !wait(input_valid)
                        close(http_stream)
                        f(AgentErrorEvent(InvalidInputError(input isa String ? input : "<non-string input>")))
                        return
                    end
                    if event isa AnthropicMessages.StreamMessageStartEvent
                        if event.message.id !== nothing
                            previous_response_id = event.message.id
                            assistant_message.response_id = previous_response_id
                        end
                        if !assistant_started
                            assistant_started = true
                            f(MessageStartEvent(:assistant, assistant_message))
                        end
                    elseif event isa AnthropicMessages.StreamContentBlockStartEvent
                        if event.content_block isa AnthropicMessages.TextBlock
                            block = AnthropicMessages.TextBlock(; text=event.content_block.text)
                            blocks_by_index[event.index] = block
                        elseif event.content_block isa AnthropicMessages.ToolUseBlock
                            block = event.content_block
                            blocks_by_index[event.index] = block
                            partial_json_by_index[event.index] = ""
                        end
                    elseif event isa AnthropicMessages.StreamContentBlockDeltaEvent
                        if event.delta isa AnthropicMessages.TextDelta
                            block = get(() -> nothing, blocks_by_index, event.index)
                            block isa AnthropicMessages.TextBlock || return
                            block.text *= event.delta.text
                            if !assistant_started
                                assistant_started = true
                                f(MessageStartEvent(:assistant, assistant_message))
                            end
                            assistant_message.text *= event.delta.text
                            f(MessageUpdateEvent(:assistant, assistant_message, :text, event.delta.text, nothing))
                        elseif event.delta isa AnthropicMessages.InputJsonDelta
                            block = get(() -> nothing, blocks_by_index, event.index)
                            block isa AnthropicMessages.ToolUseBlock || return
                            partial = get(() -> "", partial_json_by_index, event.index)
                            partial *= event.delta.partial_json
                            partial_json_by_index[event.index] = partial
                            f(MessageUpdateEvent(:assistant, assistant_message, :tool_arguments, event.delta.partial_json, block.id))
                        end
                    elseif event isa AnthropicMessages.StreamContentBlockStopEvent
                        block = get(() -> nothing, blocks_by_index, event.index)
                        if block isa AnthropicMessages.ToolUseBlock
                            partial = get(() -> "", partial_json_by_index, event.index)
                            args_json = isempty(partial) ? "{}" : partial
                            block.input = JSON.parse(args_json)
                            ptc = PendingToolCall(; call_id=block.id, name=block.name, arguments=JSON.json(block.input))
                            push!(pending_tool_calls, ptc)
                            tool = findtool(agent.tools, ptc.name)
                            f(ToolCallRequestEvent(ptc, tool.requires_approval))
                        end
                    elseif event isa AnthropicMessages.StreamMessageStopEvent
                        if assistant_started && !assistant_ended
                            assistant_ended = true
                            f(MessageEndEvent(:assistant, assistant_message))
                        end
                    elseif event isa AnthropicMessages.StreamErrorEvent
                        if assistant_started && !assistant_ended
                            assistant_ended = true
                            f(MessageEndEvent(:assistant, assistant_message))
                        end
                        f(AgentErrorEvent(ErrorException("anthropic stream error")))
                    end
                end
            else
                AnthropicMessages.stream(model, messages, apikey; system=system_prompt, tools, http_kw, stream_kw...) do http_stream, event
                    if !wait(input_valid)
                        close(http_stream)
                        f(AgentErrorEvent(InvalidInputError(input isa String ? input : "<non-string input>")))
                        return
                    end
                    if event isa AnthropicMessages.StreamMessageStartEvent
                        if event.message.id !== nothing
                            previous_response_id = event.message.id
                            assistant_message.response_id = previous_response_id
                        end
                        if !assistant_started
                            assistant_started = true
                            f(MessageStartEvent(:assistant, assistant_message))
                        end
                    elseif event isa AnthropicMessages.StreamContentBlockStartEvent
                        if event.content_block isa AnthropicMessages.TextBlock
                            block = AnthropicMessages.TextBlock(; text=event.content_block.text)
                            blocks_by_index[event.index] = block
                        elseif event.content_block isa AnthropicMessages.ToolUseBlock
                            block = event.content_block
                            blocks_by_index[event.index] = block
                            partial_json_by_index[event.index] = ""
                        end
                    elseif event isa AnthropicMessages.StreamContentBlockDeltaEvent
                        if event.delta isa AnthropicMessages.TextDelta
                            block = get(() -> nothing, blocks_by_index, event.index)
                            block isa AnthropicMessages.TextBlock || return
                            block.text *= event.delta.text
                            if !assistant_started
                                assistant_started = true
                                f(MessageStartEvent(:assistant, assistant_message))
                            end
                            assistant_message.text *= event.delta.text
                            f(MessageUpdateEvent(:assistant, assistant_message, :text, event.delta.text, nothing))
                        elseif event.delta isa AnthropicMessages.InputJsonDelta
                            block = get(() -> nothing, blocks_by_index, event.index)
                            block isa AnthropicMessages.ToolUseBlock || return
                            partial = get(() -> "", partial_json_by_index, event.index)
                            partial *= event.delta.partial_json
                            partial_json_by_index[event.index] = partial
                            f(MessageUpdateEvent(:assistant, assistant_message, :tool_arguments, event.delta.partial_json, block.id))
                        end
                    elseif event isa AnthropicMessages.StreamContentBlockStopEvent
                        block = get(() -> nothing, blocks_by_index, event.index)
                        if block isa AnthropicMessages.ToolUseBlock
                            partial = get(() -> "", partial_json_by_index, event.index)
                            args_json = isempty(partial) ? "{}" : partial
                            block.input = JSON.parse(args_json)
                            ptc = PendingToolCall(; call_id=block.id, name=block.name, arguments=JSON.json(block.input))
                            push!(pending_tool_calls, ptc)
                            tool = findtool(agent.tools, ptc.name)
                            f(ToolCallRequestEvent(ptc, tool.requires_approval))
                        end
                    elseif event isa AnthropicMessages.StreamMessageStopEvent
                        if assistant_started && !assistant_ended
                            assistant_ended = true
                            f(MessageEndEvent(:assistant, assistant_message))
                        end
                    elseif event isa AnthropicMessages.StreamErrorEvent
                        if assistant_started && !assistant_ended
                            assistant_ended = true
                            f(MessageEndEvent(:assistant, assistant_message))
                        end
                        f(AgentErrorEvent(ErrorException("anthropic stream error")))
                    end
                end
            end
            if assistant_started && !assistant_ended
                f(MessageEndEvent(:assistant, assistant_message))
            end
            if !wait(input_valid)
                throw(ArgumentError("input_guardrail check failed for input: `$input`"))
            end
            sorted_indexes = sort(collect(keys(blocks_by_index)))
            assistant_blocks = AnthropicMessages.ContentBlock[]
            for idx in sorted_indexes
                push!(assistant_blocks, blocks_by_index[idx])
            end
            assistant_content = isempty(assistant_blocks) ? assistant_message.text : assistant_blocks
            push!(messages, AnthropicMessages.Message(; role="assistant", content=assistant_content))
            requires_approval = PendingToolCall[]
            for ptc in pending_tool_calls
                tool = findtool(agent.tools, ptc.name)
                if tool.requires_approval
                    push!(requires_approval, ptc)
                end
            end
            if isempty(pending_tool_calls) || !isempty(requires_approval)
                response_id = ensure_response_id(previous_response_id)
                if !isempty(requires_approval)
                    cache_tool_calls!(requires_approval, CachedToolCallContext(model.api, response_id, (; system=system_prompt, messages=copy(messages))))
                end
                result = Result(; previous_response_id=response_id, pending_tool_calls=requires_approval)
                f(AgentEvaluateEndEvent(result))
                return result
            end
            tool_results = Future{ToolResultMessage}[]
            for tc in pending_tool_calls
                tool = findtool(agent.tools, tc.name)
                f(ToolExecutionStartEvent(tc))
                push!(tool_results, call_function_tool!(f, tool, tc))
            end
            tool_blocks = AnthropicMessages.ContentBlock[]
            for trm in tool_results
                result = wait(trm)
                push!(tool_blocks, AnthropicMessages.ToolResultBlock(; tool_use_id=result.call_id, content=result.output, is_error=result.is_error))
            end
            push!(messages, AnthropicMessages.Message(; role="user", content=tool_blocks))
            f(TurnEndEvent(turn, assistant_started ? assistant_message : nothing, pending_tool_calls))
            turn += 1
            f(TurnStartEvent(turn))
        end
    end
end

function evaluate_google_generative_ai!(f::Function, agent::Agent, input::Union{String,Vector{PendingToolCall}}, apikey::String; model::Model, previous_response_id::Union{Nothing, String} = nothing, http_kw=(;), kw...)
    return Future{Result}() do
        tools = isempty(agent.tools) ? nothing : [GoogleGenerativeAI.Tool(agent.tools)]
        input_valid = Future{Bool}(() -> (agent.input_guardrail === nothing || !(input isa String)) ? true : agent.input_guardrail(agent.prompt, input, apikey))
        f(AgentEvaluateStartEvent())
        turn = 1
        f(TurnStartEvent(turn))
        if haskey(kw, :systemInstruction)
            system_instruction = kw[:systemInstruction]
            system_instruction isa String && (system_instruction = GoogleGenerativeAI.Content(; parts=[GoogleGenerativeAI.Part(; text=system_instruction)]))
        else
            system_instruction = GoogleGenerativeAI.Content(; parts=[GoogleGenerativeAI.Part(; text=agent.prompt)])
        end
        local contents
        if input isa Vector{PendingToolCall}
            resolved_calls, context = resolve_cached_tool_calls!(input)
            context.provider != model.api && throw(ArgumentError("pending tool calls are cached for $(context.provider), not $(model.api)"))
            previous_response_id = context.response_id
            state = context.state
            state === nothing && throw(ArgumentError("missing cached state for google-generative-ai"))
            system_instruction = state.system_instruction
            contents = state.contents
            tool_results = Future{ToolResultMessage}[]
            for tc in resolved_calls
                tool = findtool(agent.tools, tc.name)
                f(ToolExecutionStartEvent(tc))
                if tc.approved
                    push!(tool_results, call_function_tool!(f, tool, tc))
                else
                    push!(tool_results, reject_function_tool!(f, tc, tc))
                end
            end
            clear_cached_tool_calls!([tc.call_id for tc in resolved_calls])
            response_parts = GoogleGenerativeAI.Part[]
            for trm in tool_results
                result = wait(trm)
                response_payload = result.is_error ? Dict("error" => result.output) : Dict("result" => result.output)
                push!(response_parts, GoogleGenerativeAI.Part(; functionResponse=GoogleGenerativeAI.FunctionResponse(; name=result.name, response=response_payload)))
            end
            if !isempty(response_parts)
                push!(contents, GoogleGenerativeAI.Content(; role="user", parts=response_parts))
            end
        else
            contents = GoogleGenerativeAI.Content[]
            push!(contents, GoogleGenerativeAI.Content(; role="user", parts=[GoogleGenerativeAI.Part(; text=input)]))
        end
        pending_tool_calls = PendingToolCall[]
        while true
            assistant_message = AssistantTextMessage(; response_id=previous_response_id)
            assistant_started = false
            assistant_ended = false
            empty!(pending_tool_calls)
            assistant_parts = GoogleGenerativeAI.Part[]
            seen_call_ids = Set{String}()
            stream_kw = haskey(kw, :instructions) ? Base.structdiff(kw, (; instructions=nothing)) : kw
            if haskey(stream_kw, :systemInstruction)
                GoogleGenerativeAI.stream(model, contents, apikey; tools, http_kw, stream_kw...) do http_stream, event
                    if !wait(input_valid)
                        close(http_stream)
                        f(AgentErrorEvent(InvalidInputError(input isa String ? input : "<non-string input>")))
                        return
                    end
                    if event isa GoogleGenerativeAI.GenerateContentResponse
                        if event.responseId !== nothing
                            previous_response_id = event.responseId
                            assistant_message.response_id = previous_response_id
                        end
                        event.candidates === nothing && return
                        isempty(event.candidates) && return
                        candidate = event.candidates[1]
                        candidate.content === nothing && return
                        candidate.content.parts === nothing && return
                        for part in candidate.content.parts
                            if part.text !== nothing
                                if !assistant_started
                                    assistant_started = true
                                    f(MessageStartEvent(:assistant, assistant_message))
                                end
                                assistant_message.text *= part.text
                                if !isempty(assistant_parts) && assistant_parts[end].text !== nothing
                                    assistant_parts[end].text *= part.text
                                else
                                    push!(assistant_parts, GoogleGenerativeAI.Part(; text=part.text))
                                end
                                f(MessageUpdateEvent(:assistant, assistant_message, :text, part.text, nothing))
                            elseif part.functionCall !== nothing
                                if !assistant_started
                                    assistant_started = true
                                    f(MessageStartEvent(:assistant, assistant_message))
                                end
                                fc = part.functionCall
                                fc.name === nothing && throw(ArgumentError("function call missing name"))
                                call_id = fc.id === nothing ? new_call_id("gemini") : fc.id
                                call_id in seen_call_ids && continue
                                push!(seen_call_ids, call_id)
                                args_json = fc.args === nothing ? "{}" : JSON.json(fc.args)
                                ptc = PendingToolCall(; call_id=call_id, name=fc.name, arguments=args_json)
                                push!(pending_tool_calls, ptc)
                                tool = findtool(agent.tools, ptc.name)
                                f(ToolCallRequestEvent(ptc, tool.requires_approval))
                                push!(assistant_parts, GoogleGenerativeAI.Part(; functionCall=fc))
                            end
                        end
                    elseif event isa GoogleGenerativeAI.StreamDoneEvent
                        if assistant_started && !assistant_ended
                            assistant_ended = true
                            f(MessageEndEvent(:assistant, assistant_message))
                        end
                    elseif event isa GoogleGenerativeAI.StreamErrorEvent
                        if assistant_started && !assistant_ended
                            assistant_ended = true
                            f(MessageEndEvent(:assistant, assistant_message))
                        end
                        f(AgentErrorEvent(ErrorException(event.message)))
                    end
                end
            else
                GoogleGenerativeAI.stream(model, contents, apikey; tools, systemInstruction=system_instruction, http_kw, stream_kw...) do http_stream, event
                    if !wait(input_valid)
                        close(http_stream)
                        f(AgentErrorEvent(InvalidInputError(input isa String ? input : "<non-string input>")))
                        return
                    end
                    if event isa GoogleGenerativeAI.GenerateContentResponse
                        if event.responseId !== nothing
                            previous_response_id = event.responseId
                            assistant_message.response_id = previous_response_id
                        end
                        event.candidates === nothing && return
                        isempty(event.candidates) && return
                        candidate = event.candidates[1]
                        candidate.content === nothing && return
                        candidate.content.parts === nothing && return
                        for part in candidate.content.parts
                            if part.text !== nothing
                                if !assistant_started
                                    assistant_started = true
                                    f(MessageStartEvent(:assistant, assistant_message))
                                end
                                assistant_message.text *= part.text
                                if !isempty(assistant_parts) && assistant_parts[end].text !== nothing
                                    assistant_parts[end].text *= part.text
                                else
                                    push!(assistant_parts, GoogleGenerativeAI.Part(; text=part.text))
                                end
                                f(MessageUpdateEvent(:assistant, assistant_message, :text, part.text, nothing))
                            elseif part.functionCall !== nothing
                                if !assistant_started
                                    assistant_started = true
                                    f(MessageStartEvent(:assistant, assistant_message))
                                end
                                fc = part.functionCall
                                fc.name === nothing && throw(ArgumentError("function call missing name"))
                                call_id = fc.id === nothing ? new_call_id("gemini") : fc.id
                                call_id in seen_call_ids && continue
                                push!(seen_call_ids, call_id)
                                args_json = fc.args === nothing ? "{}" : JSON.json(fc.args)
                                ptc = PendingToolCall(; call_id=call_id, name=fc.name, arguments=args_json)
                                push!(pending_tool_calls, ptc)
                                tool = findtool(agent.tools, ptc.name)
                                f(ToolCallRequestEvent(ptc, tool.requires_approval))
                                push!(assistant_parts, GoogleGenerativeAI.Part(; functionCall=fc))
                            end
                        end
                    elseif event isa GoogleGenerativeAI.StreamDoneEvent
                        if assistant_started && !assistant_ended
                            assistant_ended = true
                            f(MessageEndEvent(:assistant, assistant_message))
                        end
                    elseif event isa GoogleGenerativeAI.StreamErrorEvent
                        if assistant_started && !assistant_ended
                            assistant_ended = true
                            f(MessageEndEvent(:assistant, assistant_message))
                        end
                        f(AgentErrorEvent(ErrorException(event.message)))
                    end
                end
            end
            if assistant_started && !assistant_ended
                f(MessageEndEvent(:assistant, assistant_message))
            end
            if !wait(input_valid)
                throw(ArgumentError("input_guardrail check failed for input: `$input`"))
            end
            if !isempty(assistant_parts)
                push!(contents, GoogleGenerativeAI.Content(; role="model", parts=assistant_parts))
            end
            requires_approval = PendingToolCall[]
            for ptc in pending_tool_calls
                tool = findtool(agent.tools, ptc.name)
                if tool.requires_approval
                    push!(requires_approval, ptc)
                end
            end
            if isempty(pending_tool_calls) || !isempty(requires_approval)
                response_id = ensure_response_id(previous_response_id)
                if !isempty(requires_approval)
                    cache_tool_calls!(requires_approval, CachedToolCallContext(model.api, response_id, (; system_instruction=system_instruction, contents=copy(contents))))
                end
                result = Result(; previous_response_id=response_id, pending_tool_calls=requires_approval)
                f(AgentEvaluateEndEvent(result))
                return result
            end
            tool_results = Future{ToolResultMessage}[]
            for tc in pending_tool_calls
                tool = findtool(agent.tools, tc.name)
                f(ToolExecutionStartEvent(tc))
                push!(tool_results, call_function_tool!(f, tool, tc))
            end
            response_parts = GoogleGenerativeAI.Part[]
            for trm in tool_results
                result = wait(trm)
                response_payload = result.is_error ? Dict("error" => result.output) : Dict("result" => result.output)
                push!(response_parts, GoogleGenerativeAI.Part(; functionResponse=GoogleGenerativeAI.FunctionResponse(; name=result.name, response=response_payload)))
            end
            push!(contents, GoogleGenerativeAI.Content(; role="user", parts=response_parts))
            f(TurnEndEvent(turn, assistant_started ? assistant_message : nothing, pending_tool_calls))
            turn += 1
            f(TurnStartEvent(turn))
        end
    end
end

function evaluate_google_gemini_cli!(f::Function, agent::Agent, input::Union{String,Vector{PendingToolCall}}, apikey::String; model::Model, previous_response_id::Union{Nothing, String} = nothing, http_kw=(;), kw...)
    return Future{Result}() do
        tools = isempty(agent.tools) ? nothing : [GoogleGeminiCli.Tool(agent.tools)]
        input_valid = Future{Bool}(() -> (agent.input_guardrail === nothing || !(input isa String)) ? true : agent.input_guardrail(agent.prompt, input, apikey))
        f(AgentEvaluateStartEvent())
        turn = 1
        f(TurnStartEvent(turn))
        if haskey(kw, :systemInstruction)
            system_instruction = kw[:systemInstruction]
            system_instruction isa String && (system_instruction = GoogleGeminiCli.Content(; parts=[GoogleGeminiCli.Part(; text=system_instruction)]))
        else
            system_instruction = GoogleGeminiCli.Content(; parts=[GoogleGeminiCli.Part(; text=agent.prompt)])
        end
        local contents
        if input isa Vector{PendingToolCall}
            resolved_calls, context = resolve_cached_tool_calls!(input)
            context.provider != model.api && throw(ArgumentError("pending tool calls are cached for $(context.provider), not $(model.api)"))
            previous_response_id = context.response_id
            state = context.state
            state === nothing && throw(ArgumentError("missing cached state for google-gemini-cli"))
            system_instruction = state.system_instruction
            contents = state.contents
            tool_results = Future{ToolResultMessage}[]
            for tc in resolved_calls
                tool = findtool(agent.tools, tc.name)
                f(ToolExecutionStartEvent(tc))
                if tc.approved
                    push!(tool_results, call_function_tool!(f, tool, tc))
                else
                    push!(tool_results, reject_function_tool!(f, tc, tc))
                end
            end
            clear_cached_tool_calls!([tc.call_id for tc in resolved_calls])
            response_parts = GoogleGeminiCli.Part[]
            for trm in tool_results
                result = wait(trm)
                response_payload = result.is_error ? Dict("error" => result.output) : Dict("output" => result.output)
                push!(response_parts, GoogleGeminiCli.Part(; functionResponse=GoogleGeminiCli.FunctionResponse(; id=result.call_id, name=result.name, response=response_payload)))
            end
            if !isempty(response_parts)
                push!(contents, GoogleGeminiCli.Content(; role="user", parts=response_parts))
            end
        else
            contents = GoogleGeminiCli.Content[]
            push!(contents, GoogleGeminiCli.Content(; role="user", parts=[GoogleGeminiCli.Part(; text=input)]))
        end
        pending_tool_calls = PendingToolCall[]
        while true
            assistant_message = AssistantTextMessage(; response_id=previous_response_id)
            assistant_started = false
            assistant_ended = false
            empty!(pending_tool_calls)
            assistant_parts = GoogleGeminiCli.Part[]
            seen_call_ids = Set{String}()
            stream_kw = haskey(kw, :instructions) ? Base.structdiff(kw, (; instructions=nothing)) : kw
            if haskey(stream_kw, :systemInstruction)
                GoogleGeminiCli.stream(model, contents, apikey; tools, http_kw, stream_kw...) do http_stream, event
                    if !wait(input_valid)
                        close(http_stream)
                        f(AgentErrorEvent(InvalidInputError(input isa String ? input : "<non-string input>")))
                        return
                    end
                    if event isa GoogleGeminiCli.StreamChunk
                        if event.response !== nothing && event.response.responseId !== nothing
                            previous_response_id = event.response.responseId
                            assistant_message.response_id = previous_response_id
                        end
                        response = event.response
                        response === nothing && return
                        response.candidates === nothing && return
                        isempty(response.candidates) && return
                        candidate = response.candidates[1]
                        candidate.content === nothing && return
                        candidate.content.parts === nothing && return
                        for part in candidate.content.parts
                            if part.text !== nothing
                                if !assistant_started
                                    assistant_started = true
                                    f(MessageStartEvent(:assistant, assistant_message))
                                end
                                if part.thought === true
                                    assistant_message.reasoning *= part.text
                                    f(MessageUpdateEvent(:assistant, assistant_message, :reasoning, part.text, nothing))
                                    if !isempty(assistant_parts) && assistant_parts[end].thought === true
                                        assistant_parts[end].text *= part.text
                                    else
                                        push!(assistant_parts, GoogleGeminiCli.Part(; text=part.text, thought=true, thoughtSignature=part.thoughtSignature))
                                    end
                                else
                                    assistant_message.text *= part.text
                                    f(MessageUpdateEvent(:assistant, assistant_message, :text, part.text, nothing))
                                    if !isempty(assistant_parts) && assistant_parts[end].text !== nothing && assistant_parts[end].thought !== true
                                        assistant_parts[end].text *= part.text
                                    else
                                        push!(assistant_parts, GoogleGeminiCli.Part(; text=part.text))
                                    end
                                end
                            elseif part.functionCall !== nothing
                                if !assistant_started
                                    assistant_started = true
                                    f(MessageStartEvent(:assistant, assistant_message))
                                end
                                fc = part.functionCall
                                fc.name === nothing && throw(ArgumentError("function call missing name"))
                                call_id = fc.id === nothing || fc.id in seen_call_ids ? new_call_id("gemini-cli") : fc.id
                                push!(seen_call_ids, call_id)
                                args_json = fc.args === nothing ? "{}" : JSON.json(fc.args)
                                ptc = PendingToolCall(; call_id=call_id, name=fc.name, arguments=args_json)
                                push!(pending_tool_calls, ptc)
                                tool = findtool(agent.tools, ptc.name)
                                f(ToolCallRequestEvent(ptc, tool.requires_approval))
                                push!(assistant_parts, GoogleGeminiCli.Part(; functionCall=GoogleGeminiCli.FunctionCall(; id=call_id, name=fc.name, args=fc.args), thoughtSignature=part.thoughtSignature))
                            end
                        end
                    elseif event isa GoogleGeminiCli.StreamDoneEvent
                        if assistant_started && !assistant_ended
                            assistant_ended = true
                            f(MessageEndEvent(:assistant, assistant_message))
                        end
                    elseif event isa GoogleGeminiCli.StreamErrorEvent
                        if assistant_started && !assistant_ended
                            assistant_ended = true
                            f(MessageEndEvent(:assistant, assistant_message))
                        end
                        f(AgentErrorEvent(ErrorException(event.message)))
                    end
                end
            else
                GoogleGeminiCli.stream(model, contents, apikey; tools, systemInstruction=system_instruction, http_kw, stream_kw...) do http_stream, event
                    if !wait(input_valid)
                        close(http_stream)
                        f(AgentErrorEvent(InvalidInputError(input isa String ? input : "<non-string input>")))
                        return
                    end
                    if event isa GoogleGeminiCli.StreamChunk
                        if event.response !== nothing && event.response.responseId !== nothing
                            previous_response_id = event.response.responseId
                            assistant_message.response_id = previous_response_id
                        end
                        response = event.response
                        response === nothing && return
                        response.candidates === nothing && return
                        isempty(response.candidates) && return
                        candidate = response.candidates[1]
                        candidate.content === nothing && return
                        candidate.content.parts === nothing && return
                        for part in candidate.content.parts
                            if part.text !== nothing
                                if !assistant_started
                                    assistant_started = true
                                    f(MessageStartEvent(:assistant, assistant_message))
                                end
                                if part.thought === true
                                    assistant_message.reasoning *= part.text
                                    f(MessageUpdateEvent(:assistant, assistant_message, :reasoning, part.text, nothing))
                                    if !isempty(assistant_parts) && assistant_parts[end].thought === true
                                        assistant_parts[end].text *= part.text
                                    else
                                        push!(assistant_parts, GoogleGeminiCli.Part(; text=part.text, thought=true, thoughtSignature=part.thoughtSignature))
                                    end
                                else
                                    assistant_message.text *= part.text
                                    f(MessageUpdateEvent(:assistant, assistant_message, :text, part.text, nothing))
                                    if !isempty(assistant_parts) && assistant_parts[end].text !== nothing && assistant_parts[end].thought !== true
                                        assistant_parts[end].text *= part.text
                                    else
                                        push!(assistant_parts, GoogleGeminiCli.Part(; text=part.text))
                                    end
                                end
                            elseif part.functionCall !== nothing
                                if !assistant_started
                                    assistant_started = true
                                    f(MessageStartEvent(:assistant, assistant_message))
                                end
                                fc = part.functionCall
                                fc.name === nothing && throw(ArgumentError("function call missing name"))
                                call_id = fc.id === nothing || fc.id in seen_call_ids ? new_call_id("gemini-cli") : fc.id
                                push!(seen_call_ids, call_id)
                                args_json = fc.args === nothing ? "{}" : JSON.json(fc.args)
                                ptc = PendingToolCall(; call_id=call_id, name=fc.name, arguments=args_json)
                                push!(pending_tool_calls, ptc)
                                tool = findtool(agent.tools, ptc.name)
                                f(ToolCallRequestEvent(ptc, tool.requires_approval))
                                push!(assistant_parts, GoogleGeminiCli.Part(; functionCall=GoogleGeminiCli.FunctionCall(; id=call_id, name=fc.name, args=fc.args), thoughtSignature=part.thoughtSignature))
                            end
                        end
                    elseif event isa GoogleGeminiCli.StreamDoneEvent
                        if assistant_started && !assistant_ended
                            assistant_ended = true
                            f(MessageEndEvent(:assistant, assistant_message))
                        end
                    elseif event isa GoogleGeminiCli.StreamErrorEvent
                        if assistant_started && !assistant_ended
                            assistant_ended = true
                            f(MessageEndEvent(:assistant, assistant_message))
                        end
                        f(AgentErrorEvent(ErrorException(event.message)))
                    end
                end
            end
            if assistant_started && !assistant_ended
                f(MessageEndEvent(:assistant, assistant_message))
            end
            if !wait(input_valid)
                throw(ArgumentError("input_guardrail check failed for input: `$input`"))
            end
            if !isempty(assistant_parts)
                push!(contents, GoogleGeminiCli.Content(; role="model", parts=assistant_parts))
            end
            requires_approval = PendingToolCall[]
            for ptc in pending_tool_calls
                tool = findtool(agent.tools, ptc.name)
                if tool.requires_approval
                    push!(requires_approval, ptc)
                end
            end
            if isempty(pending_tool_calls) || !isempty(requires_approval)
                response_id = ensure_response_id(previous_response_id)
                if !isempty(requires_approval)
                    cache_tool_calls!(requires_approval, CachedToolCallContext(model.api, response_id, (; system_instruction=system_instruction, contents=copy(contents))))
                end
                result = Result(; previous_response_id=response_id, pending_tool_calls=requires_approval)
                f(AgentEvaluateEndEvent(result))
                return result
            end
            tool_results = Future{ToolResultMessage}[]
            for tc in pending_tool_calls
                tool = findtool(agent.tools, tc.name)
                f(ToolExecutionStartEvent(tc))
                push!(tool_results, call_function_tool!(f, tool, tc))
            end
            response_parts = GoogleGeminiCli.Part[]
            for trm in tool_results
                result = wait(trm)
                response_payload = result.is_error ? Dict("error" => result.output) : Dict("output" => result.output)
                push!(response_parts, GoogleGeminiCli.Part(; functionResponse=GoogleGeminiCli.FunctionResponse(; id=result.call_id, name=result.name, response=response_payload)))
            end
            if !isempty(response_parts)
                push!(contents, GoogleGeminiCli.Content(; role="user", parts=response_parts))
            end
            f(TurnEndEvent(turn, assistant_started ? assistant_message : nothing, pending_tool_calls))
            turn += 1
            f(TurnStartEvent(turn))
        end
    end
end

evaluate(args...; kw...) = wait(evaluate!(args...; kw...))

function call_function_tool!(f, tool::AgentTool, tc::PendingToolCall)
    return Future{ToolResultMessage}() do
        args = JSON.parse(tc.arguments, parameters(tool))
        is_error = false
        output = ""
    try
        output = string(tool.func(args...))
    catch e
        is_error = true
        output = sprint(showerror, e)
    end
        trm = ToolResultMessage(; output, is_error, call_id=tc.call_id, name=tc.name, arguments=tc.arguments)
        f(ToolExecutionEndEvent(tc, trm))
        return trm
    end
end

function reject_function_tool!(f, tc::PendingToolCall, pending::PendingToolCall)
    trm = ToolResultMessage(; output=pending.rejected_reason, is_error=true, call_id=tc.call_id, name=tc.name, arguments=tc.arguments)
    f(ToolExecutionEndEvent(tc, trm))
    return Future{ToolResultMessage}(() -> trm)
end
