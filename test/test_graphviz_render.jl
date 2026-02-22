@testset "GraphViz Rendering" begin
    EX = Namespace("http://example.org/")

    g = RDFGraph()
    add!(g, Triple(EX("s1"), EX("p1"), Literal("hello")))
    add!(g, Triple(EX("s1"), EX("p2"), EX("o1")))

    @testset "render_dot SVG" begin
        dot = to_dot(g)
        data = render_dot(dot; format=:svg)
        @test length(data) > 0
        svg_str = String(copy(data))
        @test occursin("<svg", svg_str)
    end

    @testset "render_graph" begin
        data = render_graph(g; format=:svg, label="Test Graph")
        @test length(data) > 0
        svg_str = String(copy(data))
        @test occursin("<svg", svg_str)
    end

    @testset "render_schema" begin
        schema_g = RDFGraph()
        add!(schema_g, Triple(EX("Person"), RDF.type, RDFS.Class))
        data = render_schema(schema_g; format=:svg, label="Schema Test")
        @test length(data) > 0
    end

    @testset "save_visualization" begin
        tmpfile = tempname() * ".svg"
        try
            save_visualization(g, tmpfile; label="Save Test")
            @test isfile(tmpfile)
            content = read(tmpfile, String)
            @test occursin("<svg", content)
        finally
            isfile(tmpfile) && rm(tmpfile)
        end
    end

    @testset "save_visualization DOT format" begin
        tmpfile = tempname() * ".dot"
        try
            save_visualization(g, tmpfile)
            @test isfile(tmpfile)
            content = read(tmpfile, String)
            @test occursin("digraph", content)
        finally
            isfile(tmpfile) && rm(tmpfile)
        end
    end

    @testset "save_visualization schema mode" begin
        schema_g = RDFGraph()
        add!(schema_g, Triple(EX("Person"), RDF.type, RDFS.Class))
        tmpfile = tempname() * ".dot"
        try
            save_visualization(schema_g, tmpfile; schema=true)
            @test isfile(tmpfile)
            content = read(tmpfile, String)
            @test occursin("digraph", content)
            @test occursin("RDFS Schema", content)
        finally
            isfile(tmpfile) && rm(tmpfile)
        end
    end
end
