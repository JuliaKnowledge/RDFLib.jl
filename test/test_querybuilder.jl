using Test
using RDFLib

@testset "QueryBuilder" begin
    EX = Namespace("http://example.org/")

    function make_test_graph()
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        add!(g, EX("alice"), EX("name"), Literal("Alice"))
        add!(g, EX("alice"), EX("age"), Literal(30))
        add!(g, EX("alice"), EX("knows"), EX("bob"))
        add!(g, EX("bob"), RDF.type, EX("Person"))
        add!(g, EX("bob"), EX("name"), Literal("Bob"))
        add!(g, EX("bob"), EX("age"), Literal(25))
        add!(g, EX("carol"), RDF.type, EX("Person"))
        add!(g, EX("carol"), EX("name"), Literal("Carol"))
        add!(g, EX("carol"), EX("age"), Literal(35))
        g
    end

    @testset "SelectQuery basics" begin
        q = SelectQuery()
        q = select(q, :name, :age)
        q = where(q, "?person", "<http://example.org/name>", "?name")
        q = where(q, "?person", "<http://example.org/age>", "?age")
        q = limit(q, 10)
        s = build(q)
        @test occursin("SELECT ?name ?age", s)
        @test occursin("?person <http://example.org/name> ?name .", s)
        @test occursin("LIMIT 10", s)
    end

    @testset "SelectQuery with prefix" begin
        q = SelectQuery() |>
            q -> prefix(q, "ex", "http://example.org/") |>
            q -> select(q, :s) |>
            q -> where(q, "?s", "ex:name", "?name")
        s = build(q)
        @test occursin("PREFIX ex: <http://example.org/>", s)
        @test occursin("?s ex:name ?name .", s)
    end

    @testset "SelectQuery with filter" begin
        q = SelectQuery()
        q = select(q, :name)
        q = where(q, "?person", "<http://example.org/age>", "?age")
        q = filter(q, "?age > 25")
        s = build(q)
        @test occursin("FILTER(?age > 25)", s)
    end

    @testset "SelectQuery with order_by" begin
        q = SelectQuery()
        q = select(q, :name)
        q = where(q, "?person", "<http://example.org/name>", "?name")
        q = order_by(q, :name, :desc)
        s = build(q)
        @test occursin("ORDER BY DESC(?name)", s)
    end

    @testset "SelectQuery with order_by ascending" begin
        q = SelectQuery()
        q = select(q, :name)
        q = order_by(q, :name)
        s = build(q)
        @test occursin("ORDER BY ?name", s)
    end

    @testset "SelectQuery DISTINCT" begin
        q = SelectQuery()
        q = select(q, :s)
        q = distinct(q)
        s = build(q)
        @test occursin("SELECT DISTINCT ?s", s)
    end

    @testset "SelectQuery with offset" begin
        q = SelectQuery()
        q = select(q, :s)
        q = limit(q, 10)
        q = offset(q, 5)
        s = build(q)
        @test occursin("LIMIT 10", s)
        @test occursin("OFFSET 5", s)
    end

    @testset "SelectQuery with OPTIONAL" begin
        q = SelectQuery()
        q = select(q, :name, :email)
        q = where(q, "?person", "<http://example.org/name>", "?name")
        q = optional(q, ("?person", "<http://example.org/email>", "?email"))
        s = build(q)
        @test occursin("OPTIONAL {", s)
        @test occursin("?person <http://example.org/email> ?email .", s)
    end

    @testset "SelectQuery with UNION" begin
        q = SelectQuery()
        q = select(q, :s)
        q = union_pattern(q,
            [("?s", "<http://example.org/name>", "?n")],
            [("?s", "<http://example.org/label>", "?n")]
        )
        s = build(q)
        @test occursin("UNION", s)
    end

    @testset "SelectQuery with MINUS" begin
        q = SelectQuery()
        q = select(q, :s)
        q = where(q, "?s", "?p", "?o")
        q = minus(q, ("?s", "<http://example.org/name>", "?n"))
        s = build(q)
        @test occursin("MINUS {", s)
    end

    @testset "SelectQuery with BIND" begin
        q = SelectQuery()
        q = select(q, :s, :label)
        q = where(q, "?s", "<http://example.org/name>", "?name")
        q = query_bind(q, "CONCAT(\"Hello, \", ?name)", "label")
        s = build(q)
        @test occursin("BIND(CONCAT(\"Hello, \", ?name) AS ?label)", s)
    end

    @testset "SelectQuery with GROUP BY and HAVING" begin
        q = SelectQuery()
        q = select(q, :type)
        q = where(q, "?s", "<http://www.w3.org/1999/02/22-rdf-syntax-ns#type>", "?type")
        q = group_by(q, :type)
        q = having(q, "COUNT(?s) > 1")
        s = build(q)
        @test occursin("GROUP BY ?type", s)
        @test occursin("HAVING(COUNT(?s) > 1)", s)
    end

    @testset "SelectQuery with VALUES" begin
        q = SelectQuery()
        q = select(q, :s, :name)
        q = where(q, "?s", "<http://example.org/name>", "?name")
        q = query_values(q, ["s"], [["<http://example.org/alice>"], ["<http://example.org/bob>"]])
        s = build(q)
        @test occursin("VALUES", s)
    end

    @testset "SelectQuery SELECT *" begin
        q = SelectQuery()
        q = where(q, "?s", "?p", "?o")
        s = build(q)
        @test occursin("SELECT *", s)
    end

    @testset "ConstructQuery" begin
        q = ConstructQuery()
        q = construct(q, ("?s", "<http://example.org/name>", "?name"))
        q = where(q, "?s", "<http://example.org/label>", "?name")
        s = build(q)
        @test occursin("CONSTRUCT {", s)
        @test occursin("WHERE {", s)
    end

    @testset "AskQuery" begin
        q = AskQuery()
        q = where(q, "<http://example.org/alice>", "<http://example.org/name>", "?name")
        s = build(q)
        @test occursin("ASK", s)
        @test occursin("ASK {", s)
    end

    @testset "DescribeQuery" begin
        q = DescribeQuery()
        q = describe(q, "<http://example.org/alice>")
        s = build(q)
        @test occursin("DESCRIBE <http://example.org/alice>", s)
    end

    @testset "DescribeQuery with WHERE" begin
        q = DescribeQuery()
        q = describe(q, "?s")
        q = where(q, "?s", "<http://www.w3.org/1999/02/22-rdf-syntax-ns#type>", "<http://example.org/Person>")
        s = build(q)
        @test occursin("DESCRIBE ?s", s)
        @test occursin("WHERE {", s)
    end

    @testset "Pipe syntax" begin
        q = SelectQuery() |>
            q -> prefix(q, "ex", "http://example.org/") |>
            q -> select(q, :name, :age) |>
            q -> where(q, "?person", "ex:name", "?name") |>
            q -> where(q, "?person", "ex:age", "?age") |>
            q -> filter(q, "?age > 25") |>
            q -> order_by(q, :age, :desc) |>
            q -> limit(q, 10)
        s = build(q)
        @test occursin("PREFIX ex: <http://example.org/>", s)
        @test occursin("SELECT ?name ?age", s)
        @test occursin("FILTER(?age > 25)", s)
        @test occursin("ORDER BY DESC(?age)", s)
        @test occursin("LIMIT 10", s)
    end

    @testset "execute against graph" begin
        g = make_test_graph()
        q = SelectQuery() |>
            q -> select(q, :name) |>
            q -> where(q, "?s", "<http://www.w3.org/1999/02/22-rdf-syntax-ns#type>", "<http://example.org/Person>") |>
            q -> where(q, "?s", "<http://example.org/name>", "?name")
        results = execute(q, g)
        @test length(results) == 3
        names = [string(r["name"]) for r in results]
        @test "Alice" in names
        @test "Bob" in names
        @test "Carol" in names
    end

    @testset "execute with filter" begin
        g = make_test_graph()
        q = SelectQuery() |>
            q -> select(q, :name) |>
            q -> where(q, "?s", "<http://example.org/age>", "?age") |>
            q -> where(q, "?s", "<http://example.org/name>", "?name") |>
            q -> filter(q, "?age > 25")
        results = execute(q, g)
        names = [string(r["name"]) for r in results]
        @test "Alice" in names
        @test "Carol" in names
        @test !("Bob" in names)
    end

    @testset "execute ASK" begin
        g = make_test_graph()
        q = AskQuery()
        q = where(q, "<http://example.org/alice>", "<http://example.org/name>", "?name")
        @test execute(q, g) == true

        q2 = AskQuery()
        q2 = where(q2, "<http://example.org/nobody>", "<http://example.org/name>", "?name")
        @test execute(q2, g) == false
    end

    @testset "execute CONSTRUCT" begin
        g = make_test_graph()
        q = ConstructQuery()
        q = construct(q, ("?s", "<http://example.org/hasName>", "?name"))
        q = where(q, "?s", "<http://example.org/name>", "?name")
        result = execute(q, g)
        @test result isa RDFGraph
        @test length(result) >= 1
    end

    @testset "URIRef and Literal in where" begin
        q = SelectQuery()
        q = select(q, :s)
        q = where(q, :s, URIRef("http://example.org/name"), Literal("Alice"))
        s = build(q)
        @test occursin("<http://example.org/name>", s)
        @test occursin("\"Alice\"", s)
    end

    @testset "ConstructQuery with limit/offset" begin
        q = ConstructQuery()
        q = construct(q, ("?s", "?p", "?o"))
        q = where(q, "?s", "?p", "?o")
        q = limit(q, 5)
        q = offset(q, 2)
        s = build(q)
        @test occursin("LIMIT 5", s)
        @test occursin("OFFSET 2", s)
    end

    @testset "AskQuery with prefix and filter" begin
        q = AskQuery()
        q = prefix(q, "ex", "http://example.org/")
        q = where(q, "?s", "ex:age", "?age")
        q = filter(q, "?age > 100")
        s = build(q)
        @test occursin("PREFIX ex:", s)
        @test occursin("ASK", s)
        @test occursin("FILTER", s)
    end

    @testset "DescribeQuery with prefix" begin
        q = DescribeQuery()
        q = prefix(q, "ex", "http://example.org/")
        q = describe(q, "ex:alice")
        s = build(q)
        @test occursin("PREFIX ex:", s)
        @test occursin("DESCRIBE ex:alice", s)
    end
end
