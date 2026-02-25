@testset "OWL 2 RL Inference" begin
    EX = Namespace("http://example.org/")

    @testset "Property Chain" begin
        g = RDFGraph()
        parent = EX.parent
        ancestor = EX.ancestor
        # ancestor owl:propertyChainAxiom (parent parent)
        head, tris = Collection([parent, parent])
        for t in tris; add!(g, t); end
        add!(g, Triple(ancestor, OWL.propertyChainAxiom, head))
        add!(g, Triple(EX.alice, parent, EX.bob))
        add!(g, Triple(EX.bob, parent, EX.carol))
        owl2_rl_closure!(g)
        @test Triple(EX.alice, ancestor, EX.carol) in g
    end

    @testset "hasValue" begin
        g = RDFGraph()
        restriction = EX.USCitizenRestriction
        add!(g, Triple(restriction, OWL.hasValue, EX.USA))
        add!(g, Triple(restriction, OWL.onProperty, EX.citizenship))
        add!(g, Triple(EX.alice, RDF.type, restriction))
        owl2_rl_closure!(g)
        @test Triple(EX.alice, EX.citizenship, EX.USA) in g
        # Reverse: bob has citizenship USA → bob rdf:type restriction
        add!(g, Triple(EX.bob, EX.citizenship, EX.USA))
        owl2_rl_closure!(g)
        @test Triple(EX.bob, RDF.type, restriction) in g
    end

    @testset "someValuesFrom" begin
        g = RDFGraph()
        restriction = EX.HasChildRestriction
        add!(g, Triple(restriction, OWL.someValuesFrom, EX.Person))
        add!(g, Triple(restriction, OWL.onProperty, EX.hasChild))
        add!(g, Triple(EX.alice, EX.hasChild, EX.bob))
        add!(g, Triple(EX.bob, RDF.type, EX.Person))
        owl2_rl_closure!(g)
        @test Triple(EX.alice, RDF.type, restriction) in g
    end

    @testset "allValuesFrom" begin
        g = RDFGraph()
        restriction = EX.AllHumanChildren
        add!(g, Triple(restriction, OWL.allValuesFrom, EX.Human))
        add!(g, Triple(restriction, OWL.onProperty, EX.hasChild))
        add!(g, Triple(EX.alice, RDF.type, restriction))
        add!(g, Triple(EX.alice, EX.hasChild, EX.bob))
        owl2_rl_closure!(g)
        @test Triple(EX.bob, RDF.type, EX.Human) in g
    end

    @testset "intersectionOf" begin
        g = RDFGraph()
        head, tris = Collection([EX.Student, EX.Worker])
        for t in tris; add!(g, t); end
        add!(g, Triple(EX.WorkingStudent, OWL.intersectionOf, head))
        add!(g, Triple(EX.alice, RDF.type, EX.Student))
        add!(g, Triple(EX.alice, RDF.type, EX.Worker))
        add!(g, Triple(EX.bob, RDF.type, EX.Student))  # only Student
        owl2_rl_closure!(g)
        @test Triple(EX.alice, RDF.type, EX.WorkingStudent) in g
        @test !(Triple(EX.bob, RDF.type, EX.WorkingStudent) in g)
    end

    @testset "unionOf" begin
        g = RDFGraph()
        head, tris = Collection([EX.Cat, EX.Dog])
        for t in tris; add!(g, t); end
        add!(g, Triple(EX.Pet, OWL.unionOf, head))
        add!(g, Triple(EX.fido, RDF.type, EX.Dog))
        add!(g, Triple(EX.whiskers, RDF.type, EX.Cat))
        owl2_rl_closure!(g)
        @test Triple(EX.fido, RDF.type, EX.Pet) in g
        @test Triple(EX.whiskers, RDF.type, EX.Pet) in g
    end

    @testset "FunctionalProperty" begin
        g = RDFGraph()
        add!(g, Triple(EX.hasMother, RDF.type, OWL.FunctionalProperty))
        add!(g, Triple(EX.alice, EX.hasMother, EX.carol))
        add!(g, Triple(EX.alice, EX.hasMother, EX.carolAlias))
        owl2_rl_closure!(g)
        @test Triple(EX.carol, OWL.sameAs, EX.carolAlias) in g
    end

    @testset "InverseFunctionalProperty" begin
        g = RDFGraph()
        add!(g, Triple(EX.ssn, RDF.type, OWL.InverseFunctionalProperty))
        ssn_val = Literal("123-45-6789")
        add!(g, Triple(EX.alice, EX.ssn, ssn_val))
        add!(g, Triple(EX.aliceAlias, EX.ssn, ssn_val))
        owl2_rl_closure!(g)
        @test Triple(EX.alice, OWL.sameAs, EX.aliceAlias) in g
    end

    @testset "hasKey" begin
        g = RDFGraph()
        head, tris = Collection([EX.email])
        for t in tris; add!(g, t); end
        add!(g, Triple(EX.Person, OWL.hasKey, head))
        email = Literal("alice@example.org")
        add!(g, Triple(EX.alice, RDF.type, EX.Person))
        add!(g, Triple(EX.aliceAlias, RDF.type, EX.Person))
        add!(g, Triple(EX.alice, EX.email, email))
        add!(g, Triple(EX.aliceAlias, EX.email, email))
        owl2_rl_closure!(g)
        @test Triple(EX.alice, OWL.sameAs, EX.aliceAlias) in g
    end

    @testset "differentFrom symmetry" begin
        g = RDFGraph()
        add!(g, Triple(EX.alice, OWL.differentFrom, EX.bob))
        owl2_rl_closure!(g)
        @test Triple(EX.bob, OWL.differentFrom, EX.alice) in g
    end

    @testset "infer with :owl2" begin
        g = RDFGraph()
        add!(g, Triple(EX.A, RDFS.subClassOf, EX.B))
        add!(g, Triple(EX.x, RDF.type, EX.A))
        result = infer(g; rules=:owl2)
        @test Triple(EX.x, RDF.type, EX.B) in result
    end
end
