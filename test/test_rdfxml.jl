using Test
using RDFLib

@testset "RDF/XML" begin
    EX = Namespace("http://example.org/")

    @testset "serialization" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        add!(g, EX("alice"), RDFS.label, Literal("Alice"))
        xml = serialize(g, RDFXMLFormat())

        @test contains(xml, "rdf:RDF")
        @test contains(xml, "rdf:Description")
        @test contains(xml, "http://example.org/alice")
        @test contains(xml, "Alice")
    end

    @testset "serialization - URI object" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), EX("knows"), EX("bob"))
        xml = serialize(g, RDFXMLFormat())
        @test contains(xml, "rdf:resource")
        @test contains(xml, "http://example.org/bob")
    end

    @testset "serialization - language tag" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDFS.label, Literal("Alice", lang="en"))
        xml = serialize(g, RDFXMLFormat())
        @test contains(xml, "xml:lang")
        @test contains(xml, "en")
    end

    @testset "parsing - basic" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/alice">
                <rdf:type rdf:resource="http://example.org/Person"/>
                <ex:name>Alice</ex:name>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 2
    end

    @testset "parsing - URI objects" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/alice">
                <ex:knows rdf:resource="http://example.org/bob"/>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 1
        t = first(g)
        @test t.object == EX("bob")
    end

    @testset "parsing - typed node" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <ex:Person rdf:about="http://example.org/alice">
                <ex:name>Alice</ex:name>
            </ex:Person>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 2  # type triple + name triple
        # Check type triple exists
        type_objs = collect(objects(g, EX("alice"), RDF.type))
        @test EX("Person") in type_objs
    end

    @testset "parsing - datatype" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/"
                 xmlns:xsd="http://www.w3.org/2001/XMLSchema#">
            <rdf:Description rdf:about="http://example.org/alice">
                <ex:age rdf:datatype="http://www.w3.org/2001/XMLSchema#integer">30</ex:age>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        objs = collect(objects(g, EX("alice"), EX("age")))
        @test length(objs) == 1
        @test convert(Any, objs[1]) == 30
    end

    @testset "parsing - blank nodes" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/alice">
                <ex:address rdf:parseType="Resource">
                    <ex:city>London</ex:city>
                </ex:address>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 2  # alice→address→_:b, _:b→city→"London"
    end

    @testset "round-trip" begin
        g1 = RDFGraph()
        bind!(g1, "ex", EX)
        add!(g1, EX("alice"), RDF.type, EX("Person"))
        add!(g1, EX("alice"), RDFS.label, Literal("Alice"))
        add!(g1, EX("alice"), EX("knows"), EX("bob"))

        xml = serialize(g1, RDFXMLFormat())
        g2 = parse_rdf(xml, RDFXMLFormat())

        @test length(g2) == length(g1)
        for t in g1
            @test t in g2
        end
    end
end
