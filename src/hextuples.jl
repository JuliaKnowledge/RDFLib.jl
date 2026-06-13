# ─── Hextuples Format ─────────────────────────────────────────────────
# Line-based format: each line is a JSON array of 6 strings:
#   [subject, predicate, object_value, datatype, language, graph]

import JSON

const _HT_XSD = "http://www.w3.org/2001/XMLSchema#"
const _HT_GLOBALID = "globalId"
const _HT_LOCALID = "localId"
const _RDF_LANGSTRING = "http://www.w3.org/1999/02/22-rdf-syntax-ns#langString"

# ─── Serialization ──────────────────────────────────────────────────

"""
    serialize_hextuples(g::RDFGraph) -> String

Serialize a graph to Hextuples format (default graph).
"""
function serialize_hextuples(g::RDFGraph)
    buf = IOBuffer()
    for t in g
        _write_hextuple_line(buf, t, nothing)
    end
    String(take!(buf))
end

"""
    serialize_hextuples(ds::Dataset) -> String

Serialize a dataset to Hextuples format.
"""
function serialize_hextuples(ds::Dataset)
    buf = IOBuffer()
    for q in quads(ds)
        _write_hextuple_line(buf, Triple(q), q.graph)
    end
    String(take!(buf))
end

function _write_hextuple_line(io::IO, t::Triple, graph_name::Union{URIRef, BNode, Nothing})
    subj_str = t.subject isa URIRef ? t.subject.value : ("_:" * t.subject.id)
    pred_str = t.predicate.value
    obj_val, dt, lang_tag = _hextuple_object(t.object)
    graph_str = graph_name isa URIRef ? graph_name.value :
                graph_name isa BNode ? ("_:" * graph_name.id) : ""
    line = JSON.json([subj_str, pred_str, obj_val, dt, lang_tag, graph_str])
    write(io, line, "\n")
end

function _hextuple_object(u::URIRef)
    (u.value, _HT_GLOBALID, "")
end

function _hextuple_object(b::BNode)
    ("_:" * b.id, _HT_LOCALID, "")
end

function _hextuple_object(lit::Literal)
    if !isnothing(lit.language)
        return (lit.lexical, _RDF_LANGSTRING, lit.language)
    elseif !isnothing(lit.datatype)
        return (lit.lexical, lit.datatype.value, "")
    else
        return (lit.lexical, _HT_XSD * "string", "")
    end
end

# ─── Parsing ────────────────────────────────────────────────────────

"""
    parse_hextuples(str::AbstractString) -> Dataset

Parse a Hextuples string into a Dataset.
"""
function parse_hextuples(str::AbstractString)
    ds = Dataset()
    for line in split(str, '\n')
        stripped = strip(line)
        isempty(stripped) && continue
        arr = JSON.parse(stripped)
        length(arr) == 6 || throw(ArgumentError("Hextuple line must have 6 elements, got $(length(arr))"))
        subj = _parse_ht_node(arr[1])
        pred = URIRef(arr[2])
        obj = _parse_ht_object(arr[3], arr[4], arr[5])
        graph_name = isempty(arr[6]) ? nothing :
                     startswith(arr[6], "_:") ? BNode(arr[6][3:end]) : URIRef(arr[6])
        add!(ds, Triple(subj, pred, obj), graph_name)
    end
    ds
end

"""
    parse_hextuples!(g::RDFGraph, str::AbstractString)

Parse Hextuples and add default graph triples to `g`.
"""
function parse_hextuples!(g::RDFGraph, str::AbstractString)
    ds = parse_hextuples(str)
    default_g = get_graph(ds)
    if !isnothing(default_g)
        for t in default_g
            add!(g, t)
        end
    end
    g
end

function _parse_ht_node(s::AbstractString)
    if startswith(s, "_:")
        BNode(s[3:end])
    else
        URIRef(s)
    end
end

function _parse_ht_object(value::AbstractString, datatype::AbstractString, lang::AbstractString)
    if datatype == _HT_GLOBALID
        return URIRef(value)
    elseif datatype == _HT_LOCALID
        bnode_id = startswith(value, "_:") ? value[3:end] : value
        return BNode(bnode_id)
    elseif datatype == _RDF_LANGSTRING && !isempty(lang)
        return Literal(value, lang=lang)
    else
        return Literal(value, datatype=URIRef(datatype))
    end
end
