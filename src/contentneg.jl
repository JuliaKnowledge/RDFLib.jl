# ─── Content Negotiation & URL/File Loading ──────────────────────────

using Downloads

# ─── MIME Type Registry ──────────────────────────────────────────────

"""
    mime_type(fmt::SerializationFormat) -> String

Return the primary MIME type for a serialization format.
"""
mime_type(::NTriplesFormat) = "application/n-triples"
mime_type(::TurtleFormat) = "text/turtle"
mime_type(::NQuadsFormat) = "application/n-quads"
mime_type(::RDFXMLFormat) = "application/rdf+xml"
mime_type(::TriGFormat) = "application/trig"
mime_type(::JSONLDFormat) = "application/ld+json"

"""
    format_from_mime(mime::AbstractString) -> SerializationFormat

Determine the serialization format from a MIME type string.
Parameters after `;` (e.g. charset) are stripped before matching.
"""
function format_from_mime(mime::AbstractString)
    base_mime = lowercase(strip(split(mime, ';')[1]))

    mime_map = Dict(
        "application/n-triples" => NTriplesFormat(),
        "text/turtle"           => TurtleFormat(),
        "application/x-turtle"  => TurtleFormat(),
        "application/n-quads"   => NQuadsFormat(),
        "application/rdf+xml"   => RDFXMLFormat(),
        "application/xml"       => RDFXMLFormat(),
        "text/xml"              => RDFXMLFormat(),
        "application/trig"      => TriGFormat(),
        "application/ld+json"   => JSONLDFormat(),
        "application/json"      => JSONLDFormat(),
        "text/n3"               => TurtleFormat(),
        "text/plain"            => NTriplesFormat(),
    )

    fmt = get(mime_map, base_mime, nothing)
    isnothing(fmt) && throw(ArgumentError("Unknown MIME type: $mime"))
    fmt
end

# ─── Accept Header Construction ──────────────────────────────────────

"""
    accept_header(; preferred=nothing) -> String

Build an HTTP Accept header for content negotiation.
Lists all supported RDF formats with quality values.
If `preferred` is given, that format receives `q=1.0`.
"""
function accept_header(; preferred::Union{SerializationFormat,Nothing}=nothing)
    formats = [
        ("text/turtle",           0.9),
        ("application/ld+json",   0.8),
        ("application/rdf+xml",   0.7),
        ("application/n-triples", 0.6),
        ("application/n-quads",   0.5),
        ("application/trig",      0.4),
    ]

    parts = String[]
    for (mime, q) in formats
        if !isnothing(preferred) && mime_type(preferred) == mime
            push!(parts, "$mime;q=1.0")
        else
            push!(parts, "$mime;q=$q")
        end
    end
    join(parts, ", ")
end

# ─── URL Format Detection ───────────────────────────────────────────

"""
    _detect_format_from_url(url) -> SerializationFormat

Detect RDF format from a URL's path extension, ignoring query/fragment.
Falls back to `TurtleFormat()` if no extension is recognized.
"""
function _detect_format_from_url(url::AbstractString)
    path = split(split(url, '?')[1], '#')[1]
    filename = split(path, '/')[end]

    if occursin('.', filename)
        ext = lowercase(split(filename, '.')[end])
        ext_map = Dict(
            "ttl"      => TurtleFormat(),
            "turtle"   => TurtleFormat(),
            "nt"       => NTriplesFormat(),
            "ntriples" => NTriplesFormat(),
            "nq"       => NQuadsFormat(),
            "nquads"   => NQuadsFormat(),
            "rdf"      => RDFXMLFormat(),
            "xml"      => RDFXMLFormat(),
            "owl"      => RDFXMLFormat(),
            "trig"     => TriGFormat(),
            "jsonld"   => JSONLDFormat(),
            "json"     => JSONLDFormat(),
            "n3"       => TurtleFormat(),
        )
        fmt = get(ext_map, ext, nothing)
        !isnothing(fmt) && return fmt
    end

    TurtleFormat()
end

# ─── Load from URL ──────────────────────────────────────────────────

"""
    load_rdf(url::AbstractString; format=nothing) -> RDFGraph

Load an RDF graph from a URL with automatic content negotiation.

If `format` is not specified, the format is determined from the
server's Content-Type response header, falling back to URL extension detection.

# Examples
```julia
g = load_rdf("http://example.org/data.ttl")
g = load_rdf("http://example.org/data", format=TurtleFormat())
```
"""
function load_rdf(url::AbstractString; format::Union{SerializationFormat,Nothing}=nothing)
    hdrs = Pair{String,String}["Accept" => accept_header(preferred=format)]

    buf = IOBuffer()
    resp = try
        Downloads.request(url; headers=hdrs, output=buf)
    catch e
        throw(ErrorException("Failed to fetch $url: $e"))
    end

    content = String(take!(buf))

    if isnothing(format)
        # Try Content-Type header first
        content_type = ""
        for (k, v) in resp.headers
            if lowercase(k) == "content-type"
                content_type = v
                break
            end
        end

        if !isempty(content_type)
            try
                format = format_from_mime(content_type)
            catch
                format = _detect_format_from_url(url)
            end
        else
            format = _detect_format_from_url(url)
        end
    end

    parse_rdf(content, format)
end

# ─── File Load / Save ───────────────────────────────────────────────

"""
    save_rdf(g::RDFGraph, filename::AbstractString; format=nothing)

Save an RDF graph to a file. Format is detected from the file extension
if not specified.

# Examples
```julia
save_rdf(g, "output.ttl")
save_rdf(g, "output.rdf", format=RDFXMLFormat())
```
"""
function save_rdf(g::RDFGraph, filename::AbstractString;
                  format::Union{SerializationFormat,Nothing}=nothing)
    if isnothing(format)
        format = _detect_format(filename)
    end
    open(filename, "w") do io
        serialize(io, g, format)
    end
    filename
end

"""
    load_rdf_file(filename::AbstractString; format=nothing) -> RDFGraph

Load an RDF graph from a local file. Format is detected from the file
extension if not specified.

# Examples
```julia
g = load_rdf_file("data.ttl")
g = load_rdf_file("data.rdf", format=RDFXMLFormat())
```
"""
function load_rdf_file(filename::AbstractString;
                       format::Union{SerializationFormat,Nothing}=nothing)
    if isnothing(format)
        format = _detect_format(filename)
    end
    content = read(filename, String)
    parse_rdf(content, format)
end
