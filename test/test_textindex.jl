using Test
using RDFLib

@testset "TextIndex" begin
    EX = Namespace("http://example.org/")

    function make_test_graph()
        g = RDFGraph()
        add!(g, EX("alice"), EX("name"), Literal("Alice Smith"))
        add!(g, EX("bob"), EX("name"), Literal("Bob Jones"))
        add!(g, EX("carol"), EX("name"), Literal("Carol Smith"))
        add!(g, EX("alice"), EX("description"), Literal("Alice is a software engineer"))
        add!(g, EX("bob"), EX("description"), Literal("Bob works in data science"))
        add!(g, EX("alice"), EX("age"), Literal(30))
        add!(g, EX("bob"), EX("age"), Literal(25))
        g
    end

    @testset "Basic construction" begin
        g = make_test_graph()
        idx = TextIndex(g)
        @test idx.indexed == true
        @test !isempty(idx.inverted_index)
    end

    @testset "Empty index" begin
        idx = TextIndex()
        @test idx.indexed == false
        @test isempty(idx.inverted_index)
    end

    @testset "Build and rebuild" begin
        g = make_test_graph()
        idx = TextIndex()
        build!(idx, g)
        @test idx.indexed == true
        n1 = length(idx.inverted_index)
        build!(idx, g)
        @test length(idx.inverted_index) == n1
    end

    @testset "Exact token search" begin
        g = make_test_graph()
        idx = TextIndex(g)
        results = text_search(idx, "alice")
        @test length(results) >= 1
        # Should find triples with "Alice" in literal
        objs = [r.object for r in results]
        @test any(o -> o isa Literal && occursin("Alice", o.lexical), objs)
    end

    @testset "Case insensitive search" begin
        g = make_test_graph()
        idx = TextIndex(g)
        results_lower = text_search(idx, "alice")
        results_upper = text_search(idx, "ALICE")
        # Both should find same triples (tokenization lowercases)
        # "ALICE" lowercased to "alice" matches the lowercased tokens
        @test length(results_lower) == length(results_upper)
    end

    @testset "Prefix search" begin
        g = make_test_graph()
        idx = TextIndex(g)
        results = text_search(idx, "ali*")
        @test length(results) >= 1
        objs = [r.object for r in results]
        @test any(o -> o isa Literal && occursin("Alice", o.lexical), objs)
    end

    @testset "Multi-token AND search" begin
        g = make_test_graph()
        idx = TextIndex(g)
        results = text_search(idx, "alice smith")
        @test length(results) >= 1
        # Should match "Alice Smith" (contains both tokens)
        objs = [r.object for r in results]
        @test any(o -> o isa Literal && o.lexical == "Alice Smith", objs)
    end

    @testset "No results for non-matching query" begin
        g = make_test_graph()
        idx = TextIndex(g)
        results = text_search(idx, "zzzznotfound")
        @test isempty(results)
    end

    @testset "Limit results" begin
        g = make_test_graph()
        idx = TextIndex(g)
        results = text_search(idx, "smith"; limit=1)
        @test length(results) <= 1
    end

    @testset "Empty query" begin
        g = make_test_graph()
        idx = TextIndex(g)
        results = text_search(idx, "")
        @test isempty(results)
    end

    @testset "Only indexes literals" begin
        g = make_test_graph()
        idx = TextIndex(g)
        # Numeric literals are tokenized as their string representation
        results = text_search(idx, "30")
        @test length(results) >= 1
    end

    @testset "Prefix search with broader match" begin
        g = make_test_graph()
        idx = TextIndex(g)
        results = text_search(idx, "smi*")
        @test length(results) >= 2  # Alice Smith, Carol Smith
    end

    @testset "SPARQL CONTAINS_TEXT integration" begin
        g = make_test_graph()

        results = sparql_query(g, """
            SELECT ?s ?name WHERE {
                ?s <http://example.org/name> ?name .
                FILTER(CONTAINS_TEXT(?name, "alice"))
            }
        """)
        @test length(results) >= 1
        names = [string(r["name"]) for r in results]
        @test "Alice Smith" in names
    end

    @testset "SPARQL CONTAINS_TEXT prefix search" begin
        g = make_test_graph()

        results = sparql_query(g, """
            SELECT ?s ?name WHERE {
                ?s <http://example.org/name> ?name .
                FILTER(CONTAINS_TEXT(?name, "smi*"))
            }
        """)
        @test length(results) >= 2
        names = [string(r["name"]) for r in results]
        @test "Alice Smith" in names
        @test "Carol Smith" in names
    end

    @testset "SPARQL CONTAINS_TEXT no match" begin
        g = make_test_graph()

        results = sparql_query(g, """
            SELECT ?s ?name WHERE {
                ?s <http://example.org/name> ?name .
                FILTER(CONTAINS_TEXT(?name, "zzzznotfound"))
            }
        """)
        @test isempty(results)
    end

    @testset "Global text index set/clear" begin
        g = make_test_graph()
        idx = TextIndex(g)
        set_text_index!(idx)
        @test RDFLib._GLOBAL_TEXT_INDEX[] === idx
        clear_text_index!()
        @test isnothing(RDFLib._GLOBAL_TEXT_INDEX[])
    end
end
