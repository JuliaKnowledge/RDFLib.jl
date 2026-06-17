using Test
using RDFLib

const EE = Namespace("http://example.org/")
const _XSDi = URIRef("http://www.w3.org/2001/XMLSchema#integer")
const _XSDdec = URIRef("http://www.w3.org/2001/XMLSchema#decimal")
const _XSDstr = URIRef("http://www.w3.org/2001/XMLSchema#string")

@testset "Entailment regimes" begin

    @testset "simple entailment — ground subgraph" begin
        g = RDFGraph()
        add!(g, Triple(EE("s"), EE("p"), EE("o")))
        add!(g, Triple(EE("a"), EE("b"), EE("c")))
        c = RDFGraph(); add!(c, Triple(EE("s"), EE("p"), EE("o")))
        @test entails(g, c; regime = "simple")
        c2 = RDFGraph(); add!(c2, Triple(EE("s"), EE("p"), EE("x")))
        @test !entails(g, c2; regime = "simple")
    end

    @testset "simple entailment — blank node generalization" begin
        g = RDFGraph()
        add!(g, Triple(EE("s"), EE("p"), EE("o")))
        c = RDFGraph(); add!(c, Triple(EE("s"), EE("p"), BNode("x")))
        @test entails(g, c; regime = "simple")
        @test simple_entails(g, c)
        # Shared blank node must map consistently.
        g2 = RDFGraph()
        add!(g2, Triple(EE("a"), EE("p"), EE("o")))
        add!(g2, Triple(EE("b"), EE("p"), EE("o")))
        cc = RDFGraph()
        add!(cc, Triple(BNode("z"), EE("p"), EE("o")))
        add!(cc, Triple(BNode("z"), EE("p"), EE("o")))
        @test simple_entails(g2, cc)
        # Conclusion needing two *distinct* witnesses for one bnode fails.
        cc2 = RDFGraph()
        add!(cc2, Triple(BNode("z"), EE("p"), EE("o")))
        add!(cc2, Triple(BNode("z"), EE("q"), EE("o")))
        @test !simple_entails(g2, cc2)
    end

    @testset "simple entailment — triple terms with bnodes" begin
        g = RDFGraph()
        tt = TripleTerm(EE("a"), EE("b"), EE("c"))
        add!(g, Triple(EE("a1"), EE("p1"), tt))
        # Replace inner subject with a fresh bnode.
        c = RDFGraph()
        add!(c, Triple(EE("a1"), EE("p1"), TripleTerm(BNode("x"), EE("b"), EE("c"))))
        @test entails(g, c; regime = "simple")
        # A different inner predicate is not entailed.
        c2 = RDFGraph()
        add!(c2, Triple(EE("a1"), EE("p1"), TripleTerm(BNode("x"), EE("Z"), EE("c"))))
        @test !entails(g, c2; regime = "simple")
    end

    @testset "RDFS entailment — subclass typing" begin
        g = RDFGraph()
        add!(g, Triple(EE("fido"), RDF.type, EE("Dog")))
        add!(g, Triple(EE("Dog"), RDFS.subClassOf, EE("Animal")))
        c = RDFGraph(); add!(c, Triple(EE("fido"), RDF.type, EE("Animal")))
        @test entails(g, c; regime = "RDFS")
        @test !entails(g, c; regime = "simple")
    end

    @testset "RDFS entailment — domain / range" begin
        g = RDFGraph()
        add!(g, Triple(EE("p"), RDFS.domain, EE("C")))
        add!(g, Triple(EE("p"), RDFS.range, EE("D")))
        add!(g, Triple(EE("x"), EE("p"), EE("y")))
        cd = RDFGraph(); add!(cd, Triple(EE("x"), RDF.type, EE("C")))
        cr = RDFGraph(); add!(cr, Triple(EE("y"), RDF.type, EE("D")))
        @test entails(g, cd; regime = "RDFS")
        @test entails(g, cr; regime = "RDFS")
    end

    @testset "RDFS entailment — container membership (rdfs12)" begin
        g = RDFGraph()
        _1 = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#_1")
        add!(g, Triple(EE("a"), _1, EE("b")))
        c = RDFGraph(); add!(c, Triple(EE("a"), RDFS.member, EE("b")))
        @test entails(g, c; regime = "RDFS")
    end

    @testset "datatype value-equivalence (RDF)" begin
        g = RDFGraph()
        add!(g, Triple(EE("foo"), EE("bar"), Literal("010", datatype = _XSDi)))
        c = RDFGraph(); add!(c, Triple(EE("foo"), EE("bar"), Literal("10", datatype = _XSDi)))
        @test entails(g, c; regime = "RDF")
        # integer 10 ≡ decimal 10.0
        gd = RDFGraph()
        add!(gd, Triple(EE("foo"), EE("bar"), Literal("10", datatype = _XSDi)))
        cd = RDFGraph(); add!(cd, Triple(EE("foo"), EE("bar"), Literal("10.0", datatype = _XSDdec)))
        @test entails(gd, cd; regime = "RDF")
    end

    @testset "datatype literal typing (RDF rdfD)" begin
        g = RDFGraph()
        add!(g, Triple(EE("a"), EE("b"), Literal("42", datatype = _XSDi)))
        c = RDFGraph()
        add!(c, Triple(EE("a"), EE("b"), BNode("x")))
        add!(c, Triple(BNode("x"), RDF.type, _XSDi))
        @test entails(g, c; regime = "RDF")
    end

    @testset "inconsistency — ill-typed literal" begin
        g = RDFGraph()
        add!(g, Triple(EE("a"), EE("b"), Literal("flargh", datatype = _XSDi)))
        @test is_inconsistent(g; recognized = Set([_XSDi.value]))
        @test entails(g, false; regime = "RDFS")        # inconsistent ⇒ entails false
        # Consistent graph does not entail false.
        g2 = RDFGraph()
        add!(g2, Triple(EE("a"), EE("b"), Literal("42", datatype = _XSDi)))
        @test !entails(g2, false; regime = "RDFS")
    end

    @testset "inconsistency — rdfs:range datatype clash" begin
        g = RDFGraph()
        add!(g, Triple(EE("bar"), RDFS.range, _XSDstr))
        add!(g, Triple(EE("foo"), EE("bar"), Literal("25", datatype = _XSDi)))
        @test entails(g, false; regime = "RDFS")
    end

    @testset "boolean conclusion — true is trivial" begin
        g = RDFGraph(); add!(g, Triple(EE("a"), EE("b"), EE("c")))
        @test entails(g, true; regime = "simple")
    end

    @testset "2-arg entails still works" begin
        g = RDFGraph()
        add!(g, Triple(EE("Dog"), RDFS.subClassOf, EE("Animal")))
        add!(g, Triple(EE("fido"), RDF.type, EE("Dog")))
        @test entails(g, Triple(EE("fido"), RDF.type, EE("Animal")))
    end
end
