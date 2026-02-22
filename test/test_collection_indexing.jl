using Test
using RDFLib

@testset "CollectionView" begin
    EX = RDFLib.Namespace("http://example.org/")

    @testset "basic indexing and length" begin
        g = RDFGraph()
        items = [Literal("a"), Literal("b"), Literal("c")]
        head, tris = Collection(items)
        for t in tris; add!(g, t); end

        cv = CollectionView(g, head)
        @test length(cv) == 3
        @test cv[1] == Literal("a")
        @test cv[2] == Literal("b")
        @test cv[3] == Literal("c")
    end

    @testset "BoundsError" begin
        g = RDFGraph()
        items = [Literal("x")]
        head, tris = Collection(items)
        for t in tris; add!(g, t); end

        cv = CollectionView(g, head)
        @test_throws BoundsError cv[0]
        @test_throws BoundsError cv[2]
    end

    @testset "iteration" begin
        g = RDFGraph()
        items = [Literal("1"), Literal("2"), Literal("3")]
        head, tris = Collection(items)
        for t in tris; add!(g, t); end

        cv = CollectionView(g, head)
        collected = collect(cv)
        @test collected == items
    end

    @testset "empty collection" begin
        g = RDFGraph()
        # rdf:nil as head
        cv = CollectionView(g, URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil"))
        @test length(cv) == 0
        @test collect(cv) == Identifier[]
    end

    @testset "collection_view from graph head" begin
        g = RDFGraph()
        items = [Literal("hello"), Literal("world")]
        head, tris = Collection(items)
        for t in tris; add!(g, t); end

        cv = collection_view(g, head)
        @test cv[1] == Literal("hello")
        @test length(cv) == 2
    end

    @testset "collection_view from subject/predicate" begin
        g = RDFGraph()
        subj = EX("mylist")
        pred = EX("items")
        items = [Literal("a"), Literal("b")]
        add_collection!(g, subj, pred, items)

        cv = collection_view(g, subj, pred)
        @test length(cv) == 2
        @test cv[1] == Literal("a")
        @test cv[2] == Literal("b")
    end

    @testset "collection_view not found" begin
        g = RDFGraph()
        subj = EX("nothing")
        pred = EX("here")
        @test_throws ArgumentError collection_view(g, subj, pred)
    end
end
