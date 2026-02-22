@testset "N3 Unifier" begin
    EX = RDFLib.Namespace("http://example.org/")
    rdf_type = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")

    @testset "unify_term" begin
        @testset "Variable binds to URI" begin
            b = RDFLib.Binding()
            result = RDFLib.unify_term(Variable("x"), EX("Socrates"), b)
            @test result !== nothing
            @test result[Variable("x")] == EX("Socrates")
        end

        @testset "consistent rebinding succeeds" begin
            b = RDFLib.Binding(Variable("x") => EX("Socrates"))
            result = RDFLib.unify_term(Variable("x"), EX("Socrates"), b)
            @test result !== nothing
            @test result[Variable("x")] == EX("Socrates")
        end

        @testset "inconsistent binding fails" begin
            b = RDFLib.Binding(Variable("x") => EX("Socrates"))
            result = RDFLib.unify_term(Variable("x"), EX("Plato"), b)
            @test result === nothing
        end

        @testset "ground terms match if equal" begin
            b = RDFLib.Binding()
            @test RDFLib.unify_term(EX("a"), EX("a"), b) !== nothing
            @test RDFLib.unify_term(EX("a"), EX("b"), b) === nothing
        end
    end

    @testset "unify_triple" begin
        pattern = Triple(Variable("X"), rdf_type, Variable("Y"))
        fact = Triple(EX("Socrates"), rdf_type, EX("Human"))
        b = RDFLib.Binding()

        result = RDFLib.unify_triple(pattern, fact, b)
        @test result !== nothing
        @test result[Variable("X")] == EX("Socrates")
        @test result[Variable("Y")] == EX("Human")

        # Predicate mismatch fails
        fact2 = Triple(EX("Socrates"), EX("likes"), EX("Human"))
        @test RDFLib.unify_triple(pattern, fact2, b) === nothing
    end

    @testset "apply_bindings" begin
        bindings = RDFLib.Binding(
            Variable("X") => EX("Socrates"),
            Variable("Y") => EX("Human")
        )
        pattern = Triple(Variable("X"), rdf_type, Variable("Y"))
        result = RDFLib.apply_bindings(pattern, bindings)
        @test result.subject == EX("Socrates")
        @test result.predicate == rdf_type
        @test result.object == EX("Human")

        # Unbound variable stays as variable
        partial = RDFLib.Binding(Variable("X") => EX("Socrates"))
        result2 = RDFLib.apply_bindings(pattern, partial)
        @test result2.subject == EX("Socrates")
        @test result2.object == Variable("Y")

        # apply_bindings on individual terms
        @test RDFLib.apply_bindings(Variable("X"), bindings) == EX("Socrates")
        @test RDFLib.apply_bindings(EX("fixed"), bindings) == EX("fixed")
    end

    @testset "is_ground" begin
        @test RDFLib.is_ground(Triple(EX("s"), rdf_type, EX("o"))) == true
        @test RDFLib.is_ground(Triple(Variable("X"), rdf_type, EX("o"))) == false
        @test RDFLib.is_ground(Triple(EX("s"), rdf_type, Variable("Y"))) == false
    end

    @testset "match_conjunction" begin
        g = RDFGraph()
        add!(g, Triple(EX("Socrates"), rdf_type, EX("Human")))
        add!(g, Triple(EX("Plato"), rdf_type, EX("Human")))
        add!(g, Triple(EX("Human"), URIRef("http://www.w3.org/2000/01/rdf-schema#subClassOf"), EX("Animal")))

        @testset "single pattern — multiple solutions" begin
            patterns = [Triple(Variable("X"), rdf_type, EX("Human"))]
            results = RDFLib.match_conjunction(patterns, g)
            @test length(results) == 2
            xs = Set([b[Variable("X")] for b in results])
            @test EX("Socrates") in xs
            @test EX("Plato") in xs
        end

        @testset "multi-pattern conjunction" begin
            rdfs_sub = URIRef("http://www.w3.org/2000/01/rdf-schema#subClassOf")
            patterns = [
                Triple(Variable("S"), rdf_type, Variable("A")),
                Triple(Variable("A"), rdfs_sub, Variable("B"))
            ]
            results = RDFLib.match_conjunction(patterns, g)
            @test length(results) == 2
            # Both Socrates and Plato should match ?S, with ?A=Human, ?B=Animal
            for b in results
                @test b[Variable("A")] == EX("Human")
                @test b[Variable("B")] == EX("Animal")
            end
            ss = Set([b[Variable("S")] for b in results])
            @test EX("Socrates") in ss
            @test EX("Plato") in ss
        end

        @testset "no matches" begin
            patterns = [Triple(Variable("X"), rdf_type, EX("Robot"))]
            results = RDFLib.match_conjunction(patterns, g)
            @test isempty(results)
        end

        @testset "empty patterns" begin
            results = RDFLib.match_conjunction(Triple[], g)
            @test length(results) == 1
            @test isempty(results[1])
        end

        @testset "with initial bindings" begin
            patterns = [Triple(Variable("X"), rdf_type, Variable("Y"))]
            init = RDFLib.Binding(Variable("Y") => EX("Human"))
            results = RDFLib.match_conjunction(patterns, g, init)
            @test length(results) == 2
            for b in results
                @test b[Variable("Y")] == EX("Human")
            end
        end
    end

    @testset "real graph — Socrates a Human" begin
        g = RDFGraph()
        add!(g, Triple(EX("Socrates"), rdf_type, EX("Human")))
        patterns = [Triple(Variable("X"), rdf_type, Variable("Y"))]
        results = RDFLib.match_conjunction(patterns, g)
        @test length(results) == 1
        @test results[1][Variable("X")] == EX("Socrates")
        @test results[1][Variable("Y")] == EX("Human")
    end
end
