using Test
using RDFLib

@testset "N3 Proof" begin

    # Shared terms
    socrates = URIRef("http://example.org/Socrates")
    human    = URIRef("http://example.org/Human")
    mortal   = URIRef("http://example.org/Mortal")
    rdf_type = RDF.type
    subclass = RDFS.subClassOf

    @testset "extraction_step" begin
        t = Triple(socrates, rdf_type, human)
        step = extraction_step(t)
        @test step.step_type == EXTRACTION
        @test length(step.conclusion) == 1
        @test step.conclusion[1] === t
        @test isempty(step.evidence)
        @test step.rule === nothing
        @test isempty(step.bindings)
        @test step.source === nothing

        step2 = extraction_step(t; source="http://example.org/data.n3")
        @test step2.source == "http://example.org/data.n3"
    end

    @testset "inference_step" begin
        t1 = Triple(socrates, rdf_type, human)
        t2 = Triple(human, subclass, mortal)
        conclusion = Triple(socrates, rdf_type, mortal)

        ev1 = extraction_step(t1)
        ev2 = extraction_step(t2)

        x = Variable("x")
        y = Variable("y")
        z = Variable("z")
        rule_ant = [Triple(x, rdf_type, y), Triple(y, subclass, z)]
        binds = Dict{Variable, Identifier}(x => socrates, y => human, z => mortal)

        step = inference_step([conclusion], [ev1, ev2], rule_ant, binds)
        @test step.step_type == INFERENCE
        @test length(step.conclusion) == 1
        @test step.conclusion[1] === conclusion
        @test length(step.evidence) == 2
        @test step.rule == rule_ant
        @test step.bindings[x] === socrates
        @test step.source === nothing
    end

    @testset "ProofTrace" begin
        trace = ProofTrace()
        @test isempty(trace.steps)
        @test isempty(trace.extractions)

        t1 = Triple(socrates, rdf_type, human)
        t2 = Triple(human, subclass, mortal)
        conclusion = Triple(socrates, rdf_type, mortal)

        s1 = record_extraction!(trace, t1; source="data.n3")
        s2 = record_extraction!(trace, t2; source="data.n3")
        @test length(trace.steps) == 2
        @test haskey(trace.extractions, t1)
        @test haskey(trace.extractions, t2)

        x = Variable("x")
        y = Variable("y")
        z = Variable("z")
        rule_ant = [Triple(x, rdf_type, y), Triple(y, subclass, z)]
        binds = Dict{Variable, Identifier}(x => socrates, y => human, z => mortal)

        s3 = record_inference!(trace, [conclusion], [t1, t2], rule_ant, binds)
        @test length(trace.steps) == 3
        @test s3.step_type == INFERENCE
        @test length(s3.evidence) == 2
        @test s3.evidence[1] === s1
        @test s3.evidence[2] === s2
    end

    @testset "proof_to_n3" begin
        trace = ProofTrace()
        t1 = Triple(socrates, rdf_type, human)
        t2 = Triple(human, subclass, mortal)
        conclusion = Triple(socrates, rdf_type, mortal)

        record_extraction!(trace, t1; source="http://example.org/data.n3")
        record_extraction!(trace, t2; source="http://example.org/data.n3")

        x = Variable("x")
        y = Variable("y")
        z = Variable("z")
        rule_ant = [Triple(x, rdf_type, y), Triple(y, subclass, z)]
        binds = Dict{Variable, Identifier}(x => socrates, y => human, z => mortal)
        record_inference!(trace, [conclusion], [t1, t2], rule_ant, binds)

        n3_str = proof_to_n3(trace)

        @test occursin("r:Proof", n3_str)
        @test occursin("r:Extraction", n3_str)
        @test occursin("r:Inference", n3_str)
        @test occursin("r:gives", n3_str)
        @test occursin("r:evidence", n3_str)
        @test occursin("r:binding", n3_str)
        @test occursin("@prefix r:", n3_str)
        @test occursin("<http://example.org/Socrates>", n3_str)
    end

    @testset "proof_to_graph" begin
        trace = ProofTrace()
        t1 = Triple(socrates, rdf_type, human)
        t2 = Triple(human, subclass, mortal)
        conclusion = Triple(socrates, rdf_type, mortal)

        record_extraction!(trace, t1)
        record_extraction!(trace, t2)

        x = Variable("x")
        binds = Dict{Variable, Identifier}(x => socrates)
        record_inference!(trace, [conclusion], [t1, t2],
                          [Triple(x, rdf_type, human)], binds)

        g = proof_to_graph(trace)
        reason_ns = Namespace("http://www.w3.org/2000/10/swap/reason#")

        # 3 steps × (1 type + 5 per conclusion) = 18
        @test length(g) == 18

        # Check for Extraction and Inference types
        extraction_type = reason_ns("Extraction")
        inference_type = reason_ns("Inference")
        ext_count = length(collect(triples(g, (nothing, RDF.type, extraction_type))))
        inf_count = length(collect(triples(g, (nothing, RDF.type, inference_type))))
        @test ext_count == 2
        @test inf_count == 1
    end

    @testset "Integration: Socrates proof" begin
        # Full proof: Socrates is Human, Human subClassOf Mortal => Socrates is Mortal
        trace = ProofTrace()

        t1 = Triple(socrates, rdf_type, human)
        t2 = Triple(human, subclass, mortal)
        conclusion = Triple(socrates, rdf_type, mortal)

        record_extraction!(trace, t1; source="http://example.org/facts.n3")
        record_extraction!(trace, t2; source="http://example.org/ontology.n3")

        x = Variable("x")
        y = Variable("y")
        z = Variable("z")
        rule_ant = [Triple(x, rdf_type, y), Triple(y, subclass, z)]
        binds = Dict{Variable, Identifier}(x => socrates, y => human, z => mortal)
        record_inference!(trace, [conclusion], [t1, t2], rule_ant, binds)

        # Verify trace structure
        @test length(trace.steps) == 3
        @test trace.steps[1].step_type == EXTRACTION
        @test trace.steps[2].step_type == EXTRACTION
        @test trace.steps[3].step_type == INFERENCE

        # N3 output
        n3_str = proof_to_n3(trace)
        @test occursin("r:Proof", n3_str)
        @test occursin("r:Extraction", n3_str)
        @test occursin("r:Inference", n3_str)
        @test occursin("r:gives", n3_str)
        @test occursin("r:evidence", n3_str)
        @test occursin("r:binding", n3_str)

        # Graph output
        g = proof_to_graph(trace)
        @test length(g) > 0
    end
end
