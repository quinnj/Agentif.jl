struct CachedToolCallContext
    provider::String
    response_id::String
    state::Any
end

const _tool_call_cache = Dict{String,PendingToolCall}()
const _tool_call_context_cache = Dict{String,CachedToolCallContext}()
const _tool_call_cache_lock = ReentrantLock()

function cache_tool_calls!(pending_tool_calls::Vector{PendingToolCall}, context::CachedToolCallContext)
    lock(_tool_call_cache_lock)
    try
        for ptc in pending_tool_calls
            _tool_call_cache[ptc.call_id] = ptc
            _tool_call_context_cache[ptc.call_id] = context
        end
    finally
        unlock(_tool_call_cache_lock)
    end
    return pending_tool_calls
end

function resolve_cached_tool_calls!(pending_tool_calls::Vector{PendingToolCall})
    resolved = PendingToolCall[]
    context = nothing
    lock(_tool_call_cache_lock)
    try
        for ptc in pending_tool_calls
            ptc.approved === nothing && throw(ArgumentError("pending tool calls must be approved or rejected before continuing"))
            cached = get(() -> nothing, _tool_call_cache, ptc.call_id)
            cached === nothing && throw(ArgumentError("unknown tool call id: $(ptc.call_id)"))
            cached.approved = ptc.approved
            cached.rejected_reason = ptc.rejected_reason
            push!(resolved, cached)
            cached_context = get(() -> nothing, _tool_call_context_cache, ptc.call_id)
            cached_context === nothing && throw(ArgumentError("missing context for tool call id: $(ptc.call_id)"))
            if context === nothing
                context = cached_context
            elseif cached_context.response_id != context.response_id
                throw(ArgumentError("pending tool calls originate from different contexts: $(context.response_id) vs $(cached_context.response_id)"))
            end
        end
    finally
        unlock(_tool_call_cache_lock)
    end
    return resolved, context
end

function clear_cached_tool_calls!(call_ids::Vector{String})
    lock(_tool_call_cache_lock)
    try
        for call_id in call_ids
            delete!(_tool_call_cache, call_id)
            delete!(_tool_call_context_cache, call_id)
        end
    finally
        unlock(_tool_call_cache_lock)
    end
    return nothing
end
