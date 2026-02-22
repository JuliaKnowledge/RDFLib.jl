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
end
