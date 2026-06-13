# ─── JSON-LD Format ─────────────────────────────────────────────────
# JSON-based RDF serialization using JSON3.
#
# Parsing is implemented on top of the JSON-LD 1.1 expansion algorithm in
# jsonld_processing.jl, so all expansion features (contexts, @vocab/@base,
# container maps, @nest, scoped contexts, remote contexts via a loader hook,
# @reverse, @list, @direction, @json) are honored when converting to RDF.
#
# RDF conversion notes:
#   - `@list` arrays are converted to rdf:first/rdf:rest/rdf:nil chains, and
#     well-formed chains are detected and serialized back as `@list` arrays
#     (an empty `@list` corresponds to rdf:nil).
#   - `@reverse` entries produce triples with subject and object swapped.
#   - Value objects with `@language`/`@direction` map to language-tagged
#     `Literal`s with the `direction` field set (compound-literal form; the
#     i18n datatype form is not supported).
#   - `"@type": "@json"` value objects become rdf:JSON literals (serialized
#     with JSON3; JCS canonicalization is not applied). rdf:JSON literals are
#     serialized back as `{"@value": <lexical>, "@type": rdf:JSON}` to
#     preserve the exact lexical form.
#   - Named graphs are not supported: `@graph` contents are merged into the
#     target graph.

const _JLD_RDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
const _JLD_RDF_TYPE = _JLD_RDF * "type"
const _JLD_RDF_FIRST = _JLD_RDF * "first"
const _JLD_RDF_REST = _JLD_RDF * "rest"
const _JLD_RDF_NIL = _JLD_RDF * "nil"
const _JLD_RDF_JSON = _JLD_RDF * "JSON"

# ─── Serialization ──────────────────────────────────────────────────

"""
    serialize_jsonld(io::IO, g::RDFGraph)

Serialize a graph as JSON-LD to an IO stream.

Well-formed RDF collections (rdf:first/rdf:rest/rdf:nil chains whose nodes are
blank nodes referenced exactly once) are emitted as `@list` arrays;
language-tagged literals with a base direction include `@direction`; rdf:JSON
literals are emitted as typed values preserving their lexical form.
"""
function serialize_jsonld(io::IO, g::RDFGraph)
    data = _jsonld_build(g)
    JSON3.pretty(io, data, allow_inf=true)
end

"""
    serialize_jsonld(g::RDFGraph) -> String

Serialize a graph to a JSON-LD string.
"""
function serialize_jsonld(g::RDFGraph)
    buf = IOBuffer()
    serialize_jsonld(buf, g)
    String(take!(buf))
end

function _jsonld_build(g::RDFGraph)
    # Build @context from namespace manager
    context = Dict{String, Any}()
    for (prefix, uri) in namespaces(g)
        isempty(prefix) && continue
        context[prefix] = uri
    end

    # Detect well-formed rdf:List chains so they can be emitted as @list
    lists, consumed = _jsonld_collect_lists(g)

    # Group triples by subject
    subject_map = Dict{String, Dict{String, Any}}()
    for t in g
        (t.subject isa BNode && t.subject in consumed) && continue
        sid = _jsonld_subject_id(t.subject)
        node = get!(subject_map, sid, Dict{String, Any}("@id" => sid))
        pid = _jsonld_predicate_key(t.predicate, g.namespace_manager, context)
        oval = if pid == "@type" && t.object isa URIRef
            t.object.value  # @type values are plain URI strings
        else
            _jsonld_object_value(t.object, g.namespace_manager, context, lists)
        end

        if haskey(node, pid)
            existing = node[pid]
            if existing isa Vector
                push!(existing, oval)
            else
                node[pid] = [existing, oval]
            end
        else
            node[pid] = oval
        end
    end

    # Build output
    graph = [node for (_, node) in sort(collect(subject_map), by=first)]

    result = Dict{String, Any}()
    if !isempty(context)
        result["@context"] = context
    end
    if length(graph) == 1
        merge!(result, graph[1])
    else
        result["@graph"] = graph
    end
    result
end

"""
Find well-formed RDF collection chains in `g`.

Returns `(lists, consumed)` where `lists` maps each chain-head `BNode` to the
list items and `consumed` is the set of all blank nodes making up detected
chains. A chain node qualifies only if it is a blank node with exactly one
rdf:first and one rdf:rest triple and exactly one incoming reference, so
conversion to `@list` is lossless.
"""
function _jsonld_collect_lists(g::RDFGraph)
    firstp = URIRef(_JLD_RDF_FIRST)
    restp = URIRef(_JLD_RDF_REST)
    nil = URIRef(_JLD_RDF_NIL)
    subj_triples = Dict{BNode, Vector{Triple}}()
    obj_refs = Dict{BNode, Vector{Triple}}()
    for t in g
        t.subject isa BNode && push!(get!(subj_triples, t.subject, Triple[]), t)
        t.object isa BNode && push!(get!(obj_refs, t.object, Triple[]), t)
    end
    function iscand(b::BNode)
        ts = get(subj_triples, b, Triple[])
        length(ts) == 2 || return false
        count(t -> t.predicate == firstp, ts) == 1 || return false
        count(t -> t.predicate == restp, ts) == 1 || return false
        length(get(obj_refs, b, Triple[])) == 1
    end
    lists = Dict{BNode, Vector{Identifier}}()
    consumed = Set{BNode}()
    for b in keys(subj_triples)
        iscand(b) || continue
        # A head's single incoming reference is not rdf:rest from another chain node
        ref = obj_refs[b][1]
        (ref.predicate == restp && ref.subject isa BNode && iscand(ref.subject)) && continue
        items = Identifier[]
        chain = BNode[]
        cur = b
        ok = true
        while true
            ts = subj_triples[cur]
            f = ts[findfirst(t -> t.predicate == firstp, ts)].object
            r = ts[findfirst(t -> t.predicate == restp, ts)].object
            push!(items, f)
            push!(chain, cur)
            if r == nil
                break
            elseif r isa BNode && iscand(r) && !(r in chain)
                cur = r
            else
                ok = false
                break
            end
        end
        ok || continue
        lists[b] = items
        union!(consumed, chain)
    end
    lists, consumed
end

function _jsonld_subject_id(s::URIRef)
    s.value
end

function _jsonld_subject_id(s::BNode)
    "_:" * s.id
end

function _jsonld_predicate_key(p::URIRef, nsm::NamespaceManager, context::Dict)
    p.value == _JLD_RDF_TYPE && return "@type"
    # Try compact URI
    try
        prefix, _, localname = compute_qname(nsm, p)
        if haskey(context, prefix)
            return "$prefix:$localname"
        end
    catch; end
    p.value
end

function _jsonld_object_value(o::URIRef, ::NamespaceManager, ::Dict, lists)
    Dict{String, Any}("@id" => o.value)
end

function _jsonld_object_value(o::BNode, nsm::NamespaceManager, context::Dict, lists)
    if haskey(lists, o)
        return Dict{String, Any}("@list" =>
            Any[_jsonld_object_value(x, nsm, context, lists) for x in lists[o]])
    end
    Dict{String, Any}("@id" => "_:" * o.id)
end

function _jsonld_object_value(o::Literal, ::NamespaceManager, ::Dict, lists)
    if !isnothing(o.language)
        d = Dict{String, Any}("@value" => o.lexical, "@language" => o.language)
        isnothing(o.direction) || (d["@direction"] = o.direction)
        return d
    elseif !isnothing(o.datatype)
        xsd = "http://www.w3.org/2001/XMLSchema#"
        dt = o.datatype.value
        # Native JSON types
        if dt == xsd * "integer" || dt == xsd * "int" || dt == xsd * "long"
            v = tryparse(Int, o.lexical)
            !isnothing(v) && return v
        elseif dt == xsd * "double" || dt == xsd * "float" || dt == xsd * "decimal"
            v = tryparse(Float64, o.lexical)
            !isnothing(v) && return v
        elseif dt == xsd * "boolean"
            return o.lexical in ("true", "1")
        elseif dt == xsd * "string"
            return o.lexical
        end
        # rdf:JSON and other datatypes keep their exact lexical form
        return Dict{String, Any}("@value" => o.lexical, "@type" => dt)
    else
        return o.lexical
    end
end

# ─── Parsing ────────────────────────────────────────────────────────

"""
    parse_jsonld!(g::RDFGraph, io::IO; kwargs...) -> RDFGraph

Parse JSON-LD from an IO stream and add triples to the graph.
"""
function parse_jsonld!(g::RDFGraph, io::IO; kwargs...)
    data = read(io, String)
    parse_jsonld!(g, data; kwargs...)
end

"""
    parse_jsonld!(g::RDFGraph, input::AbstractString;
                  base=nothing, context_loader=_jsonld_default_loader) -> RDFGraph

Parse JSON-LD from a string and add triples to the graph.

The document is first run through JSON-LD 1.1 expansion (`jsonld_expand`), so
contexts (including remote contexts via `context_loader`, scoped contexts,
container maps, `@reverse` terms, `@nest`, `@vocab`/`@base`, `@direction`) are
fully honored. `@list` arrays become rdf:first/rdf:rest/rdf:nil chains and
`"@type": "@json"` values become rdf:JSON literals. Prefix mappings found in
the top-level `@context` are bound on the graph for round-tripping.

# Keyword arguments
- `base`: base IRI used to resolve relative IRIs.
- `context_loader`: function called with a URL when a remote `@context` is
  referenced (defaults to an HTTP loader; inject a custom one for tests).
"""
function parse_jsonld!(g::RDFGraph, input::AbstractString;
                       base=nothing, context_loader=_jsonld_default_loader)
    doc = _parse_json(input)
    _jsonld_bind_prefixes!(g, doc)
    nodes = jsonld_expand(doc; base=base, context_loader=context_loader)
    for n in nodes
        _jsonld_node_to_rdf!(g, n)
    end
    g
end

"""
    parse_jsonld(source; kwargs...) -> RDFGraph

Parse JSON-LD from a string or IO stream into a new graph.
"""
function parse_jsonld(source; kwargs...)
    g = RDFGraph()
    if source isa IO || source isa IOBuffer
        parse_jsonld!(g, source; kwargs...)
    else
        parse_jsonld!(g, String(source); kwargs...)
    end
end

"""Bind namespace-like prefix mappings from the document's top-level @context."""
function _jsonld_bind_prefixes!(g::RDFGraph, doc)
    doc isa AbstractDict || return
    ctx = get(doc, "@context", nothing)
    for item in (ctx isa AbstractVector ? ctx : Any[ctx])
        item isa AbstractDict || continue
        for (k, v) in item
            key = String(k)
            (startswith(key, "@") || isempty(key)) && continue
            v isa AbstractString || continue
            uri = String(v)
            isempty(uri) && continue
            # Only bind mappings that look like namespaces
            uri[end] in ('/', '#', ':') && bind!(g, key, Namespace(uri))
        end
    end
    return
end

"""Convert an expanded node object to triples; returns the node's subject."""
function _jsonld_node_to_rdf!(g::RDFGraph, node::AbstractDict)::Union{Identifier, Nothing}
    haskey(node, "@value") && return _jsonld_value_to_literal(node)
    haskey(node, "@list") && return _jsonld_list_to_rdf!(g, node["@list"])
    id = get(node, "@id", nothing)
    subject = if id === nothing
        BNode()
    elseif startswith(id, "_:")
        BNode(id[3:end])
    else
        URIRef(String(id))
    end

    for key in sort!(collect(String.(keys(node))))
        key == "@id" && continue
        val = node[key]
        if key == "@type"
            for t in (val isa AbstractVector ? val : Any[val])
                t isa AbstractString || continue
                obj = startswith(t, "_:") ? BNode(t[3:end]) : URIRef(String(t))
                add!(g, Triple(subject, URIRef(_JLD_RDF_TYPE), obj))
            end
        elseif key == "@reverse"
            for (rprop, rvals) in val
                rp = String(rprop)
                startswith(rp, "@") && continue
                pred = URIRef(rp)
                for rv in (rvals isa AbstractVector ? rvals : Any[rvals])
                    o = _jsonld_object_to_rdf!(g, rv)
                    o isa Union{URIRef, BNode} || continue   # literals cannot be subjects
                    add!(g, Triple(o, pred, subject))
                end
            end
        elseif key == "@graph"
            # Named graph semantics are not supported; merge into this graph
            for n in (val isa AbstractVector ? val : Any[val])
                n isa AbstractDict && _jsonld_node_to_rdf!(g, n)
            end
        elseif startswith(key, "@")
            continue   # @index and other non-RDF keywords are dropped
        else
            pred = URIRef(key)
            for v in (val isa AbstractVector ? val : Any[val])
                o = _jsonld_object_to_rdf!(g, v)
                o === nothing && continue
                add!(g, Triple(subject, pred, o))
            end
        end
    end
    subject
end

"""Convert an expanded object value (value/list/node object) to an RDF term."""
function _jsonld_object_to_rdf!(g::RDFGraph, v)::Union{Identifier, Nothing}
    if v isa AbstractDict
        haskey(v, "@value") && return _jsonld_value_to_literal(v)
        haskey(v, "@list") && return _jsonld_list_to_rdf!(g, v["@list"])
        return _jsonld_node_to_rdf!(g, v)
    elseif v isa AbstractString
        return Literal(String(v))
    elseif v isa Bool
        return Literal(v)
    elseif v isa Integer
        return Literal(v)
    elseif v isa AbstractFloat
        return Literal(v)
    end
    nothing
end

"""Convert an @list array to an rdf:first/rdf:rest/rdf:nil chain."""
function _jsonld_list_to_rdf!(g::RDFGraph, items)::Identifier
    arr = items isa AbstractVector ? items : Any[items]
    objs = Identifier[]
    for item in arr
        o = _jsonld_object_to_rdf!(g, item)
        o === nothing || push!(objs, o)
    end
    isempty(objs) && return URIRef(_JLD_RDF_NIL)
    head = BNode()
    cur = head
    for (i, o) in enumerate(objs)
        add!(g, Triple(cur, URIRef(_JLD_RDF_FIRST), o))
        nxt = i == length(objs) ? URIRef(_JLD_RDF_NIL) : BNode()
        add!(g, Triple(cur, URIRef(_JLD_RDF_REST), nxt))
        nxt isa BNode && (cur = nxt)
    end
    head
end

_jsonld_lexical(v) = v isa Bool ? (v ? "true" : "false") : string(v)

"""Convert an expanded value object to a Literal."""
function _jsonld_value_to_literal(v::AbstractDict)::Union{Literal, Nothing}
    val = get(v, "@value", nothing)
    val === nothing && return nothing
    t = get(v, "@type", nothing)
    lang = get(v, "@language", nothing)
    dir = get(v, "@direction", nothing)
    if t == "@json" || t == _JLD_RDF_JSON
        # Preserve the exact lexical form when it is already a string typed
        # rdf:JSON; otherwise serialize the JSON value (no JCS canonicalization)
        if t == _JLD_RDF_JSON && val isa AbstractString
            return Literal(String(val), datatype=URIRef(_JLD_RDF_JSON))
        end
        return Literal(JSON3.write(val), datatype=URIRef(_JLD_RDF_JSON))
    end
    if lang !== nothing
        d = dir isa AbstractString && dir in ("ltr", "rtl") ? dir : nothing
        return Literal(_jsonld_lexical(val), lang=String(lang), direction=d)
    end
    if t isa AbstractString && !startswith(t, "@")
        return Literal(_jsonld_lexical(val), datatype=URIRef(String(t)))
    end
    val isa Bool && return Literal(val)
    val isa Integer && return Literal(val)
    val isa AbstractFloat && return Literal(val)
    val isa AbstractString && return Literal(String(val))
    Literal(string(val))
end

# ─── Register with high-level API ──────────────────────────────────

serialize(io::IO, g::RDFGraph, ::JSONLDFormat) = serialize_jsonld(io, g)
parse_rdf!(g::RDFGraph, source, ::JSONLDFormat) = parse_jsonld!(g, source)
