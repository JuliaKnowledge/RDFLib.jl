# ─── Chunked Serialization / Parsing ────────────────────────────────

"""
    serialize_chunked(g::RDFGraph, fmt::SerializationFormat, io::IO; chunk_size::Int=10000)

Serialize a graph in chunks to avoid building the entire output in memory.
For line-based formats (N-Triples, N-Quads), writes `chunk_size` triples at a
time with IO flushes between chunks. For other formats, falls back to normal
`serialize`.
"""
function serialize_chunked(g::RDFGraph, fmt::NTriplesFormat, io::IO; chunk_size::Int=10000)
    count = 0
    for t in g
        write(io, _nt_term(t.subject))
        write(io, " ")
        write(io, _nt_term(t.predicate))
        write(io, " ")
        write(io, _nt_term(t.object))
        write(io, " .\n")
        count += 1
        if count >= chunk_size
            flush(io)
            count = 0
        end
    end
    flush(io)
    nothing
end

function serialize_chunked(g::RDFGraph, fmt::NQuadsFormat, io::IO; chunk_size::Int=10000)
    count = 0
    graph_uri = g.identifier
    for t in g
        write(io, _nt_term(t.subject))
        write(io, " ")
        write(io, _nt_term(t.predicate))
        write(io, " ")
        write(io, _nt_term(t.object))
        if !isnothing(graph_uri)
            write(io, " ")
            write(io, _nt_term(graph_uri))
        end
        write(io, " .\n")
        count += 1
        if count >= chunk_size
            flush(io)
            count = 0
        end
    end
    flush(io)
    nothing
end

# Fallback for non-line-based formats
function serialize_chunked(g::RDFGraph, fmt::SerializationFormat, io::IO; chunk_size::Int=10000)
    serialize(io, g, fmt)
    nothing
end

"""
    serialize_chunked(g::RDFGraph, fmt::SerializationFormat, filename::AbstractString; chunk_size::Int=10000)

Serialize a graph to a file in chunks.
"""
function serialize_chunked(g::RDFGraph, fmt::SerializationFormat, filename::AbstractString; chunk_size::Int=10000)
    open(filename, "w") do io
        serialize_chunked(g, fmt, io; chunk_size=chunk_size)
    end
    nothing
end

"""
    parse_chunked(io::IO, fmt::NTriplesFormat; chunk_size::Int=10000) -> Channel{Triple}

Parse N-Triples from an IO stream in chunks, yielding triples through a Channel.

# Example
```julia
open("large.nt") do io
    for triple in parse_chunked(io, NTriplesFormat(); chunk_size=5000)
        # process triple
    end
end
```
"""
function parse_chunked(io::IO, fmt::NTriplesFormat; chunk_size::Int=10000)
    Channel{Triple}(chunk_size) do ch
        lines = String[]
        for line in eachline(io)
            stripped = strip(line)
            isempty(stripped) && continue
            startswith(stripped, '#') && continue
            push!(lines, stripped)
            if length(lines) >= chunk_size
                _parse_nt_chunk!(ch, lines)
                empty!(lines)
            end
        end
        if !isempty(lines)
            _parse_nt_chunk!(ch, lines)
        end
    end
end

function _parse_nt_chunk!(ch::Channel{Triple}, lines::Vector{String})
    for stripped in lines
        m = match(_NT_LINE, stripped)
        if isnothing(m)
            @warn "Skipping invalid N-Triples line: $stripped"
            continue
        end
        subj = _parse_nt_node(m.captures[1])
        pred_match = match(_NT_URIREF, m.captures[2])
        pred = URIRef(pred_match.captures[1])
        obj  = _parse_nt_object(m.captures[3])
        put!(ch, Triple(subj, pred, obj))
    end
end
