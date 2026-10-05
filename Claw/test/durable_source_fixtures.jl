isdefined(@__MODULE__, :attached_fixture) || include("durable_integration_fixtures.jl")

struct DurableRelevanceEvent <: Claw.ChannelEvent
    channel::DurableChannel
    text::String
end
Claw.get_name(::DurableRelevanceEvent)="durable-relevance"
Claw.get_channel(e::DurableRelevanceEvent)=e.channel
Claw.event_content(e::DurableRelevanceEvent)=e.text
Claw.event_source_tag(::DurableRelevanceEvent)="durable-relevance"
Claw.event_extra(e::DurableRelevanceEvent)=Dict{String,Any}("source_id"=>e.channel.post)
Claw.is_trusted_content(::DurableRelevanceEvent)=false

durable_jev()=Claw.JevConfig(Claw.JevSDK.Client("fixture-key";base_url="http://127.0.0.1:1",connect_timeout=.2,request_timeout=.2);
    allowed_sources=["durable-relevance"])
durable_policy()=Claw.EventRelevancePolicy("durable recovery","Keep possibly relevant work; reject clearly irrelevant work";deduplicate=false)
function durable_relevance_response(request;reject=Int[])
    answers=Dict{String,Claw.JevSDK.Answer}()
    for (key,q) in request.questions
        id=parse(Int,last(split(key,"_")))
        answers[key]=Claw.JevSDK.NoulAnswer(id in reject ? .001 : .9)
    end
    Claw.JevSDK.SystemOneResponse("fixture-jev",answers,Claw.JevSDK.Usage(;input_tokens=10,output_tokens=2))
end
function source_claims(a,texts)
    [begin
        ev=DurableRelevanceEvent(DurableChannel("source";post="post:$i"),text)
        id=Claw.submit_event!(a,ev;dedup_key="fixture:$i:$text")
        (Claw._claim_event!(a,id),ev)
    end for (i,text) in enumerate(texts)]
end
function durable_source_rehydrate!(a)
    Claw.register_rehydrator!("durable-relevance",row->DurableRelevanceEvent(
        DurableChannel(something(row.channel_id,"source");post=string(get(row.extra,"source_id","post"))),row.content))
end
