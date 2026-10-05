struct SubmissionConflict <: Exception
    request_id::String
end
Base.showerror(io::IO, e::SubmissionConflict) = print(io, "submission conflicts with immutable request ", e.request_id)
struct StaleInvocation <: Exception end
struct HarnessPoisoned <: Exception end
struct DurableBlocked <: Exception
    reason::String
end
Base.showerror(io::IO,e::DurableBlocked)=print(io,e.reason)
struct ConversationRef
    id::String
end
struct AgentProfileRef
    id::String
end
struct DeliveryAddress
    adapter::String
    version::Int
    routing::Dict{String, Any}
end
struct SubmissionReceipt
    harness::Any
    id::String
end

"""Versioned replay permission. Legacy tools are unsafe and opaque by default.

`invoke(tool, parsed, context)` can return ToolOutcome. `reconcile(intent)` returns
`:retry`, a proven ToolOutcome, or `nothing` (uncertain); this is an explicit
protocol, never an inference from a tool name. The version covers adapter code.
"""
struct ToolSpec
    tool::Agentif.AgentTool
    version::String
    replay::Symbol
    execution::Symbol
    effect::Symbol
    capabilities::Vector{String}
    invoke::Function
    reconcile::Union{Nothing, Function}
end
function ToolSpec(tool::Agentif.AgentTool; version::String = "legacy-v1", replay::Symbol = :unsafe,
        execution::Symbol = :parallel, effect::Symbol = :opaque, capabilities = String[],
        invoke::Function = Agentif.invoke_tool, reconcile = nothing)
    replay in (:safe, :unsafe) || throw(ArgumentError("replay must be safe or unsafe"))
    execution in (:parallel, :sequential) || throw(ArgumentError("invalid tool execution contract"))
    return ToolSpec(tool, version, replay, execution, effect, sort!(unique(String.(capabilities))), invoke, reconcile)
end

struct DeliveryAdapter
    version::Int
    capability::Symbol   # :unsafe, :idempotent, :reconcile
    send::Function       # (address, body, stable_key) -> serializable remote receipt
    reconcile::Union{Nothing, Function}
    available::Function
end
function DeliveryAdapter(send::Function; version::Int = 1, capability::Symbol = :unsafe, reconcile = nothing, available = address -> true)
    capability in (:unsafe, :idempotent, :reconcile) || throw(ArgumentError("invalid delivery capability"))
    capability === :reconcile && reconcile === nothing && throw(ArgumentError("reconcile callback required"))
    DeliveryAdapter(version, capability, send, reconcile, available)
end

Base.@kwdef struct HarnessLimits
    models::Int = 4
    tools::Int = 4
    attempts::Int = 5
    retry_delays::Vector{Float64} = [1, 5, 30, 60]
    max_retry_delay::Float64 = 300
    progress_bytes::Int = 16000
    progress_interval::Float64 = 0.25
    tool_timeout::Float64 = 300
    request_timeout::Float64 = 900
    run_timeout::Float64 = 3600
    observer_frames::Int = 100
end

mutable struct Harness
    assistant::Any
    writer::SQLiteWriter
    readers::ReaderPool
    history::Agentif.SessionStore
    epoch::Int
    owner::Union{Nothing, IOStream}
    owns_connections::Bool
    agents::Dict{String, Agentif.Agent}
    specs::Dict{Tuple{String, String}, ToolSpec}
    environments::Dict{String, LLMTools.LocalExecutionEnv}
    adapters::Dict{String, DeliveryAdapter}
    limits::HarnessLimits
    compaction::Agentif.CompactionConfig
    stream_fn::Function
    clock::Function
    fault::Function
    state::Symbol
    lock::ReentrantLock
    live::Dict{String, Any}
    observers::Vector{Any}
    scheduler::Union{Nothing, Task}
    wake::Threads.Event
    indexer::Union{Nothing,Task}
    supervision_due::Float64
    due_timers::Dict{String,Tuple{Float64,Float64}}
end

struct InvocationContext
    harness::Harness
    task_id::String
    epoch::Int
    token::String
    revision::Base.RefValue{Int}
    abort::Agentif.Abort
    deadline::Float64
    monotonic_deadline::Float64
    lock::ReentrantLock
    last_progress::Base.RefValue{Float64}
    heartbeat::Base.RefValue{Float64}
end

struct DurableSessionReader <: Agentif.SessionStore
    readers::ReaderPool
end
Agentif.get_branch_leaf(s::DurableSessionReader, id::String) = with_read(s.readers) do db
    rows = _drows(db, "SELECT leaf_entry_id FROM session_branches WHERE branch_id=?", (id,))
    isempty(rows) ? nothing : _dnull(rows[1].leaf_entry_id)
end
Agentif.get_entry(s::DurableSessionReader, id::String) = with_read(s.readers) do db
    rows = _drows(db, "SELECT entry,is_deleted FROM session_entries WHERE entry_id=?", (id,))
    isempty(rows) && return nothing
    entry = JSON.parse(rows[1].entry, Agentif.SessionEntry)
    rows[1].is_deleted == 0 && return entry
    Agentif.SessionEntry(; id = entry.id, parent_id = entry.parent_id, is_deleted = true)
end

_did() = string(Agentif.UID8())
_dmono() = time_ns()/1e9
_dnull(x) = x === missing || x === nothing ? nothing : x
function _canonical(x)
    x isa AbstractDict && return "{" * join((JSON.json(String(k)) * ":" * _canonical(x[k]) for k in sort!(collect(keys(x)); by = String)), ",") * "}"
    x isa NamedTuple && return _canonical(Dict(String(k) => v for (k,v) in pairs(x)))
    x isa AbstractVector && return "[" * join(_canonical.(x), ",") * "]"
    return JSON.json(x)
end
_digest(x) = bytes2hex(SHA.sha256(_canonical(x)))
function _profile_config(value)
    if value isa AbstractDict
        return Dict(String(k)=>_profile_config(v) for (k,v) in value if
            String(k) in ("maxTokens","max_tokens","max_completion_tokens","maxOutputTokens","max_output_tokens","contextWindow","reserve_tokens") || !_is_sensitive_integration_key(k))
    elseif value isa AbstractVector
        return _profile_config.(value)
    end
    value
end
_profile_model(model) = _profile_config(JSON.parse(JSON.json(model)))

# The limit includes JSON escaping and its wrapper, and always leaves valid UTF-8
# and JSON. Truncating serialized bytes directly would corrupt the checkpoint.
function _bounded_json(value,limit::Int)
    payload=JSON.json(value)
    sizeof(payload)<=limit && return payload
    text=payload
    lo=0;hi=length(text)
    while lo<hi
        mid=cld(lo+hi,2)
        sizeof(JSON.json(Dict("truncated"=>true,"text"=>first(text,mid))))<=limit ? (lo=mid) : (hi=mid-1)
    end
    JSON.json(Dict("truncated"=>true,"text"=>first(text,lo)))
end
_env_data(r::LLMTools.EnvRef) = Dict("kind"=>r.kind,"id"=>r.id,"version"=>r.version,"root"=>r.root,"capabilities"=>r.capabilities)
_spec_data(s::ToolSpec) = Dict("name"=>s.tool.name,"description"=>s.tool.description,"version"=>s.version,"schema"=>_digest(JSON.parse(JSON.json(Agentif.OpenAICompletions.schema(Agentif.parameters(s.tool))))),
    "replay"=>String(s.replay),"execution"=>String(s.execution),"effect"=>String(s.effect),"capabilities"=>s.capabilities)

function _drows(db, sql, params = ())
    cursor = SQLite.DBInterface.execute(db, sql, params)
    try
        return [NamedTuple{Tuple(propertynames(r))}(Tuple(r[k] for k in propertynames(r))) for r in cursor]
    finally
        SQLite.DBInterface.close!(cursor)
    end
end
_done(db, sql, params = ()) = begin
    rows = _drows(db, sql, params)
    isempty(rows) ? nothing : rows[1]
end
_dread(f, h::Harness) = execute_write(f, h.writer)

function _diagnostic(h::Harness, error)
    text = first(sprint(showerror, error), 4000)
    for agent in values(h.agents)
        isempty(agent.apikey) || (text = replace(text, agent.apikey => "[redacted]"))
    end
    return replace(text, r"(?i)(bearer\s+|api[_-]?key[=: ]+|token[=: ]+)[A-Za-z0-9_./+\-=]+" => s"\1[redacted]")
end
