using Test
using RDFLib

include(joinpath(@__DIR__, "..", "src", "longturtle.jl"))

const EX_LT = "http://example.org/"

@testset "Long Turtle Format" begin

    @testset "Serialize URI triple" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_LT * "s"), URIRef(EX_LT * "p"), URIRef(EX_LT * "o")))
        result = serialize_longturtle(g)
        @test occursin("<$(EX_LT)s>", result)
        @test occursin("<$(EX_LT)p>", result)
        @test occursin("<$(EX_LT)o>", result)
        @test endswith(strip(result), ".")
    end

    @testset "Serialize plain literal" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_LT * "s"), URIRef(EX_LT * "p"), Literal("hello")))
        result = serialize_longturtle(g)
        @test occursin("\"hello\"", result)
    end

    @testset "Serialize typed literal" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_LT * "s"), URIRef(EX_LT * "p"), Literal(42)))
        result = serialize_longturtle(g)
        @test occursin("\"42\"^^<http://www.w3.org/2001/XMLSchema#integer>", result)
    end

    @testset "Serialize language-tagged literal" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_LT * "s"), URIRef(EX_LT * "p"), Literal("bonjour", lang="fr")))
        result = serialize_longturtle(g)
        @test occursin("\"bonjour\"@fr", result)
    end

    @testset "Serialize blank node" begin
        g = RDFGraph()
        add!(g, Triple(BNode("b1"), URIRef(EX_LT * "p"), Literal("val")))
        result = serialize_longturtle(g)
        @test occursin("_:b1", result)
    end

    @testset "One triple per line" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_LT * "s"), URIRef(EX_LT * "p1"), Literal("a")))
        add!(g, Triple(URIRef(EX_LT * "s"), URIRef(EX_LT * "p2"), Literal("b")))
        result = serialize_longturtle(g)
        lines = filter(!isempty, split(strip(result), '\n'))
        @test length(lines) == 2
        @test all(l -> endswith(strip(l), "."), lines)
    end

    @testset "Parseable by standard Turtle parser" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_LT * "s"), URIRef(EX_LT * "p"), Literal("hello")))
        add!(g, Triple(URIRef(EX_LT * "s"), URIRef(EX_LT * "p2"), URIRef(EX_LT * "o")))
        lt = serialize_longturtle(g)
        g2 = parse_rdf(lt, TurtleFormat())
        @test length(g2) == 2
    end

    @testset "Serialize directional language-tagged literal" begin
        g = RDFGraph()
        lit = Literal("hello", lang="en", direction="ltr")
        add!(g, Triple(URIRef(EX_LT * "s"), URIRef(EX_LT * "p"), lit))
        result = serialize_longturtle(g)
        @test occursin("\"hello\"@en--ltr", result)
        # round-trips through the Turtle parser
        g2 = parse_rdf(result, TurtleFormat())
        @test Triple(URIRef(EX_LT * "s"), URIRef(EX_LT * "p"), lit) in g2
    end

    @testset "Serialize RDF 1.2 triple term (object position)" begin
        g = RDFGraph()
        tt = TripleTerm(URIRef(EX_LT * "s"), URIRef(EX_LT * "p"), URIRef(EX_LT * "o"))
        add!(g, Triple(URIRef(EX_LT * "a"), URIRef(EX_LT * "b"), tt))
        result = serialize_longturtle(g)
        @test occursin("<<( <$(EX_LT)s> <$(EX_LT)p> <$(EX_LT)o> )>>", result)
        g2 = parse_rdf(result, TurtleFormat())
        @test Triple(URIRef(EX_LT * "a"), URIRef(EX_LT * "b"), tt) in g2
    end
end
