# Utilities

Graph analysis, visualization, and miscellaneous tools.

## Graph Utilities

```@docs
merge_graphs
graph_diff
graph_stats
cbd
connected_components
```

## Graph Extras

```@docs
transitive_objects
transitive_subjects
all_nodes
triples_choices
skolemize
de_skolemize
parse_into!
graph_n3
```

## Isomorphism

```@docs
isomorphic
graph_hash
to_simple_graph
from_simple_graph
```

## Visualization

```@docs
to_dot
rdfs2dot
render_dot
render_graph
render_schema
save_visualization
```

## VoID Metadata

```@docs
generate_void
```

## Text Search

```@docs
TextIndex
build!
text_search
set_text_index!
clear_text_index!
```

## Tabular Mapping

```@docs
RDFMapping
RDFTemplate
ColumnType
IRIColumn
LiteralColumn
LangColumn
AutoColumn
rdf_map!
map_default!
rdf_insert!
rdf_query
rdf_update!
table_to_rdf
OTTRTemplate
OTTRParam
OTTRInstance
OTTRArg
OTTRParamType
parse_ottr
add_template!
ottr_map!
rdf_validate
rdf_reason!
```

## Exceptions

```@docs
RDFError
ParserError
UniquenessError
SPARQLError
SerializationError
NamespaceError
StoreError
unique_value
```

## CLI Tools

```@docs
rdfpipe
csv2rdf
```
