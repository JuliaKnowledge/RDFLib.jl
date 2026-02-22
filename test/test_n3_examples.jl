@testset "N3 Reasoning Examples" begin

    RDF_TYPE = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    RDFS_SUBCLASSOF = URIRef("http://www.w3.org/2000/01/rdf-schema#subClassOf")

    # ── 1. Socrates — basic subclass inference ──────────────────────────
    @testset "Socrates — subclass inference" begin
        EX = Namespace("http://example.org/socrates#")
        n3str = """
        @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#>.
        @prefix : <http://example.org/socrates#>.

        :Socrates a :Human.
        :Human rdfs:subClassOf :Mortal.

        {?A rdfs:subClassOf ?B. ?S a ?A} => {?S a ?B}.
        """
        g = parse_n3(n3str)
        result = reason(g)

        @test Triple(EX("Socrates"), RDF_TYPE, EX("Mortal")) in result
        @test Triple(EX("Socrates"), RDF_TYPE, EX("Human")) in result
    end

    # ── 2. Simple forward rule ──────────────────────────────────────────
    @testset "Simple forward rule — plays piano" begin
        EX = Namespace("http://example.org/")
        n3str = """
        @prefix : <http://example.org/>.

        :Alice :plays :Piano.
        {?P :plays :Piano} => {?P :likes :Music}.
        """
        g = parse_n3(n3str)
        result = reason(g)

        @test Triple(EX("Alice"), EX("likes"), EX("Music")) in result
    end

    # ── 3. Multiple rules, cascading (fixed-point) ──────────────────────
    @testset "Cascading subclass — fixed-point" begin
        EX = Namespace("http://example.org/")
        n3str = """
        @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#>.
        @prefix : <http://example.org/>.

        :Socrates a :Human.
        :Human rdfs:subClassOf :Mammal.
        :Mammal rdfs:subClassOf :Animal.

        {?A rdfs:subClassOf ?B. ?S a ?A} => {?S a ?B}.
        {?A rdfs:subClassOf ?B. ?B rdfs:subClassOf ?C} => {?A rdfs:subClassOf ?C}.
        """
        g = parse_n3(n3str)
        result = reason(g)

        @test Triple(EX("Socrates"), RDF_TYPE, EX("Mammal")) in result
        @test Triple(EX("Socrates"), RDF_TYPE, EX("Animal")) in result
        @test Triple(EX("Human"), RDFS_SUBCLASSOF, EX("Animal")) in result
    end

    # ── 4. Backward rule with math builtin ──────────────────────────────
    @testset "Math builtin — greaterThan in rule" begin
        EX = Namespace("http://example.org/")
        xsd_int = URIRef("http://www.w3.org/2001/XMLSchema#integer")
        math_gt = URIRef("http://www.w3.org/2000/10/swap/math#greaterThan")

        data = RDFGraph()
        add!(data, Triple(EX("a"), EX("value"), Literal("10", datatype=xsd_int)))
        add!(data, Triple(EX("b"), EX("value"), Literal("3", datatype=xsd_int)))

        ant = [
            Triple(Variable("X"), EX("value"), Variable("V")),
            Triple(Variable("V"), math_gt, Literal("7", datatype=xsd_int))
        ]
        con = [Triple(Variable("X"), EX("moreInteresting"), Literal(true))]
        rule = N3Rule(ant, con, FORWARD, nothing, Set([Variable("X"), Variable("V")]))

        reasoner = N3Reasoner(data, [rule])
        eam_loop!(reasoner)

        @test Triple(EX("a"), EX("moreInteresting"), Literal(true)) in reasoner.facts
        @test !(Triple(EX("b"), EX("moreInteresting"), Literal(true)) in reasoner.facts)
    end

    # ── 5. Wine example — selective rule firing ─────────────────────────
    @testset "Wine example — selective rule" begin
        EX = Namespace("http://example.org/")
        n3str = """
        @prefix : <http://example.org/>.

        :ChateauxGreysac a :Wine.
        :Badenhortst a :Wine.
        :Croissant a :Bread.

        {?X a :Wine} => {?X :contains :Alcohol}.
        """
        g = parse_n3(n3str)
        result = reason(g)

        @test Triple(EX("ChateauxGreysac"), EX("contains"), EX("Alcohol")) in result
        @test Triple(EX("Badenhortst"), EX("contains"), EX("Alcohol")) in result
        @test !(Triple(EX("Croissant"), EX("contains"), EX("Alcohol")) in result)
    end

    # ── 6. Symmetry rule ────────────────────────────────────────────────
    @testset "Symmetry rule" begin
        EX = Namespace("http://example.org/")
        n3str = """
        @prefix : <http://example.org/>.

        :Alice :knows :Bob.
        {?X :knows ?Y} => {?Y :knows ?X}.
        """
        g = parse_n3(n3str)
        result = reason(g)

        @test Triple(EX("Bob"), EX("knows"), EX("Alice")) in result
        @test Triple(EX("Alice"), EX("knows"), EX("Bob")) in result
    end

    # ── 7. Multiple consequent triples (separate rules) ────────────────
    @testset "Multiple consequent triples" begin
        EX = Namespace("http://example.org/")
        n3str = """
        @prefix : <http://example.org/>.

        :Alice a :Student.
        {?X a :Student} => {?X :status :Enrolled}.
        {?X a :Student} => {?X :needs :ID}.
        """
        g = parse_n3(n3str)
        result = reason(g)

        @test Triple(EX("Alice"), EX("status"), EX("Enrolled")) in result
        @test Triple(EX("Alice"), EX("needs"), EX("ID")) in result
    end

    # ── 8. No rule fires ────────────────────────────────────────────────
    @testset "No rule fires — no matching data" begin
        EX = Namespace("http://example.org/")
        n3str = """
        @prefix : <http://example.org/>.

        :Alice a :Human.
        {?X a :Robot} => {?X :has :Battery}.
        """
        g = parse_n3(n3str)
        result = reason(g; pass_only_new=true)

        @test length(result) == 0
    end

    # ── 9. Cycle termination ────────────────────────────────────────────
    @testset "Cycle termination — reachability" begin
        EX = Namespace("http://example.org/")
        n3str = """
        @prefix : <http://example.org/>.

        :A :link :B.
        :B :link :C.
        :C :link :A.

        {?X :link ?Y} => {?X :reachable ?Y}.
        {?X :reachable ?Y. ?Y :link ?Z} => {?X :reachable ?Z}.
        """
        g = parse_n3(n3str)
        result = reason(g; max_iterations=200)

        @test Triple(EX("A"), EX("reachable"), EX("B")) in result
        @test Triple(EX("A"), EX("reachable"), EX("C")) in result
        @test Triple(EX("B"), EX("reachable"), EX("C")) in result
        @test Triple(EX("B"), EX("reachable"), EX("A")) in result
        @test Triple(EX("C"), EX("reachable"), EX("A")) in result
        @test Triple(EX("C"), EX("reachable"), EX("B")) in result
        # Key: we get here without hanging
        @test length(result) < 200
    end

    # ── 10. EYE comparison ──────────────────────────────────────────────
    @testset "Compare with EYE reasoner" begin
        swipl = "/opt/homebrew/bin/swipl"
        eye = "/Users/sdwfrost/Projects/rdf/eye/eye.pl"
        tmpdir = "/Users/sdwfrost/Projects/rdf/tmp"

        if isfile(swipl) && isfile(eye)
            mkpath(tmpdir)

            data_n3 = """
            @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#>.
            @prefix : <http://example.org/socrates#>.

            :Socrates a :Human.
            :Human rdfs:subClassOf :Mortal.

            {?A rdfs:subClassOf ?B. ?S a ?A} => {?S a ?B}.
            """

            query_n3 = """
            @prefix : <http://example.org/socrates#>.
            {?S a :Mortal} => {?S a :Mortal}.
            """

            data_file = joinpath(tmpdir, "test_socrates.n3")
            query_file = joinpath(tmpdir, "test_socrates_query.n3")

            try
                write(data_file, data_n3)
                write(query_file, query_n3)

                eye_output = read(`$swipl -g main -t halt $eye -- --nope --pass-only-new $data_file --query $query_file`, String)

                # EYE should produce :Socrates a :Mortal
                @test occursin("Socrates", eye_output)
                @test occursin("Mortal", eye_output)

                # Julia reasoner should agree
                EX = Namespace("http://example.org/socrates#")
                g = parse_n3(data_n3)
                qg = parse_n3(query_n3)
                julia_result = reason(g; query=qg)

                @test Triple(EX("Socrates"), RDF_TYPE, EX("Mortal")) in julia_result
            catch e
                @warn "EYE comparison failed" exception=e
                @test_skip "EYE comparison skipped"
            finally
                rm(data_file; force=true)
                rm(query_file; force=true)
            end
        else
            @info "Skipping EYE comparison — swipl or eye.pl not found"
        end
    end

    # ── 11. String builtin in rule ──────────────────────────────────────
    @testset "String builtin — upperCase" begin
        EX = Namespace("http://example.org/")
        string_upper = URIRef("http://www.w3.org/2000/10/swap/string#upperCase")

        data = RDFGraph()
        add!(data, Triple(EX("Alice"), EX("name"), Literal("alice")))

        ant = [
            Triple(Variable("X"), EX("name"), Variable("N")),
            Triple(Variable("N"), string_upper, Variable("U"))
        ]
        con = [Triple(Variable("X"), EX("upperName"), Variable("U"))]
        rule = N3Rule(ant, con, FORWARD, nothing,
                      Set([Variable("X"), Variable("N"), Variable("U")]))

        reasoner = N3Reasoner(data, [rule])
        eam_loop!(reasoner)

        # Check that the derived triple has the uppercased name
        found = false
        for t in reasoner.facts
            if t.subject == EX("Alice") && t.predicate == EX("upperName")
                @test t.object isa Literal
                @test t.object.lexical == "ALICE"
                found = true
            end
        end
        @test found
    end

    # ── 12. Math comparison in rule ─────────────────────────────────────
    @testset "Math comparison — greaterThan filter" begin
        EX = Namespace("http://example.org/")
        xsd_int = URIRef("http://www.w3.org/2001/XMLSchema#integer")
        math_gt = URIRef("http://www.w3.org/2000/10/swap/math#greaterThan")

        data = RDFGraph()
        add!(data, Triple(EX("A"), EX("value"), Literal("10", datatype=xsd_int)))
        add!(data, Triple(EX("B"), EX("value"), Literal("5", datatype=xsd_int)))

        # Rule: {?X :value ?V. ?V math:greaterThan "7"} => {?X :isHigh true}
        ant = [
            Triple(Variable("X"), EX("value"), Variable("V")),
            Triple(Variable("V"), math_gt, Literal("7", datatype=xsd_int))
        ]
        con = [Triple(Variable("X"), EX("isHigh"), Literal(true))]
        rule = N3Rule(ant, con, FORWARD, nothing,
                      Set([Variable("X"), Variable("V")]))

        reasoner = N3Reasoner(data, [rule])
        eam_loop!(reasoner)

        @test Triple(EX("A"), EX("isHigh"), Literal(true)) in reasoner.facts
        @test !(Triple(EX("B"), EX("isHigh"), Literal(true)) in reasoner.facts)
    end

end
