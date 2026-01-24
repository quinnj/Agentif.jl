using UUIDs

abstract type SessionStore end

struct InMemorySessionStore <: SessionStore
    sessions::Dict{String, AgentState}
end

InMemorySessionStore() = InMemorySessionStore(Dict{String, AgentState}())

struct FileSessionStore <: SessionStore
    directory::String
end

function FileSessionStore(directory::AbstractString)
    dir = abspath(directory)
    mkpath(dir)
    return FileSessionStore(dir)
end

function ensure_session_id(session_id::String)
    isempty(session_id) && throw(ArgumentError("session_id is required"))
    occursin(r"[\\/]", session_id) && throw(ArgumentError("session_id must not contain path separators: $session_id"))
    return session_id
end

function session_path(store::FileSessionStore, session_id::String)
    sid = ensure_session_id(session_id)
    return joinpath(store.directory, sid)
end

function load_session(store::InMemorySessionStore, session_id::String)
    return get!(store.sessions, session_id) do
        AgentState()
    end
end

function load_session(store::FileSessionStore, session_id::String)
    sid = ensure_session_id(session_id)
    path = session_path(store, sid)
    state = nothing
    if isfile(path)
        try
            state = JSON.parsefile(path, AgentState)
        catch
            state = nothing
        end
    end
    state === nothing && (state = AgentState())
    return state
end

function save_session!(store::InMemorySessionStore, session_id::String, state::AgentState)
    store.sessions[session_id] = state
    return
end

function save_session!(store::FileSessionStore, session_id::String, state::AgentState)
    sid = ensure_session_id(session_id)
    path = session_path(store, sid)
    open(path, "w") do io
        write(io, JSON.json(state))
    end
    return
end

mutable struct AgentSession{T <: AgentContext, S <: SessionStore} <: AgentContext
    ctx::T
    store::S
    session_id::String
end

function AgentSession(ctx::AgentContext; store::SessionStore = InMemorySessionStore(), session_id::Union{Nothing, String} = nothing)
    sid = session_id === nothing ? string(UUIDs.uuid4()) : session_id
    return AgentSession(ctx, store, sid)
end

function get_agent(x::AgentSession)
    agent = get_agent(x.ctx)
    set!(agent.state, load_session(x.store, x.session_id))
    return agent
end

function session_agent(session::AgentSession)
    ctx = session.ctx
    while ctx isa AgentSession
        ctx = ctx.ctx
    end
    return get_agent(ctx)
end

function handle_event(session::AgentSession, event)
    if event isa AgentEvaluateEndEvent
        agent = session_agent(session)
        save_session!(session.store, session.session_id, agent.state)
    end
    return
end
