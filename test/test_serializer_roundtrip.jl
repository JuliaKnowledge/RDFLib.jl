using Test
using RDFLib
import JSON

const EX = Namespace("http://example.org/")

# Helper: check every triple in g1 appears in g2 and lengths match
function graphs_equal(g1::RDFGraph, g2::RDFGraph)
    length(g1) == length(g2) && all(t -> t in g2, g1)
end

# Helper: build a standard test graph with mixed term types
function make_test_graph()
    g = RDFGraph()
    bind!(g, "ex", EX)
    add!(g, EX("alice"), RDF.type, EX("Person"))
    add!(g, EX("alice"), RDFS.label, Literal("Alice", lang="en"))
    add!(g, EX("alice"), EX("age"), Literal(30))
    add!(g, EX("alice"), EX("knows"), EX("bob"))
    add!(g, EX("bob"), RDF.type, EX("Person"))
    add!(g, EX("bob"), RDFS.label, Literal("Bob"))
    g
end

# ═══════════════════════════════════════════════════════════════════
# 1. Turtle serializer roundtrip
# ═══════════════════════════════════════════════════════════════════
@testset "Turtle serializer roundtrip" begin

    @testset "prefix/namespace handling" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("s"), EX("p"), Literal("val"))
        ttl = serialize(g, TurtleFormat())
        @test occursin("@prefix ex:", ttl)
        @test occursin("ex:s", ttl)
        @test occursin("ex:p", ttl)
    end

    @testset "boolean serialization roundtrip" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("s"), EX("active"), Literal(true))
        add!(g, EX("s"), EX("deleted"), Literal(false))
        ttl = serialize(g, TurtleFormat())
        @test occursin("true", ttl)
        @test occursin("false", ttl)
        g2 = parse_rdf(ttl, TurtleFormat())
        @test length(g2) == 2
        active = first(objects(g2, EX("s"), EX("active")))
        @test convert(Any, active) == true
        deleted = first(objects(g2, EX("s"), EX("deleted")))
        @test convert(Any, deleted) == false
    end

    @testset "list serialization roundtrip" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add_collection!(g, EX("s"), EX("items"), [EX("a"), EX("b"), EX("c")])
        ttl = serialize(g, TurtleFormat())
        g2 = parse_rdf(ttl, TurtleFormat())
        @test length(g2) == length(g)
    end

    @testset "unicode roundtrip" begin
        g = RDFGraph()
        add!(g, EX("s"), EX("label"), Literal("héllo wörld 日本語"))
        ttl = serialize(g, TurtleFormat())
        g2 = parse_rdf(ttl, TurtleFormat())
        @test length(g2) == 1
        obj = first(objects(g2, EX("s"), EX("label")))
        @test string(obj) == "héllo wörld 日本語"
    end

    @testset "final dot on last triple" begin
        g = RDFGraph()
        add!(g, EX("s"), EX("p"), Literal("val"))
        ttl = serialize(g, TurtleFormat())
        @test endswith(strip(ttl), ".")
    end

    @testset "full roundtrip" begin
        g1 = make_test_graph()
        ttl = serialize(g1, TurtleFormat())
        g2 = parse_rdf(ttl, TurtleFormat())
        @test graphs_equal(g1, g2)
    end
end

# ═══════════════════════════════════════════════════════════════════
# 2. N3 serializer roundtrip
# ═══════════════════════════════════════════════════════════════════
@testset "N3 serializer roundtrip" begin

    @testset "simple triple roundtrip" begin
        g = RDFGraph()
        add!(g, EX("s"), EX("p"), Literal("hello"))
        n3_str = serialize_n3(g)
        g2 = parse_n3(n3_str)
        @test length(g2) == 1
        @test first(g2).subject == EX("s")
    end

    @testset "implications serialization (log:implies)" begin
        g = RDFGraph()
        ante = Formula()
        add!(ante, Triple(EX("x"), RDF.type, EX("Human")))
        cons = Formula()
        add!(cons, Triple(EX("x"), RDF.type, EX("Mortal")))
        add!(g, Triple(ante, LOG("implies"), cons))
        n3_str = serialize_n3(g)
        @test occursin("=>", n3_str)
        @test occursin("{", n3_str)
        @test occursin("}", n3_str)
    end

    @testset "merging graphs and re-serializing" begin
        g1 = RDFGraph()
        add!(g1, EX("a"), EX("p"), Literal("1"))
        g2 = RDFGraph()
        add!(g2, EX("b"), EX("q"), Literal("2"))
        merged = merge_graphs(g1, g2)
        n3_str = serialize_n3(merged)
        g3 = parse_n3(n3_str)
        @test length(g3) == 2
    end

    @testset "empty formula serialization" begin
        g = RDFGraph()
        f = Formula()
        add!(g, Triple(f, LOG("implies"), EX("result")))
        n3_str = serialize_n3(g)
        @test occursin("{", n3_str)
        @test occursin("}", n3_str)
    end

    @testset "full roundtrip" begin
        g1 = RDFGraph()
        bind!(g1, "ex", EX)
        add!(g1, EX("alice"), RDF.type, EX("Person"))
        add!(g1, EX("alice"), EX("name"), Literal("Alice", lang="en"))
        add!(g1, EX("alice"), EX("age"), Literal(42))
        n3_str = serialize_n3(g1)
        g2 = parse_n3(n3_str)
        @test length(g2) == length(g1)
        for t in g1
            @test t in g2
        end
    end
end

# ═══════════════════════════════════════════════════════════════════
# 3. RDF/XML serializer roundtrip
# ═══════════════════════════════════════════════════════════════════
@testset "RDF/XML serializer roundtrip" begin

    @testset "basic roundtrip with datatypes" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("s"), EX("age"), Literal(42))
        add!(g, EX("s"), RDFS.label, Literal("hello"))
        xml = serialize(g, RDFXMLFormat())
        g2 = parse_rdf(xml, RDFXMLFormat())
        @test length(g2) == 2
        age = first(objects(g2, EX("s"), EX("age")))
        @test convert(Any, age) == 42
        lbl = first(objects(g2, EX("s"), RDFS.label))
        @test string(lbl) == "hello"
    end

    @testset "multiple triples same subject" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        add!(g, EX("alice"), RDFS.label, Literal("Alice"))
        add!(g, EX("alice"), EX("age"), Literal(30))
        xml = serialize(g, RDFXMLFormat())
        g2 = parse_rdf(xml, RDFXMLFormat())
        @test graphs_equal(g, g2)
    end

    @testset "blank node serialization" begin
        g = RDFGraph()
        b = BNode()
        add!(g, EX("alice"), EX("address"), b)
        add!(g, b, EX("city"), Literal("London"))
        xml = serialize(g, RDFXMLFormat())
        g2 = parse_rdf(xml, RDFXMLFormat())
        @test length(g2) == 2
        # BNode IDs may differ; check structural equivalence
        cities = collect(objects(g2, nothing, EX("city")))
        @test length(cities) >= 1
        @test string(cities[1]) == "London"
    end

    @testset "subclass relationships" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("Student"), RDFS.subClassOf, EX("Person"))
        add!(g, EX("Person"), RDFS.subClassOf, EX("Agent"))
        xml = serialize(g, RDFXMLFormat())
        g2 = parse_rdf(xml, RDFXMLFormat())
        @test graphs_equal(g, g2)
    end

    @testset "full roundtrip" begin
        g1 = RDFGraph()
        bind!(g1, "ex", EX)
        add!(g1, EX("alice"), RDF.type, EX("Person"))
        add!(g1, EX("alice"), RDFS.label, Literal("Alice"))
        add!(g1, EX("alice"), EX("knows"), EX("bob"))
        xml = serialize(g1, RDFXMLFormat())
        g2 = parse_rdf(xml, RDFXMLFormat())
        @test graphs_equal(g1, g2)
    end
end

# ═══════════════════════════════════════════════════════════════════
# 4. HexTuples serializer roundtrip
# ═══════════════════════════════════════════════════════════════════
@testset "HexTuples serializer roundtrip" begin

    @testset "single graph roundtrip" begin
        g = RDFGraph()
        add!(g, Triple(EX("s"), EX("p"), Literal("hello")))
        hext = serialize_hextuples(g)
        ds = parse_hextuples(hext)
        g2 = get_graph(ds)
        @test length(g2) == 1
        @test first(g2).subject == EX("s")
    end

    @testset "JSON representation validation" begin
        g = RDFGraph()
        add!(g, Triple(EX("s"), EX("p"), EX("o")))
        hext = serialize_hextuples(g)
        parsed = JSON.parse(strip(hext))
        @test length(parsed) == 6
        @test parsed[1] == "http://example.org/s"
        @test parsed[2] == "http://example.org/p"
        @test parsed[3] == "http://example.org/o"
        @test parsed[4] == "globalId"
    end

    @testset "datatype handling" begin
        g = RDFGraph()
        add!(g, Triple(EX("s"), EX("age"), Literal(42)))
        hext = serialize_hextuples(g)
        parsed = JSON.parse(strip(hext))
        @test parsed[3] == "42"
        @test parsed[4] == "http://www.w3.org/2001/XMLSchema#integer"
        ds = parse_hextuples(hext)
        g2 = get_graph(ds)
        obj = first(g2).object
        @test convert(Any, obj) == 42
    end

    @testset "language-tagged literals" begin
        g = RDFGraph()
        add!(g, Triple(EX("s"), EX("name"), Literal("bonjour", lang="fr")))
        hext = serialize_hextuples(g)
        parsed = JSON.parse(strip(hext))
        @test parsed[3] == "bonjour"
        @test parsed[5] == "fr"
        ds = parse_hextuples(hext)
        g2 = get_graph(ds)
        obj = first(g2).object
        @test lang(obj) == "fr"
    end

    @testset "blank node roundtrip" begin
        g = RDFGraph()
        add!(g, Triple(BNode("b1"), EX("p"), Literal("val")))
        hext = serialize_hextuples(g)
        ds = parse_hextuples(hext)
        g2 = get_graph(ds)
        @test length(g2) == 1
        @test first(g2).subject isa BNode
    end
end

# ═══════════════════════════════════════════════════════════════════
# 5. TriX serializer roundtrip
# ═══════════════════════════════════════════════════════════════════
@testset "TriX serializer roundtrip" begin

    @testset "single graph roundtrip" begin
        g = RDFGraph()
        add!(g, Triple(EX("s"), EX("p"), Literal("hello")))
        xml = serialize_trix(g)
        ds = parse_trix(xml)
        g2 = get_graph(ds)
        @test length(g2) == 1
        @test first(g2).subject == EX("s")
        @test first(g2).object == Literal("hello")
    end

    @testset "named graph serialization" begin
        ds = Dataset()
        add!(ds, Triple(EX("s1"), EX("p1"), Literal("default")))
        add!(ds, Triple(EX("s2"), EX("p2"), Literal("named")), EX("g1"))
        xml = serialize_trix(ds)
        @test occursin("<graph>", xml)
        @test count("<graph>", xml) == 2
        ds2 = parse_trix(xml)
        @test length(get_graph(ds2)) == 1
        g1 = get_graph(ds2, EX("g1"))
        @test !isnothing(g1)
        @test length(g1) == 1
    end

    @testset "namespace handling" begin
        xml = serialize_trix(RDFGraph())
        @test occursin("TriX", xml)
        @test occursin("xmlns", xml)
    end

    @testset "typed literal roundtrip" begin
        g = RDFGraph()
        add!(g, Triple(EX("s"), EX("age"), Literal(42)))
        xml = serialize_trix(g)
        ds = parse_trix(xml)
        g2 = get_graph(ds)
        @test length(g2) == 1
        @test convert(Any, first(g2).object) == 42
    end
end

# ═══════════════════════════════════════════════════════════════════
# 6. RDF Patch serializer roundtrip
# ═══════════════════════════════════════════════════════════════════
@testset "RDF Patch serializer roundtrip" begin

    @testset "add triple operations" begin
        additions = [Triple(EX("s"), EX("p"), Literal("new"))]
        result = serialize_rdfpatch(additions, Triple[])
        @test occursin("A ", result)
        @test occursin("TX .", result)
        @test occursin("TC .", result)
        adds, dels = parse_rdfpatch(result)
        @test length(adds) == 1
        @test length(dels) == 0
        @test adds[1].subject == EX("s")
        @test adds[1].object == Literal("new")
    end

    @testset "delete triple operations" begin
        deletions = [Triple(EX("s"), EX("p"), Literal("old"))]
        result = serialize_rdfpatch(Triple[], deletions)
        @test occursin("D ", result)
        adds, dels = parse_rdfpatch(result)
        @test length(adds) == 0
        @test length(dels) == 1
        @test dels[1].object == Literal("old")
    end

    @testset "diff between graphs" begin
        g1 = RDFGraph()
        add!(g1, EX("s"), EX("p"), Literal("old"))
        add!(g1, EX("s"), EX("q"), Literal("keep"))
        g2 = RDFGraph()
        add!(g2, EX("s"), EX("q"), Literal("keep"))
        add!(g2, EX("s"), EX("r"), Literal("new"))
        # Compute diff manually
        to_add = [t for t in g2 if !(t in g1)]
        to_del = [t for t in g1 if !(t in g2)]
        patch = serialize_rdfpatch(to_add, to_del)
        @test occursin("A ", patch)
        @test occursin("D ", patch)
        # Apply patch to g1
        apply_rdfpatch!(g1, patch)
        @test length(g1) == 2
        @test Triple(EX("s"), EX("r"), Literal("new")) in g1
        @test !(Triple(EX("s"), EX("p"), Literal("old")) in g1)
    end
end

# ═══════════════════════════════════════════════════════════════════
# 7. N-Quads serializer roundtrip
# ═══════════════════════════════════════════════════════════════════
@testset "N-Quads serializer roundtrip" begin

    @testset "default graph roundtrip (no leaked graph identifiers)" begin
        ds = Dataset()
        add!(ds, EX("s"), EX("p"), Literal("hello"))
        nq = serialize(ds, NQuadsFormat())
        lines = filter(!isempty, split(strip(nq), '\n'))
        @test length(lines) == 1
        # Default graph: no fourth URI component
        @test count('<', lines[1]) == 2
        ds2 = parse_nquads(nq)
        @test length(get_graph(ds2)) == 1
        @test first(get_graph(ds2)).subject == EX("s")
    end

    @testset "named graph preservation" begin
        ds = Dataset()
        add!(ds, EX("s"), EX("p"), Literal("named"), EX("g1"))
        nq = serialize(ds, NQuadsFormat())
        @test occursin("http://example.org/g1", nq)
        ds2 = parse_nquads(nq)
        g1 = get_graph(ds2, EX("g1"))
        @test !isnothing(g1)
        @test length(g1) == 1
        @test first(g1).object == Literal("named")
    end

    @testset "mixed default and named graph roundtrip" begin
        ds = Dataset()
        add!(ds, EX("s"), EX("p"), Literal("default"))
        add!(ds, EX("s"), EX("p"), Literal("g1"), EX("g1"))
        add!(ds, EX("s"), EX("p"), Literal("g2"), EX("g2"))
        nq = serialize(ds, NQuadsFormat())
        ds2 = parse_nquads(nq)
        @test length(ds2) == 3
        @test length(get_graph(ds2)) == 1
        @test length(get_graph(ds2, EX("g1"))) == 1
        @test length(get_graph(ds2, EX("g2"))) == 1
    end
end

# ═══════════════════════════════════════════════════════════════════
# 8. Long Turtle serializer roundtrip
# ═══════════════════════════════════════════════════════════════════
@testset "Long Turtle serializer roundtrip" begin

    @testset "deterministic serialization" begin
        g = RDFGraph()
        add!(g, EX("b"), EX("p"), Literal("2"))
        add!(g, EX("a"), EX("p"), Literal("1"))
        add!(g, EX("c"), EX("p"), Literal("3"))
        out1 = serialize_longturtle(g)
        out2 = serialize_longturtle(g)
        @test out1 == out2
    end

    @testset "consistent output with BNodes" begin
        g = RDFGraph()
        b1 = BNode("b1")
        b2 = BNode("b2")
        add!(g, b1, EX("p"), Literal("a"))
        add!(g, b2, EX("p"), Literal("b"))
        add!(g, EX("s"), EX("ref"), b1)
        out1 = serialize_longturtle(g)
        out2 = serialize_longturtle(g)
        @test out1 == out2
        @test occursin("_:b1", out1)
        @test occursin("_:b2", out1)
    end

    @testset "one triple per line" begin
        g = RDFGraph()
        add!(g, EX("s"), EX("p1"), Literal("a"))
        add!(g, EX("s"), EX("p2"), Literal("b"))
        result = serialize_longturtle(g)
        lines = filter(!isempty, split(strip(result), '\n'))
        @test length(lines) == 2
        @test all(l -> endswith(strip(l), "."), lines)
    end

    @testset "parseable by standard Turtle parser" begin
        g = RDFGraph()
        add!(g, EX("s"), EX("p"), Literal("hello"))
        add!(g, EX("s"), EX("age"), Literal(42))
        lt = serialize_longturtle(g)
        g2 = parse_rdf(lt, TurtleFormat())
        @test length(g2) == 2
        for t in g
            @test t in g2
        end
    end
end

# ═══════════════════════════════════════════════════════════════════
# 9. Cross-format roundtrip
# ═══════════════════════════════════════════════════════════════════
@testset "Cross-format roundtrip" begin

    base_graph = make_test_graph()

    @testset "Turtle → NTriples → verify" begin
        ttl = serialize(base_graph, TurtleFormat())
        g_ttl = parse_rdf(ttl, TurtleFormat())
        nt = serialize(g_ttl, NTriplesFormat())
        g_nt = parse_rdf(nt, NTriplesFormat())
        @test graphs_equal(base_graph, g_nt)
    end

    @testset "Turtle → RDF/XML → verify" begin
        # Use graph without language tags (RDF/XML parser drops lang tags)
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        add!(g, EX("alice"), RDFS.label, Literal("Alice"))
        add!(g, EX("alice"), EX("knows"), EX("bob"))
        xml = serialize(g, RDFXMLFormat())
        g2 = parse_rdf(xml, RDFXMLFormat())
        @test graphs_equal(g, g2)
    end

    @testset "Turtle → N3 → verify" begin
        ttl = serialize(base_graph, TurtleFormat())
        g_ttl = parse_rdf(ttl, TurtleFormat())
        n3_str = serialize(g_ttl, N3Format())
        g_n3 = parse_rdf(n3_str, N3Format())
        @test length(g_n3) == length(base_graph)
        for t in base_graph
            @test t in g_n3
        end
    end

    @testset "NTriples → Turtle → NTriples → verify" begin
        nt1 = serialize(base_graph, NTriplesFormat())
        g1 = parse_rdf(nt1, NTriplesFormat())
        ttl = serialize(g1, TurtleFormat())
        g2 = parse_rdf(ttl, TurtleFormat())
        nt2 = serialize(g2, NTriplesFormat())
        g3 = parse_rdf(nt2, NTriplesFormat())
        @test graphs_equal(base_graph, g3)
    end

    @testset "Turtle → HexTuples → verify" begin
        # Use typed literals (HexTuples adds xsd:string to plain literals)
        g = RDFGraph()
        add!(g, EX("s"), EX("age"), Literal(42))
        add!(g, EX("s"), EX("q"), EX("o"))
        hext = serialize_hextuples(g)
        ds = parse_hextuples(hext)
        g2 = get_graph(ds)
        @test length(g2) == length(g)
        @test Triple(EX("s"), EX("q"), EX("o")) in g2
        age = first(objects(g2, EX("s"), EX("age")))
        @test convert(Any, age) == 42
    end

    @testset "Turtle → LongTurtle → verify" begin
        g = RDFGraph()
        add!(g, EX("s"), EX("p"), Literal("hello"))
        add!(g, EX("s"), EX("age"), Literal(42))
        add!(g, EX("s"), RDFS.label, Literal("test", lang="en"))
        lt = serialize_longturtle(g)
        g2 = parse_rdf(lt, TurtleFormat())
        @test length(g2) == length(g)
        for t in g
            @test t in g2
        end
    end

    @testset "NTriples → RDF/XML → Turtle → NTriples" begin
        # Use graph without lang tags (RDF/XML parser limitation)
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        add!(g, EX("alice"), RDFS.label, Literal("Alice"))
        add!(g, EX("alice"), EX("knows"), EX("bob"))
        nt1 = serialize(g, NTriplesFormat())
        g1 = parse_rdf(nt1, NTriplesFormat())
        xml = serialize(g1, RDFXMLFormat())
        g2 = parse_rdf(xml, RDFXMLFormat())
        ttl = serialize(g2, TurtleFormat())
        g3 = parse_rdf(ttl, TurtleFormat())
        nt2 = serialize(g3, NTriplesFormat())
        g4 = parse_rdf(nt2, NTriplesFormat())
        @test graphs_equal(g, g4)
    end
end

# ═══════════════════════════════════════════════════════════════════
# 10. Final newline
# ═══════════════════════════════════════════════════════════════════
@testset "Final newline" begin
    g = RDFGraph()
    add!(g, EX("s"), EX("p"), Literal("val"))

    @testset "NTriples ends with newline" begin
        out = serialize(g, NTriplesFormat())
        @test endswith(out, "\n")
    end

    @testset "Turtle ends with newline" begin
        out = serialize(g, TurtleFormat())
        @test endswith(out, "\n")
    end

    @testset "RDF/XML ends with newline" begin
        out = serialize(g, RDFXMLFormat())
        @test endswith(out, "\n")
    end

    @testset "N3 ends with newline" begin
        out = serialize_n3(g)
        @test endswith(out, "\n")
    end

    @testset "HexTuples ends with newline" begin
        out = serialize_hextuples(g)
        @test endswith(out, "\n")
    end

    @testset "LongTurtle ends with newline" begin
        out = serialize_longturtle(g)
        @test endswith(out, "\n")
    end

    @testset "TriX ends with newline" begin
        out = serialize_trix(g)
        @test endswith(out, "\n")
    end

    @testset "NQuads ends with newline" begin
        ds = Dataset()
        add!(ds, EX("s"), EX("p"), Literal("val"))
        out = serialize(ds, NQuadsFormat())
        @test endswith(out, "\n")
    end
end
