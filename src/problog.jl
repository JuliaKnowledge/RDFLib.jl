# ProbLog — Probabilistic Logic Programming for RDFLib.jl
#
# Implements exact probabilistic inference via BDD-based weighted model counting.
# Each probabilistic fact becomes a Boolean variable; derivation paths become
# Boolean formulas; BDD compilation + WMC gives exact success probabilities.
#
# Supports: probabilistic facts, rules, negation-as-failure (\+), evidence
# conditioning, wildcards (_), inequality (\==), and <- syntax.

# ─── Types ────────────────────────────────────────────────────────────────

"""
A ground atom: predicate name + tuple of arguments (all strings).
"""
struct PrologAtom
    predicate::String
    args::Vector{String}
    negated::Bool  # true for negation-as-failure (\+)
end

PrologAtom(pred::String, args::Vector{String}) = PrologAtom(pred, args, false)

Base.:(==)(a::PrologAtom, b::PrologAtom) = a.predicate == b.predicate && a.args == b.args && a.negated == b.negated
Base.hash(a::PrologAtom, h::UInt) = hash(a.predicate, hash(a.args, hash(a.negated, h)))

function Base.show(io::IO, a::PrologAtom)
    a.negated && print(io, "\\+")
    if isempty(a.args)
        print(io, a.predicate)
    else
        print(io, a.predicate, "(", join(a.args, ","), ")")
    end
end

"""Positive version of an atom (strip negation flag)."""
_pos(a::PrologAtom) = a.negated ? PrologAtom(a.predicate, a.args, false) : a

"""
A ProbLog clause: `prob :: head :- body1, body2, ...`
- `prob`: probability (1.0 for deterministic rules)
- `head`: head atom pattern (may contain variables like "X", "Y")
- `body`: vector of body atom patterns (may include negated atoms)
- Variables start with uppercase letter; `_` is a wildcard.
"""
struct PrologClause
    prob::Float64
    head::PrologAtom
    body::Vector{PrologAtom}
end

"""
A ProbLog program: collection of clauses + queries + evidence.
"""
mutable struct ProbLogProgram
    clauses::Vector{PrologClause}
    queries::Vector{PrologAtom}
    evidence::Vector{Tuple{PrologAtom, Bool}}
end

ProbLogProgram() = ProbLogProgram(PrologClause[], PrologAtom[], Tuple{PrologAtom,Bool}[])

# ─── Parser ───────────────────────────────────────────────────────────────

"""
    parse_problog(source::String) → ProbLogProgram

Parse a ProbLog program from a string. Supports:
- `p::fact.`                  probabilistic fact
- `p::head :- body1, body2.`  probabilistic rule
- `p::head <- body1, body2.`  probabilistic rule (alternative syntax)
- `head :- body1, body2.`     deterministic rule (prob=1.0)
- `fact.`                     deterministic fact (prob=1.0)
- `\\+atom`                   negation-as-failure in rule bodies
- `X \\== Y`                  inequality constraint in rule bodies
- `query(atom).`              query directive
- `evidence(atom, true/false).` evidence directive
- `% comment`                 comments
- `_` wildcard                 anonymous variable (unique per occurrence)
"""
function parse_problog(source::String)::ProbLogProgram
    prog = ProbLogProgram()
    lines = split(source, '\n')
    text = ""
    for line in lines
        ci = findfirst('%', line)
        if ci !== nothing
            line = line[1:ci-1]
        end
        text *= " " * strip(line)
    end

    # Split into statements on '.' but not on decimal points in numbers
    statements = String[]
    start = 1
    i = 1
    while i <= length(text)
        if text[i] == '.'
            is_decimal = false
            if i > 1 && i < length(text)
                is_decimal = isdigit(text[i-1]) && isdigit(text[i+1])
            end
            if !is_decimal
                push!(statements, text[start:i-1])
                start = i + 1
            end
        end
        i += 1
    end
    if start <= length(text)
        push!(statements, text[start:end])
    end

    _wildcard_counter = Ref(0)
    for stmt in statements
        s = strip(stmt)
        isempty(s) && continue
        _parse_statement!(prog, s, _wildcard_counter)
    end
    return prog
end

function _parse_statement!(prog::ProbLogProgram, s::AbstractString, wc::Ref{Int})
    s = strip(s)

    # query(atom) :- condition  (conditional query — treat condition as body for grounding)
    m = match(r"^query\(\s*(.+?)\s*\)\s*:-\s*(.+)$", s)
    if m !== nothing
        atom = _parse_atom(strip(m.captures[1]), wc)
        # For conditional queries like `query(p(X)) :- a(X)`, we add grounding queries
        # by expanding the body to find all valid X values
        _add_conditional_query!(prog, atom, strip(m.captures[2]), wc)
        return
    end

    # query(atom)
    m = match(r"^query\(\s*(.+)\s*\)$", s)
    if m !== nothing
        atom = _parse_atom(strip(m.captures[1]), wc)
        push!(prog.queries, atom)
        return
    end

    # evidence(atom, true/false)
    m = match(r"^evidence\(\s*(.+)\s*,\s*(true|false)\s*\)$", s)
    if m !== nothing
        atom = _parse_atom(strip(m.captures[1]), wc)
        val = m.captures[2] == "true"
        push!(prog.evidence, (atom, val))
        return
    end

    # prob :: head :- body  OR  prob :: head <- body  OR  prob :: fact
    prob = 1.0
    rest = s
    m = match(r"^([0-9]+(?:\.[0-9]+)?)\s*::\s*(.+)$", s)
    if m !== nothing
        prob = parse(Float64, m.captures[1])
        rest = strip(m.captures[2])
    end

    # head :- body  OR  head <- body
    m = match(r"^(.+?)\s*(?::-|<-)\s*(.+)$", rest)
    if m !== nothing
        head = _parse_atom(strip(m.captures[1]), wc)
        body_str = strip(m.captures[2])
        body = _parse_body(body_str, wc)
        push!(prog.clauses, PrologClause(prob, head, body))
    else
        # Bare fact
        head = _parse_atom(strip(rest), wc)
        push!(prog.clauses, PrologClause(prob, head, PrologAtom[]))
    end
end

"""Handle conditional queries like `query(p(X)) :- a(X).`"""
function _add_conditional_query!(prog::ProbLogProgram, query_atom::PrologAtom,
                                  cond_body::AbstractString, wc::Ref{Int})
    body_atoms = _parse_body(cond_body, wc)
    # Find all groundings of the condition using existing facts
    # For now, just collect ground atoms from clauses and ground the query
    # This will be resolved during grounding phase
    for atom in body_atoms
        # Look for matching ground facts in program
        for clause in prog.clauses
            if isempty(clause.body) && clause.head.predicate == atom.predicate &&
               length(clause.head.args) == length(atom.args) &&
               !any(_is_variable, clause.head.args)
                # Apply substitution to query atom
                subst = Dict{String,String}()
                matched = true
                for (p_arg, f_arg) in zip(atom.args, clause.head.args)
                    if _is_variable(p_arg)
                        if haskey(subst, p_arg)
                            if subst[p_arg] != f_arg
                                matched = false; break
                            end
                        else
                            subst[p_arg] = f_arg
                        end
                    elseif p_arg != f_arg
                        matched = false; break
                    end
                end
                if matched
                    g_query = _apply_subst(query_atom, subst)
                    if g_query ∉ prog.queries
                        push!(prog.queries, g_query)
                    end
                end
            end
        end
    end
end

function _parse_atom(s::AbstractString, wc::Ref{Int})::PrologAtom
    s = strip(s)
    # Handle negation-as-failure: \+atom or \+ atom
    negated = false
    if startswith(s, "\\+")
        negated = true
        s = strip(s[3:end])
    end

    m = match(r"^(\w+)\((.+)\)$", s)
    if m !== nothing
        pred = m.captures[1]
        args_str = m.captures[2]
        args = String[_process_arg(strip(a), wc) for a in _split_args(args_str)]
        return PrologAtom(pred, args, negated)
    else
        return PrologAtom(s, String[], negated)
    end
end

# Legacy version without wildcard counter
function _parse_atom(s::AbstractString)::PrologAtom
    wc = Ref(0)
    _parse_atom(s, wc)
end

"""Process an argument: replace `_` wildcards with unique variable names."""
function _process_arg(arg::AbstractString, wc::Ref{Int})::String
    if arg == "_"
        wc[] += 1
        return "_W$(wc[])"
    end
    return String(arg)
end

function _split_args(s::AbstractString)::Vector{String}
    args = String[]
    depth = 0
    start = 1
    for (i, c) in enumerate(s)
        if c == '('
            depth += 1
        elseif c == ')'
            depth -= 1
        elseif c == ',' && depth == 0
            push!(args, s[start:i-1])
            start = i + 1
        end
    end
    push!(args, s[start:end])
    return args
end

function _is_variable(s::String)::Bool
    !isempty(s) && (isuppercase(s[1]) || s[1] == '_')
end

"""Parse a comma-separated body, handling \\+ negation and \\== inequality."""
function _parse_body(s::AbstractString, wc::Ref{Int})::Vector{PrologAtom}
    parts = _split_body(s)
    atoms = PrologAtom[]
    for p in parts
        p = strip(p)
        isempty(p) && continue
        # Skip built-in constraints we can't evaluate (arithmetic, is, >, <)
        if _is_builtin_constraint(p)
            continue
        end
        # Handle \== inequality: X \== Y → stored as special atom
        m = match(r"^(\w+)\s*\\==\s*(\w+)$", p)
        if m !== nothing
            push!(atoms, PrologAtom("__neq__", [_process_arg(m.captures[1], wc),
                                                  _process_arg(m.captures[2], wc)], false))
            continue
        end
        push!(atoms, _parse_atom(p, wc))
    end
    return atoms
end

"""Split body text on commas, respecting parentheses and \\+ prefixes."""
function _split_body(s::AbstractString)::Vector{String}
    parts = String[]
    depth = 0
    start = 1
    for (i, c) in enumerate(s)
        if c == '('
            depth += 1
        elseif c == ')'
            depth -= 1
        elseif c == ',' && depth == 0
            push!(parts, s[start:i-1])
            start = i + 1
        end
    end
    push!(parts, s[start:end])
    return parts
end

"""Check if a body literal is an unsupported built-in constraint."""
function _is_builtin_constraint(s::AbstractString)::Bool
    s = strip(s)
    # Skip: true, X > 0, X is Y-1, X =:= Y, etc.
    s == "true" && return true
    occursin(r"\bis\b", s) && return true
    occursin(r"[><=]", s) && !occursin(r"\\==", s) && return true
    occursin(r"=:=|=\\=|=\.\.", s) && return true
    return false
end

# ─── Grounding ────────────────────────────────────────────────────────────

"""
Ground a ProbLog program: expand all variables by substitution.
Iteratively grounds rules as new facts are derived.
Handles negation-as-failure atoms and inequality constraints.
"""
function ground_program(prog::ProbLogProgram)::Vector{Tuple{Float64, PrologAtom, Vector{PrologAtom}}}
    ground_atoms = Dict{String, Set{PrologAtom}}()

    # First pass: collect all ground facts
    for clause in prog.clauses
        if isempty(clause.body) && !any(_is_variable, clause.head.args)
            pset = get!(Set{PrologAtom}, ground_atoms, clause.head.predicate)
            push!(pset, clause.head)
        end
    end

    ground_clauses = Tuple{Float64, PrologAtom, Vector{PrologAtom}}[]
    seen_clauses = Set{UInt64}()

    _gc_hash(p, h, b) = hash(p, hash(h, hash(b)))

    # Add ground facts
    for clause in prog.clauses
        if isempty(clause.body) && !any(_is_variable, clause.head.args)
            hsh = _gc_hash(clause.prob, clause.head, PrologAtom[])
            if hsh ∉ seen_clauses
                push!(seen_clauses, hsh)
                push!(ground_clauses, (clause.prob, clause.head, PrologAtom[]))
            end
        end
    end

    # Iteratively ground rules until no new ground atoms are produced
    changed = true
    while changed
        changed = false
        for clause in prog.clauses
            vars = _collect_vars(clause)
            if isempty(vars) && !isempty(clause.body)
                # Already ground rule — add once
                # Filter out satisfied constraints
                body = _filter_ground_body(clause.body)
                body === nothing && continue  # constraint failed
                hsh = _gc_hash(clause.prob, clause.head, body)
                if hsh ∉ seen_clauses
                    push!(seen_clauses, hsh)
                    push!(ground_clauses, (clause.prob, clause.head, body))
                    pset = get!(Set{PrologAtom}, ground_atoms, clause.head.predicate)
                    if clause.head ∉ pset
                        push!(pset, clause.head)
                        changed = true
                    end
                end
                continue
            end

            isempty(vars) && continue

            substitutions = _find_groundings(clause, ground_atoms)
            for subst in substitutions
                g_head = _apply_subst(clause.head, subst)
                g_body_raw = PrologAtom[_apply_subst(a, subst) for a in clause.body]
                g_body = _filter_ground_body(g_body_raw)
                g_body === nothing && continue  # constraint failed
                hsh = _gc_hash(clause.prob, g_head, g_body)
                if hsh ∉ seen_clauses
                    push!(seen_clauses, hsh)
                    push!(ground_clauses, (clause.prob, g_head, g_body))
                    pset = get!(Set{PrologAtom}, ground_atoms, g_head.predicate)
                    if g_head ∉ pset
                        push!(pset, g_head)
                        changed = true
                    end
                end
            end
        end
    end

    return ground_clauses
end

"""Filter ground body: evaluate constraints (__neq__), keep regular atoms."""
function _filter_ground_body(body::Vector{PrologAtom})::Union{Nothing, Vector{PrologAtom}}
    filtered = PrologAtom[]
    for atom in body
        if atom.predicate == "__neq__"
            # Inequality constraint: both args must be ground and different
            length(atom.args) == 2 || return nothing
            atom.args[1] == atom.args[2] && return nothing  # constraint violated
            # Constraint satisfied — don't include in body
        else
            push!(filtered, atom)
        end
    end
    return filtered
end

function _collect_vars(clause::PrologClause)::Set{String}
    vars = Set{String}()
    for arg in clause.head.args
        _is_variable(arg) && push!(vars, arg)
    end
    for atom in clause.body
        for arg in atom.args
            _is_variable(arg) && push!(vars, arg)
        end
    end
    return vars
end

function _find_groundings(clause::PrologClause,
                           ground_facts::Dict{String, Set{PrologAtom}})::Vector{Dict{String,String}}
    substitutions = Dict{String,String}[Dict{String,String}()]

    # For each non-negated, non-constraint body atom, constrain substitutions
    for atom in clause.body
        atom.negated && continue  # negated atoms don't provide bindings
        atom.predicate == "__neq__" && continue  # constraints checked after grounding
        facts = get(ground_facts, atom.predicate, Set{PrologAtom}())
        new_subs = Dict{String,String}[]
        for subst in substitutions
            for fact in facts
                length(fact.args) == length(atom.args) || continue
                new_subst = _try_match(atom, fact, subst)
                new_subst !== nothing && push!(new_subs, new_subst)
            end
        end
        substitutions = new_subs
        isempty(substitutions) && return substitutions
    end

    # Check inequality constraints
    if any(a -> a.predicate == "__neq__", clause.body)
        substitutions = filter(substitutions) do subst
            for atom in clause.body
                atom.predicate == "__neq__" || continue
                a1 = get(subst, atom.args[1], atom.args[1])
                a2 = get(subst, atom.args[2], atom.args[2])
                a1 == a2 && return false
            end
            return true
        end
    end

    # For facts with variables (head-only), ground against known constants
    if isempty(clause.body) && any(_is_variable, clause.head.args)
        all_constants = Set{String}()
        for (_, facts) in ground_facts
            for f in facts
                for a in f.args
                    push!(all_constants, a)
                end
            end
        end

        new_subs = Dict{String,String}[]
        head_vars = [arg for arg in clause.head.args if _is_variable(arg)]
        for subst in substitutions
            _enumerate_substs!(new_subs, head_vars, 1, subst, collect(all_constants))
        end
        substitutions = new_subs
    end

    return substitutions
end

function _enumerate_substs!(results::Vector{Dict{String,String}},
                              vars::Vector{String}, idx::Int,
                              subst::Dict{String,String}, constants::Vector{String})
    if idx > length(vars)
        push!(results, copy(subst))
        return
    end
    v = vars[idx]
    if haskey(subst, v)
        _enumerate_substs!(results, vars, idx + 1, subst, constants)
    else
        for c in constants
            subst[v] = c
            _enumerate_substs!(results, vars, idx + 1, subst, constants)
        end
        delete!(subst, v)
    end
end

function _try_match(pattern::PrologAtom, fact::PrologAtom,
                     subst::Dict{String,String})::Union{Dict{String,String}, Nothing}
    new_subst = copy(subst)
    for (p_arg, f_arg) in zip(pattern.args, fact.args)
        if _is_variable(p_arg)
            if haskey(new_subst, p_arg)
                new_subst[p_arg] == f_arg || return nothing
            else
                new_subst[p_arg] = f_arg
            end
        else
            p_arg == f_arg || return nothing
        end
    end
    return new_subst
end

function _apply_subst(atom::PrologAtom, subst::Dict{String,String})::PrologAtom
    new_args = String[get(subst, a, a) for a in atom.args]
    PrologAtom(atom.predicate, new_args, atom.negated)
end

# ─── BDD (Reduced Ordered Binary Decision Diagram) ───────────────────────
#
# A BDD node is either:
# - Terminal: TRUE (id=1) or FALSE (id=0)
# - Internal: variable var, low child (var=false), high child (var=true)
#
# We use hash-consing (unique table) to ensure each distinct (var,low,high)
# triple maps to exactly one node. This makes equality checks O(1).

const BDD_FALSE = 0
const BDD_TRUE  = 1

struct BDDNode
    var::Int32     # variable index (0 for terminals)
    low::Int32     # node id when var=false
    high::Int32    # node id when var=true
end

"""BDD manager: maintains unique table and computed-table (memo) for operations."""
mutable struct BDDManager
    nodes::Vector{BDDNode}             # node id → BDDNode
    unique::Dict{BDDNode, Int32}       # (var,low,high) → node id
    apply_cache::Dict{Tuple{Int32,Int32,Symbol}, Int32}  # memoized apply results
    n_vars::Int32
end

function BDDManager()
    mgr = BDDManager(
        BDDNode[BDDNode(0, 0, 0), BDDNode(0, 1, 1)],  # FALSE=1, TRUE=2 (1-indexed)
        Dict{BDDNode, Int32}(),
        Dict{Tuple{Int32,Int32,Symbol}, Int32}(),
        Int32(0)
    )
    return mgr
end

@inline bdd_is_terminal(id::Int32) = id <= Int32(2)
@inline bdd_is_true(id::Int32) = id == Int32(2)
@inline bdd_is_false(id::Int32) = id == Int32(1)

"""Get or create a BDD node. Enforces reduction rules."""
function bdd_mk!(mgr::BDDManager, var::Int32, low::Int32, high::Int32)::Int32
    # Reduction: if both children are the same, skip this node
    low == high && return low
    node = BDDNode(var, low, high)
    # Check unique table
    get!(mgr.unique, node) do
        push!(mgr.nodes, node)
        Int32(length(mgr.nodes))
    end
end

"""Create a new BDD variable (positive literal)."""
function bdd_var!(mgr::BDDManager)::Int32
    mgr.n_vars += Int32(1)
    bdd_mk!(mgr, mgr.n_vars, Int32(1), Int32(2))  # false if var=false, true if var=true
end

"""Apply a binary operation (AND, OR) to two BDD nodes."""
function bdd_apply!(mgr::BDDManager, f::Int32, g::Int32, op::Symbol)::Int32
    # Terminal cases
    if op == :and
        bdd_is_false(f) && return Int32(1)
        bdd_is_false(g) && return Int32(1)
        bdd_is_true(f) && return g
        bdd_is_true(g) && return f
    elseif op == :or
        bdd_is_true(f) && return Int32(2)
        bdd_is_true(g) && return Int32(2)
        bdd_is_false(f) && return g
        bdd_is_false(g) && return f
    end
    f == g && (op == :and || op == :or) && return f

    # Check cache
    key = (f, g, op)
    cached = get(mgr.apply_cache, key, Int32(0))
    cached != Int32(0) && return cached

    fn = mgr.nodes[f]
    gn = mgr.nodes[g]

    # Determine top variable
    fvar = bdd_is_terminal(f) ? typemax(Int32) : fn.var
    gvar = bdd_is_terminal(g) ? typemax(Int32) : gn.var
    topvar = min(fvar, gvar)

    # Cofactors
    f_low  = fvar == topvar ? fn.low  : f
    f_high = fvar == topvar ? fn.high : f
    g_low  = gvar == topvar ? gn.low  : g
    g_high = gvar == topvar ? gn.high : g

    # Recurse
    low  = bdd_apply!(mgr, f_low,  g_low,  op)
    high = bdd_apply!(mgr, f_high, g_high, op)

    result = bdd_mk!(mgr, topvar, low, high)
    mgr.apply_cache[key] = result
    return result
end

@inline function bdd_and!(mgr::BDDManager, f::Int32, g::Int32)::Int32
    bdd_apply!(mgr, f, g, :and)
end

@inline function bdd_or!(mgr::BDDManager, f::Int32, g::Int32)::Int32
    bdd_apply!(mgr, f, g, :or)
end

"""Negate a BDD node."""
function bdd_not!(mgr::BDDManager, f::Int32)::Int32
    bdd_is_true(f) && return Int32(1)
    bdd_is_false(f) && return Int32(2)

    cached = get(mgr.apply_cache, (f, Int32(0), :not), Int32(0))
    cached != Int32(0) && return cached

    fn = mgr.nodes[f]
    low  = bdd_not!(mgr, fn.low)
    high = bdd_not!(mgr, fn.high)
    result = bdd_mk!(mgr, fn.var, low, high)
    mgr.apply_cache[(f, Int32(0), :not)] = result
    return result
end

"""
Weighted model count on a BDD.
`weights[var]` = (weight_true, weight_false) for each variable.
Returns the sum over all satisfying assignments of Π(weights along assignment).
"""
function bdd_wmc(mgr::BDDManager, node::Int32,
                  weights::Dict{Int32, Tuple{Float64, Float64}})::Float64
    cache = Dict{Int32, Float64}()
    _bdd_wmc_rec(mgr, node, weights, cache)
end

function _bdd_wmc_rec(mgr::BDDManager, node::Int32,
                       weights::Dict{Int32, Tuple{Float64, Float64}},
                       cache::Dict{Int32, Float64})::Float64
    bdd_is_true(node) && return 1.0
    bdd_is_false(node) && return 0.0

    cached = get(cache, node, NaN)
    !isnan(cached) && return cached

    n = mgr.nodes[node]
    w_true, w_false = weights[n.var]

    val_low  = _bdd_wmc_rec(mgr, n.low,  weights, cache)
    val_high = _bdd_wmc_rec(mgr, n.high, weights, cache)

    result = w_false * val_low + w_true * val_high
    cache[node] = result
    return result
end

# ─── BDD-Based Probabilistic Inference ────────────────────────────────────

"""
    problog_infer(prog::ProbLogProgram) → Dict{PrologAtom, Float64}

Run exact probabilistic inference using BDD-based weighted model counting.

Algorithm:
1. Ground the program
2. Assign a BDD variable to each unique probabilistic fact
3. For each query atom, build a Boolean formula representing all derivation paths
4. Compile the formula to a BDD
5. Compute exact probability via weighted model counting
"""
function problog_infer(prog::ProbLogProgram;
                        max_iterations::Int=1000,
                        tol::Float64=1e-10)::Dict{PrologAtom, Float64}
    ground_clauses = ground_program(prog)

    # Separate facts and rules
    fact_clauses = Tuple{Float64, PrologAtom}[]
    rule_clauses = Tuple{Float64, PrologAtom, Vector{PrologAtom}}[]

    for (p, head, body) in ground_clauses
        if isempty(body)
            push!(fact_clauses, (p, head))
        else
            push!(rule_clauses, (p, head, body))
        end
    end

    # Create BDD manager
    mgr = BDDManager()
    # weights: variable INDEX → (weight_true, weight_false)
    weights = Dict{Int32, Tuple{Float64, Float64}}()

    """Create a new BDD variable with given probability weight."""
    function _new_prob_var!(prob::Float64)::Int32
        node_id = bdd_var!(mgr)
        var_idx = mgr.n_vars  # variable index assigned by bdd_var!
        weights[var_idx] = (prob, 1.0 - prob)
        return node_id
    end

    # Assign a BDD variable to each unique probabilistic fact
    # Deterministic facts (prob=1.0) don't need variables
    fact_node = Dict{PrologAtom, Int32}()     # atom → BDD node id
    fact_prob = Dict{PrologAtom, Float64}()   # atom → probability (for reference)

    for (p, atom) in fact_clauses
        if !haskey(fact_prob, atom)
            fact_prob[atom] = p
            if p < 1.0 && p > 0.0
                fact_node[atom] = _new_prob_var!(p)
            end
        else
            # Multiple facts for same atom: independent sources → OR of BDD variables
            if !haskey(fact_node, atom)
                # First source was deterministic (p=1.0 or p=0.0)
                old_p = fact_prob[atom]
                if old_p == 1.0
                    # Already TRUE, additional source doesn't change anything
                    continue
                end
                # old_p was 0.0, now we have a new source
                fact_node[atom] = _new_prob_var!(p)
                fact_prob[atom] = p
            else
                # Both are probabilistic — OR them as independent variables
                new_node = _new_prob_var!(p)
                fact_node[atom] = bdd_or!(mgr, fact_node[atom], new_node)
                # Update combined probability for reference
                fact_prob[atom] = 1.0 - (1.0 - fact_prob[atom]) * (1.0 - p)
            end
        end
    end

    # Build derivation BDDs for each atom
    atom_bdd = Dict{PrologAtom, Int32}()

    # Initialize fact BDDs
    for (atom, p) in fact_prob
        if p == 1.0
            atom_bdd[atom] = Int32(2)  # TRUE
        elseif p == 0.0
            atom_bdd[atom] = Int32(1)  # FALSE
        elseif haskey(fact_node, atom)
            atom_bdd[atom] = fact_node[atom]
        end
    end

    # Group rules by head
    rules_by_head = Dict{PrologAtom, Vector{Tuple{Float64, Vector{PrologAtom}}}}()
    for (p, head, body) in rule_clauses
        rules = get!(Vector{Tuple{Float64, Vector{PrologAtom}}}, rules_by_head, head)
        push!(rules, (p, body))
    end

    # Allocate BDD variables for probabilistic rules up-front (not per-iteration)
    rule_vars = Dict{Int, Int32}()  # rule index → BDD node id
    rule_index = 0
    rule_indexed = Tuple{Int, Float64, PrologAtom, Vector{PrologAtom}}[]
    for (head, rules) in rules_by_head
        for (rule_prob, body) in rules
            rule_index += 1
            push!(rule_indexed, (rule_index, rule_prob, head, body))
            if rule_prob < 1.0 && rule_prob > 0.0
                rule_vars[rule_index] = _new_prob_var!(rule_prob)
            end
        end
    end

    # Re-group indexed rules by head
    indexed_by_head = Dict{PrologAtom, Vector{Tuple{Int, Float64, Vector{PrologAtom}}}}()
    for (idx, rp, head, body) in rule_indexed
        rs = get!(Vector{Tuple{Int, Float64, Vector{PrologAtom}}}, indexed_by_head, head)
        push!(rs, (idx, rp, body))
    end

    # Iterative BDD construction (for recursive programs)
    for _ in 1:max_iterations
        changed = false
        for (head, rules) in indexed_by_head
            head_bdd = get(atom_bdd, head, Int32(1))  # existing BDD or FALSE

            # Start from fact BDD (if any)
            new_head_bdd = Int32(1)  # FALSE
            if haskey(fact_prob, head)
                p = fact_prob[head]
                if p == 1.0
                    new_head_bdd = Int32(2)
                elseif p > 0.0 && haskey(fact_node, head)
                    new_head_bdd = fact_node[head]
                end
            end

            for (rule_idx, rule_prob, body) in rules
                rule_prob == 0.0 && continue

                # Build body BDD: AND of all body atom BDDs
                body_bdd = Int32(2)  # TRUE
                all_resolved = true
                for batom in body
                    pos_atom = _pos(batom)
                    b_bdd = get(atom_bdd, pos_atom, Int32(0))
                    if b_bdd == Int32(0)
                        if batom.negated
                            # Negated atom with no BDD → atom is always false → \+atom is TRUE
                            continue
                        end
                        all_resolved = false
                        break
                    end
                    if batom.negated
                        b_bdd = bdd_not!(mgr, b_bdd)
                    end
                    body_bdd = bdd_and!(mgr, body_bdd, b_bdd)
                    bdd_is_false(body_bdd) && break
                end
                !all_resolved && continue

                # If rule has probability < 1.0, AND with its pre-allocated variable
                if rule_prob < 1.0
                    body_bdd = bdd_and!(mgr, body_bdd, rule_vars[rule_idx])
                end

                # OR into head BDD
                new_head_bdd = bdd_or!(mgr, new_head_bdd, body_bdd)
            end

            if new_head_bdd != head_bdd
                atom_bdd[head] = new_head_bdd
                changed = true
            end
        end

        !changed && break
    end

    # Compute probabilities via WMC
    probs = Dict{PrologAtom, Float64}()

    # Build evidence BDD: conjunction of all evidence constraints
    evidence_bdd = Int32(2)  # TRUE
    has_evidence = !isempty(prog.evidence)
    if has_evidence
        for (ev_atom, ev_val) in prog.evidence
            pos_ev = _pos(ev_atom)
            ev_node = get(atom_bdd, pos_ev, Int32(0))
            if ev_node == Int32(0)
                # Atom not derived at all
                if ev_val
                    evidence_bdd = Int32(1)  # FALSE — evidence impossible
                end
                # If evidence is false for non-derived atom, that's trivially satisfied
                continue
            end
            if ev_val
                evidence_bdd = bdd_and!(mgr, evidence_bdd, ev_node)
            else
                evidence_bdd = bdd_and!(mgr, evidence_bdd, bdd_not!(mgr, ev_node))
            end
        end
    end

    if has_evidence && !bdd_is_false(evidence_bdd)
        # P(evidence)
        p_evidence = bdd_wmc(mgr, evidence_bdd, weights)
        if p_evidence > 0.0
            for (atom, bdd_id) in atom_bdd
                # P(query | evidence) = P(query ∧ evidence) / P(evidence)
                joint_bdd = bdd_and!(mgr, bdd_id, evidence_bdd)
                p_joint = bdd_wmc(mgr, joint_bdd, weights)
                probs[atom] = p_joint / p_evidence
            end
        end
    else
        for (atom, bdd_id) in atom_bdd
            probs[atom] = bdd_wmc(mgr, bdd_id, weights)
        end
    end

    return probs
end

# ─── High-Level API ──────────────────────────────────────────────────────

"""
    problog_query(source::String) → Dict{String, Float64}

Parse and evaluate a ProbLog program, returning probabilities for queried atoms.

Example:
```julia
result = problog_query(\"\"\"
    0.5::heads1.
    0.6::heads2.
    someHeads :- heads1.
    someHeads :- heads2.
    query(someHeads).
\"\"\")
# result["someHeads"] ≈ 0.8
```
"""
function problog_query(source::String;
                        max_iterations::Int=1000,
                        tol::Float64=1e-10)::Dict{String, Float64}
    prog = parse_problog(source)
    probs = problog_infer(prog; max_iterations=max_iterations, tol=tol)

    result = Dict{String, Float64}()
    for q in prog.queries
        key = string(q)
        result[key] = get(probs, q, 0.0)
    end
    return result
end

"""
    problog_query(source::String, queries::Vector{String}) → Dict{String, Float64}

Parse a ProbLog program and evaluate specific queries (ignoring query() directives).
"""
function problog_query(source::String, queries::Vector{String};
                        max_iterations::Int=1000,
                        tol::Float64=1e-10)::Dict{String, Float64}
    prog = parse_problog(source)
    # Override queries
    prog.queries = PrologAtom[_parse_atom(q) for q in queries]
    probs = problog_infer(prog; max_iterations=max_iterations, tol=tol)

    result = Dict{String, Float64}()
    for q in prog.queries
        key = string(q)
        result[key] = get(probs, q, 0.0)
    end
    return result
end
