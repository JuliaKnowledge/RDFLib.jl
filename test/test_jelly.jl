@testset "Jelly RDF Format" begin
    function benchmark_fixture_graph(n::Int)
        g = RDFGraph()
        for i in 1:n
            s = URIRef("http://example.org/node$i")
            add!(g, Triple(s, URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"),
                           URIRef("http://xmlns.com/foaf/0.1/Person")))
            add!(g, Triple(s, URIRef("http://xmlns.com/foaf/0.1/name"),
                           Literal("Person $i")))
            add!(g, Triple(s, URIRef("http://xmlns.com/foaf/0.1/age"),
                           Literal(string(20 + i % 60),
                                   datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))))
            if i > 1
                add!(g, Triple(s, URIRef("http://xmlns.com/foaf/0.1/knows"),
                               URIRef("http://example.org/node$(i-1)")))
            end
        end
        g
    end

    @testset "Basic round-trip" begin
        g = RDFGraph()
        add!(g, Triple(URIRef("http://example.org/alice"), URIRef("http://xmlns.com/foaf/0.1/name"), Literal("Alice")))
        add!(g, Triple(URIRef("http://example.org/alice"), URIRef("http://xmlns.com/foaf/0.1/age"), Literal("30", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))))
        add!(g, Triple(URIRef("http://example.org/alice"), URIRef("http://xmlns.com/foaf/0.1/knows"), URIRef("http://example.org/bob")))
        add!(g, Triple(URIRef("http://example.org/bob"), URIRef("http://xmlns.com/foaf/0.1/name"), Literal("Bob", lang="en")))
        add!(g, Triple(BNode("x1"), URIRef("http://xmlns.com/foaf/0.1/name"), Literal("Unknown")))

        data = serialize_jelly(g)
        @test length(data) > 0
        @test data isa Vector{UInt8}

        g2 = parse_jelly(data)
        @test length(g2) == length(g)
        for t in triples(g)
            @test t in g2
        end
    end

    @testset "Empty graph" begin
        g = RDFGraph()
        data = serialize_jelly(g)
        g2 = parse_jelly(data)
        @test length(g2) == 0
    end

    @testset "Literals" begin
        g = RDFGraph()
        ex = URIRef("http://example.org/s")
        p = URIRef("http://example.org/p")

        # Plain literal
        add!(g, Triple(ex, p, Literal("hello")))
        # Language-tagged
        add!(g, Triple(ex, URIRef("http://example.org/p2"), Literal("bonjour", lang="fr")))
        # Typed literals
        add!(g, Triple(ex, URIRef("http://example.org/p3"), Literal("42", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))))
        add!(g, Triple(ex, URIRef("http://example.org/p4"), Literal("3.14", datatype=URIRef("http://www.w3.org/2001/XMLSchema#decimal"))))
        add!(g, Triple(ex, URIRef("http://example.org/p5"), Literal("true", datatype=URIRef("http://www.w3.org/2001/XMLSchema#boolean"))))

        data = serialize_jelly(g)
        g2 = parse_jelly(data)
        @test length(g2) == 5

        # Check literal types preserved
        for t in triples(g)
            @test t in g2
        end

        # Verify specific literal properties
        for t in triples(g2, (ex, URIRef("http://example.org/p2"), nothing))
            @test t.object isa Literal
            @test t.object.language == "fr"
        end
        for t in triples(g2, (ex, URIRef("http://example.org/p3"), nothing))
            @test t.object.datatype == URIRef("http://www.w3.org/2001/XMLSchema#integer")
        end
    end

    @testset "Blank nodes" begin
        g = RDFGraph()
        b1 = BNode("b1")
        b2 = BNode("b2")
        add!(g, Triple(b1, URIRef("http://example.org/p"), b2))
        add!(g, Triple(b2, URIRef("http://example.org/q"), Literal("val")))

        data = serialize_jelly(g)
        g2 = parse_jelly(data)
        @test length(g2) == 2

        # BNode subjects and objects preserved
        bnode_subjects = [t.subject for t in triples(g2) if t.subject isa BNode]
        @test length(bnode_subjects) == 2
    end

    @testset "Many IRIs (prefix compression)" begin
        g = RDFGraph()
        for i in 1:50
            add!(g, Triple(
                URIRef("http://example.org/node$i"),
                URIRef("http://xmlns.com/foaf/0.1/name"),
                Literal("Node $i")
            ))
        end

        data = serialize_jelly(g)
        nt_data = serialize(g, NTriplesFormat())

        # Jelly should be significantly smaller than NTriples due to prefix compression
        @test length(data) < length(nt_data)

        g2 = parse_jelly(data)
        @test length(g2) == 50
    end

    @testset "Repeated term optimization" begin
        g = RDFGraph()
        s = URIRef("http://example.org/subject")
        for i in 1:20
            add!(g, Triple(s, URIRef("http://example.org/p$i"), Literal("val$i")))
        end

        data = serialize_jelly(g)
        g2 = parse_jelly(data)
        @test length(g2) == 20

        # All triples should have the same subject
        for t in triples(g2)
            @test t.subject == s
        end
    end

    @testset "File I/O" begin
        g = RDFGraph()
        add!(g, Triple(URIRef("http://example.org/a"), URIRef("http://example.org/b"), URIRef("http://example.org/c")))
        add!(g, Triple(URIRef("http://example.org/a"), URIRef("http://example.org/d"), Literal("test")))

        tmpf = tempname() * ".jelly"
        serialize_jelly_to_file(g, tmpf)
        @test isfile(tmpf)
        @test filesize(tmpf) > 0

        g2 = parse_jelly_file(tmpf)
        @test length(g2) == 2
        for t in triples(g)
            @test t in g2
        end
        rm(tmpf)
    end

    @testset "parse_jelly! into existing graph" begin
        g = RDFGraph()
        add!(g, Triple(URIRef("http://example.org/existing"), URIRef("http://example.org/p"), Literal("pre")))

        g2 = RDFGraph()
        add!(g2, Triple(URIRef("http://example.org/new"), URIRef("http://example.org/q"), Literal("post")))
        data = serialize_jelly(g2)

        parse_jelly!(g, data)
        @test length(g) == 2
    end

    @testset "Large graph" begin
        g = RDFGraph()
        for i in 1:1000
            add!(g, Triple(
                URIRef("http://example.org/s$i"),
                URIRef("http://example.org/p"),
                Literal("value $i")
            ))
        end

        data = serialize_jelly(g)
        g2 = parse_jelly(data)
        @test length(g2) == 1000
    end

    @testset "Multiple datatypes" begin
        g = RDFGraph()
        ex = URIRef("http://example.org/s")
        xsd = "http://www.w3.org/2001/XMLSchema#"

        types = ["integer", "decimal", "boolean", "date", "dateTime", "float", "double"]
        for (i, dt) in enumerate(types)
            add!(g, Triple(ex, URIRef("http://example.org/p$i"),
                          Literal("val", datatype=URIRef(xsd * dt))))
        end

        data = serialize_jelly(g)
        g2 = parse_jelly(data)
        @test length(g2) == length(types)

        # Verify datatype diversity preserved
        dts = Set{URIRef}()
        for t in triples(g2)
            t.object isa Literal && t.object.datatype !== nothing && push!(dts, t.object.datatype)
        end
        @test length(dts) == length(types)
    end

    @testset "Unicode content" begin
        g = RDFGraph()
        add!(g, Triple(URIRef("http://example.org/s"), URIRef("http://example.org/p"),
                       Literal("日本語テスト")))
        add!(g, Triple(URIRef("http://example.org/s"), URIRef("http://example.org/q"),
                       Literal("émojis: 🎉🌍")))

        data = serialize_jelly(g)
        g2 = parse_jelly(data)
        @test length(g2) == 2

        vals = Set(t.object.lexical for t in triples(g2))
        @test "日本語テスト" in vals
        @test "émojis: 🎉🌍" in vals
    end

    @testset "Encoder options" begin
        g = RDFGraph()
        for i in 1:10
            add!(g, Triple(URIRef("http://example.org/s$i"), URIRef("http://example.org/p"), Literal("v$i")))
        end

        # Custom lookup table sizes
        data1 = serialize_jelly(g; max_names=64, max_prefixes=8, max_datatypes=8)
        data2 = serialize_jelly(g; max_names=256, max_prefixes=32, max_datatypes=32)

        g1 = parse_jelly(data1)
        g2 = parse_jelly(data2)
        @test length(g1) == 10
        @test length(g2) == 10
    end

    @testset "Cross-language interop fixture from pyjelly" begin
        fixture = joinpath(@__DIR__, "..", "benchmarks", "results", "jelly", "python_n100.jelly")
        @test isfile(fixture)
        expected = benchmark_fixture_graph(100)
        g_from_py = parse_jelly_file(fixture)
        @test length(g_from_py) == length(expected)
        for t in triples(expected)
            @test t in g_from_py
        end
    end

    @testset "Cross-language interop with live pyjelly" begin
        python = joinpath(@__DIR__, "..", ".venv", "bin", "python3")
        if isfile(python)
            # Generate Jelly from Python
            tmpdir = mktempdir()
            py_file = joinpath(tmpdir, "py_out.jelly")
            jl_file = joinpath(tmpdir, "jl_out.jelly")

            py_script = """
from pyjelly.integrations.rdflib import register_extension_to_rdflib
register_extension_to_rdflib()
from rdflib import Graph, URIRef, Literal, Namespace
from rdflib.namespace import RDF, FOAF, XSD
import io

g = Graph()
EX = Namespace('http://example.org/')
g.add((EX.a, RDF.type, FOAF.Person))
g.add((EX.a, FOAF.name, Literal('Alice')))
g.add((EX.a, FOAF.age, Literal('30', datatype=XSD.integer)))
g.add((EX.a, FOAF.knows, EX.b))
g.add((EX.b, FOAF.name, Literal('Bob', lang='en')))

buf = io.BytesIO()
g.serialize(destination=buf, format='jelly')
with open('$py_file', 'wb') as f:
    f.write(buf.getvalue())
print(len(g))
"""
            py_count = parse(Int, strip(read(`$python -c $py_script`, String)))

            # Julia reads Python's Jelly
            g_from_py = parse_jelly_file(py_file)
            @test length(g_from_py) == py_count

            # Julia writes Jelly, Python reads
            g_jl = RDFGraph()
            add!(g_jl, Triple(URIRef("http://example.org/x"), URIRef("http://example.org/p"), Literal("test")))
            add!(g_jl, Triple(URIRef("http://example.org/x"), URIRef("http://example.org/q"), Literal("42", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))))
            serialize_jelly_to_file(g_jl, jl_file)

            py_verify = """
from pyjelly.integrations.rdflib import register_extension_to_rdflib
register_extension_to_rdflib()
from rdflib import Graph
g = Graph()
g.parse('$jl_file', format='jelly')
print(len(g))
"""
            py_parsed = parse(Int, strip(read(`$python -c $py_verify`, String)))
            @test py_parsed == length(g_jl)

            rm(tmpdir, recursive=true)
        else
            @info "Skipping live pyjelly roundtrip; checked-in pyjelly fixture covers interoperability"
        end
    end
end
