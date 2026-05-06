# ─── Apache Arrow IPC serialization ──────────────────────────────────
#
# Stores a graph as two Arrow tables packaged in a single Arrow IPC
# file (the second table is appended via Arrow.append):
#
#   1. "terms"   columns: kind::UInt8, lex::String, lang::String,
#                          datatype::String — one row per dictionary id
#                          (id == row index, 1-based).
#   2. "triples" columns: s::UInt32, p::UInt32, o::UInt32 — encoded
#                          triples referencing term ids.
#
# kind: 1 = URIRef, 2 = BNode, 3 = Literal. lang/datatype are empty
# strings when not applicable.
#
# Goals:
#   * Fast load/save vs N-Triples/Turtle on large graphs.
#   * Zero-copy interop with Polars / maplib / DuckDB / pyarrow — the
#     `triples` table has the same shape as those engines expect.
#   * Optional dictionary-encoded Arrow term column for direct join
#     against external Arrow tables (future work).
#
# Note: this module deliberately does NOT introduce a new Store type;
# Arrow files are loaded into whatever store the user's RDFGraph uses
# (defaults to MemoryStore). For maximum efficiency on EncodedStore
# we provide a bulk-load fast path that bypasses term re-interning.

using Arrow

# ─── Term encoding helpers ────────────────────────────────────────────

@inline _term_kind(::URIRef)  = UInt8(1)
@inline _term_kind(::BNode)   = UInt8(2)
@inline _term_kind(::Literal) = UInt8(3)

@inline function _term_columns(t::URIRef)
    (UInt8(1), t.value, "", "")
end

@inline function _term_columns(t::BNode)
    (UInt8(2), t.id, "", "")
end

@inline function _term_columns(t::Literal)
    lang = isnothing(t.language) ? "" : t.language
    dt   = isnothing(t.datatype) ? "" : t.datatype.value
    (UInt8(3), t.lexical, lang, dt)
end

@inline function _decode_term(kind::UInt8, lex::AbstractString,
                                lang::AbstractString, datatype::AbstractString)::Identifier
    if kind == 1
        return URIRef(String(lex))
    elseif kind == 2
        return BNode(String(lex))
    elseif kind == 3
        if !isempty(lang)
            return Literal(String(lex), lang=String(lang))
        elseif !isempty(datatype)
            return Literal(String(lex), datatype=URIRef(String(datatype)))
        else
            return Literal(String(lex))
        end
    else
        throw(ArgumentError("unknown term kind $kind"))
    end
end

# ─── Build a (terms_table, triples_table) view of a graph ────────────
#
# Reuses the EncodedStore dictionary directly when possible to avoid
# rebuilding the term map on save.

function _build_arrow_tables(g::RDFGraph)
    s = g.store
    if s isa EncodedStore
        return _build_arrow_tables_from_encoded(s)
    end
    # Generic path: assign ids on the fly while iterating.
    term_to_id = Dict{Identifier,UInt32}()
    id_to_term = Identifier[]
    sids = UInt32[]; pids = UInt32[]; oids = UInt32[]
    n = length(g)
    sizehint!(sids, n); sizehint!(pids, n); sizehint!(oids, n)
    @inline function id_for!(t::Identifier)
        id = get(term_to_id, t, UInt32(0))
        id != 0 && return id
        push!(id_to_term, t)
        new = UInt32(length(id_to_term))
        term_to_id[t] = new
        return new
    end
    for tr in g
        push!(sids, id_for!(tr.subject))
        push!(pids, id_for!(tr.predicate))
        push!(oids, id_for!(tr.object))
    end
    return _terms_table(id_to_term), (s=sids, p=pids, o=oids)
end

function _build_arrow_tables_from_encoded(store::EncodedStore)
    n = length(store.insertion_order_enc)
    sids = Vector{UInt32}(undef, n)
    pids = Vector{UInt32}(undef, n)
    oids = Vector{UInt32}(undef, n)
    @inbounds for i in 1:n
        t = store.insertion_order_enc[i]
        sids[i] = t[1]; pids[i] = t[2]; oids[i] = t[3]
    end
    return _terms_table(store.id_to_term), (s=sids, p=pids, o=oids)
end

function _terms_table(id_to_term::Vector{Identifier})
    n = length(id_to_term)
    kinds = Vector{UInt8}(undef, n)
    lex   = Vector{String}(undef, n)
    lang  = Vector{String}(undef, n)
    dt    = Vector{String}(undef, n)
    @inbounds for i in 1:n
        kinds[i], lex[i], lang[i], dt[i] = _term_columns(id_to_term[i])
    end
    (kind=kinds, lex=lex, lang=lang, datatype=dt)
end

# ─── Public serialize / parse hooks ──────────────────────────────────

"""
    serialize_arrow(io::IO, g::RDFGraph)

Serialize a graph to the Arrow IPC stream format. Writes two tables
(`terms` then `triples`) into the same stream. Use `parse_arrow!` to
load.
"""
function serialize_arrow(io::IO, g::RDFGraph; compress::Union{Symbol,Nothing}=:lz4)
    terms_tbl, trip_tbl = _build_arrow_tables(g)
    terms_bytes = take!(let buf = IOBuffer()
        if compress === nothing
            Arrow.write(buf, terms_tbl)
        else
            Arrow.write(buf, terms_tbl; compress=compress)
        end
        buf
    end)
    trip_bytes = take!(let buf = IOBuffer()
        if compress === nothing
            Arrow.write(buf, trip_tbl)
        else
            Arrow.write(buf, trip_tbl; compress=compress)
        end
        buf
    end)
    # 16-byte header: magic "RDFLIBARROW01\0\0\0" + UInt64 terms-length + UInt64 triples-length
    write(io, b"RDFLIBARROW01\0\0\0")
    write(io, UInt64(length(terms_bytes)))
    write(io, UInt64(length(trip_bytes)))
    write(io, terms_bytes)
    write(io, trip_bytes)
    return nothing
end

function serialize_arrow(g::RDFGraph; compress::Union{Symbol,Nothing}=:lz4)
    buf = IOBuffer()
    serialize_arrow(buf, g; compress=compress)
    take!(buf)
end

"""
    parse_arrow!(g::RDFGraph, source) -> g

Read an Arrow IPC file written by `serialize_arrow` and load triples
into `g`. Source may be an `IO`, a filename, or a `Vector{UInt8}`.
"""
function parse_arrow!(g::RDFGraph, io::IO)
    header = read(io, 16)
    length(header) == 16 || throw(ArgumentError("truncated Arrow file"))
    String(header[1:13]) == "RDFLIBARROW01" || throw(ArgumentError("not an RDFLib Arrow file"))
    terms_len = read(io, UInt64)
    trip_len  = read(io, UInt64)
    terms_bytes = read(io, terms_len)
    trip_bytes  = read(io, trip_len)
    terms_tbl = Arrow.Table(terms_bytes)
    trip_tbl  = Arrow.Table(trip_bytes)
    _load_arrow_into_graph!(g, terms_tbl, trip_tbl)
end

function parse_arrow!(g::RDFGraph, source::AbstractString)
    open(source, "r") do io
        parse_arrow!(g, io)
    end
end

function parse_arrow!(g::RDFGraph, source::Vector{UInt8})
    parse_arrow!(g, IOBuffer(source))
end

function _load_arrow_into_graph!(g::RDFGraph, terms_tbl, trip_tbl)
    kinds = terms_tbl.kind
    lex   = terms_tbl.lex
    lang  = terms_tbl.lang
    dt    = terms_tbl.datatype
    n_terms = length(kinds)
    id_to_term = Vector{Identifier}(undef, n_terms)
    @inbounds for i in 1:n_terms
        id_to_term[i] = _decode_term(kinds[i], lex[i], lang[i], dt[i])
    end
    sids = trip_tbl.s; pids = trip_tbl.p; oids = trip_tbl.o
    n_trip = length(sids)
    s = g.store
    if s isa EncodedStore && s.count == 0
        # Bulk-load fast path: install dictionary directly, skip re-interning.
        for (i, t) in enumerate(id_to_term)
            push!(s.id_to_term, t)
            s.term_to_id[t] = UInt32(i)
        end
        sizehint!(s.insertion_order_enc, n_trip)
        @inbounds for i in 1:n_trip
            push!(s.insertion_order_enc, (sids[i], pids[i], oids[i]))
        end
        s.count = n_trip
        s.indexed = false
        s.secondary_indexed = false
        _ensure_indexed!(s)
    else
        @inbounds for i in 1:n_trip
            add!(g, Triple(id_to_term[sids[i]], id_to_term[pids[i]], id_to_term[oids[i]]))
        end
    end
    return g
end

"""
    parse_arrow(source) -> RDFGraph

Parse an Arrow IPC file into a fresh `RDFGraph` (uses the default `MemoryStore`).
"""
function parse_arrow(source)
    g = RDFGraph()
    parse_arrow!(g, source)
end

# ─── Hook into the high-level dispatch ───────────────────────────────

serialize(io::IO, g::RDFGraph, ::ArrowFormat) = serialize_arrow(io, g)
parse_rdf!(g::RDFGraph, source, ::ArrowFormat) = parse_arrow!(g, source)
