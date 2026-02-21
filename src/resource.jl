# ─── Resource ────────────────────────────────────────────────────────

"""
    Resource(g::RDFGraph, identifier::IdentifiedNode)

An object-oriented view of a node in an RDF graph. Provides convenient
property-style access to the node's predicates and objects.

# Examples
```julia
g = RDFGraph()
EX = Namespace("http://example.org/")
add!(g, Triple(EX("alice"), RDFS.label, Literal("Alice")))
add!(g, Triple(EX("alice"), EX("age"), Literal(30)))

r = Resource(g, EX("alice"))
r[RDFS.label]           # Literal("Alice") — single value
collect(r[EX("knows")])  # all values for a predicate (when using iteration)
```
"""
struct Resource
    graph::RDFGraph
    identifier::IdentifiedNode
end

Resource(g::RDFGraph, uri::AbstractString) = Resource(g, URIRef(uri))

# ─── Property access ────────────────────────────────────────────────

"""
    getindex(r::Resource, predicate::URIRef)

Return the first object value for `predicate`, or `nothing` if none.
"""
function Base.getindex(r::Resource, predicate::URIRef)
    for o in objects(r.graph, r.identifier, predicate)
        return o
    end
    nothing
end

"""
    getall(r::Resource, predicate::URIRef) -> Vector{Identifier}

Return all object values for `predicate`.
"""
function getall(r::Resource, predicate::URIRef)
    Identifier[o for o in objects(r.graph, r.identifier, predicate)]
end

# ─── Mutation ────────────────────────────────────────────────────────

"""
    setindex!(r::Resource, value::Identifier, predicate::URIRef)

Replace all existing values for `predicate` with `value`.
"""
function Base.setindex!(r::Resource, value::Identifier, predicate::URIRef)
    remove!(r.graph, (r.identifier, predicate, nothing))
    add!(r.graph, Triple(r.identifier, predicate, value))
    r
end

"""
    add!(r::Resource, predicate::URIRef, value::Identifier)

Add a triple without replacing existing values.
"""
function add!(r::Resource, predicate::URIRef, value::Identifier)
    add!(r.graph, Triple(r.identifier, predicate, value))
    r
end

"""
    remove!(r::Resource, predicate::URIRef)

Remove all triples with the given predicate for this resource.
"""
function remove!(r::Resource, predicate::URIRef)
    remove!(r.graph, (r.identifier, predicate, nothing))
    r
end

"""
    remove!(r::Resource, predicate::URIRef, value::Identifier)

Remove a specific triple for this resource.
"""
function remove!(r::Resource, predicate::URIRef, value::Identifier)
    remove!(r.graph, (r.identifier, predicate, value))
    r
end

# ─── Type checking ──────────────────────────────────────────────────

"""
    types(r::Resource) -> Vector{Identifier}

Return all `rdf:type` values for this resource.
"""
types(r::Resource) = getall(r, RDF.type)

"""
    isa_resource(r::Resource, type::URIRef) -> Bool

Check whether the resource has the given `rdf:type`.
"""
isa_resource(r::Resource, type::URIRef) = type in getall(r, RDF.type)

# ─── Predicate listing ──────────────────────────────────────────────

"""
    predicates(r::Resource) -> Vector{URIRef}

Return the unique predicates used by this resource.
"""
function predicates(r::Resource)
    unique(collect(predicates(r.graph, r.identifier, nothing)))
end

# ─── Label ───────────────────────────────────────────────────────────

"""
    label(r::Resource)

Return the `rdfs:label` value, or `nothing`.
"""
label(r::Resource) = r[RDFS.label]

# ─── Iteration ───────────────────────────────────────────────────────

function Base.iterate(r::Resource)
    ts = triples(r.graph, (r.identifier, nothing, nothing))
    result = iterate(ts)
    isnothing(result) && return nothing
    t, state = result
    ((t.predicate, t.object), (ts, state))
end

function Base.iterate(r::Resource, state)
    ts, st = state
    result = iterate(ts, st)
    isnothing(result) && return nothing
    t, st2 = result
    ((t.predicate, t.object), (ts, st2))
end

Base.eltype(::Type{Resource}) = Tuple{URIRef, Identifier}
Base.IteratorSize(::Type{Resource}) = Base.SizeUnknown()

# ─── Show ────────────────────────────────────────────────────────────

function Base.show(io::IO, r::Resource)
    id = r.identifier isa URIRef ? r.identifier.value : "_:$(r.identifier.id)"
    print(io, "Resource(", id, ")")
end

# ─── Navigation ──────────────────────────────────────────────────────

"""
    resource(r::Resource, predicate::URIRef) -> Resource

Navigate to the object of `predicate` as a new Resource.
Returns a Resource wrapping the first `IdentifiedNode` object, or errors if none.
"""
function resource(r::Resource, predicate::URIRef)
    for o in objects(r.graph, r.identifier, predicate)
        if o isa IdentifiedNode
            return Resource(r.graph, o)
        end
    end
    error("No IdentifiedNode object found for predicate $predicate")
end
