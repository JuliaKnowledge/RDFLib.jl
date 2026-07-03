using Test, RDFLib

# Qualify RDFGraph to avoid ambiguity with Graphs.jl (loaded by isomorphism.jl)
const G = RDFLib.RDFGraph

@testset "N3" begin
    EX = Namespace("http://example.org/")

    @testset "Formula creation" begin
        f = Formula()
        @test f isa Node
        add!(f, Triple(EX("s"), EX("p"), Literal("o")))
        @test length(f.graph) == 1
    end

    @testset "Formula equality" begin
        f1 = Formula()
        f2 = Formula()
        add!(f1, Triple(EX("s"), EX("p"), Literal("o")))
        add!(f2, Triple(EX("s"), EX("p"), Literal("o")))
        @test f1 == f2
    end

    @testset "Formula in triple" begin
        f = Formula()
        add!(f, Triple(EX("s"), EX("p"), EX("o")))
        t = Triple(f, URIRef("http://www.w3.org/2000/10/swap/log#implies"), EX("result"))
        @test t.subject isa Formula
    end

    @testset "N3 serialization - basic" begin
        g = G()
        add!(g, Triple(EX("s"), EX("p"), Literal("hello")))
        n3_str = serialize_n3(g)
        @test occursin("hello", n3_str)
    end

    @testset "N3 serialization - formula" begin
        g = G()
        ante = Formula()
        add!(ante, Triple(Variable("S"), URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"), EX("Human")))
        cons = Formula()
        add!(cons, Triple(Variable("S"), URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"), EX("Mortal")))
        add!(g, Triple(ante, URIRef("http://www.w3.org/2000/10/swap/log#implies"), cons))
        n3_str = serialize_n3(g)
        @test occursin("=>", n3_str)
        @test occursin("{", n3_str)
    end

    @testset "N3 parsing - basic Turtle subset" begin
        input = """
        @prefix ex: <http://example.org/> .
        ex:s ex:p "hello" .
        """
        g = parse_n3(input)
        @test length(g) == 1
    end

    @testset "N3 parsing - formula/rules" begin
        input = """
        @prefix : <http://example.org/> .
        @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .

        :Socrates a :Human .
        :Human rdfs:subClassOf :Mortal .

        {
            ?S a ?A .
            ?A rdfs:subClassOf ?B .
        }
        =>
        {
            ?S a ?B .
        } .
        """
        g = parse_n3(input)
        @test length(g) >= 3  # 2 facts + 1 rule triple
        # The rule should be a Triple with Formula subjects/objects
        rule_triples = collect(triples(g, (nothing, URIRef("http://www.w3.org/2000/10/swap/log#implies"), nothing)))
        @test length(rule_triples) >= 1
        rule = first(rule_triples)
        @test rule.subject isa Formula
        @test rule.object isa Formula
    end

    @testset "N3 parsing - backward rule" begin
        input = """
        @prefix : <http://example.org/> .
        { ?X :p ?Y } <= { ?X :q ?Y } .
        """
        g = parse_n3(input)
        rules = collect(triples(g, (nothing, URIRef("http://www.w3.org/2000/10/swap/log#impliedBy"), nothing)))
        @test length(rules) == 1
        # For <=, subject is consequent, object is antecedent (log:impliedBy)
    end

    @testset "N3 parsing - owl:sameAs shorthand" begin
        input = """
        @prefix : <http://example.org/> .
        :a = :b .
        """
        g = parse_n3(input)
        ts = collect(g)
        @test length(ts) == 1
        @test ts[1].predicate == URIRef("http://www.w3.org/2002/07/owl#sameAs")
    end

    @testset "N3 parsing - variables" begin
        input = """
        @prefix : <http://example.org/> .
        { ?x :p ?y } => { ?y :q ?x } .
        """
        g = parse_n3(input)
        rules = collect(triples(g, (nothing, URIRef("http://www.w3.org/2000/10/swap/log#implies"), nothing)))
        @test length(rules) == 1
        ante = rules[1].subject
        @test ante isa Formula
        # The formula should contain Variable terms
        ante_triples = collect(ante.graph)
        @test length(ante_triples) == 1
        @test ante_triples[1].subject isa Variable
    end

    @testset "N3 round-trip" begin
        input = """
        @prefix : <http://example.org/> .
        :s :p "hello" .
        :s :q :o .
        """
        g1 = parse_n3(input)
        n3_str = serialize_n3(g1)
        g2 = parse_n3(n3_str)
        @test length(g1) == length(g2)
    end

    @testset "LOG namespace" begin
        @test LOG.implies isa URIRef
        @test LOG.implies.value == "http://www.w3.org/2000/10/swap/log#implies"
    end

    @testset "Literal subjects: strict RDF rejects, N3 formulas accept" begin
        # Strict RDF graphs must still reject literal subjects.
        g_strict = RDFGraph()
        @test_throws ArgumentError add!(g_strict,
            Triple(Literal("hello"), URIRef("urn:p"), URIRef("urn:o")))

        # N3 formulas (e.g., crypto: builtins) permit literal subjects.
        n3 = """
        @prefix : <urn:example:> .
        @prefix crypto: <http://www.w3.org/2000/10/swap/crypto#> .
        {
            "hello world" crypto:md5 ?md5 .
        }
        =>
        {
            :result :md5 ?md5 .
        } .
        """
        g = parse_n3(n3)
        result = reason(g)
        ex = Namespace("urn:example:")
        md5s = [t.object for t in triples(result, (ex("result"), ex("md5"), nothing))]
        @test length(md5s) == 1
        @test md5s[1] == Literal("5eb63bbbe01eeed093cb22bb8f5acdc3")
    end
end

@testset "N3 parser regression fixes" begin
    EX = Namespace("http://example.org/")

    @testset "generated bnode IDs do not collide with document labels" begin
        g = parse_n3("""
            @prefix ex: <http://example.org/> .
            _:b1 ex:x ex:y .
            [ ex:p ex:o ] ex:q ex:r .
        """)
        @test length(g) == 3
        @test BNode("b1") in Set(t.subject for t in g)
        anon_q = [t.subject for t in triples(g, (nothing, EX("q"), EX("r")))]
        @test length(anon_q) == 1
        @test anon_q[1] != BNode("b1")
    end

    @testset "bnode label does not consume terminating dot" begin
        g = parse_n3("""
            @prefix ex: <http://example.org/> .
            ex:s ex:p _:b1.
            ex:s2 ex:p2 ex:o2 .
        """)
        @test length(g) == 2
        @test Triple(EX("s"), EX("p"), BNode("b1")) in g
        @test Triple(EX("s2"), EX("p2"), EX("o2")) in g
    end

    @testset "PN_LOCAL dots and escapes" begin
        g = parse_n3("""
            @prefix ex: <http://example.org/> .
            ex:a.b ex:v1.0 ex:c\\,d .
            ex:e%20f ex:p ex:o.
        """)
        @test Triple(EX("a.b"), EX("v1.0"), EX("c,d")) in g
        @test Triple(EX("e%20f"), EX("p"), EX("o")) in g
    end

    @testset "true/false token boundary" begin
        g = parse_n3("""
            @prefix trueblue: <http://example.org/tb#> .
            @prefix ex: <http://example.org/> .
            ex:s ex:p trueblue:x .
            ex:s ex:q true .
        """)
        @test Triple(EX("s"), EX("p"), URIRef("http://example.org/tb#x")) in g
        @test Triple(EX("s"), EX("q"), Literal(true)) in g
    end

    @testset "leading-dot decimals" begin
        g = parse_n3("@prefix ex: <http://example.org/> . ex:s ex:p .5 .")
        xsd_decimal = URIRef("http://www.w3.org/2001/XMLSchema#decimal")
        @test Triple(EX("s"), EX("p"), Literal(".5", datatype=xsd_decimal)) in g
    end

    @testset "base resolution handles fragments and parent segments" begin
        g = parse_n3("""
            @base <http://example.org/dir/file> .
            <#frag> <../p> <> .
        """)
        @test Triple(URIRef("http://example.org/dir/file#frag"),
                     URIRef("http://example.org/p"),
                     URIRef("http://example.org/dir/file")) in g
    end

    @testset "'a' keyword boundary" begin
        rdf_type = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
        g = parse_n3("@prefix ex: <http://example.org/> . ex:s a[ex:p ex:o] .")
        @test length(g) == 2
        @test length(collect(triples(g, (EX("s"), rdf_type, nothing)))) == 1
    end

    @testset "long string greedy termination" begin
        g = parse_n3("@prefix ex: <http://example.org/> . ex:s ex:p \"\"\"a\"\"\"\" .")
        @test Triple(EX("s"), EX("p"), Literal("a\"")) in g
    end

    @testset "unicode escape errors" begin
        @test_throws ArgumentError parse_n3("@prefix ex: <http://example.org/> . ex:s ex:p \"\\u00")
        @test_throws ArgumentError parse_n3("@prefix ex: <http://example.org/> . ex:s ex:p \"\\uD800\" .")
        # only \\u/\\U escapes inside IRIs
        @test_throws ArgumentError parse_n3("<http://example.org/s\\n> <http://example.org/p> <http://example.org/o> .")
    end

    @testset "directional literals" begin
        g = parse_n3("@prefix ex: <http://example.org/> . ex:s ex:p \"x\"@en--ltr . ex:s ex:q \"y\"@ar--rtl .")
        lits = Dict(t.predicate => t.object for t in g)
        @test lits[EX("p")] == Literal("x", lang="en", direction="ltr")
        @test lits[EX("q")] == Literal("y", lang="ar", direction="rtl")

        # round-trip through the N3 serializer
        g2 = RDFGraph()
        bind!(g2, "ex", EX)
        add!(g2, Triple(EX("s"), EX("p"), Literal("x", lang="en", direction="ltr")))
        out = serialize_n3(g2)
        g3 = parse_n3(out)
        @test Triple(EX("s"), EX("p"), Literal("x", lang="en", direction="ltr")) in g3
    end

    @testset "serializer escapes PN_LOCAL reserved characters" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, Triple(EX("a,b"), EX("p"), Literal("v")))
        out = serialize_n3(g)
        g2 = parse_n3(out)
        @test length(g2) == 1
        @test Triple(EX("a,b"), EX("p"), Literal("v")) in g2
    end
end
