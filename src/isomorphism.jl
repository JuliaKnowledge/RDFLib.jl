# ─── RDF RDFGraph Isomorphism ──────────────────────────────────────────
#
# Tests whether two RDF graphs are isomorphic (identical up to blank
# node relabeling) using canonical hash / partition refinement.
# Also provides graph hashing and conversion to Graphs.jl SimpleDiGraph.

import Graphs
import Graphs: SimpleDiGraph, add_edge!

# ─── Helpers ────────────────────────────────────────────────────────

_has_bnode(t::Triple) = t.subject isa BNode || t.object isa BNode

"""Split triples into ground (no blank nodes) and non-ground."""
function _partition_triples(triples::Vector{Triple})
    ground = Triple[]
    bnode  = Triple[]
    for t in triples
        push!(_has_bnode(t) ? bnode : ground, t)
    end
    ground, bnode
end

"""Collect all blank nodes appearing in a set of triples."""
function _collect_bnodes(triples::Vector{Triple})
    bnodes = Set{BNode}()
    for t in triples
        t.subject isa BNode && push!(bnodes, t.subject)
        t.object  isa BNode && push!(bnodes, t.object)
    end
    collect(bnodes)
end

"""
Hash an Identifier, replacing blank nodes with a canonical label from `mapping`.
If the node is a BNode not in `mapping`, use `default_label`.
"""
function _canonical_id(node::Identifier, mapping::Dict{BNode,UInt}, default_label::UInt=UInt(0))
    if node isa BNode
        return get(mapping, node, default_label)
    else
        return hash(node)
    end
end

"""
Compute a signature for a triple given a bnode→label mapping.
The predicate and any non-bnode terms contribute their hash directly.
BNode terms contribute their current label from the mapping.
"""
function _triple_signature(t::Triple, mapping::Dict{BNode,UInt})
    s = _canonical_id(t.subject, mapping)
    p = hash(t.predicate)
    o = _canonical_id(t.object, mapping)
    hash((s, p, o))
end

"""
Compute a canonical hash for each blank node based on the signatures of
its incident triples. Iterate until the labeling is stable.
Returns a Dict{BNode, UInt} mapping.
"""
function _canonical_labeling(triples::Vector{Triple})
    bnodes = _collect_bnodes(triples)
    isempty(bnodes) && return Dict{BNode,UInt}()

    # Build incidence: bnode → list of triples it appears in
    incidence = Dict{BNode, Vector{Triple}}()
    for b in bnodes
        incidence[b] = Triple[]
    end
    for t in triples
        t.subject isa BNode && push!(incidence[t.subject], t)
        t.object  isa BNode && push!(incidence[t.object], t)
    end

    # Initial labeling: all bnodes get the same label (fully anonymous)
    mapping = Dict{BNode,UInt}(b => UInt(0) for b in bnodes)

    max_iter = length(bnodes) + 10
    for _ in 1:max_iter
        new_mapping = Dict{BNode,UInt}()
        for b in bnodes
            sigs = sort!([_triple_signature(t, mapping) for t in incidence[b]])
            new_mapping[b] = hash(sigs)
        end
        new_mapping == mapping && break
        mapping = new_mapping
    end

    mapping
end

"""
Canonicalize a set of bnode-containing triples by computing a canonical
labeling and returning a sorted vector of triple signatures.
"""
function _canonical_form(triples::Vector{Triple})
    mapping = _canonical_labeling(triples)
    sigs = sort!([_triple_signature(t, mapping) for t in triples])
    sigs
end

"""
Check bnode isomorphism via permutation search (for small bnode counts)
or canonical hash comparison.
"""
function _check_bnode_isomorphism(bnode_triples1::Vector{Triple},
                                  bnode_triples2::Vector{Triple})
    bnodes1 = _collect_bnodes(bnode_triples1)
    bnodes2 = _collect_bnodes(bnode_triples2)
    length(bnodes1) != length(bnodes2) && return false

    n = length(bnodes1)

    # For small bnode counts, try all permutations
    if n <= 8
        return _try_permutations(bnode_triples1, bnode_triples2, bnodes1, bnodes2)
    end

    # For larger counts, compare canonical forms
    _canonical_form(bnode_triples1) == _canonical_form(bnode_triples2)
end

"""
Try all permutations of bnode mappings from g2's bnodes to g1's bnodes.
"""
function _try_permutations(triples1::Vector{Triple}, triples2::Vector{Triple},
                           bnodes1::Vector{BNode}, bnodes2::Vector{BNode})
    set1 = Set(triples1)
    _permute_check(triples2, bnodes2, bnodes1, set1, Int[], collect(1:length(bnodes1)))
end

"""Recursive permutation search with pruning."""
function _permute_check(triples2::Vector{Triple}, bnodes2::Vector{BNode},
                        bnodes1::Vector{BNode}, target::Set{Triple},
                        chosen::Vector{Int}, remaining::Vector{Int})
    if length(chosen) == length(bnodes2)
        # Build mapping and check
        mapping = Dict{BNode,BNode}()
        for (i, idx) in enumerate(chosen)
            mapping[bnodes2[i]] = bnodes1[idx]
        end
        remapped = Set(_remap_triple(t, mapping) for t in triples2)
        return remapped == target
    end

    for (ri, idx) in enumerate(remaining)
        new_remaining = [remaining[j] for j in eachindex(remaining) if j != ri]
        new_chosen = push!(copy(chosen), idx)
        if _permute_check(triples2, bnodes2, bnodes1, target, new_chosen, new_remaining)
            return true
        end
    end
    false
end

"""Remap blank nodes in a triple according to a BNode→BNode mapping."""
function _remap_triple(t::Triple, mapping::Dict{BNode,BNode})
    s = t.subject isa BNode ? get(mapping, t.subject, t.subject) : t.subject
    o = t.object  isa BNode ? get(mapping, t.object, t.object)  : t.object
    Triple(s, t.predicate, o)
end

# ─── Public API ─────────────────────────────────────────────────────

"""
    isomorphic(g1::RDFGraph, g2::RDFGraph) -> Bool

Test whether two RDF graphs are isomorphic (identical up to blank node
relabeling). Ground triples (containing no blank nodes) must match exactly;
blank-node-containing triples are checked via permutation search (≤8 bnodes)
or canonical hash comparison.

# Examples
```julia
g1, g2 = RDFGraph(), RDFGraph()
EX = Namespace("http://example.org/")
add!(g1, Triple(EX("s"), EX("p"), BNode("a")))
add!(g2, Triple(EX("s"), EX("p"), BNode("z")))
isomorphic(g1, g2)  # true
```
"""
function isomorphic(g1::RDFGraph, g2::RDFGraph)
    length(g1) != length(g2) && return false

    t1 = collect(g1)
    t2 = collect(g2)

    ground1, bnode1 = _partition_triples(t1)
    ground2, bnode2 = _partition_triples(t2)

    # Ground triples must match exactly
    Set(ground1) != Set(ground2) && return false
    length(bnode1) != length(bnode2) && return false
    isempty(bnode1) && return true

    _check_bnode_isomorphism(bnode1, bnode2)
end

"""
    graph_hash(g::RDFGraph) -> UInt

Compute a canonical hash of an RDF graph that is invariant under blank node
relabeling. Two isomorphic graphs will produce the same hash.
"""
function graph_hash(g::RDFGraph)
    triples_vec = collect(g)
    isempty(triples_vec) && return hash(:empty_graph)

    ground, bnode = _partition_triples(triples_vec)

    # Hash ground triples (order-independent via sorted hashes)
    ground_hashes = sort!([hash(t) for t in ground])
    h = hash(ground_hashes, hash(:ground))

    # Hash bnode triples via canonical form
    if !isempty(bnode)
        canon = _canonical_form(bnode)
        h = hash(canon, h)
    end

    h
end

"""
    to_simple_graph(g::RDFGraph) -> (SimpleDiGraph, Dict{Int, Identifier})

Convert an RDF graph to a Graphs.jl `SimpleDiGraph`. Each unique RDF term
(subject, predicate, or object) is assigned a vertex. Each triple becomes a
directed edge from the subject vertex to the object vertex.

Returns a tuple of `(digraph, vertex_to_term)` where `vertex_to_term` maps
integer vertex IDs back to their corresponding RDF `Identifier`.

# Examples
```julia
g = RDFGraph()
EX = Namespace("http://example.org/")
add!(g, Triple(EX("a"), EX("p"), EX("b")))
dg, mapping = to_simple_graph(g)
Graphs.nv(dg)  # number of unique terms
Graphs.ne(dg)  # number of triples (edges)
```
"""
function to_simple_graph(g::RDFGraph)
    triples_vec = collect(g)

    # Build term → vertex mapping
    term_to_vertex = Dict{Identifier, Int}()
    vertex_to_term = Dict{Int, Identifier}()
    next_id = 1

    function get_vertex!(term::Identifier)
        get!(term_to_vertex, term) do
            id = next_id
            next_id += 1
            vertex_to_term[id] = term
            id
        end
    end

    # First pass: assign vertices to all terms
    for t in triples_vec
        get_vertex!(t.subject)
        get_vertex!(t.object)
    end

    # Build directed graph
    dg = SimpleDiGraph(length(term_to_vertex))
    for t in triples_vec
        add_edge!(dg, term_to_vertex[t.subject], term_to_vertex[t.object])
    end

    dg, vertex_to_term
end

"""
    from_simple_graph(dg::SimpleDiGraph, vertex_to_term::Dict{Int, Identifier};
                      predicate::URIRef=URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#value")) -> RDFGraph

Convert a Graphs.jl `SimpleDiGraph` back to an `RDFGraph`. Each edge becomes a triple
using the provided `vertex_to_term` mapping (as returned by `to_simple_graph`).
All edges use the same `predicate` (defaults to `rdf:value`).

# Example
```julia
dg, mapping = to_simple_graph(g)
g2 = from_simple_graph(dg, mapping)
```
"""
function from_simple_graph(dg::SimpleDiGraph, vertex_to_term::Dict{Int, Identifier};
                           predicate::URIRef=URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#value"))
    g = RDFGraph()
    for e in Graphs.edges(dg)
        s = vertex_to_term[Graphs.src(e)]
        o = vertex_to_term[Graphs.dst(e)]
        if s isa Node && o isa Identifier
            add!(g, Triple(s, predicate, o))
        end
    end
    g
end
