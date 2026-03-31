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
end
