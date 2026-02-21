using Test
using RDFLib

@testset "Namespaces" begin
    @testset "Namespace basics" begin
        ex = Namespace("http://example.org/")
        @test ex("Person") == URIRef("http://example.org/Person")
        @test ex(:name) == URIRef("http://example.org/name")
        @test URIRef("http://example.org/foo") in ex
        @test !(URIRef("http://other.org/foo") in ex)
    end

    @testset "Property-style access" begin
        ex = Namespace("http://example.org/")
        @test ex.Person == URIRef("http://example.org/Person")
    end

    @testset "DefinedNamespace - RDF" begin
        @test RDF.type == URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
        @test RDF.Property == URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#Property")
        @test RDF.first == URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
    end

    @testset "DefinedNamespace - RDFS" begin
        @test RDFS.label == URIRef("http://www.w3.org/2000/01/rdf-schema#label")
        @test RDFS.subClassOf == URIRef("http://www.w3.org/2000/01/rdf-schema#subClassOf")
    end

    @testset "DefinedNamespace - XSD" begin
        @test XSD.integer == URIRef("http://www.w3.org/2001/XMLSchema#integer")
        @test XSD.string == URIRef("http://www.w3.org/2001/XMLSchema#string")
        @test XSD.boolean == URIRef("http://www.w3.org/2001/XMLSchema#boolean")
    end

    @testset "DefinedNamespace - OWL" begin
        @test OWL.Class == URIRef("http://www.w3.org/2002/07/owl#Class")
        @test OWL.Thing == URIRef("http://www.w3.org/2002/07/owl#Thing")
    end

    @testset "DefinedNamespace warns on unknown term" begin
        @test_warn "not defined" RDF("notARealTerm")
    end

    @testset "NamespaceManager" begin
        nsm = NamespaceManager()

        # Default bindings
        @test expand_curie(nsm, "rdf:type") == RDF.type
        @test expand_curie(nsm, "xsd:integer") == XSD.integer

        # Custom binding
        bind!(nsm, "ex", Namespace("http://example.org/"))
        @test expand_curie(nsm, "ex:Person") == URIRef("http://example.org/Person")

        # compute_qname
        pfx, ns_uri, localname = compute_qname(nsm, URIRef("http://example.org/Person"))
        @test pfx == "ex"
        @test localname == "Person"

        # Auto-binding for unknown namespace
        pfx2, ns_uri2, localname2 = compute_qname(nsm, URIRef("http://unknown.org/foo"))
        @test startswith(pfx2, "ns")
        @test localname2 == "foo"
    end
end
