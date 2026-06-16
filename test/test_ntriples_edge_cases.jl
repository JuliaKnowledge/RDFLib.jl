using Test
using RDFLib

@testset "N-Triples Edge Cases" begin
    EX = Namespace("http://example.org/")

    # ── 1. Quote handling ──────────────────────────────────────────────
    @testset "quote handling" begin
        @testset "escaped double quotes in literal" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal("He said \"hello\""))
            nt = serialize(g, NTriplesFormat())
            @test contains(nt, "\\\"hello\\\"")
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test string(obj) == "He said \"hello\""
        end

        @testset "literal containing single quotes" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal("it's a test"))
            nt = serialize(g, NTriplesFormat())
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test string(obj) == "it's a test"
        end

        @testset "literal with both quote types" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal("She said \"it's fine\""))
            nt = serialize(g, NTriplesFormat())
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test string(obj) == "She said \"it's fine\""
        end
    end

    # ── 2. Unicode ─────────────────────────────────────────────────────
    @testset "unicode" begin
        @testset "Swedish characters in literal" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal("Ångström"))
            nt = serialize(g, NTriplesFormat())
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test string(obj) == "Ångström"
        end

        @testset "CJK characters in literal" begin
            g = RDFGraph()
            add!(g, EX("s"), RDFS.label, Literal("日本語", lang="ja"))
            nt = serialize(g, NTriplesFormat())
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), RDFS.label))
            @test string(obj) == "日本語"
            @test lang(obj) == "ja"
        end

        @testset "emoji in literal" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal("Hello 🌍🎉"))
            nt = serialize(g, NTriplesFormat())
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test string(obj) == "Hello 🌍🎉"
        end

        @testset "unicode in URI" begin
            g = RDFGraph()
            add!(g, URIRef("http://example.org/café"), EX("p"), Literal("test"))
            nt = serialize(g, NTriplesFormat())
            g2 = parse_rdf(nt, NTriplesFormat())
            @test length(g2) == 1
            t = first(g2)
            @test t.subject == URIRef("http://example.org/café")
        end
    end

    # ── 3. Newline/tab escaping ────────────────────────────────────────
    @testset "escape sequences" begin
        @testset "newline roundtrip" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal("line1\nline2\nline3"))
            nt = serialize(g, NTriplesFormat())
            @test contains(nt, "\\n")
            @test !contains(nt, "\nline2")
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test string(obj) == "line1\nline2\nline3"
        end

        @testset "tab roundtrip" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal("col1\tcol2"))
            nt = serialize(g, NTriplesFormat())
            @test contains(nt, "\\t")
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test string(obj) == "col1\tcol2"
        end

        @testset "carriage return roundtrip" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal("line1\r\nline2"))
            nt = serialize(g, NTriplesFormat())
            @test contains(nt, "\\r\\n")
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test string(obj) == "line1\r\nline2"
        end

        @testset "backslash roundtrip" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal("path\\to\\file"))
            nt = serialize(g, NTriplesFormat())
            @test contains(nt, "\\\\")
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test string(obj) == "path\\to\\file"
        end
    end

    # ── 4. BNode handling ──────────────────────────────────────────────
    @testset "blank nodes" begin
        @testset "consistent BNode labels" begin
            g = RDFGraph()
            b = BNode("mynode")
            add!(g, b, EX("p"), Literal("val"))
            nt = serialize(g, NTriplesFormat())
            @test contains(nt, "_:mynode")
        end

        @testset "BNode as subject and object" begin
            g = RDFGraph()
            b1 = BNode("a1")
            b2 = BNode("a2")
            add!(g, b1, EX("knows"), b2)
            add!(g, b2, EX("name"), Literal("Bob"))
            nt = serialize(g, NTriplesFormat())
            @test contains(nt, "_:a1")
            @test contains(nt, "_:a2")
            g2 = parse_rdf(nt, NTriplesFormat())
            @test length(g2) == 2
        end

        @testset "multiple BNodes parsed distinctly" begin
            nt = """
            _:b1 <http://example.org/p> "one" .
            _:b2 <http://example.org/p> "two" .
            """
            g = parse_rdf(nt, NTriplesFormat())
            @test length(g) == 2
            subjs = collect(subjects(g, EX("p"), nothing))
            @test length(subjs) == 2
            @test subjs[1] != subjs[2]
        end
    end

    # ── 5. Whitespace edge cases ───────────────────────────────────────
    @testset "whitespace" begin
        @testset "extra spaces between components" begin
            nt = """<http://example.org/s>   <http://example.org/p>   "hello"   ."""
            g = parse_rdf(nt, NTriplesFormat())
            @test length(g) == 1
        end

        @testset "tabs between components" begin
            nt = "<http://example.org/s>\t<http://example.org/p>\t\"hello\"\t."
            g = parse_rdf(nt, NTriplesFormat())
            @test length(g) == 1
        end

        @testset "leading/trailing whitespace on lines" begin
            nt = "   <http://example.org/s> <http://example.org/p> \"hello\" .   \n"
            g = parse_rdf(nt, NTriplesFormat())
            @test length(g) == 1
        end
    end

    # ── 6. Large literals ──────────────────────────────────────────────
    @testset "large literals" begin
        @testset "1000+ character string" begin
            long_str = repeat("abcdefghij", 120)  # 1200 chars
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal(long_str))
            nt = serialize(g, NTriplesFormat())
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test string(obj) == long_str
            @test length(string(obj)) == 1200
        end
    end

    # ── 7. Empty literal ──────────────────────────────────────────────
    @testset "empty literal" begin
        @testset "empty string literal" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal(""))
            nt = serialize(g, NTriplesFormat())
            @test contains(nt, "\"\"")
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test string(obj) == ""
        end
    end

    # ── 8. Datatype handling ──────────────────────────────────────────
    @testset "datatypes" begin
        @testset "xsd:integer" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal(42))
            nt = serialize(g, NTriplesFormat())
            @test contains(nt, "\"42\"^^<http://www.w3.org/2001/XMLSchema#integer>")
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test convert(Any, obj) == 42
        end

        @testset "xsd:double" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal(3.14))
            nt = serialize(g, NTriplesFormat())
            @test contains(nt, "^^<http://www.w3.org/2001/XMLSchema#double>")
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test convert(Any, obj) ≈ 3.14
        end

        @testset "xsd:boolean true" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal(true))
            nt = serialize(g, NTriplesFormat())
            @test contains(nt, "\"true\"^^<http://www.w3.org/2001/XMLSchema#boolean>")
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test convert(Any, obj) == true
        end

        @testset "xsd:boolean false" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal(false))
            nt = serialize(g, NTriplesFormat())
            @test contains(nt, "\"false\"^^<http://www.w3.org/2001/XMLSchema#boolean>")
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test convert(Any, obj) == false
        end

        @testset "xsd:date" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal("2024-01-15", datatype=XSD.date))
            nt = serialize(g, NTriplesFormat())
            @test contains(nt, "\"2024-01-15\"^^<http://www.w3.org/2001/XMLSchema#date>")
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test string(obj) == "2024-01-15"
            @test datatype(obj) == XSD.date
        end
    end

    # ── 9. Language tags ──────────────────────────────────────────────
    @testset "language tags" begin
        @testset "simple language tag" begin
            nt = """<http://example.org/s> <http://example.org/p> "hello"@en ."""
            g = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g, EX("s"), EX("p")))
            @test lang(obj) == "en"
        end

        @testset "region subtag" begin
            nt = """<http://example.org/s> <http://example.org/p> "color"@en-US ."""
            g = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g, EX("s"), EX("p")))
            @test lowercase(lang(obj)) == "en-us"
        end

        @testset "German language tag" begin
            g = RDFGraph()
            add!(g, EX("s"), RDFS.label, Literal("Hallo", lang="de"))
            nt = serialize(g, NTriplesFormat())
            @test contains(nt, "\"Hallo\"@de")
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), RDFS.label))
            @test lang(obj) == "de"
        end

        @testset "Chinese script subtag" begin
            g = RDFGraph()
            add!(g, EX("s"), RDFS.label, Literal("你好", lang="zh-Hans"))
            nt = serialize(g, NTriplesFormat())
            @test contains(lowercase(nt), "@zh-hans")
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), RDFS.label))
            @test lowercase(lang(obj)) == "zh-hans"
            @test string(obj) == "你好"
        end
    end

    # ── 10. Special characters ────────────────────────────────────────
    @testset "special characters" begin
        @testset "backslash in literal" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal("C:\\Users\\test"))
            nt = serialize(g, NTriplesFormat())
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test string(obj) == "C:\\Users\\test"
        end

        @testset "ampersand in literal" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal("Tom & Jerry"))
            nt = serialize(g, NTriplesFormat())
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test string(obj) == "Tom & Jerry"
        end

        @testset "mixed escape sequences" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal("line1\nline2\ttab\\slash\"quote"))
            nt = serialize(g, NTriplesFormat())
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test string(obj) == "line1\nline2\ttab\\slash\"quote"
        end
    end

    # ── 11. Serializer consistency ────────────────────────────────────
    @testset "serializer consistency" begin
        @testset "serialize-parse-serialize roundtrip" begin
            g1 = RDFGraph()
            add!(g1, EX("alice"), RDF.type, EX("Person"))
            add!(g1, EX("alice"), RDFS.label, Literal("Alice", lang="en"))
            add!(g1, EX("alice"), EX("age"), Literal(30))
            add!(g1, BNode("b1"), EX("name"), Literal("line1\nline2"))
            add!(g1, EX("alice"), EX("note"), Literal("She said \"hi\""))

            nt1 = serialize(g1, NTriplesFormat())
            g2 = parse_rdf(nt1, NTriplesFormat())
            nt2 = serialize(g2, NTriplesFormat())
            g3 = parse_rdf(nt2, NTriplesFormat())

            @test length(g2) == length(g1)
            @test length(g3) == length(g2)
            # Every triple in g1 should be in g3
            for t in g1
                @test t in g3
            end
        end

        @testset "multiple datatypes roundtrip" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("int"), Literal(42))
            add!(g, EX("s"), EX("dbl"), Literal(2.718))
            add!(g, EX("s"), EX("bool"), Literal(true))
            add!(g, EX("s"), EX("str"), Literal("plain"))
            add!(g, EX("s"), EX("lang"), Literal("bonjour", lang="fr"))
            add!(g, EX("s"), EX("date"), Literal("2024-06-15", datatype=XSD.date))

            nt = serialize(g, NTriplesFormat())
            g2 = parse_rdf(nt, NTriplesFormat())
            @test length(g2) == length(g)
            for t in g
                @test t in g2
            end
        end
    end

    # ── 12. Full ECHAR set ────────────────────────────────────────────
    @testset "ECHAR escapes" begin
        @testset "backspace and form feed roundtrip" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal("a\bb\fc"))
            nt = serialize(g, NTriplesFormat())
            @test contains(nt, "\\b")
            @test contains(nt, "\\f")
            @test !contains(nt, "\b")   # raw control chars must not be emitted
            @test !contains(nt, "\f")
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test string(obj) == "a\bb\fc"
        end

        @testset "parse \\b, \\f and \\' escapes" begin
            nt = "<http://example.org/s> <http://example.org/p> \"a\\bb\\fc\\'d\" ."
            g = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g, EX("s"), EX("p")))
            @test string(obj) == "a\bb\fc'd"
        end

        @testset "truncated \\u escape throws" begin
            nt = "<http://example.org/s> <http://example.org/p> \"x\\u00\" ."
            @test_throws ArgumentError parse_rdf(nt, NTriplesFormat())
        end

        @testset "truncated \\U escape throws" begin
            nt = "<http://example.org/s> <http://example.org/p> \"x\\U0001F6\" ."
            @test_throws ArgumentError parse_rdf(nt, NTriplesFormat())
        end

        @testset "surrogate code points rejected" begin
            for esc in ("\\uD800", "\\uDFFF", "\\U0000DC00")
                nt = "<http://example.org/s> <http://example.org/p> \"x$(esc)\" ."
                @test_throws ArgumentError parse_rdf(nt, NTriplesFormat())
            end
        end

        @testset "unknown escape sequence throws" begin
            nt = "<http://example.org/s> <http://example.org/p> \"x\\q\" ."
            @test_throws ArgumentError parse_rdf(nt, NTriplesFormat())
        end

        @testset "valid \\u and \\U escapes decode" begin
            nt = "<http://example.org/s> <http://example.org/p> \"caf\\u00E9 \\U0001F600\" ."
            g = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g, EX("s"), EX("p")))
            @test string(obj) == "café 😀"
        end
    end

    # ── 13. UCHAR escapes in IRIs ─────────────────────────────────────
    @testset "IRI UCHAR escapes" begin
        @testset "\\u escape decoded in IRI" begin
            nt = "<http://example.org/caf\\u00E9> <http://example.org/p> \"x\" ."
            g = parse_rdf(nt, NTriplesFormat())
            @test first(g).subject == URIRef("http://example.org/café")
        end

        @testset "\\U escape decoded in IRI" begin
            nt = "<http://example.org/s> <http://example.org/p> <http://example.org/\\U0001F600> ."
            g = parse_rdf(nt, NTriplesFormat())
            @test first(g).object == URIRef("http://example.org/😀")
        end

        @testset "non-UCHAR backslash escape in IRI throws" begin
            nt = "<http://example.org/a\\nb> <http://example.org/p> \"x\" ."
            @test_throws ArgumentError parse_rdf(nt, NTriplesFormat())
        end

        @testset "surrogate in IRI escape throws" begin
            nt = "<http://example.org/\\uD800> <http://example.org/p> \"x\" ."
            @test_throws ArgumentError parse_rdf(nt, NTriplesFormat())
        end
    end

    # ── 14. Grammar coverage: bnode labels, lang tags, comments ──────
    @testset "grammar coverage" begin
        @testset "bnode label with dash" begin
            g = parse_rdf("_:b-1 <http://example.org/p> \"x\" .", NTriplesFormat())
            @test first(g).subject == BNode("b-1")
        end

        @testset "bnode label with internal dot" begin
            g = parse_rdf("_:b.1 <http://example.org/p> \"x\" .", NTriplesFormat())
            @test first(g).subject == BNode("b.1")
        end

        @testset "bnode label followed by statement dot" begin
            g = parse_rdf("<http://example.org/s> <http://example.org/p> _:b1.", NTriplesFormat())
            @test first(g).object == BNode("b1")
        end

        @testset "bnode label with non-ASCII PN_CHARS" begin
            g = parse_rdf("_:bé <http://example.org/p> \"x\" .", NTriplesFormat())
            @test first(g).subject == BNode("bé")
        end

        @testset "bnode label starting with digit" begin
            g = parse_rdf("_:0b <http://example.org/p> \"x\" .", NTriplesFormat())
            @test first(g).subject == BNode("0b")
        end

        @testset "language tag with digits in subtag" begin
            nt = "<http://example.org/s> <http://example.org/p> \"orthographie\"@de-1996 ."
            g = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g, EX("s"), EX("p")))
            @test lang(obj) == "de-1996"
        end

        @testset "end-of-line comment after dot" begin
            nt = "<http://example.org/s> <http://example.org/p> \"x\" . # trailing comment"
            g = parse_rdf(nt, NTriplesFormat())
            @test length(g) == 1
        end

        @testset "malformed line throws with line number" begin
            nt = "<http://example.org/s> <http://example.org/p> \"ok\" .\nthis is garbage\n"
            err = try
                parse_rdf(nt, NTriplesFormat())
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test contains(err.msg, "line 2")
        end

        @testset "missing final dot throws" begin
            @test_throws ArgumentError parse_rdf("<http://example.org/s> <http://example.org/p> \"x\"", NTriplesFormat())
        end

        @testset "trailing garbage after dot throws" begin
            @test_throws ArgumentError parse_rdf("<http://example.org/s> <http://example.org/p> \"x\" . garbage", NTriplesFormat())
        end

        @testset "parse_ntriples_vec throws on invalid line" begin
            @test_throws ArgumentError RDFLib.parse_ntriples_vec(IOBuffer("not a triple\n"))
            ts = RDFLib.parse_ntriples_vec(IOBuffer("_:b-1 <http://example.org/p> \"x\" . # c\n"))
            @test length(ts) == 1
            @test ts[1].subject == BNode("b-1")
        end
    end

    # ── 15. Serializer IRI escaping ───────────────────────────────────
    @testset "serializer IRI escaping" begin
        @testset "space in IRI escaped as \\u0020" begin
            g = RDFGraph()
            add!(g, URIRef("http://example.org/a b"), EX("p"), Literal("x"))
            nt = serialize(g, NTriplesFormat())
            @test contains(nt, "\\u0020")
            @test !contains(nt, "<http://example.org/a b>")
            g2 = parse_rdf(nt, NTriplesFormat())
            @test first(g2).subject == URIRef("http://example.org/a b")
        end

        @testset "'>' in IRI escaped as \\u003E" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), URIRef("http://example.org/a>b"))
            nt = serialize(g, NTriplesFormat())
            @test contains(uppercase(nt), "\\U003E")
            g2 = parse_rdf(nt, NTriplesFormat())
            @test first(g2).object == URIRef("http://example.org/a>b")
        end

        @testset "control char in IRI escaped" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), URIRef("http://example.org/a\tb"))
            nt = serialize(g, NTriplesFormat())
            @test contains(nt, "\\u0009")
            g2 = parse_rdf(nt, NTriplesFormat())
            @test first(g2).object == URIRef("http://example.org/a\tb")
        end

        @testset "other control chars in literal use \\u form" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal("a\x01b"))
            nt = serialize(g, NTriplesFormat())
            @test contains(nt, "\\u0001")
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test string(obj) == "a\x01b"
        end
    end

    # ── 16. SPARQL 1.2 directional literals ───────────────────────────
    @testset "directional literals" begin
        @testset "parse @en--ltr" begin
            nt = "<http://example.org/s> <http://example.org/p> \"hello\"@en--ltr ."
            g = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g, EX("s"), EX("p")))
            @test obj isa Literal
            @test lang(obj) == "en"
            @test obj.direction == "ltr"
        end

        @testset "parse @he--rtl with subtag" begin
            nt = "<http://example.org/s> <http://example.org/p> \"שלום\"@he-IL--rtl ."
            g = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g, EX("s"), EX("p")))
            @test lang(obj) == "he-il"
            @test obj.direction == "rtl"
        end

        @testset "serialize and roundtrip direction" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal("hello", lang="en", direction="ltr"))
            nt = serialize(g, NTriplesFormat())
            @test contains(nt, "\"hello\"@en--ltr")
            g2 = parse_rdf(nt, NTriplesFormat())
            obj = first(objects(g2, EX("s"), EX("p")))
            @test obj == Literal("hello", lang="en", direction="ltr")
        end

        @testset "invalid direction throws" begin
            nt = "<http://example.org/s> <http://example.org/p> \"x\"@en--xyz ."
            @test_throws ArgumentError parse_rdf(nt, NTriplesFormat())
        end
    end

    # ── 17. RDF 1.2 triple terms ───────────────────────────────────────
    @testset "triple terms" begin
        inner = TripleTerm(EX("s"), EX("p"), EX("o"))

        @testset "parse RDF 1.2 '<<( )>>' triple term in object position" begin
            nt = "<http://example.org/x> <http://example.org/q> <<( <http://example.org/s> <http://example.org/p> <http://example.org/o> )>> ."
            g = parse_rdf(nt, NTriplesFormat())
            @test first(g).object == inner
        end

        @testset "nested triple terms (object position only)" begin
            nt = "<http://example.org/x> <http://example.org/q> <<( <http://example.org/a> <http://example.org/b> <<( <http://example.org/s> <http://example.org/p> <http://example.org/o> )>> )>> ."
            g = parse_rdf(nt, NTriplesFormat())
            @test first(g).object == TripleTerm(EX("a"), EX("b"), inner)
        end

        @testset "reifier '<< >>' form rejected in N-Triples 1.2" begin
            nt = "<http://example.org/x> <http://example.org/q> << <http://example.org/s> <http://example.org/p> <http://example.org/o> >> ."
            @test_throws ArgumentError parse_rdf(nt, NTriplesFormat())
        end

        @testset "triple term as subject rejected" begin
            nt = "<<( <http://example.org/s> <http://example.org/p> <http://example.org/o> )>> <http://example.org/q> <http://example.org/z> ."
            @test_throws ArgumentError parse_rdf(nt, NTriplesFormat())
        end

        @testset "triple term serialization roundtrip" begin
            g = RDFGraph()
            add!(g, EX("x"), EX("q"), inner)
            nt = serialize(g, NTriplesFormat())
            @test contains(nt, "<<( <http://example.org/s> <http://example.org/p> <http://example.org/o> )>>")
            g2 = parse_rdf(nt, NTriplesFormat())
            @test length(g2) == 1
            for t in g
                @test t in g2
            end
        end

        @testset "unterminated triple term throws" begin
            nt = "<http://example.org/x> <http://example.org/q> <<( <http://example.org/s> <http://example.org/p> <http://example.org/o> ."
            @test_throws ArgumentError parse_rdf(nt, NTriplesFormat())
        end
    end

    @testset "relative IRIs rejected (no base in N-Triples)" begin
        # nt-syntax-bad-uri-06/07/08/09: relative IRIs are illegal.
        @test_throws ArgumentError parse_rdf("<s> <http://a/p> <http://a/o> .", NTriplesFormat())
        @test_throws ArgumentError parse_rdf("<http://a/s> <p> <http://a/o> .", NTriplesFormat())
        @test_throws ArgumentError parse_rdf("<http://a/s> <http://a/p> <o> .", NTriplesFormat())
        @test_throws ArgumentError parse_rdf("<http://a/s> <http://a/p> \"x\"^^<dt> .", NTriplesFormat())
        # Absolute IRIs still parse.
        g = parse_rdf("<http://a/s> <http://a/p> <http://a/o> .", NTriplesFormat())
        @test Triple(URIRef("http://a/s"), URIRef("http://a/p"), URIRef("http://a/o")) in g
    end
end
