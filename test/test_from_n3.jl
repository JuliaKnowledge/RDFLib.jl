using Test
using RDFLib

@testset "from_n3 / to_term" begin
    @testset "URIRef" begin
        @test from_n3("<http://example.org/x>") == URIRef("http://example.org/x")
        @test from_n3("<http://www.w3.org/1999/02/22-rdf-syntax-ns#type>") == RDF.type
    end

    @testset "BNode" begin
        @test from_n3("_:b1") == BNode("b1")
        @test from_n3("_:node42") == BNode("node42")
    end

    @testset "plain literal" begin
        lit = from_n3("\"hello\"")
        @test lit isa Literal
        @test lit.lexical == "hello"
        @test isnothing(lit.language)
        @test isnothing(lit.datatype)
    end

    @testset "language literal" begin
        lit = from_n3("\"hello\"@en")
        @test lit.lexical == "hello"
        @test lit.language == "en"
    end

    @testset "typed literal with full URI" begin
        lit = from_n3("\"42\"^^<http://www.w3.org/2001/XMLSchema#integer>")
        @test lit.lexical == "42"
        @test lit.datatype == XSD.integer
    end

    @testset "typed literal with xsd prefix" begin
        lit = from_n3("\"true\"^^xsd:boolean")
        @test lit.lexical == "true"
        @test lit.datatype == XSD.boolean
    end

    @testset "escaped characters" begin
        lit = from_n3("\"hello\\nworld\"")
        @test lit.lexical == "hello\nworld"
    end

    @testset "to_term alias" begin
        @test to_term("<http://example.org/x>") == from_n3("<http://example.org/x>")
    end

    @testset "error on invalid input" begin
        @test_throws ArgumentError from_n3("")
        @test_throws ArgumentError from_n3("invalid")
    end
end
