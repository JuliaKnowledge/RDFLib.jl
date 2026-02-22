using Test
using RDFLib

include("../src/namespace_creator.jl")

const NSC_EX = Namespace("http://example.org/")

@testset "Namespace Creator" begin
    @testset "basic namespace generation" begin
        g = RDFGraph()
        rdf_type = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
        add!(g, Triple(NSC_EX("Person"), rdf_type, URIRef("http://www.w3.org/2002/07/owl#Class")))
        add!(g, Triple(NSC_EX("name"), rdf_type, URIRef("http://www.w3.org/2002/07/owl#DatatypeProperty")))

        code = create_namespace(g, "http://example.org/", "EX")
        @test occursin("const EX = DefinedNamespace(", code)
        @test occursin("\"http://example.org/\"", code)
        @test occursin("\"Person\"", code)
        @test occursin("\"name\"", code)
    end

    @testset "filters invalid local names" begin
        g = RDFGraph()
        rdf_type = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
        add!(g, Triple(URIRef("http://example.org/valid_term"), rdf_type, URIRef("http://www.w3.org/2002/07/owl#Class")))
        # URI with special characters should be filtered out
        add!(g, Triple(URIRef("http://example.org/has space"), rdf_type, URIRef("http://www.w3.org/2002/07/owl#Class")))

        code = create_namespace(g, "http://example.org/", "EX")
        @test occursin("\"valid_term\"", code)
        @test !occursin("has space", code)
    end

    @testset "sorted terms" begin
        g = RDFGraph()
        rdf_type = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
        add!(g, Triple(URIRef("http://example.org/Zebra"), rdf_type, URIRef("http://www.w3.org/2002/07/owl#Class")))
        add!(g, Triple(URIRef("http://example.org/Apple"), rdf_type, URIRef("http://www.w3.org/2002/07/owl#Class")))

        code = create_namespace(g, "http://example.org/", "FRUIT")
        apple_pos = findfirst("Apple", code)
        zebra_pos = findfirst("Zebra", code)
        @test apple_pos !== nothing
        @test zebra_pos !== nothing
        @test apple_pos.start < zebra_pos.start
    end

    @testset "terms from all triple positions" begin
        g = RDFGraph()
        # Term in subject position
        add!(g, Triple(URIRef("http://example.org/SubjTerm"), URIRef("http://other.org/p"), Literal("x")))
        # Term in predicate position
        add!(g, Triple(URIRef("http://other.org/s"), URIRef("http://example.org/PredTerm"), Literal("x")))
        # Term in object position
        add!(g, Triple(URIRef("http://other.org/s"), URIRef("http://other.org/p"), URIRef("http://example.org/ObjTerm")))

        code = create_namespace(g, "http://example.org/", "NS")
        @test occursin("\"SubjTerm\"", code)
        @test occursin("\"PredTerm\"", code)
        @test occursin("\"ObjTerm\"", code)
    end

    @testset "empty graph produces empty term set" begin
        g = RDFGraph()
        code = create_namespace(g, "http://example.org/", "EMPTY")
        @test occursin("const EMPTY = DefinedNamespace(", code)
        @test occursin("Set([", code)
    end

    @testset "auto-generated comment header" begin
        g = RDFGraph()
        code = create_namespace(g, "http://example.org/", "MY_NS")
        @test occursin("# Auto-generated namespace: MY_NS", code)
        @test occursin("# URI: http://example.org/", code)
    end
end
