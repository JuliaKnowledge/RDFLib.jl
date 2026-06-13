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

    @testset "10-cycle vs two 5-cycles (>8 bnodes regression)" begin
        # Color refinement alone cannot distinguish these regular graphs;
        # the old signature-hash path returned a false positive here.
        EX = Namespace("http://example.org/")
        p = EX("next")

        # g1: single 10-cycle of blank nodes
        g1 = RDFGraph()
        b = [BNode("a$i") for i in 1:10]
        for i in 1:10
            add!(g1, Triple(b[i], p, b[mod1(i + 1, 10)]))
        end

        # g2: two disjoint 5-cycles of blank nodes
        g2 = RDFGraph()
        c = [BNode("c$i") for i in 1:10]
        for i in 1:5
            add!(g2, Triple(c[i], p, c[mod1(i + 1, 5)]))
            add!(g2, Triple(c[5 + i], p, c[5 + mod1(i + 1, 5)]))
        end

        @test length(g1) == 10 && length(g2) == 10
        @test !isomorphic(g1, g2)
        @test !isomorphic(g2, g1)

        # Two 5-cycle pairs ARE isomorphic to each other
        g3 = RDFGraph()
        d = [BNode("zz$i") for i in 1:10]
        for i in 1:5
            add!(g3, Triple(d[i], p, d[mod1(i + 1, 5)]))
            add!(g3, Triple(d[5 + i], p, d[5 + mod1(i + 1, 5)]))
        end
        @test isomorphic(g2, g3)
        @test isomorphic(g3, g2)

        # A 10-cycle relabeled is isomorphic to the 10-cycle
        g4 = RDFGraph()
        e = [BNode("e$i") for i in 1:10]
        for i in 1:10
            add!(g4, Triple(e[i], p, e[mod1(i + 1, 10)]))
        end
        @test isomorphic(g1, g4)
    end

    @testset "12-bnode random tree relabeled" begin
        EX = Namespace("http://example.org/")
        p = EX("child")
        # Deterministic "random" tree: parent of node i is (i*7 % i_range)+1 clipped
        parents = [1, 1, 2, 2, 3, 4, 4, 5, 7, 8, 9]  # parents of nodes 2..12
        g1 = RDFGraph()
        b = [BNode("n$i") for i in 1:12]
        for (i, par) in enumerate(parents)
            add!(g1, Triple(b[par], p, b[i + 1]))
        end
        # Relabeled (reversed names, shuffled insertion order)
        g2 = RDFGraph()
        c = [BNode("m$(13 - i)") for i in 1:12]
        for (i, par) in Iterators.reverse(collect(enumerate(parents)))
            add!(g2, Triple(c[par], p, c[i + 1]))
        end
        @test isomorphic(g1, g2)
        @test graph_hash(g1) == graph_hash(g2)

        # Breaking one edge makes them non-isomorphic
        g3 = RDFGraph()
        for (i, par) in enumerate(parents)
            add!(g3, Triple(b[par == 9 ? 10 : par], p, b[i + 1]))
        end
        @test !isomorphic(g1, g3)
    end

    @testset "graph_hash invariance for >8 bnodes" begin
        EX = Namespace("http://example.org/")
        p = EX("next")
        g1 = RDFGraph()
        g2 = RDFGraph()
        for i in 1:9
            add!(g1, Triple(BNode("x$i"), p, BNode("x$(i + 1)")))
            add!(g2, Triple(BNode("y$(i + 100)"), p, BNode("y$(i + 101)")))
        end
        @test isomorphic(g1, g2)
        @test graph_hash(g1) == graph_hash(g2)
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
