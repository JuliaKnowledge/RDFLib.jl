using Test
using RDFLib

@testset "N-Triples" begin
    EX = Namespace("http://example.org/")

    @testset "serialization" begin
        g = RDFGraph()
        add!(g, EX("s"), EX("p"), Literal("hello"))
        nt = serialize(g, NTriplesFormat())
        @test contains(nt, "<http://example.org/s>")
        @test contains(nt, "<http://example.org/p>")
        @test contains(nt, "\"hello\"")
        @test endswith(strip(nt), ".")
    end

    @testset "serialization with language tag" begin
        g = RDFGraph()
        add!(g, EX("s"), RDFS.label, Literal("hola", lang="es"))
        nt = serialize(g, NTriplesFormat())
        @test contains(nt, "\"hola\"@es")
    end

    @testset "serialization with datatype" begin
        g = RDFGraph()
        add!(g, EX("s"), EX("age"), Literal(42))
        nt = serialize(g, NTriplesFormat())
        @test contains(nt, "\"42\"^^<http://www.w3.org/2001/XMLSchema#integer>")
    end

    @testset "serialization with blank node" begin
        g = RDFGraph()
        b = BNode("x1")
        add!(g, b, RDF.type, EX("Thing"))
        nt = serialize(g, NTriplesFormat())
        @test contains(nt, "_:x1")
    end

    @testset "parse simple" begin
        nt = """
        <http://example.org/s> <http://example.org/p> "hello" .
        <http://example.org/s> <http://example.org/p2> <http://example.org/o> .
        """
        g = parse_rdf(nt, NTriplesFormat())
        @test length(g) == 2
    end

    @testset "parse with language tag" begin
        nt = """<http://example.org/s> <http://example.org/p> "bonjour"@fr ."""
        g = parse_rdf(nt, NTriplesFormat())
        objs = collect(objects(g, URIRef("http://example.org/s"), URIRef("http://example.org/p")))
        @test length(objs) == 1
        @test lang(objs[1]) == "fr"
    end

    @testset "parse with datatype" begin
        nt = """<http://example.org/s> <http://example.org/p> "42"^^<http://www.w3.org/2001/XMLSchema#integer> ."""
        g = parse_rdf(nt, NTriplesFormat())
        objs = collect(objects(g, URIRef("http://example.org/s"), URIRef("http://example.org/p")))
        @test length(objs) == 1
        @test toPython(objs[1]) == 42
    end

    @testset "parse blank node" begin
        nt = """_:b1 <http://example.org/p> "hello" ."""
        g = parse_rdf(nt, NTriplesFormat())
        @test length(g) == 1
        t = first(g)
        @test t.subject isa BNode
        @test t.subject == BNode("b1")
    end

    @testset "parse with escapes" begin
        nt = """<http://example.org/s> <http://example.org/p> "line1\\nline2" ."""
        g = parse_rdf(nt, NTriplesFormat())
        objs = collect(objects(g, URIRef("http://example.org/s"), URIRef("http://example.org/p")))
        @test string(objs[1]) == "line1\nline2"
    end

    @testset "parse skips comments and blank lines" begin
        nt = """
        # This is a comment
        
        <http://example.org/s> <http://example.org/p> "hello" .
        # Another comment
        """
        g = parse_rdf(nt, NTriplesFormat())
        @test length(g) == 1
    end

    @testset "round-trip" begin
        g1 = RDFGraph()
        add!(g1, EX("alice"), RDF.type, EX("Person"))
        add!(g1, EX("alice"), RDFS.label, Literal("Alice", lang="en"))
        add!(g1, EX("alice"), EX("age"), Literal(30))

        nt = serialize(g1, NTriplesFormat())
        g2 = parse_rdf(nt, NTriplesFormat())

        @test length(g2) == length(g1)
        for t in g1
            @test t in g2
        end
    end
end
