# ─── Serialization Format Types ──────────────────────────────────────
# Defined early so format implementations can reference them.

"""
    SerializationFormat

Abstract type for RDF serialization formats.
Dispatch on format types instead of rdflib's plugin registry.
"""
abstract type SerializationFormat end

"""N-Triples format (`.nt`)"""
struct NTriplesFormat <: SerializationFormat end

"""Turtle format (`.ttl`)"""
struct TurtleFormat <: SerializationFormat end

"""N-Quads format (`.nq`)"""
struct NQuadsFormat <: SerializationFormat end

"""RDF/XML format (`.rdf`, `.xml`)"""
struct RDFXMLFormat <: SerializationFormat end

"""TriG format (`.trig`)"""
struct TriGFormat <: SerializationFormat end

"""JSON-LD format (`.jsonld`)"""
struct JSONLDFormat <: SerializationFormat end

"""Notation3 (N3) format (`.n3`)"""
struct N3Format <: SerializationFormat end

"""Apache Arrow IPC format (`.arrow`). Columnar binary; fast load/save and
zero-copy interop with maplib/Polars/DuckDB."""
struct ArrowFormat <: SerializationFormat end

"""Detect serialization format from file extension."""
function _detect_format(filename::AbstractString)
    ext = lowercase(splitext(filename)[2])
    if ext == ".nt" || ext == ".ntriples"
        NTriplesFormat()
    elseif ext == ".ttl" || ext == ".turtle"
        TurtleFormat()
    elseif ext == ".nq" || ext == ".nquads"
        NQuadsFormat()
    elseif ext == ".rdf" || ext == ".xml" || ext == ".rdfxml"
        RDFXMLFormat()
    elseif ext == ".trig"
        TriGFormat()
    elseif ext == ".jsonld" || ext == ".json"
        JSONLDFormat()
    elseif ext == ".n3"
        N3Format()
    elseif ext == ".arrow"
        ArrowFormat()
    else
        throw(ArgumentError("Cannot detect format from extension: $ext"))
    end
end
