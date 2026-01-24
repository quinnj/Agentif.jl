mutable struct Future{T}
    const notify::Threads.Condition
    @atomic set::Int8 # if 0, result is undefined, 1 means result is T, 2 means result is an exception
    result::Union{Exception, T} # undefined initially
    Future{T}() where {T} = new{T}(Threads.Condition(), 0)
end

Future() = Future{Nothing}() # default future type
Base.pointer(f::Future) = pointer_from_objref(f)
Future(ptr::Ptr) = unsafe_pointer_to_objref(ptr)::Future
Future{T}(ptr::Ptr) where {T} = unsafe_pointer_to_objref(ptr)::Future{T}

function Future{T}(f) where {T}
    fut = Future{T}()
    Threads.@spawn try
        notify(fut, f())
    catch e
        notify(fut, capture(e))
    end
    return fut
end

function Base.wait(f::Future{T}) where {T}
    set = @atomic f.set
    set == 1 && return f.result::T
    set == 2 && throw(f.result::Exception)
    lock(f.notify) # acquire barrier
    try
        set = f.set
        set == 1 && return f.result::T
        set == 2 && throw(f.result::Exception)
        wait(f.notify)
    finally
        unlock(f.notify) # release barrier
    end
    if f.set == 1
        return f.result::T
    else
        @assert isdefined(f, :result)
        throw(f.result::Exception)
    end
end

capture(e::Exception) = CapturedException(e, Base.catch_backtrace())

Base.notify(f::Future{Nothing}) = notify(f, nothing)
function Base.notify(f::Future{T}, x) where {T}
    lock(f.notify) # acquire barrier
    try
        if f.set == Int8(0)
            if x isa Exception
                set = Int8(2)
                f.result = x
            else
                set = Int8(1)
                f.result = convert(T, x)
            end
            @atomic :release f.set = set
            notify(f.notify)
        end
    finally
        unlock(f.notify)
    end
    return nothing
end
