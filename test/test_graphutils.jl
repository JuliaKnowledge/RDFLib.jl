using Test, RDFLib

@testset "RDFGraph Utilities" begin
    EX = Namespace("http://example.org/")

    @testset "merge_graphs - basic" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        add!(g1, Triple(EX("a"), EX("p"), Literal("1")))
        add!(g2, Triple(EX("b"), EX("q"), Literal("2")))
        merged = merge_graphs(g1, g2)
        @test length(merged) == 2
    end

    @testset "merge_graphs - blank node scoping" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        b = BNode("shared")
        add!(g1, Triple(EX("a"), EX("p"), b))
        add!(g1, Triple(b, EX("q"), Literal("from_g1")))
        add!(g2, Triple(EX("a"), EX("p"), b))
        add!(g2, Triple(b, EX("q"), Literal("from_g2")))

        merged = merge_graphs(g1, g2)
        @test length(merged) == 4  # Both sets of triples, with renamed bnodes
        # The two blank nodes should now be different
        bnode_objs = [t.object for t in merged if t.object isa Literal]
        @test Literal("from_g1") in bnode_objs
        @test Literal("from_g2") in bnode_objs
    end

    @testset "merge_graphs - no blank nodes" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        add!(g1, Triple(EX("a"), EX("p"), Literal("1")))
        add!(g2, Triple(EX("a"), EX("p"), Literal("1")))  # same triple
        merged = merge_graphs(g1, g2)
        @test length(merged) == 1  # deduplication
    end

    @testset "graph_diff" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        add!(g1, Triple(EX("a"), EX("p"), Literal("1")))
        add!(g1, Triple(EX("b"), EX("p"), Literal("2")))
        add!(g2, Triple(EX("a"), EX("p"), Literal("1")))
        add!(g2, Triple(EX("c"), EX("p"), Literal("3")))

        shared, left, right = graph_diff(g1, g2)
        @test length(shared) == 1
        @test length(left) == 1
        @test length(right) == 1
    end

    @testset "graph_stats" begin
        g = RDFGraph()
        add!(g, Triple(EX("a"), EX("p"), Literal("v")))
        add!(g, Triple(EX("a"), EX("q"), EX("b")))
        add!(g, Triple(BNode("x"), EX("r"), Literal("w")))

        stats = graph_stats(g)
        @test stats.triples == 3
        @test stats.subjects == 2
        @test stats.predicates == 3
        @test stats.blank_nodes == 1
        @test stats.literals == 2
    end

    @testset "cbd - basic" begin
        g = RDFGraph()
        add!(g, Triple(EX("alice"), EX("name"), Literal("Alice")))
        add!(g, Triple(EX("alice"), EX("knows"), EX("bob")))
        add!(g, Triple(EX("bob"), EX("name"), Literal("Bob")))

        desc = cbd(g, EX("alice"))
        @test length(desc) == 2  # alice's direct triples only
    end

    @testset "cbd - follows blank nodes" begin
        g = RDFGraph()
        b = BNode("addr")
        add!(g, Triple(EX("alice"), EX("address"), b))
        add!(g, Triple(b, EX("city"), Literal("NYC")))
        add!(g, Triple(b, EX("zip"), Literal("10001")))
        add!(g, Triple(EX("bob"), EX("name"), Literal("Bob")))

        desc = cbd(g, EX("alice"))
        @test length(desc) == 3  # alice -> addr, addr -> city, addr -> zip
    end

    @testset "connected_components" begin
        g = RDFGraph()
        add!(g, Triple(EX("a"), EX("p"), EX("b")))
        add!(g, Triple(EX("b"), EX("q"), EX("c")))
        add!(g, Triple(EX("x"), EX("r"), EX("y")))  # separate component

        components = connected_components(g)
        @test length(components) == 2
        sizes = sort([length(c) for c in components])
        @test sizes == [1, 2]
    end

    @testset "connected_components - single component" begin
        g = RDFGraph()
        add!(g, Triple(EX("a"), EX("p"), EX("b")))
        add!(g, Triple(EX("b"), EX("q"), EX("c")))

        components = connected_components(g)
        @test length(components) == 1
    end
end
