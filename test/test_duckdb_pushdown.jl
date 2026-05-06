using RDFLib
using Test

@testset "DuckDB BGP pushdown smoke" begin
    g = RDFGraph(store=DuckDBStore())
    EX = Namespace("http://example.org/")
    bind!(g.namespace_manager, "ex", EX)

    # Build small graph: 3 customers, 6 orders
    for i in 1:3
        c = URIRef("$(EX.uri)c$i")
        add!(g, Triple(c, RDF.type, EX.Customer))
        add!(g, Triple(c, EX.country, Literal("US")))
        for j in 1:2
            o = URIRef("$(EX.uri)o$(i)_$j")
            add!(g, Triple(o, RDF.type, EX.Order))
            add!(g, Triple(o, EX.placedBy, c))
            add!(g, Triple(o, EX.amount, Literal(string(10*i + j),
                datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))))
        end
    end

    @test length(g) == 3 * 2 + 3 * 3 * 2  # customer triples + order triples
    # 3 customers * 2 (type+country) + 3*2 orders * 3 (type+placedBy+amount) = 6+18 = 24
    @test length(g) == 24

    # Query 1: pure BGP COUNT(*)
    res = sparql_query(g, """
        PREFIX ex: <http://example.org/>
        SELECT (COUNT(*) AS ?n) WHERE { ?s a ex:Customer }
    """)
    @test res[1]["n"].lexical == "3"

    # Query 2: BGP star + GROUP BY + COUNT
    res = sparql_query(g, """
        PREFIX ex: <http://example.org/>
        PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
        SELECT ?country (COUNT(?o) AS ?n)
        WHERE { ?c rdf:type ex:Customer ; ex:country ?country .
                ?o rdf:type ex:Order ; ex:placedBy ?c }
        GROUP BY ?country
    """)
    @test length(res) == 1
    @test res[1]["country"].lexical == "US"
    @test res[1]["n"].lexical == "6"

    # Query 3: BGP + SUM
    res = sparql_query(g, """
        PREFIX ex: <http://example.org/>
        PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
        SELECT (SUM(?a) AS ?total)
        WHERE { ?o rdf:type ex:Order ; ex:amount ?a }
    """)
    # 11+12+21+22+31+32 = 129
    @test parse(Float64, res[1]["total"].lexical) == 129.0

    # Query 4: BGP returning bound vars, ORDER BY, LIMIT
    res = sparql_query(g, """
        PREFIX ex: <http://example.org/>
        SELECT ?s WHERE { ?s a ex:Customer } ORDER BY ?s LIMIT 2
    """)
    @test length(res) == 2
    @test res[1]["s"].value == "http://example.org/c1"

    # Query 5: OPTIONAL (LEFT JOIN)
    # Add a customer with no orders
    c4 = URIRef("$(EX.uri)c4")
    add!(g, Triple(c4, RDF.type, EX.Customer))
    add!(g, Triple(c4, EX.country, Literal("UK")))

    res = sparql_query(g, """
        PREFIX ex: <http://example.org/>
        PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
        SELECT ?country (COUNT(?o) AS ?n)
        WHERE { ?c rdf:type ex:Customer ; ex:country ?country .
                OPTIONAL { ?o ex:placedBy ?c } }
        GROUP BY ?country
        ORDER BY ?country
    """)
    @test length(res) == 2
    bycountry = Dict(r["country"].lexical => r["n"].lexical for r in res)
    @test bycountry["US"] == "6"
    @test bycountry["UK"] == "0"

    close(g.store)
    println("DuckDB pushdown tests passed")
end
