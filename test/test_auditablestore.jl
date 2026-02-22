using Test
using RDFLib

include(joinpath(@__DIR__, "..", "src", "auditablestore.jl"))

@testset "AuditableStore" begin
    s1 = URIRef("http://example.org/s1")
    s2 = URIRef("http://example.org/s2")
    p  = URIRef("http://example.org/p")
    o1 = Literal("hello")
    o2 = Literal("world")
    t1 = Triple(s1, p, o1)
    t2 = Triple(s2, p, o2)

    @testset "delegates add!/length to inner store" begin
        store = AuditableStore(MemoryStore())
        add!(store, t1)
        @test length(store) == 1
        @test !isempty(store)
    end

    @testset "duplicate add recorded but inner deduplicates" begin
        store = AuditableStore(MemoryStore())
        add!(store, t1)
        add!(store, t1)
        @test length(store) == 1
        @test length(journal(store)) == 2
    end

    @testset "journal records add operations" begin
        store = AuditableStore(MemoryStore())
        add!(store, t1)
        add!(store, t2)
        j = journal(store)
        @test length(j) == 2
        @test j[1] == (:add, t1)
        @test j[2] == (:add, t2)
    end

    @testset "journal records remove operations" begin
        store = AuditableStore(MemoryStore())
        add!(store, t1)
        add!(store, t2)
        clear_journal!(store)
        remove!(store, (s1, p, o1))
        j = journal(store)
        @test length(j) == 1
        @test j[1] == (:remove, t1)
        @test length(store) == 1
    end

    @testset "remove with wildcard records all removed triples" begin
        store = AuditableStore(MemoryStore())
        add!(store, t1)
        add!(store, t2)
        clear_journal!(store)
        remove!(store, (nothing, p, nothing))
        j = journal(store)
        @test length(j) == 2
        @test length(store) == 0
    end

    @testset "triples delegates to inner" begin
        store = AuditableStore(MemoryStore())
        add!(store, t1)
        add!(store, t2)
        result = collect(triples(store, (nothing, nothing, nothing)))
        @test length(result) == 2
    end

    @testset "undo add" begin
        store = AuditableStore(MemoryStore())
        add!(store, t1)
        @test length(store) == 1
        undone = undo!(store)
        @test undone == (:add, t1)
        @test length(store) == 0
    end

    @testset "undo remove" begin
        store = AuditableStore(MemoryStore())
        add!(store, t1)
        clear_journal!(store)
        remove!(store, (s1, p, o1))
        @test length(store) == 0
        undone = undo!(store)
        @test undone == (:remove, t1)
        @test length(store) == 1
    end

    @testset "undo on empty journal returns nothing" begin
        store = AuditableStore(MemoryStore())
        @test undo!(store) === nothing
    end

    @testset "clear_journal!" begin
        store = AuditableStore(MemoryStore())
        add!(store, t1)
        add!(store, t2)
        @test length(journal(store)) == 2
        clear_journal!(store)
        @test length(journal(store)) == 0
        @test length(store) == 2  # data not affected
    end

    @testset "works with RDFGraph" begin
        store = AuditableStore(MemoryStore())
        g = RDFGraph(store=store)
        add!(g, t1)
        add!(g, t2)
        @test length(g) == 2
        @test length(journal(store)) == 2
    end

    @testset "multiple undo operations" begin
        store = AuditableStore(MemoryStore())
        add!(store, t1)
        add!(store, t2)
        undo!(store)
        @test length(store) == 1
        undo!(store)
        @test length(store) == 0
        @test undo!(store) === nothing
    end
end
