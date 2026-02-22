@testset "SPARQL 1.2" begin
    # Build a test graph
    g = RDFGraph()
    ex = Namespace("http://example.org/")
    bind!(g, "ex", ex)

    add!(g, Triple(ex("alice"), ex("name"), Literal("Alice")))
    add!(g, Triple(ex("alice"), ex("age"), Literal(30)))
    add!(g, Triple(ex("alice"), ex("born"), Literal("1994-06-15T08:30:00", datatype=URIRef("http://www.w3.org/2001/XMLSchema#dateTime"))))
    add!(g, Triple(ex("bob"), ex("name"), Literal("Bob")))
    add!(g, Triple(ex("bob"), ex("age"), Literal(25)))
    add!(g, Triple(ex("bob"), ex("score"), Literal(3.14)))
    add!(g, Triple(ex("carol"), ex("name"), Literal("Carol")))
    add!(g, Triple(ex("carol"), ex("age"), Literal(30.0)))
    add!(g, Triple(ex("carol"), ex("email"), Literal("carol@example.org")))

    @testset "Hash Functions" begin
        # SHA1
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?name (SHA1(?name) AS ?hash) WHERE {
                ex:alice ex:name ?name
            }
        """)
        @test length(results) == 1
        @test haskey(results[1], "hash")
        @test results[1]["hash"] isa Literal
        @test length(results[1]["hash"].lexical) == 40  # SHA1 hex = 40 chars

        # SHA256
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?name (SHA256(?name) AS ?hash) WHERE {
                ex:alice ex:name ?name
            }
        """)
        @test length(results) == 1
        @test length(results[1]["hash"].lexical) == 64  # SHA256 hex = 64 chars

        # SHA384
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?name (SHA384(?name) AS ?hash) WHERE {
                ex:alice ex:name ?name
            }
        """)
        @test length(results) == 1
        @test length(results[1]["hash"].lexical) == 96

        # SHA512
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?name (SHA512(?name) AS ?hash) WHERE {
                ex:alice ex:name ?name
            }
        """)
        @test length(results) == 1
        @test length(results[1]["hash"].lexical) == 128
    end

    @testset "Date/Time Functions" begin
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?born (YEAR(?born) AS ?y) (MONTH(?born) AS ?m) (DAY(?born) AS ?d)
                   (HOURS(?born) AS ?h) (MINUTES(?born) AS ?min) (SECONDS(?born) AS ?sec)
            WHERE {
                ex:alice ex:born ?born
            }
        """)
        @test length(results) == 1
        r = results[1]
        @test haskey(r, "y")
        @test haskey(r, "m")
        @test haskey(r, "d")
        @test haskey(r, "h")
        @test haskey(r, "min")
        @test haskey(r, "sec")

        # Check values
        _numval(lit::Literal) = parse(Float64, lit.lexical)
        _numval(x) = parse(Float64, string(x))
        @test _numval(r["y"]) == 1994
        @test _numval(r["m"]) == 6
        @test _numval(r["d"]) == 15
        @test _numval(r["h"]) == 8
        @test _numval(r["min"]) == 30
        @test _numval(r["sec"]) == 0
    end

    @testset "RAND Function" begin
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (RAND() AS ?r) WHERE {
                ex:alice ex:name ?name
            }
        """)
        @test length(results) == 1
        @test haskey(results[1], "r")
        val = parse(Float64, results[1]["r"].lexical)
        @test 0.0 <= val < 1.0
    end

    @testset "STRBEFORE / STRAFTER" begin
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (STRBEFORE(?email, "@") AS ?user) (STRAFTER(?email, "@") AS ?domain) WHERE {
                ex:carol ex:email ?email
            }
        """)
        @test length(results) == 1
        @test results[1]["user"].lexical == "carol"
        @test results[1]["domain"].lexical == "example.org"
    end

    @testset "sameValue Function" begin
        # sameValue: value-based equality — 30 == 30.0 is true
        # Test with BIND + sameValue
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?age (sameValue(?age, 30) AS ?same) WHERE {
                ?s ex:age ?age
            }
        """)
        # alice has age=30, carol has age=30.0
        # Both should have sameValue = true
        for r in results
            s = string(r["s"])
            if s == "http://example.org/alice" || s == "http://example.org/carol"
                @test r["same"].lexical == "true"
            end
        end
        # Bob has age=25, sameValue(25, 30) = false
        bob = filter(r -> string(r["s"]) == "http://example.org/bob", results)
        @test length(bob) == 1
        @test bob[1]["same"].lexical == "false"
    end

    @testset "Arithmetic Expressions" begin
        # Basic addition
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?name (?age + 1 AS ?next_age) WHERE {
                ?s ex:name ?name .
                ?s ex:age ?age
            }
            ORDER BY ?name
        """)
        @test length(results) >= 2
        # Find Alice's result
        alice_result = filter(r -> r["name"].lexical == "Alice", results)
        @test length(alice_result) == 1
        next_age = parse(Float64, alice_result[1]["next_age"].lexical)
        @test next_age == 31.0

        # Multiplication
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (?age * 2 AS ?double_age) WHERE {
                ex:bob ex:age ?age
            }
        """)
        @test length(results) == 1
        @test parse(Float64, results[1]["double_age"].lexical) == 50.0

        # Division
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (?age / 5 AS ?fifth) WHERE {
                ex:bob ex:age ?age
            }
        """)
        @test length(results) == 1
        @test parse(Float64, results[1]["fifth"].lexical) == 5.0

        # Subtraction
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (?age - 5 AS ?younger) WHERE {
                ex:bob ex:age ?age
            }
        """)
        @test length(results) == 1
        @test parse(Float64, results[1]["younger"].lexical) == 20.0
    end

    @testset "SELECT Expressions" begin
        # Expression in SELECT using STR
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (STR(?s) AS ?subject_str) ?name WHERE {
                ?s ex:name ?name
            }
            ORDER BY ?name
            LIMIT 1
        """)
        @test length(results) == 1
        @test haskey(results[1], "subject_str")
        @test results[1]["subject_str"].lexical == "http://example.org/alice"
        @test results[1]["name"].lexical == "Alice"

        # UCASE in SELECT
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (UCASE(?name) AS ?upper_name) WHERE {
                ex:alice ex:name ?name
            }
        """)
        @test length(results) == 1
        @test results[1]["upper_name"].lexical == "ALICE"

        # STRLEN in SELECT
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (STRLEN(?name) AS ?len) WHERE {
                ex:alice ex:name ?name
            }
        """)
        @test length(results) == 1
        @test parse(Int, results[1]["len"].lexical) == 5
    end

    @testset "VERSION Declaration" begin
        # VERSION should be parsed and ignored
        results = sparql_query(g, """
            VERSION '1.2'
            PREFIX ex: <http://example.org/>
            SELECT ?name WHERE {
                ex:alice ex:name ?name
            }
        """)
        @test length(results) == 1
        @test results[1]["name"].lexical == "Alice"
    end

    @testset "REDUCED Modifier" begin
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT REDUCED ?name WHERE {
                ?s ex:name ?name
            }
        """)
        @test length(results) >= 1
        # All names should be distinct (REDUCED eliminates most/all duplicates)
        names = [r["name"].lexical for r in results]
        @test length(names) == length(Set(names))
    end

    @testset "CONSTRUCT WHERE Shorthand" begin
        result_g = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            CONSTRUCT WHERE {
                ex:alice ex:name ?name
            }
        """)
        @test result_g isa RDFGraph
        @test length(result_g) == 1
        ts = collect(triples(result_g))
        @test ts[1].subject == ex("alice")
        @test ts[1].predicate == ex("name")
        @test ts[1].object == Literal("Alice")
    end

    @testset "GRAPH Pattern" begin
        # Create a Dataset with named graphs
        ds = Dataset()
        default_g = get_graph(ds)
        add!(default_g, Triple(ex("alice"), ex("name"), Literal("Alice")))

        ng = add_graph(ds, ex("graph1"))
        add!(ng, Triple(ex("bob"), ex("name"), Literal("Bob")))

        # Query default graph only
        results = sparql_query(default_g, """
            PREFIX ex: <http://example.org/>
            SELECT ?name WHERE {
                ?s ex:name ?name
            }
        """)
        @test length(results) >= 1
    end

    @testset "Combined SPARQL 1.2 Query" begin
        # A query using multiple 1.2 features
        results = sparql_query(g, """
            VERSION '1.2'
            PREFIX ex: <http://example.org/>
            SELECT ?name (?age + 1 AS ?next_age) (UCASE(?name) AS ?upper) WHERE {
                ?s ex:name ?name .
                ?s ex:age ?age
                FILTER(?age > 20)
            }
            ORDER BY ?name
        """)
        @test length(results) >= 2
        # Alice should be first (alphabetical)
        @test results[1]["name"].lexical == "Alice"
        @test results[1]["upper"].lexical == "ALICE"
        next_age = parse(Float64, results[1]["next_age"].lexical)
        @test next_age == 31.0
    end
end
