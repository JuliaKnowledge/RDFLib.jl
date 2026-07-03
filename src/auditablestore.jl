# ─── AuditableStore ─────────────────────────────────────────────────
# Wraps any AbstractStore and records all add/remove operations for undo.

"""
    AuditableStore(inner::AbstractStore)

A store wrapper that records all add/remove operations in a journal,
enabling undo of the most recent operation.
"""
mutable struct AuditableStore{S<:RDFLib.AbstractStore} <: RDFLib.AbstractStore
    inner::S
    journal::Vector{Tuple{Symbol, RDFLib.Triple}}
end

AuditableStore(inner::RDFLib.AbstractStore) = AuditableStore(inner, Tuple{Symbol, RDFLib.Triple}[])

function _auditable_contains(store::RDFLib.AbstractStore, t::RDFLib.Triple)
    for _ in RDFLib.triples(store, (t.subject, t.predicate, t.object))
        return true
    end
    false
end

function RDFLib.add!(store::AuditableStore, t::RDFLib.Triple)
    already_present = _auditable_contains(store.inner, t)
    RDFLib.add!(store.inner, t)
    if !already_present && _auditable_contains(store.inner, t)
        push!(store.journal, (:add, t))
    end
    store
end

function RDFLib.remove!(store::AuditableStore, pattern::RDFLib.TriplePattern)
    candidates = collect(RDFLib.triples(store.inner, pattern))
    RDFLib.remove!(store.inner, pattern)
    for t in candidates
        _auditable_contains(store.inner, t) && continue
        push!(store.journal, (:remove, t))
    end
    store
end

RDFLib.triples(store::AuditableStore, pattern::RDFLib.TriplePattern) = RDFLib.triples(store.inner, pattern)
Base.length(store::AuditableStore) = length(store.inner)
Base.isempty(store::AuditableStore) = isempty(store.inner)

"""
    undo!(store::AuditableStore)

Undo the last recorded operation. Returns `(op, triple)` or `nothing`.
"""
function undo!(store::AuditableStore)
    isempty(store.journal) && return nothing
    op, t = pop!(store.journal)
    if op == :add
        RDFLib.remove!(store.inner, (t.subject, t.predicate, t.object))
    else
        RDFLib.add!(store.inner, t)
    end
    (op, t)
end

"""
    journal(store::AuditableStore)

Return the journal of recorded operations.
"""
journal(store::AuditableStore) = store.journal

"""
    clear_journal!(store::AuditableStore)

Clear the operation journal without undoing anything.
"""
function clear_journal!(store::AuditableStore)
    empty!(store.journal)
    store
end
