@testset "Chunked Serialization" begin
    EX = Namespace("http://example.org/")

    # Build a graph with 100 triples
    g = RDFGraph()
    for i in 1:100
        add!(g, Triple(EX("s$i"), EX("p"), Literal("value $i")))
    end

    @testset "serialize_chunked NTriples to IO" begin
        buf = IOBuffer()
        serialize_chunked(g, NTriplesFormat(), buf; chunk_size=25)
        nt_str = String(take!(buf))
        lines = filter(!isempty, split(nt_str, '\n'))
        @test length(lines) == 100
    end

    @testset "serialize_chunked NTriples round-trip" begin
        buf = IOBuffer()
        serialize_chunked(g, NTriplesFormat(), buf; chunk_size=30)
        nt_str = String(take!(buf))
        g2 = parse_rdf(nt_str, NTriplesFormat())
        @test length(g2) == 100
    end

    @testset "serialize_chunked to file" begin
        tmpfile = tempname() * ".nt"
        try
            serialize_chunked(g, NTriplesFormat(), tmpfile; chunk_size=50)
            @test isfile(tmpfile)
            g2 = parse_rdf(open(tmpfile), NTriplesFormat())
            @test length(g2) == 100
        finally
            isfile(tmpfile) && rm(tmpfile)
        end
    end

    @testset "serialize_chunked fallback for Turtle" begin
        buf = IOBuffer()
        serialize_chunked(g, TurtleFormat(), buf)
        ttl_str = String(take!(buf))
        @test !isempty(ttl_str)
    end

    @testset "parse_chunked NTriples" begin
        nt_str = serialize(g, NTriplesFormat())
        ch = parse_chunked(IOBuffer(nt_str), NTriplesFormat(); chunk_size=20)
        collected = collect(ch)
        @test length(collected) == 100
        @test all(t -> t isa Triple, collected)
    end
end
