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

# ─── Encoded-Binding (EB) pipeline ──────────────────────────────────
#
# An EncBinding is a Dict{String, UInt32} where each entry is a variable
# name -> store-interned UInt32 id. Bindings flow through the encoded
# BGP pipeline as Vector{EncBinding} so that join inner loops operate
# on UInt32 throughout, never paying full Identifier hash/eq.
#
# Decoding to Dict{String, Identifier} happens only when:
#   * Filter / BIND / expression evaluation needs Identifier values
#   * Returning final results to the SPARQL evaluator caller
#
# Sentinel: an entry with id 0 means "value bound but not present in
# store dict" — such bindings will fail any subsequent join, but may be
# valid in projection (handled by tracking the original Identifier in
# `extras_of(eb)` only when needed; in BGP-only runs this never arises
# because all bound values come from store matches, hence have id > 0).

const EncBinding = Dict{String, UInt32}

"""Encode a single Identifier-binding to an EncBinding. Returns
`nothing` if any value is not in the store dict (binding cannot match
anything in subsequent joins)."""
function _encode_one_binding(store::EncodedStore, b::Dict{String,Identifier})
    eb = EncBinding()
    sizehint!(eb, length(b))
    for (k, v) in b
        id = get(store.term_to_id, v, UInt32(0))
        id == 0 && return nothing
        eb[k] = id
    end
    return eb
end

"""Encode a vector of Identifier-bindings, dropping infeasible ones."""
function _encode_bindings(store::EncodedStore, bs::Vector{Dict{String,Identifier}})
    out = EncBinding[]
    sizehint!(out, length(bs))
    for b in bs
        eb = _encode_one_binding(store, b)
        eb === nothing || push!(out, eb)
    end
    out
end

"""Decode a single EncBinding back to a Dict{String, Identifier}."""
@inline function _decode_one_binding(store::EncodedStore, eb::EncBinding)
    b = Dict{String,Identifier}()
    sizehint!(b, length(eb))
    @inbounds for (k, id) in eb
        b[k] = store.id_to_term[id]
    end
    b
end

"""Decode a vector of EncBindings back."""
function _decode_bindings(store::EncodedStore, ebs::Vector{EncBinding})
    out = Vector{Dict{String,Identifier}}(undef, length(ebs))
    @inbounds for i in eachindex(ebs)
        out[i] = _decode_one_binding(store, ebs[i])
    end
    out
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

# ─── EB star evaluator (encoded bindings end-to-end) ────────────────
#
# Mirrors `_ast_eval_star_encoded` but uses Vector{EncBinding} for both
# input and output. All inner-loop joins are pure UInt32; no Identifier
# hash/eq is paid per binding.

function _ast_eval_star_eb(store::EncodedStore, pats,
                            ebs::Vector{EncBinding}, limit::Int)
    subj_var = pats[1].subject::String
    n = length(pats)
    pred_uris = URIRef[pats[i].predicate::URIRef for i in 1:n]
    results = EncBinding[]

    pred_ids = Vector{UInt32}(undef, n)
    @inbounds for i in 1:n
        pid = _enc_id(store, pred_uris[i])
        pid == 0 && return results
        pred_ids[i] = pid
    end

    # Pre-resolve POS buckets (one per pattern) and statically-bound subjects.
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

    # Pre-compute static (Identifier) object ids for fast pattern-vs-store check.
    static_obj_ids = Vector{UInt32}(undef, n)
    @inbounds for i in 1:n
        obj = pats[i].object
        if obj isa Identifier
            static_obj_ids[i] = _enc_id(store, obj)  # already > 0 (checked above)
        else
            static_obj_ids[i] = UInt32(0)
        end
    end

    for eb in ebs
        s_id = get(eb, subj_var, UInt32(0))
        if s_id != 0
            _star_check_eb!(results, store, eb, s_id, subj_var, pats, pred_ids,
                            obj_sets_enc, obj_firsts_enc, static_obj_ids, n, limit)
        else
            # Subject not yet bound — find driver via most selective constraint.
            driver = static_bound_subjects
            skip_binding = false
            @inbounds for i in 1:n
                obj = pats[i].object
                if obj isa String
                    bv_id = get(eb, obj, UInt32(0))
                    if bv_id != 0
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
                    _star_check_eb!(results, store, eb, s_id, subj_var, pats, pred_ids,
                                    obj_sets_enc, obj_firsts_enc, static_obj_ids, n, limit)
                    limit > 0 && length(results) >= limit && break
                end
            else
                # Full subject scan
                for (s_id, _) in store.spo_enc
                    _star_check_eb!(results, store, eb, s_id, subj_var, pats, pred_ids,
                                    obj_sets_enc, obj_firsts_enc, static_obj_ids, n, limit)
                    limit > 0 && length(results) >= limit && break
                end
            end
        end
        limit > 0 && length(results) >= limit && break
    end
    results
end

@inline function _star_check_eb!(results, store::EncodedStore, eb::EncBinding,
                                  s_id::UInt32, subj_var, pats, pred_ids,
                                  obj_sets, obj_firsts, static_obj_ids, n, limit)
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
        # Pre-validate objects against bound vars / static patterns.
        @inbounds for i in 1:n
            obj_id = obj_firsts[i]
            pat_obj = pats[i].object
            if pat_obj isa String
                bv_id = get(eb, pat_obj, UInt32(0))
                bv_id != 0 && bv_id != obj_id && return
            elseif pat_obj isa Identifier
                static_obj_ids[i] != obj_id && return
            else
                # Triple-term or rare path: decode and resolve via legacy helper.
                # (Falls back to one-time decoded check.)
                bdec = _decode_one_binding(store, eb)
                resolved = _ast_resolve_term(pat_obj, bdec)
                resolved === nothing && return
                _enc_id(store, resolved) != obj_id && return
            end
        end
        # Emit row — push EncBinding directly, no decode.
        new_eb = copy(eb)
        get(new_eb, subj_var, UInt32(0)) == 0 && (new_eb[subj_var] = s_id)
        @inbounds for i in 1:n
            pat_obj = pats[i].object
            if pat_obj isa String
                get(new_eb, pat_obj, UInt32(0)) == 0 && (new_eb[pat_obj] = obj_firsts[i])
            end
        end
        push!(results, new_eb)
    else
        # Multi-valued: cross-product
        new_eb = copy(eb)
        get(new_eb, subj_var, UInt32(0)) == 0 && (new_eb[subj_var] = s_id)
        _star_cross_eb!(results, store, new_eb, obj_sets, pats, static_obj_ids, 1, n, limit)
    end
end

function _star_cross_eb!(results, store::EncodedStore, eb::EncBinding, obj_sets, pats,
                          static_obj_ids, idx, n, limit)
    if idx > n
        push!(results, copy(eb))
        return
    end
    pat_obj = pats[idx].object
    for obj_id in obj_sets[idx]
        if pat_obj isa String
            existing = get(eb, pat_obj, UInt32(0))
            if existing != 0
                existing == obj_id || continue
                _star_cross_eb!(results, store, eb, obj_sets, pats, static_obj_ids,
                                idx + 1, n, limit)
            else
                eb[pat_obj] = obj_id
                _star_cross_eb!(results, store, eb, obj_sets, pats, static_obj_ids,
                                idx + 1, n, limit)
                delete!(eb, pat_obj)
            end
        elseif pat_obj isa Identifier
            static_obj_ids[idx] == obj_id || continue
            _star_cross_eb!(results, store, eb, obj_sets, pats, static_obj_ids,
                            idx + 1, n, limit)
        else
            bdec = _decode_one_binding(store, eb)
            resolved = _ast_resolve_term(pat_obj, bdec)
            resolved === nothing && continue
            _enc_id(store, resolved) == obj_id || continue
            _star_cross_eb!(results, store, eb, obj_sets, pats, static_obj_ids,
                            idx + 1, n, limit)
        end
        limit > 0 && length(results) >= limit && return
    end
end

# ─── EB star + filter ───────────────────────────────────────────────
# When filters are present, decode binding only inside the filter call.

function _ast_eval_star_filter_eb(g::RDFGraph, store::EncodedStore, pats,
                                   filters::Vector{SparqlExpr},
                                   ebs::Vector{EncBinding}, limit::Int)
    # Run the no-filter star first (cheaper), then filter.
    candidates = _ast_eval_star_eb(store, pats, ebs, 0)
    isempty(candidates) && return candidates
    out = EncBinding[]
    for eb in candidates
        bdec = _decode_one_binding(store, eb)
        ok = true
        for f in filters
            if !_ast_eval_expr_bool(f, bdec, g)
                ok = false; break
            end
        end
        if ok
            push!(out, eb)
            limit > 0 && length(out) >= limit && break
        end
    end
    out
end

# ─── Patterns dispatch for EncodedStore ─────────────────────────────

function _ast_eval_patterns_star_encoded(g::RDFGraph, patterns::Vector{SparqlPattern},
                                          bindings::Vector{Dict{String,Identifier}}, limit::Int)
    store = g.store::EncodedStore
    i = 1
    n = length(patterns)
    # EB pipeline state: when `ebs` is non-empty the rowset lives in
    # encoded space; we materialize back to `bindings` only at handoff
    # boundaries (non-PatTriple patterns) and at the end.
    ebs = EncBinding[]
    using_eb = false

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
            if !using_eb
                ebs = _encode_bindings(store, bindings)
                using_eb = true
            end
            if isempty(ebs)
                return Dict{String,Identifier}[]
            end
            if isempty(filters)
                ebs = _ast_eval_star_eb(store, star_pats, ebs, eff_limit)
            else
                ebs = _ast_eval_star_filter_eb(g, store, star_pats, filters,
                                                ebs, eff_limit)
            end
            i = j
            isempty(ebs) && return Dict{String,Identifier}[]
        else
            # Non-star or single PatTriple: hand back to generic per-pattern eval.
            if using_eb
                bindings = _decode_bindings(store, ebs)
                ebs = EncBinding[]
                using_eb = false
            end
            is_last = (i == n)
            if is_last && limit > 0
                bindings = _ast_eval_pattern_limited(g, patterns[i], bindings, limit)
            else
                bindings = _ast_eval_pattern(g, patterns[i], bindings)
            end
            i += 1
            isempty(bindings) && return bindings
        end
    end
    if using_eb
        return _decode_bindings(store, ebs)
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
            if !issubset(Set(fvars), produced)
                ok = false; break
            end
            fend = j; j += 1
        end
        if !ok
            break
        end
        score = _star_size_encoded(store, patterns, i, send)
        push!(groups, (i, send, fend, score, produced, consumed))
        i = fend + 1
    end
    length(groups) < 2 && return patterns

    # Greedy join-aware planner mirroring _reorder_star_groups (memory):
    # the first group may be any (start with most selective), subsequent
    # groups must share a variable with already-placed groups.
    remaining = collect(eachindex(groups))
    available = Set{String}()
    order = Int[]
    while !isempty(remaining)
        best_idx = -1
        best_score = typemax(Int)
        for ri in remaining
            (_, _, _, sc, _, cons) = groups[ri]
            connected = isempty(available) || !isempty(intersect(cons, available))
            connected || continue
            if sc < best_score
                best_score = sc; best_idx = ri
            end
        end
        if best_idx == -1
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
