using Test
using RDFLib

include(joinpath(@__DIR__, "..", "src", "trix.jl"))

const EX_TRIX = "http://example.org/"

@testset "TriX Format" begin

    @testset "Serialize single graph" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_TRIX * "s"), URIRef(EX_TRIX * "p"), Literal("hello")))
        xml = serialize_trix(g)
        @test occursin("<TriX", xml)
        @test occursin("<uri>$(EX_TRIX)s</uri>", xml)
        @test occursin("<uri>$(EX_TRIX)p</uri>", xml)
        @test occursin("<plainLiteral>hello</plainLiteral>", xml)
    end

    @testset "Serialize URIRef object" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_TRIX * "s"), URIRef(EX_TRIX * "p"), URIRef(EX_TRIX * "o")))
        xml = serialize_trix(g)
        @test count("<uri>", xml) >= 3
    end

    @testset "Serialize blank node" begin
        g = RDFGraph()
        add!(g, Triple(BNode("b1"), URIRef(EX_TRIX * "p"), Literal("val")))
        xml = serialize_trix(g)
        @test occursin("<id>b1</id>", xml)
    end

    @testset "Serialize typed literal" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_TRIX * "s"), URIRef(EX_TRIX * "p"), Literal(42)))
        xml = serialize_trix(g)
        @test occursin("typedLiteral", xml)
        @test occursin("integer", xml)
        @test occursin(">42<", xml)
    end

    @testset "Serialize language-tagged literal" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_TRIX * "s"), URIRef(EX_TRIX * "p"), Literal("bonjour", lang="fr")))
        xml = serialize_trix(g)
        @test occursin("xml:lang=\"fr\"", xml)
        @test occursin("plainLiteral", xml)
        @test occursin("bonjour", xml)
    end

    @testset "Serialize dataset with named graphs" begin
        ds = Dataset()
        add!(ds, Triple(URIRef(EX_TRIX * "s1"), URIRef(EX_TRIX * "p1"), Literal("default")))
        add!(ds, Triple(URIRef(EX_TRIX * "s2"), URIRef(EX_TRIX * "p2"), Literal("named")), URIRef(EX_TRIX * "g1"))
        xml = serialize_trix(ds)
        @test occursin("<graph>", xml)
        @test count("<graph>", xml) == 2
        @test occursin("<uri>$(EX_TRIX)g1</uri>", xml)
    end

    @testset "Parse TriX basic" begin
        xml = """<?xml version="1.0"?>
        <TriX xmlns="http://www.w3.org/2004/03/trix/trix-1/">
          <graph>
            <triple>
              <uri>http://example.org/s</uri>
              <uri>http://example.org/p</uri>
              <plainLiteral>hello</plainLiteral>
            </triple>
          </graph>
        </TriX>"""
        ds = parse_trix(xml)
        default_g = get_graph(ds)
        @test length(default_g) == 1
        ts = collect(default_g)
        @test ts[1].subject == URIRef("http://example.org/s")
        @test ts[1].object == Literal("hello")
    end

    @testset "Parse TriX named graph" begin
        xml = """<?xml version="1.0"?>
        <TriX xmlns="http://www.w3.org/2004/03/trix/trix-1/">
          <graph>
            <uri>http://example.org/g1</uri>
            <triple>
              <uri>http://example.org/s</uri>
              <uri>http://example.org/p</uri>
              <uri>http://example.org/o</uri>
            </triple>
          </graph>
        </TriX>"""
        ds = parse_trix(xml)
        named_g = get_graph(ds, URIRef("http://example.org/g1"))
        @test !isnothing(named_g)
        @test length(named_g) == 1
    end

    @testset "Parse TriX blank node" begin
        xml = """<TriX xmlns="http://www.w3.org/2004/03/trix/trix-1/">
          <graph>
            <triple>
              <id>b1</id>
              <uri>http://example.org/p</uri>
              <id>b2</id>
            </triple>
          </graph>
        </TriX>"""
        ds = parse_trix(xml)
        ts = collect(get_graph(ds))
        @test ts[1].subject == BNode("b1")
        @test ts[1].object == BNode("b2")
    end

    @testset "Parse TriX typed literal" begin
        xml = """<TriX xmlns="http://www.w3.org/2004/03/trix/trix-1/">
          <graph>
            <triple>
              <uri>http://example.org/s</uri>
              <uri>http://example.org/p</uri>
              <typedLiteral datatype="http://www.w3.org/2001/XMLSchema#integer">42</typedLiteral>
            </triple>
          </graph>
        </TriX>"""
        ds = parse_trix(xml)
        ts = collect(get_graph(ds))
        @test ts[1].object == Literal("42", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))
    end

    @testset "Parse TriX language-tagged literal" begin
        xml = """<TriX xmlns="http://www.w3.org/2004/03/trix/trix-1/">
          <graph>
            <triple>
              <uri>http://example.org/s</uri>
              <uri>http://example.org/p</uri>
              <plainLiteral xml:lang="en">hello</plainLiteral>
            </triple>
          </graph>
        </TriX>"""
        ds = parse_trix(xml)
        ts = collect(get_graph(ds))
        @test ts[1].object == Literal("hello", lang="en")
    end

    @testset "Parse TriX multiple graphs" begin
        xml = """<TriX xmlns="http://www.w3.org/2004/03/trix/trix-1/">
          <graph>
            <triple>
              <uri>http://example.org/s1</uri>
              <uri>http://example.org/p1</uri>
              <plainLiteral>default</plainLiteral>
            </triple>
          </graph>
          <graph>
            <uri>http://example.org/g1</uri>
            <triple>
              <uri>http://example.org/s2</uri>
              <uri>http://example.org/p2</uri>
              <plainLiteral>named</plainLiteral>
            </triple>
          </graph>
        </TriX>"""
        ds = parse_trix(xml)
        @test length(get_graph(ds)) == 1
        @test length(get_graph(ds, URIRef("http://example.org/g1"))) == 1
    end

    @testset "parse_trix! into existing graph" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_TRIX * "existing"), URIRef(EX_TRIX * "p"), Literal("old")))
        xml = """<TriX xmlns="http://www.w3.org/2004/03/trix/trix-1/">
          <graph>
            <triple>
              <uri>http://example.org/new</uri>
              <uri>http://example.org/p</uri>
              <plainLiteral>new</plainLiteral>
            </triple>
          </graph>
        </TriX>"""
        parse_trix!(g, xml)
        @test length(g) == 2
    end

    @testset "Round-trip single graph" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_TRIX * "s"), URIRef(EX_TRIX * "p"), Literal("val")))
        add!(g, Triple(URIRef(EX_TRIX * "s"), URIRef(EX_TRIX * "p2"), Literal(42)))
        add!(g, Triple(URIRef(EX_TRIX * "s"), URIRef(EX_TRIX * "p3"), Literal("hola", lang="es")))
        xml = serialize_trix(g)
        ds2 = parse_trix(xml)
        @test length(get_graph(ds2)) == 3
    end

    @testset "Round-trip dataset" begin
        ds = Dataset()
        add!(ds, Triple(URIRef(EX_TRIX * "s"), URIRef(EX_TRIX * "p"), Literal("default")))
        add!(ds, Triple(URIRef(EX_TRIX * "s2"), URIRef(EX_TRIX * "p2"), URIRef(EX_TRIX * "o2")), URIRef(EX_TRIX * "g1"))
        xml = serialize_trix(ds)
        ds2 = parse_trix(xml)
        @test length(get_graph(ds2)) == 1
        @test length(get_graph(ds2, URIRef(EX_TRIX * "g1"))) == 1
    end

    @testset "XML special characters escaped" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_TRIX * "s"), URIRef(EX_TRIX * "p"), Literal("a < b & c > d")))
        xml = serialize_trix(g)
        @test occursin("a &lt; b &amp; c &gt; d", xml)
        ds = parse_trix(xml)
        ts = collect(get_graph(ds))
        @test ts[1].object == Literal("a < b & c > d")
    end

    @testset "Empty graph" begin
        g = RDFGraph()
        xml = serialize_trix(g)
        @test occursin("<TriX", xml)
        @test occursin("<graph>", xml)
    end

    @testset "Boolean literal round-trip" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_TRIX * "s"), URIRef(EX_TRIX * "p"), Literal(true)))
        xml = serialize_trix(g)
        ds = parse_trix(xml)
        ts = collect(get_graph(ds))
        @test ts[1].object == Literal(true)
    end
end
