using Test
using RDFLib

# Helper to extract numeric value from a Literal
_numval(lit::Literal) = tryparse(Float64, lit.lexical)
_numval(x) = tryparse(Float64, string(x))

@testset "SPARQL 1.2 Spec Examples" begin

    # ─── Section 2: Making Simple Queries ──────────────────────────

    @testset "§2.1 Writing a Simple Query" begin
        g = RDFGraph()
        dc = Namespace("http://purl.org/dc/elements/1.1/")
        add!(g, Triple(URIRef("http://example.org/book/book1"), dc("title"), Literal("SPARQL Tutorial")))

        results = sparql_query(g, """
            PREFIX dc: <http://purl.org/dc/elements/1.1/>
            SELECT ?title WHERE {
                <http://example.org/book/book1> dc:title ?title .
            }
        """)
        @test length(results) == 1
        @test results[1]["title"] == Literal("SPARQL Tutorial")
    end

    @testset "§2.2 Multiple Matches" begin
        g = RDFGraph()
        foaf = Namespace("http://xmlns.com/foaf/0.1/")
        add!(g, Triple(BNode("a"), foaf("name"), Literal("Johnny Lee Outlaw")))
        add!(g, Triple(BNode("a"), foaf("mbox"), URIRef("mailto:jlow@example.com")))
        add!(g, Triple(BNode("b"), foaf("name"), Literal("Peter Goodguy")))
        add!(g, Triple(BNode("b"), foaf("mbox"), URIRef("mailto:peter@example.org")))

        results = sparql_query(g, """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            SELECT ?name ?mbox WHERE {
                ?x foaf:name ?name .
                ?x foaf:mbox ?mbox .
            }
        """)
        @test length(results) == 2
        names = Set(r["name"].lexical for r in results)
        @test "Johnny Lee Outlaw" in names
        @test "Peter Goodguy" in names
    end

    @testset "§2.3.1 Matching Literals with Language Tags" begin
        g = RDFGraph()
        rdfs_ns = Namespace("http://www.w3.org/2000/01/rdf-schema#")
        add!(g, Triple(URIRef("http://example.org/cat"), rdfs_ns("label"), Literal("cat", lang="en")))
        add!(g, Triple(URIRef("http://example.org/cat"), rdfs_ns("label"), Literal("chat", lang="fr")))

        # Match with lang tag "en"
        results = sparql_query(g, """
            PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
            SELECT ?label WHERE {
                <http://example.org/cat> rdfs:label ?label .
                FILTER (LANG(?label) = "en")
            }
        """)
        @test length(results) == 1
        @test results[1]["label"].lexical == "cat"
        @test results[1]["label"].language == "en"

        # Plain literal "cat" (no lang tag) should NOT match "cat"@en
        results2 = sparql_query(g, """
            PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
            SELECT ?x WHERE {
                ?x rdfs:label "cat" .
            }
        """)
        @test isempty(results2)
    end

    @testset "§2.3.2 Matching Literals with Numeric Types" begin
        g = RDFGraph()
        ns = Namespace("http://example.org/ns#")
        add!(g, Triple(URIRef("http://example.org/ns#y"), ns("p"), Literal(42)))

        results = sparql_query(g, """
            PREFIX ns: <http://example.org/ns#>
            SELECT ?v WHERE {
                ns:y ns:p ?v .
            }
        """)
        @test length(results) == 1
        @test _numval(results[1]["v"]) == 42.0
    end

    @testset "§2.5 Creating Values with Expressions" begin
        g = RDFGraph()
        foaf = Namespace("http://xmlns.com/foaf/0.1/")
        add!(g, Triple(BNode("a"), foaf("givenName"), Literal("John")))
        add!(g, Triple(BNode("a"), foaf("surname"), Literal("Doe")))

        # CONCAT with BIND
        results = sparql_query(g, """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            SELECT ?name WHERE {
                ?p foaf:givenName ?g .
                ?p foaf:surname ?s .
                BIND(CONCAT(?g, " ", ?s) AS ?name)
            }
        """)
        @test length(results) == 1
        @test results[1]["name"].lexical == "John Doe"
    end

    @testset "§2.6 Building RDF Graphs (CONSTRUCT)" begin
        g = RDFGraph()
        org = Namespace("http://example.org/org#")
        foaf = Namespace("http://xmlns.com/foaf/0.1/")
        add!(g, Triple(URIRef("http://example.org/person/1"), org("employeeName"), Literal("Alice")))
        add!(g, Triple(URIRef("http://example.org/person/2"), org("employeeName"), Literal("Bob")))

        result = sparql_query(g, """
            PREFIX org: <http://example.org/org#>
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            CONSTRUCT { ?x foaf:name ?name }
            WHERE { ?x org:employeeName ?name }
        """)
        @test result isa RDFGraph
        @test length(result) == 2
        ts = collect(triples(result))
        preds = Set(t.predicate for t in ts)
        @test URIRef("http://xmlns.com/foaf/0.1/name") in preds
    end

    # ─── Section 3: RDF Term Constraints ───────────────────────────

    @testset "§3.1 Restricting the Value of Strings" begin
        g = RDFGraph()
        dc = Namespace("http://purl.org/dc/elements/1.1/")
        add!(g, Triple(URIRef("http://example.org/book/book1"), dc("title"), Literal("SPARQL Tutorial")))
        add!(g, Triple(URIRef("http://example.org/book/book2"), dc("title"), Literal("The Semantic Web")))

        # FILTER regex — match titles starting with "SPARQL"
        results = sparql_query(g, """
            PREFIX dc: <http://purl.org/dc/elements/1.1/>
            SELECT ?title WHERE {
                ?x dc:title ?title .
                FILTER regex(?title, "^SPARQL")
            }
        """)
        @test length(results) == 1
        @test results[1]["title"].lexical == "SPARQL Tutorial"

        # Case-insensitive regex
        results2 = sparql_query(g, """
            PREFIX dc: <http://purl.org/dc/elements/1.1/>
            SELECT ?title WHERE {
                ?x dc:title ?title .
                FILTER regex(?title, "^sparql", "i")
            }
        """)
        @test length(results2) == 1
        @test results2[1]["title"].lexical == "SPARQL Tutorial"
    end

    @testset "§3.2 Restricting Numeric Values" begin
        g = RDFGraph()
        ns = Namespace("http://example.org/ns#")
        dc = Namespace("http://purl.org/dc/elements/1.1/")
        add!(g, Triple(URIRef("http://example.org/book/book1"), dc("title"), Literal("SPARQL Tutorial")))
        add!(g, Triple(URIRef("http://example.org/book/book1"), ns("price"), Literal(42.0)))
        add!(g, Triple(URIRef("http://example.org/book/book2"), dc("title"), Literal("The Semantic Web")))
        add!(g, Triple(URIRef("http://example.org/book/book2"), ns("price"), Literal(23.0)))

        results = sparql_query(g, """
            PREFIX dc: <http://purl.org/dc/elements/1.1/>
            PREFIX ns: <http://example.org/ns#>
            SELECT ?title ?price WHERE {
                ?x dc:title ?title .
                ?x ns:price ?price .
                FILTER (?price < 30.5)
            }
        """)
        @test length(results) == 1
        @test results[1]["title"].lexical == "The Semantic Web"
    end

    # ─── Section 5.2.2: Scope of Filters ──────────────────────────

    @testset "§5.2.2 Scope of Filters" begin
        g = RDFGraph()
        dc = Namespace("http://purl.org/dc/elements/1.1/")
        ns = Namespace("http://example.org/ns#")
        add!(g, Triple(URIRef("http://example.org/b1"), dc("title"), Literal("SPARQL Tutorial")))
        add!(g, Triple(URIRef("http://example.org/b1"), ns("price"), Literal(42.0)))
        add!(g, Triple(URIRef("http://example.org/b2"), dc("title"), Literal("Advanced RDF")))
        add!(g, Triple(URIRef("http://example.org/b2"), ns("price"), Literal(10.0)))

        # Filter at end of group — standard usage
        r1 = sparql_query(g, """
            PREFIX dc: <http://purl.org/dc/elements/1.1/>
            PREFIX ns: <http://example.org/ns#>
            SELECT ?title WHERE {
                ?x dc:title ?title .
                ?x ns:price ?price .
                FILTER (?price < 30)
            }
        """)
        @test length(r1) == 1
        @test r1[1]["title"].lexical == "Advanced RDF"
    end

    # ─── Section 6: Optional Values ────────────────────────────────

    @testset "§6.1 Optional Pattern Matching" begin
        g = RDFGraph()
        foaf = Namespace("http://xmlns.com/foaf/0.1/")
        add!(g, Triple(BNode("a"), foaf("name"), Literal("Alice")))
        add!(g, Triple(BNode("a"), foaf("mbox"), URIRef("mailto:alice@example.com")))
        add!(g, Triple(BNode("b"), foaf("name"), Literal("Bob")))
        # Bob has no mbox

        results = sparql_query(g, """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            SELECT ?name ?mbox WHERE {
                ?x foaf:name ?name .
                OPTIONAL { ?x foaf:mbox ?mbox }
            }
        """)
        @test length(results) == 2
        alice = filter(r -> r["name"].lexical == "Alice", results)
        @test length(alice) == 1
        @test haskey(alice[1], "mbox")
        bob = filter(r -> r["name"].lexical == "Bob", results)
        @test length(bob) == 1
        # Bob may or may not have "mbox" key; if present it should be unbound
    end

    @testset "§6.2 Constraints in Optional" begin
        g = RDFGraph()
        dc = Namespace("http://purl.org/dc/elements/1.1/")
        ns = Namespace("http://example.org/ns#")
        add!(g, Triple(URIRef("http://example.org/book/book1"), dc("title"), Literal("SPARQL Tutorial")))
        add!(g, Triple(URIRef("http://example.org/book/book1"), ns("price"), Literal(42.0)))
        add!(g, Triple(URIRef("http://example.org/book/book2"), dc("title"), Literal("The Semantic Web")))
        add!(g, Triple(URIRef("http://example.org/book/book2"), ns("price"), Literal(23.0)))

        results = sparql_query(g, """
            PREFIX dc: <http://purl.org/dc/elements/1.1/>
            PREFIX ns: <http://example.org/ns#>
            SELECT ?title ?price WHERE {
                ?x dc:title ?title .
                OPTIONAL { ?x ns:price ?price . FILTER (?price < 30) }
            }
        """)
        @test length(results) == 2
        # Book2 ($23) should have price; Book1 ($42) should not pass the filter
        book2 = filter(r -> r["title"].lexical == "The Semantic Web", results)
        @test length(book2) == 1
        @test haskey(book2[1], "price")
    end

    @testset "§6.3 Multiple Optional Graph Patterns" begin
        g = RDFGraph()
        foaf = Namespace("http://xmlns.com/foaf/0.1/")
        add!(g, Triple(BNode("a"), foaf("name"), Literal("Alice")))
        add!(g, Triple(BNode("a"), foaf("mbox"), URIRef("mailto:alice@example.com")))
        add!(g, Triple(BNode("a"), foaf("homepage"), URIRef("http://alice.example.com")))
        add!(g, Triple(BNode("b"), foaf("name"), Literal("Bob")))
        add!(g, Triple(BNode("b"), foaf("mbox"), URIRef("mailto:bob@example.com")))
        # Bob has mbox but no homepage

        results = sparql_query(g, """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            SELECT ?name ?mbox ?homepage WHERE {
                ?x foaf:name ?name .
                OPTIONAL { ?x foaf:mbox ?mbox }
                OPTIONAL { ?x foaf:homepage ?homepage }
            }
        """)
        @test length(results) == 2
        alice = filter(r -> r["name"].lexical == "Alice", results)
        @test length(alice) == 1
        @test haskey(alice[1], "mbox")
        @test haskey(alice[1], "homepage")
    end

    # ─── Section 7: Alternatives (UNION) ──────────────────────────

    @testset "§7 UNION - alternative patterns" begin
        g = RDFGraph()
        dc10 = Namespace("http://purl.org/dc/elements/1.0/")
        dc11 = Namespace("http://purl.org/dc/elements/1.1/")
        add!(g, Triple(URIRef("http://example.org/book/book1"), dc10("title"), Literal("SPARQL - First Edition")))
        add!(g, Triple(URIRef("http://example.org/book/book2"), dc11("title"), Literal("SPARQL - Second Edition")))

        results = sparql_query(g, """
            PREFIX dc10: <http://purl.org/dc/elements/1.0/>
            PREFIX dc11: <http://purl.org/dc/elements/1.1/>
            SELECT ?title WHERE {
                { ?book dc10:title ?title } UNION { ?book dc11:title ?title }
            }
        """)
        @test length(results) == 2
        titles = Set(r["title"].lexical for r in results)
        @test "SPARQL - First Edition" in titles
        @test "SPARQL - Second Edition" in titles
    end

    @testset "§7 UNION - multi-variable" begin
        g = RDFGraph()
        dc10 = Namespace("http://purl.org/dc/elements/1.0/")
        dc11 = Namespace("http://purl.org/dc/elements/1.1/")
        ex = Namespace("http://example.org/ns#")
        add!(g, Triple(URIRef("http://example.org/book/book1"), dc10("title"), Literal("SPARQL - First")))
        add!(g, Triple(URIRef("http://example.org/book/book1"), dc10("creator"), Literal("Alice")))
        add!(g, Triple(URIRef("http://example.org/book/book2"), dc11("title"), Literal("SPARQL - Second")))
        add!(g, Triple(URIRef("http://example.org/book/book2"), dc11("creator"), Literal("Bob")))

        results = sparql_query(g, """
            PREFIX dc10: <http://purl.org/dc/elements/1.0/>
            PREFIX dc11: <http://purl.org/dc/elements/1.1/>
            SELECT ?title ?creator WHERE {
                { ?book dc10:title ?title . ?book dc10:creator ?creator }
                UNION
                { ?book dc11:title ?title . ?book dc11:creator ?creator }
            }
        """)
        @test length(results) == 2
    end

    # ─── Section 8: Negation ───────────────────────────────────────

    @testset "§8.1.1 NOT EXISTS" begin
        g = RDFGraph()
        foaf = Namespace("http://xmlns.com/foaf/0.1/")
        add!(g, Triple(URIRef("http://example.org/alice"), RDF.type, foaf("Person")))
        add!(g, Triple(URIRef("http://example.org/alice"), foaf("name"), Literal("Alice")))
        add!(g, Triple(URIRef("http://example.org/bob"), RDF.type, foaf("Person")))
        # Bob has no foaf:name

        results = sparql_query(g, """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            SELECT ?person WHERE {
                ?person a foaf:Person .
                FILTER NOT EXISTS { ?person foaf:name ?name }
            }
        """)
        @test length(results) == 1
        @test results[1]["person"] == URIRef("http://example.org/bob")
    end

    @testset "§8.1.2 EXISTS" begin
        g = RDFGraph()
        foaf = Namespace("http://xmlns.com/foaf/0.1/")
        add!(g, Triple(URIRef("http://example.org/alice"), RDF.type, foaf("Person")))
        add!(g, Triple(URIRef("http://example.org/alice"), foaf("name"), Literal("Alice")))
        add!(g, Triple(URIRef("http://example.org/bob"), RDF.type, foaf("Person")))

        results = sparql_query(g, """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            SELECT ?person WHERE {
                ?person a foaf:Person .
                FILTER EXISTS { ?person foaf:name ?name }
            }
        """)
        @test length(results) == 1
        @test results[1]["person"] == URIRef("http://example.org/alice")
    end

    @testset "§8.2 MINUS" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("alice"), RDF.type, ex("Person")))
        add!(g, Triple(ex("alice"), ex("knows"), ex("bob")))
        add!(g, Triple(ex("bob"), RDF.type, ex("Person")))
        add!(g, Triple(ex("carol"), RDF.type, ex("Person")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s a ex:Person .
                MINUS { ?s ex:knows ?other }
            }
        """)
        subjects = Set(r["s"] for r in results)
        @test !(ex("alice") in subjects)  # alice knows bob
        @test ex("bob") in subjects
        @test ex("carol") in subjects
    end

    @testset "§8.3.1 NOT EXISTS vs MINUS — shared variables" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("b"), ex("c")))

        # NOT EXISTS: inner ?s is correlated with outer ?s
        r1 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s ex:b ex:c .
                FILTER NOT EXISTS { ?s ex:b ex:c }
            }
        """)
        @test isempty(r1)

        # MINUS: shared variable ?s means rows with matching ?s are removed
        r2 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s ex:b ex:c .
                MINUS { ?s ex:b ex:c }
            }
        """)
        @test isempty(r2)
    end

    @testset "§8.3.2 NOT EXISTS vs MINUS — fixed pattern (no shared vars)" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("b"), ex("c")))

        # MINUS with no shared variables — nothing removed (no compatible bindings)
        r1 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s ex:b ex:c .
                MINUS { ?x ex:b ex:c }
            }
        """)
        @test length(r1) == 1

        # NOT EXISTS with different var — inner pattern still matches → result removed
        r2 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s ex:b ex:c .
                FILTER NOT EXISTS { ?x ex:b ex:c }
            }
        """)
        @test isempty(r2)
    end

    # ─── Section 9: Property Paths ─────────────────────────────────

    @testset "§9.2 Alternative paths (|)" begin
        g = RDFGraph()
        dc = Namespace("http://purl.org/dc/elements/1.1/")
        rdfs_ns = Namespace("http://www.w3.org/2000/01/rdf-schema#")
        add!(g, Triple(URIRef("http://example.org/book1"), dc("title"), Literal("SPARQL")))
        add!(g, Triple(URIRef("http://example.org/book2"), rdfs_ns("label"), Literal("Advanced RDF")))

        results = sparql_query(g, """
            PREFIX dc: <http://purl.org/dc/elements/1.1/>
            PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
            SELECT ?x ?title WHERE {
                ?x dc:title|rdfs:label ?title .
            }
        """)
        @test length(results) == 2
        titles = Set(r["title"].lexical for r in results)
        @test "SPARQL" in titles
        @test "Advanced RDF" in titles
    end

    @testset "§9.2 Sequence paths (/)" begin
        g = RDFGraph()
        foaf = Namespace("http://xmlns.com/foaf/0.1/")
        add!(g, Triple(URIRef("http://example.org/alice"), foaf("knows"), URIRef("http://example.org/bob")))
        add!(g, Triple(URIRef("http://example.org/bob"), foaf("name"), Literal("Bob")))

        results = sparql_query(g, """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            SELECT ?name WHERE {
                <http://example.org/alice> foaf:knows/foaf:name ?name .
            }
        """)
        @test length(results) == 1
        @test results[1]["name"].lexical == "Bob"
    end

    @testset "§9.2 Two-step sequence path" begin
        g = RDFGraph()
        foaf = Namespace("http://xmlns.com/foaf/0.1/")
        add!(g, Triple(URIRef("http://example.org/alice"), foaf("knows"), URIRef("http://example.org/bob")))
        add!(g, Triple(URIRef("http://example.org/bob"), foaf("knows"), URIRef("http://example.org/carol")))
        add!(g, Triple(URIRef("http://example.org/carol"), foaf("name"), Literal("Carol")))

        results = sparql_query(g, """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            SELECT ?name WHERE {
                <http://example.org/alice> foaf:knows/foaf:knows/foaf:name ?name .
            }
        """)
        @test length(results) == 1
        @test results[1]["name"].lexical == "Carol"
    end

    @testset "§9.2 Inverse paths (^)" begin
        g = RDFGraph()
        foaf = Namespace("http://xmlns.com/foaf/0.1/")
        add!(g, Triple(URIRef("http://example.org/alice"), foaf("mbox"), URIRef("mailto:alice@example.org")))

        results = sparql_query(g, """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            SELECT ?x WHERE {
                <mailto:alice@example.org> ^foaf:mbox ?x .
            }
        """)
        @test length(results) == 1
        @test results[1]["x"] == URIRef("http://example.org/alice")
    end

    @testset "§9.2 Arbitrary-length paths (+)" begin
        g = RDFGraph()
        foaf = Namespace("http://xmlns.com/foaf/0.1/")
        add!(g, Triple(URIRef("http://example.org/alice"), foaf("knows"), URIRef("http://example.org/bob")))
        add!(g, Triple(URIRef("http://example.org/bob"), foaf("knows"), URIRef("http://example.org/carol")))
        add!(g, Triple(URIRef("http://example.org/carol"), foaf("knows"), URIRef("http://example.org/dave")))

        results = sparql_query(g, """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            SELECT ?person WHERE {
                <http://example.org/alice> foaf:knows+ ?person .
            }
        """)
        persons = Set(r["person"] for r in results)
        @test URIRef("http://example.org/bob") in persons
        @test URIRef("http://example.org/carol") in persons
        @test URIRef("http://example.org/dave") in persons
        @test !(URIRef("http://example.org/alice") in persons)
    end

    @testset "§9.2 rdfs:subClassOf* (zero-or-more)" begin
        g = RDFGraph()
        rdf_ns = Namespace("http://www.w3.org/1999/02/22-rdf-syntax-ns#")
        rdfs_ns = Namespace("http://www.w3.org/2000/01/rdf-schema#")
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), rdf_ns("type"), ex("Dog")))
        add!(g, Triple(ex("Dog"), rdfs_ns("subClassOf"), ex("Animal")))
        add!(g, Triple(ex("Animal"), rdfs_ns("subClassOf"), ex("LivingThing")))

        results = sparql_query(g, """
            PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
            PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
            PREFIX ex: <http://example.org/>
            SELECT ?type WHERE {
                ex:a rdf:type/rdfs:subClassOf* ?type .
            }
        """)
        types = Set(r["type"] for r in results)
        @test ex("Dog") in types
        @test ex("Animal") in types
        @test ex("LivingThing") in types
    end

    @testset "§9.2 Negated property paths" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        rdf_ns = Namespace("http://www.w3.org/1999/02/22-rdf-syntax-ns#")
        add!(g, Triple(ex("a"), rdf_ns("type"), ex("Thing")))
        add!(g, Triple(ex("a"), ex("name"), Literal("Alice")))
        add!(g, Triple(ex("a"), ex("age"), Literal(30)))

        results = sparql_query(g, """
            PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
            PREFIX ex: <http://example.org/>
            SELECT ?o WHERE {
                ex:a !(rdf:type) ?o .
            }
        """)
        objs = Set(r["o"] for r in results)
        @test !(ex("Thing") in objs)
        @test Literal("Alice") in objs || Literal(30) in objs
    end

    @testset "§9.2 RDF collection traversal (rdf:rest*/rdf:first)" begin
        g = RDFGraph()
        rdf_ns = Namespace("http://www.w3.org/1999/02/22-rdf-syntax-ns#")
        ex = Namespace("http://example.org/")
        # Build a list: (1 2 3)
        add!(g, Triple(ex("list"), rdf_ns("first"), Literal(1)))
        add!(g, Triple(ex("list"), rdf_ns("rest"), BNode("r1")))
        add!(g, Triple(BNode("r1"), rdf_ns("first"), Literal(2)))
        add!(g, Triple(BNode("r1"), rdf_ns("rest"), BNode("r2")))
        add!(g, Triple(BNode("r2"), rdf_ns("first"), Literal(3)))
        add!(g, Triple(BNode("r2"), rdf_ns("rest"), rdf_ns("nil")))

        results = sparql_query(g, """
            PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
            PREFIX ex: <http://example.org/>
            SELECT ?item WHERE {
                ex:list rdf:rest*/rdf:first ?item .
            }
        """)
        items = Set(_numval(r["item"]) for r in results)
        @test 1.0 in items
        @test 2.0 in items
        @test 3.0 in items
    end

    # ─── Section 10: Assignment ────────────────────────────────────

    @testset "§10.1 BIND" begin
        g = RDFGraph()
        ns = Namespace("http://example.org/ns#")
        add!(g, Triple(URIRef("http://example.org/item1"), ns("price"), Literal(100.0)))
        add!(g, Triple(URIRef("http://example.org/item1"), ns("discount"), Literal(0.2)))

        results = sparql_query(g, """
            PREFIX ns: <http://example.org/ns#>
            SELECT ?item ?price WHERE {
                ?item ns:price ?p .
                ?item ns:discount ?discount .
                BIND(?p*(1-?discount) AS ?price)
            }
        """)
        @test length(results) == 1
        @test haskey(results[1], "price")
        @test _numval(results[1]["price"]) ≈ 80.0
    end

    @testset "§10.2 VALUES — single variable" begin
        g = RDFGraph()
        dc = Namespace("http://purl.org/dc/elements/1.1/")
        ns = Namespace("http://example.org/ns#")
        add!(g, Triple(URIRef("http://example.org/book/book1"), dc("title"), Literal("SPARQL")))
        add!(g, Triple(URIRef("http://example.org/book/book1"), ns("price"), Literal(42.0)))
        add!(g, Triple(URIRef("http://example.org/book/book2"), dc("title"), Literal("RDF Primer")))
        add!(g, Triple(URIRef("http://example.org/book/book2"), ns("price"), Literal(20.0)))
        add!(g, Triple(URIRef("http://example.org/book/book3"), dc("title"), Literal("Linked Data")))
        add!(g, Triple(URIRef("http://example.org/book/book3"), ns("price"), Literal(15.0)))

        results = sparql_query(g, """
            PREFIX dc: <http://purl.org/dc/elements/1.1/>
            PREFIX : <http://example.org/book/>
            SELECT ?book ?title WHERE {
                VALUES ?book { :book1 :book3 }
                ?book dc:title ?title .
            }
        """)
        @test length(results) == 2
        titles = Set(r["title"].lexical for r in results)
        @test "SPARQL" in titles
        @test "Linked Data" in titles
    end

    @testset "§10.2 VALUES — multi variable with UNDEF" begin
        g = RDFGraph()
        dc = Namespace("http://purl.org/dc/elements/1.1/")
        ns = Namespace("http://example.org/ns#")
        add!(g, Triple(URIRef("http://example.org/book/book1"), dc("title"), Literal("SPARQL")))
        add!(g, Triple(URIRef("http://example.org/book/book1"), ns("price"), Literal(42.0)))
        add!(g, Triple(URIRef("http://example.org/book/book2"), dc("title"), Literal("RDF Primer")))
        add!(g, Triple(URIRef("http://example.org/book/book2"), ns("price"), Literal(20.0)))

        results = sparql_query(g, """
            PREFIX dc: <http://purl.org/dc/elements/1.1/>
            PREFIX ns: <http://example.org/ns#>
            PREFIX : <http://example.org/book/>
            SELECT ?book ?title ?price WHERE {
                VALUES (?book ?title) { (:book1 UNDEF) (:book2 UNDEF) }
                ?book dc:title ?title .
                ?book ns:price ?price .
            }
        """)
        @test length(results) == 2
    end

    # ─── Section 11: Aggregates ────────────────────────────────────

    @testset "§11.1 Aggregate Example — SUM with GROUP BY and HAVING" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("order1"), ex("item"), ex("widget")))
        add!(g, Triple(ex("order1"), ex("amount"), Literal(5)))
        add!(g, Triple(ex("order2"), ex("item"), ex("widget")))
        add!(g, Triple(ex("order2"), ex("amount"), Literal(10)))
        add!(g, Triple(ex("order3"), ex("item"), ex("gadget")))
        add!(g, Triple(ex("order3"), ex("amount"), Literal(3)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?item (SUM(?amount) AS ?total) WHERE {
                ?order ex:item ?item .
                ?order ex:amount ?amount .
            }
            GROUP BY ?item
            HAVING (?total > 4)
        """)
        # widget: 5+10=15 > 4 ✓, gadget: 3 > 4 ✗
        @test length(results) == 1
        @test results[1]["item"] == ex("widget")
        @test _numval(results[1]["total"]) == 15.0
    end

    @testset "§11.5 Aggregate Example — AVG" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal(1)))
        add!(g, Triple(ex("b"), ex("val"), Literal(2)))
        add!(g, Triple(ex("c"), ex("val"), Literal(3)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (AVG(?val) AS ?avg) WHERE {
                ?s ex:val ?val .
            }
        """)
        @test length(results) == 1
        @test _numval(results[1]["avg"]) == 2.0
    end

    # ─── Section 12: Subqueries ────────────────────────────────────

    @testset "§12.1 Subquery — inner MIN with GROUP BY" begin
        g = RDFGraph()
        foaf = Namespace("http://xmlns.com/foaf/0.1/")
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("alice"), foaf("knows"), ex("bob")))
        add!(g, Triple(ex("alice"), foaf("knows"), ex("carol")))
        add!(g, Triple(ex("bob"), foaf("name"), Literal("Bob")))
        add!(g, Triple(ex("carol"), foaf("name"), Literal("Carol")))

        results = sparql_query(g, """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            PREFIX ex: <http://example.org/>
            SELECT ?y ?minName WHERE {
                ex:alice foaf:knows ?y .
                {
                    SELECT ?y (MIN(?name) AS ?minName) WHERE {
                        ?y foaf:name ?name .
                    } GROUP BY ?y
                }
            }
        """)
        @test length(results) == 2
        names = Set(r["minName"].lexical for r in results)
        @test "Bob" in names
        @test "Carol" in names
    end

    # ─── Section 15: Solution Modifiers ────────────────────────────

    @testset "§15.1 ORDER BY" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal(3)))
        add!(g, Triple(ex("b"), ex("val"), Literal(1)))
        add!(g, Triple(ex("c"), ex("val"), Literal(2)))

        # Ascending
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?val WHERE {
                ?s ex:val ?val .
            } ORDER BY ?val
        """)
        vals = [_numval(r["val"]) for r in results]
        @test issorted(vals)

        # Descending
        results2 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s ?val WHERE {
                ?s ex:val ?val .
            } ORDER BY DESC(?val)
        """)
        vals2 = [_numval(r["val"]) for r in results2]
        @test issorted(vals2, rev=true)
    end

    @testset "§15.3 DISTINCT" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("type"), ex("Thing")))
        add!(g, Triple(ex("b"), ex("type"), ex("Thing")))
        add!(g, Triple(ex("c"), ex("type"), ex("Other")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT DISTINCT ?type WHERE {
                ?s ex:type ?type .
            }
        """)
        types = [r["type"] for r in results]
        @test length(types) == length(unique(types))
        @test length(types) == 2
    end

    @testset "§15.4/15.5 OFFSET and LIMIT" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        for i in 1:5
            add!(g, Triple(ex("item$i"), ex("val"), Literal(i)))
        end

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?val WHERE {
                ?s ex:val ?val .
            } ORDER BY ?val LIMIT 2 OFFSET 1
        """)
        @test length(results) == 2
        # With ORDER BY ?val ascending, items are 1,2,3,4,5; offset 1 skip first → 2,3
        @test _numval(results[1]["val"]) == 2.0
        @test _numval(results[2]["val"]) == 3.0
    end

    # ─── Section 16: Query Forms ───────────────────────────────────

    @testset "§16.1.2 SELECT Expressions" begin
        g = RDFGraph()
        ns = Namespace("http://example.org/ns#")
        add!(g, Triple(URIRef("http://example.org/item1"), ns("price"), Literal(40.0)))
        add!(g, Triple(URIRef("http://example.org/item1"), ns("discount"), Literal(0.1)))

        # Expression in SELECT: ?p*(1-?discount) AS ?price
        results = sparql_query(g, """
            PREFIX ns: <http://example.org/ns#>
            SELECT ?item (?p*(1-?discount) AS ?salePrice) WHERE {
                ?item ns:price ?p .
                ?item ns:discount ?discount .
            }
        """)
        @test length(results) == 1
        @test haskey(results[1], "salePrice")
        @test _numval(results[1]["salePrice"]) ≈ 36.0
    end

    @testset "§16.2 CONSTRUCT — foaf to vcard conversion" begin
        g = RDFGraph()
        foaf = Namespace("http://xmlns.com/foaf/0.1/")
        vcard = Namespace("http://www.w3.org/2001/vcard-rdf/3.0#")
        add!(g, Triple(URIRef("http://example.org/alice"), foaf("name"), Literal("Alice")))
        add!(g, Triple(URIRef("http://example.org/bob"), foaf("name"), Literal("Bob")))

        result = sparql_query(g, """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            PREFIX vcard: <http://www.w3.org/2001/vcard-rdf/3.0#>
            CONSTRUCT { ?x vcard:FN ?name }
            WHERE { ?x foaf:name ?name }
        """)
        @test result isa RDFGraph
        @test length(result) == 2
        ts = collect(triples(result))
        @test all(t -> t.predicate == URIRef("http://www.w3.org/2001/vcard-rdf/3.0#FN"), ts)
    end

    @testset "§16.2.4 CONSTRUCT WHERE shorthand" begin
        g = RDFGraph()
        foaf = Namespace("http://xmlns.com/foaf/0.1/")
        add!(g, Triple(URIRef("http://example.org/alice"), foaf("name"), Literal("Alice")))

        result = sparql_query(g, """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            CONSTRUCT WHERE {
                <http://example.org/alice> foaf:name ?name .
            }
        """)
        @test result isa RDFGraph
        @test length(result) == 1
    end

    @testset "§16.3 ASK — true and false" begin
        g = RDFGraph()
        foaf = Namespace("http://xmlns.com/foaf/0.1/")
        add!(g, Triple(URIRef("http://example.org/alice"), foaf("name"), Literal("Alice")))

        result_true = sparql_query(g, """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            ASK { <http://example.org/alice> foaf:name ?name }
        """)
        @test result_true === true

        result_false = sparql_query(g, """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            ASK { <http://example.org/alice> foaf:age ?age }
        """)
        @test result_false === false
    end

    # ─── Section 17: Functions ─────────────────────────────────────

    @testset "§17.4.1.1 BOUND" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("date"), Literal("2024-01-01")))
        add!(g, Triple(ex("b"), ex("name"), Literal("Bob")))

        # BOUND(?date) — only :a has a date
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s ?p ?o .
                OPTIONAL { ?s ex:date ?date }
                FILTER(BOUND(?date))
            }
        """)
        subjects = Set(r["s"] for r in results)
        @test ex("a") in subjects

        # !BOUND(?date)
        results2 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s ?p ?o .
                OPTIONAL { ?s ex:date ?date }
                FILTER(!BOUND(?date))
            }
        """)
        subjects2 = Set(r["s"] for r in results2)
        @test ex("b") in subjects2
    end

    @testset "§17.4.1.2 IF" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal(2)))
        add!(g, Triple(ex("b"), ex("val"), Literal(5)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s (IF(?v = 2, "yes", "no") AS ?result) WHERE {
                ?s ex:val ?v .
            }
        """)
        @test length(results) == 2
        result_map = Dict(r["s"] => r["result"].lexical for r in results)
        @test result_map[ex("a")] == "yes"
        @test result_map[ex("b")] == "no"
    end

    @testset "§17.4.2.1 sameTerm" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal(2)))

        # sameTerm — check via FILTER
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?v WHERE {
                ex:a ex:val ?v .
                FILTER(sameTerm(?v, ?v))
            }
        """)
        @test length(results) == 1
    end

    @testset "§17.4.2.3 isIRI" begin
        g = RDFGraph()
        foaf = Namespace("http://xmlns.com/foaf/0.1/")
        add!(g, Triple(URIRef("http://example.org/a"), foaf("mbox"), URIRef("mailto:alice@example.org")))
        add!(g, Triple(URIRef("http://example.org/b"), foaf("mbox"), Literal("bob@example.org")))

        results = sparql_query(g, """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            SELECT ?x WHERE {
                ?x foaf:mbox ?mbox .
                FILTER isIRI(?mbox)
            }
        """)
        @test length(results) == 1
        @test results[1]["x"] == URIRef("http://example.org/a")
    end

    @testset "§17.4.2.5 isLiteral" begin
        g = RDFGraph()
        foaf = Namespace("http://xmlns.com/foaf/0.1/")
        add!(g, Triple(URIRef("http://example.org/a"), foaf("mbox"), URIRef("mailto:alice@example.org")))
        add!(g, Triple(URIRef("http://example.org/b"), foaf("mbox"), Literal("bob@example.org")))

        results = sparql_query(g, """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            SELECT ?x WHERE {
                ?x foaf:mbox ?mbox .
                FILTER isLiteral(?mbox)
            }
        """)
        @test length(results) == 1
        @test results[1]["x"] == URIRef("http://example.org/b")
    end

    @testset "§17.4.2.7 STR — regex on str(?mbox)" begin
        g = RDFGraph()
        foaf = Namespace("http://xmlns.com/foaf/0.1/")
        add!(g, Triple(URIRef("http://example.org/a"), foaf("mbox"), URIRef("mailto:alice@work.example")))
        add!(g, Triple(URIRef("http://example.org/b"), foaf("mbox"), URIRef("mailto:bob@home.example")))

        results = sparql_query(g, raw"""
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            SELECT ?x WHERE {
                ?x foaf:mbox ?mbox .
                FILTER regex(STR(?mbox), "@work\.example$")
            }
        """)
        @test length(results) == 1
        @test results[1]["x"] == URIRef("http://example.org/a")
    end

    @testset "§17.4.2.8 LANG" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("name"), Literal("Alice", lang="en")))
        add!(g, Triple(ex("a"), ex("name"), Literal("Alicia", lang="es")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?name WHERE {
                ex:a ex:name ?name .
                FILTER(LANG(?name) = "es")
            }
        """)
        @test length(results) == 1
        @test results[1]["name"].lexical == "Alicia"
    end

    @testset "§17.4.2.12 DATATYPE" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        xsd = Namespace("http://www.w3.org/2001/XMLSchema#")
        add!(g, Triple(ex("a"), ex("shoeSize"), Literal("42", datatype=xsd("integer"))))
        add!(g, Triple(ex("b"), ex("shoeSize"), Literal("large")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            SELECT ?x ?size WHERE {
                ?x ex:shoeSize ?size .
                FILTER(DATATYPE(?size) = xsd:integer)
            }
        """)
        @test length(results) == 1
        @test results[1]["x"] == ex("a")
    end

    @testset "§17.4.3.1 STRLEN" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal("chat")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (STRLEN(?v) AS ?len) WHERE {
                ex:a ex:val ?v .
            }
        """)
        @test length(results) == 1
        @test _numval(results[1]["len"]) == 4.0
    end

    @testset "§17.4.3.2 SUBSTR" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal("foobar")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (SUBSTR(?v, 4) AS ?sub) WHERE {
                ex:a ex:val ?v .
            }
        """)
        @test length(results) == 1
        @test results[1]["sub"].lexical == "bar"
    end

    @testset "§17.4.3.3/4 UCASE/LCASE" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal("foo")))

        r1 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (UCASE(?v) AS ?upper) WHERE { ex:a ex:val ?v }
        """)
        @test r1[1]["upper"].lexical == "FOO"

        r2 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (LCASE(?v) AS ?lower) WHERE { ex:a ex:val ?v }
        """)
        @test r2[1]["lower"].lexical == "foo"
    end

    @testset "§17.4.3.5/6 STRSTARTS/STRENDS" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal("foobar")))

        r1 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (STRSTARTS(?v, "foo") AS ?starts) WHERE { ex:a ex:val ?v }
        """)
        @test r1[1]["starts"].lexical == "true"

        r2 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (STRENDS(?v, "bar") AS ?ends) WHERE { ex:a ex:val ?v }
        """)
        @test r2[1]["ends"].lexical == "true"
    end

    @testset "§17.4.3.7 CONTAINS" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal("foobar")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (CONTAINS(?v, "bar") AS ?has) WHERE { ex:a ex:val ?v }
        """)
        @test results[1]["has"].lexical == "true"
    end

    @testset "§17.4.3.8/9 STRBEFORE/STRAFTER" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal("abc")))

        r1 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (STRBEFORE(?v, "b") AS ?before) WHERE { ex:a ex:val ?v }
        """)
        @test r1[1]["before"].lexical == "a"

        r2 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (STRAFTER(?v, "b") AS ?after) WHERE { ex:a ex:val ?v }
        """)
        @test r2[1]["after"].lexical == "c"
    end

    @testset "§17.4.4.5 RAND" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("p"), ex("b")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (RAND() AS ?r) WHERE { ex:a ex:p ex:b }
        """)
        @test length(results) == 1
        val = _numval(results[1]["r"])
        @test !isnothing(val)
        @test 0.0 <= val < 1.0
    end

    @testset "§17.4.5 Date/Time Functions" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        xsd = Namespace("http://www.w3.org/2001/XMLSchema#")
        add!(g, Triple(ex("a"), ex("born"), Literal("2004-12-31T19:01:02", datatype=xsd("dateTime"))))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (YEAR(?d) AS ?y) (MONTH(?d) AS ?m) (DAY(?d) AS ?day)
                   (HOURS(?d) AS ?h) (MINUTES(?d) AS ?min) (SECONDS(?d) AS ?sec)
            WHERE {
                ex:a ex:born ?d .
            }
        """)
        @test length(results) == 1
        r = results[1]
        @test _numval(r["y"]) == 2004.0
        @test _numval(r["m"]) == 12.0
        @test _numval(r["day"]) == 31.0
        @test _numval(r["h"]) == 19.0
        @test _numval(r["min"]) == 1.0
        @test _numval(r["sec"]) == 2.0
    end

    @testset "§17.4.7 Hash Functions" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal("abc")))

        # SHA1
        r1 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (SHA1(?v) AS ?hash) WHERE { ex:a ex:val ?v }
        """)
        @test length(r1[1]["hash"].lexical) == 40

        # SHA256
        r2 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (SHA256(?v) AS ?hash) WHERE { ex:a ex:val ?v }
        """)
        @test length(r2[1]["hash"].lexical) == 64

        # SHA384
        r3 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (SHA384(?v) AS ?hash) WHERE { ex:a ex:val ?v }
        """)
        @test length(r3[1]["hash"].lexical) == 96

        # SHA512
        r4 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (SHA512(?v) AS ?hash) WHERE { ex:a ex:val ?v }
        """)
        @test length(r4[1]["hash"].lexical) == 128
    end

    # ─── Section 4.3: VERSION Announcement ────────────────────────

    @testset "§4.3 VERSION declaration" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("name"), Literal("Alice")))

        results = sparql_query(g, """
            VERSION '1.2'
            PREFIX ex: <http://example.org/>
            SELECT ?name WHERE {
                ex:a ex:name ?name
            }
        """)
        @test length(results) == 1
        @test results[1]["name"].lexical == "Alice"
    end

    # ─── Additional spec examples ──────────────────────────────────

    @testset "§9.2 Property path with aggregation SUM" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        # item -> price via path item/price
        add!(g, Triple(ex("order1"), ex("item"), ex("widget")))
        add!(g, Triple(ex("widget"), ex("price"), Literal(10.0)))
        add!(g, Triple(ex("order2"), ex("item"), ex("widget")))
        add!(g, Triple(ex("order3"), ex("item"), ex("gadget")))
        add!(g, Triple(ex("gadget"), ex("price"), Literal(5.0)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (SUM(?price) AS ?total) WHERE {
                ?order ex:item/ex:price ?price .
            }
        """)
        @test length(results) == 1
        # 10.0 (widget via order1) + 10.0 (widget via order2) + 5.0 (gadget via order3) = 25.0
        @test _numval(results[1]["total"]) == 25.0
    end

    @testset "§16.1.2 Chained SELECT expressions" begin
        g = RDFGraph()
        ns = Namespace("http://example.org/ns#")
        add!(g, Triple(URIRef("http://example.org/item1"), ns("price"), Literal(100.0)))
        add!(g, Triple(URIRef("http://example.org/item1"), ns("discount"), Literal(0.2)))

        results = sparql_query(g, """
            PREFIX ns: <http://example.org/ns#>
            SELECT ?item (?p AS ?fullPrice) (?p*(1-?discount) AS ?customerPrice) WHERE {
                ?item ns:price ?p .
                ?item ns:discount ?discount .
            }
        """)
        @test length(results) == 1
        @test haskey(results[1], "fullPrice")
        @test haskey(results[1], "customerPrice")
        @test _numval(results[1]["fullPrice"]) == 100.0
        @test _numval(results[1]["customerPrice"]) ≈ 80.0
    end

    @testset "§15.1 ORDER BY — multiple keys" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("name"), Literal("Alice")))
        add!(g, Triple(ex("a"), ex("score"), Literal(90)))
        add!(g, Triple(ex("b"), ex("name"), Literal("Bob")))
        add!(g, Triple(ex("b"), ex("score"), Literal(90)))
        add!(g, Triple(ex("c"), ex("name"), Literal("Carol")))
        add!(g, Triple(ex("c"), ex("score"), Literal(85)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?name ?score WHERE {
                ?s ex:name ?name .
                ?s ex:score ?score .
            }
            ORDER BY DESC(?score) ?name
        """)
        @test length(results) == 3
        # Highest score first, then alphabetical name
        @test results[1]["name"].lexical == "Alice" || results[1]["name"].lexical == "Bob"
        @test results[3]["name"].lexical == "Carol"
    end

    @testset "§11 COUNT aggregate" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("type"), ex("Person")))
        add!(g, Triple(ex("b"), ex("type"), ex("Person")))
        add!(g, Triple(ex("c"), ex("type"), ex("Animal")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?type (COUNT(?s) AS ?count) WHERE {
                ?s ex:type ?type .
            } GROUP BY ?type
        """)
        @test length(results) == 2
        for r in results
            if r["type"] == ex("Person")
                @test _numval(r["count"]) == 2.0
            elseif r["type"] == ex("Animal")
                @test _numval(r["count"]) == 1.0
            end
        end
    end

    @testset "§11 MAX/MIN aggregate" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal(10)))
        add!(g, Triple(ex("b"), ex("val"), Literal(20)))
        add!(g, Triple(ex("c"), ex("val"), Literal(30)))

        r1 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (MAX(?v) AS ?maxVal) WHERE { ?s ex:val ?v }
        """)
        @test _numval(r1[1]["maxVal"]) == 30.0

        r2 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (MIN(?v) AS ?minVal) WHERE { ?s ex:val ?v }
        """)
        @test _numval(r2[1]["minVal"]) == 10.0
    end

    @testset "§17.4.3.10 CONCAT" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("first"), Literal("Hello")))
        add!(g, Triple(ex("a"), ex("last"), Literal("World")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (CONCAT(?f, " ", ?l) AS ?full) WHERE {
                ex:a ex:first ?f .
                ex:a ex:last ?l .
            }
        """)
        @test length(results) == 1
        @test results[1]["full"].lexical == "Hello World"
    end

    @testset "§17.4.3.12 REGEX in FILTER" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal("hello123")))
        add!(g, Triple(ex("b"), ex("val"), Literal("world")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?v WHERE {
                ?s ex:val ?v .
                FILTER regex(?v, "[0-9]+")
            }
        """)
        @test length(results) == 1
        @test results[1]["v"].lexical == "hello123"
    end

    @testset "§17.4.4.1-4 Numeric functions: ABS, ROUND, CEIL, FLOOR" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal(-2.5)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (ABS(?v) AS ?a) (ROUND(?v) AS ?r) (CEIL(?v) AS ?c) (FLOOR(?v) AS ?f) WHERE {
                ex:a ex:val ?v .
            }
        """)
        @test length(results) == 1
        r = results[1]
        @test _numval(r["a"]) == 2.5
        @test _numval(r["c"]) == -2.0
        @test _numval(r["f"]) == -3.0
    end

    @testset "§17.4.1.3 COALESCE" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("name"), Literal("Alice")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (COALESCE(?missing, ?name) AS ?val) WHERE {
                ex:a ex:name ?name .
            }
        """)
        @test length(results) == 1
        @test results[1]["val"].lexical == "Alice"
    end

    @testset "§17.4.5.1 NOW" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("p"), ex("b")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (NOW() AS ?t) WHERE { ex:a ex:p ex:b }
        """)
        @test length(results) == 1
        @test results[1]["t"] isa Literal
    end

    @testset "§17.4.2.18/19 UUID / STRUUID" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("p"), ex("b")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (UUID() AS ?u) (STRUUID() AS ?su) WHERE { ex:a ex:p ex:b }
        """)
        @test length(results) == 1
        @test results[1]["u"] isa URIRef
        @test results[1]["su"] isa Literal
        @test startswith(results[1]["u"].value, "urn:uuid:")
    end

    @testset "§17.4.3.13 REPLACE" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal("hello world")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (REPLACE(?v, "world", "SPARQL") AS ?new) WHERE { ex:a ex:val ?v }
        """)
        @test results[1]["new"].lexical == "hello SPARQL"
    end

    @testset "§17.4.1.5/6 Logical OR/AND in FILTER" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal(1)))
        add!(g, Triple(ex("b"), ex("val"), Literal(5)))
        add!(g, Triple(ex("c"), ex("val"), Literal(10)))

        # AND
        r1 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?v WHERE {
                ?s ex:val ?v .
                FILTER (?v >= 2 && ?v <= 8)
            }
        """)
        @test length(r1) == 1
        @test _numval(r1[1]["v"]) == 5.0

        # OR
        r2 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?v WHERE {
                ?s ex:val ?v .
                FILTER (?v = 1 || ?v = 10)
            }
        """)
        @test length(r2) == 2
    end

    @testset "§17.4.1.8/9 IN / NOT IN" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("type"), ex("Dog")))
        add!(g, Triple(ex("b"), ex("type"), ex("Cat")))
        add!(g, Triple(ex("c"), ex("type"), ex("Fish")))

        results = sparql_query(g, """
            SELECT ?s WHERE {
                ?s <http://example.org/type> ?t .
                FILTER (?t IN (<http://example.org/Dog>, <http://example.org/Cat>))
            }
        """)
        @test length(results) == 2

        results2 = sparql_query(g, """
            SELECT ?s WHERE {
                ?s <http://example.org/type> ?t .
                FILTER (?t NOT IN (<http://example.org/Dog>, <http://example.org/Cat>))
            }
        """)
        @test length(results2) == 1
        @test results2[1]["s"] == ex("c")
    end

    @testset "§17.4.2.4 isBLANK" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(BNode("x"), ex("name"), Literal("Anon")))
        add!(g, Triple(ex("a"), ex("name"), Literal("Named")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s ex:name ?name .
                FILTER isBlank(?s)
            }
        """)
        @test length(results) == 1
        @test results[1]["s"] isa BNode
    end

    @testset "§17.4.2.6 isNUMERIC" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal(42)))
        add!(g, Triple(ex("b"), ex("val"), Literal("hello")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s ex:val ?v .
                FILTER isNUMERIC(?v)
            }
        """)
        @test length(results) == 1
        @test results[1]["s"] == ex("a")
    end

    @testset "§17.4.3.11 langMATCHES" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("label"), Literal("English", lang="en")))
        add!(g, Triple(ex("b"), ex("label"), Literal("French", lang="fr")))
        add!(g, Triple(ex("c"), ex("label"), Literal("Plain")))

        # Match "*" — any language tag
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s ex:label ?l .
                FILTER(LANGMATCHES(LANG(?l), "*"))
            }
        """)
        @test length(results) == 2  # a and b have lang tags, c does not

        # Match specific
        results2 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s ex:label ?l .
                FILTER(LANGMATCHES(LANG(?l), "en"))
            }
        """)
        @test length(results2) == 1
        @test results2[1]["s"] == ex("a")
    end

    @testset "§10.1 BIND with FILTER" begin
        g = RDFGraph()
        ns = Namespace("http://example.org/ns#")
        add!(g, Triple(URIRef("http://example.org/item1"), ns("price"), Literal(100.0)))
        add!(g, Triple(URIRef("http://example.org/item1"), ns("discount"), Literal(0.2)))
        add!(g, Triple(URIRef("http://example.org/item2"), ns("price"), Literal(50.0)))
        add!(g, Triple(URIRef("http://example.org/item2"), ns("discount"), Literal(0.1)))

        results = sparql_query(g, """
            PREFIX ns: <http://example.org/ns#>
            SELECT ?item ?salePrice WHERE {
                ?item ns:price ?p .
                ?item ns:discount ?discount .
                BIND(?p*(1-?discount) AS ?salePrice)
                FILTER(?salePrice < 50)
            }
        """)
        @test length(results) == 1
        @test _numval(results[1]["salePrice"]) ≈ 45.0
    end

    @testset "§11 GROUP_CONCAT aggregate" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("tag"), Literal("red")))
        add!(g, Triple(ex("a"), ex("tag"), Literal("blue")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s (GROUP_CONCAT(?tag) AS ?tags) WHERE {
                ?s ex:tag ?tag .
            } GROUP BY ?s
        """)
        @test length(results) == 1
        tag_str = results[1]["tags"].lexical
        @test occursin("red", tag_str)
        @test occursin("blue", tag_str)
    end

    @testset "§11 SAMPLE aggregate" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal(1)))
        add!(g, Triple(ex("b"), ex("val"), Literal(2)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (SAMPLE(?v) AS ?sample) WHERE {
                ?s ex:val ?v .
            }
        """)
        @test length(results) == 1
        val = _numval(results[1]["sample"])
        @test val == 1.0 || val == 2.0
    end

    @testset "§17.4.2.13 IRI function" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("ref"), Literal("http://example.org/target")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (IRI(?v) AS ?uri) WHERE {
                ex:a ex:ref ?v .
            }
        """)
        @test length(results) == 1
        @test results[1]["uri"] isa URIRef
        @test results[1]["uri"] == URIRef("http://example.org/target")
    end

    @testset "§17.4.2.14 BNODE function" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("p"), ex("b")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (BNODE() AS ?bn) WHERE { ex:a ex:p ex:b }
        """)
        @test length(results) == 1
        @test results[1]["bn"] isa BNode
    end

    @testset "§17.4.2.15 STRDT" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal("42")))

        results = sparql_query(g, """
            SELECT (STRDT(?v, <http://www.w3.org/2001/XMLSchema#integer>) AS ?typed) WHERE {
                <http://example.org/a> <http://example.org/val> ?v .
            }
        """)
        @test length(results) == 1
        @test results[1]["typed"] isa Literal
        @test results[1]["typed"].datatype == URIRef("http://www.w3.org/2001/XMLSchema#integer")
    end

    @testset "§17.4.2.16 STRLANG" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal("hello")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (STRLANG(?v, "en") AS ?tagged) WHERE {
                ex:a ex:val ?v .
            }
        """)
        @test length(results) == 1
        @test results[1]["tagged"] isa Literal
        @test results[1]["tagged"].language == "en"
        @test results[1]["tagged"].lexical == "hello"
    end

    @testset "§17.4.3.14 ENCODE_FOR_URI" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal("hello world")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (ENCODE_FOR_URI(?v) AS ?encoded) WHERE {
                ex:a ex:val ?v .
            }
        """)
        @test length(results) == 1
        @test occursin("hello", results[1]["encoded"].lexical)
        # Space should be encoded
        @test !occursin(" ", results[1]["encoded"].lexical)
    end

    @testset "§2.5 CONCAT in SELECT expression" begin
        g = RDFGraph()
        foaf = Namespace("http://xmlns.com/foaf/0.1/")
        add!(g, Triple(BNode("a"), foaf("givenName"), Literal("John")))
        add!(g, Triple(BNode("a"), foaf("surname"), Literal("Doe")))

        results = sparql_query(g, """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            SELECT (CONCAT(?g, " ", ?s) AS ?fullName) WHERE {
                ?p foaf:givenName ?g .
                ?p foaf:surname ?s .
            }
        """)
        @test length(results) == 1
        @test results[1]["fullName"].lexical == "John Doe"
    end

    @testset "§11 COUNT DISTINCT aggregate" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("color"), Literal("red")))
        add!(g, Triple(ex("b"), ex("color"), Literal("red")))
        add!(g, Triple(ex("c"), ex("color"), Literal("blue")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (COUNT(DISTINCT ?color) AS ?numColors) WHERE {
                ?s ex:color ?color .
            }
        """)
        @test length(results) == 1
        @test _numval(results[1]["numColors"]) == 2.0
    end

    @testset "§8.3.3 NOT EXISTS vs MINUS — inner FILTER" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("p"), Literal(1)))

        # NOT EXISTS with inner FILTER
        r1 = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE {
                ?s ex:p ?v .
                FILTER NOT EXISTS { ?s ex:p ?v2 . FILTER(?v2 > 0) }
            }
        """)
        # ex:a has p=1, and 1>0 is true, so NOT EXISTS removes it
        @test isempty(r1)
    end

    @testset "§17.4.2.7 STR function in BIND" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("p"), ex("b")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (STR(?s) AS ?str_s) WHERE {
                ?s ex:p ex:b .
            }
        """)
        @test length(results) == 1
        @test results[1]["str_s"].lexical == "http://example.org/a"
    end

    @testset "§17.4.2.8 LANG function in BIND" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("name"), Literal("Alice", lang="en")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (LANG(?name) AS ?langTag) WHERE {
                ex:a ex:name ?name .
            }
        """)
        @test length(results) == 1
        @test results[1]["langTag"].lexical == "en"
    end

    @testset "§17.4.2.12 DATATYPE function in BIND" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("val"), Literal(42)))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT (DATATYPE(?v) AS ?dt) WHERE {
                ex:a ex:val ?v .
            }
        """)
        @test length(results) == 1
        @test results[1]["dt"] == URIRef("http://www.w3.org/2001/XMLSchema#integer")
    end

    @testset "§15 LIMIT only" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        for i in 1:10
            add!(g, Triple(ex("item$i"), ex("val"), Literal(i)))
        end

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE { ?s ex:val ?v } LIMIT 3
        """)
        @test length(results) == 3
    end

    @testset "§15 OFFSET only" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        for i in 1:5
            add!(g, Triple(ex("item$i"), ex("val"), Literal(i)))
        end

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?v WHERE { ?s ex:val ?v } ORDER BY ?v OFFSET 3
        """)
        @test length(results) == 2
        @test _numval(results[1]["v"]) == 4.0
        @test _numval(results[2]["v"]) == 5.0
    end

    @testset "§16.2 CONSTRUCT with multiple patterns" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("alice"), ex("name"), Literal("Alice")))
        add!(g, Triple(ex("alice"), ex("age"), Literal(30)))

        result = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            CONSTRUCT {
                ?s foaf:name ?name .
                ?s foaf:age ?age .
            } WHERE {
                ?s ex:name ?name .
                ?s ex:age ?age .
            }
        """)
        @test result isa RDFGraph
        @test length(result) == 2
    end

    @testset "§5.1 Empty result set" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("a"), ex("p"), ex("b")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE { ?s ex:nonexistent ?o }
        """)
        @test isempty(results)
    end

    @testset "§4.2.4 rdf:type shorthand 'a'" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("alice"), RDF.type, ex("Person")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?s WHERE { ?s a ex:Person }
        """)
        @test length(results) == 1
        @test results[1]["s"] == ex("alice")
    end

    @testset "§4.2.1 Predicate-Object Lists (;)" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("alice"), ex("name"), Literal("Alice")))
        add!(g, Triple(ex("alice"), ex("age"), Literal(30)))

        # Use expanded form (repeated subject)
        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?name ?age WHERE {
                ex:alice ex:name ?name .
                ex:alice ex:age ?age .
            }
        """)
        @test length(results) == 1
        @test results[1]["name"].lexical == "Alice"
    end

    @testset "§4.2.2 Object Lists (,)" begin
        g = RDFGraph()
        ex = Namespace("http://example.org/")
        add!(g, Triple(ex("alice"), ex("likes"), ex("bob")))
        add!(g, Triple(ex("alice"), ex("likes"), ex("carol")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?who WHERE {
                ex:alice ex:likes ?who .
            }
        """)
        @test length(results) == 2
    end

end
