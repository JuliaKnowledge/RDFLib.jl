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

"""
    parse_nquads!(ds::Dataset, io::IO) -> Dataset

Parse N-Quads from an IO stream into a dataset. Graph labels may be IRIs
or blank nodes. Malformed lines raise an `ArgumentError` reporting the
line number.
"""
function parse_nquads!(ds::Dataset, io::IO)
    lineno = 0
    for line in eachline(io)
        lineno += 1
        st = _nt_parse_statement(line, lineno, "N-Quads"; allow_graph=true)
        isnothing(st) && continue
        subj, pred, obj, graph_name = st
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
