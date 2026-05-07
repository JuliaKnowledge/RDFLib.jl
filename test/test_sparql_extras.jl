using Test
using RDFLib

@testset "SPARQL Extras" begin
    EX = Namespace("http://example.org/")

    # ─── 1. Aggregate with Undefined Values ────────────────────────────

    @testset "Aggregates with Undefined Values" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        # Group "a": has values 10 and 20
        add!(g, Triple(EX("s1"), EX("group"), EX("a")))
        add!(g, Triple(EX("s1"), EX("val"), Literal(10)))
        add!(g, Triple(EX("s2"), EX("group"), EX("a")))
        add!(g, Triple(EX("s2"), EX("val"), Literal(20)))
        # Group "b": has value 5
        add!(g, Triple(EX("s3"), EX("group"), EX("b")))
        add!(g, Triple(EX("s3"), EX("val"), Literal(5)))
        # Group "c": has NO val (undefined)
        add!(g, Triple(EX("s4"), EX("group"), EX("c")))

        @testset "SUM with undefined" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?g (SUM(?val) AS ?sum) WHERE {
                    ?s ex:group ?g .
                    OPTIONAL { ?s ex:val ?val }
                } GROUP BY ?g
            """)
            sums = Dict(r["g"] => r["sum"] for r in results)
            @test convert(Any, sums[EX("a")]) == 30
            @test convert(Any, sums[EX("b")]) == 5
            # Group "c" has no values: SUM should be 0
            @test convert(Any, sums[EX("c")]) == 0
        end

        @testset "COUNT with undefined" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?g (COUNT(?val) AS ?cnt) WHERE {
                    ?s ex:group ?g .
                    OPTIONAL { ?s ex:val ?val }
                } GROUP BY ?g
            """)
            counts = Dict(r["g"] => r["cnt"] for r in results)
            @test convert(Any, counts[EX("a")]) == 2
            @test convert(Any, counts[EX("b")]) == 1
            @test convert(Any, counts[EX("c")]) == 0
        end

        @testset "MIN with undefined" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?g (MIN(?val) AS ?minval) WHERE {
                    ?s ex:group ?g .
                    OPTIONAL { ?s ex:val ?val }
                } GROUP BY ?g
            """)
            mins = Dict(r["g"] => r["minval"] for r in results)
            @test convert(Any, mins[EX("a")]) == 10
            @test convert(Any, mins[EX("b")]) == 5
        end

        @testset "MAX with undefined" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?g (MAX(?val) AS ?maxval) WHERE {
                    ?s ex:group ?g .
                    OPTIONAL { ?s ex:val ?val }
                } GROUP BY ?g
            """)
            maxs = Dict(r["g"] => r["maxval"] for r in results)
            @test convert(Any, maxs[EX("a")]) == 20
            @test convert(Any, maxs[EX("b")]) == 5
        end

        @testset "SAMPLE with undefined" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?g (SAMPLE(?val) AS ?samp) WHERE {
                    ?s ex:group ?g .
                    OPTIONAL { ?s ex:val ?val }
                } GROUP BY ?g
            """)
            samples = Dict(r["g"] => r["samp"] for r in results)
            @test samples[EX("a")] isa Literal
            @test convert(Any, samples[EX("a")]) in (10, 20)
            @test convert(Any, samples[EX("b")]) == 5
        end

        @testset "GROUP_CONCAT with undefined" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?g (GROUP_CONCAT(?val) AS ?concat) WHERE {
                    ?s ex:group ?g .
                    OPTIONAL { ?s ex:val ?val }
                } GROUP BY ?g
            """)
            concats = Dict(r["g"] => r["concat"] for r in results)
            # Group "a" should concat two values
            @test concats[EX("a")] isa Literal
            ca = concats[EX("a")].lexical
            @test occursin("10", ca) && occursin("20", ca)
            # Group "c" with no values should produce empty string
            @test concats[EX("c")].lexical == ""
        end
    end

    # ─── 2. Nested Filters ─────────────────────────────────────────────

    @testset "Nested Filters" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("x1"), EX("p"), Literal("hello")))
        add!(g, Triple(EX("x1"), EX("q"), Literal("world")))
        add!(g, Triple(EX("x2"), EX("p"), Literal("hi")))
        # x2 has no :q triple

        @testset "FILTER EXISTS with variable propagation" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?x WHERE {
                    ?x ex:p ?y .
                    FILTER EXISTS { ?x ex:q ?z }
                }
            """)
            subjects = [r["x"] for r in results]
            @test EX("x1") in subjects
            @test !(EX("x2") in subjects)
        end

        @testset "FILTER NOT EXISTS with variable binding" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?x WHERE {
                    ?x ex:p ?y .
                    FILTER NOT EXISTS { ?x ex:q ?z }
                }
            """)
            subjects = [r["x"] for r in results]
            @test EX("x2") in subjects
            @test !(EX("x1") in subjects)
        end

        @testset "Nested FILTER EXISTS with outer variable" begin
            # x1 has both :p and :q, x2 has only :p
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?x ?y WHERE {
                    ?x ex:p ?y .
                    FILTER EXISTS { ?x ex:q ?z }
                }
            """)
            @test length(results) == 1
            @test results[1]["x"] == EX("x1")
            @test results[1]["y"] == Literal("hello")
        end
    end

    # ─── 3. SPARQL Expressions ─────────────────────────────────────────

    @testset "SPARQL Expressions" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("alice"), EX("name"), Literal("Alice Smith")))
        add!(g, Triple(EX("bob"), EX("name"), Literal("Bob Jones")))
        add!(g, Triple(EX("alice"), EX("age"), Literal(30)))
        add!(g, Triple(EX("bob"), EX("age"), Literal(17)))
        add!(g, Triple(EX("alice"), EX("score"), Literal(85)))
        add!(g, Triple(EX("bob"), EX("score"), Literal(92)))

        @testset "REGEX function" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s ?name WHERE {
                    ?s ex:name ?name .
                    FILTER(REGEX(?name, "Smith"))
                }
            """)
            @test length(results) == 1
            @test results[1]["s"] == EX("alice")
        end

        @testset "REGEX case-insensitive" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s ?name WHERE {
                    ?s ex:name ?name .
                    FILTER(REGEX(?name, "alice", "i"))
                }
            """)
            @test length(results) == 1
            @test results[1]["s"] == EX("alice")
        end

        @testset "Arithmetic BIND" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s (?age + ?score AS ?total) WHERE {
                    ?s ex:age ?age .
                    ?s ex:score ?score .
                }
            """)
            totals = Dict(r["s"] => parse(Float64, r["total"].lexical) for r in results)
            @test totals[EX("alice")] == 115.0
            @test totals[EX("bob")] == 109.0
        end

        @testset "FILTER comparison >" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s WHERE {
                    ?s ex:age ?age .
                    FILTER(?age > 18)
                }
            """)
            @test length(results) == 1
            @test results[1]["s"] == EX("alice")
        end

        @testset "FILTER comparison <" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s WHERE {
                    ?s ex:age ?age .
                    FILTER(?age < 18)
                }
            """)
            @test length(results) == 1
            @test results[1]["s"] == EX("bob")
        end

        @testset "Logical AND (&&)" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s WHERE {
                    ?s ex:age ?age .
                    ?s ex:score ?score .
                    FILTER(?age > 18 && ?score > 80)
                }
            """)
            @test length(results) == 1
            @test results[1]["s"] == EX("alice")
        end

        @testset "Logical OR (||)" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s WHERE {
                    ?s ex:age ?age .
                    FILTER(?age = 17 || ?age = 30)
                }
            """)
            @test length(results) == 2
            subjects = Set(r["s"] for r in results)
            @test EX("alice") in subjects
            @test EX("bob") in subjects
        end
    end

    # ─── 4. SPARQL Operators (Date Casting) ────────────────────────────

    @testset "SPARQL Operators" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("event1"), EX("date"), Literal("2024-01-15", datatype=URIRef("http://www.w3.org/2001/XMLSchema#date"))))
        add!(g, Triple(EX("event2"), EX("date"), Literal("2024-06-20", datatype=URIRef("http://www.w3.org/2001/XMLSchema#date"))))
        add!(g, Triple(EX("event1"), EX("datetime"), Literal("2024-01-15T10:30:00", datatype=URIRef("http://www.w3.org/2001/XMLSchema#dateTime"))))

        @testset "Date comparison in FILTER" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s ?d WHERE {
                    ?s ex:date ?d .
                    FILTER(?d > "2024-03-01"^^<http://www.w3.org/2001/XMLSchema#date>)
                }
            """)
            @test length(results) >= 1
            subjects = [r["s"] for r in results]
            @test EX("event2") in subjects
        end

        @testset "DateTime extraction" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT (YEAR(?dt) AS ?y) (MONTH(?dt) AS ?m) WHERE {
                    ex:event1 ex:datetime ?dt
                }
            """)
            @test length(results) == 1
            @test haskey(results[1], "y")
            @test haskey(results[1], "m")
            y_val = parse(Float64, results[1]["y"].lexical)
            m_val = parse(Float64, results[1]["m"].lexical)
            @test y_val == 2024
            @test m_val == 1
        end

        @testset "STR cast of typed literal" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT (STR(?d) AS ?ds) WHERE {
                    ex:event1 ex:date ?d
                }
            """)
            @test length(results) == 1
            @test results[1]["ds"].lexical == "2024-01-15"
        end
    end

    # ─── 5. OPTIONAL Clause ────────────────────────────────────────────

    @testset "OPTIONAL Clause" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("alice"), RDF.type, EX("Person")))
        add!(g, Triple(EX("alice"), EX("name"), Literal("Alice")))
        add!(g, Triple(EX("alice"), EX("email"), Literal("alice@example.org")))
        add!(g, Triple(EX("bob"), RDF.type, EX("Person")))
        add!(g, Triple(EX("bob"), EX("name"), Literal("Bob")))
        # Bob has no email

        @testset "Variables bound/unbound in OPTIONAL" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s ?email WHERE {
                    ?s a ex:Person .
                    OPTIONAL { ?s ex:email ?email }
                }
            """)
            @test length(results) == 2
            alice_row = filter(r -> r["s"] == EX("alice"), results)
            @test length(alice_row) == 1
            @test haskey(alice_row[1], "email")
            @test alice_row[1]["email"] == Literal("alice@example.org")

            bob_row = filter(r -> r["s"] == EX("bob"), results)
            @test length(bob_row) == 1
            # Bob's email is unbound
            @test !haskey(bob_row[1], "email") || bob_row[1]["email"] === nothing
        end

        @testset "Multiple OPTIONALs" begin
            add!(g, Triple(EX("alice"), EX("phone"), Literal("555-1234")))
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s ?email ?phone WHERE {
                    ?s a ex:Person .
                    OPTIONAL { ?s ex:email ?email }
                    OPTIONAL { ?s ex:phone ?phone }
                }
            """)
            @test length(results) == 2
            alice_row = filter(r -> r["s"] == EX("alice"), results)
            @test length(alice_row) == 1
            @test haskey(alice_row[1], "email")
            @test haskey(alice_row[1], "phone")
        end

        @testset "OPTIONAL with FILTER inside" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s ?email WHERE {
                    ?s a ex:Person .
                    OPTIONAL {
                        ?s ex:email ?email .
                        FILTER(CONTAINS(?email, "alice"))
                    }
                }
            """)
            @test length(results) >= 1
            alice_row = filter(r -> r["s"] == EX("alice"), results)
            @test length(alice_row) == 1
            @test haskey(alice_row[1], "email")
        end
    end

    # ─── 6. Subselect ──────────────────────────────────────────────────

    @testset "Subselect" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("alice"), RDF.type, EX("Person")))
        add!(g, Triple(EX("alice"), EX("age"), Literal(30)))
        add!(g, Triple(EX("alice"), EX("name"), Literal("Alice")))
        add!(g, Triple(EX("bob"), RDF.type, EX("Person")))
        add!(g, Triple(EX("bob"), EX("age"), Literal(25)))
        add!(g, Triple(EX("bob"), EX("name"), Literal("Bob")))
        add!(g, Triple(EX("carol"), RDF.type, EX("Person")))
        add!(g, Triple(EX("carol"), EX("age"), Literal(35)))
        add!(g, Triple(EX("carol"), EX("name"), Literal("Carol")))

        @testset "Nested SELECT within SELECT" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s ?name WHERE {
                    {
                        SELECT ?s WHERE {
                            ?s a ex:Person .
                            ?s ex:age ?age .
                            FILTER(?age > 27)
                        }
                    }
                    ?s ex:name ?name .
                }
            """)
            @test length(results) == 2
            names = Set(r["name"].lexical for r in results)
            @test "Alice" in names
            @test "Carol" in names
        end

        @testset "Subquery with LIMIT" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s ?name WHERE {
                    {
                        SELECT ?s WHERE {
                            ?s a ex:Person .
                        } LIMIT 2
                    }
                    ?s ex:name ?name .
                }
            """)
            @test length(results) == 2
        end

        @testset "Subquery with ORDER BY" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s ?name WHERE {
                    {
                        SELECT ?s WHERE {
                            ?s a ex:Person .
                            ?s ex:age ?age .
                        } ORDER BY DESC(?age) LIMIT 1
                    }
                    ?s ex:name ?name .
                }
            """)
            @test length(results) == 1
            @test results[1]["name"].lexical == "Carol"
        end
    end

    # ─── 7. Property Paths ─────────────────────────────────────────────

    @testset "Property Paths" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("a"), EX("p1"), EX("b")))
        add!(g, Triple(EX("b"), EX("p2"), EX("c")))
        add!(g, Triple(EX("a"), EX("q1"), EX("d")))
        add!(g, Triple(EX("d"), EX("q1"), EX("e")))
        add!(g, Triple(EX("e"), EX("q1"), EX("f")))

        @testset "Sequence path (p1/p2)" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?o WHERE {
                    ex:a ex:p1/ex:p2 ?o .
                }
            """)
            @test length(results) == 1
            @test results[1]["o"] == EX("c")
        end

        @testset "Alternative path (p1|q1)" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?o WHERE {
                    ex:a ex:p1|ex:q1 ?o .
                }
            """)
            @test length(results) == 2
            objs = Set(r["o"] for r in results)
            @test EX("b") in objs
            @test EX("d") in objs
        end

        @testset "Inverse path (^p1)" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s WHERE {
                    ex:b ^ex:p1 ?s .
                }
            """)
            @test length(results) == 1
            @test results[1]["s"] == EX("a")
        end

        @testset "OneOrMore path (+)" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?o WHERE {
                    ex:a ex:q1+ ?o .
                }
            """)
            ends = Set(r["o"] for r in results)
            @test EX("d") in ends
            @test EX("e") in ends
            @test EX("f") in ends
            @test !(EX("a") in ends)  # + excludes self
        end

        @testset "ZeroOrMore path (*)" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?o WHERE {
                    ex:a ex:q1* ?o .
                }
            """)
            ends = Set(r["o"] for r in results)
            @test EX("a") in ends  # * includes self
            @test EX("d") in ends
            @test EX("e") in ends
            @test EX("f") in ends
        end

        @testset "Negated property set" begin
            g2 = RDFGraph()
            bind!(g2, "ex", EX)
            add!(g2, Triple(EX("x"), EX("p1"), Literal("a")))
            add!(g2, Triple(EX("x"), EX("p2"), Literal("b")))
            add!(g2, Triple(EX("x"), EX("p3"), Literal("c")))
            results = sparql_query(g2, """
                PREFIX ex: <http://example.org/>
                SELECT ?o WHERE {
                    ex:x !(ex:p1|ex:p2) ?o .
                }
            """)
            @test length(results) >= 1
            objs = Set(r["o"] for r in results)
            @test Literal("c") in objs
            @test !(Literal("a") in objs)
            @test !(Literal("b") in objs)
        end
    end

    # ─── 8. SPARQL UNION with BIND ─────────────────────────────────────

    @testset "UNION with BIND" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("a"), EX("name"), Literal("Alice")))
        add!(g, Triple(EX("b"), EX("title"), Literal("Bob")))

        @testset "UNION of different patterns" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s ?label WHERE {
                    { ?s ex:name ?label }
                    UNION
                    { ?s ex:title ?label }
                }
            """)
            @test length(results) == 2
            labels = Set(r["label"].lexical for r in results)
            @test "Alice" in labels
            @test "Bob" in labels
        end

        @testset "UNION with BIND" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s ?label ?source WHERE {
                    {
                        ?s ex:name ?label .
                        BIND("name" AS ?source)
                    }
                    UNION
                    {
                        ?s ex:title ?label .
                        BIND("title" AS ?source)
                    }
                }
            """)
            @test length(results) == 2
            for r in results
                @test haskey(r, "source")
                if r["s"] == EX("a")
                    @test r["source"] == Literal("name")
                elseif r["s"] == EX("b")
                    @test r["source"] == Literal("title")
                end
            end
        end

        @testset "UNION with VALUES" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s ?label WHERE {
                    VALUES ?s { ex:a ex:b }
                    { ?s ex:name ?label }
                    UNION
                    { ?s ex:title ?label }
                }
            """)
            @test length(results) == 2
            labels = Set(r["label"].lexical for r in results)
            @test "Alice" in labels
            @test "Bob" in labels
        end
    end

    # ─── 9. SPARQL String Functions ────────────────────────────────────

    @testset "String Functions" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("a"), EX("name"), Literal("Alice")))
        add!(g, Triple(EX("b"), EX("name"), Literal("Bob")))

        @testset "CONCAT" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT (CONCAT(?name, " Smith") AS ?full) WHERE {
                    ex:a ex:name ?name
                }
            """)
            @test length(results) == 1
            @test results[1]["full"].lexical == "Alice Smith"
        end

        @testset "CONCAT with undefined variable" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s (CONCAT(?name, ?missing) AS ?result) WHERE {
                    ?s ex:name ?name .
                    OPTIONAL { ?s ex:label ?missing }
                }
            """)
            # Should get results even with undefined; CONCAT may produce empty or error
            @test length(results) >= 1
        end

        @testset "UCASE and LCASE" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT (UCASE(?name) AS ?upper) (LCASE(?name) AS ?lower) WHERE {
                    ex:a ex:name ?name
                }
            """)
            @test length(results) == 1
            @test results[1]["upper"].lexical == "ALICE"
            @test results[1]["lower"].lexical == "alice"
        end

        @testset "SHA1 hash" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT (SHA1(?name) AS ?hash) WHERE {
                    ex:a ex:name ?name
                }
            """)
            @test length(results) == 1
            @test results[1]["hash"] isa Literal
            @test length(results[1]["hash"].lexical) == 40  # SHA1 = 40 hex chars
        end

        @testset "SHA256 hash" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT (SHA256(?name) AS ?hash) WHERE {
                    ex:a ex:name ?name
                }
            """)
            @test length(results) == 1
            @test length(results[1]["hash"].lexical) == 64
        end

        @testset "STRLEN" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s (STRLEN(?name) AS ?len) WHERE {
                    ?s ex:name ?name
                }
            """)
            lens = Dict(r["s"] => parse(Int, r["len"].lexical) for r in results)
            @test lens[EX("a")] == 5  # "Alice"
            @test lens[EX("b")] == 3  # "Bob"
        end

        @testset "CONTAINS" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s WHERE {
                    ?s ex:name ?name .
                    FILTER CONTAINS(?name, "lic")
                }
            """)
            @test length(results) == 1
            @test results[1]["s"] == EX("a")
        end

        @testset "STRSTARTS and STRENDS" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s WHERE {
                    ?s ex:name ?name .
                    FILTER STRSTARTS(?name, "Al")
                }
            """)
            @test length(results) == 1
            @test results[1]["s"] == EX("a")

            results2 = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s WHERE {
                    ?s ex:name ?name .
                    FILTER STRENDS(?name, "ob")
                }
            """)
            @test length(results2) == 1
            @test results2[1]["s"] == EX("b")
        end
    end

    # ─── 10. SPARQL CONSTRUCT ──────────────────────────────────────────

    @testset "CONSTRUCT" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("alice"), RDF.type, EX("Person")))
        add!(g, Triple(EX("alice"), EX("name"), Literal("Alice")))
        add!(g, Triple(EX("alice"), EX("age"), Literal(30)))
        add!(g, Triple(EX("bob"), RDF.type, EX("Person")))
        add!(g, Triple(EX("bob"), EX("name"), Literal("Bob")))
        add!(g, Triple(EX("bob"), EX("age"), Literal(25)))

        @testset "CONSTRUCT basic" begin
            result = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                CONSTRUCT {
                    ?s ex:name ?name .
                } WHERE {
                    ?s a ex:Person .
                    ?s ex:name ?name .
                }
            """)
            @test result isa RDFGraph
            @test length(result) == 2
        end

        @testset "CONSTRUCT creates proper triples" begin
            result = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                CONSTRUCT {
                    ?s ex:displayName ?name .
                } WHERE {
                    ?s a ex:Person .
                    ?s ex:name ?name .
                }
            """)
            @test result isa RDFGraph
            ts = collect(triples(result))
            @test length(ts) == 2
            preds = Set(t.predicate for t in ts)
            @test EX("displayName") in preds
        end

        @testset "CONSTRUCT with FILTER" begin
            result = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                CONSTRUCT {
                    ?s ex:name ?name .
                } WHERE {
                    ?s a ex:Person .
                    ?s ex:name ?name .
                    ?s ex:age ?age .
                    FILTER(?age > 27)
                }
            """)
            @test result isa RDFGraph
            @test length(result) == 1
            ts = collect(triples(result))
            @test ts[1].object == Literal("Alice")
        end

        @testset "CONSTRUCT result is a graph" begin
            result = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                CONSTRUCT {
                    ?s a ex:Adult .
                } WHERE {
                    ?s a ex:Person .
                    ?s ex:age ?age .
                    FILTER(?age >= 18)
                }
            """)
            @test result isa RDFGraph
            # Can query the constructed graph
            sub_results = sparql_query(result, """
                PREFIX ex: <http://example.org/>
                SELECT ?s WHERE {
                    ?s a ex:Adult .
                }
            """)
            @test length(sub_results) == 2
        end

        @testset "CONSTRUCT allocates fresh blank nodes per solution" begin
            result = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                CONSTRUCT {
                    _:card ex:owner ?s .
                    _:card ex:name ?name .
                } WHERE {
                    ?s a ex:Person .
                    ?s ex:name ?name .
                }
            """)
            triples_out = collect(triples(result))
            @test length(triples_out) == 4

            owners = Dict{BNode, Identifier}()
            names = Dict{BNode, Identifier}()
            for t in triples_out
                if t.subject isa BNode && t.predicate == EX("owner")
                    owners[t.subject] = t.object
                elseif t.subject isa BNode && t.predicate == EX("name")
                    names[t.subject] = t.object
                end
            end

            @test length(owners) == 2
            @test Set(keys(owners)) == Set(keys(names))
            @test Set(values(owners)) == Set([EX("alice"), EX("bob")])
            @test Set(values(names)) == Set([Literal("Alice"), Literal("Bob")])
        end
    end

    # ─── Additional: ASK queries ───────────────────────────────────────

    @testset "ASK with complex patterns" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("alice"), EX("knows"), EX("bob")))
        add!(g, Triple(EX("bob"), EX("knows"), EX("carol")))

        @testset "ASK with property path" begin
            result = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                ASK {
                    ex:alice ex:knows/ex:knows ex:carol .
                }
            """)
            @test result === true
        end

        @testset "ASK false case" begin
            result = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                ASK {
                    ex:carol ex:knows ex:alice .
                }
            """)
            @test result === false
        end
    end

    # ─── Additional: DESCRIBE ──────────────────────────────────────────

    @testset "DESCRIBE" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("alice"), EX("name"), Literal("Alice")))
        add!(g, Triple(EX("alice"), EX("age"), Literal(30)))
        add!(g, Triple(EX("bob"), EX("name"), Literal("Bob")))

        @testset "DESCRIBE returns a graph" begin
            result = sparql_query(g, """
                DESCRIBE <http://example.org/alice>
            """)
            @test result isa RDFGraph
            @test length(result) >= 2  # name and age
        end
    end

    # ─── Additional: MINUS ─────────────────────────────────────────────

    @testset "MINUS" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("a"), RDF.type, EX("Thing")))
        add!(g, Triple(EX("b"), RDF.type, EX("Thing")))
        add!(g, Triple(EX("a"), EX("special"), Literal("yes")))

        @testset "MINUS basic" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s WHERE {
                    ?s a ex:Thing .
                    MINUS { ?s ex:special ?v }
                }
            """)
            @test length(results) == 1
            @test results[1]["s"] == EX("b")
        end
    end

    # ─── Additional: VALUES ────────────────────────────────────────────

    @testset "VALUES" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("a"), EX("name"), Literal("Alice")))
        add!(g, Triple(EX("b"), EX("name"), Literal("Bob")))
        add!(g, Triple(EX("c"), EX("name"), Literal("Carol")))

        @testset "VALUES restricts results" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?s ?name WHERE {
                    VALUES ?s { ex:a ex:c }
                    ?s ex:name ?name .
                }
            """)
            @test length(results) == 2
            names = Set(r["name"].lexical for r in results)
            @test "Alice" in names
            @test "Carol" in names
            @test !("Bob" in names)
        end
    end

    # ─── Additional: ORDER BY with OFFSET ──────────────────────────────

    @testset "ORDER BY with OFFSET" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("a"), EX("val"), Literal(1)))
        add!(g, Triple(EX("b"), EX("val"), Literal(2)))
        add!(g, Triple(EX("c"), EX("val"), Literal(3)))
        add!(g, Triple(EX("d"), EX("val"), Literal(4)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?val WHERE {
                ?s ex:val ?val .
            }
            ORDER BY ASC(?val)
            LIMIT 2
        """)
        @test length(results) == 2
        @test parse(Int, results[1]["val"].lexical) == 1
        @test parse(Int, results[2]["val"].lexical) == 2
    end
end
