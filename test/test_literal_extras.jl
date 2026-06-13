using Test
using RDFLib
using Dates

@testset "Literal Extras" begin

    # ─── 1. DateTime Literal Tests ──────────────────────────────────────
    @testset "DateTime Literals" begin
        @testset "Equality of datetime literals" begin
            dt = DateTime(2023, 6, 15, 14, 30, 0)
            l1 = Literal(dt)
            l2 = Literal(dt)
            @test l1 == l2
        end

        @testset "DateTime auto-typed as xsd:dateTime" begin
            dt = DateTime(2024, 3, 1, 12, 0, 0)
            l = Literal(dt)
            @test datatype(l) == XSD.dateTime
        end

        @testset "Convert datetime literal to Julia DateTime" begin
            dt = DateTime(2023, 1, 15, 10, 30, 0)
            l = Literal(dt)
            @test convert(Any, l) == dt
            @test convert(Any, l) == dt
        end

        @testset "Parse datetime with timezone Z" begin
            dt = parse_xsd_datetime("2023-01-15T10:30:00Z")
            @test dt == DateTime(2023, 1, 15, 10, 30, 0)
        end

        @testset "Parse datetime with offset" begin
            # Offsets are applied (normalized to UTC), not stripped
            dt = parse_xsd_datetime("2023-01-15T10:30:00+05:30")
            @test dt == DateTime(2023, 1, 15, 5, 0, 0)
            @test dt != parse_xsd_datetime("2023-01-15T10:30:00Z")
        end

        @testset "Parse datetime with fractional seconds" begin
            dt = parse_xsd_datetime("2023-01-15T10:30:00.500")
            @test dt == DateTime(2023, 1, 15, 10, 30, 0, 500)
        end

        @testset "Round-trip datetime through Literal" begin
            dt = DateTime(2024, 7, 4, 9, 15, 30)
            l = Literal(dt)
            @test convert(Any, l) == dt
            # Also test via xsd_literal
            l2 = xsd_literal(dt)
            @test parse_xsd_datetime(l2.lexical) == dt
        end

        @testset "Date literal" begin
            d = Date(2024, 1, 15)
            l = Literal(d)
            @test datatype(l) == XSD.date
            @test convert(Date, l) == d
        end
    end

    # ─── 2. Literal Construction Tests ──────────────────────────────────
    @testset "Literal Construction" begin
        @testset "Boolean literals from strings" begin
            # "true" / "false" as xsd:boolean
            l_true = Literal("true", datatype=XSD.boolean)
            l_false = Literal("false", datatype=XSD.boolean)
            @test convert(Any, l_true) == true
            @test convert(Any, l_false) == false

            # "1" / "0" as xsd:boolean
            l_one = Literal("1", datatype=XSD.boolean)
            l_zero = Literal("0", datatype=XSD.boolean)
            @test convert(Any, l_one) == true
            @test convert(Any, l_zero) == false
        end

        @testset "Boolean literal from Julia Bool" begin
            @test Literal(true).lexical == "true"
            @test Literal(false).lexical == "false"
            @test datatype(Literal(true)) == XSD.boolean
            @test datatype(Literal(false)) == XSD.boolean
        end

        @testset "Lang and datatype exclusivity" begin
            @test_throws ArgumentError Literal("hello", lang="en",
                datatype=XSD.string)
        end

        @testset "Auto-datatype from Julia types" begin
            @test datatype(Literal(42)) == XSD.integer
            @test datatype(Literal(3.14)) == XSD.double
            @test datatype(Literal(true)) == XSD.boolean
            @test datatype(Literal(false)) == XSD.boolean
            @test datatype(Literal(DateTime(2024, 1, 1))) == XSD.dateTime
            @test datatype(Literal(Date(2024, 1, 1))) == XSD.date
        end

        @testset "Literal lexical values" begin
            @test Literal(42).lexical == "42"
            @test Literal(-7).lexical == "-7"
            @test Literal(true).lexical == "true"
            @test Literal(false).lexical == "false"
        end

        @testset "Literal from string with explicit datatype" begin
            l = Literal("42", datatype=XSD.integer)
            @test convert(Any, l) == 42
            @test l.lexical == "42"
        end

        @testset "Backslash handling in strings" begin
            l = Literal("a\\b")
            @test l.lexical == "a\\b"
            @test occursin("\\\\", n3(l))  # escaped in N3
        end

        @testset "N3 representation with quotes" begin
            l = Literal("say \"hi\"")
            @test n3(l) == "\"say \\\"hi\\\"\""
        end

        @testset "N3 plain literal" begin
            l = Literal("hello")
            @test n3(l) == "\"hello\""
        end

        @testset "N3 language-tagged literal" begin
            l = Literal("bonjour", lang="fr")
            @test n3(l) == "\"bonjour\"@fr"
        end

        @testset "N3 typed literal" begin
            l = Literal("42", datatype=XSD.integer)
            @test n3(l) == "\"42\"^^<http://www.w3.org/2001/XMLSchema#integer>"
        end
    end

    # ─── 3. Term Comparison Tests ───────────────────────────────────────
    @testset "Term Comparisons" begin
        @testset "URIRef != Literal with same string" begin
            u = URIRef("http://example.org/x")
            l = Literal("http://example.org/x")
            @test u != l
        end

        @testset "Literal(\"1\") != 1" begin
            l = Literal("1")
            @test l != 1
        end

        @testset "Total ordering of term types" begin
            b = BNode("x")
            u = URIRef("http://example.org/x")
            l = Literal("x")
            v = Variable("x")
            @test b < u
            @test u < l
            @test l < v
            @test b < v
        end

        @testset "Literal equality with same value and type" begin
            l1 = Literal("42", datatype=XSD.integer)
            l2 = Literal("42", datatype=XSD.integer)
            @test l1 == l2
        end

        @testset "Literal inequality with different types" begin
            l1 = Literal("42", datatype=XSD.integer)
            l2 = Literal("42", datatype=XSD.string)
            @test l1 != l2
        end

        @testset "Language tag case insensitivity" begin
            l1 = Literal("hello", lang="en")
            l2 = Literal("hello", lang="EN")
            @test l1 == l2
        end
    end

    # ─── 4. Duration Literal Tests ──────────────────────────────────────
    @testset "Duration Literals" begin
        @testset "Create xsd:duration literal" begin
            l = Literal("P1Y2M3DT4H5M6S", datatype=XSD.duration)
            @test l.lexical == "P1Y2M3DT4H5M6S"
            @test datatype(l) == XSD.duration
        end

        @testset "Equality of equivalent durations" begin
            l1 = Literal("P1Y", datatype=XSD.duration)
            l2 = Literal("P1Y", datatype=XSD.duration)
            @test l1 == l2
        end

        @testset "N3 representation of duration" begin
            l = Literal("P1Y2M", datatype=XSD.duration)
            expected = "\"P1Y2M\"^^<http://www.w3.org/2001/XMLSchema#duration>"
            @test n3(l) == expected
        end
    end

    # ─── 5. HexBinary Tests ────────────────────────────────────────────
    @testset "HexBinary Literals" begin
        @testset "Create xsd:hexBinary literal" begin
            l = Literal("DEADBEEF", datatype=XSD.hexBinary)
            @test l.lexical == "DEADBEEF"
            @test datatype(l) == XSD.hexBinary
        end

        @testset "N3 representation of hexBinary" begin
            l = Literal("48656C6C6F", datatype=XSD.hexBinary)
            expected = "\"48656C6C6F\"^^<http://www.w3.org/2001/XMLSchema#hexBinary>"
            @test n3(l) == expected
        end

        @testset "HexBinary equality" begin
            l1 = Literal("FF00", datatype=XSD.hexBinary)
            l2 = Literal("FF00", datatype=XSD.hexBinary)
            @test l1 == l2
        end
    end

    # ─── 6. Normalized String and Token ─────────────────────────────────
    @testset "NormalizedString and Token Literals" begin
        @testset "Create xsd:normalizedString literal" begin
            l = Literal("hello world", datatype=XSD.normalizedString)
            @test l.lexical == "hello world"
            @test datatype(l) == XSD.normalizedString
        end

        @testset "N3 representation of normalizedString" begin
            l = Literal("hello world", datatype=XSD.normalizedString)
            expected = "\"hello world\"^^<http://www.w3.org/2001/XMLSchema#normalizedString>"
            @test n3(l) == expected
        end

        @testset "Create xsd:token literal" begin
            l = Literal("hello", datatype=XSD.token)
            @test l.lexical == "hello"
            @test datatype(l) == XSD.token
        end

        @testset "N3 representation of token" begin
            l = Literal("hello", datatype=XSD.token)
            expected = "\"hello\"^^<http://www.w3.org/2001/XMLSchema#token>"
            @test n3(l) == expected
        end
    end

    # ─── 7. Special Float Values ────────────────────────────────────────
    @testset "Special Float Values" begin
        @testset "Inf literal" begin
            l = Literal("INF", datatype=XSD.double)
            @test l.lexical == "INF"
            @test datatype(l) == XSD.double
        end

        @testset "-Inf literal" begin
            l = Literal("-INF", datatype=XSD.double)
            @test l.lexical == "-INF"
            @test datatype(l) == XSD.double
        end

        @testset "NaN literal" begin
            l = Literal("NaN", datatype=XSD.double)
            @test l.lexical == "NaN"
            @test datatype(l) == XSD.double
        end

        @testset "N3 of special floats" begin
            l_inf = Literal("INF", datatype=XSD.double)
            l_ninf = Literal("-INF", datatype=XSD.double)
            l_nan = Literal("NaN", datatype=XSD.double)
            @test n3(l_inf) == "\"INF\"^^<http://www.w3.org/2001/XMLSchema#double>"
            @test n3(l_ninf) == "\"-INF\"^^<http://www.w3.org/2001/XMLSchema#double>"
            @test n3(l_nan) == "\"NaN\"^^<http://www.w3.org/2001/XMLSchema#double>"
        end

        @testset "Literal from Julia Inf/NaN" begin
            l_inf = Literal(Inf)
            l_nan = Literal(NaN)
            @test datatype(l_inf) == XSD.double
            @test datatype(l_nan) == XSD.double
            # xsd:double requires INF/-INF/NaN lexicals (not Julia's Inf)
            @test l_inf.lexical == "INF"
            @test Literal(-Inf).lexical == "-INF"
            @test l_nan.lexical == "NaN"
            @test l_inf == Literal("INF", datatype=XSD.double)
            @test Literal(-Inf) == Literal("-INF", datatype=XSD.double)
        end

        @testset "Special float lexicals convert to values" begin
            @test convert(Any, Literal("INF", datatype=XSD.double)) == Inf
            @test convert(Any, Literal("-INF", datatype=XSD.double)) == -Inf
            @test isnan(convert(Any, Literal("NaN", datatype=XSD.double)))
        end
    end

    # ─── 9. RDF 1.1 simple literal ≡ xsd:string ────────────────────────
    @testset "Simple literal is xsd:string (RDF 1.1)" begin
        @testset "Equality, hash, set membership" begin
            @test Literal("a") == Literal("a", datatype=XSD.string)
            @test hash(Literal("a")) == hash(Literal("a", datatype=XSD.string))
            @test Literal("a", datatype=XSD.string) in Set([Literal("a")])
        end

        @testset "No ^^xsd:string in serialization" begin
            @test n3(Literal("a", datatype=XSD.string)) == "\"a\""
        end

        @testset "Graph round-trip: typed and plain are the same triple" begin
            g = RDFGraph()
            s = URIRef("http://example.org/s")
            p = URIRef("http://example.org/p")
            add!(g, Triple(s, p, Literal("a", datatype=XSD.string)))
            @test Triple(s, p, Literal("a")) in g
            add!(g, Triple(s, p, Literal("a")))
            @test length(g) == 1
        end

        @testset "DATATYPE() returns xsd:string for simple literals" begin
            g = RDFGraph()
            ex = Namespace("http://example.org/")
            add!(g, Triple(ex("a"), ex("val"), Literal("plain")))
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT (DATATYPE(?v) AS ?dt) WHERE { ex:a ex:val ?v . }
            """)
            @test length(results) == 1
            @test results[1]["dt"] == XSD.string
        end

        @testset "DATATYPE() returns rdf:langString for lang literals" begin
            g = RDFGraph()
            ex = Namespace("http://example.org/")
            add!(g, Triple(ex("a"), ex("val"), Literal("chat", lang="fr")))
            results = sparql_query(g, """
                PREFIX ex: <http://example.org/>
                SELECT (DATATYPE(?v) AS ?dt) WHERE { ex:a ex:val ?v . }
            """)
            @test length(results) == 1
            @test results[1]["dt"] == URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#langString")
        end
    end

    # ─── 10. Base direction (SPARQL 1.2) ────────────────────────────────
    @testset "Directional language-tagged literals" begin
        l = Literal("مرحبا", lang="ar", direction="rtl")
        @test direction(l) == "rtl"
        @test l == Literal("مرحبا", lang="ar", direction="rtl")
        @test l != Literal("مرحبا", lang="ar")
        @test_throws ArgumentError Literal("x", direction="ltr")
        @test_throws ArgumentError Literal("x", lang="en", direction="diagonal")
    end

    # ─── 8. Literal Arithmetic ──────────────────────────────────────────
    @testset "Literal Arithmetic" begin
        @testset "Adding two integer literals via convert" begin
            l1 = Literal(2)
            l2 = Literal(3)
            result = convert(Any, l1) + convert(Any, l2)
            @test result == 5
        end

        @testset "Adding integer + float via convert" begin
            l1 = Literal(2)
            l2 = Literal(3.0)
            result = convert(Any, l1) + convert(Any, l2)
            @test result == 5.0
            @test result isa Float64
        end

        @testset "Integer subtraction via convert" begin
            l1 = Literal(10)
            l2 = Literal(4)
            result = convert(Any, l1) - convert(Any, l2)
            @test result == 6
        end

        @testset "Multiplication via convert" begin
            l1 = Literal(3)
            l2 = Literal(7)
            result = convert(Any, l1) * convert(Any, l2)
            @test result == 21
        end

        @testset "Convert results back to Literal" begin
            l1 = Literal(2)
            l2 = Literal(3)
            sum_val = convert(Any, l1) + convert(Any, l2)
            result_lit = Literal(sum_val)
            @test convert(Any, result_lit) == 5
            @test datatype(result_lit) == XSD.integer
        end

        @testset "Float arithmetic result type" begin
            l1 = Literal(1.5)
            l2 = Literal(2.5)
            result = convert(Any, l1) + convert(Any, l2)
            @test result == 4.0
            result_lit = Literal(result)
            @test datatype(result_lit) == XSD.double
        end
    end

end
