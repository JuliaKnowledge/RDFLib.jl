module RDFLib

using UUIDs
using Dates
using EzXML
using Downloads: download
import JSON3
import SHA
import MD5
import XML
import JSON
import CSV
import Tables

# XSD datetime parsing (needed by terms.jl convert methods)
include("xsd_datetime.jl")

# Core term types
include("terms.jl")

# Namespace management
include("namespaces.jl")
include("extra_namespaces.jl")
include("more_namespaces.jl")

# Store interface and implementations
include("store.jl")
include("sqlitestore.jl")
include("duckdbstore.jl")
include("sparqlstore.jl")
include("lmdbstore.jl")

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
include("jsonld_processing.jl")

# High-level serialize/parse API
include("io.jl")

# Content negotiation & URL/file loading
include("contentneg.jl")

# N-Quads format (requires Dataset)
include("nquads.jl")

# Collections & Containers
include("collections.jl")

# Collection indexing support
include("collection_indexing.jl")

# RDF-specific exception types
include("exceptions.jl")

# Resource abstraction
include("resource.jl")

# GeoSPARQL support (WKT parsing, spatial relations, metrics)
include("geosparql.jl")

# SPARQL query engine
include("sparql_ast.jl")
include("sparql_parser.jl")
include("sparql_eval.jl")
include("sparql.jl")

# DOT visualization
include("visualization.jl")

# RDFGraph isomorphism
include("isomorphism.jl")

# RDFGraph extras (transitive, skolemize, etc.)
include("graph_extras.jl")

# RDFGraph utilities (merge, diff, stats, CBD, connected components)
include("graphutils.jl")

# SHACL validation
include("shacl.jl")

# Notation3 (N3) format
include("n3.jl")

# N3 builtin predicates (math, string, log, crypto)
include("n3_builtins.jl")

# N3 reasoning: rule extraction and unification
include("n3_rules.jl")
include("n3_unifier.jl")

# N3 proof trace generation
include("n3_proof.jl")

# N3 reasoner (Euler Abstract Machine)
include("n3_reasoner.jl")

# Datalog reasoner (semi-naive evaluation)
include("datalog.jl")

# ProbLog — probabilistic logic programming
include("problog.jl")

# Additional formats
include("trix.jl")
include("hextuples.jl")
include("longturtle.jl")
include("rdfpatch.jl")
include("sparql_tsv.jl")
include("sparql_results_parser.jl")

# Store wrappers
include("auditablestore.jl")
include("concurrentstore.jl")

# Event system
include("events.jl")

# Plugin system
include("plugin.jl")

# InfixOWL
include("infixowl.jl")

# VoID metadata
include("void.jl")

# Namespace creator
include("namespace_creator.jl")

# Graph describer
include("describer.jl")

# ConjunctiveGraph, ReadOnlyGraphAggregate, BatchAddGraph, IsomorphicGraph
include("conjunctivegraph.jl")
include("readonlyaggregate.jl")
include("batchaddgraph.jl")
include("isomorphicgraph.jl")

# Inference engine (RDFS/OWL forward chaining)
include("inference.jl")

# RDFS/OWL schema DOT visualization
include("rdfs2dot.jl")

# GraphViz.jl rendering integration
include("graphviz_render.jl")

# Chunked serialization/parsing
include("chunk_serializer.jl")

# HEXT (Hextuples) compatibility aliases
include("hext.jl")

# N3 term parser
include("from_n3.jl")

# Jelly RDF binary format
include("jelly.jl")

# ShEx (Shape Expressions) validation
include("shex.jl")

# CLI tools
include("cli.jl")

# SPARQL/N3 Server (HTTP.jl)
include("server.jl")

# SPARQL Query Builder DSL
include("querybuilder.jl")

# Full-Text Search Index
include("textindex.jl")

export
    # Term types
    Identifier, Node, IdentifiedNode,
    URIRef, BNode, Literal, Variable, Triple, TripleTerm,
    n3, datatype, lang, value,
    defrag, fragment,
    from_n3, to_term,
    validate_iri, validate_iri!, parse_iri,
    validate_langtag, normalize_langtag,

    # Namespaces
    Namespace, DefinedNamespace,
    RDF, RDFS, XSD, OWL, SKOS,
    FOAF, DC, DCTERMS, DCAT, PROV, SDO, SH, VANN, VOID, DOAP, ORG, GEO,
    GEOF,
    BRICK, CSVW, DCAM, DCMITYPE, ODRL2, PROF, QB, SOSA, SSN, TIME, WGS,
    NamespaceManager, bind!, expand_curie, compute_qname,

    # Store
    AbstractStore, MemoryStore, SQLiteStore, DuckDBStore, SPARQLStore, LMDBStore,
    transaction, sparql_remote, add_bulk!, clear!,

    # RDFGraph
    RDFGraph,
    add!, remove!, triples, subjects, predicates, objects,
    subject_predicates, subject_objects, predicate_objects,

    # I/O
    NTriplesFormat, TurtleFormat,
    NQuadsFormat, RDFXMLFormat, TriGFormat, JSONLDFormat,
    SerializationFormat,
    serialize, parse_rdf, parse_rdf!,
    parse_rdf_with_base, parse_rdf_with_base!,

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
    clear_service_cache!, set_service_cache_ttl!,

    # Collections & Containers
    Collection, add_collection!, collect_list,
    add_container!, collect_container,
    container_membership_property,
    CollectionView, collection_view,

    # Exceptions
    RDFError, ParserError, UniquenessError, SPARQLError,
    SerializationError, NamespaceError, StoreError,
    unique_value,

    # Visualization
    to_dot, rdfs2dot,
    render_dot, render_graph, render_schema, save_visualization,

    # Isomorphism
    isomorphic, graph_hash, to_simple_graph, from_simple_graph,

    # RDFGraph utilities
    merge_graphs, graph_diff, graph_stats, cbd, connected_components,

    # RDFGraph extras
    transitive_objects, transitive_subjects, all_nodes, triples_choices,
    skolemize, de_skolemize, parse_into!, graph_n3,

    # SHACL
    validate, ValidationReport, ValidationResult,

    # ShEx
    validate_shex, parse_shex, ShExSchema, ShExValidationReport,

    # N3
    Formula, N3Format, serialize_n3, parse_n3, parse_n3!, LOG, MATH,

    # N3 builtins
    register_builtin!, is_builtin, evaluate_builtin,

    # N3 reasoning
    RuleDirection, FORWARD, BACKWARD,
    N3Rule, extract_rules, RuleSet,
    Binding, unify_term, unify_triple, apply_bindings, is_ground, match_conjunction,

    # N3 proof
    StepType, EXTRACTION, INFERENCE,
    ProofStep, extraction_step, inference_step,
    ProofTrace, record_extraction!, record_inference!,
    proof_to_n3, proof_to_graph,

    # N3 reasoner
    N3Reasoner, eam_step!, eam_loop!, reason,

    # Datalog reasoner
    datalog_reason, DatalogProgram, DatalogRule, semi_naive!,

    # ProbLog — probabilistic logic programming
    problog_query, problog_infer, parse_problog,
    ProbLogProgram, PrologAtom, PrologClause,

    # Additional formats
    serialize_trix, parse_trix, parse_trix!,
    serialize_hextuples, parse_hextuples, parse_hextuples!,
    serialize_hext, parse_hext, parse_hext!,
    serialize_longturtle,
    serialize_rdfpatch, parse_rdfpatch, apply_rdfpatch!,
    sparql_results_tsv,
    parse_sparql_results_json, parse_sparql_results_xml,
    parse_sparql_results_csv, parse_sparql_results_tsv,
    parse_sparql_ask_json, parse_sparql_ask_xml,

    # Chunked serialization
    serialize_chunked, parse_chunked,

    # Store wrappers
    AuditableStore, undo!, clear_journal!,
    ConcurrentStore,

    # Event system
    RDFEvent, TripleAdded, TripleRemoved, GraphCleared,
    EventDispatcher, on!, off!, emit!,
    ObservableGraph,

    # Plugin system
    register_parser!, register_serializer!, register_store!,
    unregister_parser!, unregister_serializer!, unregister_store!,
    get_parser, get_serializer, get_store,
    list_parsers, list_serializers, list_stores,

    # InfixOWL
    OWLClass, OWLProperty, OWLObjectProperty, OWLDatatypeProperty,
    subclass_of!, owl_restriction, owl_ontology!, owl_individual,
    owl_union, owl_intersection, owl_complement,

    # VoID
    generate_void,

    # Namespace creator
    create_namespace,

    # Graph describer
    Describer, describe, rdf_type!, property!, properties!,
    label!, comment!, related!, sub_describe!,

    # Inference
    rdfs_closure, rdfs_closure!, owl_closure, owl_closure!,
    owl2_rl_closure, owl2_rl_closure!, infer, entails,

    # CLI tools
    rdfpipe, csv2rdf,

    # XSD datetime utilities
    parse_xsd_datetime, parse_xsd_date, parse_xsd_time,
    format_xsd_datetime, format_xsd_date, format_xsd_time,
    xsd_literal,

    # ConjunctiveGraph
    ConjunctiveGraph, get_context, remove_context!,

    # ReadOnlyGraphAggregate
    ReadOnlyGraphAggregate,

    # BatchAddGraph
    BatchAddGraph, flush!, close!,

    # IsomorphicGraph
    IsomorphicGraph, to_isomorphic,

    # JSON-LD Processing
    jsonld_expand, jsonld_compact, jsonld_frame, jsonld_flatten,

    # GeoSPARQL
    parse_wkt, to_wkt,
    AbstractGeometry, GeoPoint, GeoLineString, GeoPolygon,
    GeoMultiPoint, GeoMultiLineString, GeoMultiPolygon, GeoCollection,
    geo_distance, geo_contains, geo_within, geo_intersects,
    geo_disjoint, geo_equals, geo_touches, geo_overlaps,
    geo_area, geo_buffer, geo_boundary,

    # Query Builder DSL
    AbstractQuery, SelectQuery, ConstructQuery, AskQuery, DescribeQuery,
    select, where, prefix, optional, union_pattern, minus, query_bind, query_values,
    group_by, having, order_by, limit, offset, distinct, construct, describe,
    build, execute,

    # Text Index
    TextIndex, build!, text_search, set_text_index!, clear_text_index!,

    # Jelly binary format
    serialize_jelly, parse_jelly, parse_jelly!,
    serialize_jelly_to_file, parse_jelly_file,

    # SPARQL Server
    SparqlServer, DatasetEndpoint,
    add_dataset!, remove_dataset!, get_dataset,
    serve!, stop!

end # module
