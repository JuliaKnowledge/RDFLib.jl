# ─── Notation3 (N3) Format ───────────────────────────────────────────
# N3 is a superset of Turtle adding formulas (quoted graphs),
# implications (=>), reverse implications (<=), owl:sameAs (=),
# @forAll/@forSome directives, and ?variable syntax.

# ─── Formula type ────────────────────────────────────────────────────

"""
    Formula <: Node

An N3 formula (quoted graph) — a set of triples enclosed in `{ }`.
Can appear as subject or object in triples, enabling logical rules.

# Examples
```julia
f = Formula()
add!(f, Triple(URIRef("http://ex.org/s"), URIRef("http://ex.org/p"), URIRef("http://ex.org/o")))
```
"""
mutable struct Formula <: Node
    graph::RDFGraph
    id::String
end

Formula() = Formula(RDFGraph(), "F" * replace(string(uuid4()), "-" => ""))

function Base.:(==)(a::Formula, b::Formula)
    isomorphic(a.graph, b.graph)
end

function Base.hash(a::Formula, h::UInt)
    # Hash based on sorted triple signatures for consistency
    ts = sort(collect(a.graph), by=t -> (string(t.subject), string(t.predicate), string(t.object)))
    for t in ts
        h = hash(t, h)
    end
    hash(:Formula, h)
end

Base.show(io::IO, f::Formula) = print(io, "Formula(", length(f.graph), " triples)")

function n3(f::Formula)
    buf = IOBuffer()
    write(buf, "{ ")
    for (i, t) in enumerate(f.graph)
        i > 1 && write(buf, " ")
        write(buf, n3(t.subject), " ", n3(t.predicate), " ", n3(t.object), " .")
    end
    write(buf, " }")
    String(take!(buf))
end

"""Add a triple to a Formula's internal graph."""
function add!(f::Formula, t::Triple)
    add!(f.graph, t)
    f
end

# ─── N3 Namespaces ──────────────────────────────────────────────────

const LOG = Namespace("http://www.w3.org/2000/10/swap/log#")
const MATH = Namespace("http://www.w3.org/2000/10/swap/math#")

# ─── N3 Format Type ─────────────────────────────────────────────────
# N3Format is defined in formats.jl

# ─── N3 Serializer ──────────────────────────────────────────────────

"""
    serialize_n3(io::IO, g::RDFGraph)

Serialize a graph in Notation3 format.
"""
function serialize_n3(io::IO, g::RDFGraph)
    ctx = _N3SerContext(g)
    _n3_preprocess!(ctx)
    _n3_write_prefixes(io, ctx)
    _n3_write_triples(io, ctx)
end

"""
    serialize_n3(g::RDFGraph) -> String

Serialize a graph to a Notation3 format string.
"""
function serialize_n3(g::RDFGraph)
    buf = IOBuffer()
    serialize_n3(buf, g)
    String(take!(buf))
end

mutable struct _N3SerContext
    graph::RDFGraph
    subject_props::Dict{Node, Dict{URIRef, Vector{Identifier}}}
    references::Dict{Identifier, Int}
    serialized::Set{Node}
    prefixes::Dict{String, String}

    function _N3SerContext(g::RDFGraph)
        new(g,
            Dict{Node, Dict{URIRef, Vector{Identifier}}}(),
            Dict{Identifier, Int}(),
            Set{Node}(),
            Dict{String, String}())
    end
end

function _n3_preprocess!(ctx::_N3SerContext)
    g = ctx.graph
    for t in g
        s, p, o = t.subject, t.predicate, t.object
        if !haskey(ctx.subject_props, s)
            ctx.subject_props[s] = Dict{URIRef, Vector{Identifier}}()
        end
        props = ctx.subject_props[s]
        if !haskey(props, p)
            props[p] = Identifier[]
        end
        push!(props[p], o)
        ctx.references[o] = get(ctx.references, o, 0) + 1
    end

    for (prefix, ns_uri) in namespaces(g)
        ctx.prefixes[prefix] = ns_uri
    end

    for t in g
        _n3_try_qname!(ctx, t.subject)
        _n3_try_qname!(ctx, t.predicate)
        _n3_try_qname!(ctx, t.object)
    end
end

function _n3_try_qname!(ctx::_N3SerContext, u::URIRef)
    try
        prefix, ns_uri, _ = compute_qname(ctx.graph.namespace_manager, u)
        ctx.prefixes[prefix] = ns_uri
    catch
    end
end
_n3_try_qname!(::_N3SerContext, ::Identifier) = nothing

function _n3_write_prefixes(io::IO, ctx::_N3SerContext)
    sorted = sort(collect(ctx.prefixes), by=first)
    for (prefix, uri) in sorted
        write(io, "@prefix ", prefix, ": <", uri, "> .\n")
    end
    if !isempty(sorted)
        write(io, "\n")
    end
end

function _n3_write_triples(io::IO, ctx::_N3SerContext)
    subjects = collect(keys(ctx.subject_props))

    # Separate formulas, URIRefs, BNodes
    formulas = filter(s -> s isa Formula, subjects)
    urirefs = sort(filter(s -> s isa URIRef, subjects), by=s -> s.value)
    bnodes = filter(s -> s isa BNode, subjects)
    ordered = vcat(urirefs, bnodes, formulas)

    first_subject = true
    for subject in ordered
        subject in ctx.serialized && continue
        if !first_subject
            write(io, "\n")
        end
        first_subject = false
        _n3_write_subject(io, ctx, subject)
    end
end

function _n3_write_subject(io::IO, ctx::_N3SerContext, subject::Node)
    push!(ctx.serialized, subject)
    props = ctx.subject_props[subject]

    log_implies = URIRef("http://www.w3.org/2000/10/swap/log#implies")
    owl_sameAs = URIRef("http://www.w3.org/2002/07/owl#sameAs")

    # Check for implication shorthand: Formula => Formula
    if subject isa Formula && haskey(props, log_implies) && length(props) == 1
        objs = props[log_implies]
        for obj in objs
            _n3_write_formula(io, ctx, subject)
            write(io, " => ")
            if obj isa Formula
                _n3_write_formula(io, ctx, obj)
            else
                write(io, _n3_format_node(ctx, obj))
            end
            write(io, " .\n")
        end
        return
    end

    # Normal subject
    if subject isa Formula
        _n3_write_formula(io, ctx, subject)
    elseif subject isa BNode && get(ctx.references, subject, 0) == 0
        write(io, "[]")
    else
        write(io, _n3_format_node(ctx, subject))
    end

    _n3_write_predicate_list(io, ctx, props, 1)
    write(io, " .\n")
end

function _n3_write_formula(io::IO, ctx::_N3SerContext, f::Formula)
    write(io, "{\n")
    for t in f.graph
        write(io, "    ", _n3_format_node(ctx, t.subject))
        write(io, " ", _n3_format_verb(ctx, t.predicate))
        write(io, " ")
        if t.object isa Formula
            _n3_write_formula(io, ctx, t.object)
        else
            write(io, _n3_format_node(ctx, t.object))
        end
        write(io, " .\n")
    end
    write(io, "}")
end

function _n3_write_predicate_list(io::IO, ctx::_N3SerContext,
                                   props::Dict{URIRef, Vector{Identifier}},
                                   indent_level::Int)
    indent = "    " ^ indent_level
    rdf_type = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    owl_sameAs = URIRef("http://www.w3.org/2002/07/owl#sameAs")

    preds = sort(collect(keys(props)), by=p -> p.value)
    type_idx = findfirst(p -> p == rdf_type, preds)
    if !isnothing(type_idx) && type_idx > 1
        deleteat!(preds, type_idx)
        pushfirst!(preds, rdf_type)
    end

    for (i, pred) in enumerate(preds)
        if i == 1
            write(io, " ")
        else
            write(io, " ;\n", indent)
        end

        # Use shorthand operators
        if pred == owl_sameAs
            write(io, "=")
        else
            write(io, _n3_format_verb(ctx, pred))
        end

        write(io, " ")
        _n3_write_object_list(io, ctx, props[pred])
    end
end

function _n3_write_object_list(io::IO, ctx::_N3SerContext, objects::Vector{Identifier})
    for (i, obj) in enumerate(objects)
        i > 1 && write(io, ", ")
        if obj isa Formula
            _n3_write_formula(io, ctx, obj)
        else
            write(io, _n3_format_node(ctx, obj))
        end
    end
end

function _n3_format_verb(ctx::_N3SerContext, pred::URIRef)
    rdf_type = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    log_implies = URIRef("http://www.w3.org/2000/10/swap/log#implies")
    if pred == rdf_type
        return "a"
    elseif pred == log_implies
        return "=>"
    end
    _n3_format_node(ctx, pred)
end

function _n3_format_node(ctx::_N3SerContext, u::URIRef)
    try
        prefix, _, localname = compute_qname(ctx.graph.namespace_manager, u)
        return string(prefix, ":", localname)
    catch
        return n3(u)
    end
end

_n3_format_node(ctx::_N3SerContext, b::BNode) = n3(b)
_n3_format_node(ctx::_N3SerContext, v::Variable) = n3(v)

function _n3_format_node(ctx::_N3SerContext, lit::Literal)
    if !isnothing(lit.datatype) && isnothing(lit.language)
        dt = lit.datatype
        xsd_uri = "http://www.w3.org/2001/XMLSchema#"
        if dt.value == xsd_uri * "integer"
            return lit.lexical
        elseif dt.value == xsd_uri * "decimal"
            return lit.lexical
        elseif dt.value == xsd_uri * "boolean"
            return lit.lexical
        end
    end
    n3(lit)
end

# ─── N3 Parser ──────────────────────────────────────────────────────

"""
    parse_n3(source) -> RDFGraph

Parse Notation3 (N3) format into a graph.
"""
function parse_n3(source)
    g = RDFGraph()
    if source isa IO || source isa IOBuffer
        parse_n3!(g, read(source, String))
    else
        parse_n3!(g, String(source))
    end
end

"""
    parse_n3!(g::RDFGraph, input::AbstractString) -> RDFGraph

Parse Notation3 (N3) format from a string and add triples to the graph.
"""
function parse_n3!(g::RDFGraph, input::AbstractString)
    parser = _N3Parser(g, String(input))
    _n3_parse_document!(parser)
    g
end

mutable struct _N3Parser
    graph::RDFGraph
    input::String
    pos::Int
    prefixes::Dict{String, String}
    base::Union{String, Nothing}
    bnodecounter::Int
    formula_scope::Int  # incremented when entering a formula to scope _:label BNodes
end

function _N3Parser(g::RDFGraph, input::String)
    _N3Parser(g, input, 1, Dict{String,String}(), nothing, 0, 0)
end

# ─── Shared parser utilities ────────────────────────────────────────

function _n3_skip_ws!(p::_N3Parser)
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if c in (' ', '\t', '\n', '\r')
            p.pos = nextind(p.input, p.pos)
        elseif c == '#'
            while p.pos <= lastindex(p.input) && p.input[p.pos] != '\n'
                p.pos = nextind(p.input, p.pos)
            end
        else
            break
        end
    end
end

function _n3_peek(p::_N3Parser)
    p.pos > lastindex(p.input) && return nothing
    p.input[p.pos]
end

function _n3_peek_str(p::_N3Parser, n::Int)
    endpos = p.pos
    for _ in 1:n-1
        endpos > lastindex(p.input) && return SubString(p.input, p.pos, lastindex(p.input))
        endpos = nextind(p.input, endpos)
    end
    endpos > lastindex(p.input) && return SubString(p.input, p.pos, lastindex(p.input))
    SubString(p.input, p.pos, endpos)
end

function _n3_consume!(p::_N3Parser, expected::Char)
    c = _n3_peek(p)
    c === nothing && throw(ArgumentError("Unexpected end of input, expected '$expected'"))
    c != expected && throw(ArgumentError("Expected '$expected', got '$c' at position $(p.pos)"))
    p.pos = nextind(p.input, p.pos)
    c
end

function _n3_consume_str!(p::_N3Parser, expected::AbstractString)
    for c in expected
        _n3_consume!(p, c)
    end
end

function _n3_at_string(p::_N3Parser, s::AbstractString)
    endpos = p.pos
    for c in s
        endpos > lastindex(p.input) && return false
        p.input[endpos] != c && return false
        endpos = nextind(p.input, endpos)
    end
    true
end

function _n3_at_string_ci(p::_N3Parser, s::AbstractString)
    endpos = p.pos
    for c in s
        endpos > lastindex(p.input) && return false
        lowercase(p.input[endpos]) != lowercase(c) && return false
        endpos = nextind(p.input, endpos)
    end
    true
end

# ─── Document parsing ───────────────────────────────────────────────

function _n3_parse_document!(p::_N3Parser)
    _n3_skip_ws!(p)
    while p.pos <= lastindex(p.input)
        if _n3_at_string(p, "@prefix")
            _n3_parse_prefix_directive!(p)
        elseif _n3_at_string(p, "@base")
            _n3_parse_base_directive!(p)
        elseif _n3_at_string(p, "@forAll")
            _n3_parse_forall_directive!(p)
        elseif _n3_at_string(p, "@forSome")
            _n3_parse_forsome_directive!(p)
        elseif _n3_at_sparql_prefix(p)
            _n3_parse_sparql_prefix!(p)
        elseif _n3_at_sparql_base(p)
            _n3_parse_sparql_base!(p)
        else
            _n3_parse_triples!(p, p.graph)
        end
        _n3_skip_ws!(p)
    end
end

function _n3_at_sparql_prefix(p::_N3Parser)
    _n3_at_string_ci(p, "PREFIX") && !_n3_at_string_ci(p, "PREFIX:")
end

function _n3_at_sparql_base(p::_N3Parser)
    _n3_at_string_ci(p, "BASE") && !_n3_at_string_ci(p, "BASE:")
end

# ─── Directive parsing ──────────────────────────────────────────────

function _n3_parse_prefix_directive!(p::_N3Parser)
    _n3_consume_str!(p, "@prefix")
    _n3_skip_ws!(p)
    prefix = _n3_parse_prefix_name!(p)
    _n3_skip_ws!(p)
    uri = _n3_parse_iriref!(p)
    _n3_skip_ws!(p)
    _n3_consume!(p, '.')
    p.prefixes[prefix] = uri
    bind!(p.graph, prefix, Namespace(uri))
end

function _n3_parse_sparql_prefix!(p::_N3Parser)
    for _ in 1:6; p.pos = nextind(p.input, p.pos); end
    _n3_skip_ws!(p)
    prefix = _n3_parse_prefix_name!(p)
    _n3_skip_ws!(p)
    uri = _n3_parse_iriref!(p)
    p.prefixes[prefix] = uri
    bind!(p.graph, prefix, Namespace(uri))
end

function _n3_parse_base_directive!(p::_N3Parser)
    _n3_consume_str!(p, "@base")
    _n3_skip_ws!(p)
    uri = _n3_parse_iriref!(p)
    _n3_skip_ws!(p)
    _n3_consume!(p, '.')
    p.base = uri
end

function _n3_parse_sparql_base!(p::_N3Parser)
    for _ in 1:4; p.pos = nextind(p.input, p.pos); end
    _n3_skip_ws!(p)
    uri = _n3_parse_iriref!(p)
    p.base = uri
end

function _n3_parse_forall_directive!(p::_N3Parser)
    _n3_consume_str!(p, "@forAll")
    _n3_skip_ws!(p)
    # Parse variable list until '.'
    while true
        _n3_skip_ws!(p)
        c = _n3_peek(p)
        (c === nothing || c == '.') && break
        _n3_parse_node!(p)  # consume the variable/term
        _n3_skip_ws!(p)
        c = _n3_peek(p)
        c == ',' && (p.pos = nextind(p.input, p.pos))
    end
    _n3_consume!(p, '.')
end

function _n3_parse_forsome_directive!(p::_N3Parser)
    _n3_consume_str!(p, "@forSome")
    _n3_skip_ws!(p)
    while true
        _n3_skip_ws!(p)
        c = _n3_peek(p)
        (c === nothing || c == '.') && break
        _n3_parse_node!(p)
        _n3_skip_ws!(p)
        c = _n3_peek(p)
        c == ',' && (p.pos = nextind(p.input, p.pos))
    end
    _n3_consume!(p, '.')
end

function _n3_parse_prefix_name!(p::_N3Parser)
    buf = IOBuffer()
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if c == ':'
            p.pos = nextind(p.input, p.pos)
            return String(take!(buf))
        elseif c in (' ', '\t', '\n', '\r')
            throw(ArgumentError("Unexpected whitespace in prefix name at position $(p.pos)"))
        else
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        end
    end
    throw(ArgumentError("Unexpected end of input in prefix name"))
end

function _n3_parse_iriref!(p::_N3Parser)
    _n3_consume!(p, '<')
    buf = IOBuffer()
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if c == '>'
            p.pos = nextind(p.input, p.pos)
            uri = String(take!(buf))
            if !isnothing(p.base) && !_n3_is_absolute_uri(uri)
                return _n3_resolve_uri(p.base, uri)
            end
            return uri
        elseif c == '\\'
            p.pos = nextind(p.input, p.pos)
            write(buf, _n3_parse_escape_char!(p))
        else
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        end
    end
    throw(ArgumentError("Unterminated IRI reference"))
end

_n3_is_absolute_uri(uri::AbstractString) = occursin("://", uri) || startswith(uri, "urn:")

function _n3_resolve_uri(base::AbstractString, relative::AbstractString)
    isempty(relative) && return base
    startswith(relative, '#') && return string(base, relative)
    idx = findlast('/', base)
    isnothing(idx) ? relative : string(base[1:idx], relative)
end

# ─── Triple parsing ─────────────────────────────────────────────────

function _n3_parse_triples!(p::_N3Parser, target::RDFGraph)
    _n3_skip_ws!(p)
    c = _n3_peek(p)
    c === nothing && return

    subject = _n3_parse_subject!(p, target)
    _n3_skip_ws!(p)

    _n3_parse_predicate_object_list!(p, target, subject)

    _n3_skip_ws!(p)
    c = _n3_peek(p)
    if c == '.'
        _n3_consume!(p, '.')
    end
    # In formulas, the '.' may be omitted before '}'
end

function _n3_parse_subject!(p::_N3Parser, target::RDFGraph)::Identifier
    _n3_parse_node!(p, target)
end

# Resolve an RDF list from graph — used for predicate list expansion
function _n3_resolve_list(node::Identifier, graph::RDFGraph)
    rdf_first = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
    rdf_rest = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
    rdf_nil = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
    node isa BNode || return nothing
    items = Identifier[]
    current = node
    seen = Set{Identifier}()
    while current != rdf_nil
        current in seen && return nothing
        push!(seen, current)
        first_val = nothing; rest_val = nothing
        for t in triples(graph, (current, rdf_first, nothing)); first_val = t.object; break; end
        for t in triples(graph, (current, rdf_rest, nothing)); rest_val = t.object; break; end
        first_val === nothing && return nothing
        rest_val === nothing && return nothing
        push!(items, first_val)
        current = rest_val
    end
    items
end

# Remove RDF list structure triples from graph
function _n3_remove_list!(node::Identifier, graph::RDFGraph)
    rdf_first = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
    rdf_rest = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
    rdf_nil = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
    current = node
    while current isa BNode
        next = nothing
        for t in triples(graph, (current, rdf_rest, nothing)); next = t.object; break; end
        for t in collect(triples(graph, (current, nothing, nothing)))
            remove!(graph, (t.subject, t.predicate, t.object))
        end
        current = next
    end
end

function _n3_parse_predicate_object_list!(p::_N3Parser, target::RDFGraph, subject::Identifier)
    while true
        _n3_skip_ws!(p)
        c = _n3_peek(p)
        (c === nothing || c == '.' || c == ']' || c == ')' || c == '}') && break

        # Check for N3 operators: =>, <=, =
        predicate, swap = _n3_parse_verb!(p, target)
        _n3_skip_ws!(p)

        # If predicate is a BNode list head, expand into multiple predicates
        if predicate isa BNode
            preds = _n3_resolve_list(predicate, target)
            if preds !== nothing && !isempty(preds)
                # Remove the list structure triples for the predicate list
                _n3_remove_list!(predicate, target)
                # Parse objects once, then add triples for each predicate
                objects = Identifier[]
                while true
                    _n3_skip_ws!(p)
                    obj = _n3_parse_object!(p, target)
                    push!(objects, obj)
                    _n3_skip_ws!(p)
                    c2 = _n3_peek(p)
                    if c2 == ','
                        p.pos = nextind(p.input, p.pos)
                    else
                        break
                    end
                end
                for pred in preds
                    for obj in objects
                        add!(target, Triple(subject, pred, obj))
                    end
                end
            else
                _n3_parse_object_list!(p, target, subject, predicate, swap)
            end
        else
            _n3_parse_object_list!(p, target, subject, predicate, swap)
        end

        _n3_skip_ws!(p)
        c = _n3_peek(p)
        if c == ';'
            p.pos = nextind(p.input, p.pos)
            _n3_skip_ws!(p)
            c2 = _n3_peek(p)
            (c2 === nothing || c2 == '.' || c2 == ']' || c2 == '}') && break
        else
            break
        end
    end
end

function _n3_parse_verb!(p::_N3Parser, target::RDFGraph)
    c = _n3_peek(p)
    log_implies = URIRef("http://www.w3.org/2000/10/swap/log#implies")
    owl_sameAs = URIRef("http://www.w3.org/2002/07/owl#sameAs")

    # Check for => (log:implies)
    s2 = _n3_peek_str(p, 2)
    if s2 == "=>"
        _n3_consume_str!(p, "=>")
        return (log_implies, false)
    end

    # Check for <= (log:impliedBy — backward chaining)
    if s2 == "<="
        _n3_consume_str!(p, "<=")
        log_impliedBy = URIRef("http://www.w3.org/2000/10/swap/log#impliedBy")
        return (log_impliedBy, false)  # keep original order: consequent <= antecedent
    end

    # Check for = (owl:sameAs) — but not == or =>
    if c == '='
        next_pos = nextind(p.input, p.pos)
        next_c = next_pos <= lastindex(p.input) ? p.input[next_pos] : nothing
        if next_c != '>' && next_c != '='
            p.pos = nextind(p.input, p.pos)
            return (owl_sameAs, false)
        end
    end

    # Check for 'a' keyword
    if c == 'a'
        next_pos = nextind(p.input, p.pos)
        if next_pos > lastindex(p.input) || p.input[next_pos] in (' ', '\t', '\n', '\r')
            p.pos = next_pos
            return (URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"), false)
        end
    end

    node = _n3_parse_node!(p, target)
    (node, false)
end

function _n3_parse_object_list!(p::_N3Parser, target::RDFGraph, subject::Identifier, predicate::Identifier, swap::Bool)
    while true
        _n3_skip_ws!(p)
        object = _n3_parse_object!(p, target)

        add!(target, Triple(subject, predicate, object))

        _n3_skip_ws!(p)
        c = _n3_peek(p)
        if c == ','
            p.pos = nextind(p.input, p.pos)
        else
            break
        end
    end
end

function _n3_parse_object!(p::_N3Parser, target::RDFGraph)::Identifier
    _n3_parse_node!(p, target)
end

# ─── Node parsing ───────────────────────────────────────────────────

function _n3_parse_node!(p::_N3Parser, target::RDFGraph=p.graph)::Identifier
    c = _n3_peek(p)
    c === nothing && throw(ArgumentError("Unexpected end of input"))

    node = _n3_parse_base_node!(p, target)

    # Handle N3 resource path syntax: node!pred (forward) or node^pred (reverse)
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if c == '!'
            p.pos = nextind(p.input, p.pos)
            pred = _n3_parse_base_node!(p, target)
            pred isa URIRef || throw(ArgumentError("Path predicate must be a URI at position $(p.pos)"))
            bn = BNode()
            add!(target, Triple(node, pred, bn))
            node = bn
        elseif c == '^'
            # Make sure it's not ^^ (datatype)
            next_pos = nextind(p.input, p.pos)
            if next_pos <= lastindex(p.input) && p.input[next_pos] == '^'
                break  # ^^ is datatype indicator, not path
            end
            p.pos = nextind(p.input, p.pos)
            pred = _n3_parse_base_node!(p, target)
            pred isa URIRef || throw(ArgumentError("Path predicate must be a URI at position $(p.pos)"))
            bn = BNode()
            add!(target, Triple(bn, pred, node))
            node = bn
        else
            break
        end
    end

    return node
end

function _n3_parse_base_node!(p::_N3Parser, target::RDFGraph=p.graph)::Identifier
    c = _n3_peek(p)
    c === nothing && throw(ArgumentError("Unexpected end of input"))

    if c == '<'
        return URIRef(_n3_parse_iriref!(p))
    elseif c == '_'
        return _n3_parse_blank_node_label!(p)
    elseif c == '['
        return _n3_parse_blank_node_property_list!(p, target)
    elseif c == '('
        return _n3_parse_collection!(p, target)
    elseif c == '{'
        return _n3_parse_formula!(p)
    elseif c == '?'
        return _n3_parse_variable!(p)
    elseif c == '"' || c == '\''
        return _n3_parse_literal!(p)
    elseif c == '+' || c == '-' || isdigit(c)
        return _n3_parse_numeric_literal!(p)
    elseif _n3_at_string(p, "true")
        next_pos = p.pos
        for _ in 1:4
            next_pos = nextind(p.input, next_pos)
        end
        # Make sure 'true' isn't a prefix of a longer word
        if next_pos > lastindex(p.input) || p.input[next_pos] in (' ', '\t', '\n', '\r', '.', ';', ',', ')', ']', '}')
            _n3_consume_str!(p, "true")
            return Literal(true)
        end
        return _n3_parse_prefixed_name!(p)
    elseif _n3_at_string(p, "false")
        next_pos = p.pos
        for _ in 1:5
            next_pos = nextind(p.input, next_pos)
        end
        if next_pos > lastindex(p.input) || p.input[next_pos] in (' ', '\t', '\n', '\r', '.', ';', ',', ')', ']', '}')
            _n3_consume_str!(p, "false")
            return Literal(false)
        end
        return _n3_parse_prefixed_name!(p)
    else
        return _n3_parse_prefixed_name!(p)
    end
end

# ─── Variable parsing ──────────────────────────────────────────────

function _n3_parse_variable!(p::_N3Parser)
    _n3_consume!(p, '?')
    buf = IOBuffer()
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if isletter(c) || isdigit(c) || c == '_'
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        else
            break
        end
    end
    name = String(take!(buf))
    isempty(name) && throw(ArgumentError("Empty variable name at position $(p.pos)"))
    Variable(name)
end

# ─── Formula parsing ───────────────────────────────────────────────

function _n3_parse_formula!(p::_N3Parser)
    _n3_consume!(p, '{')
    f = Formula()
    # Copy prefixes into formula graph
    for (prefix, uri) in p.prefixes
        bind!(f.graph, prefix, Namespace(uri))
    end

    # Scope named BNodes to this formula level
    p.formula_scope += 1
    saved_scope = p.formula_scope

    _n3_skip_ws!(p)
    while true
        _n3_skip_ws!(p)
        c = _n3_peek(p)
        (c === nothing || c == '}') && break

        # Parse a triple statement into the formula's graph
        _n3_parse_triples!(p, f.graph)
        _n3_skip_ws!(p)
    end

    # Restore scope (formula_scope keeps incrementing, never decremented)
    _n3_consume!(p, '}')
    f
end

# ─── Blank node parsing ────────────────────────────────────────────

function _n3_parse_blank_node_label!(p::_N3Parser)
    _n3_consume!(p, '_')
    _n3_consume!(p, ':')
    buf = IOBuffer()
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if isletter(c) || isdigit(c) || c in ('_', '-', '.', '·')
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        else
            break
        end
    end
    label = String(take!(buf))
    label = rstrip(label, '.')
    # Scope named BNodes per formula to avoid collisions across { } blocks
    if p.formula_scope > 0
        BNode("$(label)_scope$(p.formula_scope)")
    else
        BNode(label)
    end
end

function _n3_parse_blank_node_property_list!(p::_N3Parser, target::RDFGraph)
    _n3_consume!(p, '[')
    _n3_skip_ws!(p)
    bnode = _n3_new_bnode!(p)

    c = _n3_peek(p)
    if c != ']'
        _n3_parse_predicate_object_list!(p, target, bnode)
    end

    _n3_skip_ws!(p)
    _n3_consume!(p, ']')
    bnode
end

function _n3_new_bnode!(p::_N3Parser)
    p.bnodecounter += 1
    BNode("b$(p.bnodecounter)")
end

# ─── Collection parsing ────────────────────────────────────────────

function _n3_parse_collection!(p::_N3Parser, target::RDFGraph)
    _n3_consume!(p, '(')
    _n3_skip_ws!(p)

    # Handle ($ ... $) set syntax — treat as regular list
    is_set = false
    c = _n3_peek(p)
    if c == '\$'
        is_set = true
        p.pos = nextind(p.input, p.pos)
        _n3_skip_ws!(p)
    end

    rdf_first = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
    rdf_rest = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
    rdf_nil = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")

    c = _n3_peek(p)
    if c == ')' || (is_set && c == '\$')
        if is_set && c == '\$'
            p.pos = nextind(p.input, p.pos)
            _n3_skip_ws!(p)
        end
        _n3_consume!(p, ')')
        return rdf_nil
    end

    head = _n3_new_bnode!(p)
    current = head

    while true
        _n3_skip_ws!(p)
        c = _n3_peek(p)
        (c == ')' || (is_set && c == '\$')) && break

        item = _n3_parse_node!(p, target)
        add!(target, Triple(current, rdf_first, item))

        _n3_skip_ws!(p)
        c = _n3_peek(p)
        if c == ')' || (is_set && c == '\$')
            add!(target, Triple(current, rdf_rest, rdf_nil))
        else
            next_node = _n3_new_bnode!(p)
            add!(target, Triple(current, rdf_rest, next_node))
            current = next_node
        end
    end

    if is_set
        c = _n3_peek(p)
        if c == '\$'
            p.pos = nextind(p.input, p.pos)
            _n3_skip_ws!(p)
        end
    end
    _n3_consume!(p, ')')
    head
end

# ─── Prefixed name parsing ─────────────────────────────────────────

function _n3_parse_prefixed_name!(p::_N3Parser)
    buf = IOBuffer()
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if c == ':'
            p.pos = nextind(p.input, p.pos)
            break
        elseif c in (' ', '\t', '\n', '\r', '.', ';', ',', ')', ']', '}')
            throw(ArgumentError("Invalid prefixed name at position $(p.pos)"))
        else
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        end
    end
    prefix = String(take!(buf))

    local_buf = IOBuffer()
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if c in (' ', '\t', '\n', '\r', '.', ';', ',', ')', ']', '}', '#', '!', '^')
            break
        elseif c == '\\'
            p.pos = nextind(p.input, p.pos)
            write(local_buf, _n3_parse_pname_escape!(p))
        else
            write(local_buf, c)
            p.pos = nextind(p.input, p.pos)
        end
    end
    localname = String(take!(local_buf))

    ns_uri = get(p.prefixes, prefix, nothing)
    if isnothing(ns_uri)
        throw(ArgumentError("Unknown prefix: '$prefix' at position $(p.pos)"))
    end
    URIRef(ns_uri * localname)
end

function _n3_parse_pname_escape!(p::_N3Parser)
    c = p.input[p.pos]
    p.pos = nextind(p.input, p.pos)
    c
end

# ─── Literal parsing ───────────────────────────────────────────────

function _n3_parse_literal!(p::_N3Parser)
    s2 = _n3_peek_str(p, 3)
    if s2 == "\"\"\"" || s2 == "'''"
        lexical = _n3_parse_long_string!(p)
    else
        lexical = _n3_parse_short_string!(p)
    end

    c = _n3_peek(p)
    if c == '@'
        p.pos = nextind(p.input, p.pos)
        lang_tag = _n3_parse_lang_tag!(p)
        return Literal(lexical, lang=lang_tag)
    elseif c == '^'
        _n3_consume_str!(p, "^^")
        dt = _n3_parse_node!(p)
        return Literal(lexical, datatype=dt::URIRef)
    else
        return Literal(lexical)
    end
end

function _n3_parse_short_string!(p::_N3Parser)
    quote_char = p.input[p.pos]
    p.pos = nextind(p.input, p.pos)
    buf = IOBuffer()
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if c == quote_char
            p.pos = nextind(p.input, p.pos)
            return String(take!(buf))
        elseif c == '\\'
            p.pos = nextind(p.input, p.pos)
            write(buf, _n3_parse_escape_char!(p))
        elseif c == '\n' || c == '\r'
            throw(ArgumentError("Newline in short string at position $(p.pos)"))
        else
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        end
    end
    throw(ArgumentError("Unterminated string literal"))
end

function _n3_parse_long_string!(p::_N3Parser)
    quote_char = p.input[p.pos]
    _n3_consume_str!(p, string(quote_char, quote_char, quote_char))
    buf = IOBuffer()
    end_pattern = string(quote_char, quote_char, quote_char)
    while p.pos <= lastindex(p.input)
        if _n3_at_string(p, end_pattern)
            _n3_consume_str!(p, end_pattern)
            return String(take!(buf))
        end
        c = p.input[p.pos]
        if c == '\\'
            p.pos = nextind(p.input, p.pos)
            write(buf, _n3_parse_escape_char!(p))
        else
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        end
    end
    throw(ArgumentError("Unterminated long string literal"))
end

function _n3_parse_escape_char!(p::_N3Parser)
    c = p.input[p.pos]
    p.pos = nextind(p.input, p.pos)
    if c == 'n'; return '\n'
    elseif c == 'r'; return '\r'
    elseif c == 't'; return '\t'
    elseif c == '\\'; return '\\'
    elseif c == '"'; return '"'
    elseif c == '\''; return '\''
    elseif c == 'u'
        hex = p.input[p.pos:nextind(p.input, p.pos, 3)]
        p.pos = nextind(p.input, p.pos, 4)
        return Char(parse(UInt32, hex, base=16))
    elseif c == 'U'
        hex = p.input[p.pos:nextind(p.input, p.pos, 7)]
        p.pos = nextind(p.input, p.pos, 8)
        return Char(parse(UInt32, hex, base=16))
    else
        return c
    end
end

function _n3_parse_lang_tag!(p::_N3Parser)
    buf = IOBuffer()
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if isletter(c) || c == '-' || isdigit(c)
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        else
            break
        end
    end
    String(take!(buf))
end

function _n3_parse_numeric_literal!(p::_N3Parser)
    buf = IOBuffer()
    has_dot = false
    has_exp = false

    c = _n3_peek(p)
    if c == '+' || c == '-'
        write(buf, c)
        p.pos = nextind(p.input, p.pos)
    end

    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if isdigit(c)
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        elseif c == '.' && !has_dot && !has_exp
            next_pos = nextind(p.input, p.pos)
            if next_pos <= lastindex(p.input) && isdigit(p.input[next_pos])
                has_dot = true
                write(buf, c)
                p.pos = next_pos
            else
                break
            end
        elseif (c == 'e' || c == 'E') && !has_exp
            has_exp = true
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
            c2 = _n3_peek(p)
            if c2 == '+' || c2 == '-'
                write(buf, c2)
                p.pos = nextind(p.input, p.pos)
            end
        else
            break
        end
    end

    lexical = String(take!(buf))
    xsd = "http://www.w3.org/2001/XMLSchema#"

    if has_exp
        Literal(lexical, datatype=URIRef(xsd * "double"))
    elseif has_dot
        Literal(lexical, datatype=URIRef(xsd * "decimal"))
    else
        Literal(lexical, datatype=URIRef(xsd * "integer"))
    end
end

# ─── Register format with high-level API ───────────────────────────

serialize(io::IO, g::RDFGraph, ::N3Format) = serialize_n3(io, g)
parse_rdf!(g::RDFGraph, source, ::N3Format) = parse_n3!(g, source isa IO ? read(source, String) : String(source))
