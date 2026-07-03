using Test, RDFLib

@testset "Collections & Containers" begin
    @testset "Collection creation" begin
        items = Identifier[Literal("a"), Literal("b"), Literal("c")]
        head, triples = Collection(items)
        @test head isa BNode
        @test length(triples) == 6  # 3 first + 3 rest (including nil)
    end

    @testset "Collection round-trip" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        items = Identifier[Literal("x"), Literal("y"), Literal("z")]
        head, tris = Collection(items)
        for t in tris; add!(g, t); end
        add!(g, Triple(EX("s"), EX("list"), head))

        recovered = collect_list(g, head)
        @test length(recovered) == 3
        @test recovered[1] == Literal("x")
        @test recovered[2] == Literal("y")
        @test recovered[3] == Literal("z")
    end

    @testset "Collection - empty" begin
        head, tris = Collection(Identifier[])
        @test head == RDF.nil
        @test isempty(tris)
    end

    @testset "collect_list from rdf:nil" begin
        g = RDFGraph()
        @test isempty(collect_list(g, RDF.nil))
    end

    @testset "collect_list stops on cyclic list" begin
        g = RDFGraph()
        head = BNode("cycle")
        add!(g, Triple(head, RDF.first, Literal("x")))
        add!(g, Triple(head, RDF.rest, head))
        @test collect_list(g, head) == Identifier[Literal("x")]
    end

    @testset "add_collection!" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        add_collection!(g, EX("s"), EX("items"), Identifier[Literal("a"), Literal("b")])
        # Should have: s items head, head first "a", head rest n2, n2 first "b", n2 rest nil
        @test length(g) == 5
    end

    @testset "Container - Bag" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        bag = EX("mybag")
        add_container!(g, bag, :Bag, Identifier[Literal("a"), Literal("b"), Literal("c")])
        # type + 3 members = 4 triples
        @test length(g) == 4
        items = collect_container(g, bag)
        @test length(items) == 3
        @test Literal("a") in items
    end

    @testset "Container - Seq ordering" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        seq = EX("myseq")
        add_container!(g, seq, :Seq, Identifier[Literal("first"), Literal("second"), Literal("third")])
        items = collect_container(g, seq)
        @test items[1] == Literal("first")
        @test items[2] == Literal("second")
        @test items[3] == Literal("third")
    end

    @testset "container_membership_property" begin
        @test container_membership_property(1) == URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#_1")
        @test container_membership_property(42) == URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#_42")
    end
end
