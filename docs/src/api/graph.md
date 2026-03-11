# Graph

The core `RDFGraph` type and operations for adding, removing, and querying triples.

## RDFGraph

```@docs
RDFGraph
add!
remove!
triples
subjects
predicates
objects
subject_predicates
subject_objects
predicate_objects
```

## Dataset (Named Graphs)

```@docs
Dataset
Quad
add_graph
remove_graph
get_graph
graphs
quads
contexts
```

## Resource

```@docs
Resource
getall
types
isa_resource
label
resource
```

## Collections & Containers

```@docs
Collection
add_collection!
collect_list
add_container!
collect_container
container_membership_property
CollectionView
collection_view
```

## Graph Wrappers

```@docs
ConjunctiveGraph
get_context
remove_context!
ReadOnlyGraphAggregate
BatchAddGraph
flush!
close!
IsomorphicGraph
to_isomorphic
```

## Describer

```@docs
Describer
describe
rdf_type!
property!
properties!
label!
comment!
related!
sub_describe!
```

## Event System

```@docs
on!
off!
emit!
ObservableGraph
```
