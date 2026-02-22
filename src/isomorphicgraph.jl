# ─── IsomorphicGraph ─────────────────────────────────────────────────
#
# Wrapper around RDFGraph that overrides == and hash to use graph
# isomorphism (blank-node-invariant comparison).

"""
    IsomorphicGraph(g::RDFGraph)

Wrap an RDFGraph so that `==` and `hash` use graph isomorphism.
Two IsomorphicGraphs are equal if and only if their underlying
graphs are isomorphic (identical up to blank node relabeling).

# Examples
```julia
g1, g2 = RDFGraph(), RDFGraph()
EX = Namespace("http://example.org/")
add!(g1, Triple(EX("s"), EX("p"), BNode("a")))
add!(g2, Triple(EX("s"), EX("p"), BNode("z")))
IsomorphicGraph(g1) == IsomorphicGraph(g2)  # true
```
"""
struct IsomorphicGraph
    graph::RDFGraph
end

function Base.:(==)(a::IsomorphicGraph, b::IsomorphicGraph)
    isomorphic(a.graph, b.graph)
end

function Base.hash(a::IsomorphicGraph, h::UInt)
    hash(graph_hash(a.graph), hash(:IsomorphicGraph, h))
end

"""
    to_isomorphic(g::RDFGraph) -> IsomorphicGraph

Convenience function to wrap a graph for isomorphism-based comparison.
"""
to_isomorphic(g::RDFGraph) = IsomorphicGraph(g)
