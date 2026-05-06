using RDFLib, Test, Random
Random.seed!(42)

@testset "DuckDB bulk_add!" begin
    g = RDFGraph(store=DuckDBStore())
    ts = [Triple(URIRef("http://ex.org/s$(i÷10)"),
                 URIRef("http://ex.org/p$(i%5)"),
                 URIRef("http://ex.org/o$i")) for i in 1:1000]
    bulk_add!(g.store, ts)
    @test length(g) == 1000

    # Idempotency: re-adding gives no growth
    bulk_add!(g.store, ts)
    @test length(g) == 1000

    # Mixed with literals + bnodes
    add_more = [
        Triple(BNode("b1"), URIRef("http://ex.org/p"), Literal("hi", lang="en")),
        Triple(URIRef("http://ex.org/x"), URIRef("http://ex.org/n"),
               Literal("42", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))),
    ]
    bulk_add!(g.store, add_more)
    @test length(g) == 1002

    # Round-trip a literal: query with pushdown
    res = sparql_query(g, """
        PREFIX ex: <http://ex.org/>
        SELECT ?n WHERE { ex:x ex:n ?n }
    """)
    @test length(res) == 1
    @test res[1]["n"].lexical == "42"

    # bulk_add! with dedup=false (assumes disjoint)
    g2 = RDFGraph(store=DuckDBStore())
    bulk_add!(g2.store, ts; dedup=false)
    @test length(g2) == 1000
    close(g2.store)

    # Pattern lookup works (existing iteration path)
    n_p0 = 0
    for _ in triples(g, (nothing, URIRef("http://ex.org/p0"), nothing))
        n_p0 += 1
    end
    @test n_p0 == 200  # 1000 / 5

    close(g.store)
end
