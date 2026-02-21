# ─── High-level serialization/parsing API ────────────────────────────
# Format types are defined in formats.jl

# ─── serialize ──────────────────────────────────────────────────────

"""
    serialize(io::IO, g::RDFGraph, format::SerializationFormat)

Serialize a graph to an IO stream in the given format.

# Examples
```julia
g = RDFGraph()
add!(g, Triple(URIRef("http://example.org/s"), URIRef("http://example.org/p"), Literal("hello")))
io = IOBuffer()
serialize(io, g, NTriplesFormat())
```
"""
serialize(io::IO, g::RDFGraph, ::NTriplesFormat) = serialize_ntriples(io, g)

"""
    serialize(g::RDFGraph, format::SerializationFormat=NTriplesFormat()) -> String

Serialize a graph to a string in the given format. Defaults to N-Triples.

# Examples
```julia
g = RDFGraph()
add!(g, Triple(URIRef("http://example.org/s"), URIRef("http://example.org/p"), Literal("hello")))
str = serialize(g)                    # N-Triples (default)
str = serialize(g, TurtleFormat())    # Turtle format
```
"""
function serialize(g::RDFGraph, fmt::SerializationFormat=NTriplesFormat())
    buf = IOBuffer()
    serialize(buf, g, fmt)
    String(take!(buf))
end

"""
    serialize(filename::AbstractString, g::RDFGraph, format::SerializationFormat)

Serialize a graph to a file. The format must be specified explicitly.

# Examples
```julia
serialize("output.ttl", g, TurtleFormat())
```
"""
function serialize(filename::AbstractString, g::RDFGraph, fmt::SerializationFormat)
    open(filename, "w") do io
        serialize(io, g, fmt)
    end
end

# ─── parse_rdf ──────────────────────────────────────────────────────

"""
    parse_rdf!(g::RDFGraph, source, format::SerializationFormat) -> RDFGraph

Parse RDF from `source` (IO stream or string) into an existing graph, adding
to any triples already present.

# Examples
```julia
g = RDFGraph()
parse_rdf!(g, \"\"\"<http://example.org/s> <http://example.org/p> "hello" .\\n\"\"\", NTriplesFormat())
```
"""
parse_rdf!(g::RDFGraph, source, ::NTriplesFormat) = parse_ntriples!(g, source)

"""
    parse_rdf(source, format::SerializationFormat=NTriplesFormat()) -> RDFGraph

Parse RDF from `source` (IO stream or string) into a new graph. Defaults to N-Triples.

# Examples
```julia
g = parse_rdf(\"\"\"<http://example.org/s> <http://example.org/p> "hello" .\\n\"\"\", NTriplesFormat())
g = parse_rdf(open("data.ttl"), TurtleFormat())
```
"""
function parse_rdf(source, fmt::SerializationFormat=NTriplesFormat())
    g = RDFGraph()
    parse_rdf!(g, source, fmt)
end

"""
    parse_rdf(filename::AbstractString) -> RDFGraph

Parse RDF from a file, auto-detecting the format from the file extension.

Supported extensions: `.nt`, `.ttl`, `.nq`, `.rdf`/`.xml`, `.trig`, `.jsonld`/`.json`.

# Examples
```julia
g = parse_rdf("data.ttl")   # auto-detects Turtle
g = parse_rdf("data.nt")    # auto-detects N-Triples
```
"""
function parse_rdf(filename::AbstractString)
    fmt = _detect_format(filename)
    g = RDFGraph()
    open(filename) do io
        parse_rdf!(g, io, fmt)
    end
    g
end
