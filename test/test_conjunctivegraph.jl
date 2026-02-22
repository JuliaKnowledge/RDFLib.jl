using Test
using RDFLib

@testset "ConjunctiveGraph" begin
    EX = RDFLib.Namespace("http://example.org/")

    @testset "construction" begin
        cg = ConjunctiveGraph()
        @test length(cg) == 0
        @test isempty(cg)
    end

    @testset "add to default graph" begin
        cg = ConjunctiveGraph()
        add!(cg, Triple(EX("s"), EX("p"), EX("o")))
        @test length(cg) == 1
        @test !isempty(cg)
    end

    @testset "add to named graph" begin
        cg = ConjunctiveGraph()
        add!(cg, Triple(EX("s"), EX("p"), EX("o")), EX("g1"))
        @test length(cg) == 1
        g1 = get_context(cg, EX("g1"))
        @test g1 !== nothing
        @test length(g1) == 1
    end

    @testset "triples across all graphs" begin
        cg = ConjunctiveGraph()
        add!(cg, Triple(EX("s1"), EX("p"), EX("o1")))
        add!(cg, Triple(EX("s2"), EX("p"), EX("o2")), EX("g1"))
        add!(cg, Triple(EX("s3"), EX("p"), EX("o3")), EX("g2"))
        all_triples = collect(triples(cg, (nothing, EX("p"), nothing)))
        @test length(all_triples) == 3
    end

    @testset "contexts" begin
        cg = ConjunctiveGraph()
        add!(cg, Triple(EX("s"), EX("p"), EX("o")))
        add!(cg, Triple(EX("s2"), EX("p"), EX("o2")), EX("g1"))
        ctxs = collect(contexts(cg))
        @test nothing in ctxs
        @test EX("g1") in ctxs
        @test length(ctxs) == 2
    end

    @testset "get_context" begin
        cg = ConjunctiveGraph()
        add!(cg, Triple(EX("s"), EX("p"), EX("o")))
        default_g = get_context(cg, nothing)
        @test default_g !== nothing
        @test length(default_g) == 1
    end

    @testset "remove_context!" begin
        cg = ConjunctiveGraph()
        add!(cg, Triple(EX("s"), EX("p"), EX("o")), EX("g1"))
        @test length(cg) == 1
        remove_context!(cg, EX("g1"))
        @test length(cg) == 0
        ctxs = collect(contexts(cg))
        @test !(EX("g1") in ctxs)
    end

    @testset "iteration" begin
        cg = ConjunctiveGraph()
        add!(cg, Triple(EX("s1"), EX("p"), EX("o1")))
        add!(cg, Triple(EX("s2"), EX("p"), EX("o2")), EX("g1"))
        collected = collect(cg)
        @test length(collected) == 2
        @test all(t -> t isa Triple, collected)
    end

    @testset "quads" begin
        cg = ConjunctiveGraph()
        add!(cg, Triple(EX("s1"), EX("p"), EX("o1")))
        add!(cg, Triple(EX("s2"), EX("p"), EX("o2")), EX("g1"))
        qs = collect(quads(cg))
        @test length(qs) == 2
        @test all(q -> q isa Quad, qs)
        graph_names = [q.graph for q in qs]
        @test nothing in graph_names
        @test EX("g1") in graph_names
    end

    @testset "remove!" begin
        cg = ConjunctiveGraph()
        add!(cg, Triple(EX("s"), EX("p"), EX("o")))
        add!(cg, Triple(EX("s"), EX("p"), EX("o")), EX("g1"))
        remove!(cg, (EX("s"), EX("p"), EX("o")))
        @test length(cg) == 0
    end

    @testset "from existing Dataset" begin
        ds = Dataset()
        add!(ds, Triple(EX("s"), EX("p"), EX("o")))
        cg = ConjunctiveGraph(ds)
        @test length(cg) == 1
    end

    @testset "deduplication in triples" begin
        cg = ConjunctiveGraph()
        t = Triple(EX("s"), EX("p"), EX("o"))
        add!(cg, t)
        add!(cg, t, EX("g1"))
        # Same triple in two graphs, but triples() deduplicates
        all_t = collect(triples(cg, (nothing, nothing, nothing)))
        @test length(all_t) == 1
    end
end
