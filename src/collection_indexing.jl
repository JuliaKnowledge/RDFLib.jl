# ─── Collection Indexing Support ─────────────────────────────────────

"""
    CollectionView(g::RDFGraph, head::Node)

A view into an RDF collection in a graph that supports indexing and iteration.
"""
struct CollectionView
    graph::RDFGraph
    head::Node
end

"""Access a collection item by 1-based index."""
function Base.getindex(cv::CollectionView, i::Int)
    items = collect_list(cv.graph, cv.head)
    1 <= i <= length(items) || throw(BoundsError(cv, i))
    items[i]
end

"""Get the length of a collection."""
function Base.length(cv::CollectionView)
    length(collect_list(cv.graph, cv.head))
end

"""Iterate over collection items."""
function Base.iterate(cv::CollectionView)
    items = collect_list(cv.graph, cv.head)
    isempty(items) ? nothing : (items[1], (items, 2))
end

function Base.iterate(cv::CollectionView, state)
    items, idx = state
    idx > length(items) ? nothing : (items[idx], (items, idx + 1))
end

Base.eltype(::Type{CollectionView}) = Identifier

"""Create a CollectionView for a collection in the graph."""
function collection_view(g::RDFGraph, head::Node)
    CollectionView(g, head)
end

"""Get items from a collection reachable via subject/predicate."""
function collection_view(g::RDFGraph, subject::Node, predicate::URIRef)
    heads = collect(objects(g, subject, predicate))
    isempty(heads) && throw(ArgumentError("No collection found at $subject $predicate"))
    heads[1] isa Node || throw(ArgumentError("Collection head must be a Node"))
    CollectionView(g, heads[1]::Node)
end
