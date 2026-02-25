using Test
using RDFLib

@testset "Format Roundtrip" begin
    EX = Namespace("http://example.org/")

    # Helper: check structural equality (ignoring BNode IDs)
    function graphs_structurally_equal(g1::RDFGraph, g2::RDFGraph)
        length(g1) == length(g2) || return false
        # Check all non-BNode triples match exactly
        for t in g1
            if !(t.subject isa BNode || t.object isa BNode)
                t in g2 || return false
            end
        end
        true
    end

    # Helper: check exact equality (no BNodes)
    function graphs_equal(g1::RDFGraph, g2::RDFGraph)
        length(g1) == length(g2) && all(t -> t in g2, g1)
    end

    # ═══════════════════════════════════════════════════════════════════
    # 1. Simple graph (3 triples, URIs only) through all formats
    # ═══════════════════════════════════════════════════════════════════
    @testset "Simple URI-only graph" begin
        function make_simple()
            g = RDFGraph()
            bind!(g, "ex", EX)
            add!(g, EX("alice"), RDF.type, EX("Person"))
            add!(g, EX("alice"), EX("knows"), EX("bob"))
            add!(g, EX("bob"), RDF.type, EX("Person"))
            g
        end

        @testset "NTriples roundtrip" begin
            g = make_simple()
            s = serialize(g, NTriplesFormat())
            g2 = parse_rdf(s, NTriplesFormat())
            @test graphs_equal(g, g2)
        end

        @testset "Turtle roundtrip" begin
            g = make_simple()
            s = serialize(g, TurtleFormat())
            g2 = parse_rdf(s, TurtleFormat())
            @test graphs_equal(g, g2)
        end

        @testset "N3 roundtrip" begin
            g = make_simple()
            s = serialize(g, N3Format())
            g2 = parse_rdf(s, N3Format())
            @test graphs_equal(g, g2)
        end

        @testset "RDF/XML roundtrip" begin
            g = make_simple()
            s = serialize(g, RDFXMLFormat())
            g2 = parse_rdf(s, RDFXMLFormat())
            @test graphs_equal(g, g2)
        end

        @testset "JSON-LD roundtrip" begin
            g = make_simple()
            s = serialize(g, JSONLDFormat())
            g2 = parse_rdf(s, JSONLDFormat())
            @test graphs_equal(g, g2)
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # 2. Literals with datatypes through all formats
    # ═══════════════════════════════════════════════════════════════════
    @testset "Datatyped literals" begin
        function make_typed()
            g = RDFGraph()
            bind!(g, "ex", EX)
            add!(g, EX("s"), EX("age"), Literal(42))
            add!(g, EX("s"), EX("score"), Literal(3.14))
            add!(g, EX("s"), EX("active"), Literal(true))
            g
        end

        @testset "NTriples roundtrip" begin
            g = make_typed()
            s = serialize(g, NTriplesFormat())
            g2 = parse_rdf(s, NTriplesFormat())
            @test length(g2) == 3
            age = first(objects(g2, EX("s"), EX("age")))
            @test convert(Any, age) == 42
        end

        @testset "Turtle roundtrip" begin
            g = make_typed()
            s = serialize(g, TurtleFormat())
            g2 = parse_rdf(s, TurtleFormat())
            @test length(g2) == 3
            active = first(objects(g2, EX("s"), EX("active")))
            @test convert(Any, active) == true
        end

        @testset "RDF/XML roundtrip" begin
            g = make_typed()
            s = serialize(g, RDFXMLFormat())
            g2 = parse_rdf(s, RDFXMLFormat())
            @test length(g2) == 3
            age = first(objects(g2, EX("s"), EX("age")))
            @test convert(Any, age) == 42
        end

        @testset "JSON-LD roundtrip" begin
            g = make_typed()
            s = serialize(g, JSONLDFormat())
            g2 = parse_rdf(s, JSONLDFormat())
            @test length(g2) == 3
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # 3. Language-tagged literals through all formats
    # ═══════════════════════════════════════════════════════════════════
    @testset "Language-tagged literals" begin
        function make_lang()
            g = RDFGraph()
            bind!(g, "ex", EX)
            add!(g, EX("s"), RDFS.label, Literal("Hello", lang="en"))
            add!(g, EX("s"), RDFS.label, Literal("Bonjour", lang="fr"))
            g
        end

        @testset "NTriples roundtrip" begin
            g = make_lang()
            s = serialize(g, NTriplesFormat())
            g2 = parse_rdf(s, NTriplesFormat())
            @test length(g2) == 2
            labels = collect(objects(g2, EX("s"), RDFS.label))
            langs = Set(lang(l) for l in labels)
            @test "en" in langs
            @test "fr" in langs
        end

        @testset "Turtle roundtrip" begin
            g = make_lang()
            s = serialize(g, TurtleFormat())
            g2 = parse_rdf(s, TurtleFormat())
            @test length(g2) == 2
            labels = collect(objects(g2, EX("s"), RDFS.label))
            @test any(l -> string(l) == "Hello" && lang(l) == "en", labels)
        end

        @testset "N3 roundtrip" begin
            g = make_lang()
            s = serialize(g, N3Format())
            g2 = parse_rdf(s, N3Format())
            @test length(g2) == 2
        end

        @testset "JSON-LD roundtrip" begin
            g = make_lang()
            s = serialize(g, JSONLDFormat())
            g2 = parse_rdf(s, JSONLDFormat())
            @test length(g2) == 2
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # 4. BNodes through formats that support them
    # ═══════════════════════════════════════════════════════════════════
    @testset "BNode roundtrip" begin
        function make_bnode()
            g = RDFGraph()
            bind!(g, "ex", EX)
            b = BNode()
            add!(g, EX("alice"), EX("address"), b)
            add!(g, b, EX("city"), Literal("London"))
            g
        end

        @testset "NTriples roundtrip" begin
            g = make_bnode()
            s = serialize(g, NTriplesFormat())
            g2 = parse_rdf(s, NTriplesFormat())
            @test length(g2) == 2
            cities = collect(objects(g2, nothing, EX("city")))
            @test length(cities) >= 1
            @test string(cities[1]) == "London"
        end

        @testset "Turtle roundtrip" begin
            g = make_bnode()
            s = serialize(g, TurtleFormat())
            g2 = parse_rdf(s, TurtleFormat())
            @test length(g2) == 2
        end

        @testset "N3 roundtrip" begin
            g = make_bnode()
            s = serialize(g, N3Format())
            g2 = parse_rdf(s, N3Format())
            @test length(g2) == 2
        end

        @testset "RDF/XML roundtrip" begin
            g = make_bnode()
            s = serialize(g, RDFXMLFormat())
            g2 = parse_rdf(s, RDFXMLFormat())
            @test length(g2) == 2
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # 5. Unicode content through all formats
    # ═══════════════════════════════════════════════════════════════════
    @testset "Unicode content" begin
        function make_unicode()
            g = RDFGraph()
            bind!(g, "ex", EX)
            add!(g, EX("s"), RDFS.label, Literal("日本語テスト"))
            add!(g, EX("s"), EX("desc"), Literal("héllo wörld café"))
            g
        end

        @testset "NTriples roundtrip" begin
            g = make_unicode()
            s = serialize(g, NTriplesFormat())
            g2 = parse_rdf(s, NTriplesFormat())
            @test length(g2) == 2
            lbl = first(objects(g2, EX("s"), RDFS.label))
            @test string(lbl) == "日本語テスト"
        end

        @testset "Turtle roundtrip" begin
            g = make_unicode()
            s = serialize(g, TurtleFormat())
            g2 = parse_rdf(s, TurtleFormat())
            @test length(g2) == 2
            desc = first(objects(g2, EX("s"), EX("desc")))
            @test string(desc) == "héllo wörld café"
        end

        @testset "N3 roundtrip" begin
            g = make_unicode()
            s = serialize(g, N3Format())
            g2 = parse_rdf(s, N3Format())
            @test length(g2) == 2
        end

        @testset "RDF/XML roundtrip" begin
            g = make_unicode()
            s = serialize(g, RDFXMLFormat())
            g2 = parse_rdf(s, RDFXMLFormat())
            @test length(g2) == 2
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # 6. Large graph (20+ triples) roundtrip
    # ═══════════════════════════════════════════════════════════════════
    @testset "Large graph roundtrip" begin
        function make_large()
            g = RDFGraph()
            bind!(g, "ex", EX)
            for i in 1:25
                s = EX("item$i")
                add!(g, s, RDF.type, EX("Item"))
                add!(g, s, RDFS.label, Literal("Item $i"))
                add!(g, s, EX("index"), Literal(i))
            end
            g
        end

        @testset "NTriples roundtrip" begin
            g = make_large()
            s = serialize(g, NTriplesFormat())
            g2 = parse_rdf(s, NTriplesFormat())
            @test length(g2) == 75
        end

        @testset "Turtle roundtrip" begin
            g = make_large()
            s = serialize(g, TurtleFormat())
            g2 = parse_rdf(s, TurtleFormat())
            @test length(g2) == 75
        end

        @testset "RDF/XML roundtrip" begin
            g = make_large()
            s = serialize(g, RDFXMLFormat())
            g2 = parse_rdf(s, RDFXMLFormat())
            @test length(g2) == 75
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # 7. Mixed content roundtrip
    # ═══════════════════════════════════════════════════════════════════
    @testset "Mixed content roundtrip" begin
        function make_mixed()
            g = RDFGraph()
            bind!(g, "ex", EX)
            b = BNode("addr1")
            add!(g, EX("alice"), RDF.type, EX("Person"))
            add!(g, EX("alice"), RDFS.label, Literal("Alice", lang="en"))
            add!(g, EX("alice"), EX("age"), Literal(30))
            add!(g, EX("alice"), EX("address"), b)
            add!(g, b, EX("city"), Literal("London"))
            add!(g, EX("alice"), EX("knows"), EX("bob"))
            g
        end

        @testset "NTriples roundtrip" begin
            g = make_mixed()
            s = serialize(g, NTriplesFormat())
            g2 = parse_rdf(s, NTriplesFormat())
            @test length(g2) == 6
        end

        @testset "Turtle roundtrip" begin
            g = make_mixed()
            s = serialize(g, TurtleFormat())
            g2 = parse_rdf(s, TurtleFormat())
            @test length(g2) == 6
        end

        @testset "N3 roundtrip" begin
            g = make_mixed()
            s = serialize(g, N3Format())
            g2 = parse_rdf(s, N3Format())
            @test length(g2) == 6
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # 8. Collections (RDF lists) through Turtle/N3
    # ═══════════════════════════════════════════════════════════════════
    @testset "Collections roundtrip" begin
        function make_collection()
            g = RDFGraph()
            bind!(g, "ex", EX)
            add_collection!(g, EX("s"), EX("items"), [EX("a"), EX("b"), EX("c")])
            g
        end

        @testset "Turtle roundtrip" begin
            g = make_collection()
            n = length(g)
            s = serialize(g, TurtleFormat())
            g2 = parse_rdf(s, TurtleFormat())
            @test length(g2) == n
        end

        @testset "N3 roundtrip" begin
            g = make_collection()
            n = length(g)
            s = serialize(g, N3Format())
            g2 = parse_rdf(s, N3Format())
            @test length(g2) == n
        end

        @testset "NTriples roundtrip" begin
            g = make_collection()
            n = length(g)
            s = serialize(g, NTriplesFormat())
            g2 = parse_rdf(s, NTriplesFormat())
            @test length(g2) == n
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # 9. Nested blank nodes through Turtle/N3/RDF-XML
    # ═══════════════════════════════════════════════════════════════════
    @testset "Nested blank nodes" begin
        function make_nested_bnodes()
            g = RDFGraph()
            bind!(g, "ex", EX)
            b1 = BNode("outer")
            b2 = BNode("inner")
            add!(g, EX("alice"), EX("address"), b1)
            add!(g, b1, EX("street"), Literal("123 Main St"))
            add!(g, b1, EX("geo"), b2)
            add!(g, b2, EX("lat"), Literal(51.5))
            add!(g, b2, EX("lon"), Literal(-0.1))
            g
        end

        @testset "Turtle roundtrip" begin
            g = make_nested_bnodes()
            s = serialize(g, TurtleFormat())
            g2 = parse_rdf(s, TurtleFormat())
            @test length(g2) == 5
        end

        @testset "N3 roundtrip" begin
            g = make_nested_bnodes()
            s = serialize(g, N3Format())
            g2 = parse_rdf(s, N3Format())
            @test length(g2) == 5
        end

        @testset "RDF/XML roundtrip" begin
            g = make_nested_bnodes()
            s = serialize(g, RDFXMLFormat())
            g2 = parse_rdf(s, RDFXMLFormat())
            @test length(g2) == 5
        end

        @testset "NTriples roundtrip" begin
            g = make_nested_bnodes()
            s = serialize(g, NTriplesFormat())
            g2 = parse_rdf(s, NTriplesFormat())
            @test length(g2) == 5
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # 10. Empty graph roundtrip
    # ═══════════════════════════════════════════════════════════════════
    @testset "Empty graph roundtrip" begin
        @testset "NTriples" begin
            g = RDFGraph()
            s = serialize(g, NTriplesFormat())
            g2 = parse_rdf(s, NTriplesFormat())
            @test length(g2) == 0
        end

        @testset "Turtle" begin
            g = RDFGraph()
            s = serialize(g, TurtleFormat())
            g2 = parse_rdf(s, TurtleFormat())
            @test length(g2) == 0
        end

        @testset "RDF/XML" begin
            g = RDFGraph()
            s = serialize(g, RDFXMLFormat())
            g2 = parse_rdf(s, RDFXMLFormat())
            @test length(g2) == 0
        end

        @testset "N3" begin
            g = RDFGraph()
            s = serialize(g, N3Format())
            g2 = parse_rdf(s, N3Format())
            @test length(g2) == 0
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # 11. N-Quads roundtrip with Dataset
    # ═══════════════════════════════════════════════════════════════════
    @testset "N-Quads Dataset roundtrip" begin
        @testset "default graph" begin
            ds = Dataset()
            add!(ds, EX("s"), EX("p"), Literal("hello"))
            nq = serialize(ds, NQuadsFormat())
            ds2 = parse_nquads(nq)
            @test length(get_graph(ds2)) == 1
        end

        @testset "named graphs" begin
            ds = Dataset()
            add!(ds, EX("s"), EX("p"), Literal("default"))
            add!(ds, EX("s"), EX("p"), Literal("g1"), EX("g1"))
            nq = serialize(ds, NQuadsFormat())
            ds2 = parse_nquads(nq)
            @test length(get_graph(ds2)) == 1
            @test length(get_graph(ds2, EX("g1"))) == 1
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # 12. TriG roundtrip with Dataset
    # ═══════════════════════════════════════════════════════════════════
    @testset "TriG Dataset roundtrip" begin
        @testset "default + named graph" begin
            ds = Dataset()
            bind!(ds, "ex", EX)
            add!(ds, EX("s1"), EX("p"), Literal("default"))
            add!(ds, EX("s2"), EX("p"), Literal("named"), EX("g1"))
            trig = serialize(ds, TriGFormat())
            ds2 = parse_trig(trig)
            @test length(get_graph(ds2)) == 1
            g1 = get_graph(ds2, EX("g1"))
            @test !isnothing(g1) && length(g1) == 1
        end

        @testset "multiple named graphs" begin
            ds = Dataset()
            bind!(ds, "ex", EX)
            add!(ds, EX("a"), EX("p"), Literal("1"), EX("g1"))
            add!(ds, EX("b"), EX("p"), Literal("2"), EX("g2"))
            trig = serialize(ds, TriGFormat())
            ds2 = parse_trig(trig)
            @test length(get_graph(ds2, EX("g1"))) == 1
            @test length(get_graph(ds2, EX("g2"))) == 1
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # 13. HexTuples roundtrip
    # ═══════════════════════════════════════════════════════════════════
    @testset "HexTuples roundtrip" begin
        @testset "URI-only graph" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), EX("o"))
            hext = serialize_hextuples(g)
            ds = parse_hextuples(hext)
            g2 = get_graph(ds)
            @test length(g2) == 1
            @test first(g2).subject == EX("s")
        end

        @testset "typed literals" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("age"), Literal(42))
            hext = serialize_hextuples(g)
            ds = parse_hextuples(hext)
            g2 = get_graph(ds)
            @test convert(Any, first(g2).object) == 42
        end

        @testset "language tags" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("name"), Literal("bonjour", lang="fr"))
            hext = serialize_hextuples(g)
            ds = parse_hextuples(hext)
            g2 = get_graph(ds)
            @test lang(first(g2).object) == "fr"
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # 14. LongTurtle roundtrip (parses as standard Turtle)
    # ═══════════════════════════════════════════════════════════════════
    @testset "LongTurtle roundtrip" begin
        @testset "simple roundtrip" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal("hello"))
            add!(g, EX("s"), EX("age"), Literal(42))
            lt = serialize_longturtle(g)
            g2 = parse_rdf(lt, TurtleFormat())
            @test length(g2) == 2
            for t in g
                @test t in g2
            end
        end

        @testset "mixed content" begin
            g = RDFGraph()
            bind!(g, "ex", EX)
            add!(g, EX("alice"), RDF.type, EX("Person"))
            add!(g, EX("alice"), RDFS.label, Literal("Alice", lang="en"))
            add!(g, EX("alice"), EX("age"), Literal(30))
            lt = serialize_longturtle(g)
            g2 = parse_rdf(lt, TurtleFormat())
            @test length(g2) == 3
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # 15. Cross-format roundtrips
    # ═══════════════════════════════════════════════════════════════════
    @testset "Cross-format: NTriples → Turtle → NTriples" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        add!(g, EX("alice"), EX("age"), Literal(30))
        add!(g, EX("alice"), EX("knows"), EX("bob"))
        nt1 = serialize(g, NTriplesFormat())
        g2 = parse_rdf(nt1, NTriplesFormat())
        ttl = serialize(g2, TurtleFormat())
        g3 = parse_rdf(ttl, TurtleFormat())
        nt2 = serialize(g3, NTriplesFormat())
        g4 = parse_rdf(nt2, NTriplesFormat())
        @test graphs_equal(g, g4)
    end

    @testset "Cross-format: Turtle → RDF/XML → Turtle" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        add!(g, EX("alice"), RDFS.label, Literal("Alice"))
        ttl = serialize(g, TurtleFormat())
        g2 = parse_rdf(ttl, TurtleFormat())
        xml = serialize(g2, RDFXMLFormat())
        g3 = parse_rdf(xml, RDFXMLFormat())
        @test graphs_equal(g, g3)
    end

    @testset "Cross-format: Turtle → N3 → Turtle" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("s"), EX("p"), Literal("hello"))
        add!(g, EX("s"), EX("age"), Literal(42))
        ttl = serialize(g, TurtleFormat())
        g2 = parse_rdf(ttl, TurtleFormat())
        n3 = serialize(g2, N3Format())
        g3 = parse_rdf(n3, N3Format())
        @test graphs_equal(g, g3)
    end

    @testset "Cross-format: NTriples → JSON-LD → NTriples" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        add!(g, EX("alice"), EX("knows"), EX("bob"))
        nt1 = serialize(g, NTriplesFormat())
        g2 = parse_rdf(nt1, NTriplesFormat())
        jld = serialize(g2, JSONLDFormat())
        g3 = parse_rdf(jld, JSONLDFormat())
        @test graphs_equal(g, g3)
    end

    # ═══════════════════════════════════════════════════════════════════
    # 16. Isomorphism-based roundtrip for BNode graphs
    # ═══════════════════════════════════════════════════════════════════
    @testset "Isomorphic roundtrip with BNodes" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        b1 = BNode()
        b2 = BNode()
        add!(g, EX("s"), EX("ref"), b1)
        add!(g, b1, EX("p"), Literal("a"))
        add!(g, EX("s"), EX("ref"), b2)
        add!(g, b2, EX("p"), Literal("b"))

        @testset "NTriples isomorphic" begin
            s = serialize(g, NTriplesFormat())
            g2 = parse_rdf(s, NTriplesFormat())
            @test isomorphic(g, g2)
        end

        @testset "Turtle isomorphic" begin
            s = serialize(g, TurtleFormat())
            g2 = parse_rdf(s, TurtleFormat())
            @test isomorphic(g, g2)
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # 17. TriX roundtrip
    # ═══════════════════════════════════════════════════════════════════
    @testset "TriX roundtrip" begin
        @testset "single graph" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("p"), Literal("hello"))
            xml = serialize_trix(g)
            ds = parse_trix(xml)
            g2 = get_graph(ds)
            @test length(g2) == 1
        end

        @testset "named graphs" begin
            ds = Dataset()
            add!(ds, EX("s1"), EX("p"), Literal("default"))
            add!(ds, EX("s2"), EX("p"), Literal("named"), EX("g1"))
            xml = serialize_trix(ds)
            ds2 = parse_trix(xml)
            @test length(get_graph(ds2)) == 1
            @test length(get_graph(ds2, EX("g1"))) == 1
        end
    end
end
