# ─── JSON-LD Format ─────────────────────────────────────────────────
# JSON-based RDF serialization using JSON3

# ─── Serialization ──────────────────────────────────────────────────

"""
    serialize_jsonld(io::IO, g::RDFGraph)

Serialize a graph as JSON-LD to an IO stream.
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

    # Group triples by subject
    subject_map = Dict{String, Dict{String, Any}}()
    for t in g
        sid = _jsonld_subject_id(t.subject)
        node = get!(subject_map, sid, Dict{String, Any}("@id" => sid))
        pid = _jsonld_predicate_key(t.predicate, g.namespace_manager, context)
        oval = if pid == "@type" && t.object isa URIRef
            t.object.value  # @type values are plain URI strings
        else
            _jsonld_object_value(t.object, g.namespace_manager, context)
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

function _jsonld_subject_id(s::URIRef)
    s.value
end

function _jsonld_subject_id(s::BNode)
    "_:" * s.id
end

function _jsonld_predicate_key(p::URIRef, nsm::NamespaceManager, context::Dict)
    rdf_type = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
    p.value == rdf_type && return "@type"
    # Try compact URI
    try
        prefix, _, localname = compute_qname(nsm, p)
        if haskey(context, prefix)
            return "$prefix:$localname"
        end
    catch; end
    p.value
end

function _jsonld_object_value(o::URIRef, nsm::NamespaceManager, context::Dict)
    # For rdf:type values, return just the URI
    return Dict{String, Any}("@id" => o.value)
end

function _jsonld_object_value(o::BNode, ::NamespaceManager, ::Dict)
    Dict{String, Any}("@id" => "_:" * o.id)
end

function _jsonld_object_value(o::Literal, ::NamespaceManager, ::Dict)
    if !isnothing(o.language)
        return Dict{String, Any}("@value" => o.lexical, "@language" => o.language)
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
        return Dict{String, Any}("@value" => o.lexical, "@type" => dt)
    else
        return o.lexical
    end
end

# ─── Parsing ────────────────────────────────────────────────────────

"""
    parse_jsonld!(g::RDFGraph, io::IO) -> RDFGraph

Parse JSON-LD from an IO stream and add triples to the graph.
"""
function parse_jsonld!(g::RDFGraph, io::IO)
    data = read(io, String)
    parse_jsonld!(g, data)
end

"""
    parse_jsonld!(g::RDFGraph, input::AbstractString) -> RDFGraph

Parse JSON-LD from a string and add triples to the graph.
"""
function parse_jsonld!(g::RDFGraph, input::AbstractString)
    raw = JSON3.read(input)
    if raw isa JSON3.Array
        # Top-level array: treat each element as a node document
        for item in raw
            if item isa JSON3.Object
                data = _json3_to_dict(item)
                _jsonld_parse_doc!(g, data)
            end
        end
    else
        data = JSON3.read(input, Dict{String, Any})
        _jsonld_parse_doc!(g, data)
    end
    g
end

function _json3_to_dict(obj)::Dict{String, Any}
    d = Dict{String, Any}()
    for (k, v) in pairs(obj)
        key = string(k)
        if v isa JSON3.Object
            d[key] = _json3_to_dict(v)
        elseif v isa JSON3.Array
            d[key] = Any[x isa JSON3.Object ? _json3_to_dict(x) : x for x in v]
        else
            d[key] = v
        end
    end
    d
end

"""
    parse_jsonld(source) -> RDFGraph

Parse JSON-LD from a string or IO stream into a new graph.
"""
function parse_jsonld(source)
    g = RDFGraph()
    if source isa IO || source isa IOBuffer
        parse_jsonld!(g, source)
    else
        parse_jsonld!(g, String(source))
    end
end

function _jsonld_parse_doc!(g::RDFGraph, data::Dict{String, Any})
    # Process @context
    context = get(data, "@context", Dict{String, Any}())
    if context isa Dict
        for (prefix, uri) in context
            if uri isa String
                bind!(g, prefix, Namespace(uri))
            end
        end
    end

    # Process @graph or single node
    if haskey(data, "@graph")
        graph_data = data["@graph"]
        if graph_data isa Vector
            for node in graph_data
                node isa Dict && _jsonld_parse_node!(g, node, context)
            end
        end
    else
        _jsonld_parse_node!(g, data, context)
    end
end

function _jsonld_parse_node!(g::RDFGraph, node::Dict{String, Any}, context)
    # Get subject
    id = get(node, "@id", nothing)
    subject = if isnothing(id)
        BNode()
    elseif startswith(id, "_:")
        BNode(id[3:end])
    else
        URIRef(_jsonld_expand_uri(id, context))
    end

    for (key, val) in node
        startswith(key, "@") && key != "@type" && continue

        if key == "@type"
            # @type values are URIs
            types = val isa Vector ? val : [val]
            for t in types
                if t isa String
                    type_uri = URIRef(_jsonld_expand_uri(t, context))
                    add!(g, Triple(subject, URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"), type_uri))
                end
            end
        else
            predicate = URIRef(_jsonld_expand_uri(key, context))
            values = val isa Vector ? val : [val]
            for v in values
                obj = _jsonld_parse_value(v, context)
                !isnothing(obj) && add!(g, Triple(subject, predicate, obj))
            end
        end
    end
end

function _jsonld_parse_value(val, context)::Union{Identifier, Nothing}
    if val isa Dict
        if haskey(val, "@id")
            id = val["@id"]
            if startswith(id, "_:")
                return BNode(id[3:end])
            else
                return URIRef(_jsonld_expand_uri(id, context))
            end
        elseif haskey(val, "@value")
            v = val["@value"]
            lexical = string(v)
            lang_val = get(val, "@language", nothing)
            type_val = get(val, "@type", nothing)
            if !isnothing(lang_val)
                return Literal(lexical, lang=lang_val)
            elseif !isnothing(type_val)
                return Literal(lexical, datatype=URIRef(_jsonld_expand_uri(type_val, context)))
            else
                return Literal(lexical)
            end
        else
            # Nested node — create blank node
            g_temp = RDFGraph()
            _jsonld_parse_node!(g_temp, val, context)
            return nothing  # Simplified: skip nested for now
        end
    elseif val isa String
        return Literal(val)
    elseif val isa Integer
        return Literal(val)
    elseif val isa AbstractFloat
        return Literal(val)
    elseif val isa Bool
        return Literal(val)
    end
    nothing
end

function _jsonld_expand_uri(uri::AbstractString, context)
    # Already absolute
    contains(uri, "://") && return uri
    startswith(uri, "urn:") && return uri

    # Try prefix expansion
    idx = findfirst(':', uri)
    if !isnothing(idx)
        prefix = uri[1:idx-1]
        localname = uri[idx+1:end]
        if context isa Dict
            ns = get(context, prefix, nothing)
            if !isnothing(ns) && ns isa String
                return ns * localname
            end
        end
    end
    uri
end

# ─── Register with high-level API ──────────────────────────────────

serialize(io::IO, g::RDFGraph, ::JSONLDFormat) = serialize_jsonld(io, g)
parse_rdf!(g::RDFGraph, source, ::JSONLDFormat) = parse_jsonld!(g, source)
