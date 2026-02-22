using Test
using RDFLib

include("../src/cli.jl")

const CLI_EX = Namespace("http://example.org/")

@testset "CLI Tools" begin
    @testset "rdfpipe" begin
        @testset "N-Triples to N-Triples round-trip" begin
            nt = "<http://example.org/s> <http://example.org/p> \"hello\" .\n"
            result = rdfpipe(nt, NTriplesFormat(), NTriplesFormat())
            @test occursin("<http://example.org/s>", result)
            @test occursin("<http://example.org/p>", result)
            @test occursin("\"hello\"", result)
        end

        @testset "N-Triples to Turtle" begin
            nt = "<http://example.org/s> <http://example.org/p> \"hello\" .\n"
            result = rdfpipe(nt, NTriplesFormat(), TurtleFormat())
            @test occursin("hello", result)
        end

        @testset "Turtle to N-Triples" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:p "world" .
            """
            result = rdfpipe(ttl, TurtleFormat(), NTriplesFormat())
            @test occursin("<http://example.org/s>", result)
            @test occursin("\"world\"", result)
        end
    end

    @testset "csv2rdf" begin
        @testset "basic CSV conversion" begin
            csv = """name,age
Alice,30
Bob,25
"""
            g = csv2rdf(csv, "http://example.org/")
            @test length(g) > 0
            # Should have rows for Alice and Bob
            all_subjs = Set(collect(subjects(g)))
            @test length(all_subjs) == 2
        end

        @testset "subject from first column" begin
            csv = """id,name
alice,Alice
bob,Bob
"""
            g = csv2rdf(csv, "http://example.org/")
            # Subjects should be based on 'id' column values
            all_subjs = Set(collect(subjects(g)))
            @test URIRef("http://example.org/alice") in all_subjs
            @test URIRef("http://example.org/bob") in all_subjs
        end

        @testset "subject column by name" begin
            csv = """name,city
Alice,NYC
Bob,LA
"""
            g = csv2rdf(csv, "http://example.org/"; subject_column="name")
            all_subjs = Set(collect(subjects(g)))
            @test URIRef("http://example.org/Alice") in all_subjs
        end

        @testset "numeric values become typed literals" begin
            csv = """name,age
Alice,30
"""
            g = csv2rdf(csv, "http://example.org/")
            age_pred = URIRef("http://example.org/age")
            age_vals = collect(objects(g, nothing, age_pred))
            @test length(age_vals) >= 1
            # CSV.jl parses integers
            age_val = first(age_vals)
            @test age_val isa Literal
        end

        @testset "predicate prefix" begin
            csv = """name,age
Alice,30
"""
            g = csv2rdf(csv, "http://example.org/people/"; predicate_prefix="http://schema.org/")
            name_pred = URIRef("http://schema.org/name")
            name_vals = collect(objects(g, nothing, name_pred))
            @test length(name_vals) >= 1
        end

        @testset "URI subject values" begin
            csv = """uri,label
http://example.org/alice,Alice
"""
            g = csv2rdf(csv, "http://example.org/")
            @test URIRef("http://example.org/alice") in Set(collect(subjects(g)))
        end

        @testset "missing values are skipped" begin
            csv = """name,nickname
Alice,
Bob,Bobby
"""
            g = csv2rdf(csv, "http://example.org/")
            nick_pred = URIRef("http://example.org/nickname")
            nick_vals = collect(objects(g, nothing, nick_pred))
            # Only Bob has a nickname — Alice's is missing
            @test length(nick_vals) >= 1
        end
    end

    @testset "_uri_encode" begin
        @test _uri_encode("hello") == "hello"
        @test _uri_encode("hello world") == "hello%20world"
        @test _uri_encode("a_b") == "a_b"
        @test _uri_encode("a.b") == "a.b"
    end
end
