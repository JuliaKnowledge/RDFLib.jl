using Test
using RDFLib

include(joinpath(@__DIR__, "..", "src", "hextuples.jl"))

const EX_HT = "http://example.org/"

@testset "Hextuples Format" begin

    @testset "Serialize URI triple" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_HT * "s"), URIRef(EX_HT * "p"), URIRef(EX_HT * "o")))
        result = serialize_hextuples(g)
        parsed = JSON.parse(strip(result))
        @test parsed[1] == EX_HT * "s"
        @test parsed[2] == EX_HT * "p"
        @test parsed[3] == EX_HT * "o"
        @test parsed[4] == "globalId"
        @test parsed[5] == ""
        @test parsed[6] == ""
    end

    @testset "Serialize plain literal" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_HT * "s"), URIRef(EX_HT * "p"), Literal("hello")))
        result = serialize_hextuples(g)
        parsed = JSON.parse(strip(result))
        @test parsed[3] == "hello"
        @test parsed[4] == "http://www.w3.org/2001/XMLSchema#string"
        @test parsed[5] == ""
    end

    @testset "Serialize typed literal" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_HT * "s"), URIRef(EX_HT * "p"), Literal(42)))
        result = serialize_hextuples(g)
        parsed = JSON.parse(strip(result))
        @test parsed[3] == "42"
        @test parsed[4] == "http://www.w3.org/2001/XMLSchema#integer"
    end

    @testset "Serialize language-tagged literal" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_HT * "s"), URIRef(EX_HT * "p"), Literal("bonjour", lang="fr")))
        result = serialize_hextuples(g)
        parsed = JSON.parse(strip(result))
        @test parsed[3] == "bonjour"
        @test parsed[4] == "http://www.w3.org/1999/02/22-rdf-syntax-ns#langString"
        @test parsed[5] == "fr"
    end

    @testset "Serialize blank node subject" begin
        g = RDFGraph()
        add!(g, Triple(BNode("b1"), URIRef(EX_HT * "p"), Literal("val")))
        result = serialize_hextuples(g)
        parsed = JSON.parse(strip(result))
        @test parsed[1] == "_:b1"
    end

    @testset "Serialize blank node object" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_HT * "s"), URIRef(EX_HT * "p"), BNode("b2")))
        result = serialize_hextuples(g)
        parsed = JSON.parse(strip(result))
        @test parsed[3] == "_:b2"
        @test parsed[4] == "localId"
    end

    @testset "Serialize dataset with named graph" begin
        ds = Dataset()
        add!(ds, Triple(URIRef(EX_HT * "s"), URIRef(EX_HT * "p"), Literal("val")), URIRef(EX_HT * "g1"))
        result = serialize_hextuples(ds)
        parsed = JSON.parse(strip(result))
        @test parsed[6] == EX_HT * "g1"
    end

    @testset "Parse URI triple" begin
        line = """["http://example.org/s","http://example.org/p","http://example.org/o","globalId","",""]"""
        ds = parse_hextuples(line)
        ts = collect(get_graph(ds))
        @test length(ts) == 1
        @test ts[1].subject == URIRef("http://example.org/s")
        @test ts[1].object == URIRef("http://example.org/o")
    end

    @testset "Parse typed literal" begin
        line = """["http://example.org/s","http://example.org/p","42","http://www.w3.org/2001/XMLSchema#integer","",""]"""
        ds = parse_hextuples(line)
        ts = collect(get_graph(ds))
        @test ts[1].object == Literal("42", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))
    end

    @testset "Parse language-tagged literal" begin
        line = """["http://example.org/s","http://example.org/p","hello","http://www.w3.org/1999/02/22-rdf-syntax-ns#langString","en",""]"""
        ds = parse_hextuples(line)
        ts = collect(get_graph(ds))
        @test ts[1].object == Literal("hello", lang="en")
    end

    @testset "Parse blank node" begin
        line = """["_:b1","http://example.org/p","_:b2","localId","",""]"""
        ds = parse_hextuples(line)
        ts = collect(get_graph(ds))
        @test ts[1].subject == BNode("b1")
        @test ts[1].object == BNode("b2")
    end

    @testset "Parse named graph" begin
        line = """["http://example.org/s","http://example.org/p","http://example.org/o","globalId","","http://example.org/g1"]"""
        ds = parse_hextuples(line)
        named_g = get_graph(ds, URIRef("http://example.org/g1"))
        @test !isnothing(named_g)
        @test length(named_g) == 1
    end

    @testset "Parse multiple lines" begin
        lines = """["http://example.org/s1","http://example.org/p","http://example.org/o1","globalId","",""]
["http://example.org/s2","http://example.org/p","http://example.org/o2","globalId","",""]"""
        ds = parse_hextuples(lines)
        @test length(get_graph(ds)) == 2
    end

    @testset "parse_hextuples! into existing graph" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_HT * "old"), URIRef(EX_HT * "p"), Literal("old")))
        line = """["http://example.org/new","http://example.org/p","new","http://www.w3.org/2001/XMLSchema#string","",""]"""
        parse_hextuples!(g, line)
        @test length(g) == 2
    end

    @testset "Round-trip graph" begin
        g = RDFGraph()
        add!(g, Triple(URIRef(EX_HT * "s"), URIRef(EX_HT * "p"), Literal("hello")))
        add!(g, Triple(URIRef(EX_HT * "s"), URIRef(EX_HT * "p2"), URIRef(EX_HT * "o")))
        add!(g, Triple(URIRef(EX_HT * "s"), URIRef(EX_HT * "p3"), Literal("hola", lang="es")))
        result = serialize_hextuples(g)
        ds = parse_hextuples(result)
        @test length(get_graph(ds)) == 3
    end

    @testset "Round-trip dataset" begin
        ds = Dataset()
        add!(ds, Triple(URIRef(EX_HT * "s1"), URIRef(EX_HT * "p"), Literal("default")))
        add!(ds, Triple(URIRef(EX_HT * "s2"), URIRef(EX_HT * "p"), Literal("named")), URIRef(EX_HT * "g1"))
        result = serialize_hextuples(ds)
        ds2 = parse_hextuples(result)
        @test length(get_graph(ds2)) == 1
        @test length(get_graph(ds2, URIRef(EX_HT * "g1"))) == 1
    end

    @testset "Empty lines ignored" begin
        lines = """["http://example.org/s","http://example.org/p","val","http://www.w3.org/2001/XMLSchema#string","",""]

"""
        ds = parse_hextuples(lines)
        @test length(get_graph(ds)) == 1
    end
end
