# ─── EncodedStore ────────────────────────────────────────────────────
# Dictionary-encoded integer-ID triple store.
# Terms are interned to UInt32 ids (1-indexed; 0 is sentinel/missing).
# All indices are over UInt32 → much smaller, faster hash/eq, cache friendly.
# Implements the AbstractStore interface drop-in compatible with MemoryStore.

"""
    EncodedStore()

In-memory triple store using interned UInt32 IDs for terms.
Backed by SPO/POS/OSP indices on UInt32 plus a flat insertion-order list of
encoded triples. Drop-in replacement for `MemoryStore` for queries, with
significantly lower memory and faster join performance for SPARQL via the
encoded BGP fast path.
"""
mutable struct EncodedStore <: AbstractStore
    # Term <-> id mapping (1-indexed; id 0 reserved as sentinel for "no id").
    id_to_term::Vector{Identifier}
    term_to_id::Dict{Identifier, UInt32}

    # Encoded triples in insertion order (single source of truth)
    insertion_order_enc::Vector{NTuple{3, UInt32}}

    # Indices on encoded ids
    spo_enc::Dict{UInt32, Dict{UInt32, Set{UInt32}}}
    pos_enc::Dict{UInt32, Dict{UInt32, Set{UInt32}}}
    osp_enc::Dict{UInt32, Dict{UInt32, Set{UInt32}}}

    # Flat per-key indices (encoded)
    subj_flat_enc::Dict{UInt32, Vector{NTuple{3, UInt32}}}
    pred_flat_enc::Dict{UInt32, Vector{NTuple{3, UInt32}}}

    count::Int
    indexed::Bool            # SPO built
    secondary_indexed::Bool  # POS/OSP/flat built

    # Lazy numeric cache: parallel to id_to_term (resized on first lookup)
    # status: 0=unknown, 1=cached numeric, 2=known non-numeric
    numeric_status::Vector{UInt8}
    numeric_value::Vector{Float64}
end

EncodedStore() = EncodedStore(
    Identifier[],
    Dict{Identifier, UInt32}(),
    NTuple{3, UInt32}[],
    Dict{UInt32, Dict{UInt32, Set{UInt32}}}(),
    Dict{UInt32, Dict{UInt32, Set{UInt32}}}(),
    Dict{UInt32, Dict{UInt32, Set{UInt32}}}(),
    Dict{UInt32, Vector{NTuple{3, UInt32}}}(),
    Dict{UInt32, Vector{NTuple{3, UInt32}}}(),
    0,
    true,
    false,
    UInt8[],
    Float64[],
)

# ─── Term interning ─────────────────────────────────────────────────

"""Intern a term into the store, returning its UInt32 id (creating if new)."""
@inline function _intern!(store::EncodedStore, t::Identifier)::UInt32
    id = get(store.term_to_id, t, UInt32(0))
    id != 0 && return id
    push!(store.id_to_term, t)
    new_id = UInt32(length(store.id_to_term))
    store.term_to_id[t] = new_id
    return new_id
end

"""Look up id without creating; 0 if absent."""
@inline function _lookup_id(store::EncodedStore, t::Identifier)::UInt32
    return get(store.term_to_id, t, UInt32(0))
end

"""Decode a UInt32 id back to its Identifier."""
@inline _decode(store::EncodedStore, id::UInt32)::Identifier = store.id_to_term[id]

# ─── Lazy numeric cache ─────────────────────────────────────────────
# Parallel to id_to_term. Lazily populated on first SUM/AVG/numeric-comparison.
# status[id]: 0=unknown, 1=numeric, 2=non-numeric.

@inline function _enc_numeric(store::EncodedStore, id::UInt32)::Union{Float64, Nothing}
    id == 0 && return nothing
    status = store.numeric_status
    n = length(store.id_to_term)
    if length(status) < n
        old = length(status)
        resize!(status, n)
        resize!(store.numeric_value, n)
        @inbounds for i in (old+1):n
            status[i] = 0x00
        end
    end
    @inbounds st = status[id]
    if st == 0x01
        @inbounds return store.numeric_value[id]
    elseif st == 0x02
        return nothing
    end
    @inbounds v = store.id_to_term[id]
    nv = _ast_to_numeric(v)
    if nv === nothing
        @inbounds status[id] = 0x02
        return nothing
    else
        f = Float64(nv)
        @inbounds store.numeric_value[id] = f
        @inbounds status[id] = 0x01
        return f
    end
end

"""Decode an encoded triple."""
@inline function _decode_triple(store::EncodedStore, t::NTuple{3, UInt32})::Triple
    Triple(store.id_to_term[t[1]], store.id_to_term[t[2]], store.id_to_term[t[3]])
end

# ─── Index construction ─────────────────────────────────────────────

function _ensure_indexed!(store::EncodedStore)
    store.indexed && return
    empty!(store.spo_enc)
    sizehint!(store.spo_enc, max(16, length(store.insertion_order_enc) ÷ 3 + 1))
    for (s, p, o) in store.insertion_order_enc
        sp = get!(Dict{UInt32, Set{UInt32}}, store.spo_enc, s)
        push!(get!(Set{UInt32}, sp, p), o)
    end
    store.indexed = true
end

function _ensure_all_indexed!(store::EncodedStore)
    _ensure_indexed!(store)
    store.secondary_indexed && return
    _build_secondary_indices!(store)
end

function _build_secondary_indices!(store::EncodedStore)
    store.secondary_indexed && return
    empty!(store.pos_enc); empty!(store.osp_enc)
    empty!(store.subj_flat_enc); empty!(store.pred_flat_enc)
    for et in store.insertion_order_enc
        s, p, o = et
        po = get!(Dict{UInt32, Set{UInt32}}, store.pos_enc, p)
        push!(get!(Set{UInt32}, po, o), s)
        os = get!(Dict{UInt32, Set{UInt32}}, store.osp_enc, o)
        push!(get!(Set{UInt32}, os, s), p)
        push!(get!(Vector{NTuple{3, UInt32}}, store.subj_flat_enc, s), et)
        push!(get!(Vector{NTuple{3, UInt32}}, store.pred_flat_enc, p), et)
    end
    store.secondary_indexed = true
end

# ─── add! / remove! ─────────────────────────────────────────────────

function add!(store::EncodedStore, t::Triple)
    s_id = _intern!(store, t.subject)
    p_id = _intern!(store, t.predicate)
    o_id = _intern!(store, t.object)
    _ensure_indexed!(store)
    sp = get(store.spo_enc, s_id, nothing)
    if sp !== nothing
        objs = get(sp, p_id, nothing)
        if objs !== nothing && o_id in objs
            return store
        end
    end
    _add_unchecked_enc!(store, (s_id, p_id, o_id))
    store
end

@inline function _add_unchecked_enc!(store::EncodedStore, et::NTuple{3, UInt32})
    s, p, o = et
    sp = get!(Dict{UInt32, Set{UInt32}}, store.spo_enc, s)
    push!(get!(Set{UInt32}, sp, p), o)
    if store.secondary_indexed
        po = get!(Dict{UInt32, Set{UInt32}}, store.pos_enc, p)
        push!(get!(Set{UInt32}, po, o), s)
        os = get!(Dict{UInt32, Set{UInt32}}, store.osp_enc, o)
        push!(get!(Set{UInt32}, os, s), p)
        push!(get!(Vector{NTuple{3, UInt32}}, store.subj_flat_enc, s), et)
        push!(get!(Vector{NTuple{3, UInt32}}, store.pred_flat_enc, p), et)
    end
    push!(store.insertion_order_enc, et)
    store.count += 1
end

"""
    add_bulk!(store::EncodedStore, triples_vec) -> store

Bulk insertion: batch-interns all terms and appends encoded triples in one
pass. Avoids the per-triple overhead of `add!` (repeated index checks,
un-hinted Dict/Vector growth). Duplicates are skipped, mirroring `add!`.
"""
function add_bulk!(store::EncodedStore, triples_vec::Vector{Triple})
    isempty(triples_vec) && return store
    n = length(triples_vec)
    _ensure_indexed!(store)

    # Pre-size dictionaries/vectors for the incoming batch.
    sizehint!(store.term_to_id, length(store.term_to_id) + 2 * n)
    sizehint!(store.id_to_term, length(store.id_to_term) + 2 * n)
    sizehint!(store.insertion_order_enc, length(store.insertion_order_enc) + n)
    sizehint!(store.spo_enc, length(store.spo_enc) + n ÷ 3 + 1)

    secondary = store.secondary_indexed
    @inbounds for t in triples_vec
        # Batch intern (terms repeat heavily across a batch; `_intern!` is a
        # single hash lookup when already present).
        s_id = _intern!(store, t.subject)
        p_id = _intern!(store, t.predicate)
        o_id = _intern!(store, t.object)
        # Dedup check shares the SPO bucket lookup with the insert.
        sp = get!(Dict{UInt32, Set{UInt32}}, store.spo_enc, s_id)
        objs = get!(Set{UInt32}, sp, p_id)
        o_id in objs && continue
        push!(objs, o_id)
        et = (s_id, p_id, o_id)
        if secondary
            po = get!(Dict{UInt32, Set{UInt32}}, store.pos_enc, p_id)
            push!(get!(Set{UInt32}, po, o_id), s_id)
            os = get!(Dict{UInt32, Set{UInt32}}, store.osp_enc, o_id)
            push!(get!(Set{UInt32}, os, s_id), p_id)
            push!(get!(Vector{NTuple{3, UInt32}}, store.subj_flat_enc, s_id), et)
            push!(get!(Vector{NTuple{3, UInt32}}, store.pred_flat_enc, p_id), et)
        end
        push!(store.insertion_order_enc, et)
        store.count += 1
    end
    store
end

function remove!(store::EncodedStore, pattern::TriplePattern)
    _ensure_all_indexed!(store)
    s_id, p_id, o_id = _encode_pattern(store, pattern)
    # Pattern term not in dictionary → nothing to remove.
    if (pattern[1] !== nothing && s_id == 0) ||
       (pattern[2] !== nothing && p_id == 0) ||
       (pattern[3] !== nothing && o_id == 0)
        return store
    end
    matches = _collect_encoded(store, s_id, p_id, o_id, pattern[1], pattern[2], pattern[3])
    isempty(matches) && return store
    match_set = Set{NTuple{3, UInt32}}(matches)
    for et in matches
        _remove_from_indices_enc!(store, et)
    end
    filter!(et -> !(et in match_set), store.insertion_order_enc)
    store
end

function _remove_from_indices_enc!(store::EncodedStore, et::NTuple{3, UInt32})
    s, p, o = et
    if haskey(store.spo_enc, s) && haskey(store.spo_enc[s], p)
        delete!(store.spo_enc[s][p], o)
        isempty(store.spo_enc[s][p]) && delete!(store.spo_enc[s], p)
        isempty(store.spo_enc[s]) && delete!(store.spo_enc, s)
    end
    if store.secondary_indexed
        if haskey(store.pos_enc, p) && haskey(store.pos_enc[p], o)
            delete!(store.pos_enc[p][o], s)
            isempty(store.pos_enc[p][o]) && delete!(store.pos_enc[p], o)
            isempty(store.pos_enc[p]) && delete!(store.pos_enc, p)
        end
        if haskey(store.osp_enc, o) && haskey(store.osp_enc[o], s)
            delete!(store.osp_enc[o][s], p)
            isempty(store.osp_enc[o][s]) && delete!(store.osp_enc[o], s)
            isempty(store.osp_enc[o]) && delete!(store.osp_enc, o)
        end
        if haskey(store.subj_flat_enc, s)
            filter!(x -> x != et, store.subj_flat_enc[s])
        end
        if haskey(store.pred_flat_enc, p)
            filter!(x -> x != et, store.pred_flat_enc[p])
        end
    end
    store.count -= 1
end

# Encode a TriplePattern; nothing → 0 (wildcard); missing term → 0 (won't match).
@inline function _encode_pattern(store::EncodedStore, pattern::TriplePattern)
    s = pattern[1] === nothing ? UInt32(0) : _lookup_id(store, pattern[1])
    p = pattern[2] === nothing ? UInt32(0) : _lookup_id(store, pattern[2])
    o = pattern[3] === nothing ? UInt32(0) : _lookup_id(store, pattern[3])
    return (s, p, o)
end

# Collect encoded triples matching pattern; any of (s_id,p_id,o_id) == 0 is wildcard
# but only if the corresponding pattern slot was nothing. If the slot was
# non-nothing AND id==0 the caller should have already short-circuited to empty.
function _collect_encoded(store::EncodedStore, s_id::UInt32, p_id::UInt32, o_id::UInt32,
                          s_orig, p_orig, o_orig)::Vector{NTuple{3, UInt32}}
    s_w = s_orig === nothing
    p_w = p_orig === nothing
    o_w = o_orig === nothing
    result = NTuple{3, UInt32}[]
    if !s_w && !p_w && !o_w
        sp = get(store.spo_enc, s_id, nothing)
        sp === nothing && return result
        objs = get(sp, p_id, nothing)
        objs === nothing && return result
        if o_id in objs; push!(result, (s_id, p_id, o_id)); end
    elseif !s_w && !p_w
        sp = get(store.spo_enc, s_id, nothing)
        sp === nothing && return result
        objs = get(sp, p_id, nothing)
        objs === nothing && return result
        for o in objs; push!(result, (s_id, p_id, o)); end
    elseif !s_w && !o_w
        os = get(store.osp_enc, o_id, nothing)
        os === nothing && return result
        preds = get(os, s_id, nothing)
        preds === nothing && return result
        for p in preds; push!(result, (s_id, p, o_id)); end
    elseif !p_w && !o_w
        po = get(store.pos_enc, p_id, nothing)
        po === nothing && return result
        subjs = get(po, o_id, nothing)
        subjs === nothing && return result
        for s in subjs; push!(result, (s, p_id, o_id)); end
    elseif !s_w
        if haskey(store.subj_flat_enc, s_id)
            return copy(store.subj_flat_enc[s_id])
        end
    elseif !p_w
        if haskey(store.pred_flat_enc, p_id)
            return copy(store.pred_flat_enc[p_id])
        end
    elseif !o_w
        os = get(store.osp_enc, o_id, nothing)
        os === nothing && return result
        for (s, preds) in os
            for p in preds
                push!(result, (s, p, o_id))
            end
        end
    else
        return copy(store.insertion_order_enc)
    end
    return result
end

# ─── Public triples interface (decode for backward compat) ──────────

function triples(store::EncodedStore, pattern::TriplePattern)::Vector{Triple}
    _ensure_all_indexed!(store)
    s_id, p_id, o_id = _encode_pattern(store, pattern)
    if (pattern[1] !== nothing && s_id == 0) ||
       (pattern[2] !== nothing && p_id == 0) ||
       (pattern[3] !== nothing && o_id == 0)
        return Triple[]
    end
    enc = _collect_encoded(store, s_id, p_id, o_id, pattern[1], pattern[2], pattern[3])
    result = Vector{Triple}(undef, length(enc))
    @inbounds for i in eachindex(enc)
        result[i] = _decode_triple(store, enc[i])
    end
    return result
end

Base.length(store::EncodedStore) = store.count
Base.isempty(store::EncodedStore) = store.count == 0

# ─── Backward-compat property access ────────────────────────────────
# Some code paths (datalog, jelly, n3_reasoner, graph iter) read
# `store.insertion_order` directly. Provide a lazy decoded view via getproperty.

function Base.getproperty(store::EncodedStore, name::Symbol)
    if name === :insertion_order
        # Decode lazily (slow path; only legacy callers use this)
        enc = getfield(store, :insertion_order_enc)
        result = Vector{Triple}(undef, length(enc))
        @inbounds for i in eachindex(enc)
            result[i] = _decode_triple(store, enc[i])
        end
        return result
    end
    return getfield(store, name)
end

function Base.propertynames(store::EncodedStore, private::Bool=false)
    base = fieldnames(EncodedStore)
    return (base..., :insertion_order)
end
