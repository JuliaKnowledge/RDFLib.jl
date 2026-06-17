# RDFLib.jl

[![Build Status](https://github.com/JuliaKnowledge/RDFLib.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/JuliaKnowledge/RDFLib.jl/actions/workflows/CI.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

An idiomatic Julia port of Python's [rdflib](https://rdflib.readthedocs.io/) package for working with RDF (Resource Description Framework) data. RDFLib.jl uses Julia's type system and multiple dispatch to provide a natural API for creating, querying, and serializing RDF graphs, with indexed in-memory stores, a dictionary-encoded store for larger graphs, and persistent SQLite/DuckDB/LMDB backends.

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/JuliaKnowledge/RDFLib.jl")
```

Or from the Pkg REPL:

```
pkg> add https://github.com/JuliaKnowledge/RDFLib.jl
```

## Testing

Run the full suite with:

```julia
using Pkg
Pkg.test()
```

The repository now includes hermetic fixtures for the previously skipped
ProbLog and Jelly interoperability coverage, so the default suite does not need
external files or a local Python `pyjelly` environment.

Optional integration dependencies are still useful for extra parity checks:

- **Fuseki** — if a live endpoint is available at `http://localhost:3030/test`
  (or `SPARQL_TEST_ENDPOINT` is set), `test/test_sparql_remote.jl` compares the
  local engine against a live remote store. Without Fuseki, the same file runs a
  local smoke fallback instead of skipping.
- **SWI-Prolog + `eye.pl`** — enables external EYE comparison in
  `test/test_n3_examples.jl`. Without it, the Julia reasoner assertions still
  run.
- **Python + `pyjelly` in `.venv/`** — enables a live Julia↔Python Jelly
  roundtrip in `test/test_jelly.jl`. Without it, the suite uses the checked-in
  `pyjelly` fixture under `benchmarks/results/jelly/`.

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
    println(row["name"])  # Literal("Alice"), Literal("Bob")
end

# Serialize to Turtle
turtle_str = serialize(g, TurtleFormat())
println(turtle_str)
```

## Features

### Serialization Formats

| Format | Serialize | Parse | Type |
|--------|-----------|-------|------|
| N-Triples (incl. RDF-star triple terms, directional literals) | ✅ | ✅ | `NTriplesFormat()` |
| Turtle (incl. quoted triples `<< >>`, annotations, directional literals) | ✅ | ✅ | `TurtleFormat()` |
| RDF/XML (xml:base, xml:lang inheritance, parseType Literal/Resource/Collection, rdf:li, rdf:ID reification) | ✅ | ✅ | `RDFXMLFormat()` |
| JSON-LD 1.1 (scoped contexts, container maps, `@list`/`@reverse`/`@nest`/`@direction`/`@json`, remote context loader hook) | ✅ | ✅ | `JSONLDFormat()` |
| TriG | ✅ | ✅ | `TriGFormat()` |
| N-Quads | ✅ | ✅ | `NQuadsFormat()` |
| Notation3 (N3) | ✅ | ✅ | `N3Format()` |
| TriX | ✅ | ✅ | — |
| Hextuples | ✅ | ✅ | — |
| Long Turtle | ✅ | — | — |
| RDF Patch | ✅ | ✅ | — |
| SPARQL Results JSON | ✅ | ✅ | — |
| SPARQL Results XML | ✅ | ✅ | — |
| SPARQL Results CSV | ✅ | ✅ | — |
| SPARQL Results TSV | ✅ | ✅ | — |

### Store Backends

| Store | Description |
|-------|-------------|
| `MemoryStore` | In-memory triple store with SPO/POS/OSP indices (default) |
| `EncodedStore` | Dictionary-encoded in-memory store (interned terms, faster joins on larger graphs) |
| `SQLiteStore` | Persistent storage using SQLite (batched bulk loads, prepared statements) |
| `DuckDBStore` | Analytical storage using DuckDB, with SQL pushdown for eligible queries |
| `LMDBStore` | Persistent memory-mapped storage using LMDB (dictionary-encoded, sorted indices) |
| `SPARQLStore` | Remote SPARQL endpoint as read-only store |
| `AuditableStore` | Wrapper that journals all changes with undo support |
| `ConcurrentStore` | Thread-safe wrapper for concurrent access |

### SPARQL Query Engine

SPARQL 1.1 query and update engine with SPARQL 1.2 features:

- **SELECT** — variable bindings with DISTINCT, REDUCED, LIMIT, OFFSET, ORDER BY (spec total ordering across term types)
- **ASK** — boolean existence queries
- **CONSTRUCT** — build new graphs from query patterns (ORDER BY/LIMIT honored)
- **DESCRIBE** — concise bounded descriptions
- **UPDATE** — INSERT DATA, DELETE DATA, INSERT/DELETE WHERE, and graph management (CREATE, DROP, CLEAR, COPY, MOVE, ADD, WITH) over datasets
- Aggregates: COUNT, SUM, AVG, MIN, MAX, GROUP_CONCAT, SAMPLE (plus MEDIAN/MODE extensions), with spec-conformant empty-group behavior
- GROUP BY (including expression aliases) / HAVING
- FILTER expressions with datatype-driven typed comparisons and three-valued error semantics; XSD constructor casts (`xsd:integer(?x)` etc.)
- OPTIONAL, UNION, MINUS, BIND, VALUES, blank-node property lists, collections, BASE
- Property paths (`/`, `|`, `*`, `+`, `?`, `^`, `!` including negated sets with inverse members), index-backed evaluation
- GRAPH / FROM / FROM NAMED over `Dataset` and `ConjunctiveGraph` (on a plain `RDFGraph`, FROM falls back to the graph itself)
- Subqueries and federated queries (SERVICE), with FILTER/BIND/OPTIONAL serialized to the remote endpoint
- SPARQL 1.2: directional language-tagged literals (`"x"@en--ltr`), LANGDIR / hasLANG / hasLANGDIR / STRLANGDIR, triple terms with TRIPLE/SUBJECT/PREDICATE/OBJECT/isTRIPLE

The same query answers are guaranteed across `MemoryStore`, `EncodedStore`, and `DuckDBStore` by a cross-evaluator consistency test suite.

### Reasoning & Inference

- **RDFS/OWL inference** — forward-chaining RDFS entailment (rdfs2, 3, 5, 6, 7, 9, 10, 11, 12, 13; axiomatic rdfs4a/4b/8 opt-in via `axiomatic=true`) and an OWL 2 RL-style rule subset (sameAs, property chains, hasValue, someValuesFrom/allValuesFrom, intersection/union/complement, hasKey, (inverse)functional properties)
- **N3 reasoning** — forward and backward chaining with Notation3 rules (semi-naive delta evaluation, including rules with pure builtins), ~125 built-in predicates for math, string, list, and crypto operations, with proof traces
- **Datalog** — semi-naive bottom-up evaluation with stratified negation (negation-as-failure with safety and stratifiability checks)
- **ProbLog** — probabilistic logic programming with exact BDD-based inference
- **InfixOWL** — DSL for building OWL ontologies

### Validation

- **SHACL** — validate graphs against SHACL shapes, producing `ValidationReport` with `ValidationResult` entries. Supports the core constraint components including logical constraints (`sh:not/and/or/xone`), shape-based constraints (`sh:node`, `sh:qualifiedValueShape` with disjointness), `sh:closed`/`sh:ignoredProperties`, full property paths (sequence, inverse, alternative, zero-or-more, one-or-more, zero-or-one), pair constraints (`sh:equals/disjoint/lessThan/lessThanOrEquals`), `sh:languageIn`/`sh:uniqueLang`, SPARQL-based constraints (`sh:sparql`), and all four target kinds plus implicit class targets. See the `validate` docstring for exact coverage.
- **ShEx** — ShExC schema parsing and validation

### Graph Utilities

| Function | Description |
|----------|-------------|
| `isomorphic(g1, g2)` | Test graph isomorphism (blank-node independent) |
| `merge_graphs(g1, g2)` | Merge two graphs |
| `graph_diff(g1, g2)` | Compute added/removed triples |
| `cbd(g, node)` | Concise Bounded Description |
| `connected_components(g)` | Find connected components |
| `graph_stats(g)` | Triple count, node/predicate statistics |
| `to_dot(g)` | GraphViz DOT visualization |
| `graph_hash(g)` | Blank-node-independent hash |

### Datasets (Named Graphs)

```julia
ds = Dataset()
add_graph(ds, URIRef("http://example.org/g1"), g)
for quad in quads(ds)
    println(quad)
end
```

### InfixOWL DSL

Build OWL ontologies using a Julia DSL:

```julia
g = RDFGraph()
cls = OWLClass(g, URIRef("http://example.org/Person"))
subclass_of!(g, cls, OWLClass(g, URIRef("http://example.org/Agent")))
```

### VoID Metadata

```julia
void_graph = generate_void(g, URIRef("http://example.org/dataset"))
```

### Predefined Namespaces

28+ standard namespaces available: `RDF`, `RDFS`, `XSD`, `OWL`, `SKOS`, `FOAF`, `DC`, `DCTERMS`, `DCAT`, `PROV`, `SDO`, `SH`, `VANN`, `VOID`, `DOAP`, `ORG`, `GEO`, and more.

### Additional Features

- **Collections & Containers** — `add_collection!`, `collect_list`, `add_container!`, `collect_container`
- **Resource abstraction** — navigate graphs using `Resource` objects
- **Content negotiation** — `load_rdf` from URLs with automatic format detection
- **Event system** — observe graph changes with `on!`, `off!`, `emit!`
- **Plugin system** — register custom parsers, serializers, and stores
- **Namespace creator** — `create_namespace` to build custom namespace modules
- **Graph describer** — `Describer` DSL for building graph fragments
- **CLI tools** — `rdfpipe` for format conversion, `csv2rdf` for CSV-to-RDF

## API Reference

### Core Types

- `URIRef(uri)` — RDF URI reference
- `BNode()` / `BNode(id)` — blank node
- `Literal(value; datatype=nothing, lang=nothing)` — RDF literal
- `Variable(name)` — SPARQL variable
- `Triple(s, p, o)` — RDF triple
- `Quad(s, p, o, g)` — RDF quad (named graph)

### Graph Operations

- `RDFGraph()` — create empty graph
- `add!(g, triple)` — add a triple
- `remove!(g, triple)` — remove a triple
- `triples(g; subject, predicate, object)` — pattern matching
- `subjects(g, p, o)`, `predicates(g, s, o)`, `objects(g, s, p)` — accessors
- `length(g)`, `isempty(g)`, `in(triple, g)` — basic queries

### Serialization

- `serialize(g, format)` — serialize graph to string
- `parse_rdf(str, format)` — parse string into new graph
- `parse_rdf!(g, str, format)` — parse into existing graph
- `load_rdf(url)` — load from URL with content negotiation
- `save_rdf(g, path, format)` — save to file

### SPARQL

- `sparql_query(g, query)` — execute SELECT/ASK/CONSTRUCT/DESCRIBE
- `sparql_update(g, query)` — execute INSERT/DELETE
- `sparql_results_json(results)` — serialize results to JSON
- `sparql_results_xml(results)` — serialize results to XML
- `sparql_results_csv(results)` — serialize results to CSV
- `sparql_results_tsv(results)` — serialize results to TSV
- `parse_sparql_results_json(str)` — parse JSON results
- `parse_sparql_results_xml(str)` — parse XML results
- `parse_sparql_results_csv(str)` — parse CSV results
- `parse_sparql_results_tsv(str)` — parse TSV results

### Namespaces

- `Namespace(uri)` — create namespace; use `ns("localname")` to mint URIs
- `bind!(nsm, prefix, uri)` — bind prefix in namespace manager
- `expand_curie(nsm, curie)` — expand `prefix:local` to full URI
- `compute_qname(nsm, uri)` — compute qualified name for URI

## Vignettes

| # | Topic | Description |
|---|-------|-------------|
| 1 | [Getting Started](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/01-getting-started/getting-started.md) | Installation, first graph, basic operations |
| 2 | [RDF Terms](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/02-rdf-terms/rdf-terms.md) | URIs, literals, and blank nodes |
| 3 | [Building Graphs](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/03-building-graphs/building-graphs.md) | Graph construction and manipulation |
| 4 | [Namespaces](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/04-namespaces/namespaces.md) | Namespaces and vocabularies |
| 5 | [Serialization](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/05-serialization/serialization.md) | Serialization formats |
| 6 | [SPARQL Queries](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/06-sparql-queries/sparql-queries.md) | SPARQL queries and updates |
| 7 | [Collections & Containers](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/07-collections-containers/collections-containers.md) | RDF collections and containers |
| 8 | [Datasets & Named Graphs](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/08-datasets-named-graphs/datasets-named-graphs.md) | Named graphs and quads |
| 9 | [RDFS/OWL Inference](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/09-inference-rdfs-owl/inference-rdfs-owl.md) | RDFS and OWL entailment |
| 10 | [N3 Reasoning](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/10-n3-reasoning/n3-reasoning.md) | Forward/backward chaining with N3 rules |
| 11 | [SHACL Validation](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/11-shacl-validation/shacl-validation.md) | Shape constraint validation |
| 12 | [Store Backends](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/12-store-backends/store-backends.md) | SQLite, DuckDB, auditable, concurrent stores |
| 13 | [Tabular Mapping](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/13-tabular-mapping/tabular-mapping.md) | CSV/DataFrame to RDF with OTTR templates |
| 14 | [Datalog](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/14-datalog/datalog.md) | Semi-naive bottom-up reasoning |
| 15 | [ProbLog](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/15-problog/problog.md) | Probabilistic logic programming |
| 16 | [GeoSPARQL](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/16-geosparql/geosparql.md) | Spatial data in RDF |
| 16 | [Property Paths](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/16-property-paths/property-paths.md) | SPARQL property path expressions |
| 17 | [Graph Utilities](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/17-graph-utilities/graph-utilities.md) | Isomorphism, CBD, VoID, visualization |
| 18 | [Ecology](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/18-ecology/ecology.md) | Marine food web knowledge graph |
| 19 | [Ash Dieback](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/19-ash-dieback/ash-dieback.md) | UK ash dieback disease modeling |
| 20 | [Bayesian Belief Networks](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/20-bayesian-belief-networks/bayesian-belief-networks.md) | BBN for species interaction networks |
| 21 | [Epidemiology](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/21-epidemiology/epidemiology.md) | Infectious disease surveillance |
| 22 | [Lassa Fever](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/vignettes/22-lassa-fever/lassa-fever.md) | Lassa fever surveillance in Nigeria |

## Conformance notes & limitations

The test suite (6,000+ assertions) includes spec-derived regression tests for RDF 1.1/SPARQL semantics and a cross-evaluator consistency suite that runs the same queries against `MemoryStore`, `EncodedStore`, and `DuckDBStore` and requires identical answers.

### W3C conformance

RDFLib.jl is tested against the **official W3C [rdf-tests](https://github.com/w3c/rdf-tests) manifests** via a manifest-driven harness (`test/w3c/`). The suite is permissively licensed but not vendored; fetch it once with `julia --project=. test/w3c/fetch.jl`, after which `Pkg.test()` runs the conformance gate (it skips automatically when the suite is absent). Current pass rates:

| Suite | Passing |
|-------|---------|
| RDF 1.1 Turtle / N-Triples / N-Quads / TriG / RDF-XML | 313/313, 70/70, 87/87, 356/356, 166/166 — **100%** |
| RDF 1.2 (RDF-star) Turtle / TriG / N-Triples / N-Quads / RDF-XML | 416/416, 416/416, 140/140, 155/155, 197/197 — **100%** |
| RDF Canonicalization (RDFC-1.0) N-Triples / N-Quads | 41/41, 41/41 — **100%** |
| RDF semantics / entailment (RDF-MT, RDF 1.2 semantics) | 48/48, 77/77 — **100%** |
| SPARQL 1.0 / 1.1 Query / 1.1 Update / 1.2 | 482/482, 328/328, 157/157, 269/269 — **100%** |
| SPARQL results CSV / TSV / JSON | **100%** |
| SPARQL Protocol / Graph Store / Service Description | 34/34, 12/12, 3/3 — **100%** |
| SPARQL 1.1 entailment-regime queries | 66 / 70 (RDFS, OWL 2 RL + OWL-DL class-expression query answering) |

The RDF syntax/canonicalization/semantics suites, the core SPARQL suites (query, update, 1.0, 1.2), the results formats, and the SPARQL-over-HTTP Protocol / Graph Store / Service Description suites all pass **100%**. RDFS, OWL 2 RL, and a substantial OWL-DL subset of the entailment-regime queries are answered by closure materialization plus OWL class-expression query rewriting against the closed graph (`owl_query.jl`) — including `intersectionOf`/`unionOf`/`oneOf`/`hasValue`/`someValuesFrom`/`complementOf`, qualified cardinality, and closed-role (`allValuesFrom oneOf`) counting. The only remaining 4 failures are the **RIF** entailment tests, which are unsatisfiable offline: their RIF rule documents (`rif01.rif`, `Frames-premise.rif`, …) are not vendored in the `rdf-tests` suite, so the rules a conformant processor would need simply aren't present. Known limitations, documented in the relevant docstrings:

- JSON-LD: `@included`, `@import`, `@protected` enforcement, and framing beyond a basic subset are not implemented.
- SHACL: `sh:ask` validators, custom SHACL-SPARQL constraint components, SPARQL-based targets, and `owl:imports` are not implemented.
- SPARQL: `FROM`/`FROM NAMED` on a plain `RDFGraph` (no named graphs) falls back to querying the graph itself; use `Dataset`/`ConjunctiveGraph` for dataset semantics. `USING`/`USING NAMED` is parsed and validated but not applied to UPDATE WHERE evaluation. DuckDB SQL pushdown is limited to COUNT-family aggregate queries; everything else transparently falls back to the generic evaluator.
- TriX and Hextuples are available via `serialize_trix`/`parse_trix` and `serialize_hextuples`/`parse_hextuples` rather than the generic `serialize`/`parse_rdf` API.
- Timezone-less `xsd:dateTime` values are compared as UTC.

## Dependencies

- [EzXML.jl](https://github.com/JuliaIO/EzXML.jl) — XML parsing
- [JSON.jl](https://github.com/JuliaIO/JSON.jl) / [JSON3.jl](https://github.com/quinnj/JSON3.jl) — JSON parsing
- [SQLite.jl](https://github.com/JuliaDatabases/SQLite.jl) — SQLite store backend
- [DuckDB.jl](https://github.com/duckdb/duckdb) — DuckDB store backend
- [CSV.jl](https://github.com/JuliaData/CSV.jl) — CSV utilities
- [Graphs.jl](https://github.com/JuliaGraphs/Graphs.jl) — graph algorithms
- [GraphViz.jl](https://github.com/Keno/GraphViz.jl) — DOT visualization
- [SHA.jl](https://github.com/JuliaCrypto/SHA.jl) — hashing

## Contributing

Contributions are welcome! Please open an [issue](https://github.com/JuliaKnowledge/RDFLib.jl/issues) or submit a [pull request](https://github.com/JuliaKnowledge/RDFLib.jl/pulls) on GitHub.

## License

[MIT](https://github.com/JuliaKnowledge/RDFLib.jl/blob/main/LICENSE)
