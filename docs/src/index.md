# RDFLib.jl

*An idiomatic Julia package for working with RDF (Resource Description Framework) data.*

RDFLib.jl is a comprehensive Julia port of Python's [rdflib](https://rdflib.readthedocs.io/) package. It uses Julia's type system and multiple dispatch to provide a natural, high-performance API for creating, querying, serializing, and reasoning over RDF graphs.

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/JuliaKnowledge/RDFLib.jl")
```

## Quick Start

```julia
using RDFLib

# Create a graph and define namespaces
g = RDFGraph()
ex = Namespace("http://example.org/")

# Add triples
add!(g, Triple(ex("alice"), RDF.type, FOAF.Person))
add!(g, Triple(ex("alice"), FOAF.name, Literal("Alice")))
add!(g, Triple(ex("alice"), FOAF.age, Literal(30)))
add!(g, Triple(ex("alice"), FOAF.knows, ex("bob")))
add!(g, Triple(ex("bob"), RDF.type, FOAF.Person))
add!(g, Triple(ex("bob"), FOAF.name, Literal("Bob", lang="en")))

# Query with SPARQL
results = sparql_query(g, """
    PREFIX foaf: <http://xmlns.com/foaf/0.1/>
    SELECT ?name WHERE {
        ?person a foaf:Person .
        ?person foaf:name ?name .
    }
""")
for row in results
    println(row["name"])
end

# Serialize to Turtle
println(serialize(g, TurtleFormat()))
```

## Features

- **14+ serialization formats** including Turtle, JSON-LD, RDF/XML, N-Triples, TriG, N3, and more
- **Full SPARQL 1.2 query engine** with SELECT, ASK, CONSTRUCT, DESCRIBE, UPDATE, aggregates, property paths, and federated queries
- **Multiple store backends**: in-memory, SQLite, DuckDB, LMDB, remote SPARQL endpoints
- **Reasoning engines**: RDFS/OWL forward chaining, N3 (Euler Abstract Machine), Datalog (semi-naive), ProbLog (probabilistic)
- **Validation**: SHACL shapes and ShEx (Shape Expressions)
- **GeoSPARQL**: WKT parsing, spatial predicates, metric functions
- **28+ predefined namespaces**: RDF, RDFS, XSD, OWL, SKOS, FOAF, DC, PROV, SDO, and more

## Contents

```@contents
Pages = [
    "tutorials/getting-started.md",
    "tutorials/rdf-terms.md",
    "tutorials/building-graphs.md",
    "tutorials/namespaces.md",
    "tutorials/serialization.md",
    "tutorials/sparql-queries.md",
]
Depth = 1
```
