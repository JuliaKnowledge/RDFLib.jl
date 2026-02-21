# ─── Quad ───────────────────────────────────────────────────────────

"""
    Quad(subject, predicate, object, graph)

An RDF quad — a triple with a graph context.
"""
struct Quad
    subject::Node
    predicate::URIRef
    object::Identifier
    graph::Union{URIRef, Nothing}  # nothing = default graph
end

Quad(t::Triple, g::Union{URIRef, Nothing}=nothing) = Quad(t.subject, t.predicate, t.object, g)
Triple(q::Quad) = Triple(q.subject, q.predicate, q.object)

Base.show(io::IO, q::Quad) = print(io, "(", q.subject, ", ", q.predicate, ", ", q.object, ", ", something(q.graph, "default"), ")")
Base.:(==)(a::Quad, b::Quad) = a.subject == b.subject && a.predicate == b.predicate && a.object == b.object && a.graph == b.graph
function Base.hash(a::Quad, h::UInt)
    hash(a.graph, hash(a.object, hash(a.predicate, hash(a.subject, hash(:Quad, h)))))
end

# ─── Dataset ────────────────────────────────────────────────────────

"""
    Dataset()

An RDF Dataset: a default graph plus zero or more named graphs.

# Examples
```julia
ds = Dataset()
add!(ds, Triple(EX("s"), EX("p"), EX("o")))  # adds to default graph
add!(ds, Triple(EX("s"), EX("p2"), EX("o2")), EX("graph1"))  # named graph

for q in quads(ds)
    println(q)
end
```
"""
mutable struct Dataset
    default_graph::RDFGraph
    named_graphs::Dict{URIRef, RDFGraph}
    namespace_manager::NamespaceManager
end

function Dataset()
    nsm = NamespaceManager()
    Dataset(RDFGraph(), Dict{URIRef, RDFGraph}(), nsm)
end

"""
    add!(ds::Dataset, triple, graph_name=nothing)

Add a triple to the default graph (graph_name=nothing) or a named graph.
"""
function add!(ds::Dataset, t::Triple, graph_name::Union{URIRef, Nothing}=nothing)
    g = _get_or_create_graph!(ds, graph_name)
    add!(g, t)
    ds
end

function add!(ds::Dataset, s::Node, p::URIRef, o::Identifier, graph_name::Union{URIRef, Nothing}=nothing)
    add!(ds, Triple(s, p, o), graph_name)
end

"""
    remove!(ds::Dataset, pattern, graph_name=nothing)

Remove matching triples from a specific graph or all graphs if graph_name is nothing.
"""
function remove!(ds::Dataset, pattern::TriplePattern, graph_name::Union{URIRef, Nothing}=nothing)
    if isnothing(graph_name)
        # Remove from all graphs
        remove!(ds.default_graph, pattern)
        for g in values(ds.named_graphs)
            remove!(g, pattern)
        end
    else
        g = get(ds.named_graphs, graph_name, nothing)
        !isnothing(g) && remove!(g, pattern)
    end
    ds
end

"""
    get_graph(ds::Dataset, name=nothing) -> RDFGraph

Get the default graph (name=nothing) or a named graph.
"""
function get_graph(ds::Dataset, name::Union{URIRef, Nothing}=nothing)
    isnothing(name) ? ds.default_graph : get(ds.named_graphs, name, nothing)
end

"""
    add_graph(ds::Dataset, name::URIRef) -> RDFGraph

Add a named graph and return it.
"""
function add_graph(ds::Dataset, name::URIRef)
    _get_or_create_graph!(ds, name)
end

"""
    remove_graph(ds::Dataset, name::URIRef)

Remove a named graph.
"""
function remove_graph(ds::Dataset, name::URIRef)
    delete!(ds.named_graphs, name)
    ds
end

"""
    graphs(ds::Dataset)

Iterate over all (name, graph) pairs. Default graph has name=nothing.
"""
function graphs(ds::Dataset)
    Channel{Tuple{Union{URIRef, Nothing}, RDFGraph}}() do ch
        put!(ch, (nothing, ds.default_graph))
        for (name, g) in ds.named_graphs
            put!(ch, (name, g))
        end
    end
end

"""
    contexts(ds::Dataset)

Iterate over all graph identifiers (including nothing for default graph).
"""
function contexts(ds::Dataset)
    Channel{Union{URIRef, Nothing}}() do ch
        put!(ch, nothing)
        for name in keys(ds.named_graphs)
            put!(ch, name)
        end
    end
end

"""
    quads(ds::Dataset) -> iterator of Quad

Iterate all quads across all graphs.
"""
function quads(ds::Dataset)
    Channel{Quad}() do ch
        for t in ds.default_graph
            put!(ch, Quad(t, nothing))
        end
        for (name, g) in ds.named_graphs
            for t in g
                put!(ch, Quad(t, name))
            end
        end
    end
end

"""
    quads(ds::Dataset, pattern) -> iterator of Quad

Iterate quads matching a pattern (s, p, o, graph_name).
"""
function quads(ds::Dataset, pattern::Tuple{Union{Node,Nothing}, Union{URIRef,Nothing}, Union{Identifier,Nothing}, Union{URIRef,Nothing}})
    s, p, o, gname = pattern
    triple_pattern = (s, p, o)
    Channel{Quad}() do ch
        if isnothing(gname)
            # Search all graphs
            for t in triples(ds.default_graph, triple_pattern)
                put!(ch, Quad(t, nothing))
            end
            for (name, g) in ds.named_graphs
                for t in triples(g, triple_pattern)
                    put!(ch, Quad(t, name))
                end
            end
        else
            # Search specific named graph
            g = get(ds.named_graphs, gname, nothing)
            if !isnothing(g)
                for t in triples(g, triple_pattern)
                    put!(ch, Quad(t, gname))
                end
            end
        end
    end
end

function Base.length(ds::Dataset)
    n = length(ds.default_graph)
    for g in values(ds.named_graphs)
        n += length(g)
    end
    n
end

Base.isempty(ds::Dataset) = length(ds) == 0

function Base.show(io::IO, ds::Dataset)
    ng = length(ds.named_graphs)
    nq = length(ds)
    print(io, "Dataset ($nq quads, $(ng) named graphs)")
end

"""
    bind!(ds::Dataset, prefix, namespace)

Bind a namespace prefix on this dataset's namespace manager.
"""
bind!(ds::Dataset, prefix::AbstractString, ns) = bind!(ds.namespace_manager, prefix, ns)

"""
    namespaces(ds::Dataset)

List all namespace bindings.
"""
namespaces(ds::Dataset) = namespaces(ds.namespace_manager)

# ─── Internal helpers ───────────────────────────────────────────────

function _get_or_create_graph!(ds::Dataset, name::Nothing)
    ds.default_graph
end

function _get_or_create_graph!(ds::Dataset, name::URIRef)
    if !haskey(ds.named_graphs, name)
        ds.named_graphs[name] = RDFGraph(identifier=name)
    end
    ds.named_graphs[name]
end
