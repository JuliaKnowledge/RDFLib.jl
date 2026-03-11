using Test
using RDFLib
using RDFLib: namespaces

@testset "Base URI (publicID) support" begin
    nt_data = """<http://example.org/s> <http://example.org/p> "hello" .\n"""

    @testset "parse_rdf_with_base! sets base URI" begin
        g = RDFGraph()
        parse_rdf_with_base!(g, nt_data, NTriplesFormat(), "http://example.org/")
        ns = namespaces(g)
        @test haskey(ns, "")
        @test ns[""] == "http://example.org/"
        @test length(g) == 1
    end

    @testset "parse_rdf_with_base creates graph with base" begin
        g = parse_rdf_with_base(nt_data, NTriplesFormat(), "http://example.org/base/")
        ns = namespaces(g)
        @test haskey(ns, "")
        @test ns[""] == "http://example.org/base/"
        @test length(g) == 1
    end

    @testset "parse_rdf_with_base! adds to existing graph" begin
        g = RDFGraph()
        add!(g, Triple(URIRef("http://example.org/a"), URIRef("http://example.org/b"), Literal("existing")))
        parse_rdf_with_base!(g, nt_data, NTriplesFormat(), "http://example.org/")
        @test length(g) == 2
        ns = namespaces(g)
        @test ns[""] == "http://example.org/"
    end

    @testset "serialize(g, fmt, filename) alternative arg order" begin
        g = RDFGraph()
        add!(g, Triple(URIRef("http://example.org/s"), URIRef("http://example.org/p"), Literal("hello")))
        outfile = joinpath(mktempdir(), "test_base_uri_output.ttl")
        serialize(g, TurtleFormat(), outfile)
        @test isfile(outfile)
        content = read(outfile, String)
        # Turtle serializer may use prefixed names; check for the local name
        @test occursin("example.org", content)
        rm(outfile; force=true)
    end

    @testset "base_uri reflected in namespace manager" begin
        g = parse_rdf_with_base(nt_data, TurtleFormat(), "http://example.org/ns/")
        ns = namespaces(g)
        @test ns[""] == "http://example.org/ns/"
        qname = compute_qname(g.namespace_manager, URIRef("http://example.org/ns/foo"))
        @test qname[1] == ""
        @test qname[3] == "foo"
    end
end
