using Test
using RDFLib
using Dates

@testset "Term Types" begin
    @testset "URIRef" begin
        u = URIRef("http://example.org/resource")
        @test string(u) == "http://example.org/resource"
        @test n3(u) == "<http://example.org/resource>"
        @test u == URIRef("http://example.org/resource")
        @test u != URIRef("http://example.org/other")
        @test hash(u) == hash(URIRef("http://example.org/resource"))

        # defrag / fragment
        u2 = URIRef("http://example.org/page#section")
        @test defrag(u2) == URIRef("http://example.org/page")
        @test fragment(u2) == "section"
        @test fragment(u) == ""
    end

    @testset "BNode" begin
        b1 = BNode()
        b2 = BNode()
        @test b1 != b2  # unique IDs
        @test startswith(n3(b1), "_:")

        b3 = BNode("mynode")
        @test string(b3) == "mynode"
        @test n3(b3) == "_:mynode"
        @test b3 == BNode("mynode")
    end

    @testset "Literal - plain" begin
        l = Literal("hello")
        @test string(l) == "hello"
        @test n3(l) == "\"hello\""
        @test lang(l) === nothing
        @test datatype(l) === nothing
    end

    @testset "Literal - language tagged" begin
        l = Literal("bonjour", lang="fr")
        @test lang(l) == "fr"
        @test n3(l) == "\"bonjour\"@fr"
        @test l == Literal("bonjour", lang="FR")  # case-insensitive
    end

    @testset "Literal - typed" begin
        l = Literal("42", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))
        @test n3(l) == "\"42\"^^<http://www.w3.org/2001/XMLSchema#integer>"
        @test toPython(l) == 42
    end

    @testset "Literal - auto-typed constructors" begin
        @test toPython(Literal(42)) == 42
        @test toPython(Literal(3.14)) == 3.14
        @test toPython(Literal(true)) == true
        @test toPython(Literal(false)) == false

        dt = DateTime(2024, 1, 15, 10, 30, 0)
        l = Literal(dt)
        @test datatype(l) == URIRef("http://www.w3.org/2001/XMLSchema#dateTime")
        @test toPython(l) == dt

        d = Date(2024, 1, 15)
        l = Literal(d)
        @test datatype(l) == URIRef("http://www.w3.org/2001/XMLSchema#date")
    end

    @testset "Literal - escaping" begin
        l = Literal("line1\nline2")
        @test n3(l) == "\"line1\\nline2\""
        l2 = Literal("say \"hi\"")
        @test n3(l2) == "\"say \\\"hi\\\"\""
    end

    @testset "Literal - lang/datatype exclusivity" begin
        @test_throws ArgumentError Literal("x", lang="en",
            datatype=URIRef("http://www.w3.org/2001/XMLSchema#string"))
    end

    @testset "Variable" begin
        v = Variable("x")
        @test string(v) == "x"
        @test n3(v) == "?x"

        # Strips leading ? or $
        v2 = Variable("?y")
        @test string(v2) == "y"
        v3 = Variable("\$z")
        @test string(v3) == "z"

        @test_throws ArgumentError Variable("?")
    end

    @testset "Triple" begin
        s = URIRef("http://example.org/s")
        p = URIRef("http://example.org/p")
        o = Literal("hello")
        t = Triple(s, p, o)
        @test t.subject == s
        @test t.predicate == p
        @test t.object == o
        @test t == Triple(s, p, o)
    end

    @testset "Ordering" begin
        b = BNode("x")
        u = URIRef("http://example.org/x")
        l = Literal("x")
        v = Variable("x")
        @test b < u < l < v
    end
end
