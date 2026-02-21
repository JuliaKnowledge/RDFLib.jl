using Test, RDFLib

@testset "DOT Visualization" begin
    @testset "basic graph" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        add!(g, Triple(EX("alice"), EX("knows"), EX("bob")))
        add!(g, Triple(EX("alice"), RDFS.label, Literal("Alice")))

        dot = to_dot(g)
        @test occursin("digraph", dot)
        @test occursin("->", dot)
        @test occursin("Alice", dot)
    end

    @testset "blank nodes" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        b = BNode("x1")
        add!(g, Triple(EX("s"), EX("p"), b))
        add!(g, Triple(b, EX("q"), Literal("val")))

        dot = to_dot(g)
        @test occursin("shape=circle", dot) || occursin("shape=\"circle\"", dot) || occursin("point", dot)
    end

    @testset "literal with language tag" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        add!(g, Triple(EX("s"), RDFS.label, Literal("Bonjour", lang="fr")))

        dot = to_dot(g)
        @test occursin("Bonjour", dot)
        @test occursin("fr", dot)
    end

    @testset "IO output" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        add!(g, Triple(EX("a"), EX("b"), EX("c")))

        buf = IOBuffer()
        to_dot(buf, g)
        dot = String(take!(buf))
        @test startswith(dot, "digraph")
    end

    @testset "empty graph" begin
        g = RDFGraph()
        dot = to_dot(g)
        @test occursin("digraph", dot)
    end

    @testset "special characters escaped" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        add!(g, Triple(EX("s"), EX("p"), Literal("line1\nline2")))
        dot = to_dot(g)
        @test occursin("digraph", dot)
        # Newline should be escaped in the DOT output
        @test !occursin("line1\nline2", dot)
        @test occursin("line1\\nline2", dot)
    end

    @testset "file output" begin
        g = RDFGraph()
        EX = Namespace("http://example.org/")
        add!(g, Triple(EX("a"), EX("b"), EX("c")))

        tmpfile = tempname() * ".dot"
        try
            to_dot(g, tmpfile)
            content = read(tmpfile, String)
            @test occursin("digraph", content)
        finally
            isfile(tmpfile) && rm(tmpfile)
        end
    end
end
