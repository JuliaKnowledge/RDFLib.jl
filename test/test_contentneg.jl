using Test, RDFLib

@testset "Content Negotiation" begin
    @testset "mime_type" begin
        @test mime_type(TurtleFormat()) == "text/turtle"
        @test mime_type(NTriplesFormat()) == "application/n-triples"
        @test mime_type(JSONLDFormat()) == "application/ld+json"
        @test mime_type(RDFXMLFormat()) == "application/rdf+xml"
        @test mime_type(NQuadsFormat()) == "application/n-quads"
        @test mime_type(TriGFormat()) == "application/trig"
    end

    @testset "format_from_mime" begin
        @test format_from_mime("text/turtle") isa TurtleFormat
        @test format_from_mime("application/n-triples") isa NTriplesFormat
        @test format_from_mime("application/ld+json") isa JSONLDFormat
        @test format_from_mime("application/rdf+xml") isa RDFXMLFormat
        @test format_from_mime("text/turtle; charset=utf-8") isa TurtleFormat
        @test format_from_mime("application/x-turtle") isa TurtleFormat
        @test format_from_mime("application/xml") isa RDFXMLFormat
        @test format_from_mime("text/xml") isa RDFXMLFormat
        @test format_from_mime("application/trig") isa TriGFormat
        @test format_from_mime("application/json") isa JSONLDFormat
        @test format_from_mime("text/n3") isa TurtleFormat
        @test format_from_mime("text/plain") isa NTriplesFormat
    end

    @testset "format_from_mime - unknown" begin
        @test_throws ArgumentError format_from_mime("text/html")
    end

    @testset "accept_header" begin
        hdr = accept_header()
        @test occursin("text/turtle", hdr)
        @test occursin("application/ld+json", hdr)
        @test occursin("application/rdf+xml", hdr)
        @test occursin("application/n-triples", hdr)
        @test occursin("application/n-quads", hdr)
        @test occursin("application/trig", hdr)
    end

    @testset "accept_header - preferred" begin
        hdr = accept_header(preferred=JSONLDFormat())
        @test occursin("application/ld+json;q=1.0", hdr)
    end

    @testset "save and load file - turtle" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        bind!(g, "ex", EX)
        add!(g, Triple(EX("s"), EX("p"), Literal("hello")))

        tmpfile = tempname() * ".ttl"
        try
            result = save_rdf(g, tmpfile)
            @test result == tmpfile
            @test isfile(tmpfile)
            g2 = load_rdf_file(tmpfile)
            @test length(g2) == 1
        finally
            rm(tmpfile, force=true)
        end
    end

    @testset "save and load - ntriples" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        add!(g, Triple(EX("s"), EX("p"), EX("o")))

        tmpfile = tempname() * ".nt"
        try
            save_rdf(g, tmpfile)
            g2 = load_rdf_file(tmpfile)
            @test length(g2) == 1
        finally
            rm(tmpfile, force=true)
        end
    end

    @testset "save and load - explicit format" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        add!(g, Triple(EX("s"), EX("p"), Literal("v")))

        tmpfile = tempname() * ".dat"
        try
            save_rdf(g, tmpfile, format=NTriplesFormat())
            g2 = load_rdf_file(tmpfile, format=NTriplesFormat())
            @test length(g2) == 1
        finally
            rm(tmpfile, force=true)
        end
    end

    @testset "URL format detection" begin
        @test RDFLib._detect_format_from_url("http://example.org/data.ttl") isa TurtleFormat
        @test RDFLib._detect_format_from_url("http://example.org/data.jsonld") isa JSONLDFormat
        @test RDFLib._detect_format_from_url("http://example.org/data.rdf") isa RDFXMLFormat
        @test RDFLib._detect_format_from_url("http://example.org/data.nt") isa NTriplesFormat
        @test RDFLib._detect_format_from_url("http://example.org/data.nq") isa NQuadsFormat
        @test RDFLib._detect_format_from_url("http://example.org/data.trig") isa TriGFormat
        @test RDFLib._detect_format_from_url("http://example.org/data.ttl?version=2") isa TurtleFormat
        @test RDFLib._detect_format_from_url("http://example.org/data.ttl#frag") isa TurtleFormat
        @test RDFLib._detect_format_from_url("http://example.org/data") isa TurtleFormat  # default fallback
    end
end
