# ─── N3 Reasoner (Euler Abstract Machine) ────────────────────────────
# Forward/backward chaining N3 reasoner with cycle detection (Euler paths).

const _RDF_FIRST = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
const _RDF_REST  = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
const _LOG_IMPLIES = URIRef("http://www.w3.org/2000/10/swap/log#implies")

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

    for p in patterns
        if p.predicate isa URIRef && is_builtin(p.predicate)
            push!(builtin, p)
        elseif p.predicate == _RDF_FIRST || p.predicate == _RDF_REST
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

    # Add list-structure triples directly to the working graph for list resolution
    # This allows builtins and structural checks to find list elements
    if !isempty(list_structure)
        for t in list_structure
            add!(graph, apply_bindings(t, bindings))
        end
    end

    # Build a separate eval_graph only for structural unification (list_graph)
    eval_graph = !isempty(list_structure) ? graph : nothing

    base_bindings = if reasoner !== nothing && !isempty(reasoner.ruleset.backward_rules)
        _match_with_backward(regular, graph, bindings, reasoner; list_graph=eval_graph)
    else
        match_conjunction(regular, graph, bindings; list_graph=eval_graph)
    end

    isempty(builtin) && return base_bindings

    # Sort builtins so producers come before consumers
    sorted = _sort_builtins(builtin, isempty(base_bindings) ? bindings : base_bindings[1];
                            list_structure=list_structure)

    results = Binding[]
    for b in base_bindings
        _apply_builtins!(results, sorted, 1, b, graph)
    end
    return results
end

"""
Sort builtins topologically: builtins that produce variables should come before
builtins that consume those variables.  Uses Kahn's algorithm on a dependency
graph derived from subject-input / object-output variable analysis.
"""
function _sort_builtins(builtins::Vector{Triple}, bindings::Binding;
                        list_structure::Vector{Triple}=Triple[])
    length(builtins) <= 1 && return builtins

    # Build map: BNode → Variables in its list structure
    bnode_vars = Dict{BNode, Set{Variable}}()
    bnode_rest = Dict{BNode, BNode}()
    for t in list_structure
        t.subject isa BNode || continue
        vars = get!(Set{Variable}, bnode_vars, t.subject)
        t.object isa Variable && push!(vars, t.object)
        if t.predicate == URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest") && t.object isa BNode
            bnode_rest[t.subject] = t.object
        end
    end
    # Propagate vars through rdf:rest chains so list heads see all vars
    changed = true
    while changed
        changed = false
        for (bn, rest_bn) in bnode_rest
            haskey(bnode_vars, rest_bn) || continue
            vars = get!(Set{Variable}, bnode_vars, bn)
            before = length(vars)
            union!(vars, bnode_vars[rest_bn])
            length(vars) > before && (changed = true)
        end
    end

    function _vars(node::Identifier)
        vars = Set{Variable}()
        if node isa Variable
            push!(vars, node)
        elseif node isa BNode && haskey(bnode_vars, node)
            union!(vars, bnode_vars[node])
        end
        return vars
    end

    n = length(builtins)
    initially_bound = Set{Variable}(keys(bindings))

    # Classify builtins for input/output analysis
    _LOG_NS = "http://www.w3.org/2000/10/swap/log#"
    check_only_preds = Set([URIRef(_LOG_NS * "notEqualTo"), URIRef(_LOG_NS * "notIncludes")])
    equalTo_pred = URIRef(_LOG_NS * "equalTo")

    # Compute input/output vars per builtin
    input_vars  = Vector{Set{Variable}}(undef, n)
    output_vars = Vector{Set{Variable}}(undef, n)
    is_check    = falses(n)
    for i in 1:n
        svars = _vars(builtins[i].subject)
        ovars = _vars(builtins[i].object)
        if builtins[i].predicate in check_only_preds
            # Check builtins need ALL vars bound, produce nothing
            input_vars[i]  = union(svars, ovars)
            output_vars[i] = Set{Variable}()
            is_check[i] = true
        elseif builtins[i].predicate == equalTo_pred
            # equalTo can bind either side: subject input → object output, or vice versa
            input_vars[i]  = svars
            output_vars[i] = union(svars, ovars)
        else
            # Standard: subject is input, object is output
            input_vars[i]  = svars
            output_vars[i] = ovars
        end
    end

    # Build dependency edges: i depends on j if i needs a var that j produces
    # (and that var is not already bound from the regular-pattern match)
    deps = [Set{Int}() for _ in 1:n]
    for i in 1:n
        needed = setdiff(input_vars[i], initially_bound)
        for j in 1:n
            i == j && continue
            if !isempty(intersect(needed, output_vars[j]))
                push!(deps[i], j)
            end
        end
    end

    # Kahn's algorithm with priority: prefer non-check builtins
    sorted = Triple[]
    in_degree = [length(deps[i]) for i in 1:n]
    ready = [i for i in 1:n if in_degree[i] == 0]
    processed = Set{Int}()

    while !isempty(ready)
        # Prefer non-check builtins (producers) over checks
        cidx = findfirst(i -> !is_check[i], ready)
        pos = cidx !== nothing ? cidx : 1
        idx = ready[pos]
        deleteat!(ready, pos)
        push!(processed, idx)
        push!(sorted, builtins[idx])
        for i in 1:n
            if i ∉ processed && idx in deps[i]
                delete!(deps[i], idx)
                in_degree[i] -= 1
                if in_degree[i] == 0
                    push!(ready, i)
                end
            end
        end
    end

    # Append any remaining (cycles or unresolved)
    for i in 1:n
        i ∉ processed && push!(sorted, builtins[i])
    end

    return sorted
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

# ─── List destructuring ────────────────────────────────────────────

const _RDF_NIL_URI = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")

"""
Resolve list pattern variables from list-structure triples.
When a binding maps a formula BNode (list head) to a graph BNode (list head),
extract variable bindings by matching the formula's list structure against the graph's list.
"""
function _resolve_list_bindings(bindings_list::Vector{Binding},
                                list_structure::Vector{Triple},
                                eval_graph::RDFGraph,
                                graph::RDFGraph)
    # Build map of formula list heads → list patterns (BNode → [(position, term)])
    # Identify list heads: BNodes that appear as subjects in rdf:first but not as objects in rdf:rest
    all_subjects = Set{BNode}()
    rest_targets = Set{Identifier}()
    for t in list_structure
        t.subject isa BNode && push!(all_subjects, t.subject)
        t.predicate == _RDF_REST && push!(rest_targets, t.object)
    end
    list_heads = setdiff(all_subjects, rest_targets)

    isempty(list_heads) && return bindings_list

    # For each list head, extract the pattern: ordered (element_term) list
    head_patterns = Dict{BNode, Vector{Identifier}}()
    for head in list_heads
        head_patterns[head] = _extract_list_pattern(head, list_structure)
    end

    results = Binding[]
    for bindings in bindings_list
        # For each binding, check if any bound value maps a formula list head to a graph BNode
        new_bindings = _unify_list_patterns(bindings, head_patterns, graph, eval_graph)
        append!(results, new_bindings)
    end
    return results
end

"""Extract ordered list pattern from list-structure triples starting at `head`."""
function _extract_list_pattern(head::BNode, list_structure::Vector{Triple})
    pattern = Identifier[]
    current = head
    seen = Set{Identifier}()
    while current != _RDF_NIL_URI && current isa BNode && !(current in seen)
        push!(seen, current)
        first_val = nothing
        rest_val = nothing
        for t in list_structure
            t.subject == current || continue
            if t.predicate == _RDF_FIRST
                first_val = t.object
            elseif t.predicate == _RDF_REST
                rest_val = t.object
            end
        end
        first_val === nothing && break
        push!(pattern, first_val)
        rest_val === nothing && break
        current = rest_val
    end
    return pattern
end

"""Unify list patterns against graph data, producing variable bindings."""
function _unify_list_patterns(bindings::Binding, head_patterns::Dict{BNode, Vector{Identifier}},
                              graph::RDFGraph, eval_graph::RDFGraph)
    # Find which formula BNodes are bound to graph BNodes
    pending = Tuple{BNode, Identifier}[]  # (formula_head, graph_value)
    for (formula_head, _) in head_patterns
        # Check if formula_head is directly bound (via some variable or direct match)
        bound_val = get(bindings, Variable(string(formula_head)), nothing)
        if bound_val === nothing
            # Check if any variable is bound to a value, and that variable's original
            # formula position corresponds to this list head
            for (var, val) in bindings
                if val == formula_head
                    # This variable was bound to the formula BNode — skip
                    continue
                end
            end
            # Check reverse: is formula_head used as an object value for some regular pattern?
            # The regular match would have unified formula_head with graph BNode
            for (var, val) in bindings
                if var isa Variable && val isa BNode
                    # Check if formula_head appears somewhere we can map
                end
            end
        end
    end

    # Simpler approach: iterate through bindings and look for BNode values
    # that could be list heads in the graph
    result_bindings = [copy(bindings)]

    for (formula_head, pattern_elements) in head_patterns
        any(el -> el isa Variable, pattern_elements) || continue  # no variables to bind

        new_results = Binding[]
        for b in result_bindings
            # Find what the formula_head maps to in the current bindings
            graph_node = nothing
            for (var, val) in b
                if val == formula_head && var isa Variable
                    # A variable was bound to this formula BNode — shouldn't happen normally
                    continue
                end
            end

            # The formula BNode may have been unified with a graph BNode during regular matching
            # Look for the graph BNode by checking what the regular patterns bound
            # The regular patterns had `?s ?p formula_head` or `?s ?p ?o` where ?o → formula_head
            # After unification, we need to find the graph BNode that corresponds
            for (var, val) in b
                if val isa BNode && val != formula_head
                    # Check if this graph BNode is a list head
                    graph_items = _resolve_rdf_list(val, graph)
                    if graph_items !== nothing && length(graph_items) == length(pattern_elements)
                        # Try to unify pattern elements with graph list items
                        unified = _unify_list_elements(pattern_elements, graph_items, b, eval_graph, graph)
                        if unified !== nothing
                            push!(new_results, unified)
                        end
                    end
                end
            end

            # Also check if the formula_head itself maps to something via the bindings indirectly
            # (e.g., regular pattern had `:Let :params BNODE_formula` and unified BNODE_formula with BNODE_graph)
            # This happens when the formula BNode appears directly in a regular pattern object position
            # In that case, unify_triple would have needed to match BNode→BNode
            # But BNodes don't unify unless they're exactly equal...
            # The structural list matching via list_graph handles this case.

            if isempty(new_results)
                # Fallback: try all list heads in graph that match the pattern length
                for (var, val) in b
                    val isa BNode || continue
                    graph_items = _resolve_rdf_list(val, graph)
                    graph_items === nothing && continue
                    length(graph_items) == length(pattern_elements) || continue
                    unified = _unify_list_elements(pattern_elements, graph_items, b, eval_graph, graph)
                    if unified !== nothing
                        push!(new_results, unified)
                    end
                end
            end
        end

        if !isempty(new_results)
            result_bindings = new_results
        end
    end

    return result_bindings
end

"""Unify list pattern elements with graph list items."""
function _unify_list_elements(pattern::Vector{Identifier}, items::Vector{Identifier},
                              bindings::Binding, eval_graph::RDFGraph, graph::RDFGraph)
    result = copy(bindings)
    for (pel, item) in zip(pattern, items)
        if pel isa Variable
            existing = get(result, pel, nothing)
            if existing === nothing
                result[pel] = item
            elseif !_terms_match(existing, item)
                return nothing
            end
        else
            # Check if pattern element is a BNode (nested list)
            if pel isa BNode
                # Nested list: resolve both and compare
                pel_items = _resolve_rdf_list(pel, eval_graph)
                item_items = _resolve_rdf_list(item, graph)
                if pel_items !== nothing && item_items !== nothing
                    nested = _unify_list_elements(pel_items, item_items, result, eval_graph, graph)
                    nested === nothing && return nothing
                    result = nested
                elseif !_terms_match(pel, item)
                    return nothing
                end
            elseif !_terms_match(pel, item)
                return nothing
            end
        end
    end
    return result
end

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

    # Widen query for Formula terms (need unification)
    if s isa Formula; s = nothing; end
    if o isa Formula; o = nothing; end

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

            # Find the consequent triple matching the pattern's predicate
            con_idx = findfirst(t -> t.predicate == pattern.predicate, rule.consequent)
            con_idx === nothing && continue
            con_pattern = rule.consequent[con_idx]
            # Freshen rule variables and BNodes to avoid conflicts
            var_map = Dict{Variable, Variable}()
            bnode_map = Dict{BNode, BNode}()
            fresh_ant = [_freshen_triple(t, var_map; bnode_map=bnode_map) for t in rule.antecedent]
            fresh_con_all = [_freshen_triple(t, var_map; bnode_map=bnode_map) for t in rule.consequent]
            fresh_con = fresh_con_all[con_idx]

            unified = unify_triple(fresh_con, pattern, Binding())
            # If simple unify fails, try structural list unification
            if unified === nothing
                rule_list_graph = RDFGraph()
                for t in fresh_con_all; add!(rule_list_graph, t); end
                unified = _unify_triple_structural(fresh_con, pattern, Binding(), rule_list_graph, 
                                                   list_graph !== nothing ? list_graph : graph)
            end
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

"""Freshen variables and BNodes in a triple to avoid name collisions between rules."""
function _freshen_triple(t::Triple, var_map::Dict{Variable, Variable};
                         bnode_map::Union{Dict{BNode, BNode}, Nothing}=nothing)
    s = _freshen_term(t.subject, var_map; bnode_map=bnode_map)
    p = t.predicate  # predicate stays as-is
    o = _freshen_term(t.object, var_map; bnode_map=bnode_map)
    Triple(s, p, o)
end

function _freshen_term(term::Variable, var_map::Dict{Variable, Variable};
                       bnode_map::Union{Dict{BNode, BNode}, Nothing}=nothing)
    get!(var_map, term) do
        Variable(term.name * "_" * string(objectid(var_map), base=16)[end-3:end])
    end
end

function _freshen_term(term::BNode, var_map::Dict{Variable, Variable};
                       bnode_map::Union{Dict{BNode, BNode}, Nothing}=nothing)
    bnode_map === nothing && return term
    get!(bnode_map, term) do
        BNode()
    end
end

function _freshen_term(term::Identifier, var_map::Dict{Variable, Variable};
                       bnode_map::Union{Dict{BNode, BNode}, Nothing}=nothing)
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

    # Skip structural dedup for list structure triples (rdf:first/rdf:rest with BNode subject)
    if t.subject isa BNode && (t.predicate == _RDF_FIRST || t.predicate == _RDF_REST)
        return false
    end

    store = graph.store

    # If object is a BNode (might be list head), check structurally
    if t.object isa BNode
        if store isa MemoryStore
            sp = get(store.spo, t.subject, nothing)
            if sp !== nothing
                objs = get(sp, t.predicate, nothing)
                if objs !== nothing
                    for o in objs
                        o isa BNode && _terms_equal(t.object, o, graph) && return true
                    end
                end
            end
        else
            for existing in triples(graph, (t.subject, t.predicate, nothing))
                existing.object isa BNode && _terms_equal(t.object, existing.object, graph) && return true
            end
        end
    end

    # If subject is a BNode, check if a triple with same predicate+object exists with any BNode subject
    if t.subject isa BNode
        if store isa MemoryStore
            po = get(store.pos, t.predicate, nothing)
            if po !== nothing
                for (o, subjs) in po
                    for s in subjs
                        s isa BNode || continue
                        if t.object isa BNode && o isa BNode
                            _terms_equal(t.object, o, graph) && return true
                        elseif _terms_match(t.object, o)
                            return true
                        end
                    end
                end
            end
        else
            for existing in triples(graph, (nothing, t.predicate, nothing))
                if existing.subject isa BNode
                    if t.object isa BNode && existing.object isa BNode
                        _terms_equal(t.object, existing.object, graph) && return true
                    elseif _terms_match(t.object, existing.object)
                        return true
                    end
                end
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
            bnode_map = Dict{BNode, BNode}()

            # Phase 1: Ground and freshen all consequent triples
            grounded_all = Triple[]
            for con_pattern in rule.consequent
                grounded = apply_bindings(con_pattern, bindings)
                grounded = _freshen_bnodes_selective(grounded, bnode_map, consequent_bnodes)
                push!(grounded_all, grounded)
            end

            # Phase 2: Build temp graph from list structure triples for BNode list resolution
            temp_graph = RDFGraph()
            main_triples = Triple[]
            for gt in grounded_all
                if gt.subject isa BNode && (gt.predicate == _RDF_FIRST || gt.predicate == _RDF_REST)
                    add!(temp_graph, gt)
                else
                    push!(main_triples, gt)
                end
            end

            # Phase 3: For main triples with BNode list heads, use _build_rdf_list
            # to reuse existing lists (content-addressed dedup)
            for (i, gt) in enumerate(main_triples)
                if gt.object isa BNode
                    items = _resolve_rdf_list(gt.object, temp_graph)
                    if items !== nothing
                        head = _build_rdf_list(items, reasoner.facts)
                        main_triples[i] = Triple(gt.subject, gt.predicate, head)
                    end
                end
                if gt.subject isa BNode
                    items = _resolve_rdf_list(gt.subject, temp_graph)
                    if items !== nothing
                        head = _build_rdf_list(items, reasoner.facts)
                        main_triples[i] = Triple(head, main_triples[i].predicate, main_triples[i].object)
                    end
                end
            end

            # Phase 4: Add only main triples (list structure handled by _build_rdf_list)
            for grounded in main_triples
                if is_ground(grounded) && !_triple_exists_structurally(grounded, reasoner.facts)
                    path_key = hash((hash(rule), hash(grounded)))
                    path_key in reasoner.euler_path && continue
                    push!(reasoner.euler_path, path_key)

                    add!(reasoner.facts, grounded)
                    push!(reasoner.derived, grounded)
                    reasoner.inference_count += 1
                    new_facts = true

                    if grounded.predicate == _LOG_IMPLIES
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
                pass_only_new::Bool=false,
                base_dir::Union{String, Nothing}=nothing)
    # Set base directory for file-loading builtins
    if base_dir !== nothing
        push!(_N3_BASE_DIRS, base_dir)
    end
    
    working = RDFGraph()
    # Copy namespaces from input graph
    for (prefix, ns_uri) in namespaces(data)
        bind!(working, prefix, ns_uri)
    end
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
    # Only remove triples where both subject and object are Formulas (actual rules)
    log_implies = _LOG_IMPLIES
    log_impliedBy = URIRef("http://www.w3.org/2000/10/swap/log#impliedBy")
    for pred in (log_implies, log_impliedBy)
        for t in collect(triples(working, (nothing, pred, nothing)))
            if t.subject isa Formula && t.object isa Formula
                remove!(working, (t.subject, t.predicate, t.object))
            end
        end
    end

    reasoner = N3Reasoner(working, all_rules;
                          max_iterations=max_iterations,
                          max_inferences=max_inferences)
    eam_loop!(reasoner)

    # Clean up base directory
    if base_dir !== nothing
        filter!(d -> d != base_dir, _N3_BASE_DIRS)
    end

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
