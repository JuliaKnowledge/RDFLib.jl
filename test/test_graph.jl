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
        @test collect(g) == [Triple(EX("s"), RDF.type, EX("Person"))]
        @test !(Triple(EX("s"), RDFS.label, Literal("Alice")) in g)
    end

    @testset "reject invalid triples" begin
        g = RDFGraph()
        @test_throws ArgumentError add!(g, Triple(Literal("bad"), EX("p"), Literal("ok")))
        @test_throws ArgumentError add!(g, Triple(EX("s"), Literal("bad"), Literal("ok")))
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

    @testset "triples keyword API (README)" begin
        g = RDFGraph()
        add!(g, EX("a"), RDF.type, EX("Person"))
        add!(g, EX("b"), RDF.type, EX("Animal"))
        add!(g, EX("a"), RDFS.label, Literal("Alice"))

        # All triples (no keywords)
        @test length(collect(triples(g))) == 3

        # Single keyword filters
        @test length(collect(triples(g; subject=EX("a")))) == 2
        @test length(collect(triples(g; predicate=RDF.type))) == 2
        @test length(collect(triples(g; object=EX("Person")))) == 1

        # Combined keywords
        r = collect(triples(g; subject=EX("a"), predicate=RDFS.label))
        @test length(r) == 1
        @test r[1].object == Literal("Alice")

        # Keyword form agrees with tuple form
        @test Set(collect(triples(g; predicate=RDF.type))) ==
              Set(collect(triples(g, (nothing, RDF.type, nothing))))
    end

    @testset "mutation during iteration throws" begin
        g = RDFGraph()
        for i in 1:5
            add!(g, EX("s$i"), RDF.type, EX("Thing"))
        end

        # add! during iteration
        @test_throws ErrorException begin
            for t in g
                add!(g, EX("new"), RDF.type, EX("Thing"))
            end
        end

        # remove! during iteration
        g2 = RDFGraph()
        for i in 1:5
            add!(g2, EX("s$i"), RDF.type, EX("Thing"))
        end
        @test_throws ErrorException begin
            for t in g2
                remove!(g2, (t.subject, nothing, nothing))
            end
        end

        # Plain iteration and read-only pattern queries do not throw
        g3 = RDFGraph()
        add!(g3, EX("a"), RDF.type, EX("Thing"))
        add!(g3, EX("b"), RDF.type, EX("Thing"))
        n = 0
        for t in g3
            # Pattern query triggers (secondary) index builds — must NOT
            # count as a modification
            @test length(collect(triples(g3, (t.subject, nothing, nothing)))) == 1
            n += 1
        end
        @test n == 2

        # Iteration after mutation works again
        add!(g3, EX("c"), RDF.type, EX("Thing"))
        @test length(collect(g3)) == 3
    end

    @testset "serialization rejects invalid stored RDF triples" begin
        g = RDFGraph()
        add!(g.store, Triple(EX("s"), Literal("bad"), Literal("ok")))
        @test_throws ArgumentError serialize(g, NTriplesFormat())
        @test_throws ArgumentError serialize(g, TurtleFormat())
    end
end
