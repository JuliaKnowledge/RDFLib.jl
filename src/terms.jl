# ─── Abstract type hierarchy ────────────────────────────────────────
# Mirrors rdflib: Node > Identifier > {IdentifiedNode{URIRef,BNode}, Literal, Variable}

"""
    Identifier

Abstract supertype for all RDF identifiers (URIs, blank nodes, literals, variables).
"""
abstract type Identifier end

"""
    Node <: Identifier

Abstract type for RDF nodes that can appear as subjects in triples.
"""
abstract type Node <: Identifier end

"""
    IdentifiedNode <: Node

Abstract type for nodes with identity (URIRef and BNode).
"""
abstract type IdentifiedNode <: Node end

# ─── URIRef ─────────────────────────────────────────────────────────

"""
    URIRef(uri::AbstractString)

An RDF URI reference. Immutable wrapper around a URI string.

# Examples
```julia
u = URIRef("http://example.org/resource")
n3(u)  # "<http://example.org/resource>"
```
"""
struct URIRef <: IdentifiedNode
    value::String
    _hash::UInt
    function URIRef(v::AbstractString)
        s = String(v)
        new(s, hash(s, hash(:URIRef, zero(UInt))))
    end
end

URIRef(u::URIRef) = u

Base.string(u::URIRef) = u.value
Base.show(io::IO, u::URIRef) = print(io, "URIRef(\"", u.value, "\")")
Base.:(==)(a::URIRef, b::URIRef) = a.value == b.value
Base.hash(a::URIRef, h::UInt) = hash(a._hash, h)
Base.isless(a::URIRef, b::URIRef) = isless(a.value, b.value)

"""
    defrag(u::URIRef) -> URIRef

Return the URI without the fragment identifier.
"""
function defrag(u::URIRef)
    idx = findlast('#', u.value)
    isnothing(idx) ? u : URIRef(u.value[1:idx-1])
end

"""
    fragment(u::URIRef) -> String

Return the fragment identifier (after `#`), or empty string.
"""
function fragment(u::URIRef)
    idx = findlast('#', u.value)
    isnothing(idx) ? "" : u.value[idx+1:end]
end

"""
    n3(u::URIRef) -> String

N3/SPARQL representation: `<uri>`.
"""
n3(u::URIRef) = string("<", u.value, ">")

# ─── BNode ──────────────────────────────────────────────────────────

"""
    BNode()
    BNode(id::AbstractString)

An RDF blank node. Auto-generates a unique identifier if none provided.

# Examples
```julia
b = BNode()
n3(b)  # "_:N<hex>"
```
"""
struct BNode <: IdentifiedNode
    id::String
    _hash::UInt

    function BNode(id::AbstractString)
        s = String(id)
        new(s, hash(s, hash(:BNode, zero(UInt))))
    end
end

# Fast BNode ID generation using Random instead of UUID
const _BNODE_HEX = collect("0123456789abcdef")
function BNode()
    # Generate 32-char hex string directly — avoids uuid4() overhead
    buf = Vector{UInt8}(undef, 33)
    buf[1] = UInt8('N')
    @inbounds for i in 2:33
        buf[i] = UInt8(_BNODE_HEX[rand(1:16)])
    end
    BNode(String(buf))
end

Base.string(b::BNode) = b.id
Base.show(io::IO, b::BNode) = print(io, "BNode(\"", b.id, "\")")
Base.:(==)(a::BNode, b::BNode) = a.id == b.id
Base.hash(a::BNode, h::UInt) = hash(a._hash, h)
Base.isless(a::BNode, b::BNode) = isless(a.id, b.id)

n3(b::BNode) = string("_:", b.id)

# ─── Literal ────────────────────────────────────────────────────────

"""
    Literal(value; datatype=nothing, lang=nothing, direction=nothing)
    Literal(value::Number)
    Literal(value::Bool)
    Literal(value::DateTime)

An RDF literal value with optional datatype URI, language tag, and (SPARQL 1.2)
base direction (`"ltr"` or `"rtl"`, only allowed together with `lang`).

Language tags and datatypes are mutually exclusive (per RDF spec, a language-tagged
literal implicitly has datatype `rdf:langString`, or `rdf:dirLangString` when a base
direction is present).

Per RDF 1.1, a simple literal and an `xsd:string`-typed literal with the same lexical
form denote the same term: `Literal("a") == Literal("a", datatype=XSD.string)`.
Internally both are stored in the canonical simple form (`datatype === nothing`).

# Examples
```julia
Literal("hello")
Literal("bonjour", lang="fr")
Literal("שלום", lang="he", direction="rtl")
Literal(42)                        # auto-typed as xsd:integer
Literal("3.14", datatype=URIRef("http://www.w3.org/2001/XMLSchema#decimal"))
```
"""
struct Literal <: Identifier
    lexical::String
    datatype::Union{URIRef, Nothing}
    language::Union{String, Nothing}
    direction::Union{String, Nothing}
    _hash::UInt

    function Literal(lexical::AbstractString;
                     datatype::Union{URIRef, Nothing}=nothing,
                     lang::Union{AbstractString, Nothing}=nothing,
                     direction::Union{AbstractString, Nothing}=nothing)
        if !isnothing(lang) && !isnothing(datatype)
            if datatype != _RDF_LANGSTRING_DT && datatype != _RDF_DIRLANGSTRING_DT
                throw(ArgumentError("Language-tagged literals cannot have an explicit datatype other than rdf:langString or rdf:dirLangString"))
            end
        end
        dir = nothing
        if !isnothing(direction)
            isnothing(lang) && throw(ArgumentError("Literal base direction requires a language tag"))
            d = String(direction)
            d in ("ltr", "rtl") || throw(ArgumentError("Literal base direction must be \"ltr\" or \"rtl\", got \"$d\""))
            dir = d
        end
        language = isnothing(lang) ? nothing : lowercase(String(lang))
        # Canonical internal form:
        #  - RDF 1.1: a simple literal IS an xsd:string literal, so an explicit
        #    xsd:string datatype is normalized away (stored as `nothing`)
        #  - the implicit rdf:langString / rdf:dirLangString datatype of
        #    language-tagged literals is likewise stored as `nothing`
        dt = datatype
        if !isnothing(language)
            dt = nothing
        elseif dt == _XSD_STRING_DT
            dt = nothing
        end
        lex = String(lexical)
        h = hash(lex, hash(:Literal, zero(UInt)))
        h = hash(dt, h)
        h = hash(language, h)
        h = hash(dir, h)
        new(lex, dt, language, dir, h)
    end
end

# Convenience constructors for common Julia types
const _XSD = "http://www.w3.org/2001/XMLSchema#"

# Cached XSD datatype URIRefs to avoid repeated allocation
const _XSD_BOOLEAN  = URIRef(_XSD * "boolean")
const _XSD_INTEGER  = URIRef(_XSD * "integer")
const _XSD_DOUBLE   = URIRef(_XSD * "double")
const _XSD_DATETIME = URIRef(_XSD * "dateTime")
const _XSD_DATE     = URIRef(_XSD * "date")
const _XSD_TIME     = URIRef(_XSD * "time")
const _XSD_STRING_DT = URIRef(_XSD * "string")
const _RDF_LANGSTRING_DT = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#langString")
const _RDF_DIRLANGSTRING_DT = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#dirLangString")

"""
    _float_lexical(v::AbstractFloat) -> String

Canonical XSD lexical form for a float: `INF`, `-INF`, `NaN` for the special
values, otherwise Julia's decimal representation.
"""
function _float_lexical(v::AbstractFloat)
    isnan(v) && return "NaN"
    isinf(v) && return v > 0 ? "INF" : "-INF"
    string(v)
end

Literal(v::Bool) = Literal(v ? "true" : "false", datatype=_XSD_BOOLEAN)
Literal(v::Integer) = Literal(string(v), datatype=_XSD_INTEGER)
Literal(v::AbstractFloat) = Literal(_float_lexical(v), datatype=_XSD_DOUBLE)
Literal(v::DateTime) = Literal(format_xsd_datetime(v), datatype=_XSD_DATETIME)
Literal(v::Date) = Literal(format_xsd_date(v), datatype=_XSD_DATE)
Literal(v::Time) = Literal(format_xsd_time(v), datatype=_XSD_TIME)

function Base.show(io::IO, lit::Literal)
    print(io, "Literal(\"", lit.lexical, "\"")
    if !isnothing(lit.language)
        print(io, ", lang=\"", lit.language, "\"")
        if !isnothing(lit.direction)
            print(io, ", direction=\"", lit.direction, "\"")
        end
    elseif !isnothing(lit.datatype)
        print(io, ", datatype=", lit.datatype)
    end
    print(io, ")")
end

Base.string(lit::Literal) = lit.lexical

function Base.:(==)(a::Literal, b::Literal)
    a.lexical == b.lexical && a.datatype == b.datatype &&
        a.language == b.language && a.direction == b.direction
end

function Base.hash(a::Literal, h::UInt)
    hash(a._hash, h)
end

"""
    lang(lit::Literal) -> Union{String, Nothing}

Return the language tag, or `nothing`.
"""
lang(lit::Literal) = lit.language

"""
    direction(lit::Literal) -> Union{String, Nothing}

Return the base direction (`"ltr"` or `"rtl"`) of a directional language-tagged
literal (SPARQL 1.2), or `nothing`.
"""
direction(lit::Literal) = lit.direction

"""
    datatype(lit::Literal) -> Union{URIRef, Nothing}

Return the datatype URI, or `nothing` for simple (plain) literals and
language-tagged literals. Note that per RDF 1.1 simple literals denote
`xsd:string` values and language-tagged literals have implicit datatype
`rdf:langString` (`rdf:dirLangString` when a base direction is present).
"""
datatype(lit::Literal) = lit.datatype

"""
    convert(Any, lit::Literal)
    convert(Int, lit::Literal)
    convert(Float64, lit::Literal)
    convert(Bool, lit::Literal)
    convert(DateTime, lit::Literal)
    convert(Date, lit::Literal)
    convert(String, lit::Literal)

Convert a Literal to a native Julia value. `convert(Any, lit)` auto-detects
the target type from the literal's XSD datatype. Returns the lexical string
if the datatype is unrecognized.
"""
function _literal_to_julia(lit::Literal)
    dt = lit.datatype
    isnothing(dt) && return lit.lexical
    dtval = dt.value
    if dtval == _XSD * "integer" || dtval == _XSD * "int" || dtval == _XSD * "long"
        return parse(Int, lit.lexical)
    elseif dtval == _XSD * "double" || dtval == _XSD * "float" || dtval == _XSD * "decimal"
        return parse(Float64, lit.lexical)
    elseif dtval == _XSD * "boolean"
        return lit.lexical in ("true", "1")
    elseif dtval == _XSD * "dateTime"
        return parse_xsd_datetime(lit.lexical)
    elseif dtval == _XSD * "date"
        return parse_xsd_date(lit.lexical)
    elseif dtval == _XSD * "string"
        return lit.lexical
    else
        return lit.lexical
    end
end

Base.convert(::Type{Any}, lit::Literal) = _literal_to_julia(lit)
Base.convert(::Type{Int}, lit::Literal) = parse(Int, lit.lexical)
Base.convert(::Type{Float64}, lit::Literal) = parse(Float64, lit.lexical)
Base.convert(::Type{Bool}, lit::Literal) = lit.lexical in ("true", "1")
Base.convert(::Type{DateTime}, lit::Literal) = parse_xsd_datetime(lit.lexical)
Base.convert(::Type{Date}, lit::Literal) = parse_xsd_date(lit.lexical)
Base.convert(::Type{String}, lit::Literal) = lit.lexical

"""
    n3(lit::Literal) -> String

N3/SPARQL representation of the literal.
"""
function n3(lit::Literal)
    escaped = _escape_literal(lit.lexical)
    s = string("\"", escaped, "\"")
    if !isnothing(lit.language)
        s *= "@" * lit.language
        if !isnothing(lit.direction)
            s *= "--" * lit.direction
        end
    elseif !isnothing(lit.datatype)
        s *= "^^<" * lit.datatype.value * ">"
    end
    s
end

function _escape_literal(s::AbstractString)
    # Fast path: if no special characters, return as-is
    needs_escape = false
    for c in s
        if c == '\\' || c == '"' || c == '\n' || c == '\r' || c == '\t'
            needs_escape = true
            break
        end
    end
    needs_escape || return String(s)

    buf = IOBuffer(sizehint=sizeof(s) + 16)
    for c in s
        if c == '\\'
            write(buf, "\\\\")
        elseif c == '"'
            write(buf, "\\\"")
        elseif c == '\n'
            write(buf, "\\n")
        elseif c == '\r'
            write(buf, "\\r")
        elseif c == '\t'
            write(buf, "\\t")
        else
            write(buf, c)
        end
    end
    String(take!(buf))
end

# ─── Variable ───────────────────────────────────────────────────────

"""
    Variable(name::AbstractString)

A SPARQL/N3 variable (e.g., `?x`).
"""
struct Variable <: Node
    name::String

    function Variable(name::AbstractString)
        n = String(name)
        if startswith(n, '?') || startswith(n, '$')
            n = n[2:end]
        end
        isempty(n) && throw(ArgumentError("Variable name cannot be empty"))
        new(n)
    end
end

Base.string(v::Variable) = v.name
Base.show(io::IO, v::Variable) = print(io, "Variable(\"", v.name, "\")")
Base.:(==)(a::Variable, b::Variable) = a.name == b.name
Base.hash(a::Variable, h::UInt) = hash(a.name, hash(:Variable, h))

n3(v::Variable) = string("?", v.name)

# ─── TripleTerm (RDF-star) ──────────────────────────────────────────

"""
    TripleTerm(subject::Node, predicate::URIRef, object::Identifier)

An RDF-star triple term — a triple used as a term (subject or object) in another triple.
Written as `<< s p o >>` in SPARQL 1.2 and Turtle-star.
"""
struct TripleTerm <: Node
    subject::Node
    predicate::URIRef
    object::Identifier
end

Base.show(io::IO, tt::TripleTerm) = print(io, "TripleTerm(", tt.subject, ", ", tt.predicate, ", ", tt.object, ")")
Base.:(==)(a::TripleTerm, b::TripleTerm) = a.subject == b.subject && a.predicate == b.predicate && a.object == b.object
function Base.hash(a::TripleTerm, h::UInt)
    hash(a.object, hash(a.predicate, hash(a.subject, hash(:TripleTerm, h))))
end

n3(tt::TripleTerm) = string("<< ", n3(tt.subject), " ", n3(tt.predicate), " ", n3(tt.object), " >>")

# ─── Triple ─────────────────────────────────────────────────────────

"""
    Triple

An RDF triple (subject, predicate, object).
Subject must be a Node (URIRef or BNode), predicate must be a URIRef,
object can be any Identifier.
"""
struct Triple
    subject::Identifier
    predicate::Identifier  # URIRef normally; Variable in N3 rules
    object::Identifier
end

Base.show(io::IO, t::Triple) = print(io, "(", t.subject, ", ", t.predicate, ", ", t.object, ")")
Base.:(==)(a::Triple, b::Triple) = a.subject == b.subject && a.predicate == b.predicate && a.object == b.object
function Base.hash(a::Triple, h::UInt)
    hash(a.object, hash(a.predicate, hash(a.subject, hash(:Triple, h))))
end

# ─── Ordering (for SPARQL-style sorting) ────────────────────────────
# BNode < URIRef < Literal < Variable

_type_order(::BNode) = 1
_type_order(::URIRef) = 2
_type_order(::Literal) = 3
_type_order(::Variable) = 4
_type_order(::TripleTerm) = 5

function Base.isless(a::Identifier, b::Identifier)
    oa, ob = _type_order(a), _type_order(b)
    oa != ob && return oa < ob
    # Same type — fall through to type-specific isless
    return isless(string(a), string(b))
end

# ─── TriplePattern (for queries) ────────────────────────────────────

"""
A pattern for matching triples. `nothing` in any position is a wildcard.
"""
const TriplePattern = Tuple{Union{Identifier, Nothing}, Union{Identifier, Nothing}, Union{Identifier, Nothing}}

# ─── IRI Validation (RFC 3986) ──────────────────────────────────────

const _IRI_SCHEME_RE = r"^[A-Za-z][A-Za-z0-9+\-.]*$"
const _IRI_SPLIT_RE = r"^(([A-Za-z][A-Za-z0-9+\-.]*):)?(//([^/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?$"
const _BAD_PERCENT_RE = r"%(?![0-9A-Fa-f]{2})"

"""
    validate_iri(iri::AbstractString) -> Bool

Validate an IRI string according to RFC 3986.
Checks for valid scheme, no spaces/illegal characters, and proper percent-encoding.
"""
function validate_iri(iri::AbstractString)::Bool
    isempty(iri) && return false
    occursin(' ', iri) && return false
    m = match(_IRI_SPLIT_RE, iri)
    isnothing(m) && return false
    scheme = m.captures[2]
    isnothing(scheme) && return false
    isempty(scheme) && return false
    !occursin(_IRI_SCHEME_RE, scheme) && return false
    occursin(_BAD_PERCENT_RE, iri) && return false
    for ch in iri
        (ch < ' ' || ch == '\x7f') && return false
        ch in ('<', '>', '{', '}', '|', '\\', '^', '`') && return false
    end
    return true
end

"""
    validate_iri!(iri::AbstractString)

Validate an IRI string, throwing `ArgumentError` if invalid.
"""
function validate_iri!(iri::AbstractString)
    validate_iri(iri) || throw(ArgumentError("Invalid IRI: $iri"))
    nothing
end

"""
    parse_iri(iri::AbstractString) -> NamedTuple

Parse an IRI into components: `(scheme, authority, path, query, fragment)`.
Any component not present is `nothing`.
"""
function parse_iri(iri::AbstractString)
    m = match(_IRI_SPLIT_RE, iri)
    isnothing(m) && return (scheme=nothing, authority=nothing, path="", query=nothing, fragment=nothing)
    (
        scheme    = m.captures[2],
        authority = m.captures[4],
        path      = something(m.captures[5], ""),
        query     = m.captures[7],
        fragment  = m.captures[9],
    )
end

# ─── BCP 47 Language Tag Validation (RFC 5646) ─────────────────────

# Quick structural check: hyphen-separated alphanumeric subtags of 1-8 chars,
# starting with an alphabetic subtag.
const _LANGTAG_RE = r"^[A-Za-z]{1,8}(-[A-Za-z0-9]{1,8})*$"
# Full BCP 47 (RFC 5646) well-formedness:
#   langtag    = language ["-" script] ["-" region] *("-" variant)
#                *("-" extension) ["-" privateuse]
#   language   = 2*3ALPHA ["-" extlang] / 4ALPHA / 5*8ALPHA
#   extension  = singleton 1*("-" 2*8alphanum)   (singleton != x)
#   privateuse = "x" 1*("-" 1*8alphanum)
# A tag may also consist solely of a private-use sequence.
const _LANGTAG_FULL_RE = r"""^
(?:
    (?<language>[A-Za-z]{2,3}(?:-[A-Za-z]{3}){0,3}|[A-Za-z]{4,8})
    (?:-(?<script>[A-Za-z]{4}))?
    (?:-(?<region>[A-Za-z]{2}|[0-9]{3}))?
    (?:-(?:[A-Za-z0-9]{5,8}|[0-9][A-Za-z0-9]{3}))*
    (?:-[0-9A-WY-Za-wy-z](?:-[A-Za-z0-9]{2,8})+)*
    (?:-[Xx](?:-[A-Za-z0-9]{1,8})+)?
  |
    [Xx](?:-[A-Za-z0-9]{1,8})+
)$"""x

"""
    validate_langtag(tag::AbstractString) -> Bool

Validate a BCP 47 language tag per RFC 5646 (well-formedness, including
extension and private-use subtags).
"""
function validate_langtag(tag::AbstractString)::Bool
    isempty(tag) && return false
    !occursin(_LANGTAG_RE, tag) && return false
    !isnothing(match(_LANGTAG_FULL_RE, tag))
end

"""
    normalize_langtag(tag::AbstractString) -> String

Normalize a BCP 47 language tag: language lowercase, script titlecase, region
uppercase. Subtags following a singleton (extension or private-use marker)
are left lowercase, per RFC 5646 conventions.
"""
function normalize_langtag(tag::AbstractString)::String
    parts = split(tag, '-')
    isempty(parts) && return String(tag)
    result = String[lowercase(parts[1])]
    seen_singleton = length(parts[1]) == 1  # private-use-only tag ("x-...")
    for i in 2:length(parts)
        p = parts[i]
        if seen_singleton
            push!(result, lowercase(p))
        elseif length(p) == 1
            seen_singleton = true
            push!(result, lowercase(p))
        elseif length(p) == 4 && all(isletter, p)
            push!(result, titlecase(p))
        elseif length(p) == 2 && all(isletter, p)
            push!(result, uppercase(p))
        elseif length(p) == 3 && all(isdigit, p)
            push!(result, p)
        else
            push!(result, lowercase(p))
        end
    end
    join(result, "-")
end
