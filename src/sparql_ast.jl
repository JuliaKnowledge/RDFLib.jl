# ═══════════════════════════════════════════════════════════════════
# SPARQL AST — Typed intermediate representation for parsed queries
# ═══════════════════════════════════════════════════════════════════
#
# These types form the contract between the parser (sparql_parser.jl)
# and the evaluator (sparql_eval.jl).  Filter/Bind expressions are
# represented as a proper tree (`SparqlExpr`) rather than raw strings,
# giving correct operator precedence and nesting for free.

# ─── Expression AST ────────────────────────────────────────────────

abstract type SparqlExpr end

"""Variable reference: `?name`"""
struct ExprVar <: SparqlExpr
    name::String       # without leading '?'
end

"""Literal value"""
struct ExprLiteral <: SparqlExpr
    value::Literal
end

"""URI reference"""
struct ExprURI <: SparqlExpr
    uri::URIRef
end

"""Blank node in expression (e.g. for isBlank checks)"""
struct ExprBNode <: SparqlExpr
    node::BNode
end

"""Boolean constant (used for TRUE/FALSE keywords)"""
struct ExprBool <: SparqlExpr
    value::Bool
end

"""Binary operator: `left op right`
`op` is one of: :||, :&&, :==, :!=, :<, :>, :<=, :>=, :+, :-, :*, :/"""
struct ExprBinaryOp <: SparqlExpr
    op::Symbol
    left::SparqlExpr
    right::SparqlExpr
end

"""Unary operator: `op arg`
`op` is one of: :!, :+, :-"""
struct ExprUnaryOp <: SparqlExpr
    op::Symbol
    arg::SparqlExpr
end

"""Function call: `FUNC(arg1, arg2, ...)`
Covers all SPARQL built-ins: STR, LANG, DATATYPE, BOUND, isIRI, isLiteral,
isBlank, isNumeric, CONTAINS, STRSTARTS, STRENDS, STRLEN, UCASE, LCASE,
SUBSTR, REPLACE, CONCAT, LANGMATCHES, REGEX, IF, COALESCE, BNODE, IRI,
URI, STRDT, STRLANG, ABS, CEIL, FLOOR, ROUND, RAND, NOW, YEAR, MONTH,
DAY, HOURS, MINUTES, SECONDS, TIMEZONE, TZ, MD5, SHA1, SHA256, SHA384,
SHA512, ENCODE_FOR_URI, STRUUID, UUID, TRIPLE, SUBJECT, PREDICATE, OBJECT,
isTRIPLE, sameTerm, ADJUST, plus GeoSPARQL functions."""
struct ExprFunctionCall <: SparqlExpr
    name::String       # uppercase canonical name for bare builtins;
                       # full IRI (original case) for IRI-named functions,
                       # e.g. "http://www.w3.org/2001/XMLSchema#integer"
    args::Vector{SparqlExpr}
end

"""Aggregate: `COUNT(DISTINCT ?x)`, `GROUP_CONCAT(?x; separator=",")`"""
struct ExprAggregate <: SparqlExpr
    func::String       # "COUNT", "SUM", "AVG", "MIN", "MAX",
                       # "GROUP_CONCAT", "SAMPLE", "MEDIAN", "MODE"
    arg::SparqlExpr
    distinct::Bool
    separator::Union{String, Nothing}
end

"""EXISTS / NOT EXISTS sub-pattern test in FILTER"""
struct ExprExists <: SparqlExpr
    patterns::Vector{Any}   # Vector{SparqlPattern} (Any to break circular ref)
    negated::Bool
end

"""IN / NOT IN list test: `expr (NOT)? IN (val1, val2, ...)`"""
struct ExprIn <: SparqlExpr
    expr::SparqlExpr
    values::Vector{SparqlExpr}
    negated::Bool
end

"""Wildcard `*` used in `COUNT(*)`"""
struct ExprStar <: SparqlExpr end

# ─── Pattern AST ───────────────────────────────────────────────────

abstract type SparqlPattern end

"""Basic graph pattern triple: `subject predicate object`"""
struct PatTriple <: SparqlPattern
    subject::Any       # ExprVar, ExprURI, ExprLiteral, or a path expression
    predicate::Any     # ExprURI, ExprVar, or PathExpr
    object::Any
end

"""FILTER constraint"""
struct PatFilter <: SparqlPattern
    expr::SparqlExpr
end

"""BIND expression: `BIND(expr AS ?var)`"""
struct PatBind <: SparqlPattern
    expr::SparqlExpr
    var::String
end

"""OPTIONAL { patterns }"""
struct PatOptional <: SparqlPattern
    patterns::Vector{SparqlPattern}
end

"""UNION of pattern groups"""
struct PatUnion <: SparqlPattern
    branches::Vector{Vector{SparqlPattern}}
end

"""MINUS { patterns }"""
struct PatMinus <: SparqlPattern
    patterns::Vector{SparqlPattern}
end

"""FILTER EXISTS / NOT EXISTS (at pattern level, references expression)"""
struct PatFilterExists <: SparqlPattern
    patterns::Vector{SparqlPattern}
    negated::Bool
end

"""VALUES inline data"""
struct PatValues <: SparqlPattern
    variables::Vector{String}
    rows::Vector{Vector{Union{Identifier, Nothing}}}
end

"""Subquery: `{ SELECT ... }`"""
struct PatSubquery <: SparqlPattern
    query::Any  # SparqlSelect (Any to break forward ref)
end

"""GRAPH pattern: `GRAPH <uri> { patterns }`"""
struct PatGraph <: SparqlPattern
    graph_term::Any    # ExprURI or ExprVar
    patterns::Vector{SparqlPattern}
end

"""SERVICE endpoint: `SERVICE [SILENT] <uri> { patterns }`"""
struct PatService <: SparqlPattern
    endpoint::Any      # ExprURI or ExprVar
    patterns::Vector{SparqlPattern}
    silent::Bool
end

"""LATERAL { patterns } (SPARQL 1.2)"""
struct PatLateral <: SparqlPattern
    patterns::Vector{SparqlPattern}
end

"""
A nested group `{ ... }` that must be evaluated as an independent join unit
(its own algebra), rather than flattened into the surrounding group. This
preserves SPARQL variable-scope semantics for FILTERs: a FILTER inside a group
is evaluated against that group's own solutions, so it does not see variables
bound only in the enclosing group (SPARQL §18.2.2.2 / §5.2.1).
"""
struct PatGroup <: SparqlPattern
    patterns::Vector{SparqlPattern}
end

"""RDF-star triple term pattern: `<< s p o >>` (SPARQL 1.2)"""
struct PatTripleTerm <: SparqlPattern
    subject::Any
    predicate::Any
    object::Any
    annotation::Any
end

"""
SPARQL 1.2 triple-term term `<<( s p o )>>` used as a subject/object term or
in an expression. Each of `subject`/`predicate`/`object` is itself a term
(URIRef/Literal/BNode/variable-name-String or a nested `TripleTermPattern`).

This is distinct from `TripleTerm` (the concrete RDF value): a `TripleTermPattern`
may contain variables and is resolved/matched recursively during evaluation.
"""
struct TripleTermPattern <: SparqlExpr
    subject::Any
    predicate::Any
    object::Any
end

# ─── Property Path AST ────────────────────────────────────────────
# Preserved from original implementation; well-structured already.

abstract type PathExpr end

struct PathURI <: PathExpr
    uri::URIRef
end

struct PathSequence <: PathExpr
    steps::Vector{PathExpr}
end

struct PathAlternative <: PathExpr
    options::Vector{PathExpr}
end

struct PathInverse <: PathExpr
    path::PathExpr
end

struct PathZeroOrMore <: PathExpr
    path::PathExpr
end

struct PathOneOrMore <: PathExpr
    path::PathExpr
end

struct PathZeroOrOne <: PathExpr
    path::PathExpr
end

"""Negated property set: `!(:p|^:q|...)`.
`uris` holds forward members, `inverse` holds inverse (`^`-prefixed) members."""
struct PathNegatedSet <: PathExpr
    uris::Vector{URIRef}
    inverse::Vector{URIRef}
end

PathNegatedSet(uris::Vector{URIRef}) = PathNegatedSet(uris, URIRef[])

# ─── Select expression (computed column) ──────────────────────────

"""A `(expr AS ?alias)` in SELECT clause"""
struct SelectExpr
    expr::SparqlExpr
    alias::String
end

"""An aggregate in SELECT clause with its alias"""
struct SelectAggregate
    agg::ExprAggregate
    alias::String
end

# ─── Query AST ────────────────────────────────────────────────────

struct SparqlSelect
    variables::Vector{String}               # empty = SELECT *
    patterns::Vector{SparqlPattern}
    prefixes::Dict{String, String}
    limit::Union{Int, Nothing}
    offset::Int
    order_by::Vector{Tuple{SparqlExpr, Symbol}}  # (expr, :asc/:desc)
    distinct::Bool
    reduced::Bool
    aggregates::Vector{SelectAggregate}
    group_by::Vector{SparqlExpr}
    having::Union{SparqlExpr, Nothing}
    select_exprs::Vector{SelectExpr}
    from::Vector{URIRef}                    # FROM <iri> dataset clauses
    from_named::Vector{URIRef}              # FROM NAMED <iri> dataset clauses
end

# Backwards-compatible constructor (no dataset clauses)
function SparqlSelect(variables, patterns, prefixes, limit, offset, order_by,
                      distinct, reduced, aggregates, group_by, having, select_exprs)
    SparqlSelect(variables, patterns, prefixes, limit, offset, order_by,
                 distinct, reduced, aggregates, group_by, having, select_exprs,
                 URIRef[], URIRef[])
end

struct SparqlAsk
    patterns::Vector{SparqlPattern}
    prefixes::Dict{String, String}
end

struct SparqlConstruct
    template::Vector{PatTriple}
    patterns::Vector{SparqlPattern}
    prefixes::Dict{String, String}
    limit::Union{Int, Nothing}
    offset::Int
    order_by::Vector{Tuple{SparqlExpr, Symbol}}
    from::Vector{URIRef}                    # FROM <iri> dataset clauses
    from_named::Vector{URIRef}              # FROM NAMED <iri> dataset clauses
end
# Backward-compatible constructor (no dataset clauses).
SparqlConstruct(template, patterns, prefixes, limit, offset, order_by) =
    SparqlConstruct(template, patterns, prefixes, limit, offset, order_by, URIRef[], URIRef[])

struct SparqlDescribe
    terms::Vector{Any}                      # ExprURI or ExprVar
    patterns::Vector{SparqlPattern}
    prefixes::Dict{String, String}
    from::Vector{URIRef}                    # FROM <iri> dataset clauses
    from_named::Vector{URIRef}              # FROM NAMED <iri> dataset clauses
end
SparqlDescribe(terms, patterns, prefixes) =
    SparqlDescribe(terms, patterns, prefixes, URIRef[], URIRef[])

# ─── Union type for query dispatch ────────────────────────────────

const SparqlQuery = Union{SparqlSelect, SparqlAsk, SparqlConstruct, SparqlDescribe}

# ─── UPDATE AST ───────────────────────────────────────────────────
#
# Quad-aware UPDATE AST nodes. A "quad" is a 4-tuple `(s, p, o, graph)`:
#   * `s`/`p`/`o` are terms (URIRef, Literal, BNode) or variable-name `String`s
#   * `graph` is `nothing` (default graph), a `URIRef` (`GRAPH <iri> { … }`),
#     or a variable-name `String` (`GRAPH ?g { … }`, only in modify templates)
#
# These supersede the 3-tuple `_SPARQL*` update structs in `sparql.jl` for any
# operation that uses a `GRAPH` block. The parser still emits the legacy
# 3-tuple `_SPARQL*` structs for plain (no-GRAPH) operations, preserving the
# existing evaluator contract; it emits the quad structs below only when a
# `GRAPH` block is present. Multi-operation requests are wrapped in
# `UpdateRequest` (a `;`-separated sequence executed in order).

const QuadTuple = Tuple{Any, Any, Any, Any}   # (s, p, o, graph)

"""INSERT DATA with one or more GRAPH blocks."""
struct UpdateInsertData
    quads::Vector{QuadTuple}
    prefixes::Dict{String, String}
end

"""DELETE DATA with one or more GRAPH blocks."""
struct UpdateDeleteData
    quads::Vector{QuadTuple}
    prefixes::Dict{String, String}
end

"""DELETE/INSERT … WHERE whose templates reference named graphs."""
struct UpdateModify
    delete_template::Vector{QuadTuple}
    insert_template::Vector{QuadTuple}
    patterns::Vector{SparqlPattern}
    prefixes::Dict{String, String}
    with_graph::Union{URIRef, Nothing}
    using_graphs::Vector{URIRef}        # USING <iri> — WHERE-clause default graph(s)
    using_named::Vector{URIRef}         # USING NAMED <iri> — WHERE-clause named graphs
end

UpdateModify(del, ins, pats, prefixes) = UpdateModify(del, ins, pats, prefixes, nothing, URIRef[], URIRef[])
UpdateModify(del, ins, pats, prefixes, with_graph) = UpdateModify(del, ins, pats, prefixes, with_graph, URIRef[], URIRef[])

"""A `;`-separated sequence of update operations, executed in order."""
struct UpdateRequest
    operations::Vector{Any}
end

struct UpdateClear
    target::String     # "ALL", "DEFAULT", "NAMED", "NOOP"
end

struct UpdateLoad
    source::String
    target::Union{String, Nothing}
end

"""
Graph-management UPDATE operation (SPARQL 1.1 Update §3.2):
COPY / MOVE / ADD / CREATE / DROP / CLEAR.

- `op`     — one of `:copy`, `:move`, `:add`, `:create`, `:drop`, `:clear`
- `silent` — SILENT flag
- `source` — for COPY/MOVE/ADD: `:default` or a graph `URIRef`; otherwise `nothing`
- `target` — destination (COPY/MOVE/ADD) or operand (CREATE/DROP/CLEAR):
             `:default`, `:named`, `:all`, or a graph `URIRef`
"""
struct UpdateGraphOp
    op::Symbol
    silent::Bool
    source::Union{URIRef, Symbol, Nothing}
    target::Union{URIRef, Symbol, Nothing}
end

const SparqlUpdate = Union{UpdateInsertData, UpdateDeleteData, UpdateModify,
                           UpdateClear, UpdateLoad, UpdateGraphOp, UpdateRequest}
