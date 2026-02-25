# Namespaces and Vocabularies


## Overview

Namespaces provide short, readable prefixes for long URI bases.
RDFLib.jl comes with many predefined namespaces for common RDF
vocabularies and lets you create your own.

``` julia
using RDFLib
```

## Predefined Namespaces

RDFLib.jl includes all major W3C and community vocabularies:

``` julia
# Core W3C vocabularies
println("RDF type:          ", RDF.type)
println("RDFS label:        ", RDFS("label"))
println("OWL Class:         ", OWL("Class"))
println("XSD integer:       ", XSD.integer)
println("XSD dateTime:      ", XSD.dateTime)

# Community vocabularies
println("FOAF name:         ", FOAF("name"))
println("DC title:          ", DC("title"))
println("DCTERMS created:   ", DCTERMS("created"))
println("SKOS prefLabel:    ", SKOS("prefLabel"))
println("PROV wasGeneratedBy: ", PROV("wasGeneratedBy"))
println("Schema.org name:   ", SDO("name"))
```

    RDF type:          URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    RDFS label:        URIRef("http://www.w3.org/2000/01/rdf-schema#label")
    OWL Class:         URIRef("http://www.w3.org/2002/07/owl#Class")
    XSD integer:       URIRef("http://www.w3.org/2001/XMLSchema#integer")
    XSD dateTime:      URIRef("http://www.w3.org/2001/XMLSchema#dateTime")
    FOAF name:         URIRef("http://xmlns.com/foaf/0.1/name")
    DC title:          URIRef("http://purl.org/dc/elements/1.1/title")
    DCTERMS created:   URIRef("http://purl.org/dc/terms/created")
    SKOS prefLabel:    URIRef("http://www.w3.org/2004/02/skos/core#prefLabel")
    PROV wasGeneratedBy: URIRef("http://www.w3.org/ns/prov#wasGeneratedBy")
    Schema.org name:   URIRef("https://schema.org/name")

## Creating Custom Namespaces

``` julia
# Simple namespace from a URI base
bio = Namespace("http://purl.org/vocab/bio/0.1/")
println(bio("Birth"))
println(bio("Event"))

# Use namespaces to build URIs concisely
dbr = Namespace("http://dbpedia.org/resource/")
dbo = Namespace("http://dbpedia.org/ontology/")

g = RDFGraph()
add!(g, Triple(dbr("Julia_Language"), RDF.type, dbo("ProgrammingLanguage")))
add!(g, Triple(dbr("Julia_Language"), dbo("designer"), dbr("Jeff_Bezanson")))
add!(g, Triple(dbr("Julia_Language"), RDFS("label"), Literal("Julia"; lang="en")))
```

    URIRef("http://purl.org/vocab/bio/0.1/Birth")
    URIRef("http://purl.org/vocab/bio/0.1/Event")

    RDFGraph (3 triples)

## Binding Prefixes to Graphs

Prefix bindings control how URIs are shortened in serialized output:

``` julia
bind!(g, "dbr", Namespace("http://dbpedia.org/resource/"))
bind!(g, "dbo", Namespace("http://dbpedia.org/ontology/"))

println(serialize(g, TurtleFormat()))
```

    @prefix dbo: <http://dbpedia.org/ontology/> .
    @prefix dbr: <http://dbpedia.org/resource/> .
    @prefix owl: <http://www.w3.org/2002/07/owl#> .
    @prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
    @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
    @prefix skos: <http://www.w3.org/2004/02/skos/core#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

    dbr:Julia_Language a dbo:ProgrammingLanguage ;
        dbo:designer dbr:Jeff_Bezanson ;
        rdfs:label "Julia"@en .

## Namespace Manager

The `NamespaceManager` provides centralized prefix management:

``` julia
nsm = NamespaceManager()
bind!(nsm, "ex", Namespace("http://example.org/"))
bind!(nsm, "foaf", Namespace("http://xmlns.com/foaf/0.1/"))
bind!(nsm, "schema", Namespace("http://schema.org/"))

# Expand CURIEs (Compact URIs)
println(expand_curie(nsm, "ex:alice"))
println(expand_curie(nsm, "foaf:name"))
```

    URIRef("http://example.org/alice")
    URIRef("http://xmlns.com/foaf/0.1/name")

``` julia
# Compute qualified names (reverse of expand)
qname = compute_qname(nsm, URIRef("http://xmlns.com/foaf/0.1/Person"))
println("QName: ", qname)
```

    QName: ("foaf", "http://xmlns.com/foaf/0.1/", "Person")

## Programmatic Namespace Creation

Create new vocabulary namespaces with metadata:

``` julia
# create_namespace generates Julia code for a DefinedNamespace from a graph
# First, build a small ontology graph
vocab_g = RDFGraph()
vocab_ns = Namespace("http://example.org/myvocab#")
add!(vocab_g, Triple(vocab_ns("Person"), RDF.type, RDFS("Class")))
add!(vocab_g, Triple(vocab_ns("hasFriend"), RDF.type, RDF("Property")))

code = create_namespace(vocab_g, "http://example.org/myvocab#", "MyVocab")
println(code)

# For direct use, just create a Namespace
my_vocab = Namespace("http://example.org/myvocab#")
println(my_vocab("Person"))
println(my_vocab("hasFriend"))
```

    # Auto-generated namespace: MyVocab
    # URI: http://example.org/myvocab#

    const MyVocab = DefinedNamespace(
        "http://example.org/myvocab#",
        Set([
            "Person",
            "hasFriend"
        ])
    )

    URIRef("http://example.org/myvocab#Person")
    URIRef("http://example.org/myvocab#hasFriend")

## Using Namespaces in Practice

A common pattern is to define all your namespaces at the top of your
code:

``` julia
# Define project namespaces
ex = Namespace("http://example.org/")
schema = Namespace("http://schema.org/")

# Build a well-prefixed graph
g = RDFGraph()
bind!(g, "ex", ex)
bind!(g, "schema", schema)
bind!(g, "xsd", Namespace("http://www.w3.org/2001/XMLSchema#"))

# Describe a conference
conf = ex("juliacon2025")
add!(g, Triple(conf, RDF.type, schema("Event")))
add!(g, Triple(conf, schema("name"), Literal("JuliaCon 2025")))
add!(g, Triple(conf, schema("startDate"), Literal("2025-07-21"; datatype=XSD.date)))
add!(g, Triple(conf, schema("endDate"), Literal("2025-07-25"; datatype=XSD.date)))
add!(g, Triple(conf, schema("location"), Literal("Aachen, Germany")))
add!(g, Triple(conf, schema("url"), URIRef("https://juliacon.org/2025/")))

println(serialize(g, TurtleFormat()))
```

    @prefix ex: <http://example.org/> .
    @prefix ns1: <https://juliacon.org/2025/> .
    @prefix owl: <http://www.w3.org/2002/07/owl#> .
    @prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
    @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
    @prefix schema: <http://schema.org/> .
    @prefix skos: <http://www.w3.org/2004/02/skos/core#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

    ex:juliacon2025 a schema:Event ;
        schema:endDate "2025-07-25"^^xsd:date ;
        schema:location "Aachen, Germany" ;
        schema:name "JuliaCon 2025" ;
        schema:startDate "2025-07-21"^^xsd:date ;
        schema:url ns1: .

## Common Vocabulary Prefixes

Here is a quick reference of commonly used namespace prefixes:

| Prefix | URI | Purpose |
|----|----|----|
| `rdf:` | `http://www.w3.org/1999/02/22-rdf-syntax-ns#` | RDF syntax |
| `rdfs:` | `http://www.w3.org/2000/01/rdf-schema#` | RDF Schema |
| `owl:` | `http://www.w3.org/2002/07/owl#` | OWL ontology |
| `xsd:` | `http://www.w3.org/2001/XMLSchema#` | XML Schema datatypes |
| `foaf:` | `http://xmlns.com/foaf/0.1/` | Friend of a Friend |
| `dc:` | `http://purl.org/dc/elements/1.1/` | Dublin Core |
| `dcterms:` | `http://purl.org/dc/terms/` | Dublin Core Terms |
| `skos:` | `http://www.w3.org/2004/02/skos/core#` | Knowledge organization |
| `schema:` | `http://schema.org/` | Schema.org |
| `prov:` | `http://www.w3.org/ns/prov#` | Provenance |
| `shacl:` | `http://www.w3.org/ns/shacl#` | Shapes Constraint Language |
