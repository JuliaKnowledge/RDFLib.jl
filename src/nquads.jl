# ─── N-Quads Format ─────────────────────────────────────────────────
# Extension of N-Triples with a 4th graph component:
#   <subject> <predicate> <object> <graph> .
# Default graph triples omit the graph component.
# NQuadsFormat is defined in formats.jl

# ─── Serialization ──────────────────────────────────────────────────

"""
    serialize_nquads(io::IO, ds::Dataset)

Serialize a dataset as N-Quads.
"""
function serialize_nquads(io::IO, ds::Dataset)
    for q in quads(ds)
        write(io, _nt_term(q.subject))
        write(io, " ")
        write(io, _nt_term(q.predicate))
        write(io, " ")
        write(io, _nt_term(q.object))
        if !isnothing(q.graph)
            write(io, " ")
            write(io, _nt_term(q.graph))
        end
        write(io, " .\n")
    end
end

"""
    serialize_nquads(ds::Dataset) -> String

Serialize a dataset to an N-Quads string.
"""
function serialize_nquads(ds::Dataset)
    buf = IOBuffer()
    serialize_nquads(buf, ds)
    String(take!(buf))
end

# ─── Parsing ────────────────────────────────────────────────────────

const _NQ_LINE = r"^\s*((?:<[^>]*>)|(?:_:[A-Za-z0-9_]+))\s+((?:<[^>]*>))\s+((?:<[^>]*>)|(?:_:[A-Za-z0-9_]+)|(?:\"(?:[^\"\\]|\\.)*\"(?:@[a-zA-Z\-]+|\^\^<[^>]*>)?))\s*(?:((?:<[^>]*>)|(?:_:[A-Za-z0-9_]+))\s*)?\.\s*$"

"""
    parse_nquads!(ds::Dataset, io::IO) -> Dataset

Parse N-Quads from an IO stream into a dataset.
"""
function parse_nquads!(ds::Dataset, io::IO)
    for line in eachline(io)
        stripped = strip(line)
        isempty(stripped) && continue
        startswith(stripped, '#') && continue

        m = match(_NQ_LINE, stripped)
        if isnothing(m)
            @warn "Skipping invalid N-Quads line: $stripped"
            continue
        end

        subj = _parse_nt_node(m.captures[1])
        pred_match = match(_NT_URIREF, m.captures[2])
        pred = URIRef(pred_match.captures[1])
        obj = _parse_nt_object(m.captures[3])

        # 4th component: graph name (optional)
        graph_name = nothing
        if !isnothing(m.captures[4])
            graph_node = _parse_nt_node(m.captures[4])
            if graph_node isa URIRef
                graph_name = graph_node
            end
        end

        add!(ds, Triple(subj, pred, obj), graph_name)
    end
    ds
end

"""
    parse_nquads!(ds::Dataset, s::AbstractString) -> Dataset

Parse N-Quads from a string into a dataset.
"""
function parse_nquads!(ds::Dataset, s::AbstractString)
    parse_nquads!(ds, IOBuffer(s))
end

"""
    parse_nquads(source) -> Dataset

Parse N-Quads from a string or IO stream into a new dataset.
"""
function parse_nquads(source)
    ds = Dataset()
    if source isa IO || source isa IOBuffer
        parse_nquads!(ds, source)
    else
        parse_nquads!(ds, String(source))
    end
end

# ─── High-level API registration ───────────────────────────────────

serialize(io::IO, ds::Dataset, ::NQuadsFormat) = serialize_nquads(io, ds)

function serialize(ds::Dataset, fmt::NQuadsFormat=NQuadsFormat())
    buf = IOBuffer()
    serialize(buf, ds, fmt)
    String(take!(buf))
end
