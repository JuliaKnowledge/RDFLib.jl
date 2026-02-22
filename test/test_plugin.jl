using Test
using RDFLib

include(joinpath(@__DIR__, "..", "src", "plugin.jl"))

@testset "Plugin System" begin
    s = URIRef("http://example.org/s")
    p = URIRef("http://example.org/p")
    o = Literal("hello")
    t = Triple(s, p, o)

    # Clear registries before tests
    empty!(_PARSER_REGISTRY)
    empty!(_SERIALIZER_REGISTRY)
    empty!(_STORE_REGISTRY)

    @testset "register and get parser" begin
        called = Ref(false)
        my_parser = (g, data) -> (called[] = true; g)
        register_parser!("text/x-test", my_parser)
        fn = get_parser("text/x-test")
        @test fn !== nothing
        fn(RDFGraph(), "data")
        @test called[]
    end

    @testset "register and get serializer" begin
        my_ser = g -> "serialized"
        register_serializer!("text/x-test", my_ser)
        fn = get_serializer("text/x-test")
        @test fn !== nothing
        @test fn(RDFGraph()) == "serialized"
    end

    @testset "register and get store" begin
        register_store!("memory", MemoryStore)
        st = get_store("memory")
        @test st === MemoryStore
    end

    @testset "get unknown returns nothing" begin
        @test get_parser("application/x-unknown") === nothing
        @test get_serializer("application/x-unknown") === nothing
        @test get_store("nonexistent") === nothing
    end

    @testset "list_parsers" begin
        empty!(_PARSER_REGISTRY)
        register_parser!("text/a", (g, d) -> g)
        register_parser!("text/b", (g, d) -> g)
        parsers = list_parsers()
        @test "text/a" in parsers
        @test "text/b" in parsers
        @test length(parsers) == 2
    end

    @testset "list_serializers" begin
        empty!(_SERIALIZER_REGISTRY)
        register_serializer!("text/a", g -> "a")
        sers = list_serializers()
        @test "text/a" in sers
    end

    @testset "list_stores" begin
        empty!(_STORE_REGISTRY)
        register_store!("mem", MemoryStore)
        stores = list_stores()
        @test "mem" in stores
    end

    @testset "unregister parser" begin
        empty!(_PARSER_REGISTRY)
        register_parser!("text/x", (g, d) -> g)
        @test get_parser("text/x") !== nothing
        unregister_parser!("text/x")
        @test get_parser("text/x") === nothing
    end

    @testset "unregister serializer" begin
        empty!(_SERIALIZER_REGISTRY)
        register_serializer!("text/x", g -> "x")
        @test get_serializer("text/x") !== nothing
        unregister_serializer!("text/x")
        @test get_serializer("text/x") === nothing
    end

    @testset "unregister store" begin
        empty!(_STORE_REGISTRY)
        register_store!("test", MemoryStore)
        @test get_store("test") !== nothing
        unregister_store!("test")
        @test get_store("test") === nothing
    end

    @testset "_register_builtins!" begin
        empty!(_PARSER_REGISTRY)
        empty!(_SERIALIZER_REGISTRY)
        empty!(_STORE_REGISTRY)
        _register_builtins!()
        @test get_parser("application/n-triples") !== nothing
        @test get_parser("text/turtle") !== nothing
        @test get_serializer("application/n-triples") !== nothing
        @test get_serializer("text/turtle") !== nothing
        @test get_store("memory") === MemoryStore
    end

    @testset "builtin n-triples round-trip via plugin" begin
        empty!(_PARSER_REGISTRY)
        empty!(_SERIALIZER_REGISTRY)
        _register_builtins!()
        g = RDFGraph()
        add!(g, t)
        ser_fn = get_serializer("application/n-triples")
        nt_str = ser_fn(g)
        @test occursin("http://example.org/s", nt_str)
        g2 = RDFGraph()
        parse_fn = get_parser("application/n-triples")
        parse_fn(g2, nt_str)
        @test length(g2) == 1
    end

    @testset "overwrite registration" begin
        empty!(_PARSER_REGISTRY)
        register_parser!("text/x", (g, d) -> "first")
        register_parser!("text/x", (g, d) -> "second")
        fn = get_parser("text/x")
        @test fn(RDFGraph(), "") == "second"
    end
end
