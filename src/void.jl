# ─── VoID (Vocabulary of Interlinked Datasets) description generator ──

const _VOID = Namespace("http://rdfs.org/ns/void#")
const _VOID_DCTERMS = Namespace("http://purl.org/dc/terms/")
const _VOID_RDF_NS = Namespace("http://www.w3.org/1999/02/22-rdf-syntax-ns#")

"""
    generate_void(g::RDFGraph, dataset_uri::URIRef; title=nothing, description=nothing) -> RDFGraph

Generate a VoID (Vocabulary of Interlinked Datasets) description for the given graph.
Returns a new graph containing the VoID metadata.
"""
function generate_void(g::RDFGraph, dataset_uri::URIRef;
                       title::Union{String,Nothing}=nothing,
                       description::Union{String,Nothing}=nothing)
    vg = RDFGraph()
    bind!(vg, "void", _VOID)
    bind!(vg, "dcterms", _VOID_DCTERMS)

    # Dataset type
    add!(vg, Triple(dataset_uri, _VOID_RDF_NS("type"), _VOID("Dataset")))

    # Optional metadata
    !isnothing(title) && add!(vg, Triple(dataset_uri, _VOID_DCTERMS("title"), Literal(title)))
    !isnothing(description) && add!(vg, Triple(dataset_uri, _VOID_DCTERMS("description"), Literal(description)))

    # Triple count
    add!(vg, Triple(dataset_uri, _VOID("triples"), Literal(length(g))))

    # Collect statistics
    subjs = Set{Node}()
    preds = Set{URIRef}()
    objs = Set{Identifier}()
    classes = Set{URIRef}()
    rdf_type = _VOID_RDF_NS("type")

    for t in triples(g)
        push!(subjs, t.subject)
        push!(preds, t.predicate)
        push!(objs, t.object)
        if t.predicate == rdf_type && t.object isa URIRef
            push!(classes, t.object)
        end
    end

    add!(vg, Triple(dataset_uri, _VOID("distinctSubjects"), Literal(length(subjs))))
    add!(vg, Triple(dataset_uri, _VOID("distinctObjects"), Literal(length(objs))))
    add!(vg, Triple(dataset_uri, _VOID("properties"), Literal(length(preds))))
    add!(vg, Triple(dataset_uri, _VOID("classes"), Literal(length(classes))))

    # Property partitions
    for pred in preds
        partition = BNode()
        add!(vg, Triple(dataset_uri, _VOID("propertyPartition"), partition))
        add!(vg, Triple(partition, _VOID("property"), pred))
        count = sum(1 for _ in triples(g, (nothing, pred, nothing)))
        add!(vg, Triple(partition, _VOID("triples"), Literal(count)))
    end

    # Class partitions
    for cls in classes
        partition = BNode()
        add!(vg, Triple(dataset_uri, _VOID("classPartition"), partition))
        add!(vg, Triple(partition, _VOID("class"), cls))
        count = sum(1 for _ in triples(g, (nothing, rdf_type, cls)))
        add!(vg, Triple(partition, _VOID("entities"), Literal(count)))
    end

    vg
end
