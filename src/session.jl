using UUIDs

abstract type SessionStore end

mutable struct InMemorySessionStore <: SessionStore
    sessions::Dict{String,AgentState}
end

InMemorySessionStore() = InMemorySessionStore(Dict{String,AgentState}())

function load_session(store::InMemorySessionStore, session_id::String)
    return get!(store.sessions, session_id) do
        AgentState()
    end
end

function save_session!(store::InMemorySessionStore, session_id::String, state::AgentState)
    store.sessions[session_id] = state
    return nothing
end

mutable struct AgentSession{S<:SessionStore}
    agent::Agent
    store::S
    session_id::String
end

function AgentSession(agent::Agent; store::SessionStore=InMemorySessionStore(), session_id::Union{Nothing,String}=nothing)
    sid = session_id === nothing ? string(UUIDs.uuid4()) : session_id
    return AgentSession{typeof(store)}(agent, store, sid)
end

function evaluate!(agent_session::AgentSession, input::Union{String,Vector{PendingToolCall}}, apikey::String;
        model::Union{Nothing, Model} = nothing, stream_output::Bool = isinteractive(),
        stream_reasoning::Bool = true, kw...)
    return evaluate!(agent_session, input, apikey; model, kw...) do event
        if event isa MessageUpdateEvent
            if event.kind == :text || (stream_reasoning && event.kind == :reasoning)
                if stream_output
                    print(event.delta)
                    flush(stdout)
                end
            end
        elseif event isa MessageEndEvent
            if stream_output
                println()
                flush(stdout)
            end
        end
    end
end

function evaluate!(f::Function, agent_session::AgentSession, input::Union{String,Vector{PendingToolCall}}, apikey::String;
        model::Union{Nothing, Model} = nothing, http_kw=(;), kw...)
    return Future{AgentResult}() do
        state = load_session(agent_session.store, agent_session.session_id)
        result = evaluate(f, agent_session.agent, input, apikey; model, state, http_kw, kw...)
        save_session!(agent_session.store, agent_session.session_id, state)
        return result
    end
end

evaluate(args...; kw...) = wait(evaluate!(args...; kw...))
