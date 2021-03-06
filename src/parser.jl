module Parser

export parse_domain, parse_problem, parse_pddl, @pddl, @pddl_str
export load_domain, load_problem

using ParserCombinator, Julog
using ..PDDL: Domain, Problem, Action, Event
using ..PDDL: DEFAULT_REQUIREMENTS, IMPLIED_REQUIREMENTS

struct Keyword
    name::Symbol
end
Base.show(io::IO, kw::Keyword) = print(io, "KW:", kw.name)

reader_table = Dict{Symbol, Function}()

"Parser combinator for Lisp syntax."
lisp         = Delayed()
floaty_dot   = p"[-+]?[0-9]*\.[0-9]+([eE][-+]?[0-9]+)?[Ff]" > (x -> parse(Float32, x[1:end-1]))
floaty_nodot = p"[-+]?[0-9]*[0-9]+([eE][-+]?[0-9]+)?[Ff]" > (x -> parse(Float32, x[1:end-1]))
floaty       = floaty_dot | floaty_nodot
white_space  = p"(([\s\n\r]*(?<!\\);[^\n\r$]+[\n\r\s$]*)+|[\s\n\r]+)"
opt_ws       = white_space | e""

doubley      = p"[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?[dD]" > (x -> parse(Float64, x[1:end-1]))

inty         = p"[-+]?\d+" > (x -> parse(Int, x))

uchary       = p"\\(u[\da-fA-F]{4})" > (x -> first(unescape_string(x)))
achary       = p"\\[0-7]{3}" > (x -> unescape_string(x)[1])
chary        = p"\\." > (x -> x[2])

stringy      = p"(?<!\\)\".*?(?<!\\)\"" > (x -> x[2:end-1]) #_0[2:end-1] } #r"(?<!\\)\".*?(?<!\\)"
booly        = p"(true|false)" > (x -> x == "true" ? true : false)
symboly      = p"[^\d():\?{}#'`,@~;~\[\]^\s][^\s:\?()#'`,@~;^{}~\[\]]*" > Symbol
macrosymy    = p"@[^\d():\?{}#'`,@~;~\[\]^\s][^\s:\?()#'`,@~;^{}~\[\]]*" > Symbol

sexpr        = E"(" + ~opt_ws + Repeat(lisp + ~opt_ws) + E")" |> (x -> x)
hashy        = E"#{" + ~opt_ws + Repeat(lisp + ~opt_ws) + E"}" |> (x -> Set(x))
curly        = E"{" + ~opt_ws + Repeat(lisp + ~opt_ws) + E"}" |> (x -> Dict(x[i] => x[i+1] for i = 1:2:length(x)))
dispatchy    = E"#" + symboly + ~opt_ws + lisp |> (x -> reader_table[x[1]](x[2]))
bracket      = E"[" + ~opt_ws + Repeat(lisp + ~opt_ws) + E"]" |> (x -> x)

# Additional combinators to handle PDDL-specific syntax
vary         = p"\?[^\d():\?{}#'`,@~;~\[\]^\s][^\s():\?#'`,@~;^{}~\[\]]*" > (x -> Var(Symbol(uppercasefirst(x[2:end]))))
keywordy     = p":[^\d():\?{}#'`,@~;~\[\]^\s][^\s():\?#'`,@~;^{}~\[\]]*" > (x -> Keyword(Symbol(x[2:end])))

lisp.matcher = doubley | floaty | inty | uchary | achary | chary | stringy | booly |
               vary | keywordy | symboly | macrosymy |
               dispatchy | sexpr | hashy | curly | bracket

top_level    = Repeat(~opt_ws + lisp) + ~opt_ws + Eos()

"Parse to first-order-logic formulas."
function parse_formula(expr::Vector)
    if length(expr) == 0
        return Const(:true)
    elseif length(expr) == 1 && isa(expr[1], Vector)
        return parse_formula(expr[1])
    elseif length(expr) == 1 && isa(expr[1], Var)
        return expr[1]
    elseif length(expr) == 1 && isa(expr[1], Union{Symbol,Number,String})
        return Const(expr[1])
    elseif length(expr) > 1 && isa(expr[1], Symbol)
        name = expr[1]
        if name in [:exists, :forall]
            # Handle exists and forall separately
            vars, types = parse_typed_vars(expr[2])
            typepreds = Term[@julog($ty(:v)) for (v, ty) in zip(vars, types)]
            cond = Compound(:and, typepreds)
            body = parse_formula(expr[3:3])
            return Compound(name, Term[cond, body])
        else
            # Convert = to == so that Julog can handle equality checks
            if name == :(=) name = :(==) end
            args = Term[parse_formula(expr[i:i]) for i in 2:length(expr)]
            return Compound(name, args)
        end
    else
        error("Could not parse $expr to Julog formula.")
    end
end
parse_formula(expr::Symbol) = Const(expr)
parse_formula(str::String) = parse_formula(parse_one(str, top_level)[1])

"Parse predicates with type signatures."
function parse_typed_pred(expr::Vector)
    if length(expr) == 1 && isa(expr[1], Symbol)
        return Const(expr[1]), Symbol[]
    elseif length(expr) > 1 && isa(expr[1], Symbol)
        name = expr[1]
        args, types = parse_typed_vars(expr[2:end])
        return Compound(name, Vector{Term}(args)), types
    else
        error("Could not parse $expr to typed predicate.")
    end
end

"Parse list of typed variables."
function parse_typed_vars(expr::Vector)
    # TODO : Handle either-types
    vars, types = Var[], Symbol[]
    count, is_type = 0, false
    for e in expr
        if e == :-
            is_type = true
            continue
        end
        if is_type
            append!(types, repeat([e], count))
            count, is_type = 0, false
        else
            push!(vars, e)
            count += 1
        end
    end
    append!(types, repeat([:object], count))
    return vars, types
end

"Parse list of typed constants."
function parse_typed_consts(expr::Vector)
    consts, types = Const[], Symbol[]
    count, is_type = 0, false
    for e in expr
        if e == :-
            is_type = true
            continue
        end
        if is_type
            append!(types, repeat([e], count))
            count, is_type = 0, false
        else
            push!(consts, Const(e))
            count += 1
        end
    end
    append!(types, repeat([:object], count))
    return consts, types
end

"Parse planning domain."
function parse_domain(expr::Vector)
    @assert (expr[1] == :define) "'define' keyword is missing."
    @assert (expr[2][1] == :domain) "'domain' keyword is missing."
    name = expr[2][2]
    # Parse domain header (requirements, types, etc.)
    defs = Dict(e[1].name => e for e in expr[3:end])
    requirements = parse_requirements(get(defs, :requirements, nothing))
    types = parse_types(get(defs, :types, nothing))
    constants, constypes = parse_constants(get(defs, :constants, nothing))
    predicates, predtypes = parse_predicates(get(defs, :predicates, nothing))
    functions, functypes = parse_functions(get(defs, :functions, nothing))
    # Parse domain body (actions, events, etc.)
    defs = [(e[1].name, e) for e in expr[3:end]]
    axioms = Clause[]
    actions = Dict{Symbol,Action}()
    events = Event[]
    for (kw, def) in defs
        if kw in [:axiom, :derived]
            push!(axioms, parse_axiom(def))
        elseif kw == :action
            action = parse_action(def)
            actions[action.name] = action
        elseif kw == :event
            push!(events, parse_event(def))
        end
    end
    return Domain(name, requirements, types, constants, constypes,
                  predicates, predtypes, functions, functypes,
                  axioms, actions, events)
end
parse_domain(str::String) = parse_domain(parse_one(str, top_level)[1])

"Parse domain requirements."
function parse_requirements(expr::Vector)
    @assert (expr[1].name == :requirements) ":requirements keyword is missing."
    reqs = Dict{Symbol,Bool}(e.name => true for e in expr[2:end])
    reqs = merge(DEFAULT_REQUIREMENTS, reqs)
    unchecked = [k for (k, v) in reqs if v == true]
    while length(unchecked) > 0
        req = pop!(unchecked)
        deps = get(IMPLIED_REQUIREMENTS, req, Symbol[])
        if length(deps) == 0 continue end
        reqs = merge(reqs, Dict{Symbol,Bool}(d => true for d in deps))
        append!(unchecked, deps)
    end
    return reqs
end
parse_requirements(expr::Nothing) = copy(DEFAULT_REQUIREMENTS)

"Parse type hierarchy."
function parse_types(expr::Vector)
    @assert (expr[1].name == :types) ":types keyword is missing."
    types = Dict{Symbol,Vector{Symbol}}(:object => Symbol[])
    all_subtypes = Set{Symbol}()
    accum = Symbol[]
    is_supertype = false
    for e in expr[2:end]
        if e == :-
            is_supertype = true
            continue
        end
        subtypes = get!(types, e, Symbol[])
        if is_supertype
            append!(subtypes, accum)
            union!(all_subtypes, accum)
            accum = Symbol[]
            is_supertype = false
        else
            push!(accum, e)
        end
    end
    maxtypes = setdiff(keys(types), all_subtypes, [:object])
    append!(types[:object], collect(maxtypes))
    return types
end
parse_types(expr::Nothing) = Dict{Symbol,Vector{Symbol}}(:object => Symbol[])

"Parse constants in a planning domain."
function parse_constants(expr::Vector)
    @assert (expr[1].name == :constants) ":constants keyword is missing."
    objs, types = parse_typed_consts(expr[2:end])
    types = Dict{Const,Symbol}(o => t for (o, t) in zip(objs, types))
    return objs, types
end
parse_constants(expr::Nothing) = Const[], Dict{Const,Symbol}()

"Parse predicate list."
function parse_predicates(expr::Vector)
    @assert (expr[1].name == :predicates) ":predicates keyword is missing."
    preds, types = Dict{Symbol,Term}(), Dict{Symbol,Vector{Symbol}}()
    for e in expr[2:end]
        pred, ty = parse_typed_pred(e)
        preds[pred.name] = pred
        types[pred.name] = ty
    end
    return preds, types
end
parse_predicates(expr::Nothing) =
    Dict{Symbol,Term}(), Dict{Symbol,Vector{Symbol}}()

"Parse list of function (i.e. fluent) declarations."
function parse_functions(expr::Vector)
    @assert (expr[1].name == :functions) ":functions keyword is missing."
    funcs, types = Dict{Symbol,Term}(), Dict{Symbol,Vector{Symbol}}()
    for e in expr[2:end]
        func, ty = parse_typed_pred(e)
        funcs[func.name] = func
        types[func.name] = ty
    end
    return funcs, types
end
parse_functions(expr::Nothing) =
    Dict{Symbol,Term}(), Dict{Symbol,Vector{Symbol}}()

"Parse axioms (a.k.a. derived predicates)."
function parse_axiom(expr::Vector)
    @assert (expr[1].name in [:axiom, :derived]) ":derived keyword is missing."
    head = parse_formula(expr[2])
    body = parse_formula(expr[3])
    return Clause(head, Term[body])
end
"Parse axioms (a.k.a. derived predicates)."
parse_derived(expr::Vector) = parse_axiom(expr)

"Parse action definition."
function parse_action(expr::Vector)
    args = Dict(expr[i].name => expr[i+1] for i in 1:2:length(expr))
    @assert (:action in keys(args)) ":action keyword is missing"
    name = args[:action]
    params, types = parse_parameters(get(args, :parameters, []))
    precondition = parse_precondition(get(args, :precondition, []))
    effect = parse_effect(args[:effect])
    return Action(name, params, types, precondition, effect)
end

"Parse event definition."
function parse_event(expr::Vector)
    args = Dict(expr[i].name => expr[i+1] for i in 1:2:length(expr))
    @assert (:event in keys(args)) ":action keyword is missing"
    name = args[:event]
    precondition = parse_precondition(args[:precondition])
    effect = parse_effect(args[:effect])
    return Event(name, precondition, effect)
end

"Parse action parameters."
function parse_parameters(expr::Vector)
    return parse_typed_vars(expr)
end

"Parse precondition of an action or event."
function parse_precondition(expr::Vector)
    return parse_formula(expr)
end

"Parse effect of an action or event."
function parse_effect(expr::Vector)
    return parse_formula(expr)
end

"Parse planning problem."
function parse_problem(expr::Vector, requirements::Dict=Dict())
    requirements = merge(DEFAULT_REQUIREMENTS, Dict{Symbol,Bool}(requirements))
    @assert (expr[1] == :define) "'define' keyword is missing."
    @assert (expr[2][1] == :problem) "'problem' keyword is missing."
    name = expr[2][2]
    defs = Dict(e[1].name => e for e in expr[3:end])
    domain = defs[:domain][2]
    objects, objtypes = parse_objects(get(defs, :objects, nothing))
    init = parse_init(get(defs, :init, nothing))
    goal = parse_goal(get(defs, :goal, nothing))
    metric = parse_metric(get(defs, :metric, nothing))
    return Problem(name, domain, objects, objtypes, init, goal, metric)
end
parse_problem(str::String, requirements::Dict=Dict()) =
    parse_problem(parse_one(str, top_level)[1], requirements)

"Parse objects in planning problem."
function parse_objects(expr::Vector)
    @assert (expr[1].name == :objects) ":objects keyword is missing."
    objs, types = parse_typed_consts(expr[2:end])
    types = Dict{Const,Symbol}(o => t for (o, t) in zip(objs, types))
    return objs, types
end
parse_objects(expr::Nothing) = Const[], Dict{Const,Symbol}()

"Parse initial formula literals in planning problem."
function parse_init(expr::Vector)
    @assert (expr[1].name == :init) ":init keyword is missing."
    return [parse_formula(e) for e in expr[2:end]]
end
parse_init(expr::Nothing) = Term[]

"Parse goal formula in planning problem."
function parse_goal(expr::Vector)
    @assert (expr[1].name == :goal) ":goal keyword is missing."
    return parse_formula(expr[2])
end
parse_goal(expr::Nothing) = Const(true)

"Parse metric expression in planning problem."
function parse_metric(expr::Vector)
    @assert (expr[1].name == :metric) ":metric keyword is missing."
    @assert (expr[2] in [:minimize, :maximize]) "Unrecognized optimization."
    return (expr[2] == :maximize ? 1 : -1, parse_formula(expr[3]))
end
parse_metric(expr::Nothing) = nothing

"List of PDDL keywords."
const keywords = [:domain, :problem,
                  :requirements, :types, :constants, :predicates, :functions,
                  :axiom, :derived, :action, :event,
                  :objects, :init, :goal, :metric]

"Dictionary of parsing functions."
const parse_funcs = Dict{Symbol,Function}(
    kw => getfield(@__MODULE__, Symbol(:parse_, kw)) for kw in keywords
)

"Parse to PDDL structure based on initial keyword."
function parse_pddl(expr::Vector)
    if isa(expr[1], Keyword)
        kw = expr[1].name
        return parse_funcs[kw](expr)
    elseif expr[1] == :define
        kw = expr[2][1]
        return parse_funcs[kw](expr)
    else
        return parse_formula(expr)
    end
end
parse_pddl(sym::Symbol) = parse_formula(sym)
parse_pddl(str::String) = parse_pddl(parse_one(str, top_level)[1])

"Parse string to PDDL construct."
macro pddl(str::String)
    return parse_pddl(str)
end

"Parse string to PDDL construct."
macro pddl_str(str::String)
    return parse_pddl(str)
end

"Load PDDL domain from specified path."
function load_domain(path::String)
    str = open(f->read(f, String), path)
    return parse_domain(str)
end

"Load PDDL problem from specified path."
function load_problem(path::String)
    str = open(f->read(f, String), path)
    return parse_problem(str)
end

end
