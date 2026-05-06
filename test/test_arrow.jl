using Test
using RDFLib

@testset "Arrow IPC serialization" begin
    @testset "round-trip basic terms" begin
        g = RDFGraph()
        add!(g, Triple(URIRef("http://ex/s1"), URIRef("http://ex/p"), URIRef("http://ex/o")))
        add!(g, Triple(URIRef("http://ex/s1"), URIRef("http://ex/q"), Literal("plain")))
        add!(g, Triple(URIRef("http://ex/s1"), URIRef("http://ex/r"),
                        Literal("3", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))))
        add!(g, Triple(URIRef("http://ex/s1"), URIRef("http://ex/t"),
                        Literal("hi", lang="en")))
        add!(g, Triple(BNode("b1"), URIRef("http://ex/p"), URIRef("http://ex/o")))

        data = serialize_arrow(g)
        @test length(data) > 16
        g2 = parse_arrow(data)
        @test length(g2) == length(g)
        for tr in g
            @test tr in g2
        end
    end

    @testset "EncodedStore bulk-load fast path" begin
        g = RDFGraph(store=EncodedStore())
        for i in 1:50
            add!(g, Triple(URIRef("http://ex/s$i"), URIRef("http://ex/p"),
                            Literal(string(i), datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))))
        end
        data = serialize_arrow(g)
        g2 = RDFGraph(store=EncodedStore())
        parse_arrow!(g2, data)
        @test length(g2) == length(g)
        for tr in g
            @test tr in g2
        end
    end

    @testset "compression options" begin
        g = RDFGraph()
        for i in 1:20
            add!(g, Triple(URIRef("http://ex/s$i"), URIRef("http://ex/p"), Literal("v$i")))
        end
        for opt in (nothing, :lz4, :zstd)
            data = serialize_arrow(g; compress=opt)
            g2 = parse_arrow(data)
            @test length(g2) == length(g)
        end
    end

    @testset "format dispatch via parse_rdf!/serialize" begin
        g = RDFGraph()
        add!(g, Triple(URIRef("http://ex/s"), URIRef("http://ex/p"), Literal("x")))
        buf = IOBuffer()
        serialize(buf, g, ArrowFormat())
        seekstart(buf)
        g2 = RDFGraph()
        parse_rdf!(g2, buf, ArrowFormat())
        @test length(g2) == 1
    end

    @testset "file IO via extension detection" begin
        path = tempname() * ".arrow"
        try
            g = RDFGraph()
            add!(g, Triple(URIRef("http://ex/a"), URIRef("http://ex/p"), URIRef("http://ex/b")))
            open(path, "w") do io; serialize(io, g, ArrowFormat()); end
            @test filesize(path) > 0
            g2 = RDFGraph()
            parse_arrow!(g2, path)
            @test length(g2) == 1
        finally
            isfile(path) && rm(path)
        end
    end

    @testset "rejects malformed header" begin
        @test_throws ArgumentError parse_arrow(UInt8[1,2,3])
        @test_throws ArgumentError parse_arrow(zeros(UInt8, 32))
    end
end
