# ─── RDF-specific Exception Types ────────────────────────────────────

"""Base exception for RDFLib errors."""
abstract type RDFError <: Exception end

"""Error during parsing of RDF data."""
struct ParserError <: RDFError
    message::String
    format::String
    line::Int
end
ParserError(msg::AbstractString) = ParserError(msg, "", 0)
ParserError(msg::AbstractString, fmt::AbstractString) = ParserError(msg, fmt, 0)
Base.showerror(io::IO, e::ParserError) = print(io, "ParserError: ", e.message,
    isempty(e.format) ? "" : " (format: $(e.format))",
    e.line > 0 ? " at line $(e.line)" : "")

"""Error when a unique value was expected but multiple were found."""
struct UniquenessError <: RDFError
    message::String
end
Base.showerror(io::IO, e::UniquenessError) = print(io, "UniquenessError: ", e.message)

"""Error during SPARQL query processing."""
struct SPARQLError <: RDFError
    message::String
end
Base.showerror(io::IO, e::SPARQLError) = print(io, "SPARQLError: ", e.message)

"""Error during serialization."""
struct SerializationError <: RDFError
    message::String
    format::String
end
SerializationError(msg::AbstractString) = SerializationError(msg, "")
Base.showerror(io::IO, e::SerializationError) = print(io, "SerializationError: ", e.message,
    isempty(e.format) ? "" : " (format: $(e.format))")

"""Error in namespace resolution."""
struct NamespaceError <: RDFError
    message::String
end
Base.showerror(io::IO, e::NamespaceError) = print(io, "NamespaceError: ", e.message)

"""Error in store operations."""
struct StoreError <: RDFError
    message::String
end
Base.showerror(io::IO, e::StoreError) = print(io, "StoreError: ", e.message)

"""
    unique_value(g::RDFGraph, s::Node, p::URIRef) -> Identifier

Get the unique object for a subject+predicate. Throws UniquenessError if not exactly one.
"""
function unique_value(g::RDFGraph, s::Node, p::URIRef)
    objs = collect(objects(g, s, p))
    length(objs) == 0 && throw(UniquenessError("No value found for $s $p"))
    length(objs) > 1 && throw(UniquenessError("Multiple values found for $s $p: got $(length(objs))"))
    objs[1]
end
