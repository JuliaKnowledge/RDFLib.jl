using Test
using RDFLib

include(joinpath(@__DIR__, "..", "src", "events.jl"))

@testset "Events" begin
    s1 = URIRef("http://example.org/s1")
    s2 = URIRef("http://example.org/s2")
    p  = URIRef("http://example.org/p")
    o1 = Literal("hello")
    o2 = Literal("world")
    t1 = Triple(s1, p, o1)
    t2 = Triple(s2, p, o2)

    @testset "EventDispatcher on!/emit!" begin
        d = EventDispatcher()
        events = RDFEvent[]
        cb = e -> push!(events, e)
        on!(d, TripleAdded, cb)
        emit!(d, TripleAdded(t1))
        @test length(events) == 1
        @test events[1] isa TripleAdded
        @test events[1].triple == t1
    end

    @testset "multiple listeners" begin
        d = EventDispatcher()
        count = Ref(0)
        on!(d, TripleAdded, _ -> count[] += 1)
        on!(d, TripleAdded, _ -> count[] += 10)
        emit!(d, TripleAdded(t1))
        @test count[] == 11
    end

    @testset "off! removes listener" begin
        d = EventDispatcher()
        count = Ref(0)
        cb = _ -> count[] += 1
        on!(d, TripleAdded, cb)
        emit!(d, TripleAdded(t1))
        @test count[] == 1
        off!(d, TripleAdded, cb)
        emit!(d, TripleAdded(t2))
        @test count[] == 1  # not incremented
    end

    @testset "emit with no listeners does nothing" begin
        d = EventDispatcher()
        @test_nowarn emit!(d, TripleAdded(t1))
    end

    @testset "different event types independent" begin
        d = EventDispatcher()
        added = Triple[]
        removed = Triple[]
        on!(d, TripleAdded, e -> push!(added, e.triple))
        on!(d, TripleRemoved, e -> push!(removed, e.triple))
        emit!(d, TripleAdded(t1))
        emit!(d, TripleRemoved(t2))
        @test length(added) == 1
        @test added[1] == t1
        @test length(removed) == 1
        @test removed[1] == t2
    end

    @testset "GraphCleared event" begin
        d = EventDispatcher()
        cleared = Ref(false)
        on!(d, GraphCleared, _ -> cleared[] = true)
        emit!(d, GraphCleared())
        @test cleared[]
    end

    @testset "ObservableGraph add fires TripleAdded" begin
        og = ObservableGraph()
        events = RDFEvent[]
        on!(og.dispatcher, TripleAdded, e -> push!(events, e))
        add!(og, t1)
        @test length(og) == 1
        @test length(events) == 1
        @test events[1].triple == t1
    end

    @testset "ObservableGraph remove fires TripleRemoved" begin
        og = ObservableGraph()
        removed = Triple[]
        on!(og.dispatcher, TripleRemoved, e -> push!(removed, e.triple))
        add!(og, t1)
        add!(og, t2)
        remove!(og, (s1, p, o1))
        @test length(og) == 1
        @test length(removed) == 1
        @test removed[1] == t1
    end

    @testset "ObservableGraph triples" begin
        og = ObservableGraph()
        add!(og, t1)
        add!(og, t2)
        result = collect(triples(og))
        @test length(result) == 2
    end

    @testset "ObservableGraph wraps existing graph" begin
        g = RDFGraph()
        add!(g, t1)
        og = ObservableGraph(g)
        @test length(og) == 1
        events = RDFEvent[]
        on!(og.dispatcher, TripleAdded, e -> push!(events, e))
        add!(og, t2)
        @test length(og) == 2
        @test length(events) == 1
    end

    @testset "ObservableGraph isempty" begin
        og = ObservableGraph()
        @test isempty(og)
        add!(og, t1)
        @test !isempty(og)
    end
end
