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
# Convert BNodes in rule antecedent patterns to Variables (existential quantifiers).
# BNodes shared between antecedent and consequent get the same Variable.
# BNodes only in the consequent stay as BNodes (fresh existentials).
# BNodes that are part of RDF list structure (rdf:first/rdf:rest) are kept as BNodes.
function _bnodes_to_vars(ant_triples::Vector{Triple}, con_triples::Vector{Triple})
    rdf_first = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
    rdf_rest = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")

    # Identify BNodes that form complete collection structure (have BOTH rdf:first and rdf:rest as subject)
    has_first = Set{BNode}()
    has_rest = Set{BNode}()
    for t in ant_triples
        if t.predicate == rdf_first && t.subject isa BNode
            push!(has_first, t.subject)
        end
        if t.predicate == rdf_rest && t.subject isa BNode
            push!(has_rest, t.subject)
        end
    end
    # A BNode is a list structure node only if it has BOTH rdf:first and rdf:rest
    list_bnodes = intersect(has_first, has_rest)
    # Also add BNodes that appear as rdf:rest objects of list nodes
    for t in ant_triples
        if t.predicate == rdf_rest && t.subject isa BNode && t.subject in list_bnodes && t.object isa BNode
            push!(list_bnodes, t.object)
        end
    end

    bnode_map = Dict{BNode, Variable}()
    function _conv(term::BNode)
        term in list_bnodes && return term  # Keep list structure BNodes
        get!(bnode_map, term) do
            Variable("_bn_" * term.id)
        end
    end

    # Recursively convert BNodes in a Formula
    function _conv_formula(f::Formula)
        new_f = Formula()
        for t in f.graph
            s = t.subject isa BNode ? _conv(t.subject) : t.subject
            o = t.object isa BNode ? _conv(t.object) : t.object
            s = s isa Formula ? _conv_formula(s) : s
            o = o isa Formula ? _conv_formula(o) : o
            add!(new_f, Triple(s, t.predicate, o))
        end
        new_f
    end

    function _conv_triple_ant(t::Triple)
        s = t.subject isa BNode ? _conv(t.subject) : t.subject
        o = t.object isa BNode ? _conv(t.object) : t.object
        s = s isa Formula ? _conv_formula(s) : s
        o = o isa Formula ? _conv_formula(o) : o
        Triple(s, t.predicate, o)
    end

    new_ant = [_conv_triple_ant(t) for t in ant_triples]

    # Collect all BNodes that were converted (from antecedent)
    ant_converted = Set(keys(bnode_map))

    function _conv_triple_con(t::Triple)
        s = (t.subject isa BNode && t.subject in ant_converted) ? _conv(t.subject) : t.subject
        o = (t.object isa BNode && t.object in ant_converted) ? _conv(t.object) : t.object
        Triple(s, t.predicate, o)
    end
    new_con = [_conv_triple_con(t) for t in con_triples]
    return new_ant, new_con
end

function extract_rules(g::RDFGraph)
    rules = N3Rule[]
    log_implies = URIRef("http://www.w3.org/2000/10/swap/log#implies")
    log_impliedBy = URIRef("http://www.w3.org/2000/10/swap/log#impliedBy")

    # Forward rules: {antecedent} log:implies {consequent}
    for t in triples(g, (nothing, log_implies, nothing))
        if t.subject isa Formula && t.object isa Formula
            ant_triples = collect(t.subject.graph)
            con_triples = collect(t.object.graph)
            ant_triples, con_triples = _bnodes_to_vars(ant_triples, con_triples)
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
            ant_triples, con_triples = _bnodes_to_vars(ant_triples, con_triples)
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
