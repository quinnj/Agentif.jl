isdefined(@__MODULE__, :durable_fixture) || include("durable_fixtures.jl")
using LocalSearch

function integration_until(f;seconds=30)
    @test timedwait(f,seconds;pollint=.02)===:ok
end

mutable struct DurableChannel <: Agentif.AbstractChannel
    id::String
    parent::Union{Nothing,String}
    cutoff::Union{Nothing,String}
    private::Bool
    post::String
    responses::Vector{String}
    closed::Bool
end
DurableChannel(id;parent=nothing,cutoff=nothing,private=true,post=id)=DurableChannel(id,parent,cutoff,private,post,String[],false)
Agentif.channel_id(c::DurableChannel)=c.id
Agentif.branch_id(c::DurableChannel)=c.id
Agentif.parent_branch_id(c::DurableChannel)=c.parent
Agentif.branch_entry_id(c::DurableChannel)=c.cutoff
Agentif.entry_id(c::DurableChannel)=c.post
Agentif.response_entry_id(c::DurableChannel)=isempty(c.responses) ? nothing : "response:$(c.post)"
Agentif.search_channel_id(c::DurableChannel)=something(c.parent,c.id)
Agentif.is_private(c::DurableChannel)=c.private
Agentif.is_group(c::DurableChannel)=c.parent!==nothing
Agentif.get_current_user(::DurableChannel)=Agentif.ChannelUser("u","user")
Agentif.send_message(c::DurableChannel,text)=(push!(c.responses,string(text));nothing)
Agentif.close_channel(c::DurableChannel)=(c.closed=true;nothing)
struct DurableEvent <: Claw.ChannelEvent
    channel::DurableChannel
    text::String
end
Claw.get_name(::DurableEvent)="durable-event"
Claw.get_channel(e::DurableEvent)=e.channel
Claw.event_content(e::DurableEvent)=e.text
Claw.event_extra(e::DurableEvent)=Dict{String,Any}("source_id"=>e.channel.post)

function attached_fixture(path;stream=durable_stream,embed=nothing,watcher=nothing,jev=nothing,limits=Claw.HarnessLimits(;retry_delays=[.01,.01,.01,.01]))
    Agentif.registerModel!(durable_model())
    a=Claw.AgentAssistant(path;provider="test",model_id="durable-test",apikey="secret-test-key",
        base_dir=dirname(path),search_options=(;embed),level=:error,watcher,jev)
    a._owner_lock[]=Claw._acquire_owner_lock(path)
    Claw._advance_owner_epoch!(a)
    h=Claw.open_harness(a;stream_fn=stream,limits,compaction=Agentif.CompactionConfig(;enabled=false))
    Claw._register_native_delivery!(h,a)
    a,h
end
