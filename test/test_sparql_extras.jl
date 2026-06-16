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
            mins = Dict(r["g"] => get(r, "minval", nothing) for r in results)
            @test convert(Any, mins[EX("a")]) == 10
            @test convert(Any, mins[EX("b")]) == 5
            # Group "c" has no values: MIN over empty group is unbound (spec)
            @test mins[EX("c")] === nothing
        end

        @testset "MAX with undefined" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?g (MAX(?val) AS ?maxval) WHERE {
                    ?s ex:group ?g .
                    OPTIONAL { ?s ex:val ?val }
                } GROUP BY ?g
            """)
            maxs = Dict(r["g"] => get(r, "maxval", nothing) for r in results)
            @test convert(Any, maxs[EX("a")]) == 20
            @test convert(Any, maxs[EX("b")]) == 5
            # Group "c" has no values: MAX over empty group is unbound (spec)
            @test maxs[EX("c")] === nothing
        end

        @testset "SAMPLE with undefined" begin
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?g (SAMPLE(?val) AS ?samp) WHERE {
                    ?s ex:group ?g .
                    OPTIONAL { ?s ex:val ?val }
                } GROUP BY ?g
            """)
            samples = Dict(r["g"] => get(r, "samp", nothing) for r in results)
            @test samples[EX("a")] isa Literal
            @test convert(Any, samples[EX("a")]) in (10, 20)
            @test convert(Any, samples[EX("b")]) == 5
            # Group "c" has no values: SAMPLE over empty group is unbound (spec)
            @test samples[EX("c")] === nothing
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

# ─── Review regression fixes (evaluator correctness & value semantics) ──────
@testset "Evaluator Review Regressions" begin
    EX = Namespace("http://example.org/")

    @testset "FILTER(!BOUND) after star group (item 1)" begin
        g = RDFGraph()
        add!(g, Triple(EX("s1"), EX("p"), Literal(1)))
        add!(g, Triple(EX("s1"), EX("q"), Literal(2)))
        add!(g, Triple(EX("s2"), EX("p"), Literal(3)))
        add!(g, Triple(EX("s2"), EX("q"), Literal(4)))
        # Used to crash in _collect_vars_in_expr! (ExprUnaryOp field access)
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s ex:p ?x . ?s ex:q ?y .
                FILTER(!BOUND(?x))
            }
        """)
        @test isempty(results)
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s ex:p ?x . ?s ex:q ?y .
                OPTIONAL { ?s ex:r ?a }
                FILTER(!BOUND(?a))
            }
        """)
        @test length(results) == 2
    end

    @testset "Repeated variables in star groups (item 2)" begin
        g = RDFGraph()
        # s1: p and q have DIFFERENT values; s2: same value
        add!(g, Triple(EX("s1"), EX("p"), Literal("a")))
        add!(g, Triple(EX("s1"), EX("q"), Literal("b")))
        add!(g, Triple(EX("s2"), EX("p"), Literal("c")))
        add!(g, Triple(EX("s2"), EX("q"), Literal("c")))
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?x WHERE { ?s ex:p ?x . ?s ex:q ?x }
        """)
        @test length(results) == 1
        @test results[1]["s"] == EX("s2")

        # Subject var reused in object position within a star group
        g2 = RDFGraph()
        add!(g2, Triple(EX("n1"), EX("p"), EX("n1")))   # self-loop
        add!(g2, Triple(EX("n1"), EX("q"), Literal("y")))
        add!(g2, Triple(EX("n2"), EX("p"), EX("n1")))   # NOT a self-loop
        add!(g2, Triple(EX("n2"), EX("q"), Literal("y")))
        results = sparql_query(g2, """
            PREFIX ex: <http://example.org/>
            SELECT ?x WHERE { ?x ex:p ?x . ?x ex:q ?y }
        """)
        @test length(results) == 1
        @test results[1]["x"] == EX("n1")

        # COUNT(*) fast path must not ignore repeated variables
        g3 = RDFGraph()
        add!(g3, Triple(EX("a"), EX("p"), EX("a")))
        add!(g3, Triple(EX("a"), EX("p"), EX("b")))
        results = sparql_query(g3, "SELECT (COUNT(*) AS ?c) WHERE { ?s ?p ?s }")
        @test length(results) == 1
        @test results[1]["c"].lexical == "1"
    end

    @testset "FILTER applies over whole group (item 3)" begin
        g = RDFGraph()
        add!(g, Triple(EX("s1"), EX("p"), Literal(1)))
        add!(g, Triple(EX("s2"), EX("p"), Literal(2)))
        # FILTER appears BEFORE the triple that binds ?x
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE { FILTER(?x = 1) ?s ex:p ?x }
        """)
        @test length(results) == 1
        @test results[1]["s"] == EX("s1")
    end

    @testset "Projection always applied (item 7)" begin
        g = RDFGraph()
        add!(g, Triple(EX("a1"), EX("p"), Literal("pv")))
        add!(g, Triple(EX("a2"), EX("q"), Literal("qv")))
        add!(g, Triple(EX("a2"), EX("r"), Literal("leak")))
        # First UNION branch rows bind exactly {a,b}; second branch rows bind
        # {a,b,c} — ?c must NOT leak into the projected results.
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?a ?b WHERE {
                { ?a ex:p ?b } UNION { ?a ex:q ?b . ?a ex:r ?c }
            }
        """)
        @test length(results) == 2
        for r in results
            @test issubset(keys(r), Set(["a", "b"]))
        end
    end

    @testset "Left join with heterogeneous RHS rows (item 8)" begin
        g = RDFGraph()
        add!(g, Triple(EX("s1"), EX("p"), Literal("o")))
        add!(g, Triple(EX("s2"), EX("p"), Literal("o")))
        add!(g, Triple(EX("s1"), EX("v"), EX("v1")))
        add!(g, Triple(EX("v1"), EX("w"), Literal("w1")))
        # s2 has no ex:v → its row enters the second OPTIONAL with ?v unbound,
        # which must join (not duplicate, not drop) against the ?v ex:w rows.
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT * WHERE {
                ?s ex:p ?o .
                OPTIONAL { ?s ex:v ?v }
                OPTIONAL { ?v ex:w ?w }
            }
        """)
        @test length(results) == 2
        by_s = Dict(r["s"] => r for r in results)
        @test by_s[EX("s1")]["v"] == EX("v1")
        @test by_s[EX("s1")]["w"].lexical == "w1"
        # ?v unbound on the s2 side joins the (v1, w1) row
        @test by_s[EX("s2")]["v"] == EX("v1")
        @test by_s[EX("s2")]["w"].lexical == "w1"
    end

    @testset "Datatype-driven numerics (item 9)" begin
        g = RDFGraph()
        add!(g, Triple(EX("s"), EX("plain"), Literal("42")))
        add!(g, Triple(EX("s"), EX("typed"), Literal(42)))
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (ISNUMERIC(?p) AS ?np) (ISNUMERIC(?t) AS ?nt) WHERE {
                ?s ex:plain ?p . ?s ex:typed ?t
            }
        """)
        @test results[1]["np"].lexical == "false"  # plain literal NOT numeric
        @test results[1]["nt"].lexical == "true"

        # "10" < "9" is TRUE under codepoint string comparison
        r = sparql_query(g, """SELECT ?x WHERE { ?x ?p ?o . FILTER("10" < "9") } LIMIT 1""")
        @test length(r) == 1
        # 10 < 9 numerically is false
        r = sparql_query(g, """SELECT ?x WHERE { ?x ?p ?o . FILTER(10 < 9) } LIMIT 1""")
        @test isempty(r)
        # langString is not <-comparable (type error → row fails)
        r = sparql_query(g, """SELECT ?x WHERE { ?x ?p ?o . FILTER("a"@en < "b"@en) } LIMIT 1""")
        @test isempty(r)
        # dateTime comparison normalizes timezones to UTC
        r = sparql_query(g, """SELECT ?x WHERE { ?x ?p ?o .
            FILTER("2020-01-01T10:00:00+05:00"^^<http://www.w3.org/2001/XMLSchema#dateTime>
                 < "2020-01-01T06:01:00Z"^^<http://www.w3.org/2001/XMLSchema#dateTime>) } LIMIT 1""")
        @test length(r) == 1
        # Arithmetic typing: integer division yields decimal, + keeps integer
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (5 / 2 AS ?d) (2 + 3 AS ?i) WHERE { ?x ex:typed ?t }""")
        @test r[1]["d"].lexical == "2.5"
        @test r[1]["d"].datatype == URIRef("http://www.w3.org/2001/XMLSchema#decimal")
        @test r[1]["i"].lexical == "5"
        @test r[1]["i"].datatype == URIRef("http://www.w3.org/2001/XMLSchema#integer")
    end

    @testset "Equality semantics (item 10)" begin
        g = RDFGraph()
        add!(g, Triple(EX("s"), EX("label"), Literal("foo", lang="en")))
        # "foo"@en vs plain "foo": a language-tagged literal sits in a value
        # space disjoint from a simple literal, so RDFterm-equal reports them as
        # "known different" (FALSE), not a type error (per the W3C open-world
        # equality tests, e.g. open-eq-08). Hence `=` is false and `!=` is true.
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE { ?s ex:label ?l . FILTER(?l = "foo") }
        """)
        @test isempty(r)
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE { ?s ex:label ?l . FILTER(?l != "foo") }
        """)
        @test length(r) == 1
        # "1"@en = 1 → known different (lang-tagged vs numeric) → FALSE
        r = sparql_query(g, """SELECT ?s WHERE { ?s ?p ?o . FILTER("1"@en = 1) }""")
        @test isempty(r)
        # same-language different-lexical langStrings are simply unequal
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE { ?s ex:label ?l . FILTER(?l = "bar"@en) }
        """)
        @test isempty(r)
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE { ?s ex:label ?l . FILTER(?l != "bar"@en) }
        """)
        @test length(r) == 1
        # numeric value equality across types and lexical forms
        r = sparql_query(g, """SELECT ?s WHERE { ?s ?p ?o . FILTER(1 = 1.0) }""")
        @test length(r) == 1
        r = sparql_query(g, """SELECT ?s WHERE { ?s ?p ?o .
            FILTER("1"^^<http://www.w3.org/2001/XMLSchema#integer> =
                   "01"^^<http://www.w3.org/2001/XMLSchema#integer>) }""")
        @test length(r) == 1
    end

    @testset "Error semantics (item 11)" begin
        g = RDFGraph()
        add!(g, Triple(EX("s"), EX("p"), Literal(1)))
        # error || true → true
        r = sparql_query(g, """SELECT ?s WHERE { ?s ?p ?o . FILTER(?undef > 1 || true) }""")
        @test length(r) == 1
        # error || false → error (row fails)
        r = sparql_query(g, """SELECT ?s WHERE { ?s ?p ?o . FILTER(?undef > 1 || false) }""")
        @test isempty(r)
        # error && false → false; !(error && false) → true
        r = sparql_query(g, """SELECT ?s WHERE { ?s ?p ?o . FILTER(!(?undef > 1 && false)) }""")
        @test length(r) == 1
        # !error → error (row fails)
        r = sparql_query(g, """SELECT ?s WHERE { ?s ?p ?o . FILTER(!(?undef > 1)) }""")
        @test isempty(r)
        # division by zero is an error, not a match-all
        r = sparql_query(g, """SELECT ?s WHERE { ?s ?p ?o . FILTER(1/0 = 1 || true) }""")
        @test length(r) == 1
        r = sparql_query(g, """SELECT ?s WHERE { ?s ?p ?o . FILTER(1/0 = 1) }""")
        @test isempty(r)
        # IF(error, ...) → error
        r = sparql_query(g, """SELECT ?s WHERE { ?s ?p ?o . FILTER(IF(?undef > 1, true, true)) }""")
        @test isempty(r)
        # IN propagates errors per spec: a hit wins, otherwise error poisons
        r = sparql_query(g, """SELECT ?s WHERE { ?s ?p ?o . FILTER(2 IN (1/0, 2)) }""")
        @test length(r) == 1
        r = sparql_query(g, """SELECT ?s WHERE { ?s ?p ?o . FILTER(2 IN (1/0, 3)) }""")
        @test isempty(r)
        r = sparql_query(g, """SELECT ?s WHERE { ?s ?p ?o . FILTER(2 NOT IN (1/0, 3)) }""")
        @test isempty(r)
        # unknown function → per-row error, NOT a query abort
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE { ?s ?p ?o . FILTER(ex:noSuchFunction(?o)) }
        """)
        @test isempty(r)
        # EBV of an IRI is a type error
        r = sparql_query(g, """SELECT ?s WHERE { ?s ?p ?o . FILTER(?s) }""")
        @test isempty(r)
    end

    @testset "XSD constructor casts (item 11b)" begin
        g = RDFGraph()
        add!(g, Triple(EX("s"), EX("p"), Literal("x")))
        xsd = "http://www.w3.org/2001/XMLSchema#"
        r = sparql_query(g, """
            PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            SELECT (xsd:integer("42") AS ?i) (xsd:double("1.5") AS ?d)
                   (xsd:boolean("true") AS ?b) (xsd:string(42) AS ?st)
                   (xsd:decimal("3.14") AS ?dec) (xsd:integer(7.9) AS ?tr)
                   (xsd:integer("notanint") AS ?bad)
            WHERE { ?s ?p ?o }
        """)
        @test r[1]["i"].lexical == "42"
        @test r[1]["i"].datatype == URIRef(xsd * "integer")
        @test r[1]["d"].lexical == "1.5E0"  # canonical xsd:double lexical
        @test r[1]["d"].datatype == URIRef(xsd * "double")
        @test r[1]["b"].lexical == "true"
        @test r[1]["b"].datatype == URIRef(xsd * "boolean")
        @test r[1]["st"].lexical == "42"
        @test r[1]["dec"].datatype == URIRef(xsd * "decimal")
        @test r[1]["tr"].lexical == "7"    # truncation toward zero
        @test !haskey(r[1], "bad")          # invalid cast → unbound
        r = sparql_query(g, """
            PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            SELECT (xsd:dateTime("2020-05-06T07:08:09") AS ?dt) WHERE { ?s ?p ?o }
        """)
        @test r[1]["dt"].datatype == URIRef(xsd * "dateTime")
    end

    @testset "ORDER BY total order across term types (item 12)" begin
        g = RDFGraph()
        add!(g, Triple(EX("s"), EX("p"), Literal("x")))
        r = sparql_query(g, """
            SELECT ?v WHERE {
                VALUES ?v { UNDEF <http://z.example/iri> "alit" 5 }
            } ORDER BY ?v
        """)
        @test length(r) == 4
        @test !haskey(r[1], "v")                       # unbound first
        @test r[2]["v"] == URIRef("http://z.example/iri")  # IRIs before literals
        @test r[3]["v"].lexical == "5"                  # numeric literal
        @test r[4]["v"].lexical == "alit"               # then string
        # DESC inverts
        r = sparql_query(g, """
            SELECT ?v WHERE { VALUES ?v { UNDEF <http://z.example/iri> "alit" 5 } }
            ORDER BY DESC(?v)
        """)
        @test r[1]["v"].lexical == "alit"
        @test !haskey(r[4], "v")
        # strings sort by codepoint even when they look numeric
        r = sparql_query(g, """SELECT ?v WHERE { VALUES ?v { "10" "9" } } ORDER BY ?v""")
        @test r[1]["v"].lexical == "10"
        # numbers sort by value (incl. with LIMIT top-K fast path)
        r = sparql_query(g, """SELECT ?v WHERE { VALUES ?v { 10 9 } } ORDER BY ?v LIMIT 2""")
        @test r[1]["v"].lexical == "9"
    end

    @testset "Empty-group aggregates (item 13)" begin
        g = RDFGraph()
        add!(g, Triple(EX("s"), EX("p"), Literal(1)))
        # No matches + no GROUP BY → exactly one row
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (COUNT(?x) AS ?c) (SUM(?x) AS ?sum) (AVG(?x) AS ?avg)
                   (MIN(?x) AS ?min) (MAX(?x) AS ?max) (SAMPLE(?x) AS ?smp)
            WHERE { ?s ex:nomatch ?x }
        """)
        @test length(r) == 1
        @test r[1]["c"].lexical == "0"
        @test r[1]["sum"].lexical == "0"
        @test r[1]["avg"].lexical == "0"   # AVG over empty group = 0 (SPARQL §18.5)
        @test !haskey(r[1], "min")
        @test !haskey(r[1], "max")
        @test !haskey(r[1], "smp")
        # GROUP_CONCAT over the empty group is the empty string
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (GROUP_CONCAT(?x) AS ?gc) WHERE { ?s ex:nomatch ?x }
        """)
        @test length(r) == 1
        @test r[1]["gc"].lexical == ""
        # With GROUP BY: empty input → zero rows
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s (COUNT(?x) AS ?c) WHERE { ?s ex:nomatch ?x } GROUP BY ?s
        """)
        @test isempty(r)
    end

    @testset "Aggregate typing and errors (item 13b)" begin
        xsd = "http://www.w3.org/2001/XMLSchema#"
        g = RDFGraph()
        add!(g, Triple(EX("a"), EX("v"), Literal(10)))
        add!(g, Triple(EX("b"), EX("v"), Literal(20)))
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (SUM(?x) AS ?sum) (AVG(?x) AS ?avg) WHERE { ?s ex:v ?x }
        """)
        @test r[1]["sum"].lexical == "30"   # integer sum stays integer
        @test r[1]["sum"].datatype == URIRef(xsd * "integer")
        @test r[1]["avg"].lexical == "15.0" # integer avg promotes to decimal
        @test r[1]["avg"].datatype == URIRef(xsd * "decimal")
        # doubles stay doubles
        g2 = RDFGraph()
        add!(g2, Triple(EX("a"), EX("v"), Literal(1.5)))
        add!(g2, Triple(EX("b"), EX("v"), Literal(2.5)))
        r = sparql_query(g2, """
            PREFIX ex: <http://example.org/>
            SELECT (SUM(?x) AS ?sum) WHERE { ?s ex:v ?x }
        """)
        @test r[1]["sum"].lexical == "4.0E0"  # canonical xsd:double lexical
        @test r[1]["sum"].datatype == URIRef(xsd * "double")
        # a non-numeric value poisons SUM/AVG → unbound, not silently skipped
        g3 = RDFGraph()
        add!(g3, Triple(EX("a"), EX("v"), Literal(10)))
        add!(g3, Triple(EX("b"), EX("v"), Literal("oops")))
        r = sparql_query(g3, """
            PREFIX ex: <http://example.org/>
            SELECT (SUM(?x) AS ?sum) (AVG(?x) AS ?avg) (COUNT(?x) AS ?c) WHERE { ?s ex:v ?x }
        """)
        @test length(r) == 1
        @test !haskey(r[1], "sum")
        @test !haskey(r[1], "avg")
        @test r[1]["c"].lexical == "2"
        # COUNT(DISTINCT *) dedupes by row content
        g4 = RDFGraph()
        add!(g4, Triple(EX("a"), EX("p"), Literal("x")))
        add!(g4, Triple(EX("b"), EX("p"), Literal("y")))
        r = sparql_query(g4, """
            PREFIX ex: <http://example.org/>
            SELECT (COUNT(*) AS ?c) (COUNT(DISTINCT *) AS ?dc) WHERE {
                { ?s ex:p ?o } UNION { ?s ex:p ?o }
            }
        """)
        @test r[1]["c"].lexical == "4"
        @test r[1]["dc"].lexical == "2"
    end

    # ─── W3C conformance regressions (eval-agent fixes) ───────────────

    @testset "String builtins preserve language / type" begin
        g = RDFGraph()
        add!(g, Triple(EX("s"), EX("p"), Literal("bar", lang="en")))
        add!(g, Triple(EX("t"), EX("p"), Literal("foo")))
        # UCASE/LCASE keep the language tag
        r = sparql_query(g, "PREFIX ex: <http://example.org/> SELECT (UCASE(?v) AS ?u) WHERE { ex:s ex:p ?v }")
        @test r[1]["u"].lexical == "BAR"
        @test r[1]["u"].language == "en"
        # SUBSTR keeps the language tag
        r = sparql_query(g, "PREFIX ex: <http://example.org/> SELECT (SUBSTR(?v,1,2) AS ?u) WHERE { ex:s ex:p ?v }")
        @test r[1]["u"].lexical == "ba"
        @test r[1]["u"].language == "en"
        # STRBEFORE: found → keep lang; not found → plain ""; incompatible lang → error
        r = sparql_query(g, """PREFIX ex: <http://example.org/>
            SELECT (STRBEFORE(?v,"r") AS ?a) (STRBEFORE(?v,"z") AS ?b) WHERE { ex:s ex:p ?v }""")
        @test r[1]["a"].lexical == "ba" && r[1]["a"].language == "en"
        @test r[1]["b"].lexical == "" && r[1]["b"].language === nothing
        # CONCAT of matching langs keeps the lang; mixed → plain
        r = sparql_query(g, """PREFIX ex: <http://example.org/>
            SELECT (CONCAT(?v,?v) AS ?c) WHERE { ex:s ex:p ?v }""")
        @test r[1]["c"].lexical == "barbar" && r[1]["c"].language == "en"
        # STRDT on a non-string literal is a type error → unbound
        r = sparql_query(g, """PREFIX ex: <http://example.org/> PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            SELECT (STRDT(?v,xsd:string) AS ?d) WHERE { ex:s ex:p ?v }""")
        @test !haskey(r[1], "d")  # "bar"@en is not a simple literal
    end

    @testset "ENCODE_FOR_URI / SECONDS / CEIL typing" begin
        g = RDFGraph(); add!(g, Triple(EX("s"), EX("p"), Literal("x")))
        xsd = "http://www.w3.org/2001/XMLSchema#"
        r = sparql_query(g, """SELECT (ENCODE_FOR_URI("食べ物") AS ?e) WHERE { ?s ?p ?o }""")
        @test r[1]["e"].lexical == "%E9%A3%9F%E3%81%B9%E7%89%A9"
        # SECONDS returns xsd:decimal
        r = sparql_query(g, """PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            SELECT (SECONDS("2010-06-21T11:28:01Z"^^xsd:dateTime) AS ?s) WHERE { ?x ?p ?o }""")
        @test r[1]["s"].datatype == URIRef(xsd * "decimal")
        # CEIL/FLOOR/ROUND of a decimal → integer-lexical decimal
        r = sparql_query(g, """PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            SELECT (CEIL("2.5"^^xsd:decimal) AS ?c) (FLOOR("2.5"^^xsd:decimal) AS ?f) WHERE { ?x ?p ?o }""")
        @test r[1]["c"].lexical == "3" && r[1]["c"].datatype == URIRef(xsd * "decimal")
        @test r[1]["f"].lexical == "2"
    end

    @testset "IRI() resolves against BASE" begin
        r = sparql_query(RDFGraph(), """BASE <http://example.org/> SELECT (IRI("a") AS ?i) (URI("b") AS ?u) WHERE {}""")
        @test r[1]["i"] == URIRef("http://example.org/a")
        @test r[1]["u"] == URIRef("http://example.org/b")
    end

    @testset "Decimal SUM has no float noise; xsd:double canonical form" begin
        g = RDFGraph()
        add!(g, Triple(EX("a"), EX("v"), Literal("4.1", datatype=URIRef("http://www.w3.org/2001/XMLSchema#decimal"))))
        add!(g, Triple(EX("b"), EX("v"), Literal("7.0", datatype=URIRef("http://www.w3.org/2001/XMLSchema#decimal"))))
        r = sparql_query(g, "PREFIX ex: <http://example.org/> SELECT (SUM(?x) AS ?s) WHERE { ?n ex:v ?x }")
        @test r[1]["s"].lexical == "11.1"
        # xsd:double cast → canonical scientific lexical
        r = sparql_query(RDFGraph(), """PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            SELECT (xsd:double("0.2") AS ?d) WHERE {}""")
        @test r[1]["d"].lexical == "2.0E-1"
    end

    @testset "Aggregate-bearing SELECT expressions; empty AVG = 0" begin
        g = RDFGraph()
        for v in (1,2,3,4); add!(g, Triple(EX("x"), EX("p"), Literal(v))); end
        r = sparql_query(g, """PREFIX ex: <http://example.org/>
            SELECT ((MIN(?p)+MAX(?p))/2 AS ?c) WHERE { ?g ex:p ?p }""")
        @test r[1]["c"].lexical == "2.5"
        # AVG over an empty group = 0 (SPARQL §18.5)
        r = sparql_query(RDFGraph(), """SELECT (AVG(?x) AS ?a) WHERE { ?s ?p ?x }""")
        @test r[1]["a"].lexical == "0"
    end

    @testset "Blank nodes in query patterns act as variables" begin
        g = RDFGraph()
        add!(g, Triple(EX("a"), EX("p"), Literal(1)))
        add!(g, Triple(EX("b"), EX("p"), Literal(2)))
        r = sparql_query(g, "PREFIX ex: <http://example.org/> SELECT ?v WHERE { _:x ex:p ?v }")
        @test length(r) == 2
        # the blank-node variable is not projected in SELECT *
        r = sparql_query(g, "PREFIX ex: <http://example.org/> SELECT * WHERE { _:x ex:p ?v }")
        @test all(row -> Set(keys(row)) == Set(["v"]), r)
    end

    @testset "LANG / LANGMATCHES type errors propagate" begin
        g = RDFGraph()
        add!(g, Triple(EX("s"), EX("p"), EX("anIRI")))         # IRI object
        add!(g, Triple(EX("s"), EX("q"), Literal("x")))        # plain literal
        # LANG on an IRI is a type error → FILTER removes the row
        r = sparql_query(g, """PREFIX ex: <http://example.org/>
            SELECT ?o WHERE { ex:s ?p ?o . FILTER(LANG(?o) != "@x@") }""")
        @test length(r) == 1  # only the plain literal survives
    end

    @testset "REGEX q (literal) and x (extended) flags" begin
        g = RDFGraph()
        add!(g, Triple(EX("s"), EX("p"), Literal("a.b")))
        add!(g, Triple(EX("t"), EX("p"), Literal("axb")))
        # q flag: '.' is literal, so only "a.b" matches
        r = sparql_query(g, """PREFIX ex: <http://example.org/>
            SELECT ?s WHERE { ?s ex:p ?v . FILTER(REGEX(?v, "a.b", "q")) }""")
        @test length(r) == 1
        @test r[1]["s"] == EX("s")
    end

    @testset "Open-world equality and date timezone indeterminacy" begin
        g = RDFGraph()
        add!(g, Triple(EX("a"), EX("p"), Literal("xyz")))
        add!(g, Triple(EX("b"), EX("p"), Literal("xyz", lang="en")))
        # plain vs lang-tagged are known-different → != is true
        r = sparql_query(g, """PREFIX ex: <http://example.org/>
            SELECT ?x WHERE { ?x ex:p ?v . FILTER(?v != "xyz"@en) }""")
        @test length(r) == 1 && r[1]["x"] == EX("a")
        # date with TZ vs without, same day → indeterminate → neither = nor !=
        g2 = RDFGraph()
        xsd = "http://www.w3.org/2001/XMLSchema#"
        add!(g2, Triple(EX("d1"), EX("r"), Literal("2006-08-23", datatype=URIRef(xsd*"date"))))
        add!(g2, Triple(EX("d2"), EX("r"), Literal("2006-08-23Z", datatype=URIRef(xsd*"date"))))
        r = sparql_query(g2, """PREFIX ex: <http://example.org/> PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            SELECT ?x WHERE { ?x ex:r ?v . FILTER(?v = "2006-08-23"^^xsd:date) }""")
        @test length(r) == 1 && r[1]["x"] == EX("d1")  # only the exact lexical match
    end

    @testset "Fixed-length path multiset; zero-length on bound constant" begin
        g = RDFGraph()
        add!(g, Triple(EX("a"), EX("p1"), EX("b")))
        add!(g, Triple(EX("b"), EX("p2"), EX("c")))
        add!(g, Triple(EX("a"), EX("p1"), EX("d")))
        add!(g, Triple(EX("d"), EX("p2"), EX("c")))
        # two distinct intermediate nodes → 2 solutions for ?x = c
        r = sparql_query(g, """PREFIX ex: <http://example.org/>
            SELECT ?x WHERE { ex:a ex:p1/ex:p2 ?x }""")
        @test length(r) == 2
        # zero-or-more with a constant target on an empty graph → the constant
        r = sparql_query(RDFGraph(), """PREFIX ex: <http://example.org/>
            SELECT ?s WHERE { ?s ex:p* ex:o }""")
        @test length(r) == 1 && r[1]["s"] == EX("o")
    end

    @testset "REDUCED keeps duplicates" begin
        g = RDFGraph()
        add!(g, Triple(EX("a"), EX("p"), Literal("x")))
        add!(g, Triple(EX("b"), EX("p"), Literal("x")))
        r = sparql_query(g, "PREFIX ex: <http://example.org/> SELECT REDUCED ?v WHERE { ?s ex:p ?v }")
        @test length(r) == 2  # REDUCED need not eliminate duplicates
    end

    @testset "NOW/TZ/TIMEZONE (item 14)" begin
        g = RDFGraph()
        add!(g, Triple(EX("s"), EX("p"), Literal("x")))
        xsd = "http://www.w3.org/2001/XMLSchema#"
        r = sparql_query(g, """SELECT (NOW() AS ?n) WHERE { ?s ?p ?o }""")
        @test endswith(r[1]["n"].lexical, "Z")
        @test r[1]["n"].datatype == URIRef(xsd * "dateTime")
        r = sparql_query(g, """
            PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            SELECT (TZ("2011-01-10T14:45:13.815-05:00"^^xsd:dateTime) AS ?tz)
                   (TIMEZONE("2011-01-10T14:45:13.815-05:00"^^xsd:dateTime) AS ?tzd)
                   (TZ("2011-01-10T14:45:13Z"^^xsd:dateTime) AS ?tzz)
                   (TIMEZONE("2011-01-10T14:45:13Z"^^xsd:dateTime) AS ?tzdz)
                   (TIMEZONE("2011-01-10T14:45:13"^^xsd:dateTime) AS ?notz)
            WHERE { ?s ?p ?o }
        """)
        @test r[1]["tz"].lexical == "-05:00"
        @test r[1]["tzd"].lexical == "-PT5H"
        @test r[1]["tzd"].datatype == URIRef(xsd * "dayTimeDuration")
        @test r[1]["tzz"].lexical == "Z"
        @test r[1]["tzdz"].lexical == "PT0S"
        @test !haskey(r[1], "notz")  # TIMEZONE without timezone → error
    end

    @testset "LANGDIR family (item 15)" begin
        g = RDFGraph()
        add!(g, Triple(EX("s"), EX("label"), Literal("hello", lang="en")))
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (STRLANGDIR("chat", "fr", "ltr") AS ?dl)
                   (LANGDIR(STRLANGDIR("chat", "fr", "ltr")) AS ?dir)
                   (LANGDIR(?l) AS ?nodir)
                   (hasLANG(?l, "en") AS ?hl)
                   (hasLANG(?l, "fr") AS ?hlf)
                   (hasLANG("plain", "en") AS ?hlp)
                   (hasLANGDIR(STRLANGDIR("chat", "fr", "ltr"), "fr") AS ?hld)
                   (hasLANGDIR(?l, "en") AS ?hldn)
            WHERE { ?s ex:label ?l }
        """)
        @test r[1]["dl"].language == "fr"
        @test RDFLib.direction(r[1]["dl"]) == "ltr"
        @test r[1]["dir"].lexical == "ltr"
        @test r[1]["nodir"].lexical == ""
        @test r[1]["hl"].lexical == "true"
        @test r[1]["hlf"].lexical == "false"
        @test r[1]["hlp"].lexical == "false"
        @test r[1]["hld"].lexical == "true"
        @test r[1]["hldn"].lexical == "false"  # no direction on plain langString
        # invalid direction → error (unbound)
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (STRLANGDIR("x", "en", "sideways") AS ?bad) WHERE { ?s ex:label ?l }
        """)
        @test !haskey(r[1], "bad")
    end

    @testset "CONSTRUCT honors ORDER BY before LIMIT (item 6)" begin
        g = RDFGraph()
        add!(g, Triple(EX("a"), EX("val"), Literal(3)))
        add!(g, Triple(EX("b"), EX("val"), Literal(1)))
        add!(g, Triple(EX("c"), EX("val"), Literal(2)))
        out = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            CONSTRUCT { ?s ex:top ?v } WHERE { ?s ex:val ?v }
            ORDER BY DESC(?v) LIMIT 1
        """)
        ts = collect(RDFLib.triples(out))
        @test length(ts) == 1
        @test ts[1].subject == EX("a")
        @test ts[1].object == Literal(3)
    end

    @testset "SERVICE query serialization (item 5)" begin
        q = RDFLib.sparql_parse("""
            SELECT * WHERE {
                SERVICE <http://remote.example/sparql> {
                    ?s <http://p.example/p> ?o .
                    FILTER(?o > 5)
                    OPTIONAL { ?s <http://p.example/q> ?n }
                    BIND(STR(?o) AS ?os)
                }
            }
        """)
        svc = only(filter(p -> p isa RDFLib.PatService, q.patterns))
        txt = RDFLib._ast_build_service_query(svc.patterns)
        @test occursin("?s <http://p.example/p> ?o .", txt)
        @test occursin("FILTER(", txt)
        @test occursin("?o > \"5\"^^<http://www.w3.org/2001/XMLSchema#integer>", txt)
        @test occursin("OPTIONAL {", txt)
        @test occursin("BIND(STR(?o) AS ?os)", txt)
        # Unserializable content raises (caller treats per SILENT flag)
        sub = RDFLib.sparql_parse("SELECT * WHERE { { SELECT ?s WHERE { ?s ?p ?o } } }")
        @test_throws Exception RDFLib._ast_build_service_query(Vector{RDFLib.SparqlPattern}(sub.patterns))
    end

    @testset "UNION/MINUS/subquery joins (item 19)" begin
        g = RDFGraph()
        add!(g, Triple(EX("a"), EX("p"), Literal(1)))
        add!(g, Triple(EX("b"), EX("p"), Literal(2)))
        add!(g, Triple(EX("a"), EX("q"), Literal(3)))
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE { ?s ex:p ?o . { ?s ex:p ?o } UNION { ?s ex:q ?x } }
        """)
        @test length(r) == 3  # a (via p), b (via p), a (via q)
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE { ?s ex:p ?o . MINUS { ?s ex:q ?x } }
        """)
        @test length(r) == 1
        @test r[1]["s"] == EX("b")
        r = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?c WHERE {
                ?s ex:p ?o .
                { SELECT ?s (COUNT(?x) AS ?c) WHERE { ?s ex:q ?x } GROUP BY ?s }
            }
        """)
        @test length(r) == 1
        @test r[1]["s"] == EX("a")
        @test r[1]["c"].lexical == "1"
    end
end
