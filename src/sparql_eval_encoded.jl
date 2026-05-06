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
    ebs, leftover_bindings, ended_in_eb = _eval_patterns_eb_inner(g, patterns, bindings, limit)
    if ended_in_eb
        return _decode_bindings(g.store::EncodedStore, ebs)
    else
        return leftover_bindings
    end
end

# Internal helper: returns (ebs, bindings, ended_in_eb).
# - If the pipeline ended in EB mode, ebs is meaningful and ended_in_eb=true.
# - Otherwise, leftover_bindings holds the materialized result.
function _eval_patterns_eb_inner(g::RDFGraph, patterns::Vector{SparqlPattern},
                                  bindings::Vector{Dict{String,Identifier}}, limit::Int)
    store = g.store::EncodedStore
    i = 1
    n = length(patterns)
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
                return (EncBinding[], Dict{String,Identifier}[], true)
            end
            if isempty(filters)
                ebs = _ast_eval_star_eb(store, star_pats, ebs, eff_limit)
            else
                ebs = _ast_eval_star_filter_eb(g, store, star_pats, filters,
                                                ebs, eff_limit)
            end
            i = j
            isempty(ebs) && return (EncBinding[], Dict{String,Identifier}[], true)
        else
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
            isempty(bindings) && return (EncBinding[], bindings, false)
        end
    end
    return (ebs, bindings, using_eb)
end

# Public entry: evaluate patterns and return raw EncBindings if the
# pipeline ended in EB mode; otherwise encode the final Identifier
# bindings on demand. Used by the encoded streaming-aggregate path.
function _ast_eval_patterns_star_encoded_eb(g::RDFGraph, patterns::Vector{SparqlPattern},
                                             bindings::Vector{Dict{String,Identifier}}, limit::Int)
    ebs, leftover_bindings, ended_in_eb = _eval_patterns_eb_inner(g, patterns, bindings, limit)
    if ended_in_eb
        return ebs
    else
        return _encode_bindings(g.store::EncodedStore, leftover_bindings)
    end
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

# ─── Encoded streaming aggregate ────────────────────────────────────
#
# Operates directly on Vector{EncBinding}, eliminating the BGP-exit
# decode boundary. For Q2-shape queries (BGP + GROUP BY var(s) +
# COUNT/SUM/AVG/MIN/MAX) this can shave 20-50% off total query time.

@inline function _agg_update_fast_eb(acc, plan::Tuple{Int,Bool,String,Bool},
                                      eb::EncBinding, store::EncodedStore)
    f, distinct, var, is_star = plan
    if distinct
        # DISTINCT uses Set{UInt32} — much cheaper hash/eq than Identifier.
        s = acc::Set{UInt32}
        if is_star
            # COUNT(DISTINCT *): treat each row as distinct via row hash;
            # use binding identity (rare path).
            push!(s, UInt32(hash(eb) & 0xFFFFFFFF))
        else
            id = get(eb, var, UInt32(0))
            id != 0 && push!(s, id)
        end
        return s
    end
    if f == 1  # COUNT
        if is_star
            return (acc::Int) + 1
        end
        return haskey(eb, var) ? (acc::Int) + 1 : acc
    elseif f == 2  # SUM
        id = isempty(var) ? UInt32(0) : get(eb, var, UInt32(0))
        id == 0 && return acc
        nv = _enc_numeric(store, id)
        nv === nothing && return acc
        s, ai = acc::Tuple{Float64,Bool}
        return (s + nv, ai)
    elseif f == 3  # AVG
        id = isempty(var) ? UInt32(0) : get(eb, var, UInt32(0))
        id == 0 && return acc
        nv = _enc_numeric(store, id)
        nv === nothing && return acc
        s, c = acc::Tuple{Float64,Int}
        return (s + nv, c + 1)
    elseif f == 4  # MIN
        id = isempty(var) ? UInt32(0) : get(eb, var, UInt32(0))
        id == 0 && return acc
        v = store.id_to_term[id]
        acc === nothing && return v
        return _agg_lt(v, acc::Identifier) ? v : acc
    elseif f == 5  # MAX
        id = isempty(var) ? UInt32(0) : get(eb, var, UInt32(0))
        id == 0 && return acc
        v = store.id_to_term[id]
        acc === nothing && return v
        return _agg_lt(acc::Identifier, v) ? v : acc
    elseif f == 6  # SAMPLE
        if acc === nothing
            id = isempty(var) ? UInt32(0) : get(eb, var, UInt32(0))
            return id == 0 ? acc : store.id_to_term[id]
        end
        return acc
    end
    return acc
end

# Initial accumulator state — DISTINCT uses Set{UInt32} (encoded-friendly).
@inline function _agg_init_eb(agg::ExprAggregate)
    f = agg.func
    if agg.distinct
        return Set{UInt32}()
    end
    if f == "COUNT";  return 0; end
    if f == "SUM";    return (0.0, false); end
    if f == "AVG";    return (0.0, 0); end
    if f == "MIN" || f == "MAX" || f == "SAMPLE"; return nothing; end
    return nothing
end

# Streaming GROUP BY + aggregate over Vector{EncBinding}. Group keys
# are NTuple{N,UInt32} of group_by variable ids (cheap to hash). For
# DISTINCT aggregates, accumulator is Set{UInt32}; finalize converts
# back to Identifier via the store dictionary.
function _ast_eval_group_aggregate_streaming_eb(q::SparqlSelect,
                                                  ebs::Vector{EncBinding},
                                                  store::EncodedStore, g)
    n_agg = length(q.aggregates)
    n_gb = length(q.group_by)

    if isempty(ebs) && isempty(q.group_by)
        result = Dict{String,Identifier}()
        for sa in q.aggregates
            result[sa.alias] = _ast_compute_aggregate(sa.agg, Dict{String,Identifier}[])
        end
        return Dict{String,Identifier}[result]
    end

    # Pre-classify aggregate plan
    agg_plan = Vector{Tuple{Int,Bool,String,Bool}}(undef, n_agg)
    @inbounds for i in 1:n_agg
        a = q.aggregates[i].agg
        fi = a.func == "COUNT" ? 1 : a.func == "SUM" ? 2 : a.func == "AVG" ? 3 :
             a.func == "MIN" ? 4 : a.func == "MAX" ? 5 : a.func == "SAMPLE" ? 6 : 0
        is_star = a.arg isa ExprStar
        var = a.arg isa ExprVar ? (a.arg::ExprVar).name : ""
        agg_plan[i] = (fi, a.distinct, var, is_star)
    end

    # Group-by var names (assumed all ExprVar — checked by safe-streaming gate)
    gb_vars = String[(q.group_by[i]::ExprVar).name for i in 1:n_gb]

    # State: key (NTuple of UInt32) -> (gvals_uint::Vector{UInt32}, accs::Vector{Any})
    groups = Dict{NTuple, Tuple{Vector{UInt32}, Vector{Any}}}()
    group_order = NTuple[]

    for eb in ebs
        # Build group key directly from EncBinding ids (UInt32 hashing).
        key::NTuple = if n_gb == 0
            ()
        else
            ntuple(n_gb) do i
                get(eb, gb_vars[i], UInt32(0))
            end
        end
        st = get(groups, key, nothing)
        if st === nothing
            gvals = Vector{UInt32}(undef, n_gb)
            @inbounds for i in 1:n_gb
                gvals[i] = get(eb, gb_vars[i], UInt32(0))
            end
            accs = Any[_agg_init_eb(q.aggregates[i].agg) for i in 1:n_agg]
            @inbounds for i in 1:n_agg
                accs[i] = _agg_update_fast_eb(accs[i], agg_plan[i], eb, store)
            end
            groups[key] = (gvals, accs)
            push!(group_order, key)
        else
            _, accs = st
            @inbounds for i in 1:n_agg
                accs[i] = _agg_update_fast_eb(accs[i], agg_plan[i], eb, store)
            end
        end
    end

    # Finalize: decode gvals UInt32 -> Identifier, finalize aggregates.
    new_bindings = Vector{Dict{String,Identifier}}(undef, length(group_order))
    @inbounds for gi in eachindex(group_order)
        key = group_order[gi]
        gvals, accs = groups[key]
        result = Dict{String,Identifier}()
        for (i, name) in enumerate(gb_vars)
            id = gvals[i]
            result[name] = id == 0 ? Literal("") : store.id_to_term[id]
        end
        for i in 1:n_agg
            agg = q.aggregates[i].agg
            if agg.distinct
                # Convert Set{UInt32} to Set{Identifier} for legacy finalize.
                s_id = accs[i]::Set{UInt32}
                s_ident = Set{Identifier}()
                for id in s_id
                    push!(s_ident, store.id_to_term[id])
                end
                result[q.aggregates[i].alias] = _agg_finalize(s_ident, agg)
            else
                result[q.aggregates[i].alias] = _agg_finalize(accs[i], agg)
            end
        end
        new_bindings[gi] = result
    end
    new_bindings
end

# Decide if the query is eligible for the encoded streaming aggregate
# fast path. Requirements:
# - store is EncodedStore
# - _streaming_aggregate_safe(q) (existing predicate)
# - all group_by are ExprVar
# - no SELECT expressions (they evaluate per-binding before aggregation
#   in the standard path; we'd need to thread Identifier values for them)
# - no ORDER BY using aggregate aliases that depend on per-binding decode
#   (handled post-aggregation, which works on Identifier results — OK)
function _enc_streaming_agg_eligible(q::SparqlSelect, g::RDFGraph)
    g.store isa EncodedStore || return false
    _streaming_aggregate_safe(q) || return false
    isempty(q.select_exprs) || return false
    for gb in q.group_by
        gb isa ExprVar || return false
    end
    # Require pure BGP — only PatTriple/PatFilter. OPTIONAL, UNION, MINUS,
    # subqueries etc. are handled by other paths (e.g. _try_stream_opt_agg
    # for OPTIONAL+aggregate).
    for p in q.patterns
        (p isa PatTriple || p isa PatFilter) || return false
    end
    return true
end

# ─── Encoded streaming OPTIONAL+aggregate (Q4-shape) ──────────────────
# Mirror of _exec_stream_opt_agg in sparql_eval.jl but operates on
# EncodedStore's UInt32-id indices end-to-end. Outer BGP is evaluated
# via the EB pipeline; inner OPTIONAL star-join is performed per outer
# row using pos_enc/spo_enc lookups; aggregates accumulate UInt32 ids.
function _exec_stream_opt_agg_eb(q::SparqlSelect, g::RDFGraph,
                                   outer_pats::Vector{SparqlPattern},
                                   inner_pats::Vector{SparqlPattern},
                                   inner_triples::Vector{PatTriple},
                                   inner_subj::String,
                                   agg_sources::Vector{Symbol})
    store = g.store::EncodedStore
    _ensure_all_indexed!(store)
    n_agg = length(q.aggregates)
    n_gb = length(q.group_by)
    n_inner = length(inner_triples)

    # Evaluate outer BGP via EB pipeline (returns Vector{EncBinding}).
    pats_re = length(outer_pats) >= 2 ?
        _reorder_star_groups_encoded(store, outer_pats) : outer_pats
    outer_ebs = _ast_eval_patterns_star_encoded_eb(g, pats_re,
        Dict{String,Identifier}[Dict{String,Identifier}()], 0)

    if isempty(outer_ebs)
        if n_gb == 0
            result = Dict{String,Identifier}()
            for sa in q.aggregates
                result[sa.alias] = _ast_compute_aggregate(sa.agg, Dict{String,Identifier}[])
            end
            return Dict{String,Identifier}[result]
        else
            return Dict{String,Identifier}[]
        end
    end

    # Pre-classify aggregate plan
    agg_plan = Vector{Tuple{Int,Bool,String,Bool}}(undef, n_agg)
    @inbounds for i in 1:n_agg
        a = q.aggregates[i].agg
        fi = a.func == "COUNT" ? 1 : a.func == "SUM" ? 2 : a.func == "AVG" ? 3 :
             a.func == "MIN" ? 4 : a.func == "MAX" ? 5 : a.func == "SAMPLE" ? 6 : 0
        is_star = a.arg isa ExprStar
        var = a.arg isa ExprVar ? (a.arg::ExprVar).name : ""
        agg_plan[i] = (fi, a.distinct, var, is_star)
    end

    # Pre-resolve inner predicate ids and POS buckets
    pred_ids = Vector{UInt32}(undef, n_inner)
    pos_buckets = Vector{Union{Dict{UInt32,Set{UInt32}},Nothing}}(undef, n_inner)
    has_inner_match_possible = true
    @inbounds for i in 1:n_inner
        pid = get(store.term_to_id, inner_triples[i].predicate::URIRef, UInt32(0))
        pred_ids[i] = pid
        if pid == 0
            pos_buckets[i] = nothing
            has_inner_match_possible = false
        else
            po = get(store.pos_enc, pid, nothing)
            pos_buckets[i] = po
            po === nothing && (has_inner_match_possible = false)
        end
    end

    # Inner constants encoded once
    inner_obj_const_id = Vector{UInt32}(undef, n_inner)
    @inbounds for i in 1:n_inner
        o = inner_triples[i].object
        inner_obj_const_id[i] = if o isa Identifier
            get(store.term_to_id, o, UInt32(0))
        else
            UInt32(0)
        end
        # Constant not in dict -> can't match anything
        if o isa Identifier && inner_obj_const_id[i] == 0
            has_inner_match_possible = false
        end
    end

    inner_filters = SparqlExpr[]
    for p in inner_pats
        p isa PatFilter && push!(inner_filters, (p::PatFilter).expr)
    end

    # Per-aggregate index lists for the per-row hot path
    outer_agg_idx = Int[i for i in 1:n_agg if agg_sources[i] === :outer]
    inner_agg_idx = Int[i for i in 1:n_agg if agg_sources[i] === :inner]

    # Group state: NTuple{N,UInt32} key -> (gvals::Vector{UInt32}, accs::Vector{Any})
    groups = Dict{NTuple, Tuple{Vector{UInt32}, Vector{Any}}}()
    group_order = NTuple[]

    # GB var names
    gb_vars = String[(q.group_by[i]::ExprVar).name for i in 1:n_gb]

    # Scratch EB for inner-row aggregate updates
    scratch_eb = EncBinding()
    obj_sets = Vector{Set{UInt32}}(undef, n_inner)
    obj_firsts = Vector{UInt32}(undef, n_inner)

    have_inner_filters = !isempty(inner_filters)

    for outer_eb in outer_ebs
        # Build group key from outer-only ids
        key::NTuple = if n_gb == 0
            ()
        else
            ntuple(n_gb) do i
                get(outer_eb, gb_vars[i], UInt32(0))
            end
        end

        st = get(groups, key, nothing)
        local accs::Vector{Any}
        if st === nothing
            gvals = Vector{UInt32}(undef, n_gb)
            @inbounds for i in 1:n_gb
                gvals[i] = get(outer_eb, gb_vars[i], UInt32(0))
            end
            accs = Any[_agg_init_eb(q.aggregates[i].agg) for i in 1:n_agg]
            groups[key] = (gvals, accs)
            push!(group_order, key)
        else
            _, accs = st
        end

        # Outer-source aggregates (one update per outer row, LEFT JOIN semantics)
        @inbounds for i in outer_agg_idx
            accs[i] = _agg_update_fast_eb(accs[i], agg_plan[i], outer_eb, store)
        end

        # Skip inner work if no inner-source agg + no filters, or impossible
        isempty(inner_agg_idx) && !have_inner_filters && continue
        has_inner_match_possible || continue

        # Find smallest driver subject set via POS pivot
        driver = nothing
        bail = false
        @inbounds for i in 1:n_inner
            po = pos_buckets[i]
            po === nothing && (bail = true; break)
            obj = inner_triples[i].object
            obj_id::UInt32 = 0
            if obj isa String
                bv = get(outer_eb, obj, UInt32(0))
                bv == 0 && continue  # not bound; not a constraint here
                obj_id = bv
            elseif obj isa Identifier
                obj_id = inner_obj_const_id[i]
            else
                continue
            end
            obj_id == 0 && continue
            subjs = get(po, obj_id, nothing)
            if subjs === nothing
                bail = true; break
            end
            if driver === nothing || length(subjs) < length(driver)
                driver = subjs
            end
        end
        bail && continue
        driver === nothing && continue

        for s in driver
            sp = get(store.spo_enc, s, nothing)
            sp === nothing && continue
            ok = true
            @inbounds for i in 1:n_inner
                os = get(sp, pred_ids[i], nothing)
                if os === nothing
                    ok = false; break
                end
                obj_sets[i] = os
            end
            ok || continue

            # all_single fast path
            all_single = true
            @inbounds for i in 1:n_inner
                length(obj_sets[i]) != 1 && (all_single = false; break)
            end
            if all_single
                @inbounds for i in 1:n_inner
                    obj_firsts[i] = first(obj_sets[i])
                end
                ok2 = true
                @inbounds for i in 1:n_inner
                    pat_obj = inner_triples[i].object
                    if pat_obj isa String
                        bv = get(outer_eb, pat_obj, UInt32(0))
                        if bv != 0
                            bv == obj_firsts[i] || (ok2 = false; break)
                        end
                    elseif pat_obj isa Identifier
                        inner_obj_const_id[i] == obj_firsts[i] || (ok2 = false; break)
                    end
                end
                ok2 || continue

                if have_inner_filters || !isempty(inner_agg_idx)
                    # Build scratch_eb: outer + inner subject + obj vars
                    empty!(scratch_eb)
                    for (k, v) in outer_eb
                        scratch_eb[k] = v
                    end
                    scratch_eb[inner_subj] = s
                    @inbounds for i in 1:n_inner
                        pat_obj = inner_triples[i].object
                        pat_obj isa String && (scratch_eb[pat_obj::String] = obj_firsts[i])
                    end

                    # Inner filters: decode scratch on demand
                    if have_inner_filters
                        scratch_id = _decode_one_binding(store, scratch_eb)
                        fok = true
                        for fexpr in inner_filters
                            if !_ast_eval_expr_bool(fexpr, scratch_id, g)
                                fok = false; break
                            end
                        end
                        fok || continue
                    end

                    @inbounds for i in inner_agg_idx
                        accs[i] = _agg_update_fast_eb(accs[i], agg_plan[i], scratch_eb, store)
                    end
                end
            else
                # Multi-valued: enumerate cross product
                empty!(scratch_eb)
                for (k, v) in outer_eb
                    scratch_eb[k] = v
                end
                scratch_eb[inner_subj] = s
                _stream_inner_cross_agg_eb!(scratch_eb, outer_eb, s, inner_subj,
                                              inner_triples, obj_sets, 1, n_inner,
                                              inner_filters, accs, inner_agg_idx,
                                              agg_plan, store, g, inner_obj_const_id)
            end
        end
    end

    # Finalize groups: decode UInt32 group ids to Identifier
    new_bindings = Vector{Dict{String,Identifier}}(undef, length(group_order))
    @inbounds for gi in eachindex(group_order)
        key = group_order[gi]
        gvals, accs = groups[key]
        result = Dict{String,Identifier}()
        for (i, name) in enumerate(gb_vars)
            id = gvals[i]
            result[name] = id == 0 ? Literal("") : store.id_to_term[id]
        end
        for i in 1:n_agg
            agg = q.aggregates[i].agg
            if agg.distinct
                s_id = accs[i]::Set{UInt32}
                s_ident = Set{Identifier}()
                for id in s_id
                    push!(s_ident, store.id_to_term[id])
                end
                result[q.aggregates[i].alias] = _agg_finalize(s_ident, agg)
            else
                result[q.aggregates[i].alias] = _agg_finalize(accs[i], agg)
            end
        end
        new_bindings[gi] = result
    end
    new_bindings
end

function _stream_inner_cross_agg_eb!(scratch::EncBinding,
                                       outer_eb::EncBinding,
                                       s::UInt32, inner_subj::String,
                                       inner_triples::Vector{PatTriple},
                                       obj_sets::Vector{Set{UInt32}},
                                       idx::Int, n::Int,
                                       inner_filters::Vector{SparqlExpr},
                                       accs::Vector{Any}, inner_agg_idx::Vector{Int},
                                       agg_plan::Vector{Tuple{Int,Bool,String,Bool}},
                                       store::EncodedStore, g,
                                       inner_obj_const_id::Vector{UInt32})
    if idx > n
        if !isempty(inner_filters)
            sid = _decode_one_binding(store, scratch)
            for fexpr in inner_filters
                _ast_eval_expr_bool(fexpr, sid, g) || return
            end
        end
        @inbounds for i in inner_agg_idx
            accs[i] = _agg_update_fast_eb(accs[i], agg_plan[i], scratch, store)
        end
        return
    end
    pat_obj = inner_triples[idx].object
    for obj_id in obj_sets[idx]
        # Validate against bound/constant at this position
        if pat_obj isa String
            bv = get(outer_eb, pat_obj, UInt32(0))
            if bv != 0 && bv != obj_id
                continue
            end
            scratch[pat_obj::String] = obj_id
        elseif pat_obj isa Identifier
            inner_obj_const_id[idx] == obj_id || continue
        end
        _stream_inner_cross_agg_eb!(scratch, outer_eb, s, inner_subj, inner_triples,
                                     obj_sets, idx + 1, n, inner_filters, accs,
                                     inner_agg_idx, agg_plan, store, g, inner_obj_const_id)
    end
end
