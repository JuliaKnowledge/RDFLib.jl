# ─── Abstract Store Interface ───────────────────────────────────────

"""
    AbstractStore

Abstract interface for RDF triple stores. Implementations must define:
- `add!(store, triple)` — add a triple
- `remove!(store, pattern)` — remove triples matching pattern
- `triples(store, pattern)` — iterate matching triples
- `Base.length(store)` — number of triples
"""
abstract type AbstractStore end

# ─── MemoryStore ────────────────────────────────────────────────────

"""
    MemoryStore()

In-memory triple store using three-way indices (SPO, POS, OSP) for
efficient pattern matching.
"""
mutable struct MemoryStore <: AbstractStore
    # Three indices for efficient lookup on any combination of S, P, O
    spo::Dict{Identifier, Dict{Identifier, Set{Identifier}}}
    pos::Dict{Identifier, Dict{Identifier, Set{Identifier}}}
    osp::Dict{Identifier, Dict{Identifier, Set{Identifier}}}
    # Flat indices for fast single-key queries (S?? and ?P?)
    pred_flat::Dict{Identifier, Vector{Triple}}
    subj_flat::Dict{Identifier, Vector{Triple}}
    count::Int
    insertion_order::Vector{Triple}  # Preserve insertion order for deterministic iteration
    indexed::Bool  # Whether SPO index is built
    secondary_indexed::Bool  # Whether POS/OSP indices are built
end

MemoryStore() = MemoryStore(
    Dict{Identifier, Dict{Identifier, Set{Identifier}}}(),
    Dict{Identifier, Dict{Identifier, Set{Identifier}}}(),
    Dict{Identifier, Dict{Identifier, Set{Identifier}}}(),
    Dict{Identifier, Vector{Triple}}(),
    Dict{Identifier, Vector{Triple}}(),
    0,
    Triple[],
    true,
    false  # secondary indices built lazily on first pattern query
)

# Build SPO index from insertion_order (lazy build after bulk insert)
function _ensure_indexed!(store::MemoryStore)
    store.indexed && return
    empty!(store.spo)
    sizehint!(store.spo, min(store.count, store.count ÷ 3 + 100))
    for t in store.insertion_order
        s, p, o = t.subject, t.predicate, t.object
        sp = get!(Dict{Identifier, Set{Identifier}}, store.spo, s)
        push!(get!(Set{Identifier}, sp, p), o)
    end
    store.indexed = true
end

# Build all three indices (called when SPARQL queries need POS/OSP)
function _ensure_all_indexed!(store::MemoryStore)
    _ensure_indexed!(store)
    if !store.secondary_indexed
        _build_secondary_indices!(store)
    end
end

"""Build POS and OSP indices from insertion_order."""
function _build_secondary_indices!(store::MemoryStore)
    store.secondary_indexed && return
    empty!(store.pos)
    empty!(store.osp)
    empty!(store.pred_flat)
    empty!(store.subj_flat)
    for t in store.insertion_order
        s, p, o = t.subject, t.predicate, t.object
        po = get!(Dict{Identifier, Set{Identifier}}, store.pos, p)
        push!(get!(Set{Identifier}, po, o), s)
        os = get!(Dict{Identifier, Set{Identifier}}, store.osp, o)
        push!(get!(Set{Identifier}, os, s), p)
        push!(get!(Vector{Triple}, store.pred_flat, p), t)
        push!(get!(Vector{Triple}, store.subj_flat, s), t)
    end
    store.secondary_indexed = true
end

function add!(store::MemoryStore, t::Triple)
    s, p, o = t.subject, t.predicate, t.object

    _ensure_indexed!(store)

    # Check if already present (using get to avoid double-hashing)
    sp = get(store.spo, s, nothing)
    if !isnothing(sp)
        objs = get(sp, p, nothing)
        if !isnothing(objs) && o in objs
            return store
        end
    end

    _add_unchecked!(store, t)
    store
end

# Add triple without duplicate checking (caller guarantees uniqueness)
function _add_unchecked!(store::MemoryStore, t::Triple)
    s, p, o = t.subject, t.predicate, t.object

    # SPO index (always maintained)
    sp = get!(Dict{Identifier, Set{Identifier}}, store.spo, s)
    push!(get!(Set{Identifier}, sp, p), o)

    # POS/OSP/flat indices (only if already built)
    if store.secondary_indexed
        po = get!(Dict{Identifier, Set{Identifier}}, store.pos, p)
        push!(get!(Set{Identifier}, po, o), s)
        os = get!(Dict{Identifier, Set{Identifier}}, store.osp, o)
        push!(get!(Set{Identifier}, os, s), p)
        push!(get!(Vector{Triple}, store.pred_flat, p), t)
        push!(get!(Vector{Triple}, store.subj_flat, s), t)
    end

    push!(store.insertion_order, t)
    store.count += 1
    nothing
end

"""Add a triple in deferred-index mode (fast bulk insert, indices rebuilt later)."""
function _add_deferred!(store::MemoryStore, t::Triple)
    push!(store.insertion_order, t)
    store.count += 1
    nothing
end

"""Switch store to deferred indexing mode for bulk inserts."""
function _defer_indexing!(store::MemoryStore)
    store.indexed = false
    store.secondary_indexed = false
    empty!(store.spo)
    empty!(store.pos)
    empty!(store.osp)
    empty!(store.pred_flat)
    empty!(store.subj_flat)
    nothing
end

"""Rebuild from insertion_order; optionally skip dedup for guaranteed-unique inserts."""
function _rebuild_indices!(store::MemoryStore; skip_dedup::Bool=false)
    if !skip_dedup
        n = length(store.insertion_order)
        # Fast dedup using Set{Triple} (concrete type — much faster than Dict→Dict→Set)
        seen = Set{Triple}()
        sizehint!(seen, n)
        deduped = Triple[]
        sizehint!(deduped, n)
        for t in store.insertion_order
            t in seen && continue
            push!(seen, t)
            push!(deduped, t)
        end
        store.insertion_order = deduped
        store.count = length(deduped)
    end
    # Mark indices as needing rebuild (built on demand)
    store.indexed = false
    store.secondary_indexed = false
    empty!(store.spo)
    empty!(store.pos)
    empty!(store.osp)
    empty!(store.pred_flat)
    empty!(store.subj_flat)
    nothing
end

function remove!(store::MemoryStore, pattern::TriplePattern)
    to_remove = collect(triples(store, pattern))  # triples() ensures all indices
    isempty(to_remove) && return store
    for t in to_remove
        _remove_from_indices!(store, t)
    end
    remove_set = Set{Triple}(to_remove)
    filter!(t -> !(t in remove_set), store.insertion_order)
    store
end

# Remove a single exact triple from the store
function _remove_exact!(store::MemoryStore, t::Triple)
    _ensure_indexed!(store)
    _remove_from_indices!(store, t)
    filter!(x -> x != t, store.insertion_order)
    store
end

function _remove_from_indices!(store::MemoryStore, t::Triple)
    s, p, o = t.subject, t.predicate, t.object

    # SPO
    if haskey(store.spo, s) && haskey(store.spo[s], p)
        delete!(store.spo[s][p], o)
        isempty(store.spo[s][p]) && delete!(store.spo[s], p)
        isempty(store.spo[s]) && delete!(store.spo, s)
    end

    # POS (only if secondary indices are built)
    if store.secondary_indexed
        if haskey(store.pos, p) && haskey(store.pos[p], o)
            delete!(store.pos[p][o], s)
            isempty(store.pos[p][o]) && delete!(store.pos[p], o)
            isempty(store.pos[p]) && delete!(store.pos, p)
        end

        # OSP
        if haskey(store.osp, o) && haskey(store.osp[o], s)
            delete!(store.osp[o][s], p)
            isempty(store.osp[o][s]) && delete!(store.osp[o], s)
            isempty(store.osp[o]) && delete!(store.osp, o)
        end

        # Flat indices: remove from pred_flat and subj_flat
        if haskey(store.pred_flat, p)
            filter!(x -> x != t, store.pred_flat[p])
        end
        if haskey(store.subj_flat, s)
            filter!(x -> x != t, store.subj_flat[s])
        end
    end

    store.count -= 1
end

"""
    triples(store, pattern) -> iterator of Triple

Iterate all triples matching the given pattern. `nothing` in any position is a wildcard.
"""
function triples(store::MemoryStore, pattern::TriplePattern)
    _ensure_all_indexed!(store)
    s, p, o = pattern
    _collect_triples(store, s, p, o)
end

function _collect_triples(store::MemoryStore, s, p, o)::Vector{Triple}
    result = Triple[]
    if !isnothing(s) && !isnothing(p) && !isnothing(o)
        # Fully bound — just check existence via index
        if haskey(store.spo, s) && haskey(store.spo[s], p) && o in store.spo[s][p]
            push!(result, Triple(s, p, o))
        end
    elseif !isnothing(s) && !isnothing(p)
        # S P ? — iterate objects from SPO index
        if haskey(store.spo, s) && haskey(store.spo[s], p)
            for obj in store.spo[s][p]
                push!(result, Triple(s, p, obj))
            end
        end
    elseif !isnothing(s) && !isnothing(o)
        # S ? O — iterate predicates from OSP index
        if haskey(store.osp, o) && haskey(store.osp[o], s)
            for pred in store.osp[o][s]
                push!(result, Triple(s, pred, o))
            end
        end
    elseif !isnothing(p) && !isnothing(o)
        # ? P O — iterate subjects from POS index
        if haskey(store.pos, p) && haskey(store.pos[p], o)
            for subj in store.pos[p][o]
                push!(result, Triple(subj, p, o))
            end
        end
    elseif !isnothing(s)
        # S ? ? — use flat subject index
        if haskey(store.subj_flat, s)
            return copy(store.subj_flat[s])
        end
    elseif !isnothing(p)
        # ? P ? — use flat predicate index
        if haskey(store.pred_flat, p)
            return copy(store.pred_flat[p])
        end
    elseif !isnothing(o)
        # ? ? O — iterate subjects then predicates from OSP
        if haskey(store.osp, o)
            for (subj, preds) in store.osp[o]
                for pred in preds
                    push!(result, Triple(subj, pred, o))
                end
            end
        end
    else
        for t in store.insertion_order
            push!(result, t)
        end
    end
    return result
end

Base.length(store::MemoryStore) = store.count
Base.isempty(store::MemoryStore) = store.count == 0

function add_bulk!(store::MemoryStore, triples_vec::Vector{Triple})
    n = length(triples_vec)
    sizehint!(store.spo, n ÷ 4)
    sizehint!(store.pos, 16)
    sizehint!(store.osp, n ÷ 2)
    empty!(store.pred_flat)
    empty!(store.subj_flat)
    for t in triples_vec
        s, p, o = t.subject, t.predicate, t.object
        # SPO index
        sp = get!(Dict{Identifier, Set{Identifier}}, store.spo, s)
        objs = get!(Set{Identifier}, sp, p)
        push!(objs, o)
        # POS index
        po = get!(Dict{Identifier, Set{Identifier}}, store.pos, p)
        subjs = get!(Set{Identifier}, po, o)
        push!(subjs, s)
        # OSP index
        os = get!(Dict{Identifier, Set{Identifier}}, store.osp, o)
        preds = get!(Set{Identifier}, os, s)
        push!(preds, p)
        # Flat indices
        push!(get!(Vector{Triple}, store.pred_flat, p), t)
        push!(get!(Vector{Triple}, store.subj_flat, s), t)
    end
    store.insertion_order = copy(triples_vec)
    store.count = n
    store.indexed = true
    store.secondary_indexed = true
    store
end
