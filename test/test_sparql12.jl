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

    # ─── SPARQL 1.2: triple terms, reification, lang-direction, VERSION ───
    @testset "Triple terms and reification (1.2)" begin
        REIFIES = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#reifies")
        ex = Namespace("http://example/")
        g = RDFGraph()
        # `<<:a :b :c>> :q :z .` reifies with an anonymous reifier.
        add!(g, Triple(BNode("r"), REIFIES, TripleTerm(ex("a"), ex("b"), ex("c"))))
        add!(g, Triple(BNode("r"), ex("q"), ex("z")))

        # Match the triple-term object via rdf:reifies.
        r = sparql_query(g, """
            PREFIX : <http://example/>
            SELECT * { ?r <http://www.w3.org/1999/02/22-rdf-syntax-ns#reifies> <<( :a :b :c )>> }
        """)
        @test length(r) == 1

        # Reified-triple subject `<< :a :b :c >>` desugars to its reifier.
        r = sparql_query(g, """
            PREFIX : <http://example/>
            SELECT ?z { << :a :b :c >> :q ?z }
        """)
        @test length(r) == 1
        @test r[1]["z"] == ex("z")

        # Triple term bound by BIND; introspection builtins.
        g2 = RDFGraph()
        add!(g2, Triple(ex("s"), ex("p"), ex("o")))
        r = sparql_query(g2, """
            PREFIX : <http://example/>
            SELECT ?t ?subj { ?s ?p ?o . BIND(<<(?s ?p ?o)>> AS ?t) BIND(SUBJECT(?t) AS ?subj) }
        """)
        @test length(r) == 1
        @test r[1]["t"] isa TripleTerm
        @test r[1]["subj"] == ex("s")
        @test sparql_query(g2, "SELECT (isTRIPLE(<<(<http://example/s> <http://example/p> <http://example/o>)>>) AS ?b) {}")[1]["b"] == Literal(true)
        # TRIPLE() with a literal subject is unbound.
        @test !haskey(sparql_query(g2, raw"""SELECT (TRIPLE("x", <http://example/p>, <http://example/o>) AS ?t) {}""")[1], "t")
    end

    @testset "Language base direction (1.2)" begin
        g = RDFGraph()
        # STRLANGDIR builds rdf:dirLangString; LANGDIR / hasLANG(DIR) inspect it.
        r = sparql_query(g, raw"""
            SELECT (STRLANGDIR("abc", "en", "ltr") AS ?dl)
                   (LANGDIR(STRLANGDIR("abc", "en", "rtl")) AS ?dir)
                   (hasLANGDIR(STRLANGDIR("abc", "en", "ltr")) AS ?hd)
                   (hasLANG("abc"@en) AS ?hl) WHERE {}
        """)
        @test r[1]["dl"].language == "en"
        @test r[1]["dir"].lexical == "rtl"
        @test r[1]["hd"] == Literal(true)
        @test r[1]["hl"] == Literal(true)
        # Direction is case-sensitive: "LTR" → unbound.
        @test !haskey(sparql_query(g, raw"""SELECT (STRLANGDIR("a","en","LTR") AS ?x) {}""")[1], "x")
        # Literal syntax `"x"@en--ltr` parses lang + direction.
        r2 = sparql_query(g, raw"""SELECT (LANGDIR(?v) AS ?d) WHERE { VALUES ?v { "x"@en--ltr } }""")
        @test r2[1]["d"].lexical == "ltr"
    end

    @testset "VERSION declaration (1.2)" begin
        @test RDFLib.sparql_parse(raw"""VERSION "1.2" SELECT * { ?s ?p ?o }""") isa Any
        @test RDFLib.sparql_parse(raw"""PREFIX : <http://e/> VERSION '1.2' SELECT * { ?s ?p ?o }""") isa Any
        @test_throws Exception RDFLib.sparql_parse(raw"""VERSION 1.2 SELECT * { ?s ?p ?o }""")
        @test_throws Exception RDFLib.sparql_parse("VERSION \"\"\"1.2\"\"\" SELECT * { ?s ?p ?o }")
    end

    @testset "Negative syntax / scoping (1.1/1.2)" begin
        # Triple term in subject position is illegal in VALUES.
        @test_throws Exception RDFLib.sparql_parse(raw"""SELECT * { VALUES ?x { <<( <<(<http://e/s> <http://e/p> <http://e/o>)>> <http://e/q> <http://e/z> )>> } }""")
        # Nested aggregates / duplicate VALUES vars / GROUP BY scope.
        @test_throws Exception RDFLib.sparql_parse("SELECT (COUNT(SUM(?x)) AS ?c) {}")
        @test_throws Exception RDFLib.sparql_parse("SELECT * { VALUES (?a ?a) { (1 1) } }")
        @test_throws Exception RDFLib.sparql_parse(raw"""SELECT (123 AS ?z) WHERE { } GROUP BY ?z""")
        @test_throws Exception RDFLib.sparql_parse("SELECT * { ?s ?p ?o } GROUP BY ?s")
        # BIND target must be fresh.
        @test_throws Exception RDFLib.sparql_parse("SELECT * { ?s ?p ?o . BIND(1 AS ?o) }")
        # Cross-BGP blank-node label reuse.
        @test_throws Exception RDFLib.sparql_parse("SELECT * { _:a ?p ?v . OPTIONAL { _:a ?q 1 } }")
        @test_throws Exception RDFLib.sparql_parse("SELECT * { { _:a ?p ?v } UNION { _:a ?q 1 } }")
    end

    @testset "Variable scoping in nested groups (1.0)" begin
        ex = Namespace("http://example/")
        g = RDFGraph()
        add!(g, Triple(ex("x"), ex("p"), Literal(1)))
        add!(g, Triple(ex("x"), ex("p"), Literal(2)))
        # FILTER in a nested group cannot see ?v bound outside the group.
        r = sparql_query(g, "PREFIX : <http://example/> SELECT ?v { :x :p ?v . { FILTER(?v = 1) } }")
        @test isempty(r)
    end

    @testset "TriG bnode label inside reified triple is document-scoped" begin
        # `_:b` used both as a plain blank node and inside a `<< ... >>` reified
        # triple in the SAME TriG document denotes the SAME blank node, even
        # across named-graph boundaries. (Regression: the explicit-label scanner
        # mistook `<<` for an IRI and skipped the label inside it.)
        ds = Dataset()
        RDFLib.parse_trig!(ds, """
        PREFIX : <http://example/>
        GRAPH :g1 { _:b :r :o3 . }
        GRAPH :g2 { << _:b :r :o3 >> :pb "abc" . }
        """; base="file:///x")
        plain = nothing
        for (n, gg) in graphs(ds), t in triples(gg)
            n == URIRef("http://example/g1") && (plain = t.subject)
        end
        inner = nothing
        for (n, gg) in graphs(ds), t in triples(gg)
            if n == URIRef("http://example/g2") && t.object isa RDFLib.TripleTerm
                inner = t.object.subject
            end
        end
        @test plain isa BNode && inner isa BNode
        @test plain == inner   # same document-scoped blank node

        # The W3C eval-triple-terms "GRAPHs with blank node" query joins a plain
        # triple in one graph with its reified form in another — must succeed.
        rows = sparql_query(ds, """
        PREFIX : <http://example/>
        SELECT * { GRAPH ?g1 { ?s ?p ?o } GRAPH ?g2 { << ?s ?p ?o >> ?q ?z } }
        """)
        @test length(rows) == 2
    end

    @testset "xsd:string cast canonicalizes numeric/boolean values" begin
        g = RDFGraph()
        ex = Namespace("http://example/")
        xsd = "http://www.w3.org/2001/XMLSchema#"
        add!(g, Triple(ex("a"), ex("p"), Literal("1.0", datatype=URIRef(xsd * "decimal"))))
        add!(g, Triple(ex("b"), ex("p"), Literal("1E0", datatype=URIRef(xsd * "double"))))
        add!(g, Triple(ex("c"), ex("p"), Literal("0E1", datatype=URIRef(xsd * "double"))))
        add!(g, Triple(ex("d"), ex("p"), Literal("2.5", datatype=URIRef(xsd * "decimal"))))
        add!(g, Triple(ex("e"), ex("p"), Literal("0", datatype=URIRef(xsd * "boolean"))))
        out = Dict{String,String}()
        for r in sparql_query(g, """
            PREFIX : <http://example/>
            PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            SELECT ?a (xsd:string(?v) AS ?s) WHERE { ?a :p ?v }
        """)
            out[string(r["a"].value[end])] = (r["s"]::Literal).lexical
        end
        @test out["a"] == "1"      # decimal 1.0 → "1"
        @test out["b"] == "1"      # double  1E0 → "1"
        @test out["c"] == "0"      # double  0E1 → "0"
        @test out["d"] == "2.5"    # decimal 2.5 → "2.5"
        @test out["e"] == "false"  # boolean "0" → "false"
    end

    @testset "Aggregate over a computed expression argument" begin
        # AVG/SUM over an expression (not a bare variable) must evaluate the
        # expression per row, not silently treat the group as empty.
        g = RDFGraph()
        RDFLib.parse_turtle!(g, """
        @prefix : <http://example.com/data/#> .
        :x :p 1, "2", 3, 4 .
        """)
        rows = sparql_query(g, """
        PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
        PREFIX : <http://example.com/data/#>
        SELECT ?g (AVG(IF(isNumeric(?p), ?p, COALESCE(xsd:double(?p),0))) AS ?avg)
        WHERE { ?g :p ?p } GROUP BY ?g
        """)
        @test length(rows) == 1
        avg = rows[1]["avg"]::Literal
        @test parse(Float64, avg.lexical) ≈ 2.5
    end

    @testset "CONSTRUCT WHERE with annotation mints fresh reifiers" begin
        # `:a :b ?c {| ?q ?z |}` matched against data carrying a reifier produces
        # two solutions (the reifies triple and the annotation triple); the
        # CONSTRUCT WHERE template treats the reifier as a fresh template blank
        # node, yielding two distinct reifiers (reifies-only + reifies+annotation).
        g = RDFGraph()
        RDFLib.parse_turtle!(g, """
        PREFIX : <http://example/>
        :a :b :c {| :q :z |} .
        """; base="file:///x")
        res = sparql_query(g, """
        PREFIX : <http://example/>
        CONSTRUCT WHERE { :a :b ?c {| ?q ?z |} . }
        """)
        reifies = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#reifies")
        reifiers = Set{BNode}()
        nq = 0
        for t in triples(res)
            t.subject isa BNode && push!(reifiers, t.subject)
            t.predicate == URIRef("http://example/q") && (nq += 1)
        end
        @test length(collect(triples(res))) == 4
        @test length(reifiers) == 2   # two distinct reifiers
        @test nq == 1                 # exactly one annotation triple
    end
end
