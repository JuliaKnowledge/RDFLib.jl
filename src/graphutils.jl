# ─── RDFGraph Utilities ─────────────────────────────────────────────────

"""
    merge_graphs(graphs::RDFGraph...) -> RDFGraph

Merge multiple RDF graphs with proper blank node scoping.
Each input graph's blank nodes are renamed to unique identifiers
to avoid unintended merging of blank nodes across graphs.

# Example
```julia
merged = merge_graphs(g1, g2, g3)
```
"""
function merge_graphs(graphs::RDFGraph...)
    result = RDFGraph()
    for (i, g) in enumerate(graphs)
        # Collect all blank nodes in this graph
        bnodes = Set{BNode}()
        for t in g
            t.subject isa BNode && push!(bnodes, t.subject)
            t.object isa BNode && push!(bnodes, t.object)
        end

        # Create a renaming map for this graph's blank nodes
        rename = Dict{BNode, BNode}()
        for b in bnodes
            rename[b] = BNode()  # generates unique ID
        end

        # Add triples with renamed blank nodes
        for t in g
            s = get(rename, t.subject, t.subject)
            o = t.object isa BNode ? get(rename, t.object, t.object) : t.object
            add!(result, Triple(s, t.predicate, o))
        end
    end
    result
end

"""
    graph_diff(g1::RDFGraph, g2::RDFGraph) -> (in_both, only_in_g1, only_in_g2)

Compute the difference between two graphs, returning three graphs:
- `in_both`: triples present in both graphs
- `only_in_g1`: triples only in g1
- `only_in_g2`: triples only in g2

Note: This comparison is structural (not considering blank node isomorphism).
For isomorphism-aware comparison, see `isomorphic()`.

# Example
```julia
shared, left_only, right_only = graph_diff(g1, g2)
```
"""
function graph_diff(g1::RDFGraph, g2::RDFGraph)
    in_both = intersect(g1, g2)
    only_g1 = setdiff(g1, g2)
    only_g2 = setdiff(g2, g1)
    (in_both, only_g1, only_g2)
end

"""
    graph_stats(g::RDFGraph) -> NamedTuple

Return statistics about the graph including counts of triples,
subjects, predicates, objects, URI references, blank nodes, and literals.
"""
function graph_stats(g::RDFGraph)
    n_triples = length(g)
    subjs = Set{Node}()
    preds = Set{URIRef}()
    objs = Set{Identifier}()
    n_bnodes = Set{BNode}()
    n_uris = Set{URIRef}()
    n_literals = Set{Literal}()

    for t in g
        push!(subjs, t.subject)
        push!(preds, t.predicate)
        push!(objs, t.object)
        t.subject isa BNode && push!(n_bnodes, t.subject)
        t.subject isa URIRef && push!(n_uris, t.subject)
        t.object isa BNode && push!(n_bnodes, t.object)
        t.object isa URIRef && push!(n_uris, t.object)
        t.object isa Literal && push!(n_literals, t.object)
        push!(n_uris, t.predicate)
    end

    (
        triples = n_triples,
        subjects = length(subjs),
        predicates = length(preds),
        objects = length(objs),
        uri_refs = length(n_uris),
        blank_nodes = length(n_bnodes),
        literals = length(n_literals),
    )
end

"""
    connected_components(g::RDFGraph) -> Vector{RDFGraph}

Split a graph into connected components. Two triples are connected
if they share a subject or object node.
"""
function connected_components(g::RDFGraph)
    # Union-Find
    parent = Dict{Identifier, Identifier}()

    function find(x::Identifier)
        while haskey(parent, x) && parent[x] !== x
            parent[x] = haskey(parent, parent[x]) ? parent[parent[x]] : parent[x]
            x = parent[x]
        end
        x
    end

    function unite!(a::Identifier, b::Identifier)
        ra = find(a)
        rb = find(b)
        if ra !== rb
            parent[ra] = rb
        end
    end

    all_triples = collect(g)

    # Initialize each node as its own root
    for t in all_triples
        haskey(parent, t.subject) || (parent[t.subject] = t.subject)
        haskey(parent, t.object) || (parent[t.object] = t.object)
    end

    # Unite subject and object of each triple
    for t in all_triples
        unite!(t.subject, t.object)
    end

    # Group triples by component root
    components = Dict{Identifier, RDFGraph}()
    for t in all_triples
        root = find(t.subject)
        if !haskey(components, root)
            components[root] = RDFGraph()
        end
        add!(components[root], t)
    end

    collect(values(components))
end

"""
    cbd(g::RDFGraph, node::Node) -> RDFGraph

Return the Concise Bounded Description (CBD) of a node.
This includes all triples with `node` as subject, and recursively
includes the CBD of any blank nodes that appear as objects.

# Example
```julia
description = cbd(g, URIRef("http://example.org/alice"))
```
"""
function cbd(g::RDFGraph, node::Node)
    result = RDFGraph()
    visited = Set{Node}()
    _cbd_recurse!(g, node, result, visited)
    result
end

function _cbd_recurse!(g::RDFGraph, node::Node, result::RDFGraph, visited::Set{Node})
    node in visited && return
    push!(visited, node)
    for t in triples(g, (node, nothing, nothing))
        add!(result, t)
        if t.object isa BNode
            _cbd_recurse!(g, t.object, result, visited)
        end
    end
end
