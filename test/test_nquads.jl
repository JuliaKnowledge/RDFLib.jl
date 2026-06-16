using Test
using RDFLib

@testset "N-Quads" begin
    EX = Namespace("http://example.org/")

    @testset "serialization - default graph" begin
        ds = Dataset()
        add!(ds, EX("s"), EX("p"), Literal("hello"))
        nq = serialize(ds, NQuadsFormat())
        @test contains(nq, "<http://example.org/s>")
        @test contains(nq, "\"hello\"")
        # Default graph should NOT have a 4th component
        lines = filter(!isempty, split(strip(nq), '\n'))
        @test length(lines) == 1
        # Count the tokens (should be 3 + .)
        @test count('<', lines[1]) == 2  # subject + predicate, no graph URI
    end

    @testset "serialization - named graph" begin
        ds = Dataset()
        add!(ds, EX("s"), EX("p"), Literal("hello"), EX("g1"))
        nq = serialize(ds, NQuadsFormat())
        @test contains(nq, "<http://example.org/g1>")
    end

    @testset "serialization - mixed" begin
        ds = Dataset()
        add!(ds, EX("s"), EX("p"), Literal("default"))
        add!(ds, EX("s"), EX("p"), Literal("named"), EX("g1"))
        nq = serialize(ds, NQuadsFormat())
        lines = filter(!isempty, split(strip(nq), '\n'))
        @test length(lines) == 2
    end

    @testset "parsing - default graph" begin
        nq = """<http://example.org/s> <http://example.org/p> "hello" ."""
        ds = parse_nquads(nq)
        @test length(ds) == 1
        @test length(get_graph(ds)) == 1
    end

    @testset "parsing - named graph" begin
        nq = """<http://example.org/s> <http://example.org/p> "hello" <http://example.org/g1> ."""
        ds = parse_nquads(nq)
        @test length(ds) == 1
        @test length(get_graph(ds)) == 0  # not in default
        g1 = get_graph(ds, EX("g1"))
        @test !isnothing(g1)
        @test length(g1) == 1
    end

    @testset "parsing - mixed" begin
        nq = """
        <http://example.org/s> <http://example.org/p> "default" .
        <http://example.org/s> <http://example.org/p> "g1" <http://example.org/g1> .
        <http://example.org/s> <http://example.org/p> "g2" <http://example.org/g2> .
        """
        ds = parse_nquads(nq)
        @test length(ds) == 3
        @test length(collect(contexts(ds))) == 3
    end

    @testset "round-trip" begin
        ds1 = Dataset()
        add!(ds1, EX("alice"), RDF.type, EX("Person"))
        add!(ds1, EX("alice"), RDFS.label, Literal("Alice", lang="en"), EX("labels"))
        add!(ds1, EX("bob"), RDF.type, EX("Person"), EX("people"))

        nq = serialize(ds1, NQuadsFormat())
        ds2 = parse_nquads(nq)

        @test length(ds2) == length(ds1)

        # Check same quads exist
        qs1 = sort(collect(quads(ds1)), by=q -> string(q))
        qs2 = sort(collect(quads(ds2)), by=q -> string(q))
        @test length(qs1) == length(qs2)
    end

    @testset "blank node graph labels" begin
        nq = """<http://example.org/s> <http://example.org/p> <http://example.org/o> _:g ."""
        ds = parse_nquads(nq)
        @test length(ds) == 1
        @test length(get_graph(ds)) == 0          # not silently dropped to default
        g = get_graph(ds, BNode("g"))
        @test !isnothing(g)
        @test length(g) == 1
        @test first(g) == Triple(EX("s"), EX("p"), EX("o"))

        # round-trip: serialize and reparse keeps the bnode graph label
        nq2 = serialize(ds, NQuadsFormat())
        @test contains(nq2, "_:g .")
        ds2 = parse_nquads(nq2)
        @test length(get_graph(ds2, BNode("g"))) == 1

        # quads carry the BNode graph label
        q = first(quads(ds))
        @test q.graph == BNode("g")
    end

    @testset "invalid lines throw with line number" begin
        err = try
            parse_nquads("<http://example.org/s> <http://example.org/p> \"ok\" .\nnot a quad\n")
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test contains(err.msg, "line 2")
    end

    @testset "directional literals in N-Quads" begin
        nq = """<http://example.org/s> <http://example.org/p> "hello"@en--ltr <http://example.org/g1> ."""
        ds = parse_nquads(nq)
        obj = first(objects(get_graph(ds, EX("g1")), EX("s"), EX("p")))
        @test obj == Literal("hello", lang="en", direction="ltr")

        nq2 = serialize(ds, NQuadsFormat())
        @test contains(nq2, "\"hello\"@en--ltr")
        ds2 = parse_nquads(nq2)
        @test first(objects(get_graph(ds2, EX("g1")), EX("s"), EX("p"))) == obj
    end

    @testset "end-of-line comments" begin
        nq = """<http://example.org/s> <http://example.org/p> "x" <http://example.org/g1> . # comment"""
        ds = parse_nquads(nq)
        @test length(ds) == 1
    end

    @testset "relative IRIs rejected (no base in N-Quads)" begin
        # nq-syntax-bad-uri-01 and the inherited nt-syntax-bad-uri-06..09.
        @test_throws ArgumentError parse_nquads("<http://a/s> <http://a/p> <http://a/o> <g> .")
        @test_throws ArgumentError parse_nquads("<s> <http://a/p> <http://a/o> .")
        @test_throws ArgumentError parse_nquads("<http://a/s> <http://a/p> <http://a/o> <g>.")
        # Absolute IRIs (including the graph label) still parse.
        ds = parse_nquads("<http://a/s> <http://a/p> <http://a/o> <http://a/g> .")
        @test length(ds) == 1
    end
end
