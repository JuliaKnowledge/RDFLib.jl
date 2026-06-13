@testset "SPARQL 1.2 Gaps" begin
    @testset "TripleTerm Type" begin
        tt = TripleTerm(URIRef("http://example.org/s"), URIRef("http://example.org/p"), Literal("o"))
        @test tt isa TripleTerm
        @test tt isa Node
        @test tt.subject == URIRef("http://example.org/s")
        @test tt.predicate == URIRef("http://example.org/p")
        @test tt.object == Literal("o")
        @test n3(tt) == "<< <http://example.org/s> <http://example.org/p> \"o\" >>"

        # Equality and hashing
        tt2 = TripleTerm(URIRef("http://example.org/s"), URIRef("http://example.org/p"), Literal("o"))
        @test tt == tt2
        @test hash(tt) == hash(tt2)

        # Different triple term
        tt3 = TripleTerm(URIRef("http://example.org/s2"), URIRef("http://example.org/p"), Literal("o"))
        @test tt != tt3

        # As subject in a Triple
        t = Triple(tt, URIRef("http://example.org/q"), Literal("annotation"))
        @test t.subject == tt

        # Sort order
        @test RDFLib._type_order(tt) == 5
    end

    @testset "TRIPLE/SUBJECT/PREDICATE/OBJECT/isTRIPLE Functions" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        bind!(g, "ex", ex)
        add!(g, Triple(ex("s"), ex("p"), Literal("hello")))

        # TRIPLE function in BIND
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (TRIPLE(ex:s, ex:p, "hello") AS ?tt) WHERE {
                ex:s ex:p ?o
            }
        """)
        @test length(results) == 1
        @test results[1]["tt"] isa TripleTerm
        @test results[1]["tt"].subject == ex("s")

        # SUBJECT/PREDICATE/OBJECT
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (SUBJECT(TRIPLE(ex:s, ex:p, "hello")) AS ?subj)
                   (PREDICATE(TRIPLE(ex:s, ex:p, "hello")) AS ?pred)
                   (OBJECT(TRIPLE(ex:s, ex:p, "hello")) AS ?obj) WHERE {
                ex:s ex:p ?o
            }
        """)
        @test length(results) == 1
        @test results[1]["subj"] == ex("s")
        @test results[1]["pred"] == ex("p")
        @test results[1]["obj"] == Literal("hello")

        # isTRIPLE in BIND
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (isTRIPLE(TRIPLE(ex:s, ex:p, "hello")) AS ?is_tt)
                   (isTRIPLE(?o) AS ?is_not_tt) WHERE {
                ex:s ex:p ?o
            }
        """)
        @test length(results) == 1
        @test results[1]["is_tt"].lexical == "true"
        @test results[1]["is_not_tt"].lexical == "false"
    end

    @testset "FROM / FROM NAMED" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        bind!(g, "ex", ex)
        add!(g, Triple(ex("alice"), ex("name"), Literal("Alice")))

        # FROM clause should be parsed without error
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?name
            FROM <http://example.org/default-graph>
            WHERE { ?s ex:name ?name }
        """)
        @test length(results) == 1
        @test results[1]["name"].lexical == "Alice"

        # FROM NAMED
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?name
            FROM <http://example.org/default>
            FROM NAMED <http://example.org/graph1>
            FROM NAMED <http://example.org/graph2>
            WHERE { ?s ex:name ?name }
        """)
        @test length(results) == 1

        # Multiple FROM
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?name
            FROM <http://example.org/g1>
            FROM <http://example.org/g2>
            WHERE { ?s ex:name ?name }
        """)
        @test length(results) == 1
    end

    @testset "SERVICE (Federated Query) - Parse" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        bind!(g, "ex", ex)
        add!(g, Triple(ex("alice"), ex("name"), Literal("Alice")))

        # SERVICE SILENT should not throw even if endpoint is unreachable
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?name WHERE {
                ?s ex:name ?name .
                SERVICE SILENT <http://unreachable.example.org/sparql> {
                    ?s ex:age ?age
                }
            }
        """)
        # Should get results from local part, SERVICE SILENT fails silently
        @test length(results) >= 1
    end

    @testset "Reifier Syntax - Basic Parse" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        rdf_ns = Namespace("http://www.w3.org/1999/02/22-rdf-syntax-ns#")
        bind!(g, "ex", ex)
        bind!(g, "rdf", rdf_ns)

        # Create reification manually using standard RDF reification vocabulary
        add!(g, Triple(ex("stmt1"), rdf_ns("type"), rdf_ns("Statement")))
        add!(g, Triple(ex("stmt1"), rdf_ns("subject"), ex("alice")))
        add!(g, Triple(ex("stmt1"), rdf_ns("predicate"), ex("knows")))
        add!(g, Triple(ex("stmt1"), rdf_ns("object"), ex("bob")))
        add!(g, Triple(ex("stmt1"), ex("source"), Literal("trust")))

        # Query the reified statement
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
            SELECT ?source WHERE {
                ?stmt rdf:type rdf:Statement .
                ?stmt rdf:subject ex:alice .
                ?stmt rdf:predicate ex:knows .
                ?stmt rdf:object ex:bob .
                ?stmt ex:source ?source
            }
        """)
        @test length(results) == 1
        @test results[1]["source"].lexical == "trust"
    end

    @testset "GRAPH semantics (item 4)" begin
        ex = Namespace("http://example.org/")

        @testset "GRAPH on a plain RDFGraph yields zero solutions" begin
            g = RDFGraph()
            add!(g, Triple(ex("alice"), ex("name"), Literal("Alice")))
            # A plain graph has no named graphs: GRAPH <iri> matches nothing
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?name WHERE { GRAPH <urn:nope> { ?s ex:name ?name } }
            """)
            @test isempty(results)
            # ... and GRAPH ?g matches nothing / never binds ?g
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT ?g ?name WHERE { GRAPH ?g { ?s ex:name ?name } }
            """)
            @test isempty(results)
        end

        @testset "GRAPH on a Dataset" begin
            ds = Dataset()
            add!(ds, Triple(ex("alice"), ex("name"), Literal("Alice")))            # default
            add!(ds, Triple(ex("bob"), ex("name"), Literal("Bob")), ex("g1"))      # named g1
            add!(ds, Triple(ex("carol"), ex("name"), Literal("Carol")), ex("g2"))  # named g2

            # Default-graph query does not see named graphs
            results = sparql_query(ds, """
                PREFIX ex: <http://example.org/>
                SELECT ?name WHERE { ?s ex:name ?name }
            """)
            @test [r["name"].lexical for r in results] == ["Alice"]

            # GRAPH <g1> evaluates against that named graph only
            results = sparql_query(ds, """
                PREFIX ex: <http://example.org/>
                SELECT ?name WHERE { GRAPH ex:g1 { ?s ex:name ?name } }
            """)
            @test [r["name"].lexical for r in results] == ["Bob"]

            # GRAPH <missing> yields zero solutions
            results = sparql_query(ds, """
                PREFIX ex: <http://example.org/>
                SELECT ?name WHERE { GRAPH <urn:nope> { ?s ex:name ?name } }
            """)
            @test isempty(results)

            # GRAPH ?g iterates named graphs and binds ?g
            results = sparql_query(ds, """
                PREFIX ex: <http://example.org/>
                SELECT ?g ?name WHERE { GRAPH ?g { ?s ex:name ?name } }
            """)
            @test length(results) == 2
            found = Dict(r["g"] => r["name"].lexical for r in results)
            @test found[ex("g1")] == "Bob"
            @test found[ex("g2")] == "Carol"
        end

        @testset "FROM / FROM NAMED on a Dataset" begin
            ds = Dataset()
            add!(ds, Triple(ex("alice"), ex("name"), Literal("Alice")))
            add!(ds, Triple(ex("bob"), ex("name"), Literal("Bob")), ex("g1"))
            add!(ds, Triple(ex("carol"), ex("name"), Literal("Carol")), ex("g2"))

            # FROM <g1>: queried default graph is g1 (not the dataset default)
            results = sparql_query(ds, """
                PREFIX ex: <http://example.org/>
                SELECT ?name FROM ex:g1 WHERE { ?s ex:name ?name }
            """)
            @test [r["name"].lexical for r in results] == ["Bob"]

            # Multiple FROM merge
            results = sparql_query(ds, """
                PREFIX ex: <http://example.org/>
                SELECT ?name FROM ex:g1 FROM ex:g2 WHERE { ?s ex:name ?name }
            """)
            @test sort([r["name"].lexical for r in results]) == ["Bob", "Carol"]

            # FROM NAMED restricts the graphs GRAPH ?g iterates
            results = sparql_query(ds, """
                PREFIX ex: <http://example.org/>
                SELECT ?g ?name FROM NAMED ex:g1 WHERE { GRAPH ?g { ?s ex:name ?name } }
            """)
            @test length(results) == 1
            @test results[1]["g"] == ex("g1")
            @test results[1]["name"].lexical == "Bob"
        end

        @testset "FROM clauses parse on all query forms" begin
            g = RDFGraph()
            add!(g, Triple(ex("alice"), ex("name"), Literal("Alice")))
            # On a plain RDFGraph FROM falls back to querying the graph itself
            @test sparql_query(g, """
                PREFIX ex: <http://example.org/>
                ASK FROM ex:g WHERE { ?s ex:name ?o }
            """) == true
            cons = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                CONSTRUCT { ?s ex:n ?o } FROM ex:g WHERE { ?s ex:name ?o }
            """)
            @test length(cons) == 1
            desc = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                DESCRIBE ex:alice FROM ex:g
            """)
            @test length(desc) == 1
        end

        @testset "ConjunctiveGraph queries the union of all graphs" begin
            cg = ConjunctiveGraph()
            add!(cg, Triple(ex("alice"), ex("name"), Literal("Alice"))) # default
            add!(cg, Triple(ex("bob"), ex("name"), Literal("Bob")), ex("g1"))
            results = sparql_query(cg, """
                PREFIX ex: <http://example.org/>
                SELECT ?name WHERE { ?s ex:name ?name }
            """)
            @test sort([r["name"].lexical for r in results]) == ["Alice", "Bob"]
            # GRAPH still addresses the named graphs
            results = sparql_query(cg, """
                PREFIX ex: <http://example.org/>
                SELECT ?name WHERE { GRAPH ex:g1 { ?s ex:name ?name } }
            """)
            @test [r["name"].lexical for r in results] == ["Bob"]
        end
    end
end
