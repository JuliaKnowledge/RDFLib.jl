using Test
using RDFLib

@testset "SPARQL Enhanced" begin
    EX = Namespace("http://example.org/")

    function make_test_graph()
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        add!(g, EX("alice"), RDFS.label, Literal("Alice", lang="en"))
        add!(g, EX("alice"), EX("age"), Literal(30))
        add!(g, EX("alice"), EX("knows"), EX("bob"))
        add!(g, EX("alice"), EX("email"), Literal("alice@example.org"))
        add!(g, EX("bob"), RDF.type, EX("Person"))
        add!(g, EX("bob"), RDFS.label, Literal("Bob", lang="en"))
        add!(g, EX("bob"), EX("age"), Literal(25))
        add!(g, EX("bob"), EX("knows"), EX("carol"))
        add!(g, EX("carol"), RDF.type, EX("Person"))
        add!(g, EX("carol"), RDFS.label, Literal("Carol", lang="fr"))
        add!(g, EX("carol"), EX("age"), Literal(35))
        add!(g, EX("org1"), RDF.type, EX("Organization"))
        add!(g, EX("org1"), RDFS.label, Literal("Acme Corp"))
        g
    end

    # ─── SPARQL UPDATE ──────────────────────────────────────────────

    @testset "INSERT DATA" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        sparql_update(g, """
            PREFIX ex: <http://example.org/>
            INSERT DATA {
                ex:x ex:p ex:y .
                ex:x ex:q "hello" .
            }
        """)
        @test length(g) == 2
        @test Triple(EX("x"), EX("p"), EX("y")) in g
        @test Triple(EX("x"), EX("q"), Literal("hello")) in g
    end

    @testset "DELETE DATA" begin
        g = make_test_graph()
        n = length(g)
        sparql_update(g, """
            DELETE DATA {
                <http://example.org/alice> <http://example.org/age> "30"^^<http://www.w3.org/2001/XMLSchema#integer> .
            }
        """)
        @test length(g) == n - 1
        results = sparql_query(g, """
            SELECT ?age WHERE {
                <http://example.org/alice> <http://example.org/age> ?age .
            }
        """)
        @test isempty(results)
    end

    @testset "DELETE WHERE" begin
        g = make_test_graph()
        sparql_update(g, """
            PREFIX ex: <http://example.org/>
            DELETE { ?s ex:age ?age } WHERE { ?s ex:age ?age }
        """)
        results = sparql_query(g, """
            SELECT ?s ?age WHERE {
                ?s <http://example.org/age> ?age .
            }
        """)
        @test isempty(results)
    end

    @testset "INSERT WHERE" begin
        g = make_test_graph()
        sparql_update(g, """
            PREFIX ex: <http://example.org/>
            INSERT { ?s ex:status ex:active }
            WHERE { ?s a ex:Person }
        """)
        results = sparql_query(g, """
            SELECT ?s WHERE {
                ?s <http://example.org/status> <http://example.org/active> .
            }
        """)
        @test length(results) == 3
    end

    @testset "INSERT WHERE allocates fresh blank nodes per solution" begin
        g = make_test_graph()
        sparql_update(g, """
            PREFIX ex: <http://example.org/>
            INSERT {
                _:card ex:owner ?s .
            }
            WHERE { ?s a ex:Person }
        """)

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?card ?owner WHERE {
                ?card ex:owner ?owner .
            }
        """)

        @test length(results) == 3
        @test length(Set(r["card"] for r in results)) == 3
        @test Set(r["owner"] for r in results) ==
              Set([EX("alice"), EX("bob"), EX("carol")])
    end

    @testset "DELETE INSERT WHERE" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("x"), EX("status"), EX("draft"))
        sparql_update(g, """
            PREFIX ex: <http://example.org/>
            DELETE { ?s ex:status ex:draft }
            INSERT { ?s ex:status ex:published }
            WHERE { ?s ex:status ex:draft }
        """)
        @test !(Triple(EX("x"), EX("status"), EX("draft")) in g)
        @test Triple(EX("x"), EX("status"), EX("published")) in g
    end

    @testset "CLEAR ALL" begin
        g = make_test_graph()
        @test length(g) > 0
        sparql_update(g, "CLEAR ALL")
        @test length(g) == 0
    end

    @testset "DROP ALL" begin
        g = make_test_graph()
        sparql_update(g, "DROP ALL")
        @test length(g) == 0
    end

    # ─── DESCRIBE ───────────────────────────────────────────────────

    @testset "DESCRIBE URI" begin
        g = make_test_graph()
        result = sparql_query(g, """
            DESCRIBE <http://example.org/alice>
        """)
        @test result isa RDFGraph
        @test length(result) >= 4  # type, label, age, knows, email
    end

    @testset "DESCRIBE with WHERE" begin
        g = make_test_graph()
        result = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            DESCRIBE ?s WHERE {
                ?s a ex:Person .
                ?s ex:age ?age .
            }
        """)
        @test result isa RDFGraph
        @test length(result) >= 4
    end

    # ─── MINUS ──────────────────────────────────────────────────────

    @testset "MINUS" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:Person .
                MINUS { ?s ex:knows ?other }
            }
        """)
        # carol is a Person but doesn't know anyone
        @test length(results) == 1
        @test results[1]["s"] == EX("carol")
    end

    # ─── VALUES ─────────────────────────────────────────────────────

    @testset "VALUES single variable" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?name WHERE {
                VALUES ?s { ex:alice ex:bob }
                ?s <http://www.w3.org/2000/01/rdf-schema#label> ?name .
            }
        """)
        @test length(results) == 2
        names = Set(r["name"] for r in results)
        @test Literal("Alice", lang="en") in names
        @test Literal("Bob", lang="en") in names
    end

    @testset "VALUES multi variable" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?type WHERE {
                VALUES (?s ?type) { (ex:alice ex:Person) (ex:org1 ex:Organization) }
                ?s a ?type .
            }
        """)
        @test length(results) == 2
    end

    # ─── SUBQUERY ───────────────────────────────────────────────────

    @testset "Subquery" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?name WHERE {
                {
                    SELECT ?s WHERE {
                        ?s a ex:Person .
                    }
                }
                ?s <http://www.w3.org/2000/01/rdf-schema#label> ?name .
            }
        """)
        @test length(results) == 3
    end

    # ─── FILTER && and || ───────────────────────────────────────────

    @testset "FILTER && (AND)" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?age WHERE {
                ?s a ex:Person .
                ?s ex:age ?age .
                FILTER (?age >= 25 && ?age <= 30)
            }
        """)
        @test length(results) == 2
        ages = Set(r["age"] for r in results)
        @test Literal(25) in ages
        @test Literal(30) in ages
    end

    @testset "FILTER || (OR)" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ?type .
                FILTER (?type = ex:Person || ?type = ex:Organization)
            }
        """)
        @test length(results) == 4  # 3 persons + 1 org
    end

    # ─── Enhanced FILTER functions ──────────────────────────────────

    @testset "FILTER LANG()" begin
        g = make_test_graph()
        results = sparql_query(g, """
            SELECT ?s ?name WHERE {
                ?s <http://www.w3.org/2000/01/rdf-schema#label> ?name .
                FILTER (LANG(?name) = "en")
            }
        """)
        @test length(results) == 2
    end

    @testset "FILTER CONTAINS()" begin
        g = make_test_graph()
        results = sparql_query(g, """
            SELECT ?s ?name WHERE {
                ?s <http://www.w3.org/2000/01/rdf-schema#label> ?name .
                FILTER CONTAINS(?name, "li")
            }
        """)
        @test length(results) >= 1  # "Alice" contains "li"
    end

    @testset "FILTER STRSTARTS()" begin
        g = make_test_graph()
        results = sparql_query(g, """
            SELECT ?s ?name WHERE {
                ?s <http://www.w3.org/2000/01/rdf-schema#label> ?name .
                FILTER STRSTARTS(?name, "Al")
            }
        """)
        @test length(results) == 1
        @test results[1]["s"] == EX("alice")
    end

    @testset "FILTER STRENDS()" begin
        g = make_test_graph()
        results = sparql_query(g, """
            SELECT ?s ?name WHERE {
                ?s <http://www.w3.org/2000/01/rdf-schema#label> ?name .
                FILTER STRENDS(?name, "ob")
            }
        """)
        @test length(results) == 1
        @test results[1]["s"] == EX("bob")
    end

    @testset "FILTER isNUMERIC()" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?val WHERE {
                ?s ex:age ?val .
                FILTER isNUMERIC(?val)
            }
        """)
        @test length(results) == 3
    end

    @testset "FILTER IN" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:Person .
                FILTER (?s IN (ex:alice, ex:bob))
            }
        """)
        @test length(results) == 2
    end

    @testset "FILTER NOT IN" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:Person .
                FILTER (?s NOT IN (ex:alice, ex:bob))
            }
        """)
        @test length(results) == 1
        @test results[1]["s"] == EX("carol")
    end

    # ─── Enhanced ORDER BY ──────────────────────────────────────────

    @testset "ORDER BY DESC" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?age WHERE {
                ?s a ex:Person .
                ?s ex:age ?age .
            }
            ORDER BY DESC(?age)
        """)
        @test length(results) == 3
        @test results[1]["age"] == Literal(35)
        @test results[3]["age"] == Literal(25)
    end

    @testset "ORDER BY ASC" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?age WHERE {
                ?s a ex:Person .
                ?s ex:age ?age .
            }
            ORDER BY ASC(?age)
        """)
        @test length(results) == 3
        @test results[1]["age"] == Literal(25)
        @test results[3]["age"] == Literal(35)
    end

    @testset "ORDER BY bare expression" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), EX("label"), Literal("Alice", lang="en"))
        add!(g, EX("alice"), EX("label"), Literal("Alicia", lang="es"))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?lbl (LANG(?lbl) AS ?lng) WHERE {
                ex:alice ex:label ?lbl .
            }
            ORDER BY LANG(?lbl)
        """)

        @test [r["lng"].lexical for r in results] == ["en", "es"]
    end

    # ─── Enhanced BIND expressions ──────────────────────────────────

    @testset "BIND IF()" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?category WHERE {
                ?s a ex:Person .
                ?s ex:age ?age .
                BIND(IF(?age > 29, "senior", "junior") AS ?category)
            }
        """)
        @test length(results) == 3
        categories = Dict(r["s"] => r["category"] for r in results)
        @test categories[EX("alice")] == Literal("senior")
        @test categories[EX("bob")] == Literal("junior")
        @test categories[EX("carol")] == Literal("senior")
    end

    @testset "BIND UCASE/LCASE" begin
        g = make_test_graph()
        results = sparql_query(g, """
            SELECT ?s ?upper WHERE {
                ?s <http://www.w3.org/2000/01/rdf-schema#label> ?name .
                BIND(UCASE(?name) AS ?upper)
            }
        """)
        uppers = Set(r["upper"] for r in results if haskey(r, "upper"))
        @test Literal("ALICE") in uppers || Literal("BOB") in uppers
    end

    @testset "BIND SUBSTR" begin
        g = make_test_graph()
        results = sparql_query(g, """
            SELECT ?s ?sub WHERE {
                ?s <http://www.w3.org/2000/01/rdf-schema#label> ?name .
                BIND(SUBSTR(?name, 1, 3) AS ?sub)
            }
        """)
        subs = Set(r["sub"] for r in results if haskey(r, "sub"))
        @test Literal("Ali") in subs || Literal("Bob") in subs
    end

    @testset "BIND STRLEN" begin
        g = make_test_graph()
        results = sparql_query(g, """
            SELECT ?s ?len WHERE {
                ?s <http://www.w3.org/2000/01/rdf-schema#label> ?name .
                BIND(STRLEN(?name) AS ?len)
            }
        """)
        lens = Dict(r["s"] => r["len"] for r in results if haskey(r, "len"))
        @test lens[EX("alice")] == Literal(5)
        @test lens[EX("bob")] == Literal(3)
    end

    @testset "BIND REPLACE" begin
        g = RDFGraph()
        add!(g, EX("x"), EX("val"), Literal("hello world"))
        results = sparql_query(g, """
            SELECT ?new WHERE {
                <http://example.org/x> <http://example.org/val> ?v .
                BIND(REPLACE(?v, "world", "Julia") AS ?new)
            }
        """)
        @test length(results) == 1
        @test results[1]["new"] == Literal("hello Julia")
    end

    @testset "BIND ABS/CEIL/FLOOR/ROUND" begin
        g = RDFGraph()
        add!(g, EX("x"), EX("val"), Literal(-3.7))
        results = sparql_query(g, """
            SELECT ?a ?c ?f ?r WHERE {
                <http://example.org/x> <http://example.org/val> ?v .
                BIND(ABS(?v) AS ?a)
                BIND(CEIL(?v) AS ?c)
                BIND(FLOOR(?v) AS ?f)
                BIND(ROUND(?v) AS ?r)
            }
        """)
        @test length(results) == 1
        r = results[1]
        @test haskey(r, "a") && haskey(r, "c") && haskey(r, "f") && haskey(r, "r")
    end

    @testset "BIND COALESCE" begin
        g = RDFGraph()
        add!(g, EX("x"), EX("name"), Literal("test"))
        results = sparql_query(g, """
            SELECT ?val WHERE {
                <http://example.org/x> <http://example.org/name> ?name .
                BIND(COALESCE(?missing, ?name) AS ?val)
            }
        """)
        @test length(results) == 1
        @test results[1]["val"] == Literal("test")
    end

    @testset "BIND NOW()" begin
        g = RDFGraph()
        add!(g, EX("x"), EX("p"), EX("y"))
        results = sparql_query(g, """
            SELECT ?t WHERE {
                <http://example.org/x> <http://example.org/p> ?o .
                BIND(NOW() AS ?t)
            }
        """)
        @test length(results) == 1
        @test haskey(results[1], "t")
        @test results[1]["t"] isa Literal
    end

    @testset "BIND UUID/STRUUID" begin
        g = RDFGraph()
        add!(g, EX("x"), EX("p"), EX("y"))
        results = sparql_query(g, """
            SELECT ?u ?su WHERE {
                <http://example.org/x> <http://example.org/p> ?o .
                BIND(UUID() AS ?u)
                BIND(STRUUID() AS ?su)
            }
        """)
        @test length(results) == 1
        @test haskey(results[1], "u")
        @test haskey(results[1], "su")
        @test results[1]["u"] isa URIRef
        @test results[1]["su"] isa Literal
    end

    # ─── Negated property paths ─────────────────────────────────────

    @testset "Negated property path" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?o WHERE {
                ex:alice !(ex:knows|ex:email) ?o .
            }
        """)
        # alice has type, label, age, knows, email
        # negating knows and email leaves type, label, age
        @test length(results) >= 2
        objs = Set(r["o"] for r in results)
        @test !(EX("bob") in objs)  # bob is via ex:knows
    end

    # ─── SPARQL Result Serialization ────────────────────────────────

    @testset "Results JSON - SELECT" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?age WHERE {
                ?s a ex:Person .
                ?s ex:age ?age .
            }
        """)
        json_str = sparql_results_json(results; variables=["s", "age"])
        @test occursin("\"head\"", json_str)
        @test occursin("\"results\"", json_str)
        @test occursin("\"bindings\"", json_str)
        @test occursin("\"vars\"", json_str)
        @test occursin("\"uri\"", json_str)
    end

    @testset "Results JSON - ASK" begin
        json_str = sparql_results_json(true)
        @test occursin("\"boolean\"", json_str)
        @test occursin("true", json_str)

        json_str2 = sparql_results_json(false)
        @test occursin("false", json_str2)
    end

    @testset "Results XML - SELECT" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE { ?s a ex:Person }
        """)
        xml_str = sparql_results_xml(results; variables=["s"])
        @test occursin("<sparql", xml_str)
        @test occursin("<head>", xml_str)
        @test occursin("<results>", xml_str)
        @test occursin("<variable", xml_str)
        @test occursin("<uri>", xml_str)
    end

    @testset "Results XML - ASK" begin
        xml_str = sparql_results_xml(true)
        @test occursin("<boolean>true</boolean>", xml_str)
    end

    @testset "Results CSV" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?age WHERE {
                ?s a ex:Person .
                ?s ex:age ?age .
            }
        """)
        csv_str = sparql_results_csv(results; variables=["s", "age"])
        lines = split(strip(csv_str), "\n")
        @test lines[1] == "s,age"
        @test length(lines) == 4  # header + 3 data rows
    end

    # ─── Complex integration tests ──────────────────────────────────

    @testset "Combined FILTER with && and function" begin
        g = make_test_graph()
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?name WHERE {
                ?s a ex:Person .
                ?s <http://www.w3.org/2000/01/rdf-schema#label> ?name .
                ?s ex:age ?age .
                FILTER (?age > 24 && STRSTARTS(?name, "A"))
            }
        """)
        @test length(results) == 1
        @test results[1]["s"] == EX("alice")
    end

    @testset "UPDATE then QUERY" begin
        g = RDFGraph()
        bind!(g, "ex", EX)

        # Insert some data
        sparql_update(g, """
            PREFIX ex: <http://example.org/>
            INSERT DATA {
                ex:a ex:value "1"^^<http://www.w3.org/2001/XMLSchema#integer> .
                ex:b ex:value "2"^^<http://www.w3.org/2001/XMLSchema#integer> .
                ex:c ex:value "3"^^<http://www.w3.org/2001/XMLSchema#integer> .
            }
        """)
        @test length(g) == 3

        # Delete one
        sparql_update(g, """
            PREFIX ex: <http://example.org/>
            DELETE DATA {
                ex:b ex:value "2"^^<http://www.w3.org/2001/XMLSchema#integer> .
            }
        """)
        @test length(g) == 2

        # Query remaining
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?v WHERE { ?s ex:value ?v }
            ORDER BY ASC(?v)
        """)
        @test length(results) == 2
    end

    @testset "MINUS vs NOT EXISTS equivalence" begin
        g = make_test_graph()
        # MINUS result
        r1 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:Person .
                MINUS { ?s ex:knows ?o }
            }
        """)
        # NOT EXISTS result
        r2 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:Person .
                FILTER NOT EXISTS { ?s ex:knows ?o }
            }
        """)
        # For this specific case they should give the same result
        @test Set(r["s"] for r in r1) == Set(r["s"] for r in r2)
    end
end
