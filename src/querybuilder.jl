# ─── SPARQL Query Builder DSL ───────────────────────────────────────
# Fluent, immutable query builder inspired by Jena's QueryBuilder.
# All builder functions return a new query object (functional style),
# enabling pipe-based composition.

# ─── Abstract type ──────────────────────────────────────────────────

"""
    AbstractQuery

Abstract supertype for all SPARQL query builders.
"""
abstract type AbstractQuery end

# ─── Pattern types (internal) ───────────────────────────────────────

struct _QBTriplePattern
    s::String
    p::String
    o::String
end

struct _QBOptional
    patterns::Vector{_QBTriplePattern}
end

struct _QBUnion
    left::Vector{_QBTriplePattern}
    right::Vector{_QBTriplePattern}
end

struct _QBMinus
    patterns::Vector{_QBTriplePattern}
end

struct _QBBind
    expr::String
    var::String
end

struct _QBValues
    variables::Vector{String}
    rows::Vector{Vector{String}}
end

const _QBPattern = Union{_QBTriplePattern, _QBOptional, _QBUnion, _QBMinus,
                         _QBBind, _QBValues, String}

# ─── Concrete query types ──────────────────────────────────────────

"""
    SelectQuery()

Build a SPARQL SELECT query.

# Example
```julia
q = SelectQuery() |>
    q -> prefix(q, "foaf", "http://xmlns.com/foaf/0.1/") |>
    q -> select(q, :name, :age) |>
    q -> where(q, "?person", "foaf:name", "?name") |>
    q -> filter(q, "?age > 25") |>
    q -> limit(q, 10)
sparql_str = build(q)
```
"""
struct SelectQuery <: AbstractQuery
    variables::Vector{String}
    patterns::Vector{_QBPattern}
    filters::Vector{String}
    prefixes::Vector{Pair{String,String}}
    order::Vector{Tuple{String,Symbol}}
    group::Vector{String}
    having_expr::Union{String,Nothing}
    _limit::Union{Int,Nothing}
    _offset::Union{Int,Nothing}
    _distinct::Bool
end

function SelectQuery()
    SelectQuery(String[], _QBPattern[], String[], Pair{String,String}[],
                Tuple{String,Symbol}[], String[], nothing, nothing, nothing, false)
end

"""
    ConstructQuery()

Build a SPARQL CONSTRUCT query.
"""
struct ConstructQuery <: AbstractQuery
    template::Vector{_QBTriplePattern}
    patterns::Vector{_QBPattern}
    filters::Vector{String}
    prefixes::Vector{Pair{String,String}}
    _limit::Union{Int,Nothing}
    _offset::Union{Int,Nothing}
end

function ConstructQuery()
    ConstructQuery(_QBTriplePattern[], _QBPattern[], String[],
                   Pair{String,String}[], nothing, nothing)
end

"""
    AskQuery()

Build a SPARQL ASK query.
"""
struct AskQuery <: AbstractQuery
    patterns::Vector{_QBPattern}
    filters::Vector{String}
    prefixes::Vector{Pair{String,String}}
end

AskQuery() = AskQuery(_QBPattern[], String[], Pair{String,String}[])

"""
    DescribeQuery()

Build a SPARQL DESCRIBE query.
"""
struct DescribeQuery <: AbstractQuery
    resources::Vector{String}
    patterns::Vector{_QBPattern}
    filters::Vector{String}
    prefixes::Vector{Pair{String,String}}
end

DescribeQuery() = DescribeQuery(String[], _QBPattern[], String[], Pair{String,String}[])

# ─── Builder functions ──────────────────────────────────────────────

"""
    prefix(q::AbstractQuery, name::AbstractString, uri::AbstractString)

Add a PREFIX declaration to the query.
"""
function prefix(q::SelectQuery, name::AbstractString, uri::AbstractString)
    SelectQuery(q.variables, q.patterns, q.filters,
                [q.prefixes; name => String(uri)],
                q.order, q.group, q.having_expr,
                q._limit, q._offset, q._distinct)
end

function prefix(q::ConstructQuery, name::AbstractString, uri::AbstractString)
    ConstructQuery(q.template, q.patterns, q.filters,
                   [q.prefixes; name => String(uri)],
                   q._limit, q._offset)
end

function prefix(q::AskQuery, name::AbstractString, uri::AbstractString)
    AskQuery(q.patterns, q.filters, [q.prefixes; name => String(uri)])
end

function prefix(q::DescribeQuery, name::AbstractString, uri::AbstractString)
    DescribeQuery(q.resources, q.patterns, q.filters,
                  [q.prefixes; name => String(uri)])
end

"""
    select(q::SelectQuery, vars...)

Add variables to the SELECT clause. Variables can be `Symbol`s or `String`s.
"""
function select(q::SelectQuery, vars...)
    new_vars = String[q.variables...]
    for v in vars
        name = v isa Symbol ? string(v) : String(v)
        startswith(name, '?') && (name = name[2:end])
        push!(new_vars, name)
    end
    SelectQuery(new_vars, q.patterns, q.filters, q.prefixes,
                q.order, q.group, q.having_expr,
                q._limit, q._offset, q._distinct)
end

# Helper to normalise a term string
function _qb_normalise(t::AbstractString)
    String(t)
end
function _qb_normalise(t::Symbol)
    "?" * string(t)
end
function _qb_normalise(t::URIRef)
    "<" * t.value * ">"
end
function _qb_normalise(t::Literal)
    n3(t)
end

"""
    where(q::AbstractQuery, s, p, o)

Add a basic graph pattern triple to the WHERE clause.
"""
function where end

function where(q::SelectQuery, s, p, o)
    pat = _QBTriplePattern(_qb_normalise(s), _qb_normalise(p), _qb_normalise(o))
    SelectQuery(q.variables, [q.patterns; pat], q.filters, q.prefixes,
                q.order, q.group, q.having_expr,
                q._limit, q._offset, q._distinct)
end

function where(q::ConstructQuery, s, p, o)
    pat = _QBTriplePattern(_qb_normalise(s), _qb_normalise(p), _qb_normalise(o))
    ConstructQuery(q.template, [q.patterns; pat], q.filters, q.prefixes,
                   q._limit, q._offset)
end

function where(q::AskQuery, s, p, o)
    pat = _QBTriplePattern(_qb_normalise(s), _qb_normalise(p), _qb_normalise(o))
    AskQuery([q.patterns; pat], q.filters, q.prefixes)
end

function where(q::DescribeQuery, s, p, o)
    pat = _QBTriplePattern(_qb_normalise(s), _qb_normalise(p), _qb_normalise(o))
    DescribeQuery(q.resources, [q.patterns; pat], q.filters, q.prefixes)
end

"""
    filter(q::AbstractQuery, expr::AbstractString)

Add a FILTER expression to the WHERE clause.
"""
function Base.filter(q::SelectQuery, expr::String)
    SelectQuery(q.variables, q.patterns, [q.filters; expr], q.prefixes,
                q.order, q.group, q.having_expr,
                q._limit, q._offset, q._distinct)
end
Base.filter(q::SelectQuery, expr::SubString{String}) = filter(q, String(expr))

function Base.filter(q::ConstructQuery, expr::String)
    ConstructQuery(q.template, q.patterns, [q.filters; expr], q.prefixes,
                   q._limit, q._offset)
end
Base.filter(q::ConstructQuery, expr::SubString{String}) = filter(q, String(expr))

function Base.filter(q::AskQuery, expr::String)
    AskQuery(q.patterns, [q.filters; expr], q.prefixes)
end
Base.filter(q::AskQuery, expr::SubString{String}) = filter(q, String(expr))

function Base.filter(q::DescribeQuery, expr::String)
    DescribeQuery(q.resources, q.patterns, [q.filters; expr], q.prefixes)
end
Base.filter(q::DescribeQuery, expr::SubString{String}) = filter(q, String(expr))

"""
    optional(q::AbstractQuery, patterns::Tuple...)

Add an OPTIONAL block. Each pattern is a `(s, p, o)` tuple.
"""
function optional(q::SelectQuery, patterns::Tuple...)
    tps = [_QBTriplePattern(_qb_normalise(s), _qb_normalise(p), _qb_normalise(o))
           for (s, p, o) in patterns]
    opt = _QBOptional(tps)
    SelectQuery(q.variables, [q.patterns; opt], q.filters, q.prefixes,
                q.order, q.group, q.having_expr,
                q._limit, q._offset, q._distinct)
end

function optional(q::ConstructQuery, patterns::Tuple...)
    tps = [_QBTriplePattern(_qb_normalise(s), _qb_normalise(p), _qb_normalise(o))
           for (s, p, o) in patterns]
    ConstructQuery(q.template, [q.patterns; _QBOptional(tps)], q.filters,
                   q.prefixes, q._limit, q._offset)
end

function optional(q::AskQuery, patterns::Tuple...)
    tps = [_QBTriplePattern(_qb_normalise(s), _qb_normalise(p), _qb_normalise(o))
           for (s, p, o) in patterns]
    AskQuery([q.patterns; _QBOptional(tps)], q.filters, q.prefixes)
end

"""
    union_pattern(q::AbstractQuery, left::Vector{Tuple}, right::Vector{Tuple})

Add a UNION pattern.
"""
function union_pattern(q::SelectQuery, left::Vector, right::Vector)
    lps = [_QBTriplePattern(_qb_normalise(s), _qb_normalise(p), _qb_normalise(o))
           for (s, p, o) in left]
    rps = [_QBTriplePattern(_qb_normalise(s), _qb_normalise(p), _qb_normalise(o))
           for (s, p, o) in right]
    SelectQuery(q.variables, [q.patterns; _QBUnion(lps, rps)], q.filters,
                q.prefixes, q.order, q.group, q.having_expr,
                q._limit, q._offset, q._distinct)
end

"""
    minus(q::AbstractQuery, patterns::Tuple...)

Add a MINUS block.
"""
function minus(q::SelectQuery, patterns::Tuple...)
    tps = [_QBTriplePattern(_qb_normalise(s), _qb_normalise(p), _qb_normalise(o))
           for (s, p, o) in patterns]
    SelectQuery(q.variables, [q.patterns; _QBMinus(tps)], q.filters, q.prefixes,
                q.order, q.group, q.having_expr,
                q._limit, q._offset, q._distinct)
end

"""
    query_bind(q::AbstractQuery, expr::AbstractString, var::AbstractString)

Add a BIND expression: `BIND(expr AS ?var)`.
"""
function query_bind(q::SelectQuery, expr::AbstractString, var::AbstractString)
    v = startswith(var, '?') ? var[2:end] : String(var)
    SelectQuery(q.variables, [q.patterns; _QBBind(String(expr), v)],
                q.filters, q.prefixes, q.order, q.group, q.having_expr,
                q._limit, q._offset, q._distinct)
end

"""
    query_values(q::AbstractQuery, variables::Vector, rows::Vector{Vector})

Add a VALUES clause.
"""
function query_values(q::SelectQuery, variables::Vector, rows::Vector)
    vars = [startswith(String(v), '?') ? String(v)[2:end] : String(v) for v in variables]
    str_rows = [String[_qb_normalise(v) for v in row] for row in rows]
    SelectQuery(q.variables, [q.patterns; _QBValues(vars, str_rows)],
                q.filters, q.prefixes, q.order, q.group, q.having_expr,
                q._limit, q._offset, q._distinct)
end

"""
    group_by(q::SelectQuery, vars...)

Add GROUP BY variables.
"""
function group_by(q::SelectQuery, vars...)
    new_group = String[q.group...]
    for v in vars
        name = v isa Symbol ? string(v) : String(v)
        startswith(name, '?') && (name = name[2:end])
        push!(new_group, name)
    end
    SelectQuery(q.variables, q.patterns, q.filters, q.prefixes,
                q.order, new_group, q.having_expr,
                q._limit, q._offset, q._distinct)
end

"""
    having(q::SelectQuery, expr::AbstractString)

Add a HAVING clause.
"""
function having(q::SelectQuery, expr::AbstractString)
    SelectQuery(q.variables, q.patterns, q.filters, q.prefixes,
                q.order, q.group, String(expr),
                q._limit, q._offset, q._distinct)
end

"""
    order_by(q::SelectQuery, var, direction::Symbol=:asc)

Add an ORDER BY clause. `direction` is `:asc` or `:desc`.
"""
function order_by(q::SelectQuery, var, direction::Symbol=:asc)
    name = var isa Symbol ? string(var) : String(var)
    startswith(name, '?') && (name = name[2:end])
    direction in (:asc, :desc) || throw(ArgumentError("direction must be :asc or :desc"))
    SelectQuery(q.variables, q.patterns, q.filters, q.prefixes,
                [q.order; (name, direction)], q.group, q.having_expr,
                q._limit, q._offset, q._distinct)
end

"""
    limit(q::AbstractQuery, n::Integer)

Set the LIMIT clause.
"""
function limit(q::SelectQuery, n::Integer)
    SelectQuery(q.variables, q.patterns, q.filters, q.prefixes,
                q.order, q.group, q.having_expr, Int(n), q._offset, q._distinct)
end

function limit(q::ConstructQuery, n::Integer)
    ConstructQuery(q.template, q.patterns, q.filters, q.prefixes, Int(n), q._offset)
end

"""
    offset(q::AbstractQuery, n::Integer)

Set the OFFSET clause.
"""
function offset(q::SelectQuery, n::Integer)
    SelectQuery(q.variables, q.patterns, q.filters, q.prefixes,
                q.order, q.group, q.having_expr, q._limit, Int(n), q._distinct)
end

function offset(q::ConstructQuery, n::Integer)
    ConstructQuery(q.template, q.patterns, q.filters, q.prefixes, q._limit, Int(n))
end

"""
    distinct(q::SelectQuery)

Add the DISTINCT modifier.
"""
function distinct(q::SelectQuery)
    SelectQuery(q.variables, q.patterns, q.filters, q.prefixes,
                q.order, q.group, q.having_expr, q._limit, q._offset, true)
end

"""
    construct(q::ConstructQuery, patterns::Tuple...)

Add triple patterns to the CONSTRUCT template.
"""
function construct(q::ConstructQuery, patterns::Tuple...)
    tps = [_QBTriplePattern(_qb_normalise(s), _qb_normalise(p), _qb_normalise(o))
           for (s, p, o) in patterns]
    ConstructQuery([q.template; tps], q.patterns, q.filters, q.prefixes,
                   q._limit, q._offset)
end

"""
    describe(q::DescribeQuery, resources...)

Add resources to DESCRIBE.
"""
function describe(q::DescribeQuery, resources...)
    new_res = String[q.resources...]
    for r in resources
        push!(new_res, _qb_normalise(r))
    end
    DescribeQuery(new_res, q.patterns, q.filters, q.prefixes)
end

# ─── build() — render to SPARQL string ─────────────────────────────

function _qb_render_pattern(p::_QBTriplePattern)
    "$(p.s) $(p.p) $(p.o) ."
end

function _qb_render_pattern(p::_QBOptional)
    inner = join(["  " * _qb_render_pattern(tp) for tp in p.patterns], "\n")
    "OPTIONAL {\n$inner\n}"
end

function _qb_render_pattern(p::_QBUnion)
    left_inner = join(["  " * _qb_render_pattern(tp) for tp in p.left], "\n")
    right_inner = join(["  " * _qb_render_pattern(tp) for tp in p.right], "\n")
    "{\n$left_inner\n} UNION {\n$right_inner\n}"
end

function _qb_render_pattern(p::_QBMinus)
    inner = join(["  " * _qb_render_pattern(tp) for tp in p.patterns], "\n")
    "MINUS {\n$inner\n}"
end

function _qb_render_pattern(p::_QBBind)
    "BIND($(p.expr) AS ?$(p.var))"
end

function _qb_render_pattern(p::_QBValues)
    vars = join(["?" * v for v in p.variables], " ")
    rows = join(["(" * join(r, " ") * ")" for r in p.rows], "\n  ")
    "VALUES ($vars) {\n  $rows\n}"
end

function _qb_render_pattern(p::String)
    p
end

function _qb_render_prefixes(prefixes::Vector{Pair{String,String}})
    join(["PREFIX $name: <$uri>" for (name, uri) in prefixes], "\n")
end

function _qb_render_where(patterns::Vector, filters::Vector{String})
    parts = String[]
    for p in patterns
        push!(parts, "  " * _qb_render_pattern(p))
    end
    for f in filters
        push!(parts, "  FILTER($f)")
    end
    "WHERE {\n" * join(parts, "\n") * "\n}"
end

"""
    build(q::AbstractQuery) -> String

Render the query builder to a SPARQL query string.
"""
function build(q::SelectQuery)
    parts = String[]

    # Prefixes
    if !isempty(q.prefixes)
        push!(parts, _qb_render_prefixes(q.prefixes))
    end

    # SELECT clause
    sel = "SELECT"
    q._distinct && (sel *= " DISTINCT")
    if isempty(q.variables)
        sel *= " *"
    else
        sel *= " " * join(["?" * v for v in q.variables], " ")
    end
    push!(parts, sel)

    # WHERE
    push!(parts, _qb_render_where(q.patterns, q.filters))

    # GROUP BY
    if !isempty(q.group)
        push!(parts, "GROUP BY " * join(["?" * v for v in q.group], " "))
    end

    # HAVING
    if !isnothing(q.having_expr)
        push!(parts, "HAVING($(q.having_expr))")
    end

    # ORDER BY
    if !isempty(q.order)
        clauses = String[]
        for (v, dir) in q.order
            if dir == :desc
                push!(clauses, "DESC(?$v)")
            else
                push!(clauses, "?$v")
            end
        end
        push!(parts, "ORDER BY " * join(clauses, " "))
    end

    # LIMIT / OFFSET
    if !isnothing(q._limit)
        push!(parts, "LIMIT $(q._limit)")
    end
    if !isnothing(q._offset)
        push!(parts, "OFFSET $(q._offset)")
    end

    join(parts, "\n") * "\n"
end

function build(q::ConstructQuery)
    parts = String[]

    if !isempty(q.prefixes)
        push!(parts, _qb_render_prefixes(q.prefixes))
    end

    # CONSTRUCT template
    template_lines = join(["  " * _qb_render_pattern(tp) for tp in q.template], "\n")
    push!(parts, "CONSTRUCT {\n$template_lines\n}")

    # WHERE
    push!(parts, _qb_render_where(q.patterns, q.filters))

    if !isnothing(q._limit)
        push!(parts, "LIMIT $(q._limit)")
    end
    if !isnothing(q._offset)
        push!(parts, "OFFSET $(q._offset)")
    end

    join(parts, "\n") * "\n"
end

function build(q::AskQuery)
    parts = String[]

    if !isempty(q.prefixes)
        push!(parts, _qb_render_prefixes(q.prefixes))
    end

    # ASK uses { ... } without WHERE keyword (matches parser expectation)
    inner_parts = String[]
    for p in q.patterns
        push!(inner_parts, "  " * _qb_render_pattern(p))
    end
    for f in q.filters
        push!(inner_parts, "  FILTER($f)")
    end
    push!(parts, "ASK {\n" * join(inner_parts, "\n") * "\n}")

    join(parts, "\n") * "\n"
end

function build(q::DescribeQuery)
    parts = String[]

    if !isempty(q.prefixes)
        push!(parts, _qb_render_prefixes(q.prefixes))
    end

    resources_str = isempty(q.resources) ? "*" : join(q.resources, " ")
    push!(parts, "DESCRIBE $resources_str")

    if !isempty(q.patterns) || !isempty(q.filters)
        push!(parts, _qb_render_where(q.patterns, q.filters))
    end

    join(parts, "\n") * "\n"
end

# ─── execute() — run against a graph ───────────────────────────────

"""
    execute(q::AbstractQuery, g::RDFGraph) -> results

Build the SPARQL string and execute it against the given graph.

Returns the same type as `sparql_query`:
- `SelectQuery` → `Vector{Dict{String, Identifier}}`
- `AskQuery` → `Bool`
- `ConstructQuery` → `RDFGraph`
- `DescribeQuery` → `RDFGraph`
"""
function execute(q::AbstractQuery, g::RDFGraph)
    sparql_query(g, build(q))
end
