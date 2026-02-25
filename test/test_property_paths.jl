@testset "Property Paths" begin
    EX = RDFLib.Namespace("http://example.org/")

    # ─── Build test graph ────────────────────────────────────────
    # Chain: a -p-> b -p-> c -p-> d -p-> e
    # Branch: a -q-> x -q-> y
    # Types: a,b,c are :Person; d,e are :Animal
    # Cross: c -r-> x
    g = RDFGraph()
    bind!(g, "ex", EX)
    RDF = RDFLib.Namespace("http://www.w3.org/1999/02/22-rdf-syntax-ns#")

    add!(g, Triple(EX("a"), EX("p"), EX("b")))
    add!(g, Triple(EX("b"), EX("p"), EX("c")))
    add!(g, Triple(EX("c"), EX("p"), EX("d")))
    add!(g, Triple(EX("d"), EX("p"), EX("e")))
    add!(g, Triple(EX("a"), EX("q"), EX("x")))
    add!(g, Triple(EX("x"), EX("q"), EX("y")))
    add!(g, Triple(EX("c"), EX("r"), EX("x")))
    add!(g, Triple(EX("a"), RDF("type"), EX("Person")))
    add!(g, Triple(EX("b"), RDF("type"), EX("Person")))
    add!(g, Triple(EX("c"), RDF("type"), EX("Person")))
    add!(g, Triple(EX("d"), RDF("type"), EX("Animal")))
    add!(g, Triple(EX("e"), RDF("type"), EX("Animal")))
    add!(g, Triple(EX("a"), EX("name"), Literal("Alice")))
    add!(g, Triple(EX("b"), EX("name"), Literal("Bob")))

    # ─── Sequence paths ─────────────────────────────────────────
    @testset "Sequence path /  (2 steps)" begin
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?o WHERE { ex:a ex:p/ex:p ?o }
        """)
        @test length(r) == 1
        @test r[1]["o"] == EX("c")
    end

    @testset "Sequence path / (3 steps)" begin
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?o WHERE { ex:a ex:p/ex:p/ex:p ?o }
        """)
        @test length(r) == 1
        @test r[1]["o"] == EX("d")
    end

    @testset "Sequence with mixed predicates" begin
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?o WHERE { ex:c ex:p/ex:p ?o }
        """)
        @test length(r) == 1
        @test r[1]["o"] == EX("e")
    end

    @testset "Sequence cross-predicate" begin
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?o WHERE { ex:c ex:r/ex:q ?o }
        """)
        @test length(r) == 1
        @test r[1]["o"] == EX("y")
    end

    # ─── Alternative paths ───────────────────────────────────────
    @testset "Alternative path |" begin
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?o WHERE { ex:a ex:p|ex:q ?o } ORDER BY ?o
        """)
        vals = Set(b["o"] for b in r)
        @test EX("b") in vals
        @test EX("x") in vals
        @test length(vals) == 2
    end

    @testset "Alternative with 3 options" begin
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?o WHERE { ex:c ex:p|ex:r|ex:q ?o } ORDER BY ?o
        """)
        vals = Set(b["o"] for b in r)
        @test EX("d") in vals
        @test EX("x") in vals
        @test length(vals) == 2
    end

    # ─── Inverse paths ───────────────────────────────────────────
    @testset "Inverse path ^" begin
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE { ex:b ^ex:p ?s }
        """)
        @test length(r) == 1
        @test r[1]["s"] == EX("a")
    end

    @testset "Inverse in sequence" begin
        # b <-p- a, then a -q-> x
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?o WHERE { ex:b ^ex:p/ex:q ?o }
        """)
        vals = Set(b["o"] for b in r)
        @test EX("x") in vals
    end

    # ─── ZeroOrMore * ────────────────────────────────────────────
    @testset "ZeroOrMore path *" begin
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?o WHERE { ex:a ex:p* ?o } ORDER BY ?o
        """)
        vals = Set(b["o"] for b in r)
        # a, b, c, d, e (includes self)
        @test EX("a") in vals  # zero steps
        @test EX("b") in vals
        @test EX("c") in vals
        @test EX("d") in vals
        @test EX("e") in vals
        @test length(vals) == 5
    end

    @testset "ZeroOrMore from leaf" begin
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?o WHERE { ex:e ex:p* ?o }
        """)
        vals = Set(b["o"] for b in r)
        @test EX("e") in vals  # only self (zero steps)
        @test length(vals) == 1
    end

    # ─── OneOrMore + ─────────────────────────────────────────────
    @testset "OneOrMore path +" begin
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?o WHERE { ex:a ex:p+ ?o } ORDER BY ?o
        """)
        vals = Set(b["o"] for b in r)
        # b, c, d, e (excludes self)
        @test !(EX("a") in vals)
        @test EX("b") in vals
        @test EX("e") in vals
        @test length(vals) == 4
    end

    @testset "OneOrMore from leaf" begin
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?o WHERE { ex:e ex:p+ ?o }
        """)
        @test isempty(r)
    end

    # ─── ZeroOrOne ? ─────────────────────────────────────────────
    @testset "ZeroOrOne path ?" begin
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?o WHERE { ex:a ex:p? ?o } ORDER BY ?o
        """)
        vals = Set(b["o"] for b in r)
        @test EX("a") in vals  # zero steps
        @test EX("b") in vals  # one step
        @test length(vals) == 2
    end

    # ─── Negated property sets ───────────────────────────────────
    @testset "Negated property set !" begin
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
            SELECT ?o WHERE { ex:a !(ex:p|ex:q) ?o }
        """)
        vals = Set(b["o"] for b in r)
        # a has: p->b, q->x, rdf:type->Person, name->"Alice"
        # Negated p and q, so should get type and name results
        @test EX("Person") in vals || Literal("Alice") in vals
        @test !(EX("b") in vals)
        @test !(EX("x") in vals)
    end

    # ─── Paths with variables on both sides ──────────────────────
    @testset "Path with variable subject" begin
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?o WHERE { ?s ex:p/ex:p ?o } ORDER BY ?s
        """)
        @test length(r) >= 2
        pairs = Set((b["s"], b["o"]) for b in r)
        @test (EX("a"), EX("c")) in pairs
        @test (EX("b"), EX("d")) in pairs
        @test (EX("c"), EX("e")) in pairs
    end

    # ─── Paths combined with other patterns ──────────────────────
    @testset "Path with FILTER" begin
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?o WHERE {
                ex:a ex:p+ ?o .
                ?o ex:name ?n .
            }
        """)
        vals = Set(b["o"] for b in r)
        # Only b has a name among a's p+ reachable nodes
        @test EX("b") in vals
    end

    @testset "Path with OPTIONAL" begin
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?o ?n WHERE {
                ex:a ex:p ?o .
                OPTIONAL { ?o ex:name ?n }
            }
        """)
        @test length(r) == 1
        @test r[1]["o"] == EX("b")
        @test r[1]["n"] == Literal("Bob")
    end

    @testset "Path in ASK" begin
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            ASK { ex:a ex:p+ ex:e }
        """)
        @test r == true
        r2 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            ASK { ex:e ex:p+ ex:a }
        """)
        @test r2 == false
    end

    @testset "Path in CONSTRUCT" begin
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            CONSTRUCT { ?s ex:reachable ?o }
            WHERE { ?s ex:p+ ?o }
        """)
        @test r isa RDFGraph
        @test length(r) >= 4
    end

    # ─── Cycle handling ──────────────────────────────────────────
    @testset "ZeroOrMore with cycle" begin
        gc = RDFGraph()
        bind!(gc, "ex", EX)
        add!(gc, Triple(EX("a"), EX("p"), EX("b")))
        add!(gc, Triple(EX("b"), EX("p"), EX("c")))
        add!(gc, Triple(EX("c"), EX("p"), EX("a")))  # cycle!

        r = sparql_query(gc, """
            PREFIX ex: <http://example.org/>
            SELECT ?o WHERE { ex:a ex:p* ?o }
        """)
        vals = Set(b["o"] for b in r)
        @test length(vals) == 3  # a, b, c — terminates despite cycle
        @test EX("a") in vals
        @test EX("b") in vals
        @test EX("c") in vals
    end

    @testset "OneOrMore with self-loop" begin
        gc = RDFGraph()
        bind!(gc, "ex", EX)
        add!(gc, Triple(EX("a"), EX("p"), EX("a")))  # self-loop

        r = sparql_query(gc, """
            PREFIX ex: <http://example.org/>
            SELECT ?o WHERE { ex:a ex:p+ ?o }
        """)
        vals = Set(b["o"] for b in r)
        @test EX("a") in vals
        @test length(vals) == 1
    end

    # ─── Empty results ───────────────────────────────────────────
    @testset "Path with no matches" begin
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?o WHERE { ex:a ex:nonexistent+ ?o }
        """)
        @test isempty(r)
    end

    @testset "Sequence path no match at second step" begin
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?o WHERE { ex:e ex:p/ex:q ?o }
        """)
        @test isempty(r)
    end
end
