using Test
using RDFLib

include("../src/describer.jl")

const DESC_EX = Namespace("http://example.org/")
const FOAF = Namespace("http://xmlns.com/foaf/0.1/")
const RDF_TYPE_URI = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
const RDFS_LABEL_URI = URIRef("http://www.w3.org/2000/01/rdf-schema#label")
const RDFS_COMMENT_URI = URIRef("http://www.w3.org/2000/01/rdf-schema#comment")

@testset "Describer" begin
    @testset "describe creates a Describer" begin
        g = RDFGraph()
        d = describe(g, DESC_EX("alice"))
        @test d isa Describer
        @test d.subject == DESC_EX("alice")
        @test d.graph === g
    end

    @testset "rdf_type!" begin
        g = RDFGraph()
        d = describe(g, DESC_EX("alice"))
        rdf_type!(d, FOAF("Person"))
        @test Triple(DESC_EX("alice"), RDF_TYPE_URI, FOAF("Person")) in g
    end

    @testset "property!" begin
        g = RDFGraph()
        d = describe(g, DESC_EX("alice"))
        property!(d, FOAF("name"), Literal("Alice"))
        @test Triple(DESC_EX("alice"), FOAF("name"), Literal("Alice")) in g
    end

    @testset "fluent chaining" begin
        g = RDFGraph()
        describe(g, DESC_EX("alice")) |>
            d -> rdf_type!(d, FOAF("Person")) |>
            d -> property!(d, FOAF("name"), Literal("Alice")) |>
            d -> property!(d, FOAF("age"), Literal(30))
        @test length(g) == 3
        @test Triple(DESC_EX("alice"), RDF_TYPE_URI, FOAF("Person")) in g
        @test Triple(DESC_EX("alice"), FOAF("name"), Literal("Alice")) in g
        @test Triple(DESC_EX("alice"), FOAF("age"), Literal(30)) in g
    end

    @testset "label!" begin
        g = RDFGraph()
        d = describe(g, DESC_EX("alice"))
        label!(d, "Alice")
        @test Triple(DESC_EX("alice"), RDFS_LABEL_URI, Literal("Alice")) in g
    end

    @testset "label! with language" begin
        g = RDFGraph()
        d = describe(g, DESC_EX("alice"))
        label!(d, "Alice"; lang="en")
        @test Triple(DESC_EX("alice"), RDFS_LABEL_URI, Literal("Alice", lang="en")) in g
    end

    @testset "comment!" begin
        g = RDFGraph()
        d = describe(g, DESC_EX("alice"))
        comment!(d, "A person named Alice")
        @test Triple(DESC_EX("alice"), RDFS_COMMENT_URI, Literal("A person named Alice")) in g
    end

    @testset "properties! (multiple values)" begin
        g = RDFGraph()
        d = describe(g, DESC_EX("alice"))
        properties!(d, FOAF("knows"), [DESC_EX("bob"), DESC_EX("carol")])
        @test Triple(DESC_EX("alice"), FOAF("knows"), DESC_EX("bob")) in g
        @test Triple(DESC_EX("alice"), FOAF("knows"), DESC_EX("carol")) in g
    end

    @testset "related!" begin
        g = RDFGraph()
        d = describe(g, DESC_EX("alice"))
        related!(d, FOAF("knows"), DESC_EX("bob"))
        @test Triple(DESC_EX("alice"), FOAF("knows"), DESC_EX("bob")) in g
    end

    @testset "sub_describe!" begin
        g = RDFGraph()
        d = describe(g, DESC_EX("alice"))
        property!(d, FOAF("name"), Literal("Alice"))
        d2 = sub_describe!(d, FOAF("knows"), DESC_EX("bob"))
        property!(d2, FOAF("name"), Literal("Bob"))

        @test Triple(DESC_EX("alice"), FOAF("knows"), DESC_EX("bob")) in g
        @test Triple(DESC_EX("bob"), FOAF("name"), Literal("Bob")) in g
        @test length(g) == 3
    end

    @testset "describe with BNode" begin
        g = RDFGraph()
        b = BNode()
        d = describe(g, b)
        rdf_type!(d, FOAF("Person"))
        @test Triple(b, RDF_TYPE_URI, FOAF("Person")) in g
    end
end
