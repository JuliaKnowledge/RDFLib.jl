using Test
using RDFLib

@testset "JSON-LD" begin
    EX = Namespace("http://example.org/")

    @testset "serialization" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        add!(g, EX("alice"), RDFS.label, Literal("Alice"))
        jsonld = serialize(g, JSONLDFormat())

        @test contains(jsonld, "@context") || contains(jsonld, "@id")
        @test contains(jsonld, "http://example.org/alice")
        @test contains(jsonld, "Alice")
    end

    @testset "serialization - types" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        jsonld = serialize(g, JSONLDFormat())
        @test contains(jsonld, "@type")
    end

    @testset "serialization - numeric" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), EX("age"), Literal(30))
        jsonld = serialize(g, JSONLDFormat())
        @test contains(jsonld, "30")
    end

    @testset "parsing" begin
        jsonld = """{
            "@context": {
                "ex": "http://example.org/"
            },
            "@id": "http://example.org/alice",
            "@type": "ex:Person",
            "ex:name": "Alice"
        }"""
        g = parse_rdf(jsonld, JSONLDFormat())
        @test length(g) == 2  # type + name

        type_objs = collect(objects(g, EX("alice"), RDF.type))
        @test EX("Person") in type_objs
    end

    @testset "parsing - @graph" begin
        jsonld = """{
            "@context": {
                "ex": "http://example.org/"
            },
            "@graph": [
                {
                    "@id": "http://example.org/alice",
                    "ex:name": "Alice"
                },
                {
                    "@id": "http://example.org/bob",
                    "ex:name": "Bob"
                }
            ]
        }"""
        g = parse_rdf(jsonld, JSONLDFormat())
        @test length(g) == 2
    end

    @testset "parsing - language tag" begin
        jsonld = """{
            "@id": "http://example.org/alice",
            "http://www.w3.org/2000/01/rdf-schema#label": {
                "@value": "Alice",
                "@language": "en"
            }
        }"""
        g = parse_rdf(jsonld, JSONLDFormat())
        objs = collect(objects(g, EX("alice"), RDFS.label))
        @test length(objs) == 1
        @test lang(objs[1]) == "en"
    end

    @testset "parsing - datatype" begin
        jsonld = """{
            "@id": "http://example.org/alice",
            "http://example.org/age": {
                "@value": "30",
                "@type": "http://www.w3.org/2001/XMLSchema#integer"
            }
        }"""
        g = parse_rdf(jsonld, JSONLDFormat())
        objs = collect(objects(g, EX("alice"), EX("age")))
        @test length(objs) == 1
        @test toPython(objs[1]) == 30
    end

    @testset "parsing - native types" begin
        jsonld = """{
            "@context": { "ex": "http://example.org/" },
            "@id": "http://example.org/s",
            "ex:count": 42,
            "ex:ratio": 3.14,
            "ex:active": true
        }"""
        g = parse_rdf(jsonld, JSONLDFormat())
        @test length(g) == 3
    end

    @testset "round-trip" begin
        g1 = RDFGraph()
        bind!(g1, "ex", EX)
        add!(g1, EX("alice"), RDF.type, EX("Person"))
        add!(g1, EX("alice"), RDFS.label, Literal("Alice"))

        jsonld = serialize(g1, JSONLDFormat())
        g2 = parse_rdf(jsonld, JSONLDFormat())

        @test length(g2) == length(g1)
        for t in g1
            @test t in g2
        end
    end
end
