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
end

URIRef(u::URIRef) = u

Base.string(u::URIRef) = u.value
Base.show(io::IO, u::URIRef) = print(io, "URIRef(\"", u.value, "\")")
Base.:(==)(a::URIRef, b::URIRef) = a.value == b.value
Base.hash(a::URIRef, h::UInt) = hash(a.value, hash(:URIRef, h))
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

    function BNode(id::AbstractString)
        new(String(id))
    end
end

function BNode()
    BNode("N" * replace(string(uuid4()), "-" => ""))
end

Base.string(b::BNode) = b.id
Base.show(io::IO, b::BNode) = print(io, "BNode(\"", b.id, "\")")
Base.:(==)(a::BNode, b::BNode) = a.id == b.id
Base.hash(a::BNode, h::UInt) = hash(a.id, hash(:BNode, h))
Base.isless(a::BNode, b::BNode) = isless(a.id, b.id)

n3(b::BNode) = string("_:", b.id)

# ─── Literal ────────────────────────────────────────────────────────

"""
    Literal(value; datatype=nothing, lang=nothing)
    Literal(value::Number)
    Literal(value::Bool)
    Literal(value::DateTime)

An RDF literal value with optional datatype URI or language tag.

Language tags and datatypes are mutually exclusive (per RDF spec, a language-tagged
literal implicitly has datatype `rdf:langString`).

# Examples
```julia
Literal("hello")
Literal("bonjour", lang="fr")
Literal(42)                        # auto-typed as xsd:integer
Literal("3.14", datatype=URIRef("http://www.w3.org/2001/XMLSchema#decimal"))
```
"""
struct Literal <: Identifier
    lexical::String
    datatype::Union{URIRef, Nothing}
    language::Union{String, Nothing}

    function Literal(lexical::AbstractString;
                     datatype::Union{URIRef, Nothing}=nothing,
                     lang::Union{AbstractString, Nothing}=nothing)
        if !isnothing(lang) && !isnothing(datatype)
            rdf_langString = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#langString")
            if datatype != rdf_langString
                throw(ArgumentError("Language-tagged literals cannot have an explicit datatype other than rdf:langString"))
            end
        end
        language = isnothing(lang) ? nothing : lowercase(String(lang))
        new(String(lexical), datatype, language)
    end
end

# Convenience constructors for common Julia types
const _XSD = "http://www.w3.org/2001/XMLSchema#"

Literal(v::Bool) = Literal(v ? "true" : "false", datatype=URIRef(_XSD * "boolean"))
Literal(v::Integer) = Literal(string(v), datatype=URIRef(_XSD * "integer"))
Literal(v::AbstractFloat) = Literal(string(v), datatype=URIRef(_XSD * "double"))
Literal(v::DateTime) = Literal(Dates.format(v, dateformat"yyyy-mm-ddTHH:MM:SS"), datatype=URIRef(_XSD * "dateTime"))
Literal(v::Date) = Literal(Dates.format(v, dateformat"yyyy-mm-dd"), datatype=URIRef(_XSD * "date"))
Literal(v::Time) = Literal(Dates.format(v, dateformat"HH:MM:SS"), datatype=URIRef(_XSD * "time"))

function Base.show(io::IO, lit::Literal)
    print(io, "Literal(\"", lit.lexical, "\"")
    if !isnothing(lit.language)
        print(io, ", lang=\"", lit.language, "\"")
    elseif !isnothing(lit.datatype)
        print(io, ", datatype=", lit.datatype)
    end
    print(io, ")")
end

Base.string(lit::Literal) = lit.lexical

function Base.:(==)(a::Literal, b::Literal)
    a.lexical == b.lexical && a.datatype == b.datatype && a.language == b.language
end

function Base.hash(a::Literal, h::UInt)
    h = hash(a.lexical, hash(:Literal, h))
    h = hash(a.datatype, h)
    hash(a.language, h)
end

"""
    lang(lit::Literal) -> Union{String, Nothing}

Return the language tag, or `nothing`.
"""
lang(lit::Literal) = lit.language

"""
    datatype(lit::Literal) -> Union{URIRef, Nothing}

Return the datatype URI, or `nothing`.
"""
datatype(lit::Literal) = lit.datatype

"""
    toPython(lit::Literal)

Convert a Literal to a native Julia value based on its datatype.
Returns the lexical string if the datatype is unrecognized.
"""
function toPython(lit::Literal)
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
        return DateTime(lit.lexical, dateformat"yyyy-mm-ddTHH:MM:SS")
    elseif dtval == _XSD * "date"
        return Date(lit.lexical, dateformat"yyyy-mm-dd")
    elseif dtval == _XSD * "string"
        return lit.lexical
    else
        return lit.lexical
    end
end

"""
    n3(lit::Literal) -> String

N3/SPARQL representation of the literal.
"""
function n3(lit::Literal)
    escaped = _escape_literal(lit.lexical)
    s = string("\"", escaped, "\"")
    if !isnothing(lit.language)
        s *= "@" * lit.language
    elseif !isnothing(lit.datatype)
        s *= "^^<" * lit.datatype.value * ">"
    end
    s
end

function _escape_literal(s::AbstractString)
    buf = IOBuffer()
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
