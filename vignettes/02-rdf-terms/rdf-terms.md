# RDF Terms: URIs, Literals, and Blank Nodes


## Overview

Every RDF triple is built from three kinds of *terms*: URIs (resources),
Literals (values), and Blank Nodes (anonymous resources). This vignette
covers how to create and work with each type.

``` julia
using RDFLib
```

    Precompiling packages...
    Info Given RDFLib was explicitly requested, output will be shown live 
    WARNING: Method definition convert(Type{Any}, RDFLib.Literal) in module RDFLib at /Users/sdwfrost/Projects/rdf/RDFLib.jl/src/terms.jl:239 overwritten at /Users/sdwfrost/Projects/rdf/RDFLib.jl/src/terms.jl:254.
    ERROR: Method overwriting is not permitted during Module precompilation. Use `__precompile__(false)` to opt-out of precompilation.
       1142.9 ms  ? RDFLib
    WARNING: Method definition convert(Type{Any}, RDFLib.Literal) in module RDFLib at /Users/sdwfrost/Projects/rdf/RDFLib.jl/src/terms.jl:239 overwritten at /Users/sdwfrost/Projects/rdf/RDFLib.jl/src/terms.jl:254.
    ERROR: Method overwriting is not permitted during Module precompilation. Use `__precompile__(false)` to opt-out of precompilation.

## URIs (URIRef)

A URI (Uniform Resource Identifier) uniquely identifies a resource. In
RDFLib.jl, they are represented by `URIRef`.

``` julia
# Create URIs directly
person = URIRef("http://example.org/person/alice")
println(person)
println("Type: ", typeof(person))
```

    URIRef("http://example.org/person/alice")
    Type: URIRef

``` julia
# Using namespaces (preferred)
ex = Namespace("http://example.org/")
alice = ex("alice")
knows = ex("knows")

println(alice)
println("Value: ", alice.value)
```

    URIRef("http://example.org/alice")
    Value: http://example.org/alice

``` julia
# URI utilities
uri = URIRef("http://example.org/vocab#name")
println("Fragment: ", fragment(uri))
println("Defragmented: ", defrag(uri))
println("N3 syntax: ", n3(uri))
```

    Fragment: name
    Defragmented: URIRef("http://example.org/vocab")
    N3 syntax: <http://example.org/vocab#name>

## Literals

Literals represent data values — strings, numbers, dates, booleans, etc.
They can have an optional language tag or datatype.

### Plain Strings

``` julia
# Simple string literal
name = Literal("Alice")
println(name)
println("Lexical value: ", name.lexical)
println("Datatype: ", datatype(name))
println("N3: ", n3(name))
```

    Literal("Alice")
    Lexical value: Alice
    Datatype: nothing
    N3: "Alice"

### Language-Tagged Strings

``` julia
# Literals with language tags
label_en = Literal("Cat"; lang="en")
label_fr = Literal("Chat"; lang="fr")
label_de = Literal("Katze"; lang="de")

println("English: ", label_en, " (lang=", lang(label_en), ")")
println("French:  ", label_fr, " (lang=", lang(label_fr), ")")
println("German:  ", label_de, " (lang=", lang(label_de), ")")
```

    English: Literal("Cat", lang="en") (lang=en)
    French:  Literal("Chat", lang="fr") (lang=fr)
    German:  Literal("Katze", lang="de") (lang=de)

### Typed Literals

``` julia
# Numeric types
age = Literal(30)
println("Integer: ", age, " — datatype: ", datatype(age))

height = Literal(1.75)
println("Float:   ", height, " — datatype: ", datatype(height))

# Boolean
active = Literal(true)
println("Boolean: ", active, " — datatype: ", datatype(active))

# Explicit datatype
score = Literal("98.6"; datatype=XSD.decimal)
println("Decimal: ", score, " — datatype: ", datatype(score))
```

    Integer: Literal("30", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer")) — datatype: URIRef("http://www.w3.org/2001/XMLSchema#integer")
    Float:   Literal("1.75", datatype=URIRef("http://www.w3.org/2001/XMLSchema#double")) — datatype: URIRef("http://www.w3.org/2001/XMLSchema#double")
    Boolean: Literal("true", datatype=URIRef("http://www.w3.org/2001/XMLSchema#boolean")) — datatype: URIRef("http://www.w3.org/2001/XMLSchema#boolean")
    Decimal: Literal("98.6", datatype=URIRef("http://www.w3.org/2001/XMLSchema#decimal")) — datatype: URIRef("http://www.w3.org/2001/XMLSchema#decimal")

### XSD Date/Time Types

``` julia
using Dates

# Date and time literals
today_lit = xsd_literal(today())
println("Date: ", n3(today_lit))

now_lit = xsd_literal(now())
println("DateTime: ", n3(now_lit))
```

    Date: "2026-02-26"^^<http://www.w3.org/2001/XMLSchema#date>
    DateTime: "2026-02-26T10:23:15"^^<http://www.w3.org/2001/XMLSchema#dateTime>

### Extracting Values

``` julia
# convert(Any, lit) extracts the native Julia value from a Literal
println("convert(Any, Literal(42))     = ", convert(Any, Literal(42)), " :: ", typeof(convert(Any, Literal(42))))
println("convert(Any, Literal(3.14))   = ", convert(Any, Literal(3.14)), " :: ", typeof(convert(Any, Literal(3.14))))
println("convert(Any, Literal(true))   = ", convert(Any, Literal(true)), " :: ", typeof(convert(Any, Literal(true))))
println("convert(Any, Literal(\"hi\")) = ", convert(Any, Literal("hi")), " :: ", typeof(convert(Any, Literal("hi"))))
```

    convert(Any, Literal(42))     = 42 :: Int64
    convert(Any, Literal(3.14))   = 3.14 :: Float64
    convert(Any, Literal(true))   = true :: Bool
    convert(Any, Literal("hi")) = hi :: String

## Blank Nodes (BNode)

Blank nodes represent anonymous resources — they have no global
identifier.

``` julia
# Auto-generated blank node (UUID-based)
b1 = BNode()
println("Auto BNode: ", b1, " (id=", b1.id, ")")

# Named blank node
b2 = BNode("address1")
println("Named BNode: ", b2, " (id=", b2.id, ")")
println("N3 syntax: ", n3(b2))
```

    Auto BNode: BNode("Nd80b528b57534e49b1b08d6661a186cf") (id=Nd80b528b57534e49b1b08d6661a186cf)
    Named BNode: BNode("address1") (id=address1)
    N3 syntax: _:address1

``` julia
# Blank nodes are useful for structured data without global identity
g = RDFGraph()
ex = Namespace("http://example.org/")

alice = ex("alice")
address = BNode("addr1")

add!(g, Triple(alice, ex("address"), address))
add!(g, Triple(address, ex("street"), Literal("123 Main St")))
add!(g, Triple(address, ex("city"), Literal("Springfield")))
add!(g, Triple(address, ex("zip"), Literal("62701")))

println(serialize(g, TurtleFormat()))
```

    @prefix ns1: <http://example.org/> .
    @prefix owl: <http://www.w3.org/2002/07/owl#> .
    @prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
    @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
    @prefix skos: <http://www.w3.org/2004/02/skos/core#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

    ns1:alice ns1:address [ ns1:city "Springfield" ;
            ns1:street "123 Main St" ;
            ns1:zip "62701" ] .

## Variables

Variables are used in SPARQL queries and N3 rules. They represent
unknowns to be bound during matching.

``` julia
# Create variables
x = Variable("x")
name_var = Variable("name")

println("Variable: ", x, " — name: ", x.name)
println("N3: ", n3(x))
```

    Variable: Variable("x") — name: x
    N3: ?x

## Triples

A triple combines a subject, predicate, and object into a single
statement.

``` julia
ex = Namespace("http://example.org/")

t = Triple(ex("earth"), RDF.type, ex("Planet"))
println("Subject:   ", t.subject)
println("Predicate: ", t.predicate)
println("Object:    ", t.object)
println("N3:        ", n3(t.subject), " ", n3(t.predicate), " ", n3(t.object), " .")
```

    Subject:   URIRef("http://example.org/earth")
    Predicate: URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    Object:    URIRef("http://example.org/Planet")
    N3:        <http://example.org/earth> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://example.org/Planet> .

## Type Hierarchy

RDFLib.jl uses Julia’s type system to model the RDF term hierarchy:

    Identifier (abstract)
    ├── Node (abstract)
    │   ├── IdentifiedNode (abstract)
    │   │   ├── URIRef
    │   │   └── BNode
    │   └── Formula (N3 quoted graphs)
    ├── Literal
    └── Variable

``` julia
# Type checking
println("URIRef <: Node: ", URIRef <: Node)
println("Literal <: Identifier: ", Literal <: Identifier)
println("BNode <: IdentifiedNode: ", BNode <: IdentifiedNode)
println("Variable <: Identifier: ", Variable <: Identifier)
```

    URIRef <: Node: true
    Literal <: Identifier: true
    BNode <: IdentifiedNode: true
    Variable <: Identifier: true

## Equality and Hashing

RDF terms support equality comparison and hashing, which is important
for graph operations.

``` julia
# URIs are equal if their values match
println(URIRef("http://example.org/a") == URIRef("http://example.org/a"))  # true
println(URIRef("http://example.org/a") == URIRef("http://example.org/b"))  # false

# Literals compare by value, datatype, and language
println(Literal("hello") == Literal("hello"))     # true
println(Literal(42) == Literal(42))               # true
println(Literal("hi"; lang="en") == Literal("hi"; lang="fr"))  # false
```

    true
    false
    true
    true
    false

## Parsing Terms from N3 Syntax

You can parse individual terms from N3/SPARQL string syntax:

``` julia
# Parse various term types from N3 notation
println(from_n3("<http://example.org/alice>"))
println(from_n3("\"hello\""))
println(from_n3("\"42\"^^<http://www.w3.org/2001/XMLSchema#integer>"))
println(from_n3("_:blank1"))
```

    URIRef("http://example.org/alice")
    Literal("hello")
    Literal("42", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))
    BNode("blank1")
