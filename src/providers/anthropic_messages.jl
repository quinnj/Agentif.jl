module AnthropicMessages

using StructUtils, JSON, HTTP

import ..Model, ..AgentTool, ..parameters, ..ToolResultMessage

schema(::Type{T}) where {T} = JSON.schema(T; all_fields_required=true, additionalProperties=false)

@omit_null @kwarg mutable struct TextBlock
    type::String = "text"
    text::String
end

@omit_null @kwarg mutable struct ToolUseBlock
    type::String = "tool_use"
    id::String
    name::String
    input::Any
end

@omit_null @kwarg struct ToolResultBlock
    type::String = "tool_result"
    tool_use_id::String
    content::Union{String,Vector{TextBlock}}
    is_error::Union{Nothing,Bool} = nothing
end

const ContentBlock = Union{TextBlock, ToolUseBlock, ToolResultBlock}

JSON.@choosetype ContentBlock x -> begin
    type = x.type[]
    if type == "text"
        return TextBlock
    elseif type == "tool_use"
        return ToolUseBlock
    elseif type == "tool_result"
        return ToolResultBlock
    else
        return Any
    end
end

@omit_null @kwarg struct Message
    role::String
    content::Union{String,Vector{ContentBlock}} &(json=(choosetype=x->x[] isa String ? String : Vector{ContentBlock},),)
end

@omit_null @kwarg struct Tool{T}
    name::String
    description::Union{Nothing,String} = nothing
    input_schema::JSON.Schema{T}
end

function Tool(tool::AgentTool)
    return Tool(
        name=tool.name,
        description=tool.description,
        input_schema=schema(parameters(tool))
    )
end

@omit_null @kwarg struct Usage
    input_tokens::Union{Nothing,Int} = nothing
    output_tokens::Union{Nothing,Int} = nothing
    cache_creation_input_tokens::Union{Nothing,Int} = nothing
    cache_read_input_tokens::Union{Nothing,Int} = nothing
end

@omit_null @kwarg struct ResponseMessage
    id::Union{Nothing,String} = nothing
    role::String
    content::Vector{ContentBlock} = ContentBlock[]
    model::Union{Nothing,String} = nothing
    stop_reason::Union{Nothing,String} = nothing
    stop_sequence::Union{Nothing,String} = nothing
    usage::Union{Nothing,Usage} = nothing
end

@omit_null @kwarg struct Response
    id::String
    content::Vector{ContentBlock} = ContentBlock[]
    model::String
    role::String
    stop_reason::Union{Nothing,String} = nothing
    stop_sequence::Union{Nothing,String} = nothing
    usage::Union{Nothing,Usage} = nothing
end

@omit_null @kwarg struct TextDelta
    type::String = "text_delta"
    text::String
end

@omit_null @kwarg struct InputJsonDelta
    type::String = "input_json_delta"
    partial_json::String
end

const ContentBlockDelta = Union{TextDelta, InputJsonDelta}

JSON.@choosetype ContentBlockDelta x -> begin
    type = x.type[]
    if type == "text_delta"
        return TextDelta
    elseif type == "input_json_delta"
        return InputJsonDelta
    else
        return Any
    end
end

@omit_null @kwarg struct StreamMessageStartEvent
    type::String = "message_start"
    message::ResponseMessage
end

@omit_null @kwarg struct StreamContentBlockStartEvent
    type::String = "content_block_start"
    index::Int
    content_block::ContentBlock
end

@omit_null @kwarg struct StreamContentBlockDeltaEvent
    type::String = "content_block_delta"
    index::Int
    delta::ContentBlockDelta
end

@omit_null @kwarg struct StreamContentBlockStopEvent
    type::String = "content_block_stop"
    index::Int
end

@omit_null @kwarg struct StreamMessageDeltaEvent
    type::String = "message_delta"
    delta::Any = nothing
    usage::Union{Nothing,Usage} = nothing
end

@omit_null @kwarg struct StreamMessageStopEvent
    type::String = "message_stop"
end

@omit_null @kwarg struct StreamErrorEvent
    type::String = "error"
    error::Any = nothing
end

const StreamEvent = Union{
    StreamMessageStartEvent,
    StreamContentBlockStartEvent,
    StreamContentBlockDeltaEvent,
    StreamContentBlockStopEvent,
    StreamMessageDeltaEvent,
    StreamMessageStopEvent,
    StreamErrorEvent,
}

JSON.@choosetype StreamEvent x -> begin
    type = x.type[]
    if type == "message_start"
        return StreamMessageStartEvent
    elseif type == "content_block_start"
        return StreamContentBlockStartEvent
    elseif type == "content_block_delta"
        return StreamContentBlockDeltaEvent
    elseif type == "content_block_stop"
        return StreamContentBlockStopEvent
    elseif type == "message_delta"
        return StreamMessageDeltaEvent
    elseif type == "message_stop"
        return StreamMessageStopEvent
    elseif type == "error"
        return StreamErrorEvent
    else
        return Any
    end
end

@omit_null @kwarg struct Request
    model::String
    messages::Vector{Message}
    max_tokens::Int
    system::Union{Nothing,String} = nothing
    tools::Union{Nothing,Vector{Tool}} = nothing
    tool_choice::Union{Nothing,Any} = nothing
    stream::Union{Nothing,Bool} = nothing
    temperature::Union{Nothing,Float64} = nothing
    top_p::Union{Nothing,Float64} = nothing
    stop_sequences::Union{Nothing,Vector{String}} = nothing
end

function get_sse_callback(f)
    function sse_callback(stream, event::HTTP.SSEEvent)
        try
            f(stream, JSON.parse(event.data, StreamEvent))
        catch e
            f(stream, StreamErrorEvent(; error=Dict("message" => sprint(showerror, e))))
        end
    end
end

function stream(f::Function, model::Model, messages::Vector{Message}, apikey::String; http_kw=(;), kw...)
    max_tokens = haskey(kw, :max_tokens) ? kw[:max_tokens] : model.maxTokens
    kw_no_max_tokens = haskey(kw, :max_tokens) ? Base.structdiff(kw, (; max_tokens=0)) : kw
    req = Request(; model=model.id, messages, max_tokens, stream=true, model.kw..., kw_no_max_tokens...)
    headers = Dict(
        "x-api-key" => apikey,
        "anthropic-version" => "2023-06-01",
        "Content-Type" => "application/json",
    )
    model.headers !== nothing && merge!(headers, model.headers)
    url = joinpath(model.baseUrl, "v1", "messages")
    HTTP.post(url, headers; body=JSON.json(req), sse_callback=get_sse_callback(f), http_kw...)
end

function request(model::Model, messages::Vector{Message}, apikey::String; http_kw=(;), kw...)
    max_tokens = haskey(kw, :max_tokens) ? kw[:max_tokens] : model.maxTokens
    kw_no_max_tokens = haskey(kw, :max_tokens) ? Base.structdiff(kw, (; max_tokens=0)) : kw
    req = Request(; model=model.id, messages, max_tokens, stream=false, model.kw..., kw_no_max_tokens...)
    headers = Dict(
        "x-api-key" => apikey,
        "anthropic-version" => "2023-06-01",
        "Content-Type" => "application/json",
    )
    model.headers !== nothing && merge!(headers, model.headers)
    url = joinpath(model.baseUrl, "v1", "messages")
    return JSON.parse(HTTP.post(url, headers; body=JSON.json(req), http_kw...).body, Response)
end

end # module AnthropicMessages
