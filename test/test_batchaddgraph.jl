using Test
using RDFLib

@testset "BatchAddGraph" begin
    EX = RDFLib.Namespace("http://example.org/")

    @testset "construction" begin
        g = RDFGraph()
        bag = BatchAddGraph(g; batch_size=10)
        @test length(bag) == 0
    end

    @testset "buffering and auto-flush" begin
        g = RDFGraph()
        bag = BatchAddGraph(g; batch_size=5)
        for i in 1:4
            add!(bag, Triple(EX("s$i"), EX("p"), EX("o$i")))
        end
        # Buffer not yet flushed
        @test length(g) == 0
        @test length(bag) == 4

        # Adding one more triggers auto-flush
        add!(bag, Triple(EX("s5"), EX("p"), EX("o5")))
        @test length(g) == 5
        @test length(bag) == 5
    end

    @testset "manual flush" begin
        g = RDFGraph()
        bag = BatchAddGraph(g; batch_size=100)
        for i in 1:10
            add!(bag, Triple(EX("s$i"), EX("p"), EX("o$i")))
        end
        @test length(g) == 0
        flush!(bag)
        @test length(g) == 10
    end

    @testset "close! flushes remaining" begin
        g = RDFGraph()
        bag = BatchAddGraph(g; batch_size=100)
        for i in 1:7
            add!(bag, Triple(EX("s$i"), EX("p"), EX("o$i")))
        end
        result = close!(bag)
        @test result === g
        @test length(g) == 7
    end

    @testset "multiple flushes" begin
        g = RDFGraph()
        bag = BatchAddGraph(g; batch_size=3)
        for i in 1:10
            add!(bag, Triple(EX("s$i"), EX("p"), EX("o$i")))
        end
        # 3 auto-flushes happened (at 3, 6, 9), 1 remaining in buffer
        @test length(g) == 9
        close!(bag)
        @test length(g) == 10
    end

    @testset "default batch_size" begin
        g = RDFGraph()
        bag = BatchAddGraph(g)
        @test bag.batch_size == 1000
    end
end
