# ─── RDF/XML Format ─────────────────────────────────────────────────
# XML-based RDF serialization using EzXML

const _RDF_NS = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
const _XML_NS = "http://www.w3.org/XML/1998/namespace"

# ─── Serialization ──────────────────────────────────────────────────

"""
    serialize_rdfxml(io::IO, g::RDFGraph)

Serialize a graph as RDF/XML to an IO stream.
"""
function serialize_rdfxml(io::IO, g::RDFGraph)
    doc = EzXML.XMLDocument("1.0")
    rdf_root = EzXML.ElementNode("rdf:RDF")
    EzXML.setroot!(doc, rdf_root)

    # Collect all namespaces
    nsm = g.namespace_manager
    ns_map = Dict{String,String}()
    ns_map["rdf"] = _RDF_NS
    for (prefix, uri) in namespaces(nsm)
        ns_map[prefix] = uri
    end
    # Discover additional namespaces from predicates
    for t in g
        _rdfxml_discover_ns!(ns_map, nsm, t.predicate)
        t.object isa URIRef && _rdfxml_discover_ns!(ns_map, nsm, t.object)
    end

    # Set xmlns attributes on root
    for (prefix, uri) in sort(collect(ns_map), by=first)
        if prefix == ""
            EzXML.link!(rdf_root, EzXML.AttributeNode("xmlns", uri))
        else
            EzXML.link!(rdf_root, EzXML.AttributeNode("xmlns:$prefix", uri))
        end
    end

    # Group triples by subject
    subject_triples = Dict{Node, Vector{Triple}}()
    for t in g
        push!(get!(subject_triples, t.subject, Triple[]), t)
    end

    # Serialize each subject as rdf:Description
    for subject in sort(collect(keys(subject_triples)), by=s -> string(s))
        desc = EzXML.ElementNode("rdf:Description")
        if subject isa URIRef
            EzXML.link!(desc, EzXML.AttributeNode("rdf:about", subject.value))
        elseif subject isa BNode
            EzXML.link!(desc, EzXML.AttributeNode("rdf:nodeID", subject.id))
        end

        for t in subject_triples[subject]
            pred_elem = _rdfxml_predicate_element(nsm, ns_map, t.predicate)
            _rdfxml_set_object!(pred_elem, t.object)
            EzXML.link!(desc, pred_elem)
        end

        EzXML.link!(rdf_root, desc)
    end

    # Write with indentation
    print(io, _rdfxml_pretty_print(doc))
end

function _rdfxml_discover_ns!(ns_map, nsm, uri::URIRef)
    try
        prefix, ns_uri, _ = compute_qname(nsm, uri)
        ns_map[prefix] = ns_uri
    catch; end
end

function _rdfxml_predicate_element(nsm, ns_map, pred::URIRef)
    try
        prefix, _, localname = compute_qname(nsm, pred)
        return EzXML.ElementNode("$prefix:$localname")
    catch
        # Fallback: use full URI in a generated namespace
        return EzXML.ElementNode("ns:$(fragment(pred))")
    end
end

function _rdfxml_set_object!(elem, obj::URIRef)
    EzXML.link!(elem, EzXML.AttributeNode("rdf:resource", obj.value))
end

function _rdfxml_set_object!(elem, obj::BNode)
    EzXML.link!(elem, EzXML.AttributeNode("rdf:nodeID", obj.id))
end

function _rdfxml_set_object!(elem, obj::Literal)
    if !isnothing(obj.language)
        EzXML.link!(elem, EzXML.AttributeNode("xml:lang", obj.language))
    elseif !isnothing(obj.datatype) && obj.datatype.value != "http://www.w3.org/2001/XMLSchema#string"
        EzXML.link!(elem, EzXML.AttributeNode("rdf:datatype", obj.datatype.value))
    end
    EzXML.link!(elem, EzXML.TextNode(obj.lexical))
end

function _rdfxml_pretty_print(doc::EzXML.Document)
    buf = IOBuffer()
    print(buf, doc)
    raw = String(take!(buf))
    # EzXML doesn't indent by default; do basic formatting
    raw = replace(raw, "><" => ">\n<")
    lines = split(raw, '\n')
    result = IOBuffer()
    indent = 0
    for line in lines
        stripped = strip(line)
        isempty(stripped) && continue
        if startswith(stripped, "</")
            indent = max(0, indent - 1)
        end
        println(result, "  " ^ indent, stripped)
        if startswith(stripped, "<") && !startswith(stripped, "</") &&
           !startswith(stripped, "<?") && !endswith(stripped, "/>") &&
           !contains(stripped, "</")
            indent += 1
        end
    end
    String(take!(result))
end

"""
    serialize_rdfxml(g::RDFGraph) -> String

Serialize a graph to an RDF/XML string.
"""
function serialize_rdfxml(g::RDFGraph)
    buf = IOBuffer()
    serialize_rdfxml(buf, g)
    String(take!(buf))
end

# ─── Parsing ────────────────────────────────────────────────────────

"""
    parse_rdfxml!(g::RDFGraph, io::IO) -> RDFGraph

Parse RDF/XML from an IO stream and add triples to the graph.
"""
function parse_rdfxml!(g::RDFGraph, io::IO)
    data = read(io, String)
    parse_rdfxml!(g, data)
end

"""
    parse_rdfxml!(g::RDFGraph, input::AbstractString) -> RDFGraph

Parse RDF/XML from a string and add triples to the graph.
"""
function parse_rdfxml!(g::RDFGraph, input::AbstractString)
    doc = EzXML.parsexml(input)
    root = EzXML.root(doc)

    # Check for rdf:RDF root or direct descriptions
    rootname = EzXML.nodename(root)
    if rootname == "RDF" || endswith(rootname, ":RDF")
        for child in EzXML.eachelement(root)
            _parse_rdfxml_node_element!(g, child, root)
        end
    else
        _parse_rdfxml_node_element!(g, root, root)
    end

    g
end

"""
    parse_rdfxml(source) -> RDFGraph

Parse RDF/XML from a string or IO stream into a new graph.
"""
function parse_rdfxml(source)
    g = RDFGraph()
    if source isa IO || source isa IOBuffer
        parse_rdfxml!(g, source)
    else
        parse_rdfxml!(g, String(source))
    end
end

function _parse_rdfxml_node_element!(g::RDFGraph, elem::EzXML.Node, root::EzXML.Node)
    # Determine subject
    subject = _rdfxml_get_subject(elem)

    # If element is not rdf:Description, add rdf:type triple
    elemname = EzXML.nodename(elem)
    localname = contains(elemname, ':') ? split(elemname, ':')[2] : elemname
    ns = _rdfxml_element_ns(elem)

    if localname != "Description" || ns != _RDF_NS
        if !isempty(ns)
            add!(g, Triple(subject, URIRef(_RDF_NS * "type"), URIRef(ns * localname)))
        end
    end

    # Process attribute properties (non-rdf: attributes become triples)
    for attr in EzXML.eachattribute(elem)
        aname = EzXML.nodename(attr)
        aval = EzXML.nodecontent(attr)
        _rdfxml_handle_attribute!(g, subject, aname, aval, elem)
    end

    # Process child property elements
    for child in EzXML.eachelement(elem)
        _parse_rdfxml_property_element!(g, subject, child, root)
    end
end

function _rdfxml_get_subject(elem::EzXML.Node)
    # Check rdf:about
    for attr in EzXML.eachattribute(elem)
        aname = EzXML.nodename(attr)
        if aname == "rdf:about" || aname == "about"
            return URIRef(EzXML.nodecontent(attr))
        elseif aname == "rdf:ID" || aname == "ID"
            return URIRef("#" * EzXML.nodecontent(attr))
        elseif aname == "rdf:nodeID" || aname == "nodeID"
            return BNode(EzXML.nodecontent(attr))
        end
    end
    # Anonymous subject
    BNode()
end

function _rdfxml_element_ns(elem::EzXML.Node)
    try
        return EzXML.namespace(elem)
    catch
        return ""
    end
end

function _rdfxml_handle_attribute!(g::RDFGraph, subject::Node, aname::String, aval::String, elem::EzXML.Node)
    # Skip rdf: and xml: control attributes
    startswith(aname, "rdf:") && return
    startswith(aname, "xml") && return
    startswith(aname, "xmlns") && return
    aname == "about" && return
    aname == "nodeID" && return
    aname == "ID" && return

    # Attribute is a property with literal value
    pred_uri = _rdfxml_resolve_attr_name(aname, elem)
    !isnothing(pred_uri) && add!(g, Triple(subject, pred_uri, Literal(aval)))
end

function _rdfxml_resolve_attr_name(aname::String, elem::EzXML.Node)
    if contains(aname, ':')
        prefix, localname = split(aname, ':', limit=2)
        try
            ns = _rdfxml_find_ns_for_prefix(elem, String(prefix))
            return URIRef(ns * localname)
        catch
            return nothing
        end
    end
    nothing
end

function _rdfxml_find_ns_for_prefix(elem::EzXML.Node, prefix::String)
    # Walk up the tree looking for xmlns:prefix declarations
    node = elem
    while !isnothing(node) && EzXML.iselement(node)
        for attr in EzXML.eachattribute(node)
            aname = EzXML.nodename(attr)
            if aname == "xmlns:$prefix"
                return EzXML.nodecontent(attr)
            end
        end
        node = EzXML.parentnode(node)
    end
    throw(ArgumentError("Unknown prefix: $prefix"))
end

function _parse_rdfxml_property_element!(g::RDFGraph, subject::Node, elem::EzXML.Node, root::EzXML.Node)
    # Determine predicate from element name
    ns = _rdfxml_element_ns(elem)
    localname = EzXML.nodename(elem)
    if contains(localname, ':')
        localname = split(localname, ':')[2]
    end
    predicate = URIRef(ns * localname)

    # Check for rdf:resource attribute (URI object)
    for attr in EzXML.eachattribute(elem)
        aname = EzXML.nodename(attr)
        if aname == "rdf:resource" || aname == "resource"
            add!(g, Triple(subject, predicate, URIRef(EzXML.nodecontent(attr))))
            return
        elseif aname == "rdf:nodeID" || aname == "nodeID"
            add!(g, Triple(subject, predicate, BNode(EzXML.nodecontent(attr))))
            return
        end
    end

    # Check for rdf:parseType
    parse_type = nothing
    for attr in EzXML.eachattribute(elem)
        aname = EzXML.nodename(attr)
        if aname == "rdf:parseType" || aname == "parseType"
            parse_type = EzXML.nodecontent(attr)
        end
    end

    if parse_type == "Resource"
        bnode = BNode()
        add!(g, Triple(subject, predicate, bnode))
        for child in EzXML.eachelement(elem)
            _parse_rdfxml_property_element!(g, bnode, child, root)
        end
        return
    elseif parse_type == "Collection"
        _parse_rdfxml_collection!(g, subject, predicate, elem, root)
        return
    end

    # Check for child elements (nested node)
    children = collect(EzXML.eachelement(elem))
    if !isempty(children)
        child = children[1]
        _parse_rdfxml_node_element!(g, child, root)
        obj = _rdfxml_get_subject(child)
        add!(g, Triple(subject, predicate, obj))
        return
    end

    # Text content → Literal
    text = strip(EzXML.nodecontent(elem))
    lang_val = nothing
    dt_val = nothing
    for attr in EzXML.eachattribute(elem)
        aname = EzXML.nodename(attr)
        if aname == "xml:lang"
            lang_val = EzXML.nodecontent(attr)
        elseif aname == "rdf:datatype" || aname == "datatype"
            dt_val = URIRef(EzXML.nodecontent(attr))
        end
    end

    lit = if !isnothing(lang_val)
        Literal(text, lang=lang_val)
    elseif !isnothing(dt_val)
        Literal(text, datatype=dt_val)
    else
        Literal(text)
    end
    add!(g, Triple(subject, predicate, lit))
end

function _parse_rdfxml_collection!(g::RDFGraph, subject::Node, predicate::URIRef, elem::EzXML.Node, root::EzXML.Node)
    rdf_first = URIRef(_RDF_NS * "first")
    rdf_rest = URIRef(_RDF_NS * "rest")
    rdf_nil = URIRef(_RDF_NS * "nil")

    children = collect(EzXML.eachelement(elem))
    if isempty(children)
        add!(g, Triple(subject, predicate, rdf_nil))
        return
    end

    head = BNode()
    add!(g, Triple(subject, predicate, head))
    current = head

    for (i, child) in enumerate(children)
        _parse_rdfxml_node_element!(g, child, root)
        item = _rdfxml_get_subject(child)
        add!(g, Triple(current, rdf_first, item))

        if i < length(children)
            next_node = BNode()
            add!(g, Triple(current, rdf_rest, next_node))
            current = next_node
        else
            add!(g, Triple(current, rdf_rest, rdf_nil))
        end
    end
end

# ─── Register with high-level API ──────────────────────────────────

serialize(io::IO, g::RDFGraph, ::RDFXMLFormat) = serialize_rdfxml(io, g)
parse_rdf!(g::RDFGraph, source, ::RDFXMLFormat) = parse_rdfxml!(g, source)
