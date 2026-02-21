using Test, RDFLib
import Graphs

const RDFGraph = RDFLib.RDFGraph

@testset "RDFGraph Isomorphism" begin
    @testset "identical graphs" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        EX = Namespace("http://example.org/")
        for g in (g1, g2)
            add!(g, Triple(EX("s"), EX("p"), Literal("hello")))
            add!(g, Triple(EX("s"), EX("p2"), EX("o")))
        end
        @test isomorphic(g1, g2)
    end

    @testset "different graphs" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        EX = Namespace("http://example.org/")
        add!(g1, Triple(EX("s"), EX("p"), Literal("hello")))
        add!(g2, Triple(EX("s"), EX("p"), Literal("world")))
        @test !isomorphic(g1, g2)
    end

    @testset "blank node relabeling" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        EX = Namespace("http://example.org/")
        b1 = BNode("x1")
        b2 = BNode("y1")
        add!(g1, Triple(EX("s"), EX("p"), b1))
        add!(g1, Triple(b1, EX("q"), Literal("v")))
        add!(g2, Triple(EX("s"), EX("p"), b2))
        add!(g2, Triple(b2, EX("q"), Literal("v")))
        @test isomorphic(g1, g2)
    end

    @testset "different structure with blank nodes" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        EX = Namespace("http://example.org/")
        b1 = BNode("a")
        b2 = BNode("b")
        add!(g1, Triple(EX("s"), EX("p"), b1))
        add!(g1, Triple(b1, EX("q"), Literal("v1")))
        add!(g2, Triple(EX("s"), EX("p"), b2))
        add!(g2, Triple(b2, EX("q"), Literal("v2")))
        @test !isomorphic(g1, g2)
    end

    @testset "empty graphs" begin
        @test isomorphic(RDFGraph(), RDFGraph())
    end

    @testset "different sizes" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        EX = Namespace("http://example.org/")
        add!(g1, Triple(EX("s"), EX("p"), EX("o")))
        @test !isomorphic(g1, g2)
    end

    @testset "multiple blank nodes" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        EX = Namespace("http://example.org/")
        a1, a2 = BNode("a1"), BNode("a2")
        b1, b2 = BNode("b1"), BNode("b2")
        # g1: s -> a1 -> a2
        add!(g1, Triple(EX("s"), EX("p"), a1))
        add!(g1, Triple(a1, EX("q"), a2))
        add!(g1, Triple(a2, EX("r"), Literal("end")))
        # g2: s -> b2 -> b1 (different labels, same structure)
        add!(g2, Triple(EX("s"), EX("p"), b2))
        add!(g2, Triple(b2, EX("q"), b1))
        add!(g2, Triple(b1, EX("r"), Literal("end")))
        @test isomorphic(g1, g2)
    end

    @testset "graph_hash" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        EX = Namespace("http://example.org/")
        for g in (g1, g2)
            add!(g, Triple(EX("s"), EX("p"), Literal("v")))
        end
        @test graph_hash(g1) == graph_hash(g2)
    end

    @testset "graph_hash blank node invariance" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        EX = Namespace("http://example.org/")
        add!(g1, Triple(EX("s"), EX("p"), BNode("x")))
        add!(g1, Triple(BNode("x"), EX("q"), Literal("v")))
        add!(g2, Triple(EX("s"), EX("p"), BNode("y")))
        add!(g2, Triple(BNode("y"), EX("q"), Literal("v")))
        @test graph_hash(g1) == graph_hash(g2)
    end

    @testset "to_simple_graph" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        add!(g, Triple(EX("a"), EX("p"), EX("b")))
        add!(g, Triple(EX("b"), EX("q"), EX("c")))
        dg, mapping = to_simple_graph(g)
        @test Graphs.nv(dg) >= 3
        @test Graphs.ne(dg) == 2
    end

    @testset "from_simple_graph roundtrip" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        add!(g, Triple(EX("a"), EX("p"), EX("b")))
        add!(g, Triple(EX("b"), EX("q"), EX("c")))
        dg, mapping = to_simple_graph(g)
        g2 = from_simple_graph(dg, mapping)
        # All original nodes should appear in the roundtripped graph
        @test length(g2) == 2
    end
end
