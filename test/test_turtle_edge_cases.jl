using Test
using RDFLib

@testset "Turtle Edge Cases" begin
    EX = Namespace("http://example.org/")

    # ── 1. String quoting & escape sequences ──────────────────────────
    @testset "string quoting" begin
        @testset "escaped newline in literal" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:p "line1\\nline2" .
            """
            g = parse_rdf(ttl, TurtleFormat())
            obj = first(objects(g, EX("s"), EX("p")))
            @test string(obj) == "line1\nline2"
        end

        @testset "escaped tab in literal" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:p "col1\\tcol2" .
            """
            g = parse_rdf(ttl, TurtleFormat())
            obj = first(objects(g, EX("s"), EX("p")))
            @test string(obj) == "col1\tcol2"
        end

        @testset "escaped backslash in literal" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:p "path\\\\to\\\\file" .
            """
            g = parse_rdf(ttl, TurtleFormat())
            obj = first(objects(g, EX("s"), EX("p")))
            @test string(obj) == "path\\to\\file"
        end

        @testset "escaped quote in literal" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:p "He said \\"hello\\"" .
            """
            g = parse_rdf(ttl, TurtleFormat())
            obj = first(objects(g, EX("s"), EX("p")))
            @test string(obj) == "He said \"hello\""
        end

        @testset "single-quoted string" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:p 'single quoted' .
            """
            g = parse_rdf(ttl, TurtleFormat())
            obj = first(objects(g, EX("s"), EX("p")))
            @test string(obj) == "single quoted"
        end

        @testset "long string accepts 4-quote close run" begin
            ttl = "@prefix ex: <http://example.org/> .\nex:s ex:p \"\"\"a\"\"\"\" .\n"
            g = parse_rdf(ttl, TurtleFormat())
            obj = first(objects(g, EX("s"), EX("p")))
            @test string(obj) == "a\""
        end
    end

    # ── 2. PName escaping ─────────────────────────────────────────────
    @testset "prefixed name escaping" begin
        @testset "underscore in local name" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:some_thing a ex:Type .
            """
            g = parse_rdf(ttl, TurtleFormat())
            t = first(g)
            @test t.subject == URIRef("http://example.org/some_thing")
        end

        @testset "hyphen in local name" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:some-thing a ex:Type .
            """
            g = parse_rdf(ttl, TurtleFormat())
            t = first(g)
            @test t.subject == URIRef("http://example.org/some-thing")
        end

        @testset "digits in local name" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:item42 a ex:Type .
            """
            g = parse_rdf(ttl, TurtleFormat())
            t = first(g)
            @test t.subject == URIRef("http://example.org/item42")
        end
    end

    # ── 3. Collection syntax ──────────────────────────────────────────
    @testset "collection syntax" begin
        @testset "empty collection" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:list () .
            """
            g = parse_rdf(ttl, TurtleFormat())
            @test length(g) == 1
            t = first(g)
            @test t.object == URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
        end

        @testset "single-element collection" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:list (ex:a) .
            """
            g = parse_rdf(ttl, TurtleFormat())
            # 1 main + 1 rdf:first + 1 rdf:rest = 3
            @test length(g) == 3
        end

        @testset "collection with literals" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:list ("one" "two" "three") .
            """
            g = parse_rdf(ttl, TurtleFormat())
            # 1 main + 3 rdf:first + 3 rdf:rest = 7
            @test length(g) == 7
        end
    end

    # ── 4. Base URI ───────────────────────────────────────────────────
    @testset "base URI" begin
        @testset "base with relative URIs" begin
            ttl = """
            @base <http://example.org/> .
            <alice> a <Person> .
            """
            g = parse_rdf(ttl, TurtleFormat())
            @test length(g) == 1
            t = first(g)
            @test t.subject == URIRef("http://example.org/alice")
            @test t.object == URIRef("http://example.org/Person")
        end

        @testset "SPARQL-style BASE" begin
            ttl = """
            BASE <http://example.org/>
            PREFIX ex: <http://example.org/>
            <alice> a ex:Person .
            """
            g = parse_rdf(ttl, TurtleFormat())
            @test length(g) == 1
            t = first(g)
            @test t.subject == URIRef("http://example.org/alice")
        end

        @testset "base with fragment" begin
            ttl = """
            @base <http://example.org/doc> .
            <#frag> a <Type> .
            """
            g = parse_rdf(ttl, TurtleFormat())
            t = first(g)
            @test t.subject == URIRef("http://example.org/doc#frag")
        end

        @testset "base normalizes parent segments" begin
            ttl = """
            @base <http://example.org/dir/file> .
            <../x> <p> <q> .
            """
            g = parse_rdf(ttl, TurtleFormat())
            t = first(g)
            @test t.subject == URIRef("http://example.org/x")
            @test t.predicate == URIRef("http://example.org/dir/p")
            @test t.object == URIRef("http://example.org/dir/q")
        end

        @testset "empty relative reference resolves to base" begin
            ttl = """
            @base <http://example.org/dir/file> .
            <> a <Thing> .
            """
            g = parse_rdf(ttl, TurtleFormat())
            @test Triple(URIRef("http://example.org/dir/file"), RDF.type, URIRef("http://example.org/dir/Thing")) in g
        end
    end

    # ── 5. Boolean literals ──────────────────────────────────────────
    @testset "boolean literals" begin
        @testset "true literal" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:active true .
            """
            g = parse_rdf(ttl, TurtleFormat())
            obj = first(objects(g, EX("s"), EX("active")))
            @test convert(Any, obj) == true
        end

        @testset "false literal" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:active false .
            """
            g = parse_rdf(ttl, TurtleFormat())
            obj = first(objects(g, EX("s"), EX("active")))
            @test convert(Any, obj) == false
        end

        @testset "boolean roundtrip" begin
            g = RDFGraph()
            bind!(g, "ex", EX)
            add!(g, EX("s"), EX("yes"), Literal(true))
            add!(g, EX("s"), EX("no"), Literal(false))
            ttl = serialize(g, TurtleFormat())
            g2 = parse_rdf(ttl, TurtleFormat())
            @test convert(Any, first(objects(g2, EX("s"), EX("yes")))) == true
            @test convert(Any, first(objects(g2, EX("s"), EX("no")))) == false
        end
    end

    # ── 6. Numeric literals ──────────────────────────────────────────
    @testset "numeric literals" begin
        @testset "negative integer" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:val -42 .
            """
            g = parse_rdf(ttl, TurtleFormat())
            obj = first(objects(g, EX("s"), EX("val")))
            @test convert(Any, obj) == -42
        end

        @testset "decimal literal" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:val 3.14 .
            """
            g = parse_rdf(ttl, TurtleFormat())
            obj = first(objects(g, EX("s"), EX("val")))
            @test convert(Any, obj) ≈ 3.14
        end

        @testset "double with exponent" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:val 1.5e10 .
            """
            g = parse_rdf(ttl, TurtleFormat())
            obj = first(objects(g, EX("s"), EX("val")))
            @test datatype(obj) == XSD.double
        end

        @testset "positive integer with sign" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:val +7 .
            """
            g = parse_rdf(ttl, TurtleFormat())
            obj = first(objects(g, EX("s"), EX("val")))
            @test convert(Any, obj) == 7
        end

        @testset "numeric shorthand in serializer" begin
            g = RDFGraph()
            bind!(g, "ex", EX)
            add!(g, EX("s"), EX("age"), Literal(42))
            ttl = serialize(g, TurtleFormat())
            @test contains(ttl, "42")
            @test !contains(ttl, "\"42\"")
        end
    end

    # ── 7. Blank node syntax ─────────────────────────────────────────
    @testset "blank node syntax" begin
        @testset "anonymous blank node []" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:knows [ ex:name "Alice" ] .
            """
            g = parse_rdf(ttl, TurtleFormat())
            @test length(g) == 2
        end

        @testset "empty anonymous blank node" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:ref [] .
            """
            g = parse_rdf(ttl, TurtleFormat())
            @test length(g) == 1
            t = first(g)
            @test t.object isa BNode
        end

        @testset "labeled blank node _:label" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            _:person1 ex:name "Alice" .
            _:person1 a ex:Person .
            """
            g = parse_rdf(ttl, TurtleFormat())
            @test length(g) == 2
            subjs = collect(subjects(g, nothing, nothing))
            # Both triples have same subject
            names = collect(subjects(g, EX("name"), Literal("Alice")))
            types = collect(subjects(g, RDF.type, EX("Person")))
            @test length(names) == 1
            @test length(types) == 1
            @test names[1] == types[1]
        end

        @testset "nested blank nodes" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:knows [ ex:knows [ ex:name "deep" ] ] .
            """
            g = parse_rdf(ttl, TurtleFormat())
            @test length(g) == 3
        end
    end

    # ── 8. Multi-line literals ────────────────────────────────────────
    @testset "multi-line literals" begin
        @testset "triple-quoted string with newlines" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:desc \"\"\"This is
            a multi-line
            string\"\"\" .
            """
            g = parse_rdf(ttl, TurtleFormat())
            obj = first(objects(g, EX("s"), EX("desc")))
            @test contains(string(obj), "\n")
        end

        @testset "triple-quoted with escape sequences" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:desc \"\"\"line1\\nline2\\ttab\"\"\" .
            """
            g = parse_rdf(ttl, TurtleFormat())
            obj = first(objects(g, EX("s"), EX("desc")))
            @test string(obj) == "line1\nline2\ttab"
        end

        @testset "single-quote triple-quoted string" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:desc '''multi
            line''' .
            """
            g = parse_rdf(ttl, TurtleFormat())
            obj = first(objects(g, EX("s"), EX("desc")))
            @test contains(string(obj), "\n")
        end
    end

    # ── 9. Comment handling ──────────────────────────────────────────
    @testset "comment handling" begin
        @testset "standalone comment line" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            # This is a comment
            ex:s a ex:Type .
            """
            g = parse_rdf(ttl, TurtleFormat())
            @test length(g) == 1
        end

        @testset "inline comment after triple" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s a ex:Type . # comment here
            """
            g = parse_rdf(ttl, TurtleFormat())
            @test length(g) == 1
        end

        @testset "comment between prefix and triples" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            # separator comment
            # another comment
            ex:s a ex:Type .
            """
            g = parse_rdf(ttl, TurtleFormat())
            @test length(g) == 1
        end
    end

    # ── 10. Unicode in identifiers ───────────────────────────────────
    @testset "unicode in identifiers" begin
        @testset "IRI with Unicode" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            <http://example.org/café> a ex:Place .
            """
            g = parse_rdf(ttl, TurtleFormat())
            t = first(g)
            @test t.subject == URIRef("http://example.org/café")
        end

        @testset "Unicode literal roundtrip through Turtle" begin
            g = RDFGraph()
            bind!(g, "ex", EX)
            add!(g, EX("s"), RDFS.label, Literal("Ångström"))
            ttl = serialize(g, TurtleFormat())
            g2 = parse_rdf(ttl, TurtleFormat())
            obj = first(objects(g2, EX("s"), RDFS.label))
            @test string(obj) == "Ångström"
        end

        @testset "CJK literal in Turtle" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s ex:label "日本語"@ja .
            """
            g = parse_rdf(ttl, TurtleFormat())
            obj = first(objects(g, EX("s"), EX("label")))
            @test string(obj) == "日本語"
            @test lang(obj) == "ja"
        end
    end

    # ── 11. Prefix redefinition ──────────────────────────────────────
    @testset "prefix redefinition" begin
        @testset "same prefix rebound to different URI" begin
            ttl = """
            @prefix ex: <http://example.org/> .
            ex:s a ex:Type1 .
            @prefix ex: <http://other.org/> .
            ex:s a ex:Type2 .
            """
            g = parse_rdf(ttl, TurtleFormat())
            @test length(g) == 2
            # First triple uses example.org, second uses other.org
            subjs = Set(t.subject.value for t in g)
            @test "http://example.org/s" in subjs || "http://other.org/s" in subjs
        end
    end

    # ── 12. Empty prefix ─────────────────────────────────────────────
    @testset "empty prefix" begin
        @testset "empty prefix declaration" begin
            ttl = """
            @prefix : <http://example.org/> .
            :alice a :Person .
            """
            g = parse_rdf(ttl, TurtleFormat())
            @test length(g) == 1
            t = first(g)
            @test t.subject == URIRef("http://example.org/alice")
            @test t.object == URIRef("http://example.org/Person")
        end

        @testset "empty prefix with other prefixes" begin
            ttl = """
            @prefix : <http://example.org/> .
            @prefix foaf: <http://xmlns.com/foaf/0.1/> .
            :alice foaf:name "Alice" .
            """
            g = parse_rdf(ttl, TurtleFormat())
            @test length(g) == 1
            t = first(g)
            @test t.subject == URIRef("http://example.org/alice")
            @test t.predicate == URIRef("http://xmlns.com/foaf/0.1/name")
        end
    end

    # ── Additional roundtrip tests ───────────────────────────────────
    @testset "comprehensive roundtrip" begin
        @testset "Turtle serialize-parse-serialize" begin
            g1 = RDFGraph()
            bind!(g1, "ex", EX)
            add!(g1, EX("alice"), RDF.type, EX("Person"))
            add!(g1, EX("alice"), RDFS.label, Literal("Alice", lang="en"))
            add!(g1, EX("alice"), EX("age"), Literal(30))
            add!(g1, EX("alice"), EX("active"), Literal(true))
            add!(g1, EX("bob"), RDF.type, EX("Person"))
            add!(g1, EX("alice"), EX("knows"), EX("bob"))

            ttl1 = serialize(g1, TurtleFormat())
            g2 = parse_rdf(ttl1, TurtleFormat())
            ttl2 = serialize(g2, TurtleFormat())
            g3 = parse_rdf(ttl2, TurtleFormat())

            @test length(g3) == length(g1)
            for t in g1
                @test t in g3
            end
        end

        @testset "N-Triples to Turtle and back" begin
            g1 = RDFGraph()
            add!(g1, EX("s"), EX("p"), Literal("hello\nworld"))
            add!(g1, EX("s"), EX("q"), Literal(42))
            add!(g1, EX("s"), RDFS.label, Literal("test", lang="en"))

            nt = serialize(g1, NTriplesFormat())
            g2 = parse_rdf(nt, NTriplesFormat())

            bind!(g2, "ex", EX)
            ttl = serialize(g2, TurtleFormat())
            g3 = parse_rdf(ttl, TurtleFormat())

            @test length(g3) == length(g1)
            for t in g1
                @test t in g3
            end
        end
    end
end

@testset "Turtle parser/serializer regression fixes" begin
    EX = Namespace("http://example.org/")

    @testset "generated bnode IDs do not collide with document labels" begin
        # _:b1 and the anonymous [ ... ] node must remain distinct
        g = RDFLib.parse_turtle("""
            @prefix ex: <http://example.org/> .
            _:b1 ex:x ex:y .
            [ ex:p ex:o ] ex:q ex:r .
        """)
        @test length(g) == 3
        subjects = Set(t.subject for t in g)
        @test length(subjects) == 2  # _:b1 and the (distinct) anonymous node
        # The document label must be preserved verbatim
        @test BNode("b1") in subjects
        # The anonymous node must NOT be _:b1
        anon_q = [t.subject for t in triples(g, (nothing, EX("q"), EX("r")))]
        @test length(anon_q) == 1
        @test anon_q[1] != BNode("b1")
    end

    @testset "generated bnode IDs skip later document labels too" begin
        g = RDFLib.parse_turtle("""
            @prefix ex: <http://example.org/> .
            [ ex:p ex:o ] ex:q ex:r .
            _:b1 ex:x ex:y .
        """)
        anon_q = [t.subject for t in triples(g, (nothing, EX("q"), EX("r")))]
        @test length(anon_q) == 1
        @test anon_q[1] != BNode("b1")
    end

    @testset "bnode label does not consume terminating dot" begin
        g = RDFLib.parse_turtle("""
            @prefix ex: <http://example.org/> .
            ex:s ex:p _:b1.
            ex:s2 ex:p2 ex:o2 .
        """)
        @test length(g) == 2
        @test Triple(EX("s"), EX("p"), BNode("b1")) in g
        @test Triple(EX("s2"), EX("p2"), EX("o2")) in g
    end

    @testset "bnode label with internal dots" begin
        g = RDFLib.parse_turtle("""
            @prefix ex: <http://example.org/> .
            _:a.b.c ex:p ex:o .
        """)
        @test Triple(BNode("a.b.c"), EX("p"), EX("o")) in g
    end

    @testset "PN_LOCAL with internal dots" begin
        g = RDFLib.parse_turtle("""
            @prefix ex: <http://example.org/> .
            ex:a.b ex:v1.0 ex:c .
        """)
        @test Triple(EX("a.b"), EX("v1.0"), EX("c")) in g
    end

    @testset "PN_LOCAL trailing dot is the statement terminator" begin
        g = RDFLib.parse_turtle("""
            @prefix ex: <http://example.org/> .
            ex:s ex:p ex:o.
            ex:s2 ex:p ex:o2 .
        """)
        @test length(g) == 2
        @test Triple(EX("s"), EX("p"), EX("o")) in g
    end

    @testset "PN_LOCAL_ESC escapes are unescaped" begin
        g = RDFLib.parse_turtle("""
            @prefix ex: <http://example.org/> .
            ex:a\\,b ex:p ex:o\\(1\\) .
        """)
        @test Triple(EX("a,b"), EX("p"), EX("o(1)")) in g
    end

    @testset "PN_LOCAL percent-encoded sequences kept verbatim" begin
        g = RDFLib.parse_turtle("""
            @prefix ex: <http://example.org/> .
            ex:a%20b ex:p ex:o .
        """)
        @test Triple(EX("a%20b"), EX("p"), EX("o")) in g
    end

    @testset "true/false require a token boundary" begin
        g = RDFLib.parse_turtle("""
            @prefix trueblue: <http://example.org/tb#> .
            @prefix ex: <http://example.org/> .
            ex:s ex:p trueblue:x .
        """)
        @test length(g) == 1
        @test Triple(EX("s"), EX("p"), URIRef("http://example.org/tb#x")) in g

        # plain booleans still work
        g2 = RDFLib.parse_turtle("@prefix ex: <http://example.org/> . ex:s ex:p true . ex:s ex:q false .")
        @test Triple(EX("s"), EX("p"), Literal(true)) in g2
        @test Triple(EX("s"), EX("q"), Literal(false)) in g2

        # 'true' as a prefix name
        g3 = RDFLib.parse_turtle("@prefix true: <http://example.org/t#> . @prefix ex: <http://example.org/> . ex:s ex:p true:x .")
        @test Triple(EX("s"), EX("p"), URIRef("http://example.org/t#x")) in g3
    end

    @testset "leading-dot decimals" begin
        g = RDFLib.parse_turtle("@prefix ex: <http://example.org/> . ex:s ex:p .5 . ex:s ex:q -.25 .")
        xsd_decimal = URIRef("http://www.w3.org/2001/XMLSchema#decimal")
        @test Triple(EX("s"), EX("p"), Literal(".5", datatype=xsd_decimal)) in g
        @test Triple(EX("s"), EX("q"), Literal("-.25", datatype=xsd_decimal)) in g
    end

    @testset "'a' keyword boundary" begin
        rdf_type = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
        g = RDFLib.parse_turtle("@prefix ex: <http://example.org/> . ex:s a[ex:p ex:o] .")
        @test length(g) == 2
        @test length(collect(triples(g, (EX("s"), rdf_type, nothing)))) == 1

        g2 = RDFLib.parse_turtle("@prefix ex: <http://example.org/> . ex:s a<http://example.org/T> .")
        @test Triple(EX("s"), rdf_type, EX("T")) in g2

        # 'a' as start of a prefixed name still works
        g3 = RDFLib.parse_turtle("@prefix a: <http://example.org/a#> . @prefix ex: <http://example.org/> . ex:s a:p ex:o .")
        @test Triple(EX("s"), URIRef("http://example.org/a#p"), EX("o")) in g3
    end

    @testset "long string termination per W3C grammar" begin
        # Turtle and N3 share the same long-string rule: in a run of n>=3
        # quotes, the final three close the string and the earlier quotes stay
        # in the content.
        g1 = RDFLib.parse_turtle("@prefix ex: <http://example.org/> . ex:s ex:p \"\"\"a\"\"\"\" .")
        @test Triple(EX("s"), EX("p"), Literal("a\"")) in g1
        g2 = RDFLib.parse_turtle("@prefix ex: <http://example.org/> . ex:s ex:p \"\"\"a\"\"\"\"\" .")
        @test Triple(EX("s"), EX("p"), Literal("a\"\"")) in g2

        # 1-2 quotes inside content (each followed by a non-quote) are kept.
        g3 = RDFLib.parse_turtle("@prefix ex: <http://example.org/> . ex:s ex:p \"\"\"a\"\"b\"\"\" .")
        @test Triple(EX("s"), EX("p"), Literal("a\"\"b")) in g3

        # An escaped quote may sit right before the closing delimiter.
        g4 = RDFLib.parse_turtle("@prefix ex: <http://example.org/> . ex:s ex:p \"\"\"a\\\"\"\"\" .")
        @test Triple(EX("s"), EX("p"), Literal("a\"")) in g4

        # Empty long string.
        g5 = RDFLib.parse_turtle("@prefix ex: <http://example.org/> . ex:s ex:p \"\"\"\"\"\" .")
        @test Triple(EX("s"), EX("p"), Literal("")) in g5
    end

    @testset "truncated and invalid unicode escapes" begin
        @test_throws ArgumentError RDFLib.parse_turtle("@prefix ex: <http://example.org/> . ex:s ex:p \"\\u00")
        @test_throws ArgumentError RDFLib.parse_turtle("@prefix ex: <http://example.org/> . ex:s ex:p \"\\u00ZZ\" .")
        # surrogate range rejected
        @test_throws ArgumentError RDFLib.parse_turtle("@prefix ex: <http://example.org/> . ex:s ex:p \"\\uD800\" .")
        # valid escapes still work
        g = RDFLib.parse_turtle("@prefix ex: <http://example.org/> . ex:s ex:p \"\\u00e9\\U0001F600\" .")
        @test Triple(EX("s"), EX("p"), Literal("é\U0001F600")) in g
    end

    @testset "IRI references only allow unicode escapes" begin
        @test_throws ArgumentError RDFLib.parse_turtle("<http://example.org/s\\n> <http://example.org/p> <http://example.org/o> .")
        g = RDFLib.parse_turtle("<http://example.org/s\\u00e9> <http://example.org/p> <http://example.org/o> .")
        @test Triple(URIRef("http://example.org/sé"), EX("p"), EX("o")) in g
    end

    @testset "serializer escapes PN_LOCAL reserved characters" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("a,b"), EX("p"), Literal("v")))
        ttl = serialize(g, TurtleFormat())
        g2 = parse_rdf(ttl, TurtleFormat())
        @test length(g2) == 1
        @test Triple(EX("a,b"), EX("p"), Literal("v")) in g2
    end

    @testset "serializer falls back to full IRI for unrepresentable local names" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        # '|' cannot appear in a PN_LOCAL even escaped, and is also forbidden
        # raw inside an IRIREF, so the serializer must emit it as a \u escape.
        add!(g, Triple(URIRef("http://example.org/a|b"), EX("p"), Literal("v")))
        ttl = serialize(g, TurtleFormat())
        @test contains(ttl, "<http://example.org/a\\u007Cb>")
        g2 = parse_rdf(ttl, TurtleFormat())
        @test length(g2) == 1
        @test Triple(URIRef("http://example.org/a|b"), EX("p"), Literal("v")) in g2
    end

    @testset "serializer round-trips local names with dots and dashes" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("v1.0"), EX("p"), EX("ends.")))
        add!(g, Triple(EX("-dash"), EX("p"), EX(".dot")))
        ttl = serialize(g, TurtleFormat())
        g2 = parse_rdf(ttl, TurtleFormat())
        @test length(g2) == 2
        for t in g
            @test t in g2
        end
    end

    @testset "directional literals" begin
        g = RDFLib.parse_turtle("@prefix ex: <http://example.org/> . ex:s ex:p \"x\"@en--ltr . ex:s ex:q \"y\"@ar--rtl .")
        lits = Dict(t.predicate => t.object for t in g)
        @test lits[EX("p")] == Literal("x", lang="en", direction="ltr")
        @test lits[EX("q")] == Literal("y", lang="ar", direction="rtl")

        # invalid direction rejected
        @test_throws ArgumentError RDFLib.parse_turtle("@prefix ex: <http://example.org/> . ex:s ex:p \"x\"@en--up .")

        # round-trip through the Turtle serializer
        g2 = RDFGraph()
        bind!(g2, "ex", EX)
        add!(g2, Triple(EX("s"), EX("p"), Literal("x", lang="en", direction="ltr")))
        ttl = serialize(g2, TurtleFormat())
        g3 = parse_rdf(ttl, TurtleFormat())
        @test Triple(EX("s"), EX("p"), Literal("x", lang="en", direction="ltr")) in g3

        # plain language tags unaffected
        g4 = RDFLib.parse_turtle("@prefix ex: <http://example.org/> . ex:s ex:p \"x\"@en-GB .")
        @test Triple(EX("s"), EX("p"), Literal("x", lang="en-GB")) in g4
    end

    @testset "RDF 1.2 triple terms and reifiers" begin
        rdf_type = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
        reifies = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#reifies")

        # A reifier `<< s p o >>` denotes a fresh reifier blank node that
        # rdf:reifies the triple term `<<( s p o )>>`. It does NOT assert s p o.
        g = RDFLib.parse_turtle("""
            @prefix ex: <http://example.org/> .
            << ex:s ex:p ex:o >> ex:certainty 0.9 .
        """)
        @test length(g) == 2
        tt1 = TripleTerm(EX("s"), EX("p"), EX("o"))
        xsd_decimal = URIRef("http://www.w3.org/2001/XMLSchema#decimal")
        # one rdf:reifies triple and one certainty triple, sharing a bnode subject
        reif = [t for t in g if t.predicate == reifies]
        @test length(reif) == 1
        @test reif[1].object == tt1
        rid = reif[1].subject
        @test rid isa BNode
        @test Triple(rid, EX("certainty"), Literal("0.9", datatype=xsd_decimal)) in g

        # A triple term `<<( s p o )>>` is a term and may appear as object.
        g2 = RDFLib.parse_turtle("""
            @prefix ex: <http://example.org/> .
            ex:a ex:b <<( ex:c a ex:D )>> .
        """)
        @test length(g2) == 1
        @test Triple(EX("a"), EX("b"), TripleTerm(EX("c"), rdf_type, EX("D"))) in g2

        # serialization round-trip of a triple term
        bind!(g2, "ex", EX)
        ttl = serialize(g2, TurtleFormat())
        g3 = parse_rdf(ttl, TurtleFormat())
        @test length(g3) == 1
        for t in g2
            @test t in g3
        end
    end

    @testset "RDF 1.2 annotation syntax" begin
        reifies = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#reifies")
        g = RDFLib.parse_turtle("""
            @prefix ex: <http://example.org/> .
            ex:s ex:p ex:o {| ex:certainty 0.9 ; ex:source ex:doc |} .
        """)
        tt = TripleTerm(EX("s"), EX("p"), EX("o"))
        xsd_decimal = URIRef("http://www.w3.org/2001/XMLSchema#decimal")
        # base triple + reifies + 2 annotation triples
        @test length(g) == 4
        @test Triple(EX("s"), EX("p"), EX("o")) in g
        reif = [t for t in g if t.predicate == reifies]
        @test length(reif) == 1
        @test reif[1].object == tt
        rid = reif[1].subject
        @test Triple(rid, EX("certainty"), Literal("0.9", datatype=xsd_decimal)) in g
        @test Triple(rid, EX("source"), EX("doc")) in g
    end

    # ── W3C strictness regressions ────────────────────────────────────
    @testset "IRIREF forbidden characters rejected" begin
        P = "<http://a/s> <http://a/p> "
        # Raw forbidden characters (space, <, >, ", {, }, |, ^, `, control).
        @test_throws ArgumentError RDFLib.parse_turtle("<http://a/ x> <http://a/p> <http://a/o> .")
        @test_throws ArgumentError RDFLib.parse_turtle("<http://a/{abc}> <http://a/p> <http://a/o> .")
        @test_throws ArgumentError RDFLib.parse_turtle("<http://a/a^b> <http://a/p> <http://a/o> .")
        @test_throws ArgumentError RDFLib.parse_turtle("<http://a/a`b> <http://a/p> <http://a/o> .")
        # \u escapes that decode to structurally-invalid characters.
        @test_throws ArgumentError RDFLib.parse_turtle("<http://a/x\\u0020y> <http://a/p> <http://a/o> .")
        @test_throws ArgumentError RDFLib.parse_turtle("<http://a/x\\u003Cy> <http://a/p> <http://a/o> .")
        @test_throws ArgumentError RDFLib.parse_turtle("<http://a/x\\u003Ey> <http://a/p> <http://a/o> .")
        # A \u escape encoding a char only forbidden RAW (|) is accepted.
        g = RDFLib.parse_turtle("<http://a/x\\u007Cy> <http://a/p> <http://a/o> .")
        @test Triple(URIRef("http://a/x|y"), URIRef("http://a/p"), URIRef("http://a/o")) in g
    end

    @testset "bad language tags rejected" begin
        P = "@prefix ex: <http://example.org/> . ex:s ex:p "
        @test_throws ArgumentError RDFLib.parse_turtle(P * "\"x\"@1 .")
        @test_throws ArgumentError RDFLib.parse_turtle(P * "\"x\"@ .")
        # valid tag with numeric subtag still parses
        g = RDFLib.parse_turtle(P * "\"x\"@en-US .")
        @test Literal("x", lang="en-US") in [t.object for t in g]
    end

    @testset "invalid string escapes rejected" begin
        P = "@prefix ex: <http://example.org/> . ex:s ex:p "
        @test_throws ArgumentError RDFLib.parse_turtle(P * "\"a\\zb\" .")
        @test_throws ArgumentError RDFLib.parse_turtle(P * "\"a\\xb\" .")
    end

    @testset "invalid numeric literals rejected, valid edge forms accepted" begin
        P = "<http://a/s> <http://a/p> "
        xsd = "http://www.w3.org/2001/XMLSchema#"
        @test_throws ArgumentError RDFLib.parse_turtle(P * "123e .")
        @test_throws ArgumentError RDFLib.parse_turtle(P * "123e+ .")
        # `123.E+1` is a valid DOUBLE (dot followed directly by exponent).
        g = RDFLib.parse_turtle(P * "123.E+1 .")
        @test Triple(URIRef("http://a/s"), URIRef("http://a/p"),
                     Literal("123.E+1", datatype=URIRef(xsd * "double"))) in g
        # `1.E0` likewise.
        g2 = RDFLib.parse_turtle(P * "1.e0 .")
        @test Literal("1.e0", datatype=URIRef(xsd * "double")) in [t.object for t in g2]
    end

    @testset "prefixed names with internal dots / extra PN_CHARS" begin
        # Internal dots in PN_PREFIX (turtle-syntax-ns-dots).
        g = RDFLib.parse_turtle("@prefix e.g: <http://x/> . e.g:s e.g:p e.g:o .")
        @test Triple(URIRef("http://x/s"), URIRef("http://x/p"), URIRef("http://x/o")) in g
    end

    @testset "repeated semicolons in predicate list" begin
        # repeated_semis_not_at_end / struct-04
        g = RDFLib.parse_turtle(
            "<http://a/s> <http://a/p1> <http://a/o1> ;; <http://a/p2> <http://a/o2> .")
        @test Triple(URIRef("http://a/s"), URIRef("http://a/p1"), URIRef("http://a/o1")) in g
        @test Triple(URIRef("http://a/s"), URIRef("http://a/p2"), URIRef("http://a/o2")) in g
        # repeated_semis_at_end / struct-05
        g2 = RDFLib.parse_turtle("<http://a/s> <http://a/p1> <http://a/o1> ;; .")
        @test Triple(URIRef("http://a/s"), URIRef("http://a/p1"), URIRef("http://a/o1")) in g2
    end

    @testset "subject with empty predicate-object list rejected" begin
        # N3 path-style input that is invalid Turtle (turtle-syntax-bad-n3-extras).
        @test_throws ArgumentError RDFLib.parse_turtle("@prefix : <http://x/> . :a.:b.:c .")
        @test_throws ArgumentError RDFLib.parse_turtle("@prefix : <http://x/> . :x .")
        # A blankNodePropertyList subject may legitimately stand alone.
        g = RDFLib.parse_turtle("@prefix : <http://x/> . [ :p :o ] .")
        @test length(g) == 1
    end
end
