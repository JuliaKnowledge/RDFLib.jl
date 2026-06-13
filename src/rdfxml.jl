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
        return
    catch; end
    # compute_qname failed (URI without '#' or '/'): split manually and
    # register a generated prefix so the namespace is declared on the root.
    ns_uri, localname = _rdfxml_split_uri(uri.value)
    (isempty(ns_uri) || isempty(localname)) && return
    # Already declared under some non-empty prefix?
    for (p, u) in ns_map
        (u == ns_uri && !isempty(p)) && return
    end
    ns_map[_rdfxml_gen_prefix(ns_map)] = ns_uri
end

# Split a URI into (namespace, localname) at the last '#', '/', or ':'.
function _rdfxml_split_uri(uristr::AbstractString)
    for sep in ('#', '/', ':')
        idx = findlast(sep, uristr)
        if !isnothing(idx) && idx < lastindex(uristr)
            localname = uristr[nextind(uristr, idx):end]
            # Localname must be usable as an XML name part
            if !contains(localname, '/') && !contains(localname, '#') && !contains(localname, ':')
                return (uristr[1:idx], localname)
            end
        end
    end
    ("", String(uristr))
end

function _rdfxml_gen_prefix(ns_map)
    i = 1
    while haskey(ns_map, "ns$i")
        i += 1
    end
    "ns$i"
end

function _rdfxml_predicate_element(nsm, ns_map, pred::URIRef)
    try
        prefix, _, localname = compute_qname(nsm, pred)
        if !isempty(localname)
            # Empty prefix means the default namespace, declared as xmlns=...
            return isempty(prefix) ? EzXML.ElementNode(localname) :
                                     EzXML.ElementNode("$prefix:$localname")
        end
    catch; end
    # Fallback: look up the generated prefix registered by _rdfxml_discover_ns!
    ns_uri, localname = _rdfxml_split_uri(pred.value)
    if !isempty(ns_uri) && !isempty(localname)
        for (p, u) in ns_map
            if u == ns_uri && !isempty(p)
                return EzXML.ElementNode("$p:$localname")
            end
        end
    end
    throw(ArgumentError("Cannot serialize predicate as an XML QName: $(pred.value)"))
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
    parse_rdfxml!(g::RDFGraph, io::IO; base=nothing) -> RDFGraph

Parse RDF/XML from an IO stream and add triples to the graph.
`base` provides an outermost base IRI used to resolve relative
`rdf:about`/`rdf:resource` IRIs and `rdf:ID` fragments; it can be
overridden by `xml:base` attributes in the document.
"""
function parse_rdfxml!(g::RDFGraph, io::IO; base::Union{AbstractString,Nothing}=nothing)
    data = read(io, String)
    parse_rdfxml!(g, data; base=base)
end

"""
    parse_rdfxml!(g::RDFGraph, input::AbstractString; base=nothing) -> RDFGraph

Parse RDF/XML from a string and add triples to the graph.

`xml:base` attributes are honoured and inherit through the element tree.
When no base is in scope (no `base` keyword and no `xml:base`), absolute
IRIs are kept as-is and relative IRIs are left unresolved (`rdf:ID="x"`
becomes `#x`).
"""
function parse_rdfxml!(g::RDFGraph, input::AbstractString; base::Union{AbstractString,Nothing}=nothing)
    doc = EzXML.parsexml(input)
    root = EzXML.root(doc)
    base0 = isnothing(base) ? nothing : String(base)

    # Check for rdf:RDF root or direct descriptions
    rootname = EzXML.nodename(root)
    if rootname == "RDF" || endswith(rootname, ":RDF")
        rbase = _rdfxml_update_base(root, base0)
        rlang = _rdfxml_update_lang(root, nothing)
        for child in EzXML.eachelement(root)
            _parse_rdfxml_node_element!(g, child, root, rbase, rlang)
        end
    else
        _parse_rdfxml_node_element!(g, root, root, base0, nothing)
    end

    g
end

"""
    parse_rdfxml(source; base=nothing) -> RDFGraph

Parse RDF/XML from a string or IO stream into a new graph.
"""
function parse_rdfxml(source; base::Union{AbstractString,Nothing}=nothing)
    g = RDFGraph()
    if source isa IO || source isa IOBuffer
        parse_rdfxml!(g, source; base=base)
    else
        parse_rdfxml!(g, String(source); base=base)
    end
end

# ─── Attribute helpers ───────────────────────────────────────────────
# NOTE: EzXML.nodename returns the *local* name for namespaced attributes
# (e.g. "about" for rdf:about); the namespace is queried separately.

function _rdfxml_attr_ns(attr::EzXML.Node)
    try
        return EzXML.namespace(attr)
    catch
        return ""
    end
end

# True when `attr` is the RDF attribute `localname` (rdf-namespaced, or
# unprefixed/un-namespaced for leniency with non-conformant documents).
function _rdfxml_is_rdf_attr(attr::EzXML.Node, localname::String)
    EzXML.nodename(attr) == localname || return false
    ns = _rdfxml_attr_ns(attr)
    return ns == _RDF_NS || isempty(ns)
end

function _rdfxml_is_xml_attr(attr::EzXML.Node, localname::String)
    EzXML.nodename(attr) == localname && _rdfxml_attr_ns(attr) == _XML_NS
end

# xml:base handling: a new xml:base (possibly relative, resolved against
# the inherited one) replaces the in-scope base.
function _rdfxml_update_base(elem::EzXML.Node, base::Union{String,Nothing})
    for attr in EzXML.eachattribute(elem)
        if _rdfxml_is_xml_attr(attr, "base")
            newbase = EzXML.nodecontent(attr)
            if !isnothing(base) && !_is_absolute_uri(newbase)
                return _resolve_uri(base, newbase)
            end
            return String(newbase)
        end
    end
    base
end

# xml:lang handling: nearest declaration wins; xml:lang="" cancels.
function _rdfxml_update_lang(elem::EzXML.Node, lang::Union{String,Nothing})
    for attr in EzXML.eachattribute(elem)
        if _rdfxml_is_xml_attr(attr, "lang")
            v = EzXML.nodecontent(attr)
            return isempty(v) ? nothing : String(v)
        end
    end
    lang
end

# Resolve an IRI against the in-scope base. Without a base, absolute IRIs
# are kept and relative IRIs are left as-is (documented behavior).
function _rdfxml_resolve(base::Union{String,Nothing}, iri::AbstractString)
    if isnothing(base) || _is_absolute_uri(iri)
        return String(iri)
    end
    _resolve_uri(base, iri)
end

# rdf:ID="name" denotes the IRI <base>#name.
function _rdfxml_resolve_id(base::Union{String,Nothing}, name::AbstractString)
    isnothing(base) ? "#" * name : _resolve_uri(base, "#" * name)
end

# ─── Node elements ───────────────────────────────────────────────────

function _parse_rdfxml_node_element!(g::RDFGraph, elem::EzXML.Node, root::EzXML.Node,
                                     base::Union{String,Nothing}=nothing,
                                     lang::Union{String,Nothing}=nothing)
    base = _rdfxml_update_base(elem, base)
    lang = _rdfxml_update_lang(elem, lang)

    # Determine subject (once — shared with any enclosing property element)
    subject = _rdfxml_get_subject(elem, base)

    # If element is not rdf:Description, add rdf:type triple
    localname = EzXML.nodename(elem)
    ns = _rdfxml_element_ns(elem)

    if localname != "Description" || ns != _RDF_NS
        if !isempty(ns)
            add!(g, Triple(subject, URIRef(_RDF_NS * "type"), URIRef(ns * localname)))
        end
    end

    # Process attribute properties (non-rdf/xml attributes become triples)
    for attr in EzXML.eachattribute(elem)
        _rdfxml_handle_attribute!(g, subject, attr, lang)
    end

    # Process child property elements (rdf:li counter is per node element)
    li_counter = Ref(0)
    for child in EzXML.eachelement(elem)
        _parse_rdfxml_property_element!(g, subject, child, root, base, lang, li_counter)
    end

    subject
end

function _rdfxml_get_subject(elem::EzXML.Node, base::Union{String,Nothing}=nothing)
    for attr in EzXML.eachattribute(elem)
        if _rdfxml_is_rdf_attr(attr, "about")
            return URIRef(_rdfxml_resolve(base, EzXML.nodecontent(attr)))
        elseif _rdfxml_is_rdf_attr(attr, "ID")
            return URIRef(_rdfxml_resolve_id(base, EzXML.nodecontent(attr)))
        elseif _rdfxml_is_rdf_attr(attr, "nodeID")
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

function _rdfxml_handle_attribute!(g::RDFGraph, subject::Node, attr::EzXML.Node,
                                   lang::Union{String,Nothing})
    ns = _rdfxml_attr_ns(attr)
    # Skip control attributes: rdf:*, xml:*, and un-namespaced attributes
    (ns == _RDF_NS || ns == _XML_NS || isempty(ns)) && return

    # Attribute is a property with literal value (current xml:lang applies)
    pred_uri = URIRef(ns * EzXML.nodename(attr))
    aval = EzXML.nodecontent(attr)
    lit = isnothing(lang) ? Literal(aval) : Literal(aval, lang=lang)
    add!(g, Triple(subject, pred_uri, lit))
end

# ─── Property elements ───────────────────────────────────────────────

function _parse_rdfxml_property_element!(g::RDFGraph, subject::Node, elem::EzXML.Node,
                                         root::EzXML.Node,
                                         base::Union{String,Nothing}=nothing,
                                         lang::Union{String,Nothing}=nothing,
                                         li_counter::Base.RefValue{Int}=Ref(0))
    base = _rdfxml_update_base(elem, base)
    lang = _rdfxml_update_lang(elem, lang)

    # Determine predicate from element name; rdf:li expands to rdf:_N
    ns = _rdfxml_element_ns(elem)
    localname = EzXML.nodename(elem)
    if ns == _RDF_NS && localname == "li"
        li_counter[] += 1
        predicate = URIRef(_RDF_NS * "_$(li_counter[])")
    else
        predicate = URIRef(ns * localname)
    end

    # Scan attributes
    resource_val = nothing
    nodeid_val = nothing
    parse_type = nothing
    dt_val = nothing
    reify_id = nothing
    for attr in EzXML.eachattribute(elem)
        if _rdfxml_is_rdf_attr(attr, "resource")
            resource_val = EzXML.nodecontent(attr)
        elseif _rdfxml_is_rdf_attr(attr, "nodeID")
            nodeid_val = EzXML.nodecontent(attr)
        elseif _rdfxml_is_rdf_attr(attr, "parseType")
            parse_type = EzXML.nodecontent(attr)
        elseif _rdfxml_is_rdf_attr(attr, "datatype")
            dt_val = URIRef(EzXML.nodecontent(attr))
        elseif _rdfxml_is_rdf_attr(attr, "ID")
            # rdf:ID on a property element reifies the statement
            reify_id = EzXML.nodecontent(attr)
        end
    end

    # Compute object
    object = if !isnothing(resource_val)
        URIRef(_rdfxml_resolve(base, resource_val))
    elseif !isnothing(nodeid_val)
        BNode(nodeid_val)
    elseif parse_type == "Resource"
        bnode = BNode()
        inner_li = Ref(0)
        for child in EzXML.eachelement(elem)
            _parse_rdfxml_property_element!(g, bnode, child, root, base, lang, inner_li)
        end
        bnode
    elseif parse_type == "Collection"
        _parse_rdfxml_collection!(g, elem, root, base, lang)
    elseif parse_type == "Literal"
        # Serialize the inner XML as-is into an rdf:XMLLiteral
        buf = IOBuffer()
        for n in EzXML.eachnode(elem)
            print(buf, n)
        end
        Literal(String(take!(buf)), datatype=URIRef(_RDF_NS * "XMLLiteral"))
    else
        children = collect(EzXML.eachelement(elem))
        if !isempty(children)
            # Nested node element: its subject IS the object of this triple
            _parse_rdfxml_node_element!(g, children[1], root, base, lang)
        else
            # Text content → Literal (content preserved verbatim)
            text = EzXML.nodecontent(elem)
            if !isnothing(dt_val)
                Literal(text, datatype=dt_val)
            elseif !isnothing(lang)
                Literal(text, lang=lang)
            else
                Literal(text)
            end
        end
    end

    add!(g, Triple(subject, predicate, object))

    # rdf:ID reification
    if !isnothing(reify_id)
        stmt = URIRef(_rdfxml_resolve_id(base, reify_id))
        add!(g, Triple(stmt, URIRef(_RDF_NS * "type"), URIRef(_RDF_NS * "Statement")))
        add!(g, Triple(stmt, URIRef(_RDF_NS * "subject"), subject))
        add!(g, Triple(stmt, URIRef(_RDF_NS * "predicate"), predicate))
        add!(g, Triple(stmt, URIRef(_RDF_NS * "object"), object))
    end

    object
end

# Parses the children of a parseType="Collection" property element and
# returns the head node of the list (rdf:nil for an empty collection).
# The caller adds the linking triple.
function _parse_rdfxml_collection!(g::RDFGraph, elem::EzXML.Node, root::EzXML.Node,
                                   base::Union{String,Nothing}=nothing,
                                   lang::Union{String,Nothing}=nothing)
    rdf_first = URIRef(_RDF_NS * "first")
    rdf_rest = URIRef(_RDF_NS * "rest")
    rdf_nil = URIRef(_RDF_NS * "nil")

    children = collect(EzXML.eachelement(elem))
    isempty(children) && return rdf_nil

    head = BNode()
    current = head

    for (i, child) in enumerate(children)
        # The item is the subject used by the nested node element (shared)
        item = _parse_rdfxml_node_element!(g, child, root, base, lang)
        add!(g, Triple(current, rdf_first, item))

        if i < length(children)
            next_node = BNode()
            add!(g, Triple(current, rdf_rest, next_node))
            current = next_node
        else
            add!(g, Triple(current, rdf_rest, rdf_nil))
        end
    end

    head
end

# ─── Register with high-level API ──────────────────────────────────

serialize(io::IO, g::RDFGraph, ::RDFXMLFormat) = serialize_rdfxml(io, g)
parse_rdf!(g::RDFGraph, source, ::RDFXMLFormat) = parse_rdfxml!(g, source)
