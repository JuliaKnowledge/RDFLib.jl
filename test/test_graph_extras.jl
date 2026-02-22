using Test
using RDFLib

@testset "Graph Extras" begin
    EX = RDFLib.Namespace("http://example.org/")

    @testset "transitive_objects" begin
        g = RDFGraph()
        add!(g, EX("A"), RDFS.subClassOf, EX("B"))
        add!(g, EX("B"), RDFS.subClassOf, EX("C"))
        add!(g, EX("C"), RDFS.subClassOf, EX("D"))

        result = RDFLib.transitive_objects(g, EX("A"), RDFS.subClassOf)
        @test EX("A") in result
        @test EX("B") in result
        @test EX("C") in result
        @test EX("D") in result
        @test length(result) == 4

        # From B, should reach B, C, D but not A
        result2 = RDFLib.transitive_objects(g, EX("B"), RDFS.subClassOf)
        @test EX("B") in result2
        @test EX("C") in result2
        @test EX("D") in result2
        @test !(EX("A") in result2)
        @test length(result2) == 3
    end

    @testset "transitive_subjects" begin
        g = RDFGraph()
        add!(g, EX("A"), RDFS.subClassOf, EX("B"))
        add!(g, EX("B"), RDFS.subClassOf, EX("C"))
        add!(g, EX("C"), RDFS.subClassOf, EX("D"))

        result = RDFLib.transitive_subjects(g, EX("D"), RDFS.subClassOf)
        @test EX("D") in result
        @test EX("C") in result
        @test EX("B") in result
        @test EX("A") in result
        @test length(result) == 4

        # Towards B: should find A and B only
        result2 = RDFLib.transitive_subjects(g, EX("B"), RDFS.subClassOf)
        @test EX("B") in result2
        @test EX("A") in result2
        @test !(EX("C") in result2)
        @test length(result2) == 2
    end

    @testset "all_nodes" begin
        g = RDFGraph()
        add!(g, EX("s1"), EX("p1"), EX("o1"))
        add!(g, EX("s2"), EX("p2"), Literal("hello"))

        nodes = RDFLib.all_nodes(g)
        @test EX("s1") in nodes
        @test EX("o1") in nodes
        @test EX("s2") in nodes
        @test Literal("hello") in nodes
        # Predicates are not included in all_nodes
        @test length(nodes) == 4
    end

    @testset "triples_choices" begin
        g = RDFGraph()
        add!(g, EX("a"), RDF.type, EX("Person"))
        add!(g, EX("b"), RDF.type, EX("Animal"))
        add!(g, EX("a"), RDFS.label, Literal("Alice"))
        add!(g, EX("c"), RDFS.label, Literal("Charlie"))

        # Multiple subjects
        result = RDFLib.triples_choices(g; subjects=[EX("a"), EX("b")])
        @test length(result) == 3

        # Multiple predicates
        result2 = RDFLib.triples_choices(g; predicates=[RDF.type, RDFS.label])
        @test length(result2) == 4

        # Constrained subject + multiple predicates
        result3 = RDFLib.triples_choices(g; subjects=[EX("a")], predicates=[RDF.type, RDFS.label])
        @test length(result3) == 2
    end

    @testset "skolemize" begin
        g = RDFGraph()
        b = BNode("xyz")
        add!(g, b, RDF.type, EX("Thing"))
        add!(g, EX("s"), EX("p"), b)

        sg = RDFLib.skolemize(g)
        skolem_uri = URIRef("https://rdflib.github.io/.well-known/genid/xyz")

        # BNode subject replaced
        ts = collect(triples(sg, (skolem_uri, RDF.type, nothing)))
        @test length(ts) == 1
        @test ts[1].object == EX("Thing")

        # BNode object replaced
        to = collect(triples(sg, (EX("s"), EX("p"), nothing)))
        @test length(to) == 1
        @test to[1].object == skolem_uri

        # No BNodes remain
        for t in sg
            @test !(t.subject isa BNode)
            @test !(t.object isa BNode)
        end
    end

    @testset "de_skolemize" begin
        g = RDFGraph()
        b = BNode("xyz")
        add!(g, b, RDF.type, EX("Thing"))
        add!(g, EX("s"), EX("p"), b)

        # Round-trip: skolemize then de-skolemize
        sg = RDFLib.skolemize(g)
        dg = RDFLib.de_skolemize(sg)

        @test length(dg) == 2
        ts = collect(triples(dg, (BNode("xyz"), RDF.type, nothing)))
        @test length(ts) == 1
        to = collect(triples(dg, (EX("s"), EX("p"), nothing)))
        @test length(to) == 1
        @test to[1].object == BNode("xyz")
    end

    @testset "parse_into!" begin
        g = RDFGraph()
        add!(g, EX("existing"), RDF.type, EX("Thing"))
        nt_data = "<http://example.org/s> <http://example.org/p> \"hello\" .\n"
        RDFLib.parse_into!(g, nt_data, NTriplesFormat())
        @test length(g) == 2
        vals = collect(objects(g, EX("s"), EX("p")))
        @test length(vals) == 1
        @test vals[1] == Literal("hello")
    end

    @testset "graph_n3" begin
        g = RDFGraph()
        add!(g, EX("s"), EX("p"), Literal("hello"))
        result = RDFLib.graph_n3(g)
        @test result isa String
        @test length(result) > 0
        @test occursin("hello", result)
    end
end
