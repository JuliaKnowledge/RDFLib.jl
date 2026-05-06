# ═══════════════════════════════════════════════════════════════════
# SPARQL Evaluator — EncodedStore fast paths
# ═══════════════════════════════════════════════════════════════════
#
# Mirrors the MemoryStore eval functions in sparql_eval.jl but operates
# on UInt32 ids end-to-end inside the inner loops. Bindings remain
# Dict{String,Identifier} (so the rest of the evaluator pipeline is
# unchanged); we lazily encode bound values on entry to a star group and
# decode UInt32 → Identifier only when emitting a bound row.

# ─── Helpers ────────────────────────────────────────────────────────

@inline _enc_decode(store::EncodedStore, id::UInt32) = store.id_to_term[id]

# Look up id of a term that might already be in the dictionary.
# Returns 0 if absent (means: cannot match anything in the store).
@inline function _enc_id(store::EncodedStore, t::Identifier)::UInt32
    return get(store.term_to_id, t, UInt32(0))
end

# ─── Single-pattern BGP on EncodedStore ─────────────────────────────

function _ast_eval_bgp_encoded(store::EncodedStore, pat::PatTriple,
                                binding::Dict{String,Identifier},
                                s_val, p_val, o_val)
    _ensure_all_indexed!(store)
    results = Dict{String,Identifier}[]

    s_bound = s_val isa Identifier
    p_bound = p_val isa Identifier
    o_bound = o_val isa Identifier

    s_id = s_bound ? _enc_id(store, s_val) : UInt32(0)
    p_id = p_bound ? _enc_id(store, p_val) : UInt32(0)
    o_id = o_bound ? _enc_id(store, o_val) : UInt32(0)
    # Bound term not in dictionary → no matches possible
    (s_bound && s_id == 0) && return results
    (p_bound && p_id == 0) && return results
    (o_bound && o_id == 0) && return results

    if s_bound && p_bound && o_bound
        sp = get(store.spo_enc, s_id, nothing)
        sp === nothing && return results
        objs = get(sp, p_id, nothing)
        objs === nothing && return results
        if o_id in objs
            push!(results, copy(binding))
        end
    elseif s_bound && p_bound
        sp = get(store.spo_enc, s_id, nothing)
        sp === nothing && return results
        objs = get(sp, p_id, nothing)
        objs === nothing && return results
        for o_eid in objs
            new_b = copy(binding)
            o_term = _enc_decode(store, o_eid)
            _ast_match_term(o_term, pat.object, o_val, new_b) && push!(results, new_b)
        end
    elseif s_bound && o_bound
        os = get(store.osp_enc, o_id, nothing)
        os === nothing && return results
        preds = get(os, s_id, nothing)
        preds === nothing && return results
        for p_eid in preds
            new_b = copy(binding)
            p_term = _enc_decode(store, p_eid)
            _ast_match_term(p_term, pat.predicate, p_val, new_b) && push!(results, new_b)
        end
    elseif p_bound && o_bound
        po = get(store.pos_enc, p_id, nothing)
        po === nothing && return results
        subjs = get(po, o_id, nothing)
        subjs === nothing && return results
        for s_eid in subjs
            new_b = copy(binding)
            s_term = _enc_decode(store, s_eid)
            _ast_match_term(s_term, pat.subject, s_val, new_b) && push!(results, new_b)
        end
    elseif s_bound
        sp = get(store.spo_enc, s_id, nothing)
        sp === nothing && return results
        for (p_eid, objs) in sp
            p_term = _enc_decode(store, p_eid)
            for o_eid in objs
                new_b = copy(binding)
                ok = _ast_match_term(p_term, pat.predicate, p_val, new_b)
                ok && (ok = _ast_match_term(_enc_decode(store, o_eid), pat.object, o_val, new_b))
                ok && push!(results, new_b)
            end
        end
    elseif p_bound
        po = get(store.pos_enc, p_id, nothing)
        po === nothing && return results
        for (o_eid, subjs) in po
            o_term = _enc_decode(store, o_eid)
            for s_eid in subjs
                new_b = copy(binding)
                ok = _ast_match_term(_enc_decode(store, s_eid), pat.subject, s_val, new_b)
                ok && (ok = _ast_match_term(o_term, pat.object, o_val, new_b))
                ok && push!(results, new_b)
            end
        end
    elseif o_bound
        os = get(store.osp_enc, o_id, nothing)
        os === nothing && return results
        for (s_eid, preds) in os
            s_term = _enc_decode(store, s_eid)
            for p_eid in preds
                new_b = copy(binding)
                ok = _ast_match_term(s_term, pat.subject, s_val, new_b)
                ok && (ok = _ast_match_term(_enc_decode(store, p_eid), pat.predicate, p_val, new_b))
                ok && push!(results, new_b)
            end
        end
    else
        # ??? scan
        for et in store.insertion_order_enc
            new_b = copy(binding)
            ok = _ast_match_term(_enc_decode(store, et[1]), pat.subject, s_val, new_b)
            ok && (ok = _ast_match_term(_enc_decode(store, et[2]), pat.predicate, p_val, new_b))
            ok && (ok = _ast_match_term(_enc_decode(store, et[3]), pat.object, o_val, new_b))
            ok && push!(results, new_b)
        end
    end
    results
end

# ─── Star-join on EncodedStore ──────────────────────────────────────
# Mirrors _ast_eval_star_memory but all hot-path lookups are on UInt32.

function _ast_eval_star_encoded(store::EncodedStore, pats,
                                 bindings::Vector{Dict{String,Identifier}}, limit::Int)
    subj_var = pats[1].subject::String
    n = length(pats)
    pred_uris = URIRef[pats[i].predicate::URIRef for i in 1:n]
    results = Dict{String,Identifier}[]

    _ensure_all_indexed!(store)

    # Encode pred URIs once
    pred_ids = Vector{UInt32}(undef, n)
    @inbounds for i in 1:n
        pid = _enc_id(store, pred_uris[i])
        pid == 0 && return results
        pred_ids[i] = pid
    end

    # Pre-resolve POS buckets and statically-bound objects (encoded)
    pos_buckets_enc = Vector{Dict{UInt32, Set{UInt32}}}(undef, n)
    static_bound_subjects = nothing  # Set{UInt32} or nothing
    @inbounds for i in 1:n
        po = get(store.pos_enc, pred_ids[i], nothing)
        po === nothing && return results
        pos_buckets_enc[i] = po
        obj = pats[i].object
        if obj isa Identifier
            obj_id = _enc_id(store, obj)
            obj_id == 0 && return results
            subjs = get(po, obj_id, nothing)
            subjs === nothing && return results
            if static_bound_subjects === nothing || length(subjs) < length(static_bound_subjects)
                static_bound_subjects = subjs
            end
        end
    end

    obj_sets_enc = Vector{Set{UInt32}}(undef, n)
    obj_firsts_enc = Vector{UInt32}(undef, n)

    for b in bindings
        s_val = get(b, subj_var, nothing)
        if s_val isa Identifier
            s_id = _enc_id(store, s_val)
            if s_id != 0
                _star_check_enc!(results, store, b, s_id, subj_var, pats, pred_ids,
                                 obj_sets_enc, obj_firsts_enc, n, limit)
            end
        else
            driver = static_bound_subjects
            skip_binding = false
            @inbounds for i in 1:n
                obj = pats[i].object
                if obj isa String
                    bv = get(b, obj, nothing)
                    if bv isa Identifier
                        bv_id = _enc_id(store, bv)
                        if bv_id == 0
                            skip_binding = true; break
                        end
                        subjs = get(pos_buckets_enc[i], bv_id, nothing)
                        if subjs === nothing
                            skip_binding = true; break
                        end
                        if driver === nothing || length(subjs) < length(driver)
                            driver = subjs
                        end
                    end
                end
            end
            skip_binding && continue

            if driver isa Set{UInt32}
                for s_id in driver
                    _star_check_enc!(results, store, b, s_id, subj_var, pats, pred_ids,
                                     obj_sets_enc, obj_firsts_enc, n, limit)
                    limit > 0 && length(results) >= limit && break
                end
            elseif driver === nothing && _any_bound_obj_var_enc(pats, n, b)
                # Some object var was bound but had no matches → skip
            else
                for (s_id, _) in store.spo_enc
                    _star_check_enc!(results, store, b, s_id, subj_var, pats, pred_ids,
                                     obj_sets_enc, obj_firsts_enc, n, limit)
                    limit > 0 && length(results) >= limit && break
                end
            end
        end
        limit > 0 && length(results) >= limit && break
    end
    results
end

@inline function _any_bound_obj_var_enc(pats, n::Int, b::Dict{String,Identifier})
    @inbounds for i in 1:n
        o = pats[i].object
        if o isa String && haskey(b, o)
            return true
        end
    end
    return false
end

@inline function _star_check_enc!(results, store::EncodedStore, b, s_id::UInt32,
                                   subj_var, pats, pred_ids,
                                   obj_sets, obj_firsts, n, limit)
    sp = get(store.spo_enc, s_id, nothing)
    sp === nothing && return
    @inbounds for i in 1:n
        os = get(sp, pred_ids[i], nothing)
        os === nothing && return
        obj_sets[i] = os
    end
    all_single = true
    @inbounds for i in 1:n
        length(obj_sets[i]) != 1 && (all_single = false; break)
    end
    if all_single
        @inbounds for i in 1:n
            obj_firsts[i] = first(obj_sets[i])
        end
        # Pre-validate objects
        @inbounds for i in 1:n
            obj_id = obj_firsts[i]
            pat_obj = pats[i].object
            if pat_obj isa String
                bv = get(b, pat_obj, nothing)
                if bv !== nothing
                    bv_id = _enc_id(store, bv)
                    bv_id == obj_id || return
                end
            elseif pat_obj isa Identifier
                pat_id = _enc_id(store, pat_obj)
                pat_id == obj_id || return
            else
                resolved = _ast_resolve_term(pat_obj, b)
                resolved === nothing && return
                rid = _enc_id(store, resolved)
                rid == obj_id || return
            end
        end
        # Emit row — decode on demand
        new_b = copy(b)
        if !haskey(new_b, subj_var)
            new_b[subj_var] = _enc_decode(store, s_id)
        end
        @inbounds for i in 1:n
            pat_obj = pats[i].object
            if pat_obj isa String
                if !haskey(new_b, pat_obj)
                    new_b[pat_obj] = _enc_decode(store, obj_firsts[i])
                end
            end
        end
        push!(results, new_b)
    else
        # Multi-valued: cross-product with decoded objects (rare path)
        new_b = copy(b)
        if !haskey(new_b, subj_var)
            new_b[subj_var] = _enc_decode(store, s_id)
        end
        _star_cross_enc!(results, store, new_b, obj_sets, pats, 1, n, limit)
    end
end

function _star_cross_enc!(results, store::EncodedStore, b, obj_sets, pats, idx, n, limit)
    if idx > n
        push!(results, copy(b))
        return
    end
    pat_obj = pats[idx].object
    for obj_id in obj_sets[idx]
        obj_term = _enc_decode(store, obj_id)
        if pat_obj isa String
            existing = get(b, pat_obj, nothing)
            if existing !== nothing
                existing == obj_term || continue
                _star_cross_enc!(results, store, b, obj_sets, pats, idx + 1, n, limit)
            else
                b[pat_obj] = obj_term
                _star_cross_enc!(results, store, b, obj_sets, pats, idx + 1, n, limit)
                delete!(b, pat_obj)
            end
        else
            resolved = pat_obj isa URIRef ? pat_obj : (pat_obj isa Literal ? pat_obj :
                       (pat_obj isa BNode ? pat_obj : nothing))
            (resolved !== nothing && resolved == obj_term) || continue
            _star_cross_enc!(results, store, b, obj_sets, pats, idx + 1, n, limit)
        end
        limit > 0 && length(results) >= limit && return
    end
end

# ─── Star + Filter on EncodedStore ──────────────────────────────────

function _ast_eval_star_filter_encoded(g::RDFGraph, store::EncodedStore, pats,
                                        filters::Vector{SparqlExpr},
                                        bindings::Vector{Dict{String,Identifier}}, limit::Int)
    subj_var = pats[1].subject::String
    n = length(pats)
    pred_uris = URIRef[pats[i].predicate::URIRef for i in 1:n]
    results = Dict{String,Identifier}[]

    _ensure_all_indexed!(store)
    pred_ids = Vector{UInt32}(undef, n)
    @inbounds for i in 1:n
        pid = _enc_id(store, pred_uris[i])
        pid == 0 && return results
        pred_ids[i] = pid
    end

    obj_sets_enc = Vector{Set{UInt32}}(undef, n)

    for b in bindings
        s_val = get(b, subj_var, nothing)
        if s_val isa Identifier
            s_id = _enc_id(store, s_val)
            if s_id != 0
                _star_filter_check_enc!(results, g, store, b, s_id, subj_var, pats,
                                        pred_ids, obj_sets_enc, n, filters, limit)
            end
        else
            for (s_id, _) in store.spo_enc
                _star_filter_check_enc!(results, g, store, b, s_id, subj_var, pats,
                                        pred_ids, obj_sets_enc, n, filters, limit)
                limit > 0 && length(results) >= limit && break
            end
        end
        limit > 0 && length(results) >= limit && break
    end
    results
end

@inline function _star_filter_check_enc!(results, g, store::EncodedStore, b, s_id::UInt32,
                                          subj_var, pats, pred_ids, obj_sets, n, filters, limit)
    sp = get(store.spo_enc, s_id, nothing)
    sp === nothing && return
    @inbounds for i in 1:n
        os = get(sp, pred_ids[i], nothing)
        os === nothing && return
        obj_sets[i] = os
    end
    all_single = true
    @inbounds for i in 1:n
        length(obj_sets[i]) != 1 && (all_single = false; break)
    end
    if all_single
        new_b = copy(b)
        if !haskey(new_b, subj_var)
            new_b[subj_var] = _enc_decode(store, s_id)
        end
        @inbounds for i in 1:n
            obj_id = first(obj_sets[i])
            obj = _enc_decode(store, obj_id)
            pat_obj = pats[i].object
            resolved = pat_obj isa String ? nothing : _ast_resolve_term(pat_obj, new_b)
            _ast_match_term(obj, pat_obj, resolved, new_b) || return
        end
        for f in filters
            _ast_eval_expr_bool(f, new_b, g) || return
        end
        push!(results, new_b)
    else
        new_b = copy(b)
        if !haskey(new_b, subj_var)
            new_b[subj_var] = _enc_decode(store, s_id)
        end
        _star_cross_filter_enc!(results, g, store, new_b, obj_sets, pats, filters, 1, n, limit)
    end
end

function _star_cross_filter_enc!(results, g, store::EncodedStore, b, obj_sets, pats,
                                  filters, idx, n, limit)
    if idx > n
        for f in filters
            _ast_eval_expr_bool(f, b, g) || return
        end
        push!(results, copy(b))
        return
    end
    pat_obj = pats[idx].object
    for obj_id in obj_sets[idx]
        obj_term = _enc_decode(store, obj_id)
        if pat_obj isa String
            existing = get(b, pat_obj, nothing)
            if existing !== nothing
                existing == obj_term || continue
                _star_cross_filter_enc!(results, g, store, b, obj_sets, pats, filters,
                                        idx + 1, n, limit)
            else
                b[pat_obj] = obj_term
                _star_cross_filter_enc!(results, g, store, b, obj_sets, pats, filters,
                                        idx + 1, n, limit)
                delete!(b, pat_obj)
            end
        else
            resolved = pat_obj isa URIRef ? pat_obj : (pat_obj isa Literal ? pat_obj :
                       (pat_obj isa BNode ? pat_obj : nothing))
            (resolved !== nothing && resolved == obj_term) || continue
            _star_cross_filter_enc!(results, g, store, b, obj_sets, pats, filters,
                                    idx + 1, n, limit)
        end
        limit > 0 && length(results) >= limit && return
    end
end

# ─── Patterns dispatch for EncodedStore ─────────────────────────────

function _ast_eval_patterns_star_encoded(g::RDFGraph, patterns::Vector{SparqlPattern},
                                          bindings::Vector{Dict{String,Identifier}}, limit::Int)
    store = g.store::EncodedStore
    i = 1
    n = length(patterns)
    while i <= n
        star_end = _star_group_end(patterns, i)
        if star_end > i
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
                bindings = _ast_eval_star_encoded(store, star_pats, bindings, eff_limit)
            else
                bindings = _ast_eval_star_filter_encoded(g, store, star_pats, filters,
                                                         bindings, eff_limit)
            end
            i = j
        else
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

# Selectivity-based star-group reordering for EncodedStore (mirror of
# _reorder_star_groups but uses pos_enc for size estimation).
function _reorder_star_groups_encoded(store::EncodedStore, patterns::Vector{SparqlPattern})
    n = length(patterns)
    groups = Tuple{Int,Int,Int,Int,Set{String},Set{String}}[]
    i = 1
    while i <= n
        pat = patterns[i]
        if !(pat isa PatTriple) || !(pat.subject isa String) ||
           !(pat.predicate isa URIRef)
            break
        end
        send = _star_group_end(patterns, i)
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
            for fv in fvars
                if !(fv in consumed)
                    ok = false; break
                end
            end
            ok || break
            fend = j
            j += 1
        end
        if !ok
            push!(groups, (i, send, fend, _star_size_encoded(store, patterns, i, send),
                           produced, consumed))
            i = fend + 1
            break
        end
        push!(groups, (i, send, fend, _star_size_encoded(store, patterns, i, send),
                       produced, consumed))
        i = fend + 1
    end
    if length(groups) <= 1 || i <= n
        # If we broke out, append remaining patterns unchanged
        return patterns
    end
    # Sort groups: bound objects (smaller estimate) first; ties broken by index.
    # But preserve join-feasibility: a group can come earlier only if its
    # consumed vars are produced by groups already placed.
    placed = Set{String}()
    remaining = collect(1:length(groups))
    out_idx = Int[]
    while !isempty(remaining)
        # Find min-size group whose consumed vars ⊆ placed (or has no consumed).
        best = 0; best_size = typemax(Int)
        for k in remaining
            consumed = groups[k][6]
            # The subject var of a star group is always consumed AND produced
            # by itself; only object vars must be already placed.
            obj_consumed = setdiff(consumed, [patterns[groups[k][1]].subject::String])
            if all(v -> v in placed, obj_consumed)
                if groups[k][4] < best_size
                    best = k; best_size = groups[k][4]
                end
            end
        end
        if best == 0
            # No feasible group; fall back to original order
            return patterns
        end
        push!(out_idx, best)
        union!(placed, groups[best][5])
        deleteat!(remaining, findfirst(==(best), remaining))
    end
    if out_idx == collect(1:length(groups))
        return patterns
    end
    # Materialize new order
    new_pats = SparqlPattern[]
    for k in out_idx
        gst, gend, fend = groups[k][1], groups[k][2], groups[k][3]
        for q in gst:fend
            push!(new_pats, patterns[q])
        end
    end
    return new_pats
end

# Estimate the "driver" size of a star group on EncodedStore: smallest POS
# bucket among its bound-object predicates; fall back to predicate count if
# none bound.
function _star_size_encoded(store::EncodedStore, patterns::Vector{SparqlPattern},
                             i::Int, send::Int)
    _ensure_all_indexed!(store)
    best = typemax(Int)
    found = false
    @inbounds for k in i:send
        pat = patterns[k]::PatTriple
        pred = pat.predicate
        pred isa URIRef || continue
        pid = _enc_id(store, pred)
        pid == 0 && return 0
        po = get(store.pos_enc, pid, nothing)
        po === nothing && return 0
        obj = pat.object
        if obj isa Identifier
            oid = _enc_id(store, obj)
            oid == 0 && return 0
            subjs = get(po, oid, nothing)
            subjs === nothing && return 0
            sz = length(subjs)
            if sz < best; best = sz; found = true; end
        end
    end
    if !found
        # No statically-bound objects; estimate by smallest predicate POS extent
        @inbounds for k in i:send
            pat = patterns[k]::PatTriple
            pred = pat.predicate
            pred isa URIRef || continue
            pid = _enc_id(store, pred)
            po = get(store.pos_enc, pid, nothing)
            po === nothing && return 0
            ext = sum(length(s) for s in values(po); init=0)
            if ext < best; best = ext; end
        end
    end
    return best
end
