using Test
using RDFLib

@testset "RDFGraph" begin
    EX = Namespace("http://example.org/")

    @testset "add and iterate" begin
        g = RDFGraph()
        add!(g, URIRef("http://example.org/s"), RDF.type, URIRef("http://example.org/Person"))
        add!(g, URIRef("http://example.org/s"), RDFS.label, Literal("Alice"))
        @test length(g) == 2
        @test !isempty(g)

        # Collect all triples
        all = collect(g)
        @test length(all) == 2
    end

    @testset "contains" begin
        g = RDFGraph()
        t = Triple(EX("s"), RDF.type, EX("Person"))
        add!(g, t)
        @test t in g
        @test !(Triple(EX("s"), RDF.type, EX("Animal")) in g)
    end

    @testset "remove" begin
        g = RDFGraph()
        add!(g, EX("s"), RDF.type, EX("Person"))
        add!(g, EX("s"), RDFS.label, Literal("Alice"))
        @test length(g) == 2

        remove!(g, (EX("s"), RDFS.label, Literal("Alice")))
        @test length(g) == 1
    end

    @testset "convenience accessors" begin
        g = RDFGraph()
        s1 = EX("alice")
        s2 = EX("bob")
        add!(g, s1, RDF.type, EX("Person"))
        add!(g, s2, RDF.type, EX("Person"))
        add!(g, s1, RDFS.label, Literal("Alice"))

        # subjects
        subjs = collect(subjects(g, RDF.type, EX("Person")))
        @test length(subjs) == 2
        @test s1 in subjs && s2 in subjs

        # objects
        objs = collect(objects(g, s1, RDFS.label))
        @test length(objs) == 1
        @test Literal("Alice") in objs

        # value
        @test value(g, s1, RDFS.label) == Literal("Alice")
        @test value(g, s2, RDFS.label) === nothing
    end

    @testset "set operations" begin
        g1 = RDFGraph()
        g2 = RDFGraph()
        add!(g1, EX("a"), RDF.type, EX("X"))
        add!(g1, EX("b"), RDF.type, EX("Y"))
        add!(g2, EX("b"), RDF.type, EX("Y"))
        add!(g2, EX("c"), RDF.type, EX("Z"))

        u = g1 + g2
        @test length(u) == 3

        i = intersect(g1, g2)
        @test length(i) == 1

        d = g1 - g2
        @test length(d) == 1

        sd = symdiff(g1, g2)
        @test length(sd) == 2
    end

    @testset "namespace binding" begin
        g = RDFGraph()
        bind!(g, "ex", Namespace("http://example.org/"))
        @test expand_curie(g.namespace_manager, "ex:Person") == EX("Person")
    end
end
