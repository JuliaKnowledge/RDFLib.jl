# ─── Tabular ↔ RDF Mapping ─────────────────────────────────────────
#
# Maps Tables.jl-compatible data (DataFrames, CSV, etc.) to RDF graphs
# and queries them with SPARQL, returning tabular results.
# Inspired by maplib (https://github.com/DataTreehouse/maplib).

import Tables

# ─── Column Type Hints ────────────────────────────────────────────

"""
Column type hint for RDF mapping: how table values map to RDF terms.
"""
abstract type ColumnType end

"""Values are IRIs (URIs). String values become URIRef nodes."""
struct IRIColumn <: ColumnType end

"""Values are typed literals with an explicit XSD datatype."""
struct LiteralColumn <: ColumnType
    datatype::URIRef
end

"""Values are language-tagged strings."""
struct LangColumn <: ColumnType
    lang::String
end

"""Auto-detect type from Julia value: Bool→xsd:boolean, Int→xsd:integer, etc."""
struct AutoColumn <: ColumnType end

# ─── RDF Template ─────────────────────────────────────────────────

"""
    RDFTemplate(; subject, properties...)

Defines how table columns map to RDF triples.

- `subject`: column name (Symbol) used to generate subject URIs
- `subject_prefix`: URI prefix prepended to subject values (if not already URIs)
- `properties`: Vector of `(predicate_uri, column_name, column_type)` tuples
- `types`: Vector of class URIs to assign via `rdf:type` to each subject
"""
struct RDFTemplate
    subject_column::Symbol
    subject_prefix::String
    properties::Vector{Tuple{URIRef, Symbol, ColumnType}}
    types::Vector{URIRef}
end

function RDFTemplate(;
    subject::Symbol,
    subject_prefix::AbstractString="",
    properties::AbstractVector=Tuple{URIRef, Symbol, ColumnType}[],
    types::AbstractVector{URIRef}=URIRef[])
    RDFTemplate(subject, String(subject_prefix),
        Tuple{URIRef, Symbol, ColumnType}[p for p in properties],
        URIRef[t for t in types])
end

# ─── RDF Mapping ──────────────────────────────────────────────────

"""
    RDFMapping(; graph=RDFGraph(), prefixes=Dict())

A mapping context that converts tabular data to RDF and supports SPARQL queries.

# Example
```julia
using DataFrames, RDFLib

m = RDFMapping()

df = DataFrame(
    id = ["http://example.org/Alice", "http://example.org/Bob"],
    name = ["Alice", "Bob"],
    age = [30, 25]
)

# Auto-map: column names become predicates
map_default!(m, df, :id; predicate_prefix="http://example.org/")

# Query with SPARQL
results = rdf_query(m, \"\"\"
    PREFIX ex: <http://example.org/>
    SELECT ?person ?name WHERE {
        ?person ex:name ?name .
    }
\"\"\")
```
"""
mutable struct RDFMapping
    graph::RDFGraph
    prefixes::Dict{String, String}
end

function RDFMapping(;
    graph::RDFGraph=RDFGraph(),
    prefixes::Dict{String,String}=Dict{String,String}())
    RDFMapping(graph, prefixes)
end

Base.length(m::RDFMapping) = length(m.graph)

# ─── Value Conversion ─────────────────────────────────────────────

"""Convert a Julia value to an RDF term based on column type hint."""
function _to_rdf_term(val, ct::IRIColumn)::Union{URIRef, Nothing}
    ismissing(val) && return nothing
    s = string(val)
    isempty(s) && return nothing
    URIRef(s)
end

function _to_rdf_term(val, ct::LiteralColumn)::Union{Literal, Nothing}
    ismissing(val) && return nothing
    Literal(string(val); datatype=ct.datatype)
end

function _to_rdf_term(val, ct::LangColumn)::Union{Literal, Nothing}
    ismissing(val) && return nothing
    Literal(string(val); lang=ct.lang)
end

function _to_rdf_term(val, ct::AutoColumn)::Union{Literal, Nothing}
    ismissing(val) && return nothing
    if val isa Bool
        Literal(val)
    elseif val isa Integer
        Literal(val)
    elseif val isa AbstractFloat
        Literal(val)
    elseif val isa Dates.DateTime
        Literal(string(val); datatype=XSD.dateTime)
    elseif val isa Dates.Date
        Literal(string(val); datatype=XSD.date)
    elseif val isa Dates.Time
        Literal(string(val); datatype=XSD.time)
    else
        Literal(string(val))
    end
end

"""Convert a subject value to a URIRef, optionally prepending a prefix."""
function _to_subject(val, prefix::AbstractString)::Union{URIRef, Nothing}
    ismissing(val) && return nothing
    s = string(val)
    isempty(s) && return nothing
    if startswith(s, "http://") || startswith(s, "https://") || startswith(s, "urn:")
        URIRef(s)
    elseif !isempty(prefix)
        URIRef(prefix * _uri_encode(s))
    else
        URIRef(_uri_encode(s))
    end
end

# ─── Mapping Functions ────────────────────────────────────────────

"""
    rdf_map!(m::RDFMapping, table, template::RDFTemplate)

Map a Tables.jl-compatible table to RDF triples using an explicit template.

Each row produces:
- `rdf:type` triples for each class in `template.types`
- One triple per property: `(subject, predicate, value)`

# Example
```julia
tpl = RDFTemplate(
    subject = :id,
    subject_prefix = "http://example.org/person/",
    properties = [
        (URIRef("http://xmlns.com/foaf/0.1/name"), :name, AutoColumn()),
        (URIRef("http://xmlns.com/foaf/0.1/age"), :age, LiteralColumn(XSD.integer)),
    ],
    types = [URIRef("http://xmlns.com/foaf/0.1/Person")]
)
rdf_map!(m, df, tpl)
```
"""
function rdf_map!(m::RDFMapping, table, template::RDFTemplate)
    rows = Tables.rows(table)
    rdf_type = RDF.type
    for row in rows
        subj = _to_subject(Tables.getcolumn(row, template.subject_column),
                           template.subject_prefix)
        subj === nothing && continue

        # Add rdf:type triples
        for cls in template.types
            add!(m.graph, Triple(subj, rdf_type, cls))
        end

        # Add property triples
        for (pred, col, ct) in template.properties
            val = Tables.getcolumn(row, col)
            obj = _to_rdf_term(val, ct)
            obj === nothing && continue
            add!(m.graph, Triple(subj, pred, obj))
        end
    end
    m
end

"""
    map_default!(m::RDFMapping, table, subject_column::Symbol;
                 subject_prefix="", predicate_prefix="",
                 types=URIRef[], column_types=Dict{Symbol,ColumnType}())

Auto-map a table to RDF: each column becomes a predicate using its name.

- Subject URIs are derived from `subject_column`
- Predicate URIs are `predicate_prefix * column_name`
- Values are auto-typed unless overridden in `column_types`
- `types`: class URIs added as `rdf:type` for each subject

Returns the auto-generated `RDFTemplate`.

# Example
```julia
map_default!(m, df, :id;
    predicate_prefix = "http://example.org/",
    types = [URIRef("http://example.org/Person")],
    column_types = Dict(:homepage => IRIColumn()))
```
"""
function map_default!(m::RDFMapping, table, subject_column::Symbol;
                      subject_prefix::AbstractString="",
                      predicate_prefix::AbstractString="",
                      types::AbstractVector{URIRef}=URIRef[],
                      column_types::AbstractDict{Symbol,<:ColumnType}=Dict{Symbol,ColumnType}())
    cols = Tables.columnnames(Tables.columns(table))

    properties = Tuple{URIRef, Symbol, ColumnType}[]
    for col in cols
        col == subject_column && continue
        ct = get(column_types, col, AutoColumn())
        pred = URIRef(predicate_prefix * _uri_encode(string(col)))
        push!(properties, (pred, col, ct))
    end

    tpl = RDFTemplate(subject_column, String(subject_prefix), properties, URIRef[t for t in types])
    rdf_map!(m, table, tpl)
    tpl
end

# ─── Insert via SPARQL CONSTRUCT ──────────────────────────────────

"""
    rdf_insert!(m::RDFMapping, sparql_construct::AbstractString)

Execute a SPARQL CONSTRUCT query and insert the resulting triples into the mapping's graph.
"""
function rdf_insert!(m::RDFMapping, sparql_construct::AbstractString)
    result = sparql_query(m.graph, sparql_construct)
    if result isa RDFGraph
        for triple in triples(result)
            add!(m.graph, triple)
        end
    end
    m
end

# ─── SPARQL Querying ──────────────────────────────────────────────

"""
    rdf_query(m::RDFMapping, sparql::AbstractString) → NamedTuple

Execute a SPARQL SELECT query and return results as a NamedTuple of vectors,
compatible with Tables.jl (and thus DataFrames.jl).

For ASK queries, returns a Bool.
For CONSTRUCT queries, returns an RDFGraph.

# Example
```julia
results = rdf_query(m, \"\"\"
    PREFIX ex: <http://example.org/>
    SELECT ?person ?name WHERE {
        ?person ex:name ?name .
    }
\"\"\")
# results is a NamedTuple: (person = [...], name = [...])
# Convert to DataFrame: DataFrame(results)
```
"""
function rdf_query(m::RDFMapping, sparql::AbstractString)
    result = sparql_query(m.graph, sparql)

    # SELECT queries return Vector{Dict{String, Identifier}}
    if result isa Vector{Dict{String, Identifier}}
        return _bindings_to_namedtuple(result)
    end

    # ASK, CONSTRUCT pass through
    return result
end

"""Convert SPARQL SELECT bindings to a NamedTuple of string vectors."""
function _bindings_to_namedtuple(bindings::Vector{Dict{String, Identifier}})
    isempty(bindings) && return NamedTuple()

    # Collect all variable names across all bindings
    varset = Set{String}()
    for b in bindings
        union!(varset, keys(b))
    end
    vars = sort!(collect(varset))

    # Build columns
    columns = Dict{Symbol, Vector{String}}()
    for v in vars
        col = String[]
        for b in bindings
            if haskey(b, v)
                val = b[v]
                if val isa URIRef
                    push!(col, "<" * string(val) * ">")
                elseif val isa BNode
                    push!(col, "_:" * string(val.id))
                elseif val isa Literal
                    push!(col, string(val))
                else
                    push!(col, string(val))
                end
            else
                push!(col, "")
            end
        end
        columns[Symbol(v)] = col
    end

    # Create NamedTuple preserving variable order
    syms = Tuple(Symbol.(vars))
    vals = Tuple(columns[s] for s in syms)
    NamedTuple{syms}(vals)
end

# ─── SPARQL UPDATE ────────────────────────────────────────────────

"""
    rdf_update!(m::RDFMapping, sparql::AbstractString)

Execute a SPARQL UPDATE (INSERT/DELETE) against the mapping's graph.
"""
function rdf_update!(m::RDFMapping, sparql::AbstractString)
    sparql_update(m.graph, sparql)
    m
end

# ─── Serialization ────────────────────────────────────────────────

"""
    serialize(m::RDFMapping, format::SerializationFormat=TurtleFormat()) → String

Serialize the mapping's RDF graph.
"""
function serialize(m::RDFMapping, format::SerializationFormat=TurtleFormat())
    serialize(m.graph, format)
end

"""
    parse_rdf!(m::RDFMapping, data::AbstractString, format::SerializationFormat)

Parse RDF data into the mapping's graph.
"""
function parse_rdf!(m::RDFMapping, data::AbstractString, format::SerializationFormat)
    parse_rdf!(m.graph, data, format)
    m
end

# ─── Table → RDF convenience ─────────────────────────────────────

"""
    table_to_rdf(table, subject_column::Symbol;
                 subject_prefix="", predicate_prefix="",
                 types=URIRef[], column_types=Dict()) → RDFMapping

One-shot convenience: create a mapping, auto-map a table, return the mapping.

# Example
```julia
using DataFrames
df = DataFrame(id=["Alice","Bob"], age=[30,25], city=["NYC","LA"])
m = table_to_rdf(df, :id;
    subject_prefix="http://example.org/person/",
    predicate_prefix="http://example.org/",
    types=[URIRef("http://example.org/Person")])
results = rdf_query(m, "SELECT ?s ?age WHERE { ?s <http://example.org/age> ?age }")
```
"""
function table_to_rdf(table, subject_column::Symbol;
                      subject_prefix::AbstractString="",
                      predicate_prefix::AbstractString="",
                      types::AbstractVector{URIRef}=URIRef[],
                      column_types::AbstractDict{Symbol,<:ColumnType}=Dict{Symbol,ColumnType}())
    m = RDFMapping()
    map_default!(m, table, subject_column;
        subject_prefix=subject_prefix,
        predicate_prefix=predicate_prefix,
        types=types,
        column_types=column_types)
    m
end
