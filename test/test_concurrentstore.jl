using Test
using RDFLib

# ConcurrentStore is included and exported by the RDFLib module itself.

@testset "ConcurrentStore" begin
    s1 = URIRef("http://example.org/s1")
    s2 = URIRef("http://example.org/s2")
    p  = URIRef("http://example.org/p")
    o1 = Literal("hello")
    o2 = Literal("world")
    t1 = Triple(s1, p, o1)
    t2 = Triple(s2, p, o2)

    @testset "basic add and length" begin
        store = ConcurrentStore(MemoryStore())
        add!(store, t1)
        @test length(store) == 1
        @test !isempty(store)
    end

    @testset "add multiple triples" begin
        store = ConcurrentStore(MemoryStore())
        add!(store, t1)
        add!(store, t2)
        @test length(store) == 2
    end

    @testset "duplicate add" begin
        store = ConcurrentStore(MemoryStore())
        add!(store, t1)
        add!(store, t1)
        @test length(store) == 1
    end

    @testset "remove triple" begin
        store = ConcurrentStore(MemoryStore())
        add!(store, t1)
        add!(store, t2)
        remove!(store, (s1, p, o1))
        @test length(store) == 1
    end

    @testset "triples pattern matching" begin
        store = ConcurrentStore(MemoryStore())
        add!(store, t1)
        add!(store, t2)
        result = collect(triples(store, (nothing, p, nothing)))
        @test length(result) == 2
        result_s1 = collect(triples(store, (s1, nothing, nothing)))
        @test length(result_s1) == 1
    end

    @testset "triples returns a materialized snapshot" begin
        store = ConcurrentStore(MemoryStore())
        add!(store, t1)
        add!(store, t2)
        snapshot = triples(store, (nothing, nothing, nothing))
        # Direct vector — no Channel replay
        @test snapshot isa Vector{Triple}
        @test length(snapshot) == 2
        # Mutating the store after the call does not affect the snapshot
        remove!(store, (s1, p, o1))
        @test length(snapshot) == 2
        @test length(triples(store, (nothing, nothing, nothing))) == 1
    end

    @testset "isempty" begin
        store = ConcurrentStore(MemoryStore())
        @test isempty(store)
        add!(store, t1)
        @test !isempty(store)
    end

    @testset "works with RDFGraph" begin
        store = ConcurrentStore(MemoryStore())
        g = RDFGraph(store=store)
        add!(g, t1)
        add!(g, t2)
        @test length(g) == 2
        result = collect(triples(g, (nothing, nothing, nothing)))
        @test length(result) == 2
    end

    @testset "concurrent adds with @spawn" begin
        store = ConcurrentStore(MemoryStore())
        n = 100
        tasks = Task[]
        for i in 1:n
            t = Threads.@spawn begin
                s = URIRef("http://example.org/s$i")
                p_i = URIRef("http://example.org/p")
                o = Literal("val$i")
                add!(store, Triple(s, p_i, o))
            end
            push!(tasks, t)
        end
        for t in tasks
            wait(t)
        end
        @test length(store) == n
    end
end
