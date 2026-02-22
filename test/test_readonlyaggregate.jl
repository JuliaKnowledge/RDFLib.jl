using Test
using RDFLib

@testset "ReadOnlyGraphAggregate" begin
    EX = RDFLib.Namespace("http://example.org/")

    @testset "construction" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        agg = ReadOnlyGraphAggregate([g1, g2])
        @test length(agg) == 0
        @test isempty(agg)
    end

    @testset "triples across graphs" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        add!(g1, Triple(EX("a"), EX("p"), EX("b")))
        add!(g2, Triple(EX("c"), EX("p"), EX("d")))
        agg = ReadOnlyGraphAggregate([g1, g2])
        @test length(agg) == 2
        all_t = collect(triples(agg, (nothing, EX("p"), nothing)))
        @test length(all_t) == 2
    end

    @testset "pattern matching" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        add!(g1, Triple(EX("a"), EX("p1"), EX("b")))
        add!(g2, Triple(EX("c"), EX("p2"), EX("d")))
        agg = ReadOnlyGraphAggregate([g1, g2])
        @test length(collect(triples(agg, (nothing, EX("p1"), nothing)))) == 1
        @test length(collect(triples(agg, (nothing, EX("p2"), nothing)))) == 1
        @test length(collect(triples(agg, (nothing, EX("p3"), nothing)))) == 0
    end

    @testset "graphs accessor" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        agg = ReadOnlyGraphAggregate([g1, g2])
        @test length(graphs(agg)) == 2
    end

    @testset "read-only enforcement" begin
        g1 = RDFGraph()
        agg = ReadOnlyGraphAggregate([g1])
        @test_throws ErrorException add!(agg, Triple(EX("a"), EX("p"), EX("b")))
        @test_throws ErrorException remove!(agg, (nothing, nothing, nothing))
    end

    @testset "iteration" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        add!(g1, Triple(EX("a"), EX("p"), EX("b")))
        add!(g2, Triple(EX("c"), EX("p"), EX("d")))
        agg = ReadOnlyGraphAggregate([g1, g2])
        collected = collect(agg)
        @test length(collected) == 2
        @test all(t -> t isa Triple, collected)
    end

    @testset "duplicate counting" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        t = Triple(EX("a"), EX("p"), EX("b"))
        add!(g1, t)
        add!(g2, t)
        agg = ReadOnlyGraphAggregate([g1, g2])
        # Length counts duplicates (one triple in each graph)
        @test length(agg) == 2
    end

    @testset "empty aggregate" begin
        agg = ReadOnlyGraphAggregate(RDFGraph[])
        @test length(agg) == 0
        @test isempty(agg)
        @test isempty(collect(agg))
    end
end
