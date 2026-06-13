# Datalog reasoning engine for RDFLib.jl
#
# Provides semi-naive bottom-up evaluation of Datalog rules over RDF triples.
# Each triple (s, p, o) is treated as a ternary fact TI(s, p, o).
# Rules are `head :- body` where head/body are conjunctions of triple patterns.
#
# Key differences from the N3 TAT (triple-at-a-time) engine:
# - Set-at-a-time evaluation: processes entire relations per iteration
# - Hash joins on shared variables between body patterns
# - Semi-naive: only delta (newly derived) tuples drive each iteration
# - Stratified negation: negated body atoms with negation-as-failure,
#   evaluated stratum-by-stratum (lower strata are completed first)
# - No builtins, no backward chaining, no nested formulas otherwise

# ─── Types ────────────────────────────────────────────────────────────────

"""
A Datalog atom: a triple pattern with integer-encoded terms.
Variables are marked with VAR_FLAG (high bit set), constants are plain UInt32.
Reuses IntPattern from n3_unifier.jl.
"""
const DatalogAtom = IntPattern

"""
A Datalog rule: head atom(s) derived from a conjunction of body atoms.

- `body` holds the positive body atoms.
- `neg_body` holds negated body atoms (negation-as-failure). A negated atom
  succeeds when the (fully bound) triple is absent from the database. Negated
  atoms must be *safe*: every variable in a negated atom must also occur in a
  positive body atom. Programs with negation must be *stratifiable* (no
  recursion through negation); `semi_naive!` checks both and throws an
  `ArgumentError` otherwise.
- `var_count` is the number of distinct variables across head+body+neg_body.
"""
struct DatalogRule
    head::Vector{DatalogAtom}
    body::Vector{DatalogAtom}
    neg_body::Vector{DatalogAtom}
    var_count::Int
end

# Backward-compatible constructor for negation-free rules
DatalogRule(head::Vector{DatalogAtom}, body::Vector{DatalogAtom}, var_count::Int) =
    DatalogRule(head, body, DatalogAtom[], var_count)

"""Compiled single-body rule for direct substitution (no unification needed)."""
struct DLCompiledRule
    s_slot::Int  # 0 = constant
    p_slot::Int
    o_slot::Int
    n_vars::Int
    head::Vector{DatalogAtom}
end

"""
A relation: set of integer-encoded triples, with a hash index for join.
Tuples are stored as `Vector{IntTriple}` with a `Set` for dedup.
"""
mutable struct DatalogRelation
    tuples::Vector{IntTriple}
    seen::Set{IntTriple}
end

DatalogRelation() = DatalogRelation(IntTriple[], Set{IntTriple}())

function relation_add!(rel::DatalogRelation, t::IntTriple)::Bool
    t in rel.seen && return false
    push!(rel.seen, t)
    push!(rel.tuples, t)
    return true
end

"""
A Datalog program: rules + base facts (EDB).
All data is stored as a single relation of triples (RDF is a single predicate `TI`).
"""
struct DatalogProgram
    rules::Vector{DatalogRule}
    facts::DatalogRelation  # EDB + derived IDB triples
    encoder::TermEncoder
end

function DatalogProgram()
    DatalogProgram(DatalogRule[], DatalogRelation(), TermEncoder())
end

# ─── Hash Index for Joins ─────────────────────────────────────────────────

# Index structures for fast lookup during joins
# SPO index: s -> p -> Set{o}
const SPOIndex = Dict{UInt32, Dict{UInt32, Set{UInt32}}}
# POS index: p -> o -> Vector{s}
const POSIndex = Dict{UInt32, Dict{UInt32, Vector{UInt32}}}
# PSO index: p -> s -> Vector{o}
const PSOIndex = Dict{UInt32, Dict{UInt32, Vector{UInt32}}}

struct RelationIndex
    spo::SPOIndex
    pos::POSIndex
    pso::PSOIndex
end

function build_index(tuples)::RelationIndex
    spo = SPOIndex()
    pos = POSIndex()
    pso = PSOIndex()
    for t in tuples
        # SPO
        sp = get!(Dict{UInt32, Set{UInt32}}, spo, t.s)
        push!(get!(Set{UInt32}, sp, t.p), t.o)
        # POS
        po = get!(Dict{UInt32, Vector{UInt32}}, pos, t.p)
        push!(get!(Vector{UInt32}, po, t.o), t.s)
        # PSO
        ps = get!(Dict{UInt32, Vector{UInt32}}, pso, t.p)
        push!(get!(Vector{UInt32}, ps, t.s), t.o)
    end
    return RelationIndex(spo, pos, pso)
end

# Incrementally add triples to an existing index
function index_add!(idx::RelationIndex, t::IntTriple)
    sp = get!(Dict{UInt32, Set{UInt32}}, idx.spo, t.s)
    push!(get!(Set{UInt32}, sp, t.p), t.o)
    po = get!(Dict{UInt32, Vector{UInt32}}, idx.pos, t.p)
    push!(get!(Vector{UInt32}, po, t.o), t.s)
    ps = get!(Dict{UInt32, Vector{UInt32}}, idx.pso, t.p)
    push!(get!(Vector{UInt32}, ps, t.s), t.o)
end

# ─── Join Evaluation ──────────────────────────────────────────────────────

# A binding environment: variable slot → value (0 = unbound)
const DLBindings = Vector{UInt32}

"""
    evaluate_atom(atom, idx, bindings) → Vector{DLBindings}

Evaluate a single atom against the index with current bindings.
Returns all extended bindings that satisfy the atom.
"""
function evaluate_atom(atom::DatalogAtom, idx::RelationIndex,
                       bindings::DLBindings)::Vector{DLBindings}
    results = DLBindings[]
    _evaluate_atom!(results, atom, idx, bindings)
    return results
end

function _evaluate_atom!(results::Vector{DLBindings}, atom::DatalogAtom,
                          idx::RelationIndex, bindings::DLBindings)
    # Resolve each position: bound constant, bound variable, or free variable
    s_bound = _resolve(atom.s, bindings)
    p_bound = _resolve(atom.p, bindings)
    o_bound = _resolve(atom.o, bindings)

    # Choose best index based on what's bound
    if p_bound != UNBOUND && o_bound != UNBOUND && s_bound != UNBOUND
        # All bound — just check existence
        sp = get(idx.spo, s_bound, nothing)
        sp === nothing && return
        objs = get(sp, p_bound, nothing)
        objs === nothing && return
        o_bound in objs || return
        push!(results, copy(bindings))
    elseif p_bound != UNBOUND && o_bound != UNBOUND
        # p,o bound — lookup subjects via POS
        po = get(idx.pos, p_bound, nothing)
        po === nothing && return
        subjects = get(po, o_bound, nothing)
        subjects === nothing && return
        for s_val in subjects
            new_b = _try_bind(bindings, atom.s, s_val)
            new_b !== nothing && push!(results, new_b)
        end
    elseif p_bound != UNBOUND && s_bound != UNBOUND
        # p,s bound — lookup objects via PSO
        ps = get(idx.pso, p_bound, nothing)
        ps === nothing && return
        objects = get(ps, s_bound, nothing)
        objects === nothing && return
        for o_val in objects
            new_b = _try_bind(bindings, atom.o, o_val)
            new_b !== nothing && push!(results, new_b)
        end
    elseif s_bound != UNBOUND && o_bound != UNBOUND
        # s,o bound — scan predicates for s
        sp = get(idx.spo, s_bound, nothing)
        sp === nothing && return
        for (p_val, objs) in sp
            o_bound in objs || continue
            new_b = _try_bind(bindings, atom.p, p_val)
            new_b !== nothing && push!(results, new_b)
        end
    elseif p_bound != UNBOUND
        # Only p bound — scan all s,o for this predicate via POS
        po = get(idx.pos, p_bound, nothing)
        po === nothing && return
        for (o_val, subjects) in po
            for s_val in subjects
                new_b = copy(bindings)
                b1 = _try_bind!(new_b, atom.s, s_val)
                b1 || continue
                b2 = _try_bind!(new_b, atom.o, o_val)
                b2 || continue
                push!(results, new_b)
            end
        end
    elseif s_bound != UNBOUND
        # Only s bound — scan predicates/objects for this subject
        sp = get(idx.spo, s_bound, nothing)
        sp === nothing && return
        for (p_val, objs) in sp
            for o_val in objs
                new_b = copy(bindings)
                b1 = _try_bind!(new_b, atom.p, p_val)
                b1 || continue
                b2 = _try_bind!(new_b, atom.o, o_val)
                b2 || continue
                push!(results, new_b)
            end
        end
    elseif o_bound != UNBOUND
        # Only o bound — scan all via POS, then filter
        for (p_val, po) in idx.pos
            subjects = get(po, o_bound, nothing)
            subjects === nothing && continue
            for s_val in subjects
                new_b = copy(bindings)
                b1 = _try_bind!(new_b, atom.s, s_val)
                b1 || continue
                b2 = _try_bind!(new_b, atom.p, p_val)
                b2 || continue
                push!(results, new_b)
            end
        end
    else
        # Nothing bound — full scan (rare)
        for (s_val, sp) in idx.spo
            for (p_val, objs) in sp
                for o_val in objs
                    new_b = copy(bindings)
                    b1 = _try_bind!(new_b, atom.s, s_val)
                    b1 || continue
                    b2 = _try_bind!(new_b, atom.p, p_val)
                    b2 || continue
                    b3 = _try_bind!(new_b, atom.o, o_val)
                    b3 || continue
                    push!(results, new_b)
                end
            end
        end
    end
end

@inline function _resolve(v::UInt32, bindings::DLBindings)::UInt32
    is_var(v) || return v
    slot = var_slot(v)
    return slot <= length(bindings) ? bindings[slot] : UNBOUND
end

@inline function _try_bind(bindings::DLBindings, v::UInt32, val::UInt32)::Union{DLBindings,Nothing}
    if !is_var(v)
        return v == val ? copy(bindings) : nothing
    end
    slot = var_slot(v)
    cur = bindings[slot]
    if cur == UNBOUND
        new_b = copy(bindings)
        new_b[slot] = val
        return new_b
    end
    return cur == val ? copy(bindings) : nothing
end

@inline function _try_bind!(bindings::DLBindings, v::UInt32, val::UInt32)::Bool
    if !is_var(v)
        return v == val
    end
    slot = var_slot(v)
    cur = bindings[slot]
    if cur == UNBOUND
        bindings[slot] = val
        return true
    end
    return cur == val
end

"""
    evaluate_body(atoms, idx, bindings) → Vector{DLBindings}

Evaluate a conjunction of atoms by nested-loop join with index lookups.
Atoms are ordered to maximize bound variables at each step.
"""
function evaluate_body(atoms::Vector{DatalogAtom}, idx::RelationIndex,
                       bindings::DLBindings)::Vector{DLBindings}
    current = DLBindings[bindings]
    for atom in atoms
        next = DLBindings[]
        for b in current
            _evaluate_atom!(next, atom, idx, b)
        end
        isempty(next) && return DLBindings[]
        current = next
    end
    return current
end

# ─── Rule Body Reordering ─────────────────────────────────────────────────

"""
Reorder body atoms to maximize bound variables at each step.
Greedy: at each step, pick the atom that has the most bound positions
given variables already bound by previous atoms.
"""
function reorder_body(atoms::Vector{DatalogAtom})::Vector{DatalogAtom}
    n = length(atoms)
    n <= 1 && return atoms

    remaining = collect(1:n)
    ordered = Int[]
    bound_vars = Set{UInt32}()

    for _ in 1:n
        best_idx = 1
        best_score = -1
        for (i, ri) in enumerate(remaining)
            score = _atom_score(atoms[ri], bound_vars)
            if score > best_score
                best_score = score
                best_idx = i
            end
        end
        chosen = remaining[best_idx]
        push!(ordered, chosen)
        # Add variables from chosen atom to bound set
        a = atoms[chosen]
        is_var(a.s) && push!(bound_vars, a.s)
        is_var(a.p) && push!(bound_vars, a.p)
        is_var(a.o) && push!(bound_vars, a.o)
        deleteat!(remaining, best_idx)
    end
    return DatalogAtom[atoms[i] for i in ordered]
end

function _atom_score(atom::DatalogAtom, bound_vars::Set{UInt32})::Int
    score = 0
    # Constant positions always count as bound
    is_var(atom.s) || (score += 1)
    is_var(atom.p) || (score += 1)
    is_var(atom.o) || (score += 1)
    # Variables that are already bound from previous atoms
    is_var(atom.s) && atom.s in bound_vars && (score += 1)
    is_var(atom.p) && atom.p in bound_vars && (score += 1)
    is_var(atom.o) && atom.o in bound_vars && (score += 1)
    return score
end

# ─── Stratified Negation ──────────────────────────────────────────────────

# Sentinel "predicate" for atoms with a variable in predicate position.
# Such atoms can match (or derive) any predicate, so they are treated
# conservatively in the dependency analysis.
const _DL_ANY_PRED = UNBOUND

@inline _dl_atom_pred(a::DatalogAtom)::UInt32 = is_var(a.p) ? _DL_ANY_PRED : a.p

_dl_pred_name(enc::Union{TermEncoder,Nothing}, p::UInt32) =
    p == _DL_ANY_PRED ? "<any (variable predicate)>" :
    (enc !== nothing && p <= length(enc.from_id)) ? string(decode_term(enc, p)) : "predicate #$p"

"""
    check_negation_safety(rules; encoder=nothing)

Throw an `ArgumentError` if any rule has a negated body atom containing a
variable that does not occur in a positive body atom of the same rule
(unsafe negation — the negated atom could not be fully bound when checked).
"""
function check_negation_safety(rules::Vector{DatalogRule};
                               encoder::Union{TermEncoder,Nothing}=nothing)
    for (i, r) in enumerate(rules)
        isempty(r.neg_body) && continue
        pos_vars = Set{UInt32}()
        for a in r.body
            is_var(a.s) && push!(pos_vars, a.s)
            is_var(a.p) && push!(pos_vars, a.p)
            is_var(a.o) && push!(pos_vars, a.o)
        end
        for a in r.neg_body
            for v in (a.s, a.p, a.o)
                if is_var(v) && !(v in pos_vars)
                    throw(ArgumentError(
                        "Unsafe negation in Datalog rule $i: variable slot " *
                        "$(var_slot(v)) occurs in a negated atom but in no " *
                        "positive body atom of the same rule"))
                end
            end
        end
    end
    return nothing
end

# Can facts produced by head atom `h` match body atom `b`?
# Position-wise: a variable on either side is compatible with anything;
# two constants must be equal.
@inline function _dl_atoms_compatible(h::DatalogAtom, b::DatalogAtom)::Bool
    (is_var(h.s) || is_var(b.s) || h.s == b.s) &&
    (is_var(h.p) || is_var(b.p) || h.p == b.p) &&
    (is_var(h.o) || is_var(b.o) || h.o == b.o)
end

"""
    stratify_rules(rules; encoder=nothing) → Vector{Vector{Int}}

Partition rule indices into strata for stratified-negation evaluation.

Builds a rule-level dependency graph: rule `r` depends on rule `r'` when some
head atom of `r'` can produce facts matching a body atom of `r` (positive
edge) or a negated atom of `r` (negative edge). A rule's stratum must be ≥
the strata of its positive dependencies and strictly greater than the strata
of its negative dependencies. Throws an `ArgumentError` if the program is not
stratifiable (a negative edge participates in a dependency cycle).

Negation-free programs always form a single stratum.
"""
function stratify_rules(rules::Vector{DatalogRule};
                        encoder::Union{TermEncoder,Nothing}=nothing)::Vector{Vector{Int}}
    any(r -> !isempty(r.neg_body), rules) || return [collect(1:length(rules))]

    n = length(rules)
    # pos_deps[i] / neg_deps[i]: rules whose heads can feed rule i's
    # positive / negated body atoms
    pos_deps = [Int[] for _ in 1:n]
    neg_deps = [Int[] for _ in 1:n]
    for (i, r) in enumerate(rules)
        for (j, rj) in enumerate(rules)
            for h in rj.head
                if any(b -> _dl_atoms_compatible(h, b), r.body)
                    push!(pos_deps[i], j)
                    break
                end
            end
            for h in rj.head
                if any(b -> _dl_atoms_compatible(h, b), r.neg_body)
                    push!(neg_deps[i], j)
                    break
                end
            end
        end
    end

    stratum = fill(1, n)
    limit = n + 1
    changed = true
    while changed
        changed = false
        for i in 1:n
            req = 1
            for j in pos_deps[i]
                req = max(req, stratum[j])
            end
            for j in neg_deps[i]
                req = max(req, stratum[j] + 1)
            end
            if req > stratum[i]
                if req > limit
                    culprits = [_dl_pred_name(encoder, _dl_atom_pred(a))
                                for a in rules[i].neg_body]
                    throw(ArgumentError(
                        "Datalog program is not stratifiable: negation occurs " *
                        "inside a recursive cycle (rule $i, negated atom(s) on " *
                        "$(join(unique(culprits), ", "))). Stratified negation " *
                        "requires that no predicate depends on itself through " *
                        "a negated atom."))
                end
                stratum[i] = req
                changed = true
            end
        end
    end

    max_stratum = maximum(stratum)
    strata = [Int[] for _ in 1:max_stratum]
    for i in 1:n
        push!(strata[stratum[i]], i)
    end
    filter!(!isempty, strata)
    return strata
end

# Check whether any negated atom is satisfied (present) — if so, the rule
# firing is blocked. Safety guarantees all positions resolve to constants.
@inline function _neg_blocked(neg_body::Vector{DatalogAtom}, bindings::DLBindings,
                              istore::IntStore)::Bool
    for a in neg_body
        s = is_var(a.s) ? bindings[var_slot(a.s)] : a.s
        p = is_var(a.p) ? bindings[var_slot(a.p)] : a.p
        o = is_var(a.o) ? bindings[var_slot(a.o)] : a.o
        # Unbound positions should be impossible (safety check), but be
        # conservative: an unverifiable negation blocks the derivation.
        (s == UNBOUND || p == UNBOUND || o == UNBOUND) && return true
        int_contains(istore, s, p, o) && return true
    end
    return false
end

# ─── Semi-Naive Evaluation ────────────────────────────────────────────────

"""
    semi_naive!(program; max_iterations=1000, init_istore=nothing) → Int

Run stratified semi-naive bottom-up evaluation with optimized join execution.
Rules are partitioned into strata (see [`stratify_rules`](@ref)); each stratum
is evaluated to fixpoint with semi-naive iteration before the next stratum
starts, so negated atoms only ever consult fully-computed lower strata.
Returns the number of new facts derived.

Throws an `ArgumentError` for unstratifiable programs or unsafe negation.
"""
function semi_naive!(prog::DatalogProgram; max_iterations::Int=1000,
                      init_istore::Union{IntStore,Nothing}=nothing)::Int
    rules = prog.rules
    isempty(rules) && return 0

    check_negation_safety(rules; encoder=prog.encoder)
    strata = stratify_rules(rules; encoder=prog.encoder)

    # Use IntStore for indexed storage (reuse if provided)
    istore = if init_istore !== nothing
        init_istore
    else
        s = IntStore()
        for t in prog.facts.tuples
            int_add!(s, t)
        end
        s
    end

    total_derived = 0
    for stratum_rules in strata
        total_derived += _semi_naive_stratum!(prog, stratum_rules, istore;
                                              max_iterations=max_iterations)
    end
    return total_derived
end

# Evaluate one stratum (a subset of prog.rules) to fixpoint with
# semi-naive iteration. Facts from lower strata are already in `istore`.
function _semi_naive_stratum!(prog::DatalogProgram, rule_indices::Vector{Int},
                              istore::IntStore; max_iterations::Int=1000)::Int
    rules = prog.rules
    isempty(rule_indices) && return 0

    # Separate single-body rules (no negation) from general rules.
    # Rules with negated atoms always take the general path so the
    # negation check runs before firing.
    single_rules = Int[]
    multi_rules = Int[]
    for i in rule_indices
        r = rules[i]
        if length(r.body) == 1 && isempty(r.neg_body)
            push!(single_rules, i)
        elseif length(r.body) >= 1
            push!(multi_rules, i)
        end
    end

    # Build multi-key rule index for single-body rules (same as N3 engine)
    sbody_po = Dict{Tuple{UInt32,UInt32}, Vector{Int}}()
    sbody_ps = Dict{Tuple{UInt32,UInt32}, Vector{Int}}()
    sbody_p  = Dict{UInt32, Vector{Int}}()
    sbody_var = Int[]

    for ri in single_rules
        pat = rules[ri].body[1]
        if is_var(pat.p)
            push!(sbody_var, ri)
        elseif !is_var(pat.o)
            push!(get!(Vector{Int}, sbody_po, (pat.p, pat.o)), ri)
        elseif !is_var(pat.s)
            push!(get!(Vector{Int}, sbody_ps, (pat.p, pat.s)), ri)
        else
            push!(get!(Vector{Int}, sbody_p, pat.p), ri)
        end
    end

    # Compiled single-body rules: skip unification when index already matched po/ps
    compiled = Vector{Union{DLCompiledRule, Nothing}}(nothing, length(rules))
    for ri in single_rules
        pat = rules[ri].body[1]
        s_slot = is_var(pat.s) ? Int(var_slot(pat.s)) : 0
        p_slot = is_var(pat.p) ? Int(var_slot(pat.p)) : 0
        o_slot = is_var(pat.o) ? Int(var_slot(pat.o)) : 0
        compiled[ri] = DLCompiledRule(s_slot, p_slot, o_slot, rules[ri].var_count, rules[ri].head)
    end

    # Pre-allocate binding arrays (one per rule)
    rule_bindings = [fill(UNBOUND, r.var_count) for r in rules]
    undo_stack = sizehint!(Int[], 32)

    # Reorder multi-body rule bodies for optimal join order (do once)
    ordered_bodies = Dict{Int, Vector{DatalogAtom}}()
    for ri in multi_rules
        ordered_bodies[ri] = reorder_body(rules[ri].body)
    end

    # Delta: start with all facts as "new" (relative to this stratum)
    delta = copy(istore.triples)

    total_derived = 0
    iteration = 0
    _empty_rules = Int[]

    while !isempty(delta) && iteration < max_iterations
        iteration += 1
        new_delta = IntTriple[]

        # ── Process single-body rules against delta (TAT-style) ──
        for t in delta
            # body_po index: (p, o) match — compiled fast path
            for ri in get(sbody_po, (t.p, t.o), _empty_rules)
                cr = compiled[ri]
                if cr !== nothing
                    bindings = rule_bindings[ri]
                    if cr.s_slot > 0; bindings[cr.s_slot] = t.s; end
                    for h in cr.head
                        cs = is_var(h.s) ? bindings[var_slot(h.s)] : h.s
                        cp = is_var(h.p) ? bindings[var_slot(h.p)] : h.p
                        co = is_var(h.o) ? bindings[var_slot(h.o)] : h.o
                        (cs == UNBOUND || cp == UNBOUND || co == UNBOUND) && continue
                        nt = IntTriple(cs, cp, co)
                        if int_add!(istore, nt)
                            push!(new_delta, nt)
                            relation_add!(prog.facts, nt)
                        end
                    end
                    if cr.s_slot > 0; bindings[cr.s_slot] = UNBOUND; end
                end
            end
            # body_ps index: (p, s) match — compiled fast path
            for ri in get(sbody_ps, (t.p, t.s), _empty_rules)
                cr = compiled[ri]
                if cr !== nothing
                    bindings = rule_bindings[ri]
                    if cr.o_slot > 0; bindings[cr.o_slot] = t.o; end
                    if cr.s_slot > 0; bindings[cr.s_slot] = t.s; end
                    for h in cr.head
                        cs = is_var(h.s) ? bindings[var_slot(h.s)] : h.s
                        cp = is_var(h.p) ? bindings[var_slot(h.p)] : h.p
                        co = is_var(h.o) ? bindings[var_slot(h.o)] : h.o
                        (cs == UNBOUND || cp == UNBOUND || co == UNBOUND) && continue
                        nt = IntTriple(cs, cp, co)
                        if int_add!(istore, nt)
                            push!(new_delta, nt)
                            relation_add!(prog.facts, nt)
                        end
                    end
                    if cr.o_slot > 0; bindings[cr.o_slot] = UNBOUND; end
                    if cr.s_slot > 0; bindings[cr.s_slot] = UNBOUND; end
                end
            end
            # body_p index: p-only match — use unification
            for ri in get(sbody_p, t.p, _empty_rules)
                _fire_single_rule!(rules[ri], t, rule_bindings[ri], undo_stack,
                                   istore, new_delta, prog.facts)
            end
            # variable-predicate rules
            for ri in sbody_var
                _fire_single_rule!(rules[ri], t, rule_bindings[ri], undo_stack,
                                   istore, new_delta, prog.facts)
            end
        end

        # ── Process multi-body rules with semi-naive join ──
        for ri in multi_rules
            rule = rules[ri]
            body = ordered_bodies[ri]
            n_body = length(body)

            for delta_pos in 1:n_body
                for dt in delta
                    bindings = rule_bindings[ri]
                    empty!(undo_stack)
                    _unify_atom!(body[delta_pos], dt, bindings, undo_stack) || begin
                        for i in 1:length(undo_stack); bindings[undo_stack[i]] = UNBOUND; end
                        continue
                    end

                    # Match remaining body atoms against full store
                    result_bindings = DLBindings[copy(bindings)]
                    for (i, atom) in enumerate(body)
                        i == delta_pos && continue
                        next_bindings = DLBindings[]
                        for b in result_bindings
                            _evaluate_atom_store!(next_bindings, atom, istore, b)
                        end
                        isempty(next_bindings) && break
                        result_bindings = next_bindings
                    end

                    for b in result_bindings
                        # Negation-as-failure: negated atoms consult only
                        # completed lower strata (stratification guarantees
                        # this stratum never derives a negated predicate).
                        if !isempty(rule.neg_body) && _neg_blocked(rule.neg_body, b, istore)
                            continue
                        end
                        _fire_head!(rule.head, b, istore, new_delta, prog.facts)
                    end

                    for i in 1:length(undo_stack); bindings[undo_stack[i]] = UNBOUND; end
                end
            end
        end

        total_derived += length(new_delta)
        delta = new_delta
    end

    return total_derived
end

# Fire a single-body rule: unify body with triple, then substitute head
@inline function _fire_single_rule!(rule::DatalogRule, t::IntTriple,
                                     bindings::DLBindings, undo_stack::Vector{Int},
                                     istore::IntStore, new_delta::Vector{IntTriple},
                                     facts::DatalogRelation)
    empty!(undo_stack)
    pat = rule.body[1]
    _unify_atom!(pat, t, bindings, undo_stack) || begin
        for i in 1:length(undo_stack); bindings[undo_stack[i]] = UNBOUND; end
        return
    end
    _fire_head!(rule.head, bindings, istore, new_delta, facts)
    for i in 1:length(undo_stack); bindings[undo_stack[i]] = UNBOUND; end
    return
end

# Unify an atom pattern against a triple, recording undo info
@inline function _unify_atom!(pat::DatalogAtom, t::IntTriple,
                                bindings::DLBindings, undo::Vector{Int})::Bool
    # Subject
    if is_var(pat.s)
        slot = var_slot(pat.s)
        cur = bindings[slot]
        if cur == UNBOUND
            bindings[slot] = t.s
            push!(undo, slot)
        elseif cur != t.s
            return false
        end
    elseif pat.s != t.s
        return false
    end
    # Predicate
    if is_var(pat.p)
        slot = var_slot(pat.p)
        cur = bindings[slot]
        if cur == UNBOUND
            bindings[slot] = t.p
            push!(undo, slot)
        elseif cur != t.p
            return false
        end
    elseif pat.p != t.p
        return false
    end
    # Object
    if is_var(pat.o)
        slot = var_slot(pat.o)
        cur = bindings[slot]
        if cur == UNBOUND
            bindings[slot] = t.o
            push!(undo, slot)
        elseif cur != t.o
            return false
        end
    elseif pat.o != t.o
        return false
    end
    return true
end

# Fire head: substitute variables and add new triples
@inline function _fire_head!(head::Vector{DatalogAtom}, bindings::DLBindings,
                               istore::IntStore, new_delta::Vector{IntTriple},
                               facts::DatalogRelation)
    for h in head
        cs = is_var(h.s) ? bindings[var_slot(h.s)] : h.s
        cp = is_var(h.p) ? bindings[var_slot(h.p)] : h.p
        co = is_var(h.o) ? bindings[var_slot(h.o)] : h.o
        (cs == UNBOUND || cp == UNBOUND || co == UNBOUND) && continue
        t = IntTriple(cs, cp, co)
        if int_add!(istore, t)
            push!(new_delta, t)
            relation_add!(facts, t)
        end
    end
end

# Evaluate an atom against the IntStore (uses SPO/POS indices)
function _evaluate_atom_store!(results::Vector{DLBindings}, atom::DatalogAtom,
                                 istore::IntStore, bindings::DLBindings)
    s_bound = _resolve(atom.s, bindings)
    p_bound = _resolve(atom.p, bindings)
    o_bound = _resolve(atom.o, bindings)

    if p_bound != UNBOUND && o_bound != UNBOUND && s_bound != UNBOUND
        # All bound — check existence
        if int_contains(istore, s_bound, p_bound, o_bound)
            push!(results, copy(bindings))
        end
    elseif p_bound != UNBOUND && o_bound != UNBOUND
        # POS lookup: p→o→[s]
        po = get(istore.pos, p_bound, nothing)
        po === nothing && return
        subjects = get(po, o_bound, nothing)
        subjects === nothing && return
        for s_val in subjects
            new_b = _try_bind(bindings, atom.s, s_val)
            new_b !== nothing && push!(results, new_b)
        end
    elseif p_bound != UNBOUND && s_bound != UNBOUND
        # SPO lookup: s→p→{o}
        sp = get(istore.spo, s_bound, nothing)
        sp === nothing && return
        objs = get(sp, p_bound, nothing)
        objs === nothing && return
        for o_val in objs
            new_b = _try_bind(bindings, atom.o, o_val)
            new_b !== nothing && push!(results, new_b)
        end
    elseif p_bound != UNBOUND
        # Scan all (s,o) for this predicate
        po = get(istore.pos, p_bound, nothing)
        po === nothing && return
        for (o_val, subjects) in po
            for s_val in subjects
                new_b = copy(bindings)
                _try_bind!(new_b, atom.s, s_val) || continue
                _try_bind!(new_b, atom.o, o_val) || continue
                push!(results, new_b)
            end
        end
    else
        # Full scan (rare)
        for (s_val, sp) in istore.spo
            for (p_val, objs) in sp
                for o_val in objs
                    new_b = copy(bindings)
                    _try_bind!(new_b, atom.s, s_val) || continue
                    _try_bind!(new_b, atom.p, p_val) || continue
                    _try_bind!(new_b, atom.o, o_val) || continue
                    push!(results, new_b)
                end
            end
        end
    end
end

# ─── N3 Rule Conversion ──────────────────────────────────────────────────

"""
    n3_rules_to_datalog(int_rules::Vector{IntRule}) → Vector{DatalogRule}

Convert N3 IntRules to DatalogRules. Each IntRule already has antecedent/consequent
as IntPattern vectors with variables marked by VAR_FLAG.
"""
function n3_rules_to_datalog(int_rules::Vector{IntRule})::Vector{DatalogRule}
    dl_rules = DatalogRule[]
    for ir in int_rules
        body = DatalogAtom[DatalogAtom(p.s, p.p, p.o) for p in ir.antecedent]
        head = DatalogAtom[DatalogAtom(p.s, p.p, p.o) for p in ir.consequent]
        push!(dl_rules, DatalogRule(head, body, ir.n_vars))
    end
    return dl_rules
end

# ─── High-Level API ──────────────────────────────────────────────────────

"""
    datalog_reason(g::RDFGraph; max_iterations=1000) → RDFGraph

Apply Datalog reasoning to an RDF graph containing N3 rules.
Returns a new graph with all inferred triples (excluding rules).

This is the Datalog equivalent of `reason(g)`. It:
1. Extracts N3 rules from the graph
2. Encodes all data triples to integers
3. Converts rules to Datalog format
4. Runs stratified semi-naive evaluation
5. Decodes results back to RDF terms

# Negation

Antecedent statements of the form `?SCOPE log:notIncludes { pattern }` are
treated as negated body atoms (negation-as-failure): the rule fires only when
no triple matching `pattern` is present. The subject of `log:notIncludes` is
ignored. The formula must contain exactly one triple pattern; every variable
in it must also occur in a positive body atom (safety), and the program must
be stratifiable (no recursion through negation) — otherwise an
`ArgumentError` is thrown.

```
{ ?x :type :Person . ?s log:notIncludes { ?x :status :banned } }
    => { ?x :status :welcome } .
```
"""
function datalog_reason(g::RDFGraph; max_iterations::Int=1000)::RDFGraph
    # Use the same rule extraction as the N3 reasoner
    enc = TermEncoder()

    # Separate rules from data
    log_implies_id = encode_term!(enc, URIRef("http://www.w3.org/2000/10/swap/log#implies"))

    istore = IntStore()
    dl_rules = DatalogRule[]

    # Encode graph: rules go to dl_rules, data to istore
    _ensure_indexed!(g.store)
    for triple in g.store.insertion_order
        s, p, o = triple.subject, triple.predicate, triple.object
        p_id = encode_term!(enc, p)
        if p_id == log_implies_id && s isa Formula && o isa Formula
            # This is a rule: extract antecedent/consequent
            _encode_n3_rule!(enc, s, o, dl_rules)
        else
            s_id = encode_term!(enc, s)
            o_id = encode_term!(enc, o)
            int_add!(istore, IntTriple(s_id, p_id, o_id))
        end
    end

    isempty(dl_rules) && return _decode_graph(enc, istore)

    # Build program from encoded data (uses IntStore directly)
    prog = DatalogProgram(dl_rules, DatalogRelation(), enc)
    for t in istore.triples
        relation_add!(prog.facts, t)
    end

    # Run semi-naive evaluation
    semi_naive!(prog; max_iterations=max_iterations, init_istore=istore)

    # Decode results back to RDF graph
    return _decode_istore(enc, prog)
end

const _DL_LOG_NOT_INCLUDES = URIRef("http://www.w3.org/2000/10/swap/log#notIncludes")

"""
Encode an N3 rule (Formula => Formula) into a DatalogRule with variable slots.
Antecedent statements `?SCOPE log:notIncludes { pattern }` become negated atoms.
"""
function _encode_n3_rule!(enc::TermEncoder, antecedent::Formula, consequent::Formula,
                           dl_rules::Vector{DatalogRule})
    # Collect all blank nodes in the rule and treat them as variables
    bnodes = Dict{BNode, UInt32}()
    var_slot_counter = Ref(UInt32(0))

    function get_var_slot!(node::BNode)::UInt32
        get!(bnodes, node) do
            var_slot_counter[] += 1
            VAR_FLAG | var_slot_counter[]
        end
    end

    function encode_term_or_var(term::Identifier)::UInt32
        if term isa BNode
            return get_var_slot!(term)
        elseif term isa Variable
            bn = BNode(string(term.name))
            return get_var_slot!(bn)
        else
            return encode_term!(enc, term)
        end
    end

    # Encode antecedent patterns (positive and negated)
    ant_patterns = DatalogAtom[]
    neg_patterns = DatalogAtom[]
    _ensure_indexed!(antecedent.graph.store)
    for t in antecedent.graph.store.insertion_order
        if t.predicate == _DL_LOG_NOT_INCLUDES && t.object isa Formula
            # Negated pattern: subject (scope) is ignored
            inner = collect(t.object.graph)
            length(inner) == 1 || throw(ArgumentError(
                "datalog_reason: log:notIncludes formula must contain exactly " *
                "one triple pattern (got $(length(inner)))"))
            it = inner[1]
            push!(neg_patterns, DatalogAtom(encode_term_or_var(it.subject),
                                            encode_term_or_var(it.predicate),
                                            encode_term_or_var(it.object)))
            continue
        end
        s_id = encode_term_or_var(t.subject)
        p_id = encode_term_or_var(t.predicate)
        o_id = encode_term_or_var(t.object)
        push!(ant_patterns, DatalogAtom(s_id, p_id, o_id))
    end

    # Encode consequent patterns
    con_patterns = DatalogAtom[]
    _ensure_indexed!(consequent.graph.store)
    for t in consequent.graph.store.insertion_order
        s_id = encode_term_or_var(t.subject)
        p_id = encode_term_or_var(t.predicate)
        o_id = encode_term_or_var(t.object)
        push!(con_patterns, DatalogAtom(s_id, p_id, o_id))
    end

    n_vars = Int(var_slot_counter[])
    push!(dl_rules, DatalogRule(con_patterns, ant_patterns, neg_patterns, n_vars))
end

function _decode_facts(enc::TermEncoder, facts::DatalogRelation)::RDFGraph
    result = RDFGraph()
    for t in facts.tuples
        s = decode_term(enc, t.s)
        p = decode_term(enc, t.p)
        o = decode_term(enc, t.o)
        add!(result, Triple(s, p, o))
    end
    return result
end

function _decode_graph(enc::TermEncoder, istore::IntStore)::RDFGraph
    result = RDFGraph()
    for t in istore.triples
        s = decode_term(enc, t.s)
        p = decode_term(enc, t.p)
        o = decode_term(enc, t.o)
        add!(result, Triple(s, p, o))
    end
    return result
end

function _decode_istore(enc::TermEncoder, prog::DatalogProgram)::RDFGraph
    result = RDFGraph()
    for t in prog.facts.tuples
        s = decode_term(enc, t.s)
        p = decode_term(enc, t.p)
        o = decode_term(enc, t.o)
        add!(result, Triple(s, p, o))
    end
    return result
end
