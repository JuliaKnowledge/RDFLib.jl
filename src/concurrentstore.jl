# ─── ConcurrentStore ────────────────────────────────────────────────
# Thread-safe wrapper for any AbstractStore using ReentrantLock.

"""
    ConcurrentStore(inner::AbstractStore)

A thread-safe store wrapper that serializes access via a `ReentrantLock`.
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
    collected = lock(store.lock) do
        collect(RDFLib.triples(store.inner, pattern))
    end
    Channel{RDFLib.Triple}() do ch
        for t in collected
            put!(ch, t)
        end
    end
end

Base.length(store::ConcurrentStore) = lock(store.lock) do; length(store.inner); end
Base.isempty(store::ConcurrentStore) = lock(store.lock) do; isempty(store.inner); end
