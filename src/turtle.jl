# ─── Turtle Format ──────────────────────────────────────────────────
# Human-readable RDF serialization with prefix declarations,
# subject clustering, and compact blank node syntax.

# RDF 1.2 reification predicate.
const _RDF_REIFIES = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#reifies")

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
        _validate_rdf_serializable(t)
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

function _turtle_try_qname!(ctx::_TurtleSerContext, term::TripleTerm)
    _turtle_try_qname!(ctx, term.subject)
    _turtle_try_qname!(ctx, term.predicate)
    _turtle_try_qname!(ctx, term.object)
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
    others = filter(s -> !(s isa URIRef || s isa BNode), subjects)  # e.g. TripleTerm
    ordered = vcat(urirefs, bnodes, others)

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

# ─── PN character classes (Turtle/N3 grammar, shared with n3.jl) ────

function _is_pn_chars_base(c::Char)
    ('A' <= c <= 'Z') || ('a' <= c <= 'z') ||
    ('À' <= c <= 'Ö') || ('Ø' <= c <= 'ö') ||
    ('ø' <= c <= '˿') || ('Ͱ' <= c <= 'ͽ') ||
    ('Ϳ' <= c <= '῿') || ('‌' <= c <= '‍') ||
    ('⁰' <= c <= '↏') || ('Ⰰ' <= c <= '⿯') ||
    ('、' <= c <= '퟿') || ('豈' <= c <= '﷏') ||
    ('ﷰ' <= c <= '�') || ('\U00010000' <= c <= '\U000EFFFF')
end

_is_pn_chars_u(c::Char) = c == '_' || _is_pn_chars_base(c)

function _is_pn_chars(c::Char)
    _is_pn_chars_u(c) || c == '-' || ('0' <= c <= '9') || c == '·' ||
    ('̀' <= c <= 'ͯ') || ('‿' <= c <= '⁀')
end

_is_hex_digit(c::Char) = ('0' <= c <= '9') || ('A' <= c <= 'F') || ('a' <= c <= 'f')

# Characters that may appear escaped (\\,) inside a PN_LOCAL (PN_LOCAL_ESC)
const _PN_LOCAL_ESC_CHARS = Set{Char}("_~.-!\$&'()*+,;=/?#@%")

"""
    _escape_pn_local(localname) -> Union{String, Nothing}

Escape a qname local part so it is a valid Turtle PN_LOCAL token
(applying PN_LOCAL_ESC backslash escapes where needed). Returns `nothing`
if the local name cannot be represented as a PN_LOCAL at all, in which
case the serializer must fall back to the full `<IRI>` form.
"""
function _escape_pn_local(localname::AbstractString)
    isempty(localname) && return ""  # "prefix:" (PNAME_NS) is valid Turtle
    buf = IOBuffer()
    lastidx = lastindex(localname)
    i = firstindex(localname)
    is_first = true
    while i <= lastidx
        c = localname[i]
        nxt = nextind(localname, i)
        is_last = nxt > lastidx
        if c == '%'
            # A valid %HH sequence is kept verbatim (PERCENT); a bare '%' is escaped
            if nxt <= lastidx
                h2 = nextind(localname, nxt)
                if h2 <= lastidx && _is_hex_digit(localname[nxt]) && _is_hex_digit(localname[h2])
                    write(buf, '%')
                    is_first = false
                    i = nxt
                    continue
                end
            end
            write(buf, "\\%")
        elseif c == ':'
            write(buf, c)
        elseif c == '.'
            # Dots are legal mid-name but not first or last
            if is_first || is_last
                write(buf, "\\.")
            else
                write(buf, c)
            end
        elseif _is_pn_chars(c)
            if is_first && !(_is_pn_chars_u(c) || isdigit(c))
                # '-', U+00B7, combining marks cannot start a PN_LOCAL
                if c == '-'
                    write(buf, "\\-")
                else
                    return nothing  # not escapable in first position
                end
            else
                write(buf, c)
            end
        elseif c in _PN_LOCAL_ESC_CHARS
            write(buf, '\\', c)
        else
            return nothing  # character cannot appear in a PN_LOCAL
        end
        is_first = false
        i = nxt
    end
    String(take!(buf))
end

# ─── Term formatting ────────────────────────────────────────────────

# Full `<IRI>` form, escaping characters the IRIREF grammar forbids
# (controls, space, `<>"{}|^\``, backslash) as \uXXXX so the output re-parses.
_turtle_iri(u::URIRef) = string("<", _nt_escape_iri(u.value), ">")

function _turtle_format_node(ctx::_TurtleSerContext, u::URIRef)
    # Use cached qname if available
    cached = get(ctx.qname_cache, u.value, missing)
    if cached !== missing
        return cached !== nothing ? cached : _turtle_iri(u)
    end
    # Try prefixed name
    try
        prefix, _, localname = compute_qname(ctx.graph.namespace_manager, u)
        escaped = _escape_pn_local(localname)
        if escaped === nothing
            ctx.qname_cache[u.value] = nothing
            return _turtle_iri(u)
        end
        result = string(prefix, ":", escaped)
        ctx.qname_cache[u.value] = result
        return result
    catch
        ctx.qname_cache[u.value] = nothing
        return _turtle_iri(u)
    end
end

function _turtle_format_node(ctx::_TurtleSerContext, tt::TripleTerm)
    string("<<( ", _turtle_format_node(ctx, tt.subject), " ",
           _turtle_format_node(ctx, tt.predicate), " ",
           _turtle_format_node(ctx, tt.object), " )>>")
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
            # Preserve the exact lexical form by using explicit typed-literal syntax.
        elseif dt.value == xsd_uri * "boolean"
            return lit.lexical
        else
            # Use prefixed datatype if possible
            try
                prefix, _, localname = compute_qname(ctx.graph.namespace_manager, dt)
                local_esc = _escape_pn_local(localname)
                local_esc === nothing && return n3(lit)
                escaped = _escape_literal(lit.lexical)
                return string("\"", escaped, "\"^^", prefix, ":", local_esc)
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
function parse_turtle!(g::RDFGraph, io::IO; base::Union{String,Nothing}=nothing)
    input = read(io, String)
    parse_turtle!(g, input; base=base)
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
function parse_turtle!(g::RDFGraph, input::AbstractString; base::Union{String,Nothing}=nothing)
    parser = _TurtleParser(g, String(input))
    parser.base = base
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
    doc_bnode_labels::Set{String}  # labels appearing as _:label in the document
end

# Collect a superset of the blank node labels used in the document. Every
# PN_CHARS character is either ASCII alphanumeric, '_', '-', or >= U+0080;
# '.' is allowed mid-label. Over-matching (e.g. inside string literals) is
# harmless — the set is only used to keep generated anonymous blank node IDs
# from colliding with document labels.
function _scan_doc_bnode_labels(input::String)
    labels = Set{String}()
    i = firstindex(input)
    lastidx = lastindex(input)
    while true
        r = findnext("_:", input, i)
        r === nothing && break
        k = nextind(input, last(r))
        buf = IOBuffer()
        while k <= lastidx
            c = input[k]
            if c == '_' || c == '-' || c == '.' || isdigit(c) ||
               ('A' <= c <= 'Z') || ('a' <= c <= 'z') || c >= '\x80'
                write(buf, c)
                k = nextind(input, k)
            else
                break
            end
        end
        label = rstrip(String(take!(buf)), '.')
        isempty(label) || push!(labels, label)
        i = max(k, nextind(input, last(r)))
    end
    labels
end

function _TurtleParser(g::RDFGraph, input::String)
    _TurtleParser(g, input, 1, Dict{String,String}(), nothing, 0,
                  _scan_doc_bnode_labels(input))
end

function _turtle_parse_document!(p::_TurtleParser)
    _skip_ws_and_comments!(p)
    while p.pos <= lastindex(p.input)
        if _at_prefix_directive(p)
            _parse_prefix_directive!(p)
        elseif _at_base_directive(p)
            _parse_base_directive!(p)
        elseif _at_version_directive(p)
            _parse_version_directive!(p)
        elseif _at_sparql_prefix(p)
            _parse_sparql_prefix!(p)
        elseif _at_sparql_base(p)
            _parse_sparql_base!(p)
        elseif _at_sparql_version(p)
            _parse_sparql_version!(p)
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

# `@version "…" .`  (Turtle-style version directive)
_at_version_directive(p::_TurtleParser) = _at_string(p, "@version")

# `VERSION "…"` / `version "…"`  (SPARQL-style keyword, case-insensitive,
# no leading '@', no trailing '.'). Must be at a token boundary so that a
# prefixed name like `version:x` is not mistaken for the keyword.
function _at_sparql_version(p::_TurtleParser)
    _at_string_ci(p, "VERSION") || return false
    endpos = p.pos
    for _ in 1:7
        endpos = nextind(p.input, endpos)
    end
    endpos > lastindex(p.input) && return true
    c = p.input[endpos]
    !(_is_pn_chars(c) || c == ':')
end

# Read a single-line quoted version string ('"…"' or '\'…\''). Long
# (triple-quoted) strings and unquoted tokens are rejected.
function _parse_version_string!(p::_TurtleParser)
    c = _peek(p)
    (c == '"' || c == '\'') ||
        throw(ArgumentError("VERSION directive requires a quoted string at position $(p.pos)"))
    # Reject triple-quoted (long) strings.
    if _at_string(p, string(c, c, c))
        throw(ArgumentError("VERSION directive does not accept a long (triple-quoted) string at position $(p.pos)"))
    end
    lit = _parse_literal!(p)
    (lit isa Literal && lit.datatype === nothing && lit.language === nothing) ||
        throw(ArgumentError("invalid VERSION string at position $(p.pos)"))
    lit.lexical
end

function _parse_version_directive!(p::_TurtleParser)
    _consume_str!(p, "@version")
    _skip_ws_and_comments!(p)
    _parse_version_string!(p)
    _skip_ws_and_comments!(p)
    _consume!(p, '.')
end

function _parse_sparql_version!(p::_TurtleParser)
    for _ in 1:7; p.pos = nextind(p.input, p.pos); end
    _skip_ws_and_comments!(p)
    _parse_version_string!(p)
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

# PNAME_NS ::= PN_PREFIX? ':'
# PN_PREFIX ::= PN_CHARS_BASE ( ( PN_CHARS | '.' )* PN_CHARS )?
# Internal dots are allowed; a trailing dot is not (it would belong to the
# terminator). Dots are buffered and only flushed when another PN_CHARS follows.
function _parse_prefix_name!(p::_TurtleParser)
    buf = IOBuffer()
    # An empty prefix (":") is valid.
    if _peek(p) == ':'
        p.pos = nextind(p.input, p.pos)
        return ""
    end
    c = _peek(p)
    (c !== nothing && _is_pn_chars_base(c)) ||
        throw(ArgumentError("Invalid prefix name at position $(p.pos)"))
    write(buf, c)
    p.pos = nextind(p.input, p.pos)
    pending_dots = 0
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if c == ':'
            p.pos = nextind(p.input, p.pos)
            # A pending trailing dot before ':' is illegal (PN_PREFIX must end
            # in PN_CHARS), e.g. "e.g.:".
            pending_dots > 0 &&
                throw(ArgumentError("Prefix name may not end with '.' at position $(p.pos)"))
            return String(take!(buf))
        elseif c == '.'
            pending_dots += 1
            p.pos = nextind(p.input, p.pos)
        elseif _is_pn_chars(c)
            while pending_dots > 0
                write(buf, '.'); pending_dots -= 1
            end
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        else
            throw(ArgumentError("Invalid character $(repr(c)) in prefix name at position $(p.pos)"))
        end
    end
    throw(ArgumentError("Unexpected end of input in prefix name"))
end

# Characters forbidden to appear (raw or via \u/\U escape) inside an IRIREF
# per the Turtle/N-Triples grammar:
#   #x00-#x20, '<', '>', '"', '{', '}', '|', '^', '`', '\'
_iri_char_forbidden(c::Char) =
    UInt32(c) <= 0x20 || c == '<' || c == '>' || c == '"' ||
    c == '{' || c == '}' || c == '|' || c == '^' || c == '`' || c == '\\'

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
            ec = _parse_iri_escape!(p)
            # A UCHAR escape may encode IRI characters the grammar forbids only
            # in raw form (e.g. | → '|'), but it must not encode characters
            # that would make the IRI structurally invalid: control characters,
            # space, '<' or '>' (W3C turtle-eval-bad-01/02/03).
            (UInt32(ec) <= 0x20 || ec == '<' || ec == '>') &&
                throw(ArgumentError("Illegal character $(repr(ec)) (from escape) in IRI reference at position $(p.pos)"))
            write(buf, ec)
        elseif _iri_char_forbidden(c)
            throw(ArgumentError("Illegal character $(repr(c)) in IRI reference at position $(p.pos)"))
        else
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        end
    end
    throw(ArgumentError("Unterminated IRI reference"))
end

_is_absolute_uri(uri::AbstractString) = occursin(r"^[A-Za-z][A-Za-z0-9+.-]*:", uri)

function _resolve_uri(base::AbstractString, relative::AbstractString)
    string(URIs.resolvereference(URIs.URI(base), URIs.URI(relative)))
end

# ─── Triple parsing ─────────────────────────────────────────────────

function _parse_triples!(p::_TurtleParser)
    _skip_ws_and_comments!(p)
    c = _peek(p)
    c === nothing && return

    # A blankNodePropertyList ('[...]') subject may stand alone (its nested
    # predicateObjectList already produced triples). A reifier subject
    # (`<< … >>`) may also stand alone (it already emitted its rdf:reifies
    # triple). Every other subject form requires a non-empty
    # predicateObjectList.
    subject_is_bnpl = c == '['
    subject_is_reifier = c == '<' && _at_string(p, "<<") && !_at_string(p, "<<(")

    # Parse subject
    subject = _parse_subject!(p)
    _skip_ws_and_comments!(p)

    # Parse predicate-object list
    n = _parse_predicate_object_list!(p, subject)
    (n == 0 && !subject_is_bnpl && !subject_is_reifier) &&
        throw(ArgumentError("Subject has no predicate-object list at position $(p.pos)"))

    _skip_ws_and_comments!(p)
    _consume!(p, '.')
end

function _parse_subject!(p::_TurtleParser)
    c = _peek(p)
    if c == '<'
        if _at_string(p, "<<(")
            throw(ArgumentError("a triple term '<<( … )>>' may only appear in object position at position $(p.pos)"))
        elseif _at_string(p, "<<")
            return _parse_reifier!(p)
        end
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
    npreds = 0
    while true
        _skip_ws_and_comments!(p)
        c = _peek(p)
        (c === nothing || c == '.' || c == ']' || c == ')' || c == '|') && break

        predicate = _parse_verb!(p)
        _skip_ws_and_comments!(p)
        _parse_object_list!(p, subject, predicate)
        npreds += 1

        _skip_ws_and_comments!(p)
        c = _peek(p)
        if c == ';'
            # Consume one or more consecutive ';' separators (the grammar's
            # `(';' (verb objectList)?)*` permits repeated/empty `;;`).
            while _peek(p) == ';'
                p.pos = nextind(p.input, p.pos)
                _skip_ws_and_comments!(p)
            end
            # Check for trailing semicolon before . or ] or |}
            c2 = _peek(p)
            (c2 === nothing || c2 == '.' || c2 == ']' || c2 == '|') && break
        else
            break
        end
    end
    npreds
end

function _parse_verb!(p::_TurtleParser)
    c = _peek(p)
    if c == 'a'
        # 'a' is the rdf:type keyword unless it continues as a prefixed name;
        # any non-name character (e.g. '[', '<', '"', whitespace) is a boundary.
        next_pos = nextind(p.input, p.pos)
        if next_pos > lastindex(p.input) ||
           !(_is_pn_chars(p.input[next_pos]) || p.input[next_pos] in (':', '.'))
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
        _parse_annotations!(p, subject, predicate, object)
        c = _peek(p)
        if c == ','
            p.pos = nextind(p.input, p.pos)
        else
            break
        end
    end
end

# Parse the RDF 1.2 annotation/reifier sequence that may follow an object:
#   ( '~' reifierId | '{|' predicateObjectList '|}' )*
#
# Each `~ id` and each `{| … |}` introduces a reifier for the triple
# `(subject, predicate, object)`. A `~ id` sets a pending explicit reifier
# id for the next annotation block; if the block is omitted (another `~`
# or end of sequence) the pending id is still emitted as a bare reifier.
# A `{| … |}` block uses the pending id (or a fresh blank node) as the
# reifier subject and attaches its predicate-object list to it.
function _parse_annotations!(p::_TurtleParser, subject::Node, predicate::URIRef, object::Identifier)
    pending = nothing            # explicit reifier id awaiting a block
    have_pending = false
    while true
        _skip_ws_and_comments!(p)
        if _peek(p) == '~'
            # Flush any unconsumed pending reifier id as a bare reifier.
            if have_pending
                _emit_reifier!(p, pending, subject, predicate, object)
            end
            p.pos = nextind(p.input, p.pos)
            _skip_ws_and_comments!(p)
            # The reifier id is optional: a bare `~` uses a fresh blank node.
            c2 = _peek(p)
            if c2 === nothing || c2 == '.' || c2 == ';' || c2 == ',' ||
               c2 == ']' || c2 == ')' || _at_string(p, "{|") || c2 == '~' ||
               c2 == '|'
                pending = _new_bnode!(p)
            else
                pending = _parse_reifier_id!(p)
            end
            have_pending = true
            _skip_ws_and_comments!(p)
        elseif _at_string(p, "{|")
            _consume_str!(p, "{|")
            _skip_ws_and_comments!(p)
            rid = have_pending ? pending : _new_bnode!(p)
            _emit_reifier!(p, rid, subject, predicate, object)
            have_pending = false
            pending = nothing
            # An empty annotation block `{| |}` is not allowed.
            np = _parse_predicate_object_list!(p, rid)
            np == 0 && throw(ArgumentError("empty annotation block at position $(p.pos)"))
            _skip_ws_and_comments!(p)
            _consume_str!(p, "|}")
            _skip_ws_and_comments!(p)
        else
            break
        end
    end
    if have_pending
        _emit_reifier!(p, pending, subject, predicate, object)
    end
end

function _emit_reifier!(p::_TurtleParser, rid::Node, subject::Node, predicate::URIRef, object::Identifier)
    add!(p.graph, Triple(rid, _RDF_REIFIES, TripleTerm(subject, predicate, object)))
end

function _parse_object!(p::_TurtleParser)
    _parse_node!(p)
end

# ─── Node parsing ───────────────────────────────────────────────────

function _parse_node!(p::_TurtleParser)::Identifier
    c = _peek(p)
    c === nothing && throw(ArgumentError("Unexpected end of input"))

    if c == '<'
        _at_string(p, "<<(") && return _parse_triple_term!(p)
        _at_string(p, "<<") && return _parse_reifier!(p)
        return URIRef(_parse_iriref!(p))
    elseif c == '_'
        return _parse_blank_node_label!(p)
    elseif c == '['
        return _parse_blank_node_property_list!(p)
    elseif c == '('
        return _parse_collection!(p)
    elseif c == '"' || c == '\''
        return _parse_literal!(p)
    elseif c == '+' || c == '-' || isdigit(c) ||
           (c == '.' && _next_char_is_digit(p.input, p.pos))
        return _parse_numeric_literal!(p)
    elseif _at_keyword(p, "true")
        _consume_str!(p, "true")
        return Literal(true)
    elseif _at_keyword(p, "false")
        _consume_str!(p, "false")
        return Literal(false)
    else
        return _parse_prefixed_name!(p)
    end
end

# Is the character after `pos` a digit? (for leading-dot decimals like `.5`)
function _next_char_is_digit(input::String, pos::Int)
    next_pos = nextind(input, pos)
    next_pos <= lastindex(input) && isdigit(input[next_pos])
end

# Match a keyword (`true`/`false`) only at a token boundary, so that e.g.
# `trueblue:x` or `true:x` parse as prefixed names.
function _at_keyword(p::_TurtleParser, word::AbstractString)
    _at_string(p, word) || return false
    endpos = p.pos
    for _ in 1:length(word)
        endpos = nextind(p.input, endpos)
    end
    endpos > lastindex(p.input) && return true
    c = p.input[endpos]
    !(_is_pn_chars(c) || c == ':')
end

# ─── Reifier / triple term parsing (RDF 1.2) ───────────────────────
#
# RDF 1.2 distinguishes two `<<…>>` forms:
#   * triple term:  `<<( s p o )>>`  — a term (the rdf triple term), may
#     appear in object position only. Maps directly to a `TripleTerm`.
#   * reifier:      `<< s p o >>` or `<< s p o ~ reifierId >>` — denotes a
#     reifier resource (the given id, or a fresh blank node) and emits
#     `reifier rdf:reifies <<( s p o )>>`. The reifier resource is returned
#     and used in subject/object position. It does NOT assert `s p o`.

# Parse a triple term `<<( s p o )>>`; cursor positioned at `<<(`.
function _parse_triple_term!(p::_TurtleParser)
    _consume_str!(p, "<<(")
    _skip_ws_and_comments!(p)
    s = _parse_reified_subject!(p; allow_reifier=false)
    _skip_ws_and_comments!(p)
    pred = _parse_verb!(p)
    _skip_ws_and_comments!(p)
    o = _parse_reified_object!(p; allow_reifier=false)
    _skip_ws_and_comments!(p)
    _consume_str!(p, ")>>")
    TripleTerm(s, pred, o)
end

# Parse an empty anonymous blank node `[]`. A blank-node property list with
# content (`[ … ]`) is not allowed in a reified-triple position.
function _parse_anon_bnode!(p::_TurtleParser)
    _consume!(p, '[')
    _skip_ws_and_comments!(p)
    _peek(p) == ']' ||
        throw(ArgumentError("a blank-node property list with content is not permitted as a reified-triple term at position $(p.pos)"))
    _consume!(p, ']')
    _new_bnode!(p)
end

# Subject of a reified/triple-term triple. `allow_reifier` controls whether a
# nested reifier `<< … >>` is permitted (true inside reifiers, false inside
# triple terms). Collections, literals and non-empty blank-node property
# lists are not permitted.
function _parse_reified_subject!(p::_TurtleParser; allow_reifier::Bool=true)
    c = _peek(p)
    if c == '<'
        _at_string(p, "<<(") && return _parse_triple_term!(p)
        if _at_string(p, "<<")
            allow_reifier ||
                throw(ArgumentError("a reifier '<< … >>' may not appear inside a triple term at position $(p.pos)"))
            return _parse_reifier!(p)
        end
        return URIRef(_parse_iriref!(p))
    elseif c == '_'
        return _parse_blank_node_label!(p)
    elseif c == '['
        return _parse_anon_bnode!(p)
    elseif c == '('
        throw(ArgumentError("collection not permitted as reified-triple subject at position $(p.pos)"))
    elseif c == '"' || c == '\'' || c == '+' || c == '-' || (c !== nothing && isdigit(c)) ||
           (c == '.' && _next_char_is_digit(p.input, p.pos))
        throw(ArgumentError("reified-triple subject may not be a literal at position $(p.pos)"))
    else
        return _parse_prefixed_name!(p)
    end
end

# Object of a reified/triple-term triple: like the subject but literals are
# allowed. Collections and non-empty blank-node property lists are not.
function _parse_reified_object!(p::_TurtleParser; allow_reifier::Bool=true)
    c = _peek(p)
    if c == '['
        return _parse_anon_bnode!(p)
    elseif c == '('
        throw(ArgumentError("collection not permitted as reified-triple object at position $(p.pos)"))
    elseif c == '<'
        if _at_string(p, "<<(")
            return _parse_triple_term!(p)
        elseif _at_string(p, "<<")
            allow_reifier ||
                throw(ArgumentError("a reifier '<< … >>' may not appear inside a triple term at position $(p.pos)"))
            return _parse_reifier!(p)
        end
    end
    return _parse_node!(p)
end

# Parse a reifier `<< s p o (~ reifierId)? >>`; cursor positioned at `<<`
# (not `<<(`). Returns the reifier resource (Node) and emits the
# `reifier rdf:reifies <<( s p o )>>` triple.
function _parse_reifier!(p::_TurtleParser)
    _consume_str!(p, "<<")
    _skip_ws_and_comments!(p)
    s = _parse_reified_subject!(p)
    _skip_ws_and_comments!(p)
    pred = _parse_verb!(p)
    _skip_ws_and_comments!(p)
    o = _parse_reified_object!(p)
    _skip_ws_and_comments!(p)
    reifier = nothing
    if _peek(p) == '~'
        p.pos = nextind(p.input, p.pos)
        _skip_ws_and_comments!(p)
        # The id is optional: `<< s p o ~ >>` uses a fresh blank node.
        _at_string(p, ">>") || (reifier = _parse_reifier_id!(p))
        _skip_ws_and_comments!(p)
    end
    _consume_str!(p, ">>")
    rid = reifier === nothing ? _new_bnode!(p) : reifier
    tt = TripleTerm(s, pred, o)
    add!(p.graph, Triple(rid, _RDF_REIFIES, tt))
    rid
end

# A reifier id is an IRI or blank node (label or anonymous []).
function _parse_reifier_id!(p::_TurtleParser)
    c = _peek(p)
    if c == '<'
        return URIRef(_parse_iriref!(p))
    elseif c == '_'
        return _parse_blank_node_label!(p)
    elseif c == '['
        return _parse_anon_bnode!(p)
    else
        return _parse_prefixed_name!(p)
    end
end

# Dispatch on a `<<` token: triple term (`<<(`) vs reifier (`<<`).
function _parse_quoted_triple!(p::_TurtleParser)
    _at_string(p, "<<(") && return _parse_triple_term!(p)
    return _parse_reifier!(p)
end

# ─── Blank node parsing ────────────────────────────────────────────

function _parse_blank_node_label!(p::_TurtleParser)
    _consume!(p, '_')
    _consume!(p, ':')
    c = _peek(p)
    (c === nothing || !(_is_pn_chars_u(c) || isdigit(c))) &&
        throw(ArgumentError("Invalid blank node label at position $(p.pos)"))
    buf = IOBuffer()
    write(buf, c)
    p.pos = nextind(p.input, p.pos)
    # Dots are only allowed mid-label: buffer them and flush when another
    # label character follows; trailing dots are left unconsumed (they
    # belong to the surrounding syntax, e.g. the statement terminator).
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
    BNode(String(take!(buf)))
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
    # Never collide with a blank node label used explicitly in the document
    while "b$(p.bnodecounter)" in p.doc_bnode_labels
        p.bnodecounter += 1
    end
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
    # Read prefix part (PN_PREFIX) up to and including the ':'. PN_PREFIX allows
    # internal '.', but a '.' immediately before ':' is illegal.
    c = _peek(p)
    (c !== nothing && (_is_pn_chars_base(c) || c == ':')) ||
        throw(ArgumentError("Invalid prefixed name at position $(p.pos)"))
    prefix = _parse_prefix_name!(p)

    # Read local part (after :) following the PN_LOCAL grammar
    localname = _parse_pn_local!(p)

    # Resolve prefix
    ns_uri = get(p.prefixes, prefix, nothing)
    if isnothing(ns_uri)
        throw(ArgumentError("Unknown prefix: '$prefix' at position $(p.pos)"))
    end
    URIRef(ns_uri * localname)
end

# PN_LOCAL ::= (PN_CHARS_U | ':' | [0-9] | PLX)
#              ((PN_CHARS | '.' | ':' | PLX)* (PN_CHARS | ':' | PLX))?
# PLX ::= PERCENT | PN_LOCAL_ESC
# Percent sequences are kept verbatim; PN_LOCAL_ESC escapes are unescaped.
# Shared by the Turtle and N3 parsers (both expose `input`/`pos` fields).
function _parse_pn_local!(p)
    buf = IOBuffer()
    is_first = true
    pending_dots = 0
    flush_dots!() = (while pending_dots > 0; write(buf, '.'); pending_dots -= 1; end)
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if c == '%'
            # PERCENT: '%' HEX HEX, kept verbatim
            h1 = nextind(p.input, p.pos)
            h2 = h1 <= lastindex(p.input) ? nextind(p.input, h1) : h1
            if h1 > lastindex(p.input) || h2 > lastindex(p.input) ||
               !_is_hex_digit(p.input[h1]) || !_is_hex_digit(p.input[h2])
                throw(ArgumentError("Invalid percent-encoding in prefixed name at position $(p.pos)"))
            end
            flush_dots!()
            write(buf, '%', p.input[h1], p.input[h2])
            p.pos = nextind(p.input, h2)
        elseif c == '\\'
            # PN_LOCAL_ESC: '\' followed by a reserved character
            esc_pos = nextind(p.input, p.pos)
            esc_pos > lastindex(p.input) &&
                throw(ArgumentError("Truncated escape in prefixed name at position $(p.pos)"))
            ec = p.input[esc_pos]
            ec in _PN_LOCAL_ESC_CHARS ||
                throw(ArgumentError("Invalid local-name escape '\\$ec' at position $(p.pos)"))
            flush_dots!()
            write(buf, ec)
            p.pos = nextind(p.input, esc_pos)
        elseif c == ':' || _is_pn_chars(c)
            # First char must be PN_CHARS_U | ':' | digit (not '-', U+00B7, marks)
            if is_first && !(_is_pn_chars_u(c) || isdigit(c) || c == ':')
                break
            end
            flush_dots!()
            write(buf, c)
            p.pos = nextind(p.input, p.pos)
        elseif c == '.' && !is_first
            # Dots are only allowed mid-name; trailing dots stay unconsumed
            pending_dots += 1
            p.pos = nextind(p.input, p.pos)
        else
            break
        end
        is_first = false
    end
    p.pos -= pending_dots  # '.' is a single byte; rewind unconsumed dots
    String(take!(buf))
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
        # Optional base direction (RDF 1.2): "x"@en--ltr / "x"@ar--rtl
        if _at_string(p, "--")
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
    # STRING_LITERAL_LONG ::= '"""' ( ('"' | '""')? (CHAR | ECHAR | UCHAR) )* '"""'
    # The string closes at the FIRST run of exactly three quotes. A run of one
    # or two quotes is content only when followed by a non-closing character;
    # four or more quotes at the close is a syntax error (stray quote).
    while p.pos <= lastindex(p.input)
        c = p.input[p.pos]
        if c == quote_char
            run = 0
            while p.pos <= lastindex(p.input) && p.input[p.pos] == quote_char
                run += 1
                p.pos = nextind(p.input, p.pos)
            end
            if run == 3
                return String(take!(buf))
            elseif run < 3
                # 1-2 quotes belong to content (they must be followed by a
                # non-quote, which the loop will handle on the next iteration).
                for _ in 1:run
                    write(buf, quote_char)
                end
            else
                throw(ArgumentError("Stray quote(s) before end of long string literal at position $(p.pos)"))
            end
        elseif c == '\\'
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
        return _parse_hex_escape!(p, 4)
    elseif c == 'U'
        return _parse_hex_escape!(p, 8)
    else
        throw(ArgumentError("Invalid string escape '\\$c' at position $(p.pos)"))
    end
end

# Parse exactly `n` hex digits of a \\u/\\U escape, with clean errors on
# truncation, non-hex characters, surrogates, and out-of-range code points.
function _parse_hex_escape!(p::_TurtleParser, n::Int)
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
function _parse_iri_escape!(p::_TurtleParser)
    p.pos > lastindex(p.input) &&
        throw(ArgumentError("Truncated escape sequence in IRI reference"))
    c = p.input[p.pos]
    p.pos = nextind(p.input, p.pos)
    c == 'u' && return _parse_hex_escape!(p, 4)
    c == 'U' && return _parse_hex_escape!(p, 8)
    throw(ArgumentError("Invalid escape '\\$c' in IRI reference; only \\u and \\U are allowed"))
end

# LANGTAG ::= '@' [a-zA-Z]+ ('-' [a-zA-Z0-9]+)*  (the leading '@' is already
# consumed by the caller). The primary subtag must be one or more ASCII
# letters; each '-' subtag must be one or more ASCII alphanumerics.
function _parse_lang_tag!(p::_TurtleParser)
    _ascii_letter(c) = ('a' <= c <= 'z') || ('A' <= c <= 'Z')
    _ascii_alnum(c) = _ascii_letter(c) || ('0' <= c <= '9')
    buf = IOBuffer()
    first = _peek(p)
    (first !== nothing && _ascii_letter(first)) ||
        throw(ArgumentError("Invalid language tag (must start with a letter) at position $(p.pos)"))
    while p.pos <= lastindex(p.input) && _ascii_letter(p.input[p.pos])
        write(buf, p.input[p.pos])
        p.pos = nextind(p.input, p.pos)
    end
    while p.pos <= lastindex(p.input) && p.input[p.pos] == '-'
        # A '-' continues the tag only when followed by an alphanumeric subtag;
        # "--" introduces a base direction (handled by the caller).
        next_pos = nextind(p.input, p.pos)
        (next_pos <= lastindex(p.input) && _ascii_alnum(p.input[next_pos])) || break
        write(buf, '-')
        p.pos = next_pos
        while p.pos <= lastindex(p.input) && _ascii_alnum(p.input[p.pos])
            write(buf, p.input[p.pos])
            p.pos = nextind(p.input, p.pos)
        end
    end
    String(take!(buf))
end

# ─── Numeric literal parsing ───────────────────────────────────────

# Turtle numeric grammar:
#   INTEGER  ::= [+-]? [0-9]+
#   DECIMAL  ::= [+-]? [0-9]* '.' [0-9]+
#   DOUBLE   ::= [+-]? ( [0-9]+ '.' [0-9]* EXPONENT | '.' [0-9]+ EXPONENT
#                        | [0-9]+ EXPONENT )
#   EXPONENT ::= [eE] [+-]? [0-9]+
# Note that a DOUBLE may have a '.' followed by zero digits (e.g. `123.E+1`)
# provided an EXPONENT follows; a DECIMAL requires at least one digit after '.'.
function _parse_numeric_literal!(p::_TurtleParser)
    buf = IOBuffer()
    has_dot = false
    has_exp = false
    digits_before_dot = 0
    digits_after_dot = 0

    # Optional sign
    c = _peek(p)
    if c == '+' || c == '-'
        write(buf, c)
        p.pos = nextind(p.input, p.pos)
    end

    # Integer part
    while p.pos <= lastindex(p.input) && isdigit(p.input[p.pos])
        write(buf, p.input[p.pos])
        digits_before_dot += 1
        p.pos = nextind(p.input, p.pos)
    end

    # Fractional part: '.' is consumed only when it is part of the number,
    # i.e. when followed by a digit (DECIMAL/DOUBLE) or by an exponent marker
    # after at least one integer digit (DOUBLE like `123.E+1`). Otherwise the
    # '.' is the statement terminator and is left unconsumed.
    if _peek(p) == '.'
        next_pos = nextind(p.input, p.pos)
        nextc = next_pos <= lastindex(p.input) ? p.input[next_pos] : '\0'
        if isdigit(nextc) || ((nextc == 'e' || nextc == 'E') && digits_before_dot > 0)
            has_dot = true
            write(buf, '.')
            p.pos = next_pos
            while p.pos <= lastindex(p.input) && isdigit(p.input[p.pos])
                write(buf, p.input[p.pos])
                digits_after_dot += 1
                p.pos = nextind(p.input, p.pos)
            end
        end
    end

    # Exponent
    c = _peek(p)
    if c == 'e' || c == 'E'
        has_exp = true
        write(buf, c)
        p.pos = nextind(p.input, p.pos)
        c2 = _peek(p)
        if c2 == '+' || c2 == '-'
            write(buf, c2)
            p.pos = nextind(p.input, p.pos)
        end
        # EXPONENT requires at least one digit.
        ndig = 0
        while p.pos <= lastindex(p.input) && isdigit(p.input[p.pos])
            write(buf, p.input[p.pos])
            ndig += 1
            p.pos = nextind(p.input, p.pos)
        end
        ndig == 0 &&
            throw(ArgumentError("Invalid numeric literal: exponent has no digits at position $(p.pos)"))
    end

    lexical = String(take!(buf))
    xsd = "http://www.w3.org/2001/XMLSchema#"

    # Validate digit requirements per production.
    if has_exp
        # DOUBLE: need digits before-dot or after-dot (the [0-9]+ in each branch).
        (digits_before_dot + digits_after_dot == 0) &&
            throw(ArgumentError("Invalid numeric literal '$lexical'"))
        Literal(lexical, datatype=URIRef(xsd * "double"))
    elseif has_dot
        # DECIMAL: requires at least one digit after the dot.
        digits_after_dot == 0 &&
            throw(ArgumentError("Invalid decimal literal '$lexical'"))
        Literal(lexical, datatype=URIRef(xsd * "decimal"))
    else
        digits_before_dot == 0 &&
            throw(ArgumentError("Invalid integer literal '$lexical'"))
        Literal(lexical, datatype=URIRef(xsd * "integer"))
    end
end

# ─── Register format with high-level API ───────────────────────────

serialize(io::IO, g::RDFGraph, ::TurtleFormat) = serialize_turtle(io, g)
parse_rdf!(g::RDFGraph, source, ::TurtleFormat) = parse_turtle!(g, source)
