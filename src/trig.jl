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
        start = p.pos
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
        elseif _trig_at_ci(p, "GRAPH") && !_trig_at_ci(p, "GRAPH:")
            _trig_parse_named_graph!(p)
        else
            # Either `LABEL { ... }` (named graph) or a bare statement in the
            # default graph (`subject predicate object .`). Disambiguate by
            # scanning a single leading label token and checking whether the
            # next significant character is '{'.
            label, after_label = _trig_scan_label(p)
            if label !== nothing && _trig_significant_is_brace(p, after_label)
                p.pos = after_label
                _trig_skip_ws!(p)
                graph_name = _trig_resolve_label(p, label)
                _trig_parse_graph_block!(p, graph_name)
            else
                # Bare statement: scan to the terminating '.' at depth 0 and
                # delegate the whole segment to the Turtle parser.
                _trig_parse_bare_statement!(p)
            end
        end
        _trig_skip_ws!(p)
        # Anti-hang guard: every iteration must make forward progress.
        p.pos <= start && throw(ArgumentError(
            "TriG: parser made no progress at pos $start (near " *
            "$(repr(p.input[start:min(end, nextind(p.input, start, 20))])))"))
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

# Scan one graph-label token without committing pos. Returns
# (label_string_or_nothing, position_after_label). Handles IRIrefs,
# blank-node labels and prefixed names (including the empty prefix ':').
# Returns `nothing` for the label when the token is `[`/`(` (a blank-node
# property list or collection can never be a graph label, so the statement
# must be a bare default-graph triple).
function _trig_scan_label(p::_TriGParser)
    pos = p.pos
    c = _trig_peek(p)
    if c == '<'
        # IRIref <...>
        pos = nextind(p.input, pos)
        while pos <= lastindex(p.input) && p.input[pos] != '>'
            pos = nextind(p.input, pos)
        end
        pos > lastindex(p.input) && return (nothing, p.pos)
        endpos = pos                       # at '>'
        pos = nextind(p.input, pos)        # past '>'
        return (p.input[p.pos:endpos], pos)
    elseif c == '[' || c == '('
        return (nothing, p.pos)
    else
        # Blank node label or prefixed name: read until whitespace or '{' or
        # one of the statement delimiters. The empty prefix ':' is included.
        start = pos
        while pos <= lastindex(p.input)
            ch = p.input[pos]
            (ch in (' ', '\t', '\n', '\r', '{', '}', '#')) && break
            pos = nextind(p.input, pos)
        end
        pos == start && return (nothing, p.pos)
        return (p.input[start:prevind(p.input, pos)], pos)
    end
end

# True iff the next non-whitespace/comment character at or after `from` is '{'.
function _trig_significant_is_brace(p::_TriGParser, from::Int)
    pos = from
    while pos <= lastindex(p.input)
        c = p.input[pos]
        if c in (' ', '\t', '\n', '\r')
            pos = nextind(p.input, pos)
        elseif c == '#'
            while pos <= lastindex(p.input) && p.input[pos] != '\n'
                pos = nextind(p.input, pos)
            end
        else
            return c == '{'
        end
    end
    false
end

function _trig_resolve_label(p::_TriGParser, label::AbstractString)
    if startswith(label, '<')
        iri = label[nextind(label, firstindex(label)):prevind(label, lastindex(label))]
        return URIRef(_trig_resolve_iri(p, iri))
    elseif startswith(label, "_:")
        return BNode(label[3:end])
    else
        idx = findfirst(':', label)
        idx === nothing && throw(ArgumentError("Cannot resolve TriG graph label: $label"))
        prefix = label[1:prevind(label, idx)]
        localname = label[nextind(label, idx):end]
        ns = get(p.prefixes, prefix, nothing)
        ns === nothing && throw(ArgumentError("Cannot resolve TriG graph label: $label"))
        return URIRef(ns * localname)
    end
end

function _trig_resolve_iri(p::_TriGParser, iri::AbstractString)
    if p.base !== nothing && !occursin("://", iri) && !startswith(iri, "urn:")
        # Relative IRI: resolve against base (simple concatenation/last-slash).
        return _trig_join_base(p.base, iri)
    end
    iri
end

function _trig_join_base(base::AbstractString, ref::AbstractString)
    isempty(ref) && return base
    if startswith(ref, '#') || startswith(ref, '?')
        return base * ref
    end
    base * ref
end

# Scanner that advances `pos` until reaching `target` (a Char) at bracket-depth
# 0 while respecting string literals (including triple-quoted), <...> IRIs and
# the nesting of both [] and (). Also stops at an unescaped '}' at depth 0
# (used for the final statement in a block that omits its trailing '.').
# Returns the index of the stopping character (or lastindex+1 if EOF reached).
function _trig_scan_to!(p::_TriGParser, target::Char)
    input = p.input
    lastidx = lastindex(input)
    depth = 0
    while p.pos <= lastidx
        c = input[p.pos]
        if c == '"' || c == '\''
            p.pos = _trig_skip_string!(p, c)
        elseif c == '<'
            p.pos = _trig_skip_iri!(p)
        elseif c == '#'
            # comment to end of line
            while p.pos <= lastidx && input[p.pos] != '\n'
                p.pos = nextind(input, p.pos)
            end
        elseif c == '[' || c == '('
            depth += 1
            p.pos = nextind(input, p.pos)
        elseif c == ']' || c == ')'
            depth > 0 && (depth -= 1)
            p.pos = nextind(input, p.pos)
        elseif depth == 0 && (c == target || c == '}')
            return p.pos
        else
            p.pos = nextind(input, p.pos)
        end
    end
    p.pos
end

# At a quote char; skip past the matching closing quote. Handles both single
# and triple-quoted (long) string literals and backslash escapes.
function _trig_skip_string!(p::_TriGParser, q::Char)
    input = p.input
    lastidx = lastindex(input)
    # Detect long (triple) quote.
    i2 = nextind(input, p.pos)
    i3 = i2 <= lastidx ? nextind(input, i2) : i2
    long = i2 <= lastidx && i3 <= lastidx && input[i2] == q && input[i3] == q
    if long
        pos = nextind(input, i3)  # past the three opening quotes
        while pos <= lastidx
            c = input[pos]
            if c == '\\'
                pos = pos < lastidx ? nextind(input, nextind(input, pos)) : nextind(input, pos)
            elseif c == q
                j2 = nextind(input, pos)
                j3 = j2 <= lastidx ? nextind(input, j2) : j2
                if j2 <= lastidx && j3 <= lastidx && input[j2] == q && input[j3] == q
                    return nextind(input, j3)  # past the three closing quotes
                end
                pos = nextind(input, pos)
            else
                pos = nextind(input, pos)
            end
        end
        return pos
    else
        pos = nextind(input, p.pos)  # past opening quote
        while pos <= lastidx
            c = input[pos]
            if c == '\\'
                pos = pos < lastidx ? nextind(input, nextind(input, pos)) : nextind(input, pos)
            elseif c == q
                return nextind(input, pos)  # past closing quote
            else
                pos = nextind(input, pos)
            end
        end
        return pos
    end
end

# At '<'; skip past the closing '>'.
function _trig_skip_iri!(p::_TriGParser)
    input = p.input
    lastidx = lastindex(input)
    pos = nextind(input, p.pos)
    while pos <= lastidx
        c = input[pos]
        if c == '>'
            return nextind(input, pos)
        elseif c == '\\'
            pos = pos < lastidx ? nextind(input, nextind(input, pos)) : nextind(input, pos)
        else
            pos = nextind(input, pos)
        end
    end
    return pos
end

# Prefix/base declarations in scope, to prepend to a Turtle sub-document.
function _trig_prelude(p::_TriGParser)
    join(["@prefix $k: <$v> .\n" for (k, v) in p.prefixes])
end

function _trig_parse_graph_block!(p::_TriGParser, graph_name::OptGraphName)
    _trig_consume!(p, '{')
    body_start = p.pos
    # Scan to the matching '}' with a fully string/IRI/bracket-aware scanner.
    stop = _trig_scan_to!(p, '}')
    (stop > lastindex(p.input) || p.input[stop] != '}') &&
        throw(ArgumentError("TriG: unterminated graph block (missing '}')"))
    body = body_start <= prevind(p.input, stop) ? p.input[body_start:prevind(p.input, stop)] : ""
    p.pos = nextind(p.input, stop)  # consume '}'

    # TriG allows the trailing '.' of the final statement inside a block to be
    # omitted; the Turtle parser requires it, so append one when missing.
    tb = rstrip(body)
    if !isempty(tb) && last(tb) != '.'
        body = body * " ."
    end
    _trig_emit_body!(p, body, graph_name)
end

function _trig_parse_bare_statement!(p::_TriGParser)
    start = p.pos
    stop = _trig_scan_to!(p, '.')
    if stop <= lastindex(p.input) && p.input[stop] == '.'
        segment = p.input[start:prevind(p.input, stop)]
        p.pos = nextind(p.input, stop)  # consume '.'
        _trig_emit_body!(p, segment * " .", nothing)
    elseif stop <= lastindex(p.input) && p.input[stop] == '}'
        # Shouldn't normally happen at document level, but stay defensive.
        segment = p.input[start:prevind(p.input, stop)]
        p.pos = stop
        _trig_emit_body!(p, segment * " .", nothing)
    else
        # Reached EOF: treat remaining text as a final statement.
        segment = start <= lastindex(p.input) ? p.input[start:lastindex(p.input)] : ""
        p.pos = nextind(p.input, lastindex(p.input))
        strip(segment) == "" && return
        _trig_emit_body!(p, segment * " .", nothing)
    end
end

# Parse a Turtle body (one or more statements) and add the resulting triples
# to the dataset under `graph_name`.
function _trig_emit_body!(p::_TriGParser, body::AbstractString, graph_name::OptGraphName)
    strip(body) == "" && return
    temp_g = RDFGraph()
    for (prefix, uri) in p.prefixes
        bind!(temp_g, prefix, Namespace(uri))
    end
    ttl = _trig_prelude(p) * body * "\n"
    parse_turtle!(temp_g, ttl; base=p.base)
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
