@testset "N3 Rules" begin
    EX = RDFLib.Namespace("http://example.org/")

    @testset "extract_rules — single forward rule" begin
        n3str = """
        @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
        { ?A rdfs:subClassOf ?B . ?S a ?A } => { ?S a ?B } .
        """
        g = parse_n3(n3str)
        rules = RDFLib.extract_rules(g)

        @test length(rules) == 1
        r = rules[1]
        @test r.direction == RDFLib.FORWARD
        @test length(r.antecedent) == 2
        @test length(r.consequent) == 1

        # Consequent should be ?S a ?B
        con = r.consequent[1]
        @test con.subject == Variable("S")
        @test con.predicate == URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
        @test con.object == Variable("B")
    end

    @testset "_collect_vars finds all variables" begin
        vars = Set{Variable}()
        t = Triple(Variable("X"),
                   URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"),
                   Variable("Y"))
        RDFLib._collect_vars!(vars, t)
        @test Variable("X") in vars
        @test Variable("Y") in vars
        @test length(vars) == 2
    end

    @testset "extract_rules — variables collected from antecedent and consequent" begin
        n3str = """
        @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
        { ?A rdfs:subClassOf ?B . ?S a ?A } => { ?S a ?B } .
        """
        g = parse_n3(n3str)
        rules = RDFLib.extract_rules(g)
        r = rules[1]
        @test Variable("A") in r.variables
        @test Variable("B") in r.variables
        @test Variable("S") in r.variables
        @test length(r.variables) == 3
    end

    @testset "RuleSet indexing" begin
        n3str = """
        @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
        { ?A rdfs:subClassOf ?B . ?S a ?A } => { ?S a ?B } .
        """
        g = parse_n3(n3str)
        rules = RDFLib.extract_rules(g)
        rs = RDFLib.RuleSet(rules)

        @test length(rs.forward_rules) == 1
        @test length(rs.backward_rules) == 0
        @test length(rs.all_rules) == 1

        rdf_type = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
        @test haskey(rs.predicate_index, rdf_type)
        @test length(rs.predicate_index[rdf_type]) == 1
    end

    @testset "multiple rules" begin
        n3str = """
        @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
        @prefix ex: <http://example.org/> .
        { ?A rdfs:subClassOf ?B . ?S a ?A } => { ?S a ?B } .
        { ?X ex:parent ?Y } => { ?Y ex:child ?X } .
        """
        g = parse_n3(n3str)
        rules = RDFLib.extract_rules(g)
        @test length(rules) == 2

        rs = RDFLib.RuleSet(rules)
        @test length(rs.forward_rules) == 2
        @test length(rs.all_rules) == 2

        # Both predicates should be indexed
        rdf_type = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
        ex_child = EX("child")
        @test haskey(rs.predicate_index, rdf_type)
        @test haskey(rs.predicate_index, ex_child)
    end

    @testset "no rules in plain graph" begin
        g = RDFGraph()
        add!(g, Triple(EX("s"), EX("p"), EX("o")))
        rules = RDFLib.extract_rules(g)
        @test isempty(rules)
    end
end
