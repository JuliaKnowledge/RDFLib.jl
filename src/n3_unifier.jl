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

    for fact in _match_triples(graph, query_s, p, query_o)
        new_bindings = unify_triple(patterns[idx], fact, bindings)
        if new_bindings === nothing && list_graph !== nothing
            new_bindings = _unify_triple_structural(patterns[idx], fact, bindings, list_graph, graph)
        end
        if new_bindings !== nothing
            _match_recursive!(results, patterns, idx + 1, graph, new_bindings, list_graph)
        end
    end
end

# Direct index access for pattern matching — avoids Channel overhead
function _match_triples(graph::RDFGraph, s, p, o)
    store = graph.store
    store isa MemoryStore || return triples(graph, (s, p, o))
    result = Triple[]
    s_bound = s isa Identifier
    p_bound = p isa Identifier
    o_bound = o isa Identifier
    if s_bound && p_bound && o_bound
        sp = get(store.spo, s, nothing)
        if sp !== nothing
            objs = get(sp, p, nothing)
            objs !== nothing && o in objs && push!(result, Triple(s, p, o))
        end
    elseif s_bound && p_bound
        sp = get(store.spo, s, nothing)
        if sp !== nothing
            objs = get(sp, p, nothing)
            objs !== nothing && for ov in objs; push!(result, Triple(s, p, ov)); end
        end
    elseif s_bound && o_bound
        os = get(store.osp, o, nothing)
        if os !== nothing
            preds = get(os, s, nothing)
            preds !== nothing && for pv in preds; push!(result, Triple(s, pv, o)); end
        end
    elseif p_bound && o_bound
        po = get(store.pos, p, nothing)
        if po !== nothing
            subjs = get(po, o, nothing)
            subjs !== nothing && for sv in subjs; push!(result, Triple(sv, p, o)); end
        end
    elseif s_bound
        sp = get(store.spo, s, nothing)
        if sp !== nothing
            for (pv, objs) in sp
                for ov in objs; push!(result, Triple(s, pv, ov)); end
            end
        end
    elseif p_bound
        po = get(store.pos, p, nothing)
        if po !== nothing
            for (ov, subjs) in po
                for sv in subjs; push!(result, Triple(sv, p, ov)); end
            end
        end
    elseif o_bound
        os = get(store.osp, o, nothing)
        if os !== nothing
            for (sv, preds) in os
                for pv in preds; push!(result, Triple(sv, pv, o)); end
            end
        end
    else
        return store.insertion_order
    end
    result
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

# ─── Semi-naive delta matching ─────────────────────────────────────

"""Predicate-indexed delta triples for semi-naive evaluation."""
const DeltaPredIndex = Dict{URIRef, Vector{Triple}}

function _build_delta_index(delta::Vector{Triple})
    idx = DeltaPredIndex()
    for t in delta
        t.predicate isa URIRef || continue
        push!(get!(Vector{Triple}, idx, t.predicate), t)
    end
    idx
end

"""
    match_conjunction_delta(patterns, all_graph, delta_index, initial_bindings) -> Vector{Binding}

Semi-naive matching: find bindings where at least one pattern matches
a delta triple. For each pattern position i, we match pattern[i] against
delta triples and all other patterns against the full graph.
"""
function match_conjunction_delta(patterns::Vector{Triple}, all_graph::RDFGraph,
                                 delta_index::DeltaPredIndex,
                                 initial_bindings::Binding=Binding())
    n = length(patterns)
    isempty(patterns) && return Binding[]

    results = Binding[]
    seen = Set{UInt64}()

    for delta_pos in 1:n
        pat = apply_bindings(patterns[delta_pos], initial_bindings)

        # Determine candidate delta triples for this pattern position
        if pat.predicate isa URIRef
            candidates = get(delta_index, pat.predicate, Triple[])
        elseif pat.predicate isa Variable
            candidates = Triple[]
            for ts in values(delta_index)
                append!(candidates, ts)
            end
        else
            continue
        end
        isempty(candidates) && continue

        if n == 1
            for dt in candidates
                b = unify_triple(patterns[delta_pos], dt, initial_bindings)
                b === nothing && continue
                h = _binding_hash(b)
                h in seen && continue
                push!(seen, h)
                push!(results, b)
            end
        else
            remaining = Triple[patterns[j] for j in 1:n if j != delta_pos]
            for dt in candidates
                b = unify_triple(patterns[delta_pos], dt, initial_bindings)
                b === nothing && continue
                sub = match_conjunction(remaining, all_graph, b)
                for sb in sub
                    h = _binding_hash(sb)
                    h in seen && continue
                    push!(seen, h)
                    push!(results, sb)
                end
            end
        end
    end
    results
end

# XOR-based order-independent binding hash for deduplication
function _binding_hash(b::Binding)
    h = UInt(0x9e3779b97f4a7c15)
    for (k, v) in b
        h ⊻= hash(k) * UInt(0x517cc1b727220a95) ⊻ hash(v)
    end
    h
end

# ─── Undo-log based matching (zero-copy backtracking) ──────────────
# Mutates bindings in-place and tracks newly added variables for undo.
# Only copies at the leaf (when a full match is found).

function _unify_term_undo!(a::Variable, b::Identifier, bindings::Binding,
                            undo::Vector{Variable})::Bool
    ra = get(bindings, a, nothing)
    if ra === nothing
        bindings[a] = b
        push!(undo, a)
        return true
    end
    ra === b && return true
    _terms_match(ra, b)
end

function _unify_term_undo!(a::Identifier, b::Identifier, bindings::Binding,
                            undo::Vector{Variable})::Bool
    _terms_match(a, b)
end

function _unify_triple_undo!(pattern::Triple, fact::Triple, bindings::Binding,
                              undo::Vector{Variable})::Bool
    _unify_term_undo!(pattern.subject, fact.subject, bindings, undo) || return false
    _unify_term_undo!(pattern.predicate, fact.predicate, bindings, undo) || return false
    _unify_term_undo!(pattern.object, fact.object, bindings, undo)
end

"""
    match_conjunction_undo(patterns, graph, initial_bindings) -> Vector{Binding}

Like match_conjunction but uses mutable bindings with undo-log backtracking.
Only copies the binding at the leaf (when a complete match is found), avoiding
O(depth) Dict copies per match attempt.
"""
function match_conjunction_undo(patterns::Vector{Triple}, graph::RDFGraph,
                                 initial_bindings::Binding=Binding())
    isempty(patterns) && return [initial_bindings]
    results = Binding[]
    bindings = copy(initial_bindings)
    _match_recursive_undo!(results, patterns, 1, graph, bindings)
    return results
end

function _match_recursive_undo!(results::Vector{Binding}, patterns::Vector{Triple},
                                 idx::Int, graph::RDFGraph, bindings::Binding)
    if idx > length(patterns)
        push!(results, copy(bindings))
        return
    end

    # Build query pattern from current bindings
    pat = patterns[idx]
    s_raw = pat.subject isa Variable ? get(bindings, pat.subject, nothing) : pat.subject
    p_raw = pat.predicate isa Variable ? get(bindings, pat.predicate, nothing) : pat.predicate
    o_raw = pat.object isa Variable ? get(bindings, pat.object, nothing) : pat.object

    s = s_raw isa Variable ? nothing : s_raw
    p = p_raw isa Variable ? nothing : p_raw
    o = o_raw isa Variable ? nothing : o_raw

    # Widen for numeric and Formula terms
    if s isa Literal && _to_number(s) !== nothing; s = nothing; end
    if o isa Literal && _to_number(o) !== nothing; o = nothing; end
    if s isa Formula; s = nothing; end
    if o isa Formula; o = nothing; end

    undo = Variable[]
    for fact in _match_triples(graph, s, p, o)
        empty!(undo)
        if _unify_triple_undo!(pat, fact, bindings, undo)
            _match_recursive_undo!(results, patterns, idx + 1, graph, bindings)
        end
        # Undo all bindings added in this attempt
        for v in undo
            delete!(bindings, v)
        end
    end
end

# ─── Integer-encoded reasoning (RoXi-style) ───────────────────────
# Encode terms as UInt32 for O(1) comparison. Use fixed-size arrays
# for bindings instead of Dict. This eliminates all string hashing
# from the inner loop.

const UNBOUND = UInt32(0)
const VAR_FLAG = UInt32(0x80000000)  # high bit marks variable slots

struct TermEncoder
    to_id::Dict{Identifier, UInt32}
    from_id::Vector{Identifier}
    var_to_slot::Dict{Variable, UInt32}  # per-rule variable slot assignments
end

function TermEncoder()
    TermEncoder(Dict{Identifier, UInt32}(), Identifier[], Dict{Variable, UInt32}())
end

function encode_term!(enc::TermEncoder, term::Identifier)::UInt32
    get!(enc.to_id, term) do
        push!(enc.from_id, term)
        UInt32(length(enc.from_id))
    end
end

decode_term(enc::TermEncoder, id::UInt32)::Identifier = enc.from_id[id]

struct IntTriple
    s::UInt32
    p::UInt32
    o::UInt32
end

# Integer-based SPO index
struct IntStore
    spo::Dict{UInt32, Dict{UInt32, Vector{UInt32}}}  # s→p→[o]
    pos::Dict{UInt32, Dict{UInt32, Vector{UInt32}}}  # p→o→[s]
    triples::Vector{IntTriple}
    triple_set::Set{Tuple{UInt32,UInt32,UInt32}}
end

IntStore() = IntStore(
    Dict{UInt32, Dict{UInt32, Vector{UInt32}}}(),
    Dict{UInt32, Dict{UInt32, Vector{UInt32}}}(),
    IntTriple[],
    Set{Tuple{UInt32,UInt32,UInt32}}()
)

function int_add!(store::IntStore, t::IntTriple)::Bool
    key = (t.s, t.p, t.o)
    key in store.triple_set && return false
    push!(store.triple_set, key)
    push!(store.triples, t)
    # SPO
    sp = get!(Dict{UInt32, Vector{UInt32}}, store.spo, t.s)
    push!(get!(Vector{UInt32}, sp, t.p), t.o)
    # POS
    po = get!(Dict{UInt32, Vector{UInt32}}, store.pos, t.p)
    push!(get!(Vector{UInt32}, po, t.o), t.s)
    return true
end

function int_contains(store::IntStore, s::UInt32, p::UInt32, o::UInt32)::Bool
    (s, p, o) in store.triple_set
end

# Query: return matching triples. nothing = wildcard.
function int_query(store::IntStore, s::UInt32, p::UInt32, o::UInt32)
    # All three bound
    if s != UNBOUND && p != UNBOUND && o != UNBOUND
        return int_contains(store, s, p, o) ? [IntTriple(s, p, o)] : IntTriple[]
    end
    result = IntTriple[]
    if s != UNBOUND && p != UNBOUND
        sp = get(store.spo, s, nothing)
        sp === nothing && return result
        objs = get(sp, p, nothing)
        objs === nothing && return result
        for ov in objs; push!(result, IntTriple(s, p, ov)); end
    elseif p != UNBOUND && o != UNBOUND
        po = get(store.pos, p, nothing)
        po === nothing && return result
        subjs = get(po, o, nothing)
        subjs === nothing && return result
        for sv in subjs; push!(result, IntTriple(sv, p, o)); end
    elseif s != UNBOUND
        sp = get(store.spo, s, nothing)
        sp === nothing && return result
        for (pv, objs) in sp
            (p != UNBOUND && pv != p) && continue
            for ov in objs; push!(result, IntTriple(s, pv, ov)); end
        end
    elseif p != UNBOUND
        po = get(store.pos, p, nothing)
        po === nothing && return result
        for (ov, subjs) in po
            (o != UNBOUND && ov != o) && continue
            for sv in subjs; push!(result, IntTriple(sv, p, ov)); end
        end
    else
        return store.triples
    end
    result
end

# Encoded rule pattern: variable slots marked with VAR_FLAG | slot_index
struct IntPattern
    s::UInt32  # term_id or VAR_FLAG|slot
    p::UInt32
    o::UInt32
end

struct IntRule
    antecedent::Vector{IntPattern}
    consequent::Vector{IntPattern}
    n_vars::Int
end

# Fixed-size binding array: slot_index → term_id (0 = unbound)
const IntBindings = Vector{UInt32}

@inline is_var(v::UInt32) = (v & VAR_FLAG) != 0
@inline var_slot(v::UInt32) = Int(v & ~VAR_FLAG)

function int_unify_term!(pat_v::UInt32, fact_v::UInt32,
                          bindings::IntBindings)::Bool
    if is_var(pat_v)
        slot = var_slot(pat_v)
        cur = bindings[slot]
        if cur == UNBOUND
            bindings[slot] = fact_v
            return true
        end
        return cur == fact_v
    end
    return pat_v == fact_v
end

function int_unify_undo!(pat::IntPattern, fact::IntTriple,
                          bindings::IntBindings, undo::Vector{Int})::Bool
    # Subject
    if is_var(pat.s)
        slot = var_slot(pat.s)
        cur = bindings[slot]
        if cur == UNBOUND
            bindings[slot] = fact.s
            push!(undo, slot)
        elseif cur != fact.s
            return false
        end
    elseif pat.s != fact.s
        return false
    end
    # Predicate
    if is_var(pat.p)
        slot = var_slot(pat.p)
        cur = bindings[slot]
        if cur == UNBOUND
            bindings[slot] = fact.p
            push!(undo, slot)
        elseif cur != fact.p
            return false
        end
    elseif pat.p != fact.p
        return false
    end
    # Object
    if is_var(pat.o)
        slot = var_slot(pat.o)
        cur = bindings[slot]
        if cur == UNBOUND
            bindings[slot] = fact.o
            push!(undo, slot)
        elseif cur != fact.o
            return false
        end
    elseif pat.o != fact.o
        return false
    end
    return true
end

# Match conjunction of remaining patterns using integer backtracking
function int_match_remaining!(results::Vector{IntBindings},
                               patterns::Vector{IntPattern}, idx::Int,
                               store::IntStore, bindings::IntBindings,
                               undo_stack::Vector{Int})
    if idx > length(patterns)
        push!(results, copy(bindings))
        return
    end

    pat = patterns[idx]
    # Build query from current bindings
    qs = is_var(pat.s) ? (let s=var_slot(pat.s); bindings[s] end) : pat.s
    qp = is_var(pat.p) ? (let s=var_slot(pat.p); bindings[s] end) : pat.p
    qo = is_var(pat.o) ? (let s=var_slot(pat.o); bindings[s] end) : pat.o

    mark = length(undo_stack)
    for fact in int_query(store, qs, qp, qo)
        resize!(undo_stack, mark)
        if int_unify_undo!(pat, fact, bindings, undo_stack)
            int_match_remaining!(results, patterns, idx + 1, store, bindings, undo_stack)
        end
        # Undo
        for i in (mark+1):length(undo_stack)
            bindings[undo_stack[i]] = UNBOUND
        end
    end
    resize!(undo_stack, mark)
end
