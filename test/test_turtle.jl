using Test
using RDFLib

@testset "Turtle" begin
    EX = Namespace("http://example.org/")

    @testset "serialization - basic" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        add!(g, EX("alice"), RDFS.label, Literal("Alice"))
        ttl = serialize(g, TurtleFormat())

        @test contains(ttl, "@prefix")
        @test contains(ttl, "ex:alice")
        @test contains(ttl, "a ex:Person")  # rdf:type → a
        @test contains(ttl, "\"Alice\"")
    end

    @testset "serialization - grouped predicates" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        add!(g, EX("alice"), RDFS.label, Literal("Alice"))
        add!(g, EX("alice"), EX("age"), Literal(30))
        ttl = serialize(g, TurtleFormat())

        # Should use semicolons to group predicates
        @test contains(ttl, ";")
        @test count("ex:alice", ttl) == 1  # subject appears once
    end

    @testset "serialization - multiple objects" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        add!(g, EX("alice"), RDF.type, EX("Agent"))
        ttl = serialize(g, TurtleFormat())

        # Should use commas for multiple objects of same predicate
        @test contains(ttl, ",")
    end

    @testset "serialization - numeric shorthand" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), EX("age"), Literal(42))
        ttl = serialize(g, TurtleFormat())

        # Integer literals should be bare numbers
        @test contains(ttl, "42")
        @test !contains(ttl, "\"42\"")
    end

    @testset "serialization - boolean shorthand" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), EX("active"), Literal(true))
        ttl = serialize(g, TurtleFormat())
        @test contains(ttl, "true")
    end

    @testset "serialization - preserve xsd:double lexical form" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        double_dt = URIRef("http://www.w3.org/2001/XMLSchema#double")
        original = Literal("88.0", datatype=double_dt)
        add!(g, EX("alice"), EX("score"), original)

        ttl = serialize(g, TurtleFormat())
        @test contains(ttl, "\"88.0\"")
        @test !contains(ttl, "88.0e0")

        roundtrip = parse_rdf(ttl, TurtleFormat())
        parsed = first(objects(roundtrip, EX("alice"), EX("score")))
        @test parsed == original
    end

    @testset "serialization - language tag" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDFS.label, Literal("Alice", lang="en"))
        ttl = serialize(g, TurtleFormat())
        @test contains(ttl, "\"Alice\"@en")
    end

    @testset "parsing - prefixes" begin
        ttl = """
        @prefix ex: <http://example.org/> .
        @prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .

        ex:alice rdf:type ex:Person .
        """
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 1
        t = first(g)
        @test t.subject == EX("alice")
        @test t.predicate == RDF.type
        @test t.object == EX("Person")
    end

    @testset "parsing - SPARQL-style PREFIX" begin
        ttl = """
        PREFIX ex: <http://example.org/>

        ex:alice a ex:Person .
        """
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 1
        t = first(g)
        @test t.predicate == RDF.type
    end

    @testset "parsing - semicolons" begin
        ttl = """
        @prefix ex: <http://example.org/> .

        ex:alice a ex:Person ;
            ex:name "Alice" ;
            ex:age 42 .
        """
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 3
    end

    @testset "parsing - commas" begin
        ttl = """
        @prefix ex: <http://example.org/> .

        ex:alice a ex:Person, ex:Agent .
        """
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 2
    end

    @testset "parsing - blank nodes" begin
        ttl = """
        @prefix ex: <http://example.org/> .

        ex:alice ex:knows [ ex:name "Bob" ] .
        """
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 2  # alice knows _:b, _:b name "Bob"
    end

    @testset "parsing - collections" begin
        ttl = """
        @prefix ex: <http://example.org/> .

        ex:list ex:items (ex:a ex:b ex:c) .
        """
        g = parse_rdf(ttl, TurtleFormat())
        # 1 main triple + 3 rdf:first + 3 rdf:rest = 7
        @test length(g) == 7
    end

    @testset "parsing - literals with datatypes" begin
        ttl = """
        @prefix ex: <http://example.org/> .
        @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

        ex:s ex:age "42"^^xsd:integer .
        """
        g = parse_rdf(ttl, TurtleFormat())
        objs = collect(objects(g, EX("s"), EX("age")))
        @test length(objs) == 1
        @test convert(Any, objs[1]) == 42
    end

    @testset "parsing - language tags" begin
        ttl = """
        @prefix ex: <http://example.org/> .

        ex:s ex:label "hello"@en .
        """
        g = parse_rdf(ttl, TurtleFormat())
        objs = collect(objects(g, EX("s"), EX("label")))
        @test length(objs) == 1
        @test lang(objs[1]) == "en"
    end

    @testset "parsing - numeric literals" begin
        ttl = """
        @prefix ex: <http://example.org/> .

        ex:s ex:int 42 ;
            ex:decimal 3.14 ;
            ex:double 1.5e10 ;
            ex:bool true .
        """
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 4

        int_val = first(objects(g, EX("s"), EX("int")))
        @test convert(Any, int_val) == 42

        dec_val = first(objects(g, EX("s"), EX("decimal")))
        @test convert(Any, dec_val) ≈ 3.14

        bool_val = first(objects(g, EX("s"), EX("bool")))
        @test convert(Any, bool_val) == true
    end

    @testset "parsing - long strings" begin
        ttl = """
        @prefix ex: <http://example.org/> .

        ex:s ex:desc \"\"\"This is a
        multi-line string\"\"\" .
        """
        g = parse_rdf(ttl, TurtleFormat())
        objs = collect(objects(g, EX("s"), EX("desc")))
        @test length(objs) == 1
        @test contains(string(objs[1]), "\n")
    end

    @testset "parsing - empty prefix" begin
        ttl = """
        @prefix : <http://example.org/> .

        :alice a :Person .
        """
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 1
        t = first(g)
        @test t.subject == URIRef("http://example.org/alice")
    end

    @testset "parsing - comments" begin
        ttl = """
        @prefix ex: <http://example.org/> .
        # This is a comment
        ex:alice a ex:Person . # inline comment
        """
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 1
    end

    @testset "parsing - trailing semicolon" begin
        ttl = """
        @prefix ex: <http://example.org/> .

        ex:alice a ex:Person ;
            ex:name "Alice" ;
        .
        """
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 2
    end

    @testset "round-trip" begin
        g1 = RDFGraph()
        bind!(g1, "ex", EX)
        add!(g1, EX("alice"), RDF.type, EX("Person"))
        add!(g1, EX("alice"), RDFS.label, Literal("Alice", lang="en"))
        add!(g1, EX("alice"), EX("age"), Literal(30))
        add!(g1, EX("bob"), RDF.type, EX("Person"))
        add!(g1, EX("alice"), EX("knows"), EX("bob"))

        ttl = serialize(g1, TurtleFormat())
        g2 = parse_rdf(ttl, TurtleFormat())

        @test length(g2) == length(g1)
        for t in g1
            @test t in g2
        end
    end

    @testset "RDF 1.2 version directive and reifier ids" begin
        reifies = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#reifies")
        EXV = Namespace("http://example/")
        # version directives (SPARQL-style and Turtle-style) are accepted/ignored
        for v in ("PREFIX : <http://example/>\nVERSION \"1.2\"\n:s :p :o .",
                  "PREFIX : <http://example/>\n@version \"1.2\" .\n:s :p :o .",
                  "PREFIX : <http://example/>\nversion '1.2-basic'\n:s :p :o .")
            g = RDFLib.parse_turtle(v)
            @test Triple(EXV("s"), EXV("p"), EXV("o")) in g
        end
        # bad version values are rejected
        @test_throws ArgumentError RDFLib.parse_turtle("VERSION 1.2\n")
        @test_throws ArgumentError RDFLib.parse_turtle("@version \"\"\"1.2\"\"\" .\n")

        # explicit reifier id binds the reifier resource
        g = RDFLib.parse_turtle("PREFIX : <http://example/>\n<< :s :p :o ~ :i >> :q :z .")
        @test Triple(EXV("i"), reifies, TripleTerm(EXV("s"), EXV("p"), EXV("o"))) in g
        @test Triple(EXV("i"), EXV("q"), EXV("z")) in g

        # annotation with explicit reifier id
        g2 = RDFLib.parse_turtle("PREFIX : <http://example/>\n:s :p :o ~ :i {| :r :z |} .")
        @test Triple(EXV("s"), EXV("p"), EXV("o")) in g2
        @test Triple(EXV("i"), reifies, TripleTerm(EXV("s"), EXV("p"), EXV("o"))) in g2
        @test Triple(EXV("i"), EXV("r"), EXV("z")) in g2

        # triple term as statement subject is rejected
        @test_throws ArgumentError RDFLib.parse_turtle("PREFIX : <http://example/>\n<<( :s :p :o )>> :q :z .")
    end
end
