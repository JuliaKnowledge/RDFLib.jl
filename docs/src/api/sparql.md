# SPARQL

SPARQL query and update engine.

## Query Execution

```@docs
sparql_query
sparql_update
clear_service_cache!
set_service_cache_ttl!
```

## Query Builder DSL

Build SPARQL queries programmatically:

```@docs
AbstractQuery
SelectQuery
ConstructQuery
AskQuery
DescribeQuery
select
where
prefix
optional
union_pattern
minus
query_bind
query_values
group_by
having
order_by
limit
offset
distinct
construct
build
execute
```

## SPARQL Server

```@docs
serve!
stop!
```
