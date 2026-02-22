using Test
using RDFLib

include(joinpath(@__DIR__, "..", "src", "sparql_tsv.jl"))

@testset "SPARQL Results TSV" begin

    @testset "Basic TSV output" begin
        results = [
            Dict("name" => Literal("Alice"), "age" => Literal(30))
        ]
        tsv = sparql_results_tsv(results, variables=["name", "age"])
        lines = split(strip(tsv), '\n')
        @test lines[1] == "?name\t?age"
        @test occursin("\"Alice\"", lines[2])
        @test occursin("\"30\"", lines[2])
    end

    @testset "URI values" begin
        results = [
            Dict("s" => URIRef("http://example.org/alice"))
        ]
        tsv = sparql_results_tsv(results, variables=["s"])
        lines = split(strip(tsv), '\n')
        @test lines[2] == "<http://example.org/alice>"
    end

    @testset "BNode values" begin
        results = [
            Dict("x" => BNode("b1"))
        ]
        tsv = sparql_results_tsv(results, variables=["x"])
        lines = split(strip(tsv), '\n')
        @test lines[2] == "_:b1"
    end

    @testset "Missing values" begin
        results = [
            Dict("a" => URIRef("http://example.org/x"))
        ]
        tsv = sparql_results_tsv(results, variables=["a", "b"])
        lines = split(chomp(tsv), '\n')
        parts = split(lines[2], '\t')
        @test parts[1] == "<http://example.org/x>"
        @test parts[2] == ""
    end

    @testset "Boolean ASK result" begin
        @test sparql_results_tsv(true) == "true"
        @test sparql_results_tsv(false) == "false"
    end

    @testset "Auto-detect variables" begin
        results = [
            Dict("b" => Literal("val"), "a" => URIRef("http://example.org/x"))
        ]
        tsv = sparql_results_tsv(results)
        lines = split(strip(tsv), '\n')
        # Variables sorted alphabetically
        @test lines[1] == "?a\t?b"
    end

    @testset "Multiple rows" begin
        results = [
            Dict("x" => Literal("one")),
            Dict("x" => Literal("two")),
            Dict("x" => Literal("three"))
        ]
        tsv = sparql_results_tsv(results, variables=["x"])
        lines = split(strip(tsv), '\n')
        @test length(lines) == 4  # header + 3 rows
    end

    @testset "Language-tagged literal" begin
        results = [
            Dict("label" => Literal("hello", lang="en"))
        ]
        tsv = sparql_results_tsv(results, variables=["label"])
        lines = split(strip(tsv), '\n')
        @test occursin("@en", lines[2])
    end
end
