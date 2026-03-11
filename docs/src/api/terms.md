# Terms

RDF terms are the building blocks of RDF data: URIs, blank nodes, literals, and variables.

## Types

```@docs
Identifier
Node
IdentifiedNode
URIRef
BNode
Literal
Variable
Triple
```

## Constructors and Accessors

```@docs
datatype
lang
value
n3
defrag
fragment
from_n3
to_term
validate_iri
validate_iri!
parse_iri
validate_langtag
normalize_langtag
```

## XSD Datetime Utilities

```@docs
parse_xsd_datetime
parse_xsd_date
parse_xsd_time
format_xsd_datetime
format_xsd_date
format_xsd_time
xsd_literal
```
