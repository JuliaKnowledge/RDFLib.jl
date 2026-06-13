# ─── TriG Format ────────────────────────────────────────────────────
# Extends Turtle with GRAPH { } blocks for named graphs.

# ─── Serialization ──────────────────────────────────────────────────

"""
    serialize_trig(io::IO, ds::Dataset)

Serialize a dataset as TriG (Turtle with named graph blocks) to an IO stream.
"""
function serialize_trig(io::IO, ds::Dataset)
    # Collect all prefixes from all graphs
    all_prefixes = Dict{String,String}()
    for (prefix, uri) in namespaces(ds)
        all_prefixes[prefix] = uri
    end

    # Write prefix declarations
    sorted = sort(collect(all_prefixes), by=first)
    for (prefix, uri) in sorted
        write(io, "@prefix ", prefix, ": <", uri, "> .\n")
    end
    !isempty(sorted) && write(io, "\n")

    # Write default graph (no GRAPH wrapper)
    if length(ds.default_graph) > 0
        write(io, "{\n")
        _trig_write_graph_body(io, ds.default_graph, ds.namespace_manager)
        write(io, "}\n")
    end

    # Write named graphs (names may be URIRefs or BNodes)
    for (name, g) in sort(collect(ds.named_graphs), by=p -> string(first(p)))
        length(g) == 0 && continue
        write(io, "\n")
        write(io, _trig_format_uri(ds.namespace_manager, name))
        write(io, " {\n")
        _trig_write_graph_body(io, g, ds.namespace_manager)
        write(io, "}\n")
    end
end

function _trig_write_graph_body(io::IO, g::RDFGraph, nsm::NamespaceManager)
    # Group by subject
    subject_props = Dict{Node, Dict{URIRef, Vector{Identifier}}}()
    for t in g
        _validate_rdf_serializable(t)
        s, p, o = t.subject, t.predicate, t.object
        props = get!(subject_props, s, Dict{URIRef, Vector{Identifier}}())
        push!(get!(props, p, Identifier[]), o)
    end

    rdf_type = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")

    urirefs = sort(filter(s -> s isa URIRef, collect(keys(subject_props))), by=s -> s.value)
    bnodes = filter(s -> s isa BNode, collect(keys(subject_props)))
    ordered = vcat(urirefs, bnodes)

    for (si, subject) in enumerate(ordered)
        si > 1 && write(io, "\n")
        write(io, "    ", _trig_format_term(nsm, subject))
        props = subject_props[subject]

        # Sort predicates, rdf:type first
        preds = sort(collect(keys(props)), by=p -> p.value)
        type_idx = findfirst(p -> p == rdf_type, preds)
        if !isnothing(type_idx) && type_idx > 1
            deleteat!(preds, type_idx)
            pushfirst!(preds, rdf_type)
        end

        for (pi, pred) in enumerate(preds)
            if pi == 1
                write(io, " ")
            else
                write(io, " ;\n        ")
            end

            # rdf:type → a
            if pred == rdf_type
                write(io, "a ")
            else
                write(io, _trig_format_term(nsm, pred), " ")
            end

            objs = props[pred]
            for (oi, obj) in enumerate(objs)
                oi > 1 && write(io, ", ")
                write(io, _trig_format_term(nsm, obj))
            end
        end
        write(io, " .\n")
    end
end

function _trig_format_uri(nsm::NamespaceManager, u::URIRef)
    try
        prefix, _, localname = compute_qname(nsm, u)
        return string(prefix, ":", localname)
    catch
        return n3(u)
    end
end

# Blank-node graph labels serialize as _:label
_trig_format_uri(nsm::NamespaceManager, b::BNode) = n3(b)

function _trig_format_term(nsm::NamespaceManager, u::URIRef)
    _trig_format_uri(nsm, u)
end

function _trig_format_term(nsm::NamespaceManager, b::BNode)
    n3(b)
end

function _trig_format_term(nsm::NamespaceManager, lit::Literal)
    xsd = "http://www.w3.org/2001/XMLSchema#"
    if !isnothing(lit.datatype) && isnothing(lit.language)
        dt = lit.datatype.value
        if dt == xsd * "integer" || dt == xsd * "decimal" || dt == xsd * "boolean"
            return lit.lexical
        elseif dt == xsd * "double"
            return n3(lit)
        end
    end
    n3(lit)
end

"""
    serialize_trig(ds::Dataset) -> String

Serialize a dataset to a TriG format string.
"""
function serialize_trig(ds::Dataset)
    buf = IOBuffer()
    serialize_trig(buf, ds)
    String(take!(buf))
end

# ─── Parsing ────────────────────────────────────────────────────────

"""
    parse_trig!(ds::Dataset, io::IO) -> Dataset

Parse TriG from an IO stream into a dataset.
"""
function parse_trig!(ds::Dataset, io::IO)
    input = read(io, String)
    parse_trig!(ds, input)
end

"""
    parse_trig!(ds::Dataset, input::AbstractString) -> Dataset

Parse TriG from a string into a dataset.
"""
function parse_trig!(ds::Dataset, input::AbstractString)
    parser = _TriGParser(ds, String(input))
    _trig_parse_document!(parser)
    ds
end

"""
    parse_trig(source) -> Dataset

Parse TriG from a string or IO stream into a new dataset.
"""
function parse_trig(source)
    ds = Dataset()
    if source isa IO || source isa IOBuffer
        parse_trig!(ds, source)
    else
        parse_trig!(ds, String(source))
    end
end

mutable struct _TriGParser
    dataset::Dataset
    input::String
    pos::Int
    prefixes::Dict{String, String}
    base::Union{String, Nothing}
    bnodecounter::Int
end

_TriGParser(ds::Dataset, input::String) = _TriGParser(ds, input, 1, Dict{String,String}(), nothing, 0)

function _trig_parse_document!(p::_TriGParser)
    _trig_skip_ws!(p)
    while p.pos <= lastindex(p.input)
        if _trig_at(p, "@prefix")
            _trig_parse_prefix!(p)
        elseif _trig_at_ci(p, "PREFIX") && !_trig_at_ci(p, "PREFIX:")
            _trig_parse_sparql_prefix!(p)
        elseif _trig_at(p, "@base")
            _trig_parse_base!(p)
        elseif _trig_at_ci(p, "BASE") && !_trig_at_ci(p, "BASE:")
            _trig_parse_sparql_base!(p)
        elseif _trig_peek(p) == '{'
            # Default graph block
            _trig_parse_graph_block!(p, nothing)
        elseif _trig_at_ci(p, "GRAPH")
            _trig_parse_named_graph!(p)
        else
            # Try as graph name followed by {
            graph_name = _trig_parse_term!(p)
            _trig_skip_ws!(p)
            if _trig_peek(p) == '{'
                _trig_parse_graph_block!(p, graph_name isa GraphName ? graph_name : nothing)
            else
                # Bare triples in default graph (no GRAPH keyword, no braces)
                _trig_parse_triples_in_graph!(p, nothing, graph_name)
            end
        end
        _trig_skip_ws!(p)
    end
end

function _trig_parse_named_graph!(p::_TriGParser)
    # Consume "GRAPH"
    for _ in 1:5; p.pos = nextind(p.input, p.pos); end
    _trig_skip_ws!(p)
    graph_name = _trig_parse_term!(p)::GraphName
    _trig_skip_ws!(p)
    _trig_parse_graph_block!(p, graph_name)
end

function _trig_parse_graph_block!(p::_TriGParser, graph_name::OptGraphName)
    _trig_consume!(p, '{')
    _trig_skip_ws!(p)

    # Create a temporary graph + turtle parser for the block content
    while _trig_peek(p) != '}'
        _trig_skip_ws!(p)
        _trig_peek(p) == '}' && break
        _trig_parse_triples_in_graph!(p, graph_name, nothing)
        _trig_skip_ws!(p)
    end
    _trig_consume!(p, '}')
end

function _trig_parse_triples_in_graph!(p::_TriGParser, graph_name::OptGraphName, first_subject)
    # Use the Turtle parser infrastructure to parse triples
    # Create a temporary graph
    temp_g = RDFGraph()
    for (prefix, uri) in p.prefixes
        bind!(temp_g, prefix, Namespace(uri))
    end

    # Extract remaining text until '.' and parse as Turtle triples
    # We need to find the subject-predicate-object-list and dot
    start_pos = p.pos

    # If we already parsed the first term, reconstruct
    prefix_decls = join(["@prefix $k: <$v> .\n" for (k, v) in p.prefixes])

    if !isnothing(first_subject)
        subj_str = n3(first_subject)
    else
        subj_str = ""
        # Read subject
        while p.pos <= lastindex(p.input)
            c = p.input[p.pos]
            c in (' ', '\t', '\n', '\r') && break
            p.pos = nextind(p.input, p.pos)
        end
        subj_str = p.input[start_pos:prevind(p.input, p.pos)]
    end

    # Read until we find a '.' that's not inside quotes or URIs
    _trig_skip_ws!(p)
    rest_start = p.pos
    in_string = false
    in_iri = false
    quote_char = nothing
    depth = 0
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if in_string
            if c == '\\' && p.pos < lastindex(p.input)
                p.pos = nextind(p.input, p.pos)  # skip escaped char
            elseif c == quote_char
                in_string = false
            end
        elseif in_iri
            if c == '>'
                in_iri = false
            end
        else
            if c == '"' || c == '\''
                in_string = true
                quote_char = c
            elseif c == '<'
                in_iri = true
            elseif c == '['
                depth += 1
            elseif c == ']'
                depth -= 1
            elseif c == '.' && depth == 0
                break
            elseif c == '}' && depth == 0
                # End of graph block without final dot
                break
            end
        end
        p.pos = nextind(p.input, p.pos)
    end

    rest_str = p.input[rest_start:prevind(p.input, p.pos)]
    if p.pos <= lastindex(p.input) && p.input[p.pos] == '.'
        p.pos = nextind(p.input, p.pos)
    end

    # Parse the complete triple statement via Turtle parser
    ttl = prefix_decls * subj_str * " " * rest_str * " .\n"
    try
        parse_turtle!(temp_g, ttl)
    catch e
        @warn "Failed to parse TriG triple block: $e"
        return
    end

    # Add parsed triples to the appropriate graph in the dataset
    for t in temp_g
        add!(p.dataset, _trig_fix_dirlang(t), graph_name)
    end
end

# SPARQL 1.2 directional literals ("x"@en--ltr) are scanned by the Turtle
# lang-tag reader as a single language tag "en--ltr". Split the base
# direction back out into the Literal `direction` field.
function _trig_fix_dirlang(t::Triple)
    o = t.object
    if o isa Literal && !isnothing(o.language)
        m = match(r"^(.+?)--(ltr|rtl)$", o.language)
        if !isnothing(m)
            return Triple(t.subject, t.predicate,
                          Literal(o.lexical, lang=m.captures[1], direction=m.captures[2]))
        end
    end
    t
end

# ─── TriG parser helpers ───────────────────────────────────────────

function _trig_skip_ws!(p::_TriGParser)
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

function _trig_peek(p::_TriGParser)
    p.pos > lastindex(p.input) ? nothing : p.input[p.pos]
end

function _trig_consume!(p::_TriGParser, expected::Char)
    c = _trig_peek(p)
    c != expected && throw(ArgumentError("TriG: expected '$expected', got '$c' at pos $(p.pos)"))
    p.pos = nextind(p.input, p.pos)
end

function _trig_at(p::_TriGParser, s::AbstractString)
    endpos = p.pos
    for c in s
        endpos > lastindex(p.input) && return false
        p.input[endpos] != c && return false
        endpos = nextind(p.input, endpos)
    end
    true
end

function _trig_at_ci(p::_TriGParser, s::AbstractString)
    endpos = p.pos
    for c in s
        endpos > lastindex(p.input) && return false
        lowercase(p.input[endpos]) != lowercase(c) && return false
        endpos = nextind(p.input, endpos)
    end
    true
end

function _trig_parse_prefix!(p::_TriGParser)
    for _ in 1:7; p.pos = nextind(p.input, p.pos); end  # @prefix
    _trig_skip_ws!(p)
    prefix = _trig_read_prefix_name!(p)
    _trig_skip_ws!(p)
    uri = _trig_read_iriref!(p)
    _trig_skip_ws!(p)
    _trig_consume!(p, '.')
    p.prefixes[prefix] = uri
    bind!(p.dataset, prefix, Namespace(uri))
end

function _trig_parse_sparql_prefix!(p::_TriGParser)
    for _ in 1:6; p.pos = nextind(p.input, p.pos); end
    _trig_skip_ws!(p)
    prefix = _trig_read_prefix_name!(p)
    _trig_skip_ws!(p)
    uri = _trig_read_iriref!(p)
    p.prefixes[prefix] = uri
    bind!(p.dataset, prefix, Namespace(uri))
end

function _trig_parse_base!(p::_TriGParser)
    for _ in 1:5; p.pos = nextind(p.input, p.pos); end
    _trig_skip_ws!(p)
    p.base = _trig_read_iriref!(p)
    _trig_skip_ws!(p)
    _trig_consume!(p, '.')
end

function _trig_parse_sparql_base!(p::_TriGParser)
    for _ in 1:4; p.pos = nextind(p.input, p.pos); end
    _trig_skip_ws!(p)
    p.base = _trig_read_iriref!(p)
end

function _trig_read_prefix_name!(p::_TriGParser)
    buf = IOBuffer()
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if c == ':'
            p.pos = nextind(p.input, p.pos)
            return String(take!(buf))
        else
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        end
    end
    throw(ArgumentError("Unterminated prefix name"))
end

function _trig_read_iriref!(p::_TriGParser)
    _trig_consume!(p, '<')
    buf = IOBuffer()
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if c == '>'
            p.pos = nextind(p.input, p.pos)
            return String(take!(buf))
        else
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        end
    end
    throw(ArgumentError("Unterminated IRI"))
end

function _trig_parse_term!(p::_TriGParser)
    c = _trig_peek(p)
    if c == '<'
        return URIRef(_trig_read_iriref!(p))
    elseif c == '_' && _trig_at(p, "_:")
        # Blank node label (e.g. a blank-node-named graph)
        p.pos = nextind(p.input, p.pos)  # '_'
        p.pos = nextind(p.input, p.pos)  # ':'
        start = p.pos
        while p.pos <= lastindex(p.input)
            ch = p.input[p.pos]
            (_nt_is_pn_chars(ch) || ch == '.') || break
            p.pos = nextind(p.input, p.pos)
        end
        # A label cannot end with '.'
        while p.pos > start && p.input[prevind(p.input, p.pos)] == '.'
            p.pos = prevind(p.input, p.pos)
        end
        p.pos == start && throw(ArgumentError("TriG: empty blank node label at pos $(p.pos)"))
        return BNode(p.input[start:prevind(p.input, p.pos)])
    else
        # Prefixed name
        buf = IOBuffer()
        while p.pos <= lastindex(p.input)
            c = p.input[p.pos]
            c in (' ', '\t', '\n', '\r', '{', '}') && break
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        end
        pname = String(take!(buf))
        idx = findfirst(':', pname)
        if !isnothing(idx)
            prefix = pname[1:idx-1]
            localname = pname[idx+1:end]
            ns = get(p.prefixes, prefix, nothing)
            !isnothing(ns) && return URIRef(ns * localname)
        end
        throw(ArgumentError("Cannot resolve TriG term: $pname"))
    end
end

# ─── Register with high-level API ──────────────────────────────────

serialize(io::IO, ds::Dataset, ::TriGFormat) = serialize_trig(io, ds)

function serialize(ds::Dataset, fmt::TriGFormat)
    buf = IOBuffer()
    serialize(buf, ds, fmt)
    String(take!(buf))
end
