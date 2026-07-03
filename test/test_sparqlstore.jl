@testset "SPARQLStore" begin
    @testset "construction" begin
        store = SPARQLStore("https://dbpedia.org/sparql")
        @test store.endpoint == "https://dbpedia.org/sparql"
        @test isnothing(store.default_graph)
        @test store.timeout == 30
    end

    @testset "construction with default graph" begin
        store = SPARQLStore("https://example.org/sparql",
                            default_graph="http://example.org/graph1")
        @test store.default_graph == "http://example.org/graph1"
    end

    @testset "construction with timeout" begin
        store = SPARQLStore("https://example.org/sparql", timeout=60)
        @test store.timeout == 60
    end

    @testset "read-only" begin
        store = SPARQLStore("https://example.org/sparql")
        EX = Namespace("http://example.org/")
        @test_throws ErrorException add!(store, Triple(EX("s"), EX("p"), EX("o")))
        @test_throws ErrorException remove!(store, (EX("s"), nothing, nothing))
    end

    @testset "pattern to SPARQL" begin
        EX = Namespace("http://example.org/")

        # Subject bound
        q1 = RDFLib._sparql_pattern_query((EX("s"), nothing, nothing))
        @test occursin("<http://example.org/s>", q1)
        @test occursin("?p", q1)
        @test occursin("?o", q1)
        @test startswith(q1, "SELECT")

        # Predicate bound
        q2 = RDFLib._sparql_pattern_query((nothing, EX("p"), nothing))
        @test occursin("?s", q2)
        @test occursin("<http://example.org/p>", q2)
        @test occursin("?o", q2)

        # All wildcard
        q3 = RDFLib._sparql_pattern_query((nothing, nothing, nothing))
        @test occursin("?s", q3)
        @test occursin("?p", q3)
        @test occursin("?o", q3)

        # Object bound with literal
        q4 = RDFLib._sparql_pattern_query((nothing, nothing, Literal("hello")))
        @test occursin("\"hello\"", q4)
        @test occursin("?s", q4)
        @test occursin("?p", q4)

        # All bound
        q5 = RDFLib._sparql_pattern_query((EX("s"), EX("p"), EX("o")))
        @test occursin("<http://example.org/s>", q5)
        @test occursin("<http://example.org/p>", q5)
        @test occursin("<http://example.org/o>", q5)
    end

    @testset "URL encoding" begin
        encoded = RDFLib._url_encode("SELECT ?s WHERE { ?s ?p ?o }")
        @test !occursin(' ', encoded)
        @test occursin("SELECT", encoded)
        # Special chars are percent-encoded
        @test occursin("%20", encoded) || occursin("%7B", encoded)
    end

    @testset "parse SPARQL JSON results" begin
        json_str = """
        {
            "results": {
                "bindings": [
                    {
                        "s": {"type": "uri", "value": "http://example.org/alice"},
                        "p": {"type": "uri", "value": "http://example.org/name"},
                        "o": {"type": "literal", "value": "Alice"}
                    },
                    {
                        "s": {"type": "uri", "value": "http://example.org/bob"},
                        "p": {"type": "uri", "value": "http://example.org/name"},
                        "o": {"type": "literal", "value": "Bob", "xml:lang": "en"}
                    }
                ]
            }
        }
        """
        triples_vec = RDFLib._parse_sparql_json_results(json_str)
        @test length(triples_vec) == 2
        @test triples_vec[1].subject == URIRef("http://example.org/alice")
        @test triples_vec[1].predicate == URIRef("http://example.org/name")
        @test triples_vec[1].object == Literal("Alice")
        @test triples_vec[2].subject == URIRef("http://example.org/bob")
        @test triples_vec[2].object.language == "en"
    end

    @testset "parse SPARQL JSON - typed literal" begin
        json_str = """
        {
            "results": {
                "bindings": [
                    {
                        "s": {"type": "uri", "value": "http://example.org/x"},
                        "p": {"type": "uri", "value": "http://example.org/age"},
                        "o": {"type": "typed-literal", "value": "42", "datatype": "http://www.w3.org/2001/XMLSchema#integer"}
                    }
                ]
            }
        }
        """
        triples_vec = RDFLib._parse_sparql_json_results(json_str)
        @test length(triples_vec) == 1
        @test triples_vec[1].object.datatype == URIRef("http://www.w3.org/2001/XMLSchema#integer")
        @test triples_vec[1].object.lexical == "42"
    end

    @testset "parse SPARQL JSON - directional literal" begin
        json_str = """
        {
            "results": {
                "bindings": [
                    {
                        "s": {"type": "uri", "value": "http://example.org/x"},
                        "p": {"type": "uri", "value": "http://example.org/label"},
                        "o": {"type": "literal", "value": "שלום", "xml:lang": "he", "its:dir": "rtl"}
                    }
                ]
            }
        }
        """
        triples_vec = RDFLib._parse_sparql_json_results(json_str)
        @test length(triples_vec) == 1
        @test triples_vec[1].object == Literal("שלום", lang="he", direction="rtl")
    end

    @testset "parse SPARQL JSON - blank node" begin
        json_str = """
        {
            "results": {
                "bindings": [
                    {
                        "s": {"type": "bnode", "value": "b0"},
                        "p": {"type": "uri", "value": "http://example.org/p"},
                        "o": {"type": "uri", "value": "http://example.org/o"}
                    }
                ]
            }
        }
        """
        triples_vec = RDFLib._parse_sparql_json_results(json_str)
        @test length(triples_vec) == 1
        @test triples_vec[1].subject isa BNode
        @test triples_vec[1].subject.id == "b0"
    end

    @testset "parse SPARQL JSON - with pattern fill-in" begin
        EX = Namespace("http://example.org/")
        json_str = """
        {
            "results": {
                "bindings": [
                    {
                        "p": {"type": "uri", "value": "http://example.org/name"},
                        "o": {"type": "literal", "value": "Alice"}
                    }
                ]
            }
        }
        """
        pattern = (EX("alice"), nothing, nothing)
        triples_vec = RDFLib._parse_sparql_json_results(json_str, pattern)
        @test length(triples_vec) == 1
        @test triples_vec[1].subject == EX("alice")
        @test triples_vec[1].predicate == EX("name")
        @test triples_vec[1].object == Literal("Alice")
    end

    @testset "parse SPARQL JSON - empty results" begin
        json_str = """
        {
            "results": {
                "bindings": []
            }
        }
        """
        triples_vec = RDFLib._parse_sparql_json_results(json_str)
        @test isempty(triples_vec)
    end

    @testset "SPARQL term serialization" begin
        @test RDFLib._sparql_term(URIRef("http://example.org/x")) == "<http://example.org/x>"
        @test RDFLib._sparql_term(BNode("b0")) == "_:b0"
        @test RDFLib._sparql_term(Literal("hello")) == "\"hello\""
        @test RDFLib._sparql_term(Literal("hi", lang="en")) == "\"hi\"@en"
        @test RDFLib._sparql_term(Literal("שלום", lang="he", direction="rtl")) == "\"שלום\"@he--rtl"
        dt = URIRef("http://www.w3.org/2001/XMLSchema#integer")
        @test RDFLib._sparql_term(Literal("42", datatype=dt)) == "\"42\"^^<http://www.w3.org/2001/XMLSchema#integer>"
        @test occursin("\\\"", RDFLib._sparql_term(Literal("a\" . ?s ?p ?o")))
        @test_throws ArgumentError RDFLib._sparql_term(URIRef("http://example.org/bad space"))
    end
end
