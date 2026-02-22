"""Type of inference step."""
@enum StepType EXTRACTION INFERENCE

"""
    ProofStep

A single step in a proof trace.
"""
struct ProofStep
    step_type::StepType
    conclusion::Vector{Triple}      # What was derived
    evidence::Vector{ProofStep}     # Supporting steps (for INFERENCE)
    rule::Union{Vector{Triple}, Nothing}  # The rule used (antecedent patterns)
    bindings::Dict{Variable, Identifier}  # Variable bindings used
    source::Union{String, Nothing}  # Source file/URI for EXTRACTION
end

"""Create an extraction step (fact from input data)."""
function extraction_step(triple::Triple; source::Union{String, Nothing}=nothing)
    ProofStep(EXTRACTION, [triple], ProofStep[], nothing, Dict{Variable, Identifier}(), source)
end

"""Create an inference step (derived from a rule + evidence)."""
function inference_step(conclusion::Vector{Triple}, evidence::Vector{ProofStep},
                        rule_antecedent::Vector{Triple}, bindings::Dict{Variable, Identifier})
    ProofStep(INFERENCE, conclusion, evidence, rule_antecedent, bindings, nothing)
end

"""
    ProofTrace

Complete proof trace for a reasoning session.
"""
mutable struct ProofTrace
    steps::Vector{ProofStep}
    extractions::Dict{Triple, ProofStep}  # Cache: triple → extraction step
end

ProofTrace() = ProofTrace(ProofStep[], Dict{Triple, ProofStep}())

"""Record an extraction (input fact)."""
function record_extraction!(trace::ProofTrace, triple::Triple; source=nothing)
    step = extraction_step(triple; source=source)
    push!(trace.steps, step)
    trace.extractions[triple] = step
    step
end

"""Record an inference (derived fact)."""
function record_inference!(trace::ProofTrace, conclusions::Vector{Triple},
                           evidence_triples::Vector{Triple}, rule_antecedent::Vector{Triple},
                           bindings::Dict{Variable, Identifier})
    # Look up evidence steps
    evidence = ProofStep[]
    for t in evidence_triples
        if haskey(trace.extractions, t)
            push!(evidence, trace.extractions[t])
        else
            # Find inference step that produced this
            found = false
            for s in trace.steps
                if s.step_type == INFERENCE && t in s.conclusion
                    push!(evidence, s)
                    found = true
                    break
                end
            end
            if !found
                push!(evidence, extraction_step(t))
            end
        end
    end

    step = inference_step(conclusions, evidence, rule_antecedent, bindings)
    push!(trace.steps, step)
    for c in conclusions
        trace.extractions[c] = step
    end
    step
end

"""
    proof_to_n3(trace::ProofTrace) -> String

Serialize a proof trace as N3 using the reason: vocabulary,
compatible with EYE's proof output format.
"""
function proof_to_n3(trace::ProofTrace)
    io = IOBuffer()

    # Prefixes
    println(io, "@prefix r: <http://www.w3.org/2000/10/swap/reason#>.")
    println(io, "@prefix n3: <http://www.w3.org/2004/06/rei#>.")
    println(io, "@prefix var: <http://www.w3.org/2000/10/swap/var#>.")
    println(io)

    lemma_count = 0
    step_ids = Dict{ProofStep, String}()

    # First pass: assign IDs
    for step in trace.steps
        lemma_count += 1
        step_ids[step] = "_:lemma$lemma_count"
    end

    # Proof root
    inferences = filter(s -> s.step_type == INFERENCE, trace.steps)
    if !isempty(inferences)
        println(io, "_:proof a r:Proof, r:Conjunction;")
        components = [step_ids[s] for s in inferences]
        println(io, "    r:component ", join(components, ", "), ";")
        println(io, "    r:gives {")
        for s in inferences
            for c in s.conclusion
                println(io, "        ", _proof_n3_term(c.subject), " ", _proof_n3_term(c.predicate), " ", _proof_n3_term(c.object), " .")
            end
        end
        println(io, "    }.")
        println(io)
    end

    # Each step
    for step in trace.steps
        sid = step_ids[step]
        if step.step_type == EXTRACTION
            println(io, "$sid a r:Extraction;")
            println(io, "    r:gives {")
            for c in step.conclusion
                println(io, "        ", _proof_n3_term(c.subject), " ", _proof_n3_term(c.predicate), " ", _proof_n3_term(c.object), " .")
            end
            println(io, "    };")
            src = something(step.source, "input")
            println(io, "    r:because [ a r:Parsing; r:source <$src>].")
        else
            println(io, "$sid a r:Inference;")
            println(io, "    r:gives {")
            for c in step.conclusion
                println(io, "        ", _proof_n3_term(c.subject), " ", _proof_n3_term(c.predicate), " ", _proof_n3_term(c.object), " .")
            end
            println(io, "    };")
            if !isempty(step.evidence)
                ev_ids = [get(step_ids, e, "_:unknown") for e in step.evidence]
                println(io, "    r:evidence (", join(ev_ids, " "), ");")
            end
            if !isempty(step.bindings)
                for (var, val) in step.bindings
                    println(io, "    r:binding [ r:variable [ n3: uri \"http://www.w3.org/2000/10/swap/var#$(var.name)\"]; r:boundTo ", _proof_n3_term(val), "];")
                end
            end
            println(io, "    .")
        end
        println(io)
    end

    String(take!(io))
end

function _proof_n3_term(t::URIRef)
    "<$(t.value)>"
end

function _proof_n3_term(t::BNode)
    "_:$(t.id)"
end

function _proof_n3_term(t::Literal)
    n3(t)
end

function _proof_n3_term(t::Variable)
    "?$(t.name)"
end

function _proof_n3_term(t::Identifier)
    string(t)
end

"""
    proof_to_graph(trace::ProofTrace) -> RDFGraph

Convert a proof trace to an RDF graph using the reason: vocabulary.
"""
function proof_to_graph(trace::ProofTrace)
    g = RDFGraph()
    REASON = Namespace("http://www.w3.org/2000/10/swap/reason#")

    for (i, step) in enumerate(trace.steps)
        node = BNode("step$i")
        if step.step_type == EXTRACTION
            add!(g, node, RDF.type, REASON("Extraction"))
        else
            add!(g, node, RDF.type, REASON("Inference"))
        end

        # Add conclusion triples as a separate blank node
        for (j, c) in enumerate(step.conclusion)
            stmt = BNode("step$(i)_conc$j")
            add!(g, node, REASON("gives"), stmt)
            add!(g, stmt, RDF.type, RDF("Statement"))
            add!(g, stmt, RDF("subject"), c.subject)
            add!(g, stmt, RDF("predicate"), c.predicate)
            add!(g, stmt, RDF("object"), c.object)
        end
    end

    g
end
