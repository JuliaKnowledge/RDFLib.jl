# ─── Namespace ──────────────────────────────────────────────────────

"""
    Namespace(uri::AbstractString)

An RDF namespace. Generates URIRef terms by appending local names.

# Examples
```julia
EX = Namespace("http://example.org/")
EX("Person")  # URIRef("http://example.org/Person")
```
"""
struct Namespace
    uri::String
end

(ns::Namespace)(localname::AbstractString) = URIRef(ns.uri * localname)
(ns::Namespace)(localname::Symbol) = ns(String(localname))
Base.string(ns::Namespace) = ns.uri
Base.:(==)(a::Namespace, b::Namespace) = a.uri == b.uri
Base.hash(a::Namespace, h::UInt) = hash(a.uri, hash(:Namespace, h))

"""
Check if a URIRef belongs to this namespace.
"""
Base.in(u::URIRef, ns::Namespace) = startswith(u.value, ns.uri)

# ─── DefinedNamespace ───────────────────────────────────────────────

"""
    DefinedNamespace

A namespace with an enumerated set of allowed terms (like rdflib's DefinedNamespace).
Accessing an undefined term throws an error.

Constructed internally; use the predefined `RDF`, `RDFS`, `XSD`, `OWL` constants.
"""
struct DefinedNamespace
    uri::String
    terms::Set{String}
end

function (ns::DefinedNamespace)(localname::AbstractString)
    ln = String(localname)
    if ln ∉ ns.terms
        @warn "Term '$(ln)' not defined in namespace $(ns.uri)"
    end
    URIRef(ns.uri * ln)
end

(ns::DefinedNamespace)(localname::Symbol) = ns(String(localname))
Base.in(u::URIRef, ns::DefinedNamespace) = startswith(u.value, ns.uri)

# Allow property-style access: RDF.type → RDF(:type)
function Base.getproperty(ns::DefinedNamespace, name::Symbol)
    name === :uri && return getfield(ns, :uri)
    name === :terms && return getfield(ns, :terms)
    ns(String(name))
end

function Base.getproperty(ns::Namespace, name::Symbol)
    name === :uri && return getfield(ns, :uri)
    ns(String(name))
end

# ─── Standard Namespaces ────────────────────────────────────────────

const RDF = DefinedNamespace(
    "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    Set(["type", "Property", "Statement", "subject", "predicate", "object",
         "Bag", "Seq", "Alt", "value", "List", "nil", "first", "rest",
         "XMLLiteral", "HTML", "langString", "JSON", "CompoundLiteral",
         "language", "direction", "PlainLiteral"])
)

const RDFS = DefinedNamespace(
    "http://www.w3.org/2000/01/rdf-schema#",
    Set(["Resource", "Class", "subClassOf", "subPropertyOf", "comment", "label",
         "domain", "range", "seeAlso", "isDefinedBy", "Literal", "Container",
         "ContainerMembershipProperty", "member", "Datatype"])
)

const XSD = DefinedNamespace(
    "http://www.w3.org/2001/XMLSchema#",
    Set(["string", "boolean", "decimal", "float", "double",
         "integer", "long", "int", "short", "byte",
         "nonPositiveInteger", "negativeInteger", "nonNegativeInteger",
         "positiveInteger", "unsignedLong", "unsignedInt", "unsignedShort", "unsignedByte",
         "dateTime", "date", "time", "gYear", "gMonth", "gDay",
         "gYearMonth", "gMonthDay", "duration", "dayTimeDuration", "yearMonthDuration",
         "hexBinary", "base64Binary", "anyURI", "QName", "NOTATION",
         "normalizedString", "token", "language", "Name", "NCName",
         "NMTOKEN", "ID", "IDREF", "ENTITY"])
)

const OWL = DefinedNamespace(
    "http://www.w3.org/2002/07/owl#",
    Set(["AllDifferent", "AllDisjointClasses", "AllDisjointProperties",
         "Annotation", "AnnotationProperty", "AsymmetricProperty",
         "Axiom", "Class", "DataRange", "DatatypeProperty",
         "DeprecatedClass", "DeprecatedProperty", "FunctionalProperty",
         "InverseFunctionalProperty", "IrreflexiveProperty",
         "NamedIndividual", "NegativePropertyAssertion",
         "Nothing", "ObjectProperty", "Ontology", "OntologyProperty",
         "ReflexiveProperty", "Restriction", "SymmetricProperty",
         "Thing", "TransitiveProperty",
         "backwardCompatibleWith", "bottomDataProperty", "bottomObjectProperty",
         "complementOf", "datatypeComplementOf", "differentFrom",
         "disjointUnionOf", "disjointWith", "distinctMembers",
         "equivalentClass", "equivalentProperty",
         "hasKey", "hasSelf", "hasValue",
         "imports", "incompatibleWith",
         "intersectionOf", "inverseOf",
         "maxCardinality", "maxQualifiedCardinality",
         "members", "minCardinality", "minQualifiedCardinality",
         "onClass", "onDataRange", "onDatatype", "onProperties", "onProperty",
         "oneOf", "priorVersion",
         "propertyChainAxiom", "propertyDisjointWith",
         "qualifiedCardinality",
         "sameAs", "someValuesFrom", "allValuesFrom",
         "sourceIndividual", "targetIndividual", "targetValue",
         "topDataProperty", "topObjectProperty",
         "unionOf", "versionIRI", "versionInfo",
         "withRestrictions", "cardinality"])
)

const SKOS = DefinedNamespace(
    "http://www.w3.org/2004/02/skos/core#",
    Set(["Concept", "ConceptScheme", "Collection", "OrderedCollection",
         "inScheme", "hasTopConcept", "topConceptOf",
         "prefLabel", "altLabel", "hiddenLabel",
         "broader", "narrower", "related",
         "broaderTransitive", "narrowerTransitive",
         "definition", "scopeNote", "example", "historyNote",
         "editorialNote", "changeNote", "note",
         "semanticRelation", "mappingRelation",
         "broadMatch", "narrowMatch", "relatedMatch",
         "exactMatch", "closeMatch",
         "member", "memberList",
         "notation"])
)

# ─── NamespaceManager ──────────────────────────────────────────────

"""
    NamespaceManager()

Manages prefix ↔ namespace URI bindings.

# Examples
```julia
nsm = NamespaceManager()
bind!(nsm, "ex", Namespace("http://example.org/"))
expand_curie(nsm, "ex:Person")  # URIRef("http://example.org/Person")
```
"""
mutable struct NamespaceManager
    prefix_to_ns::Dict{String, String}
    ns_to_prefix::Dict{String, String}
    _counter::Int

    function NamespaceManager(; bind_defaults::Bool=true)
        nsm = new(Dict{String,String}(), Dict{String,String}(), 0)
        if bind_defaults
            bind!(nsm, "rdf",  RDF.uri)
            bind!(nsm, "rdfs", RDFS.uri)
            bind!(nsm, "xsd",  XSD.uri)
            bind!(nsm, "owl",  OWL.uri)
            bind!(nsm, "skos", SKOS.uri)
        end
        nsm
    end
end

"""
    bind!(nsm, prefix, namespace_uri)

Bind a prefix to a namespace URI.
"""
function bind!(nsm::NamespaceManager, prefix::AbstractString, ns::AbstractString)
    p, n = String(prefix), String(ns)
    nsm.prefix_to_ns[p] = n
    nsm.ns_to_prefix[n] = p
    nsm
end

bind!(nsm::NamespaceManager, prefix::AbstractString, ns::Namespace) = bind!(nsm, prefix, ns.uri)
bind!(nsm::NamespaceManager, prefix::AbstractString, ns::DefinedNamespace) = bind!(nsm, prefix, ns.uri)

"""
    expand_curie(nsm, curie) -> URIRef

Expand a compact URI (prefix:localname) to a full URIRef.
"""
function expand_curie(nsm::NamespaceManager, curie::AbstractString)
    idx = findfirst(':', curie)
    isnothing(idx) && throw(ArgumentError("Invalid CURIE: $curie"))
    prefix = curie[1:idx-1]
    local_name = curie[idx+1:end]
    ns = get(nsm.prefix_to_ns, prefix, nothing)
    isnothing(ns) && throw(KeyError("Unknown prefix: $prefix"))
    URIRef(ns * local_name)
end

"""
    compute_qname(nsm, uri) -> (prefix, namespace, localname)

Split a URI into prefix, namespace, and local name.
Auto-binds unknown namespaces as `ns1`, `ns2`, etc.
"""
function compute_qname(nsm::NamespaceManager, uri::URIRef)
    uristr = uri.value
    # Try fragment split first, then last / or #
    for sep in ('#', '/')
        idx = findlast(sep, uristr)
        if !isnothing(idx)
            ns_uri = uristr[1:idx]
            localname = uristr[idx+1:end]
            prefix = get(nsm.ns_to_prefix, ns_uri, nothing)
            if isnothing(prefix)
                nsm._counter += 1
                prefix = "ns$(nsm._counter)"
                bind!(nsm, prefix, ns_uri)
            end
            return (prefix, ns_uri, localname)
        end
    end
    throw(ArgumentError("Cannot compute qname for: $uristr"))
end

"""
    namespaces(nsm) -> iterator of (prefix, namespace_uri) pairs
"""
namespaces(nsm::NamespaceManager) = pairs(nsm.prefix_to_ns)
