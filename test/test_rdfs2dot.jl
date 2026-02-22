@testset "RDFS2DOT" begin
    EX = Namespace("http://example.org/")

    g = RDFGraph()
    # Define classes
    add!(g, Triple(EX("Person"), RDF.type, RDFS.Class))
    add!(g, Triple(EX("Organization"), RDF.type, OWL.Class))
    add!(g, Triple(EX("Student"), RDF.type, RDFS.Class))
    add!(g, Triple(EX("Student"), RDFS.subClassOf, EX("Person")))

    # Define a property with domain/range
    add!(g, Triple(EX("worksFor"), RDF.type, OWL.ObjectProperty))
    add!(g, Triple(EX("worksFor"), RDFS.domain, EX("Person")))
    add!(g, Triple(EX("worksFor"), RDFS.range, EX("Organization")))

    # Add a label
    add!(g, Triple(EX("Person"), RDFS.label, Literal("Person")))

    dot = rdfs2dot(g; label="Test Schema")

    @testset "DOT structure" begin
        @test occursin("digraph", dot)
        @test occursin("Test Schema", dot)
        @test occursin("shape=box", dot)
    end

    @testset "Classes present" begin
        @test occursin("Person", dot)
        @test occursin("Organization", dot)
        @test occursin("Student", dot)
    end

    @testset "SubClassOf edge" begin
        @test occursin("subClassOf", dot)
        @test occursin("style=dashed", dot)
    end

    @testset "Property edge" begin
        @test occursin("worksFor", dot)
    end

    @testset "OWL class styling" begin
        @test occursin("fillcolor", dot)
    end

    @testset "IO method" begin
        buf = IOBuffer()
        rdfs2dot(buf, g; label="IO Test")
        dot2 = String(take!(buf))
        @test occursin("digraph", dot2)
        @test occursin("IO Test", dot2)
    end
end
