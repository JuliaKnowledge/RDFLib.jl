using Test
using RDFLib

const EX = Namespace("http://example.org/")

@testset "Inference" begin

    @testset "RDFS subClassOf transitivity (rdfs11)" begin
        g = RDFGraph()
        add!(g, Triple(EX("Dog"), RDFS.subClassOf, EX("Mammal")))
        add!(g, Triple(EX("Mammal"), RDFS.subClassOf, EX("Animal")))
        result = rdfs_closure(g)
        @test Triple(EX("Dog"), RDFS.subClassOf, EX("Animal")) in result
    end

    @testset "RDFS subclass typing (rdfs9)" begin
        g = RDFGraph()
        add!(g, Triple(EX("fido"), RDF.type, EX("Dog")))
        add!(g, Triple(EX("Dog"), RDFS.subClassOf, EX("Mammal")))
        add!(g, Triple(EX("Mammal"), RDFS.subClassOf, EX("Animal")))
        result = rdfs_closure(g)
        @test Triple(EX("fido"), RDF.type, EX("Mammal")) in result
        @test Triple(EX("fido"), RDF.type, EX("Animal")) in result
    end

    @testset "RDFS subPropertyOf usage (rdfs7)" begin
        g = RDFGraph()
        add!(g, Triple(EX("hasFather"), RDFS.subPropertyOf, EX("hasParent")))
        add!(g, Triple(EX("bob"), EX("hasFather"), EX("john")))
        result = rdfs_closure(g)
        @test Triple(EX("bob"), EX("hasParent"), EX("john")) in result
    end

    @testset "RDFS subPropertyOf transitivity (rdfs5)" begin
        g = RDFGraph()
        add!(g, Triple(EX("hasFather"), RDFS.subPropertyOf, EX("hasParent")))
        add!(g, Triple(EX("hasParent"), RDFS.subPropertyOf, EX("hasAncestor")))
        add!(g, Triple(EX("bob"), EX("hasFather"), EX("john")))
        result = rdfs_closure(g)
        @test Triple(EX("hasFather"), RDFS.subPropertyOf, EX("hasAncestor")) in result
        @test Triple(EX("bob"), EX("hasParent"), EX("john")) in result
        @test Triple(EX("bob"), EX("hasAncestor"), EX("john")) in result
    end

    @testset "RDFS domain inference (rdfs2)" begin
        g = RDFGraph()
        add!(g, Triple(EX("writes"), RDFS.domain, EX("Author")))
        add!(g, Triple(EX("alice"), EX("writes"), EX("book1")))
        result = rdfs_closure(g)
        @test Triple(EX("alice"), RDF.type, EX("Author")) in result
    end

    @testset "RDFS range inference (rdfs3)" begin
        g = RDFGraph()
        add!(g, Triple(EX("writes"), RDFS.range, EX("Book")))
        add!(g, Triple(EX("alice"), EX("writes"), EX("book1")))
        result = rdfs_closure(g)
        @test Triple(EX("book1"), RDF.type, EX("Book")) in result
    end

    @testset "RDFS domain+range combined" begin
        g = RDFGraph()
        add!(g, Triple(EX("teaches"), RDFS.domain, EX("Teacher")))
        add!(g, Triple(EX("teaches"), RDFS.range, EX("Student")))
        add!(g, Triple(EX("prof"), EX("teaches"), EX("grad")))
        result = rdfs_closure(g)
        @test Triple(EX("prof"), RDF.type, EX("Teacher")) in result
        @test Triple(EX("grad"), RDF.type, EX("Student")) in result
    end

    @testset "RDFS property reflexivity (rdfs6)" begin
        g = RDFGraph()
        add!(g, Triple(EX("knows"), RDF.type, RDF.Property))
        result = rdfs_closure(g)
        @test Triple(EX("knows"), RDFS.subPropertyOf, EX("knows")) in result
    end

    @testset "RDFS class reflexivity (rdfs10)" begin
        g = RDFGraph()
        add!(g, Triple(EX("Dog"), RDF.type, RDFS.Class))
        result = rdfs_closure(g)
        @test Triple(EX("Dog"), RDFS.subClassOf, EX("Dog")) in result
    end

    @testset "RDFS ContainerMembershipProperty (rdfs12)" begin
        g = RDFGraph()
        member_1 = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#_1")
        add!(g, Triple(member_1, RDF.type, RDFS.ContainerMembershipProperty))
        add!(g, Triple(EX("bag"), member_1, EX("item")))
        result = rdfs_closure(g)
        @test Triple(member_1, RDFS.subPropertyOf, RDFS.member) in result
        # rdfs7 then propagates the membership triple
        @test Triple(EX("bag"), RDFS.member, EX("item")) in result
    end

    @testset "RDFS Datatype subclass of Literal (rdfs13)" begin
        g = RDFGraph()
        xsd_int = URIRef("http://www.w3.org/2001/XMLSchema#integer")
        add!(g, Triple(xsd_int, RDF.type, RDFS.Datatype))
        result = rdfs_closure(g)
        @test Triple(xsd_int, RDFS.subClassOf, RDFS.Literal) in result
    end

    @testset "RDFS axiomatic rules (rdfs4a/4b/8) are opt-in" begin
        g = RDFGraph()
        add!(g, Triple(EX("a"), EX("p"), EX("b")))
        add!(g, Triple(EX("a"), EX("q"), Literal("text")))
        add!(g, Triple(EX("C"), RDF.type, RDFS.Class))

        # Default: no rdfs:Resource bloat
        result = rdfs_closure(g)
        @test !(Triple(EX("a"), RDF.type, RDFS.Resource) in result)
        @test !(Triple(EX("C"), RDFS.subClassOf, RDFS.Resource) in result)

        # Opt-in: rdfs4a (subjects), rdfs4b (non-literal objects), rdfs8
        result_ax = rdfs_closure(g; axiomatic=true)
        @test Triple(EX("a"), RDF.type, RDFS.Resource) in result_ax        # rdfs4a
        @test Triple(EX("b"), RDF.type, RDFS.Resource) in result_ax        # rdfs4b
        @test Triple(EX("C"), RDF.type, RDFS.Resource) in result_ax
        @test Triple(EX("C"), RDFS.subClassOf, RDFS.Resource) in result_ax # rdfs8

        # axiomatic also threads through infer()
        result_inf = infer(g; rules=:rdfs, axiomatic=true)
        @test Triple(EX("a"), RDF.type, RDFS.Resource) in result_inf
    end

    @testset "OWL TransitiveProperty" begin
        g = RDFGraph()
        add!(g, Triple(EX("ancestor"), RDF.type, OWL.TransitiveProperty))
        add!(g, Triple(EX("a"), EX("ancestor"), EX("b")))
        add!(g, Triple(EX("b"), EX("ancestor"), EX("c")))
        add!(g, Triple(EX("c"), EX("ancestor"), EX("d")))
        result = owl_closure(g)
        @test Triple(EX("a"), EX("ancestor"), EX("c")) in result
        @test Triple(EX("a"), EX("ancestor"), EX("d")) in result
        @test Triple(EX("b"), EX("ancestor"), EX("d")) in result
    end

    @testset "OWL SymmetricProperty" begin
        g = RDFGraph()
        add!(g, Triple(EX("knows"), RDF.type, OWL.SymmetricProperty))
        add!(g, Triple(EX("alice"), EX("knows"), EX("bob")))
        result = owl_closure(g)
        @test Triple(EX("bob"), EX("knows"), EX("alice")) in result
    end

    @testset "OWL inverseOf" begin
        g = RDFGraph()
        add!(g, Triple(EX("hasChild"), OWL.inverseOf, EX("hasParent")))
        add!(g, Triple(EX("john"), EX("hasChild"), EX("bob")))
        result = owl_closure(g)
        @test Triple(EX("bob"), EX("hasParent"), EX("john")) in result
    end

    @testset "OWL inverseOf bidirectional" begin
        g = RDFGraph()
        add!(g, Triple(EX("hasChild"), OWL.inverseOf, EX("hasParent")))
        add!(g, Triple(EX("bob"), EX("hasParent"), EX("john")))
        result = owl_closure(g)
        @test Triple(EX("john"), EX("hasChild"), EX("bob")) in result
    end

    @testset "OWL equivalentClass" begin
        g = RDFGraph()
        add!(g, Triple(EX("Person"), OWL.equivalentClass, EX("Human")))
        add!(g, Triple(EX("alice"), RDF.type, EX("Person")))
        result = owl_closure(g)
        @test Triple(EX("Person"), RDFS.subClassOf, EX("Human")) in result
        @test Triple(EX("Human"), RDFS.subClassOf, EX("Person")) in result
        @test Triple(EX("alice"), RDF.type, EX("Human")) in result
    end

    @testset "OWL equivalentProperty" begin
        g = RDFGraph()
        add!(g, Triple(EX("cost"), OWL.equivalentProperty, EX("price")))
        add!(g, Triple(EX("item1"), EX("cost"), Literal("10")))
        result = owl_closure(g)
        @test Triple(EX("cost"), RDFS.subPropertyOf, EX("price")) in result
        @test Triple(EX("price"), RDFS.subPropertyOf, EX("cost")) in result
        @test Triple(EX("item1"), EX("price"), Literal("10")) in result
    end

    @testset "OWL sameAs symmetry and transitivity" begin
        g = RDFGraph()
        add!(g, Triple(EX("a"), OWL.sameAs, EX("b")))
        add!(g, Triple(EX("b"), OWL.sameAs, EX("c")))
        result = owl_closure(g)
        # Symmetry
        @test Triple(EX("b"), OWL.sameAs, EX("a")) in result
        @test Triple(EX("c"), OWL.sameAs, EX("b")) in result
        # Transitivity
        @test Triple(EX("a"), OWL.sameAs, EX("c")) in result
        @test Triple(EX("c"), OWL.sameAs, EX("a")) in result
    end

    @testset "OWL sameAs property propagation" begin
        g = RDFGraph()
        add!(g, Triple(EX("a"), OWL.sameAs, EX("b")))
        add!(g, Triple(EX("a"), EX("name"), Literal("Alice")))
        add!(g, Triple(EX("a"), RDF.type, EX("Person")))
        result = owl_closure(g)
        @test Triple(EX("b"), EX("name"), Literal("Alice")) in result
        @test Triple(EX("b"), RDF.type, EX("Person")) in result
    end

    @testset "OWL sameAs predicate propagation" begin
        g = RDFGraph()
        add!(g, Triple(EX("p1"), OWL.sameAs, EX("p2")))
        add!(g, Triple(EX("alice"), EX("p1"), EX("bob")))
        result = owl_closure(g)
        @test Triple(EX("alice"), EX("p2"), EX("bob")) in result
    end

    @testset "Fixed-point convergence (multi-step)" begin
        # Requires multiple iterations: subClassOf chain + typing
        g = RDFGraph()
        add!(g, Triple(EX("Poodle"), RDFS.subClassOf, EX("Dog")))
        add!(g, Triple(EX("Dog"), RDFS.subClassOf, EX("Mammal")))
        add!(g, Triple(EX("Mammal"), RDFS.subClassOf, EX("Animal")))
        add!(g, Triple(EX("Animal"), RDFS.subClassOf, EX("LivingThing")))
        add!(g, Triple(EX("fifi"), RDF.type, EX("Poodle")))
        result = rdfs_closure(g)
        @test Triple(EX("Poodle"), RDFS.subClassOf, EX("Animal")) in result
        @test Triple(EX("Poodle"), RDFS.subClassOf, EX("LivingThing")) in result
        @test Triple(EX("Dog"), RDFS.subClassOf, EX("LivingThing")) in result
        @test Triple(EX("fifi"), RDF.type, EX("Dog")) in result
        @test Triple(EX("fifi"), RDF.type, EX("Mammal")) in result
        @test Triple(EX("fifi"), RDF.type, EX("Animal")) in result
        @test Triple(EX("fifi"), RDF.type, EX("LivingThing")) in result
    end

    @testset "infer() dispatch" begin
        g = RDFGraph()
        add!(g, Triple(EX("Dog"), RDFS.subClassOf, EX("Animal")))
        add!(g, Triple(EX("fido"), RDF.type, EX("Dog")))
        r1 = infer(g; rules=:rdfs)
        @test Triple(EX("fido"), RDF.type, EX("Animal")) in r1
        r2 = infer(g; rules=:owl)
        @test Triple(EX("fido"), RDF.type, EX("Animal")) in r2
        r3 = infer(g; rules=:all)
        @test Triple(EX("fido"), RDF.type, EX("Animal")) in r3
    end

    @testset "entails()" begin
        g = RDFGraph()
        add!(g, Triple(EX("Dog"), RDFS.subClassOf, EX("Animal")))
        add!(g, Triple(EX("fido"), RDF.type, EX("Dog")))
        @test entails(g, Triple(EX("fido"), RDF.type, EX("Animal")))
        @test !entails(g, Triple(EX("fido"), RDF.type, EX("Plant")))
    end

    @testset "In-place closure modifies graph" begin
        g = RDFGraph()
        add!(g, Triple(EX("Dog"), RDFS.subClassOf, EX("Animal")))
        add!(g, Triple(EX("fido"), RDF.type, EX("Dog")))
        orig_len = length(g)
        rdfs_closure!(g)
        @test length(g) > orig_len
        @test Triple(EX("fido"), RDF.type, EX("Animal")) in g
    end

    @testset "Empty graph closure" begin
        g = RDFGraph()
        result = rdfs_closure(g)
        @test length(result) == 0
        result2 = owl_closure(g)
        @test length(result2) == 0
    end

    @testset "No spurious triples without schema" begin
        g = RDFGraph()
        add!(g, Triple(EX("a"), EX("p"), EX("b")))
        result = rdfs_closure(g)
        @test length(result) == 1
    end
end
