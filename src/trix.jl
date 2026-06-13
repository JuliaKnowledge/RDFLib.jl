# ─── TriX Format ──────────────────────────────────────────────────────
# XML-based format for serializing RDF datasets (multiple named graphs).
# Spec: http://www.w3.org/2004/03/trix/trix-1/

import XML

const _TRIX_NS = "http://www.w3.org/2004/03/trix/trix-1/"

# ─── Serialization ──────────────────────────────────────────────────

"""
    serialize_trix(ds::Dataset) -> String

Serialize a Dataset as TriX XML.
"""
function serialize_trix(ds::Dataset)
    buf = IOBuffer()
    write(buf, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n")
    write(buf, "<TriX xmlns=\"$(_TRIX_NS)\">\n")
    for (name, g) in graphs(ds)
        _write_trix_graph(buf, g, name)
    end
    write(buf, "</TriX>\n")
    String(take!(buf))
end

"""
    serialize_trix(g::RDFGraph) -> String

Serialize a single RDFGraph as TriX XML (as default graph in a dataset).
"""
function serialize_trix(g::RDFGraph)
    ds = Dataset()
    for t in g
        add!(ds, t)
    end
    serialize_trix(ds)
end

function _write_trix_graph(io::IO, g::RDFGraph, name::Union{URIRef, BNode, Nothing})
    write(io, "  <graph>\n")
    if name isa URIRef
        write(io, "    <uri>", _xml_escape(name.value), "</uri>\n")
    elseif name isa BNode
        write(io, "    <id>", _xml_escape(name.id), "</id>\n")
    end
    for t in g
        write(io, "    <triple>\n")
        write(io, "      ", _trix_term(t.subject), "\n")
        write(io, "      ", _trix_term(t.predicate), "\n")
        write(io, "      ", _trix_term(t.object), "\n")
        write(io, "    </triple>\n")
    end
    write(io, "  </graph>\n")
end

function _trix_term(u::URIRef)
    "<uri>$(_xml_escape(u.value))</uri>"
end

function _trix_term(b::BNode)
    "<id>$(_xml_escape(b.id))</id>"
end

function _trix_term(lit::Literal)
    if !isnothing(lit.language)
        "<plainLiteral xml:lang=\"$(_xml_escape(lit.language))\">$(_xml_escape(lit.lexical))</plainLiteral>"
    elseif !isnothing(lit.datatype)
        "<typedLiteral datatype=\"$(_xml_escape(lit.datatype.value))\">$(_xml_escape(lit.lexical))</typedLiteral>"
    else
        "<plainLiteral>$(_xml_escape(lit.lexical))</plainLiteral>"
    end
end

function _xml_escape(s::AbstractString)
    s = replace(s, "&" => "&amp;")
    s = replace(s, "<" => "&lt;")
    s = replace(s, ">" => "&gt;")
    s = replace(s, "\"" => "&quot;")
    s
end

# ─── Parsing ────────────────────────────────────────────────────────

"""
    parse_trix(str::AbstractString) -> Dataset

Parse a TriX XML string into a Dataset.
"""
function parse_trix(str::AbstractString)
    ds = Dataset()
    doc = XML.parse(str, XML.Node)
    trix_el = _find_element(doc, "TriX")
    isnothing(trix_el) && return ds
    for graph_el in XML.children(trix_el)
        XML.nodetype(graph_el) != XML.Element && continue
        XML.tag(graph_el) == "graph" || continue
        graph_name = nothing
        triples_list = Triple[]
        first_uri_is_name = true
        for child in XML.children(graph_el)
            XML.nodetype(child) != XML.Element && continue
            tag = XML.tag(child)
            if tag == "uri" && first_uri_is_name
                graph_name = URIRef(_element_text(child))
                first_uri_is_name = false
            elseif tag == "id" && first_uri_is_name
                graph_name = BNode(_element_text(child))
                first_uri_is_name = false
            elseif tag == "triple"
                first_uri_is_name = false
                push!(triples_list, _parse_trix_triple(child))
            end
        end
        for t in triples_list
            add!(ds, t, graph_name)
        end
    end
    ds
end

"""
    parse_trix!(g::RDFGraph, str::AbstractString)

Parse a TriX XML string and add the default graph's triples to `g`.
"""
function parse_trix!(g::RDFGraph, str::AbstractString)
    ds = parse_trix(str)
    default_g = get_graph(ds)
    if !isnothing(default_g)
        for t in default_g
            add!(g, t)
        end
    end
    g
end

function _parse_trix_triple(triple_el)
    terms = Identifier[]
    for child in XML.children(triple_el)
        XML.nodetype(child) != XML.Element && continue
        push!(terms, _parse_trix_term(child))
    end
    length(terms) == 3 || throw(ArgumentError("TriX <triple> must have exactly 3 terms, got $(length(terms))"))
    subj = terms[1]
    subj isa Node || throw(ArgumentError("TriX subject must be a URI or blank node"))
    pred = terms[2]
    pred isa URIRef || throw(ArgumentError("TriX predicate must be a URI"))
    Triple(subj, pred, terms[3])
end

function _parse_trix_term(el)
    tag = XML.tag(el)
    text = _element_text(el)
    attrs = XML.attributes(el)
    if tag == "uri"
        return URIRef(text)
    elseif tag == "id"
        return BNode(text)
    elseif tag == "plainLiteral"
        lang_val = isnothing(attrs) ? nothing : get(attrs, "xml:lang", nothing)
        if !isnothing(lang_val) && !isempty(lang_val)
            return Literal(text, lang=lang_val)
        else
            return Literal(text)
        end
    elseif tag == "typedLiteral"
        dt = isnothing(attrs) ? nothing : get(attrs, "datatype", nothing)
        isnothing(dt) && throw(ArgumentError("typedLiteral missing datatype attribute"))
        return Literal(text, datatype=URIRef(dt))
    else
        throw(ArgumentError("Unknown TriX term element: $tag"))
    end
end

function _find_element(node, tag_name::String)
    for c in XML.children(node)
        XML.nodetype(c) == XML.Element || continue
        XML.tag(c) == tag_name && return c
    end
    nothing
end

function _element_text(el)
    buf = IOBuffer()
    for c in XML.children(el)
        if XML.nodetype(c) == XML.Text
            write(buf, XML.value(c))
        end
    end
    _xml_unescape(String(take!(buf)))
end

function _xml_unescape(s::AbstractString)
    s = replace(s, "&lt;" => "<")
    s = replace(s, "&gt;" => ">")
    s = replace(s, "&quot;" => "\"")
    s = replace(s, "&amp;" => "&")
    s
end
