# Stores

Storage backends for RDF graphs.

## Abstract Interface

```@docs
AbstractStore
transaction
add_bulk!
clear!
```

## Backends

```@docs
MemoryStore
SQLiteStore
DuckDBStore
SPARQLStore
LMDBStore
sparql_remote
```

## Store Wrappers

```@docs
AuditableStore
undo!
clear_journal!
ConcurrentStore
```

## Plugin System

```@docs
register_parser!
register_serializer!
register_store!
unregister_parser!
unregister_serializer!
unregister_store!
get_parser
get_serializer
get_store
list_parsers
list_serializers
list_stores
```
