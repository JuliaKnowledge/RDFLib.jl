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
    templates::Dict{String, Any}  # template IRI → OTTRTemplate
end

function RDFMapping(;
    graph::RDFGraph=RDFGraph(),
    prefixes::Dict{String,String}=Dict{String,String}())
    RDFMapping(graph, prefixes, Dict{String, Any}())
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

# ─── stOTTR Template Engine ──────────────────────────────────────

# Types for parsed stOTTR templates

"""Parameter type in an OTTR template."""
abstract type OTTRParamType end
struct OTTRTypeUnknown <: OTTRParamType end
struct OTTRTypeIRI <: OTTRParamType end
struct OTTRTypeLiteral <: OTTRParamType
    datatype::URIRef
end
struct OTTRTypeList <: OTTRParamType
    inner::OTTRParamType
end

"""A parameter in an OTTR template."""
struct OTTRParam
    name::String           # variable name (without ?)
    ptype::OTTRParamType
    optional::Bool
    default_value::Any     # nothing, string, number, or IRI string
end

"""An argument in an OTTR instance."""
struct OTTRArg
    variable::String       # "" for constants
    constant::Any          # nothing for variables; URIRef/Literal/BNode for constants
    list_expand::Bool      # ++?var
end

"""An instance (triple or nested template call) in an OTTR template body."""
struct OTTRInstance
    template_iri::String   # "ottr:Triple" or other template IRI
    args::Vector{OTTRArg}
    list_expander::Symbol  # :none, :cross, :zipMax
end

"""A parsed OTTR template."""
struct OTTRTemplate
    iri::String
    parameters::Vector{OTTRParam}
    instances::Vector{OTTRInstance}
end

# ─── stOTTR Parser ───────────────────────────────────────────────

"""
    parse_ottr(source::AbstractString) → Vector{OTTRTemplate}

Parse stOTTR template definitions from a string. Supports:
- `@prefix` and `prefix` declarations
- Template declarations with parameters and instances
- `ottr:Triple(?s, ?p, ?o)` patterns
- Nested template calls
- `cross |` and `zipMax |` list expanders
- `++?var` list expansion arguments
- `_:name` blank node references
- `a` shorthand for rdf:type
- Optional parameters (`? type ?var`, `??var`)
- Typed parameters (`ottr:IRI ?var`, `xsd:string ?var`)
- Default values (`?var = value`)
- Comments (`#`)
- Constant literals, typed literals (`"val"^^xsd:type`), language tags (`"val"@lang`)
"""
function parse_ottr(source::AbstractString)::Vector{OTTRTemplate}
    # Strip comments
    lines = split(source, '\n')
    cleaned = String[]
    for line in lines
        # Remove # comments (but not inside strings or IRIs)
        in_string = false
        in_iri = false
        comment_pos = 0
        for (i, c) in enumerate(line)
            if c == '"' && !in_iri
                in_string = !in_string
            elseif c == '<' && !in_string
                in_iri = true
            elseif c == '>' && !in_string
                in_iri = false
            elseif c == '#' && !in_string && !in_iri
                comment_pos = i
                break
            end
        end
        if comment_pos > 0
            push!(cleaned, line[1:comment_pos-1])
        else
            push!(cleaned, line)
        end
    end
    text = join(cleaned, " ")

    # Parse prefixes
    prefixes = Dict{String, String}()
    # Built-in prefixes
    prefixes["ottr"] = "http://ns.ottr.xyz/0.4/"
    prefixes["rdf"] = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    prefixes["rdfs"] = "http://www.w3.org/2000/01/rdf-schema#"
    prefixes["owl"] = "http://www.w3.org/2002/07/owl#"
    prefixes["xsd"] = "http://www.w3.org/2001/XMLSchema#"

    # Extract @prefix and prefix declarations
    for m in eachmatch(r"(?:@prefix|prefix)\s+(\w+)\s*:\s*<([^>]+)>\s*\.?", text)
        prefixes[m.captures[1]] = m.captures[2]
    end
    # Remove prefix declarations from text
    text = replace(text, r"(?:@prefix|prefix)\s+\w+\s*:\s*<[^>]+>\s*\.?" => " ")

    templates = OTTRTemplate[]
    _parse_templates!(templates, strip(text), prefixes)
    return templates
end

"""Expand a prefixed name to a full IRI."""
function _ottr_expand(name::AbstractString, prefixes::Dict{String,String})::String
    # Full IRI
    if startswith(name, '<') && endswith(name, '>')
        return name[2:end-1]
    end
    # Prefixed name
    m = match(r"^(\w+):(.*)$", name)
    if m !== nothing
        prefix = m.captures[1]
        local_name = m.captures[2]
        if haskey(prefixes, prefix)
            return prefixes[prefix] * local_name
        end
    end
    # `a` shorthand
    name == "a" && return "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
    return name
end

function _parse_templates!(templates::Vector{OTTRTemplate}, text::AbstractString,
                            prefixes::Dict{String,String})
    pos = 1
    while pos <= length(text)
        # Skip whitespace
        while pos <= length(text) && isspace(text[pos])
            pos += 1
        end
        pos > length(text) && break

        # Find template IRI (prefixed or full)
        tpl_match = match(r"^((?:<[^>]+>)|(?:\w+:\w[\w-]*))\s*\[", text[pos:end])
        tpl_match === nothing && break
        tpl_iri_raw = tpl_match.captures[1]
        tpl_iri = _ottr_expand(tpl_iri_raw, prefixes)
        pos += tpl_match.offset + length(tpl_match.match) - 2  # at '['

        # Parse parameter list [...]
        params, pos = _parse_ottr_params(text, pos, prefixes)

        # Skip whitespace
        while pos <= length(text) && isspace(text[pos])
            pos += 1
        end

        # Check for annotations @@ ... (skip them)
        while pos <= length(text) && pos + 1 <= length(text) && text[pos:pos+1] == "@@"
            pos += 2
            # Skip annotation content until we reach :: or end
            depth = 0
            while pos <= length(text)
                if text[pos] == '('
                    depth += 1
                elseif text[pos] == ')'
                    depth -= 1
                    if depth == 0
                        pos += 1
                        break
                    end
                end
                pos += 1
            end
            # Skip comma/whitespace between annotations
            while pos <= length(text) && (isspace(text[pos]) || text[pos] == ',')
                pos += 1
            end
        end

        # Check for :: { instances } or just .
        instances = OTTRInstance[]
        while pos <= length(text) && isspace(text[pos])
            pos += 1
        end

        if pos + 1 <= length(text) && text[pos:pos+1] == "::"
            pos += 2
            while pos <= length(text) && isspace(text[pos])
                pos += 1
            end
            if pos <= length(text) && text[pos] == '{'
                instances, pos = _parse_ottr_instances(text, pos, prefixes)
            end
        end

        # Skip trailing whitespace and period
        while pos <= length(text) && (isspace(text[pos]) || text[pos] == '.')
            pos += 1
        end

        push!(templates, OTTRTemplate(tpl_iri, params, instances))
    end
end

function _parse_ottr_params(text::AbstractString, pos::Int,
                             prefixes::Dict{String,String})::Tuple{Vector{OTTRParam}, Int}
    params = OTTRParam[]
    @assert text[pos] == '['
    pos += 1  # skip '['

    while pos <= length(text)
        while pos <= length(text) && (isspace(text[pos]) || text[pos] == ',')
            pos += 1
        end
        pos > length(text) && break
        text[pos] == ']' && (pos += 1; break)

        # Parse modifiers: ?, !, ?!, !?
        # stOTTR modifier rules:
        #   ?var — normal variable
        #   ??var — optional (first ? is modifier, second ? starts variable)
        #   !?var — nonblank (! is modifier, ? starts variable)
        #   ?!?var — optional + nonblank  
        #   !??var — nonblank + optional
        optional = false
        nonblank = false
        while pos <= length(text) && text[pos] in ('?', '!')
            c = text[pos]
            if c == '!'
                nonblank = true
                pos += 1
            elseif c == '?'
                next_pos = pos + 1
                # ??var → optional + variable (or !??var after !)
                if next_pos <= length(text) && text[next_pos] == '?'
                    optional = true
                    pos += 1  # consume modifier ?, leave next ? for variable
                    break
                end
                # ?! → optional modifier followed by nonblank modifier
                if next_pos <= length(text) && text[next_pos] == '!'
                    optional = true
                    pos += 1
                    continue  # will handle ! next
                end
                # ? followed by whitespace then type → optional modifier
                test_pos = next_pos
                while test_pos <= length(text) && isspace(text[test_pos])
                    test_pos += 1
                end
                if test_pos <= length(text)
                    rest = text[test_pos:min(end, test_pos+30)]
                    # If next token is a known type prefix (not a variable), ? is optional modifier
                    if occursin(r"^(?:(?:NE)?List<|LUB<|[A-Z_a-z]\w*:)", rest)
                        optional = true
                        pos += 1
                        break
                    end
                    # If next is ?var (after whitespace), this ? is optional modifier
                    if startswith(rest, "?") && length(rest) > 1 && isletter(rest[2])
                        optional = true
                        pos += 1
                        break
                    end
                end
                # Otherwise ? starts a variable name — stop modifier parsing
                break
            end
        end

        while pos <= length(text) && isspace(text[pos])
            pos += 1
        end
        pos > length(text) && break
        text[pos] == ']' && (pos += 1; break)

        # Parse type (if present before variable)
        # Check for List<...>, NEList<...>, or LUB<...> type
        ptype::OTTRParamType = OTTRTypeUnknown()
        list_prefix_match = match(r"^((?:NE)?List|LUB)<", text[pos:end])
        if list_prefix_match !== nothing
            # Use balanced bracket parsing for nested types like NEList<List<List<owl:Class>>>
            type_start = pos
            type_end = pos + length(list_prefix_match.match) - 1  # at '<'
            depth = 0
            tp = type_end
            while tp <= length(text)
                if text[tp] == '<'
                    depth += 1
                elseif text[tp] == '>'
                    depth -= 1
                    if depth == 0
                        type_end = tp
                        break
                    end
                end
                tp += 1
            end
            type_str = text[type_start:type_end]
            ptype = _parse_ottr_type(type_str, prefixes)
            pos = type_end + 1
            while pos <= length(text) && isspace(text[pos])
                pos += 1
            end
        else
            # Check for prefixed type or full IRI type
            type_match = match(r"^((?:<[^>]+>)|(?:\w+:\w[\w-]*))\s+", text[pos:end])
            if type_match !== nothing
                # Only treat as type if followed by ? (variable) — otherwise it might be the variable itself
                after_type = pos + length(type_match.match)
                if after_type <= length(text) && text[after_type] == '?'
                    ptype = _parse_ottr_type(type_match.captures[1], prefixes)
                    pos += length(type_match.match)
                end
            end
        end

        while pos <= length(text) && isspace(text[pos])
            pos += 1
        end

        # Parse variable name ?varName
        var_match = match(r"^\?(\w+)", text[pos:end])
        if var_match === nothing
            # Skip unrecognized token until comma or ]
            while pos <= length(text) && text[pos] ∉ (',', ']')
                pos += 1
            end
            continue
        end
        var_name = var_match.captures[1]
        pos += length(var_match.match)

        # Parse default value = ...
        default_val = nothing
        while pos <= length(text) && isspace(text[pos])
            pos += 1
        end
        if pos <= length(text) && text[pos] == '='
            pos += 1
            while pos <= length(text) && isspace(text[pos])
                pos += 1
            end
            default_val, pos = _parse_ottr_value(text, pos, prefixes)
        end

        push!(params, OTTRParam(var_name, ptype, optional, default_val))
    end

    return params, pos
end

function _parse_ottr_type(s::AbstractString, prefixes::Dict{String,String})::OTTRParamType
    # List<inner> or NEList<inner>
    m = match(r"^(?:NE)?List<(.+)>$", s)
    if m !== nothing
        return OTTRTypeList(_parse_ottr_type(m.captures[1], prefixes))
    end
    # LUB<inner>
    m2 = match(r"^LUB<(.+)>$", s)
    if m2 !== nothing
        return _parse_ottr_type(m2.captures[1], prefixes)
    end
    expanded = _ottr_expand(s, prefixes)
    if expanded == "http://ns.ottr.xyz/0.4/IRI" || expanded == "http://www.w3.org/2001/XMLSchema#anyURI"
        return OTTRTypeIRI()
    end
    xsd_prefix = "http://www.w3.org/2001/XMLSchema#"
    if startswith(expanded, xsd_prefix)
        return OTTRTypeLiteral(URIRef(expanded))
    end
    # Other types (owl:Class etc.) — treat as IRI for mapping purposes
    return OTTRTypeIRI()
end

function _parse_ottr_value(text::AbstractString, pos::Int,
                            prefixes::Dict{String,String})::Tuple{Any, Int}
    while pos <= length(text) && isspace(text[pos])
        pos += 1
    end
    pos > length(text) && return (nothing, pos)

    # String literal
    if text[pos] == '"'
        return _parse_ottr_string(text, pos, prefixes)
    end
    # List literal (...)
    if text[pos] == '('
        return _parse_ottr_list_value(text, pos, prefixes)
    end
    # Number
    num_match = match(r"^(-?\d+(?:\.\d+)?)", text[pos:end])
    if num_match !== nothing
        val_str = num_match.captures[1]
        pos += length(val_str)
        if occursin('.', val_str)
            return (parse(Float64, val_str), pos)
        else
            return (parse(Int, val_str), pos)
        end
    end
    # IRI (prefixed or full)
    iri_match = match(r"^((?:<[^>]+>)|(?:\w+:\w[\w-]*))", text[pos:end])
    if iri_match !== nothing
        pos += length(iri_match.match)
        return (_ottr_expand(iri_match.captures[1], prefixes), pos)
    end
    return (nothing, pos)
end

function _parse_ottr_string(text::AbstractString, pos::Int,
                             prefixes::Dict{String,String})::Tuple{Any, Int}
    @assert text[pos] == '"'
    pos += 1
    buf = IOBuffer()
    while pos <= length(text) && text[pos] != '"'
        if text[pos] == '\\' && pos + 1 <= length(text)
            pos += 1
        end
        write(buf, text[pos])
        pos += 1
    end
    pos <= length(text) && (pos += 1)  # skip closing "
    str_val = String(take!(buf))

    # Check for ^^type or @lang
    if pos <= length(text) && text[pos] == '^' && pos + 1 <= length(text) && text[pos+1] == '^'
        pos += 2
        type_match = match(r"^((?:<[^>]+>)|(?:\w+:\w[\w-]*))", text[pos:end])
        if type_match !== nothing
            pos += length(type_match.match)
            dt = _ottr_expand(type_match.captures[1], prefixes)
            return (Literal(str_val; datatype=URIRef(dt)), pos)
        end
    elseif pos <= length(text) && text[pos] == '@'
        pos += 1
        lang_match = match(r"^([a-zA-Z][\w-]*)", text[pos:end])
        if lang_match !== nothing
            pos += length(lang_match.match)
            return (Literal(str_val; lang=lang_match.captures[1]), pos)
        end
    end
    return (Literal(str_val), pos)
end

function _parse_ottr_list_value(text::AbstractString, pos::Int,
                                 prefixes::Dict{String,String})::Tuple{Any, Int}
    @assert text[pos] == '('
    pos += 1
    items = Any[]
    while pos <= length(text)
        while pos <= length(text) && (isspace(text[pos]) || text[pos] == ',')
            pos += 1
        end
        pos > length(text) && break
        text[pos] == ')' && (pos += 1; break)
        if text[pos] == '('
            sub, pos = _parse_ottr_list_value(text, pos, prefixes)
            push!(items, sub)
        else
            val, pos = _parse_ottr_value(text, pos, prefixes)
            push!(items, val)
        end
    end
    return (items, pos)
end

function _parse_ottr_instances(text::AbstractString, pos::Int,
                                prefixes::Dict{String,String})::Tuple{Vector{OTTRInstance}, Int}
    instances = OTTRInstance[]
    @assert text[pos] == '{'
    pos += 1

    while pos <= length(text)
        while pos <= length(text) && (isspace(text[pos]) || text[pos] == ',')
            pos += 1
        end
        pos > length(text) && break
        text[pos] == '}' && (pos += 1; break)

        # Check for list expander: cross | or zipMax |
        expander = :none
        exp_match = match(r"^(cross|zipMax)\s*\|\s*", text[pos:end])
        if exp_match !== nothing
            expander = Symbol(exp_match.captures[1])
            pos += length(exp_match.match)
        end

        # Parse template call: name(args)
        call_match = match(r"^((?:<[^>]+>)|(?:\w+:\w[\w-]*))\s*\(", text[pos:end])
        call_match === nothing && (pos += 1; continue)

        tpl_name_raw = call_match.captures[1]
        tpl_name = _ottr_expand(tpl_name_raw, prefixes)
        pos += length(call_match.match) - 1  # at '('

        args, pos = _parse_ottr_args(text, pos, prefixes)
        push!(instances, OTTRInstance(tpl_name, args, expander))
    end

    return instances, pos
end

function _parse_ottr_args(text::AbstractString, pos::Int,
                           prefixes::Dict{String,String})::Tuple{Vector{OTTRArg}, Int}
    args = OTTRArg[]
    @assert text[pos] == '('
    depth = 1
    pos += 1

    while pos <= length(text) && depth > 0
        while pos <= length(text) && (isspace(text[pos]) || text[pos] == ',')
            pos += 1
        end
        pos > length(text) && break

        if text[pos] == ')'
            depth -= 1
            pos += 1
            depth == 0 && break
            continue
        end

        # ++ list expansion prefix
        list_expand = false
        if pos + 1 <= length(text) && text[pos:pos+1] == "++"
            list_expand = true
            pos += 2
        end

        # Variable ?name
        if pos <= length(text) && text[pos] == '?'
            vm = match(r"^\?(\w+)", text[pos:end])
            if vm !== nothing
                push!(args, OTTRArg(vm.captures[1], nothing, list_expand))
                pos += length(vm.match)
                continue
            end
        end

        # Blank node _:name
        if pos + 1 <= length(text) && text[pos:pos+1] == "_:"
            bm = match(r"^_:(\w+)", text[pos:end])
            if bm !== nothing
                push!(args, OTTRArg("", BNode(bm.captures[1]), list_expand))
                pos += length(bm.match)
                continue
            end
        end

        # Empty blank node []
        if text[pos] == '['
            pos += 1
            while pos <= length(text) && text[pos] != ']'
                pos += 1
            end
            pos <= length(text) && (pos += 1)
            push!(args, OTTRArg("", BNode(), list_expand))
            continue
        end

        # `a` shorthand — only if followed by delimiter
        if pos <= length(text) && text[pos] == 'a'
            next = pos + 1
            if next > length(text) || text[next] in (' ', '\t', '\n', '\r', ',', ')')
                push!(args, OTTRArg("", URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"), false))
                pos += 1
                continue
            end
        end

        # String literal
        if text[pos] == '"'
            lit, pos = _parse_ottr_string(text, pos, prefixes)
            push!(args, OTTRArg("", lit, list_expand))
            continue
        end

        # Parenthesized list (constant list for ++)
        if text[pos] == '('
            list_val, pos = _parse_ottr_list_value(text, pos, prefixes)
            push!(args, OTTRArg("", list_val, list_expand))
            continue
        end

        # Number
        num_match = match(r"^(-?\d+(?:\.\d+)?)", text[pos:end])
        if num_match !== nothing
            val_str = num_match.captures[1]
            pos += length(val_str)
            if occursin('.', val_str)
                push!(args, OTTRArg("", Literal(parse(Float64, val_str)), list_expand))
            else
                push!(args, OTTRArg("", Literal(parse(Int, val_str)), list_expand))
            end
            continue
        end

        # IRI (prefixed or full)
        iri_match = match(r"^((?:<[^>]+>)|(?:\w+:\w[\w-]*))", text[pos:end])
        if iri_match !== nothing
            pos += length(iri_match.match)
            expanded = _ottr_expand(iri_match.captures[1], prefixes)
            push!(args, OTTRArg("", URIRef(expanded), list_expand))
            continue
        end

        # Skip unrecognized
        pos += 1
    end

    return args, pos
end

# ─── OTTR Template Expansion ─────────────────────────────────────

"""
    add_template!(m::RDFMapping, source::AbstractString)

Parse stOTTR template definitions and register them in the mapping.
"""
function add_template!(m::RDFMapping, source::AbstractString)
    templates = parse_ottr(source)
    for tpl in templates
        m.templates[tpl.iri] = tpl
    end
    m
end

"""
    ottr_map!(m::RDFMapping, template_iri::AbstractString, table)

Expand an OTTR template with data from a Tables.jl-compatible table.
Each row of the table provides values for the template parameters.
Column names must match parameter names.
"""
function ottr_map!(m::RDFMapping, template_iri::AbstractString, table)
    # Resolve template IRI
    iri = _resolve_template_iri(m, template_iri)

    haskey(m.templates, iri) || error("Template not found: $template_iri")
    tpl = m.templates[iri]::OTTRTemplate

    rows = Tables.rows(table)
    cols = Tables.columnnames(Tables.columns(table))

    # Pre-compute column→parameter mapping
    param_syms = Symbol[Symbol(p.name) for p in tpl.parameters]
    param_col_idx = Int[]  # index in tpl.parameters for params that have columns
    param_has_col = Bool[sym in cols for sym in param_syms]

    # Pre-resolve constant arguments in instances
    store = m.graph.store

    # Use deferred indexing for bulk performance
    _defer_indexing!(store)

    # Reusable bindings dict to avoid per-row allocation
    bindings = Dict{String, Any}()
    sizehint!(bindings, length(tpl.parameters))

    row_counter = 0
    for row in rows
        row_counter += 1
        empty!(bindings)
        for (i, param) in enumerate(tpl.parameters)
            if param_has_col[i]
                val = Tables.getcolumn(row, param_syms[i])
                if !ismissing(val) && val !== nothing
                    bindings[param.name] = _ottr_convert_value(val, param.ptype)
                elseif param.default_value !== nothing
                    bindings[param.name] = param.default_value
                end
            elseif param.default_value !== nothing
                bindings[param.name] = param.default_value
            end
        end
        _ottr_expand_instances!(m, tpl.instances, bindings, row_counter)
    end

    # Rebuild indices in bulk (also deduplicates)
    _rebuild_indices!(store)
    m
end

"""Resolve a template IRI, trying prefixed name, full IRI, and partial match."""
function _resolve_template_iri(m::RDFMapping, iri::AbstractString)::String
    # Already registered?
    haskey(m.templates, iri) && return iri
    # Try as prefixed name using registered template prefixes
    pm = match(r"^(\w+):(.+)$", iri)
    if pm !== nothing
        # Search registered templates
        for (k, _) in m.templates
            if endswith(k, pm.captures[2])
                return k
            end
        end
    end
    return iri
end

"""Convert a Julia value to an RDF term based on OTTR parameter type."""
function _ottr_convert_value(val, ptype::OTTRTypeIRI)
    ismissing(val) && return nothing
    s = string(val)
    URIRef(s)
end

function _ottr_convert_value(val, ptype::OTTRTypeLiteral)
    ismissing(val) && return nothing
    Literal(string(val); datatype=ptype.datatype)
end

function _ottr_convert_value(val, ptype::OTTRTypeList)
    if val isa AbstractVector
        return [_ottr_convert_value(v, ptype.inner) for v in val if !ismissing(v) && v !== nothing]
    end
    return _ottr_convert_value(val, ptype.inner)
end

function _ottr_convert_value(val, ptype::OTTRTypeUnknown)
    ismissing(val) && return nothing
    if val isa Bool
        Literal(val)
    elseif val isa Integer
        Literal(val)
    elseif val isa AbstractFloat
        Literal(val)
    elseif val isa AbstractString
        s = string(val)
        if startswith(s, "http://") || startswith(s, "https://") || startswith(s, "urn:")
            URIRef(s)
        else
            Literal(s)
        end
    elseif val isa AbstractVector
        return [_ottr_convert_value(v, OTTRTypeUnknown()) for v in val if !ismissing(v) && v !== nothing]
    else
        Literal(string(val))
    end
end

"""Resolve an OTTR argument to an RDF term given current bindings."""
function _ottr_resolve_arg(arg::OTTRArg, bindings::Dict{String,Any}, row_id::Int)
    if !isempty(arg.variable)
        val = get(bindings, arg.variable, nothing)
        return val
    end
    if arg.constant isa BNode
        return BNode(arg.constant.id * "_r$row_id")
    end
    return arg.constant
end

function _ottr_expand_instances!(m::RDFMapping, instances::Vector{OTTRInstance},
                                  bindings::Dict{String,Any}, row_id::Int)
    for inst in instances
        if inst.template_iri == "http://ns.ottr.xyz/0.4/Triple"
            _ottr_expand_triple!(m, inst, bindings, row_id)
        else
            _ottr_expand_nested!(m, inst, bindings, row_id)
        end
    end
end

function _ottr_expand_triple!(m::RDFMapping, inst::OTTRInstance,
                               bindings::Dict{String,Any}, row_id::Int)
    length(inst.args) >= 3 || return

    s_arg, p_arg, o_arg = inst.args[1], inst.args[2], inst.args[3]
    subj = _ottr_resolve_arg(s_arg, bindings, row_id)
    pred = _ottr_resolve_arg(p_arg, bindings, row_id)

    subj === nothing && return
    pred === nothing && return

    s_node = _ensure_node(subj)
    p_uri = _ensure_uriref(pred)
    store = m.graph.store

    # Handle list expansion on any argument position
    if o_arg.list_expand
        obj_val = _ottr_resolve_arg(OTTRArg(o_arg.variable, o_arg.constant, false), bindings, row_id)
        obj_val === nothing && return
        if obj_val isa AbstractVector
            for item in obj_val
                item === nothing && continue
                _add_deferred!(store, Triple(s_node, p_uri, _ensure_identifier(item)))
            end
        else
            _add_deferred!(store, Triple(s_node, p_uri, _ensure_identifier(obj_val)))
        end
    else
        obj = _ottr_resolve_arg(o_arg, bindings, row_id)
        obj === nothing && return
        if obj isa AbstractVector
            for item in obj
                item === nothing && continue
                _add_deferred!(store, Triple(s_node, p_uri, _ensure_identifier(item)))
            end
        else
            _add_deferred!(store, Triple(s_node, p_uri, _ensure_identifier(obj)))
        end
    end
end

_ensure_node(x::URIRef) = x
_ensure_node(x::BNode) = x
_ensure_node(x::Literal) = URIRef(x.lexical)
_ensure_node(x::AbstractString) = URIRef(x)
_ensure_node(x) = URIRef(string(x))

_ensure_uriref(x::URIRef) = x
_ensure_uriref(x::Literal) = URIRef(x.lexical)
_ensure_uriref(x::AbstractString) = URIRef(x)
_ensure_uriref(x) = URIRef(string(x))

_ensure_identifier(x::URIRef) = x
_ensure_identifier(x::BNode) = x
_ensure_identifier(x::Literal) = x
_ensure_identifier(x::AbstractString) = Literal(x)
_ensure_identifier(x) = Literal(string(x))

function _ottr_expand_nested!(m::RDFMapping, inst::OTTRInstance,
                               bindings::Dict{String,Any}, row_id::Int)
    haskey(m.templates, inst.template_iri) || return

    nested_tpl = m.templates[inst.template_iri]::OTTRTemplate

    nested_bindings = Dict{String, Any}()
    for (i, param) in enumerate(nested_tpl.parameters)
        if i <= length(inst.args)
            arg = inst.args[i]
            val = _ottr_resolve_arg(arg, bindings, row_id)
            if val !== nothing
                nested_bindings[param.name] = val
            end
        end
    end

    _ottr_expand_instances!(m, nested_tpl.instances, nested_bindings, row_id)
end

# ─── SHACL + Datalog Integration ─────────────────────────────────

"""
    rdf_validate(m::RDFMapping, shapes::RDFGraph) → ValidationReport
    rdf_validate(m::RDFMapping, shapes_ttl::AbstractString) → ValidationReport

Validate the mapping's RDF graph against SHACL shapes.
"""
function rdf_validate(m::RDFMapping, shapes::RDFGraph)
    validate(m.graph, shapes)
end

function rdf_validate(m::RDFMapping, shapes_ttl::AbstractString)
    shapes = RDFGraph()
    parse_rdf!(shapes, shapes_ttl, TurtleFormat())
    validate(m.graph, shapes)
end

"""
    rdf_reason!(m::RDFMapping; max_iterations=100) → RDFGraph

Apply Datalog-style reasoning to the mapping's graph, adding inferred triples.
"""
function rdf_reason!(m::RDFMapping; max_iterations::Int=100)
    result = datalog_reason(m.graph; max_iterations=max_iterations)
    # Merge inferred triples into the mapping graph
    for triple in triples(result)
        add!(m.graph, triple)
    end
    m
end
