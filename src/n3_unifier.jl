# ─── N3 Unification Engine ──────────────────────────────────────────
# Pattern matching and variable binding for N3 reasoning.

"""Variable bindings — maps Variable to ground Identifier."""
const Binding = Dict{Variable, Identifier}

"""
    unify_term(a::Identifier, b::Identifier, bindings::Binding) -> Union{Binding, Nothing}

Unify two terms. Variables in `a` can bind to values in `b`.
Returns updated bindings on success, `nothing` on failure.
"""

# Compare two Identifiers, using numeric comparison for numeric Literals.
function _terms_match(a::Identifier, b::Identifier)
    a == b && return true
    if a isa Literal && b isa Literal
        na = _to_number(a)
        nb = _to_number(b)
        na !== nothing && nb !== nothing && na == nb && return true
    end
    return false
end

function unify_term(a::Variable, b::Variable, bindings::Binding)
    ra = _resolve(a, bindings)
    rb = _resolve(b, bindings)
    # Both resolved to the same term
    ra == rb && return copy(bindings)
    if ra isa Variable && rb isa Variable
        # Both still unbound — bind a to b
        result = copy(bindings)
        result[ra] = rb
        return result
    elseif ra isa Variable
        result = copy(bindings)
        result[ra] = rb
        return result
    elseif rb isa Variable
        result = copy(bindings)
        result[rb] = ra
        return result
    else
        # Both ground — check match
        return _terms_match(ra, rb) ? copy(bindings) : nothing
    end
end

function unify_term(a::Variable, b::Identifier, bindings::Binding)
    ra = _resolve(a, bindings)
    if ra isa Variable
        result = copy(bindings)
        result[ra] = b
        return result
    end
    return _terms_match(ra, b) ? copy(bindings) : nothing
end

function unify_term(a::Identifier, b::Variable, bindings::Binding)
    rb = _resolve(b, bindings)
    if rb isa Variable
        result = copy(bindings)
        result[rb] = a
        return result
    end
    return _terms_match(rb, a) ? copy(bindings) : nothing
end

function unify_term(a::Identifier, b::Identifier, bindings::Binding)
    a == b && return copy(bindings)
    # Numeric comparison for Literals with different datatypes
    if a isa Literal && b isa Literal
        na = _to_number(a)
        nb = _to_number(b)
        if na !== nothing && nb !== nothing && na == nb
            return copy(bindings)
        end
    end
    # Formula unification: match pattern formula (a) against ground formula (b)
    if a isa Formula && b isa Formula
        return _unify_formulas(a, b, bindings)
    end
    return nothing
end

# Unify two formulas by matching each triple in `pattern` against triples in `target`.
function _unify_formulas(pattern::Formula, target::Formula, bindings::Binding)
    pat_triples = collect(pattern.graph)
    tgt_triples = collect(target.graph)
    results = _unify_formula_recursive(pat_triples, tgt_triples, 1, bindings)
    isempty(results) ? nothing : results[1]
end

function _unify_formula_recursive(pat::Vector{Triple}, tgt::Vector{Triple},
                                   idx::Int, bindings::Binding)
    idx > length(pat) && return [bindings]
    results = Binding[]
    for ft in tgt
        new_b = unify_triple(pat[idx], ft, bindings)
        if new_b !== nothing
            sub = _unify_formula_recursive(pat, tgt, idx + 1, new_b)
            append!(results, sub)
        end
    end
    results
end

"""
    unify_triple(pattern::Triple, fact::Triple, bindings::Binding) -> Union{Binding, Nothing}

Unify a triple pattern (may contain Variables) against a ground triple.
"""
function unify_triple(pattern::Triple, fact::Triple, bindings::Binding)
    b1 = unify_term(pattern.subject, fact.subject, bindings)
    b1 === nothing && return nothing
    b2 = unify_term(pattern.predicate, fact.predicate, b1)
    b2 === nothing && return nothing
    b3 = unify_term(pattern.object, fact.object, b2)
    return b3
end

"""
    apply_bindings(pattern::Triple, bindings::Binding) -> Triple

Substitute all bound variables in a triple pattern.
"""
function apply_bindings(t::Triple, bindings::Binding)
    s = t.subject isa Variable ? _resolve(t.subject, bindings) : t.subject
    p = t.predicate isa Variable ? _resolve(t.predicate, bindings) : t.predicate
    o = t.object isa Variable ? _resolve(t.object, bindings) : t.object
    Triple(s, p, o)
end

function apply_bindings(term::Variable, bindings::Binding)
    _resolve(term, bindings)
end

function apply_bindings(term::Identifier, bindings::Binding)
    term
end

"""
    is_ground(t::Triple) -> Bool

Check if a triple has no unbound variables.
"""
function is_ground(t::Triple)
    !(t.subject isa Variable) && !(t.predicate isa Variable) && !(t.object isa Variable)
end

"""
    match_conjunction(patterns::Vector{Triple}, graph::RDFGraph, initial_bindings::Binding=Binding(); list_graph=nothing) -> Vector{Binding}

Find all ways to match a conjunction of triple patterns against a graph.
Uses backtracking search over the pattern sequence.
When `list_graph` is provided, BNode list heads in patterns are compared structurally.
"""
function match_conjunction(patterns::Vector{Triple}, graph::RDFGraph,
                           initial_bindings::Binding=Binding();
                           list_graph::Union{RDFGraph, Nothing}=nothing)
    isempty(patterns) && return [initial_bindings]

    results = Binding[]
    _match_recursive!(results, patterns, 1, graph, initial_bindings, list_graph)
    return results
end

function _match_recursive!(results::Vector{Binding}, patterns::Vector{Triple},
                           idx::Int, graph::RDFGraph, bindings::Binding,
                           list_graph::Union{RDFGraph, Nothing}=nothing)
    if idx > length(patterns)
        push!(results, copy(bindings))
        return
    end

    pattern = apply_bindings(patterns[idx], bindings)

    # Convert to store lookup pattern — Variables become nothing (wildcard)
    # Numeric literals also become wildcards to support cross-datatype matching
    s = pattern.subject isa Variable ? nothing : pattern.subject
    p = pattern.predicate isa Variable ? nothing : pattern.predicate
    o = pattern.object isa Variable ? nothing : pattern.object

    # Widen store query for numeric literals (decimal vs double etc.)
    if s isa Literal && _to_number(s) !== nothing; s = nothing; end
    if o isa Literal && _to_number(o) !== nothing; o = nothing; end

    # Widen query for Formula terms (they contain variables, need unification)
    if s isa Formula; s = nothing; end
    if o isa Formula; o = nothing; end

    # If s/o are BNode list heads in the list_graph, widen query to allow structural matching
    s_is_list = (s isa BNode && list_graph !== nothing && _resolve_rdf_list(s, list_graph) !== nothing)
    o_is_list = (o isa BNode && list_graph !== nothing && _resolve_rdf_list(o, list_graph) !== nothing)
    query_s = s_is_list ? nothing : s
    query_o = o_is_list ? nothing : o

    for fact in triples(graph, (query_s, p, query_o))
        new_bindings = unify_triple(patterns[idx], fact, bindings)
        if new_bindings === nothing && list_graph !== nothing
            new_bindings = _unify_triple_structural(patterns[idx], fact, bindings, list_graph, graph)
        end
        if new_bindings !== nothing
            _match_recursive!(results, patterns, idx + 1, graph, new_bindings, list_graph)
        end
    end
end

"""Structural unification: when normal unify fails, try structural list comparison for BNodes."""
function _unify_triple_structural(pattern::Triple, fact::Triple, bindings::Binding,
                                  pattern_graph::RDFGraph, fact_graph::RDFGraph)
    b1 = _unify_term_structural(pattern.subject, fact.subject, bindings, pattern_graph, fact_graph)
    b1 === nothing && return nothing
    b2 = unify_term(pattern.predicate, fact.predicate, b1)
    b2 === nothing && return nothing
    b3 = _unify_term_structural(pattern.object, fact.object, b2, pattern_graph, fact_graph)
    return b3
end

function _unify_term_structural(a::Identifier, b::Identifier, bindings::Binding,
                                pattern_graph::RDFGraph, fact_graph::RDFGraph)
    result = unify_term(a, b, bindings)
    result !== nothing && return result
    # If both are BNodes, try structural list unification
    if a isa BNode && b isa BNode
        la = _resolve_rdf_list(a, pattern_graph)
        lb = _resolve_rdf_list(b, fact_graph)
        if la !== nothing && lb !== nothing && length(la) == length(lb)
            # Unify element-by-element, binding variables
            merged = copy(bindings)
            ok = true
            for (ea, eb) in zip(la, lb)
                u = _unify_term_structural(ea, eb, merged, pattern_graph, fact_graph)
                if u === nothing
                    ok = false; break
                end
                merged = u
            end
            ok && return merged
        end
        # Non-list structural equality
        if _terms_equal_cross(a, b, pattern_graph, fact_graph)
            return copy(bindings)
        end
    end
    return nothing
end
