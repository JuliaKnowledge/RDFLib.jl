# ─── CLI tools — rdfpipe and csv2rdf ─────────────────────────────────

import CSV
import Tables

# ─── rdfpipe ────────────────────────────────────────────────────────

"""
    rdfpipe(input::AbstractString, input_format::SerializationFormat,
            output_format::SerializationFormat) -> String

Convert RDF data between serialization formats.
"""
function rdfpipe(input::AbstractString, input_format::SerializationFormat,
                 output_format::SerializationFormat)
    g = RDFGraph()
    parse_rdf!(g, input, input_format)
    serialize(g, output_format)
end

# ─── csv2rdf ────────────────────────────────────────────────────────

"""
    _uri_encode(s::AbstractString) -> String

Percent-encode characters that are not safe in URI path segments.
"""
function _uri_encode(s::AbstractString)
    buf = IOBuffer()
    for c in s
        if isletter(c) || isdigit(c) || c in ('_', '.', '-')
            write(buf, c)
        else
            bytes = Vector{UInt8}(string(c))
            for b in bytes
                write(buf, '%')
                write(buf, uppercase(string(b, base=16, pad=2)))
            end
        end
    end
    String(take!(buf))
end

"""
    csv2rdf(csv_data::AbstractString, base_uri::AbstractString;
            subject_column::Union{String,Int}=1,
            predicate_prefix::AbstractString="") -> RDFGraph

Convert CSV data to RDF triples. Each row becomes a resource, each column a predicate.

- `subject_column`: column name or 1-based index used to generate subject URIs
- `predicate_prefix`: URI prefix for predicate URIs (defaults to `base_uri`)
"""
function csv2rdf(csv_data::AbstractString, base_uri::AbstractString;
                 subject_column::Union{String,Int}=1,
                 predicate_prefix::AbstractString="")
    g = RDFGraph()
    tbl = CSV.File(IOBuffer(csv_data))
    cols = Tables.columnnames(tbl)

    prefix = isempty(predicate_prefix) ? base_uri : predicate_prefix
    subj_col_sym = if subject_column isa Int
        cols[subject_column]
    else
        Symbol(subject_column)
    end

    for row in tbl
        subj_val = string(Tables.getcolumn(row, subj_col_sym))

        subject = if startswith(subj_val, "http://") || startswith(subj_val, "https://")
            URIRef(subj_val)
        else
            URIRef(base_uri * _uri_encode(subj_val))
        end

        for col in cols
            val = Tables.getcolumn(row, col)
            ismissing(val) && continue

            predicate = URIRef(prefix * _uri_encode(string(col)))

            object = if val isa Bool
                Literal(val)
            elseif val isa Integer
                Literal(val)
            elseif val isa AbstractFloat
                Literal(val)
            else
                Literal(string(val))
            end

            add!(g, Triple(subject, predicate, object))
        end
    end

    g
end
