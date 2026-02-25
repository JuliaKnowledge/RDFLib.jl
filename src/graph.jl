# ─── RDFGraph ──────────────────────────────────────────────────────────

"""
    RDFGraph(; store=MemoryStore(), identifier=nothing)

An RDF graph backed by a store.

# Examples
```julia
g = RDFGraph()
add!(g, Triple(URIRef("http://example.org/s"), URIRef("http://example.org/p"), Literal("hello")))
length(g)  # 1
for triple in g
    println(triple)
end
```
"""
mutable struct RDFGraph{S<:AbstractStore}
    store::S
    identifier::Union{URIRef, BNode, Nothing}
    namespace_manager::NamespaceManager
end

function RDFGraph(; store::AbstractStore=MemoryStore(),
                 identifier::Union{URIRef, BNode, Nothing}=nothing)
    RDFGraph(store, identifier, NamespaceManager())
end

# ─── Core operations ────────────────────────────────────────────────

"""
    add!(g::RDFGraph, triple::Triple)

Add a triple to the graph.
"""
function add!(g::RDFGraph, t::Triple)
    add!(g.store, t)
    g
end

"""
    add!(g::RDFGraph, s::Node, p::URIRef, o::Identifier)

Add a triple from individual components.
"""
add!(g::RDFGraph, s::Node, p::URIRef, o::Identifier) = add!(g, Triple(s, p, o))
add!(g::RDFGraph, s::Identifier, p::Identifier, o::Identifier) = add!(g, Triple(s, p, o))

"""
    remove!(g::RDFGraph, pattern::TriplePattern)

Remove all triples matching the pattern from the graph.
"""
function remove!(g::RDFGraph, pattern::TriplePattern)
    remove!(g.store, pattern)
    g
end

remove!(g::RDFGraph, t::Triple) = remove!(g, (t.subject, t.predicate, t.object))

"""
    triples(g::RDFGraph, pattern::TriplePattern)

Iterate triples matching the pattern. Use `nothing` as wildcard.

# Examples
```julia
# All triples with a given predicate
for t in triples(g, (nothing, URIRef("http://example.org/p"), nothing))
    println(t)
end
```
"""
triples(g::RDFGraph, pattern::TriplePattern) = triples(g.store, pattern)

"""
    triples(g::RDFGraph)

Iterate all triples in the graph.
"""
triples(g::RDFGraph) = triples(g, (nothing, nothing, nothing))

# ─── Convenience accessors (mirror rdflib) ──────────────────────────

"""
    subjects(g, predicate, object) -> iterator of subjects
"""
function subjects(g::RDFGraph, p::Union{URIRef,Nothing}=nothing, o::Union{Identifier,Nothing}=nothing)
    (t.subject for t in triples(g, (nothing, p, o)))
end

"""
    predicates(g, subject, object) -> iterator of predicates
"""
function predicates(g::RDFGraph, s::Union{Node,Nothing}=nothing, o::Union{Identifier,Nothing}=nothing)
    (t.predicate for t in triples(g, (s, nothing, o)))
end

"""
    objects(g, subject, predicate) -> iterator of objects
"""
function objects(g::RDFGraph, s::Union{Node,Nothing}=nothing, p::Union{URIRef,Nothing}=nothing)
    (t.object for t in triples(g, (s, p, nothing)))
end

"""
    subject_predicates(g, object) -> iterator of (subject, predicate)
"""
function subject_predicates(g::RDFGraph, o::Union{Identifier,Nothing}=nothing)
    ((t.subject, t.predicate) for t in triples(g, (nothing, nothing, o)))
end

"""
    subject_objects(g, predicate) -> iterator of (subject, object)
"""
function subject_objects(g::RDFGraph, p::Union{URIRef,Nothing}=nothing)
    ((t.subject, t.object) for t in triples(g, (nothing, p, nothing)))
end

"""
    predicate_objects(g, subject) -> iterator of (predicate, object)
"""
function predicate_objects(g::RDFGraph, s::Union{Node,Nothing}=nothing)
    ((t.predicate, t.object) for t in triples(g, (s, nothing, nothing)))
end

"""
    value(g, subject, predicate; default=nothing)

Get a single object value, or `default` if not found.
"""
function value(g::RDFGraph, s::Node, p::URIRef; default=nothing)
    for o in objects(g, s, p)
        return o
    end
    default
end

# ─── Iteration protocol ────────────────────────────────────────────

Base.length(g::RDFGraph) = length(g.store)
Base.isempty(g::RDFGraph) = isempty(g.store)

function Base.iterate(g::RDFGraph)
    # Fast path for MemoryStore: iterate insertion_order directly
    if g.store isa MemoryStore
        isempty(g.store.insertion_order) && return nothing
        return (g.store.insertion_order[1], (g.store, 2))
    end
    ch = triples(g)
    result = iterate(ch)
    isnothing(result) && return nothing
    (result[1], ch)
end

function Base.iterate(g::RDFGraph, state)
    # Fast path for MemoryStore
    if state isa Tuple{MemoryStore, Int}
        store, idx = state
        idx > length(store.insertion_order) && return nothing
        return (store.insertion_order[idx], (store, idx + 1))
    end
    ch = state
    result = iterate(ch)
    isnothing(result) && return nothing
    (result[1], ch)
end

function Base.in(t::Triple, g::RDFGraph)
    # Fast path: direct SPO index check for MemoryStore
    if g.store isa MemoryStore
        sp = get(g.store.spo, t.subject, nothing)
        sp === nothing && return false
        objs = get(sp, t.predicate, nothing)
        objs === nothing && return false
        return t.object in objs
    end
    for _ in triples(g, (t.subject, t.predicate, t.object))
        return true
    end
    false
end

Base.eltype(::Type{<:RDFGraph}) = Triple

# ─── Set operations ─────────────────────────────────────────────────

"""Union of two graphs."""
function Base.union(g1::RDFGraph, g2::RDFGraph)
    result = RDFGraph()
    for t in g1; add!(result, t); end
    for t in g2; add!(result, t); end
    result
end

"""Intersection of two graphs."""
function Base.intersect(g1::RDFGraph, g2::RDFGraph)
    result = RDFGraph()
    for t in g1
        if t in g2
            add!(result, t)
        end
    end
    result
end

"""Difference: triples in g1 but not in g2."""
function Base.setdiff(g1::RDFGraph, g2::RDFGraph)
    result = RDFGraph()
    for t in g1
        if !(t in g2)
            add!(result, t)
        end
    end
    result
end

"""Symmetric difference."""
function Base.symdiff(g1::RDFGraph, g2::RDFGraph)
    union(setdiff(g1, g2), setdiff(g2, g1))
end

# Operator aliases
Base.:(+)(g1::RDFGraph, g2::RDFGraph) = union(g1, g2)
Base.:(-)(g1::RDFGraph, g2::RDFGraph) = setdiff(g1, g2)

# ─── Namespace convenience ──────────────────────────────────────────

"""
    bind!(g::RDFGraph, prefix, namespace)

Bind a namespace prefix on this graph's namespace manager.
"""
bind!(g::RDFGraph, prefix::AbstractString, ns) = bind!(g.namespace_manager, prefix, ns)

"""
    namespaces(g::RDFGraph)

List all namespace bindings.
"""
namespaces(g::RDFGraph) = namespaces(g.namespace_manager)

# ─── Show ───────────────────────────────────────────────────────────

function Base.show(io::IO, g::RDFGraph)
    n = length(g)
    id = isnothing(g.identifier) ? "" : " $(g.identifier)"
    print(io, "RDFGraph$id ($n triples)")
end
