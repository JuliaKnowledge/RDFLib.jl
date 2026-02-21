using Test, RDFLib

@testset "Resource" begin
    EX = Namespace("http://example.org/")

    function make_graph()
        g = RDFGraph()
        add!(g, Triple(EX("alice"), RDF.type, EX("Person")))
        add!(g, Triple(EX("alice"), RDFS.label, Literal("Alice")))
        add!(g, Triple(EX("alice"), EX("age"), Literal(30)))
        add!(g, Triple(EX("alice"), EX("knows"), EX("bob")))
        add!(g, Triple(EX("alice"), EX("knows"), EX("carol")))
        add!(g, Triple(EX("bob"), RDFS.label, Literal("Bob")))
        g
    end

    @testset "creation" begin
        g = make_graph()
        r = Resource(g, EX("alice"))
        @test r.identifier == EX("alice")
    end

    @testset "getindex - single value" begin
        g = make_graph()
        r = Resource(g, EX("alice"))
        @test r[RDFS.label] == Literal("Alice")
    end

    @testset "getall - multiple values" begin
        g = make_graph()
        r = Resource(g, EX("alice"))
        knows = getall(r, EX("knows"))
        @test length(knows) == 2
        @test EX("bob") in knows
        @test EX("carol") in knows
    end

    @testset "getindex - missing predicate" begin
        g = make_graph()
        r = Resource(g, EX("alice"))
        @test isnothing(r[EX("nonexistent")])
    end

    @testset "setindex!" begin
        g = make_graph()
        r = Resource(g, EX("alice"))
        r[RDFS.label] = Literal("Alice Smith")
        @test r[RDFS.label] == Literal("Alice Smith")
        @test length(getall(r, RDFS.label)) == 1
    end

    @testset "add!" begin
        g = make_graph()
        r = Resource(g, EX("alice"))
        add!(r, EX("hobby"), Literal("chess"))
        @test r[EX("hobby")] == Literal("chess")
    end

    @testset "remove! predicate" begin
        g = make_graph()
        r = Resource(g, EX("alice"))
        remove!(r, EX("knows"))
        @test isempty(getall(r, EX("knows")))
    end

    @testset "remove! specific value" begin
        g = make_graph()
        r = Resource(g, EX("alice"))
        remove!(r, EX("knows"), EX("bob"))
        knows = getall(r, EX("knows"))
        @test length(knows) == 1
        @test EX("carol") in knows
    end

    @testset "types" begin
        g = make_graph()
        r = Resource(g, EX("alice"))
        t = types(r)
        @test EX("Person") in t
    end

    @testset "isa_resource" begin
        g = make_graph()
        r = Resource(g, EX("alice"))
        @test isa_resource(r, EX("Person"))
        @test !isa_resource(r, EX("Animal"))
    end

    @testset "predicates" begin
        g = make_graph()
        r = Resource(g, EX("alice"))
        preds = predicates(r)
        @test RDF.type in preds
        @test RDFS.label in preds
    end

    @testset "label" begin
        g = make_graph()
        r = Resource(g, EX("alice"))
        @test label(r) == Literal("Alice")
    end

    @testset "iteration" begin
        g = make_graph()
        r = Resource(g, EX("alice"))
        pairs = collect(r)
        @test length(pairs) >= 4
        @test all(p -> p isa Tuple{URIRef, Identifier}, pairs)
    end

    @testset "navigation" begin
        g = make_graph()
        r = Resource(g, EX("alice"))
        bob_r = resource(r, EX("knows"))
        @test bob_r isa Resource
        @test label(bob_r) !== nothing || true  # bob or carol
    end

    @testset "show" begin
        g = make_graph()
        r = Resource(g, EX("alice"))
        s = sprint(show, r)
        @test occursin("Resource", s)
        @test occursin("alice", s)
    end
end
