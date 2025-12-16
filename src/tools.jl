@kwarg struct AgentTool{F,T}
    name::String
    description::Union{Nothing,String} = nothing
    strict::Bool = true
    func::F
    requiresApproval::Bool = false
end

parameters(::AgentTool{F,T}) where {F,T} = T

function extract_function_args(func_expr::Expr)
    args = Symbol[]
    types = Any[]
    if func_expr.head === :call
        # Short form: f(x::T1, y::T2) = ...
        for i in 2:length(func_expr.args)
            arg = func_expr.args[i]
            if arg isa Symbol
                push!(args, arg)
                push!(types, :Any)
            elseif arg isa Expr && arg.head === :(::)
                if length(arg.args) == 1
                    push!(args, arg.args[1])
                    push!(types, :Any)
                else
                    push!(args, arg.args[1])
                    push!(types, arg.args[2])
                end
            elseif arg isa Expr && arg.head === :kw
                # Keyword argument: x::T = default
                if arg.args[1] isa Expr && arg.args[1].head === :(::)
                    if length(arg.args[1].args) == 1
                        push!(args, arg.args[1].args[1])
                        push!(types, :Any)
                    else
                        push!(args, arg.args[1].args[1])
                        push!(types, arg.args[1].args[2])
                    end
                else
                    push!(args, arg.args[1])
                    push!(types, :Any)
                end
            end
        end
    elseif func_expr.head === :function || func_expr.head === :(=)
        # Long form: function f(x::T1, y::T2) ... end
        call_expr = func_expr.head === :function ? func_expr.args[1] : func_expr.args[1]
        if call_expr.head === :call
            for i in 2:length(call_expr.args)
                arg = call_expr.args[i]
                if arg isa Symbol
                    push!(args, arg)
                    push!(types, :Any)
                elseif arg isa Expr && arg.head === :(::)
                    if length(arg.args) == 1
                        push!(args, arg.args[1])
                        push!(types, :Any)
                    else
                        push!(args, arg.args[1])
                        push!(types, arg.args[2])
                    end
                elseif arg isa Expr && arg.head === :kw
                    # Keyword argument: x::T = default
                    if arg.args[1] isa Expr && arg.args[1].head === :(::)
                        if length(arg.args[1].args) == 1
                            push!(args, arg.args[1].args[1])
                            push!(types, :Any)
                        else
                            push!(args, arg.args[1].args[1])
                            push!(types, arg.args[1].args[2])
                        end
                    else
                        push!(args, arg.args[1])
                        push!(types, :Any)
                    end
                end
            end
        end
    end
    return args, types
end

function extract_function_name(func_expr::Expr)
    if func_expr.head === :call
        return func_expr.args[1]
    elseif func_expr.head === :function || func_expr.head === :(=)
        call_expr = func_expr.head === :function ? func_expr.args[1] : func_expr.args[1]
        if call_expr.head === :call
            return call_expr.args[1]
        end
    end
    error("Could not extract function name from expression")
end

macro tool(description::String, func_expr::Expr)
    func_name = extract_function_name(func_expr)
    args, types = extract_function_args(func_expr)
    # Build NamedTuple type: @NamedTuple{arg1::T1, arg2::T2, ...}
    named_tuple_fields = Expr[]
    for (arg, typ) in zip(args, types)
        push!(named_tuple_fields, Expr(:(::), arg, typ))
    end
    named_tuple_type = if isempty(named_tuple_fields)
        :(@NamedTuple{})
    else
        Expr(:macrocall, Symbol("@NamedTuple"), nothing, Expr(:braces, named_tuple_fields...))
    end
    # Generate function definition and AgentTool construction
    quote
        # Original function definition
        $(esc(func_expr))
        # AgentTool construction
        Agentif.AgentTool{typeof($(esc(func_name))), $named_tuple_type}(
            name=string($(Meta.quot(func_name))),
            description=$(description),
            func=$(esc(func_name))
        )
    end
end

macro tool_requires_approval(description::String, func_expr::Expr)
    func_name = extract_function_name(func_expr)
    args, types = extract_function_args(func_expr)
    # Build NamedTuple type: @NamedTuple{arg1::T1, arg2::T2, ...}
    named_tuple_fields = Expr[]
    for (arg, typ) in zip(args, types)
        push!(named_tuple_fields, Expr(:(::), arg, typ))
    end
    named_tuple_type = if isempty(named_tuple_fields)
        :(@NamedTuple{})
    else
        Expr(:macrocall, Symbol("@NamedTuple"), nothing, Expr(:braces, named_tuple_fields...))
    end
    # Generate function definition and AgentTool construction
    quote
        # Original function definition
        $(esc(func_expr))
        # AgentTool construction
        Agentif.AgentTool{typeof($(esc(func_name))), $named_tuple_type}(
            name=string($(Meta.quot(func_name))),
            description=$(description),
            func=$(esc(func_name)),
            requiresApproval=true
        )
    end
end

