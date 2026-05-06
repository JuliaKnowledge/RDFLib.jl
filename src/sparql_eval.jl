# ═══════════════════════════════════════════════════════════════════
# SPARQL Evaluator — walks the AST produced by sparql_parser.jl
# ═══════════════════════════════════════════════════════════════════
#
# Evaluates SparqlQuery AST nodes against an RDFGraph, producing
# results in the same format as the legacy evaluator.

const _XSD_NS = "http://www.w3.org/2001/XMLSchema#"

# ─── Top-level evaluation ─────────────────────────────────────────

function _ast_evaluate(g::RDFGraph, q::SparqlSelect)
    # Fast path: SELECT (COUNT(*) AS ?x) WHERE { ?s ?p ?o } with no other clauses.
    # Bypasses BGP materialisation; uses the store's `length` directly.
    if _is_count_star_query(q)
        return [Dict{String,Identifier}(q.aggregates[1].alias => Literal(length(g)))]
    end

    # Push LIMIT into pattern evaluation when safe (no ORDER BY, GROUP BY, DISTINCT, computed exprs)
    push_limit = 0
    if !isnothing(q.limit) && isempty(q.order_by) && isempty(q.aggregates) &&
       isempty(q.group_by) && !q.distinct && !q.reduced && isempty(q.select_exprs)
        push_limit = q.offset + q.limit
    end
    bindings = _ast_eval_patterns(g, q.patterns; limit=push_limit)

    # Evaluate SELECT expressions
    for b in bindings
        for se in q.select_exprs
            val = _ast_eval_expr(se.expr, b, g)
            !isnothing(val) && (b[se.alias] = val)
        end
    end

    # Aggregates and GROUP BY
    if !isempty(q.aggregates) || !isempty(q.group_by)
        bindings = _ast_eval_group_aggregate(q, bindings, g)
    end

    # ORDER BY — use partial sort when LIMIT is set (top-K optimization)
    if !isempty(q.order_by)
        cmp = (a, b) -> _ast_order_compare(a, b, q.order_by, g)
        k = q.offset + (isnothing(q.limit) ? length(bindings) : q.limit)
        if k < length(bindings)
            sort!(bindings, lt=cmp, alg=PartialQuickSort(k))
        else
            sort!(bindings, lt=cmp)
        end
    end

    # Project variables — skip if bindings already match projection
    proj_vars = _ast_projection_vars(q)
    if !isempty(proj_vars) && !isempty(bindings)
        b1 = bindings[1]
        needs_proj = length(b1) != length(proj_vars) || !all(v -> haskey(b1, v), proj_vars)
        if needs_proj
            bindings = [Dict{String,Identifier}(v => b[v] for v in proj_vars if haskey(b, v)) for b in bindings]
        end
    end

    # DISTINCT / REDUCED
    (q.distinct || q.reduced) && (bindings = unique(bindings))

    # OFFSET + LIMIT
    start = q.offset + 1
    stop = isnothing(q.limit) ? length(bindings) : min(start + q.limit - 1, length(bindings))
    start <= length(bindings) ? bindings[start:stop] : Dict{String,Identifier}[]
end

function _ast_evaluate(g::RDFGraph, q::SparqlAsk)
    !isempty(_ast_eval_patterns(g, q.patterns))
end

# True iff the query is `SELECT (COUNT(*) AS ?x) WHERE { ?s ?p ?o }` with no
# other clauses (no GROUP BY, ORDER BY, LIMIT, OFFSET, HAVING, DISTINCT,
# select_exprs, or extra patterns). Lets us answer with `length(g)`.
function _is_count_star_query(q::SparqlSelect)
    length(q.aggregates) == 1 || return false
    isempty(q.select_exprs) || return false
    isempty(q.group_by) || return false
    isnothing(q.having) || return false
    isempty(q.order_by) || return false
    isnothing(q.limit) || return false
    q.offset == 0 || return false
    q.distinct && return false
    q.reduced && return false
    length(q.patterns) == 1 || return false
    p = q.patterns[1]
    p isa PatTriple || return false
    p.subject isa String || return false
    p.predicate isa String || return false
    p.object isa String || return false
    agg = q.aggregates[1].agg
    agg isa ExprAggregate || return false
    agg.func == "COUNT" || return false
    agg.distinct && return false
    agg.arg isa ExprStar || return false
    true
end

function _ast_evaluate(g::RDFGraph, q::SparqlConstruct)
    # Push LIMIT into pattern evaluation when safe (no ORDER BY)
    push_limit = isnothing(q.limit) ? 0 : q.offset + q.limit
    bindings = _ast_eval_patterns(g, q.patterns; limit=push_limit)
    # Apply LIMIT/OFFSET to bindings before constructing
    start = q.offset + 1
    stop = isnothing(q.limit) ? length(bindings) : min(start + q.limit - 1, length(bindings))
    bindings = start <= length(bindings) ? bindings[start:stop] : Dict{String,Identifier}[]
    result = RDFGraph()
    for b in bindings
        for pt in q.template
            s = _ast_resolve_term(pt.subject, b)
            p = _ast_resolve_term(pt.predicate, b)
            o = _ast_resolve_term(pt.object, b)
            (isnothing(s) || isnothing(p) || isnothing(o)) && continue
            s isa Node || continue
            p isa URIRef || continue
            o isa Identifier || continue
            add!(result, Triple(s, p, o))
        end
    end
    result
end

function _ast_evaluate(g::RDFGraph, q::SparqlDescribe)
    if isempty(q.terms)
        # DESCRIBE * — describe all subjects
        subjects = Set{Node}()
        for t in triples(g)
            push!(subjects, t.subject)
        end
        result = RDFGraph()
        for s in subjects
            for t in triples(g)
                t.subject == s && add!(result, t)
            end
        end
        return result
    end

    # Resolve terms to nodes
    bindings = isempty(q.patterns) ? [Dict{String,Identifier}()] : _ast_eval_patterns(g, q.patterns)
    nodes = Set{Node}()
    for term in q.terms
        if term isa ExprURI
            push!(nodes, term.uri)
        elseif term isa ExprVar
            for b in bindings
                v = get(b, term.name, nothing)
                v isa Node && push!(nodes, v)
            end
        end
    end

    # CBD (Concise Bounded Description)
    result = RDFGraph()
    for node in nodes
        _cbd!(result, g, node, Set{Node}())
    end
    result
end

function _cbd!(result::RDFGraph, g::RDFGraph, node::Node, visited::Set{Node})
    node in visited && return
    push!(visited, node)
    for t in triples(g)
        if t.subject == node
            add!(result, t)
            t.object isa BNode && _cbd!(result, g, t.object, visited)
        end
    end
end

# ─── Pattern evaluation ───────────────────────────────────────────

function _ast_eval_patterns(g::RDFGraph, patterns::Vector{SparqlPattern},
                             bindings::Vector{Dict{String,Identifier}} = Dict{String,Identifier}[Dict{String,Identifier}()];
                             limit::Int = 0)
    # Ensure store indices are built before querying
    if g.store isa MemoryStore
        _ensure_all_indexed!(g.store)
    end
    # Star-join optimization for MemoryStore
    if g.store isa MemoryStore && length(patterns) >= 2
        # Reorder star groups by selectivity (only when no bindings yet — i.e.,
        # this is the top-level BGP). Filters travel with their preceding star.
        if length(bindings) == 1 && isempty(bindings[1])
            patterns = _reorder_star_groups(g.store::MemoryStore, patterns)
        end
        return _ast_eval_patterns_star(g, patterns, bindings, limit)
    end
    for pattern in patterns
        bindings = _ast_eval_pattern(g, pattern, bindings)
        isempty(bindings) && return bindings
    end
    bindings
end

# Reorder star groups (with their trailing PatFilters) by estimated selectivity.
# Star groups with bound objects are usually highly selective. Only reorders
# contiguous prefix made of (star group + optional PatFilters)*. Stops at the
# first pattern that's not a recognizable star-group head or PatFilter.
function _reorder_star_groups(store::MemoryStore, patterns::Vector{SparqlPattern})
    n = length(patterns)
    groups = Tuple{Int,Int,Int,Int,Set{String},Set{String}}[]
    i = 1
    while i <= n
        send = _star_group_end(patterns, i)
        if send == i
            break
        end
        # Subject variable + all object variables produced
        produced = Set{String}()
        consumed = Set{String}()  # all vars referenced; if any is already bound,
                                   # this group acts as a join (no cartesian)
        @inbounds for k in i:send
            pat = patterns[k]::PatTriple
            s = pat.subject; s isa String && (push!(produced, s); push!(consumed, s))
            o = pat.object;  o isa String && (push!(produced, o); push!(consumed, o))
        end
        fend = send
        j = send + 1
        ok = true
        while j <= n && patterns[j] isa PatFilter
            fvars = String[]
            _collect_vars_in_expr!(fvars, (patterns[j]::PatFilter).expr)
            if !issubset(Set(fvars), produced)
                ok = false; break
            end
            fend = j; j += 1
        end
        if !ok
            break
        end
        score = _estimate_star_selectivity(store, patterns, i, send)
        push!(groups, (i, send, fend, score, produced, consumed))
        i = fend + 1
    end
    length(groups) < 2 && return patterns

    # Greedy join-aware planner: pick the most-selective group whose required
    # variables are all already produced (or that introduces no join constraint).
    # First group can be any (start with most selective).
    remaining = collect(eachindex(groups))
    available = Set{String}()
    order = Int[]
    while !isempty(remaining)
        best_idx = -1
        best_score = typemax(Int)
        # Prefer groups whose subject var is already in `available` (joins existing)
        for ri in remaining
            (_, _, _, sc, prod, cons) = groups[ri]
            connected = isempty(available) || !isempty(intersect(cons, available))
            connected || continue
            if sc < best_score
                best_score = sc; best_idx = ri
            end
        end
        if best_idx == -1
            # No connected group; fall back to most selective overall
            for ri in remaining
                sc = groups[ri][4]
                if sc < best_score
                    best_score = sc; best_idx = ri
                end
            end
        end
        push!(order, best_idx)
        union!(available, groups[best_idx][5])
        deleteat!(remaining, findfirst(==(best_idx), remaining))
    end

    # If the chosen order matches the original order, no-op
    order == collect(eachindex(groups)) && return patterns

    new_patterns = SparqlPattern[]
    for oi in order
        s, _, fe, _, _, _ = groups[oi]
        for k in s:fe
            push!(new_patterns, patterns[k])
        end
    end
    for k in i:n
        push!(new_patterns, patterns[k])
    end
    new_patterns
end

# Estimate selectivity of a star group (lower = more selective).
# If any pattern has a bound object, returns size of pos[p][o] for the smallest one.
# Otherwise returns total triples for the smallest predicate's POS (fewer subjects).
function _estimate_star_selectivity(store::MemoryStore, patterns::Vector{SparqlPattern},
                                    s::Int, e::Int)
    best_bound = typemax(Int)
    best_pred = typemax(Int)
    @inbounds for k in s:e
        pat = patterns[k]::PatTriple
        p = pat.predicate::URIRef
        po = get(store.pos, p, nothing)
        po === nothing && return 0  # empty result
        # Predicate cardinality
        psize = 0
        for (_, ss) in po
            psize += length(ss)
        end
        if psize < best_pred
            best_pred = psize
        end
        # Bound object?
        obj = pat.object
        if obj isa Identifier
            subjs = get(po, obj, nothing)
            sz = subjs === nothing ? 0 : length(subjs)
            if sz < best_bound
                best_bound = sz
            end
        end
    end
    # Bound-object selectivity beats any unbound predicate
    return best_bound < typemax(Int) ? best_bound : best_pred
end

# Detect end index of a "star group" starting at `start`.
# A star group is consecutive PatTriple patterns sharing the same subject variable
# with bound URI predicates (no property paths or variables).
function _star_group_end(patterns::Vector{SparqlPattern}, start::Int)
    pat = patterns[start]
    pat isa PatTriple || return start
    subj = pat.subject
    subj isa String || return start
    pat.predicate isa URIRef || return start
    last = start
    for j in (start+1):length(patterns)
        next = patterns[j]
        next isa PatTriple || break
        next.subject isa String || break
        next.subject == subj || break
        next.predicate isa URIRef || break
        last = j
    end
    last
end

# Pattern evaluation with star-join grouping (MemoryStore only)
function _ast_eval_patterns_star(g::RDFGraph, patterns::Vector{SparqlPattern},
                                  bindings::Vector{Dict{String,Identifier}}, limit::Int)
    store = g.store::MemoryStore
    i = 1
    n = length(patterns)
    while i <= n
        star_end = _star_group_end(patterns, i)
        if star_end > i
            # Absorb trailing PatFilter(s) into the star group
            filters = SparqlExpr[]
            j = star_end + 1
            while j <= n && patterns[j] isa PatFilter
                push!(filters, (patterns[j]::PatFilter).expr)
                j += 1
            end
            star_pats = @view patterns[i:star_end]
            is_last = (j > n)
            eff_limit = is_last ? limit : 0
            if isempty(filters)
                bindings = _ast_eval_star_memory(store, star_pats, bindings, eff_limit)
            else
                bindings = _ast_eval_star_filter_memory(g, store, star_pats, filters,
                                                        bindings, eff_limit)
            end
            i = j
        else
            # Single pattern: use normal or limited evaluation
            is_last = (i == n)
            if is_last && limit > 0
                bindings = _ast_eval_pattern_limited(g, patterns[i], bindings, limit)
            else
                bindings = _ast_eval_pattern(g, patterns[i], bindings)
            end
            i += 1
        end
        isempty(bindings) && return bindings
    end
    bindings
end

# Limited pattern evaluation — stop collecting after `limit` results.
# Used for the last pattern when LIMIT is pushed down.
function _ast_eval_pattern_limited(g::RDFGraph, pat::PatTriple, bindings, limit::Int)
    new_bindings = Dict{String,Identifier}[]
    for b in bindings
        matches = _ast_eval_bgp(g, pat, b)
        append!(new_bindings, matches)
        length(new_bindings) >= limit && break
    end
    new_bindings
end

function _ast_eval_pattern_limited(g::RDFGraph, pat::PatOptional, bindings, limit::Int)
    new_bindings = Dict{String,Identifier}[]
    for b in bindings
        opt_bindings = _ast_eval_patterns(g, pat.patterns, Dict{String,Identifier}[copy(b)])
        if isempty(opt_bindings)
            push!(new_bindings, b)
        else
            append!(new_bindings, opt_bindings)
        end
        length(new_bindings) >= limit && break
    end
    new_bindings
end

function _ast_eval_pattern_limited(g::RDFGraph, pat::SparqlPattern, bindings, limit::Int)
    result = _ast_eval_pattern(g, pat, bindings)
    length(result) > limit && resize!(result, limit)
    result
end

# Star-join: evaluate multiple patterns sharing the same subject in a single pass.
# Instead of nested-loop (pattern1 → bindings → pattern2 → bindings → ...),
# iterates subjects once and checks all predicates per subject.
function _ast_eval_star_memory(store::MemoryStore, pats, 
                                bindings::Vector{Dict{String,Identifier}}, limit::Int)
    subj_var = pats[1].subject::String
    n = length(pats)
    pred_uris = URIRef[pats[i].predicate::URIRef for i in 1:n]
    results = Dict{String,Identifier}[]
    obj_sets = Vector{Set{Identifier}}(undef, n)

    # Pre-resolve POS buckets and statically-bound objects
    _ensure_all_indexed!(store)
    pos_buckets = Vector{Dict{Identifier,Set{Identifier}}}(undef, n)
    static_bound_subjects = nothing  # Set{Identifier} or nothing
    @inbounds for i in 1:n
        po = get(store.pos, pred_uris[i], nothing)
        po === nothing && return results
        pos_buckets[i] = po
        obj = pats[i].object
        if obj isa Identifier
            subjs = get(po, obj, nothing)
            subjs === nothing && return results
            if static_bound_subjects === nothing || length(subjs) < length(static_bound_subjects)
                static_bound_subjects = subjs
            end
        end
    end

    for b in bindings
        s_val = get(b, subj_var, nothing)
        if s_val isa Identifier
            _star_check!(results, store.spo, b, s_val, subj_var, pats, pred_uris,
                         obj_sets, n, limit)
        else
            # Find smallest driver from: static-bound objects in patterns,
            # or runtime-bound object vars in `b` (post-reorder joins).
            driver = static_bound_subjects
            @inbounds for i in 1:n
                obj = pats[i].object
                if obj isa String
                    bv = get(b, obj, nothing)
                    if bv isa Identifier
                        subjs = get(pos_buckets[i], bv, nothing)
                        if subjs === nothing
                            driver = nothing  # signal: no match for this binding
                            @goto no_driver
                        end
                        if driver === nothing || length(subjs) < length(driver)
                            driver = subjs
                        end
                    end
                end
            end
            @label no_driver

            if driver isa Set{Identifier}
                for s in driver
                    _star_check!(results, store.spo, b, s, subj_var, pats, pred_uris,
                                 obj_sets, n, limit)
                    limit > 0 && length(results) >= limit && break
                end
            elseif driver === nothing && (
                # Distinguish "no match found" (skip this binding) from
                # "no constraint at all" (fall back to scan).
                any_bound_obj_var(pats, n, b)
            )
                # Some object var was bound but had no matches → skip this binding
            else
                # No bound objects anywhere → iterate all subjects in store
                for (s, _) in store.spo
                    _star_check!(results, store.spo, b, s, subj_var, pats, pred_uris,
                                 obj_sets, n, limit)
                    limit > 0 && length(results) >= limit && break
                end
            end
        end
        limit > 0 && length(results) >= limit && break
    end
    results
end

@inline function any_bound_obj_var(pats, n::Int, b::Dict{String,Identifier})
    @inbounds for i in 1:n
        o = pats[i].object
        if o isa String && haskey(b, o)
            return true
        end
    end
    return false
end

# Check one subject against all star-group predicates, emit matching bindings
@inline function _star_check!(results, spo, b, s, subj_var, pats, pred_uris,
                               obj_sets, n, limit)
    sp = get(spo, s, nothing)
    sp === nothing && return
    # Collect object sets; bail early if any predicate missing
    @inbounds for i in 1:n
        os = get(sp, pred_uris[i], nothing)
        os === nothing && return
        obj_sets[i] = os
    end
    # Fast path: all predicates have single object values (common case)
    all_single = true
    @inbounds for i in 1:n
        length(obj_sets[i]) != 1 && (all_single = false; break)
    end
    if all_single
        # Pre-validate: check bound terms and pre-bound vars match BEFORE allocating.
        # Defer Dict copy until we know the row will be emitted.
        @inbounds for i in 1:n
            obj = first(obj_sets[i])
            pat_obj = pats[i].object
            if pat_obj isa String
                # Variable: check pre-existing binding (in `b`) only
                bv = get(b, pat_obj, nothing)
                bv === nothing || bv == obj || return
            elseif pat_obj isa Identifier
                pat_obj == obj || return
            else
                # Fall back to general resolver for ExprURI/ExprLiteral patterns
                resolved = _ast_resolve_term(pat_obj, b)
                resolved === nothing && return
                resolved == obj || return
            end
        end
        # All checks passed — now allocate and bind
        new_b = copy(b)
        haskey(new_b, subj_var) || (new_b[subj_var] = s)
        @inbounds for i in 1:n
            obj = first(obj_sets[i])
            pat_obj = pats[i].object
            if pat_obj isa String
                # Bind if not already bound (pre-validated to match if it was)
                haskey(new_b, pat_obj) || (new_b[pat_obj] = obj)
            end
        end
        push!(results, new_b)
    else
        # Multi-valued predicates: cross-product (rare)
        new_b = copy(b)
        haskey(new_b, subj_var) || (new_b[subj_var] = s)
        _star_cross!(results, new_b, obj_sets, pats, 1, n, limit)
    end
end

# Recursive cross-product for multi-valued star predicates.
# Mutates `b` in-place (add/remove vars) to avoid intermediate copies.
function _star_cross!(results, b, obj_sets, pats, idx, n, limit)
    if idx > n
        push!(results, copy(b))
        return
    end
    pat_obj = pats[idx].object
    for obj in obj_sets[idx]
        if pat_obj isa String
            existing = get(b, pat_obj, nothing)
            if existing !== nothing
                existing == obj || continue
                _star_cross!(results, b, obj_sets, pats, idx + 1, n, limit)
            else
                b[pat_obj] = obj
                _star_cross!(results, b, obj_sets, pats, idx + 1, n, limit)
                delete!(b, pat_obj)
            end
        else
            # Bound term (URIRef/Literal/BNode) — check equality
            resolved = pat_obj isa URIRef ? pat_obj : (pat_obj isa Literal ? pat_obj : 
                       (pat_obj isa BNode ? pat_obj : nothing))
            (resolved !== nothing && resolved == obj) || continue
            _star_cross!(results, b, obj_sets, pats, idx + 1, n, limit)
        end
        limit > 0 && length(results) >= limit && return
    end
end

# Star-join with integrated FILTER evaluation.
# Applies filter(s) to each candidate binding BEFORE emitting,
# avoiding materialization of filtered-out results.
function _ast_eval_star_filter_memory(g::RDFGraph, store::MemoryStore, pats,
                                      filters::Vector{SparqlExpr},
                                      bindings::Vector{Dict{String,Identifier}}, limit::Int)
    subj_var = pats[1].subject::String
    n = length(pats)
    pred_uris = URIRef[pats[i].predicate::URIRef for i in 1:n]
    results = Dict{String,Identifier}[]
    obj_sets = Vector{Set{Identifier}}(undef, n)

    for b in bindings
        s_val = get(b, subj_var, nothing)
        if s_val isa Identifier
            _star_filter_check!(results, g, store.spo, b, s_val, subj_var, pats,
                                pred_uris, obj_sets, n, filters, limit)
        else
            for (s, _) in store.spo
                _star_filter_check!(results, g, store.spo, b, s, subj_var, pats,
                                    pred_uris, obj_sets, n, filters, limit)
                limit > 0 && length(results) >= limit && break
            end
        end
        limit > 0 && length(results) >= limit && break
    end
    results
end

@inline function _star_filter_check!(results, g, spo, b, s, subj_var, pats, pred_uris,
                                      obj_sets, n, filters, limit)
    sp = get(spo, s, nothing)
    sp === nothing && return
    @inbounds for i in 1:n
        os = get(sp, pred_uris[i], nothing)
        os === nothing && return
        obj_sets[i] = os
    end
    # Fast path: all single-valued
    all_single = true
    @inbounds for i in 1:n
        length(obj_sets[i]) != 1 && (all_single = false; break)
    end
    if all_single
        new_b = copy(b)
        haskey(new_b, subj_var) || (new_b[subj_var] = s)
        @inbounds for i in 1:n
            obj = first(obj_sets[i])
            pat_obj = pats[i].object
            resolved = pat_obj isa String ? nothing : _ast_resolve_term(pat_obj, new_b)
            _ast_match_term(obj, pat_obj, resolved, new_b) || return
        end
        # Apply all filters before emitting
        for f in filters
            _ast_eval_expr_bool(f, new_b, g) || return
        end
        push!(results, new_b)
    else
        # Multi-valued with filter: generate candidates, filter each
        new_b = copy(b)
        haskey(new_b, subj_var) || (new_b[subj_var] = s)
        _star_cross_filter!(results, g, new_b, obj_sets, pats, filters, 1, n, limit)
    end
end

function _star_cross_filter!(results, g, b, obj_sets, pats, filters, idx, n, limit)
    if idx > n
        for f in filters
            _ast_eval_expr_bool(f, b, g) || return
        end
        push!(results, copy(b))
        return
    end
    pat_obj = pats[idx].object
    for obj in obj_sets[idx]
        if pat_obj isa String
            existing = get(b, pat_obj, nothing)
            if existing !== nothing
                existing == obj || continue
                _star_cross_filter!(results, g, b, obj_sets, pats, filters, idx + 1, n, limit)
            else
                b[pat_obj] = obj
                _star_cross_filter!(results, g, b, obj_sets, pats, filters, idx + 1, n, limit)
                delete!(b, pat_obj)
            end
        else
            resolved = pat_obj isa URIRef ? pat_obj : (pat_obj isa Literal ? pat_obj :
                       (pat_obj isa BNode ? pat_obj : nothing))
            (resolved !== nothing && resolved == obj) || continue
            _star_cross_filter!(results, g, b, obj_sets, pats, filters, idx + 1, n, limit)
        end
        limit > 0 && length(results) >= limit && return
    end
end

function _ast_eval_pattern(g::RDFGraph, pat::PatTriple, bindings)
    new_bindings = Dict{String,Identifier}[]
    for b in bindings
        matches = _ast_eval_bgp(g, pat, b)
        append!(new_bindings, matches)
    end
    new_bindings
end

function _ast_eval_pattern(g::RDFGraph, pat::PatFilter, bindings)
    filter(b -> _ast_eval_expr_bool(pat.expr, b, g), bindings)
end

function _ast_eval_pattern(g::RDFGraph, pat::PatBind, bindings)
    for b in bindings
        val = _ast_eval_expr(pat.expr, b, g)
        !isnothing(val) && (b[pat.var] = val)
    end
    bindings
end

function _ast_eval_pattern(g::RDFGraph, pat::PatOptional, bindings)
    isempty(bindings) && return bindings

    # Hash-join optimization: evaluate OPTIONAL patterns standalone and
    # left-join by shared variables. Avoids O(n*m) re-evaluation.
    # Falls back to nested loop if patterns reference outer-only variables.
    if _opt_safe_for_hashjoin(pat.patterns, bindings)
        # Bound-join optimization: when outer bindings share variables produced
        # inside the OPTIONAL, push them as constraints (evaluate inner WITH the
        # outer bindings). This lets the star-join's runtime POS pivot use the
        # bound vars directly, avoiding a full standalone scan + hash join.
        # We then add back outer rows that had no match (LEFT JOIN semantics).
        shared = _opt_shared_vars(pat.patterns, bindings)
        if !isempty(shared) && length(shared) <= 2
            return _opt_bound_join(g, pat.patterns, bindings, shared)
        end
        opt_results = _ast_eval_patterns(g, pat.patterns)
        return _ast_left_join(bindings, opt_results)
    end

    # Fallback: nested loop (semantically equivalent, slower)
    new_bindings = Dict{String,Identifier}[]
    for b in bindings
        opt_bindings = _ast_eval_patterns(g, pat.patterns, Dict{String,Identifier}[copy(b)])
        if isempty(opt_bindings)
            push!(new_bindings, b)
        else
            append!(new_bindings, opt_bindings)
        end
    end
    new_bindings
end

# Variables shared between outer bindings and inner OPTIONAL patterns
function _opt_shared_vars(patterns::Vector{SparqlPattern}, bindings)
    inner_vars = Set{String}()
    for p in patterns
        _collect_produced_vars!(inner_vars, p)
    end
    outer_vars = Set{String}()
    for b in bindings, k in keys(b); push!(outer_vars, k); end
    sort!(collect(intersect(inner_vars, outer_vars)))
end

# Bound-join: evaluate inner with outer bindings as constraints, then add
# unmatched outer rows back (LEFT JOIN semantics).
function _opt_bound_join(g::RDFGraph, patterns::Vector{SparqlPattern},
                          outer::Vector{Dict{String,Identifier}},
                          shared::Vector{String})
    matched = _ast_eval_patterns(g, patterns, [copy(b) for b in outer])

    # Build a set of (shared-var-tuple) values that appear in matched.
    # For length-1 shared, use Set{Identifier}; otherwise Set{Tuple}.
    if length(shared) == 1
        sv = shared[1]
        seen = Set{Identifier}()
        sizehint!(seen, length(matched))
        @inbounds for m in matched
            v = get(m, sv, nothing)
            v === nothing || push!(seen, v)
        end
        # Unmatched outer rows: those whose shared-var value is not in `seen`.
        @inbounds for b in outer
            v = get(b, sv, nothing)
            (v === nothing || !(v in seen)) && push!(matched, b)
        end
    else
        seen = Set{Tuple}()
        sizehint!(seen, length(matched))
        @inbounds for m in matched
            ok = true
            vals = Vector{Identifier}(undef, length(shared))
            for (i, k) in enumerate(shared)
                v = get(m, k, nothing)
                v === nothing && (ok = false; break)
                vals[i] = v
            end
            ok && push!(seen, Tuple(vals))
        end
        @inbounds for b in outer
            ok = true
            vals = Vector{Identifier}(undef, length(shared))
            for (i, k) in enumerate(shared)
                v = get(b, k, nothing)
                v === nothing && (ok = false; break)
                vals[i] = v
            end
            (!ok || !(Tuple(vals) in seen)) && push!(matched, b)
        end
    end
    matched
end

# True iff the OPTIONAL pattern block can be evaluated standalone without
# needing variables from the outer scope. Concretely: every variable referenced
# in any FILTER/BIND expression must be bound by some triple/values pattern
# inside the block itself (not exclusively in the outer scope).
function _opt_safe_for_hashjoin(patterns::Vector{SparqlPattern}, outer_bindings)
    inner_produced = Set{String}()
    for p in patterns
        _collect_produced_vars!(inner_produced, p)
    end
    for p in patterns
        refs = String[]
        _collect_expr_vars!(refs, p)
        for v in refs
            v in inner_produced && continue
            # Referenced var not produced inside OPTIONAL → outer-scoped → unsafe
            return false
        end
    end
    true
end

function _collect_produced_vars!(out::Set{String}, p::SparqlPattern)
    if p isa PatTriple
        p.subject isa String && push!(out, p.subject)
        p.predicate isa String && push!(out, p.predicate)
        p.object isa String && push!(out, p.object)
    elseif p isa PatBind
        push!(out, p.var)
    elseif p isa PatValues
        for v in p.variables; push!(out, v); end
    elseif p isa PatOptional
        for q in p.patterns; _collect_produced_vars!(out, q); end
    elseif p isa PatUnion
        for branch in p.branches, q in branch; _collect_produced_vars!(out, q); end
    elseif p isa PatGraph
        for q in p.patterns; _collect_produced_vars!(out, q); end
        p.graph_term isa ExprVar && push!(out, p.graph_term.name)
    elseif p isa PatSubquery
        for v in _ast_projection_vars(p.query); push!(out, v); end
    end
end

function _collect_expr_vars!(out::Vector{String}, p::SparqlPattern)
    if p isa PatFilter
        _collect_vars_in_expr!(out, p.expr)
    elseif p isa PatBind
        _collect_vars_in_expr!(out, p.expr)
    elseif p isa PatOptional
        for q in p.patterns; _collect_expr_vars!(out, q); end
    elseif p isa PatUnion
        for branch in p.branches, q in branch; _collect_expr_vars!(out, q); end
    elseif p isa PatGraph
        for q in p.patterns; _collect_expr_vars!(out, q); end
    elseif p isa PatFilterExists
        # FILTER EXISTS sub-patterns; treat as expr-bearing
        for q in p.patterns; _collect_expr_vars!(out, q); end
    end
end

function _collect_vars_in_expr!(out::Vector{String}, e)
    if e isa ExprVar
        push!(out, e.name)
    elseif e isa ExprBinaryOp
        _collect_vars_in_expr!(out, e.left)
        _collect_vars_in_expr!(out, e.right)
    elseif e isa ExprUnaryOp
        _collect_vars_in_expr!(out, e.operand)
    elseif e isa ExprFunctionCall
        for a in e.args; _collect_vars_in_expr!(out, a); end
    elseif e isa ExprIn
        _collect_vars_in_expr!(out, e.expr)
        for a in e.values; _collect_vars_in_expr!(out, a); end
    elseif e isa ExprAggregate
        _collect_vars_in_expr!(out, e.expr)
    end
end

# Hash-join: left-join `lhs` with `rhs` on shared variables.
# Each LHS row produces one output for every compatible RHS row (merged),
# or itself if no RHS row matches (OPTIONAL semantics).
function _ast_left_join(lhs::Vector{Dict{String,Identifier}},
                        rhs::Vector{Dict{String,Identifier}})
    isempty(rhs) && return lhs
    isempty(lhs) && return lhs

    # Find shared variable keys (intersection of all-RHS-vars with LHS vars).
    rhs_vars = Set{String}()
    for r in rhs, k in keys(r); push!(rhs_vars, k); end
    lhs_vars = Set{String}()
    for l in lhs, k in keys(l); push!(lhs_vars, k); end
    shared = sort!(collect(intersect(lhs_vars, rhs_vars)))

    if isempty(shared)
        # Cartesian: every LHS combined with every RHS (rare, but valid).
        out = Dict{String,Identifier}[]
        sizehint!(out, length(lhs) * length(rhs))
        for l in lhs, r in rhs
            push!(out, merge(l, r))
        end
        return out
    end

    # Specialised path: single shared variable — keys are Identifiers directly,
    # avoiding Tuple/Vector allocations per row (huge win for 100K+ rows).
    if length(shared) == 1
        return _ast_left_join_single(lhs, rhs, shared[1])
    end

    # Build hash on RHS keyed by shared var values.
    Index = Dict{Tuple,Vector{Dict{String,Identifier}}}
    idx = Index()
    nshared = length(shared)
    for r in rhs
        ok = true
        key_vals = Vector{Identifier}(undef, nshared)
        for (i, v) in enumerate(shared)
            haskey(r, v) || (ok = false; break)
            key_vals[i] = r[v]
        end
        ok || continue
        key = Tuple(key_vals)
        push!(get!(() -> Dict{String,Identifier}[], idx, key), r)
    end

    out = Dict{String,Identifier}[]
    sizehint!(out, length(lhs))
    for l in lhs
        ok = true
        key_vals = Vector{Identifier}(undef, nshared)
        for (i, v) in enumerate(shared)
            haskey(l, v) || (ok = false; break)
            key_vals[i] = l[v]
        end
        if ok
            key = Tuple(key_vals)
            matches = get(idx, key, nothing)
            if matches !== nothing
                for m in matches
                    push!(out, merge(l, m))
                end
                continue
            end
        end
        push!(out, l)
    end
    out
end

# Single-shared-variable specialization: avoids per-row Tuple/Vector allocations
function _ast_left_join_single(lhs::Vector{Dict{String,Identifier}},
                                rhs::Vector{Dict{String,Identifier}},
                                key_var::String)
    idx = Dict{Identifier,Vector{Dict{String,Identifier}}}()
    sizehint!(idx, length(rhs) ÷ 4 + 8)
    @inbounds for r in rhs
        v = get(r, key_var, nothing)
        v === nothing && continue
        push!(get!(() -> Dict{String,Identifier}[], idx, v), r)
    end
    out = Dict{String,Identifier}[]
    sizehint!(out, length(lhs))
    @inbounds for l in lhs
        v = get(l, key_var, nothing)
        if v !== nothing
            matches = get(idx, v, nothing)
            if matches !== nothing
                for m in matches
                    push!(out, merge(l, m))
                end
                continue
            end
        end
        push!(out, l)
    end
    out
end

function _ast_eval_pattern(g::RDFGraph, pat::PatUnion, bindings)
    new_bindings = Dict{String,Identifier}[]
    for b in bindings
        for branch in pat.branches
            branch_result = _ast_eval_patterns(g, branch, Dict{String,Identifier}[copy(b)])
            append!(new_bindings, branch_result)
        end
    end
    new_bindings
end

function _ast_eval_pattern(g::RDFGraph, pat::PatMinus, bindings)
    inner = _ast_eval_patterns(g, pat.patterns)
    filter(b -> !any(ib -> _ast_compatible_shared(b, ib), inner), bindings)
end

function _ast_eval_pattern(g::RDFGraph, pat::PatFilterExists, bindings)
    filter(bindings) do b
        inner = _ast_eval_patterns(g, pat.patterns, Dict{String,Identifier}[copy(b)])
        has = !isempty(inner)
        pat.negated ? !has : has
    end
end

function _ast_eval_pattern(g::RDFGraph, pat::PatValues, bindings)
    new_bindings = Dict{String,Identifier}[]
    for b in bindings
        for row in pat.rows
            new_b = copy(b)
            ok = true
            for (i, var) in enumerate(pat.variables)
                i > length(row) && (ok = false; break)
                val = row[i]
                isnothing(val) && continue
                if haskey(new_b, var) && new_b[var] != val
                    ok = false; break
                end
                new_b[var] = val
            end
            ok && push!(new_bindings, new_b)
        end
    end
    new_bindings
end

function _ast_eval_pattern(g::RDFGraph, pat::PatSubquery, bindings)
    sub_results = _ast_evaluate(g, pat.query)
    new_bindings = Dict{String,Identifier}[]
    for b in bindings
        for sr in sub_results
            _ast_compatible(b, sr) && push!(new_bindings, merge(b, sr))
        end
    end
    new_bindings
end

function _ast_eval_pattern(g::RDFGraph, pat::PatGraph, bindings)
    _ast_eval_patterns(g, pat.patterns, bindings)
end

function _ast_eval_pattern(g::RDFGraph, pat::PatService, bindings)
    endpoint_uri = if pat.endpoint isa ExprURI || pat.endpoint isa URIRef
        uri = pat.endpoint isa ExprURI ? pat.endpoint.uri : pat.endpoint
        uri.value
    elseif pat.endpoint isa ExprVar && !isempty(bindings)
        val = get(first(bindings), pat.endpoint.name, nothing)
        val isa URIRef ? val.value : nothing
    else
        nothing
    end
    isnothing(endpoint_uri) && return bindings

    try
        store = SPARQLStore(endpoint_uri)
        remote_query = _ast_build_service_query(pat.patterns)
        cached = _service_cache_lookup(endpoint_uri, remote_query)
        remote_results = if !isnothing(cached)
            cached
        else
            res = _remote_select(store, remote_query)
            _service_cache_store!(endpoint_uri, remote_query, res)
            res
        end
        new_bindings = Dict{String,Identifier}[]
        for b in bindings
            for rr in remote_results
                compatible = all(k -> !haskey(rr, k) || rr[k] == v for (k, v) in b)
                compatible && push!(new_bindings, merge(b, rr))
            end
        end
        isempty(new_bindings) ? bindings : new_bindings
    catch e
        pat.silent && return bindings
        rethrow(e)
    end
end

function _ast_eval_pattern(g::RDFGraph, pat::PatLateral, bindings)
    new_bindings = Dict{String,Identifier}[]
    for b in bindings
        lateral = _ast_eval_patterns(g, pat.patterns, Dict{String,Identifier}[copy(b)])
        append!(new_bindings, lateral)
    end
    new_bindings  # Inner join: only keep rows where lateral produced results
end

function _ast_eval_pattern(g::RDFGraph, pat::PatTripleTerm, bindings)
    # RDF-star triple term: << s p o >>
    _ast_eval_pattern(g, PatTriple(pat.subject, pat.predicate, pat.object), bindings)
end

# ─── BGP evaluation ───────────────────────────────────────────────

function _ast_eval_bgp(g::RDFGraph, pat::PatTriple, binding::Dict{String,Identifier})
    s_val = _ast_resolve_term(pat.subject, binding)
    p_val = pat.predicate
    o_val = _ast_resolve_term(pat.object, binding)

    # Property path predicate
    if p_val isa PathExpr
        return _ast_eval_path_bgp(g, s_val, p_val, o_val, pat, binding)
    end

    p_val = _ast_resolve_term(p_val, binding)

    # Fast path: direct index access for MemoryStore
    if g.store isa MemoryStore
        return _ast_eval_bgp_memory(g.store, pat, binding, s_val, p_val, o_val)
    end

    # Generic path: use indexed triples() for other stores
    s_pattern = s_val isa Identifier ? s_val : nothing
    p_pattern = p_val isa Identifier ? p_val : nothing
    o_pattern = o_val isa Identifier ? o_val : nothing

    results = Dict{String,Identifier}[]
    for t in triples(g, (s_pattern, p_pattern, o_pattern))
        new_b = copy(binding)
        ok = true
        ok = ok && _ast_match_term(t.subject, pat.subject, s_val, new_b)
        ok = ok && _ast_match_term(t.predicate, pat.predicate, p_val, new_b)
        ok = ok && _ast_match_term(t.object, pat.object, o_val, new_b)
        ok && push!(results, new_b)
    end
    results
end

# Direct MemoryStore index access — avoids Channel overhead
function _ast_eval_bgp_memory(store::MemoryStore, pat::PatTriple,
                               binding::Dict{String,Identifier},
                               s_val, p_val, o_val)
    results = Dict{String,Identifier}[]
    s_bound = s_val isa Identifier
    p_bound = p_val isa Identifier
    o_bound = o_val isa Identifier

    if s_bound && p_bound && o_bound
        # Fully bound — existence check
        if haskey(store.spo, s_val) && haskey(store.spo[s_val], p_val) && o_val in store.spo[s_val][p_val]
            push!(results, copy(binding))
        end
    elseif s_bound && p_bound
        # S P ? — iterate objects from index
        sp = get(store.spo, s_val, nothing)
        if !isnothing(sp)
            objs = get(sp, p_val, nothing)
            if !isnothing(objs)
                for o in objs
                    new_b = copy(binding)
                    _ast_match_term(o, pat.object, o_val, new_b) && push!(results, new_b)
                end
            end
        end
    elseif s_bound && o_bound
        # S ? O — iterate predicates from OSP
        os = get(store.osp, o_val, nothing)
        if !isnothing(os)
            preds = get(os, s_val, nothing)
            if !isnothing(preds)
                for p in preds
                    new_b = copy(binding)
                    _ast_match_term(p, pat.predicate, p_val, new_b) && push!(results, new_b)
                end
            end
        end
    elseif p_bound && o_bound
        # ? P O — iterate subjects from POS
        po = get(store.pos, p_val, nothing)
        if !isnothing(po)
            subjs = get(po, o_val, nothing)
            if !isnothing(subjs)
                for s in subjs
                    new_b = copy(binding)
                    _ast_match_term(s, pat.subject, s_val, new_b) && push!(results, new_b)
                end
            end
        end
    elseif s_bound
        # S ? ? — iterate predicate-object pairs from SPO
        sp = get(store.spo, s_val, nothing)
        if !isnothing(sp)
            for (p, objs) in sp
                for o in objs
                    new_b = copy(binding)
                    ok = _ast_match_term(p, pat.predicate, p_val, new_b)
                    ok && (ok = _ast_match_term(o, pat.object, o_val, new_b))
                    ok && push!(results, new_b)
                end
            end
        end
    elseif p_bound
        # ? P ? — iterate object-subject pairs from POS
        po = get(store.pos, p_val, nothing)
        if !isnothing(po)
            for (o, subjs) in po
                for s in subjs
                    new_b = copy(binding)
                    ok = _ast_match_term(s, pat.subject, s_val, new_b)
                    ok && (ok = _ast_match_term(o, pat.object, o_val, new_b))
                    ok && push!(results, new_b)
                end
            end
        end
    elseif o_bound
        # ? ? O — iterate subject-predicate pairs from OSP
        os = get(store.osp, o_val, nothing)
        if !isnothing(os)
            for (s, preds) in os
                for p in preds
                    new_b = copy(binding)
                    ok = _ast_match_term(s, pat.subject, s_val, new_b)
                    ok && (ok = _ast_match_term(p, pat.predicate, p_val, new_b))
                    ok && push!(results, new_b)
                end
            end
        end
    else
        # ? ? ? — iterate all triples
        for t in store.insertion_order
            new_b = copy(binding)
            ok = _ast_match_term(t.subject, pat.subject, s_val, new_b)
            ok && (ok = _ast_match_term(t.predicate, pat.predicate, p_val, new_b))
            ok && (ok = _ast_match_term(t.object, pat.object, o_val, new_b))
            ok && push!(results, new_b)
        end
    end
    results
end

function _ast_match_term(graph_val::Identifier, pattern, resolved, binding::Dict{String,Identifier})
    if pattern isa String  # variable name
        if haskey(binding, pattern)
            return binding[pattern] == graph_val
        else
            binding[pattern] = graph_val
            return true
        end
    else
        return !isnothing(resolved) && resolved == graph_val
    end
end

function _ast_resolve_term(term, binding::Dict{String,Identifier})
    if term isa String  # variable
        return get(binding, term, nothing)
    end
    if term isa URIRef || term isa Literal || term isa BNode
        return term
    end
    if term isa ExprVar
        return get(binding, term.name, nothing)
    end
    if term isa ExprURI
        return term.uri
    end
    if term isa ExprLiteral
        return term.value
    end
    nothing
end

# ─── Property path evaluation ─────────────────────────────────────

function _ast_eval_path_bgp(g::RDFGraph, s_val, path::PathExpr, o_val, pat::PatTriple, binding)
    s_var = pat.subject isa String ? pat.subject : nothing
    o_var = pat.object isa String ? pat.object : nothing

    pairs = _ast_eval_path(g, path, s_val isa Node ? s_val : nothing,
                            o_val isa Identifier ? o_val : nothing)
    results = Dict{String,Identifier}[]
    for (s, o) in pairs
        new_b = copy(binding)
        if !isnothing(s_var)
            if haskey(new_b, s_var) && new_b[s_var] != s
                continue
            end
            new_b[s_var] = s
        elseif !isnothing(s_val) && s != s_val
            continue
        end
        if !isnothing(o_var)
            if haskey(new_b, o_var) && new_b[o_var] != o
                continue
            end
            new_b[o_var] = o
        elseif !isnothing(o_val) && o != o_val
            continue
        end
        push!(results, new_b)
    end
    results
end

function _ast_eval_path(g::RDFGraph, path::PathURI, start::Union{Node,Nothing}, target::Union{Identifier,Nothing})
    results = Tuple{Node, Identifier}[]
    for t in triples(g)
        t.predicate == path.uri || continue
        (!isnothing(start) && t.subject != start) && continue
        (!isnothing(target) && t.object != target) && continue
        push!(results, (t.subject, t.object))
    end
    results
end

function _ast_eval_path(g::RDFGraph, path::PathSequence, start::Union{Node,Nothing}, target::Union{Identifier,Nothing})
    isempty(path.steps) && return Tuple{Node,Identifier}[]
    if length(path.steps) == 1
        return _ast_eval_path(g, path.steps[1], start, target)
    end
    # Evaluate first step, then chain
    current = _ast_eval_path(g, path.steps[1], start, nothing)
    for i in 2:length(path.steps)
        next = Tuple{Node,Identifier}[]
        is_last = i == length(path.steps)
        for (_, mid) in current
            mid isa Node || continue
            step_results = _ast_eval_path(g, path.steps[i], mid, is_last ? target : nothing)
            for (_, o) in step_results
                push!(next, (mid, o))
            end
        end
        # Preserve original start
        if !isempty(next)
            final = Tuple{Node,Identifier}[]
            for (s, _) in current
                for (_, o) in next
                    push!(final, (s, o))
                end
            end
            current = final
        else
            current = next
        end
    end
    # Fix: chain must map (original_start → final_target)
    # Re-evaluate properly
    _ast_eval_path_chain(g, path.steps, start, target)
end

function _ast_eval_path_chain(g::RDFGraph, steps::Vector{PathExpr}, start, target)
    if length(steps) == 1
        return _ast_eval_path(g, steps[1], start, target)
    end
    first_results = _ast_eval_path(g, steps[1], start, nothing)
    results = Tuple{Node,Identifier}[]
    for (s, mid) in first_results
        mid isa Node || continue
        rest = _ast_eval_path_chain(g, steps[2:end], mid, target)
        for (_, o) in rest
            push!(results, (s, o))
        end
    end
    results
end

function _ast_eval_path(g::RDFGraph, path::PathAlternative, start::Union{Node,Nothing}, target::Union{Identifier,Nothing})
    results = Tuple{Node,Identifier}[]
    for option in path.options
        append!(results, _ast_eval_path(g, option, start, target))
    end
    unique(results)
end

function _ast_eval_path(g::RDFGraph, path::PathInverse, start::Union{Node,Nothing}, target::Union{Identifier,Nothing})
    # Swap start and target
    inner = _ast_eval_path(g, path.path, target isa Node ? target : nothing, start)
    [(o isa Node ? o : first(t for t in triples(g) if true).subject, s) for (s, o) in inner if o isa Node]
    # Simplified: reverse the pairs
    results = Tuple{Node,Identifier}[]
    for (s, o) in inner
        o isa Node && push!(results, (o, s))
    end
    results
end

function _ast_eval_path(g::RDFGraph, path::PathZeroOrMore, start::Union{Node,Nothing}, target::Union{Identifier,Nothing})
    _ast_eval_path_closure(g, path.path, start, target, include_zero=true)
end

function _ast_eval_path(g::RDFGraph, path::PathOneOrMore, start::Union{Node,Nothing}, target::Union{Identifier,Nothing})
    _ast_eval_path_closure(g, path.path, start, target, include_zero=false)
end

function _ast_eval_path(g::RDFGraph, path::PathZeroOrOne, start::Union{Node,Nothing}, target::Union{Identifier,Nothing})
    results = _ast_eval_path(g, path.path, start, target)
    # Add zero-length (identity) matches
    if !isnothing(start)
        if isnothing(target) || target == start
            push!(results, (start, start))
        end
    else
        for t in triples(g)
            push!(results, (t.subject, t.subject))
            t.object isa Node && push!(results, (t.object, t.object))
        end
    end
    unique(results)
end

function _ast_eval_path_closure(g::RDFGraph, path::PathExpr, start::Union{Node,Nothing},
                                 target::Union{Identifier,Nothing}; include_zero::Bool=false)
    results = Tuple{Node,Identifier}[]
    if !isnothing(start)
        # BFS from start
        visited = Set{Identifier}()  # empty — allow finding start via cycles
        queue = Identifier[start]
        include_zero && push!(results, (start, start))
        while !isempty(queue)
            current = popfirst!(queue)
            current in visited && continue
            push!(visited, current)
            current isa Node || continue
            for (_, next) in _ast_eval_path(g, path, current, nothing)
                if isnothing(target) || next == target
                    push!(results, (start, next))
                end
                if !(next in visited)
                    push!(queue, next)
                end
            end
        end
    else
        # All nodes as starting points
        all_nodes = Set{Node}()
        for t in triples(g)
            push!(all_nodes, t.subject)
            t.object isa Node && push!(all_nodes, t.object)
        end
        for node in all_nodes
            append!(results, _ast_eval_path_closure(g, path, node, target, include_zero=include_zero))
        end
    end
    unique(results)
end

function _ast_eval_path(g::RDFGraph, path::PathNegatedSet, start::Union{Node,Nothing}, target::Union{Identifier,Nothing})
    excluded = Set(path.uris)
    results = Tuple{Node,Identifier}[]
    for t in triples(g)
        t.predicate in excluded && continue
        (!isnothing(start) && t.subject != start) && continue
        (!isnothing(target) && t.object != target) && continue
        push!(results, (t.subject, t.object))
    end
    results
end

# ─── Expression evaluation ────────────────────────────────────────
# Returns Identifier (Literal, URIRef, BNode) or nothing

function _ast_eval_expr(expr::ExprVar, binding::Dict{String,Identifier}, g::RDFGraph=RDFGraph())
    get(binding, expr.name, nothing)
end

function _ast_eval_expr(expr::ExprLiteral, binding::Dict{String,Identifier}, g::RDFGraph=RDFGraph())
    expr.value
end

function _ast_eval_expr(expr::ExprURI, binding::Dict{String,Identifier}, g::RDFGraph=RDFGraph())
    expr.uri
end

function _ast_eval_expr(expr::ExprBNode, binding::Dict{String,Identifier}, g::RDFGraph=RDFGraph())
    expr.node
end

function _ast_eval_expr(expr::ExprBool, binding::Dict{String,Identifier}, g::RDFGraph=RDFGraph())
    Literal(expr.value)
end

function _ast_eval_expr(expr::ExprStar, binding::Dict{String,Identifier}, g::RDFGraph=RDFGraph())
    nothing  # Star is only meaningful in aggregates
end

function _ast_eval_expr(expr::ExprBinaryOp, binding::Dict{String,Identifier}, g::RDFGraph=RDFGraph())
    left = _ast_eval_expr(expr.left, binding, g)
    right = _ast_eval_expr(expr.right, binding, g)

    if expr.op == :||
        return Literal(_ast_to_bool(left) || _ast_to_bool(right))
    elseif expr.op == :&&
        return Literal(_ast_to_bool(left) && _ast_to_bool(right))
    end

    (isnothing(left) || isnothing(right)) && return nothing

    if expr.op in (:(==), :!=, :<, :>, :<=, :>=)
        return _ast_eval_comparison(expr.op, left, right)
    end

    if expr.op in (:+, :-, :*, :/)
        return _ast_eval_arithmetic(expr.op, left, right)
    end

    nothing
end

function _ast_eval_expr(expr::ExprUnaryOp, binding::Dict{String,Identifier}, g::RDFGraph=RDFGraph())
    val = _ast_eval_expr(expr.arg, binding, g)
    if expr.op == :!
        return Literal(!_ast_to_bool(val))
    elseif expr.op == :-
        n = _ast_to_numeric(val)
        !isnothing(n) && return Literal(-n)
    elseif expr.op == :+
        return val
    end
    nothing
end

function _ast_eval_expr(expr::ExprIn, binding::Dict{String,Identifier}, g::RDFGraph=RDFGraph())
    val = _ast_eval_expr(expr.expr, binding, g)
    isnothing(val) && return Literal(expr.negated)
    found = any(expr.values) do v
        ev = _ast_eval_expr(v, binding, g)
        !isnothing(ev) && _ast_values_equal(val, ev)
    end
    Literal(expr.negated ? !found : found)
end

function _ast_eval_expr(expr::ExprExists, binding::Dict{String,Identifier}, g::RDFGraph=RDFGraph())
    inner = _ast_eval_patterns(g, Vector{SparqlPattern}(expr.patterns), Dict{String,Identifier}[copy(binding)])
    has = !isempty(inner)
    Literal(expr.negated ? !has : has)
end

function _ast_eval_expr(expr::ExprAggregate, binding::Dict{String,Identifier}, g::RDFGraph=RDFGraph())
    # Aggregates are evaluated separately in group/aggregate handling, not inline.
    # However, during HAVING evaluation we stash computed aggregate values in the binding
    # keyed as "__agg_<hash>__". Check for that first.
    akey = "__agg_$(hash(expr))__"
    haskey(binding, akey) && return binding[akey]
    nothing
end

# ─── Function call evaluation ─────────────────────────────────────

function _ast_eval_expr(expr::ExprFunctionCall, binding::Dict{String,Identifier}, g::RDFGraph=RDFGraph())
    name = expr.name
    args = expr.args

    # Evaluate all args lazily for short-circuit functions
    _eval_arg(i) = i <= length(args) ? _ast_eval_expr(args[i], binding, g) : nothing

    # ── String functions ──
    if name == "STR"
        val = _eval_arg(1)
        return isnothing(val) ? nothing : Literal(val isa URIRef ? val.value : val isa Literal ? val.lexical : string(val))
    elseif name == "STRLEN"
        val = _eval_arg(1)
        return isnothing(val) ? nothing : Literal(length(val isa Literal ? val.lexical : string(val)))
    elseif name == "UCASE"
        val = _eval_arg(1)
        return _ast_str_op(val, uppercase)
    elseif name == "LCASE"
        val = _eval_arg(1)
        return _ast_str_op(val, lowercase)
    elseif name == "CONCAT"
        parts = [let v = _eval_arg(i); isnothing(v) ? "" : v isa Literal ? v.lexical : string(v) end for i in 1:length(args)]
        return Literal(join(parts))
    elseif name == "CONTAINS"
        s = _eval_arg(1); p = _eval_arg(2)
        (isnothing(s) || isnothing(p)) && return nothing
        return Literal(occursin(_ast_str(p), _ast_str(s)))
    elseif name == "STRSTARTS"
        s = _eval_arg(1); p = _eval_arg(2)
        (isnothing(s) || isnothing(p)) && return nothing
        return Literal(startswith(_ast_str(s), _ast_str(p)))
    elseif name == "STRENDS"
        s = _eval_arg(1); p = _eval_arg(2)
        (isnothing(s) || isnothing(p)) && return nothing
        return Literal(endswith(_ast_str(s), _ast_str(p)))
    elseif name == "STRBEFORE"
        s = _eval_arg(1); p = _eval_arg(2)
        (isnothing(s) || isnothing(p)) && return nothing
        ss = _ast_str(s); pp = _ast_str(p)
        idx = findfirst(pp, ss)
        return Literal(isnothing(idx) ? "" : ss[1:first(idx)-1])
    elseif name == "STRAFTER"
        s = _eval_arg(1); p = _eval_arg(2)
        (isnothing(s) || isnothing(p)) && return nothing
        ss = _ast_str(s); pp = _ast_str(p)
        idx = findfirst(pp, ss)
        return Literal(isnothing(idx) ? "" : ss[last(idx)+1:end])
    elseif name == "SUBSTR"
        val = _eval_arg(1)
        isnothing(val) && return nothing
        s = _ast_str(val)
        start_v = _eval_arg(2)
        isnothing(start_v) && return nothing
        si = _ast_to_int(start_v)
        isnothing(si) && return nothing
        if length(args) >= 3
            len_v = _eval_arg(3)
            len = _ast_to_int(len_v)
            !isnothing(len) && return Literal(s[si:min(si+len-1, lastindex(s))])
        end
        return Literal(s[si:end])
    elseif name == "REPLACE"
        val = _eval_arg(1)
        isnothing(val) && return nothing
        pat = _eval_arg(2); rep = _eval_arg(3)
        (isnothing(pat) || isnothing(rep)) && return nothing
        flags = length(args) >= 4 ? _ast_str(_eval_arg(4)) : ""
        rx = _ast_make_regex(_ast_str(pat), flags)
        return Literal(replace(_ast_str(val), rx => _ast_str(rep)))
    elseif name == "ENCODE_FOR_URI"
        val = _eval_arg(1)
        return isnothing(val) ? nothing : Literal(_uri_encode(_ast_str(val)))

    # ── RDF term functions ──
    elseif name == "LANG"
        val = _eval_arg(1)
        return isnothing(val) ? Literal("") :
               val isa Literal && !isnothing(val.language) ? Literal(val.language) : Literal("")
    elseif name == "DATATYPE"
        val = _eval_arg(1)
        return (val isa Literal && !isnothing(val.datatype)) ? val.datatype : nothing
    elseif name == "IRI" || name == "URI"
        val = _eval_arg(1)
        return isnothing(val) ? nothing : URIRef(val isa Literal ? val.lexical : val isa URIRef ? val.value : string(val))
    elseif name == "BNODE"
        return isempty(args) ? BNode() : BNode(_ast_str(_eval_arg(1)))
    elseif name == "STRDT"
        val = _eval_arg(1); dt = _eval_arg(2)
        (isnothing(val) || isnothing(dt)) && return nothing
        return Literal(_ast_str(val), datatype=(dt isa URIRef ? dt : URIRef(_ast_str(dt))))
    elseif name == "STRLANG"
        val = _eval_arg(1); lang = _eval_arg(2)
        (isnothing(val) || isnothing(lang)) && return nothing
        return Literal(_ast_str(val), lang=_ast_str(lang))
    elseif name == "LANGMATCHES"
        lang = _eval_arg(1); tag = _eval_arg(2)
        isnothing(lang) && return Literal(false)
        ls = lowercase(_ast_str(lang)); ts = lowercase(_ast_str(tag))
        return Literal(ts == "*" ? !isempty(ls) : (ls == ts || startswith(ls, ts * "-")))
    elseif name == "SAMETERM"
        a = _eval_arg(1); b = _eval_arg(2)
        return Literal(!isnothing(a) && !isnothing(b) && a === b)
    elseif name == "REGEX"
        val = _eval_arg(1)
        isnothing(val) && return Literal(false)
        pat = _eval_arg(2)
        isnothing(pat) && return Literal(false)
        flags = length(args) >= 3 ? _ast_str(_eval_arg(3)) : ""
        rx = _ast_make_regex(_ast_str(pat), flags)
        return Literal(!isnothing(match(rx, _ast_str(val))))

    # ── Type test functions ──
    elseif name == "ISIRI" || name == "ISURI"
        return Literal(_eval_arg(1) isa URIRef)
    elseif name == "ISLITERAL"
        return Literal(_eval_arg(1) isa Literal)
    elseif name == "ISBLANK"
        return Literal(_eval_arg(1) isa BNode)
    elseif name == "ISNUMERIC"
        val = _eval_arg(1)
        return Literal(!isnothing(_ast_to_numeric(val)))
    elseif name == "BOUND"
        if !isempty(args) && args[1] isa ExprVar
            return Literal(haskey(binding, args[1].name) && !isnothing(binding[args[1].name]))
        end
        return Literal(false)
    elseif name == "ISTRIPLE"
        val = _eval_arg(1)
        return Literal(val isa TripleTerm ? "true" : "false", datatype=URIRef("http://www.w3.org/2001/XMLSchema#boolean"))

    # ── Numeric functions ──
    elseif name == "ABS"
        n = _ast_to_numeric(_eval_arg(1))
        return isnothing(n) ? nothing : Literal(abs(n))
    elseif name == "CEIL"
        n = _ast_to_numeric(_eval_arg(1))
        return isnothing(n) ? nothing : Literal(Int(ceil(n)))
    elseif name == "FLOOR"
        n = _ast_to_numeric(_eval_arg(1))
        return isnothing(n) ? nothing : Literal(Int(floor(n)))
    elseif name == "ROUND"
        n = _ast_to_numeric(_eval_arg(1))
        return isnothing(n) ? nothing : Literal(round(n))
    elseif name == "RAND"
        return Literal(rand())

    # ── Date/Time functions ──
    elseif name == "NOW"
        return Literal(Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS"),
                       datatype=URIRef(_XSD_NS * "dateTime"))
    elseif name in ("YEAR", "MONTH", "DAY", "HOURS", "MINUTES", "SECONDS", "TZ", "TIMEZONE")
        val = _eval_arg(1)
        return _ast_datetime_accessor(name, val)

    # ── Hash functions ──
    elseif name in ("MD5", "SHA1", "SHA256", "SHA384", "SHA512")
        val = _eval_arg(1)
        return isnothing(val) ? nothing : _ast_hash(name, _ast_str(val))

    # ── Conditional ──
    elseif name == "IF"
        cond = _eval_arg(1)
        return _ast_to_bool(cond) ? _eval_arg(2) : _eval_arg(3)
    elseif name == "COALESCE"
        for i in 1:length(args)
            val = _eval_arg(i)
            !isnothing(val) && return val
        end
        return nothing

    # ── UUID ──
    elseif name == "STRUUID"
        return Literal(string(Base.UUID(rand(UInt128))))
    elseif name == "UUID"
        return URIRef("urn:uuid:" * string(Base.UUID(rand(UInt128))))

    # ── RDF-star functions ──
    elseif name == "TRIPLE"
        s = _eval_arg(1); p = _eval_arg(2); o = _eval_arg(3)
        (isnothing(s) || isnothing(p) || isnothing(o)) && return nothing
        return TripleTerm(s, p, o)
    elseif name == "SUBJECT"
        val = _eval_arg(1)
        val isa TripleTerm && return val.subject
        return nothing
    elseif name == "PREDICATE"
        val = _eval_arg(1)
        val isa TripleTerm && return val.predicate
        return nothing
    elseif name == "OBJECT"
        val = _eval_arg(1)
        val isa TripleTerm && return val.object
        return nothing

    # ── ADJUST (SPARQL 1.2) ──
    elseif name == "ADJUST"
        val = _eval_arg(1); tz = _eval_arg(2)
        return val  # simplified — returns value unchanged

    # ── sameValue (SPARQL 1.2) ──
    elseif name == "SAMEVALUE"
        v1 = _eval_arg(1); v2 = _eval_arg(2)
        (isnothing(v1) || isnothing(v2)) && return nothing
        if v1 isa Literal && v2 isa Literal
            n1 = _ast_to_numeric(v1); n2 = _ast_to_numeric(v2)
            if !isnothing(n1) && !isnothing(n2)
                return Literal(n1 == n2 ? "true" : "false", datatype=URIRef("http://www.w3.org/2001/XMLSchema#boolean"))
            end
        end
        return Literal(v1 == v2 ? "true" : "false", datatype=URIRef("http://www.w3.org/2001/XMLSchema#boolean"))

    # ── GeoSPARQL ──
    elseif startswith(name, "GEOF:") || startswith(name, "HTTP://WWW.OPENGIS.NET/")
        return _ast_eval_geosparql(name, args, binding, g)

    # ── Text search ──
    elseif name == "CONTAINS_TEXT"
        val = _eval_arg(1); pattern = _eval_arg(2)
        (isnothing(val) || isnothing(pattern)) && return Literal(false)
        val_str = lowercase(_ast_str(val))
        pat_str = lowercase(_ast_str(pattern))
        if endswith(pat_str, '*')
            # Prefix search: tokenize and check for prefix match
            prefix_str = pat_str[1:end-1]
            tokens = split(val_str, r"[\s\p{P}]+", keepempty=false)
            return Literal(any(t -> startswith(t, prefix_str), tokens))
        else
            return Literal(occursin(pat_str, val_str))
        end
    end

    # Unknown function — throw so fallback to legacy evaluator kicks in
    error("Unknown SPARQL function: $name")
end

# ─── Expression helpers ───────────────────────────────────────────

function _ast_eval_expr_bool(expr::SparqlExpr, binding::Dict{String,Identifier}, g::RDFGraph)::Bool
    val = _ast_eval_expr(expr, binding, g)
    _ast_to_bool(val)
end

function _ast_to_bool(val)::Bool
    isnothing(val) && return false
    val isa Bool && return val
    val isa Literal || return true
    lx = val.lexical
    dt = isnothing(val.datatype) ? nothing : val.datatype.value
    # xsd:boolean
    if dt == _XSD_NS * "boolean"
        return lx in ("true", "1")
    end
    # numeric: 0 is false
    if !isnothing(dt) && _is_numeric_dt(dt)
        n = tryparse(Float64, lx)
        return !isnothing(n) && n != 0.0
    end
    # string: empty is false
    !isempty(lx)
end

function _ast_to_numeric(val)
    isnothing(val) && return nothing
    val isa Number && return val
    val isa Literal || return nothing
    n = tryparse(Float64, val.lexical)
    isnothing(n) && return nothing
    # Return Int if it's an integer type
    dt = isnothing(val.datatype) ? nothing : val.datatype.value
    if !isnothing(dt) && dt in (_XSD_NS * "integer", _XSD_NS * "int", _XSD_NS * "long",
                                 _XSD_NS * "short", _XSD_NS * "byte",
                                 _XSD_NS * "nonNegativeInteger", _XSD_NS * "positiveInteger")
        i = tryparse(Int, val.lexical)
        return isnothing(i) ? n : i
    end
    n
end

function _ast_to_int(val)
    n = _ast_to_numeric(val)
    isnothing(n) && return nothing
    n isa Integer ? n : Int(round(n))
end

function _ast_str(val)::String
    isnothing(val) && return ""
    val isa Literal ? val.lexical : val isa URIRef ? val.value : string(val)
end

function _ast_str_op(val, f)
    isnothing(val) && return nothing
    Literal(f(val isa Literal ? val.lexical : string(val)))
end

function _is_numeric_dt(dt::String)
    dt in (_XSD_NS * "integer", _XSD_NS * "int", _XSD_NS * "long",
           _XSD_NS * "double", _XSD_NS * "float", _XSD_NS * "decimal",
           _XSD_NS * "short", _XSD_NS * "byte",
           _XSD_NS * "nonNegativeInteger", _XSD_NS * "positiveInteger",
           _XSD_NS * "nonPositiveInteger", _XSD_NS * "negativeInteger",
           _XSD_NS * "unsignedInt", _XSD_NS * "unsignedLong",
           _XSD_NS * "unsignedShort", _XSD_NS * "unsignedByte")
end

function _ast_eval_comparison(op::Symbol, left, right)
    # Try numeric comparison first
    ln = _ast_to_numeric(left)
    rn = _ast_to_numeric(right)
    if !isnothing(ln) && !isnothing(rn)
        return Literal(_apply_op(op, ln, rn))
    end
    # Fall back to string comparison
    ls = _ast_str(left)
    rs = _ast_str(right)
    if op == :(==)
        return Literal(_ast_values_equal(left, right))
    elseif op == :!=
        return Literal(!_ast_values_equal(left, right))
    end
    Literal(_apply_op(op, ls, rs))
end

function _ast_eval_arithmetic(op::Symbol, left, right)
    ln = _ast_to_numeric(left)
    rn = _ast_to_numeric(right)
    if !isnothing(ln) && !isnothing(rn)
        result = if op == :+; ln + rn
        elseif op == :-;     ln - rn
        elseif op == :*;     ln * rn
        elseif op == :/;     rn == 0 ? nothing : ln / rn
        else nothing
        end
        return isnothing(result) ? nothing : Literal(result)
    end
    # Date arithmetic: dateTime ± duration
    if op in (:+, :-) && (left isa Literal || right isa Literal)
        return _ast_date_arithmetic(op, left, right)
    end
    nothing
end

function _apply_op(op::Symbol, a, b)
    op == :(==) && return a == b
    op == :!=   && return a != b
    op == :<    && return a < b
    op == :>    && return a > b
    op == :<=   && return a <= b
    op == :>=   && return a >= b
    false
end

function _ast_values_equal(a, b)
    a == b && return true
    # Compare literals by value
    if a isa Literal && b isa Literal
        na = _ast_to_numeric(a)
        nb = _ast_to_numeric(b)
        if !isnothing(na) && !isnothing(nb)
            return na == nb
        end
        return a.lexical == b.lexical
    end
    false
end

function _ast_make_regex(pattern::String, flags::String)
    opts = ""
    'i' in flags && (opts *= "i")
    's' in flags && (opts *= "s")
    'm' in flags && (opts *= "m")
    Regex(pattern, opts)
end

function _uri_encode(s::String)
    buf = IOBuffer()
    for c in s
        if isletter(c) || isdigit(c) || c in ('-', '_', '.', '~')
            write(buf, c)
        else
            for b in codeunits(string(c))
                write(buf, '%')
                write(buf, uppercase(string(b, base=16, pad=2)))
            end
        end
    end
    String(take!(buf))
end

# ─── Datetime accessor ────────────────────────────────────────────

function _ast_datetime_accessor(func::String, val)
    isnothing(val) && return nothing
    s = val isa Literal ? val.lexical : string(val)
    try
        dt = parse_xsd_datetime(s)
        if func == "YEAR";    return Literal(Dates.year(dt))
        elseif func == "MONTH";   return Literal(Dates.month(dt))
        elseif func == "DAY";     return Literal(Dates.day(dt))
        elseif func == "HOURS";   return Literal(Dates.hour(dt))
        elseif func == "MINUTES"; return Literal(Dates.minute(dt))
        elseif func == "SECONDS"; return Literal(Dates.second(dt))
        elseif func == "TZ";      return Literal(_extract_tz(s))
        elseif func == "TIMEZONE"; return Literal(_extract_tz(s))
        end
    catch
        return nothing
    end
end

function _extract_tz(s::String)
    m = match(r"([+-]\d{2}:\d{2}|Z)$", s)
    isnothing(m) ? "" : m.captures[1]
end

# ─── Hash functions ────────────────────────────────────────────────

function _ast_hash(name::String, s::String)
    if name == "MD5"
        return Literal(bytes2hex(MD5.md5(Vector{UInt8}(s))))
    elseif name == "SHA1"
        return Literal(bytes2hex(SHA.sha1(Vector{UInt8}(s))))
    elseif name == "SHA256"
        return Literal(bytes2hex(SHA.sha256(Vector{UInt8}(s))))
    elseif name == "SHA384"
        return Literal(bytes2hex(SHA.sha384(Vector{UInt8}(s))))
    elseif name == "SHA512"
        return Literal(bytes2hex(SHA.sha512(Vector{UInt8}(s))))
    end
    nothing
end

# ─── Date arithmetic ──────────────────────────────────────────────

function _ast_date_arithmetic(op::Symbol, left, right)
    # Try dateTime ± duration
    if left isa Literal && right isa Literal
        dt_val = _try_parse_dt(left)
        dur_val = _try_parse_duration(right)
        if !isnothing(dt_val) && !isnothing(dur_val)
            result_dt = op == :+ ? dt_val + dur_val : dt_val - dur_val
            return Literal(Dates.format(result_dt, "yyyy-mm-ddTHH:MM:SS"),
                           datatype=URIRef(_XSD_NS * "dateTime"))
        end
        # Try dateTime - dateTime → duration
        dt1 = _try_parse_dt(left)
        dt2 = _try_parse_dt(right)
        if !isnothing(dt1) && !isnothing(dt2) && op == :-
            diff = dt1 - dt2
            total_secs = round(Int, Dates.value(diff) / 1000)
            days = div(total_secs, 86400)
            rem_secs = mod(total_secs, 86400)
            hours = div(rem_secs, 3600)
            rem_secs = mod(rem_secs, 3600)
            mins = div(rem_secs, 60)
            secs = mod(rem_secs, 60)
            dur_str = "P"
            days > 0 && (dur_str *= "$(days)D")
            if hours > 0 || mins > 0 || secs > 0
                dur_str *= "T"
                hours > 0 && (dur_str *= "$(hours)H")
                mins > 0 && (dur_str *= "$(mins)M")
                secs > 0 && (dur_str *= "$(secs)S")
            end
            dur_str == "P" && (dur_str = "PT0S")
            return Literal(dur_str, datatype=URIRef(_XSD_NS * "dayTimeDuration"))
        end
    end
    nothing
end

function _try_parse_dt(val)
    val isa Literal || return nothing
    dt = isnothing(val.datatype) ? nothing : val.datatype.value
    (dt == _XSD_NS * "dateTime" || dt == _XSD_NS * "date") || return nothing
    try
        parse_xsd_datetime(val.lexical)
    catch
        nothing
    end
end

function _try_parse_duration(val)
    val isa Literal || return nothing
    dt = isnothing(val.datatype) ? nothing : val.datatype.value
    dt in (_XSD_NS * "duration", _XSD_NS * "dayTimeDuration", _XSD_NS * "yearMonthDuration") || return nothing
    s = val.lexical
    m = match(r"^-?P(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:([\d.]+)S)?)?$", s)
    isnothing(m) && return nothing
    years = something(tryparse(Int, something(m.captures[1], "0")), 0)
    months = something(tryparse(Int, something(m.captures[2], "0")), 0)
    days = something(tryparse(Int, something(m.captures[3], "0")), 0)
    hours = something(tryparse(Int, something(m.captures[4], "0")), 0)
    mins = something(tryparse(Int, something(m.captures[5], "0")), 0)
    secs = something(tryparse(Float64, something(m.captures[6], "0")), 0.0)
    # Approximate year/month in days (365d/y, 30d/m)
    total_days = days + years * 365 + months * 30
    Dates.Day(total_days) + Dates.Hour(hours) + Dates.Minute(mins) + Dates.Second(round(Int, secs))
end

# ─── GeoSPARQL stub ───────────────────────────────────────────────

function _ast_eval_geosparql(name, args, binding, g)
    # Normalize function name: extract the part after the last /
    func_name = lowercase(last(split(replace(name, "GEOF:" => ""), "/")))
    eval_args = [_ast_eval_expr(a, binding, g) for a in args]
    if func_name == "distance" && length(eval_args) >= 2
        g1 = _extract_wkt_geometry(eval_args[1])
        g2 = _extract_wkt_geometry(eval_args[2])
        (isnothing(g1) || isnothing(g2)) && return nothing
        return Literal(geo_distance(g1, g2))
    end
    # Simple Features binary relations
    _geo_rel = Dict("sfcontains"=>geo_contains, "sfwithin"=>geo_within,
        "sfintersects"=>geo_intersects, "sfoverlaps"=>geo_overlaps,
        "sftouches"=>geo_touches, "sfdisjoint"=>geo_disjoint, "sfequals"=>geo_equals,
        "sfcrosses"=>geo_crosses)
    if haskey(_geo_rel, func_name) && length(eval_args) >= 2
        g1 = _extract_wkt_geometry(eval_args[1])
        g2 = _extract_wkt_geometry(eval_args[2])
        (isnothing(g1) || isnothing(g2)) && return nothing
        return Literal(_geo_rel[func_name](g1, g2))
    end
    # Egenhofer relations
    _eh_rel = Dict("ehcontains"=>geo_eh_contains, "ehcoveredby"=>geo_eh_covered_by,
        "ehcovers"=>geo_eh_covers, "ehdisjoint"=>geo_eh_disjoint,
        "ehequals"=>geo_eh_equals, "ehinside"=>geo_eh_inside,
        "ehmeet"=>geo_eh_meet, "ehoverlap"=>geo_eh_overlap)
    if haskey(_eh_rel, func_name) && length(eval_args) >= 2
        g1 = _extract_wkt_geometry(eval_args[1])
        g2 = _extract_wkt_geometry(eval_args[2])
        (isnothing(g1) || isnothing(g2)) && return nothing
        return Literal(_eh_rel[func_name](g1, g2))
    end
    # RCC8 relations
    _rcc8_rel = Dict("rcc8dc"=>geo_rcc8_dc, "rcc8ec"=>geo_rcc8_ec,
        "rcc8po"=>geo_rcc8_po, "rcc8tpp"=>geo_rcc8_tpp, "rcc8ntpp"=>geo_rcc8_ntpp,
        "rcc8tppi"=>geo_rcc8_tppi, "rcc8ntppi"=>geo_rcc8_ntppi, "rcc8eq"=>geo_rcc8_eq)
    if haskey(_rcc8_rel, func_name) && length(eval_args) >= 2
        g1 = _extract_wkt_geometry(eval_args[1])
        g2 = _extract_wkt_geometry(eval_args[2])
        (isnothing(g1) || isnothing(g2)) && return nothing
        return Literal(_rcc8_rel[func_name](g1, g2))
    end
    if func_name == "buffer" && length(eval_args) >= 2
        g1 = _extract_wkt_geometry(eval_args[1])
        d = _ast_to_numeric(eval_args[2])
        (isnothing(g1) || isnothing(d)) && return nothing
        return Literal(geo_to_wkt(geo_buffer(g1, Float64(d))))
    end
    # Unary geometry → numeric functions
    _unary_num = Dict("area"=>geo_area, "length"=>geo_length, "perimeter"=>geo_perimeter,
        "dimension"=>g1->geo_dimension(g1), "coordinatedimension"=>g1->geo_coordinate_dimension(g1),
        "getsrid"=>g1->geo_get_srid(g1), "numgeometries"=>g1->geo_num_geometries(g1),
        "minx"=>geo_min_x, "maxx"=>geo_max_x, "miny"=>geo_min_y, "maxy"=>geo_max_y)
    if haskey(_unary_num, func_name) && length(eval_args) >= 1
        g1 = _extract_wkt_geometry(eval_args[1])
        isnothing(g1) && return nothing
        return Literal(_unary_num[func_name](g1))
    end
    # Unary geometry → bool functions
    _unary_bool = Dict("isempty"=>geo_is_empty, "issimple"=>geo_is_simple)
    if haskey(_unary_bool, func_name) && length(eval_args) >= 1
        g1 = _extract_wkt_geometry(eval_args[1])
        isnothing(g1) && return nothing
        return Literal(_unary_bool[func_name](g1))
    end
    # Unary geometry → string functions
    if func_name == "geometrytype" && length(eval_args) >= 1
        g1 = _extract_wkt_geometry(eval_args[1])
        isnothing(g1) && return nothing
        return Literal(geo_geometry_type(g1))
    end
    # Unary geometry → geometry functions (return WKT)
    _unary_geom = Dict("boundary"=>geo_boundary, "convexhull"=>geo_convex_hull,
        "envelope"=>geo_envelope, "centroid"=>geo_centroid)
    if haskey(_unary_geom, func_name) && length(eval_args) >= 1
        g1 = _extract_wkt_geometry(eval_args[1])
        isnothing(g1) && return nothing
        return Literal(geo_to_wkt(_unary_geom[func_name](g1)))
    end
    # Binary geometry → geometry functions (return WKT)
    _binary_geom = Dict("intersection"=>geo_intersection, "union"=>geo_union,
        "difference"=>geo_difference, "symdifference"=>geo_sym_difference)
    if haskey(_binary_geom, func_name) && length(eval_args) >= 2
        g1 = _extract_wkt_geometry(eval_args[1])
        g2 = _extract_wkt_geometry(eval_args[2])
        (isnothing(g1) || isnothing(g2)) && return nothing
        return Literal(geo_to_wkt(_binary_geom[func_name](g1, g2)))
    end
    # relate (2 or 3 args)
    if func_name == "relate" && length(eval_args) >= 2
        g1 = _extract_wkt_geometry(eval_args[1])
        g2 = _extract_wkt_geometry(eval_args[2])
        (isnothing(g1) || isnothing(g2)) && return nothing
        if length(eval_args) >= 3
            pat = eval_args[3] isa Literal ? eval_args[3].lexical : string(eval_args[3])
            return Literal(geo_relate(g1, g2, pat))
        end
        return Literal(geo_relate(g1, g2))
    end
    # geometryN (geometry + index)
    if func_name == "geometryn" && length(eval_args) >= 2
        g1 = _extract_wkt_geometry(eval_args[1])
        n = _ast_to_numeric(eval_args[2])
        (isnothing(g1) || isnothing(n)) && return nothing
        return Literal(geo_to_wkt(geo_geometry_n(g1, Int(n))))
    end
    # asWKT / asGeoJSON
    if func_name == "aswkt" && length(eval_args) >= 1
        g1 = _extract_wkt_geometry(eval_args[1])
        isnothing(g1) && return nothing
        return Literal(geo_to_wkt(g1))
    end
    if func_name == "asgeojson" && length(eval_args) >= 1
        g1 = _extract_wkt_geometry(eval_args[1])
        isnothing(g1) && return nothing
        return Literal(geo_to_geojson(g1))
    end
    # minZ/maxZ — use actual Z coordinate for 3D geometries
    if func_name in ("minz", "maxz") && length(eval_args) >= 1
        g1 = _extract_wkt_geometry(eval_args[1])
        isnothing(g1) && return nothing
        pts = _all_points(g1)
        zvals = [p.z for p in pts if !isnan(p.z)]
        isempty(zvals) && return Literal(0.0)
        return Literal(func_name == "minz" ? minimum(zvals) : maximum(zvals))
    end
    # GeoSPARQL 1.3: is3D, isMeasured, volume, surfaceArea
    if func_name == "is3d" && length(eval_args) >= 1
        g1 = _extract_wkt_geometry(eval_args[1])
        isnothing(g1) && return nothing
        return Literal(geo_is_3d(g1))
    end
    if func_name == "ismeasured" && length(eval_args) >= 1
        g1 = _extract_wkt_geometry(eval_args[1])
        isnothing(g1) && return nothing
        return Literal(geo_is_measured(g1))
    end
    if func_name == "volume" && length(eval_args) >= 1
        g1 = _extract_wkt_geometry(eval_args[1])
        isnothing(g1) && return nothing
        return Literal(geo_volume(g1))
    end
    if func_name == "surfacearea" && length(eval_args) >= 1
        g1 = _extract_wkt_geometry(eval_args[1])
        isnothing(g1) && return nothing
        return Literal(geo_surface_area(g1))
    end
    nothing
end

# ─── Aggregate computation ────────────────────────────────────────

function _ast_eval_group_aggregate(q::SparqlSelect, bindings, g)
    # Streaming path: when all aggregates are streaming-friendly (no DISTINCT,
    # no GROUP_CONCAT/MEDIAN/MODE), avoid materialising bindings per group.
    # Instead maintain per-group accumulators directly.
    if _streaming_aggregate_safe(q)
        return _ast_eval_group_aggregate_streaming(q, bindings, g)
    end
    groups = Dict{Any, Vector{Dict{String,Identifier}}}()
    group_order = Any[]  # preserve insertion order for HAVING
    for b in bindings
        key = if !isempty(q.group_by)
            Tuple(let e = _ast_eval_expr(gb, b, g); isnothing(e) ? nothing : e end
                  for gb in q.group_by)
        else
            ()
        end
        if !haskey(groups, key)
            push!(group_order, key)
        end
        push!(get!(groups, key, Dict{String,Identifier}[]), b)
    end

    new_bindings = Dict{String,Identifier}[]
    for key in group_order
        group = groups[key]
        result = Dict{String,Identifier}()
        # Copy group-by variable values from first row
        if !isempty(q.group_by) && !isempty(group)
            for gb in q.group_by
                if gb isa ExprVar && haskey(group[1], gb.name)
                    result[gb.name] = group[1][gb.name]
                end
            end
        end
        # Compute aggregates
        for sa in q.aggregates
            result[sa.alias] = _ast_compute_aggregate(sa.agg, group)
        end
        # HAVING filter — compute aggregate values in having expression context
        if !isnothing(q.having)
            having_row = copy(result)
            _ast_stash_agg_values!(q.having, having_row, group)
            _ast_eval_expr_bool(q.having, having_row, g) || continue
        end
        push!(new_bindings, result)
    end

    new_bindings
end

# Detect if streaming aggregation is safe — all aggregates support O(1) update
# and the query has no HAVING (HAVING needs full per-group bindings for now).
function _streaming_aggregate_safe(q::SparqlSelect)
    !isnothing(q.having) && return false
    isempty(q.aggregates) && return false
    for sa in q.aggregates
        agg = sa.agg
        # COUNT DISTINCT, SUM DISTINCT, AVG DISTINCT supported via Set-based accumulator
        if agg.distinct
            agg.func in ("COUNT", "SUM", "AVG", "MIN", "MAX") || return false
            agg.arg isa ExprVar || agg.arg isa ExprStar || return false
        else
            agg.func in ("COUNT", "SUM", "AVG", "MIN", "MAX", "SAMPLE") || return false
        end
    end
    for gb in q.group_by
        gb isa ExprVar || return false
    end
    return true
end

# Streaming GROUP BY + aggregate. Maintains accumulators per group as we walk
# bindings. Skips materialising the per-group binding lists.
function _ast_eval_group_aggregate_streaming(q::SparqlSelect, bindings, g)
    n_agg = length(q.aggregates)
    n_gb = length(q.group_by)
    # Per group state: (group_var_values::Vector{Identifier}, accumulators::Vector{Any})
    groups = Dict{NTuple, Tuple{Vector{Identifier}, Vector{Any}}}()
    group_order = NTuple[]
    # Empty bindings + no group-by: still emit one row of empties
    if isempty(bindings) && isempty(q.group_by)
        result = Dict{String,Identifier}()
        for sa in q.aggregates
            # Compute on empty group
            result[sa.alias] = _ast_compute_aggregate(sa.agg, Dict{String,Identifier}[])
        end
        return Dict{String,Identifier}[result]
    end
    for b in bindings
        key = if n_gb == 0
            ()
        else
            ntuple(n_gb) do i
                e = _ast_eval_expr(q.group_by[i], b, g)
                isnothing(e) ? nothing : e
            end
        end
        st = get(groups, key, nothing)
        if st === nothing
            gvals = Identifier[]
            for gb in q.group_by
                push!(gvals, get(b, (gb::ExprVar).name, Literal("")))
            end
            accs = Any[_agg_init(q.aggregates[i].agg) for i in 1:n_agg]
            for i in 1:n_agg
                accs[i] = _agg_update(accs[i], q.aggregates[i].agg, b)
            end
            groups[key] = (gvals, accs)
            push!(group_order, key)
        else
            _, accs = st
            for i in 1:n_agg
                accs[i] = _agg_update(accs[i], q.aggregates[i].agg, b)
            end
        end
    end

    new_bindings = Vector{Dict{String,Identifier}}(undef, length(group_order))
    @inbounds for gi in eachindex(group_order)
        key = group_order[gi]
        gvals, accs = groups[key]
        result = Dict{String,Identifier}()
        for (i, gb) in enumerate(q.group_by)
            result[(gb::ExprVar).name] = gvals[i]
        end
        for i in 1:n_agg
            result[q.aggregates[i].alias] = _agg_finalize(accs[i], q.aggregates[i].agg)
        end
        new_bindings[gi] = result
    end
    new_bindings
end

# Initial accumulator state for a streaming aggregate
@inline function _agg_init(agg::ExprAggregate)
    f = agg.func
    if agg.distinct
        # All DISTINCT variants need a set of seen values
        if f == "COUNT"
            return Set{Identifier}()
        elseif f == "SUM" || f == "AVG"
            return Set{Identifier}()
        elseif f == "MIN" || f == "MAX"
            return Set{Identifier}()
        end
    end
    if f == "COUNT"
        return 0
    elseif f == "SUM"
        return (0.0, false)
    elseif f == "AVG"
        return (0.0, 0)
    elseif f == "MIN" || f == "MAX"
        return nothing
    elseif f == "SAMPLE"
        return nothing
    end
    return nothing
end

@inline function _agg_update(acc, agg::ExprAggregate, b::Dict{String,Identifier})
    f = agg.func
    arg = agg.arg
    if agg.distinct
        # Collect distinct values into a Set; finalize computes the result later.
        s = acc::Set{Identifier}
        if arg isa ExprStar
            # COUNT(DISTINCT *) — distinct over the entire row signature.
            # Approximate via row-tuple hash (rare path).
            push!(s, Literal(string(hash(b))))
        elseif arg isa ExprVar
            v = get(b, arg.name, nothing)
            v !== nothing && push!(s, v)
        end
        return s
    end
    if f == "COUNT"
        if arg isa ExprStar
            return acc + 1
        elseif arg isa ExprVar
            return haskey(b, arg.name) ? acc + 1 : acc
        end
        return acc
    elseif f == "SUM"
        v = _ast_extract_numeric_for_agg(arg, b)
        v === nothing && return acc
        s, all_int = acc::Tuple{Float64,Bool}
        return (s + Float64(v), all_int)
    elseif f == "AVG"
        v = _ast_extract_numeric_for_agg(arg, b)
        v === nothing && return acc
        s, c = acc::Tuple{Float64,Int}
        return (s + Float64(v), c + 1)
    elseif f == "MIN"
        v = _ast_extract_value_for_agg(arg, b)
        v === nothing && return acc
        if acc === nothing
            return v
        end
        return _agg_lt(v, acc) ? v : acc
    elseif f == "MAX"
        v = _ast_extract_value_for_agg(arg, b)
        v === nothing && return acc
        if acc === nothing
            return v
        end
        return _agg_lt(acc, v) ? v : acc
    elseif f == "SAMPLE"
        if acc === nothing
            v = _ast_extract_value_for_agg(arg, b)
            return v === nothing ? acc : v
        end
        return acc
    end
    return acc
end

@inline function _ast_extract_numeric_for_agg(arg, b::Dict{String,Identifier})
    if arg isa ExprVar
        v = get(b, arg.name, nothing)
        v === nothing && return nothing
        return _ast_to_numeric(v)
    end
    return nothing
end

@inline function _ast_extract_value_for_agg(arg, b::Dict{String,Identifier})
    if arg isa ExprVar
        return get(b, arg.name, nothing)
    end
    return nothing
end

@inline function _agg_lt(a::Identifier, b::Identifier)
    na = _ast_to_numeric(a)
    nb = _ast_to_numeric(b)
    if na !== nothing && nb !== nothing
        return na < nb
    end
    sa = a isa Literal ? a.lexical : string(a)
    sb = b isa Literal ? b.lexical : string(b)
    return sa < sb
end

@inline function _agg_finalize(acc, agg::ExprAggregate)
    f = agg.func
    if agg.distinct
        s = acc::Set{Identifier}
        if f == "COUNT"
            return Literal(length(s))
        elseif f == "SUM"
            tot = 0.0
            for v in s
                n = _ast_to_numeric(v)
                n !== nothing && (tot += Float64(n))
            end
            return isinteger(tot) ? Literal(Int(tot)) : Literal(tot)
        elseif f == "AVG"
            tot = 0.0; c = 0
            for v in s
                n = _ast_to_numeric(v)
                n !== nothing && (tot += Float64(n); c += 1)
            end
            return c == 0 ? Literal(0.0) : Literal(tot / c)
        elseif f == "MIN" || f == "MAX"
            isempty(s) && return Literal("")
            it = iterate(s); best = it[1]; state = it[2]
            while true
                it = iterate(s, state); it === nothing && break
                v = it[1]; state = it[2]
                if (f == "MIN" && _agg_lt(v, best)) || (f == "MAX" && _agg_lt(best, v))
                    best = v
                end
            end
            return best
        end
    end
    if f == "COUNT"
        return Literal(acc::Int)
    elseif f == "SUM"
        s, _ = acc::Tuple{Float64,Bool}
        return isinteger(s) ? Literal(Int(s)) : Literal(s)
    elseif f == "AVG"
        s, c = acc::Tuple{Float64,Int}
        return c == 0 ? Literal(0.0) : Literal(s / c)
    elseif f == "MIN" || f == "MAX" || f == "SAMPLE"
        return acc === nothing ? Literal("") : acc::Identifier
    end
    return Literal("")
end

"""Recursively find ExprAggregate nodes and stash their computed values in the binding."""
function _ast_stash_agg_values!(expr::ExprAggregate, binding::Dict{String,Identifier}, group)
    binding["__agg_$(hash(expr))__"] = _ast_compute_aggregate(expr, group)
end
function _ast_stash_agg_values!(expr::ExprBinaryOp, binding, group)
    _ast_stash_agg_values!(expr.left, binding, group)
    _ast_stash_agg_values!(expr.right, binding, group)
end
function _ast_stash_agg_values!(expr::ExprUnaryOp, binding, group)
    _ast_stash_agg_values!(expr.arg, binding, group)
end
function _ast_stash_agg_values!(expr::ExprFunctionCall, binding, group)
    for a in expr.args; _ast_stash_agg_values!(a, binding, group); end
end
function _ast_stash_agg_values!(expr, binding, group) end  # leaf nodes — no-op

function _ast_compute_aggregate(agg::ExprAggregate, group::Vector{Dict{String,Identifier}})
    var_name = agg.arg isa ExprVar ? agg.arg.name : nothing
    is_star = agg.arg isa ExprStar

    # Fast path: COUNT(*) without DISTINCT — just count rows
    if agg.func == "COUNT" && is_star && !agg.distinct
        return Literal(length(group))
    end
    # Fast path: COUNT(?v) without DISTINCT — count rows where v is bound
    if agg.func == "COUNT" && !isnothing(var_name) && !agg.distinct
        c = 0
        @inbounds for b in group
            haskey(b, var_name) && (c += 1)
        end
        return Literal(c)
    end

    vals = if is_star
        Identifier[Literal("x") for _ in group]  # dummy for COUNT(*) DISTINCT
    elseif !isnothing(var_name)
        Identifier[b[var_name] for b in group if haskey(b, var_name)]
    else
        Identifier[]
    end

    agg.distinct && (vals = unique(vals))

    if agg.func == "COUNT"
        return Literal(length(vals))
    elseif agg.func == "SUM"
        nums = filter(!isnothing, [_ast_to_numeric(v) for v in vals])
        return Literal(isempty(nums) ? 0 : sum(nums))
    elseif agg.func == "AVG"
        nums = filter(!isnothing, [_ast_to_numeric(v) for v in vals])
        return Literal(isempty(nums) ? 0.0 : sum(nums) / length(nums))
    elseif agg.func == "MIN"
        nums = filter(!isnothing, [_ast_to_numeric(v) for v in vals])
        !isempty(nums) && return Literal(minimum(nums))
        isempty(vals) && return Literal("")
        return argmin(v -> v isa Literal ? v.lexical : string(v), vals)
    elseif agg.func == "MAX"
        nums = filter(!isnothing, [_ast_to_numeric(v) for v in vals])
        !isempty(nums) && return Literal(maximum(nums))
        isempty(vals) && return Literal("")
        return argmax(v -> v isa Literal ? v.lexical : string(v), vals)
    elseif agg.func == "SAMPLE"
        return isempty(vals) ? Literal("") : first(vals)
    elseif agg.func == "GROUP_CONCAT"
        sep = something(agg.separator, " ")
        strs = [v isa Literal ? v.lexical : string(v) for v in vals]
        return Literal(join(strs, sep))
    elseif agg.func == "MEDIAN"
        nums = sort(filter(!isnothing, [_ast_to_numeric(v) for v in vals]))
        isempty(nums) && return Literal(0)
        mid = div(length(nums) + 1, 2)
        result = iseven(length(nums)) ? (nums[mid] + nums[mid+1]) / 2 : nums[mid]
        # Return Int if the result is a whole number
        return Literal(isinteger(result) ? Int(result) : result)
    elseif agg.func == "MODE"
        isempty(vals) && return Literal("")
        counts = Dict{Identifier, Int}()
        for v in vals
            counts[v] = get(counts, v, 0) + 1
        end
        return first(sort(collect(keys(counts)), by=k->counts[k], rev=true))
    end
    Literal("")
end

# ─── ORDER BY comparison ──────────────────────────────────────────

function _ast_order_compare(a, b, order_by, g)
    for (expr, dir) in order_by
        va = if expr isa ExprVar
            string(get(a, expr.name, ""))
        else
            v = _ast_eval_expr(expr, a, g)
            isnothing(v) ? "" : _ast_str(v)
        end
        vb = if expr isa ExprVar
            string(get(b, expr.name, ""))
        else
            v = _ast_eval_expr(expr, b, g)
            isnothing(v) ? "" : _ast_str(v)
        end
        if va != vb
            # Try numeric comparison
            na = tryparse(Float64, va)
            nb = tryparse(Float64, vb)
            if !isnothing(na) && !isnothing(nb)
                return dir == :asc ? na < nb : na > nb
            end
            return dir == :asc ? va < vb : va > vb
        end
    end
    false
end

# ─── Projection ───────────────────────────────────────────────────

function _ast_projection_vars(q::SparqlSelect)
    proj = copy(q.variables)
    for sa in q.aggregates
        sa.alias in proj || push!(proj, sa.alias)
    end
    for se in q.select_exprs
        se.alias in proj || push!(proj, se.alias)
    end
    proj
end

# ─── Binding compatibility ────────────────────────────────────────

function _ast_compatible(a::Dict{String,Identifier}, b::Dict{String,Identifier})
    for (k, v) in a
        haskey(b, k) && b[k] != v && return false
    end
    true
end

function _ast_compatible_shared(a::Dict{String,Identifier}, b::Dict{String,Identifier})
    shared = false
    for (k, v) in a
        if haskey(b, k)
            shared = true
            v != b[k] && return false
        end
    end
    shared
end

# ─── SERVICE query builder ────────────────────────────────────────

function _ast_build_service_query(patterns::Vector{SparqlPattern})
    parts = String[]
    for p in patterns
        if p isa PatTriple
            s = _term_to_sparql(p.subject)
            pred = _term_to_sparql(p.predicate)
            o = _term_to_sparql(p.object)
            push!(parts, "$s $pred $o .")
        end
    end
    "SELECT * WHERE { " * join(parts, " ") * " }"
end

function _term_to_sparql(t)
    t isa String && return "?$t"
    t isa URIRef && return "<$(t.value)>"
    t isa Literal && return n3(t)
    t isa BNode && return "_:$(t.id)"
    string(t)
end
