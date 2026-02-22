using Test
using RDFLib

@testset "IsomorphicGraph" begin
    EX = RDFLib.Namespace("http://example.org/")

    @testset "equal graphs" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        add!(g1, Triple(EX("s"), EX("p"), EX("o")))
        add!(g2, Triple(EX("s"), EX("p"), EX("o")))
        @test IsomorphicGraph(g1) == IsomorphicGraph(g2)
    end

    @testset "bnode relabeling" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        add!(g1, Triple(EX("s"), EX("p"), BNode("a")))
        add!(g2, Triple(EX("s"), EX("p"), BNode("z")))
        @test IsomorphicGraph(g1) == IsomorphicGraph(g2)
    end

    @testset "non-isomorphic graphs" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        add!(g1, Triple(EX("s"), EX("p"), EX("o1")))
        add!(g2, Triple(EX("s"), EX("p"), EX("o2")))
        @test IsomorphicGraph(g1) != IsomorphicGraph(g2)
    end

    @testset "hash equality" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        add!(g1, Triple(EX("s"), EX("p"), BNode("x")))
        add!(g2, Triple(EX("s"), EX("p"), BNode("y")))
        @test hash(IsomorphicGraph(g1)) == hash(IsomorphicGraph(g2))
    end

    @testset "hash inequality" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        add!(g1, Triple(EX("s"), EX("p1"), EX("o")))
        add!(g2, Triple(EX("s"), EX("p2"), EX("o")))
        @test hash(IsomorphicGraph(g1)) != hash(IsomorphicGraph(g2))
    end

    @testset "to_isomorphic convenience" begin
        g = RDFGraph()
        add!(g, Triple(EX("s"), EX("p"), EX("o")))
        ig = to_isomorphic(g)
        @test ig isa IsomorphicGraph
        @test ig.graph === g
    end

    @testset "use in Set/Dict" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        add!(g1, Triple(EX("s"), EX("p"), BNode("a")))
        add!(g2, Triple(EX("s"), EX("p"), BNode("b")))
        s = Set([IsomorphicGraph(g1), IsomorphicGraph(g2)])
        # Isomorphic graphs should collapse to one entry
        @test length(s) == 1
    end

    @testset "empty graphs" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        @test IsomorphicGraph(g1) == IsomorphicGraph(g2)
        @test hash(IsomorphicGraph(g1)) == hash(IsomorphicGraph(g2))
    end
end
