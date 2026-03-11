using Documenter
using RDFLib

makedocs(
    sitename = "RDFLib.jl",
    authors = "Simon Frost",
    modules = [RDFLib],
    warnonly = [:missing_docs],
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://juliaknowledge.github.io/RDFLib.jl/stable/",
    ),
    pages = [
        "Home" => "index.md",
        "Tutorials" => [
            "Getting Started" => "tutorials/getting-started.md",
            "RDF Terms" => "tutorials/rdf-terms.md",
            "Building Graphs" => "tutorials/building-graphs.md",
            "Namespaces" => "tutorials/namespaces.md",
            "Serialization" => "tutorials/serialization.md",
            "SPARQL Queries" => "tutorials/sparql-queries.md",
        ],
        "Guide" => [
            "Collections & Containers" => "guide/collections-containers.md",
            "Datasets & Named Graphs" => "guide/datasets-named-graphs.md",
            "Store Backends" => "guide/store-backends.md",
            "Tabular Mapping" => "guide/tabular-mapping.md",
            "Property Paths" => "guide/property-paths.md",
            "Graph Utilities" => "guide/graph-utilities.md",
            "GeoSPARQL" => "guide/geosparql.md",
        ],
        "Reasoning & Inference" => [
            "RDFS/OWL Inference" => "reasoning/inference-rdfs-owl.md",
            "N3 Reasoning" => "reasoning/n3-reasoning.md",
            "Datalog" => "reasoning/datalog.md",
            "ProbLog" => "reasoning/problog.md",
            "SHACL Validation" => "reasoning/shacl-validation.md",
        ],
        "Case Studies" => [
            "Ecology" => "cases/ecology.md",
            "Ash Dieback" => "cases/ash-dieback.md",
            "Bayesian Belief Networks" => "cases/bayesian-belief-networks.md",
            "Epidemiology" => "cases/epidemiology.md",
            "Lassa Fever" => "cases/lassa-fever.md",
        ],
        "API Reference" => [
            "Terms" => "api/terms.md",
            "Namespaces" => "api/namespaces.md",
            "Graph" => "api/graph.md",
            "Stores" => "api/stores.md",
            "Serialization" => "api/serialization.md",
            "SPARQL" => "api/sparql.md",
            "Reasoning" => "api/reasoning.md",
            "Validation" => "api/validation.md",
            "GeoSPARQL" => "api/geosparql.md",
            "Utilities" => "api/utilities.md",
        ],
    ],
)

deploydocs(
    repo = "github.com/JuliaKnowledge/RDFLib.jl.git",
    devbranch = "master",
)
