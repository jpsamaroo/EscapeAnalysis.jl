using EscapeAnalysis, InteractiveUtils, Test, JETTest

mutable struct MutableSome{T}
    value::T
end
mutable struct MutableCondition
    cond::Bool
end

@testset "EscapeAnalysis" begin

@testset "basics" begin
    let # simplest
        result = analyze_escapes((Any,)) do a # return to caller
            return nothing
        end
        @test has_return_escape(result.state.arguments[2])
    end

    let # return
        result = analyze_escapes((Any,)) do a
            return a
        end
        @test has_return_escape(result.state.arguments[1]) # self
        @test has_return_escape(result.state.arguments[2]) # argument
    end

    let # global assignement
        result = analyze_escapes((Any,)) do a
            global aa = a
            return nothing
        end
        @test has_global_escape(result.state.arguments[2])
    end

    # https://github.com/aviatesk/EscapeAnalysis.jl/pull/16
    let # don't propagate escape information for bitypes
        result = analyze_escapes((Nothing,)) do a
            global bb = a
        end
        @test !(has_global_escape(result.state.arguments[2]))
    end
end

@testset "control flows" begin
    let # branching
        result = analyze_escapes((Any,Bool,)) do a, c
            if c
                return nothing # a doesn't escape in this branch
            else
                return a # a escapes to a caller
            end
        end
        @test has_return_escape(result.state.arguments[2])
    end

    let # π node
        result = analyze_escapes((Any,)) do a
            if isa(a, Regex)
                identity(a) # compiler will introduce π node here
                return a    # return escape !
            else
                return nothing
            end
        end
        @assert any(@nospecialize(x)->isa(x, Core.PiNode), result.ir.stmts.inst)
        @test has_return_escape(result.state.arguments[2])
    end

    let # loop
        result = analyze_escapes((Int,)) do n
            c = MutableCondition(false)
            while n > 0
                rand(Bool) && return c
            end
            nothing
        end
        i = findfirst(==(MutableCondition), result.ir.stmts.type)
        @assert !isnothing(i)
        @test has_return_escape(result.state.ssavalues[i])
    end

    let # exception
        result = analyze_escapes((Any,)) do a
            try
                nothing
            catch err
                return a # return escape
            end
        end
        @test has_return_escape(result.state.arguments[2])
    end
end

let # more complex
    result = analyze_escapes((Bool,)) do c
        x = Vector{MutableCondition}() # return escape
        y = MutableCondition(c) # return escape
        if c
            push!(x, y)
            return nothing
        else
            return x # return escape
        end
    end

    i = findfirst(==(Vector{MutableCondition}), result.ir.stmts.type)
    @assert !isnothing(i)
    @test has_return_escape(result.state.ssavalues[i])
    i = findfirst(==(MutableCondition), result.ir.stmts.type)
    @assert !isnothing(i)
    @test has_return_escape(result.state.ssavalues[i])
end

let # simple allocation
    result = analyze_escapes((Bool,)) do c
        mm = MutableCondition(c) # just allocated, never escapes
        return mm.cond ? nothing : 1
    end

    i = findfirst(==(MutableCondition), result.ir.stmts.type) # allocation statement
    @assert !isnothing(i)
    @test has_no_escape(result.state.ssavalues[i])
end

@testset "inter-procedural" begin
    m = Module()

    # FIXME currently we can't prove the effect-freeness of `getfield(RefValue{String}, :x)`
    # because of this check https://github.com/JuliaLang/julia/blob/94b9d66b10e8e3ebdb268e4be5f7e1f43079ad4e/base/compiler/tfuncs.jl#L745
    # and thus it leads to the following two broken tests

    @eval m @noinline f_no_escape(x) = (broadcast(identity, x); nothing)
    let
        result = @eval m $analyze_escapes() do
            f_no_escape(Ref("Hi"))
        end
        i = findfirst(==(Base.RefValue{String}), result.ir.stmts.type) # find allocation statement
        @assert !isnothing(i)
        @test_broken has_no_escape(result.state.ssavalues[i])
    end

    @eval m @noinline f_no_escape2(x) = broadcast(identity, x)
    let
        result = @eval m $analyze_escapes() do
            f_no_escape2(Ref("Hi"))
        end
        i = findfirst(==(Base.RefValue{String}), result.ir.stmts.type) # find allocation statement
        @assert !isnothing(i)
        @test_broken has_no_escape(result.state.ssavalues[i])
    end

    @eval m @noinline f_global_escape(x) = (global xx = x) # obvious escape
    let
        result = @eval m $analyze_escapes() do
            f_global_escape(Ref("Hi"))
        end
        i = findfirst(==(Base.RefValue{String}), result.ir.stmts.type) # find allocation statement
        @assert !isnothing(i)
        @test has_global_escape(result.state.ssavalues[i])
    end

    # if we can't determine the matching method statically, we should be conservative
    let
        result = @eval m $analyze_escapes((Ref{Any},)) do a
            may_exist(a)
        end
        @test has_all_escape(result.state.arguments[2])
    end
    let
        result = @eval m $analyze_escapes((Ref{Any},)) do a
            Base.@invokelatest f_no_escape(a)
        end
        @test has_all_escape(result.state.arguments[2])
    end

    # handling of simple union-split (just exploit the inliner's effort)
    @eval m begin
        @noinline unionsplit_noescape(_)      = string(nothing)
        @noinline unionsplit_noescape(a::Int) = a + 10
    end
    let
        T = Union{Int,Nothing}
        result = @eval m $analyze_escapes(($T,)) do value
            a = $MutableSome{$T}(value)
            unionsplit_noescape(a.value)
            return nothing
        end
        i = findfirst(==(MutableSome{T}), result.ir.stmts.type) # find allocation statement
        @assert !isnothing(i)
        @test has_no_escape(result.state.ssavalues[i])
    end

    # appropriate conversion of inter-procedural context
    # https://github.com/aviatesk/EscapeAnalysis.jl/issues/7
    @eval m @noinline f_no_escape_simple(a) = Base.inferencebarrier(nothing)
    let
        result = @eval m $analyze_escapes() do
            aaa = Ref("foo") # shouldn't be "return escape"
            a = f_no_escape_simple(aaa)
            nothing
        end
        i = findfirst(==(Base.RefValue{String}), result.ir.stmts.type) # find allocation statement
        @assert !isnothing(i)
        @test has_no_escape(result.state.ssavalues[i])
    end
    let
        result = @eval m $analyze_escapes() do
            aaa = Ref("foo") # still should be "return escape"
            a = f_no_escape_simple(aaa)
            return aaa
        end
        i = findfirst(==(Base.RefValue{String}), result.ir.stmts.type) # find allocation statement
        @assert !isnothing(i)
        @test has_return_escape(result.state.ssavalues[i])
    end

    # should propagate escape information imposed on return value to the aliased call argument
    @eval m @noinline function f_return_escape(a)
        println("hi") # prevent inlining
        return a
    end
    let
        result = @eval m $analyze_escapes() do
            obj = Ref("foo")           # should be "return escape"
            ret = f_return_escape(obj)
            return ret                 # alias of `obj`
        end
        i = findfirst(==(Base.RefValue{String}), result.ir.stmts.type) # find allocation statement
        @assert !isnothing(i)
        @test has_return_escape(result.state.ssavalues[i])
    end

    # we've not implemented a proper alias analysis,
    # TODO alias analysis should help us avoid propagatig the constraint imposed on `ret` to `obj`
    @eval m @noinline function f_no_return_escape(a)
        println("hi") # prevent inlining
        return "hi"
    end
    let
        result = @eval m $analyze_escapes() do
            obj = Ref("foo")              # better to not be "return escape"
            ret = f_no_return_escape(obj)
            return ret                    # must not alias to `obj`
        end
        i = findfirst(==(Base.RefValue{String}), result.ir.stmts.type) # find allocation statement
        @assert !isnothing(i)
        @test_broken !has_return_escape(result.state.ssavalues[i])
    end
end

@testset "builtins" begin
    let # throw
        r = analyze_escapes((Any,)) do a
            throw(a)
        end
        @test has_thrown_escape(r.state.arguments[2])
    end

    let # implicit throws
        r = analyze_escapes((Any,)) do a
            getfield(a, :may_not_field)
        end
        @test has_thrown_escape(r.state.arguments[2])

        r = analyze_escapes((Any,)) do a
            sizeof(a)
        end
        @test has_thrown_escape(r.state.arguments[2])
    end

    let # :===
        result = analyze_escapes((Bool, String)) do cond, s
            m = cond ? MutableSome(s) : nothing
            c = m === nothing
            return c
        end
        i = findfirst(==(MutableSome{String}), result.ir.stmts.type) # find allocation statement
        @assert !isnothing(i)
        @test has_no_escape(result.state.ssavalues[i])
    end

    let # sizeof
        ary = [0,1,2]
        result = @eval analyze_escapes() do
            ary = $(QuoteNode(ary))
            sizeof(ary)
        end
        i = findfirst(==(Core.Const(ary)), result.ir.stmts.type) # find allocation statement
        @assert !isnothing(i)
        @test has_no_escape(result.state.ssavalues[i])
    end

    let # ifelse
        result = analyze_escapes((Bool,)) do c
            r = ifelse(c, Ref("yes"), Ref("no"))
            return r
        end
        inds = findall(==(Base.RefValue{String}), result.ir.stmts.type) # find allocation statement
        @assert !isempty(inds)
        for i in inds
            @test has_return_escape(result.state.ssavalues[i])
        end
    end
    let # ifelse (with constant condition)
        result = analyze_escapes() do
            r = ifelse(true, Ref("yes"), Ref(nothing))
            return r
        end
        i = findfirst(==(Base.RefValue{String}), result.ir.stmts.type) # find allocation statement
        @assert !isnothing(i)
        @test has_return_escape(result.state.ssavalues[i])
        i = findfirst(==(Base.RefValue{Nothing}), result.ir.stmts.type) # find allocation statement
        @assert !isnothing(i)
        @test has_no_escape(result.state.ssavalues[i])
    end
end

@testset "Exprs" begin
    let
        result = analyze_escapes((String,)) do s
            m = MutableSome(s)
            GC.@preserve m begin
                return nothing
            end
        end
        i = findfirst(==(MutableSome{String}), result.ir.stmts.type) # find allocation statement
        @test !isnothing(i)
        @test has_no_escape(result.state.ssavalues[i])
    end

    let # :isdefined
        result = analyze_escapes((String, Bool, )) do a, b
            if b
                s = Ref(a)
            end
            return @isdefined(s)
        end
        i = findfirst(==(Base.RefValue{String}), result.ir.stmts.type) # find allocation statement
        @test !isnothing(i)
        @test has_no_escape(result.state.ssavalues[i])
    end

    let # :foreigncall
        result = analyze_escapes((Vector{String}, Int, )) do a, b
            return isassigned(a, b) # TODO: specialize isassigned
        end
        @test has_all_escape(result.state.arguments[2])
    end
end

@testset "special-casing bitstype" begin
    let
        result = analyze_escapes((Int,)) do a
            o = MutableSome(a) # no need to escape
            f = getfield(o, :value)
            return f
        end
        i = findfirst(==(MutableSome{Int}), result.ir.stmts.type) # allocation statement
        @assert !isnothing(i)
        @test has_no_escape(result.state.ssavalues[i])
    end

    let # an escaped tuple stmt will not propagate to its Int argument (since Int is of bitstype)
        result = analyze_escapes((Int, Any, )) do a, b
            t = tuple(a, b)
            global tt = t
            return nothing
        end
        @test has_return_escape(result.state.arguments[2])
        @test has_global_escape(result.state.arguments[3])
    end
end

@testset "code quality" begin
    # assert that our main routine are free from (unnecessary) runtime dispatches

    function function_filter(@nospecialize(ft))
        ft === typeof(Core.Compiler.widenconst) && return false # `widenconst` is very untyped, ignore
        ft === typeof(EscapeAnalysis.escape_builtin!) && return false # `escape_builtin!` is very untyped, ignore
        ft === typeof(isbitstype) && return false # `isbitstype` is very untyped, ignore
        return true
    end

    test_nodispatch(only(methods(EscapeAnalysis.find_escapes)).sig; function_filter)

    for m in methods(EscapeAnalysis.escape_builtin!)
        Base._methods_by_ftype(m.sig, 1, Base.get_world_counter()) === false && continue
        test_nodispatch(m.sig; function_filter)
    end
end

end # @testset "EscapeAnalysis" begin
