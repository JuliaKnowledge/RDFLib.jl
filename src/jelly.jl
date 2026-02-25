# Jelly RDF serialization format support
# https://w3id.org/jelly/1.1.1/specification/serialization
# Hand-rolled protobuf codec — no ProtoBuf.jl dependency

# ─── Jelly constants ──────────────────────────────────────────────
const JELLY_VERSION = UInt32(2)  # Jelly 1.1.x
const JELLY_DEFAULT_MAX_NAMES = UInt32(128)
const JELLY_DEFAULT_MAX_PREFIXES = UInt32(16)
const JELLY_DEFAULT_MAX_DATATYPES = UInt32(16)
const JELLY_DEFAULT_FRAME_SIZE = 256
const _XSD_STRING_JELLY = "http://www.w3.org/2001/XMLSchema#string"

# ─── Low-level protobuf primitives ───────────────────────────────
# Wire types: 0=varint, 2=length-delimited

@inline function _varint_size(x::UInt64)::Int
    x < 0x80 && return 1
    x < 0x4000 && return 2
    x < 0x200000 && return 3
    x < 0x10000000 && return 4
    return 5  # enough for our use
end

@inline function _pb_put_varint!(buf::Vector{UInt8}, pos::Int, x::UInt64)::Int
    while x >= 0x80
        pos += 1
        @inbounds buf[pos] = UInt8((x & 0x7f) | 0x80)
        x >>= 7
    end
    pos += 1
    @inbounds buf[pos] = UInt8(x)
    return pos
end

@inline _tag(field::Int, wt::Int) = UInt64((field << 3) | wt)

# Write tag + varint value (wire type 0) — skips if val == 0
@inline function _pb_put_uint32!(buf::Vector{UInt8}, pos::Int, field::Int, val::UInt32)::Int
    val == 0 && return pos
    pos = _pb_put_varint!(buf, pos, _tag(field, 0))
    return _pb_put_varint!(buf, pos, UInt64(val))
end

# Write tag + length + string bytes (wire type 2) — skips if empty
@inline function _pb_put_string!(buf::Vector{UInt8}, pos::Int, field::Int, s::AbstractString)::Int
    nb = sizeof(s)
    nb == 0 && return pos
    pos = _pb_put_varint!(buf, pos, _tag(field, 2))
    pos = _pb_put_varint!(buf, pos, UInt64(nb))
    unsafe_copyto!(pointer(buf, pos + 1), pointer(s), nb)
    return pos + nb
end

# Write tag + length + submessage bytes (wire type 2)
@inline function _pb_put_submsg!(buf::Vector{UInt8}, pos::Int, field::Int, data::Vector{UInt8}, dlen::Int)::Int
    pos = _pb_put_varint!(buf, pos, _tag(field, 2))
    pos = _pb_put_varint!(buf, pos, UInt64(dlen))
    if dlen > 0
        unsafe_copyto!(pointer(buf, pos + 1), pointer(data), dlen)
    end
    return pos + dlen
end

# ─── Protobuf reader ─────────────────────────────────────────────

@inline function _pb_get_varint(data::Vector{UInt8}, pos::Int)::Tuple{UInt64, Int}
    @inbounds b = data[pos]; pos += 1
    result = UInt64(b & 0x7f)
    (b & 0x80) == 0 && return (result, pos)
    shift = 7
    while true
        @inbounds b = data[pos]; pos += 1
        result |= UInt64(b & 0x7f) << shift
        (b & 0x80) == 0 && break
        shift += 7
    end
    return (result, pos)
end

@inline function _pb_get_tag(data::Vector{UInt8}, pos::Int)::Tuple{Int, Int, Int}
    val, pos = _pb_get_varint(data, pos)
    return (Int(val >> 3), Int(val & 0x07), pos)
end

@inline function _pb_get_string(data::Vector{UInt8}, pos::Int)::Tuple{String, Int}
    len, pos = _pb_get_varint(data, pos)
    n = Int(len)
    s = unsafe_string(pointer(data, pos), n)
    return (s, pos + n)
end

@inline function _pb_skip(data::Vector{UInt8}, pos::Int, wt::Int)::Int
    if wt == 0  # varint
        while @inbounds(data[pos]) & 0x80 != 0; pos += 1; end
        return pos + 1
    elseif wt == 2  # length-delimited
        len, pos = _pb_get_varint(data, pos)
        return pos + Int(len)
    elseif wt == 5; return pos + 4
    elseif wt == 1; return pos + 8
    end
    error("unknown wire type $wt")
end

# ─── Lookup tables (O(1) LRU) ────────────────────────────────────

mutable struct JellyLookup
    data::Dict{String, Int}
    reverse::Vector{String}   # index → key (pre-allocated array)
    prev::Vector{Int}         # index → prev index (0 = none)
    next::Vector{Int}         # index → next index (0 = none)
    head::Int
    tail::Int
    max_size::Int
    _next_index::Int
    _evicting::Bool
end

function JellyLookup(max_size::Int)
    JellyLookup(
        Dict{String,Int}(),
        Vector{String}(undef, max_size),
        zeros(Int, max_size),
        zeros(Int, max_size),
        0, 0, max_size, 1, false,
    )
end

@inline function _lookup_touch!(lu::JellyLookup, key::AbstractString)::Int
    idx = get(lu.data, key, 0)
    idx == 0 && return 0
    idx == lu.tail && return idx
    @inbounds p = lu.prev[idx]; @inbounds n = lu.next[idx]
    if p != 0; @inbounds lu.next[p] = n; else; lu.head = n; end
    if n != 0; @inbounds lu.prev[n] = p; end
    old_tail = lu.tail
    if old_tail != 0; @inbounds lu.next[old_tail] = idx; end
    @inbounds lu.prev[idx] = old_tail; @inbounds lu.next[idx] = 0
    lu.tail = idx
    if lu.head == 0; lu.head = idx; end
    return idx
end

function _lookup_insert!(lu::JellyLookup, key::AbstractString)::Int
    lu.max_size == 0 && error("lookup disabled")
    if lu._evicting
        evicted_idx = lu.head; @inbounds evicted_key = lu.reverse[evicted_idx]
        @inbounds new_head = lu.next[evicted_idx]; lu.head = new_head
        if new_head != 0; @inbounds lu.prev[new_head] = 0; else; lu.tail = 0; end
        @inbounds lu.next[evicted_idx] = 0; @inbounds lu.prev[evicted_idx] = 0
        delete!(lu.data, evicted_key)
        lu.data[key] = evicted_idx; @inbounds lu.reverse[evicted_idx] = key
        old_tail = lu.tail
        if old_tail != 0; @inbounds lu.next[old_tail] = evicted_idx; end
        @inbounds lu.prev[evicted_idx] = old_tail; lu.tail = evicted_idx
        if lu.head == 0; lu.head = evicted_idx; end
        return evicted_idx
    else
        idx = lu._next_index
        lu.data[key] = idx; @inbounds lu.reverse[idx] = key
        old_tail = lu.tail
        if old_tail != 0; @inbounds lu.next[old_tail] = idx; end
        @inbounds lu.prev[idx] = old_tail; lu.tail = idx
        if lu.head == 0; lu.head = idx; end
        lu._next_index += 1
        lu._evicting = (length(lu.data) >= lu.max_size)
        return idx
    end
end

# ─── Lookup Encoder/Decoder ──────────────────────────────────────

mutable struct JellyLookupEncoder
    lookup::JellyLookup
    last_assigned_index::Int
    last_reused_index::Int
end
JellyLookupEncoder(n::Int) = JellyLookupEncoder(JellyLookup(n), 0, 0)

@inline function encode_entry_index!(enc::JellyLookupEncoder, key::AbstractString)::Union{Int, Nothing}
    idx = _lookup_touch!(enc.lookup, key)
    if idx != 0
        return nothing  # already in lookup, just touched
    end
    prev = enc.last_assigned_index
    idx = _lookup_insert!(enc.lookup, key)
    enc.last_assigned_index = idx
    return idx == prev + 1 ? 0 : idx
end

# Combined: encode_entry + encode_term in one pass (avoids double hash)
@inline function encode_entry_and_term!(enc::JellyLookupEncoder, key::AbstractString)::Tuple{Union{Int,Nothing}, Int}
    idx = _lookup_touch!(enc.lookup, key)
    entry_result = nothing
    if idx == 0
        prev_a = enc.last_assigned_index
        idx = _lookup_insert!(enc.lookup, key)
        enc.last_assigned_index = idx
        entry_result = idx == prev_a + 1 ? 0 : idx
    end
    enc.last_reused_index = idx
    return (entry_result, idx)
end

@inline function encode_term_index!(enc::JellyLookupEncoder, value::AbstractString)::Int
    idx = _lookup_touch!(enc.lookup, value)
    if idx == 0
        idx = enc.lookup.data[value]
    end
    enc.last_reused_index = idx
    return idx
end

@inline function encode_prefix_term_index!(enc::JellyLookupEncoder, value::AbstractString)::Int
    enc.lookup.max_size == 0 && return 0
    prev = enc.last_reused_index
    isempty(value) && prev == 0 && return 0
    idx = encode_term_index!(enc, value)
    prev == 0 && return idx
    return idx == prev ? 0 : idx
end

@inline function encode_name_term_index!(enc::JellyLookupEncoder, value::AbstractString)::Int
    prev = enc.last_reused_index
    idx = encode_term_index!(enc, value)
    return idx == prev + 1 ? 0 : idx
end

@inline function encode_datatype_term_index!(enc::JellyLookupEncoder, value::AbstractString)::Int
    enc.lookup.max_size == 0 && return 0
    return encode_term_index!(enc, value)
end


mutable struct JellyLookupDecoder
    data::Vector{Union{String, Nothing}}
    last_assigned_index::Int
    last_reused_index::Int
end

JellyLookupDecoder(n::Int) = JellyLookupDecoder(Vector{Union{String,Nothing}}(nothing, n), 0, 0)

@inline function decode_assign_entry!(d::JellyLookupDecoder, index::Int, value::String)
    actual = index == 0 ? d.last_assigned_index + 1 : index
    @inbounds d.data[actual] = value; d.last_assigned_index = actual
end

@inline function decode_at!(d::JellyLookupDecoder, index::Int)::String
    d.last_reused_index = index; @inbounds val = d.data[index]
    isnothing(val) && error("invalid lookup index $index"); return val
end

@inline function decode_prefix_term_index!(d::JellyLookupDecoder, index::Int)::String
    actual = index == 0 ? d.last_reused_index : index
    actual == 0 && return ""; return decode_at!(d, actual)
end

@inline function decode_name_term_index!(d::JellyLookupDecoder, index::Int)::String
    actual = index == 0 ? d.last_reused_index + 1 : index
    return decode_at!(d, actual)
end

@inline function decode_datatype_term_index!(d::JellyLookupDecoder, index::Int)::String
    return decode_at!(d, index)
end

# ─── IRI splitting ────────────────────────────────────────────────

@inline function _jelly_split_iri(iri::String)
    # Single-pass byte scan from end for '#' or '/'
    bytes = codeunits(iri)
    n = length(bytes)
    i = n
    while i >= 1
        @inbounds b = bytes[i]
        if b == UInt8('#') || b == UInt8('/')
            return (SubString(iri, 1, i), SubString(iri, i+1, n))
        end
        i -= 1
    end
    return (SubString(iri, 1, 0), SubString(iri, 1, n))
end

# ─── Jelly Encoder ────────────────────────────────────────────────
# Strategy: each row is built into a scratch buffer, then written to the main
# output with a known length. This avoids backpatching and two-pass encoding.

mutable struct JellyEncoder
    names::JellyLookupEncoder
    prefixes::JellyLookupEncoder
    datatypes::JellyLookupEncoder
    repeated_subject::Union{Identifier, Nothing}
    repeated_predicate::Union{Identifier, Nothing}
    repeated_object::Union{Identifier, Nothing}
    max_names::UInt32
    max_prefixes::UInt32
    max_datatypes::UInt32
    # Output buffer: complete stream bytes (frame-wrapped rows)
    out::Vector{UInt8}
    opos::Int
    # Scratch buffers for building submessages
    row_scratch::Vector{UInt8}   # for building a single row
    term_scratch::Vector{UInt8}  # for building a term (IRI/literal)
end

function JellyEncoder(;
    max_names::Integer=JELLY_DEFAULT_MAX_NAMES,
    max_prefixes::Integer=JELLY_DEFAULT_MAX_PREFIXES,
    max_datatypes::Integer=JELLY_DEFAULT_MAX_DATATYPES,
    bufsize::Int=1048576,
)
    JellyEncoder(
        JellyLookupEncoder(Int(max_names)),
        JellyLookupEncoder(Int(max_prefixes)),
        JellyLookupEncoder(Int(max_datatypes)),
        nothing, nothing, nothing,
        UInt32(max_names), UInt32(max_prefixes), UInt32(max_datatypes),
        Vector{UInt8}(undef, bufsize), 0,
        Vector{UInt8}(undef, 4096),
        Vector{UInt8}(undef, 512),
    )
end

@inline function _ensure!(buf::Vector{UInt8}, pos::Int, needed::Int)
    if pos + needed > length(buf)
        resize!(buf, max(length(buf) * 2, pos + needed + 1024))
    end
end

# Emit a row to the main output buffer, wrapped as frame field 1 (StreamRow)
@inline function _emit_row!(enc::JellyEncoder, row_data::Vector{UInt8}, rlen::Int)
    _ensure!(enc.out, enc.opos, rlen + 12)
    # Frame field 1 = StreamRow (tag 0x0a = field 1, wire type 2)
    enc.opos = _pb_put_varint!(enc.out, enc.opos, _tag(1, 2))
    enc.opos = _pb_put_varint!(enc.out, enc.opos, UInt64(rlen))
    unsafe_copyto!(pointer(enc.out, enc.opos + 1), pointer(row_data), rlen)
    enc.opos += rlen
end

# ─── Encode IRI to scratch buffer ─────────────────────────────────
# Returns (prefix_id, name_id) — also emits any needed lookup entry rows

function _encode_iri!(enc::JellyEncoder, iri_str::AbstractString)::Tuple{UInt32, UInt32}
    prefix, name = _jelly_split_iri(iri_str)

    pid = UInt32(0)
    if enc.prefixes.lookup.max_size > 0
        prev_p = enc.prefixes.last_reused_index
        pe, p_idx = encode_entry_and_term!(enc.prefixes, prefix)
        if !isnothing(pe)
            _emit_entry_row!(enc, 10, UInt32(pe), prefix)
        end
        # Compute prefix term delta (mirrors encode_prefix_term_index! logic)
        if !(isempty(prefix) && prev_p == 0)
            pid = UInt32(prev_p == 0 ? p_idx : (p_idx == prev_p ? 0 : p_idx))
        end
    else
        name = iri_str
    end

    prev_n = enc.names.last_reused_index
    ne, n_idx = encode_entry_and_term!(enc.names, name)
    if !isnothing(ne)
        _emit_entry_row!(enc, 9, UInt32(ne), name)
    end
    nid = UInt32(n_idx == prev_n + 1 ? 0 : n_idx)

    return (pid, nid)
end

# Emit a lookup entry row (prefix/name/datatype) — these are { id: uint32, value: string }
function _emit_entry_row!(enc::JellyEncoder, row_field::Int, id::UInt32, value::AbstractString)
    s = enc.row_scratch
    _ensure!(s, 0, sizeof(value) + 30)
    # Build entry message: { 1: id, 2: value }
    p = 0
    p = _pb_put_uint32!(s, p, 1, id)
    p = _pb_put_string!(s, p, 2, value)
    # Wrap as StreamRow { <row_field>: entry }
    t = enc.term_scratch
    _ensure!(t, 0, p + 12)
    tp = 0
    tp = _pb_put_submsg!(t, tp, row_field, s, p)
    _emit_row!(enc, t, tp)
end

# Write IRI submessage (prefix_id, name_id) into buf at pos
@inline function _put_iri!(buf::Vector{UInt8}, pos::Int, field::Int, pid::UInt32, nid::UInt32)::Int
    # Build RdfIri in-place: { 1: prefix_id, 2: name_id }
    # Compute inner size first
    inner_size = 0
    if pid != 0; inner_size += 1 + _varint_size(UInt64(pid)); end
    if nid != 0; inner_size += 1 + _varint_size(UInt64(nid)); end
    if inner_size == 0 && pid == 0 && nid == 0
        # Empty IRI — still need to emit the submessage with zero length
        inner_size = 0
    end
    pos = _pb_put_varint!(buf, pos, _tag(field, 2))
    pos = _pb_put_varint!(buf, pos, UInt64(inner_size))
    pos = _pb_put_uint32!(buf, pos, 1, pid)
    pos = _pb_put_uint32!(buf, pos, 2, nid)
    return pos
end

# Write literal submessage into buf at pos — datatype_id must be pre-resolved
@inline function _put_literal!(buf::Vector{UInt8}, pos::Int, field::Int, lit::Literal, dtid::UInt32)::Int
    # Compute inner size
    lex_len = sizeof(lit.lexical)
    inner_size = 0
    if lex_len > 0; inner_size += 1 + _varint_size(UInt64(lex_len)) + lex_len; end
    has_lang = lit.language !== nothing && lit.language != ""
    if has_lang
        lang_len = sizeof(lit.language)
        inner_size += 1 + _varint_size(UInt64(lang_len)) + lang_len
    elseif dtid != 0
        inner_size += 1 + _varint_size(UInt64(dtid))
    end
    _ensure!(buf, pos, inner_size + 12)
    pos = _pb_put_varint!(buf, pos, _tag(field, 2))
    pos = _pb_put_varint!(buf, pos, UInt64(inner_size))
    pos = _pb_put_string!(buf, pos, 1, lit.lexical)
    if has_lang
        pos = _pb_put_string!(buf, pos, 2, lit.language)
    elseif dtid != 0
        pos = _pb_put_uint32!(buf, pos, 3, dtid)
    end
    return pos
end

# ─── Triple encoding ─────────────────────────────────────────────

function _encode_triple_fast!(enc::JellyEncoder, t::Triple)
    # Phase 1: Emit any needed lookup entries (prefix, name, datatype)
    # and compute IRI indices for each changed term

    s_pid = UInt32(0); s_nid = UInt32(0); s_changed = t.subject !== enc.repeated_subject
    if s_changed
        enc.repeated_subject = t.subject
        if t.subject isa URIRef
            s_pid, s_nid = _encode_iri!(enc, t.subject.value)
        end
    end

    p_pid = UInt32(0); p_nid = UInt32(0); p_changed = t.predicate !== enc.repeated_predicate
    if p_changed
        enc.repeated_predicate = t.predicate
        if t.predicate isa URIRef
            p_pid, p_nid = _encode_iri!(enc, t.predicate.value)
        end
    end

    o_pid = UInt32(0); o_nid = UInt32(0); o_dtid = UInt32(0)
    o_changed = t.object !== enc.repeated_object
    if o_changed
        enc.repeated_object = t.object
        if t.object isa URIRef
            o_pid, o_nid = _encode_iri!(enc, t.object.value)
        elseif t.object isa Literal
            lit = t.object
            if (lit.language === nothing || lit.language == "") && lit.datatype !== nothing
                dt_str = lit.datatype.value
                if dt_str != _XSD_STRING_JELLY
                    de, dt_idx = encode_entry_and_term!(enc.datatypes, dt_str)
                    if !isnothing(de)
                        _emit_entry_row!(enc, 11, UInt32(de), dt_str)  # field 11 = datatype
                    end
                    o_dtid = UInt32(dt_idx)
                end
            end
        end
    end

    # Phase 2: Build the RdfTriple message into row_scratch
    rs = enc.row_scratch
    _ensure!(rs, 0, 256)
    rp = 0

    if s_changed
        term = t.subject
        if term isa URIRef
            rp = _put_iri!(rs, rp, 1, s_pid, s_nid)
        elseif term isa BNode
            rp = _pb_put_string!(rs, rp, 2, term.id)
        elseif term isa Literal
            rp = _put_literal!(rs, rp, 3, term, UInt32(0))
        end
    end

    if p_changed
        term = t.predicate
        if term isa URIRef
            rp = _put_iri!(rs, rp, 5, p_pid, p_nid)
        elseif term isa BNode
            rp = _pb_put_string!(rs, rp, 6, term.id)
        end
    end

    if o_changed
        term = t.object
        if term isa URIRef
            rp = _put_iri!(rs, rp, 9, o_pid, o_nid)
        elseif term isa BNode
            rp = _pb_put_string!(rs, rp, 10, term.id)
        elseif term isa Literal
            rp = _put_literal!(rs, rp, 11, term, o_dtid)
        end
    end

    # Phase 3: Wrap as StreamRow { triple (field 2) = <triple_bytes> }
    ts = enc.term_scratch
    _ensure!(ts, 0, rp + 12)
    tp = 0
    tp = _pb_put_submsg!(ts, tp, 2, rs, rp)
    _emit_row!(enc, ts, tp)
end

# ─── Options / Namespace rows ─────────────────────────────────────

function _emit_options!(enc::JellyEncoder; stream_name::String="")
    s = enc.row_scratch
    _ensure!(s, 0, 100 + sizeof(stream_name))
    p = 0
    p = _pb_put_string!(s, p, 1, stream_name)
    p = _pb_put_uint32!(s, p, 2, UInt32(1))  # TRIPLES
    p = _pb_put_uint32!(s, p, 9, enc.max_names)
    p = _pb_put_uint32!(s, p, 10, enc.max_prefixes)
    p = _pb_put_uint32!(s, p, 11, enc.max_datatypes)
    p = _pb_put_uint32!(s, p, 14, UInt32(1))  # FLAT_TRIPLES
    p = _pb_put_uint32!(s, p, 15, UInt32(JELLY_VERSION))
    # Wrap as StreamRow { options (field 1) = ... }
    t = enc.term_scratch
    _ensure!(t, 0, p + 12)
    tp = 0
    tp = _pb_put_submsg!(t, tp, 1, s, p)
    _emit_row!(enc, t, tp)
end

function _emit_namespace!(enc::JellyEncoder, prefix::String, pid::UInt32, nid::UInt32)
    s = enc.row_scratch
    _ensure!(s, 0, 50 + sizeof(prefix))
    p = 0
    p = _pb_put_string!(s, p, 1, prefix)  # name
    p = _put_iri!(s, p, 2, pid, nid)       # value (RdfIri)
    t = enc.term_scratch
    _ensure!(t, 0, p + 12)
    tp = 0
    tp = _pb_put_submsg!(t, tp, 6, s, p)  # field 6 = namespace
    _emit_row!(enc, t, tp)
end

# ─── Top-level serialize ─────────────────────────────────────────

"""
    serialize_jelly(g::RDFGraph; kwargs...) -> Vector{UInt8}

Serialize an RDF graph to Jelly binary format (protobuf).
Returns a byte vector containing a length-delimited RdfStreamFrame.
"""
function serialize_jelly(g::RDFGraph;
    frame_size::Int=JELLY_DEFAULT_FRAME_SIZE,
    max_names::Integer=JELLY_DEFAULT_MAX_NAMES,
    max_prefixes::Integer=JELLY_DEFAULT_MAX_PREFIXES,
    max_datatypes::Integer=JELLY_DEFAULT_MAX_DATATYPES,
    stream_name::String="",
)::Vector{UInt8}
    n_triples = length(g)
    enc = JellyEncoder(; max_names, max_prefixes, max_datatypes,
                        bufsize=max(n_triples * 80, 8192))

    # Write options row
    _emit_options!(enc; stream_name)

    # Namespace declarations
    for (prefix, uri_str) in namespaces(g)
        pid, nid = _encode_iri!(enc, uri_str)
        _emit_namespace!(enc, prefix, pid, nid)
    end

    # Encode all triples — use direct store access for MemoryStore to avoid Channel overhead
    if g.store isa MemoryStore
        for t in g.store.insertion_order
            _encode_triple_fast!(enc, t)
        end
    else
        for t in triples(g)
            _encode_triple_fast!(enc, t)
        end
    end

    # enc.out[1:enc.opos] now contains the RdfStreamFrame message body
    # (all rows wrapped as field 1). Add length-delimited frame prefix.
    frame_len = enc.opos
    result = Vector{UInt8}(undef, frame_len + 10)
    rp = _pb_put_varint!(result, 0, UInt64(frame_len))
    unsafe_copyto!(pointer(result, rp + 1), pointer(enc.out), frame_len)
    resize!(result, rp + frame_len)
    return result
end

# ─── Jelly Decoder ────────────────────────────────────────────────

mutable struct JellyDecoder
    names::Union{JellyLookupDecoder, Nothing}
    prefixes::Union{JellyLookupDecoder, Nothing}
    datatypes::Union{JellyLookupDecoder, Nothing}
    repeated_subject::Union{Identifier, Nothing}
    repeated_predicate::Union{Identifier, Nothing}
    repeated_object::Union{Identifier, Nothing}
end

JellyDecoder() = JellyDecoder(nothing, nothing, nothing, nothing, nothing, nothing)

@inline function _dec_iri(dec::JellyDecoder, data::Vector{UInt8}, pos::Int, limit::Int)::Tuple{URIRef, Int}
    prefix_id = 0; name_id = 0
    while pos < limit
        field, wt, pos = _pb_get_tag(data, pos)
        if field == 1; v, pos = _pb_get_varint(data, pos); prefix_id = Int(v)
        elseif field == 2; v, pos = _pb_get_varint(data, pos); name_id = Int(v)
        else; pos = _pb_skip(data, pos, wt)
        end
    end
    prefix = decode_prefix_term_index!(dec.prefixes, prefix_id)
    name = decode_name_term_index!(dec.names, name_id)
    iri = isempty(prefix) ? name : prefix * name
    return (URIRef(iri), limit)
end

@inline function _dec_literal(dec::JellyDecoder, data::Vector{UInt8}, pos::Int, limit::Int)::Tuple{Literal, Int}
    lex = ""; langtag = nothing; dt_id = 0
    while pos < limit
        field, wt, pos = _pb_get_tag(data, pos)
        if field == 1; lex, pos = _pb_get_string(data, pos)
        elseif field == 2; langtag, pos = _pb_get_string(data, pos)
        elseif field == 3; v, pos = _pb_get_varint(data, pos); dt_id = Int(v)
        else; pos = _pb_skip(data, pos, wt)
        end
    end
    if langtag !== nothing
        return (Literal(lex, lang=langtag), limit)
    elseif dt_id > 0
        dt_str = decode_datatype_term_index!(dec.datatypes, dt_id)
        return (Literal(lex, datatype=URIRef(dt_str)), limit)
    end
    return (Literal(lex), limit)
end

function _dec_triple!(dec::JellyDecoder, g::RDFGraph, data::Vector{UInt8}, pos::Int, limit::Int)::Int
    s = dec.repeated_subject
    p = dec.repeated_predicate
    o = dec.repeated_object

    while pos < limit
        field, wt, pos = _pb_get_tag(data, pos)
        if wt == 2
            len, pos = _pb_get_varint(data, pos)
            fend = pos + Int(len)
            if field == 1;     s, _ = _dec_iri(dec, data, pos, fend)
            elseif field == 2; s = BNode(unsafe_string(pointer(data, pos), Int(len)))
            elseif field == 3; s, _ = _dec_literal(dec, data, pos, fend)
            elseif field == 5; p, _ = _dec_iri(dec, data, pos, fend)
            elseif field == 6; p = BNode(unsafe_string(pointer(data, pos), Int(len)))
            elseif field == 7; p, _ = _dec_literal(dec, data, pos, fend)
            elseif field == 9; o, _ = _dec_iri(dec, data, pos, fend)
            elseif field == 10; o = BNode(unsafe_string(pointer(data, pos), Int(len)))
            elseif field == 11; o, _ = _dec_literal(dec, data, pos, fend)
            end
            pos = fend
        elseif wt == 0
            _, pos = _pb_get_varint(data, pos)
        else
            pos = _pb_skip(data, pos, wt)
        end
    end

    dec.repeated_subject = s
    dec.repeated_predicate = p
    dec.repeated_object = o
    (isnothing(s) || isnothing(p) || isnothing(o)) && return limit
    add!(g, Triple(s::Node, p::URIRef, o))
    return limit
end

# Fast path: collect triples into vector for bulk insert
function _dec_triple_vec!(dec::JellyDecoder, triples::Vector{Triple}, data::Vector{UInt8}, pos::Int, limit::Int)::Int
    s = dec.repeated_subject
    p = dec.repeated_predicate
    o = dec.repeated_object

    while pos < limit
        field, wt, pos = _pb_get_tag(data, pos)
        if wt == 2
            len, pos = _pb_get_varint(data, pos)
            fend = pos + Int(len)
            if field == 1;     s, _ = _dec_iri(dec, data, pos, fend)
            elseif field == 2; s = BNode(unsafe_string(pointer(data, pos), Int(len)))
            elseif field == 3; s, _ = _dec_literal(dec, data, pos, fend)
            elseif field == 5; p, _ = _dec_iri(dec, data, pos, fend)
            elseif field == 6; p = BNode(unsafe_string(pointer(data, pos), Int(len)))
            elseif field == 7; p, _ = _dec_literal(dec, data, pos, fend)
            elseif field == 9; o, _ = _dec_iri(dec, data, pos, fend)
            elseif field == 10; o = BNode(unsafe_string(pointer(data, pos), Int(len)))
            elseif field == 11; o, _ = _dec_literal(dec, data, pos, fend)
            end
            pos = fend
        elseif wt == 0
            _, pos = _pb_get_varint(data, pos)
        else
            pos = _pb_skip(data, pos, wt)
        end
    end

    dec.repeated_subject = s
    dec.repeated_predicate = p
    dec.repeated_object = o
    (isnothing(s) || isnothing(p) || isnothing(o)) && return limit
    push!(triples, Triple(s::Node, p::URIRef, o))
    return limit
end

function _dec_entry(data::Vector{UInt8}, pos::Int, limit::Int)::Tuple{Int, String}
    id = 0; value = ""
    while pos < limit
        field, wt, pos = _pb_get_tag(data, pos)
        if field == 1 && wt == 0; v, pos = _pb_get_varint(data, pos); id = Int(v)
        elseif field == 2 && wt == 2; value, pos = _pb_get_string(data, pos)
        else; pos = _pb_skip(data, pos, wt)
        end
    end
    return (id, value)
end

function _dec_options!(dec::JellyDecoder, data::Vector{UInt8}, pos::Int, limit::Int)::Int
    max_names = 128; max_prefixes = 16; max_datatypes = 16
    while pos < limit
        field, wt, pos = _pb_get_tag(data, pos)
        if field == 9 && wt == 0; v, pos = _pb_get_varint(data, pos); max_names = Int(v)
        elseif field == 10 && wt == 0; v, pos = _pb_get_varint(data, pos); max_prefixes = Int(v)
        elseif field == 11 && wt == 0; v, pos = _pb_get_varint(data, pos); max_datatypes = Int(v)
        else; pos = _pb_skip(data, pos, wt)
        end
    end
    dec.names = JellyLookupDecoder(max_names)
    dec.prefixes = JellyLookupDecoder(max_prefixes)
    dec.datatypes = JellyLookupDecoder(max_datatypes)
    return limit
end

function _dec_namespace!(dec::JellyDecoder, g::RDFGraph, data::Vector{UInt8}, pos::Int, limit::Int)::Int
    name = ""; prefix_id = 0; name_id = 0
    while pos < limit
        field, wt, pos = _pb_get_tag(data, pos)
        if field == 1 && wt == 2; name, pos = _pb_get_string(data, pos)
        elseif field == 2 && wt == 2
            len, pos = _pb_get_varint(data, pos)
            iri_end = pos + Int(len)
            while pos < iri_end
                f2, w2, pos = _pb_get_tag(data, pos)
                if f2 == 1; v, pos = _pb_get_varint(data, pos); prefix_id = Int(v)
                elseif f2 == 2; v, pos = _pb_get_varint(data, pos); name_id = Int(v)
                else; pos = _pb_skip(data, pos, w2)
                end
            end
        else; pos = _pb_skip(data, pos, wt)
        end
    end
    if !isnothing(dec.prefixes) && !isnothing(dec.names)
        prefix_str = decode_prefix_term_index!(dec.prefixes, prefix_id)
        name_str = decode_name_term_index!(dec.names, name_id)
        bind!(g.namespace_manager, name, prefix_str * name_str)
    end
    return limit
end

function _dec_stream_row!(dec::JellyDecoder, g::RDFGraph, data::Vector{UInt8}, pos::Int, limit::Int)::Int
    pos >= limit && return limit
    field, wt, pos = _pb_get_tag(data, pos)
    if wt == 2
        len, pos = _pb_get_varint(data, pos)
        fend = pos + Int(len)
        if field == 1;     _dec_options!(dec, data, pos, fend)
        elseif field == 2; _dec_triple!(dec, g, data, pos, fend)
        elseif field == 6; _dec_namespace!(dec, g, data, pos, fend)
        elseif field == 9
            id, value = _dec_entry(data, pos, fend)
            !isnothing(dec.names) && decode_assign_entry!(dec.names, id, value)
        elseif field == 10
            id, value = _dec_entry(data, pos, fend)
            !isnothing(dec.prefixes) && decode_assign_entry!(dec.prefixes, id, value)
        elseif field == 11
            id, value = _dec_entry(data, pos, fend)
            !isnothing(dec.datatypes) && decode_assign_entry!(dec.datatypes, id, value)
        end
        return fend
    else
        return _pb_skip(data, pos, wt)
    end
end

# Vector-collecting variants for bulk parse
function _dec_stream_row_vec!(dec::JellyDecoder, g::RDFGraph, triples::Vector{Triple}, data::Vector{UInt8}, pos::Int, limit::Int)::Int
    pos >= limit && return limit
    field, wt, pos = _pb_get_tag(data, pos)
    if wt == 2
        len, pos = _pb_get_varint(data, pos)
        fend = pos + Int(len)
        if field == 1;     _dec_options!(dec, data, pos, fend)
        elseif field == 2; _dec_triple_vec!(dec, triples, data, pos, fend)
        elseif field == 6; _dec_namespace!(dec, g, data, pos, fend)
        elseif field == 9
            id, value = _dec_entry(data, pos, fend)
            !isnothing(dec.names) && decode_assign_entry!(dec.names, id, value)
        elseif field == 10
            id, value = _dec_entry(data, pos, fend)
            !isnothing(dec.prefixes) && decode_assign_entry!(dec.prefixes, id, value)
        elseif field == 11
            id, value = _dec_entry(data, pos, fend)
            !isnothing(dec.datatypes) && decode_assign_entry!(dec.datatypes, id, value)
        end
        return fend
    else
        return _pb_skip(data, pos, wt)
    end
end

function _dec_frame!(dec::JellyDecoder, g::RDFGraph, data::Vector{UInt8}, pos::Int, limit::Int)::Int
    while pos < limit
        field, wt, pos = _pb_get_tag(data, pos)
        if field == 1 && wt == 2
            row_len, pos = _pb_get_varint(data, pos)
            row_end = pos + Int(row_len)
            _dec_stream_row!(dec, g, data, pos, row_end)
            pos = row_end
        else
            pos = _pb_skip(data, pos, wt)
        end
    end
    return limit
end

function _dec_frame!(dec::JellyDecoder, g::RDFGraph, triples::Vector{Triple}, data::Vector{UInt8}, pos::Int, limit::Int)::Int
    while pos < limit
        field, wt, pos = _pb_get_tag(data, pos)
        if field == 1 && wt == 2
            row_len, pos = _pb_get_varint(data, pos)
            row_end = pos + Int(row_len)
            _dec_stream_row_vec!(dec, g, triples, data, pos, row_end)
            pos = row_end
        else
            pos = _pb_skip(data, pos, wt)
        end
    end
    return limit
end

# ─── Public API ───────────────────────────────────────────────────

"""
    parse_jelly(data::Vector{UInt8}) -> RDFGraph
    parse_jelly(io::IO) -> RDFGraph

Parse Jelly binary format (length-delimited protobuf frames) into an RDF graph.
"""
function parse_jelly(data::Vector{UInt8})::RDFGraph
    g = RDFGraph()
    dec = JellyDecoder()
    triples_vec = Triple[]
    sizehint!(triples_vec, length(data) ÷ 20)
    pos = 1
    limit = length(data) + 1
    while pos < limit
        frame_len, pos = _pb_get_varint(data, pos)
        frame_end = pos + Int(frame_len)
        _dec_frame!(dec, g, triples_vec, data, pos, frame_end)
        pos = frame_end
    end
    # Bulk insert all triples at once (avoids per-triple index overhead)
    if !isempty(triples_vec)
        store = g.store
        if isempty(store.spo)
            add_bulk!(store, triples_vec)
        else
            for t in triples_vec; add!(g, t); end
        end
    end
    return g
end

function parse_jelly(io::IO)::RDFGraph
    parse_jelly(read(io))
end

"""
    parse_jelly!(g::RDFGraph, data::Vector{UInt8}) -> RDFGraph

Parse Jelly binary data and add triples to existing graph.
"""
function parse_jelly!(g::RDFGraph, data::Vector{UInt8})::RDFGraph
    dec = JellyDecoder()
    store = g.store
    # Use bulk path for MemoryStore (avoids per-triple Dict overhead)
    if store isa MemoryStore && isempty(store.spo)
        triples_vec = Triple[]
        sizehint!(triples_vec, length(data) ÷ 20)
        pos = 1
        limit = length(data) + 1
        while pos < limit
            frame_len, pos = _pb_get_varint(data, pos)
            frame_end = pos + Int(frame_len)
            _dec_frame!(dec, g, triples_vec, data, pos, frame_end)
            pos = frame_end
        end
        if !isempty(triples_vec)
            add_bulk!(store, triples_vec)
        end
    else
        pos = 1
        limit = length(data) + 1
        while pos < limit
            frame_len, pos = _pb_get_varint(data, pos)
            frame_end = pos + Int(frame_len)
            _dec_frame!(dec, g, data, pos, frame_end)
            pos = frame_end
        end
    end
    return g
end

# ─── File I/O convenience ────────────────────────────────────────

"""
    serialize_jelly_to_file(g::RDFGraph, filename::AbstractString; kwargs...)

Serialize graph to Jelly format and write to file.
"""
function serialize_jelly_to_file(g::RDFGraph, filename::AbstractString; kwargs...)
    data = serialize_jelly(g; kwargs...)
    write(filename, data)
end

"""
    parse_jelly_file(filename::AbstractString) -> RDFGraph

Parse a Jelly file into an RDF graph.
"""
function parse_jelly_file(filename::AbstractString)::RDFGraph
    parse_jelly(read(filename))
end
