@testset "SPARQL Results Parser" begin

    # ─── Test data ───────────────────────────────────────────────────
    ex = RDFLib.Namespace("http://example.org/")

    results = [
        Dict{String, RDFLib.Identifier}(
            "s" => URIRef("http://example.org/alice"),
            "name" => Literal("Alice"),
            "age" => Literal("30", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))
        ),
        Dict{String, RDFLib.Identifier}(
            "s" => URIRef("http://example.org/bob"),
            "name" => Literal("Bob", lang="en"),
            "age" => Literal("25", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))
        )
    ]
    vars = ["age", "name", "s"]

    # ─── JSON round-trip ─────────────────────────────────────────────
    @testset "JSON round-trip" begin
        json_str = sparql_results_json(results; variables=vars)
        parsed_vars, parsed_results = parse_sparql_results_json(json_str)

        @test parsed_vars == vars
        @test length(parsed_results) == 2

        @test parsed_results[1]["s"] == URIRef("http://example.org/alice")
        @test parsed_results[1]["name"] == Literal("Alice")
        @test parsed_results[1]["age"] == Literal("30", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))

        @test parsed_results[2]["s"] == URIRef("http://example.org/bob")
        @test parsed_results[2]["name"] == Literal("Bob", lang="en")
    end

    # ─── JSON ASK ────────────────────────────────────────────────────
    @testset "JSON ASK" begin
        ask_true = sparql_results_json(true)
        ask_false = sparql_results_json(false)
        @test parse_sparql_ask_json(ask_true) == true
        @test parse_sparql_ask_json(ask_false) == false
    end

    # ─── XML round-trip ──────────────────────────────────────────────
    @testset "XML round-trip" begin
        xml_str = sparql_results_xml(results; variables=vars)
        parsed_vars, parsed_results = parse_sparql_results_xml(xml_str)

        @test parsed_vars == vars
        @test length(parsed_results) == 2

        @test parsed_results[1]["s"] == URIRef("http://example.org/alice")
        @test parsed_results[1]["name"] == Literal("Alice")
        @test parsed_results[1]["age"] == Literal("30", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))

        @test parsed_results[2]["name"] == Literal("Bob", lang="en")
    end

    # ─── XML ASK ─────────────────────────────────────────────────────
    @testset "XML ASK" begin
        ask_true = sparql_results_xml(true)
        ask_false = sparql_results_xml(false)
        @test parse_sparql_ask_xml(ask_true) == true
        @test parse_sparql_ask_xml(ask_false) == false
    end

    # ─── TSV round-trip ──────────────────────────────────────────────
    @testset "TSV round-trip" begin
        tsv_str = sparql_results_tsv(results; variables=vars)
        parsed_vars, parsed_results = parse_sparql_results_tsv(tsv_str)

        @test parsed_vars == vars
        @test length(parsed_results) == 2

        @test parsed_results[1]["s"] == URIRef("http://example.org/alice")
        @test parsed_results[1]["name"] == Literal("Alice")
        @test parsed_results[1]["age"] == Literal("30", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))

        @test parsed_results[2]["name"] == Literal("Bob", lang="en")
    end

    # ─── CSV round-trip ──────────────────────────────────────────────
    @testset "CSV round-trip" begin
        csv_str = sparql_results_csv(results; variables=vars)
        parsed_vars, parsed_results = parse_sparql_results_csv(csv_str)

        @test parsed_vars == vars
        @test length(parsed_results) == 2

        # CSV is lossy: URIs are recognized by scheme prefix
        @test parsed_results[1]["s"] == URIRef("http://example.org/alice")
        # CSV loses datatype info — plain literal
        @test parsed_results[1]["name"] == Literal("Alice")
    end

    # ─── Hand-crafted JSON ───────────────────────────────────────────
    @testset "Hand-crafted JSON" begin
        json = """
        {
          "head": {"vars": ["x", "y"]},
          "results": {
            "bindings": [
              {
                "x": {"type": "uri", "value": "http://example.org/thing"},
                "y": {"type": "literal", "value": "hello", "xml:lang": "en"}
              },
              {
                "x": {"type": "bnode", "value": "b0"},
                "y": {"type": "literal", "value": "42", "datatype": "http://www.w3.org/2001/XMLSchema#integer"}
              }
            ]
          }
        }
        """
        parsed_vars, parsed_results = parse_sparql_results_json(json)
        @test parsed_vars == ["x", "y"]
        @test length(parsed_results) == 2
        @test parsed_results[1]["x"] == URIRef("http://example.org/thing")
        @test parsed_results[1]["y"] == Literal("hello", lang="en")
        @test parsed_results[2]["x"] == BNode("b0")
        @test parsed_results[2]["y"] == Literal("42", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))
    end

    # ─── Hand-crafted XML ────────────────────────────────────────────
    @testset "Hand-crafted XML" begin
        xml = """<?xml version="1.0"?>
        <sparql xmlns="http://www.w3.org/2005/sparql-results#">
          <head>
            <variable name="x"/>
            <variable name="y"/>
          </head>
          <results>
            <result>
              <binding name="x"><uri>http://example.org/thing</uri></binding>
              <binding name="y"><literal xml:lang="en">hello</literal></binding>
            </result>
            <result>
              <binding name="x"><bnode>b0</bnode></binding>
              <binding name="y"><literal datatype="http://www.w3.org/2001/XMLSchema#integer">42</literal></binding>
            </result>
          </results>
        </sparql>
        """
        parsed_vars, parsed_results = parse_sparql_results_xml(xml)
        @test parsed_vars == ["x", "y"]
        @test length(parsed_results) == 2
        @test parsed_results[1]["x"] == URIRef("http://example.org/thing")
        @test parsed_results[1]["y"] == Literal("hello", lang="en")
        @test parsed_results[2]["x"] == BNode("b0")
        @test parsed_results[2]["y"] == Literal("42", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))
    end

    # ─── Empty results ───────────────────────────────────────────────
    @testset "Empty results" begin
        empty_results = Dict{String, RDFLib.Identifier}[]

        json_str = sparql_results_json(empty_results; variables=["x"])
        v, r = parse_sparql_results_json(json_str)
        @test v == ["x"]
        @test isempty(r)

        xml_str = sparql_results_xml(empty_results; variables=["x"])
        v, r = parse_sparql_results_xml(xml_str)
        @test v == ["x"]
        @test isempty(r)
    end

    # ─── Blank node handling ─────────────────────────────────────────
    @testset "Blank nodes" begin
        bn_results = [
            Dict{String, RDFLib.Identifier}("x" => BNode("node1"))
        ]

        json_str = sparql_results_json(bn_results; variables=["x"])
        _, parsed = parse_sparql_results_json(json_str)
        @test parsed[1]["x"] == BNode("node1")

        xml_str = sparql_results_xml(bn_results; variables=["x"])
        _, parsed = parse_sparql_results_xml(xml_str)
        @test parsed[1]["x"] == BNode("node1")
    end

    # ─── Unbound variables (sparse bindings) ─────────────────────────
    @testset "Unbound variables" begin
        sparse = [
            Dict{String, RDFLib.Identifier}("x" => URIRef("http://example.org/a")),
            Dict{String, RDFLib.Identifier}("x" => URIRef("http://example.org/b"), "y" => Literal("val"))
        ]

        json_str = sparql_results_json(sparse; variables=["x", "y"])
        v, r = parse_sparql_results_json(json_str)
        @test length(r) == 2
        @test haskey(r[1], "x")
        @test !haskey(r[1], "y")
        @test haskey(r[2], "y")
    end

    # ─── Special characters ──────────────────────────────────────────
    @testset "Special characters in literals" begin
        special_results = [
            Dict{String, RDFLib.Identifier}(
                "x" => Literal("line1\nline2"),
                "y" => Literal("she said \"hi\"")
            )
        ]

        # JSON round-trip with special chars
        json_str = sparql_results_json(special_results; variables=["x", "y"])
        _, parsed = parse_sparql_results_json(json_str)
        @test parsed[1]["x"].lexical == "line1\nline2"
        @test parsed[1]["y"].lexical == "she said \"hi\""

        # XML round-trip with special chars
        xml_str = sparql_results_xml(special_results; variables=["x", "y"])
        _, parsed = parse_sparql_results_xml(xml_str)
        @test parsed[1]["x"].lexical == "line1\nline2"
        @test parsed[1]["y"].lexical == "she said \"hi\""
    end
end
