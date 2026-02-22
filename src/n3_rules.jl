# ─── N3 Rule Representation ─────────────────────────────────────────
# Extracts implication rules from N3 graphs for reasoning.

"""Direction of an N3 rule."""
@enum RuleDirection FORWARD BACKWARD

"""
    N3Rule

An N3 implication rule extracted from a graph.
"""
struct N3Rule
    antecedent::Vector{Triple}    # patterns in the IF part (may contain Variables)
    consequent::Vector{Triple}    # patterns in the THEN part (may contain Variables)
    direction::RuleDirection      # FORWARD (=>) or BACKWARD (<=)
    source::Union{String, Nothing}
    variables::Set{Variable}     # all variables appearing in the rule
end

"""
    extract_rules(g::RDFGraph) -> Vector{N3Rule}

Find all `log:implies` triples where subject/object are Formulas,
extract the triple patterns from each Formula's graph, collect Variables.
"""
function extract_rules(g::RDFGraph)
    rules = N3Rule[]
    log_implies = URIRef("http://www.w3.org/2000/10/swap/log#implies")
    log_impliedBy = URIRef("http://www.w3.org/2000/10/swap/log#impliedBy")

    # Forward rules: {antecedent} log:implies {consequent}
    for t in triples(g, (nothing, log_implies, nothing))
        if t.subject isa Formula && t.object isa Formula
            ant_triples = collect(t.subject.graph)
            con_triples = collect(t.object.graph)
            vars = Set{Variable}()
            for tt in vcat(ant_triples, con_triples)
                _collect_vars!(vars, tt)
            end
            push!(rules, N3Rule(ant_triples, con_triples, FORWARD, nothing, vars))
        end
    end

    # Backward rules: {consequent} log:impliedBy {antecedent}
    for t in triples(g, (nothing, log_impliedBy, nothing))
        if t.subject isa Formula && t.object isa Formula
            ant_triples = collect(t.object.graph)    # object is antecedent
            con_triples = collect(t.subject.graph)   # subject is consequent
            vars = Set{Variable}()
            for tt in vcat(ant_triples, con_triples)
                _collect_vars!(vars, tt)
            end
            push!(rules, N3Rule(ant_triples, con_triples, BACKWARD, nothing, vars))
        end
    end

    rules
end

function _collect_vars!(vars::Set{Variable}, t::Triple)
    t.subject isa Variable && push!(vars, t.subject)
    t.predicate isa Variable && push!(vars, t.predicate)
    t.object isa Variable && push!(vars, t.object)
end

"""
    RuleSet

Collection of rules with indexing by consequent predicate for fast backward lookup.
"""
struct RuleSet
    forward_rules::Vector{N3Rule}
    backward_rules::Vector{N3Rule}
    all_rules::Vector{N3Rule}
    predicate_index::Dict{URIRef, Vector{N3Rule}}
end

function RuleSet(rules::Vector{N3Rule})
    fwd = filter(r -> r.direction == FORWARD, rules)
    bwd = filter(r -> r.direction == BACKWARD, rules)
    idx = Dict{URIRef, Vector{N3Rule}}()
    for r in rules
        for t in r.consequent
            if t.predicate isa URIRef
                push!(get!(idx, t.predicate, N3Rule[]), r)
            end
        end
    end
    RuleSet(fwd, bwd, rules, idx)
end
