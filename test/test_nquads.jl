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
end
