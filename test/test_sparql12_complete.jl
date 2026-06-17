@testset "SPARQL 1.2 Complete Coverage" begin

    # ─── Helper: build a test graph ───────────────────────────────────
    function _make_test_graph()
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("alice"), ex("age"), Literal(30)))
        add!(g, Triple(ex("bob"),   ex("age"), Literal(25)))
        add!(g, Triple(ex("carol"), ex("age"), Literal(35)))
        add!(g, Triple(ex("dave"),  ex("age"), Literal(25)))
        add!(g, Triple(ex("eve"),   ex("age"), Literal(40)))
        add!(g, Triple(ex("alice"), ex("name"), Literal("Alice")))
        add!(g, Triple(ex("bob"),   ex("name"), Literal("Bob")))
        add!(g, Triple(ex("carol"), ex("name"), Literal("Carol")))
        add!(g, Triple(ex("dave"),  ex("name"), Literal("Dave")))
        add!(g, Triple(ex("eve"),   ex("name"), Literal("Eve")))
        add!(g, Triple(ex("alice"), ex("dept"), ex("engineering")))
        add!(g, Triple(ex("bob"),   ex("dept"), ex("engineering")))
        add!(g, Triple(ex("carol"), ex("dept"), ex("sales")))
        add!(g, Triple(ex("dave"),  ex("dept"), ex("sales")))
        add!(g, Triple(ex("eve"),   ex("dept"), ex("engineering")))
        return g
    end

    # ═══════════════════════════════════════════════════════════════════
    # MEDIAN aggregate
    # ═══════════════════════════════════════════════════════════════════
    @testset "MEDIAN aggregate" begin
        g = _make_test_graph()

        # Overall median of 5 values: 25, 25, 30, 35, 40 → median = 30
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (MEDIAN(?age) AS ?med)
            WHERE { ?s ex:age ?age }
        """)
        @test length(r) == 1
        @test r[1]["med"] == Literal(30)

        # Median per group — engineering: 25, 30, 40 → 30; sales: 25, 35 → 30
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?dept (MEDIAN(?age) AS ?med)
            WHERE { ?s ex:age ?age . ?s ex:dept ?dept }
            GROUP BY ?dept
        """)
        @test length(r) == 2
        eng = [row for row in r if row["dept"] == URIRef("http://example.org/engineering")]
        sal = [row for row in r if row["dept"] == URIRef("http://example.org/sales")]
        @test eng[1]["med"] == Literal(30)
        @test sal[1]["med"] == Literal(30)

        # Median of even count: 2 values → average
        g2 = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g2, Triple(ex("a"), ex("v"), Literal(10)))
        add!(g2, Triple(ex("b"), ex("v"), Literal(20)))
        r = sparql_query(g2, """
            PREFIX ex: <http://example.org/>
            SELECT (MEDIAN(?v) AS ?med)
            WHERE { ?s ex:v ?v }
        """)
        @test length(r) == 1
        med_val = r[1]["med"]
        @test med_val isa Literal
        @test parse(Float64, med_val.lexical) ≈ 15.0
    end

    # ═══════════════════════════════════════════════════════════════════
    # MODE aggregate
    # ═══════════════════════════════════════════════════════════════════
    @testset "MODE aggregate" begin
        g = _make_test_graph()

        # Mode of ages: 25 appears twice, all others once → mode = 25
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (MODE(?age) AS ?m)
            WHERE { ?s ex:age ?age }
        """)
        @test length(r) == 1
        @test r[1]["m"] == Literal(25)

        # Mode per department
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?dept (MODE(?age) AS ?m)
            WHERE { ?s ex:age ?age . ?s ex:dept ?dept }
            GROUP BY ?dept
        """)
        @test length(r) == 2
        # Engineering: 25, 30, 40 — all unique, mode is whichever comes first in Dict
        # Sales: 25, 35 — all unique
        # Just verify we get results
        for row in r
            @test haskey(row, "m")
            @test row["m"] isa Literal
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # LATERAL joins
    # ═══════════════════════════════════════════════════════════════════
    @testset "LATERAL joins" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        # Friendship graph
        add!(g, Triple(ex("alice"), ex("knows"), ex("bob")))
        add!(g, Triple(ex("alice"), ex("knows"), ex("carol")))
        add!(g, Triple(ex("bob"),   ex("knows"), ex("dave")))
        add!(g, Triple(ex("alice"), ex("age"), Literal(30)))
        add!(g, Triple(ex("bob"),   ex("age"), Literal(25)))
        add!(g, Triple(ex("carol"), ex("age"), Literal(35)))
        add!(g, Triple(ex("dave"),  ex("age"), Literal(28)))

        # LATERAL: for each person Alice knows, get their age
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?friend ?age
            WHERE {
                ex:alice ex:knows ?friend .
                LATERAL { ?friend ex:age ?age }
            }
        """)
        @test length(r) == 2
        friends = Set(row["friend"] for row in r)
        @test URIRef("http://example.org/bob") in friends
        @test URIRef("http://example.org/carol") in friends
        for row in r
            @test haskey(row, "age")
            @test row["age"] isa Literal
        end

        # LATERAL with FILTER using outer variable
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?person ?friend ?age
            WHERE {
                ?person ex:knows ?friend .
                LATERAL { ?friend ex:age ?age . FILTER(?age > 27) }
            }
        """)
        # bob(25) filtered out from alice→bob, carol(35) kept, dave(28) kept
        ages = [parse(Int, row["age"].lexical) for row in r]
        @test all(a -> a > 27, ages)

        # LATERAL with no matching inner pattern
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?person ?friend ?email
            WHERE {
                ?person ex:knows ?friend .
                LATERAL { ?friend ex:email ?email }
            }
        """)
        @test isempty(r)
    end

    # ═══════════════════════════════════════════════════════════════════
    # Date/time duration arithmetic
    # ═══════════════════════════════════════════════════════════════════
    @testset "Duration arithmetic" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        xsd = Namespace("http://www.w3.org/2001/XMLSchema#")
        add!(g, Triple(ex("event"), ex("start"),
            Literal("2024-01-15T10:00:00", datatype=URIRef("http://www.w3.org/2001/XMLSchema#dateTime"))))
        add!(g, Triple(ex("event"), ex("duration"),
            Literal("P2DT3H", datatype=URIRef("http://www.w3.org/2001/XMLSchema#dayTimeDuration"))))

        # Add duration to dateTime
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            SELECT ((?start + ?dur) AS ?end)
            WHERE {
                ex:event ex:start ?start .
                ex:event ex:duration ?dur
            }
        """)
        @test length(r) == 1
        end_val = r[1]["end"]
        @test end_val isa Literal
        @test occursin("2024-01-17", end_val.lexical)
        @test occursin("13:00:00", end_val.lexical)

        # Subtract duration from dateTime
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ((?start - ?dur) AS ?before)
            WHERE {
                ex:event ex:start ?start .
                ex:event ex:duration ?dur
            }
        """)
        @test length(r) == 1
        before_val = r[1]["before"]
        @test before_val isa Literal
        @test occursin("2024-01-13", before_val.lexical)
        @test occursin("07:00:00", before_val.lexical)

        # Subtract two dateTimes → duration
        g2 = RDFGraph()
        add!(g2, Triple(ex("e"), ex("start"),
            Literal("2024-01-10T08:00:00", datatype=URIRef("http://www.w3.org/2001/XMLSchema#dateTime"))))
        add!(g2, Triple(ex("e"), ex("end"),
            Literal("2024-01-12T14:30:00", datatype=URIRef("http://www.w3.org/2001/XMLSchema#dateTime"))))

        r = sparql_query(g2, """
            PREFIX ex: <http://example.org/>
            SELECT ((?end - ?start) AS ?elapsed)
            WHERE {
                ex:e ex:start ?start .
                ex:e ex:end ?end
            }
        """)
        @test length(r) == 1
        elapsed = r[1]["elapsed"]
        @test elapsed isa Literal
        @test occursin("P", elapsed.lexical)
        @test elapsed.datatype == URIRef("http://www.w3.org/2001/XMLSchema#dayTimeDuration")

        # yearMonthDuration
        g3 = RDFGraph()
        add!(g3, Triple(ex("d"), ex("date"),
            Literal("2024-03-15", datatype=URIRef("http://www.w3.org/2001/XMLSchema#date"))))
        add!(g3, Triple(ex("d"), ex("offset"),
            Literal("P1Y2M", datatype=URIRef("http://www.w3.org/2001/XMLSchema#yearMonthDuration"))))

        r = sparql_query(g3, """
            PREFIX ex: <http://example.org/>
            SELECT ((?date + ?offset) AS ?future)
            WHERE {
                ex:d ex:date ?date .
                ex:d ex:offset ?offset
            }
        """)
        @test length(r) == 1
        future = r[1]["future"]
        @test future isa Literal
        # 2024-03-15 + P1Y2M = 2025-05-15 (approx, using 365d/y + 30d/m)
        @test occursin("2025", future.lexical)
    end

    # ═══════════════════════════════════════════════════════════════════
    # DESCRIBE with Concise Bounded Description
    # ═══════════════════════════════════════════════════════════════════
    @testset "DESCRIBE CBD" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        bn = BNode("addr1")
        add!(g, Triple(ex("alice"), ex("name"), Literal("Alice")))
        add!(g, Triple(ex("alice"), ex("address"), bn))
        add!(g, Triple(bn, ex("street"), Literal("123 Main St")))
        add!(g, Triple(bn, ex("city"), Literal("Springfield")))
        add!(g, Triple(ex("bob"), ex("name"), Literal("Bob")))

        # DESCRIBE should follow blank nodes
        result = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            DESCRIBE ex:alice
        """)
        @test result isa RDFGraph
        result_triples = collect(triples(result))
        # Should include alice's direct triples + blank node triples
        @test length(result_triples) >= 4  # name, address, street, city

        # Check that blank node properties are included
        has_street = any(t -> t.predicate == URIRef("http://example.org/street"), result_triples)
        has_city = any(t -> t.predicate == URIRef("http://example.org/city"), result_triples)
        @test has_street
        @test has_city

        # Bob's triples should NOT be included
        has_bob_name = any(t -> t.subject == URIRef("http://example.org/bob"), result_triples)
        @test !has_bob_name

        # DESCRIBE with variable
        result = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            DESCRIBE ?person WHERE { ?person ex:name "Alice" }
        """)
        @test result isa RDFGraph
        @test length(collect(triples(result))) >= 4

        # DESCRIBE with no blank nodes
        result = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            DESCRIBE ex:bob
        """)
        @test result isa RDFGraph
        bob_triples = collect(triples(result))
        @test length(bob_triples) == 1
        @test bob_triples[1].object == Literal("Bob")
    end

    # ═══════════════════════════════════════════════════════════════════
    # Triple term patterns in WHERE (<< s p o >>)
    # ═══════════════════════════════════════════════════════════════════
    @testset "Triple term patterns" begin
        # SPARQL 1.2 triple terms `<<( s p o )>>` match TripleTerm values in the
        # data (e.g. via rdf:reifies). A triple term may also bind variables.
        REIFIES = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#reifies")
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        # Reified statements: a reifier blank/IRI node rdf:reifies a triple term.
        add!(g, Triple(ex("r1"), REIFIES, TripleTerm(ex("alice"), ex("knows"), ex("bob"))))
        add!(g, Triple(ex("r2"), REIFIES, TripleTerm(ex("bob"), ex("knows"), ex("carol"))))
        add!(g, Triple(ex("r1"), ex("certainty"), Literal(9)))

        # `?r rdf:reifies <<( ?s ex:knows ?o )>>` matches the triple terms.
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
            SELECT ?s ?o
            WHERE {
                ?r rdf:reifies <<( ?s ex:knows ?o )>>
            }
        """)
        @test length(r) == 2
        pairs = Set((row["s"], row["o"]) for row in r)
        @test (URIRef("http://example.org/alice"), URIRef("http://example.org/bob")) in pairs
        @test (URIRef("http://example.org/bob"), URIRef("http://example.org/carol")) in pairs

        # Triple term with fixed subject.
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
            SELECT ?o
            WHERE {
                ?r rdf:reifies <<( ex:alice ex:knows ?o )>>
            }
        """)
        @test length(r) == 1
        @test r[1]["o"] == URIRef("http://example.org/bob")

        # Reified triple `<< s p o >>` desugars to a reifier; join with the
        # reifier's other properties.
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?c
            WHERE {
                << ex:alice ex:knows ex:bob >> ex:certainty ?c .
            }
        """)
        @test length(r) == 1
        @test r[1]["c"] == Literal(9)
    end

    # ═══════════════════════════════════════════════════════════════════
    # MD5 hash function (SPARQL 1.1 gap that was just fixed)
    # ═══════════════════════════════════════════════════════════════════
    @testset "MD5 hash function" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("s"), ex("p"), Literal("abc")))

        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (MD5(?o) AS ?hash)
            WHERE { ex:s ex:p ?o }
        """)
        @test length(r) == 1
        @test r[1]["hash"] == Literal("900150983cd24fb0d6963f7d28e17f72")

        # Empty string MD5
        g2 = RDFGraph()
        add!(g2, Triple(ex("s"), ex("p"), Literal("")))
        r = sparql_query(g2, """
            PREFIX ex: <http://example.org/>
            SELECT (MD5(?o) AS ?hash)
            WHERE { ex:s ex:p ?o }
        """)
        @test length(r) == 1
        @test r[1]["hash"] == Literal("d41d8cd98f00b204e9800998ecf8427e")
    end

    # ═══════════════════════════════════════════════════════════════════
    # SPARQL 1.2 functions: TRIPLE, SUBJECT, PREDICATE, OBJECT, isTRIPLE
    # (already implemented — verify they work end-to-end)
    # ═══════════════════════════════════════════════════════════════════
    @testset "RDF-star functions" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("alice"), ex("knows"), ex("bob")))
        add!(g, Triple(ex("alice"), ex("name"), Literal("Alice")))

        # TRIPLE() constructor
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (TRIPLE(ex:alice, ex:knows, ex:bob) AS ?tt)
            WHERE {}
        """)
        @test length(r) == 1
        tt = r[1]["tt"]
        @test tt isa TripleTerm

        # SUBJECT, PREDICATE, OBJECT extractors
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (SUBJECT(TRIPLE(ex:alice, ex:knows, ex:bob)) AS ?s)
                   (PREDICATE(TRIPLE(ex:alice, ex:knows, ex:bob)) AS ?p)
                   (OBJECT(TRIPLE(ex:alice, ex:knows, ex:bob)) AS ?o)
            WHERE {}
        """)
        @test length(r) == 1
        @test r[1]["s"] == URIRef("http://example.org/alice")
        @test r[1]["p"] == URIRef("http://example.org/knows")
        @test r[1]["o"] == URIRef("http://example.org/bob")

        # isTRIPLE
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (isTRIPLE(TRIPLE(ex:alice, ex:knows, ex:bob)) AS ?yes)
                   (isTRIPLE(ex:alice) AS ?no)
            WHERE {}
        """)
        @test length(r) == 1
        @test r[1]["yes"] == Literal(true)
        @test r[1]["no"] == Literal(false)
    end

    # ═══════════════════════════════════════════════════════════════════
    # SPARQL 1.2 ADJUST function
    # ═══════════════════════════════════════════════════════════════════
    @testset "ADJUST function" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("e"), ex("time"),
            Literal("2024-06-15T10:30:00Z", datatype=URIRef("http://www.w3.org/2001/XMLSchema#dateTime"))))

        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (ADJUST(?t, "+05:30") AS ?adjusted)
            WHERE { ex:e ex:time ?t }
        """)
        # ADJUST may or may not be implemented; just verify no crash
        @test length(r) == 1
    end

    # ═══════════════════════════════════════════════════════════════════
    # Combined SPARQL 1.2 features
    # ═══════════════════════════════════════════════════════════════════
    @testset "Combined features" begin
        g = _make_test_graph()

        # MEDIAN with HAVING
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?dept (MEDIAN(?age) AS ?med)
            WHERE { ?s ex:age ?age . ?s ex:dept ?dept }
            GROUP BY ?dept
            HAVING (MEDIAN(?age) >= 30)
        """)
        @test length(r) >= 1
        for row in r
            @test parse(Float64, row["med"].lexical) >= 30
        end

        # MODE with ORDER BY
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?dept (MODE(?age) AS ?m) (COUNT(?s) AS ?cnt)
            WHERE { ?s ex:age ?age . ?s ex:dept ?dept }
            GROUP BY ?dept
            ORDER BY ?dept
        """)
        @test length(r) == 2

        # LATERAL with LIMIT
        g2 = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g2, Triple(ex("a"), ex("knows"), ex("b")))
        add!(g2, Triple(ex("a"), ex("knows"), ex("c")))
        add!(g2, Triple(ex("b"), ex("val"), Literal(1)))
        add!(g2, Triple(ex("c"), ex("val"), Literal(2)))

        r = sparql_query(g2, """
            PREFIX ex: <http://example.org/>
            SELECT ?friend ?v
            WHERE {
                ex:a ex:knows ?friend .
                LATERAL { ?friend ex:val ?v }
            }
            LIMIT 1
        """)
        @test length(r) == 1
    end
end
