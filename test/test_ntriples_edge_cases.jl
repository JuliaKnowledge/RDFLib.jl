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
end
