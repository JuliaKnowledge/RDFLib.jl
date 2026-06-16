# ─── RDF/XML Format ─────────────────────────────────────────────────
# XML-based RDF serialization using EzXML

const _RDF_NS = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
const _XML_NS = "http://www.w3.org/XML/1998/namespace"

# RDF/XML syntax term sets (RDF 1.1 Syntax §6.1.2-6.1.4).
const _RDFXML_CORE_SYNTAX_TERMS = Set(["RDF", "ID", "about", "parseType",
                                       "resource", "nodeID", "datatype"])
const _RDFXML_OLD_TERMS = Set(["aboutEach", "aboutEachPrefix", "bagID"])

struct RDFXMLError <: Exception
    msg::String
end
Base.showerror(io::IO, e::RDFXMLError) = print(io, "RDFXMLError: ", e.msg)

# XML 1.0 Name / NCName validation (no ':' allowed in an NCName).
# Conservative approximation of the XML Name char classes sufficient for the
# conformance suite: ASCII letters/_/digits/.-/middle-dot plus all non-ASCII
# characters above U+00B7, with the usual NameStartChar restriction.
function _rdfxml_is_namestart(c::Char)
    c == '_' && return true
    ('A' <= c <= 'Z') && return true
    ('a' <= c <= 'z') && return true
    # Combining diacritical marks (U+0300–U+036F) are NameChar but never
    # NameStartChar, so they must be excluded from the upper-range accept.
    ('̀' <= c <= 'ͯ') && return false
    c >= 'À' && c != '×' && c != '÷' && return true
    return false
end

function _rdfxml_is_namechar(c::Char)
    _rdfxml_is_namestart(c) && return true
    ('0' <= c <= '9') && return true
    (c == '-' || c == '.' || c == '·') && return true
    # combining marks / extenders in the upper ranges
    c >= '̀' && return true
    return false
end

function _rdfxml_is_ncname(s::AbstractString)
    isempty(s) && return false
    first_done = false
    for c in s
        c == ':' && return false
        if !first_done
            _rdfxml_is_namestart(c) || return false
            first_done = true
        else
            _rdfxml_is_namechar(c) || return false
        end
    end
    return true
end

_rdfxml_check_id(name::AbstractString) =
    _rdfxml_is_ncname(name) || throw(RDFXMLError("rdf:ID/rdf:nodeID is not a valid XML NCName: \"$name\""))

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
# Mutable parser state shared across the recursive descent.
mutable struct _RDFXMLState
    seen_ids::Set{String}   # resolved rdf:ID IRIs, for duplicate detection
end
_RDFXMLState() = _RDFXMLState(Set{String}())

function parse_rdfxml!(g::RDFGraph, input::AbstractString; base::Union{AbstractString,Nothing}=nothing)
    doc = EzXML.parsexml(input)
    root = EzXML.root(doc)
    base0 = isnothing(base) ? nothing : String(base)
    st = _RDFXMLState()

    # Check for rdf:RDF root or direct descriptions
    rootname = EzXML.nodename(root)
    rootns = _rdfxml_element_ns(root)
    if rootname == "RDF" && rootns == _RDF_NS
        rbase = _rdfxml_update_base(root, base0)
        rlang = _rdfxml_update_lang(root, nothing)
        for child in EzXML.eachelement(root)
            _parse_rdfxml_node_element!(g, st, child, root, rbase, rlang)
        end
    else
        _parse_rdfxml_node_element!(g, st, root, root, base0, nothing)
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

# Register a resolved rdf:ID IRI, erroring on a duplicate (within base).
function _rdfxml_register_id!(st::_RDFXMLState, iri::AbstractString)
    iri in st.seen_ids && throw(RDFXMLError("duplicate rdf:ID resolves to <$iri>"))
    push!(st.seen_ids, iri)
end

# A node element name must not be a core syntax term, rdf:li, or an old term.
function _rdfxml_check_node_name(ns::AbstractString, localname::AbstractString)
    ns == _RDF_NS || return
    if localname in _RDFXML_CORE_SYNTAX_TERMS || localname == "li" ||
       localname in _RDFXML_OLD_TERMS
        throw(RDFXMLError("$localname cannot be used as a node element name"))
    end
end

# A property element name must not be a core syntax term, rdf:Description, or
# an old term (rdf:li IS permitted).
function _rdfxml_check_property_name(ns::AbstractString, localname::AbstractString)
    ns == _RDF_NS || return
    if localname in _RDFXML_CORE_SYNTAX_TERMS || localname == "Description" ||
       localname in _RDFXML_OLD_TERMS
        throw(RDFXMLError("$localname cannot be used as a property element name"))
    end
end

# A property attribute name must not be a core syntax term, rdf:li,
# rdf:Description, or an old term.
function _rdfxml_check_property_attr(ns::AbstractString, localname::AbstractString)
    ns == _RDF_NS || return
    if localname in _RDFXML_CORE_SYNTAX_TERMS || localname == "li" ||
       localname == "Description" || localname in _RDFXML_OLD_TERMS
        throw(RDFXMLError("rdf:$localname cannot be used as a property attribute"))
    end
end

function _parse_rdfxml_node_element!(g::RDFGraph, st::_RDFXMLState, elem::EzXML.Node, root::EzXML.Node,
                                     base::Union{String,Nothing}=nothing,
                                     lang::Union{String,Nothing}=nothing)
    base = _rdfxml_update_base(elem, base)
    lang = _rdfxml_update_lang(elem, lang)

    localname = EzXML.nodename(elem)
    ns = _rdfxml_element_ns(elem)
    _rdfxml_check_node_name(ns, localname)

    # Determine subject (once — shared with any enclosing property element)
    subject = _rdfxml_get_subject(g, st, elem, base)

    # If element is not rdf:Description, add rdf:type triple
    if localname != "Description" || ns != _RDF_NS
        if !isempty(ns)
            add!(g, Triple(subject, URIRef(_RDF_NS * "type"), URIRef(ns * localname)))
        end
    end

    # Process attribute properties (non-control attributes become triples)
    for attr in EzXML.eachattribute(elem)
        _rdfxml_handle_attribute!(g, subject, attr, base, lang)
    end

    # Process child property elements (rdf:li counter is per node element)
    li_counter = Ref(0)
    for child in EzXML.eachelement(elem)
        _parse_rdfxml_property_element!(g, st, subject, child, root, base, lang, li_counter)
    end

    subject
end

function _rdfxml_get_subject(g::RDFGraph, st::_RDFXMLState, elem::EzXML.Node, base::Union{String,Nothing}=nothing)
    have_about = false; have_id = false; have_nodeid = false
    subject = nothing
    for attr in EzXML.eachattribute(elem)
        if _rdfxml_is_rdf_attr(attr, "about")
            have_about = true
            subject = URIRef(_rdfxml_resolve(base, EzXML.nodecontent(attr)))
        elseif _rdfxml_is_rdf_attr(attr, "ID")
            have_id = true
            name = EzXML.nodecontent(attr)
            _rdfxml_check_id(name)
            iri = _rdfxml_resolve_id(base, name)
            _rdfxml_register_id!(st, iri)
            subject = URIRef(iri)
        elseif _rdfxml_is_rdf_attr(attr, "nodeID")
            have_nodeid = true
            nid = EzXML.nodecontent(attr)
            _rdfxml_check_id(nid)
            subject = BNode(nid)
        elseif _rdfxml_is_rdf_attr(attr, "bagID") || _rdfxml_is_rdf_attr(attr, "aboutEach") ||
               _rdfxml_is_rdf_attr(attr, "aboutEachPrefix")
            throw(RDFXMLError("$(EzXML.nodename(attr)) is not a permitted RDF/XML attribute"))
        end
    end
    # At most one of rdf:about / rdf:ID / rdf:nodeID may appear on a node.
    (have_about + have_id + have_nodeid) > 1 &&
        throw(RDFXMLError("only one of rdf:about, rdf:ID, rdf:nodeID may appear on a node element"))
    subject === nothing ? BNode() : subject
end

function _rdfxml_element_ns(elem::EzXML.Node)
    try
        return EzXML.namespace(elem)
    catch
        return ""
    end
end

# Handle a property attribute on a node element. Control attributes
# (rdf:about/ID/nodeID/etc., xml:*) are skipped here. rdf:type as an
# attribute yields a URIRef object; other (rdf-or-foreign) property
# attributes yield literal objects.
# True when `attr` is a property attribute (yields a triple), i.e. namespaced,
# not xml:*, and not an RDF/XML control/syntax term.
function _rdfxml_is_property_attr(attr::EzXML.Node)
    ns = _rdfxml_attr_ns(attr)
    (ns == _XML_NS || isempty(ns)) && return false
    localname = EzXML.nodename(attr)
    if ns == _RDF_NS
        (localname in _RDFXML_CORE_SYNTAX_TERMS) && return false
        (localname in _RDFXML_OLD_TERMS) && return false
    end
    return true
end

function _rdfxml_handle_attribute!(g::RDFGraph, subject::Node, attr::EzXML.Node,
                                   base::Union{String,Nothing}, lang::Union{String,Nothing})
    ns = _rdfxml_attr_ns(attr)
    localname = EzXML.nodename(attr)
    # xml:* and un-namespaced (xmlns, plain) attributes are not properties.
    (ns == _XML_NS || isempty(ns)) && return
    if ns == _RDF_NS
        # Control / subject attributes are consumed elsewhere.
        (localname in _RDFXML_CORE_SYNTAX_TERMS) && return
        # rdf:type attribute → rdf:type triple with a URIRef object.
        if localname == "type"
            add!(g, Triple(subject, URIRef(_RDF_NS * "type"),
                           URIRef(_rdfxml_resolve(base, EzXML.nodecontent(attr)))))
            return
        end
        # rdf:li and old terms are forbidden as property attributes.
        _rdfxml_check_property_attr(ns, localname)
    end

    pred_uri = URIRef(ns * localname)
    aval = EzXML.nodecontent(attr)
    lit = isnothing(lang) ? Literal(aval) : Literal(aval, lang=lang)
    add!(g, Triple(subject, pred_uri, lit))
end

# ─── XML literal canonicalization (parseType="Literal") ──────────────
# A pragmatic Exclusive XML Canonicalization sufficient for rdf:XMLLiteral:
# elements are written with in-scope namespace declarations that have not
# already been rendered by an output ancestor (sorted by prefix), empty
# elements are expanded to <tag></tag>, and text is XML-escaped.

function _rdfxml_c14n_escape_text(s::AbstractString)
    s = replace(s, "&" => "&amp;")
    s = replace(s, "<" => "&lt;")
    s = replace(s, ">" => "&gt;")
    return s
end

function _rdfxml_c14n_escape_attr(s::AbstractString)
    s = replace(s, "&" => "&amp;")
    s = replace(s, "<" => "&lt;")
    s = replace(s, "\"" => "&quot;")
    s = replace(s, "\t" => "&#x9;")
    s = replace(s, "\n" => "&#xA;")
    s = replace(s, "\r" => "&#xD;")
    return s
end

# Reconstruct an element's qualified name (prefix:local) from its namespace.
function _rdfxml_c14n_qname(n::EzXML.Node)
    local_name = EzXML.nodename(n)
    uri = try EzXML.namespace(n) catch; nothing end
    isnothing(uri) && return local_name
    for (pfx, u) in (try EzXML.namespaces(n) catch; Tuple{String,String}[] end)
        if u == uri
            return isempty(pfx) ? local_name : pfx * ":" * local_name
        end
    end
    return local_name
end

function _rdfxml_c14n_node(buf::IO, n::EzXML.Node, rendered::Dict{String,String})
    if EzXML.iselement(n)
        qname = _rdfxml_c14n_qname(n)
        print(buf, "<", qname)
        # Namespace declarations: those in scope but not yet rendered.
        local_rendered = copy(rendered)
        nss = try EzXML.namespaces(n) catch; Tuple{String,String}[] end
        newdecls = Tuple{String,String}[]
        for (pfx, uri) in nss
            if get(local_rendered, pfx, nothing) != uri
                push!(newdecls, (pfx, uri))
                local_rendered[pfx] = uri
            end
        end
        for (pfx, uri) in newdecls
            if isempty(pfx)
                print(buf, " xmlns=\"", _rdfxml_c14n_escape_attr(uri), "\"")
            else
                print(buf, " xmlns:", pfx, "=\"", _rdfxml_c14n_escape_attr(uri), "\"")
            end
        end
        # Attributes (sorted by name), excluding namespace declarations.
        attrs = Tuple{String,String}[]
        for a in EzXML.eachattribute(n)
            push!(attrs, (EzXML.nodename(a), EzXML.nodecontent(a)))
        end
        sort!(attrs, by = x -> x[1])
        for (an, av) in attrs
            print(buf, " ", an, "=\"", _rdfxml_c14n_escape_attr(av), "\"")
        end
        print(buf, ">")
        for c in EzXML.eachnode(n)
            _rdfxml_c14n_node(buf, c, local_rendered)
        end
        print(buf, "</", qname, ">")
    elseif EzXML.istext(n) || EzXML.iscdata(n)
        print(buf, _rdfxml_c14n_escape_text(EzXML.nodecontent(n)))
    else
        # comments / PIs: emit verbatim text content of the node
        print(buf, n)
    end
end

# ─── Property elements ───────────────────────────────────────────────

function _parse_rdfxml_property_element!(g::RDFGraph, st::_RDFXMLState, subject::Node, elem::EzXML.Node,
                                         root::EzXML.Node,
                                         base::Union{String,Nothing}=nothing,
                                         lang::Union{String,Nothing}=nothing,
                                         li_counter::Base.RefValue{Int}=Ref(0))
    base = _rdfxml_update_base(elem, base)
    lang = _rdfxml_update_lang(elem, lang)

    # Determine predicate from element name; rdf:li expands to rdf:_N
    ns = _rdfxml_element_ns(elem)
    localname = EzXML.nodename(elem)
    _rdfxml_check_property_name(ns, localname)
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
    has_prop_attr = false   # any non-control property attribute present?
    for attr in EzXML.eachattribute(elem)
        if _rdfxml_is_rdf_attr(attr, "resource")
            resource_val = EzXML.nodecontent(attr)
        elseif _rdfxml_is_rdf_attr(attr, "nodeID")
            nodeid_val = EzXML.nodecontent(attr)
            _rdfxml_check_id(nodeid_val)
        elseif _rdfxml_is_rdf_attr(attr, "parseType")
            parse_type = EzXML.nodecontent(attr)
        elseif _rdfxml_is_rdf_attr(attr, "datatype")
            dt_val = URIRef(EzXML.nodecontent(attr))
        elseif _rdfxml_is_rdf_attr(attr, "ID")
            # rdf:ID on a property element reifies the statement
            reify_id = EzXML.nodecontent(attr)
            _rdfxml_check_id(reify_id)
        elseif _rdfxml_is_rdf_attr(attr, "bagID") || _rdfxml_is_rdf_attr(attr, "aboutEach") ||
               _rdfxml_is_rdf_attr(attr, "aboutEachPrefix")
            throw(RDFXMLError("$(EzXML.nodename(attr)) is not a permitted RDF/XML attribute"))
        elseif _rdfxml_is_property_attr(attr)
            has_prop_attr = true
        end
    end

    # A property element may carry at most one node-identity / value selector.
    if !isnothing(nodeid_val) && !isnothing(resource_val)
        throw(RDFXMLError("rdf:nodeID and rdf:resource cannot both appear on a property element"))
    end
    # parseType excludes rdf:resource / rdf:nodeID / rdf:datatype.
    if !isnothing(parse_type) && (!isnothing(resource_val) || !isnothing(nodeid_val) || !isnothing(dt_val))
        throw(RDFXMLError("rdf:parseType cannot be combined with rdf:resource/rdf:nodeID/rdf:datatype"))
    end

    # Compute object
    object = if has_prop_attr
        # Empty property element with property attributes: the object is a
        # resource node (rdf:resource / rdf:nodeID if given, else a fresh
        # bnode) and the property attributes describe THAT node.
        obj = if !isnothing(resource_val)
            URIRef(_rdfxml_resolve(base, resource_val))
        elseif !isnothing(nodeid_val)
            BNode(nodeid_val)
        else
            BNode()
        end
        for attr in EzXML.eachattribute(elem)
            _rdfxml_is_property_attr(attr) || continue
            _rdfxml_handle_attribute!(g, obj, attr, base, lang)
        end
        obj
    elseif !isnothing(resource_val)
        URIRef(_rdfxml_resolve(base, resource_val))
    elseif !isnothing(nodeid_val)
        BNode(nodeid_val)
    elseif parse_type == "Resource"
        bnode = BNode()
        inner_li = Ref(0)
        for child in EzXML.eachelement(elem)
            _parse_rdfxml_property_element!(g, st, bnode, child, root, base, lang, inner_li)
        end
        bnode
    elseif parse_type == "Collection"
        _parse_rdfxml_collection!(g, st, elem, root, base, lang)
    elseif parse_type == "Literal"
        # Canonicalize the inner XML into an rdf:XMLLiteral.
        buf = IOBuffer()
        for n in EzXML.eachnode(elem)
            _rdfxml_c14n_node(buf, n, Dict{String,String}())
        end
        Literal(String(take!(buf)), datatype=URIRef(_RDF_NS * "XMLLiteral"))
    else
        children = collect(EzXML.eachelement(elem))
        if !isempty(children)
            # Nested node element: its subject IS the object of this triple
            _parse_rdfxml_node_element!(g, st, children[1], root, base, lang)
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
function _parse_rdfxml_collection!(g::RDFGraph, st::_RDFXMLState, elem::EzXML.Node, root::EzXML.Node,
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
        item = _parse_rdfxml_node_element!(g, st, child, root, base, lang)
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
