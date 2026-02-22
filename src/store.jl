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
end

MemoryStore() = MemoryStore(
    Dict{Identifier, Dict{Identifier, Set{Identifier}}}(),
    Dict{Identifier, Dict{Identifier, Set{Identifier}}}(),
    Dict{Identifier, Dict{Identifier, Set{Identifier}}}(),
    0
)

function add!(store::MemoryStore, t::Triple)
    s, p, o = t.subject, t.predicate, t.object

    # Check if already present
    if haskey(store.spo, s) && haskey(store.spo[s], p) && o in store.spo[s][p]
        return store
    end

    # SPO index
    if !haskey(store.spo, s)
        store.spo[s] = Dict{Identifier, Set{Identifier}}()
    end
    if !haskey(store.spo[s], p)
        store.spo[s][p] = Set{Identifier}()
    end
    push!(store.spo[s][p], o)

    # POS index
    if !haskey(store.pos, p)
        store.pos[p] = Dict{Identifier, Set{Identifier}}()
    end
    if !haskey(store.pos[p], o)
        store.pos[p][o] = Set{Identifier}()
    end
    push!(store.pos[p][o], s)

    # OSP index
    if !haskey(store.osp, o)
        store.osp[o] = Dict{Identifier, Set{Identifier}}()
    end
    if !haskey(store.osp[o], s)
        store.osp[o][s] = Set{Identifier}()
    end
    push!(store.osp[o][s], p)

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
        # Fully bound — just check existence
        if haskey(store.spo, s) && haskey(store.spo[s], p) && o in store.spo[s][p]
            put!(ch, Triple(s, p, o))
        end
    elseif !isnothing(s) && !isnothing(p)
        # S P ? — look up in SPO
        if haskey(store.spo, s) && haskey(store.spo[s], p)
            for obj in store.spo[s][p]
                put!(ch, Triple(s, p, obj))
            end
        end
    elseif !isnothing(s) && !isnothing(o)
        # S ? O — look up in OSP
        if haskey(store.osp, o) && haskey(store.osp[o], s)
            for pred in store.osp[o][s]
                put!(ch, Triple(s, pred, o))
            end
        end
    elseif !isnothing(p) && !isnothing(o)
        # ? P O — look up in POS
        if haskey(store.pos, p) && haskey(store.pos[p], o)
            for subj in store.pos[p][o]
                put!(ch, Triple(subj, p, o))
            end
        end
    elseif !isnothing(s)
        # S ? ? — iterate SPO[s]
        if haskey(store.spo, s)
            for (pred, objs) in store.spo[s]
                for obj in objs
                    put!(ch, Triple(s, pred, obj))
                end
            end
        end
    elseif !isnothing(p)
        # ? P ? — iterate POS[p]
        if haskey(store.pos, p)
            for (obj, subjs) in store.pos[p]
                for subj in subjs
                    put!(ch, Triple(subj, p, obj))
                end
            end
        end
    elseif !isnothing(o)
        # ? ? O — iterate OSP[o]
        if haskey(store.osp, o)
            for (subj, preds) in store.osp[o]
                for pred in preds
                    put!(ch, Triple(subj, pred, o))
                end
            end
        end
    else
        # ? ? ? — iterate everything
        for (subj, po) in store.spo
            for (pred, objs) in po
                for obj in objs
                    put!(ch, Triple(subj, pred, obj))
                end
            end
        end
    end
end

Base.length(store::MemoryStore) = store.count
Base.isempty(store::MemoryStore) = store.count == 0
