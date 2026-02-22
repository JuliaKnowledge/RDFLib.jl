# ─── InfixOWL — OWL ontology construction DSL ─────────────────────────

const _RDF_TYPE = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
const _RDFS_LABEL = URIRef("http://www.w3.org/2000/01/rdf-schema#label")
const _RDFS_COMMENT = URIRef("http://www.w3.org/2000/01/rdf-schema#comment")
const _RDFS_SUBCLASSOF = URIRef("http://www.w3.org/2000/01/rdf-schema#subClassOf")
const _RDFS_DOMAIN = URIRef("http://www.w3.org/2000/01/rdf-schema#domain")
const _RDFS_RANGE = URIRef("http://www.w3.org/2000/01/rdf-schema#range")

const _OWL_CLASS = URIRef("http://www.w3.org/2002/07/owl#Class")
const _OWL_OBJECTPROPERTY = URIRef("http://www.w3.org/2002/07/owl#ObjectProperty")
const _OWL_DATATYPEPROPERTY = URIRef("http://www.w3.org/2002/07/owl#DatatypeProperty")
const _OWL_ANNOTATIONPROPERTY = URIRef("http://www.w3.org/2002/07/owl#AnnotationProperty")
const _OWL_RESTRICTION = URIRef("http://www.w3.org/2002/07/owl#Restriction")
const _OWL_ONTOLOGY = URIRef("http://www.w3.org/2002/07/owl#Ontology")
const _OWL_ONPROPERTY = URIRef("http://www.w3.org/2002/07/owl#onProperty")
const _OWL_SOMEVALUESFROM = URIRef("http://www.w3.org/2002/07/owl#someValuesFrom")
const _OWL_ALLVALUESFROM = URIRef("http://www.w3.org/2002/07/owl#allValuesFrom")
const _OWL_HASVALUE = URIRef("http://www.w3.org/2002/07/owl#hasValue")
const _OWL_CARDINALITY = URIRef("http://www.w3.org/2002/07/owl#cardinality")
const _OWL_MINCARDINALITY = URIRef("http://www.w3.org/2002/07/owl#minCardinality")
const _OWL_MAXCARDINALITY = URIRef("http://www.w3.org/2002/07/owl#maxCardinality")
const _OWL_UNIONOF = URIRef("http://www.w3.org/2002/07/owl#unionOf")
const _OWL_INTERSECTIONOF = URIRef("http://www.w3.org/2002/07/owl#intersectionOf")
const _OWL_COMPLEMENTOF = URIRef("http://www.w3.org/2002/07/owl#complementOf")
const _OWL_VERSIONIRI = URIRef("http://www.w3.org/2002/07/owl#versionIRI")
const _OWL_IMPORTS = URIRef("http://www.w3.org/2002/07/owl#imports")

const _RDF_FIRST = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
const _RDF_REST = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
const _RDF_NIL_URI = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")

# ─── OWLClass ───────────────────────────────────────────────────────

"""
    OWLClass(uri::URIRef, g::RDFGraph; label=nothing)

Declare an OWL class in the graph.
"""
mutable struct OWLClass
    uri::URIRef
    graph::RDFGraph

    function OWLClass(uri::URIRef, g::RDFGraph; label::Union{String,Nothing}=nothing)
        add!(g, Triple(uri, _RDF_TYPE, _OWL_CLASS))
        if !isnothing(label)
            add!(g, Triple(uri, _RDFS_LABEL, Literal(label)))
        end
        new(uri, g)
    end
end

"""
    subclass_of!(cls::OWLClass, parent)

Assert that `cls` is a subclass of `parent`.
"""
function subclass_of!(cls::OWLClass, parent::OWLClass)
    add!(cls.graph, Triple(cls.uri, _RDFS_SUBCLASSOF, parent.uri))
end

function subclass_of!(cls::OWLClass, parent::URIRef)
    add!(cls.graph, Triple(cls.uri, _RDFS_SUBCLASSOF, parent))
end

# ─── OWLProperty ────────────────────────────────────────────────────

mutable struct OWLProperty
    uri::URIRef
    graph::RDFGraph
    property_type::Symbol  # :object, :datatype, :annotation

    OWLProperty(uri::URIRef, g::RDFGraph, pt::Symbol) = new(uri, g, pt)
end

function _add_property_metadata!(g::RDFGraph, uri::URIRef; domain=nothing, range=nothing, label=nothing)
    if !isnothing(domain)
        add!(g, Triple(uri, _RDFS_DOMAIN, domain isa OWLClass ? domain.uri : domain))
    end
    if !isnothing(range)
        add!(g, Triple(uri, _RDFS_RANGE, range isa OWLClass ? range.uri : range))
    end
    if !isnothing(label)
        add!(g, Triple(uri, _RDFS_LABEL, Literal(label)))
    end
end

"""
    OWLObjectProperty(uri, g; domain=nothing, range=nothing, label=nothing)

Declare an OWL object property.
"""
function OWLObjectProperty(uri::URIRef, g::RDFGraph; domain=nothing, range=nothing, label=nothing)
    add!(g, Triple(uri, _RDF_TYPE, _OWL_OBJECTPROPERTY))
    _add_property_metadata!(g, uri; domain, range, label)
    OWLProperty(uri, g, :object)
end

"""
    OWLDatatypeProperty(uri, g; domain=nothing, range=nothing, label=nothing)

Declare an OWL datatype property.
"""
function OWLDatatypeProperty(uri::URIRef, g::RDFGraph; domain=nothing, range=nothing, label=nothing)
    add!(g, Triple(uri, _RDF_TYPE, _OWL_DATATYPEPROPERTY))
    _add_property_metadata!(g, uri; domain, range, label)
    OWLProperty(uri, g, :datatype)
end

# ─── OWL Restriction ───────────────────────────────────────────────

"""
    owl_restriction(g, property; some_values_from=nothing, all_values_from=nothing,
                    has_value=nothing, cardinality=nothing, min_cardinality=nothing,
                    max_cardinality=nothing)

Create an OWL restriction blank node in the graph. Returns the BNode.
"""
function owl_restriction(g::RDFGraph, property::URIRef;
                         some_values_from=nothing, all_values_from=nothing,
                         has_value=nothing, cardinality=nothing,
                         min_cardinality=nothing, max_cardinality=nothing)
    r = BNode()
    add!(g, Triple(r, _RDF_TYPE, _OWL_RESTRICTION))
    add!(g, Triple(r, _OWL_ONPROPERTY, property))
    !isnothing(some_values_from) && add!(g, Triple(r, _OWL_SOMEVALUESFROM,
        some_values_from isa OWLClass ? some_values_from.uri : some_values_from))
    !isnothing(all_values_from) && add!(g, Triple(r, _OWL_ALLVALUESFROM,
        all_values_from isa OWLClass ? all_values_from.uri : all_values_from))
    !isnothing(has_value) && add!(g, Triple(r, _OWL_HASVALUE, has_value))
    !isnothing(cardinality) && add!(g, Triple(r, _OWL_CARDINALITY, Literal(cardinality)))
    !isnothing(min_cardinality) && add!(g, Triple(r, _OWL_MINCARDINALITY, Literal(min_cardinality)))
    !isnothing(max_cardinality) && add!(g, Triple(r, _OWL_MAXCARDINALITY, Literal(max_cardinality)))
    r
end

# ─── OWL Ontology metadata ─────────────────────────────────────────

"""
    owl_ontology!(g, uri; version=nothing, imports=nothing, label=nothing)

Declare OWL ontology metadata.
"""
function owl_ontology!(g::RDFGraph, uri::URIRef; version=nothing, imports=nothing, label=nothing)
    add!(g, Triple(uri, _RDF_TYPE, _OWL_ONTOLOGY))
    !isnothing(version) && add!(g, Triple(uri, _OWL_VERSIONIRI, version))
    !isnothing(label) && add!(g, Triple(uri, _RDFS_LABEL, Literal(label)))
    if !isnothing(imports)
        for imp in (imports isa Vector ? imports : [imports])
            add!(g, Triple(uri, _OWL_IMPORTS, imp))
        end
    end
end

# ─── RDF List helper (internal) ─────────────────────────────────────

function _build_rdf_list!(g::RDFGraph, items::Vector)
    isempty(items) && return _RDF_NIL_URI
    nodes = [BNode() for _ in items]
    for (i, item) in enumerate(items)
        uri = item isa OWLClass ? item.uri : item
        add!(g, Triple(nodes[i], _RDF_FIRST, uri))
        rest = i < length(items) ? nodes[i+1] : _RDF_NIL_URI
        add!(g, Triple(nodes[i], _RDF_REST, rest))
    end
    nodes[1]
end

# ─── Set operations: union, intersection, complement ────────────────

"""
    owl_union(g, classes)

Create an anonymous OWL union class. Returns the BNode.
"""
function owl_union(g::RDFGraph, classes::Vector)
    b = BNode()
    add!(g, Triple(b, _RDF_TYPE, _OWL_CLASS))
    head = _build_rdf_list!(g, classes)
    add!(g, Triple(b, _OWL_UNIONOF, head))
    b
end

"""
    owl_intersection(g, classes)

Create an anonymous OWL intersection class. Returns the BNode.
"""
function owl_intersection(g::RDFGraph, classes::Vector)
    b = BNode()
    add!(g, Triple(b, _RDF_TYPE, _OWL_CLASS))
    head = _build_rdf_list!(g, classes)
    add!(g, Triple(b, _OWL_INTERSECTIONOF, head))
    b
end

"""
    owl_complement(g, cls)

Create an anonymous OWL complement class. Returns the BNode.
"""
function owl_complement(g::RDFGraph, cls)
    b = BNode()
    add!(g, Triple(b, _RDF_TYPE, _OWL_CLASS))
    add!(g, Triple(b, _OWL_COMPLEMENTOF, cls isa OWLClass ? cls.uri : cls))
    b
end

# ─── Individual ─────────────────────────────────────────────────────

"""
    owl_individual(g, uri, cls; properties=Dict())

Create an OWL individual (instance) of the given class.
"""
function owl_individual(g::RDFGraph, uri::URIRef, cls::Union{OWLClass, URIRef}; properties=Dict())
    class_uri = cls isa OWLClass ? cls.uri : cls
    add!(g, Triple(uri, _RDF_TYPE, class_uri))
    for (prop, val) in properties
        add!(g, Triple(uri, prop, val))
    end
end
