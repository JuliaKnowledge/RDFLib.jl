# ═══════════════════════════════════════════════════════════════════
# SPARQL Evaluator — walks the AST produced by sparql_parser.jl
# ═══════════════════════════════════════════════════════════════════
#
# Evaluates SparqlQuery AST nodes against an RDFGraph, producing
# results in the same format as the legacy evaluator.

const _XSD_NS = "http://www.w3.org/2001/XMLSchema#"

# ─── Top-level evaluation ─────────────────────────────────────────

function _ast_evaluate(g::RDFGraph, q::SparqlSelect)
    bindings = _ast_eval_patterns(g, q.patterns)

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

    # ORDER BY
    if !isempty(q.order_by)
        sort!(bindings, lt=(a, b) -> _ast_order_compare(a, b, q.order_by, g))
    end

    # Project variables
    proj_vars = _ast_projection_vars(q)
    if !isempty(proj_vars)
        bindings = [Dict{String,Identifier}(v => b[v] for v in proj_vars if haskey(b, v)) for b in bindings]
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

function _ast_evaluate(g::RDFGraph, q::SparqlConstruct)
    bindings = _ast_eval_patterns(g, q.patterns)
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
    # Apply LIMIT/OFFSET to constructed triples if specified
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
                             bindings::Vector{Dict{String,Identifier}} = Dict{String,Identifier}[Dict{String,Identifier}()])
    for pattern in patterns
        bindings = _ast_eval_pattern(g, pattern, bindings)
        isempty(bindings) && return bindings
    end
    bindings
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
    _geo_rel = Dict("sfcontains"=>geo_contains, "sfwithin"=>geo_within,
        "sfintersects"=>geo_intersects, "sfoverlaps"=>geo_overlaps,
        "sftouches"=>geo_touches, "sfdisjoint"=>geo_disjoint, "sfequals"=>geo_equals)
    if haskey(_geo_rel, func_name) && length(eval_args) >= 2
        g1 = _extract_wkt_geometry(eval_args[1])
        g2 = _extract_wkt_geometry(eval_args[2])
        (isnothing(g1) || isnothing(g2)) && return nothing
        return Literal(_geo_rel[func_name](g1, g2))
    end
    if func_name == "buffer" && length(eval_args) >= 2
        g1 = _extract_wkt_geometry(eval_args[1])
        d = _ast_to_numeric(eval_args[2])
        (isnothing(g1) || isnothing(d)) && return nothing
        return Literal(geo_to_wkt(geo_buffer(g1, Float64(d))))
    end
    nothing
end

# ─── Aggregate computation ────────────────────────────────────────

function _ast_eval_group_aggregate(q::SparqlSelect, bindings, g)
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

    vals = if is_star
        Identifier[Literal("x") for _ in group]  # dummy for COUNT(*)
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
