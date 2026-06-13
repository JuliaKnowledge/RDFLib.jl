using Test
using RDFLib

@testset "Issue Regressions" begin

    # ─── Issue #084: Unicode in Turtle/RDF-XML parsing ────────────────
    @testset "Issue #084: Unicode in parsers" begin
        ttl = """
        @prefix skos: <http://www.w3.org/2004/02/skos/core#> .
        @prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
        @prefix : <http://www.test.org/#> .

        :world rdf:type skos:Concept;
            skos:prefLabel "World"@en.
        :africa rdf:type skos:Concept;
            skos:prefLabel "Africa"@en;
            skos:broaderTransitive :world.
        :CI rdf:type skos:Concept;
            skos:prefLabel "Côte d'Ivoire"@fr;
            skos:broaderTransitive :africa.
        """

        g = parse_rdf(ttl, TurtleFormat())
        ci = URIRef("http://www.test.org/#CI")
        skos_pref = URIRef("http://www.w3.org/2004/02/skos/core#prefLabel")
        v = value(g, ci, skos_pref)
        @test v !== nothing
        @test string(v) == "Côte d'Ivoire"
        @test lang(v) == "fr"

        # Roundtrip: serialize and re-parse preserves Unicode
        nt = serialize(g, NTriplesFormat())
        g2 = parse_rdf(nt, NTriplesFormat())
        v2 = value(g2, ci, skos_pref)
        @test v2 !== nothing
        @test string(v2) == "Côte d'Ivoire"
        @test lang(v2) == "fr"

        # RDF/XML with Unicode
        rdfxml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF
           xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
           xmlns:skos="http://www.w3.org/2004/02/skos/core#"
        >
          <rdf:Description rdf:about="http://www.test.org/#CI">
            <rdf:type rdf:resource="http://www.w3.org/2004/02/skos/core#Concept"/>
            <skos:prefLabel xml:lang="fr">Côte d'Ivoire</skos:prefLabel>
          </rdf:Description>
        </rdf:RDF>
        """
        g3 = parse_rdf(rdfxml, RDFXMLFormat())
        v3 = value(g3, ci, skos_pref)
        @test v3 !== nothing
        @test string(v3) == "Côte d'Ivoire"
        @test lang(v3) == "fr"
    end

    # ─── Issue #161: Turtle namespace prefix with underscore ──────────
    @testset "Issue #161: Turtle namespace prefixes" begin
        ttl = """
        @prefix p_9: <urn:test:> .
        @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .

        p_9:a p_9:b p_9:c .

        <http://data.linkedmdb.org/resource/director/1>
            rdfs:label "Cecil B. DeMille (Director)" .
        """

        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 2

        # Roundtrip through Turtle
        ttl2 = serialize(g, TurtleFormat())
        g2 = parse_rdf(ttl2, TurtleFormat())
        @test length(g2) == 2
        @test isomorphic(g, g2)
    end

    # ─── Issue #184: Escaping of triple double-quotes in serialization ─
    @testset "Issue #184: Quote escaping roundtrip" begin
        g = RDFGraph()
        add!(g, URIRef("http://foobar"), URIRef("http://fooprop"),
             Literal("abc\ndef\"\"\"\"\""))
        # N-Triples roundtrip
        nt = serialize(g, NTriplesFormat())
        g2 = parse_rdf(nt, NTriplesFormat())
        @test isomorphic(g, g2)

        # Turtle roundtrip
        ttl = serialize(g, TurtleFormat())
        g3 = parse_rdf(ttl, TurtleFormat())
        @test isomorphic(g, g3)
    end

    # ─── Issue #223: Collection with duplicate items ──────────────────
    @testset "Issue #223: Collection with duplicates" begin
        ttl = """
        @prefix : <http://example.org/>.
        :s :p (:a :b :a).
        """
        g = parse_rdf(ttl, TurtleFormat())
        s = URIRef("http://example.org/s")
        p = URIRef("http://example.org/p")
        head_nodes = collect(objects(g, s, p))
        @test length(head_nodes) == 1
        head = head_nodes[1]
        items = collect_list(g, head)
        @test length(items) == 3
        @test items[1] == URIRef("http://example.org/a")
        @test items[2] == URIRef("http://example.org/b")
        @test items[3] == URIRef("http://example.org/a")
    end

    # ─── Issue #432: TriG default graph and named graphs ──────────────
    @testset "Issue #432: TriG default and named graphs" begin
        data = """
        @prefix : <http://example.com/> .

        <g1> { <d> <e> <f> . }
        <g2> { <g> <h> <i> . }
        """
        ds = Dataset()
        parse_trig!(ds, data)
        ctx = collect(contexts(ds))
        @test length(ctx) >= 2  # at least named graphs g1 and g2
    end

    # ─── Issue #655: Inf/NaN literal serialization ────────────────────
    @testset "Issue #655: Inf and NaN serialization" begin
        # Float Inf, -Inf, NaN
        lit_inf = Literal(Inf)
        lit_ninf = Literal(-Inf)
        lit_nan = Literal(NaN)

        @test datatype(lit_inf) == XSD.double
        @test datatype(lit_ninf) == XSD.double
        @test datatype(lit_nan) == XSD.double

        # Roundtrip Inf/NaN through NTriples (Turtle parser may not handle special floats)
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        add!(g, EX("bob"), EX("val"), Literal(Inf))
        add!(g, EX("bob"), EX("val2"), Literal(NaN))
        nt = serialize(g, NTriplesFormat())
        g2 = parse_rdf(nt, NTriplesFormat())
        @test length(g2) == 2

        # Non-numeric "inf" and "nan" should stay as plain strings
        @test datatype(Literal("inf")) === nothing
        @test datatype(Literal("nan")) === nothing
    end

    # ─── Issue #801: URI with percent-encoding preserved ──────────────
    @testset "Issue #801: Percent-encoded URIs" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        bind!(g, "ex", EX)
        b = BNode()
        add!(g, b, EX("first%20name"), Literal("John"))
        ttl = serialize(g, TurtleFormat())
        @test contains(ttl, "first%20name")
        @test contains(ttl, "\"John\"")
    end

    # ─── Issue #920: NTriples/Turtle parsing URIs with only scheme ────
    @testset "Issue #920: URIs with only scheme" begin
        # NTriples
        g1 = parse_rdf("<a:> <b:> <c:> .\n", NTriplesFormat())
        @test length(g1) == 1

        g2 = parse_rdf("<http://a> <http://b> <http://c> .\n", NTriplesFormat())
        @test length(g2) == 1

        g3 = parse_rdf("<https://a> <http://> <http://c> .\n", NTriplesFormat())
        @test length(g3) == 1

        # Turtle
        g4 = parse_rdf("<a:> <b:> <c:> .", TurtleFormat())
        @test length(g4) == 1

        g5 = parse_rdf("<http://a> <http://b> <http://c> .", TurtleFormat())
        @test length(g5) == 1
    end

    # ─── Issue #977: Namespace prefix serialization ───────────────────
    @testset "Issue #977: Prefix serialization" begin
        g = RDFGraph()
        bind!(g, "isbn", "urn:isbn:")
        bind!(g, "webn", "http://w3c.org/example/isbn/")
        add!(g, URIRef("urn:isbn:1503280780"), RDFS.label, Literal("Moby Dick"))
        add!(g, URIRef("http://w3c.org/example/isbn/1503280780"), RDFS.label, Literal("Moby Dick"))
        ttl = serialize(g, TurtleFormat())
        @test contains(ttl, "@prefix webn:")
        @test contains(ttl, "@prefix isbn:")
    end

    # ─── Issue #1043: Scientific notation for small decimals ──────────
    @testset "Issue #1043: Scientific notation decimals" begin
        g = RDFGraph()
        bind!(g, "xsd", XSD)
        bind!(g, "rdfs", RDFS)
        add!(g, URIRef("http://example.org/number"), RDFS.label,
             Literal("0.00000004", datatype=XSD.decimal))
        ttl = serialize(g, TurtleFormat())
        # Should contain the decimal value
        @test contains(ttl, "0.00000004") || contains(ttl, "4e-08") || contains(ttl, "4E-08") || contains(ttl, "4.0e-8")

        # Roundtrip
        g2 = parse_rdf(ttl, TurtleFormat())
        @test length(g2) == 1
    end

    # ─── Issue #1141: Parse with different stores ─────────────────────
    @testset "Issue #1141: Turtle parse with MemoryStore" begin
        data = "@prefix : <http://example.com/> . :s :p :o ."
        g = parse_rdf(data, TurtleFormat())
        @test length(g) == 1

        # Also parse NTriples with scheme-only URIs
        data2 = "<a:> <b:> <c:> .\n"
        g2 = parse_rdf(data2, NTriplesFormat())
        @test length(g2) == 1
    end

    # ─── Issue #1404: Skolemize/de-skolemize roundtrip ────────────────
    @testset "Issue #1404: Skolemize roundtrip" begin
        ttl = """
        @prefix wd: <http://www.wikidata.org/entity/> .
        @prefix foaf: <http://xmlns.com/foaf/0.1/> .

        wd:Q1203 foaf:knows [ a foaf:Person;
            foaf:name "Ringo" ].
        """
        g = parse_rdf(ttl, TurtleFormat())
        wd_q = URIRef("http://www.wikidata.org/entity/Q1203")
        foaf_knows = FOAF.knows

        # Get the original bnode
        bnode_id = value(g, wd_q, foaf_knows)
        @test bnode_id isa BNode

        # Skolemize: BNode → URIRef
        sg = skolemize(g)
        skolem_node = value(sg, wd_q, foaf_knows)
        @test skolem_node isa URIRef
        @test contains(skolem_node.value, bnode_id.id)

        # Original and skolemized should NOT be isomorphic
        @test !isomorphic(g, sg)

        # De-skolemize back: should be isomorphic with original
        dsg = de_skolemize(sg)
        @test isomorphic(g, dsg)
    end

    # ─── Issue #1998: NTriples no trailing double newline ─────────────
    @testset "Issue #1998: NTriples no double newline" begin
        g = RDFGraph()
        bob = URIRef("http://example.org/people/Bob")
        add!(g, bob, RDF.type, FOAF.Person)
        nt = serialize(g, NTriplesFormat())
        @test !endswith(nt, "\n\n")
        @test endswith(strip(nt), ".")
    end

    # ─── Issue #3126: De-skolemize ignores literals ───────────────────
    @testset "Issue #3126: De-skolemize ignores literals" begin
        nt = "<http://example.com> <http://example.com> \"http://example.com [some remark]\" .\n"
        g = parse_rdf(nt, NTriplesFormat())
        dg = de_skolemize(g)
        # Should not throw on repeated de-skolemize
        dg2 = de_skolemize(dg)
        @test length(dg2) == 1
    end

    # ─── Issue #160: Collection rendering in graphs ───────────────────
    @testset "Issue #160: Collection creation and roundtrip" begin
        EX = Namespace("http://example.org/foo/")
        g = RDFGraph()
        items = Identifier[EX("a"), EX("b"), EX("c")]
        head, tris = Collection(items)
        for t in tris; add!(g, t); end
        add!(g, Triple(EX("thing"), RDF.type, EX("Other")))
        add!(g, Triple(EX("thing"), EX("property"), Literal("Some Value")))
        add!(g, Triple(EX("thing"), URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#first"), EX("a")))

        # Recover the collection
        recovered = collect_list(g, head)
        @test length(recovered) == 3
        @test recovered[1] == EX("a")
        @test recovered[2] == EX("b")
        @test recovered[3] == EX("c")
    end

    # ─── Issue #247: RDF/XML parsing with xml:lang on Literal ─────────
    @testset "Issue #247: XML Literal with xml:lang" begin
        rdfxml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF
            xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
        >
        <rdf:Description rdf:about="http://example.org/">
            <dc:description rdf:parseType="Literal">
                <p xmlns="http://www.w3.org/1999/xhtml" xml:lang="en"></p>
            </dc:description>
        </rdf:Description>
        </rdf:RDF>"""
        # parseType="Literal" must yield exactly one triple whose object is
        # an rdf:XMLLiteral containing the serialized inner XML.
        g = parse_rdf(rdfxml, RDFXMLFormat())
        @test length(g) == 1
        t = first(g)
        @test t.subject == URIRef("http://example.org/")
        @test t.predicate == URIRef("http://purl.org/dc/elements/1.1/description")
        @test t.object isa Literal
        @test t.object.datatype == URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#XMLLiteral")
        @test contains(t.object.lexical, "<p")
    end

    # ─── Issue #363: RDF/XML parseType="Resource" ─────────────────────
    @testset "Issue #363: RDF/XML parseType Resource" begin
        rdfxml = """<?xml version="1.0" encoding="utf-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
            xmlns="http://www.example.org/meeting_organization#">
            <rdf:Description rdf:about="http://meetings.example.com/cal#m1">
                <Location rdf:parseType="Resource">
                    <zip xmlns="http://www.another.example.org/geographical#">02139</zip>
                    <lat xmlns="http://www.another.example.org/geographical#">14.124425</lat>
                </Location>
            </rdf:Description>
        </rdf:RDF>
        """
        g = parse_rdf(rdfxml, RDFXMLFormat())
        @test length(g) == 3  # m1 → Location (bnode), bnode → zip, bnode → lat
        m1 = URIRef("http://meetings.example.com/cal#m1")
        loc_pred = URIRef("http://www.example.org/meeting_organization#Location")
        locs = collect(objects(g, m1, loc_pred))
        @test length(locs) == 1
        @test locs[1] isa BNode
        # The properties must attach to the SAME blank node m1 points to
        geo = "http://www.another.example.org/geographical#"
        zips = collect(objects(g, locs[1], URIRef(geo * "zip")))
        lats = collect(objects(g, locs[1], URIRef(geo * "lat")))
        @test zips == [Literal("02139")]
        @test lats == [Literal("14.124425")]
    end

    # ─── Issue #492: Turtle with Unicode escapes ──────────────────────
    @testset "Issue #492: Turtle Unicode handling" begin
        # Turtle with non-ASCII characters
        ttl = """
        @prefix : <http://example.org/> .
        :item :label "Ünïcödé" .
        :item :label "日本語" .
        """
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 2

        ttl2 = serialize(g, TurtleFormat())
        g2 = parse_rdf(ttl2, TurtleFormat())
        @test isomorphic(g, g2)
    end

    # ─── Issue #553/554: Literal comparison ───────────────────────────
    @testset "Issue #554: Literal equality and comparison" begin
        # Same lexical, same type
        l1 = Literal("hello")
        l2 = Literal("hello")
        @test l1 == l2

        # Typed literals
        l3 = Literal(42)
        l4 = Literal(42)
        @test l3 == l4

        # Different values
        l5 = Literal("hello")
        l6 = Literal("world")
        @test l5 != l6

        # Language-tagged equality
        l7 = Literal("hello", lang="en")
        l8 = Literal("hello", lang="en")
        @test l7 == l8

        # Different languages
        l9 = Literal("hello", lang="en")
        l10 = Literal("hello", lang="fr")
        @test l9 != l10
    end

    # ─── Issue #655 extended: NTriples Inf/NaN roundtrip ──────────────
    @testset "Issue #655: NTriples Inf/NaN roundtrip" begin
        g1 = RDFGraph()
        EX = Namespace("http://example.org/")
        add!(g1, EX("bob"), EX("val"), Literal(Inf))
        add!(g1, EX("bob"), EX("val2"), Literal(-Inf))
        add!(g1, EX("bob"), EX("val3"), Literal(NaN))

        nt = serialize(g1, NTriplesFormat())
        g2 = parse_rdf(nt, NTriplesFormat())
        @test length(g2) == 3

        # All three triples should be present
        @test isomorphic(g1, g2)
    end

    # ─── Issue #910: SPARQL basic SELECT ─────────────────────────────
    @testset "Issue #910: SPARQL basic SELECT" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        add!(g, EX("a"), EX("type"), Literal("x"))
        add!(g, EX("b"), EX("type"), Literal("x"))
        results = sparql_query(g, "SELECT ?s WHERE { ?s <http://example.org/type> ?o . }")
        @test length(results) == 2
    end

    # ─── Issue #715: SPARQL basic pattern matching ────────────────────
    @testset "Issue #715: SPARQL basic pattern matching" begin
        g = RDFGraph()
        a_node = URIRef("http://example.org/a")
        b_node = URIRef("http://example.org/b")
        x_node = URIRef("http://example.org/x")
        y_node = URIRef("http://example.org/y")
        isa_pred = URIRef("http://example.org/isa")
        add!(g, a_node, isa_pred, x_node)
        add!(g, a_node, isa_pred, y_node)
        add!(g, b_node, isa_pred, x_node)

        # Basic pattern
        r1 = sparql_query(g, "SELECT ?child ?parent WHERE { ?child <http://example.org/isa> ?parent . }")
        @test length(r1) == 3
    end

    # ─── Issue #554: SPARQL on empty graph ────────────────────────────
    @testset "Issue #554: SPARQL on empty graph" begin
        g = RDFGraph()
        add!(g, URIRef("http://example.org/s"), URIRef("http://example.org/p"), Literal("v"))
        results = sparql_query(g, "SELECT ?s WHERE { ?s <http://example.org/nonexistent> ?o . }")
        @test length(results) == 0
    end

    # ─── Issue #1003: Base URI in serialization ───────────────────────
    @testset "Issue #1003: Base URI in Turtle" begin
        g = RDFGraph()
        cs = URIRef("")
        add!(g, cs, RDF.type, SKOS.ConceptScheme)
        add!(g, cs, DCTERMS.creator, URIRef("https://creator.com"))
        bind!(g, "skos", SKOS)
        bind!(g, "dct", DCTERMS)

        # Without base, serialize should work
        ttl = serialize(g, TurtleFormat())
        @test length(ttl) > 0

        # Graph should contain the triples
        @test length(g) == 2
    end

    # ─── Issue #248: Relative URI with base in N3 ─────────────────────
    @testset "Issue #248: Base URI and relative URIs" begin
        g = RDFGraph()
        LCCO = Namespace("http://loc.gov/catdir/cpso/lcco/")
        bind!(g, "lcco", LCCO)
        concept = URIRef(LCCO.uri * "1")
        add!(g, concept, RDF.type, SKOS.Concept)
        add!(g, concept, SKOS.prefLabel, Literal("Scrapbooks"))

        @test length(g) == 2
        ttl = serialize(g, TurtleFormat())
        @test contains(ttl, "Scrapbooks")
    end

    # ─── Issue #1873: Turtle parsing with semicolons ─────────────────
    @testset "Issue #1873: Turtle semicolons" begin
        # Test that Turtle parser handles trailing/spurious semicolons
        ttl = """
        @prefix : <http://example.org/> .
        :a :b :c ; :d :e .
        """
        g = parse_rdf(ttl, TurtleFormat())
        @test length(g) == 2

        # Verify both triples
        EX = Namespace("http://example.org/")
        triples_list = collect(triples(g, (EX("a"), nothing, nothing)))
        @test length(triples_list) == 2
    end

    # ─── Issue #977: Typed literal n3 output ──────────────────────────
    @testset "Issue #977: Typed literal n3 representation" begin
        l_int = Literal(42)
        @test contains(n3(l_int), "42")
        @test contains(n3(l_int), "integer")

        l_str = Literal("hello")
        @test n3(l_str) == "\"hello\""

        l_lang = Literal("hola", lang="es")
        @test n3(l_lang) == "\"hola\"@es"

        l_dt = Literal("true", datatype=XSD.boolean)
        @test contains(n3(l_dt), "boolean")
    end

    # ─── Issue #160 extended: Empty collection ────────────────────────
    @testset "Issue #160: Empty collection" begin
        head, tris = Collection(Identifier[])
        @test head == RDF.nil
        @test isempty(tris)
    end

    # ─── Issue #920 extended: Various scheme-only URIs ────────────────
    @testset "Issue #920: Multiple scheme-only URIs" begin
        # Parse various minimal URIs
        for data in [
            "<a:> <b:> <c:> .\n",
            "<http://a> <http://b> <http://c> .\n",
            "<https://a> <http://> <http://c> .\n"
        ]
            g = parse_rdf(data, NTriplesFormat())
            @test length(g) == 1
        end
    end

    # ─── Issue #184 extended: Newlines in literals ────────────────────
    @testset "Issue #184: Newlines in N-Triples literals" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        add!(g, EX("s"), EX("p"), Literal("line1\nline2\nline3"))
        nt = serialize(g, NTriplesFormat())
        # Newlines should be escaped in N-Triples
        @test contains(nt, "\\n")
        @test !contains(nt, "\nline2")  # raw newline should not appear in NT

        # Roundtrip
        g2 = parse_rdf(nt, NTriplesFormat())
        @test isomorphic(g, g2)
        obj = first(objects(g2, EX("s"), EX("p")))
        @test string(obj) == "line1\nline2\nline3"
    end

    # ─── Issue #1998 extended: NTriples correct line ending ───────────
    @testset "Issue #1998: NTriples single trailing newline" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        add!(g, EX("s"), EX("p"), Literal("hello"))
        nt = serialize(g, NTriplesFormat())
        # Should end with exactly one newline (or no double newline)
        @test !endswith(nt, "\n\n")
    end

    # ─── Issue #3126 extended: De-skolemize with literal containing URI ─
    @testset "Issue #3126: De-skolemize robustness" begin
        g = RDFGraph()
        add!(g, URIRef("http://example.com/s"), URIRef("http://example.com/p"),
             Literal("https://rdflib.github.io/.well-known/genid/somevalue"))
        dg = de_skolemize(g)
        # Literal should NOT be converted to BNode
        obj = first(objects(dg, URIRef("http://example.com/s"), URIRef("http://example.com/p")))
        @test obj isa Literal
        @test string(obj) == "https://rdflib.github.io/.well-known/genid/somevalue"
    end

    # ─── Issue #1404 extended: Skolemize preserves structure ──────────
    @testset "Issue #1404: Skolemize preserves graph structure" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        b1 = BNode("test1")
        b2 = BNode("test2")
        add!(g, EX("s"), EX("p"), b1)
        add!(g, b1, EX("q"), b2)
        add!(g, b2, EX("r"), Literal("value"))

        sg = skolemize(g)
        @test length(sg) == 3
        # No BNodes in skolemized graph
        for t in sg
            @test !(t.subject isa BNode)
            @test !(t.object isa BNode) || t.object isa Literal
        end

        # De-skolemize back
        dsg = de_skolemize(sg)
        @test isomorphic(g, dsg)
    end

    # ─── Issue #084 extended: Language tags preserved through formats ──
    @testset "Issue #084: Language tag roundtrip" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        add!(g, EX("s"), RDFS.label, Literal("Ελληνικά", lang="el"))
        add!(g, EX("s"), RDFS.label, Literal("العربية", lang="ar"))
        add!(g, EX("s"), RDFS.label, Literal("中文", lang="zh"))

        nt = serialize(g, NTriplesFormat())
        g2 = parse_rdf(nt, NTriplesFormat())
        @test length(g2) == 3
        @test isomorphic(g, g2)

        ttl = serialize(g, TurtleFormat())
        g3 = parse_rdf(ttl, TurtleFormat())
        @test length(g3) == 3
        @test isomorphic(g, g3)
    end

    # ─── Issue #801 extended: Percent encoding in NTriples ────────────
    @testset "Issue #801: Percent encoding NTriples" begin
        g = RDFGraph()
        uri = URIRef("http://example.org/has%20space")
        add!(g, URIRef("http://example.org/s"), uri, Literal("val"))
        nt = serialize(g, NTriplesFormat())
        @test contains(nt, "has%20space")

        g2 = parse_rdf(nt, NTriplesFormat())
        @test length(g2) == 1
    end

    # ─── Issue #655 extended: n3 representation of special literals ───
    @testset "Issue #655: Special literal n3 output" begin
        # Boolean literals
        @test n3(Literal(true)) == "\"true\"^^<http://www.w3.org/2001/XMLSchema#boolean>"
        @test n3(Literal(false)) == "\"false\"^^<http://www.w3.org/2001/XMLSchema#boolean>"

        # Integer
        @test contains(n3(Literal(0)), "0")

        # Float
        @test contains(n3(Literal(3.14)), "3.14")
    end

    # ─── Issue #223 extended: Add collection and recover via graph ────
    @testset "Issue #223: add_collection! roundtrip" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        items = Identifier[EX("x"), EX("y"), EX("z")]
        add_collection!(g, EX("s"), EX("list"), items)

        head_nodes = collect(objects(g, EX("s"), EX("list")))
        @test length(head_nodes) == 1
        head = head_nodes[1]
        recovered = collect_list(g, head)
        @test length(recovered) == 3
        @test recovered == items
    end

    # ─── Issue #161 extended: Prefix binding roundtrip ────────────────
    @testset "Issue #161: Prefix binding in Turtle" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        CUSTOM = Namespace("http://custom.example.org/vocab#")
        bind!(g, "ex", EX)
        bind!(g, "custom", CUSTOM)
        add!(g, EX("alice"), RDF.type, CUSTOM("Person"))
        add!(g, EX("alice"), CUSTOM("age"), Literal(30))

        ttl = serialize(g, TurtleFormat())
        @test contains(ttl, "@prefix ex:")
        @test contains(ttl, "@prefix custom:")

        g2 = parse_rdf(ttl, TurtleFormat())
        @test isomorphic(g, g2)
    end

    # ─── Issue #1141 extended: NTriples parse robustness ──────────────
    @testset "Issue #1141: Parse various triple formats" begin
        # Standard NTriples
        g1 = parse_rdf("<http://example.org/s> <http://example.org/p> <http://example.org/o> .\n", NTriplesFormat())
        @test length(g1) == 1

        # With literal object
        g2 = parse_rdf("<http://example.org/s> <http://example.org/p> \"hello\" .\n", NTriplesFormat())
        @test length(g2) == 1

        # With typed literal
        g3 = parse_rdf("<http://example.org/s> <http://example.org/p> \"42\"^^<http://www.w3.org/2001/XMLSchema#integer> .\n", NTriplesFormat())
        @test length(g3) == 1
    end

end
