# ─── ReadOnlyGraphAggregate ──────────────────────────────────────────
#
# A read-only union view over multiple RDFGraph objects.

"""
    ReadOnlyGraphAggregate(graphs::Vector{<:RDFGraph})

A read-only aggregate view over multiple RDF graphs. Queries search
all constituent graphs. Mutation operations throw an error.

# Examples
```julia
g1, g2 = RDFGraph(), RDFGraph()
EX = Namespace("http://example.org/")
add!(g1, Triple(EX("a"), EX("p"), EX("b")))
add!(g2, Triple(EX("c"), EX("p"), EX("d")))
agg = ReadOnlyGraphAggregate([g1, g2])
length(agg)  # 2
```
"""
struct ReadOnlyGraphAggregate
    _graphs::Vector{RDFGraph}
end

ReadOnlyGraphAggregate(gs::Vector{<:RDFGraph}) = ReadOnlyGraphAggregate(collect(RDFGraph, gs))

"""
    graphs(agg::ReadOnlyGraphAggregate)

Return the constituent graphs.
"""
graphs(agg::ReadOnlyGraphAggregate) = agg._graphs

"""
    triples(agg::ReadOnlyGraphAggregate, pattern::TriplePattern)

Search all constituent graphs for matching triples.
"""
function triples(agg::ReadOnlyGraphAggregate, pattern::TriplePattern)
    Channel{Triple}() do ch
        for g in agg._graphs
            for t in triples(g, pattern)
                put!(ch, t)
            end
        end
    end
end

triples(agg::ReadOnlyGraphAggregate) = triples(agg, (nothing, nothing, nothing))

"""
    length(agg::ReadOnlyGraphAggregate)

Total triple count across all graphs (may count duplicates).
"""
function Base.length(agg::ReadOnlyGraphAggregate)
    sum(length(g) for g in agg._graphs; init=0)
end

Base.isempty(agg::ReadOnlyGraphAggregate) = all(isempty(g) for g in agg._graphs)

# ─── Read-only enforcement ──────────────────────────────────────────

function add!(agg::ReadOnlyGraphAggregate, t::Triple)
    error("ReadOnlyGraphAggregate does not support add! — it is read-only")
end

function remove!(agg::ReadOnlyGraphAggregate, pattern::TriplePattern)
    error("ReadOnlyGraphAggregate does not support remove! — it is read-only")
end

# ─── Iteration ──────────────────────────────────────────────────────

function Base.iterate(agg::ReadOnlyGraphAggregate)
    ch = triples(agg)
    result = iterate(ch)
    isnothing(result) && return nothing
    (result[1], ch)
end

function Base.iterate(agg::ReadOnlyGraphAggregate, ch)
    result = iterate(ch)
    isnothing(result) && return nothing
    (result[1], ch)
end

Base.eltype(::Type{ReadOnlyGraphAggregate}) = Triple

function Base.show(io::IO, agg::ReadOnlyGraphAggregate)
    ng = length(agg._graphs)
    n = length(agg)
    print(io, "ReadOnlyGraphAggregate ($n triples, $ng graphs)")
end
