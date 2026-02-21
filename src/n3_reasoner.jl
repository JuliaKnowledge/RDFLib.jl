# ─── N3 Reasoner (Euler Abstract Machine) ────────────────────────────
# Forward/backward chaining N3 reasoner with cycle detection (Euler paths).

"""
    N3Reasoner

The Euler Abstract Machine — a forward/backward chaining N3 reasoner
with cycle detection (Euler paths).
"""
mutable struct N3Reasoner
    facts::RDFGraph
    ruleset::RuleSet
    derived::Set{Triple}
    euler_path::Set{UInt64}
    max_iterations::Int
    max_inferences::Int
    inference_count::Int
    proof_steps::Vector{Any}
end

function N3Reasoner(facts::RDFGraph, rules::Vector{N3Rule};
                    max_iterations::Int=1000, max_inferences::Int=1000000)
    N3Reasoner(
        facts,
        RuleSet(rules),
        Set{Triple}(),
        Set{UInt64}(),
        max_iterations,
        max_inferences,
        0,
        []
    )
end

# ─── Matching with builtins ─────────────────────────────────────────

function _match_with_builtins(patterns::Vector{Triple}, graph::RDFGraph, bindings::Binding;
                              reasoner::Union{N3Reasoner, Nothing}=nothing)
    regular = Triple[]
    builtin = Triple[]
    list_structure = Triple[]  # rdf:first/rdf:rest triples from collections in rule patterns

    rdf_first = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
    rdf_rest = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")

    for p in patterns
        if p.predicate isa URIRef && is_builtin(p.predicate)
            push!(builtin, p)
        elseif p.predicate == rdf_first || p.predicate == rdf_rest
            # Check if subject is a BNode (collection structure) — keep for list resolution
            if p.subject isa BNode
                push!(list_structure, p)
            else
                push!(regular, p)
            end
        else
            push!(regular, p)
        end
    end

    # Build a combined graph for builtin evaluation: working graph + list structure
    eval_graph = graph
    if !isempty(list_structure)
        eval_graph = RDFGraph()
        for t in triples(graph, (nothing, nothing, nothing))
            add!(eval_graph, t)
        end
        for t in list_structure
            add!(eval_graph, t)
        end
    end

    base_bindings = if reasoner !== nothing && !isempty(reasoner.ruleset.backward_rules)
        _match_with_backward(regular, graph, bindings, reasoner; list_graph=eval_graph)
    else
        match_conjunction(regular, graph, bindings; list_graph=(!isempty(list_structure) ? eval_graph : nothing))
    end

    isempty(builtin) && return base_bindings

    results = Binding[]
    for b in base_bindings
        _apply_builtins!(results, builtin, 1, b, eval_graph)
    end
    return results
end

function _apply_builtins!(results::Vector{Binding}, builtins::Vector{Triple},
                          idx::Int, bindings::Binding, graph::RDFGraph)
    if idx > length(builtins)
        push!(results, bindings)
        return
    end

    bt = builtins[idx]
    subj = apply_bindings(bt.subject, bindings)
    obj = apply_bindings(bt.object, bindings)

    new_bindings_list = evaluate_builtin(bt.predicate, subj, obj, bindings, graph)
    for new_b in new_bindings_list
        _apply_builtins!(results, builtins, idx + 1, new_b, graph)
    end
end

# ─── Backward chaining integration into pattern matching ───────────

"""Match conjunction with backward chaining support for computed predicates."""
function _match_with_backward(patterns::Vector{Triple}, graph::RDFGraph,
                               bindings::Binding, reasoner::N3Reasoner;
                               list_graph::Union{RDFGraph, Nothing}=nothing)
    isempty(patterns) && return [bindings]
    results = Binding[]
    _match_backward_recursive!(results, patterns, 1, graph, bindings, reasoner, list_graph)
    return results
end

function _match_backward_recursive!(results::Vector{Binding}, patterns::Vector{Triple},
                                    idx::Int, graph::RDFGraph, bindings::Binding,
                                    reasoner::N3Reasoner,
                                    list_graph::Union{RDFGraph, Nothing}=nothing)
    if idx > length(patterns)
        push!(results, copy(bindings))
        return
    end

    pattern = apply_bindings(patterns[idx], bindings)
    s = pattern.subject isa Variable ? nothing : pattern.subject
    p = pattern.predicate isa Variable ? nothing : pattern.predicate
    o = pattern.object isa Variable ? nothing : pattern.object

    # Widen query for BNode list heads
    s_is_list = (s isa BNode && list_graph !== nothing && _resolve_rdf_list(s, list_graph) !== nothing)
    o_is_list = (o isa BNode && list_graph !== nothing && _resolve_rdf_list(o, list_graph) !== nothing)
    query_s = s_is_list ? nothing : s
    query_o = o_is_list ? nothing : o

    # Try graph matches first
    for fact in triples(graph, (query_s, p, query_o))
        new_bindings = unify_triple(patterns[idx], fact, bindings)
        if new_bindings === nothing && list_graph !== nothing
            new_bindings = _unify_triple_structural(patterns[idx], fact, bindings, list_graph, graph)
        end
        if new_bindings !== nothing
            _match_backward_recursive!(results, patterns, idx + 1, graph, new_bindings, reasoner, list_graph)
        end
    end

    # Then try backward rules
    if pattern.predicate isa URIRef
        for rule in get(reasoner.ruleset.predicate_index, pattern.predicate, N3Rule[])
            rule.direction == BACKWARD || continue
            length(rule.consequent) >= 1 || continue

            con_pattern = rule.consequent[1]
            # Freshen rule variables to avoid conflicts
            var_map = Dict{Variable, Variable}()
            fresh_ant = [_freshen_triple(t, var_map) for t in rule.antecedent]
            fresh_con = _freshen_triple(con_pattern, var_map)

            unified = unify_triple(fresh_con, pattern, Binding())
            unified === nothing && continue

            merged = _merge_bindings(unified, bindings)
            merged === nothing && continue

            # Euler path check
            path_key = hash((hash(rule), hash(merged)))
            path_key in reasoner.euler_path && continue
            push!(reasoner.euler_path, path_key)

            ant_bindings = _match_with_builtins(fresh_ant, graph, merged; reasoner=reasoner)
            for ab in ant_bindings
                # Translate back to original pattern variables
                final_b = copy(bindings)
                for (k, v) in ab
                    if haskey(unified, k) || k in keys(bindings)
                        continue
                    end
                end
                # Merge all bindings
                final_merged = _merge_bindings(bindings, ab)
                final_merged === nothing && continue
                _match_backward_recursive!(results, patterns, idx + 1, graph, final_merged, reasoner, list_graph)
            end

            delete!(reasoner.euler_path, path_key)
        end
    end
end

"""Freshen variables in a triple to avoid name collisions between rules."""
function _freshen_triple(t::Triple, var_map::Dict{Variable, Variable})
    s = _freshen_term(t.subject, var_map)
    p = t.predicate  # predicate stays as-is
    o = _freshen_term(t.object, var_map)
    Triple(s, p, o)
end

function _freshen_term(term::Variable, var_map::Dict{Variable, Variable})
    get!(var_map, term) do
        Variable(term.name * "_" * string(objectid(var_map), base=16)[end-3:end])
    end
end

function _freshen_term(term::Identifier, var_map::Dict{Variable, Variable})
    term
end

# ─── BNode freshening in consequents ───────────────────────────────

"""Replace BNodes in a triple with fresh BNodes (existentials in consequents)."""
function _freshen_bnodes(t::Triple, bnode_map::Dict{BNode, BNode})
    s = _freshen_bnode(t.subject, bnode_map)
    o = _freshen_bnode(t.object, bnode_map)
    Triple(s, t.predicate, o)
end

function _freshen_bnode(term::BNode, bnode_map::Dict{BNode, BNode})
    get!(bnode_map, term) do
        BNode()
    end
end

function _freshen_bnode(term::Identifier, bnode_map::Dict{BNode, BNode})
    term
end

# ─── Forward chaining step ──────────────────────────────────────────

"""Check if a triple exists in graph, using structural list comparison for BNode terms."""
function _triple_exists_structurally(t::Triple, graph::RDFGraph)
    t in graph && return true
    # If object is a BNode (might be list head), check structurally
    if t.object isa BNode
        for existing in triples(graph, (t.subject, t.predicate, nothing))
            if existing.object isa BNode && _terms_equal(t.object, existing.object, graph)
                return true
            end
        end
    end
    # If subject is a BNode
    if t.subject isa BNode
        for existing in triples(graph, (nothing, t.predicate, t.object))
            if existing.subject isa BNode && _terms_equal(t.subject, existing.subject, graph)
                return true
            end
        end
    end
    return false
end

function eam_step!(reasoner::N3Reasoner)::Bool
    new_facts = false

    for rule in reasoner.ruleset.forward_rules
        bindings_list = _match_with_builtins(rule.antecedent, reasoner.facts, Binding();
                                              reasoner=reasoner)

        # Collect BNodes that appear in the raw consequent patterns (existentials)
        consequent_bnodes = Set{BNode}()
        for cp in rule.consequent
            cp.subject isa BNode && push!(consequent_bnodes, cp.subject)
            cp.object isa BNode && push!(consequent_bnodes, cp.object)
        end

        for bindings in bindings_list
            # Fresh BNode map per binding set, only for consequent-pattern BNodes
            bnode_map = Dict{BNode, BNode}()

            for con_pattern in rule.consequent
                grounded = apply_bindings(con_pattern, bindings)
                # Only freshen BNodes that were in the original consequent pattern
                grounded = _freshen_bnodes_selective(grounded, bnode_map, consequent_bnodes)

                if is_ground(grounded) && !_triple_exists_structurally(grounded, reasoner.facts)
                    path_key = hash((hash(rule), hash(grounded)))
                    path_key in reasoner.euler_path && continue
                    push!(reasoner.euler_path, path_key)

                    add!(reasoner.facts, grounded)
                    push!(reasoner.derived, grounded)
                    reasoner.inference_count += 1
                    new_facts = true

                    # Check if derived triple is itself a rule (nested implication)
                    if grounded.predicate == URIRef("http://www.w3.org/2000/10/swap/log#implies")
                        if grounded.subject isa Formula && grounded.object isa Formula
                            new_rule = N3Rule(
                                collect(grounded.subject.graph),
                                collect(grounded.object.graph),
                                FORWARD, nothing,
                                _collect_all_vars(grounded.subject.graph, grounded.object.graph)
                            )
                            push!(reasoner.ruleset.forward_rules, new_rule)
                            for ct in new_rule.consequent
                                if ct.predicate isa URIRef
                                    push!(get!(reasoner.ruleset.predicate_index, ct.predicate, N3Rule[]), new_rule)
                                end
                            end
                        end
                    end

                    reasoner.inference_count >= reasoner.max_inferences && return new_facts
                end
            end
        end
    end

    return new_facts
end

function _collect_all_vars(g1::RDFGraph, g2::RDFGraph)
    vars = Set{Variable}()
    for g in (g1, g2)
        for t in g
            _collect_vars!(vars, t)
        end
    end
    vars
end

"""Replace only BNodes that are in the `eligible` set."""
function _freshen_bnodes_selective(t::Triple, bnode_map::Dict{BNode, BNode}, eligible::Set{BNode})
    s = _freshen_bnode_selective(t.subject, bnode_map, eligible)
    o = _freshen_bnode_selective(t.object, bnode_map, eligible)
    Triple(s, t.predicate, o)
end

function _freshen_bnode_selective(term::BNode, bnode_map::Dict{BNode, BNode}, eligible::Set{BNode})
    term in eligible || return term
    get!(bnode_map, term) do
        BNode()
    end
end

function _freshen_bnode_selective(term::Identifier, bnode_map::Dict{BNode, BNode}, eligible::Set{BNode})
    term
end

# ─── Fixed-point loop ───────────────────────────────────────────────

function eam_loop!(reasoner::N3Reasoner)
    for _ in 1:reasoner.max_iterations
        changed = eam_step!(reasoner)
        !changed && break
        reasoner.inference_count >= reasoner.max_inferences && break
    end
    reasoner
end

# ─── Backward chaining ─────────────────────────────────────────────

function _merge_bindings(a::Binding, b::Binding)::Union{Binding, Nothing}
    merged = copy(a)
    for (k, v) in b
        if haskey(merged, k)
            merged[k] != v && return nothing
        else
            merged[k] = v
        end
    end
    merged
end

function _prove_backward(reasoner::N3Reasoner, goal::Triple, bindings::Binding)::Vector{Binding}
    results = Binding[]
    pred = goal.predicate
    pred isa URIRef || return results

    for rule in get(reasoner.ruleset.predicate_index, pred, N3Rule[])
        rule.direction == BACKWARD || continue

        for con_pattern in rule.consequent
            unified = unify_triple(con_pattern, goal, Binding())
            unified === nothing && continue

            merged = _merge_bindings(unified, bindings)
            merged === nothing && continue

            ant_bindings = _match_with_builtins(rule.antecedent, reasoner.facts, merged;
                                                 reasoner=reasoner)
            append!(results, ant_bindings)
        end
    end
    results
end

# ─── Query filtering ───────────────────────────────────────────────

function _apply_query(reasoner::N3Reasoner, query_graph::RDFGraph)
    query_rules = extract_rules(query_graph)
    result = RDFGraph()

    # If query has rules, use them as SELECT patterns
    if !isempty(query_rules)
        for rule in query_rules
            bindings_list = match_conjunction(rule.antecedent, reasoner.facts)
            for bindings in bindings_list
                for con in rule.consequent
                    grounded = apply_bindings(con, bindings)
                    is_ground(grounded) && add!(result, grounded)
                end
            end
        end
    else
        # Query graph has plain triple patterns — match each
        query_triples = collect(query_graph)
        if !isempty(query_triples)
            bindings_list = match_conjunction(query_triples, reasoner.facts)
            for bindings in bindings_list
                for qt in query_triples
                    grounded = apply_bindings(qt, bindings)
                    is_ground(grounded) && add!(result, grounded)
                end
            end
        end
    end

    result
end

# ─── Public API ─────────────────────────────────────────────────────

"""
    reason(data::RDFGraph; rules=nothing, query=nothing,
           max_iterations=1000, pass_only_new=false) -> RDFGraph

Run the N3 reasoner on `data` with optional `rules` graph.
Rules are N3 implications (`{antecedent} => {consequent}`) extracted from the
rules and/or data graphs.

If `query` is provided, only matching results are returned.
If `pass_only_new` is true, only derived (new) facts are returned.
"""
function reason(data::RDFGraph;
                rules::Union{RDFGraph, Nothing}=nothing,
                query::Union{RDFGraph, Nothing}=nothing,
                max_iterations::Int=1000,
                max_inferences::Int=1000000,
                pass_only_new::Bool=false)
    working = RDFGraph()
    for t in data
        add!(working, t)
    end

    all_rules = N3Rule[]
    if rules !== nothing
        for t in rules
            add!(working, t)
        end
        append!(all_rules, extract_rules(rules))
    end
    append!(all_rules, extract_rules(data))

    # Remove rule (log:implies and log:impliedBy) triples from working graph
    log_implies = URIRef("http://www.w3.org/2000/10/swap/log#implies")
    log_impliedBy = URIRef("http://www.w3.org/2000/10/swap/log#impliedBy")
    for pred in (log_implies, log_impliedBy)
        for t in collect(triples(working, (nothing, pred, nothing)))
            remove!(working, (t.subject, t.predicate, t.object))
        end
    end

    reasoner = N3Reasoner(working, all_rules;
                          max_iterations=max_iterations,
                          max_inferences=max_inferences)
    eam_loop!(reasoner)

    if query !== nothing
        return _apply_query(reasoner, query)
    end

    if pass_only_new
        result = RDFGraph()
        for t in reasoner.derived
            add!(result, t)
        end
        return result
    end

    return reasoner.facts
end
