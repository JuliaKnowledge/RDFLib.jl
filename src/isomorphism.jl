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

# ─── Color refinement ───────────────────────────────────────────────
#
# Blank node isomorphism is decided by color refinement (1-WL) plus
# individuation-and-backtracking. Refinement alone cannot distinguish
# certain regular structures (e.g. one 10-cycle vs. two disjoint
# 5-cycles), so when refinement stabilizes with non-singleton color
# classes we individuate one node per class and recurse. The final
# candidate bijection is ALWAYS verified by exact triple-set equality
# under the mapping, so hash collisions can never produce a false
# positive.

"""Signature of a term: refined color for blank nodes, plain hash otherwise."""
_term_sig(term::Identifier, colors::Dict{BNode,UInt}) =
    term isa BNode ? hash((:bnode, colors[term])) : hash(term)

"""Build incidence map: bnode → triples it appears in (each triple once)."""
function _build_incidence(triples::Vector{Triple}, bnodes::Vector{BNode})
    incidence = Dict{BNode, Vector{Triple}}(b => Triple[] for b in bnodes)
    for t in triples
        t.subject isa BNode && push!(incidence[t.subject], t)
        if t.object isa BNode && t.object != t.subject
            push!(incidence[t.object], t)
        end
    end
    incidence
end

"""
One round of color refinement: each bnode's new color combines its previous
color with the sorted multiset of signatures of its incident triples
(distinguishing the subject and object roles). Because the previous color
is folded in, the color partition can only split, never merge.
"""
function _refine_round(bnodes::Vector{BNode},
                       incidence::Dict{BNode, Vector{Triple}},
                       colors::Dict{BNode,UInt})
    new_colors = Dict{BNode,UInt}()
    for b in bnodes
        sigs = UInt[]
        for t in incidence[b]
            tsig = hash((_term_sig(t.subject, colors),
                         hash(t.predicate),
                         _term_sig(t.object, colors)))
            t.subject == b && push!(sigs, hash((tsig, 0x01)))
            t.object  == b && push!(sigs, hash((tsig, 0x02)))
        end
        sort!(sigs)
        new_colors[b] = hash((colors[b], sigs))
    end
    new_colors
end

_n_colors(colors::Dict{BNode,UInt}) = length(Set(values(colors)))

"""
Refine a single graph's coloring until the partition stabilizes.

Stability is detected when the number of distinct colors stops increasing
(the partition can only split since each round folds the previous color
in). Note: comparing raw mappings (`new_mapping == mapping`) can never
detect convergence because the color *values* change every round even at
the fixed point — only the partition stabilizes.
"""
function _refine_stable!(colors::Dict{BNode,UInt}, bnodes::Vector{BNode},
                         incidence::Dict{BNode, Vector{Triple}})
    nc = _n_colors(colors)
    for _ in 1:(length(bnodes) + 1)
        new_colors = _refine_round(bnodes, incidence, colors)
        nnc = length(Set(values(new_colors)))
        merge!(colors, new_colors)
        nnc == nc && break
        nc = nnc
    end
    colors
end

"""
Refine two graphs' colorings in lockstep, comparing the color multisets
after every round. Returns `false` as soon as the multisets diverge
(graphs cannot be isomorphic), `true` when both partitions are stable.
"""
function _joint_refine!(c1::Dict{BNode,UInt}, bn1::Vector{BNode}, inc1,
                        c2::Dict{BNode,UInt}, bn2::Vector{BNode}, inc2)
    sort!(collect(values(c1))) == sort!(collect(values(c2))) || return false
    nc = _n_colors(c1)
    for _ in 1:(length(bn1) + 1)
        new1 = _refine_round(bn1, inc1, c1)
        new2 = _refine_round(bn2, inc2, c2)
        sort!(collect(values(new1))) == sort!(collect(values(new2))) || return false
        nnc = length(Set(values(new1)))
        merge!(c1, new1)
        merge!(c2, new2)
        nnc == nc && return true
        nc = nnc
    end
    true
end

const _EMPTY_BNODES = BNode[]

"""
Individuation-and-refinement search. Refines both colorings to stability;
if every color class is a singleton, the colors define a candidate
bijection which is verified by exact triple-set equality (mandatory — no
false positives regardless of hash behavior). Otherwise, one node from the
smallest non-singleton class of graph 1 is individuated (given a fresh
color) and matched against each same-colored node of graph 2, backtracking
on failure. Worst-case exponential (as expected for graph isomorphism) but
refinement makes typical RDF graphs resolve with little or no branching.
"""
function _iso_backtrack(triples1::Vector{Triple}, target2::Set{Triple},
                        bn1::Vector{BNode}, inc1,
                        bn2::Vector{BNode}, inc2,
                        c1::Dict{BNode,UInt}, c2::Dict{BNode,UInt},
                        depth::Int)
    _joint_refine!(c1, bn1, inc1, c2, bn2, inc2) || return false

    groups1 = Dict{UInt, Vector{BNode}}()
    for b in bn1
        push!(get!(() -> BNode[], groups1, c1[b]), b)
    end
    groups2 = Dict{UInt, Vector{BNode}}()
    for b in bn2
        push!(get!(() -> BNode[], groups2, c2[b]), b)
    end
    length(groups1) == length(groups2) || return false

    # Find the smallest non-singleton color class (deterministic tie-break)
    pick_color = UInt(0)
    pick_size = typemax(Int)
    found = false
    for (col, members) in groups1
        sz = length(members)
        sz == length(get(groups2, col, _EMPTY_BNODES)) || return false
        if sz > 1 && (!found || sz < pick_size || (sz == pick_size && col < pick_color))
            pick_color = col
            pick_size = sz
            found = true
        end
    end

    if !found
        # Discrete partition: colors define the candidate bijection g1→g2.
        # MANDATORY verification by actual triple correspondence.
        mapping = Dict{BNode,BNode}()
        for (col, members) in groups1
            mapping[members[1]] = groups2[col][1]
        end
        return Set(_remap_triple(t, mapping) for t in triples1) == target2
    end

    members1 = sort(groups1[pick_color], by = b -> b.id)
    members2 = sort(groups2[pick_color], by = b -> b.id)
    b1 = members1[1]  # any member works: an isomorphism must map it into the same class
    fresh = hash((:individuated, depth, pick_color))
    for b2 in members2
        nc1 = copy(c1)
        nc2 = copy(c2)
        nc1[b1] = fresh
        nc2[b2] = fresh
        if _iso_backtrack(triples1, target2, bn1, inc1, bn2, inc2, nc1, nc2, depth + 1)
            return true
        end
    end
    false
end

"""
Compute a refinement-stable labeling for the blank nodes of `triples`.
Isomorphic graphs always produce the same label multiset; non-isomorphic
graphs may collide (refinement is not a complete invariant).
"""
function _refined_labeling(triples::Vector{Triple})
    bnodes = _collect_bnodes(triples)
    isempty(bnodes) && return Dict{BNode,UInt}()
    incidence = _build_incidence(triples, bnodes)
    colors = Dict{BNode,UInt}(b => UInt(0) for b in bnodes)
    _refine_stable!(colors, bnodes, incidence)
end

"""
Canonical-ish form for hashing: sorted triple signatures under the
refinement-stable labeling. Invariant under blank node relabeling. Used by
`graph_hash` only — NOT a sound isomorphism test on its own (see
`_iso_backtrack` for the sound check).
"""
function _canonical_form(triples::Vector{Triple})
    colors = _refined_labeling(triples)
    sort!([hash((_term_sig(t.subject, colors),
                 hash(t.predicate),
                 _term_sig(t.object, colors))) for t in triples])
end

"""
Sound blank node isomorphism check: color refinement + individuation with
backtracking, with mandatory verification of the final bijection.
"""
function _check_bnode_isomorphism(bnode_triples1::Vector{Triple},
                                  bnode_triples2::Vector{Triple})
    bn1 = _collect_bnodes(bnode_triples1)
    bn2 = _collect_bnodes(bnode_triples2)
    length(bn1) != length(bn2) && return false
    inc1 = _build_incidence(bnode_triples1, bn1)
    inc2 = _build_incidence(bnode_triples2, bn2)
    c1 = Dict{BNode,UInt}(b => UInt(0) for b in bn1)
    c2 = Dict{BNode,UInt}(b => UInt(0) for b in bn2)
    _iso_backtrack(bnode_triples1, Set(bnode_triples2), bn1, inc1, bn2, inc2, c1, c2, 0)
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
blank-node-containing triples are checked via color refinement plus
individuation-and-backtracking, and the resulting bijection is verified by
exact triple correspondence — the check is sound (no false positives) and
complete, while remaining polynomial on typical RDF graphs.

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

Compute a hash of an RDF graph that is invariant under blank node
relabeling. Two isomorphic graphs always produce the same hash.

The blank node portion is hashed from the color-refinement-stable labeling
(see `_refined_labeling`). Refinement is not a complete isomorphism
invariant, so rare collisions between *non-isomorphic* graphs are possible
(e.g. unions of regular cycles with identical local structure); use
[`isomorphic`](@ref) for a definitive answer. This is the usual hash
contract: equal hashes are necessary but not sufficient for equality.
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
