using Test
using RDFLib

include("../src/void.jl")

const _EX = Namespace("http://example.org/")
const _VOID_NS = Namespace("http://rdfs.org/ns/void#")
const _RDF_TYPE_URI = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")

@testset "VoID Metadata" begin
    # Build a sample graph
    function sample_graph()
        g = RDFGraph()
        rdf = Namespace("http://www.w3.org/1999/02/22-rdf-syntax-ns#")
        foaf = Namespace("http://xmlns.com/foaf/0.1/")

        add!(g, Triple(_EX("alice"), rdf("type"), foaf("Person")))
        add!(g, Triple(_EX("bob"), rdf("type"), foaf("Person")))
        add!(g, Triple(_EX("alice"), foaf("name"), Literal("Alice")))
        add!(g, Triple(_EX("bob"), foaf("name"), Literal("Bob")))
        add!(g, Triple(_EX("alice"), foaf("knows"), _EX("bob")))
        g
    end

    @testset "generate_void returns a graph" begin
        g = sample_graph()
        vg = generate_void(g, _EX("myDataset"))
        @test vg isa RDFGraph
        @test length(vg) > 0
    end

    @testset "dataset type" begin
        g = sample_graph()
        vg = generate_void(g, _EX("myDataset"))
        @test Triple(_EX("myDataset"), _RDF_TYPE_URI, _VOID_NS("Dataset")) in vg
    end

    @testset "triple count" begin
        g = sample_graph()
        vg = generate_void(g, _EX("myDataset"))
        @test Triple(_EX("myDataset"), _VOID_NS("triples"), Literal(5)) in vg
    end

    @testset "distinct subjects" begin
        g = sample_graph()
        vg = generate_void(g, _EX("myDataset"))
        @test Triple(_EX("myDataset"), _VOID_NS("distinctSubjects"), Literal(2)) in vg
    end

    @testset "distinct objects" begin
        g = sample_graph()
        vg = generate_void(g, _EX("myDataset"))
        # Objects: foaf:Person, "Alice", "Bob", ex:bob => 4 distinct
        obj_triples = collect(triples(vg, (_EX("myDataset"), _VOID_NS("distinctObjects"), nothing)))
        @test length(obj_triples) == 1
        val = parse(Int, string(obj_triples[1].object))
        @test val == 4
    end

    @testset "properties count" begin
        g = sample_graph()
        vg = generate_void(g, _EX("myDataset"))
        # Predicates: rdf:type, foaf:name, foaf:knows => 3
        @test Triple(_EX("myDataset"), _VOID_NS("properties"), Literal(3)) in vg
    end

    @testset "classes count" begin
        g = sample_graph()
        vg = generate_void(g, _EX("myDataset"))
        # Classes: foaf:Person => 1
        @test Triple(_EX("myDataset"), _VOID_NS("classes"), Literal(1)) in vg
    end

    @testset "property partitions exist" begin
        g = sample_graph()
        vg = generate_void(g, _EX("myDataset"))
        partitions = collect(objects(vg, _EX("myDataset"), _VOID_NS("propertyPartition")))
        @test length(partitions) == 3  # 3 distinct predicates
    end

    @testset "class partitions exist" begin
        g = sample_graph()
        vg = generate_void(g, _EX("myDataset"))
        partitions = collect(objects(vg, _EX("myDataset"), _VOID_NS("classPartition")))
        @test length(partitions) == 1  # 1 class
    end

    @testset "optional title" begin
        g = sample_graph()
        vg = generate_void(g, _EX("myDataset"); title="My Dataset")
        dcterms = Namespace("http://purl.org/dc/terms/")
        @test Triple(_EX("myDataset"), dcterms("title"), Literal("My Dataset")) in vg
    end

    @testset "empty graph" begin
        g = RDFGraph()
        vg = generate_void(g, _EX("emptyDataset"))
        @test Triple(_EX("emptyDataset"), _VOID_NS("triples"), Literal(0)) in vg
        @test Triple(_EX("emptyDataset"), _VOID_NS("distinctSubjects"), Literal(0)) in vg
    end
end
