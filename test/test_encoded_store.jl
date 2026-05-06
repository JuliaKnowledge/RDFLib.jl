# Regression tests for EncodedStore — re-runs core graph/SPARQL operations
# against an EncodedStore-backed Graph and verifies identical semantics to
# MemoryStore. The aim is to surface any divergence in encoding/decoding,
# pattern matching, iteration, equality, or SPARQL evaluation.

using Test
using RDFLib

@testset "EncodedStore" begin
    EX = Namespace("http://example.org/")

    @testset "construction & basic properties" begin
        s = EncodedStore()
        @test length(s) == 0
        @test isempty(s)
        g = RDFGraph(store=s)
        @test g.store isa EncodedStore
        @test length(g) == 0
        @test isempty(g)
    end

    @testset "add! / length / dedup" begin
        g = RDFGraph(store=EncodedStore())
        t1 = Triple(EX("a"), EX("p"), EX("b"))
        t2 = Triple(EX("a"), EX("p"), EX("c"))
        add!(g, t1)
        add!(g, t2)
        add!(g, t1)  # dup
        @test length(g) == 2
    end

    @testset "literal types and language tags" begin
        g = RDFGraph(store=EncodedStore())
        l1 = Literal("hello")
        l2 = Literal("hello", lang="en")
        l3 = Literal("42", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))
        add!(g, Triple(EX("s"), EX("p"), l1))
        add!(g, Triple(EX("s"), EX("p"), l2))
        add!(g, Triple(EX("s"), EX("p"), l3))
        # Distinct literal values should yield distinct triples
        @test length(g) == 3
        # Re-adding the same literal value should dedup
        add!(g, Triple(EX("s"), EX("p"), Literal("hello", lang="en")))
        @test length(g) == 3
    end

    @testset "BNode interning" begin
        g = RDFGraph(store=EncodedStore())
        b1 = BNode("b1")
        b2 = BNode("b1")  # same nominal id
        add!(g, Triple(b1, EX("p"), EX("o")))
        add!(g, Triple(b2, EX("p"), EX("o")))  # dup since b1 == b2
        @test length(g) == 1
    end

    @testset "triples pattern matching" begin
        g = RDFGraph(store=EncodedStore())
        a, b, c = EX("a"), EX("b"), EX("c")
        p, q = EX("p"), EX("q")
        add!(g, Triple(a, p, b))
        add!(g, Triple(a, p, c))
        add!(g, Triple(a, q, b))
        add!(g, Triple(b, p, c))

        @test length(triples(g, (nothing, nothing, nothing))) == 4
        @test length(triples(g, (a, nothing, nothing))) == 3
        @test length(triples(g, (nothing, p, nothing))) == 3
        @test length(triples(g, (nothing, nothing, b))) == 2
        @test length(triples(g, (a, p, nothing))) == 2
        @test length(triples(g, (a, nothing, b))) == 2
        @test length(triples(g, (nothing, p, c))) == 2
        @test length(triples(g, (a, p, b))) == 1
        # Non-existent terms
        @test isempty(triples(g, (EX("nope"), nothing, nothing)))
        @test isempty(triples(g, (nothing, EX("nope"), nothing)))
        @test isempty(triples(g, (nothing, nothing, EX("nope"))))
    end

    @testset "remove! by pattern" begin
        g = RDFGraph(store=EncodedStore())
        a, b, c = EX("a"), EX("b"), EX("c")
        p = EX("p")
        add!(g, Triple(a, p, b))
        add!(g, Triple(a, p, c))
        add!(g, Triple(b, p, c))
        remove!(g, (nothing, nothing, c))
        @test length(g) == 1
        @test Triple(a, p, b) in g
        @test !(Triple(a, p, c) in g)
        @test !(Triple(b, p, c) in g)
    end

    @testset "iteration order preserved" begin
        g = RDFGraph(store=EncodedStore())
        a, b, c = EX("a"), EX("b"), EX("c")
        p = EX("p")
        ts = [Triple(a, p, b), Triple(a, p, c), Triple(b, p, c)]
        for t in ts; add!(g, t); end
        collected = collect(g)
        @test collected == ts
    end

    @testset "in operator" begin
        g = RDFGraph(store=EncodedStore())
        t = Triple(EX("s"), EX("p"), EX("o"))
        @test !(t in g)
        add!(g, t)
        @test t in g
        @test !(Triple(EX("s"), EX("p"), EX("other")) in g)
        @test !(Triple(EX("unknown"), EX("p"), EX("o")) in g)
    end

    @testset "subjects / predicates / objects accessors" begin
        g = RDFGraph(store=EncodedStore())
        a, b = EX("a"), EX("b")
        p, q = EX("p"), EX("q")
        add!(g, Triple(a, p, b))
        add!(g, Triple(a, q, b))
        add!(g, Triple(b, p, a))
        @test Set(collect(subjects(g, p))) == Set([a, b])
        @test Set(collect(predicates(g, a))) == Set([p, q])
        @test Set(collect(objects(g, a, p))) == Set([b])
    end

    @testset "N-Triples roundtrip" begin
        g1 = RDFGraph(store=EncodedStore())
        a, b = EX("a"), EX("b")
        add!(g1, Triple(a, EX("p"), b))
        add!(g1, Triple(a, EX("q"), Literal("hello", lang="en")))
        add!(g1, Triple(a, EX("r"), Literal("42", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))))
        nt = serialize(g1, NTriplesFormat())
        g2 = RDFGraph(store=EncodedStore())
        parse_rdf!(g2, nt, NTriplesFormat())
        @test length(g2) == length(g1)
        for t in g1
            @test t in g2
        end
    end

    @testset "Turtle roundtrip" begin
        g1 = RDFGraph(store=EncodedStore())
        a, b = EX("a"), EX("b")
        add!(g1, Triple(a, EX("p"), b))
        add!(g1, Triple(a, EX("q"), Literal("hello")))
        ttl = serialize(g1, TurtleFormat())
        g2 = RDFGraph(store=EncodedStore())
        parse_rdf!(g2, ttl, TurtleFormat())
        @test length(g2) == length(g1)
        for t in g1
            @test t in g2
        end
    end

    @testset "set operations" begin
        g1 = RDFGraph(store=EncodedStore())
        g2 = RDFGraph(store=EncodedStore())
        a, b, c = EX("a"), EX("b"), EX("c")
        p = EX("p")
        add!(g1, Triple(a, p, b))
        add!(g1, Triple(a, p, c))
        add!(g2, Triple(a, p, b))
        add!(g2, Triple(b, p, c))
        u = union(g1, g2)
        @test length(u) == 3
        i = intersect(g1, g2)
        @test length(i) == 1
        @test Triple(a, p, b) in i
        d = setdiff(g1, g2)
        @test length(d) == 1
        @test Triple(a, p, c) in d
    end

    @testset "SPARQL — basic SELECT" begin
        g = RDFGraph(store=EncodedStore())
        a, b, c = EX("a"), EX("b"), EX("c")
        p, q = EX("p"), EX("q")
        add!(g, Triple(a, p, b))
        add!(g, Triple(a, q, c))
        add!(g, Triple(b, p, c))
        rs = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?o WHERE { ?s ex:p ?o }
        """)
        rows = Set((r["s"], r["o"]) for r in rs)
        @test length(rows) == 2
        @test (a, b) in rows
        @test (b, c) in rows
    end

    @testset "SPARQL — COUNT(*)" begin
        g = RDFGraph(store=EncodedStore())
        for i in 1:50
            add!(g, Triple(EX("s$i"), EX("p"), EX("o$i")))
        end
        rs = sparql_query(g, "SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }")
        rows = collect(rs)
        @test length(rows) == 1
        cnt = first(rows)["n"]
        @test parse(Int, string(cnt)) == 50
    end

    @testset "SPARQL — join + GROUP BY + aggregate" begin
        g = RDFGraph(store=EncodedStore())
        c1 = EX("c1"); c2 = EX("c2")
        cust = URIRef("http://example.org/customer")
        country = EX("country")
        order = EX("order")
        placedBy = EX("placedBy")
        amount = EX("amount")
        usa = Literal("USA"); uk = Literal("UK")
        add!(g, Triple(c1, RDFLib.RDF.type, cust))
        add!(g, Triple(c1, country, usa))
        add!(g, Triple(c2, RDFLib.RDF.type, cust))
        add!(g, Triple(c2, country, uk))
        for i in 1:5
            o = EX("o_c1_$i")
            add!(g, Triple(o, RDFLib.RDF.type, order))
            add!(g, Triple(o, placedBy, c1))
            add!(g, Triple(o, amount, Literal(string(i*10), datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))))
        end
        for i in 1:3
            o = EX("o_c2_$i")
            add!(g, Triple(o, RDFLib.RDF.type, order))
            add!(g, Triple(o, placedBy, c2))
            add!(g, Triple(o, amount, Literal(string(i*100), datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))))
        end
        rs = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
            SELECT ?country (COUNT(?o) AS ?n) (SUM(?a) AS ?total)
            WHERE {
              ?c rdf:type ex:customer ; ex:country ?country .
              ?o rdf:type ex:order ; ex:placedBy ?c ; ex:amount ?a .
            }
            GROUP BY ?country
            ORDER BY ?country
        """)
        rows = collect(rs)
        @test length(rows) == 2
        @test string(rows[1]["country"]) == "UK"
        @test parse(Int, string(rows[1]["n"])) == 3
        @test parse(Int, string(rows[1]["total"])) == 600
        @test string(rows[2]["country"]) == "USA"
        @test parse(Int, string(rows[2]["n"])) == 5
        @test parse(Int, string(rows[2]["total"])) == 150
    end

    @testset "SPARQL — OPTIONAL" begin
        g = RDFGraph(store=EncodedStore())
        add!(g, Triple(EX("s1"), EX("name"), Literal("Alice")))
        add!(g, Triple(EX("s2"), EX("name"), Literal("Bob")))
        add!(g, Triple(EX("s1"), EX("age"), Literal("30", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))))
        rs = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?name ?age WHERE {
              ?s ex:name ?name .
              OPTIONAL { ?s ex:age ?age }
            }
        """)
        rows = collect(rs)
        @test length(rows) == 2
    end

    @testset "MemoryStore vs EncodedStore — semantic parity" begin
        ts = [
            Triple(EX("a"), EX("p"), EX("b")),
            Triple(EX("a"), EX("p"), EX("c")),
            Triple(EX("b"), EX("p"), EX("c")),
            Triple(EX("a"), EX("q"), Literal("hello")),
            Triple(EX("b"), EX("q"), Literal("world")),
        ]
        g_mem = RDFGraph()
        g_enc = RDFGraph(store=EncodedStore())
        for t in ts
            add!(g_mem, t); add!(g_enc, t)
        end
        @test length(g_mem) == length(g_enc)
        for pat in [(nothing, nothing, nothing), (EX("a"), nothing, nothing),
                    (nothing, EX("p"), nothing), (nothing, nothing, EX("c")),
                    (EX("a"), EX("p"), nothing), (EX("a"), nothing, Literal("hello"))]
            r1 = Set(triples(g_mem, pat))
            r2 = Set(triples(g_enc, pat))
            @test r1 == r2
        end
        for q in [
            "SELECT ?s ?o WHERE { ?s <http://example.org/p> ?o }",
            "SELECT ?s WHERE { ?s ?p <http://example.org/c> }",
            "SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }",
        ]
            r1 = Set(Tuple(sort(collect(r), by=first)) for r in sparql_query(g_mem, q))
            r2 = Set(Tuple(sort(collect(r), by=first)) for r in sparql_query(g_enc, q))
            @test r1 == r2
        end
    end
end
