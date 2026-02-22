using Test
using RDFLib

include(joinpath(@__DIR__, "..", "src", "rdfpatch.jl"))

const EX_RP = "http://example.org/"

@testset "RDF Patch Format" begin

    @testset "Serialize additions only" begin
        additions = [Triple(URIRef(EX_RP * "s"), URIRef(EX_RP * "p"), Literal("val"))]
        result = serialize_rdfpatch(additions, Triple[])
        @test occursin("TX .", result)
        @test occursin("TC .", result)
        @test occursin("A <$(EX_RP)s>", result)
    end

    @testset "Serialize deletions only" begin
        deletions = [Triple(URIRef(EX_RP * "s"), URIRef(EX_RP * "p"), Literal("old"))]
        result = serialize_rdfpatch(Triple[], deletions)
        @test occursin("D <$(EX_RP)s>", result)
    end

    @testset "Serialize both additions and deletions" begin
        additions = [Triple(URIRef(EX_RP * "s"), URIRef(EX_RP * "p"), Literal("new"))]
        deletions = [Triple(URIRef(EX_RP * "s"), URIRef(EX_RP * "p"), Literal("old"))]
        result = serialize_rdfpatch(additions, deletions)
        @test occursin("A ", result)
        @test occursin("D ", result)
    end

    @testset "Parse additions" begin
        patch = """TX .
A <http://example.org/s> <http://example.org/p> "value" .
TC ."""
        additions, deletions = parse_rdfpatch(patch)
        @test length(additions) == 1
        @test length(deletions) == 0
        @test additions[1].subject == URIRef("http://example.org/s")
        @test additions[1].object == Literal("value")
    end

    @testset "Parse deletions" begin
        patch = """TX .
D <http://example.org/s> <http://example.org/p> "old" .
TC ."""
        additions, deletions = parse_rdfpatch(patch)
        @test length(additions) == 0
        @test length(deletions) == 1
    end

    @testset "Parse mixed" begin
        patch = """TX .
A <http://example.org/s> <http://example.org/p> "new" .
D <http://example.org/s> <http://example.org/p> "old" .
TC ."""
        additions, deletions = parse_rdfpatch(patch)
        @test length(additions) == 1
        @test length(deletions) == 1
    end

    @testset "Apply patch - add" begin
        g = RDFGraph()
        patch = """TX .
A <http://example.org/s> <http://example.org/p> "hello" .
TC ."""
        apply_rdfpatch!(g, patch)
        @test length(g) == 1
        ts = collect(g)
        @test ts[1].object == Literal("hello")
    end

    @testset "Apply patch - delete" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_RP * "s"), URIRef(EX_RP * "p"), Literal("old")))
        @test length(g) == 1
        patch = """TX .
D <http://example.org/s> <http://example.org/p> "old" .
TC ."""
        apply_rdfpatch!(g, patch)
        @test length(g) == 0
    end

    @testset "Apply patch - add and delete" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_RP * "s"), URIRef(EX_RP * "p"), Literal("old")))
        patch = """TX .
D <http://example.org/s> <http://example.org/p> "old" .
A <http://example.org/s> <http://example.org/p> "new" .
TC ."""
        apply_rdfpatch!(g, patch)
        @test length(g) == 1
        ts = collect(g)
        @test ts[1].object == Literal("new")
    end

    @testset "Round-trip" begin
        additions = [
            Triple(URIRef(EX_RP * "s1"), URIRef(EX_RP * "p"), Literal("a")),
            Triple(URIRef(EX_RP * "s2"), URIRef(EX_RP * "p"), URIRef(EX_RP * "o"))
        ]
        deletions = [
            Triple(URIRef(EX_RP * "s3"), URIRef(EX_RP * "p"), Literal(42))
        ]
        patch_str = serialize_rdfpatch(additions, deletions)
        a2, d2 = parse_rdfpatch(patch_str)
        @test length(a2) == 2
        @test length(d2) == 1
    end

    @testset "Blank comments and empty lines" begin
        patch = """
# This is a comment
TX .

A <http://example.org/s> <http://example.org/p> "val" .

TC .
"""
        additions, deletions = parse_rdfpatch(patch)
        @test length(additions) == 1
    end

    @testset "Blank node in patch" begin
        patch = """TX .
A _:b1 <http://example.org/p> "val" .
TC ."""
        additions, _ = parse_rdfpatch(patch)
        @test length(additions) == 1
        @test additions[1].subject == BNode("b1")
    end
end
