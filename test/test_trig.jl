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
end
