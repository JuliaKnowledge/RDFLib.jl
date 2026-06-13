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

    @testset "Literal - simple literal ≡ xsd:string (RDF 1.1)" begin
        plain = Literal("a")
        typed = Literal("a", datatype=URIRef("http://www.w3.org/2001/XMLSchema#string"))
        @test plain == typed
        @test hash(plain) == hash(typed)
        @test datatype(plain) === datatype(typed)
        # No ^^xsd:string emitted in N3/NT serialization
        @test n3(typed) == "\"a\""
        # Both usable interchangeably as Dict keys / in Sets
        @test length(Set([plain, typed])) == 1
        # Explicit rdf:langString on a language-tagged literal normalizes the same way
        ls = Literal("hi", lang="en",
                     datatype=URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#langString"))
        @test ls == Literal("hi", lang="en")
        @test n3(ls) == "\"hi\"@en"
    end

    @testset "Literal - base direction (SPARQL 1.2)" begin
        l = Literal("hello", lang="en", direction="ltr")
        @test direction(l) == "ltr"
        @test lang(l) == "en"
        @test l == Literal("hello", lang="en", direction="ltr")
        @test hash(l) == hash(Literal("hello", lang="en", direction="ltr"))
        @test l != Literal("hello", lang="en")
        @test l != Literal("hello", lang="en", direction="rtl")
        @test direction(Literal("hello", lang="en")) === nothing
        @test direction(Literal("hello")) === nothing
        @test repr(l) == "Literal(\"hello\", lang=\"en\", direction=\"ltr\")"
        @test n3(l) == "\"hello\"@en--ltr"
        # direction requires a language tag
        @test_throws ArgumentError Literal("hello", direction="ltr")
        # only "ltr"/"rtl" allowed
        @test_throws ArgumentError Literal("hello", lang="en", direction="up")
        # rdf:dirLangString is an acceptable explicit datatype for directional literals
        dls = Literal("hello", lang="en", direction="rtl",
                      datatype=URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#dirLangString"))
        @test dls == Literal("hello", lang="en", direction="rtl")
        # rdf:dirLangString is in the RDF namespace
        @test RDF.dirLangString == URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#dirLangString")
    end

    @testset "Literal - typed" begin
        l = Literal("42", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))
        @test n3(l) == "\"42\"^^<http://www.w3.org/2001/XMLSchema#integer>"
        @test convert(Any, l) == 42
    end

    @testset "Literal - auto-typed constructors" begin
        @test convert(Any, Literal(42)) == 42
        @test convert(Any, Literal(3.14)) == 3.14
        @test convert(Any, Literal(true)) == true
        @test convert(Any, Literal(false)) == false

        dt = DateTime(2024, 1, 15, 10, 30, 0)
        l = Literal(dt)
        @test datatype(l) == URIRef("http://www.w3.org/2001/XMLSchema#dateTime")
        @test convert(Any, l) == dt

        d = Date(2024, 1, 15)
        l = Literal(d)
        @test datatype(l) == URIRef("http://www.w3.org/2001/XMLSchema#date")
    end

    @testset "Literal - special float lexicals (xsd:double)" begin
        @test Literal(Inf).lexical == "INF"
        @test Literal(-Inf).lexical == "-INF"
        @test Literal(NaN).lexical == "NaN"
        @test Literal(Inf32).lexical == "INF"
        @test datatype(Literal(Inf)) == URIRef("http://www.w3.org/2001/XMLSchema#double")
        # value direction: INF/-INF/NaN lexicals convert back to floats
        dbl = URIRef("http://www.w3.org/2001/XMLSchema#double")
        @test convert(Any, Literal("INF", datatype=dbl)) == Inf
        @test convert(Any, Literal("-INF", datatype=dbl)) == -Inf
        @test isnan(convert(Any, Literal("NaN", datatype=dbl)))
        @test convert(Float64, Literal(Inf)) == Inf
        # round-trip
        @test convert(Any, Literal(-Inf)) == -Inf
    end

    @testset "Literal - dateTime fractional seconds" begin
        dt = DateTime(2020, 1, 1, 0, 0, 0, 123)
        l = Literal(dt)
        @test l.lexical == "2020-01-01T00:00:00.123"
        @test convert(Any, l) == dt
        # whole seconds keep the short form
        @test Literal(DateTime(2020, 1, 1)).lexical == "2020-01-01T00:00:00"
        # Time literals keep milliseconds too
        @test Literal(Time(10, 30, 0, 500)).lexical == "10:30:00.500"
        @test Literal(Time(10, 30, 0)).lexical == "10:30:00"
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
