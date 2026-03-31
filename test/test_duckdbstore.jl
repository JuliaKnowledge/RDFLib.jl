Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
@testset "DuckDBStore" begin
    @testset "basic add and length" begin
        store = DuckDBStore()
        g = RDFLib.RDFGraph(store=store)
        EX = Namespace("http://example.org/")
        add!(g, Triple(EX("s"), EX("p"), Literal("hello")))
        @test length(g) == 1
    end

    @testset "add duplicate" begin
        store = DuckDBStore()
        g = RDFLib.RDFGraph(store=store)
        EX = Namespace("http://example.org/")
        t = Triple(EX("s"), EX("p"), Literal("hello"))
        add!(g, t)
        add!(g, t)
        @test length(g) == 1
    end

    @testset "triples - all" begin
        store = DuckDBStore()
        g = RDFLib.RDFGraph(store=store)
        EX = Namespace("http://example.org/")
        add!(g, Triple(EX("s1"), EX("p1"), Literal("a")))
        add!(g, Triple(EX("s2"), EX("p2"), Literal("b")))
        all_t = collect(g)
        @test length(all_t) == 2
    end

    @testset "triples - pattern matching" begin
        store = DuckDBStore()
        g = RDFLib.RDFGraph(store=store)
        EX = Namespace("http://example.org/")
        add!(g, Triple(EX("s"), EX("p1"), Literal("a")))
        add!(g, Triple(EX("s"), EX("p2"), Literal("b")))
        add!(g, Triple(EX("s2"), EX("p1"), Literal("c")))

        r1 = collect(triples(g, (EX("s"), EX("p1"), nothing)))
        @test length(r1) == 1
        @test r1[1].object == Literal("a")

        r2 = collect(triples(g, (EX("s"), nothing, nothing)))
        @test length(r2) == 2

        r3 = collect(triples(g, (nothing, EX("p1"), nothing)))
        @test length(r3) == 2
    end

    @testset "remove" begin
        store = DuckDBStore()
        g = RDFLib.RDFGraph(store=store)
        EX = Namespace("http://example.org/")
        add!(g, Triple(EX("s"), EX("p1"), Literal("a")))
        add!(g, Triple(EX("s"), EX("p2"), Literal("b")))
        remove!(g, (EX("s"), EX("p1"), nothing))
        @test length(g) == 1
    end

    @testset "literal with datatype" begin
        store = DuckDBStore()
        g = RDFLib.RDFGraph(store=store)
        EX = Namespace("http://example.org/")
        add!(g, Triple(EX("s"), EX("age"), Literal(42)))
        ts = collect(g)
        @test length(ts) == 1
        @test ts[1].object isa Literal
        @test ts[1].object.lexical == "42"
        @test ts[1].object.datatype == URIRef("http://www.w3.org/2001/XMLSchema#integer")
    end

    @testset "literal with language tag" begin
        store = DuckDBStore()
        g = RDFLib.RDFGraph(store=store)
        EX = Namespace("http://example.org/")
        add!(g, Triple(EX("s"), RDFS.label, Literal("Bonjour", lang="fr")))
        ts = collect(g)
        @test length(ts) == 1
        @test ts[1].object.language == "fr"
    end

    @testset "blank nodes" begin
        store = DuckDBStore()
        g = RDFLib.RDFGraph(store=store)
        EX = Namespace("http://example.org/")
        b = BNode("x1")
        add!(g, Triple(EX("s"), EX("p"), b))
        add!(g, Triple(b, EX("q"), Literal("val")))
        @test length(g) == 2
        r = collect(triples(g, (b, nothing, nothing)))
        @test length(r) == 1
    end

    @testset "URI objects" begin
        store = DuckDBStore()
        g = RDFLib.RDFGraph(store=store)
        EX = Namespace("http://example.org/")
        add!(g, Triple(EX("s"), EX("p"), EX("o")))
        ts = collect(g)
        @test ts[1].object == EX("o")
        @test ts[1].object isa URIRef
    end

    @testset "in operator" begin
        store = DuckDBStore()
        g = RDFLib.RDFGraph(store=store)
        EX = Namespace("http://example.org/")
        t = Triple(EX("s"), EX("p"), Literal("hello"))
        add!(g, t)
        @test t in g
    end

    @testset "iteration" begin
        store = DuckDBStore()
        g = RDFLib.RDFGraph(store=store)
        EX = Namespace("http://example.org/")
        add!(g, Triple(EX("a"), EX("p"), Literal("1")))
        add!(g, Triple(EX("b"), EX("p"), Literal("2")))
        count = 0
        for t in g
            count += 1
        end
        @test count == 2
    end

    @testset "serialization round-trip" begin
        store = DuckDBStore()
        g = RDFLib.RDFGraph(store=store)
        EX = Namespace("http://example.org/")
        bind!(g, "ex", EX)
        add!(g, Triple(EX("alice"), RDF.type, EX("Person")))
        add!(g, Triple(EX("alice"), RDFS.label, Literal("Alice", lang="en")))
        add!(g, Triple(EX("alice"), EX("age"), Literal(30)))

        ttl = serialize(g, TurtleFormat())
        g2 = parse_rdf(ttl, TurtleFormat())
        @test length(g2) == length(g)
    end

    @testset "file-backed persistence" begin
        db_path = tempname() * ".duckdb"
        try
            store1 = DuckDBStore(db_path)
            g1 = RDFLib.RDFGraph(store=store1)
            EX = Namespace("http://example.org/")
            add!(g1, Triple(EX("s"), EX("p"), Literal("persistent")))
            @test length(g1) == 1
            close(store1)

            store2 = DuckDBStore(db_path)
            g2 = RDFLib.RDFGraph(store=store2)
            @test length(g2) == 1
            ts = collect(g2)
            @test ts[1].object == Literal("persistent")
            close(store2)
        finally
            rm(db_path, force=true)
            rm(db_path * ".wal", force=true)
        end
    end

    @testset "transaction" begin
        store = DuckDBStore()
        g = RDFLib.RDFGraph(store=store)
        EX = Namespace("http://example.org/")
        transaction(store) do
            for i in 1:100
                add!(g, Triple(EX("s$i"), EX("p"), Literal("v$i")))
            end
        end
        @test length(g) == 100
    end

    @testset "SPARQL query" begin
        store = DuckDBStore()
        g = RDFLib.RDFGraph(store=store)
        EX = Namespace("http://example.org/")
        bind!(g, "ex", EX)
        add!(g, Triple(EX("alice"), RDF.type, EX("Person")))
        add!(g, Triple(EX("alice"), RDFS.label, Literal("Alice")))
        add!(g, Triple(EX("bob"), RDF.type, EX("Person")))
        add!(g, Triple(EX("bob"), RDFS.label, Literal("Bob")))

        results = sparql_query(g, """
            PREFIX ex: <http://example.org/>
            SELECT ?name WHERE { ?s a ex:Person . ?s <http://www.w3.org/2000/01/rdf-schema#label> ?name }
        """)
        names = sort([r["name"].lexical for r in results])
        @test names == ["Alice", "Bob"]
    end
end
end
