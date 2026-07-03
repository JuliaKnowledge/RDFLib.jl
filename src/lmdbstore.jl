# ─── LMDBStore ──────────────────────────────────────────────────────
#
# Persistent triple store backed by LMDB (Lightning Memory-Mapped Database).
# Uses dictionary encoding (terms ↔ integer IDs) and three sorted indices
# (SPO, POS, OSP) for efficient pattern matching with prefix range scans.
#
# Architecture:
#   - "term2id" DB: serialized term bytes → UInt64 ID (big-endian)
#   - "id2term" DB: UInt64 ID (big-endian) → serialized term bytes
#   - "spo" DB: 24-byte key (s_id ++ p_id ++ o_id) → empty value
#   - "pos" DB: 24-byte key (p_id ++ o_id ++ s_id) → empty value
#   - "osp" DB: 24-byte key (o_id ++ s_id ++ p_id) → empty value
#   - "meta" DB: metadata (next_id counter, triple count)

using LMDB

"""
    LMDBStore(path::AbstractString; map_size=1_073_741_824)
    LMDBStore(path::AbstractString, env::LMDB.Environment)

Persistent triple store backed by LMDB with dictionary-encoded SPO/POS/OSP indices.

Each term (URI, literal, blank node) is stored once in a dictionary and referenced
by a compact 8-byte integer ID. Triples are stored as 24-byte keys in three sorted
indices, enabling efficient prefix-based range scans for pattern matching.

`map_size` (bytes) sets the maximum size of the memory map and may exceed
4 GiB (it is passed to LMDB as a `size_t`). The in-memory term↔id caches
are bounded by `_LMDB_TERM_CACHE_MAX` entries and fully evicted when the
cap is reached.

# Examples
```julia
store = LMDBStore(mktempdir())
g = RDFGraph(store=store)
add!(g, Triple(URIRef("http://example.org/s"), URIRef("http://example.org/p"), Literal("hello")))
close(store)
```
"""
mutable struct LMDBStore <: AbstractStore
    env::LMDB.Environment
    path::String
    # DB handles (opened lazily within transactions)
    _db_term2id::Union{LMDB.DBI, Nothing}
    _db_id2term::Union{LMDB.DBI, Nothing}
    _db_spo::Union{LMDB.DBI, Nothing}
    _db_pos::Union{LMDB.DBI, Nothing}
    _db_osp::Union{LMDB.DBI, Nothing}
    _db_meta::Union{LMDB.DBI, Nothing}
    _next_id::UInt64
    _count::Int
    _read_txn::Union{LMDB.Transaction, Nothing}  # cached readonly txn
    _term2id_cache::Dict{Identifier, UInt64}      # in-memory term→id cache
    _id2term_cache::Dict{UInt64, Identifier}       # in-memory id→term cache
end

const _LMDB_READONLY = Cuint(0x20000)  # MDB_RDONLY
const _LMDB_KEY_BYTES = 24  # 3 × 8 bytes (UInt64 big-endian)
const _LMDB_EMPTY_VAL = UInt8[0]

# Soft cap on the in-memory term↔id caches (number of entries). When the
# cap is reached both caches are cleared (simple full eviction — terms are
# re-cached from LMDB on demand). `add_bulk!` may temporarily exceed the
# cap within a single batch because it requires all of the batch's terms
# to stay cached between its phases; the cap is re-applied on the next
# cache insert. A `Ref` so it can be tuned (and tested) at runtime.
const _LMDB_TERM_CACHE_MAX = Ref(1_000_000)

# Insert into both caches, applying the size cap first.
function _lmdb_cache_put!(store, term::Identifier, id::UInt64)
    if length(store._term2id_cache) >= _LMDB_TERM_CACHE_MAX[]
        empty!(store._term2id_cache)
        empty!(store._id2term_cache)
    end
    store._term2id_cache[term] = id
    store._id2term_cache[id] = term
    nothing
end

function LMDBStore(path::AbstractString; map_size::Integer=1_073_741_824)
    map_size > 0 || throw(ArgumentError("map_size must be positive"))
    mkpath(String(path))
    env = LMDB.create()
    env[:DBs] = 8
    # mdb_env_set_mapsize takes a size_t, but LMDB.jl's setindex! only
    # accepts Cuint, which throws InexactError for map sizes ≥ 4 GiB.
    # Call the C API wrapper directly with the correct integer type.
    LMDB.LibLMDB.mdb_env_set_mapsize(env.handle, Csize_t(map_size))
    LMDB.open(env, String(path))
    store = LMDBStore(env, String(path), nothing, nothing, nothing, nothing, nothing, nothing,
                      UInt64(1), 0, nothing, Dict{Identifier,UInt64}(), Dict{UInt64,Identifier}())
    _lmdb_init!(store)
    store
end

# ─── Internal: DB handle management ────────────────────────────────

function _lmdb_open_dbs!(store::LMDBStore, txn::LMDB.Transaction)
    store._db_term2id = LMDB.open(txn, "term2id", flags=LMDB.MDB_CREATE)
    store._db_id2term = LMDB.open(txn, "id2term", flags=LMDB.MDB_CREATE)
    store._db_spo = LMDB.open(txn, "spo", flags=LMDB.MDB_CREATE)
    store._db_pos = LMDB.open(txn, "pos", flags=LMDB.MDB_CREATE)
    store._db_osp = LMDB.open(txn, "osp", flags=LMDB.MDB_CREATE)
    store._db_meta = LMDB.open(txn, "meta", flags=LMDB.MDB_CREATE)
end

function _lmdb_init!(store::LMDBStore)
    txn = LMDB.start(store.env)
    try
        _lmdb_open_dbs!(store, txn)
        # Load metadata
        store._next_id = _lmdb_get_meta_u64(txn, store._db_meta, "next_id", UInt64(1))
        store._count = Int(_lmdb_get_meta_u64(txn, store._db_meta, "count", UInt64(0)))
        LMDB.commit(txn)
    catch
        LMDB.abort(txn)
        rethrow()
    end
end

function _lmdb_get_meta_u64(txn, db, key::String, default::UInt64)
    try
        val = LMDB.get(txn, db, Vector{UInt8}(key), Vector{UInt8})
        length(val) == 8 || return default
        ntoh(reinterpret(UInt64, val)[1])
    catch
        default
    end
end

function _lmdb_put_meta_u64!(txn, db, key::String, val::UInt64)
    LMDB.put!(txn, db, Vector{UInt8}(key), collect(reinterpret(UInt8, [hton(val)])))
end

# ─── Internal: Term serialization ──────────────────────────────────
# Format: type_byte ++ data
#   URIRef:  0x01 ++ uri_string
#   BNode:   0x02 ++ id_string
#   Legacy Literal: 0x03 ++ lexical \0 datatype_uri \0 language
#   Literal v2:     0x04 ++ len(lexical) ++ lexical ++ len(datatype_uri) ++
#                         datatype_uri ++ len(language) ++ language ++
#                         len(direction) ++ direction

function _lmdb_serialize_term(term::URIRef)
    io = IOBuffer()
    write(io, UInt8(0x01))
    write(io, string(term))
    take!(io)
end

function _lmdb_serialize_term(term::BNode)
    io = IOBuffer()
    write(io, UInt8(0x02))
    write(io, string(term))
    take!(io)
end

function _lmdb_serialize_term(term::Literal)
    io = IOBuffer()
    write(io, UInt8(0x04))
    lex = Vector{UInt8}(codeunits(term.lexical))
    dt = Vector{UInt8}(codeunits(isnothing(term.datatype) ? "" : string(term.datatype)))
    lang = Vector{UInt8}(codeunits(something(term.language, "")))
    dir = Vector{UInt8}(codeunits(something(term.direction, "")))
    for field in (lex, dt, lang, dir)
        n = UInt32(length(field))
        write(io, UInt8((n >> 24) & 0xff))
        write(io, UInt8((n >> 16) & 0xff))
        write(io, UInt8((n >> 8) & 0xff))
        write(io, UInt8(n & 0xff))
        write(io, field)
    end
    take!(io)
end

function _lmdb_serialize_term_legacy(term::Literal)
    io = IOBuffer()
    write(io, UInt8(0x03))
    write(io, term.lexical)
    write(io, UInt8(0x00))
    dt = isnothing(term.datatype) ? "" : string(term.datatype)
    write(io, dt)
    write(io, UInt8(0x00))
    lang = something(term.language, "")
    write(io, lang)
    take!(io)
end

function _lmdb_read_u32(data::Vector{UInt8}, pos::Int)
    pos + 3 <= length(data) || error("Truncated LMDB literal field length")
    n = (UInt32(data[pos]) << 24) |
        (UInt32(data[pos + 1]) << 16) |
        (UInt32(data[pos + 2]) << 8) |
        UInt32(data[pos + 3])
    (Int(n), pos + 4)
end

function _lmdb_read_field(data::Vector{UInt8}, pos::Int)
    len, pos = _lmdb_read_u32(data, pos)
    len == 0 && return ("", pos)
    stop = pos + len - 1
    stop <= length(data) || error("Truncated LMDB literal field payload")
    (String(data[pos:stop]), stop + 1)
end

function _lmdb_deserialize_term(data::Vector{UInt8})
    tag = data[1]
    if tag == 0x01
        URIRef(String(data[2:end]))
    elseif tag == 0x02
        BNode(String(data[2:end]))
    elseif tag == 0x03
        # Split on null bytes
        rest = data[2:end]
        z1 = findfirst(==(0x00), rest)
        lexical = String(rest[1:z1-1])
        rest2 = rest[z1+1:end]
        z2 = findfirst(==(0x00), rest2)
        dt_str = String(rest2[1:z2-1])
        lang_str = String(rest2[z2+1:end])
        lang = isempty(lang_str) ? nothing : lang_str
        if !isnothing(lang)
            Literal(lexical, lang=lang)
        elseif !isempty(dt_str)
            Literal(lexical, datatype=URIRef(dt_str))
        else
            Literal(lexical)
        end
    elseif tag == 0x04
        pos = 2
        lexical, pos = _lmdb_read_field(data, pos)
        dt_str, pos = _lmdb_read_field(data, pos)
        lang_str, pos = _lmdb_read_field(data, pos)
        dir_str, pos = _lmdb_read_field(data, pos)
        dt = isempty(dt_str) ? nothing : URIRef(dt_str)
        lang = isempty(lang_str) ? nothing : lang_str
        dir = isempty(dir_str) ? nothing : dir_str
        Literal(lexical; datatype=dt, lang=lang, direction=dir)
    else
        error("Unknown term type tag: $tag")
    end
end

function _lmdb_lookup_term_id(txn::LMDB.Transaction, store::LMDBStore,
                              term::Identifier, term_bytes::Vector{UInt8})
    existing_id = try
        val = LMDB.get(txn, store._db_term2id, term_bytes, Vector{UInt8})
        ntoh(reinterpret(UInt64, val)[1])
    catch
        nothing
    end
    if isnothing(existing_id) && term isa Literal && isnothing(term.direction)
        legacy_bytes = _lmdb_serialize_term_legacy(term)
        existing_id = try
            val = LMDB.get(txn, store._db_term2id, legacy_bytes, Vector{UInt8})
            ntoh(reinterpret(UInt64, val)[1])
        catch
            nothing
        end
    end
    existing_id
end

# ─── Internal: ID packing ─────────────────────────────────────────

function _lmdb_pack_key!(buf::Vector{UInt8}, a::UInt64, b::UInt64, c::UInt64)
    buf[1:8]   .= reinterpret(UInt8, [hton(a)])
    buf[9:16]  .= reinterpret(UInt8, [hton(b)])
    buf[17:24] .= reinterpret(UInt8, [hton(c)])
    buf
end

function _lmdb_unpack_key(buf::Vector{UInt8})
    a = ntoh(reinterpret(UInt64, buf[1:8])[1])
    b = ntoh(reinterpret(UInt64, buf[9:16])[1])
    c = ntoh(reinterpret(UInt64, buf[17:24])[1])
    (a, b, c)
end

function _lmdb_prefix(id::UInt64)
    collect(reinterpret(UInt8, [hton(id)]))
end

function _lmdb_prefix2(a::UInt64, b::UInt64)
    buf = Vector{UInt8}(undef, 16)
    buf[1:8]  .= reinterpret(UInt8, [hton(a)])
    buf[9:16] .= reinterpret(UInt8, [hton(b)])
    buf
end

# ─── Internal: Term ↔ ID mapping ──────────────────────────────────

function _lmdb_term_to_id!(store::LMDBStore, txn::LMDB.Transaction, term::Identifier)
    # Check in-memory cache first
    cached = get(store._term2id_cache, term, nothing)
    !isnothing(cached) && return cached

    term_bytes = _lmdb_serialize_term(term)
    existing_id = _lmdb_lookup_term_id(txn, store, term, term_bytes)
    if !isnothing(existing_id)
        _lmdb_cache_put!(store, term, existing_id)
        return existing_id
    end

    # Assign new ID
    id = store._next_id
    store._next_id += 1
    id_bytes = reinterpret(UInt8, [hton(id)])
    LMDB.put!(txn, store._db_term2id, term_bytes, id_bytes)
    LMDB.put!(txn, store._db_id2term, id_bytes, term_bytes)
    _lmdb_cache_put!(store, term, id)
    id
end

function _lmdb_term_to_id(store::LMDBStore, txn::LMDB.Transaction, term::Identifier)
    cached = get(store._term2id_cache, term, nothing)
    !isnothing(cached) && return cached

    term_bytes = _lmdb_serialize_term(term)
    id = _lmdb_lookup_term_id(txn, store, term, term_bytes)
    if !isnothing(id)
        _lmdb_cache_put!(store, term, id)
        id
    else
        nothing
    end
end

function _lmdb_id_to_term(store::LMDBStore, txn::LMDB.Transaction, id::UInt64)
    cached = get(store._id2term_cache, id, nothing)
    !isnothing(cached) && return cached

    id_bytes = reinterpret(UInt8, [hton(id)])
    data = LMDB.get(txn, store._db_id2term, id_bytes, Vector{UInt8})
    term = _lmdb_deserialize_term(data)
    _lmdb_cache_put!(store, term, id)
    term
end

# ─── Store interface ───────────────────────────────────────────────

function add!(store::LMDBStore, t::Triple)
    txn = LMDB.start(store.env)
    try
        s_id = _lmdb_term_to_id!(store, txn, t.subject)
        p_id = _lmdb_term_to_id!(store, txn, t.predicate)
        o_id = _lmdb_term_to_id!(store, txn, t.object)

        key = Vector{UInt8}(undef, _LMDB_KEY_BYTES)

        # Check if already exists (SPO)
        _lmdb_pack_key!(key, s_id, p_id, o_id)
        exists = try
            LMDB.get(txn, store._db_spo, key, Vector{UInt8})
            true
        catch
            false
        end
        if !exists
            LMDB.put!(txn, store._db_spo, key, _LMDB_EMPTY_VAL)
            _lmdb_pack_key!(key, p_id, o_id, s_id)
            LMDB.put!(txn, store._db_pos, key, _LMDB_EMPTY_VAL)
            _lmdb_pack_key!(key, o_id, s_id, p_id)
            LMDB.put!(txn, store._db_osp, key, _LMDB_EMPTY_VAL)
            store._count += 1
            _lmdb_put_meta_u64!(txn, store._db_meta, "count", UInt64(store._count))
            _lmdb_put_meta_u64!(txn, store._db_meta, "next_id", store._next_id)
        end
        LMDB.commit(txn)
        _lmdb_invalidate_read_txn!(store)
    catch
        LMDB.abort(txn)
        rethrow()
    end
    store
end

function remove!(store::LMDBStore, pattern::TriplePattern)
    to_remove = triples(store, pattern)
    isempty(to_remove) && return store
    _lmdb_invalidate_read_txn!(store)
    txn = LMDB.start(store.env)
    try
        key = Vector{UInt8}(undef, _LMDB_KEY_BYTES)
        for t in to_remove
            s_id = _lmdb_term_to_id(store, txn, t.subject)
            p_id = _lmdb_term_to_id(store, txn, t.predicate)
            o_id = _lmdb_term_to_id(store, txn, t.object)
            (isnothing(s_id) || isnothing(p_id) || isnothing(o_id)) && continue

            _lmdb_pack_key!(key, s_id, p_id, o_id)
            try LMDB.delete!(txn, store._db_spo, key) catch end
            _lmdb_pack_key!(key, p_id, o_id, s_id)
            try LMDB.delete!(txn, store._db_pos, key) catch end
            _lmdb_pack_key!(key, o_id, s_id, p_id)
            try LMDB.delete!(txn, store._db_osp, key) catch end
            store._count -= 1
        end
        _lmdb_put_meta_u64!(txn, store._db_meta, "count", UInt64(max(0, store._count)))
        LMDB.commit(txn)
        _lmdb_invalidate_read_txn!(store)
    catch
        LMDB.abort(txn)
        rethrow()
    end
    store
end

function _lmdb_invalidate_read_txn!(store::LMDBStore)
    if !isnothing(store._read_txn)
        try LMDB.abort(store._read_txn) catch end
        store._read_txn = nothing
    end
end

function _lmdb_get_read_txn(store::LMDBStore)
    if isnothing(store._read_txn)
        store._read_txn = LMDB.start(store.env, flags=_LMDB_READONLY)
    end
    store._read_txn
end

function triples(store::LMDBStore, pattern::TriplePattern)
    s, p, o = pattern
    result = Triple[]
    txn = _lmdb_get_read_txn(store)
    try
        _lmdb_query!(result, store, txn, s, p, o)
    catch e
        # If txn went stale, invalidate and retry once
        _lmdb_invalidate_read_txn!(store)
        txn = _lmdb_get_read_txn(store)
        _lmdb_query!(result, store, txn, s, p, o)
    end
    result
end

function _lmdb_query!(result::Vector{Triple}, store::LMDBStore, txn::LMDB.Transaction,
                       s, p, o)
    # Resolve known terms to IDs
    s_id = isnothing(s) ? nothing : _lmdb_term_to_id(store, txn, s)
    p_id = isnothing(p) ? nothing : _lmdb_term_to_id(store, txn, p)
    o_id = isnothing(o) ? nothing : _lmdb_term_to_id(store, txn, o)

    # If a specified term has no ID, it can't match anything
    (!isnothing(s) && isnothing(s_id)) && return
    (!isnothing(p) && isnothing(p_id)) && return
    (!isnothing(o) && isnothing(o_id)) && return

    if !isnothing(s_id) && !isnothing(p_id) && !isnothing(o_id)
        # Fully bound — point lookup in SPO
        key = Vector{UInt8}(undef, _LMDB_KEY_BYTES)
        _lmdb_pack_key!(key, s_id, p_id, o_id)
        exists = try
            LMDB.get(txn, store._db_spo, key, Vector{UInt8}); true
        catch; false
        end
        exists && push!(result, Triple(s, p, o))
    elseif !isnothing(s_id) && !isnothing(p_id)
        # S P ? — prefix scan in SPO with 16-byte prefix
        _lmdb_scan_index!(result, store, txn, store._db_spo,
            _lmdb_prefix2(s_id, p_id)) do a, b, c
            Triple(_lmdb_id_to_term(store, txn, a),
                   _lmdb_id_to_term(store, txn, b),
                   _lmdb_id_to_term(store, txn, c))
        end
    elseif !isnothing(p_id) && !isnothing(o_id)
        # ? P O — prefix scan in POS
        _lmdb_scan_index!(result, store, txn, store._db_pos,
            _lmdb_prefix2(p_id, o_id)) do a, b, c
            Triple(_lmdb_id_to_term(store, txn, c),  # s
                   _lmdb_id_to_term(store, txn, a),  # p
                   _lmdb_id_to_term(store, txn, b))   # o
        end
    elseif !isnothing(s_id) && !isnothing(o_id)
        # S ? O — prefix scan in OSP
        _lmdb_scan_index!(result, store, txn, store._db_osp,
            _lmdb_prefix2(o_id, s_id)) do a, b, c
            Triple(_lmdb_id_to_term(store, txn, b),  # s
                   _lmdb_id_to_term(store, txn, c),  # p
                   _lmdb_id_to_term(store, txn, a))   # o
        end
    elseif !isnothing(s_id)
        # S ? ? — prefix scan in SPO with 8-byte prefix
        _lmdb_scan_index!(result, store, txn, store._db_spo,
            _lmdb_prefix(s_id)) do a, b, c
            Triple(_lmdb_id_to_term(store, txn, a),
                   _lmdb_id_to_term(store, txn, b),
                   _lmdb_id_to_term(store, txn, c))
        end
    elseif !isnothing(p_id)
        # ? P ? — prefix scan in POS
        _lmdb_scan_index!(result, store, txn, store._db_pos,
            _lmdb_prefix(p_id)) do a, b, c
            Triple(_lmdb_id_to_term(store, txn, c),
                   _lmdb_id_to_term(store, txn, a),
                   _lmdb_id_to_term(store, txn, b))
        end
    elseif !isnothing(o_id)
        # ? ? O — prefix scan in OSP
        _lmdb_scan_index!(result, store, txn, store._db_osp,
            _lmdb_prefix(o_id)) do a, b, c
            Triple(_lmdb_id_to_term(store, txn, b),
                   _lmdb_id_to_term(store, txn, c),
                   _lmdb_id_to_term(store, txn, a))
        end
    else
        # ? ? ? — full scan of SPO
        _lmdb_scan_index!(result, store, txn, store._db_spo,
            UInt8[]) do a, b, c
            Triple(_lmdb_id_to_term(store, txn, a),
                   _lmdb_id_to_term(store, txn, b),
                   _lmdb_id_to_term(store, txn, c))
        end
    end
end

function _lmdb_scan_index!(make_triple, result::Vector{Triple},
                            store::LMDBStore, txn::LMDB.Transaction,
                            db::LMDB.DBI, prefix::AbstractVector{UInt8})
    cur = LMDB.open(txn, db)
    try
        for k in LMDB.keys(cur, Vector{UInt8}; prefix=prefix)
            length(k) == _LMDB_KEY_BYTES || continue
            a, b, c = _lmdb_unpack_key(k)
            push!(result, make_triple(a, b, c))
        end
    finally
        LMDB.close(cur)
    end
end

Base.length(store::LMDBStore) = store._count
Base.isempty(store::LMDBStore) = store._count == 0

function Base.close(store::LMDBStore)
    _lmdb_invalidate_read_txn!(store)
    for db in (store._db_term2id, store._db_id2term, store._db_spo,
               store._db_pos, store._db_osp, store._db_meta)
        !isnothing(db) && LMDB.isopen(db) && LMDB.close(store.env, db)
    end
    LMDB.isopen(store.env) && LMDB.close(store.env)
    store._db_term2id = nothing
    store._db_id2term = nothing
    store._db_spo = nothing
    store._db_pos = nothing
    store._db_osp = nothing
    store._db_meta = nothing
end

"""
    foreach_triple(f, store::LMDBStore, pattern::TriplePattern)

Call `f(triple)` for each matching triple without allocating a result vector.
"""
function foreach_triple(f, store::LMDBStore, pattern::TriplePattern)
    for t in triples(store, pattern)
        f(t)
    end
    nothing
end

"""
    transaction(f, store::LMDBStore)

Execute `f(store)` within an LMDB transaction. Currently triples() and add!()
each use their own transactions; this is provided for interface compatibility.
"""
function transaction(f, store::LMDBStore)
    f(store)
end

# ─── Fast clear ────────────────────────────────────────────────────

"""
    clear!(store::LMDBStore)

Efficiently clear all data from the store by emptying all LMDB databases.
Much faster than removing triples one at a time.
"""
function clear!(store::LMDBStore)
    _lmdb_invalidate_read_txn!(store)
    txn = LMDB.start(store.env)
    try
        # Empty all databases (delete=false keeps the DB handles valid)
        LMDB.drop(txn, store._db_spo; delete=false)
        LMDB.drop(txn, store._db_pos; delete=false)
        LMDB.drop(txn, store._db_osp; delete=false)
        LMDB.drop(txn, store._db_term2id; delete=false)
        LMDB.drop(txn, store._db_id2term; delete=false)
        LMDB.drop(txn, store._db_meta; delete=false)
        # Reset metadata
        store._next_id = UInt64(1)
        store._count = 0
        _lmdb_put_meta_u64!(txn, store._db_meta, "next_id", UInt64(1))
        _lmdb_put_meta_u64!(txn, store._db_meta, "count", UInt64(0))
        LMDB.commit(txn)
    catch
        LMDB.abort(txn)
        rethrow()
    end
    empty!(store._term2id_cache)
    empty!(store._id2term_cache)
    store
end

# ─── Batch add for performance ─────────────────────────────────────

const _LMDB_APPEND = Cuint(0x20000)  # MDB_APPEND flag for sorted inserts

"""
    add_bulk!(store::LMDBStore, triples)

Add multiple triples in a single LMDB transaction for much higher throughput.
When the store is empty, uses sorted inserts with MDB_APPEND for maximum speed.
"""
function add_bulk!(store::LMDBStore, triples_iter)
    triples_vec = triples_iter isa AbstractVector ? triples_iter : collect(triples_iter)
    isempty(triples_vec) && return 0
    is_empty = store._count == 0

    # Apply the term cache cap up-front: the phases below require every
    # term of this batch to remain cached, so eviction must not happen
    # mid-batch (the cap may be temporarily exceeded by one batch's terms).
    if length(store._term2id_cache) >= _LMDB_TERM_CACHE_MAX[]
        empty!(store._term2id_cache)
        empty!(store._id2term_cache)
    end

    # Phase 1: Pre-collect unique terms not already in cache
    new_terms = Dict{Identifier, Vector{UInt8}}()
    for t in triples_vec
        for term in (t.subject, t.predicate, t.object)
            if !haskey(store._term2id_cache, term) && !haskey(new_terms, term)
                new_terms[term] = _lmdb_serialize_term(term)
            end
        end
    end

    txn = LMDB.start(store.env)
    try
        # Phase 2: Assign IDs to all new terms in one pass
        if is_empty && isempty(store._term2id_cache)
            # Empty store: skip LMDB lookups, assign IDs directly
            # Sort term bytes so id2term inserts are in key order (MDB_APPEND)
            sorted_terms = sort!(collect(new_terms), by=last)
            for (term, bytes) in sorted_terms
                id = store._next_id
                store._next_id += 1
                id_bytes = reinterpret(UInt8, [hton(id)])
                LMDB.put!(txn, store._db_term2id, bytes, id_bytes)
                LMDB.put!(txn, store._db_id2term, id_bytes, bytes; flags=_LMDB_APPEND)
                store._term2id_cache[term] = id
                store._id2term_cache[id] = term
            end
        else
            # Non-empty store: check LMDB for existing terms
            for (term, bytes) in new_terms
                existing = try
                    val = LMDB.get(txn, store._db_term2id, bytes, Vector{UInt8})
                    ntoh(reinterpret(UInt64, val)[1])
                catch
                    nothing
                end
                if isnothing(existing) && term isa Literal && isnothing(term.direction)
                    legacy = _lmdb_serialize_term_legacy(term)
                    existing = try
                        val = LMDB.get(txn, store._db_term2id, legacy, Vector{UInt8})
                        ntoh(reinterpret(UInt64, val)[1])
                    catch
                        nothing
                    end
                end
                if !isnothing(existing)
                    store._term2id_cache[term] = existing
                    store._id2term_cache[existing] = term
                else
                    id = store._next_id
                    store._next_id += 1
                    id_bytes = reinterpret(UInt8, [hton(id)])
                    LMDB.put!(txn, store._db_term2id, bytes, id_bytes)
                    LMDB.put!(txn, store._db_id2term, id_bytes, bytes)
                    store._term2id_cache[term] = id
                    store._id2term_cache[id] = term
                end
            end
        end

        # Phase 3: Build triple ID tuples and dedup
        id_triples = Vector{NTuple{3,UInt64}}(undef, length(triples_vec))
        for (i, t) in enumerate(triples_vec)
            id_triples[i] = (
                store._term2id_cache[t.subject],
                store._term2id_cache[t.predicate],
                store._term2id_cache[t.object]
            )
        end
        unique!(sort!(id_triples))  # sort + dedup

        key = Vector{UInt8}(undef, _LMDB_KEY_BYTES)

        if is_empty
            # Fast path: sorted inserts with MDB_APPEND (no existence checks)
            # SPO keys — already sorted by (s, p, o)
            for (s_id, p_id, o_id) in id_triples
                _lmdb_pack_key!(key, s_id, p_id, o_id)
                LMDB.put!(txn, store._db_spo, key, _LMDB_EMPTY_VAL; flags=_LMDB_APPEND)
            end
            # POS keys — sort by (p, o, s)
            sort!(id_triples, by=x -> (x[2], x[3], x[1]))
            for (s_id, p_id, o_id) in id_triples
                _lmdb_pack_key!(key, p_id, o_id, s_id)
                LMDB.put!(txn, store._db_pos, key, _LMDB_EMPTY_VAL; flags=_LMDB_APPEND)
            end
            # OSP keys — sort by (o, s, p)
            sort!(id_triples, by=x -> (x[3], x[1], x[2]))
            for (s_id, p_id, o_id) in id_triples
                _lmdb_pack_key!(key, o_id, s_id, p_id)
                LMDB.put!(txn, store._db_osp, key, _LMDB_EMPTY_VAL; flags=_LMDB_APPEND)
            end
            added = length(id_triples)
        else
            # Slow path: check existence before inserting
            added = 0
            for (s_id, p_id, o_id) in id_triples
                _lmdb_pack_key!(key, s_id, p_id, o_id)
                exists = try
                    LMDB.get(txn, store._db_spo, key, Vector{UInt8}); true
                catch; false
                end
                if !exists
                    LMDB.put!(txn, store._db_spo, key, _LMDB_EMPTY_VAL)
                    _lmdb_pack_key!(key, p_id, o_id, s_id)
                    LMDB.put!(txn, store._db_pos, key, _LMDB_EMPTY_VAL)
                    _lmdb_pack_key!(key, o_id, s_id, p_id)
                    LMDB.put!(txn, store._db_osp, key, _LMDB_EMPTY_VAL)
                    added += 1
                end
            end
        end

        store._count += added
        _lmdb_put_meta_u64!(txn, store._db_meta, "count", UInt64(store._count))
        _lmdb_put_meta_u64!(txn, store._db_meta, "next_id", store._next_id)
        LMDB.commit(txn)
        _lmdb_invalidate_read_txn!(store)
        added
    catch
        LMDB.abort(txn)
        rethrow()
    end
end
