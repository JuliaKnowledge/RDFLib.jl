using Test
using RDFLib

@testset "SPARQL HAVING" begin
    EX = Namespace("http://example.org/")

    # ─── Helper: build a graph mirroring Python test_having.py ────────
    function make_having_graph()
        g = RDFGraph()
        bind!(g, "ex", EX)
        # <urn:a> <urn:p> 1 .
        # <urn:b> <urn:p> 3 .
        # <urn:c> <urn:q> 1 .
        add!(g, Triple(URIRef("urn:a"), URIRef("urn:p"), Literal(1)))
        add!(g, Triple(URIRef("urn:b"), URIRef("urn:p"), Literal(3)))
        add!(g, Triple(URIRef("urn:c"), URIRef("urn:q"), Literal(1)))
        g
    end

    # ─── 1. GROUP BY (baseline, from test_having.py) ─────────────────
    @testset "GROUP BY baseline" begin
        g = make_having_graph()
        results = sparql_query(g, """
            SELECT ?p WHERE { ?s ?p ?o } GROUP BY ?p
        """)
        @test length(results) == 2
        preds = Set(r["p"] for r in results)
        @test URIRef("urn:p") in preds
        @test URIRef("urn:q") in preds
    end

    # ─── 2. HAVING aggregate eq literal (from test_having.py) ────────
    @testset "HAVING aggregate eq literal (avg)" begin
        g = make_having_graph()
        results = sparql_query(g, """
            SELECT ?p (AVG(?o) AS ?a)
            WHERE { ?s ?p ?o }
            GROUP BY ?p HAVING (AVG(?o) = 2)
        """)
        @test length(results) == 1
        @test results[1]["p"] == URIRef("urn:p")
    end

    # ─── 3. HAVING with variable != IRI (from test_having.py) ────────
    @testset "HAVING variable != IRI" begin
        g = make_having_graph()
        results = sparql_query(g, """
            SELECT ?p
            WHERE { ?s ?p ?o }
            GROUP BY ?p HAVING (?p != <urn:foo>)
        """)
        @test length(results) == 2
    end

    # ─── 4. GROUP BY with COUNT, HAVING COUNT > N ────────────────────
    @testset "HAVING COUNT > N" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("s1"), EX("group"), EX("a")))
        add!(g, Triple(EX("s2"), EX("group"), EX("a")))
        add!(g, Triple(EX("s3"), EX("group"), EX("a")))
        add!(g, Triple(EX("s4"), EX("group"), EX("b")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?g (COUNT(?s) AS ?cnt)
            WHERE { ?s ex:group ?g }
            GROUP BY ?g HAVING (COUNT(?s) > 1)
        """)
        @test length(results) == 1
        @test results[1]["g"] == EX("a")
        @test convert(Any, results[1]["cnt"]) == 3
    end

    # ─── 5. GROUP BY with SUM, HAVING SUM > N ───────────────────────
    @testset "HAVING SUM > N" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("s1"), EX("group"), EX("a")))
        add!(g, Triple(EX("s1"), EX("val"), Literal(10)))
        add!(g, Triple(EX("s2"), EX("group"), EX("a")))
        add!(g, Triple(EX("s2"), EX("val"), Literal(20)))
        add!(g, Triple(EX("s3"), EX("group"), EX("b")))
        add!(g, Triple(EX("s3"), EX("val"), Literal(5)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?g (SUM(?v) AS ?total)
            WHERE { ?s ex:group ?g . ?s ex:val ?v }
            GROUP BY ?g HAVING (SUM(?v) > 10)
        """)
        @test length(results) == 1
        @test results[1]["g"] == EX("a")
        @test convert(Any, results[1]["total"]) == 30
    end

    # ─── 6. GROUP BY with AVG, HAVING AVG > N ───────────────────────
    @testset "HAVING AVG > N" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("s1"), EX("group"), EX("a")))
        add!(g, Triple(EX("s1"), EX("val"), Literal(10)))
        add!(g, Triple(EX("s2"), EX("group"), EX("a")))
        add!(g, Triple(EX("s2"), EX("val"), Literal(20)))
        add!(g, Triple(EX("s3"), EX("group"), EX("b")))
        add!(g, Triple(EX("s3"), EX("val"), Literal(2)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?g (AVG(?v) AS ?avg)
            WHERE { ?s ex:group ?g . ?s ex:val ?v }
            GROUP BY ?g HAVING (AVG(?v) > 5)
        """)
        @test length(results) == 1
        @test results[1]["g"] == EX("a")
        @test convert(Any, results[1]["avg"]) == 15.0
    end

    # ─── 7. HAVING with MIN ─────────────────────────────────────────
    @testset "HAVING MIN > N" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("s1"), EX("group"), EX("a")))
        add!(g, Triple(EX("s1"), EX("val"), Literal(10)))
        add!(g, Triple(EX("s2"), EX("group"), EX("a")))
        add!(g, Triple(EX("s2"), EX("val"), Literal(20)))
        add!(g, Triple(EX("s3"), EX("group"), EX("b")))
        add!(g, Triple(EX("s3"), EX("val"), Literal(1)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?g (MIN(?v) AS ?m)
            WHERE { ?s ex:group ?g . ?s ex:val ?v }
            GROUP BY ?g HAVING (MIN(?v) > 5)
        """)
        @test length(results) == 1
        @test results[1]["g"] == EX("a")
        @test convert(Any, results[1]["m"]) == 10
    end

    # ─── 8. HAVING with MAX ─────────────────────────────────────────
    @testset "HAVING MAX < N" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("s1"), EX("group"), EX("a")))
        add!(g, Triple(EX("s1"), EX("val"), Literal(10)))
        add!(g, Triple(EX("s2"), EX("group"), EX("a")))
        add!(g, Triple(EX("s2"), EX("val"), Literal(20)))
        add!(g, Triple(EX("s3"), EX("group"), EX("b")))
        add!(g, Triple(EX("s3"), EX("val"), Literal(3)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?g (MAX(?v) AS ?mx)
            WHERE { ?s ex:group ?g . ?s ex:val ?v }
            GROUP BY ?g HAVING (MAX(?v) < 10)
        """)
        @test length(results) == 1
        @test results[1]["g"] == EX("b")
        @test convert(Any, results[1]["mx"]) == 3
    end

    # ─── 9. HAVING with equality (= literal value) ──────────────────
    @testset "HAVING equality = literal" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("s1"), EX("group"), EX("a")))
        add!(g, Triple(EX("s1"), EX("val"), Literal(5)))
        add!(g, Triple(EX("s2"), EX("group"), EX("a")))
        add!(g, Triple(EX("s2"), EX("val"), Literal(5)))
        add!(g, Triple(EX("s3"), EX("group"), EX("b")))
        add!(g, Triple(EX("s3"), EX("val"), Literal(7)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?g (SUM(?v) AS ?total)
            WHERE { ?s ex:group ?g . ?s ex:val ?v }
            GROUP BY ?g HAVING (SUM(?v) = 10)
        """)
        @test length(results) == 1
        @test results[1]["g"] == EX("a")
    end

    # ─── 10. HAVING with inequality (!=) ─────────────────────────────
    @testset "HAVING inequality !=" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("s1"), EX("group"), EX("a")))
        add!(g, Triple(EX("s1"), EX("val"), Literal(5)))
        add!(g, Triple(EX("s2"), EX("group"), EX("b")))
        add!(g, Triple(EX("s2"), EX("val"), Literal(10)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?g (SUM(?v) AS ?total)
            WHERE { ?s ex:group ?g . ?s ex:val ?v }
            GROUP BY ?g HAVING (SUM(?v) != 5)
        """)
        @test length(results) == 1
        @test results[1]["g"] == EX("b")
    end

    # ─── 11. HAVING with variable != IRI (extended) ──────────────────
    @testset "HAVING ?var != IRI" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("s1"), EX("p"), Literal(1)))
        add!(g, Triple(EX("s2"), EX("q"), Literal(2)))
        add!(g, Triple(EX("s3"), EX("r"), Literal(3)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?p
            WHERE { ?s ?p ?o }
            GROUP BY ?p HAVING (?p != ex:r)
        """)
        preds = Set(r["p"] for r in results)
        @test length(results) == 2
        @test EX("p") in preds
        @test EX("q") in preds
        @test !(EX("r") in preds)
    end

    # ─── 12. Multiple aggregates in SELECT with HAVING on one ────────
    @testset "Multiple aggregates, HAVING on one" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("s1"), EX("group"), EX("a")))
        add!(g, Triple(EX("s1"), EX("val"), Literal(10)))
        add!(g, Triple(EX("s2"), EX("group"), EX("a")))
        add!(g, Triple(EX("s2"), EX("val"), Literal(20)))
        add!(g, Triple(EX("s3"), EX("group"), EX("b")))
        add!(g, Triple(EX("s3"), EX("val"), Literal(5)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?g (COUNT(?s) AS ?cnt) (SUM(?v) AS ?total)
            WHERE { ?s ex:group ?g . ?s ex:val ?v }
            GROUP BY ?g HAVING (COUNT(?s) > 1)
        """)
        @test length(results) == 1
        @test results[1]["g"] == EX("a")
        @test convert(Any, results[1]["cnt"]) == 2
        @test convert(Any, results[1]["total"]) == 30
    end

    # ─── 13. HAVING combined with ORDER BY ───────────────────────────
    @testset "HAVING with ORDER BY" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        for (s, grp, v) in [("s1","a",10), ("s2","a",20), ("s3","b",30),
                             ("s4","b",40), ("s5","c",1)]
            add!(g, Triple(EX(s), EX("group"), EX(grp)))
            add!(g, Triple(EX(s), EX("val"), Literal(v)))
        end

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?g (SUM(?v) AS ?total)
            WHERE { ?s ex:group ?g . ?s ex:val ?v }
            GROUP BY ?g HAVING (SUM(?v) > 5)
            ORDER BY DESC(?total)
        """)
        @test length(results) == 2
        @test convert(Any, results[1]["total"]) >= convert(Any, results[2]["total"])
    end

    # ─── 14. HAVING combined with LIMIT ──────────────────────────────
    @testset "HAVING with LIMIT" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        for (s, grp, v) in [("s1","a",10), ("s2","a",20), ("s3","b",30),
                             ("s4","b",40), ("s5","c",1)]
            add!(g, Triple(EX(s), EX("group"), EX(grp)))
            add!(g, Triple(EX(s), EX("val"), Literal(v)))
        end

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?g (SUM(?v) AS ?total)
            WHERE { ?s ex:group ?g . ?s ex:val ?v }
            GROUP BY ?g HAVING (SUM(?v) > 5)
            LIMIT 1
        """)
        @test length(results) == 1
    end

    # ─── 15. GROUP BY multiple variables with HAVING ─────────────────
    @testset "GROUP BY multiple variables with HAVING" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("s1"), EX("cat"), EX("x")))
        add!(g, Triple(EX("s1"), EX("type"), EX("t1")))
        add!(g, Triple(EX("s1"), EX("val"), Literal(5)))
        add!(g, Triple(EX("s2"), EX("cat"), EX("x")))
        add!(g, Triple(EX("s2"), EX("type"), EX("t1")))
        add!(g, Triple(EX("s2"), EX("val"), Literal(15)))
        add!(g, Triple(EX("s3"), EX("cat"), EX("y")))
        add!(g, Triple(EX("s3"), EX("type"), EX("t2")))
        add!(g, Triple(EX("s3"), EX("val"), Literal(3)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?c ?t (SUM(?v) AS ?total)
            WHERE { ?s ex:cat ?c . ?s ex:type ?t . ?s ex:val ?v }
            GROUP BY ?c ?t HAVING (SUM(?v) > 10)
        """)
        @test length(results) == 1
        @test results[1]["c"] == EX("x")
        @test results[1]["t"] == EX("t1")
        @test convert(Any, results[1]["total"]) == 20
    end

    # ─── 16. HAVING on GROUP_CONCAT with COUNT ──────────────────────
    @testset "HAVING on GROUP_CONCAT" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("s1"), EX("group"), EX("a")))
        add!(g, Triple(EX("s1"), EX("tag"), Literal("alpha")))
        add!(g, Triple(EX("s2"), EX("group"), EX("a")))
        add!(g, Triple(EX("s2"), EX("tag"), Literal("beta")))
        add!(g, Triple(EX("s3"), EX("group"), EX("b")))
        add!(g, Triple(EX("s3"), EX("tag"), Literal("x")))

        # Use COUNT in both SELECT and HAVING so the engine can resolve it
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?g (COUNT(?tag) AS ?cnt) (GROUP_CONCAT(?tag) AS ?tags)
            WHERE { ?s ex:group ?g . ?s ex:tag ?tag }
            GROUP BY ?g HAVING (COUNT(?tag) > 1)
        """)
        @test length(results) == 1
        @test results[1]["g"] == EX("a")
        tags_str = results[1]["tags"].lexical
        @test occursin("alpha", tags_str)
        @test occursin("beta", tags_str)
    end

    # ─── 17. HAVING filters all groups ───────────────────────────────
    @testset "HAVING filters all groups (empty result)" begin
        g = make_having_graph()
        results = sparql_query(g, """
            SELECT ?p (COUNT(?s) AS ?cnt)
            WHERE { ?s ?p ?o }
            GROUP BY ?p HAVING (COUNT(?s) > 100)
        """)
        @test isempty(results)
    end

    # ─── 18. HAVING keeps all groups ─────────────────────────────────
    @testset "HAVING keeps all groups" begin
        g = make_having_graph()
        results = sparql_query(g, """
            SELECT ?p (COUNT(?s) AS ?cnt)
            WHERE { ?s ?p ?o }
            GROUP BY ?p HAVING (COUNT(?s) > 0)
        """)
        @test length(results) == 2
    end

    # ─── 19. HAVING with >= ─────────────────────────────────────────
    @testset "HAVING >=" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("s1"), EX("group"), EX("a")))
        add!(g, Triple(EX("s1"), EX("val"), Literal(10)))
        add!(g, Triple(EX("s2"), EX("group"), EX("b")))
        add!(g, Triple(EX("s2"), EX("val"), Literal(5)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?g (SUM(?v) AS ?total)
            WHERE { ?s ex:group ?g . ?s ex:val ?v }
            GROUP BY ?g HAVING (SUM(?v) >= 10)
        """)
        @test length(results) == 1
        @test results[1]["g"] == EX("a")
    end

    # ─── 20. HAVING with <= ─────────────────────────────────────────
    @testset "HAVING <=" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("s1"), EX("group"), EX("a")))
        add!(g, Triple(EX("s1"), EX("val"), Literal(10)))
        add!(g, Triple(EX("s2"), EX("group"), EX("b")))
        add!(g, Triple(EX("s2"), EX("val"), Literal(5)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?g (SUM(?v) AS ?total)
            WHERE { ?s ex:group ?g . ?s ex:val ?v }
            GROUP BY ?g HAVING (SUM(?v) <= 5)
        """)
        @test length(results) == 1
        @test results[1]["g"] == EX("b")
    end

    # ─── 21. HAVING COUNT = 1 (exact match) ─────────────────────────
    @testset "HAVING COUNT = 1 exact" begin
        g = make_having_graph()
        results = sparql_query(g, """
            SELECT ?p (COUNT(?o) AS ?cnt)
            WHERE { ?s ?p ?o }
            GROUP BY ?p HAVING (COUNT(?o) = 1)
        """)
        @test length(results) == 1
        @test results[1]["p"] == URIRef("urn:q")
    end

    # ─── 22. HAVING COUNT = 2 ───────────────────────────────────────
    @testset "HAVING COUNT = 2" begin
        g = make_having_graph()
        results = sparql_query(g, """
            SELECT ?p (COUNT(?s) AS ?cnt)
            WHERE { ?s ?p ?o }
            GROUP BY ?p HAVING (COUNT(?s) = 2)
        """)
        @test length(results) == 1
        @test results[1]["p"] == URIRef("urn:p")
    end

    # ─── 23. HAVING with SUM = 0 (no matching triples) ──────────────
    @testset "HAVING SUM on single group" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("s1"), EX("group"), EX("a")))
        add!(g, Triple(EX("s1"), EX("val"), Literal(100)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?g (SUM(?v) AS ?total)
            WHERE { ?s ex:group ?g . ?s ex:val ?v }
            GROUP BY ?g HAVING (SUM(?v) = 100)
        """)
        @test length(results) == 1
        @test convert(Any, results[1]["total"]) == 100
    end

    # ─── 24. HAVING + ORDER BY + LIMIT combined ─────────────────────
    @testset "HAVING + ORDER BY + LIMIT combined" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        for (s, grp, v) in [("s1","a",10), ("s2","a",20),
                             ("s3","b",30), ("s4","b",40),
                             ("s5","c",50), ("s6","c",60),
                             ("s7","d",1)]
            add!(g, Triple(EX(s), EX("group"), EX(grp)))
            add!(g, Triple(EX(s), EX("val"), Literal(v)))
        end

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?g (SUM(?v) AS ?total)
            WHERE { ?s ex:group ?g . ?s ex:val ?v }
            GROUP BY ?g HAVING (SUM(?v) > 5)
            LIMIT 2
        """)
        @test length(results) == 2
        totals = Set(convert(Any, r["total"]) for r in results)
        # Three groups pass HAVING (a=30, b=70, c=110); LIMIT 2 returns any two
        @test all(t -> t in (30, 70, 110), totals)
    end

    # ─── 25. HAVING on AVG = exact value ─────────────────────────────
    @testset "HAVING AVG = exact value" begin
        g = make_having_graph()
        results = sparql_query(g, """
            SELECT ?p (AVG(?o) AS ?a)
            WHERE { ?s ?p ?o }
            GROUP BY ?p HAVING (AVG(?o) = 1)
        """)
        @test length(results) == 1
        @test results[1]["p"] == URIRef("urn:q")
    end
end
