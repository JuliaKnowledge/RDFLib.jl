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
    _hash::UInt  # cached hash (0 = not yet computed)
end

Formula() = Formula(RDFGraph(strict=false), "F" * replace(string(uuid4()), "-" => ""), UInt(0))

function Base.:(==)(a::Formula, b::Formula)
    a === b && return true
    isomorphic(a.graph, b.graph)
end

function Base.hash(a::Formula, h::UInt)
    if a._hash == UInt(0) && length(a.graph) > 0
        # Compute and cache content hash
        ts = sort(collect(a.graph), by=t -> (string(t.subject), string(t.predicate), string(t.object)))
        ch = UInt(0)
        for t in ts
            ch = hash(t, ch)
        end
        a._hash = hash(:Formula, ch)
    end
    h ⊻ (a._hash != UInt(0) ? a._hash : hash(:Formula, h))
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
function _n3_try_qname!(ctx::_N3SerContext, term::TripleTerm)
    _n3_try_qname!(ctx, term.subject)
    _n3_try_qname!(ctx, term.predicate)
    _n3_try_qname!(ctx, term.object)
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

    # Separate formulas, URIRefs, BNodes, and other terms (e.g. TripleTerm)
    formulas = filter(s -> s isa Formula, subjects)
    urirefs = sort(filter(s -> s isa URIRef, subjects), by=s -> s.value)
    bnodes = filter(s -> s isa BNode, subjects)
    others = filter(s -> !(s isa URIRef || s isa BNode || s isa Formula), subjects)
    ordered = vcat(urirefs, bnodes, others, formulas)

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
        escaped = _escape_pn_local(localname)
        escaped === nothing && return n3(u)
        return string(prefix, ":", escaped)
    catch
        return n3(u)
    end
end

_n3_format_node(ctx::_N3SerContext, b::BNode) = n3(b)
_n3_format_node(ctx::_N3SerContext, v::Variable) = n3(v)

function _n3_format_node(ctx::_N3SerContext, tt::TripleTerm)
    string("<< ", _n3_format_node(ctx, tt.subject), " ",
           _n3_format_node(ctx, tt.predicate), " ",
           _n3_format_node(ctx, tt.object), " >>")
end

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
    parse_n3!(g::RDFGraph, input::AbstractString; base=nothing) -> RDFGraph

Parse Notation3 (N3) format from a string and add triples to the graph.
"""
function parse_n3!(g::RDFGraph, input::AbstractString; base::Union{String,Nothing}=nothing)
    parser = _N3Parser(g, String(input))
    if base !== nothing
        parser.base = base
        # Register base directory for file-loading builtins (log:semantics, etc.)
        base_dir = dirname(base)
        if !isempty(base_dir)
            push!(_N3_BASE_DIRS, base_dir)
        end
        # Track current document base URI for builtins like log:parsedAsN3
        push!(_N3_DOC_BASE_URIS, base)
    end
    _n3_parse_document!(parser)
    g
end

# Well-known N3/Semantic Web prefixes used without declaration
const _N3_WELL_KNOWN_PREFIXES = Dict{String,String}(
    "rdf"    => "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    "rdfs"   => "http://www.w3.org/2000/01/rdf-schema#",
    "owl"    => "http://www.w3.org/2002/07/owl#",
    "xsd"    => "http://www.w3.org/2001/XMLSchema#",
    "log"    => "http://www.w3.org/2000/10/swap/log#",
    "math"   => "http://www.w3.org/2000/10/swap/math#",
    "string" => "http://www.w3.org/2000/10/swap/string#",
    "list"   => "http://www.w3.org/2000/10/swap/list#",
    "crypto" => "http://www.w3.org/2000/10/swap/crypto#",
    "time"   => "http://www.w3.org/2000/10/swap/time#",
)

mutable struct _N3Parser
    graph::RDFGraph
    input::String
    pos::Int
    prefixes::Dict{String, String}
    base::Union{String, Nothing}
    bnodecounter::Int
    formula_scope::Int  # incremented when entering a formula to scope _:label BNodes
    forsome_uris::Set{String}   # URIs declared with @forSome
    forall_uris::Set{String}    # URIs declared with @forAll
    doc_bnode_labels::Set{String}  # labels appearing as _:label in the document
end

function _N3Parser(g::RDFGraph, input::String)
    _N3Parser(g, input, 1, Dict{String,String}(), nothing, 0, 0,
              Set{String}(), Set{String}(),
              _scan_doc_bnode_labels(input))
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
    rdf_type = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    log_ForAll = URIRef("http://www.w3.org/2000/10/swap/log#ForAll")
    while true
        _n3_skip_ws!(p)
        c = _n3_peek(p)
        (c === nothing || c == '.') && break
        node = _n3_parse_node!(p)
        if node isa URIRef
            push!(p.forall_uris, node.value)
            add!(p.graph, Triple(node, rdf_type, log_ForAll))
        end
        _n3_skip_ws!(p)
        c = _n3_peek(p)
        c == ',' && (p.pos = nextind(p.input, p.pos))
    end
    _n3_consume!(p, '.')
end

function _n3_parse_forsome_directive!(p::_N3Parser)
    _n3_consume_str!(p, "@forSome")
    _n3_skip_ws!(p)
    rdf_type = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    log_ForSome = URIRef("http://www.w3.org/2000/10/swap/log#ForSome")
    while true
        _n3_skip_ws!(p)
        c = _n3_peek(p)
        (c === nothing || c == '.') && break
        node = _n3_parse_node!(p)
        if node isa URIRef
            push!(p.forsome_uris, node.value)
            add!(p.graph, Triple(node, rdf_type, log_ForSome))
        end
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
            write(buf, _n3_parse_iri_escape!(p))
        else
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        end
    end
    throw(ArgumentError("Unterminated IRI reference"))
end

_n3_is_absolute_uri(uri::AbstractString) = occursin(r"^[A-Za-z][A-Za-z0-9+.-]*:", uri)

function _n3_resolve_uri(base::AbstractString, relative::AbstractString)
    string(URIs.resolvereference(URIs.URI(base), URIs.URI(relative)))
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

    # Check for 'a' keyword — any non-name character is a boundary
    if c == 'a'
        next_pos = nextind(p.input, p.pos)
        if next_pos > lastindex(p.input) ||
           !(_is_pn_chars(p.input[next_pos]) || p.input[next_pos] in (':', '.'))
            p.pos = next_pos
            return (URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"), false)
        end
    end

    # Check for 'is' keyword (N3 "is ... of" syntax: subject is pred of object ≡ object pred subject)
    if c == 'i' && _n3_at_string(p, "is")
        is_end = p.pos
        for _ in 1:2; is_end = nextind(p.input, is_end); end
        if is_end > lastindex(p.input) || p.input[is_end] in (' ', '\t', '\n', '\r')
            _n3_consume_str!(p, "is")
            _n3_skip_ws!(p)
            predicate = _n3_parse_node!(p, target)
            _n3_skip_ws!(p)
            if !_n3_at_string(p, "of")
                throw(ArgumentError("Expected 'of' after 'is <predicate>' at position $(p.pos)"))
            end
            of_end = p.pos
            for _ in 1:2; of_end = nextind(p.input, of_end); end
            if !(of_end > lastindex(p.input) || p.input[of_end] in (' ', '\t', '\n', '\r'))
                throw(ArgumentError("Expected 'of' keyword at position $(p.pos)"))
            end
            _n3_consume_str!(p, "of")
            return (predicate, true)
        end
    end

    # Check for 'has' keyword (N3 explicit forward: S has P O ≡ S P O)
    if c == 'h' && _n3_at_string(p, "has")
        has_end = p.pos
        for _ in 1:3; has_end = nextind(p.input, has_end); end
        if has_end > lastindex(p.input) || p.input[has_end] in (' ', '\t', '\n', '\r')
            _n3_consume_str!(p, "has")
            _n3_skip_ws!(p)
            predicate = _n3_parse_node!(p, target)
            return (predicate, false)
        end
    end

    node = _n3_parse_node!(p, target)
    (node, false)
end

function _n3_parse_object_list!(p::_N3Parser, target::RDFGraph, subject::Identifier, predicate::Identifier, swap::Bool)
    while true
        _n3_skip_ws!(p)
        object = _n3_parse_object!(p, target)

        if swap
            add!(target, Triple(object, predicate, subject))
        else
            add!(target, Triple(subject, predicate, object))
        end

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

    # @forAll URIs become Variables (universal quantification)
    if node isa URIRef && node.value in p.forall_uris
        i = findlast('#', node.value)
        local_name = i !== nothing ? node.value[i+1:end] : basename(node.value)
        node = Variable(local_name)
    end

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

# RDF-star << S P O >> — parse as a Formula containing a single triple
function _n3_parse_quoted_triple!(p::_N3Parser, target::RDFGraph=p.graph)::Identifier
    _n3_consume_str!(p, "<<")
    _n3_skip_ws!(p)
    s = _n3_parse_node!(p, target)
    _n3_skip_ws!(p)
    pred = _n3_parse_node!(p, target)
    _n3_skip_ws!(p)
    o = _n3_parse_node!(p, target)
    _n3_skip_ws!(p)
    _n3_consume_str!(p, ">>")
    f = Formula()
    add!(f, Triple(s, pred, o))
    return f
end

function _n3_parse_base_node!(p::_N3Parser, target::RDFGraph=p.graph)::Identifier
    c = _n3_peek(p)
    c === nothing && throw(ArgumentError("Unexpected end of input"))

    if c == '<'
        # Check for RDF-star << ... >> quoted triple
        next_pos = nextind(p.input, p.pos)
        if next_pos <= lastindex(p.input) && p.input[next_pos] == '<'
            return _n3_parse_quoted_triple!(p, target)
        end
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
    elseif c == '+' || c == '-' || isdigit(c) ||
           (c == '.' && _next_char_is_digit(p.input, p.pos))
        return _n3_parse_numeric_literal!(p)
    elseif _n3_at_keyword(p, "true")
        _n3_consume_str!(p, "true")
        return Literal(true)
    elseif _n3_at_keyword(p, "false")
        _n3_consume_str!(p, "false")
        return Literal(false)
    else
        return _n3_parse_prefixed_name!(p)
    end
end

# Match a keyword (`true`/`false`) only at a token boundary, so that e.g.
# `trueblue:x` or `true:x` parse as prefixed names.
function _n3_at_keyword(p::_N3Parser, word::AbstractString)
    _n3_at_string(p, word) || return false
    endpos = p.pos
    for _ in 1:length(word)
        endpos = nextind(p.input, endpos)
    end
    endpos > lastindex(p.input) && return true
    c = p.input[endpos]
    !(_is_pn_chars(c) || c == ':')
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
    c = _n3_peek(p)
    (c === nothing || !(_is_pn_chars_u(c) || isdigit(c))) &&
        throw(ArgumentError("Invalid blank node label at position $(p.pos)"))
    buf = IOBuffer()
    write(buf, c)
    p.pos = nextind(p.input, p.pos)
    # Dots are only allowed mid-label: buffer them and flush when another
    # label character follows; trailing dots are left unconsumed.
    pending_dots = 0
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if c == '.'
            pending_dots += 1
            p.pos = nextind(p.input, p.pos)
        elseif _is_pn_chars(c)
            while pending_dots > 0
                write(buf, '.')
                pending_dots -= 1
            end
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        else
            break
        end
    end
    p.pos -= pending_dots  # '.' is a single byte; rewind unconsumed dots
    label = String(take!(buf))
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
    # Never collide with a blank node label used explicitly in the document
    while "b$(p.bnodecounter)" in p.doc_bnode_labels
        p.bnodecounter += 1
    end
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

    # Mark sets with rdf:type log:Set
    if is_set
        rdf_type = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
        log_Set = URIRef("http://www.w3.org/2000/10/swap/log#Set")
        add!(target, Triple(head, rdf_type, log_Set))
    end

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

    # PN_LOCAL grammar (shared with the Turtle parser). N3 path operators
    # '!' and '^' are not PN_CHARS, so they naturally terminate the name.
    localname = _parse_pn_local!(p)

    ns_uri = get(p.prefixes, prefix, nothing)
    if isnothing(ns_uri)
        # Default empty prefix to base URI + "#" (N3/CWM convention)
        if prefix == "" && !isnothing(p.base)
            ns_uri = p.base * "#"
        else
            # Fallback: well-known N3/Semantic Web prefixes
            ns_uri = get(_N3_WELL_KNOWN_PREFIXES, prefix, nothing)
            if isnothing(ns_uri)
                throw(ArgumentError("Unknown prefix: '$prefix' at position $(p.pos)"))
            end
        end
    end
    URIRef(ns_uri * localname)
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
        # Optional base direction (RDF 1.2): "x"@en--ltr / "x"@ar--rtl
        if _n3_at_string(p, "--")
            p.pos = nextind(p.input, nextind(p.input, p.pos))
            dir_buf = IOBuffer()
            while p.pos <= lastindex(p.input) && isletter(p.input[p.pos])
                write(dir_buf, p.input[p.pos])
                p.pos = nextind(p.input, p.pos)
            end
            dir = String(take!(dir_buf))
            dir in ("ltr", "rtl") ||
                throw(ArgumentError("Invalid base direction '$dir'; expected 'ltr' or 'rtl'"))
            return Literal(lexical, lang=lang_tag, direction=dir)
        end
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
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if c == quote_char
            # Longest match: in a run of n >= 3 quotes, the final three close
            # the string and any preceding quotes belong to the content.
            run = 0
            while p.pos <= lastindex(p.input) && p.input[p.pos] == quote_char
                run += 1
                p.pos = nextind(p.input, p.pos)
            end
            if run >= 3
                for _ in 1:(run - 3)
                    write(buf, quote_char)
                end
                return String(take!(buf))
            end
            for _ in 1:run
                write(buf, quote_char)
            end
        elseif c == '\\'
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
    p.pos > lastindex(p.input) &&
        throw(ArgumentError("Truncated escape sequence at end of input"))
    c = p.input[p.pos]
    p.pos = nextind(p.input, p.pos)
    if c == 'n'; return '\n'
    elseif c == 'r'; return '\r'
    elseif c == 't'; return '\t'
    elseif c == 'b'; return '\b'
    elseif c == 'f'; return '\f'
    elseif c == '\\'; return '\\'
    elseif c == '"'; return '"'
    elseif c == '\''; return '\''
    elseif c == 'u'
        return _n3_parse_hex_escape!(p, 4)
    elseif c == 'U'
        return _n3_parse_hex_escape!(p, 8)
    else
        return c
    end
end

# Parse exactly `n` hex digits of a \\u/\\U escape with clean errors.
function _n3_parse_hex_escape!(p::_N3Parser, n::Int)
    cp = UInt32(0)
    for _ in 1:n
        p.pos > lastindex(p.input) &&
            throw(ArgumentError("Truncated \\u escape at end of input"))
        c = p.input[p.pos]
        _is_hex_digit(c) ||
            throw(ArgumentError("Invalid hex digit '$c' in \\u escape at position $(p.pos)"))
        cp = cp * 0x10 + UInt32(parse(UInt8, string(c), base=16))
        p.pos = nextind(p.input, p.pos)
    end
    (0xD800 <= cp <= 0xDFFF) &&
        throw(ArgumentError("Surrogate code point U+$(string(cp, base=16, pad=4)) in \\u escape"))
    cp > 0x10FFFF &&
        throw(ArgumentError("Code point out of range in \\U escape"))
    Char(cp)
end

# Inside an IRIREF (<...>) only \\u and \\U escapes are legal.
function _n3_parse_iri_escape!(p::_N3Parser)
    p.pos > lastindex(p.input) &&
        throw(ArgumentError("Truncated escape sequence in IRI reference"))
    c = p.input[p.pos]
    p.pos = nextind(p.input, p.pos)
    c == 'u' && return _n3_parse_hex_escape!(p, 4)
    c == 'U' && return _n3_parse_hex_escape!(p, 8)
    throw(ArgumentError("Invalid escape '\\$c' in IRI reference; only \\u and \\U are allowed"))
end

function _n3_parse_lang_tag!(p::_N3Parser)
    buf = IOBuffer()
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if isletter(c) || isdigit(c)
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        elseif c == '-'
            # A '-' only continues the tag when followed by an alphanumeric
            # subtag; "--" introduces a base direction (handled by the caller).
            next_pos = nextind(p.input, p.pos)
            if next_pos <= lastindex(p.input) &&
               (isletter(p.input[next_pos]) || isdigit(p.input[next_pos]))
                write(buf, c)
                p.pos = nextind(p.input, p.pos)
            else
                break
            end
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
