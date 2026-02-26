# Store Backends


## Overview

RDFLib.jl supports multiple storage backends for RDF graphs. This
vignette covers the built-in stores: in-memory, SQLite, DuckDB,
auditable, concurrent, and batch.

``` julia
using RDFLib
ex = Namespace("http://example.org/")
```

    Namespace("http://example.org/")

## MemoryStore (Default)

The default in-memory store is fast and suitable for most use cases.

``` julia
# MemoryStore is the default
g = RDFGraph()
println("Store type: ", typeof(g.store))

add!(g, Triple(ex("a"), ex("p"), Literal("hello")))
add!(g, Triple(ex("b"), ex("p"), Literal("world")))
println("Triples: ", length(g))
```

    Store type: MemoryStore
    Triples: 2

## SQLite Store

Persist your graph to a SQLite database for durability and
larger-than-memory graphs.

``` julia
# Create a SQLite-backed graph
db_path = tempname() * ".db"
store = SQLiteStore(db_path)
g = RDFGraph(; store=store)

# Add data
for i in 1:100
    add!(g, Triple(ex("item$i"), RDF.type, ex("Item")))
    add!(g, Triple(ex("item$i"), ex("value"), Literal(i)))
end

println("SQLite graph: $(length(g)) triples")

# Query works the same way
results = collect(triples(g, (nothing, RDF.type, ex("Item"))))
println("Items found: $(length(results))")
```

    SQLite graph: 200 triples
    Items found: 100

``` julia
# Data persists — reopen the same file
store2 = SQLiteStore(db_path)
g2 = RDFGraph(; store=store2)
println("Reopened: $(length(g2)) triples")

# Clean up
rm(db_path; force=true)
```

    Reopened: 200 triples

## DuckDB Store

DuckDB provides excellent analytical query performance for large graphs.

``` julia
db_path = tempname() * ".duckdb"
store = DuckDBStore(db_path)
g = RDFGraph(; store=store)

# Bulk insert
for i in 1:50
    add!(g, Triple(ex("sensor$i"), RDF.type, ex("Sensor")))
    add!(g, Triple(ex("sensor$i"), ex("reading"), Literal(rand() * 100)))
    add!(g, Triple(ex("sensor$i"), ex("location"), Literal("Zone $(i % 5 + 1)")))
end

println("DuckDB graph: $(length(g)) triples")

# Clean up
rm(db_path; force=true)
```

    DuckDB graph: 150 triples

## Auditable Store

Track every change with undo/redo support:

``` julia
base_store = MemoryStore()
store = AuditableStore(base_store)
g = RDFGraph(; store=store)

# Make some changes
add!(g, Triple(ex("a"), ex("p"), Literal("original")))
println("After add: $(length(g)) triples")

add!(g, Triple(ex("b"), ex("q"), Literal("second")))
println("After second add: $(length(g)) triples")

# Undo the last change
undo!(store)
println("After undo: $(length(g)) triples")

# Check what's left
for t in g
    println("  ", t)
end
```

    After add: 1 triples
    After second add: 2 triples
    After undo: 1 triples
      (URIRef("http://example.org/a"), URIRef("http://example.org/p"), Literal("original"))

## Concurrent Store

Thread-safe wrapper for multi-threaded applications:

``` julia
base = MemoryStore()
store = ConcurrentStore(base)
g = RDFGraph(; store=store)

# Safe to use from multiple threads
add!(g, Triple(ex("x"), ex("y"), Literal("z")))
println("Concurrent store: $(length(g)) triples")
```

    Concurrent store: 1 triples

## Batch Add Graph

Optimize bulk insertions by batching:

``` julia
g = RDFGraph()

# Use BatchAddGraph for efficient bulk loading
batch = BatchAddGraph(g)

for i in 1:1000
    add!(batch, Triple(ex("item$i"), RDF.type, ex("Item")))
end

# Flush to commit all at once
flush!(batch)
println("Batch inserted: $(length(g)) triples")
```

    Batch inserted: 1000 triples

## Store Comparison

<table>
<colgroup>
<col style="width: 22%" />
<col style="width: 16%" />
<col style="width: 16%" />
<col style="width: 16%" />
<col style="width: 29%" />
</colgroup>
<thead>
<tr>
<th>Store</th>
<th style="text-align: center;">Persistent</th>
<th style="text-align: center;">Speed</th>
<th style="text-align: center;">Thread-Safe</th>
<th>Best For</th>
</tr>
</thead>
<tbody>
<tr>
<td>MemoryStore</td>
<td style="text-align: center;">❌</td>
<td style="text-align: center;">⚡ Fast</td>
<td style="text-align: center;">❌</td>
<td>Small-medium graphs, prototyping</td>
</tr>
<tr>
<td>SQLiteStore</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">🔶 Medium</td>
<td style="text-align: center;">❌</td>
<td>Persistent storage, medium graphs</td>
</tr>
<tr>
<td>DuckDBStore</td>
<td style="text-align: center;">✅</td>
<td style="text-align: center;">🔶 Medium</td>
<td style="text-align: center;">❌</td>
<td>Analytics, large graphs</td>
</tr>
<tr>
<td>ConcurrentStore</td>
<td style="text-align: center;">depends</td>
<td style="text-align: center;">⚠️ Overhead</td>
<td style="text-align: center;">✅</td>
<td>Multi-threaded apps</td>
</tr>
<tr>
<td>AuditableStore</td>
<td style="text-align: center;">depends</td>
<td style="text-align: center;">⚠️ Overhead</td>
<td style="text-align: center;">❌</td>
<td>Change tracking, undo/redo</td>
</tr>
<tr>
<td>BatchAddGraph</td>
<td style="text-align: center;">depends</td>
<td style="text-align: center;">⚡ Bulk</td>
<td style="text-align: center;">❌</td>
<td>Data loading</td>
</tr>
</tbody>
</table>

## Transactions

Some stores support transactions for atomic operations:

``` julia
store = SQLiteStore()
g = RDFGraph(; store=store)

# Transaction ensures all-or-nothing
transaction(store) do
    add!(g, Triple(ex("a"), ex("p"), Literal("1")))
    add!(g, Triple(ex("b"), ex("q"), Literal("2")))
end

println("After transaction: $(length(g)) triples")
```

    After transaction: 2 triples

## Isomorphic Graph

A wrapper that provides canonical form for blank node-insensitive
comparison:

``` julia
g1 = parse_rdf("""
    @prefix ex: <http://example.org/> .
    ex:a ex:p [ ex:q "hello" ] .
""", TurtleFormat())

g2 = parse_rdf("""
    @prefix ex: <http://example.org/> .
    ex:a ex:p [ ex:q "hello" ] .
""", TurtleFormat())

iso1 = to_isomorphic(g1)
iso2 = to_isomorphic(g2)
println("Isomorphic: ", iso1 == iso2)
```

    Isomorphic: true
