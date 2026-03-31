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
