using Test
using RDFLib

@testset "MemoryStore" begin
    store = MemoryStore()
    s = URIRef("http://example.org/s")
    p = URIRef("http://example.org/p")
    o = Literal("hello")
    t = Triple(s, p, o)

    @testset "add and length" begin
        add!(store, t)
        @test length(store) == 1

        # Duplicate add should not increase count
        add!(store, t)
        @test length(store) == 1
    end

    @testset "triple pattern matching" begin
        p2 = URIRef("http://example.org/p2")
        o2 = Literal("world")
        add!(store, Triple(s, p2, o2))
        @test length(store) == 2

        # S P O — exact match
        @test length(collect(triples(store, (s, p, o)))) == 1

        # S P ? — bound subject and predicate
        @test length(collect(triples(store, (s, p, nothing)))) == 1

        # S ? ? — bound subject
        @test length(collect(triples(store, (s, nothing, nothing)))) == 2

        # ? P ? — bound predicate
        @test length(collect(triples(store, (nothing, p, nothing)))) == 1

        # ? ? O — bound object
        @test length(collect(triples(store, (nothing, nothing, o)))) == 1

        # ? ? ? — all triples
        @test length(collect(triples(store, (nothing, nothing, nothing)))) == 2
    end

    @testset "remove" begin
        remove!(store, (s, p, o))
        @test length(store) == 1
        @test isempty(collect(triples(store, (s, p, o))))
        @test length(collect(triples(store, (s, nothing, nothing)))) == 1
        @test collect(triples(store, (nothing, p, nothing))) == Triple[]

        # Remove by wildcard
        remove!(store, (s, nothing, nothing))
        @test length(store) == 0
        @test isempty(store)
        @test collect(triples(store, (nothing, nothing, nothing))) == Triple[]
    end

    @testset "add_bulk! into empty store" begin
        st = MemoryStore()
        t1 = Triple(URIRef("http://ex.org/s1"), URIRef("http://ex.org/p"), Literal("a"))
        t2 = Triple(URIRef("http://ex.org/s2"), URIRef("http://ex.org/p"), Literal("b"))
        RDFLib.add_bulk!(st, [t1, t2])
        @test length(st) == 2
        @test length(st.insertion_order) == 2
        @test length(collect(triples(st, (nothing, nothing, nothing)))) == 2
    end

    @testset "add_bulk! preserves existing content (regression)" begin
        st = MemoryStore()
        t0 = Triple(URIRef("http://ex.org/s0"), URIRef("http://ex.org/p"), Literal("pre"))
        t1 = Triple(URIRef("http://ex.org/s1"), URIRef("http://ex.org/p"), Literal("a"))
        t2 = Triple(URIRef("http://ex.org/s2"), URIRef("http://ex.org/p"), Literal("b"))
        add!(st, t0)
        # Force secondary indices to be built before the bulk insert
        @test length(collect(triples(st, (nothing, URIRef("http://ex.org/p"), nothing)))) == 1

        RDFLib.add_bulk!(st, [t1, t2])
        @test length(st) == 3
        @test length(st.insertion_order) == 3
        all_triples = collect(triples(st, (nothing, nothing, nothing)))
        @test length(all_triples) == 3
        @test t0 in all_triples  # pre-existing triple must survive
        # Pattern queries must see old and new triples
        @test length(collect(triples(st, (nothing, URIRef("http://ex.org/p"), nothing)))) == 3
        @test length(collect(triples(st, (URIRef("http://ex.org/s0"), nothing, nothing)))) == 1
        @test length(collect(triples(st, (URIRef("http://ex.org/s1"), nothing, nothing)))) == 1
    end

    @testset "add_bulk! dedups input and existing triples" begin
        st = MemoryStore()
        t1 = Triple(URIRef("http://ex.org/s1"), URIRef("http://ex.org/p"), Literal("a"))
        t2 = Triple(URIRef("http://ex.org/s2"), URIRef("http://ex.org/p"), Literal("b"))
        add!(st, t1)
        # Input contains duplicates of each other and of existing content
        RDFLib.add_bulk!(st, [t1, t2, t2, t1, t2])
        @test length(st) == 2
        @test length(st.insertion_order) == 2
        @test length(collect(triples(st, (nothing, nothing, nothing)))) == 2
        # Set indices and insertion_order must stay in sync after removal
        remove!(st, (nothing, nothing, Literal("b")))
        @test length(st) == 1
        @test length(st.insertion_order) == 1
        @test collect(triples(st, (nothing, nothing, nothing))) == [t1]
    end
end
