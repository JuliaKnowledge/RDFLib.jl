module RDFLib

using UUIDs
using Dates
using EzXML
import JSON3
import SHA

# Core term types
include("terms.jl")

# Namespace management
include("namespaces.jl")
include("extra_namespaces.jl")

# Store interface and implementations
include("store.jl")
include("sqlitestore.jl")
include("duckdbstore.jl")
include("sparqlstore.jl")

# RDFGraph
include("graph.jl")

# Serialization format type declarations
include("formats.jl")

# Dataset (named graphs) — needed by TriG, NQuads
include("dataset.jl")

# Serialization formats
include("ntriples.jl")
include("turtle.jl")
include("rdfxml.jl")
include("trig.jl")
include("jsonld.jl")

# High-level serialize/parse API
include("io.jl")

# Content negotiation & URL/file loading
include("contentneg.jl")

# N-Quads format (requires Dataset)
include("nquads.jl")

# Collections & Containers
include("collections.jl")

# Resource abstraction
include("resource.jl")

# SPARQL query engine
include("sparql.jl")

# DOT visualization
include("visualization.jl")

# RDFGraph isomorphism
include("isomorphism.jl")

# RDFGraph utilities (merge, diff, stats, CBD, connected components)
include("graphutils.jl")

# SHACL validation
include("shacl.jl")

# Notation3 (N3) format
include("n3.jl")

export
    # Term types
    Identifier, Node, IdentifiedNode,
    URIRef, BNode, Literal, Variable, Triple, TripleTerm,
    n3, datatype, lang, value, toPython,
    defrag, fragment,

    # Namespaces
    Namespace, DefinedNamespace,
    RDF, RDFS, XSD, OWL, SKOS,
    FOAF, DC, DCTERMS, DCAT, PROV, SDO, SH, VANN, VOID, DOAP, ORG, GEO,
    NamespaceManager, bind!, expand_curie, compute_qname,

    # Store
    AbstractStore, MemoryStore, SQLiteStore, DuckDBStore, SPARQLStore,
    transaction, sparql_remote,

    # RDFGraph
    RDFGraph,
    add!, remove!, triples, subjects, predicates, objects,
    subject_predicates, subject_objects, predicate_objects,

    # I/O
    NTriplesFormat, TurtleFormat,
    NQuadsFormat, RDFXMLFormat, TriGFormat, JSONLDFormat,
    SerializationFormat,
    serialize, parse_rdf, parse_rdf!,

    # Content negotiation & loading
    mime_type, format_from_mime, accept_header,
    load_rdf, load_rdf_file, save_rdf,

    # Dataset
    Dataset, Quad,
    add_graph, remove_graph, get_graph, graphs, quads, contexts,
    parse_nquads, parse_nquads!, serialize_nquads,
    parse_trig, parse_trig!, serialize_trig,

    # Resource
    Resource, getall, types, isa_resource, label, resource,

    # SPARQL
    sparql_query,
    sparql_update,
    sparql_results_json, sparql_results_xml, sparql_results_csv,

    # Collections & Containers
    Collection, add_collection!, collect_list,
    add_container!, collect_container,
    container_membership_property,

    # Visualization
    to_dot,

    # Isomorphism
    isomorphic, graph_hash, to_simple_graph, from_simple_graph,

    # RDFGraph utilities
    merge_graphs, graph_diff, graph_stats, cbd, connected_components,

    # SHACL
    validate, ValidationReport, ValidationResult,

    # N3
    Formula, N3Format, serialize_n3, parse_n3, parse_n3!, LOG, MATH

end # module
