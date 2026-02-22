using Test
using RDFLib

@testset "More Namespaces" begin
    @testset "BRICK" begin
        @test BRICK("Equipment") == URIRef("https://brickschema.org/schema/Brick#Equipment")
    end

    @testset "CSVW" begin
        @test CSVW("Table") == URIRef("http://www.w3.org/ns/csvw#Table")
    end

    @testset "DCAM" begin
        @test DCAM.domainIncludes == URIRef("http://purl.org/dc/dcam/domainIncludes")
        @test DCAM.rangeIncludes == URIRef("http://purl.org/dc/dcam/rangeIncludes")
        @test DCAM.memberOf == URIRef("http://purl.org/dc/dcam/memberOf")
        @test DCAM.VocabularyEncodingScheme == URIRef("http://purl.org/dc/dcam/VocabularyEncodingScheme")
    end

    @testset "DCMITYPE" begin
        @test DCMITYPE.Collection == URIRef("http://purl.org/dc/dcmitype/Collection")
        @test DCMITYPE.Dataset == URIRef("http://purl.org/dc/dcmitype/Dataset")
        @test DCMITYPE.Image == URIRef("http://purl.org/dc/dcmitype/Image")
        @test DCMITYPE.Text == URIRef("http://purl.org/dc/dcmitype/Text")
        @test DCMITYPE.Software == URIRef("http://purl.org/dc/dcmitype/Software")
    end

    @testset "ODRL2" begin
        @test ODRL2("Policy") == URIRef("http://www.w3.org/ns/odrl/2/Policy")
        @test ODRL2("permission") == URIRef("http://www.w3.org/ns/odrl/2/permission")
    end

    @testset "PROF" begin
        @test PROF.Profile == URIRef("http://www.w3.org/ns/dx/prof/Profile")
        @test PROF.hasResource == URIRef("http://www.w3.org/ns/dx/prof/hasResource")
        @test PROF.isProfileOf == URIRef("http://www.w3.org/ns/dx/prof/isProfileOf")
    end

    @testset "QB" begin
        @test QB.DataSet == URIRef("http://purl.org/linked-data/cube#DataSet")
        @test QB.Observation == URIRef("http://purl.org/linked-data/cube#Observation")
        @test QB.dimension == URIRef("http://purl.org/linked-data/cube#dimension")
        @test QB.measure == URIRef("http://purl.org/linked-data/cube#measure")
        @test QB.structure == URIRef("http://purl.org/linked-data/cube#structure")
    end

    @testset "SOSA" begin
        @test SOSA("Sensor") == URIRef("http://www.w3.org/ns/sosa/Sensor")
        @test SOSA("Observation") == URIRef("http://www.w3.org/ns/sosa/Observation")
    end

    @testset "SSN" begin
        @test SSN.Deployment == URIRef("http://www.w3.org/ns/ssn/Deployment")
        @test SSN.System == URIRef("http://www.w3.org/ns/ssn/System")
        @test SSN.hasInput == URIRef("http://www.w3.org/ns/ssn/hasInput")
        @test SSN.implements == URIRef("http://www.w3.org/ns/ssn/implements")
    end

    @testset "TIME" begin
        @test TIME("Instant") == URIRef("http://www.w3.org/2006/time#Instant")
        @test TIME("before") == URIRef("http://www.w3.org/2006/time#before")
    end

    @testset "WGS" begin
        @test WGS.Point == URIRef("https://www.w3.org/2003/01/geo/wgs84_pos#Point")
        @test WGS.lat == URIRef("https://www.w3.org/2003/01/geo/wgs84_pos#lat")
        @test WGS.long == URIRef("https://www.w3.org/2003/01/geo/wgs84_pos#long")
        @test WGS.alt == URIRef("https://www.w3.org/2003/01/geo/wgs84_pos#alt")
    end

    @testset "use in triples" begin
        g = RDFGraph()
        EX = RDFLib.Namespace("http://example.org/")
        add!(g, EX("sensor1"), RDF.type, SOSA("Sensor"))
        add!(g, EX("sensor1"), SOSA("observes"), EX("temperature"))
        @test length(g) == 2
    end
end
