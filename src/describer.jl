# ─── Graph Describer — fluent API for building RDF descriptions ──────

const _DESC_RDF_TYPE = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
const _DESC_RDFS_LABEL = URIRef("http://www.w3.org/2000/01/rdf-schema#label")
const _DESC_RDFS_COMMENT = URIRef("http://www.w3.org/2000/01/rdf-schema#comment")

"""
    Describer

Fluent API for describing an RDF subject. Chain calls to build up triples.
"""
mutable struct Describer
    graph::RDFGraph
    subject::Node
end

"""
    describe(g::RDFGraph, subject::Node) -> Describer

Start describing a subject in the graph.
"""
function describe(g::RDFGraph, subject::Node)
    Describer(g, subject)
end

"""
    rdf_type!(d::Describer, type_uri::URIRef) -> Describer

Add an rdf:type triple for the described subject.
"""
function rdf_type!(d::Describer, type_uri::URIRef)
    add!(d.graph, Triple(d.subject, _DESC_RDF_TYPE, type_uri))
    d
end

"""
    property!(d::Describer, predicate::URIRef, object::Identifier) -> Describer

Add a property triple for the described subject.
"""
function property!(d::Describer, predicate::URIRef, object::Identifier)
    add!(d.graph, Triple(d.subject, predicate, object))
    d
end

"""
    properties!(d::Describer, predicate::URIRef, objects::Vector) -> Describer

Add multiple values for the same predicate.
"""
function properties!(d::Describer, predicate::URIRef, objects::Vector)
    for obj in objects
        add!(d.graph, Triple(d.subject, predicate, obj))
    end
    d
end

"""
    label!(d::Describer, label::AbstractString; lang=nothing) -> Describer

Add an rdfs:label for the described subject.
"""
function label!(d::Describer, lbl::AbstractString; lang=nothing)
    lit = isnothing(lang) ? Literal(lbl) : Literal(lbl, lang=lang)
    add!(d.graph, Triple(d.subject, _DESC_RDFS_LABEL, lit))
    d
end

"""
    comment!(d::Describer, comment::AbstractString; lang=nothing) -> Describer

Add an rdfs:comment for the described subject.
"""
function comment!(d::Describer, cmt::AbstractString; lang=nothing)
    lit = isnothing(lang) ? Literal(cmt) : Literal(cmt, lang=lang)
    add!(d.graph, Triple(d.subject, _DESC_RDFS_COMMENT, lit))
    d
end

"""
    related!(d::Describer, predicate::URIRef, target::Node) -> Describer

Add a relationship triple.
"""
function related!(d::Describer, predicate::URIRef, target::Node)
    property!(d, predicate, target)
end

"""
    sub_describe!(d::Describer, predicate::URIRef, object::Node) -> Describer

Link the current subject to `object` via `predicate` and return a new Describer
for `object`, enabling nested description.
"""
function sub_describe!(d::Describer, predicate::URIRef, object::Node)
    add!(d.graph, Triple(d.subject, predicate, object))
    Describer(d.graph, object)
end
