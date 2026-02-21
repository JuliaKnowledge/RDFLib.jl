using Test, RDFLib

@testset "Extra Namespaces" begin
    @testset "FOAF" begin
        @test FOAF.Person isa URIRef
        @test FOAF.Person.value == "http://xmlns.com/foaf/0.1/Person"
        @test FOAF.knows.value == "http://xmlns.com/foaf/0.1/knows"
        @test FOAF.name.value == "http://xmlns.com/foaf/0.1/name"
    end

    @testset "DC" begin
        @test DC.title isa URIRef
        @test DC.title.value == "http://purl.org/dc/elements/1.1/title"
        @test DC.creator.value == "http://purl.org/dc/elements/1.1/creator"
    end

    @testset "DCTERMS" begin
        @test DCTERMS.created isa URIRef
        @test DCTERMS.created.value == "http://purl.org/dc/terms/created"
        @test DCTERMS.license.value == "http://purl.org/dc/terms/license"
    end

    @testset "DCAT" begin
        @test DCAT.Dataset isa URIRef
        @test DCAT.Dataset.value == "http://www.w3.org/ns/dcat#Dataset"
    end

    @testset "PROV" begin
        @test PROV.Entity isa URIRef
        @test PROV.Entity.value == "http://www.w3.org/ns/prov#Entity"
        @test PROV.wasGeneratedBy.value == "http://www.w3.org/ns/prov#wasGeneratedBy"
    end

    @testset "SDO" begin
        @test SDO.Person isa URIRef
        @test SDO.Person.value == "https://schema.org/Person"
        @test SDO.name.value == "https://schema.org/name"
    end

    @testset "SH" begin
        @test SH.NodeShape isa URIRef
        @test SH.NodeShape.value == "http://www.w3.org/ns/shacl#NodeShape"
    end

    @testset "VANN" begin
        @test VANN.preferredNamespacePrefix isa URIRef
    end

    @testset "VOID" begin
        @test VOID.Dataset isa URIRef
        @test VOID.Dataset.value == "http://rdfs.org/ns/void#Dataset"
    end

    @testset "DOAP" begin
        @test DOAP.Project isa URIRef
        @test DOAP.Project.value == "http://usefulinc.com/ns/doap#Project"
    end

    @testset "ORG" begin
        @test ORG.Organization isa URIRef
    end

    @testset "GEO" begin
        @test GEO.Feature isa URIRef
        @test GEO.Feature.value == "http://www.opengis.net/ont/geosparql#Feature"
    end
end
