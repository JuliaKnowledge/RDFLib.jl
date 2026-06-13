# ─── ConcurrentStore ────────────────────────────────────────────────
# Thread-safe wrapper for any AbstractStore using ReentrantLock.

"""
    ConcurrentStore(inner::AbstractStore)

A thread-safe store wrapper that serializes all access via a single
`ReentrantLock` per store (coarse-grained: one operation at a time, but
re-entrant so a thread holding the lock may call other store operations).
`triples` returns a fully materialized `Vector{Triple}` snapshot collected
under the lock, so iterating the result requires no further
synchronization and is unaffected by concurrent mutation.
"""
mutable struct ConcurrentStore{S<:RDFLib.AbstractStore} <: RDFLib.AbstractStore
    inner::S
    lock::ReentrantLock
end

ConcurrentStore(inner::RDFLib.AbstractStore) = ConcurrentStore(inner, ReentrantLock())

function RDFLib.add!(store::ConcurrentStore, t::RDFLib.Triple)
    lock(store.lock) do
        RDFLib.add!(store.inner, t)
    end
    store
end

function RDFLib.remove!(store::ConcurrentStore, pattern::RDFLib.TriplePattern)
    lock(store.lock) do
        RDFLib.remove!(store.inner, pattern)
    end
    store
end

function RDFLib.triples(store::ConcurrentStore, pattern::RDFLib.TriplePattern)
    # The result is already a snapshot collected under the lock; return it
    # directly instead of replaying it through an unbuffered Channel
    # (which cost a task switch per triple).
    lock(store.lock) do
        collect(RDFLib.triples(store.inner, pattern))
    end
end

Base.length(store::ConcurrentStore) = lock(store.lock) do; length(store.inner); end
Base.isempty(store::ConcurrentStore) = lock(store.lock) do; isempty(store.inner); end
