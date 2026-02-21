# ─── RDF Collections & Containers ────────────────────────────────────

const RDF_FIRST = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
const RDF_REST  = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
const RDF_NIL   = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
const RDF_TYPE  = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
const RDF_BAG   = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#Bag")
const RDF_SEQ   = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#Seq")
const RDF_ALT   = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#Alt")

# ─── Container Membership Properties ────────────────────────────────

"""
    container_membership_property(n::Int) -> URIRef

Return the URIRef for rdf:_n (container membership property).
"""
container_membership_property(n::Int) = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#_$n")

# ─── RDF Collections (rdf:List) ─────────────────────────────────────

"""
    Collection(items::Vector{<:Identifier}) -> (Node, Vector{Triple})

Create an RDF Collection (rdf:List) from a vector of items.
Returns the head node and the triples that make up the linked list.
An empty collection returns `(rdf:nil, [])`.

# Example
```julia
head, triples = Collection([Literal("a"), Literal("b"), Literal("c")])
for t in triples; add!(g, t); end
```
"""
function Collection(items::Vector{<:Identifier})
    isempty(items) && return (RDF_NIL, Triple[])

    nodes = [BNode() for _ in items]
    tris = Triple[]
    for (i, item) in enumerate(items)
        push!(tris, Triple(nodes[i], RDF_FIRST, item))
        rest = i < length(items) ? nodes[i+1] : RDF_NIL
        push!(tris, Triple(nodes[i], RDF_REST, rest))
    end
    return (nodes[1], tris)
end

"""
    add_collection!(g::RDFGraph, subject::Node, predicate::URIRef, items::Vector{<:Identifier})

Add an RDF collection to the graph, linked from `subject` via `predicate`.
"""
function add_collection!(g::RDFGraph, subject::Node, predicate::URIRef, items::Vector{<:Identifier})
    head, tris = Collection(items)
    add!(g, Triple(subject, predicate, head))
    for t in tris
        add!(g, t)
    end
    g
end

"""
    collect_list(g::RDFGraph, head::Node) -> Vector{Identifier}

Traverse an rdf:List starting at `head` and collect all items.
Returns an empty vector if `head` is `rdf:nil`.
"""
function collect_list(g::RDFGraph, head::Node)
    result = Identifier[]
    head == RDF_NIL && return result
    current = head
    while true
        firsts = collect(objects(g, current, RDF_FIRST))
        isempty(firsts) && break
        push!(result, firsts[1])
        rests = collect(objects(g, current, RDF_REST))
        isempty(rests) && break
        next = rests[1]
        next == RDF_NIL && break
        next isa Node || break
        current = next
    end
    return result
end

# ─── RDF Containers (rdf:Bag, rdf:Seq, rdf:Alt) ────────────────────

const _CONTAINER_TYPES = Dict{Symbol, URIRef}(
    :Bag => RDF_BAG,
    :Seq => RDF_SEQ,
    :Alt => RDF_ALT,
)

"""
    add_container!(g::RDFGraph, node::Node, container_type::Symbol, items::Vector{<:Identifier})

Create an RDF Container (`:Bag`, `:Seq`, or `:Alt`) in the graph.
Adds `rdf:type` and `rdf:_1`, `rdf:_2`, … membership triples.

# Example
```julia
bag = URIRef("http://example.org/mybag")
add_container!(g, bag, :Bag, [Literal("a"), Literal("b")])
```
"""
function add_container!(g::RDFGraph, node::Node, container_type::Symbol, items::Vector{<:Identifier})
    type_uri = get(_CONTAINER_TYPES, container_type, nothing)
    type_uri === nothing && throw(ArgumentError("Unknown container type: $container_type. Use :Bag, :Seq, or :Alt."))
    add!(g, Triple(node, RDF_TYPE, type_uri))
    for (i, item) in enumerate(items)
        add!(g, Triple(node, container_membership_property(i), item))
    end
    g
end

"""
    collect_container(g::RDFGraph, node::Node) -> Vector{Identifier}

Read items from an RDF container by collecting `rdf:_1`, `rdf:_2`, … members in order.
"""
function collect_container(g::RDFGraph, node::Node)
    rdf_ns = "http://www.w3.org/1999/02/22-rdf-syntax-ns#_"
    members = Pair{Int, Identifier}[]
    for t in triples(g, (node, nothing, nothing))
        pval = t.predicate.value
        if startswith(pval, rdf_ns)
            nstr = pval[length(rdf_ns)+1:end]
            n = tryparse(Int, nstr)
            n !== nothing && push!(members, n => t.object)
        end
    end
    sort!(members; by=first)
    return Identifier[p.second for p in members]
end
