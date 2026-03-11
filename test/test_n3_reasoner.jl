@testset "N3 Reasoner" begin

    RDF_TYPE = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    RDFS_SUBCLASSOF = URIRef("http://www.w3.org/2000/01/rdf-schema#subClassOf")
    EX = RDFLib.Namespace("http://example.org/")

    # ── 1. Socrates ──────────────────────────────────────────────────
    @testset "Socrates — basic subclass inference" begin
        n3str = """
        @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#>.
        @prefix : <http://example.org/socrates#>.

        :Socrates a :Human.
        :Human rdfs:subClassOf :Mortal.

        {?A rdfs:subClassOf ?B. ?S a ?A} => {?S a ?B}.
        """
        g = parse_n3(n3str)
        result = reason(g)

        socrates = URIRef("http://example.org/socrates#Socrates")
        mortal = URIRef("http://example.org/socrates#Mortal")
        human = URIRef("http://example.org/socrates#Human")

        @test Triple(socrates, RDF_TYPE, mortal) in result
        @test Triple(socrates, RDF_TYPE, human) in result
    end

    # ── 2. Transitive closure ────────────────────────────────────────
    @testset "Transitive closure — chain of subClassOf" begin
        n3str = """
        @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#>.
        @prefix : <http://example.org/>.

        :Dog rdfs:subClassOf :Canine.
        :Canine rdfs:subClassOf :Mammal.
        :Mammal rdfs:subClassOf :Animal.
        :Fido a :Dog.

        {?A rdfs:subClassOf ?B. ?S a ?A} => {?S a ?B}.
        {?A rdfs:subClassOf ?B. ?B rdfs:subClassOf ?C} => {?A rdfs:subClassOf ?C}.
        """
        g = parse_n3(n3str)
        result = reason(g)

        fido = URIRef("http://example.org/Fido")
        dog = URIRef("http://example.org/Dog")
        canine = URIRef("http://example.org/Canine")
        mammal = URIRef("http://example.org/Mammal")
        animal = URIRef("http://example.org/Animal")

        @test Triple(fido, RDF_TYPE, canine) in result
        @test Triple(fido, RDF_TYPE, mammal) in result
        @test Triple(fido, RDF_TYPE, animal) in result
        @test Triple(dog, RDFS_SUBCLASSOF, mammal) in result
        @test Triple(dog, RDFS_SUBCLASSOF, animal) in result
        @test Triple(canine, RDFS_SUBCLASSOF, animal) in result
    end

    # ── 3. Multiple rules ────────────────────────────────────────────
    @testset "Multiple rules fire" begin
        n3str = """
        @prefix : <http://example.org/>.

        :Alice :knows :Bob.
        :Bob :knows :Carol.

        {?X :knows ?Y} => {?Y :knownBy ?X}.
        {?X :knows ?Y. ?Y :knows ?Z} => {?X :indirectlyKnows ?Z}.
        """
        g = parse_n3(n3str)
        result = reason(g)

        alice = URIRef("http://example.org/Alice")
        bob = URIRef("http://example.org/Bob")
        carol = URIRef("http://example.org/Carol")
        known_by = URIRef("http://example.org/knownBy")
        indirectly = URIRef("http://example.org/indirectlyKnows")

        @test Triple(bob, known_by, alice) in result
        @test Triple(carol, known_by, bob) in result
        @test Triple(alice, indirectly, carol) in result
    end

    # ── 4. Fixed-point — cascading rules ─────────────────────────────
    @testset "Fixed-point — derived facts trigger further rules" begin
        n3str = """
        @prefix : <http://example.org/>.

        :a :next :b.
        :b :next :c.
        :c :next :d.

        {?X :next ?Y} => {?X :reachable ?Y}.
        {?X :reachable ?Y. ?Y :next ?Z} => {?X :reachable ?Z}.
        """
        g = parse_n3(n3str)
        result = reason(g)

        a = URIRef("http://example.org/a")
        b = URIRef("http://example.org/b")
        c = URIRef("http://example.org/c")
        d = URIRef("http://example.org/d")
        reachable = URIRef("http://example.org/reachable")

        @test Triple(a, reachable, b) in result
        @test Triple(a, reachable, c) in result
        @test Triple(a, reachable, d) in result
        @test Triple(b, reachable, c) in result
        @test Triple(b, reachable, d) in result
        @test Triple(c, reachable, d) in result
    end

    # ── 5. No infinite loop — cyclic data ────────────────────────────
    @testset "Euler path — cyclic rule terminates" begin
        n3str = """
        @prefix : <http://example.org/>.

        :a :rel :b.
        :b :rel :a.

        {?X :rel ?Y} => {?X :connected ?Y}.
        {?X :connected ?Y. ?Y :rel ?Z} => {?X :connected ?Z}.
        """
        g = parse_n3(n3str)
        result = reason(g; max_iterations=100)

        a = URIRef("http://example.org/a")
        b = URIRef("http://example.org/b")
        connected = URIRef("http://example.org/connected")

        @test Triple(a, connected, b) in result
        @test Triple(b, connected, a) in result
        # The key test is that we get here without hanging
        @test length(result) < 100
    end

    # ── 6. pass_only_new ─────────────────────────────────────────────
    @testset "pass_only_new returns only derived facts" begin
        n3str = """
        @prefix : <http://example.org/>.
        @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#>.

        :Socrates a :Human.
        :Human rdfs:subClassOf :Mortal.

        {?A rdfs:subClassOf ?B. ?S a ?A} => {?S a ?B}.
        """
        g = parse_n3(n3str)
        derived = reason(g; pass_only_new=true)

        socrates = URIRef("http://example.org/Socrates")
        mortal = URIRef("http://example.org/Mortal")
        human = URIRef("http://example.org/Human")

        @test Triple(socrates, RDF_TYPE, mortal) in derived
        # Original facts should NOT be in pass_only_new output
        @test !(Triple(socrates, RDF_TYPE, human) in derived)
    end

    # ── 7. Empty rules / data ────────────────────────────────────────
    @testset "Edge cases — empty rules and data" begin
        # No rules, just data
        g = RDFGraph()
        add!(g, Triple(EX("s"), EX("p"), EX("o")))
        result = reason(g)
        @test Triple(EX("s"), EX("p"), EX("o")) in result

        # Empty graph
        empty_g = RDFGraph()
        result2 = reason(empty_g)
        @test length(result2) == 0

        # Rules but no matching data
        n3str = """
        @prefix : <http://example.org/>.
        {?X :foo ?Y} => {?X :bar ?Y}.
        """
        g3 = parse_n3(n3str)
        result3 = reason(g3; pass_only_new=true)
        @test length(result3) == 0
    end

    # ── 8. Separate rules graph ──────────────────────────────────────
    @testset "Separate rules and data graphs" begin
        data = RDFGraph()
        socrates = URIRef("http://example.org/Socrates")
        human = URIRef("http://example.org/Human")
        mortal = URIRef("http://example.org/Mortal")
        add!(data, Triple(socrates, RDF_TYPE, human))
        add!(data, Triple(human, RDFS_SUBCLASSOF, mortal))

        rules_n3 = """
        @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#>.
        {?A rdfs:subClassOf ?B. ?S a ?A} => {?S a ?B}.
        """
        rules_g = parse_n3(rules_n3)

        result = reason(data; rules=rules_g)
        @test Triple(socrates, RDF_TYPE, mortal) in result
    end

    # ── 9. Query filtering ───────────────────────────────────────────
    @testset "Query filtering" begin
        n3str = """
        @prefix : <http://example.org/>.
        @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#>.

        :Socrates a :Human.
        :Human rdfs:subClassOf :Mortal.
        :Plato a :Human.

        {?A rdfs:subClassOf ?B. ?S a ?A} => {?S a ?B}.
        """
        g = parse_n3(n3str)

        # Query: select only the "a :Mortal" triples
        query_n3 = """
        @prefix : <http://example.org/>.
        {?S a :Mortal} => {?S a :Mortal}.
        """
        query_g = parse_n3(query_n3)

        result = reason(g; query=query_g)

        socrates = URIRef("http://example.org/Socrates")
        plato = URIRef("http://example.org/Plato")
        mortal = URIRef("http://example.org/Mortal")

        @test Triple(socrates, RDF_TYPE, mortal) in result
        @test Triple(plato, RDF_TYPE, mortal) in result
        # Original data should not appear in query-filtered output
        human = URIRef("http://example.org/Human")
        @test !(Triple(human, RDFS_SUBCLASSOF, mortal) in result)
    end

    # ── 10. N3Reasoner struct ────────────────────────────────────────
    @testset "N3Reasoner construction and direct use" begin
        data = RDFGraph()
        s = URIRef("http://example.org/s")
        p = URIRef("http://example.org/p")
        o = URIRef("http://example.org/o")
        add!(data, Triple(s, p, o))

        reasoner = N3Reasoner(data, N3Rule[])
        @test reasoner.inference_count == 0
        @test isempty(reasoner.derived)

        eam_loop!(reasoner)
        @test reasoner.inference_count == 0
    end

    # ── 11. max_inferences limit ─────────────────────────────────────
    @testset "max_inferences stops reasoning" begin
        n3str = """
        @prefix : <http://example.org/>.
        @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#>.

        :A rdfs:subClassOf :B.
        :B rdfs:subClassOf :C.
        :C rdfs:subClassOf :D.
        :D rdfs:subClassOf :E.
        :x a :A.

        {?A rdfs:subClassOf ?B. ?S a ?A} => {?S a ?B}.
        {?A rdfs:subClassOf ?B. ?B rdfs:subClassOf ?C} => {?A rdfs:subClassOf ?C}.
        """
        g = parse_n3(n3str)
        result = reason(g; max_inferences=2, pass_only_new=true)
        @test length(result) <= 2
    end

    # ── 12. Compare with EYE ─────────────────────────────────────────
    @testset "Compare with EYE reasoner" begin
        swipl = Sys.which("swipl")
        eye = get(ENV, "EYE_PATH", joinpath(dirname(@__DIR__), "..", "eye", "eye.pl"))

        if swipl !== nothing && isfile(swipl) && isfile(eye)
            # Write data file
            data_file = tempname() * ".n3"
            query_file = tempname() * ".n3"

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

            write(data_file, data_n3)
            write(query_file, query_n3)

            try
                eye_output = read(`$swipl -g main -t halt $eye -- --nope --pass-only-new $data_file --query $query_file`, String)

                # EYE should produce :Socrates a :Mortal
                @test occursin("Socrates", eye_output)
                @test occursin("Mortal", eye_output)

                # Julia reasoner should agree
                g = parse_n3(data_n3)
                qg = parse_n3(query_n3)
                result = reason(g; query=qg)

                socrates = URIRef("http://example.org/socrates#Socrates")
                mortal = URIRef("http://example.org/socrates#Mortal")
                @test Triple(socrates, RDF_TYPE, mortal) in result
            finally
                rm(data_file; force=true)
                rm(query_file; force=true)
            end
        else
            @info "Skipping EYE comparison — swipl or eye.pl not found"
        end
    end

    # ── 13. Builtin predicates in rules ──────────────────────────────
    @testset "Rules with builtin predicates" begin
        # Build programmatically since math builtins need specific structure
        data = RDFGraph()
        ex = RDFLib.Namespace("http://example.org/")
        xsd_int = URIRef("http://www.w3.org/2001/XMLSchema#integer")

        add!(data, Triple(ex("item1"), ex("value"), Literal("10", datatype=xsd_int)))
        add!(data, Triple(ex("item2"), ex("value"), Literal("5", datatype=xsd_int)))
        add!(data, Triple(ex("item3"), ex("value"), Literal("20", datatype=xsd_int)))

        # Create rule: {?X :value ?V. ?V math:greaterThan "7"} => {?X a :HighValue}
        math_gt = URIRef("http://www.w3.org/2000/10/swap/math#greaterThan")
        ant = [
            Triple(Variable("X"), ex("value"), Variable("V")),
            Triple(Variable("V"), math_gt, Literal("7", datatype=xsd_int))
        ]
        con = [Triple(Variable("X"), RDF_TYPE, ex("HighValue"))]
        rule = N3Rule(ant, con, FORWARD, nothing, Set([Variable("X"), Variable("V")]))

        rules = RDFLib.extract_rules(RDFGraph())
        push!(rules, rule)

        reasoner = N3Reasoner(data, rules)
        eam_loop!(reasoner)

        @test Triple(ex("item1"), RDF_TYPE, ex("HighValue")) in reasoner.facts
        @test Triple(ex("item3"), RDF_TYPE, ex("HighValue")) in reasoner.facts
        @test !(Triple(ex("item2"), RDF_TYPE, ex("HighValue")) in reasoner.facts)
    end

end
