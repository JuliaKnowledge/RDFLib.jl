# ─── ConjunctiveGraph ───────────────────────────────────────────────
#
# A multi-context graph spanning all named graphs in a Dataset.
# Provides a unified view over all triples across all named graphs
# plus the default graph.

"""
    ConjunctiveGraph(; identifier=nothing)

A multi-context graph that spans all named graphs in a Dataset.
Provides a unified view over all triples across all contexts.

# Examples
```julia
cg = ConjunctiveGraph()
EX = Namespace("http://example.org/")
add!(cg, Triple(EX("s"), EX("p"), EX("o")))
add!(cg, Triple(EX("s2"), EX("p2"), EX("o2")), EX("g1"))
length(cg)  # 2
```
"""
mutable struct ConjunctiveGraph
    dataset::Dataset
    identifier::Union{URIRef, BNode, Nothing}
end

function ConjunctiveGraph(; identifier::Union{URIRef, BNode, Nothing}=nothing)
    ConjunctiveGraph(Dataset(), identifier)
end

function ConjunctiveGraph(ds::Dataset; identifier::Union{URIRef, BNode, Nothing}=nothing)
    ConjunctiveGraph(ds, identifier)
end

# ─── Core operations ────────────────────────────────────────────────

"""
    add!(cg::ConjunctiveGraph, triple::Triple)

Add a triple to the default graph.
"""
function add!(cg::ConjunctiveGraph, t::Triple)
    add!(cg.dataset, t, nothing)
    cg
end

"""
    add!(cg::ConjunctiveGraph, triple::Triple, context::GraphName)

Add a triple to a named graph (context).
"""
function add!(cg::ConjunctiveGraph, t::Triple, context::GraphName)
    add!(cg.dataset, t, context)
    cg
end

"""
    remove!(cg::ConjunctiveGraph, pattern::TriplePattern, context=nothing)

Remove matching triples from a specific context or all contexts.
"""
function remove!(cg::ConjunctiveGraph, pattern::TriplePattern, context::OptGraphName=nothing)
    remove!(cg.dataset, pattern, context)
    cg
end

"""
    triples(cg::ConjunctiveGraph, pattern::TriplePattern)

Search across ALL graphs for triples matching the pattern.
"""
function triples(cg::ConjunctiveGraph, pattern::TriplePattern)
    Channel{Triple}() do ch
        seen = Set{Triple}()
        for t in triples(cg.dataset.default_graph, pattern)
            if !(t in seen)
                push!(seen, t)
                put!(ch, t)
            end
        end
        for (_, g) in cg.dataset.named_graphs
            for t in triples(g, pattern)
                if !(t in seen)
                    push!(seen, t)
                    put!(ch, t)
                end
            end
        end
    end
end

triples(cg::ConjunctiveGraph) = triples(cg, (nothing, nothing, nothing))

"""
    contexts(cg::ConjunctiveGraph)

Return all graph identifiers (including nothing for the default graph).
"""
contexts(cg::ConjunctiveGraph) = contexts(cg.dataset)

"""
    get_context(cg::ConjunctiveGraph, name::OptGraphName=nothing)

Get a specific named graph (context), or the default graph.
"""
function get_context(cg::ConjunctiveGraph, name::OptGraphName=nothing)
    get_graph(cg.dataset, name)
end

"""
    remove_context!(cg::ConjunctiveGraph, name::GraphName)

Remove a named graph from the conjunctive graph.
"""
function remove_context!(cg::ConjunctiveGraph, name::GraphName)
    remove_graph(cg.dataset, name)
    cg
end

"""
    quads(cg::ConjunctiveGraph)

Iterate all quads across all graphs.
"""
quads(cg::ConjunctiveGraph) = quads(cg.dataset)

# ─── Iteration & length ────────────────────────────────────────────

function Base.length(cg::ConjunctiveGraph)
    length(cg.dataset)
end

Base.isempty(cg::ConjunctiveGraph) = length(cg) == 0

function Base.iterate(cg::ConjunctiveGraph)
    ch = triples(cg)
    result = iterate(ch)
    isnothing(result) && return nothing
    (result[1], ch)
end

function Base.iterate(cg::ConjunctiveGraph, ch)
    result = iterate(ch)
    isnothing(result) && return nothing
    (result[1], ch)
end

Base.eltype(::Type{ConjunctiveGraph}) = Triple

function Base.show(io::IO, cg::ConjunctiveGraph)
    n = length(cg)
    ng = length(cg.dataset.named_graphs)
    print(io, "ConjunctiveGraph ($n triples, $ng named graphs)")
end

# ─── Namespace convenience ──────────────────────────────────────────

bind!(cg::ConjunctiveGraph, prefix::AbstractString, ns) = bind!(cg.dataset, prefix, ns)
namespaces(cg::ConjunctiveGraph) = namespaces(cg.dataset)
