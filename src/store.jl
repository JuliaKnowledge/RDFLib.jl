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
    count::Int
    insertion_order::Vector{Triple}  # Preserve insertion order for deterministic iteration
end

MemoryStore() = MemoryStore(
    Dict{Identifier, Dict{Identifier, Set{Identifier}}}(),
    Dict{Identifier, Dict{Identifier, Set{Identifier}}}(),
    Dict{Identifier, Dict{Identifier, Set{Identifier}}}(),
    0,
    Triple[]
)

function add!(store::MemoryStore, t::Triple)
    s, p, o = t.subject, t.predicate, t.object

    # Check if already present (using get to avoid double-hashing)
    sp = get(store.spo, s, nothing)
    if !isnothing(sp)
        objs = get(sp, p, nothing)
        if !isnothing(objs) && o in objs
            return store
        end
    end

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

    push!(store.insertion_order, t)
    store.count += 1
    store
end

function remove!(store::MemoryStore, pattern::TriplePattern)
    to_remove = collect(triples(store, pattern))
    for t in to_remove
        s, p, o = t.subject, t.predicate, t.object

        # SPO
        if haskey(store.spo, s) && haskey(store.spo[s], p)
            delete!(store.spo[s][p], o)
            isempty(store.spo[s][p]) && delete!(store.spo[s], p)
            isempty(store.spo[s]) && delete!(store.spo, s)
        end

        # POS
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

        store.count -= 1
    end
    filter!(t -> !any(r -> r.subject == t.subject && r.predicate == t.predicate && r.object == t.object, to_remove), store.insertion_order)
    store
end

"""
    triples(store, pattern) -> iterator of Triple

Iterate all triples matching the given pattern. `nothing` in any position is a wildcard.
"""
function triples(store::MemoryStore, pattern::TriplePattern)
    s, p, o = pattern
    Channel{Triple}() do ch
        _triples_inner(store, s, p, o, ch)
    end
end

function _triples_inner(store::MemoryStore, s, p, o, ch::Channel{Triple})
    if !isnothing(s) && !isnothing(p) && !isnothing(o)
        # Fully bound — just check existence via index
        if haskey(store.spo, s) && haskey(store.spo[s], p) && o in store.spo[s][p]
            put!(ch, Triple(s, p, o))
        end
    elseif !isnothing(s) && !isnothing(p)
        # S P ? — check index exists, then iterate in insertion order
        if haskey(store.spo, s) && haskey(store.spo[s], p)
            for t in store.insertion_order
                t.subject == s && t.predicate == p && put!(ch, t)
            end
        end
    elseif !isnothing(s) && !isnothing(o)
        if haskey(store.osp, o) && haskey(store.osp[o], s)
            for t in store.insertion_order
                t.subject == s && t.object == o && put!(ch, t)
            end
        end
    elseif !isnothing(p) && !isnothing(o)
        if haskey(store.pos, p) && haskey(store.pos[p], o)
            for t in store.insertion_order
                t.predicate == p && t.object == o && put!(ch, t)
            end
        end
    elseif !isnothing(s)
        if haskey(store.spo, s)
            for t in store.insertion_order
                t.subject == s && put!(ch, t)
            end
        end
    elseif !isnothing(p)
        if haskey(store.pos, p)
            for t in store.insertion_order
                t.predicate == p && put!(ch, t)
            end
        end
    elseif !isnothing(o)
        if haskey(store.osp, o)
            for t in store.insertion_order
                t.object == o && put!(ch, t)
            end
        end
    else
        for t in store.insertion_order
            put!(ch, t)
        end
    end
end

Base.length(store::MemoryStore) = store.count
Base.isempty(store::MemoryStore) = store.count == 0

function add_bulk!(store::MemoryStore, triples_vec::Vector{Triple})
    n = length(triples_vec)
    sizehint!(store.spo, n ÷ 4)
    sizehint!(store.pos, 16)
    sizehint!(store.osp, n ÷ 2)
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
    end
    store.insertion_order = copy(triples_vec)
    store.count = n
    store
end
