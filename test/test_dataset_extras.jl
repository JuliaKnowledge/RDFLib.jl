using Test
using RDFLib

@testset "Dataset Extras" begin
    EX = Namespace("http://example.org/")

    # ─── Graph creation via Dataset ─────────────────────────────────
    @testset "add_graph / remove_graph / list graphs" begin
        ds = Dataset()
        g1 = add_graph(ds, EX("g1"))
        g2 = add_graph(ds, EX("g2"))
        @test g1 isa RDFGraph
        @test g2 isa RDFGraph

        ctx = collect(contexts(ds))
        @test EX("g1") in ctx
        @test EX("g2") in ctx
        @test nothing in ctx                    # default graph always present
        @test length(ctx) == 3

        remove_graph(ds, EX("g1"))
        ctx2 = collect(contexts(ds))
        @test !(EX("g1") in ctx2)
        @test EX("g2") in ctx2
        @test length(ctx2) == 2
    end

    # ─── Adding triples to specific graphs ──────────────────────────
    @testset "triples in named graphs" begin
        ds = Dataset()
        t1 = Triple(EX("s1"), EX("p1"), Literal("v1"))
        t2 = Triple(EX("s2"), EX("p2"), Literal("v2"))
        add!(ds, t1, EX("g1"))
        add!(ds, t2, EX("g2"))

        g1 = get_graph(ds, EX("g1"))
        g2 = get_graph(ds, EX("g2"))
        @test length(g1) == 1
        @test length(g2) == 1

        g1_triples = collect(triples(g1, (nothing, nothing, nothing)))
        @test g1_triples[1] == t1

        g2_triples = collect(triples(g2, (nothing, nothing, nothing)))
        @test g2_triples[1] == t2
    end

    # ─── Graph isolation ────────────────────────────────────────────
    @testset "graph isolation" begin
        ds = Dataset()
        add!(ds, EX("a"), EX("p"), Literal("default"))
        add!(ds, EX("b"), EX("p"), Literal("named"), EX("g1"))

        default_g = get_graph(ds)
        named_g   = get_graph(ds, EX("g1"))

        # Each graph has only its own triple
        @test length(default_g) == 1
        @test length(named_g)   == 1

        # Default graph triple not visible in named graph
        default_subjects = collect(subjects(default_g, nothing, nothing))
        named_subjects   = collect(subjects(named_g, nothing, nothing))
        @test EX("a") in default_subjects
        @test !(EX("a") in named_subjects)
        @test EX("b") in named_subjects
        @test !(EX("b") in default_subjects)
    end

    # ─── Default graph operations ───────────────────────────────────
    @testset "default graph operations" begin
        ds = Dataset()
        add!(ds, EX("s"), EX("p"), Literal("1"))
        add!(ds, EX("s"), EX("p"), Literal("2"))
        add!(ds, EX("s"), EX("q"), Literal("3"), EX("named"))

        @test length(get_graph(ds)) == 2
        @test length(ds) == 3

        # remove from default graph only via pattern
        remove!(ds, (EX("s"), EX("p"), Literal("1")))
        @test length(get_graph(ds)) == 1
        @test length(ds) == 2
    end

    # ─── Dataset generators: unique subjects / predicates / objects ─
    @testset "dataset generators" begin
        ds = Dataset()
        add!(ds, EX("s1"), EX("p1"), Literal("o1"))
        add!(ds, EX("s2"), EX("p2"), Literal("o2"), EX("g1"))
        add!(ds, EX("s1"), EX("p3"), Literal("o3"), EX("g1"))

        # Collect unique subjects across all graphs via quads
        all_quads = collect(quads(ds))
        all_subjects = unique([q.subject for q in all_quads])
        @test length(all_subjects) == 2
        @test EX("s1") in all_subjects
        @test EX("s2") in all_subjects

        all_predicates = unique([q.predicate for q in all_quads])
        @test length(all_predicates) == 3

        all_objects = unique([q.object for q in all_quads])
        @test length(all_objects) == 3
    end

    # ─── Iteration: quads and graphs ────────────────────────────────
    @testset "iteration" begin
        ds = Dataset()
        add!(ds, EX("a"), EX("p"), Literal("1"))
        add!(ds, EX("b"), EX("p"), Literal("2"), EX("g1"))
        add!(ds, EX("c"), EX("p"), Literal("3"), EX("g2"))

        # quads returns Quad values with correct graph context
        qs = collect(quads(ds))
        @test length(qs) == 3
        @test all(q -> q isa Quad, qs)

        graph_ids = [q.graph for q in qs]
        @test nothing in graph_ids
        @test EX("g1") in graph_ids
        @test EX("g2") in graph_ids

        # graphs iteration yields (name, RDFGraph) pairs
        gs = collect(graphs(ds))
        @test length(gs) == 3
        for (name, g) in gs
            @test g isa RDFGraph
            @test length(g) == 1
        end
    end

    # ─── Named graph CRUD ──────────────────────────────────────────
    @testset "named graph CRUD" begin
        ds = Dataset()

        # Create
        add!(ds, EX("s"), EX("p"), Literal("val"), EX("crud"))
        @test !isnothing(get_graph(ds, EX("crud")))

        # Read
        g = get_graph(ds, EX("crud"))
        @test length(g) == 1

        # Update — add another triple to same graph
        add!(ds, EX("s2"), EX("p2"), Literal("val2"), EX("crud"))
        @test length(get_graph(ds, EX("crud"))) == 2

        # Delete graph entirely
        remove_graph(ds, EX("crud"))
        @test isnothing(get_graph(ds, EX("crud")))
        @test isempty(ds)
    end

    # ─── Quad equality and hashing ──────────────────────────────────
    @testset "Quad equality and hashing" begin
        q1 = Quad(EX("s"), EX("p"), EX("o"), EX("g"))
        q2 = Quad(EX("s"), EX("p"), EX("o"), EX("g"))
        q3 = Quad(EX("s"), EX("p"), EX("o"), nothing)

        @test q1 == q2
        @test q1 != q3
        @test hash(q1) == hash(q2)
        @test hash(q1) != hash(q3)

        # Quad from Triple
        t = Triple(EX("s"), EX("p"), EX("o"))
        q_from_t = Quad(t, EX("g"))
        @test q_from_t == q1
        @test Triple(q_from_t) == t
    end

    # ─── Dataset show / isempty / length ────────────────────────────
    @testset "show / isempty / length" begin
        ds = Dataset()
        @test isempty(ds)
        @test length(ds) == 0
        @test occursin("0 quads", sprint(show, ds))

        add!(ds, EX("s"), EX("p"), EX("o"))
        @test !isempty(ds)
        @test length(ds) == 1
        @test occursin("1 quads", sprint(show, ds))
    end

    # ─── Namespace binding on Dataset ───────────────────────────────
    @testset "namespace binding" begin
        ds = Dataset()
        bind!(ds, "ex", Namespace("http://example.org/"))
        ns = RDFLib.namespaces(ds)
        @test any(p -> p[1] == "ex", ns)
    end

    # ─── N-Quads round-trip ─────────────────────────────────────────
    @testset "N-Quads serialization round-trip" begin
        ds = Dataset()
        add!(ds, EX("s1"), EX("p1"), Literal("hello"))
        add!(ds, EX("s2"), EX("p2"), Literal("world"), EX("g1"))
        add!(ds, EX("s3"), EX("p3"), EX("o3"), EX("g2"))

        nq_str = serialize_nquads(ds)
        @test occursin("<http://example.org/s1>", nq_str)
        @test occursin("<http://example.org/g1>", nq_str)

        ds2 = parse_nquads(nq_str)
        @test length(ds2) == length(ds)

        ctx_orig = sort(filter(!isnothing, collect(contexts(ds))); by=string)
        ctx_new  = sort(filter(!isnothing, collect(contexts(ds2))); by=string)
        @test ctx_orig == ctx_new
    end

    # ─── TriG round-trip ────────────────────────────────────────────
    @testset "TriG serialization round-trip" begin
        ds = Dataset()
        bind!(ds, "ex", Namespace("http://example.org/"))
        add!(ds, EX("s"), EX("p"), Literal("default value"))
        add!(ds, EX("a"), EX("b"), Literal("in graph"), EX("g1"))

        trig_str = serialize_trig(ds)
        @test occursin("ex:", trig_str) || occursin("<http://example.org/", trig_str)

        ds2 = parse_trig(trig_str)
        @test length(ds2) == length(ds)
    end

    # ─── remove! across all graphs ──────────────────────────────────
    @testset "remove across all graphs" begin
        ds = Dataset()
        add!(ds, EX("s"), EX("p"), Literal("x"))
        add!(ds, EX("s"), EX("p"), Literal("x"), EX("g1"))
        @test length(ds) == 2

        # remove! with graph_name=nothing removes from ALL graphs
        remove!(ds, (EX("s"), EX("p"), Literal("x")))
        @test length(ds) == 0
    end

    # ─── quads pattern matching detailed ────────────────────────────
    @testset "quads pattern by subject and predicate" begin
        ds = Dataset()
        add!(ds, EX("a"), EX("type"), Literal("Person"), EX("g1"))
        add!(ds, EX("b"), EX("type"), Literal("Place"), EX("g1"))
        add!(ds, EX("a"), EX("name"), Literal("Alice"), EX("g1"))

        # Filter by subject across specific graph
        qa = collect(quads(ds, (EX("a"), nothing, nothing, EX("g1"))))
        @test length(qa) == 2

        # Filter by predicate
        qtype = collect(quads(ds, (nothing, EX("type"), nothing, EX("g1"))))
        @test length(qtype) == 2
    end
end
