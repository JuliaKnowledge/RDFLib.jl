# ─── BatchAddGraph ───────────────────────────────────────────────────
#
# Optimized bulk insertion wrapper that buffers triples and flushes
# them to the underlying graph in batches.

"""
    BatchAddGraph(g::RDFGraph; batch_size=1000)

Wrap a graph for optimized bulk insertion. Triples are buffered and
flushed to the underlying graph when the buffer reaches `batch_size`.

# Examples
```julia
g = RDFGraph()
bag = BatchAddGraph(g; batch_size=100)
EX = Namespace("http://example.org/")
for i in 1:250
    add!(bag, Triple(EX("s\$i"), EX("p"), EX("o\$i")))
end
close!(bag)  # flush remaining
length(g)    # 250
```
"""
mutable struct BatchAddGraph
    graph::RDFGraph
    buffer::Vector{Triple}
    batch_size::Int
end

function BatchAddGraph(g::RDFGraph; batch_size::Int=1000)
    BatchAddGraph(g, Triple[], batch_size)
end

"""
    add!(bag::BatchAddGraph, t::Triple)

Buffer a triple for later insertion. Auto-flushes when buffer reaches batch_size.
"""
function add!(bag::BatchAddGraph, t::Triple)
    push!(bag.buffer, t)
    if length(bag.buffer) >= bag.batch_size
        flush!(bag)
    end
    bag
end

"""
    flush!(bag::BatchAddGraph)

Write all buffered triples to the underlying graph.
"""
function flush!(bag::BatchAddGraph)
    for t in bag.buffer
        add!(bag.graph, t)
    end
    empty!(bag.buffer)
    bag
end

"""
    close!(bag::BatchAddGraph)

Flush remaining buffered triples and return the underlying graph.
"""
function close!(bag::BatchAddGraph)
    flush!(bag)
    bag.graph
end

Base.length(bag::BatchAddGraph) = length(bag.graph) + length(bag.buffer)
