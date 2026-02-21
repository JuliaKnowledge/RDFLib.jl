using Test
using RDFLib

@testset "Dataset" begin
    EX = Namespace("http://example.org/")

    @testset "default graph" begin
        ds = Dataset()
        add!(ds, Triple(EX("s"), EX("p"), Literal("hello")))
        @test length(ds) == 1

        g = get_graph(ds)
        @test length(g) == 1
    end

    @testset "named graphs" begin
        ds = Dataset()
        g1_name = EX("graph1")
        add!(ds, Triple(EX("s"), EX("p"), Literal("hello")), g1_name)
        @test length(ds) == 1

        g1 = get_graph(ds, g1_name)
        @test !isnothing(g1)
        @test length(g1) == 1

        # Default graph should be empty
        @test length(get_graph(ds)) == 0
    end

    @testset "multiple graphs" begin
        ds = Dataset()
        add!(ds, EX("s"), EX("p"), Literal("default"))
        add!(ds, EX("s"), EX("p"), Literal("g1"), EX("graph1"))
        add!(ds, EX("s"), EX("p"), Literal("g2"), EX("graph2"))

        @test length(ds) == 3

        ctx = collect(contexts(ds))
        @test length(ctx) == 3  # default + 2 named
    end

    @testset "quads iteration" begin
        ds = Dataset()
        add!(ds, EX("s"), EX("p"), Literal("default"))
        add!(ds, EX("s"), EX("p"), Literal("named"), EX("g1"))

        qs = collect(quads(ds))
        @test length(qs) == 2

        default_quads = filter(q -> isnothing(q.graph), qs)
        @test length(default_quads) == 1

        named_quads = filter(q -> !isnothing(q.graph), qs)
        @test length(named_quads) == 1
        @test named_quads[1].graph == EX("g1")
    end

    @testset "quads pattern matching" begin
        ds = Dataset()
        add!(ds, EX("a"), EX("p"), Literal("1"), EX("g1"))
        add!(ds, EX("b"), EX("p"), Literal("2"), EX("g1"))
        add!(ds, EX("a"), EX("p"), Literal("3"), EX("g2"))

        # Filter by graph
        g1_quads = collect(quads(ds, (nothing, nothing, nothing, EX("g1"))))
        @test length(g1_quads) == 2

        g2_quads = collect(quads(ds, (nothing, nothing, nothing, EX("g2"))))
        @test length(g2_quads) == 1
    end

    @testset "remove graph" begin
        ds = Dataset()
        add!(ds, EX("s"), EX("p"), Literal("x"), EX("g1"))
        @test length(ds) == 1

        remove_graph(ds, EX("g1"))
        @test length(ds) == 0
    end

    @testset "graphs iteration" begin
        ds = Dataset()
        add!(ds, EX("s"), EX("p"), Literal("default"))
        add!(ds, EX("s"), EX("p"), Literal("named"), EX("g1"))

        gs = collect(graphs(ds))
        @test length(gs) == 2

        names = [g[1] for g in gs]
        @test nothing in names
        @test EX("g1") in names
    end
end
