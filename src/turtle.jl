# ─── Turtle Format ──────────────────────────────────────────────────
# Human-readable RDF serialization with prefix declarations,
# subject clustering, and compact blank node syntax.

# ─── Serialization ──────────────────────────────────────────────────

"""
    serialize_turtle(io::IO, g::RDFGraph)

Serialize a graph in Turtle format.
"""
function serialize_turtle(io::IO, g::RDFGraph)
    ctx = _TurtleSerContext(g)
    _turtle_preprocess!(ctx)
    _turtle_write_prefixes(io, ctx)
    _turtle_write_triples(io, ctx)
end

"""
    serialize_turtle(g::RDFGraph) -> String

Serialize a graph to a Turtle format string.
"""
function serialize_turtle(g::RDFGraph)
    buf = IOBuffer()
    serialize_turtle(buf, g)
    String(take!(buf))
end

# Serialization context holding computed state
mutable struct _TurtleSerContext
    graph::RDFGraph
    # subject → Dict(predicate → [objects])
    subject_props::Dict{Node, Dict{URIRef, Vector{Identifier}}}
    # How many times each node is referenced as an object
    references::Dict{Identifier, Int}
    # Track which subjects have been serialized (for inline blank nodes)
    serialized::Set{Node}
    # Collected namespace prefixes to emit
    prefixes::Dict{String, String}
    # Cache for qname lookups: URI string → "prefix:local" or nothing
    qname_cache::Dict{String, Union{String, Nothing}}

    function _TurtleSerContext(g::RDFGraph)
        new(g,
            Dict{Node, Dict{URIRef, Vector{Identifier}}}(),
            Dict{Identifier, Int}(),
            Set{Node}(),
            Dict{String, String}(),
            Dict{String, Union{String, Nothing}}())
    end
end

function _turtle_preprocess!(ctx::_TurtleSerContext)
    g = ctx.graph

    # Group triples by subject → predicate → [objects]
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

        # Count references for blank node inlining
        ctx.references[o] = get(ctx.references, o, 0) + 1
    end

    # Collect prefixes from the graph's namespace manager
    for (prefix, ns_uri) in namespaces(g)
        ctx.prefixes[prefix] = ns_uri
    end

    # Also try to compute qnames for all URIs to discover needed prefixes
    for t in g
        _turtle_try_qname!(ctx, t.subject)
        _turtle_try_qname!(ctx, t.predicate)
        _turtle_try_qname!(ctx, t.object)
    end
end

function _turtle_try_qname!(ctx::_TurtleSerContext, term::URIRef)
    try
        prefix, ns_uri, _ = compute_qname(ctx.graph.namespace_manager, term)
        ctx.prefixes[prefix] = ns_uri
    catch
        # Not all URIs can be split into prefix + localname
    end
end

_turtle_try_qname!(::_TurtleSerContext, ::Identifier) = nothing

function _turtle_write_prefixes(io::IO, ctx::_TurtleSerContext)
    sorted = sort(collect(ctx.prefixes), by=first)
    for (prefix, uri) in sorted
        write(io, "@prefix ", prefix, ": <", uri, "> .\n")
    end
    if !isempty(sorted)
        write(io, "\n")
    end
end

function _turtle_write_triples(io::IO, ctx::_TurtleSerContext)
    # Order subjects: URIRefs sorted, then BNodes
    subjects = collect(keys(ctx.subject_props))
    urirefs = sort(filter(s -> s isa URIRef, subjects), by=s -> s.value)
    bnodes = filter(s -> s isa BNode, subjects)
    ordered = vcat(urirefs, bnodes)

    first_subject = true
    for subject in ordered
        subject in ctx.serialized && continue
        if !first_subject
            write(io, "\n")
        end
        first_subject = false
        _turtle_write_subject(io, ctx, subject)
    end
end

function _turtle_write_subject(io::IO, ctx::_TurtleSerContext, subject::Node)
    push!(ctx.serialized, subject)
    props = ctx.subject_props[subject]

    # Check if blank node can use [] syntax (referenced 0 times as object)
    if subject isa BNode && get(ctx.references, subject, 0) == 0
        write(io, "[]")
    else
        write(io, _turtle_format_node(ctx, subject))
    end

    _turtle_write_predicate_list(io, ctx, props, 1)
    write(io, " .\n")
end

function _turtle_write_predicate_list(io::IO, ctx::_TurtleSerContext,
                                       props::Dict{URIRef, Vector{Identifier}},
                                       indent_level::Int)
    indent = "    " ^ indent_level

    # Sort predicates: rdf:type first, then alphabetical
    rdf_type = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    preds = sort(collect(keys(props)), by=p -> p.value)
    # Move rdf:type to front
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
        _turtle_write_verb(io, ctx, pred)
        write(io, " ")
        _turtle_write_object_list(io, ctx, props[pred], indent_level)
    end
end

function _turtle_write_verb(io::IO, ctx::_TurtleSerContext, pred::URIRef)
    rdf_type = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    if pred == rdf_type
        write(io, "a")
    else
        write(io, _turtle_format_node(ctx, pred))
    end
end

function _turtle_write_object_list(io::IO, ctx::_TurtleSerContext,
                                    objects::Vector{Identifier},
                                    indent_level::Int)
    indent = "    " ^ indent_level
    for (i, obj) in enumerate(objects)
        if i > 1
            write(io, ",\n", indent, "    ")
        end
        # Try inline blank node
        if obj isa BNode && _can_inline_bnode(ctx, obj)
            _turtle_write_inline_bnode(io, ctx, obj)
        else
            write(io, _turtle_format_node(ctx, obj))
        end
    end
end

function _can_inline_bnode(ctx::_TurtleSerContext, node::BNode)
    get(ctx.references, node, 0) <= 1 &&
    haskey(ctx.subject_props, node) &&
    !(node in ctx.serialized)
end

function _turtle_write_inline_bnode(io::IO, ctx::_TurtleSerContext, node::BNode)
    push!(ctx.serialized, node)
    props = ctx.subject_props[node]
    write(io, "[")
    _turtle_write_predicate_list(io, ctx, props, 2)
    write(io, " ]")
end

# ─── Term formatting ────────────────────────────────────────────────

function _turtle_format_node(ctx::_TurtleSerContext, u::URIRef)
    # Use cached qname if available
    cached = get(ctx.qname_cache, u.value, missing)
    if cached !== missing
        return cached !== nothing ? cached : n3(u)
    end
    # Try prefixed name
    try
        prefix, _, localname = compute_qname(ctx.graph.namespace_manager, u)
        result = string(prefix, ":", localname)
        ctx.qname_cache[u.value] = result
        return result
    catch
        ctx.qname_cache[u.value] = nothing
        return n3(u)
    end
end

function _turtle_format_node(ctx::_TurtleSerContext, b::BNode)
    n3(b)
end

function _turtle_format_node(ctx::_TurtleSerContext, lit::Literal)
    # For typed literals, try to use prefixed datatype
    if !isnothing(lit.datatype) && isnothing(lit.language)
        dt = lit.datatype
        xsd_uri = "http://www.w3.org/2001/XMLSchema#"
        # Numeric/boolean shorthand
        if dt.value == xsd_uri * "integer"
            return lit.lexical
        elseif dt.value == xsd_uri * "decimal"
            return lit.lexical
        elseif dt.value == xsd_uri * "double"
            # Ensure scientific notation or has decimal point
            s = lit.lexical
            if 'e' in s || 'E' in s
                return s
            else
                return s * "e0"  # Force double notation
            end
        elseif dt.value == xsd_uri * "boolean"
            return lit.lexical
        else
            # Use prefixed datatype if possible
            try
                prefix, _, localname = compute_qname(ctx.graph.namespace_manager, dt)
                escaped = _escape_literal(lit.lexical)
                return string("\"", escaped, "\"^^", prefix, ":", localname)
            catch
                return n3(lit)
            end
        end
    end
    n3(lit)
end

# ─── Parsing ────────────────────────────────────────────────────────

"""
    parse_turtle!(g::RDFGraph, io::IO) -> RDFGraph

Parse Turtle format from an IO stream and add triples to the graph.
"""
function parse_turtle!(g::RDFGraph, io::IO)
    input = read(io, String)
    parse_turtle!(g, input)
end

"""
Specialised fast path for `DuckDBStore`: parse via a temporary
in-memory graph then bulk-load into DuckDB via the Appender.
"""
function parse_turtle!(g::RDFGraph{DuckDBStore}, input::AbstractString)
    tmp = RDFGraph()  # MemoryStore
    parser = _TurtleParser(tmp, String(input))
    _turtle_parse_document!(parser)
    bulk_add!(g.store, (t for t in triples(tmp)))
    # Carry over namespace bindings discovered during parsing.
    for (prefix, ns) in tmp.namespace_manager.namespaces
        bind!(g.namespace_manager, prefix, ns)
    end
    g
end

"""
    parse_turtle!(g::RDFGraph, input::AbstractString) -> RDFGraph

Parse Turtle format from a string and add triples to the graph.
"""
function parse_turtle!(g::RDFGraph, input::AbstractString)
    parser = _TurtleParser(g, String(input))
    _turtle_parse_document!(parser)
    g
end

"""
    parse_turtle(source) -> RDFGraph

Parse Turtle format from a string or IO stream into a new graph.
"""
function parse_turtle(source)
    g = RDFGraph()
    if source isa IO || source isa IOBuffer
        parse_turtle!(g, source)
    else
        parse_turtle!(g, String(source))
    end
end

# ─── Turtle Parser (Recursive Descent) ─────────────────────────────

mutable struct _TurtleParser
    graph::RDFGraph
    input::String
    pos::Int
    prefixes::Dict{String, String}
    base::Union{String, Nothing}
    bnodecounter::Int
end

function _TurtleParser(g::RDFGraph, input::String)
    _TurtleParser(g, input, 1, Dict{String,String}(), nothing, 0)
end

function _turtle_parse_document!(p::_TurtleParser)
    _skip_ws_and_comments!(p)
    while p.pos <= lastindex(p.input)
        if _at_prefix_directive(p)
            _parse_prefix_directive!(p)
        elseif _at_base_directive(p)
            _parse_base_directive!(p)
        elseif _at_sparql_prefix(p)
            _parse_sparql_prefix!(p)
        elseif _at_sparql_base(p)
            _parse_sparql_base!(p)
        else
            _parse_triples!(p)
        end
        _skip_ws_and_comments!(p)
    end
end

# ─── Whitespace / comment handling ──────────────────────────────────

function _skip_ws_and_comments!(p::_TurtleParser)
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if c in (' ', '\t', '\n', '\r')
            p.pos = nextind(p.input, p.pos)
        elseif c == '#'
            # Skip to end of line
            while p.pos <= lastindex(p.input) && p.input[p.pos] != '\n'
                p.pos = nextind(p.input, p.pos)
            end
        else
            break
        end
    end
end

function _peek(p::_TurtleParser)
    p.pos > lastindex(p.input) && return nothing
    p.input[p.pos]
end

function _peek_str(p::_TurtleParser, n::Int)
    endpos = p.pos
    for _ in 1:n-1
        endpos > lastindex(p.input) && return SubString(p.input, p.pos, lastindex(p.input))
        endpos = nextind(p.input, endpos)
    end
    endpos > lastindex(p.input) && return SubString(p.input, p.pos, lastindex(p.input))
    SubString(p.input, p.pos, endpos)
end

function _consume!(p::_TurtleParser, expected::Char)
    c = _peek(p)
    c === nothing && throw(ArgumentError("Unexpected end of input, expected '$expected'"))
    c != expected && throw(ArgumentError("Expected '$expected', got '$c' at position $(p.pos)"))
    p.pos = nextind(p.input, p.pos)
    c
end

function _consume_str!(p::_TurtleParser, expected::AbstractString)
    for c in expected
        _consume!(p, c)
    end
end

function _at_string(p::_TurtleParser, s::AbstractString)
    endpos = p.pos
    for c in s
        endpos > lastindex(p.input) && return false
        p.input[endpos] != c && return false
        endpos = nextind(p.input, endpos)
    end
    true
end

function _at_string_ci(p::_TurtleParser, s::AbstractString)
    endpos = p.pos
    for c in s
        endpos > lastindex(p.input) && return false
        lowercase(p.input[endpos]) != lowercase(c) && return false
        endpos = nextind(p.input, endpos)
    end
    true
end

# ─── Directive parsing ──────────────────────────────────────────────

_at_prefix_directive(p::_TurtleParser) = _at_string(p, "@prefix")
_at_base_directive(p::_TurtleParser) = _at_string(p, "@base")

function _at_sparql_prefix(p::_TurtleParser)
    _at_string_ci(p, "PREFIX") && !_at_string_ci(p, "PREFIX:")
end
function _at_sparql_base(p::_TurtleParser)
    _at_string_ci(p, "BASE") && !_at_string_ci(p, "BASE:")
end

function _parse_prefix_directive!(p::_TurtleParser)
    _consume_str!(p, "@prefix")
    _skip_ws_and_comments!(p)
    prefix = _parse_prefix_name!(p)
    _skip_ws_and_comments!(p)
    uri = _parse_iriref!(p)
    _skip_ws_and_comments!(p)
    _consume!(p, '.')
    p.prefixes[prefix] = uri
    bind!(p.graph, prefix, Namespace(uri))
end

function _parse_sparql_prefix!(p::_TurtleParser)
    # Consume "PREFIX" case-insensitively
    for _ in 1:6; p.pos = nextind(p.input, p.pos); end
    _skip_ws_and_comments!(p)
    prefix = _parse_prefix_name!(p)
    _skip_ws_and_comments!(p)
    uri = _parse_iriref!(p)
    p.prefixes[prefix] = uri
    bind!(p.graph, prefix, Namespace(uri))
end

function _parse_base_directive!(p::_TurtleParser)
    _consume_str!(p, "@base")
    _skip_ws_and_comments!(p)
    uri = _parse_iriref!(p)
    _skip_ws_and_comments!(p)
    _consume!(p, '.')
    p.base = uri
end

function _parse_sparql_base!(p::_TurtleParser)
    for _ in 1:4; p.pos = nextind(p.input, p.pos); end
    _skip_ws_and_comments!(p)
    uri = _parse_iriref!(p)
    p.base = uri
end

function _parse_prefix_name!(p::_TurtleParser)
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

function _parse_iriref!(p::_TurtleParser)
    _consume!(p, '<')
    buf = IOBuffer()
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if c == '>'
            p.pos = nextind(p.input, p.pos)
            uri = String(take!(buf))
            # Resolve against base if relative
            if !isnothing(p.base) && !_is_absolute_uri(uri)
                return _resolve_uri(p.base, uri)
            end
            return uri
        elseif c == '\\'
            p.pos = nextind(p.input, p.pos)
            write(buf, _parse_escape_char!(p))
        else
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        end
    end
    throw(ArgumentError("Unterminated IRI reference"))
end

_is_absolute_uri(uri::AbstractString) = occursin("://", uri) || startswith(uri, "urn:")

function _resolve_uri(base::AbstractString, relative::AbstractString)
    isempty(relative) && return base
    startswith(relative, '#') && return string(base, relative)
    # Simple resolution: replace everything after last /
    idx = findlast('/', base)
    isnothing(idx) ? relative : string(base[1:idx], relative)
end

# ─── Triple parsing ─────────────────────────────────────────────────

function _parse_triples!(p::_TurtleParser)
    _skip_ws_and_comments!(p)
    c = _peek(p)
    c === nothing && return

    # Parse subject
    subject = _parse_subject!(p)
    _skip_ws_and_comments!(p)

    # Parse predicate-object list
    _parse_predicate_object_list!(p, subject)

    _skip_ws_and_comments!(p)
    _consume!(p, '.')
end

function _parse_subject!(p::_TurtleParser)
    c = _peek(p)
    if c == '<'
        return URIRef(_parse_iriref!(p))
    elseif c == '_'
        return _parse_blank_node_label!(p)
    elseif c == '['
        return _parse_blank_node_property_list!(p)
    elseif c == '('
        return _parse_collection!(p)
    else
        return _parse_prefixed_name!(p)
    end
end

function _parse_predicate_object_list!(p::_TurtleParser, subject::Node)
    while true
        _skip_ws_and_comments!(p)
        c = _peek(p)
        (c === nothing || c == '.' || c == ']' || c == ')') && break

        predicate = _parse_verb!(p)
        _skip_ws_and_comments!(p)
        _parse_object_list!(p, subject, predicate)

        _skip_ws_and_comments!(p)
        c = _peek(p)
        if c == ';'
            p.pos = nextind(p.input, p.pos)
            _skip_ws_and_comments!(p)
            # Check for trailing semicolon before . or ]
            c2 = _peek(p)
            (c2 === nothing || c2 == '.' || c2 == ']') && break
        else
            break
        end
    end
end

function _parse_verb!(p::_TurtleParser)
    c = _peek(p)
    if c == 'a'
        # Check if it's the 'a' keyword (not start of a prefixed name)
        next_pos = nextind(p.input, p.pos)
        if next_pos > lastindex(p.input) || p.input[next_pos] in (' ', '\t', '\n', '\r')
            p.pos = next_pos
            return URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
        end
    end
    _parse_node!(p)::URIRef
end

function _parse_object_list!(p::_TurtleParser, subject::Node, predicate::URIRef)
    while true
        _skip_ws_and_comments!(p)
        object = _parse_object!(p)
        add!(p.graph, Triple(subject, predicate, object))

        _skip_ws_and_comments!(p)
        c = _peek(p)
        if c == ','
            p.pos = nextind(p.input, p.pos)
        else
            break
        end
    end
end

function _parse_object!(p::_TurtleParser)
    _parse_node!(p)
end

# ─── Node parsing ───────────────────────────────────────────────────

function _parse_node!(p::_TurtleParser)::Identifier
    c = _peek(p)
    c === nothing && throw(ArgumentError("Unexpected end of input"))

    if c == '<'
        return URIRef(_parse_iriref!(p))
    elseif c == '_'
        return _parse_blank_node_label!(p)
    elseif c == '['
        return _parse_blank_node_property_list!(p)
    elseif c == '('
        return _parse_collection!(p)
    elseif c == '"' || c == '\''
        return _parse_literal!(p)
    elseif c == '+' || c == '-' || isdigit(c)
        return _parse_numeric_literal!(p)
    elseif _at_string(p, "true")
        _consume_str!(p, "true")
        return Literal(true)
    elseif _at_string(p, "false")
        _consume_str!(p, "false")
        return Literal(false)
    else
        return _parse_prefixed_name!(p)
    end
end

# ─── Blank node parsing ────────────────────────────────────────────

function _parse_blank_node_label!(p::_TurtleParser)
    _consume!(p, '_')
    _consume!(p, ':')
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
    # Remove trailing dots (not allowed at end of blank node label)
    label = rstrip(label, '.')
    BNode(label)
end

function _parse_blank_node_property_list!(p::_TurtleParser)
    _consume!(p, '[')
    _skip_ws_and_comments!(p)
    bnode = _new_bnode!(p)

    c = _peek(p)
    if c != ']'
        _parse_predicate_object_list!(p, bnode)
    end

    _skip_ws_and_comments!(p)
    _consume!(p, ']')
    bnode
end

function _new_bnode!(p::_TurtleParser)
    p.bnodecounter += 1
    BNode("b$(p.bnodecounter)")
end

# ─── Collection parsing (RDF lists) ────────────────────────────────

function _parse_collection!(p::_TurtleParser)
    _consume!(p, '(')
    _skip_ws_and_comments!(p)

    rdf_first = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
    rdf_rest = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
    rdf_nil = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")

    c = _peek(p)
    if c == ')'
        p.pos = nextind(p.input, p.pos)
        return rdf_nil
    end

    head = _new_bnode!(p)
    current = head

    while true
        _skip_ws_and_comments!(p)
        c = _peek(p)
        c == ')' && break

        item = _parse_node!(p)
        add!(p.graph, Triple(current, rdf_first, item))

        _skip_ws_and_comments!(p)
        c = _peek(p)
        if c == ')'
            add!(p.graph, Triple(current, rdf_rest, rdf_nil))
        else
            next_node = _new_bnode!(p)
            add!(p.graph, Triple(current, rdf_rest, next_node))
            current = next_node
        end
    end

    _consume!(p, ')')
    head
end

# ─── Prefixed name parsing ─────────────────────────────────────────

function _parse_prefixed_name!(p::_TurtleParser)
    buf = IOBuffer()
    # Read prefix part (before :)
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

    # Read local part (after :)
    local_buf = IOBuffer()
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if c in (' ', '\t', '\n', '\r', '.', ';', ',', ')', ']', '}', '#')
            break
        elseif c == '\\'
            p.pos = nextind(p.input, p.pos)
            write(local_buf, _parse_pname_escape!(p))
        else
            write(local_buf, c)
            p.pos = nextind(p.input, p.pos)
        end
    end
    localname = String(take!(local_buf))

    # Resolve prefix
    ns_uri = get(p.prefixes, prefix, nothing)
    if isnothing(ns_uri)
        throw(ArgumentError("Unknown prefix: '$prefix' at position $(p.pos)"))
    end
    URIRef(ns_uri * localname)
end

function _parse_pname_escape!(p::_TurtleParser)
    c = p.input[p.pos]
    p.pos = nextind(p.input, p.pos)
    c  # In Turtle, PN_LOCAL_ESC just passes through the escaped char
end

# ─── Literal parsing ───────────────────────────────────────────────

function _parse_literal!(p::_TurtleParser)
    # Check for long string (""" or ''')
    s2 = _peek_str(p, 3)
    if s2 == "\"\"\"" || s2 == "'''"
        lexical = _parse_long_string!(p)
    else
        lexical = _parse_short_string!(p)
    end

    # Check for language tag or datatype
    c = _peek(p)
    if c == '@'
        p.pos = nextind(p.input, p.pos)
        lang_tag = _parse_lang_tag!(p)
        return Literal(lexical, lang=lang_tag)
    elseif c == '^'
        _consume_str!(p, "^^")
        dt = _parse_node!(p)
        return Literal(lexical, datatype=dt::URIRef)
    else
        return Literal(lexical)
    end
end

function _parse_short_string!(p::_TurtleParser)
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
            write(buf, _parse_escape_char!(p))
        elseif c == '\n' || c == '\r'
            throw(ArgumentError("Newline in short string at position $(p.pos)"))
        else
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        end
    end
    throw(ArgumentError("Unterminated string literal"))
end

function _parse_long_string!(p::_TurtleParser)
    quote_char = p.input[p.pos]
    _consume_str!(p, string(quote_char, quote_char, quote_char))
    buf = IOBuffer()
    end_pattern = string(quote_char, quote_char, quote_char)
    while p.pos <= lastindex(p.input)
        if _at_string(p, end_pattern)
            _consume_str!(p, end_pattern)
            return String(take!(buf))
        end
        c = p.input[p.pos]
        if c == '\\'
            p.pos = nextind(p.input, p.pos)
            write(buf, _parse_escape_char!(p))
        else
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        end
    end
    throw(ArgumentError("Unterminated long string literal"))
end

function _parse_escape_char!(p::_TurtleParser)
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

function _parse_lang_tag!(p::_TurtleParser)
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

# ─── Numeric literal parsing ───────────────────────────────────────

function _parse_numeric_literal!(p::_TurtleParser)
    buf = IOBuffer()
    has_dot = false
    has_exp = false

    # Optional sign
    c = _peek(p)
    if c == '+' || c == '-'
        write(buf, c)
        p.pos = nextind(p.input, p.pos)
    end

    # Integer part
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if isdigit(c)
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        elseif c == '.' && !has_dot && !has_exp
            # Check it's not a statement terminator
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
            # Optional sign after exponent
            c2 = _peek(p)
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

serialize(io::IO, g::RDFGraph, ::TurtleFormat) = serialize_turtle(io, g)
parse_rdf!(g::RDFGraph, source, ::TurtleFormat) = parse_turtle!(g, source)
