using Test
using RDFLib

@testset "TriG" begin
    EX = Namespace("http://example.org/")

    @testset "serialization" begin
        ds = Dataset()
        bind!(ds, "ex", EX)
        add!(ds, EX("s"), EX("p"), Literal("default"))
        add!(ds, EX("s"), EX("p"), Literal("named"), EX("g1"))
        trig = serialize(ds, TriGFormat())

        @test contains(trig, "@prefix")
        @test contains(trig, "{")
        @test contains(trig, "}")
        @test contains(trig, "\"default\"")
        @test contains(trig, "\"named\"")
    end

    @testset "serialization - graph name" begin
        ds = Dataset()
        bind!(ds, "ex", EX)
        add!(ds, EX("s"), RDF.type, EX("Thing"), EX("g1"))
        trig = serialize(ds, TriGFormat())
        @test contains(trig, "ex:g1") || contains(trig, "<http://example.org/g1>")
    end

    @testset "serialization - preserve xsd:double lexical form" begin
        ds = Dataset()
        bind!(ds, "ex", EX)
        double_dt = URIRef("http://www.w3.org/2001/XMLSchema#double")
        add!(ds, EX("s"), EX("score"), Literal("88.0", datatype=double_dt))

        trig = serialize(ds, TriGFormat())
        @test contains(trig, "\"88.0\"^^")
        @test !contains(trig, "88.0e0")

        ds2 = parse_trig(trig)
        parsed = first(objects(get_graph(ds2), EX("s"), EX("score")))
        @test parsed == Literal("88.0", datatype=double_dt)
    end

    @testset "parsing" begin
        trig = """
        @prefix ex: <http://example.org/> .

        {
            ex:s ex:p "default" .
        }

        ex:g1 {
            ex:s ex:p "named" .
        }
        """
        ds = parse_trig(trig)
        @test length(ds) == 2
        @test length(get_graph(ds)) == 1  # default graph
        @test length(get_graph(ds, EX("g1"))) == 1  # named graph
    end

    @testset "parsing - GRAPH keyword" begin
        trig = """
        @prefix ex: <http://example.org/> .

        GRAPH ex:g1 {
            ex:alice a ex:Person ;
                ex:name "Alice" .
        }
        """
        ds = parse_trig(trig)
        g1 = get_graph(ds, EX("g1"))
        @test !isnothing(g1)
        @test length(g1) == 2
    end

    @testset "parsing - multiple graphs" begin
        trig = """
        @prefix ex: <http://example.org/> .

        ex:g1 {
            ex:a ex:p "1" .
        }

        ex:g2 {
            ex:b ex:p "2" .
        }
        """
        ds = parse_trig(trig)
        @test length(ds) == 2
        @test length(get_graph(ds, EX("g1"))) == 1
        @test length(get_graph(ds, EX("g2"))) == 1
    end

    @testset "blank node graph labels" begin
        trig = """
        @prefix ex: <http://example.org/> .

        _:g1 {
            ex:s ex:p "in bnode graph" .
        }
        """
        ds = parse_trig(trig)
        g = get_graph(ds, BNode("g1"))
        @test !isnothing(g)
        @test length(g) == 1
        @test first(objects(g, EX("s"), EX("p"))) == Literal("in bnode graph")

        # serialization emits the _: label and round-trips
        out = serialize_trig(ds)
        @test contains(out, "_:g1")
        ds2 = parse_trig(out)
        g2 = get_graph(ds2, BNode("g1"))
        @test !isnothing(g2)
        @test length(g2) == 1
    end

    @testset "GRAPH keyword with blank node label" begin
        trig = """
        @prefix ex: <http://example.org/> .

        GRAPH _:g {
            ex:s ex:p "x" .
        }
        """
        ds = parse_trig(trig)
        g = get_graph(ds, BNode("g"))
        @test !isnothing(g)
        @test length(g) == 1
    end

    @testset "anonymous blank-node property-list subjects (no whitespace)" begin
        # Regression: this used to hang the parser forever (DoS).
        trig = "@prefix : <http://example/> .\n{[:p :o].[:p\"Alice\"].[:p _:o].}"
        ds = parse_trig(trig)               # must return, not hang
        @test length(collect(quads(ds))) == 3
    end

    @testset "collections inside anonymous property lists" begin
        # Regression: anon plists containing collections used to hang.
        trig = "@prefix : <http://example/> .\n" *
               "{[:p(:o)].[:p(_:o)].[:p(\"Alice\")].[:p(<http://example/o>)].}"
        ds = parse_trig(trig)               # must return, not hang
        # 4 plist triples + 4 collection rdf:first + 4 rdf:rest = 12 quads
        @test length(collect(quads(ds))) == 12
    end

    @testset "minimal-whitespace directives" begin
        trig = "BASE<http://example/base>\n" *
               "PREFIX :<http://example/a/>\n" *
               "PREFIX b:<http://example/b/>\n" *
               "@prefix:<http://example/c/>.\n" *
               ":s :p :o .b:s b:p b:o ."
        ds = parse_trig(trig)
        @test length(collect(quads(ds))) == 2
        # The empty prefix ':' is redeclared by '@prefix:<.../c/>.' (last wins).
        EXC = Namespace("http://example/c/")
        EXB = Namespace("http://example/b/")
        @test first(objects(get_graph(ds), EXC("s"), EXC("p"))) == EXC("o")
        @test first(objects(get_graph(ds), EXB("s"), EXB("p"))) == EXB("o")
    end

    @testset "empty-prefix subjects in graph blocks" begin
        trig = "@prefix : <http://example/> .\n:{: : :}{: : :}:{[]:[]}"
        ds = parse_trig(trig)               # must return, not hang
        @test length(collect(quads(ds))) == 3
        EXP = Namespace("http://example/")
        named = get_graph(ds, EXP(""))      # graph label ':'
        @test !isnothing(named)
    end

    @testset "minimal-whitespace W3C suite file" begin
        path = joinpath(@__DIR__, "w3c", "suite", "rdf", "rdf11",
                        "rdf-trig", "trig-syntax-minimal-whitespace-01.trig")
        if isfile(path)
            ds = parse_trig(read(path, String))   # must return, not hang
            @test length(collect(quads(ds))) == 47
        end
    end

    @testset "directional literals round-trip" begin
        ds = Dataset()
        bind!(ds, "ex", EX)
        add!(ds, EX("s"), EX("p"), Literal("hello", lang="en", direction="ltr"), EX("g1"))
        add!(ds, EX("s"), EX("q"), Literal("שלום", lang="he", direction="rtl"))

        trig = serialize_trig(ds)
        @test contains(trig, "@en--ltr")
        @test contains(trig, "@he--rtl")

        ds2 = parse_trig(trig)
        obj1 = first(objects(get_graph(ds2, EX("g1")), EX("s"), EX("p")))
        @test obj1 == Literal("hello", lang="en", direction="ltr")
        obj2 = first(objects(get_graph(ds2), EX("s"), EX("q")))
        @test obj2 == Literal("שלום", lang="he", direction="rtl")
    end

    @testset "escaped reserved chars in prefixed-name local part" begin
        # The brace scanner must not treat an escaped '#', '}', etc. inside a
        # prefixed name's local part as a comment or block terminator.
        trig = "@prefix : <http://example/> .\n" *
               "{:s :p :\\~\\.\\-\\!\\\$\\&\\'\\(\\)\\*\\+\\,\\;\\=\\/\\?\\#\\@\\_\\%AA .}"
        ds = parse_trig(trig)
        qs = collect(quads(ds))
        @test length(qs) == 1
        @test qs[1].subject == URIRef("http://example/s")
        @test qs[1].object == URIRef("http://example/~.-!\$&'()*+,;=/?#@_%AA")
    end

    @testset "trailing comment before closing brace (omitted final dot)" begin
        # The "needs trailing dot" heuristic must skip trailing comments so it
        # does not append a spurious '.' that lands inside the comment.
        trig = "@prefix : <http://example/> .\n{\n_:b.0 :p :o . # comment\n}"
        ds = parse_trig(trig)
        @test length(collect(quads(ds))) == 1
    end

    @testset "anonymous and labeled blank-node graph labels" begin
        EXP = Namespace("http://example/")
        ds = parse_trig("[] {<http://example/s> <http://example/p> <http://example/o> .}")
        qs = collect(quads(ds))
        @test length(qs) == 1
        @test qs[1].graph isa BNode

        ds2 = parse_trig("GRAPH [] { <http://example/s> <http://example/p> <http://example/o> }")
        @test length(collect(quads(ds2))) == 1
        @test collect(quads(ds2))[1].graph isa BNode

        ds3 = parse_trig("_:g {<http://example/s> <http://example/p> <http://example/o> .}")
        @test collect(quads(ds3))[1].graph isa BNode
    end

    @testset "blank nodes are distinct across graph blocks" begin
        # Anonymous [] in different blocks must be different blank nodes.
        trig = "@prefix : <http://example/> .\n" *
               "{[] :x :y .}\n<http://example/g> {[] :x :y .}"
        ds = parse_trig(trig)
        qs = collect(quads(ds))
        @test length(qs) == 2
        subjects_seen = Set(q.subject for q in qs)
        @test length(subjects_seen) == 2  # two distinct blank nodes
    end

    @testset "explicit _:label shared across graph blocks" begin
        # The same _:label in two blocks denotes the same node.
        trig = "@prefix : <http://example/> .\n" *
               "{_:a :p :o .}\n<http://example/g> {_:a :q :o .}"
        ds = parse_trig(trig)
        qs = collect(quads(ds))
        @test length(qs) == 2
        @test qs[1].subject == qs[2].subject  # same blank node across blocks
    end

    @testset "directives rejected inside graph blocks" begin
        @test_throws ArgumentError parse_trig("{\n  @base <http://example/> .\n}")
        @test_throws ArgumentError parse_trig("{\n  @prefix ex: <http://example/> .\n}")
        @test_throws ArgumentError parse_trig("{\n  PREFIX ex: <http://example/>\n}")
        @test_throws ArgumentError parse_trig("{\n  BASE <http://example/>\n}")
        # A language tag '@en' inside a block must NOT be mistaken for a directive.
        ds = parse_trig("@prefix : <http://example/> .\n{:s :p \"hi\"@en .}")
        @test length(collect(quads(ds))) == 1
    end

    @testset "cumulative @base resolution and base kwarg" begin
        # @base directives resolve relative to the current in-scope base, and the
        # initial base kwarg is honoured.
        trig = "{<a1> <b1> <c1> .}\n@base <http://example.org/ns/> .\n" *
               "{<a2> <b2> <c2> .}\n@base <foo/> .\n{<a3> <b3> <c3> .}\n" *
               "@prefix : <bar#> .\n{:a4 :b4 :c4 .}"
        ds = parse_trig(trig; base="https://example.com/dir/doc.trig")
        objs = Set(string(q.object) for q in quads(ds))
        @test "https://example.com/dir/c1" in objs
        @test "http://example.org/ns/c2" in objs
        @test "http://example.org/ns/foo/c3" in objs
        @test "http://example.org/ns/foo/bar#c4" in objs
    end
end
