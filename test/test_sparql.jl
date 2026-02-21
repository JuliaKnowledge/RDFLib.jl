using Test
using RDFLib

@testset "SPARQL" begin
    EX = Namespace("http://example.org/")

    # Build a test graph
    function make_test_graph()
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        add!(g, EX("alice"), RDFS.label, Literal("Alice", lang="en"))
        add!(g, EX("alice"), EX("age"), Literal(30))
        add!(g, EX("alice"), EX("knows"), EX("bob"))
        add!(g, EX("bob"), RDF.type, EX("Person"))
        add!(g, EX("bob"), RDFS.label, Literal("Bob", lang="en"))
        add!(g, EX("bob"), EX("age"), Literal(25))
        add!(g, EX("carol"), RDF.type, EX("Organization"))
        add!(g, EX("carol"), RDFS.label, Literal("Carol Corp"))
        g
    end

    @testset "SELECT - basic" begin
        g = make_test_graph()
        results = sparql_query(g, """
            SELECT ?s WHERE {
                ?s <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://example.org/Person> .
            }
        """)
        @test length(results) == 2
        subjects = [r["s"] for r in results]
        @test EX("alice") in subjects
        @test EX("bob") in subjects
    end

    @testset "SELECT - with PREFIX" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
            SELECT ?s ?name WHERE {
                ?s rdf:type ex:Person .
                ?s <http://www.w3.org/2000/01/rdf-schema#label> ?name .
            }
        """)
        @test length(results) == 2
        names = [string(r["name"]) for r in results]
        @test "Alice" in names
        @test "Bob" in names
    end

    @testset "SELECT - with 'a' shorthand" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:Person .
            }
        """)
        @test length(results) == 2
    end

    @testset "SELECT *" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT * WHERE {
                ?s a ex:Person .
                ?s ex:age ?age .
            }
        """)
        @test length(results) == 2
        @test all(r -> haskey(r, "s") && haskey(r, "age"), results)
    end

    @testset "SELECT DISTINCT" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT DISTINCT ?type WHERE {
                ?s a ?type .
            }
        """)
        types = [r["type"] for r in results]
        @test length(unique(types)) == length(types)
    end

    @testset "SELECT with LIMIT" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:Person .
            } LIMIT 1
        """)
        @test length(results) == 1
    end

    @testset "SELECT with FILTER =" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:Person .
                ?s ex:age ?age .
                FILTER (?age = 30)
            }
        """)
        @test length(results) == 1
        @test results[1]["s"] == EX("alice")
    end

    @testset "SELECT with FILTER >" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:Person .
                ?s ex:age ?age .
                FILTER (?age > 27)
            }
        """)
        @test length(results) == 1
        @test results[1]["s"] == EX("alice")
    end

    @testset "SELECT with FILTER REGEX" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
            SELECT ?s ?name WHERE {
                ?s rdfs:label ?name .
                FILTER (REGEX(?name, "ali", "i"))
            }
        """)
        @test length(results) == 1
        @test results[1]["s"] == EX("alice")
    end

    @testset "SELECT with FILTER isURI" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?o WHERE {
                ?s ex:knows ?o .
                FILTER (isURI(?o))
            }
        """)
        @test length(results) == 1
    end

    @testset "ASK - true" begin
        g = make_test_graph()
        result = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            ASK {
                ex:alice a ex:Person .
            }
        """)
        @test result === true
    end

    @testset "ASK - false" begin
        g = make_test_graph()
        result = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            ASK {
                ex:alice a ex:Animal .
            }
        """)
        @test result === false
    end

    @testset "CONSTRUCT" begin
        g = make_test_graph()
        result = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
            CONSTRUCT {
                ?s rdfs:label ?name .
            } WHERE {
                ?s a ex:Person .
                ?s rdfs:label ?name .
            }
        """)
        @test result isa RDFGraph
        @test length(result) == 2  # Alice and Bob labels
    end

    @testset "OPTIONAL" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?knows WHERE {
                ?s a ex:Person .
                OPTIONAL { ?s ex:knows ?knows }
            }
        """)
        @test length(results) == 2
        alice_result = filter(r -> r["s"] == EX("alice"), results)
        @test length(alice_result) == 1
        @test haskey(alice_result[1], "knows")
    end

    @testset "no results" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:NonExistent .
            }
        """)
        @test isempty(results)
    end

    @testset "UNION" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                { ?s a ex:Person } UNION { ?s a ex:Organization }
            }
        """)
        subjects = [r["s"] for r in results]
        @test EX("alice") in subjects
        @test EX("bob") in subjects
        @test EX("carol") in subjects
    end

    @testset "COUNT aggregate" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (COUNT(?s) AS ?count) WHERE {
                ?s a ex:Person .
            }
        """)
        @test length(results) == 1
        @test toPython(results[1]["count"]) == 2
    end

    @testset "GROUP BY with COUNT" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?type (COUNT(?s) AS ?count) WHERE {
                ?s a ?type .
            } GROUP BY ?type
        """)
        @test length(results) == 2
        for r in results
            if r["type"] == EX("Person")
                @test toPython(r["count"]) == 2
            elseif r["type"] == EX("Organization")
                @test toPython(r["count"]) == 1
            end
        end
    end

    @testset "BIND" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?label WHERE {
                ?s a ex:Person .
                BIND (<http://example.org/Person> AS ?label)
            }
        """)
        @test length(results) == 2
        @test all(r -> r["label"] == EX("Person"), results)
    end

    @testset "FILTER NOT EXISTS" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:Person .
                FILTER NOT EXISTS { ?s ex:knows ?other }
            }
        """)
        # Bob doesn't know anyone
        subjects = [r["s"] for r in results]
        @test EX("bob") in subjects
        @test !(EX("alice") in subjects)
    end

    @testset "FILTER EXISTS" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:Person .
                FILTER EXISTS { ?s ex:knows ?other }
            }
        """)
        subjects = [r["s"] for r in results]
        @test EX("alice") in subjects
        @test !(EX("bob") in subjects)
    end

    @testset "property path - sequence" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
            SELECT ?name WHERE {
                ex:alice ex:knows/rdfs:label ?name .
            }
        """)
        @test length(results) >= 1
        names = [r["name"].lexical for r in results]
        @test "Bob" in names
    end

    @testset "property path - alternative" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
            SELECT ?val WHERE {
                ex:alice rdfs:label|ex:age ?val .
            }
        """)
        @test length(results) == 2
    end

    @testset "property path - inverse" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ex:bob ^ex:knows ?s .
            }
        """)
        @test length(results) == 1
        @test results[1]["s"] == URIRef("http://example.org/alice")
    end

    @testset "property path - one or more" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        add!(g, Triple(EX("a"), EX("next"), EX("b")))
        add!(g, Triple(EX("b"), EX("next"), EX("c")))
        add!(g, Triple(EX("c"), EX("next"), EX("d")))
        results = sparql_query(g, """
            SELECT ?end WHERE {
                <http://example.org/a> <http://example.org/next>+ ?end .
            }
        """)
        ends = Set([r["end"] for r in results])
        @test EX("b") in ends
        @test EX("c") in ends
        @test EX("d") in ends
        @test !(EX("a") in ends)  # + excludes self
    end

    @testset "property path - zero or more" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        add!(g, Triple(EX("a"), EX("next"), EX("b")))
        add!(g, Triple(EX("b"), EX("next"), EX("c")))
        results = sparql_query(g, """
            SELECT ?end WHERE {
                <http://example.org/a> <http://example.org/next>* ?end .
            }
        """)
        ends = Set([r["end"] for r in results])
        @test EX("a") in ends  # * includes self
        @test EX("b") in ends
        @test EX("c") in ends
    end
end
