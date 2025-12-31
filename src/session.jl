using UUIDs

abstract type SessionStore end

struct InMemorySessionStore <: SessionStore
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

mutable struct AgentSession{S<:SessionStore} <: AgentContext
    agent::Agent
    store::S
    session_id::String
end

function AgentSession(agent::Agent; store::SessionStore=InMemorySessionStore(), session_id::Union{Nothing,String}=nothing)
    sid = session_id === nothing ? string(UUIDs.uuid4()) : session_id
    return AgentSession{typeof(store)}(agent, store, sid)
end

function get_agent(x::AgentSession)
    agent = x.agent
    set!(agent.state, load_session(x.store, x.session_id))
    return agent
end

function handle_event(session::AgentSession, event)
    if event isa AgentEvaluateEndEvent
        save_session!(session.store, session.session_id, session.agent.state)
    end
end
