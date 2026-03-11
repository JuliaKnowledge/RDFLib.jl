# Serialization

Reading and writing RDF data in multiple formats.

## Core API

```@docs
SerializationFormat
serialize
parse_rdf
parse_rdf!
parse_rdf_with_base
parse_rdf_with_base!
load_rdf
load_rdf_file
save_rdf
```

## Format Types

```@docs
NTriplesFormat
TurtleFormat
NQuadsFormat
RDFXMLFormat
TriGFormat
JSONLDFormat
N3Format
```

## Content Negotiation

```@docs
mime_type
format_from_mime
accept_header
```

## Additional Formats

```@docs
serialize_trix
parse_trix
parse_trix!
serialize_hextuples
parse_hextuples
parse_hextuples!
serialize_hext
parse_hext
parse_hext!
serialize_longturtle
serialize_rdfpatch
parse_rdfpatch
apply_rdfpatch!
serialize_chunked
parse_chunked
```

## JSON-LD Processing

```@docs
jsonld_expand
jsonld_compact
jsonld_frame
jsonld_flatten
```

## Jelly Binary Format

```@docs
serialize_jelly
parse_jelly
parse_jelly!
serialize_jelly_to_file
parse_jelly_file
```

## SPARQL Results Serialization

```@docs
sparql_results_json
sparql_results_xml
sparql_results_csv
sparql_results_tsv
parse_sparql_results_json
parse_sparql_results_xml
parse_sparql_results_csv
parse_sparql_results_tsv
parse_sparql_ask_json
parse_sparql_ask_xml
```
