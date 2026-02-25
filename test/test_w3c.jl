using Test
using RDFLib

# ═══════════════════════════════════════════════════════════════════════
# W3C-Style Conformance Test Suite for RDFLib.jl
#
# Inline test cases modeled after the W3C RDF test suites:
#   - N-Triples:  https://www.w3.org/2013/N-TriplesTests/
#   - Turtle:     https://www.w3.org/2013/TurtleTests/
#   - RDF/XML:    https://www.w3.org/2011/rdf-wg/wiki/RDF_Test_Suites
#   - N-Quads:    https://www.w3.org/2013/N-QuadsTests/
#   - TriG:       https://www.w3.org/2013/TriGTests/
#   - SPARQL:     https://www.w3.org/2009/sparql/docs/tests/
# ═══════════════════════════════════════════════════════════════════════

const EX = Namespace("http://example.org/")

@testset "W3C Conformance Tests" begin

# ─── N-TRIPLES ──────────────────────────────────────────────────────
@testset "W3C N-Triples" begin

    # ── Positive syntax tests ───────────────────────────────────────
    @testset "comment handling" begin
        g = parse_rdf("# comment\n<http://example.org/s> <http://example.org/p> <http://example.org/o> .\n", NTriplesFormat())
        @test length(g) == 1
    end

    @testset "empty file" begin
        g = parse_rdf("", NTriplesFormat())
        @test length(g) == 0
    end

    @testset "blank lines and comments only" begin
        g = parse_rdf("# comment\n\n# another\n\n", NTriplesFormat())
        @test length(g) == 0
    end

    @testset "multiple triples" begin
        nt = "<http://example.org/s1> <http://example.org/p> \"a\" .\n" *
             "<http://example.org/s2> <http://example.org/p> \"b\" .\n" *
             "<http://example.org/s3> <http://example.org/p> \"c\" .\n"
        g = parse_rdf(nt, NTriplesFormat())
        @test length(g) == 3
    end

    @testset "skip comments and blank lines between triples" begin
        nt = """
        # header comment

        <http://example.org/s> <http://example.org/p> "hello" .
        # middle comment

        <http://example.org/s2> <http://example.org/p> "world" .
        """
        g = parse_rdf(nt, NTriplesFormat())
        @test length(g) == 2
    end

    # ── String escapes ──────────────────────────────────────────────
    @testset "escape \\n (newline)" begin
        g = parse_rdf("<http://example.org/s> <http://example.org/p> \"line1\\nline2\" .\n", NTriplesFormat())
        obj = first(objects(g, URIRef("http://example.org/s"), URIRef("http://example.org/p")))
        @test string(obj) == "line1\nline2"
    end

    @testset "escape \\r (carriage return)" begin
        g = parse_rdf("<http://example.org/s> <http://example.org/p> \"a\\rb\" .\n", NTriplesFormat())
        obj = first(objects(g, URIRef("http://example.org/s"), URIRef("http://example.org/p")))
        @test string(obj) == "a\rb"
    end

    @testset "escape \\t (tab)" begin
        g = parse_rdf("<http://example.org/s> <http://example.org/p> \"a\\tb\" .\n", NTriplesFormat())
        obj = first(objects(g, URIRef("http://example.org/s"), URIRef("http://example.org/p")))
        @test string(obj) == "a\tb"
    end

    @testset "escape \\\\ (backslash)" begin
        g = parse_rdf("<http://example.org/s> <http://example.org/p> \"path\\\\to\" .\n", NTriplesFormat())
        obj = first(objects(g, URIRef("http://example.org/s"), URIRef("http://example.org/p")))
        @test string(obj) == "path\\to"
    end

    @testset "escape \\\" (double quote)" begin
        g = parse_rdf("<http://example.org/s> <http://example.org/p> \"say \\\"hello\\\"\" .\n", NTriplesFormat())
        obj = first(objects(g, URIRef("http://example.org/s"), URIRef("http://example.org/p")))
        @test string(obj) == "say \"hello\""
    end

    @testset "escape \\uXXXX (BMP unicode)" begin
        g = parse_rdf("<http://example.org/s> <http://example.org/p> \"caf\\u00E9\" .\n", NTriplesFormat())
        obj = first(objects(g, URIRef("http://example.org/s"), URIRef("http://example.org/p")))
        @test string(obj) == "café"
    end

    @testset "escape \\UXXXXXXXX (supplementary plane)" begin
        g = parse_rdf("<http://example.org/s> <http://example.org/p> \"\\U0001F600\" .\n", NTriplesFormat())
        obj = first(objects(g, URIRef("http://example.org/s"), URIRef("http://example.org/p")))
        @test string(obj) == "😀"
    end

    # ── Blank nodes ─────────────────────────────────────────────────
    @testset "blank node subject" begin
        g = parse_rdf("_:b1 <http://example.org/p> \"hello\" .\n", NTriplesFormat())
        @test length(g) == 1
        t = first(g)
        @test t.subject isa BNode
        @test t.subject == BNode("b1")
    end

    @testset "blank node object" begin
        g = parse_rdf("<http://example.org/s> <http://example.org/p> _:b2 .\n", NTriplesFormat())
        @test length(g) == 1
        @test first(g).object isa BNode
    end

    @testset "blank nodes in both positions" begin
        nt = "_:b1 <http://example.org/p> _:b2 .\n_:b2 <http://example.org/q> \"val\" .\n"
        g = parse_rdf(nt, NTriplesFormat())
        @test length(g) == 2
    end

    # ── Literals ────────────────────────────────────────────────────
    @testset "plain literal" begin
        g = parse_rdf("<http://example.org/s> <http://example.org/p> \"hello\" .\n", NTriplesFormat())
        obj = first(objects(g, URIRef("http://example.org/s"), URIRef("http://example.org/p")))
        @test string(obj) == "hello"
        @test lang(obj) === nothing
    end

    @testset "language-tagged literal" begin
        g = parse_rdf("<http://example.org/s> <http://example.org/p> \"bonjour\"@fr .\n", NTriplesFormat())
        obj = first(objects(g, URIRef("http://example.org/s"), URIRef("http://example.org/p")))
        @test lang(obj) == "fr"
        @test string(obj) == "bonjour"
    end

    @testset "datatyped literal (xsd:integer)" begin
        g = parse_rdf("<http://example.org/s> <http://example.org/p> \"42\"^^<http://www.w3.org/2001/XMLSchema#integer> .\n", NTriplesFormat())
        obj = first(objects(g, URIRef("http://example.org/s"), URIRef("http://example.org/p")))
        @test convert(Any, obj) == 42
        @test datatype(obj) == URIRef("http://www.w3.org/2001/XMLSchema#integer")
    end

    @testset "datatyped literal (xsd:boolean)" begin
        g = parse_rdf("<http://example.org/s> <http://example.org/p> \"true\"^^<http://www.w3.org/2001/XMLSchema#boolean> .\n", NTriplesFormat())
        obj = first(objects(g, URIRef("http://example.org/s"), URIRef("http://example.org/p")))
        @test convert(Any, obj) == true
    end

    @testset "datatyped literal (xsd:double)" begin
        g = parse_rdf("<http://example.org/s> <http://example.org/p> \"3.14\"^^<http://www.w3.org/2001/XMLSchema#double> .\n", NTriplesFormat())
        obj = first(objects(g, URIRef("http://example.org/s"), URIRef("http://example.org/p")))
        @test convert(Any, obj) ≈ 3.14
    end

    # ── Round-trip ──────────────────────────────────────────────────
    @testset "round-trip fidelity" begin
        g1 = RDFGraph()
        add!(g1, EX("alice"), RDF.type, EX("Person"))
        add!(g1, EX("alice"), RDFS.label, Literal("Alice", lang="en"))
        add!(g1, EX("alice"), EX("age"), Literal(30))
        add!(g1, BNode("x"), EX("p"), Literal("bnode subject"))
        nt = serialize(g1, NTriplesFormat())
        g2 = parse_rdf(nt, NTriplesFormat())
        @test length(g2) == length(g1)
        for t in g1
            @test t in g2
        end
    end
end

# ─── TURTLE ─────────────────────────────────────────────────────────
@testset "W3C Turtle" begin

    # ── Directive declarations ──────────────────────────────────────
    @testset "@base declaration" begin
        ttl = "@base <http://example.org/> .\n<alice> a <Person> .\n"
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 1
        t = first(g)
        @test t.subject == URIRef("http://example.org/alice")
        @test t.object == URIRef("http://example.org/Person")
    end

    @testset "SPARQL-style BASE declaration" begin
        ttl = "BASE <http://example.org/>\n<alice> a <Person> .\n"
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 1
        @test first(g).subject == URIRef("http://example.org/alice")
    end

    @testset "@prefix declaration" begin
        ttl = "@prefix ex: <http://example.org/> .\nex:alice a ex:Person .\n"
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 1
        @test first(g).subject == EX("alice")
        @test first(g).predicate == RDF.type
        @test first(g).object == EX("Person")
    end

    @testset "SPARQL-style PREFIX declaration" begin
        ttl = "PREFIX ex: <http://example.org/>\nex:alice a ex:Person .\n"
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 1
        @test first(g).predicate == RDF.type
    end

    @testset "empty prefix" begin
        ttl = "@prefix : <http://example.org/> .\n:alice a :Person .\n"
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 1
        @test first(g).subject == URIRef("http://example.org/alice")
    end

    @testset "multiple prefixes" begin
        ttl = """
        @prefix ex: <http://example.org/> .
        @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
        ex:alice rdfs:label "Alice" .
        """
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 1
        @test first(g).predicate == RDFS.label
    end

    # ── Abbreviated predicates ──────────────────────────────────────
    @testset "'a' shorthand for rdf:type" begin
        ttl = "@prefix ex: <http://example.org/> .\nex:alice a ex:Person .\n"
        g = parse_rdf(ttl, TurtleFormat())
        @test first(g).predicate == RDF.type
    end

    # ── Predicate lists (semicolons) ────────────────────────────────
    @testset "semicolons for predicate lists" begin
        ttl = """
        @prefix ex: <http://example.org/> .
        ex:alice a ex:Person ;
            ex:name "Alice" ;
            ex:age 42 .
        """
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 3
    end

    @testset "trailing semicolon" begin
        ttl = """
        @prefix ex: <http://example.org/> .
        ex:alice a ex:Person ;
            ex:name "Alice" ;
        .
        """
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 2
    end

    # ── Object lists (commas) ───────────────────────────────────────
    @testset "commas for object lists" begin
        ttl = "@prefix ex: <http://example.org/> .\nex:alice a ex:Person, ex:Agent .\n"
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 2
    end

    # ── Blank node syntax ───────────────────────────────────────────
    @testset "anonymous blank node []" begin
        ttl = """
        @prefix ex: <http://example.org/> .
        ex:alice ex:knows [ ex:name "Bob" ] .
        """
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 2
    end

    @testset "named blank node _:name" begin
        ttl = """
        @prefix ex: <http://example.org/> .
        _:b1 ex:name "Test" .
        _:b1 ex:age 42 .
        """
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 2
        subjs = unique([t.subject for t in g])
        @test length(subjs) == 1
        @test subjs[1] isa BNode
    end

    @testset "blank node with properties [p o]" begin
        ttl = """
        @prefix ex: <http://example.org/> .
        [ ex:name "Anon" ; ex:age 99 ] ex:status "active" .
        """
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 3
    end

    # ── Collection syntax ───────────────────────────────────────────
    @testset "RDF collection (item1 item2 item3)" begin
        ttl = """
        @prefix ex: <http://example.org/> .
        ex:list ex:items (ex:a ex:b ex:c) .
        """
        g = parse_rdf(ttl, TurtleFormat())
        # 1 main triple + 3 rdf:first + 3 rdf:rest = 7
        @test length(g) == 7
        # Last rdf:rest should point to rdf:nil
        nil = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
        rest = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
        rest_objs = collect(objects(g, nothing, rest))
        @test nil in rest_objs
    end

    @testset "empty collection ()" begin
        ttl = "@prefix ex: <http://example.org/> .\nex:s ex:list () .\n"
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 1
        nil = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
        @test first(g).object == nil
    end

    # ── String escapes and multi-line strings ───────────────────────
    @testset "multi-line string (triple quotes)" begin
        ttl = """
        @prefix ex: <http://example.org/> .
        ex:s ex:desc \"\"\"This is a
        multi-line string\"\"\" .
        """
        g = parse_rdf(ttl, TurtleFormat())
        obj = first(objects(g, EX("s"), EX("desc")))
        @test contains(string(obj), "\n")
    end

    @testset "escape sequences in Turtle strings" begin
        ttl = """
        @prefix ex: <http://example.org/> .
        ex:s ex:val "line1\\nline2" .
        """
        g = parse_rdf(ttl, TurtleFormat())
        obj = first(objects(g, EX("s"), EX("val")))
        @test string(obj) == "line1\nline2"
    end

    # ── Numeric literals ────────────────────────────────────────────
    @testset "integer literal" begin
        ttl = "@prefix ex: <http://example.org/> .\nex:s ex:val 42 .\n"
        g = parse_rdf(ttl, TurtleFormat())
        obj = first(objects(g, EX("s"), EX("val")))
        @test convert(Any, obj) == 42
        @test datatype(obj) == URIRef("http://www.w3.org/2001/XMLSchema#integer")
    end

    @testset "negative integer literal" begin
        ttl = "@prefix ex: <http://example.org/> .\nex:s ex:val -7 .\n"
        g = parse_rdf(ttl, TurtleFormat())
        obj = first(objects(g, EX("s"), EX("val")))
        @test convert(Any, obj) == -7
    end

    @testset "decimal literal" begin
        ttl = "@prefix ex: <http://example.org/> .\nex:s ex:val 3.14 .\n"
        g = parse_rdf(ttl, TurtleFormat())
        obj = first(objects(g, EX("s"), EX("val")))
        @test convert(Any, obj) ≈ 3.14
        @test datatype(obj) == URIRef("http://www.w3.org/2001/XMLSchema#decimal")
    end

    @testset "double literal (scientific notation)" begin
        ttl = "@prefix ex: <http://example.org/> .\nex:s ex:val 1.5e10 .\n"
        g = parse_rdf(ttl, TurtleFormat())
        obj = first(objects(g, EX("s"), EX("val")))
        @test datatype(obj) == URIRef("http://www.w3.org/2001/XMLSchema#double")
    end

    # ── Boolean literals ────────────────────────────────────────────
    @testset "boolean true" begin
        ttl = "@prefix ex: <http://example.org/> .\nex:s ex:active true .\n"
        g = parse_rdf(ttl, TurtleFormat())
        obj = first(objects(g, EX("s"), EX("active")))
        @test convert(Any, obj) == true
    end

    @testset "boolean false" begin
        ttl = "@prefix ex: <http://example.org/> .\nex:s ex:active false .\n"
        g = parse_rdf(ttl, TurtleFormat())
        obj = first(objects(g, EX("s"), EX("active")))
        @test convert(Any, obj) == false
    end

    # ── Datatyped literals ──────────────────────────────────────────
    @testset "explicit datatype annotation" begin
        ttl = """
        @prefix ex: <http://example.org/> .
        @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
        ex:s ex:val "42"^^xsd:integer .
        """
        g = parse_rdf(ttl, TurtleFormat())
        obj = first(objects(g, EX("s"), EX("val")))
        @test convert(Any, obj) == 42
    end

    # ── Language-tagged literals ────────────────────────────────────
    @testset "language tag" begin
        ttl = "@prefix ex: <http://example.org/> .\nex:s ex:label \"hello\"@en .\n"
        g = parse_rdf(ttl, TurtleFormat())
        obj = first(objects(g, EX("s"), EX("label")))
        @test lang(obj) == "en"
    end

    @testset "language subtag" begin
        ttl = "@prefix ex: <http://example.org/> .\nex:s ex:label \"colour\"@en-GB .\n"
        g = parse_rdf(ttl, TurtleFormat())
        obj = first(objects(g, EX("s"), EX("label")))
        # language tag is lowercased per spec
        @test lang(obj) == "en-gb"
    end

    # ── Comments ────────────────────────────────────────────────────
    @testset "comments" begin
        ttl = """
        @prefix ex: <http://example.org/> .
        # This is a comment
        ex:alice a ex:Person . # inline comment
        """
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 1
    end

    # ── Relative URIs with base ─────────────────────────────────────
    @testset "relative URIs resolved against @base" begin
        ttl = """
        @base <http://example.org/> .
        @prefix : <#> .
        <alice> a :Person .
        """
        g = parse_rdf(ttl, TurtleFormat())
        @test first(g).subject == URIRef("http://example.org/alice")
    end

    # ── Round-trip ──────────────────────────────────────────────────
    @testset "Turtle round-trip" begin
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

    @testset "serialization uses 'a' for rdf:type" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        ttl = serialize(g, TurtleFormat())
        @test contains(ttl, "a ex:Person")
    end

    @testset "serialization uses semicolons" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        add!(g, EX("alice"), RDFS.label, Literal("Alice"))
        add!(g, EX("alice"), EX("age"), Literal(30))
        ttl = serialize(g, TurtleFormat())
        @test contains(ttl, ";")
        @test count("ex:alice", ttl) == 1
    end

    @testset "serialization uses commas for object lists" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        add!(g, EX("alice"), RDF.type, EX("Agent"))
        ttl = serialize(g, TurtleFormat())
        @test contains(ttl, ",")
    end

    @testset "serialization uses bare integers" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("s"), EX("val"), Literal(42))
        ttl = serialize(g, TurtleFormat())
        @test contains(ttl, "42")
        @test !contains(ttl, "\"42\"")
    end
end

# ─── RDF/XML ────────────────────────────────────────────────────────
@testset "W3C RDF/XML" begin

    # ── Basic rdf:Description ───────────────────────────────────────
    @testset "basic rdf:Description with rdf:about" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/alice">
                <ex:name>Alice</ex:name>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 1
        @test first(g).subject == EX("alice")
    end

    # ── Typed nodes ─────────────────────────────────────────────────
    @testset "typed node (ex:Person instead of rdf:Description)" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <ex:Person rdf:about="http://example.org/alice">
                <ex:name>Alice</ex:name>
            </ex:Person>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 2
        type_objs = collect(objects(g, EX("alice"), RDF.type))
        @test EX("Person") in type_objs
    end

    # ── rdf:resource ────────────────────────────────────────────────
    @testset "rdf:resource for URI objects" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/alice">
                <ex:knows rdf:resource="http://example.org/bob"/>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 1
        @test first(g).object == EX("bob")
    end

    # ── rdf:type as element ─────────────────────────────────────────
    @testset "rdf:type as property element" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/alice">
                <rdf:type rdf:resource="http://example.org/Person"/>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 1
        @test first(g).predicate == RDF.type
        @test first(g).object == EX("Person")
    end

    # ── Datatypes via rdf:datatype ──────────────────────────────────
    @testset "rdf:datatype attribute" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/alice">
                <ex:age rdf:datatype="http://www.w3.org/2001/XMLSchema#integer">30</ex:age>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        obj = first(objects(g, EX("alice"), EX("age")))
        @test convert(Any, obj) == 30
        @test datatype(obj) == URIRef("http://www.w3.org/2001/XMLSchema#integer")
    end

    # ── Blank nodes via rdf:nodeID ──────────────────────────────────
    @testset "rdf:nodeID for blank nodes" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/alice">
                <ex:knows rdf:nodeID="b1"/>
            </rdf:Description>
            <rdf:Description rdf:nodeID="b1">
                <ex:name>Bob</ex:name>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 2
        knows_objs = collect(objects(g, EX("alice"), EX("knows")))
        @test length(knows_objs) == 1
        @test knows_objs[1] isa BNode
    end

    # ── Blank nodes via rdf:parseType="Resource" ────────────────────
    @testset "rdf:parseType=\"Resource\" (inline blank node)" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/alice">
                <ex:address rdf:parseType="Resource">
                    <ex:city>London</ex:city>
                </ex:address>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 2
    end

    # ── Collections via rdf:parseType="Collection" ──────────────────
    @testset "rdf:parseType=\"Collection\"" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/s">
                <ex:items rdf:parseType="Collection">
                    <rdf:Description rdf:about="http://example.org/a"/>
                    <rdf:Description rdf:about="http://example.org/b"/>
                </ex:items>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        # 1 main + 2 rdf:first + 2 rdf:rest = 5
        @test length(g) == 5
        nil = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
        rest = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
        rest_objs = collect(objects(g, nothing, rest))
        @test nil in rest_objs
    end

    # ── Nested descriptions ─────────────────────────────────────────
    @testset "nested rdf:Description" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/alice">
                <ex:knows>
                    <rdf:Description rdf:about="http://example.org/bob">
                        <ex:name>Bob</ex:name>
                    </rdf:Description>
                </ex:knows>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 2
        @test Triple(EX("alice"), EX("knows"), EX("bob")) in g
        name_objs = collect(objects(g, EX("bob"), EX("name")))
        @test length(name_objs) == 1
        @test string(name_objs[1]) == "Bob"
    end

    # ── Multiple properties ─────────────────────────────────────────
    @testset "multiple property elements" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/alice">
                <ex:name>Alice</ex:name>
                <ex:email>alice@example.org</ex:email>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 2
    end

    # ── Round-trip ──────────────────────────────────────────────────
    @testset "RDF/XML round-trip" begin
        g1 = RDFGraph()
        bind!(g1, "ex", EX)
        add!(g1, EX("alice"), RDF.type, EX("Person"))
        add!(g1, EX("alice"), RDFS.label, Literal("Alice"))
        add!(g1, EX("alice"), EX("knows"), EX("bob"))
        xml = serialize(g1, RDFXMLFormat())
        g2 = parse_rdf(xml, RDFXMLFormat())
        @test length(g2) == length(g1)
        for t in g1
            @test t in g2
        end
    end
end

# ─── N-QUADS ────────────────────────────────────────────────────────
@testset "W3C N-Quads" begin

    @testset "quad without named graph (default)" begin
        nq = "<http://example.org/s> <http://example.org/p> \"hello\" .\n"
        ds = parse_nquads(nq)
        @test length(ds) == 1
        @test length(get_graph(ds)) == 1
    end

    @testset "quad with named graph" begin
        nq = "<http://example.org/s> <http://example.org/p> \"hello\" <http://example.org/g1> .\n"
        ds = parse_nquads(nq)
        @test length(ds) == 1
        g1 = get_graph(ds, EX("g1"))
        @test !isnothing(g1)
        @test length(g1) == 1
    end

    @testset "mixed default and named graphs" begin
        nq = """
        <http://example.org/s> <http://example.org/p> "default" .
        <http://example.org/s> <http://example.org/p> "named" <http://example.org/g1> .
        """
        ds = parse_nquads(nq)
        @test length(ds) == 2
        @test length(get_graph(ds)) == 1
        @test length(get_graph(ds, EX("g1"))) == 1
    end

    @testset "multiple named graphs" begin
        nq = """
        <http://example.org/a> <http://example.org/p> "one" <http://example.org/g1> .
        <http://example.org/b> <http://example.org/p> "two" <http://example.org/g2> .
        """
        ds = parse_nquads(nq)
        @test length(ds) == 2
        @test length(get_graph(ds, EX("g1"))) == 1
        @test length(get_graph(ds, EX("g2"))) == 1
    end

    @testset "N-Quads round-trip" begin
        ds1 = Dataset()
        add!(ds1, EX("alice"), RDF.type, EX("Person"))
        add!(ds1, EX("bob"), RDF.type, EX("Person"), EX("people"))
        nq = serialize(ds1, NQuadsFormat())
        ds2 = parse_nquads(nq)
        @test length(ds2) == length(ds1)
    end

    @testset "N-Quads with language tag" begin
        nq = "<http://example.org/s> <http://example.org/p> \"hello\"@en <http://example.org/g> .\n"
        ds = parse_nquads(nq)
        g = get_graph(ds, EX("g"))
        obj = first(objects(g, URIRef("http://example.org/s"), URIRef("http://example.org/p")))
        @test lang(obj) == "en"
    end

    @testset "N-Quads with datatype" begin
        nq = "<http://example.org/s> <http://example.org/p> \"42\"^^<http://www.w3.org/2001/XMLSchema#integer> <http://example.org/g> .\n"
        ds = parse_nquads(nq)
        g = get_graph(ds, EX("g"))
        obj = first(objects(g, URIRef("http://example.org/s"), URIRef("http://example.org/p")))
        @test convert(Any, obj) == 42
    end
end

# ─── TRIG ───────────────────────────────────────────────────────────
@testset "W3C TriG" begin

    @testset "default graph" begin
        trig = """
        @prefix ex: <http://example.org/> .
        {
            ex:s ex:p "default" .
        }
        """
        ds = parse_trig(trig)
        @test length(get_graph(ds)) == 1
    end

    @testset "named graph" begin
        trig = """
        @prefix ex: <http://example.org/> .
        ex:g1 {
            ex:s ex:p "named" .
        }
        """
        ds = parse_trig(trig)
        g1 = get_graph(ds, EX("g1"))
        @test !isnothing(g1)
        @test length(g1) == 1
    end

    @testset "mixed default and named" begin
        trig = """
        @prefix ex: <http://example.org/> .
        {
            ex:s ex:p "default" .
        }
        ex:g1 {
            ex:a ex:p "one" .
        }
        """
        ds = parse_trig(trig)
        @test length(ds) == 2
        @test length(get_graph(ds)) == 1
        @test length(get_graph(ds, EX("g1"))) == 1
    end

    @testset "multiple named graphs" begin
        trig = """
        @prefix ex: <http://example.org/> .
        ex:g1 {
            ex:a ex:p "1" .
        }
        ex:g2 {
            ex:b ex:p "2" .
        }
        """
        ds = parse_trig(trig)
        @test length(ds) == 2
        @test length(get_graph(ds, EX("g1"))) == 1
        @test length(get_graph(ds, EX("g2"))) == 1
    end

    @testset "GRAPH keyword" begin
        trig = """
        @prefix ex: <http://example.org/> .
        GRAPH ex:g1 {
            ex:alice a ex:Person ;
                ex:name "Alice" .
        }
        """
        ds = parse_trig(trig)
        g1 = get_graph(ds, EX("g1"))
        @test !isnothing(g1)
        @test length(g1) == 2
    end

    @testset "TriG round-trip" begin
        ds1 = Dataset()
        bind!(ds1, "ex", EX)
        add!(ds1, EX("s"), EX("p"), Literal("default"))
        add!(ds1, EX("s"), EX("p"), Literal("named"), EX("g1"))
        trig = serialize(ds1, TriGFormat())
        ds2 = parse_trig(trig)
        @test length(ds2) == length(ds1)
    end
end

# ─── SPARQL ─────────────────────────────────────────────────────────
@testset "W3C SPARQL" begin

    # ── Shared test graph ───────────────────────────────────────────
    function w3c_test_graph()
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        add!(g, EX("alice"), RDFS.label, Literal("Alice", lang="en"))
        add!(g, EX("alice"), EX("age"), Literal(30))
        add!(g, EX("alice"), EX("knows"), EX("bob"))
        add!(g, EX("alice"), EX("email"), Literal("alice@example.org"))
        add!(g, EX("bob"), RDF.type, EX("Person"))
        add!(g, EX("bob"), RDFS.label, Literal("Bob", lang="en"))
        add!(g, EX("bob"), EX("age"), Literal(25))
        add!(g, EX("bob"), EX("knows"), EX("carol"))
        add!(g, EX("carol"), RDF.type, EX("Person"))
        add!(g, EX("carol"), RDFS.label, Literal("Carol", lang="fr"))
        add!(g, EX("carol"), EX("age"), Literal(35))
        add!(g, EX("org1"), RDF.type, EX("Organization"))
        add!(g, EX("org1"), RDFS.label, Literal("Acme Corp"))
        g
    end

    # ── Basic graph pattern matching ────────────────────────────────
    @testset "basic graph pattern - single triple" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            SELECT ?s WHERE {
                ?s <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://example.org/Person> .
            }
        """)
        @test length(results) == 3
    end

    @testset "basic graph pattern - join" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
            SELECT ?s ?name WHERE {
                ?s a ex:Person .
                ?s rdfs:label ?name .
            }
        """)
        @test length(results) == 3
        names = Set(string(r["name"]) for r in results)
        @test "Alice" in names
        @test "Bob" in names
        @test "Carol" in names
    end

    @testset "basic graph pattern - with 'a' shorthand" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE { ?s a ex:Person }
        """)
        @test length(results) == 3
    end

    @testset "SELECT * (all variables)" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT * WHERE {
                ?s a ex:Person .
                ?s ex:age ?age .
            }
        """)
        @test length(results) == 3
        @test all(r -> haskey(r, "s") && haskey(r, "age"), results)
    end

    @testset "no results" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE { ?s a ex:NonExistent }
        """)
        @test isempty(results)
    end

    # ── OPTIONAL patterns ───────────────────────────────────────────
    @testset "OPTIONAL - present binding" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?knows WHERE {
                ?s a ex:Person .
                OPTIONAL { ?s ex:knows ?knows }
            }
        """)
        @test length(results) == 3
        alice = filter(r -> r["s"] == EX("alice"), results)
        @test length(alice) == 1
        @test haskey(alice[1], "knows")
    end

    @testset "OPTIONAL - missing binding" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?email WHERE {
                ?s a ex:Person .
                OPTIONAL { ?s ex:email ?email }
            }
        """)
        @test length(results) == 3
        alice = filter(r -> r["s"] == EX("alice"), results)
        @test haskey(alice[1], "email")
    end

    # ── FILTER with comparison ──────────────────────────────────────
    @testset "FILTER = (equality)" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:Person .
                ?s ex:age ?age .
                FILTER (?age = 30)
            }
        """)
        @test length(results) == 1
        @test results[1]["s"] == EX("alice")
    end

    @testset "FILTER > (greater than)" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s ex:age ?age .
                FILTER (?age > 29)
            }
        """)
        subjects = Set(r["s"] for r in results)
        @test EX("alice") in subjects
        @test EX("carol") in subjects
        @test !(EX("bob") in subjects)
    end

    @testset "FILTER < (less than)" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s ex:age ?age .
                FILTER (?age < 30)
            }
        """)
        @test length(results) == 1
        @test results[1]["s"] == EX("bob")
    end

    @testset "FILTER != (not equal)" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ?type .
                FILTER (?type != ex:Person)
            }
        """)
        @test length(results) == 1
        @test results[1]["s"] == EX("org1")
    end

    @testset "FILTER && (logical AND)" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s ex:age ?age .
                FILTER (?age >= 25 && ?age <= 30)
            }
        """)
        @test length(results) == 2
    end

    @testset "FILTER || (logical OR)" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ?type .
                FILTER (?type = ex:Person || ?type = ex:Organization)
            }
        """)
        @test length(results) == 4
    end

    # ── FILTER with REGEX ───────────────────────────────────────────
    @testset "FILTER REGEX (case insensitive)" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
            SELECT ?s WHERE {
                ?s rdfs:label ?name .
                FILTER REGEX(?name, "ali", "i")
            }
        """)
        @test length(results) == 1
        @test results[1]["s"] == EX("alice")
    end

    # ── FILTER with BOUND ──────────────────────────────────────────
    @testset "FILTER BOUND" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?email WHERE {
                ?s a ex:Person .
                OPTIONAL { ?s ex:email ?email }
                FILTER (BOUND(?email))
            }
        """)
        @test length(results) == 1
        @test results[1]["s"] == EX("alice")
    end

    # ── FILTER with LANG ───────────────────────────────────────────
    @testset "FILTER LANG" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
            SELECT ?s WHERE {
                ?s rdfs:label ?name .
                FILTER (LANG(?name) = "en")
            }
        """)
        @test length(results) == 2
    end

    # ── FILTER with DATATYPE ────────────────────────────────────────
    @testset "FILTER DATATYPE" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s ex:age ?v .
                FILTER (DATATYPE(?v) = <http://www.w3.org/2001/XMLSchema#integer>)
            }
        """)
        @test length(results) == 3
    end

    # ── FILTER isURI / isLiteral / isBlank ──────────────────────────
    @testset "FILTER isURI" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?o WHERE {
                ex:alice ex:knows ?o .
                FILTER isURI(?o)
            }
        """)
        @test length(results) == 1
    end

    # ── UNION patterns ──────────────────────────────────────────────
    @testset "UNION" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                { ?s a ex:Person } UNION { ?s a ex:Organization }
            }
        """)
        subjects = Set(r["s"] for r in results)
        @test EX("alice") in subjects
        @test EX("bob") in subjects
        @test EX("carol") in subjects
        @test EX("org1") in subjects
    end

    # ── DISTINCT ────────────────────────────────────────────────────
    @testset "DISTINCT" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT DISTINCT ?type WHERE { ?s a ?type }
        """)
        types = [r["type"] for r in results]
        @test length(unique(types)) == length(types)
        @test length(types) == 2
    end

    # ── ORDER BY ────────────────────────────────────────────────────
    @testset "ORDER BY ASC" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?age WHERE {
                ?s ex:age ?age .
            } ORDER BY ASC(?age)
        """)
        @test length(results) == 3
        @test results[1]["age"] == Literal(25)
        @test results[3]["age"] == Literal(35)
    end

    @testset "ORDER BY DESC" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?age WHERE {
                ?s ex:age ?age .
            } ORDER BY DESC(?age)
        """)
        @test results[1]["age"] == Literal(35)
        @test results[3]["age"] == Literal(25)
    end

    # ── LIMIT and OFFSET ───────────────────────────────────────────
    @testset "LIMIT" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE { ?s a ex:Person } LIMIT 2
        """)
        @test length(results) == 2
    end

    @testset "LIMIT and OFFSET" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?age WHERE {
                ?s ex:age ?age .
            } ORDER BY ASC(?age) LIMIT 2 OFFSET 1
        """)
        @test length(results) == 2
        @test results[1]["age"] == Literal(30)
        @test results[2]["age"] == Literal(35)
    end

    # ── ASK queries ─────────────────────────────────────────────────
    @testset "ASK - true" begin
        g = w3c_test_graph()
        result = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            ASK { ex:alice a ex:Person }
        """)
        @test result === true
    end

    @testset "ASK - false" begin
        g = w3c_test_graph()
        result = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            ASK { ex:alice a ex:Animal }
        """)
        @test result === false
    end

    # ── CONSTRUCT queries ───────────────────────────────────────────
    @testset "CONSTRUCT" begin
        g = w3c_test_graph()
        result = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
            CONSTRUCT {
                ?s rdfs:label ?name .
            } WHERE {
                ?s a ex:Person .
                ?s rdfs:label ?name .
            }
        """)
        @test result isa RDFGraph
        @test length(result) == 3
    end

    @testset "CONSTRUCT with new predicate" begin
        g = w3c_test_graph()
        result = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            CONSTRUCT {
                ?s ex:displayName ?n .
            } WHERE {
                ?s a ex:Person .
                ?s ex:age ?n .
            }
        """)
        @test result isa RDFGraph
        @test length(result) == 3
    end

    # ── Aggregates ──────────────────────────────────────────────────
    @testset "COUNT" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (COUNT(?s) AS ?count) WHERE {
                ?s a ex:Person .
            }
        """)
        @test length(results) == 1
        @test convert(Any, results[1]["count"]) == 3
    end

    @testset "SUM" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (SUM(?age) AS ?total) WHERE {
                ?s ex:age ?age .
            }
        """)
        @test length(results) == 1
        @test convert(Any, results[1]["total"]) == 90
    end

    @testset "AVG" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (AVG(?age) AS ?avg) WHERE {
                ?s ex:age ?age .
            }
        """)
        @test length(results) == 1
        @test convert(Any, results[1]["avg"]) ≈ 30.0
    end

    @testset "MIN" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (MIN(?age) AS ?youngest) WHERE {
                ?s ex:age ?age .
            }
        """)
        @test length(results) == 1
        @test convert(Any, results[1]["youngest"]) == 25
    end

    @testset "MAX" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (MAX(?age) AS ?oldest) WHERE {
                ?s ex:age ?age .
            }
        """)
        @test length(results) == 1
        @test convert(Any, results[1]["oldest"]) == 35
    end

    # ── GROUP BY ────────────────────────────────────────────────────
    @testset "GROUP BY with COUNT" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?type (COUNT(?s) AS ?count) WHERE {
                ?s a ?type .
            } GROUP BY ?type
        """)
        @test length(results) == 2
        for r in results
            if r["type"] == EX("Person")
                @test convert(Any, r["count"]) == 3
            elseif r["type"] == EX("Organization")
                @test convert(Any, r["count"]) == 1
            end
        end
    end

    @testset "GROUP_CONCAT" begin
        g = RDFGraph()
        add!(g, EX("a"), EX("tag"), Literal("x"))
        add!(g, EX("a"), EX("tag"), Literal("y"))
        results = sparql_query(g, """
            SELECT ?s (GROUP_CONCAT(?t) AS ?tags) WHERE {
                ?s <http://example.org/tag> ?t .
            } GROUP BY ?s
        """)
        @test length(results) == 1
        tags_str = string(results[1]["tags"])
        @test contains(tags_str, "x")
        @test contains(tags_str, "y")
    end

    # ── Subqueries ──────────────────────────────────────────────────
    @testset "subquery" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?name WHERE {
                {
                    SELECT ?s WHERE {
                        ?s a ex:Person .
                    }
                }
                ?s <http://www.w3.org/2000/01/rdf-schema#label> ?name .
            }
        """)
        @test length(results) == 3
    end

    # ── Property paths ──────────────────────────────────────────────
    @testset "property path - sequence (/)" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
            SELECT ?name WHERE {
                ex:alice ex:knows/rdfs:label ?name .
            }
        """)
        @test length(results) >= 1
        names = [string(r["name"]) for r in results]
        @test "Bob" in names
    end

    @testset "property path - alternative (|)" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
            SELECT ?val WHERE {
                ex:alice rdfs:label|ex:age ?val .
            }
        """)
        @test length(results) == 2
    end

    @testset "property path - inverse (^)" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ex:bob ^ex:knows ?s .
            }
        """)
        @test length(results) == 1
        @test results[1]["s"] == EX("alice")
    end

    @testset "property path - zero-or-more (*)" begin
        g = RDFGraph()
        add!(g, Triple(EX("a"), EX("next"), EX("b")))
        add!(g, Triple(EX("b"), EX("next"), EX("c")))
        results = sparql_query(g, """
            SELECT ?end WHERE {
                <http://example.org/a> <http://example.org/next>* ?end .
            }
        """)
        ends = Set(r["end"] for r in results)
        @test EX("a") in ends
        @test EX("b") in ends
        @test EX("c") in ends
    end

    @testset "property path - one-or-more (+)" begin
        g = RDFGraph()
        add!(g, Triple(EX("a"), EX("next"), EX("b")))
        add!(g, Triple(EX("b"), EX("next"), EX("c")))
        add!(g, Triple(EX("c"), EX("next"), EX("d")))
        results = sparql_query(g, """
            SELECT ?end WHERE {
                <http://example.org/a> <http://example.org/next>+ ?end .
            }
        """)
        ends = Set(r["end"] for r in results)
        @test EX("b") in ends
        @test EX("c") in ends
        @test EX("d") in ends
        @test !(EX("a") in ends)
    end

    # ── BIND and VALUES ─────────────────────────────────────────────
    @testset "BIND" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?label WHERE {
                ?s a ex:Person .
                BIND(<http://example.org/Person> AS ?label)
            }
        """)
        @test length(results) == 3
        @test all(r -> r["label"] == EX("Person"), results)
    end

    @testset "VALUES single variable" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?name WHERE {
                VALUES ?s { ex:alice ex:bob }
                ?s <http://www.w3.org/2000/01/rdf-schema#label> ?name .
            }
        """)
        @test length(results) == 2
        names = Set(string(r["name"]) for r in results)
        @test "Alice" in names
        @test "Bob" in names
    end

    @testset "VALUES multi variable" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?type WHERE {
                VALUES (?s ?type) { (ex:alice ex:Person) (ex:org1 ex:Organization) }
                ?s a ?type .
            }
        """)
        @test length(results) == 2
    end

    # ── MINUS and NOT EXISTS / EXISTS ───────────────────────────────
    @testset "MINUS" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:Person .
                MINUS { ?s ex:knows ?other }
            }
        """)
        subjects = Set(r["s"] for r in results)
        @test EX("carol") in subjects
        @test !(EX("alice") in subjects)
    end

    @testset "FILTER NOT EXISTS" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:Person .
                FILTER NOT EXISTS { ?s ex:knows ?other }
            }
        """)
        subjects = Set(r["s"] for r in results)
        @test EX("carol") in subjects
        @test !(EX("alice") in subjects)
    end

    @testset "FILTER EXISTS" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:Person .
                FILTER EXISTS { ?s ex:knows ?other }
            }
        """)
        subjects = Set(r["s"] for r in results)
        @test EX("alice") in subjects
        @test EX("bob") in subjects
        @test !(EX("carol") in subjects)
    end

    @testset "MINUS vs NOT EXISTS equivalence" begin
        g = w3c_test_graph()
        r1 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:Person .
                MINUS { ?s ex:knows ?o }
            }
        """)
        r2 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:Person .
                FILTER NOT EXISTS { ?s ex:knows ?o }
            }
        """)
        @test Set(r["s"] for r in r1) == Set(r["s"] for r in r2)
    end

    # ── DESCRIBE ────────────────────────────────────────────────────
    @testset "DESCRIBE URI" begin
        g = w3c_test_graph()
        result = sparql_query(g, "DESCRIBE <http://example.org/alice>")
        @test result isa RDFGraph
        @test length(result) >= 4
    end

    @testset "DESCRIBE with WHERE" begin
        g = w3c_test_graph()
        result = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            DESCRIBE ?s WHERE { ?s a ex:Person }
        """)
        @test result isa RDFGraph
        @test length(result) >= 4
    end

    # ── SPARQL string functions in FILTER ───────────────────────────
    @testset "FILTER CONTAINS" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            SELECT ?s ?name WHERE {
                ?s <http://www.w3.org/2000/01/rdf-schema#label> ?name .
                FILTER CONTAINS(?name, "li")
            }
        """)
        @test length(results) >= 1
    end

    @testset "FILTER STRSTARTS" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            SELECT ?s WHERE {
                ?s <http://www.w3.org/2000/01/rdf-schema#label> ?name .
                FILTER STRSTARTS(?name, "Al")
            }
        """)
        @test length(results) == 1
        @test results[1]["s"] == EX("alice")
    end

    @testset "FILTER STRENDS" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            SELECT ?s WHERE {
                ?s <http://www.w3.org/2000/01/rdf-schema#label> ?name .
                FILTER STRENDS(?name, "ob")
            }
        """)
        @test length(results) == 1
        @test results[1]["s"] == EX("bob")
    end

    @testset "FILTER isNUMERIC" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?v WHERE {
                ?s ex:age ?v .
                FILTER isNUMERIC(?v)
            }
        """)
        @test length(results) == 3
    end

    @testset "FILTER IN" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:Person .
                FILTER (?s IN (ex:alice, ex:bob))
            }
        """)
        @test length(results) == 2
    end

    @testset "FILTER NOT IN" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:Person .
                FILTER (?s NOT IN (ex:alice, ex:bob))
            }
        """)
        @test length(results) == 1
        @test results[1]["s"] == EX("carol")
    end

    # ── BIND expressions ────────────────────────────────────────────
    @testset "BIND IF()" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?cat WHERE {
                ?s a ex:Person .
                ?s ex:age ?age .
                BIND(IF(?age > 29, "senior", "junior") AS ?cat)
            }
        """)
        @test length(results) == 3
        cats = Dict(r["s"] => string(r["cat"]) for r in results)
        @test cats[EX("alice")] == "senior"
        @test cats[EX("bob")] == "junior"
        @test cats[EX("carol")] == "senior"
    end

    @testset "BIND STRLEN" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            SELECT ?s ?len WHERE {
                ?s <http://www.w3.org/2000/01/rdf-schema#label> ?name .
                BIND(STRLEN(?name) AS ?len)
            }
        """)
        lens = Dict(r["s"] => convert(Any, r["len"]) for r in results if haskey(r, "len"))
        @test lens[EX("alice")] == 5
        @test lens[EX("bob")] == 3
    end

    @testset "BIND UCASE" begin
        g = w3c_test_graph()
        results = sparql_query(g, """
            SELECT ?s ?upper WHERE {
                ?s <http://www.w3.org/2000/01/rdf-schema#label> ?name .
                BIND(UCASE(?name) AS ?upper)
            }
        """)
        uppers = Set(string(r["upper"]) for r in results if haskey(r, "upper"))
        @test "ALICE" in uppers || "BOB" in uppers
    end

    @testset "BIND REPLACE" begin
        g = RDFGraph()
        add!(g, EX("x"), EX("val"), Literal("hello world"))
        results = sparql_query(g, """
            SELECT ?new WHERE {
                <http://example.org/x> <http://example.org/val> ?v .
                BIND(REPLACE(?v, "world", "Julia") AS ?new)
            }
        """)
        @test length(results) == 1
        @test string(results[1]["new"]) == "hello Julia"
    end

    @testset "BIND COALESCE" begin
        g = RDFGraph()
        add!(g, EX("x"), EX("name"), Literal("test"))
        results = sparql_query(g, """
            SELECT ?val WHERE {
                <http://example.org/x> <http://example.org/name> ?name .
                BIND(COALESCE(?missing, ?name) AS ?val)
            }
        """)
        @test length(results) == 1
        @test string(results[1]["val"]) == "test"
    end

    # ── SPARQL UPDATE ───────────────────────────────────────────────
    @testset "INSERT DATA" begin
        g = RDFGraph()
        sparql_update(g, """
            PREFIX ex: <http://example.org/>
            INSERT DATA {
                ex:x ex:p ex:y .
                ex:x ex:q "hello" .
            }
        """)
        @test length(g) == 2
        @test Triple(EX("x"), EX("p"), EX("y")) in g
    end

    @testset "DELETE DATA" begin
        g = RDFGraph()
        add!(g, EX("x"), EX("p"), Literal("val"))
        add!(g, EX("y"), EX("p"), Literal("keep"))
        sparql_update(g, """
            DELETE DATA {
                <http://example.org/x> <http://example.org/p> "val" .
            }
        """)
        @test length(g) == 1
        @test !(Triple(EX("x"), EX("p"), Literal("val")) in g)
    end

    @testset "DELETE WHERE (pattern)" begin
        g = w3c_test_graph()
        sparql_update(g, """
            PREFIX ex: <http://example.org/>
            DELETE { ?s ex:age ?age } WHERE { ?s ex:age ?age }
        """)
        results = sparql_query(g, "SELECT ?s WHERE { ?s <http://example.org/age> ?age }")
        @test isempty(results)
    end

    @testset "INSERT WHERE (pattern)" begin
        g = w3c_test_graph()
        sparql_update(g, """
            PREFIX ex: <http://example.org/>
            INSERT { ?s ex:status ex:active }
            WHERE { ?s a ex:Person }
        """)
        results = sparql_query(g, """
            SELECT ?s WHERE {
                ?s <http://example.org/status> <http://example.org/active> .
            }
        """)
        @test length(results) == 3
    end

    @testset "DELETE INSERT WHERE (modify)" begin
        g = RDFGraph()
        add!(g, EX("x"), EX("status"), EX("draft"))
        sparql_update(g, """
            PREFIX ex: <http://example.org/>
            DELETE { ?s ex:status ex:draft }
            INSERT { ?s ex:status ex:published }
            WHERE { ?s ex:status ex:draft }
        """)
        @test !(Triple(EX("x"), EX("status"), EX("draft")) in g)
        @test Triple(EX("x"), EX("status"), EX("published")) in g
    end

    @testset "CLEAR ALL" begin
        g = w3c_test_graph()
        @test length(g) > 0
        sparql_update(g, "CLEAR ALL")
        @test length(g) == 0
    end

    # ── Cross-format verification ───────────────────────────────────
    @testset "NT ↔ Turtle equivalence" begin
        nt = """
        <http://example.org/alice> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://example.org/Person> .
        <http://example.org/alice> <http://www.w3.org/2000/01/rdf-schema#label> "Alice" .
        <http://example.org/alice> <http://example.org/age> "30"^^<http://www.w3.org/2001/XMLSchema#integer> .
        """
        ttl = """
        @prefix ex: <http://example.org/> .
        @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
        @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
        ex:alice a ex:Person ;
            rdfs:label "Alice" ;
            ex:age 30 .
        """
        g_nt = parse_rdf(nt, NTriplesFormat())
        g_ttl = parse_rdf(ttl, TurtleFormat())
        @test length(g_nt) == length(g_ttl)
        for t in g_nt
            @test t in g_ttl
        end
    end

    @testset "NT ↔ RDF/XML equivalence" begin
        nt = """
        <http://example.org/alice> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://example.org/Person> .
        <http://example.org/alice> <http://example.org/name> "Alice" .
        """
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <ex:Person rdf:about="http://example.org/alice">
                <ex:name>Alice</ex:name>
            </ex:Person>
        </rdf:RDF>"""
        g_nt = parse_rdf(nt, NTriplesFormat())
        g_xml = parse_rdf(xml, RDFXMLFormat())
        @test length(g_nt) == length(g_xml)
        for t in g_nt
            @test t in g_xml
        end
    end

    @testset "Turtle → NT → Turtle round-trip" begin
        ttl_in = """
        @prefix ex: <http://example.org/> .
        ex:alice a ex:Person ;
            ex:name "Alice" ;
            ex:age 30 ;
            ex:knows ex:bob .
        ex:bob a ex:Person .
        """
        g1 = parse_rdf(ttl_in, TurtleFormat())
        nt = serialize(g1, NTriplesFormat())
        g2 = parse_rdf(nt, NTriplesFormat())
        ttl_out = serialize(g2, TurtleFormat())
        g3 = parse_rdf(ttl_out, TurtleFormat())
        @test length(g1) == length(g3)
        for t in g1
            @test t in g3
        end
    end
end

end # W3C Conformance Tests
