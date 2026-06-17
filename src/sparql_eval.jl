# ═══════════════════════════════════════════════════════════════════
# SPARQL Evaluator — walks the AST produced by sparql_parser.jl
# ═══════════════════════════════════════════════════════════════════
#
# Evaluates SparqlQuery AST nodes against an RDFGraph, producing
# results in the same format as the legacy evaluator.

const _XSD_NS = "http://www.w3.org/2001/XMLSchema#"

# ─── Top-level evaluation ─────────────────────────────────────────

function _ast_evaluate(g::RDFGraph, q::SparqlSelect)
    _ACTIVE_BASE[] = get(q.prefixes, "@base", nothing)
    # Fast path: SELECT (COUNT(*) AS ?x) WHERE { ?s ?p ?o } with no other clauses.
    # Bypasses BGP materialisation; uses the store's `length` directly.
    if _is_count_star_query(q)
        return [Dict{String,Identifier}(q.aggregates[1].alias => Literal(length(g)))]
    end

    # Fast path: DuckDB BGP pushdown — translate the entire SELECT into a
    # single SQL query and let DuckDB's vectorized engine evaluate it.
    if _duckdb_pushdown_eligible(q, g)
        try
            return _duckdb_pushdown_run(g, q)
        catch err
            @debug "DuckDB pushdown failed; falling back" exception=(err, catch_backtrace())
        end
    end

    # Fast path: streaming OPTIONAL+aggregate (Q4-shape queries). Returns
    # already-aggregated bindings — skips the secondary group/aggregate pass.
    streamed = _try_stream_opt_agg(q, g)
    if streamed !== nothing
        bindings = streamed
        # Skip BGP eval, SELECT exprs, and group/aggregate; jump to ORDER BY etc.
        @goto post_aggregate
    end

    # Fast path: encoded streaming aggregate (EncodedStore + GROUP BY +
    # streaming-friendly aggregates). Operates on Vector{EncBinding}
    # directly, eliminating the BGP-exit decode boundary (Q2-shape).
    if _enc_streaming_agg_eligible(q, g)
        # Try fused last-star+aggregate (Q2-shape) first — avoids
        # materializing the joined eb for the last star group.
        fused = _try_fused_bgp_agg(q, g)
        if fused !== nothing
            bindings = fused
            @goto post_aggregate
        end
        # Push LIMIT into BGP only if no ORDER BY / DISTINCT
        push_limit_eb = 0
        pats = _hoist_filters(q.patterns)
        if length(pats) >= 2
            pats = _reorder_star_groups_encoded(g.store::EncodedStore, pats)
        end
        ebs = _ast_eval_patterns_star_encoded_eb(g, pats,
            Dict{String,Identifier}[Dict{String,Identifier}()], push_limit_eb)
        bindings = _ast_eval_group_aggregate_streaming_eb(q, ebs, g.store::EncodedStore, g)
        @goto post_aggregate
    end

    # Push LIMIT into pattern evaluation when safe (no ORDER BY, GROUP BY, DISTINCT, computed exprs)
    push_limit = 0
    if !isnothing(q.limit) && isempty(q.order_by) && isempty(q.aggregates) &&
       isempty(q.group_by) && !q.distinct && !q.reduced && isempty(q.select_exprs)
        push_limit = q.offset + q.limit
    end

    # Fast path: EncodedStore + ORDER BY (single bare ExprVar) + LIMIT,
    # no DISTINCT/aggregates/group_by/select_exprs. Run BGP returning
    # raw EBs, sort by id-decoded numeric key on EBs, then decode only
    # the survivors. Avoids decoding ~30K bindings when only k are kept.
    if g.store isa EncodedStore && length(q.order_by) == 1 &&
       !isnothing(q.limit) && q.offset == 0 &&
       isempty(q.aggregates) && isempty(q.group_by) && isempty(q.select_exprs) &&
       !q.distinct && !q.reduced &&
       first(q.order_by[1]) isa ExprVar
        sort_var = (q.order_by[1][1]::ExprVar).name
        sign = q.order_by[1][2] == :desc ? -1.0 : 1.0
        store_e = g.store::EncodedStore
        pats = _hoist_filters(q.patterns)
        if length(pats) >= 2
            pats = _reorder_star_groups_encoded(store_e, pats)
        end
        ebs = _ast_eval_patterns_star_encoded_eb(g, pats,
            Dict{String,Identifier}[Dict{String,Identifier}()], 0)
        if !(ebs isa Vector{EncBinding})
            # Pipeline returned decoded bindings; fall through to legacy path.
            bindings = ebs
            @goto post_aggregate
        end
        if isempty(ebs)
            return Dict{String,Identifier}[]
        end
        # Build numeric keys from id-decoded Literal lexicals
        keys_f64 = Vector{Float64}(undef, length(ebs))
        all_numeric = true
        @inbounds for i in eachindex(ebs)
            id = get(ebs[i], sort_var, UInt32(0))
            if id == 0
                all_numeric = false; break
            end
            t = store_e.id_to_term[id]
            x = _ast_literal_float64(t)  # nothing unless a numeric-typed literal
            if x === nothing
                all_numeric = false; break
            end
            keys_f64[i] = sign * x
        end
        if all_numeric
            k = q.limit
            perm = if k < length(keys_f64)
                partialsortperm(keys_f64, 1:k)
            else
                sortperm(keys_f64)
            end
            selected = ebs[perm]
            bindings = _decode_bindings(store_e, selected)
            @goto post_orderby_skip
        end
        # Non-numeric — fall back to full decode + legacy ORDER BY path.
        bindings = _decode_bindings(store_e, ebs)
        @goto post_aggregate
    end

    bindings = _ast_eval_patterns(g, q.patterns; limit=push_limit)

    # Evaluate SELECT expressions. Those that reference aggregates (e.g.
    # `(MIN(?p)+MAX(?p))/2 AS ?c`) must be deferred until after grouping; plain
    # projections are computed per input row here.
    # A SELECT expression must be deferred until after grouping if it contains
    # an aggregate, or transitively references an aggregate alias (e.g.
    # `(?count + 1 AS ?x)` where `?count` is `(COUNT(?v) AS ?count)`). Plain
    # projection expressions that only reference other plain projection aliases
    # (e.g. projexp03's `(2 * ?sum AS ?twice)`) are evaluated per-row, in order.
    agg_dep_names = Set{String}()           # aggregate-dependent alias names
    for sa in q.aggregates; push!(agg_dep_names, sa.alias); end

    agg_exprs = SelectExpr[]
    for se in q.select_exprs
        if _expr_has_aggregate(se.expr) || _expr_refs_any(se.expr, agg_dep_names)
            push!(agg_exprs, se)
            push!(agg_dep_names, se.alias)
        else
            for b in bindings
                val = _ast_eval_expr(se.expr, b, g)
                !isnothing(val) && (b[se.alias] = val)
            end
        end
    end

    # Aggregates and GROUP BY. A SELECT expression that merely *contains* an
    # aggregate (e.g. `(MIN(?p)+MAX(?p))/2 AS ?c`) also forces grouping even when
    # there is no bare aggregate or GROUP BY clause.
    if !isempty(q.aggregates) || !isempty(q.group_by) || !isempty(agg_exprs)
        bindings = _ast_eval_group_aggregate(q, bindings, g)
        # Evaluate deferred SELECT expressions per group row, in declaration
        # order so a later expression can reference an earlier alias.
        if !isempty(agg_exprs)
            for b in bindings
                for se in agg_exprs
                    val = _ast_eval_expr(se.expr, b, g)
                    !isnothing(val) && (b[se.alias] = val)
                end
            end
        end
    end

    @label post_aggregate

    # ORDER BY — use partial sort when LIMIT is set (top-K optimization)
    if !isempty(q.order_by)
        k = q.offset + (isnothing(q.limit) ? length(bindings) : q.limit)
        # Fast path: all order_by exprs are bare ExprVar, all values numeric
        # → precompute Float64 keys, sortperm, apply. Avoids per-compare
        # string + tryparse work.
        if length(bindings) > 32 && all(o -> first(o) isa ExprVar, q.order_by)
            keys_f64 = _ast_try_numeric_sort_keys(bindings, q.order_by)
            if keys_f64 !== nothing
                perm = if k < length(bindings)
                    partialsortperm(keys_f64, 1:min(k, length(keys_f64)), lt=isless)
                else
                    sortperm(keys_f64, lt=isless)
                end
                bindings = bindings[perm]
                @goto post_orderby
            end
        end
        cmp = (a, b) -> _ast_order_compare(a, b, q.order_by, g)
        if k < length(bindings)
            sort!(bindings, lt=cmp, alg=PartialQuickSort(k))
        else
            sort!(bindings, lt=cmp)
        end
        @label post_orderby
    end

    @label post_orderby_skip
    proj_vars = _ast_projection_vars(q)

    # When OFFSET+LIMIT is set and we don't need DISTINCT (which requires
    # comparing post-projection rows), slice first so projection only runs
    # on the rows we'll actually return. Saves O(N) Dict construction when
    # N >> limit (e.g. ORDER BY + LIMIT 50 over 30K rows).
    can_slice_first = !isnothing(q.limit) && !q.distinct && !q.reduced
    if can_slice_first
        start = q.offset + 1
        stop = min(start + q.limit - 1, length(bindings))
        bindings = start <= length(bindings) ? bindings[start:stop] : Dict{String,Identifier}[]
    end

    # Project variables — always project when the query names explicit vars
    # (a first-row heuristic can leak extra variables from later rows)
    if !isempty(proj_vars) && !isempty(bindings)
        bindings = [Dict{String,Identifier}(v => b[v] for v in proj_vars if haskey(b, v)) for b in bindings]
    elseif isempty(proj_vars)
        # SELECT * — drop internal variables generated by the parser for blank
        # node property lists / collections (named "_:..."; '_'/':' cannot
        # start a user variable name)
        if any(b -> any(k -> startswith(k, "_:"), keys(b)), bindings)
            bindings = [Dict{String,Identifier}(k => v for (k, v) in b if !startswith(k, "_:")) for b in bindings]
        end
    end

    # DISTINCT eliminates duplicates. REDUCED *permits but does not require*
    # duplicate elimination (SPARQL 1.1 §18.2.1); we keep all rows, which is a
    # conforming choice and matches the W3C REDUCED reference results.
    q.distinct && (bindings = unique(bindings))

    # OFFSET + LIMIT (skipped above when can_slice_first)
    if !can_slice_first
        start = q.offset + 1
        stop = isnothing(q.limit) ? length(bindings) : min(start + q.limit - 1, length(bindings))
        bindings = start <= length(bindings) ? bindings[start:stop] : Dict{String,Identifier}[]
    end
    bindings
end

function _ast_evaluate(g::RDFGraph, q::SparqlAsk)
    _ACTIVE_BASE[] = get(q.prefixes, "@base", nothing)
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
    # Repeated variables (?s ?p ?s etc.) constrain matches — no fast path
    (p.subject == p.predicate || p.subject == p.object || p.predicate == p.object) && return false
    agg = q.aggregates[1].agg
    agg isa ExprAggregate || return false
    agg.func == "COUNT" || return false
    agg.distinct && return false
    agg.arg isa ExprStar || return false
    true
end

function _ast_evaluate(g::RDFGraph, q::SparqlConstruct)
    _ACTIVE_BASE[] = get(q.prefixes, "@base", nothing)
    # Push LIMIT into pattern evaluation only when there's no ORDER BY
    # (ORDER BY must see all solutions before LIMIT/OFFSET apply)
    has_order = !isempty(q.order_by)
    push_limit = (isnothing(q.limit) || has_order) ? 0 : q.offset + q.limit
    bindings = _ast_eval_patterns(g, q.patterns; limit=push_limit)
    if has_order
        sort!(bindings, lt=(a, b) -> _ast_order_compare(a, b, q.order_by, g))
    end
    # Apply LIMIT/OFFSET to bindings before constructing
    start = q.offset + 1
    stop = isnothing(q.limit) ? length(bindings) : min(start + q.limit - 1, length(bindings))
    bindings = start <= length(bindings) ? bindings[start:stop] : Dict{String,Identifier}[]
    result = RDFGraph()
    for b in bindings
        template_bnodes = Dict{String,BNode}()
        for pt in q.template
            s = _resolve_template_term(pt.subject, b, template_bnodes)
            p = _resolve_template_term(pt.predicate, b, template_bnodes)
            o = _resolve_template_term(pt.object, b, template_bnodes)
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
    _ACTIVE_BASE[] = get(q.prefixes, "@base", nothing)
    if isempty(q.terms)
        # DESCRIBE * — every triple's subject is described, so the result is
        # the whole graph; a single pass suffices (no per-subject scans).
        result = RDFGraph()
        for t in triples(g)
            add!(result, t)
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
    # Indexed lookup on the subject position (no full scan per node)
    for t in triples(g, (node, nothing, nothing))
        add!(result, t)
        t.object isa BNode && _cbd!(result, g, t.object, visited)
    end
end

# ─── Pattern evaluation ───────────────────────────────────────────

# FILTER applies to the whole group it appears in, not at its syntactic
# position (SPARQL §17.2). Move all PatFilter / PatFilterExists patterns to
# the end of the group, preserving their relative order. Nested groups
# (OPTIONAL, UNION, ...) are evaluated through their own _ast_eval_patterns
# call, so their internal filter scope is preserved.
function _hoist_filters(patterns::Vector{SparqlPattern})
    seen_filter = false
    needs = false
    for p in patterns
        if p isa PatFilter || p isa PatFilterExists
            seen_filter = true
        elseif seen_filter
            needs = true
            break
        end
    end
    needs || return patterns
    nonf = SparqlPattern[]
    fs = SparqlPattern[]
    for p in patterns
        (p isa PatFilter || p isa PatFilterExists) ? push!(fs, p) : push!(nonf, p)
    end
    append!(nonf, fs)
end

# A blank node appearing in a query graph pattern acts as a non-distinguished
# variable (SPARQL 1.1 §4.1.4). Rewrite each BNode term to an internal variable
# name "_:<label>" (the existing convention for parser-generated bnode vars,
# which are dropped from SELECT *). The transform is idempotent and only
# allocates when a pattern actually contains a blank node.
@inline _bn_to_var(t) = t isa BNode ? "_:" * t.id : t

function _rewrite_query_bnodes(patterns::Vector{SparqlPattern})
    any(_pattern_has_bnode, patterns) || return patterns
    SparqlPattern[_rewrite_pattern_bnodes(p) for p in patterns]
end

_pattern_has_bnode(p::PatTriple) =
    p.subject isa BNode || p.predicate isa BNode || p.object isa BNode
_pattern_has_bnode(p::PatOptional) = any(_pattern_has_bnode, p.patterns)
_pattern_has_bnode(p::PatMinus) = any(_pattern_has_bnode, p.patterns)
_pattern_has_bnode(p::PatGraph) = any(_pattern_has_bnode, p.patterns)
_pattern_has_bnode(p::PatUnion) = any(b -> any(_pattern_has_bnode, b), p.branches)
_pattern_has_bnode(p::PatFilterExists) = any(_pattern_has_bnode, p.patterns)
_pattern_has_bnode(p::PatGroup) = any(_pattern_has_bnode, p.patterns)
_pattern_has_bnode(p) = false

_rewrite_pattern_bnodes(p::PatTriple) =
    PatTriple(_bn_to_var(p.subject), _bn_to_var(p.predicate), _bn_to_var(p.object))
_rewrite_pattern_bnodes(p::PatOptional) =
    PatOptional(SparqlPattern[_rewrite_pattern_bnodes(x) for x in p.patterns])
_rewrite_pattern_bnodes(p::PatMinus) =
    PatMinus(SparqlPattern[_rewrite_pattern_bnodes(x) for x in p.patterns])
_rewrite_pattern_bnodes(p::PatGraph) =
    PatGraph(p.graph_term, SparqlPattern[_rewrite_pattern_bnodes(x) for x in p.patterns])
_rewrite_pattern_bnodes(p::PatUnion) =
    PatUnion(Vector{SparqlPattern}[SparqlPattern[_rewrite_pattern_bnodes(x) for x in b] for b in p.branches])
_rewrite_pattern_bnodes(p::PatFilterExists) =
    PatFilterExists(SparqlPattern[_rewrite_pattern_bnodes(x) for x in p.patterns], p.negated)
_rewrite_pattern_bnodes(p::PatGroup) =
    PatGroup(SparqlPattern[_rewrite_pattern_bnodes(x) for x in p.patterns])
_rewrite_pattern_bnodes(p) = p

function _ast_eval_patterns(g::RDFGraph, patterns::Vector{SparqlPattern},
                             bindings::Vector{Dict{String,Identifier}} = Dict{String,Identifier}[Dict{String,Identifier}()];
                             limit::Int = 0)
    patterns = _rewrite_query_bnodes(patterns)
    patterns = _hoist_filters(patterns)
    # Ensure store indices are built before querying
    if g.store isa MemoryStore
        _ensure_all_indexed!(g.store)
    elseif g.store isa EncodedStore
        _ensure_all_indexed!(g.store)
    end
    # Star-join optimization for MemoryStore
    if g.store isa MemoryStore && length(patterns) >= 2
        if length(bindings) == 1 && isempty(bindings[1])
            patterns = _reorder_star_groups(g.store::MemoryStore, patterns)
        end
        return _ast_eval_patterns_star(g, patterns, bindings, limit)
    end
    # Star-join optimization for EncodedStore (encoded fast path)
    if g.store isa EncodedStore && length(patterns) >= 2
        if length(bindings) == 1 && isempty(bindings[1])
            patterns = _reorder_star_groups_encoded(g.store::EncodedStore, patterns)
        end
        return _ast_eval_patterns_star_encoded(g, patterns, bindings, limit)
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
        # Recognise both multi-triple star groups AND single PatTriples as
        # reorderable units (a single triple is a 1-predicate star group).
        pat = patterns[i]
        if !(pat isa PatTriple) || !(pat.subject isa String) ||
           !(pat.predicate isa URIRef)
            break
        end
        send = _star_group_end(patterns, i)
        # Subject variable + all object variables produced
        produced = Set{String}()
        consumed = Set{String}()
        @inbounds for k in i:send
            p = patterns[k]::PatTriple
            s = p.subject; s isa String && (push!(produced, s); push!(consumed, s))
            o = p.object;  o isa String && (push!(produced, o); push!(consumed, o))
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
    # Triple-term object patterns may contain variables and need the general
    # matcher; exclude them from star-join grouping.
    pat.object isa TripleTermPattern && return start
    last = start
    for j in (start+1):length(patterns)
        next = patterns[j]
        next isa PatTriple || break
        next.subject isa String || break
        next.subject == subj || break
        next.predicate isa URIRef || break
        next.object isa TripleTermPattern && break
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
    # Cache the first element of each obj_set to avoid double `first(::Set)`
    # (each call walks the Set's underlying Dict slots).
    obj_firsts = Vector{Identifier}(undef, n)

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
                         obj_sets, obj_firsts, n, limit)
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
                                 obj_sets, obj_firsts, n, limit)
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
                                 obj_sets, obj_firsts, n, limit)
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
                               obj_sets, obj_firsts, n, limit)
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
        # Cache `first(obj_sets[i])` once — calling it walks the underlying
        # Dict slot vector which is a measurable hot-spot for 1-elem Sets.
        @inbounds for i in 1:n
            obj_firsts[i] = first(obj_sets[i])
        end
        # Pre-validate: check bound terms and pre-bound vars match BEFORE allocating.
        # Defer Dict copy until we know the row will be emitted.
        sv = get(b, subj_var, nothing)
        sv === nothing || sv == s || return
        @inbounds for i in 1:n
            obj = obj_firsts[i]
            pat_obj = pats[i].object
            if pat_obj isa String
                # Variable: check pre-existing binding (in `b`)
                bv = get(b, pat_obj, nothing)
                bv === nothing || bv == obj || return
                # Subject var reused in object position (?x :p ?x)
                pat_obj == subj_var && obj != s && return
                # Same var repeated across the star group (?s :p ?x . ?s :q ?x)
                for j in 1:i-1
                    pj = pats[j].object
                    if pj isa String && pj == pat_obj && obj_firsts[j] != obj
                        return
                    end
                end
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
            pat_obj = pats[i].object
            if pat_obj isa String
                # Bind if not already bound (pre-validated to match if it was)
                haskey(new_b, pat_obj) || (new_b[pat_obj] = obj_firsts[i])
            end
        end
        push!(results, new_b)
    else
        # Multi-valued predicates: cross-product (rare)
        sv = get(b, subj_var, nothing)
        sv === nothing || sv == s || return
        new_b = copy(b)
        new_b[subj_var] = s
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
    sv = get(b, subj_var, nothing)
    sv === nothing || sv == s || return
    if all_single
        new_b = copy(b)
        new_b[subj_var] = s
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
        new_b[subj_var] = s
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

function _ast_eval_pattern(g::RDFGraph, pat::PatGroup, bindings)
    isempty(bindings) && return bindings
    # Evaluate the group body as its own algebra unit (empty seed) so FILTERs
    # inside it are scoped to the group's own solutions, then inner-join the
    # result with the incoming bindings on shared variables.
    group_results = _ast_eval_patterns(g, pat.patterns)
    isempty(group_results) && return Dict{String,Identifier}[]
    out = Dict{String,Identifier}[]
    for b in bindings
        for gr in group_results
            merged = _ast_merge_compatible(b, gr)
            merged === nothing || push!(out, merged)
        end
    end
    out
end

# Merge two solution mappings if they agree on all shared variables, returning
# the merged mapping, or `nothing` if they are incompatible.
function _ast_merge_compatible(a::Dict{String,Identifier}, b::Dict{String,Identifier})
    merged = copy(a)
    for (k, v) in b
        if haskey(merged, k)
            merged[k] == v || return nothing
        else
            merged[k] = v
        end
    end
    merged
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
        # The bound-join trick is only sound when every outer row binds all
        # shared vars: an outer row with an unbound shared var would be
        # re-emitted bare even when extensions of it exist (duplicates).
        if !isempty(shared) && length(shared) <= 2 &&
           all(b -> all(v -> haskey(b, v), shared), bindings)
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

# True iff every pattern in `patterns` only reads its input bindings (does not
# mutate them in place). PatTriple/PatFilter are read-only; PatBind/PatValues
# can write, and nested PatOptional/PatGraph etc. could too — be conservative.
function _patterns_readonly(patterns::Vector{SparqlPattern})
    for p in patterns
        (p isa PatTriple || p isa PatFilter) || return false
    end
    return true
end

# Bound-join: evaluate inner with outer bindings as constraints, then add
# unmatched outer rows back (LEFT JOIN semantics).
function _opt_bound_join(g::RDFGraph, patterns::Vector{SparqlPattern},
                          outer::Vector{Dict{String,Identifier}},
                          shared::Vector{String})
    # If inner patterns are read-only w.r.t. bindings (no PatBind/PatValues),
    # we can pass outer directly; otherwise copy to avoid mutating outer rows.
    inner_input = if _patterns_readonly(patterns)
        outer
    else
        [copy(b) for b in outer]
    end
    matched = _ast_eval_patterns(g, patterns, inner_input)

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
        _collect_term_vars!(out, p.subject)
        _collect_term_vars!(out, p.predicate)
        _collect_term_vars!(out, p.object)
    elseif p isa PatBind
        push!(out, p.var)
    elseif p isa PatValues
        for v in p.variables; push!(out, v); end
    elseif p isa PatGroup
        for q in p.patterns; _collect_produced_vars!(out, q); end
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

# Collect variable names appearing in a term (handles nested triple-term
# patterns recursively).
function _collect_term_vars!(out::Set{String}, term)
    if term isa String
        push!(out, term)
    elseif term isa TripleTermPattern
        _collect_term_vars!(out, term.subject)
        _collect_term_vars!(out, term.predicate)
        _collect_term_vars!(out, term.object)
    end
end

function _collect_expr_vars!(out::Vector{String}, p::SparqlPattern)
    if p isa PatFilter
        _collect_vars_in_expr!(out, p.expr)
    elseif p isa PatBind
        _collect_vars_in_expr!(out, p.expr)
    elseif p isa PatGroup
        for q in p.patterns; _collect_expr_vars!(out, q); end
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
        _collect_vars_in_expr!(out, e.arg)
    elseif e isa ExprFunctionCall
        for a in e.args; _collect_vars_in_expr!(out, a); end
    elseif e isa ExprIn
        _collect_vars_in_expr!(out, e.expr)
        for a in e.values; _collect_vars_in_expr!(out, a); end
    elseif e isa ExprAggregate
        _collect_vars_in_expr!(out, e.arg)
    elseif e isa ExprExists
        # Variables mentioned anywhere inside EXISTS{...} patterns are
        # references to the enclosing scope for safety analysis.
        for p in e.patterns
            p isa SparqlPattern || continue
            produced = Set{String}()
            _collect_produced_vars!(produced, p)
            append!(out, produced)
            _collect_expr_vars!(out, p)
        end
    end
end

# Hash-join: join `lhs` with `rhs` on shared variables.
# `left=true` gives OPTIONAL (left outer) semantics: an LHS row with no
# compatible RHS row is emitted unchanged. RHS/LHS rows missing a shared
# variable are still compatible (the unbound side imposes no constraint) and
# are joined via a nested-loop fallback rather than dropped.
function _ast_hash_join(lhs::Vector{Dict{String,Identifier}},
                        rhs::Vector{Dict{String,Identifier}};
                        left::Bool)
    if isempty(rhs) || isempty(lhs)
        return left ? lhs : Dict{String,Identifier}[]
    end

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

    nshared = length(shared)
    single = nshared == 1
    sv = shared[1]

    # Index RHS rows that bind ALL shared vars; rows missing any shared var
    # are compatible with every LHS row on that var → handle via `loose`.
    idx1 = single ? Dict{Identifier,Vector{Dict{String,Identifier}}}() : nothing
    idxN = single ? nothing : Dict{Tuple,Vector{Dict{String,Identifier}}}()
    loose = Dict{String,Identifier}[]
    for r in rhs
        if single
            v = get(r, sv, nothing)
            if v === nothing
                push!(loose, r)
            else
                push!(get!(() -> Dict{String,Identifier}[], idx1, v), r)
            end
        else
            ok = true
            key_vals = Vector{Identifier}(undef, nshared)
            for (i, k) in enumerate(shared)
                v = get(r, k, nothing)
                v === nothing && (ok = false; break)
                key_vals[i] = v
            end
            if ok
                push!(get!(() -> Dict{String,Identifier}[], idxN, Tuple(key_vals)), r)
            else
                push!(loose, r)
            end
        end
    end

    out = Dict{String,Identifier}[]
    sizehint!(out, length(lhs))
    for l in lhs
        matched = false
        ok = true
        local key
        if single
            v = get(l, sv, nothing)
            ok = v !== nothing
            ok && (key = v)
        else
            key_vals = Vector{Identifier}(undef, nshared)
            for (i, k) in enumerate(shared)
                v = get(l, k, nothing)
                v === nothing && (ok = false; break)
                key_vals[i] = v
            end
            ok && (key = Tuple(key_vals))
        end
        if ok
            matches = single ? get(idx1, key, nothing) : get(idxN, key, nothing)
            if matches !== nothing
                for m in matches
                    push!(out, merge(l, m))
                end
                matched = true
            end
            for m in loose
                if _ast_compatible(l, m)
                    push!(out, merge(l, m))
                    matched = true
                end
            end
        else
            # LHS row missing a shared var: compatible with any RHS row that
            # agrees on the remaining vars — general nested-loop path.
            for m in rhs
                if _ast_compatible(l, m)
                    push!(out, merge(l, m))
                    matched = true
                end
            end
        end
        (left && !matched) && push!(out, l)
    end
    out
end

_ast_left_join(lhs, rhs) = _ast_hash_join(lhs, rhs; left=true)

function _ast_eval_pattern(g::RDFGraph, pat::PatUnion, bindings)
    # Evaluate each branch ONCE against the full input binding set (not
    # per-outer-row, which is quadratic).
    new_bindings = Dict{String,Identifier}[]
    for branch in pat.branches
        seeds = Dict{String,Identifier}[copy(b) for b in bindings]
        append!(new_bindings, _ast_eval_patterns(g, branch, seeds))
    end
    new_bindings
end

function _ast_eval_pattern(g::RDFGraph, pat::PatMinus, bindings)
    inner = _ast_eval_patterns(g, pat.patterns)
    isempty(inner) && return bindings
    # Inverted index (var,value) → inner row ids: avoids O(n*m) nested loops.
    inv = Dict{Tuple{String,Identifier},Vector{Int}}()
    for (i, ib) in enumerate(inner)
        for (k, v) in ib
            push!(get!(() -> Int[], inv, (k, v)), i)
        end
    end
    filter(bindings) do b
        for (k, v) in b
            ids = get(inv, (k, v), nothing)
            ids === nothing && continue
            for i in ids
                _ast_compatible_shared(b, inner[i]) && return false
            end
        end
        true
    end
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
    # Hash join on shared vars (inner join semantics)
    _ast_hash_join(bindings, sub_results; left=false)
end

# ─── GRAPH pattern evaluation ─────────────────────────────────────
#
# GRAPH evaluates against the *named graphs* of the queried dataset. When a
# Dataset / ConjunctiveGraph is queried (via sparql_query(ds, ...)), the
# dataset is made available here through a dynamically-scoped reference.
# A plain RDFGraph has no named graphs, so GRAPH <iri> / GRAPH ?g yield zero
# solutions per the SPARQL spec.

const _ACTIVE_DATASET = Base.RefValue{Any}(nothing)       # Union{Dataset,Nothing}
const _ACTIVE_NAMED_FILTER = Base.RefValue{Any}(nothing)  # Union{Nothing,Set} (FROM NAMED)
# The query's BASE IRI (from a `BASE <…>` prologue), used by IRI()/URI() to
# resolve relative references at evaluation time. `nothing` when no BASE given.
const _ACTIVE_BASE = Base.RefValue{Union{String,Nothing}}(nothing)

# Named graphs visible to GRAPH patterns: `nothing` when no dataset is
# active (plain RDFGraph), otherwise name => graph pairs honoring any
# FROM NAMED restriction.
function _active_named_graphs()
    ds = _ACTIVE_DATASET[]
    ds === nothing && return nothing
    ds = ds::Dataset
    filt = _ACTIVE_NAMED_FILTER[]
    filt === nothing && return ds.named_graphs
    Dict{GraphName,RDFGraph}(k => v for (k, v) in ds.named_graphs if k in filt)
end

function _ast_eval_pattern(g::RDFGraph, pat::PatGraph, bindings)
    named = _active_named_graphs()
    # Plain RDFGraph (no dataset): GRAPH matches nothing (spec semantics)
    named === nothing && return Dict{String,Identifier}[]
    gt = pat.graph_term
    out = Dict{String,Identifier}[]
    if gt isa ExprURI
        ng = get(named, gt.uri, nothing)
        ng === nothing && return out
        return _ast_eval_patterns(ng, pat.patterns, Dict{String,Identifier}[copy(b) for b in bindings])
    elseif gt isa ExprVar
        var = gt.name
        for (name, ng) in named
            seeds = Dict{String,Identifier}[]
            for b in bindings
                ex = get(b, var, nothing)
                if ex === nothing
                    nb = copy(b)
                    nb[var] = name
                    push!(seeds, nb)
                elseif ex == name
                    push!(seeds, copy(b))
                end
            end
            isempty(seeds) && continue
            append!(out, _ast_eval_patterns(ng, pat.patterns, seeds))
        end
        return out
    end
    out
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
    if isnothing(endpoint_uri)
        pat.silent && return bindings
        error("SERVICE: endpoint is not a bound IRI")
    end

    # Serialize the SERVICE block (FILTER/BIND/OPTIONAL/UNION included) into
    # remote query text. Unserializable patterns raise unless SILENT.
    remote_query = try
        _ast_build_service_query(pat.patterns)
    catch e
        pat.silent && return bindings
        rethrow(e)
    end

    try
        store = SPARQLStore(endpoint_uri)
        cached = _service_cache_lookup(endpoint_uri, remote_query)
        remote_results = if !isnothing(cached)
            cached
        else
            res = _remote_select(store, remote_query)
            _service_cache_store!(endpoint_uri, remote_query, res)
            res
        end
        # Join local bindings with remote results. An empty remote result
        # produces an empty join (NOT a pass-through of local bindings).
        new_bindings = Dict{String,Identifier}[]
        for b in bindings
            for rr in remote_results
                _ast_compatible(b, rr) && push!(new_bindings, merge(b, rr))
            end
        end
        new_bindings
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
    if g.store isa EncodedStore
        return _ast_eval_bgp_encoded(g.store, pat, binding, s_val, p_val, o_val)
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
        # Repeated-variable guard: skip rows before allocating the binding copy
        so_same = pat.subject isa String && pat.subject == pat.object
        po = get(store.pos, p_val, nothing)
        if !isnothing(po)
            for (o, subjs) in po
                for s in subjs
                    so_same && s != o && continue
                    new_b = copy(binding)
                    ok = _ast_match_term(s, pat.subject, s_val, new_b)
                    ok && (ok = _ast_match_term(o, pat.object, o_val, new_b))
                    ok && push!(results, new_b)
                end
            end
        end
    elseif o_bound
        # ? ? O — iterate subject-predicate pairs from OSP
        sp_same = pat.subject isa String && pat.subject == pat.predicate
        os = get(store.osp, o_val, nothing)
        if !isnothing(os)
            for (s, preds) in os
                for p in preds
                    sp_same && s != p && continue
                    new_b = copy(binding)
                    ok = _ast_match_term(s, pat.subject, s_val, new_b)
                    ok && (ok = _ast_match_term(p, pat.predicate, p_val, new_b))
                    ok && push!(results, new_b)
                end
            end
        end
    else
        # ? ? ? — iterate all triples
        so_same = pat.subject isa String && pat.subject == pat.object
        sp_same = pat.subject isa String && pat.subject == pat.predicate
        po_same = pat.predicate isa String && pat.predicate == pat.object
        for t in store.insertion_order
            so_same && t.subject != t.object && continue
            sp_same && t.subject != t.predicate && continue
            po_same && t.predicate != t.object && continue
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
    elseif pattern isa TripleTermPattern
        # Match a triple-term pattern against a TripleTerm graph value,
        # binding nested variables.
        graph_val isa TripleTerm || return false
        ok = _ast_match_term(graph_val.subject, pattern.subject,
                             _ast_resolve_term(pattern.subject, binding), binding)
        ok || return false
        ok = _ast_match_term(graph_val.predicate, pattern.predicate,
                             _ast_resolve_term(pattern.predicate, binding), binding)
        ok || return false
        return _ast_match_term(graph_val.object, pattern.object,
                               _ast_resolve_term(pattern.object, binding), binding)
    else
        return !isnothing(resolved) && resolved == graph_val
    end
end

function _ast_resolve_term(term, binding::Dict{String,Identifier})
    if term isa String  # variable
        return get(binding, term, nothing)
    end
    if term isa URIRef || term isa Literal || term isa BNode || term isa TripleTerm
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
    if term isa TripleTermPattern
        # Resolve recursively; all three components must be bound to concrete
        # terms and form a valid RDF-star triple term.
        s = _ast_resolve_term(term.subject, binding)
        p = _ast_resolve_term(term.predicate, binding)
        o = _ast_resolve_term(term.object, binding)
        (isnothing(s) || isnothing(p) || isnothing(o)) && return nothing
        (s isa Node && p isa URIRef && o isa Identifier) || return nothing
        return TripleTerm(s, p, o)
    end
    nothing
end

function _resolve_template_term(term, binding::Dict{String,Identifier},
                                template_bnodes::Dict{String,BNode})
    if term isa BNode
        return get!(template_bnodes, term.id) do
            BNode()
        end
    end
    if term isa ExprBNode
        return get!(template_bnodes, term.node.id) do
            BNode()
        end
    end
    return _ast_resolve_term(term, binding)
end

# ─── Property path evaluation ─────────────────────────────────────

function _ast_eval_path_bgp(g::RDFGraph, s_val, path::PathExpr, o_val, pat::PatTriple, binding)
    s_var = pat.subject isa String ? pat.subject : nothing
    o_var = pat.object isa String ? pat.object : nothing

    # Note: a literal start is allowed (zero-length paths and inverse paths
    # can have literal endpoints per spec)
    pairs = _ast_eval_path(g, path, s_val isa Identifier ? s_val : nothing,
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

# Path evaluation. `start`/`target` are bound endpoints (or nothing).
# Pairs are (subject-endpoint, object-endpoint); both slots are Identifier
# because zero-length and inverse paths can have literal endpoints.
const _PathPair = Tuple{Identifier,Identifier}

function _ast_eval_path(g::RDFGraph, path::PathURI, start::Union{Identifier,Nothing}, target::Union{Identifier,Nothing})
    results = _PathPair[]
    # A literal cannot be the subject of a triple
    (start !== nothing && !(start isa Node)) && return results
    s_pat = start isa Node ? start : nothing
    o_pat = target isa Identifier ? target : nothing
    # Index-backed lookup: never full-scan when an endpoint is bound
    for t in triples(g, (s_pat, path.uri, o_pat))
        push!(results, (t.subject, t.object))
    end
    results
end

function _ast_eval_path(g::RDFGraph, path::PathSequence, start::Union{Identifier,Nothing}, target::Union{Identifier,Nothing})
    isempty(path.steps) && return _PathPair[]
    _ast_eval_path_chain(g, path.steps, start, target)
end

function _ast_eval_path_chain(g::RDFGraph, steps::Vector{PathExpr}, start, target)
    if length(steps) == 1
        return _ast_eval_path(g, steps[1], start, target)
    end
    first_results = _ast_eval_path(g, steps[1], start, nothing)
    results = _PathPair[]
    rest_cache = Dict{Identifier,Vector{_PathPair}}()
    for (s, mid) in first_results
        rest = get!(rest_cache, mid) do
            _ast_eval_path_chain(g, steps[2:end], mid, target)
        end
        for (_, o) in rest
            push!(results, (s, o))
        end
    end
    # Fixed-length paths (sequence) yield a multiset — duplicates from distinct
    # intermediate nodes are preserved (SPARQL 1.1 §18.4 / §9.3).
    results
end

function _ast_eval_path(g::RDFGraph, path::PathAlternative, start::Union{Identifier,Nothing}, target::Union{Identifier,Nothing})
    # Alternative is a fixed-length path: duplicates across branches are kept.
    results = _PathPair[]
    for option in path.options
        append!(results, _ast_eval_path(g, option, start, target))
    end
    results
end

function _ast_eval_path(g::RDFGraph, path::PathInverse, start::Union{Identifier,Nothing}, target::Union{Identifier,Nothing})
    # x ^p y  ⇔  y p x: evaluate inner path with endpoints swapped, then
    # reverse the pairs. The inverse-path subject may be a literal.
    (target !== nothing && !(target isa Node)) && return _PathPair[]
    inner = _ast_eval_path(g, path.path, target, start)
    results = _PathPair[]
    for (s, o) in inner
        push!(results, (o, s))
    end
    results
end

function _ast_eval_path(g::RDFGraph, path::PathZeroOrMore, start::Union{Identifier,Nothing}, target::Union{Identifier,Nothing})
    _ast_eval_path_closure(g, path.path, start, target, include_zero=true)
end

function _ast_eval_path(g::RDFGraph, path::PathOneOrMore, start::Union{Identifier,Nothing}, target::Union{Identifier,Nothing})
    _ast_eval_path_closure(g, path.path, start, target, include_zero=false)
end

function _ast_eval_path(g::RDFGraph, path::PathZeroOrOne, start::Union{Identifier,Nothing}, target::Union{Identifier,Nothing})
    results = _ast_eval_path(g, path.path, start, target)
    # Add zero-length (identity) matches; literal endpoints included per spec
    if !isnothing(start)
        if isnothing(target) || target == start
            push!(results, (start, start))
        end
    elseif !isnothing(target)
        push!(results, (target, target))
    else
        for term in _path_graph_terms(g)
            push!(results, (term, term))
        end
    end
    unique(results)
end

# All terms occurring in the graph (subjects and objects, incl. literals) —
# the candidate set for zero-length path endpoints.
function _path_graph_terms(g::RDFGraph)
    terms = Set{Identifier}()
    for t in triples(g)
        push!(terms, t.subject)
        push!(terms, t.object)
    end
    terms
end

function _ast_eval_path_closure(g::RDFGraph, path::PathExpr, start::Union{Identifier,Nothing},
                                 target::Union{Identifier,Nothing}; include_zero::Bool=false)
    results = _PathPair[]
    if !isnothing(start)
        # BFS from start
        if include_zero && (isnothing(target) || target == start)
            push!(results, (start, start))
        end
        visited = Set{Identifier}()
        queue = Identifier[start]
        while !isempty(queue)
            current = popfirst!(queue)
            current in visited && continue
            push!(visited, current)
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
        # All terms as starting points (literals only contribute zero-length)
        for term in _path_graph_terms(g)
            if term isa Node
                append!(results, _ast_eval_path_closure(g, path, term, target, include_zero=include_zero))
            elseif include_zero && (isnothing(target) || target == term)
                push!(results, (term, term))
            end
        end
        # A bound target is itself a valid zero-length endpoint even when it does
        # not occur in the graph (e.g. `?s :p* :o` on an empty graph → `:o`).
        if include_zero && target !== nothing
            push!(results, (target, target))
        end
    end
    unique(results)
end

function _ast_eval_path(g::RDFGraph, path::PathNegatedSet, start::Union{Identifier,Nothing}, target::Union{Identifier,Nothing})
    # Per SPARQL 1.1: !(p1|...|^q1|...) ≡ !(p1|...) UNION ^(!(q1|...)).
    # The forward component exists when there are forward members or the set
    # has no inverse members; the inverse component exists when there are
    # inverse members (matching reverse edges whose predicate is excluded
    # from the inverse member set).
    results = _PathPair[]
    if !isempty(path.uris) || isempty(path.inverse)
        excluded = Set(path.uris)
        if start === nothing || start isa Node
            s_pat = start isa Node ? start : nothing
            for t in triples(g, (s_pat, nothing, target))
                t.predicate in excluded && continue
                push!(results, (t.subject, t.object))
            end
        end
    end
    if !isempty(path.inverse)
        excluded_inv = Set(path.inverse)
        # Reverse edges: pair (a, b) where b q a — subject pattern is the
        # target endpoint, object pattern the start endpoint.
        if target === nothing || target isa Node
            t_pat = target isa Node ? target : nothing
            for t in triples(g, (t_pat, nothing, start))
                t.predicate in excluded_inv && continue
                push!(results, (t.object, t.subject))
            end
        end
    end
    unique(results)
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

function _ast_eval_expr(expr::TripleTermPattern, binding::Dict{String,Identifier}, g::RDFGraph=RDFGraph())
    # SPARQL 1.2 triple term `<<( s p o )>>` used in an expression (e.g. BIND).
    # Yields a TripleTerm when all parts resolve to terms forming a valid
    # triple term, otherwise unbound (nothing).
    _ast_resolve_term(expr, binding)
end

function _ast_eval_expr(expr::ExprBinaryOp, binding::Dict{String,Identifier}, g::RDFGraph=RDFGraph())
    # Logical operators use three-valued error semantics (SPARQL §17.2):
    #   error || true  → true     error || false → error
    #   error && false → false    error && true  → error
    if expr.op == :||
        l = _ast_ebv(_ast_eval_expr(expr.left, binding, g))
        l === true && return Literal(true)
        r = _ast_ebv(_ast_eval_expr(expr.right, binding, g))
        r === true && return Literal(true)
        (l === false && r === false) && return Literal(false)
        return nothing
    elseif expr.op == :&&
        l = _ast_ebv(_ast_eval_expr(expr.left, binding, g))
        l === false && return Literal(false)
        r = _ast_ebv(_ast_eval_expr(expr.right, binding, g))
        r === false && return Literal(false)
        (l === true && r === true) && return Literal(true)
        return nothing
    end

    left = _ast_eval_expr(expr.left, binding, g)
    right = _ast_eval_expr(expr.right, binding, g)
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
        b = _ast_ebv(val)
        b === nothing && return nothing  # !error → error (row fails)
        return Literal(!b)
    elseif expr.op == :-
        tn = _typed_numeric(val)
        tn === nothing && return nothing
        return _numeric_literal(tn[1], -tn[2])
    elseif expr.op == :+
        return _typed_numeric(val) === nothing ? nothing : val
    end
    nothing
end

function _ast_eval_expr(expr::ExprIn, binding::Dict{String,Identifier}, g::RDFGraph=RDFGraph())
    # IN is equivalent to (expr = v1 || expr = v2 || ...) with `||` error
    # semantics; NOT IN is its negation (SPARQL §17.4.1.9/10).
    val = _ast_eval_expr(expr.expr, binding, g)
    isnothing(val) && return nothing
    err = false
    for v in expr.values
        ev = _ast_eval_expr(v, binding, g)
        if ev === nothing
            err = true
            continue
        end
        r = _ast_term_eq(val, ev)
        if r === nothing
            err = true
        elseif r
            return Literal(!expr.negated)
        end
    end
    err && return nothing
    Literal(expr.negated)
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
        # Each argument must be a string/langString literal (a type error
        # otherwise → unbound). If every argument shares the same language tag
        # the result carries it; if all are simple/xsd:string the result is a
        # simple literal; otherwise the result is a simple literal.
        vals = Identifier[]
        for i in 1:length(args)
            v = _eval_arg(i)
            isnothing(v) && return nothing
            _is_str_or_lang_lit(v) || return nothing
            push!(vals, v)
        end
        lex = join(v.lexical for v in vals)
        if !isempty(vals)
            lang1 = vals[1].language
            dir1 = vals[1].direction
            if lang1 !== nothing && all(v -> v.language == lang1, vals)
                # Preserve the language tag only if every argument also shares
                # the same base direction (including all having none); otherwise
                # the result is a plain string.
                if all(v -> v.direction == dir1, vals)
                    return dir1 === nothing ? Literal(lex; lang=lang1) :
                                              Literal(lex; lang=lang1, direction=dir1)
                end
            end
        end
        return Literal(lex)
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
        _str_args_compatible(s, p) || return nothing
        ss = s.lexical; pp = p.lexical
        isempty(pp) && return _str_like("", s)           # empty needle → "" (arg1 lang)
        idx = findfirst(pp, ss)
        isnothing(idx) && return Literal("")             # not found → "" (plain)
        return _str_like(ss[1:prevind(ss, first(idx))], s)
    elseif name == "STRAFTER"
        s = _eval_arg(1); p = _eval_arg(2)
        (isnothing(s) || isnothing(p)) && return nothing
        _str_args_compatible(s, p) || return nothing
        ss = s.lexical; pp = p.lexical
        isempty(pp) && return _str_like(ss, s)           # empty needle → arg1 unchanged
        idx = findfirst(pp, ss)
        isnothing(idx) && return Literal("")             # not found → "" (plain)
        return _str_like(ss[last(idx)+1:end], s)
    elseif name == "SUBSTR"
        val = _eval_arg(1)
        isnothing(val) && return nothing
        _is_str_or_lang_lit(val) || return nothing
        s = val.lexical
        start_v = _eval_arg(2)
        isnothing(start_v) && return nothing
        # SUBSTR uses 1-based codepoint indexing per XPath fn:substring.
        si_f = _ast_to_numeric(start_v)
        isnothing(si_f) && return nothing
        si = round(Int, si_f)
        n = length(s)  # number of codepoints
        if length(args) >= 3
            len_v = _eval_arg(3)
            len_f = _ast_to_numeric(len_v)
            isnothing(len_f) && return nothing
            len = round(Int, len_f)
            # XPath semantics: characters at positions >= si and < si+len.
            lo = max(si, 1)
            hi = min(si + len - 1, n)
            return _str_like(_substr_chars(s, lo, hi), val)
        end
        lo = max(si, 1)
        return _str_like(_substr_chars(s, lo, n), val)
    elseif name == "REPLACE"
        val = _eval_arg(1)
        isnothing(val) && return nothing
        _is_str_or_lang_lit(val) || return nothing
        pat = _eval_arg(2); rep = _eval_arg(3)
        (isnothing(pat) || isnothing(rep)) && return nothing
        flags = length(args) >= 4 ? _ast_str(_eval_arg(4)) : ""
        rx = _ast_make_regex(_ast_str(pat), flags)
        rep_str = replace(_ast_str(rep), r"\$(\d)" => s"\\\1")  # $N → \N (Julia capture refs)
        return _str_like(replace(val.lexical, rx => SubstitutionString(rep_str)), val)
    elseif name == "ENCODE_FOR_URI"
        val = _eval_arg(1)
        return isnothing(val) ? nothing : Literal(_uri_encode(_ast_str(val)))

    # ── RDF term functions ──
    elseif name == "LANG"
        val = _eval_arg(1)
        # LANG is only defined on literals; on an IRI/blank node it is a type
        # error (→ unbound), distinct from a literal with no tag (→ "").
        val isa Literal || return nothing
        return Literal(something(val.language, ""))
    elseif name == "DATATYPE"
        val = _eval_arg(1)
        val isa Literal || return nothing
        # Per SPARQL/RDF 1.1: simple literals have datatype xsd:string,
        # language-tagged literals rdf:langString (rdf:dirLangString when a
        # base direction is present).
        if !isnothing(val.language)
            return isnothing(val.direction) ? _RDF_LANGSTRING_DT : _RDF_DIRLANGSTRING_DT
        end
        return isnothing(val.datatype) ? _XSD_STRING_DT : val.datatype
    elseif name == "IRI" || name == "URI"
        val = _eval_arg(1)
        isnothing(val) && return nothing
        val isa URIRef && return val            # IRI(<iri>) is the iri unchanged
        ref = val isa Literal ? val.lexical : string(val)
        # Resolve a relative reference against the query's BASE, if any. A
        # reference with a scheme (`scheme:`) is already absolute.
        base = _ACTIVE_BASE[]
        if base !== nothing && !occursin(r"^[A-Za-z][A-Za-z0-9+.\-]*:", ref)
            return URIRef(_sparql_resolve_base(base, ref))
        end
        return URIRef(ref)
    elseif name == "BNODE"
        return isempty(args) ? BNode() : BNode(_ast_str(_eval_arg(1)))
    elseif name == "STRDT"
        val = _eval_arg(1); dt = _eval_arg(2)
        (isnothing(val) || isnothing(dt)) && return nothing
        # STRDT requires a simple literal (plain / xsd:string) as its first
        # argument and an IRI as the datatype; anything else is a type error.
        _is_string_lit(val) || return nothing
        dt isa URIRef || return nothing
        return Literal(val.lexical, datatype=dt)
    elseif name == "STRLANG"
        val = _eval_arg(1); lang = _eval_arg(2)
        (isnothing(val) || isnothing(lang)) && return nothing
        _is_string_lit(val) || return nothing
        _is_str_or_lang_lit(lang) || return nothing
        ls = lang.lexical
        isempty(ls) && return nothing
        return Literal(val.lexical, lang=ls)

    # ── SPARQL 1.2 direction-aware functions ──
    elseif name == "LANGDIR"
        val = _eval_arg(1)
        val isa Literal || return nothing
        return Literal(something(val.direction, ""))
    elseif name == "HASLANG"
        # SPARQL 1.2 hasLANG(literal): true iff the term has a language tag.
        val = _eval_arg(1)
        val isa Literal || return Literal(false)
        return Literal(val.language !== nothing)
    elseif name == "HASLANGDIR"
        # SPARQL 1.2 hasLANGDIR(literal): true iff the term has both a language
        # tag and a base direction.
        val = _eval_arg(1)
        val isa Literal || return Literal(false)
        return Literal(val.language !== nothing && val.direction !== nothing)
    elseif name == "STRLANGDIR"
        val = _eval_arg(1); lang = _eval_arg(2); dir = _eval_arg(3)
        (isnothing(val) || isnothing(lang) || isnothing(dir)) && return nothing
        _is_string_lit(val) || return nothing
        # The direction must be exactly "ltr" or "rtl" (case-sensitive).
        d = _ast_str(dir)
        d in ("ltr", "rtl") || return nothing
        ls = _ast_str(lang)
        isempty(ls) && return nothing
        return Literal(val.lexical, lang=ls, direction=d)
    elseif name == "LANGMATCHES"
        lang = _eval_arg(1); tag = _eval_arg(2)
        (isnothing(lang) || isnothing(tag)) && return nothing  # propagate errors
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

    # ── Numeric functions ── (preserve the argument's numeric type per spec)
    elseif name == "ABS"
        tn = _typed_numeric(_eval_arg(1))
        return tn === nothing ? nothing : _numeric_literal(tn[1], abs(tn[2]))
    elseif name == "CEIL"
        tn = _typed_numeric(_eval_arg(1))
        return tn === nothing ? nothing : _rounding_literal(tn[1], ceil(tn[2]))
    elseif name == "FLOOR"
        tn = _typed_numeric(_eval_arg(1))
        return tn === nothing ? nothing : _rounding_literal(tn[1], floor(tn[2]))
    elseif name == "ROUND"
        tn = _typed_numeric(_eval_arg(1))
        # Round half toward positive infinity (XPath fn:round)
        return tn === nothing ? nothing : _rounding_literal(tn[1], floor(tn[2] + 0.5))
    elseif name == "RAND"
        return Literal(rand())

    # ── Date/Time functions ──
    elseif name == "NOW"
        # Current time in UTC with explicit timezone (Z)
        return Literal(Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS") * "Z",
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
        b = _ast_ebv(_eval_arg(1))
        b === nothing && return nothing  # IF(error, ...) → error
        return b ? _eval_arg(2) : _eval_arg(3)
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
        # A triple term requires a Node subject (URIRef/BNode, NOT itself a
        # triple term), an IRI predicate, and any term object (which may be a
        # nested triple term).
        ((s isa URIRef || s isa BNode) && p isa URIRef && o isa Identifier) || return nothing
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

    # ── GeoSPARQL ── (function names keep their original case now;
    # match case-insensitively)
    elseif startswith(uppercase(name), "GEOF:") || startswith(lowercase(name), "http://www.opengis.net/")
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

    # ── XSD constructor casts (SPARQL §17.5) ──
    elseif startswith(name, _XSD_NS)
        return _ast_xsd_cast(name[length(_XSD_NS)+1:end], _eval_arg(1))
    end

    # Unknown function → per-row type error (row fails), not a query abort
    return nothing
end

# Basic language-range matching (RFC 4647 basic filtering), as used by
# LANGMATCHES / hasLANG / hasLANGDIR.
function _lang_range_matches(lang::AbstractString, range::AbstractString)
    ls = lowercase(lang)
    ts = lowercase(range)
    ts == "*" && return !isempty(ls)
    ls == ts || startswith(ls, ts * "-")
end

# XSD constructor casts per SPARQL 1.1 §17.5 / XPath casting rules.
# Returns the cast literal or `nothing` (type error).
function _ast_xsd_cast(target::String, val)
    val === nothing && return nothing
    if target == "string"
        val isa URIRef && return Literal(val.value)
        val isa Literal || return nothing
        return Literal(val.lexical)
    end
    val isa Literal || return nothing
    lx = strip(val.lexical)
    if target == "boolean"
        if _is_boolean_lit(val)
            return Literal(_bool_value(val) ? "true" : "false", datatype=_XSD_BOOLEAN)
        end
        tn = _typed_numeric(val)
        if tn !== nothing
            v = tn[2]
            return Literal((v == 0 || (v isa Float64 && isnan(v))) ? "false" : "true",
                           datatype=_XSD_BOOLEAN)
        end
        _is_string_lit(val) || return nothing
        lx in ("true", "1") && return Literal("true", datatype=_XSD_BOOLEAN)
        lx in ("false", "0") && return Literal("false", datatype=_XSD_BOOLEAN)
        return nothing
    elseif target == "integer"
        _is_boolean_lit(val) && return Literal(_bool_value(val) ? "1" : "0", datatype=_XSD_INTEGER)
        tn = _typed_numeric(val)
        if tn !== nothing
            v = tn[2]
            (v isa Float64 && (isnan(v) || isinf(v) || abs(v) >= 9.2e18)) && return nothing
            return Literal(string(Int64(trunc(v))), datatype=_XSD_INTEGER)
        end
        _is_string_lit(val) || return nothing
        i = tryparse(Int64, lx)
        return i === nothing ? nothing : Literal(string(i), datatype=_XSD_INTEGER)
    elseif target == "decimal"
        _is_boolean_lit(val) && return Literal(_bool_value(val) ? "1.0" : "0.0", datatype=_XSD_DECIMAL_DT)
        tn = _typed_numeric(val)
        if tn !== nothing
            v = tn[2]
            (v isa Float64 && (isnan(v) || isinf(v))) && return nothing
            return _numeric_literal(:decimal, v)
        end
        _is_string_lit(val) || return nothing
        occursin(r"[eE]", lx) && return nothing
        f = tryparse(Float64, lx)
        return f === nothing ? nothing : _numeric_literal(:decimal, f)
    elseif target == "float" || target == "double"
        kind = target == "float" ? :float : :double
        _is_boolean_lit(val) && return _numeric_literal(kind, _bool_value(val) ? 1.0 : 0.0)
        tn = _typed_numeric(val)
        tn !== nothing && return _numeric_literal(kind, tn[2])
        _is_string_lit(val) || return nothing
        f = lx == "INF" ? Inf : lx == "-INF" ? -Inf : lx == "NaN" ? NaN : tryparse(Float64, lx)
        return f === nothing ? nothing : _numeric_literal(kind, f)
    elseif target == "dateTime"
        dc = _datetime_class(val)
        if dc !== nothing || _is_string_lit(val)
            occursin("T", lx) || dc === :date || return nothing
            try
                parse_xsd_datetime(lx)  # validate
                return Literal(String(lx), datatype=_XSD_DATETIME)
            catch
                return nothing
            end
        end
        return nothing
    elseif target == "date"
        dc = _datetime_class(val)
        if dc === :date
            return val
        elseif dc === :dateTime || _is_string_lit(val)
            try
                d = occursin("T", lx) ? Date(parse_xsd_datetime(lx)) : parse_xsd_date(lx)
                return Literal(format_xsd_date(d), datatype=_XSD_DATE)
            catch
                return nothing
            end
        end
        return nothing
    end
    nothing  # unsupported cast target → error
end

# ─── Expression helpers ───────────────────────────────────────────

function _ast_eval_expr_bool(expr::SparqlExpr, binding::Dict{String,Identifier}, g::RDFGraph)::Bool
    val = _ast_eval_expr(expr, binding, g)
    _ast_ebv(val) === true
end

# ─── Typed value semantics (SPARQL 1.1 §17) ───────────────────────
#
# A literal is numeric ONLY if its datatype is one of the XSD numeric types
# (integer hierarchy, decimal, float, double). Plain/string literals are NOT
# numeric. Expression evaluation uses `nothing` as the error sentinel.

const _XSD_DECIMAL_DT = URIRef(_XSD_NS * "decimal")
const _XSD_FLOAT_DT   = URIRef(_XSD_NS * "float")
const _XSD_DAYTIMEDURATION_DT = URIRef(_XSD_NS * "dayTimeDuration")

# Datatype IRI → numeric kind (:integer, :decimal, :float, :double, :none)
function _numeric_kind_of_dt(dt::String)
    startswith(dt, _XSD_NS) || return :none
    local_name = dt[length(_XSD_NS)+1:end]
    if local_name in ("integer", "int", "long", "short", "byte",
                      "nonNegativeInteger", "positiveInteger",
                      "nonPositiveInteger", "negativeInteger",
                      "unsignedInt", "unsignedLong", "unsignedShort", "unsignedByte")
        return :integer
    elseif local_name == "decimal"
        return :decimal
    elseif local_name == "float"
        return :float
    elseif local_name == "double"
        return :double
    end
    :none
end

_is_numeric_dt(dt::String) = _numeric_kind_of_dt(dt) !== :none

# Numeric type promotion rank
@inline _kind_rank(k::Symbol) = k === :integer ? 1 : k === :decimal ? 2 : k === :float ? 3 : 4
@inline _rank_kind(r::Int) = r == 1 ? :integer : r == 2 ? :decimal : r == 3 ? :float : :double
@inline _promote_kind(a::Symbol, b::Symbol) = _rank_kind(max(_kind_rank(a), _kind_rank(b)))

# Parse a literal as a typed numeric value. Returns `(kind, value)` where
# value is Int64 (integers) or Float64, or `nothing` when the literal is not
# a (well-formed) XSD numeric literal.
function _typed_numeric(val)
    val isa Literal || return nothing
    val.language === nothing || return nothing
    dt = val.datatype
    dt === nothing && return nothing
    k = _numeric_kind_of_dt(dt.value)
    k === :none && return nothing
    lx = strip(val.lexical)
    if k === :integer
        i = tryparse(Int64, lx)
        i === nothing && return nothing
        return (k, i)
    elseif k === :decimal
        occursin(r"[eE]", lx) && return nothing  # decimal lexical has no exponent
        f = tryparse(Float64, lx)
        f === nothing && return nothing
        return (k, f)
    else
        f = lx == "INF" ? Inf : lx == "-INF" ? -Inf : lx == "NaN" ? NaN : tryparse(Float64, lx)
        f === nothing && return nothing
        return (k, f)
    end
end

# CEIL/FLOOR/ROUND always yield an integer value; the SPARQL test suite
# serializes a decimal-typed result with a bare integer lexical (e.g. CEIL of
# 2.5 → "3"^^xsd:decimal, not "3.0"). For integer/float/double inputs we use
# the normal typed lexical.
function _rounding_literal(kind::Symbol, v::Real)
    if kind === :decimal
        (isnan(v) || isinf(v)) && return nothing
        return Literal(string(Int64(v)), datatype=_XSD_DECIMAL_DT)
    end
    _numeric_literal(kind, v)
end

# Build a numeric literal of the given kind from a Julia number.
function _numeric_literal(kind::Symbol, v::Real)
    if kind === :integer
        if v isa Float64
            (isnan(v) || isinf(v) || abs(v) >= 9.2e18) && return nothing  # out of Int64 range
            return Literal(string(Int64(v)), datatype=_XSD_INTEGER)
        end
        return Literal(string(Int64(v)), datatype=_XSD_INTEGER)
    elseif kind === :decimal
        f = Float64(v)
        (isnan(f) || isinf(f)) && return nothing
        return Literal(_decimal_lexical(f), datatype=_XSD_DECIMAL_DT)
    elseif kind === :float
        return Literal(_xsd_double_lexical(Float64(v)), datatype=_XSD_FLOAT_DT)
    else
        return Literal(_xsd_double_lexical(Float64(v)), datatype=_XSD_DOUBLE)
    end
end

# Canonical xsd:decimal lexical form. Float64 arithmetic introduces tiny
# representation noise (e.g. 4.1 + 7.0 → 11.100000000000001); round to the
# shortest decimal that reproduces the value, then ensure a fractional digit.
function _decimal_lexical(f::Float64)
    if isinteger(f) && abs(f) < 1e15
        return string(Int64(f)) * ".0"
    end
    # Round to 15 significant digits to absorb Float64 representation noise
    # introduced by decimal arithmetic (e.g. 4.1 + 7.0 → 11.100000000000001 →
    # "11.1"), then take the shortest round-tripping decimal of that.
    f = _round_sig(f, 15)
    s = string(f)  # Julia prints the shortest round-tripping decimal
    # Julia uses scientific notation for very large/small magnitudes; xsd:decimal
    # never does, so expand those into plain fixed-point form.
    (occursin('e', s) || occursin('E', s)) && return _decimal_from_sci(s)
    occursin('.', s) || (s *= ".0")
    return s
end

# Round `f` to `n` significant decimal digits.
function _round_sig(f::Float64, n::Int)
    f == 0.0 && return 0.0
    d = n - 1 - floor(Int, log10(abs(f)))
    return round(f; digits=d)
end

# Expand a Julia scientific-notation string (e.g. "1.0e-7") into plain
# fixed-point decimal notation ("0.0000001").
function _decimal_from_sci(s::AbstractString)
    m = match(r"^(-?)(\d+)(?:\.(\d+))?[eE]([+-]?\d+)$", s)
    m === nothing && return String(s)
    sign, intp, frac, exps = m.captures[1], m.captures[2], m.captures[3], m.captures[4]
    frac = frac === nothing ? "" : frac
    digits = intp * frac
    point = length(intp) + parse(Int, exps)   # position of the decimal point
    out = if point <= 0
        "0." * "0"^(-point) * digits
    elseif point >= length(digits)
        digits * "0"^(point - length(digits)) * ".0"
    else
        digits[1:point] * "." * digits[point+1:end]
    end
    out = replace(out, r"(\.\d*?)0+$" => s"\1")
    endswith(out, '.') && (out *= "0")
    return sign * out
end

# Canonical xsd:double / xsd:float lexical form per the XSD spec: a mantissa
# with exactly one digit before the point and at least one after, an "E", and
# an integer exponent (e.g. 0.2 → "2.0E-1", 100 → "1.0E2").
function _xsd_double_lexical(v::Float64)
    isnan(v) && return "NaN"
    isinf(v) && return v > 0 ? "INF" : "-INF"
    v == 0.0 && return (1/v < 0 ? "-0.0E0" : "0.0E0")
    neg = v < 0
    # Start from Julia's shortest round-tripping decimal, then normalize to the
    # required single-digit-mantissa scientific form by shifting the point.
    base = string(abs(v))
    digits, exp10 = _mantissa_digits_and_exp(base)
    # `digits` is the significant digits (no point); place the point after the
    # first digit. `exp10` is the exponent for digits[1].digits[2:] * 10^exp10.
    frac = length(digits) > 1 ? digits[2:end] : "0"
    frac = rstrip(frac, '0'); isempty(frac) && (frac = "0")
    (neg ? "-" : "") * string(digits[1]) * "." * frac * "E" * string(exp10)
end

# Decompose a plain/scientific decimal string into (significant-digit string,
# exponent) such that value == d[1].d[2:] × 10^exp.
function _mantissa_digits_and_exp(s::AbstractString)
    m = match(r"^(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$", s)
    m === nothing && return ("0", 0)
    intp = m.captures[1]
    frac = m.captures[2] === nothing ? "" : m.captures[2]
    e = m.captures[3] === nothing ? 0 : parse(Int, m.captures[3])
    alldig = intp * frac
    # exponent of the first overall digit
    firstexp = length(intp) - 1 + e
    # strip leading zeros, adjusting the exponent
    i = findfirst(c -> c != '0', alldig)
    if i === nothing
        return ("0", 0)
    end
    firstexp -= (i - 1)
    sig = rstrip(alldig[i:end], '0')
    isempty(sig) && (sig = "0")
    return (sig, firstexp)
end

# Plain numeric value of a literal (no kind), or `nothing`. Plain literals
# and strings are NOT numeric (datatype-driven semantics).
function _ast_to_numeric(val)
    val isa Number && return val
    tn = _typed_numeric(val)
    tn === nothing && return nothing
    tn[2]
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
    lex = f(val isa Literal ? val.lexical : string(val))
    # UCASE/LCASE preserve the language tag (and base direction) of the argument.
    if val isa Literal && val.language !== nothing
        return Literal(lex; lang=val.language, direction=val.direction)
    end
    Literal(lex)
end

# Build a string-result literal that inherits the language tag / direction of
# the source argument `src` (used by SUBSTR, STRBEFORE, STRAFTER, REPLACE).
# Per SPARQL 1.1, these functions propagate arg1's language tag.
function _str_like(lex::AbstractString, src)
    if src isa Literal && src.language !== nothing
        return Literal(lex; lang=src.language, direction=src.direction)
    end
    Literal(lex)
end

# Codepoint-based substring: characters at 1-based positions `lo..hi`
# (inclusive), clamped to the string. Empty if the range is empty.
function _substr_chars(s::AbstractString, lo::Int, hi::Int)
    n = length(s)
    lo = max(lo, 1); hi = min(hi, n)
    hi < lo && return ""
    String(collect(s)[lo:hi])
end

# True if `val` is a plain/xsd:string or language-tagged literal (the argument
# kinds the SPARQL string built-ins accept). Numeric/boolean/date literals,
# URIs and blank nodes are type errors.
@inline _is_str_or_lang_lit(val) =
    val isa Literal && (val.language !== nothing ||
                        val.datatype === nothing || val.datatype == _XSD_STRING_DT)

# SPARQL "argument compatibility" for STRBEFORE/STRAFTER/REPLACE-style pairs:
# arg1 and arg2 are compatible if arg2 is a plain string, or both carry the
# same language tag. Returns false (→ type error) otherwise.
function _str_args_compatible(arg1, arg2)
    (_is_str_or_lang_lit(arg1) && _is_str_or_lang_lit(arg2)) || return false
    arg2.language === nothing && return true
    arg1.language == arg2.language
end

# A "string literal" for comparison purposes: simple literal or xsd:string
# (the Literal constructor normalizes xsd:string to a simple literal).
@inline function _is_string_lit(l)
    l isa Literal && l.language === nothing &&
        (l.datatype === nothing || l.datatype == _XSD_STRING_DT)
end

@inline function _is_boolean_lit(l)
    l isa Literal && l.datatype !== nothing &&
        l.datatype.value == _XSD_NS * "boolean" &&
        l.lexical in ("true", "false", "1", "0")
end

@inline _bool_value(l::Literal) = l.lexical in ("true", "1")

@inline function _datetime_class(l)
    l isa Literal || return nothing
    dt = l.datatype
    dt === nothing && return nothing
    dtv = dt.value
    dtv == _XSD_NS * "dateTime" && return :dateTime
    dtv == _XSD_NS * "date" && return :date
    nothing
end

# Effective boolean value (SPARQL §17.2.2). Three-valued: true / false /
# nothing (type error). EBV of a non-literal (IRI, blank node, unbound) is
# an error.
function _ast_ebv(val)
    val === nothing && return nothing
    val isa Bool && return val
    val isa Literal || return nothing
    # Language-tagged (and dir-lang) literals have no EBV → type error.
    val.language === nothing || return nothing
    dt = val.datatype
    dt === nothing && return !isempty(val.lexical)
    dtv = dt.value
    if dtv == _XSD_NS * "boolean"
        lx = val.lexical
        # Well-formed boolean lexical only; ill-formed → type error (unbound).
        return (lx == "true" || lx == "1") ? true :
               (lx == "false" || lx == "0") ? false : nothing
    end
    if _numeric_kind_of_dt(dtv) !== :none
        tn = _typed_numeric(val)
        tn === nothing && return false  # ill-formed numeric lexical → false
        v = tn[2]
        return !(v == 0 || (v isa Float64 && isnan(v)))
    end
    nothing  # other datatypes have no EBV → type error
end

# Backwards-compatible strict-boolean helper
_ast_to_bool(val)::Bool = _ast_ebv(val) === true

# Value comparison for `<`, `<=`, `>`, `>=` (and value-equality of typed
# pairs). Returns -1 / 0 / 1, or `nothing` for a type error (incomparable
# operands). Per spec:
#  - numeric <-> numeric by value
#  - string <-> string (simple/xsd:string, no language tag) by codepoint
#  - boolean <-> boolean (false < true)
#  - dateTime <-> dateTime by timeline value. `parse_xsd_datetime` normalizes
#    timezoned values to UTC; TZ-less values are treated as UTC (the spec
#    leaves <14h-apart comparisons implementation-defined).
#  - everything else (incl. lang-tagged literals, IRIs) → type error
function _ast_value_cmp(a, b)
    a isa Literal && b isa Literal || return nothing
    ta = _typed_numeric(a)
    tb = _typed_numeric(b)
    if ta !== nothing && tb !== nothing
        va = ta[2]; vb = tb[2]
        (va isa Float64 && isnan(va)) && return nothing
        (vb isa Float64 && isnan(vb)) && return nothing
        return va < vb ? -1 : va > vb ? 1 : 0
    end
    if _is_string_lit(a) && _is_string_lit(b)
        return cmp(a.lexical, b.lexical)
    end
    if _is_boolean_lit(a) && _is_boolean_lit(b)
        ba = _bool_value(a); bb = _bool_value(b)
        return ba == bb ? 0 : (ba ? 1 : -1)
    end
    ca = _datetime_class(a); cb = _datetime_class(b)
    if ca !== nothing && ca === cb
        return _xsd_temporal_cmp(a.lexical, b.lexical, ca)
    end
    nothing
end

# RDFterm-equal for `=` / `!=` (SPARQL §17.4.1.7). Returns true/false, or
# `nothing` for a type error: two literals that are not the same RDF term
# and not comparable by value (e.g. "foo"@en = "foo", "1"@en = 1,
# literals of unknown datatypes with different lexical forms).
function _ast_term_eq(a, b)
    a == b && return true
    (a === nothing || b === nothing) && return nothing
    if a isa TripleTerm && b isa TripleTerm
        # SPARQL 1.2: triple terms are `=` when their components are pairwise
        # RDFterm-equal (value-equality on the object, term-equality elsewhere).
        es = _ast_term_eq(a.subject, b.subject)
        es === nothing && return nothing
        es === false && return false
        ep = _ast_term_eq(a.predicate, b.predicate)
        ep === nothing && return nothing
        ep === false && return false
        return _ast_term_eq(a.object, b.object)
    end
    # A triple term and a non-triple-term are known-different.
    (a isa TripleTerm) != (b isa TripleTerm) && return false
    if a isa Literal && b isa Literal
        c = _ast_value_cmp(a, b)
        c !== nothing && return c == 0
        # Not value-comparable and not the same term.
        # A language-tagged literal occupies its own (per-tag) value space that
        # is disjoint from every other kind of literal; since a==b already ruled
        # out an identical term, such a pair is "known different" → FALSE.
        if a.language !== nothing || b.language !== nothing
            return false
        end
        # Classify each operand by value space. Two literals in *different*
        # recognized spaces are known-different → FALSE. Within the *same* space
        # an indeterminate value comparison (e.g. timezoned vs untimezoned date)
        # is a genuine type error → nothing. An unknown datatype is also a type
        # error.
        ka = _value_class(a); kb = _value_class(b)
        (ka === :unknown || kb === :unknown) && return nothing
        ka == kb ? nothing : false
    else
        false
    end
end

# Classify a (non-language) literal into a value space for RDFterm-equal:
# `:string`, `:numeric`, `:boolean`, a datetime class (`:date`/`:dateTime`/…),
# or `:unknown` (unrecognized datatype or ill-formed lexical).
function _value_class(l::Literal)
    dt = l.datatype
    (dt === nothing || dt == _XSD_STRING_DT) && return :string
    _typed_numeric(l) !== nothing && return :numeric
    _is_boolean_lit(l) && return :boolean
    dc = _datetime_class(l)
    dc !== nothing && return dc
    return :unknown
end

# Compare two xsd:date / xsd:dateTime lexical forms by value, applying the XSD
# rule that an operand with no timezone spans the ±14h indeterminacy window.
# Returns -1/0/1, or `nothing` when the order is indeterminate (a type error,
# e.g. `2006-08-23` vs `2006-08-23Z`).
function _xsd_temporal_cmp(lex_a::AbstractString, lex_b::AbstractString, cls::Symbol)
    pa = _temporal_instant(lex_a, cls); pa === nothing && return nothing
    pb = _temporal_instant(lex_b, cls); pb === nothing && return nothing
    (ta, has_a) = pa
    (tb, has_b) = pb
    if has_a == has_b
        return ta < tb ? -1 : ta > tb ? 1 : 0
    end
    # Exactly one is timezoned: the untimezoned operand could lie anywhere in a
    # ±14h band. If that whole band falls on one side, the order is determinate;
    # otherwise it is indeterminate.
    band = Dates.Hour(14)
    if has_a   # b is untimezoned → compare a against b's band
        ta < tb - band && return -1
        ta > tb + band && return 1
        return nothing
    else       # a is untimezoned
        ta + band < tb && return -1
        ta - band > tb && return 1
        return nothing
    end
end

# Parse a date/dateTime lexical into (DateTime-in-UTC, has_timezone). Dates are
# treated as the midnight instant. Returns `nothing` on a malformed lexical.
function _temporal_instant(lex::AbstractString, cls::Symbol)
    try
        base, tzmin = _split_tz(strip(lex))
        if cls === :date
            d = parse_xsd_date(base)
            dt = DateTime(d)
            tzmin !== nothing && tzmin != 0 && (dt -= Dates.Minute(tzmin))
            return (dt, tzmin !== nothing)
        else
            # parse_xsd_datetime already applies the timezone offset.
            dt = parse_xsd_datetime(lex)
            return (dt, tzmin !== nothing)
        end
    catch
        return nothing
    end
end

function _ast_eval_comparison(op::Symbol, left, right)
    if op == :(==) || op == :!=
        r = _ast_term_eq(left, right)
        r === nothing && return nothing
        return Literal(op == :(==) ? r : !r)
    end
    c = _ast_value_cmp(left, right)
    c === nothing && return nothing
    res = op == :< ? c < 0 :
          op == :> ? c > 0 :
          op == :<= ? c <= 0 :
          op == :>= ? c >= 0 : false
    Literal(res)
end

function _ast_eval_arithmetic(op::Symbol, left, right)
    la = _typed_numeric(left)
    ra = _typed_numeric(right)
    if la !== nothing && ra !== nothing
        lk, lv = la
        rk, rv = ra
        kind = _promote_kind(lk, rk)
        if op == :/
            if kind === :integer || kind === :decimal
                rv == 0 && return nothing  # division by zero → error
                return _numeric_literal(:decimal, lv / rv)
            end
            return _numeric_literal(kind, lv / rv)
        end
        v = op == :+ ? lv + rv :
            op == :- ? lv - rv :
            op == :* ? lv * rv : nothing
        v === nothing && return nothing
        return _numeric_literal(kind, v)
    end
    # Date arithmetic: dateTime ± duration
    if op in (:+, :-) && (left isa Literal || right isa Literal)
        return _ast_date_arithmetic(op, left, right)
    end
    nothing
end

# value-equality helper retained for compatibility (true only when terms are
# equal or value-equal; type errors count as not-equal here)
_ast_values_equal(a, b) = _ast_term_eq(a, b) === true

function _ast_make_regex(pattern::String, flags::String)
    # The XPath/SPARQL `q` flag (RDF 1.1 / XPath 3) treats the whole pattern as a
    # literal string: all metacharacters lose their special meaning. Apply it by
    # escaping the pattern before compiling. (When combined with `i`, the `i`
    # flag still applies.)
    pat = 'q' in flags ? _regex_quote(pattern) : pattern
    opts = ""
    'i' in flags && (opts *= "i")
    's' in flags && (opts *= "s")
    'm' in flags && (opts *= "m")
    'x' in flags && (opts *= "x")  # extended / ignore-whitespace mode
    try
        return Regex(pat, opts)
    catch
        # Some XSD/XPath regex constructs aren't valid PCRE; treat such a pattern
        # as one that never matches rather than erroring out the whole query.
        return r"(?!)"
    end
end

# Escape every PCRE metacharacter so the pattern matches itself literally.
function _regex_quote(s::AbstractString)
    out = IOBuffer()
    for c in s
        c in ('\\','^','$','.','[',']','|','(',')','?','*','+','{','}','-') && write(out, '\\')
        write(out, c)
    end
    String(take!(out))
end

function _uri_encode(s::String)
    buf = IOBuffer()
    for c in s
        # Per SPARQL ENCODE_FOR_URI only the ASCII unreserved set is preserved;
        # non-ASCII letters/digits must be percent-encoded.
        if (c in 'A':'Z') || (c in 'a':'z') || (c in '0':'9') || c in ('-', '_', '.', '~')
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
        # Per SPARQL 17.4.5, YEAR/MONTH/.../SECONDS return the component of the
        # literal in its own timezone, so parse without normalizing to UTC.
        dt = parse_xsd_datetime(_strip_tz(strip(s)))
        if func == "YEAR";    return Literal(Dates.year(dt))
        elseif func == "MONTH";   return Literal(Dates.month(dt))
        elseif func == "DAY";     return Literal(Dates.day(dt))
        elseif func == "HOURS";   return Literal(Dates.hour(dt))
        elseif func == "MINUTES"; return Literal(Dates.minute(dt))
        elseif func == "SECONDS"
            # SECONDS returns an xsd:decimal (including any fractional part).
            sec = Dates.second(dt); ms = Dates.millisecond(dt)
            return ms == 0 ? Literal(string(sec), datatype=_XSD_DECIMAL_DT) :
                             _numeric_literal(:decimal, sec + ms / 1000)
        elseif func == "TZ"
            # TZ returns the timezone designator as a simple literal ("" if none)
            return Literal(_extract_tz(s))
        elseif func == "TIMEZONE"
            # TIMEZONE returns an xsd:dayTimeDuration; error if no timezone
            tzs = _extract_tz(s)
            isempty(tzs) && return nothing
            return Literal(_tz_to_duration(tzs), datatype=_XSD_DAYTIMEDURATION_DT)
        end
    catch
        return nothing
    end
end

function _extract_tz(s::String)
    m = match(r"([+-]\d{2}:\d{2}|Z)$", strip(s))
    isnothing(m) ? "" : m.captures[1]
end

# Convert a timezone designator ("Z", "+05:30", "-08:00") to an
# xsd:dayTimeDuration lexical form ("PT0S", "PT5H30M", "-PT8H").
function _tz_to_duration(tz::AbstractString)
    (tz == "Z" || tz == "+00:00" || tz == "-00:00") && return "PT0S"
    m = match(r"^([+-])(\d{2}):(\d{2})$", tz)
    isnothing(m) && return "PT0S"
    sign = m.captures[1] == "-" ? "-" : ""
    h = parse(Int, m.captures[2])
    mi = parse(Int, m.captures[3])
    out = sign * "PT"
    h > 0 && (out *= "$(h)H")
    mi > 0 && (out *= "$(mi)M")
    (h == 0 && mi == 0) && (out *= "0S")
    out
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
    # Normalize function name: strip any geof: prefix (case-insensitive) and
    # extract the part after the last /
    func_name = lowercase(last(split(replace(name, r"(?i)^GEOF:" => ""), "/")))
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
    # Empty solution sequence + no GROUP BY → exactly one row of
    # aggregates-over-the-empty-group (SPARQL §18.5; COUNT()=0, SUM()=0, ...)
    if isempty(bindings) && isempty(q.group_by)
        result = Dict{String,Identifier}()
        for sa in q.aggregates
            v = _ast_compute_aggregate(sa.agg, Dict{String,Identifier}[])
            v === nothing || (result[sa.alias] = v)
        end
        for se in q.select_exprs
            _expr_has_aggregate(se.expr) &&
                _ast_stash_agg_values!(se.expr, result, Dict{String,Identifier}[])
        end
        if !isnothing(q.having)
            having_row = copy(result)
            _ast_stash_agg_values!(q.having, having_row, Dict{String,Identifier}[])
            _ast_eval_expr_bool(q.having, having_row, g) || return Dict{String,Identifier}[]
        end
        return Dict{String,Identifier}[result]
    end
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
        # Compute aggregates (nothing = error/empty → variable stays unbound)
        for sa in q.aggregates
            v = _ast_compute_aggregate(sa.agg, group)
            v === nothing || (result[sa.alias] = v)
        end
        # Stash aggregate values used by computed SELECT expressions
        # (e.g. `(MIN(?p)+MAX(?p))/2 AS ?c`) so they can be evaluated post-group.
        for se in q.select_exprs
            _expr_has_aggregate(se.expr) && _ast_stash_agg_values!(se.expr, result, group)
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
    # Computed SELECT expressions containing aggregates (e.g.
    # `(MIN(?p)+MAX(?p))/2 AS ?c`) need full per-group bindings; not streamable.
    any(se -> _expr_has_aggregate(se.expr), q.select_exprs) && return false
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

# Streaming OPTIONAL+aggregate: avoid materializing inner-BGP rows by piping
# matches directly into per-group accumulators using a reused scratch dict.
# Returns Vector{Dict} of finalized aggregate rows (caller handles ORDER BY/LIMIT/proj),
# or `nothing` if the query doesn't fit the supported shape.
#
# Supported shape (Q4-class queries):
#   SELECT (group-by-vars + aggregates only)
#   WHERE { outer-BGP+Filter . OPTIONAL { inner-single-star-BGP+Filter . } }
#   GROUP BY <outer-vars only>
# Aggregates over outer vars must be DISTINCT (or MIN/MAX/SAMPLE) so that
# outer-row multiplicity from inner matches doesn't affect the result.
function _try_stream_opt_agg(q::SparqlSelect, g::RDFGraph)
    isempty(q.aggregates) && return nothing
    !isnothing(q.having) && return nothing
    !isempty(q.select_exprs) && return nothing
    g.store isa MemoryStore || g.store isa EncodedStore || return nothing
    !_streaming_aggregate_safe(q) && return nothing

    # Reject any ExprStar aggregate arg (COUNT(*), COUNT(DISTINCT *)) — row-signature
    # distinctness is unsafe with a reused scratch dict.
    for sa in q.aggregates
        sa.agg.arg isa ExprStar && return nothing
        sa.agg.arg isa ExprVar || return nothing
    end

    # Pattern shape: outer (1+ patterns) + trailing PatOptional
    ps = q.patterns
    length(ps) >= 2 || return nothing
    last_p = ps[end]
    last_p isa PatOptional || return nothing
    inner_pats = (last_p::PatOptional).patterns
    outer_pats = SparqlPattern[ps[i] for i in 1:length(ps)-1]
    isempty(outer_pats) && return nothing
    isempty(inner_pats) && return nothing

    # Both sides must be pure BGP+Filter
    for p in outer_pats
        (p isa PatTriple || p isa PatFilter) || return nothing
    end
    for p in inner_pats
        (p isa PatTriple || p isa PatFilter) || return nothing
    end

    # Inner: must be a single star group (all triples share same subject var)
    inner_triples = PatTriple[]
    for p in inner_pats
        p isa PatTriple && push!(inner_triples, p::PatTriple)
    end
    isempty(inner_triples) && return nothing
    inner_subj = inner_triples[1].subject
    inner_subj isa String || return nothing
    for t in inner_triples
        t.subject == inner_subj || return nothing
        t.predicate isa URIRef || return nothing
    end

    # Outer-produced vars (statically — assumes outer BGP can bind these)
    outer_vars = Set{String}()
    for p in outer_pats
        if p isa PatTriple
            p.subject isa String && push!(outer_vars, p.subject::String)
            p.object isa String && push!(outer_vars, p.object::String)
        end
    end
    isempty(outer_vars) && return nothing

    # Inner subject var must be FRESH (not in outer); otherwise we'd need to
    # constrain the candidate-subject scan to the bound value (not implemented).
    inner_subj in outer_vars && return nothing

    # Reject repeated obj vars in inner star (would require equality validation
    # that the simple object-singleton path doesn't perform).
    inner_obj_vars = String[]
    for t in inner_triples
        if t.object isa String && t.object != inner_subj
            t.object in inner_obj_vars && return nothing
            push!(inner_obj_vars, t.object::String)
        end
    end

    # Inner-produced vars: subject + fresh obj vars
    inner_produced = Set{String}([inner_subj])
    for v in inner_obj_vars
        v in outer_vars || push!(inner_produced, v)
    end

    # GROUP BY: every var must be outer-produced
    for gb in q.group_by
        gb isa ExprVar || return nothing
        (gb::ExprVar).name in outer_vars || return nothing
    end

    # Projection / ORDER BY: only group-by vars and aggregate aliases allowed
    agg_aliases = Set{String}(sa.alias for sa in q.aggregates)
    gb_names = Set{String}((gb::ExprVar).name for gb in q.group_by)
    proj = _ast_projection_vars(q)
    for v in proj
        (v in agg_aliases || v in gb_names) || return nothing
    end
    for ob in q.order_by
        e = ob[1]
        if e isa ExprVar
            ((e::ExprVar).name in agg_aliases || (e::ExprVar).name in gb_names) || return nothing
        else
            return nothing
        end
    end

    # Classify each aggregate as :outer or :inner.
    n_agg = length(q.aggregates)
    agg_sources = Vector{Symbol}(undef, n_agg)
    for (i, sa) in enumerate(q.aggregates)
        vn = (sa.agg.arg::ExprVar).name
        if vn in outer_vars
            # Multiplicity-sensitive aggregates over outer vars must be DISTINCT
            # (MIN/MAX/SAMPLE are insensitive to duplicate values).
            f = sa.agg.func
            if !sa.agg.distinct && (f == "COUNT" || f == "SUM" || f == "AVG")
                return nothing
            end
            agg_sources[i] = :outer
        elseif vn in inner_produced
            agg_sources[i] = :inner
        else
            return nothing
        end
    end

    if g.store isa EncodedStore
        return _exec_stream_opt_agg_eb(q, g, outer_pats, inner_pats, inner_triples,
                                        inner_subj, agg_sources)
    end
    return _exec_stream_opt_agg(q, g, outer_pats, inner_pats, inner_triples,
                                 inner_subj, agg_sources)
end

function _exec_stream_opt_agg(q::SparqlSelect, g::RDFGraph,
                               outer_pats::Vector{SparqlPattern},
                               inner_pats::Vector{SparqlPattern},
                               inner_triples::Vector{PatTriple},
                               inner_subj::String,
                               agg_sources::Vector{Symbol})
    store = g.store::MemoryStore
    _ensure_all_indexed!(store)
    n_agg = length(q.aggregates)
    n_gb = length(q.group_by)
    n_inner = length(inner_triples)

    # Evaluate outer BGP fully (typically small relative to the join product)
    outer_bindings = _ast_eval_patterns(g, outer_pats,
                                         Dict{String,Identifier}[Dict{String,Identifier}()])
    # Empty outer + no GROUP BY: still emit a single aggregate-on-empty row.
    if isempty(outer_bindings)
        if n_gb == 0
            result = Dict{String,Identifier}()
            for sa in q.aggregates
                v = _ast_compute_aggregate(sa.agg, Dict{String,Identifier}[])
                v === nothing || (result[sa.alias] = v)
            end
            return Dict{String,Identifier}[result]
        else
            return Dict{String,Identifier}[]
        end
    end

    # Pre-classify aggregate plan for _agg_update_fast
    agg_plan = Vector{Tuple{Int,Bool,String,Bool}}(undef, n_agg)
    @inbounds for i in 1:n_agg
        a = q.aggregates[i].agg
        fi = a.func == "COUNT" ? 1 : a.func == "SUM" ? 2 : a.func == "AVG" ? 3 :
             a.func == "MIN" ? 4 : a.func == "MAX" ? 5 : a.func == "SAMPLE" ? 6 : 0
        is_star = a.arg isa ExprStar
        var = a.arg isa ExprVar ? (a.arg::ExprVar).name : ""
        agg_plan[i] = (fi, a.distinct, var, is_star)
    end

    # Pre-resolve inner predicate URIs and POS buckets
    pred_uris = URIRef[t.predicate::URIRef for t in inner_triples]
    pos_buckets = Vector{Union{Dict{Identifier,Set{Identifier}},Nothing}}(undef, n_inner)
    has_inner_match_possible = true
    @inbounds for i in 1:n_inner
        po = get(store.pos, pred_uris[i], nothing)
        pos_buckets[i] = po
        if po === nothing
            has_inner_match_possible = false
        end
    end

    # Inner PatFilters (evaluated per candidate inner solution)
    inner_filters = SparqlExpr[]
    for p in inner_pats
        p isa PatFilter && push!(inner_filters, (p::PatFilter).expr)
    end

    # Group state and scratch
    groups = Dict{Tuple,Tuple{Vector{Union{Identifier,Nothing}},Vector{Any}}}()
    group_order = Tuple[]
    scratch = Dict{String,Identifier}()
    obj_sets = Vector{Set{Identifier}}(undef, n_inner)
    obj_firsts = Vector{Identifier}(undef, n_inner)

    # Per-aggregate index lists for the per-row hot path
    outer_agg_idx = Int[i for i in 1:n_agg if agg_sources[i] === :outer]
    inner_agg_idx = Int[i for i in 1:n_agg if agg_sources[i] === :inner]

    for outer_b in outer_bindings
        # Build group key from outer-only vars
        key = if n_gb == 0
            ()
        else
            ntuple(n_gb) do i
                e = _ast_eval_expr(q.group_by[i], outer_b, g)
                isnothing(e) ? nothing : e
            end
        end

        st = get(groups, key, nothing)
        local accs::Vector{Any}
        if st === nothing
            gvals = Union{Identifier,Nothing}[]
            for gb in q.group_by
                push!(gvals, get(outer_b, (gb::ExprVar).name, nothing))
            end
            accs = Any[_agg_init(q.aggregates[i].agg) for i in 1:n_agg]
            groups[key] = (gvals, accs)
            push!(group_order, key)
        else
            _, accs = st
        end

        # Always update outer-source aggregates once per outer row (LEFT JOIN
        # semantics: outer contributes regardless of inner match).
        @inbounds for i in outer_agg_idx
            accs[i] = _agg_update_fast(accs[i], agg_plan[i], outer_b)
        end

        # Skip inner if no agg consumes it AND no inner match is even possible.
        # (For inner-agg-free queries the streaming check is just a no-op anyway.)
        isempty(inner_agg_idx) && isempty(inner_filters) && continue
        has_inner_match_possible || continue

        # Populate scratch with outer_b once per outer row. Inner-var keys get
        # OVERWRITTEN per match (every inner match binds the same set of inner
        # vars), so no stale-binding issue between matches.
        empty!(scratch)
        for (k, v) in outer_b
            scratch[k] = v
        end

        # Find smallest driver set via POS pivot on bound objects
        driver = nothing
        bail = false
        @inbounds for i in 1:n_inner
            po = pos_buckets[i]
            po === nothing && (bail = true; break)
            obj = inner_triples[i].object
            if obj isa String
                bv = get(outer_b, obj, nothing)
                if bv isa Identifier
                    subjs = get(po, bv, nothing)
                    if subjs === nothing
                        bail = true; break
                    end
                    if driver === nothing || length(subjs) < length(driver)
                        driver = subjs
                    end
                end
            elseif obj isa Identifier
                subjs = get(po, obj, nothing)
                if subjs === nothing
                    bail = true; break
                end
                if driver === nothing || length(subjs) < length(driver)
                    driver = subjs
                end
            end
        end
        bail && continue
        # No driver = no bound objects = would scan all subjects. For inner OPTIONAL
        # we should not full-scan the store per outer row; conservatively fall back.
        # This shouldn't happen normally because we required has_shared via the
        # "shared var" check… actually we didn't enforce that; do it now.
        driver === nothing && continue

        for s in driver
            sp = get(store.spo, s, nothing)
            sp === nothing && continue
            ok = true
            @inbounds for i in 1:n_inner
                os = get(sp, pred_uris[i], nothing)
                if os === nothing
                    ok = false; break
                end
                obj_sets[i] = os
            end
            ok || continue

            scratch[inner_subj] = s

            all_single = true
            @inbounds for i in 1:n_inner
                length(obj_sets[i]) != 1 && (all_single = false; break)
            end
            if all_single
                @inbounds for i in 1:n_inner
                    obj_firsts[i] = first(obj_sets[i])
                end
                # Validate bound vars / constants
                ok2 = true
                @inbounds for i in 1:n_inner
                    pat_obj = inner_triples[i].object
                    if pat_obj isa String
                        bv = get(outer_b, pat_obj, nothing)
                        if bv isa Identifier
                            bv == obj_firsts[i] || (ok2 = false; break)
                        end
                    elseif pat_obj isa Identifier
                        pat_obj == obj_firsts[i] || (ok2 = false; break)
                    end
                end
                ok2 || continue

                # Bind inner obj vars in scratch (overwrites prior match's values)
                @inbounds for i in 1:n_inner
                    pat_obj = inner_triples[i].object
                    pat_obj isa String && (scratch[pat_obj::String] = obj_firsts[i])
                end

                # Inner filters (full bindings now in scratch)
                fok = true
                for fexpr in inner_filters
                    if !_ast_eval_expr_bool(fexpr, scratch, g)
                        fok = false; break
                    end
                end
                fok || continue

                # Update inner-source aggregates
                @inbounds for i in inner_agg_idx
                    accs[i] = _agg_update_fast(accs[i], agg_plan[i], scratch)
                end
            else
                # Multi-valued: enumerate cross product of obj_sets
                _stream_inner_cross_agg!(scratch, outer_b, s, inner_subj, inner_triples,
                                          obj_sets, 1, n_inner, inner_filters, accs,
                                          inner_agg_idx, agg_plan, g)
            end
        end
    end

    # Finalize groups
    new_bindings = Vector{Dict{String,Identifier}}(undef, length(group_order))
    @inbounds for gi in eachindex(group_order)
        key = group_order[gi]
        gvals, accs = groups[key]
        result = Dict{String,Identifier}()
        for (i, gb) in enumerate(q.group_by)
            gv = gvals[i]
            gv === nothing || (result[(gb::ExprVar).name] = gv)
        end
        for i in 1:n_agg
            v = _agg_finalize(accs[i], q.aggregates[i].agg)
            v === nothing || (result[q.aggregates[i].alias] = v)
        end
        new_bindings[gi] = result
    end
    new_bindings
end

# Recursive cross-product enumerator for multi-valued inner star matches.
# Mutates `scratch` in place; restores nothing (caller's loop overwrites for next subj).
function _stream_inner_cross_agg!(scratch::Dict{String,Identifier},
                                    outer_b::Dict{String,Identifier},
                                    s::Identifier, inner_subj::String,
                                    inner_triples::Vector{PatTriple},
                                    obj_sets::Vector{Set{Identifier}},
                                    idx::Int, n::Int,
                                    inner_filters::Vector{SparqlExpr},
                                    accs::Vector{Any}, inner_agg_idx::Vector{Int},
                                    agg_plan::Vector{Tuple{Int,Bool,String,Bool}}, g)
    if idx > n
        # Inner filters
        for fexpr in inner_filters
            _ast_eval_expr_bool(fexpr, scratch, g) || return
        end
        # Update inner aggregates
        @inbounds for i in inner_agg_idx
            accs[i] = _agg_update_fast(accs[i], agg_plan[i], scratch)
        end
        return
    end
    pat_obj = inner_triples[idx].object
    for obj in obj_sets[idx]
        if pat_obj isa String
            bv = get(outer_b, pat_obj, nothing)
            if bv isa Identifier
                bv == obj || continue
            end
            scratch[pat_obj::String] = obj
        elseif pat_obj isa Identifier
            pat_obj == obj || continue
        end
        _stream_inner_cross_agg!(scratch, outer_b, s, inner_subj, inner_triples,
                                   obj_sets, idx + 1, n, inner_filters, accs,
                                   inner_agg_idx, agg_plan, g)
    end
end

function _ast_eval_group_aggregate_streaming(q::SparqlSelect, bindings, g)
    n_agg = length(q.aggregates)
    n_gb = length(q.group_by)
    # Per group state: (group_var_values, accumulators)
    groups = Dict{NTuple, Tuple{Vector{Union{Identifier,Nothing}}, Vector{Any}}}()
    group_order = NTuple[]
    # Empty bindings + no group-by: still emit one row of empty-group aggregates
    if isempty(bindings) && isempty(q.group_by)
        result = Dict{String,Identifier}()
        for sa in q.aggregates
            v = _ast_compute_aggregate(sa.agg, Dict{String,Identifier}[])
            v === nothing || (result[sa.alias] = v)
        end
        return Dict{String,Identifier}[result]
    end
    # Pre-classify aggregate plan once: avoids string compares + ExprAggregate
    # field lookups on the hot path. Tuple = (func_id, distinct, var_name, is_star).
    # func_id: 1=COUNT, 2=SUM, 3=AVG, 4=MIN, 5=MAX, 6=SAMPLE
    agg_plan = Vector{Tuple{Int,Bool,String,Bool}}(undef, n_agg)
    @inbounds for i in 1:n_agg
        a = q.aggregates[i].agg
        fi = a.func == "COUNT" ? 1 : a.func == "SUM" ? 2 : a.func == "AVG" ? 3 :
             a.func == "MIN" ? 4 : a.func == "MAX" ? 5 : a.func == "SAMPLE" ? 6 : 0
        is_star = a.arg isa ExprStar
        var = a.arg isa ExprVar ? (a.arg::ExprVar).name : ""
        agg_plan[i] = (fi, a.distinct, var, is_star)
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
            gvals = Union{Identifier,Nothing}[]
            for gb in q.group_by
                push!(gvals, get(b, (gb::ExprVar).name, nothing))
            end
            accs = Any[_agg_init(q.aggregates[i].agg) for i in 1:n_agg]
            @inbounds for i in 1:n_agg
                accs[i] = _agg_update_fast(accs[i], agg_plan[i], b)
            end
            groups[key] = (gvals, accs)
            push!(group_order, key)
        else
            _, accs = st
            @inbounds for i in 1:n_agg
                accs[i] = _agg_update_fast(accs[i], agg_plan[i], b)
            end
        end
    end

    new_bindings = Vector{Dict{String,Identifier}}(undef, length(group_order))
    @inbounds for gi in eachindex(group_order)
        key = group_order[gi]
        gvals, accs = groups[key]
        result = Dict{String,Identifier}()
        for (i, gb) in enumerate(q.group_by)
            gv = gvals[i]
            gv === nothing || (result[(gb::ExprVar).name] = gv)
        end
        for i in 1:n_agg
            v = _agg_finalize(accs[i], q.aggregates[i].agg)
            v === nothing || (result[q.aggregates[i].alias] = v)
        end
        new_bindings[gi] = result
    end
    new_bindings
end

# Initial accumulator state for a streaming aggregate.
# SUM acc = (sum::Float64, kind_rank::Int, error::Bool)
# AVG acc = (sum::Float64, count::Int, kind_rank::Int, error::Bool)
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
        return (0.0, 1, false)
    elseif f == "AVG"
        return (0.0, 0, 1, false)
    elseif f == "MIN" || f == "MAX"
        return nothing
    elseif f == "SAMPLE"
        return nothing
    end
    return nothing
end

@inline function _agg_update(acc, agg::ExprAggregate, b::Dict{String,Identifier})
    f = agg.func
    fi = f == "COUNT" ? 1 : f == "SUM" ? 2 : f == "AVG" ? 3 :
         f == "MIN" ? 4 : f == "MAX" ? 5 : f == "SAMPLE" ? 6 : 0
    arg = agg.arg
    is_star = arg isa ExprStar
    var = arg isa ExprVar ? arg.name : ""
    _agg_update_fast(acc, (fi, agg.distinct, var, is_star), b)
end

# Faster aggregate update: dispatches on pre-classified plan tuple, avoiding
# string compares and ExprAggregate field lookups on the hot path.
@inline function _agg_update_fast(acc, plan::Tuple{Int,Bool,String,Bool},
                                   b::Dict{String,Identifier})
    f, distinct, var, is_star = plan
    if distinct
        s = acc::Set{Identifier}
        if is_star
            # COUNT(DISTINCT *) — dedupe by canonical row representation
            push!(s, Literal(_row_canonical(b)))
        else
            v = get(b, var, nothing)
            v !== nothing && push!(s, v)
        end
        return s
    end
    if f == 1  # COUNT
        if is_star
            return (acc::Int) + 1
        end
        return haskey(b, var) ? (acc::Int) + 1 : acc
    elseif f == 2  # SUM
        v = isempty(var) ? nothing : get(b, var, nothing)
        v === nothing && return acc
        s, kr, err = acc::Tuple{Float64,Int,Bool}
        err && return acc
        tn = _typed_numeric(v)
        tn === nothing && return (s, kr, true)  # type error poisons the aggregate
        return (s + Float64(tn[2]), max(kr, _kind_rank(tn[1])), false)
    elseif f == 3  # AVG
        v = isempty(var) ? nothing : get(b, var, nothing)
        v === nothing && return acc
        s, c, kr, err = acc::Tuple{Float64,Int,Int,Bool}
        err && return acc
        tn = _typed_numeric(v)
        tn === nothing && return (s, c, kr, true)
        return (s + Float64(tn[2]), c + 1, max(kr, _kind_rank(tn[1])), false)
    elseif f == 4  # MIN
        v = isempty(var) ? nothing : get(b, var, nothing)
        v === nothing && return acc
        acc === nothing && return v
        return _agg_lt(v, acc::Identifier) ? v : acc
    elseif f == 5  # MAX
        v = isempty(var) ? nothing : get(b, var, nothing)
        v === nothing && return acc
        acc === nothing && return v
        return _agg_lt(acc::Identifier, v) ? v : acc
    elseif f == 6  # SAMPLE
        if acc === nothing
            v = isempty(var) ? nothing : get(b, var, nothing)
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

# MIN/MAX ordering uses the ORDER BY total order (consistent, deterministic).
@inline function _agg_lt(a::Identifier, b::Identifier)
    _ast_order_cmp(a, b) < 0
end

# Finalize a streaming accumulator. Returns an Identifier or `nothing`
# (unbound) for empty MIN/MAX/SAMPLE/AVG groups and errored SUM/AVG.
# Tolerates the legacy SUM/AVG accumulator shapes (Tuple{Float64,Bool} /
# Tuple{Float64,Int}) still produced by the encoded-store update paths.
function _agg_finalize(acc, agg::ExprAggregate)
    f = agg.func
    if agg.distinct
        s = acc::Set{Identifier}
        if f == "COUNT"
            return Literal(length(s))
        elseif f == "SUM"
            isempty(s) && return Literal(0)
            t = _typed_sum(collect(s))
            t === :error && return nothing
            return _numeric_literal(t[1], t[2])
        elseif f == "AVG"
            isempty(s) && return nothing
            t = _typed_sum(collect(s))
            t === :error && return nothing
            return _numeric_literal(_promote_kind(t[1], :decimal), Float64(t[2]) / length(s))
        elseif f == "MIN" || f == "MAX"
            isempty(s) && return nothing
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
        if acc isa Tuple{Float64,Int,Bool}
            s, kr, err = acc
            err && return nothing
            return _numeric_literal(_rank_kind(kr), s)
        end
        s = (acc::Tuple{Float64,Bool})[1]  # legacy encoded accumulator
        return isinteger(s) ? Literal(Int(s)) : Literal(s)
    elseif f == "AVG"
        if acc isa Tuple{Float64,Int,Int,Bool}
            s, c, kr, err = acc
            err && return nothing
            c == 0 && return Literal(0)  # AVG over empty group = 0 (per spec)
            return _numeric_literal(_promote_kind(_rank_kind(kr), :decimal), s / c)
        end
        s, c = acc::Tuple{Float64,Int}  # legacy encoded accumulator
        return c == 0 ? Literal(0) : Literal(s / c)
    elseif f == "MIN" || f == "MAX" || f == "SAMPLE"
        return acc === nothing ? nothing : acc::Identifier
    end
    return nothing
end

# True if an expression tree contains an aggregate (COUNT/SUM/AVG/...).
_expr_has_aggregate(e::ExprAggregate) = true
_expr_has_aggregate(e::ExprBinaryOp) = _expr_has_aggregate(e.left) || _expr_has_aggregate(e.right)
_expr_has_aggregate(e::ExprUnaryOp) = _expr_has_aggregate(e.arg)
_expr_has_aggregate(e::ExprFunctionCall) = any(_expr_has_aggregate, e.args)
_expr_has_aggregate(e::ExprIn) = _expr_has_aggregate(e.expr) || any(_expr_has_aggregate, e.values)
_expr_has_aggregate(e) = false

# Whether an expression references any variable whose name is in `names`.
_expr_refs_any(e::ExprVar, names) = e.name in names
_expr_refs_any(e::ExprBinaryOp, names) = _expr_refs_any(e.left, names) || _expr_refs_any(e.right, names)
_expr_refs_any(e::ExprUnaryOp, names) = _expr_refs_any(e.arg, names)
_expr_refs_any(e::ExprFunctionCall, names) = any(a -> _expr_refs_any(a, names), e.args)
_expr_refs_any(e::ExprIn, names) = _expr_refs_any(e.expr, names) || any(v -> _expr_refs_any(v, names), e.values)
_expr_refs_any(e::ExprAggregate, names) = _expr_refs_any(e.arg, names)
_expr_refs_any(e, names) = false

"""Recursively find ExprAggregate nodes and stash their computed values in the binding."""
function _ast_stash_agg_values!(expr::ExprAggregate, binding::Dict{String,Identifier}, group)
    v = _ast_compute_aggregate(expr, group)
    v === nothing || (binding["__agg_$(hash(expr))__"] = v)
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

# Canonical row representation for COUNT(DISTINCT *) — dedupe by the actual
# row content, not by hash alone.
function _term_canonical(v)
    v isa URIRef && return "U" * v.value
    v isa BNode && return "B" * v.id
    v isa Literal && return "L" * n3(v)
    "X" * string(v)
end

function _row_canonical(b::Dict{String,Identifier})
    ks = sort!(collect(keys(b)))
    io = IOBuffer()
    for k in ks
        print(io, k, '\x01', _term_canonical(b[k]), '\x02')
    end
    String(take!(io))
end

# Sum a vector of values with typed-numeric semantics.
# Returns (kind, value) or :error (any non-numeric bound value) — the caller
# turns :error into an unbound aggregate result.
function _typed_sum(vals)
    krank = 1
    si = Int64(0)
    sf = 0.0
    any_float = false
    for v in vals
        tn = _typed_numeric(v)
        tn === nothing && return :error
        k, x = tn
        krank = max(krank, _kind_rank(k))
        if x isa Int64 && !any_float
            si += x
        else
            any_float = true
            sf += Float64(x)
        end
    end
    value = any_float ? sf + Float64(si) : si
    (_rank_kind(krank), value)
end

# Compute an aggregate over a fully materialised group.
# Returns an Identifier, or `nothing` (unbound) for empty MIN/MAX/SAMPLE/AVG
# groups and for SUM/AVG groups containing non-numeric (type-error) values.
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
        if agg.distinct
            # COUNT(DISTINCT *) — dedupe by canonical row representation
            Identifier[Literal(_row_canonical(b)) for b in group]
        else
            Identifier[Literal("x") for _ in group]
        end
    elseif !isnothing(var_name)
        Identifier[b[var_name] for b in group if haskey(b, var_name)]
    else
        Identifier[]
    end

    agg.distinct && (vals = unique(vals))

    if agg.func == "COUNT"
        return Literal(length(vals))
    elseif agg.func == "SUM"
        isempty(vals) && return Literal(0)  # SUM over empty group = 0
        s = _typed_sum(vals)
        s === :error && return nothing
        return _numeric_literal(s[1], s[2])
    elseif agg.func == "AVG"
        isempty(vals) && return Literal(0)  # AVG over empty group = 0 (per spec)
        s = _typed_sum(vals)
        s === :error && return nothing
        kind = _promote_kind(s[1], :decimal)  # integer avg promotes to decimal
        return _numeric_literal(kind, Float64(s[2]) / length(vals))
    elseif agg.func == "MIN"
        isempty(vals) && return nothing
        best = vals[1]
        for v in @view vals[2:end]
            _agg_lt(v, best) && (best = v)
        end
        return best
    elseif agg.func == "MAX"
        isempty(vals) && return nothing
        best = vals[1]
        for v in @view vals[2:end]
            _agg_lt(best, v) && (best = v)
        end
        return best
    elseif agg.func == "SAMPLE"
        return isempty(vals) ? nothing : first(vals)
    elseif agg.func == "GROUP_CONCAT"
        sep = something(agg.separator, " ")
        strs = [v isa Literal ? v.lexical : string(v) for v in vals]
        return Literal(join(strs, sep))  # empty group → "" per spec
    elseif agg.func == "MEDIAN"
        nums = sort(filter(!isnothing, [_ast_to_numeric(v) for v in vals]))
        isempty(nums) && return nothing
        mid = div(length(nums) + 1, 2)
        result = iseven(length(nums)) ? (nums[mid] + nums[mid+1]) / 2 : nums[mid]
        # Return Int if the result is a whole number
        return Literal(isinteger(result) ? Int(result) : result)
    elseif agg.func == "MODE"
        isempty(vals) && return nothing
        counts = Dict{Identifier, Int}()
        for v in vals
            counts[v] = get(counts, v, 0) + 1
        end
        return first(sort(collect(keys(counts)), by=k->counts[k], rev=true))
    end
    nothing
end

# ─── ORDER BY comparison ──────────────────────────────────────────

# Try to compute numeric (Float64) sort keys for ORDER BY when every
# expr is a bare ExprVar and every binding produces a numeric Literal.
# Returns Vector{Float64} for single ORDER BY (DESC encoded as -value),
# Vector{NTuple{N,Float64}} for multiple, or nothing if any binding is
# non-numeric.
function _ast_try_numeric_sort_keys(bindings, order_by)
    n = length(order_by)
    if n == 1
        expr, dir = order_by[1]
        var = (expr::ExprVar).name
        sign = dir == :desc ? -1.0 : 1.0
        keys = Vector{Float64}(undef, length(bindings))
        @inbounds for i in eachindex(bindings)
            v = get(bindings[i], var, nothing)
            x = _ast_literal_float64(v)
            x === nothing && return nothing
            keys[i] = sign * x
        end
        return keys
    else
        # Multi-key path: build NTuple of signed Float64 per row.
        signs = ntuple(i -> order_by[i][2] == :desc ? -1.0 : 1.0, n)
        vars = ntuple(i -> (order_by[i][1]::ExprVar).name, n)
        keys = Vector{NTuple{n,Float64}}(undef, length(bindings))
        @inbounds for i in eachindex(bindings)
            b = bindings[i]
            row = ntuple(n) do j
                v = get(b, vars[j], nothing)
                x = _ast_literal_float64(v)
                x === nothing ? NaN : signs[j] * x
            end
            any(isnan, row) && return nothing
            keys[i] = row
        end
        return keys
    end
end

@inline function _ast_literal_float64(v)
    # Only numeric-typed literals participate in the numeric sort fast path;
    # mixed/non-numeric values fall back to the total-order comparator.
    tn = _typed_numeric(v)
    tn === nothing && return nothing
    x = Float64(tn[2])
    isnan(x) && return nothing
    x
end

# ORDER BY total order (SPARQL §15.1):
#   unbound < blank nodes < IRIs (by codepoint) < literals
# Within literals: numeric by value, strings by codepoint, booleans and
# dateTimes by value; remaining literals are grouped by datatype IRI then
# lexical form (any consistent total order is allowed there).
@inline function _order_group(v)
    v === nothing && return 0
    v isa BNode && return 1
    v isa URIRef && return 2
    v isa Literal && return 3
    4  # triple terms and anything else last
end

# Literal subclass for ordering: 0=numeric, 1=string, 2=langString,
# 3=boolean, 4=dateTime/date, 5=other
@inline function _lit_order_class(l::Literal)
    _typed_numeric(l) !== nothing && return 0
    _is_string_lit(l) && return 1
    l.language !== nothing && return 2
    _is_boolean_lit(l) && return 3
    _datetime_class(l) !== nothing && return 4
    5
end

# Three-way comparison implementing the total order. Returns -1/0/1.
function _ast_order_cmp(a, b)
    ga = _order_group(a)
    gb = _order_group(b)
    ga != gb && return ga < gb ? -1 : 1
    ga == 0 && return 0
    a isa BNode && return cmp(a.id, (b::BNode).id)
    a isa URIRef && return cmp(a.value, (b::URIRef).value)
    if a isa Literal && b isa Literal
        ca = _lit_order_class(a)
        cb = _lit_order_class(b)
        ca != cb && return ca < cb ? -1 : 1
        if ca == 0  # numeric by value (NaN sorts last among numerics)
            va = _typed_numeric(a)[2]
            vb = _typed_numeric(b)[2]
            na = va isa Float64 && isnan(va)
            nb = vb isa Float64 && isnan(vb)
            if na || nb
                (na && nb) || return na ? 1 : -1
            elseif va != vb
                return va < vb ? -1 : 1
            end
        elseif ca == 1  # strings by codepoint
            c = cmp(a.lexical, b.lexical)
            c != 0 && return c
        elseif ca == 2  # lang-tagged: language tag, then lexical
            c = cmp(something(a.language, ""), something(b.language, ""))
            c != 0 && return c
            c = cmp(a.lexical, b.lexical)
            c != 0 && return c
        elseif ca == 3  # booleans: false < true
            ba = _bool_value(a); bb = _bool_value(b)
            ba != bb && return ba ? 1 : -1
        elseif ca == 4  # dateTime/date by value
            c = try
                da = _datetime_class(a) === :date ? DateTime(parse_xsd_date(a.lexical)) :
                                                    parse_xsd_datetime(a.lexical)
                db = _datetime_class(b) === :date ? DateTime(parse_xsd_date(b.lexical)) :
                                                    parse_xsd_datetime(b.lexical)
                da < db ? -1 : da > db ? 1 : 0
            catch
                cmp(a.lexical, b.lexical)
            end
            c != 0 && return c
        end
        # Consistent tie-breaking within a class: datatype IRI then lexical
        c = cmp(a.datatype === nothing ? "" : a.datatype.value,
                b.datatype === nothing ? "" : b.datatype.value)
        c != 0 && return c
        return cmp(a.lexical, b.lexical)
    end
    cmp(string(a), string(b))
end

function _ast_order_compare(a, b, order_by, g)
    for (expr, dir) in order_by
        va = expr isa ExprVar ? get(a, expr.name, nothing) : _ast_eval_expr(expr, a, g)
        vb = expr isa ExprVar ? get(b, expr.name, nothing) : _ast_eval_expr(expr, b, g)
        c = _ast_order_cmp(va, vb)
        c == 0 && continue
        return dir == :asc ? c < 0 : c > 0
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
    "SELECT * WHERE { " * _patterns_to_sparql(patterns) * " }"
end

# Serialize a pattern group back to SPARQL text for remote (SERVICE)
# execution. Raises for anything that cannot be faithfully serialized.
function _patterns_to_sparql(patterns::Vector{SparqlPattern})
    parts = String[]
    for p in patterns
        if p isa PatTriple
            p.predicate isa PathExpr && !(p.predicate isa PathURI) &&
                error("SERVICE: property paths cannot be serialized for remote execution")
            s = _term_to_sparql(p.subject)
            pred = _term_to_sparql(p.predicate)
            o = _term_to_sparql(p.object)
            push!(parts, "$s $pred $o .")
        elseif p isa PatFilter
            push!(parts, "FILTER(" * _expr_to_sparql(p.expr) * ")")
        elseif p isa PatBind
            push!(parts, "BIND(" * _expr_to_sparql(p.expr) * " AS ?" * p.var * ")")
        elseif p isa PatOptional
            push!(parts, "OPTIONAL { " * _patterns_to_sparql(p.patterns) * " }")
        elseif p isa PatUnion
            push!(parts, join(("{ " * _patterns_to_sparql(br) * " }" for br in p.branches),
                              " UNION "))
        elseif p isa PatFilterExists
            push!(parts, "FILTER " * (p.negated ? "NOT EXISTS" : "EXISTS") *
                         " { " * _patterns_to_sparql(p.patterns) * " }")
        else
            error("SERVICE: cannot serialize pattern of type $(typeof(p)) for remote execution")
        end
    end
    join(parts, " ")
end

function _expr_to_sparql(e)::String
    e isa ExprVar && return "?" * e.name
    e isa ExprLiteral && return n3(e.value)
    e isa ExprURI && return "<" * e.uri.value * ">"
    e isa ExprBool && return e.value ? "true" : "false"
    if e isa ExprBinaryOp
        op = e.op == :(==) ? "=" : string(e.op)
        return "(" * _expr_to_sparql(e.left) * " " * op * " " * _expr_to_sparql(e.right) * ")"
    end
    e isa ExprUnaryOp && return string(e.op) * "(" * _expr_to_sparql(e.arg) * ")"
    if e isa ExprFunctionCall
        fname = startswith(e.name, "http://") || startswith(e.name, "https://") ?
                "<" * e.name * ">" : e.name
        return fname * "(" * join((_expr_to_sparql(a) for a in e.args), ", ") * ")"
    end
    if e isa ExprIn
        return "(" * _expr_to_sparql(e.expr) * (e.negated ? " NOT IN (" : " IN (") *
               join((_expr_to_sparql(v) for v in e.values), ", ") * "))"
    end
    error("SERVICE: cannot serialize expression of type $(typeof(e)) for remote execution")
end

function _term_to_sparql(t)
    t isa String && return "?$t"
    t isa URIRef && return "<$(t.value)>"
    t isa Literal && return n3(t)
    t isa BNode && return "_:$(t.id)"
    t isa PathURI && return "<$(t.uri.value)>"
    t isa ExprVar && return "?$(t.name)"
    t isa ExprURI && return "<$(t.uri.value)>"
    t isa ExprLiteral && return n3(t.value)
    error("SERVICE: cannot serialize term $(typeof(t)) for remote execution")
end
