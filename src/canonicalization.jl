# ─── RDF Dataset Canonicalization (RDFC-1.0) ────────────────────────
#
# Implementation of the W3C RDF Dataset Canonicalization algorithm
# (RDFC-1.0, https://www.w3.org/TR/rdf-canon/).
#
# The public entry points are:
#   rdf_canonicalize(g::RDFGraph)::String   — canonical N-Triples
#   rdf_canonicalize(ds::Dataset)::String   — canonical N-Quads
#   canonical_bnode_labels(...)             — the issued c14nN labels
#
# The algorithm assigns canonical blank-node identifiers (`c14n0`, `c14n1`, …)
# via hash-based partitioning (first-degree hashes + N-degree hashing with a
# canonical issuer), then serializes every quad in canonical N-Quads/N-Triples
# form, sorts the lines by Unicode code point (== UTF-8 byte order), and joins
# them with newlines.

using SHA

# ─── Canonical serialization of terms ───────────────────────────────
#
# Per the RDFC-1.0 "Serialization" step, each quad is written in canonical
# N-Quads form. Literals use the canonical N-Triples escaping; an xsd:string
# datatype is omitted (already normalized away by our Literal type); language
# tags are lower-cased (already done by our Literal type).

# Characters that must be escaped inside a canonical IRIREF: control chars
# (<= 0x20), 0x7F, and the delimiters the grammar forbids. Written as \uXXXX.
@inline _c14n_iri_needs_escape(c::Char) =
    UInt32(c) <= 0x20 || c == '<' || c == '>' || c == '"' ||
    c == '{' || c == '}' || c == '|' || c == '^' || c == '`' || c == '\\' ||
    UInt32(c) == 0x7F

function _c14n_escape_iri(s::AbstractString)
    any(_c14n_iri_needs_escape, s) || return String(s)
    buf = IOBuffer(sizehint = sizeof(s) + 16)
    for c in s
        if _c14n_iri_needs_escape(c)
            cp = UInt32(c)
            if cp > 0xFFFF
                print(buf, "\\U", uppercase(string(cp, base = 16, pad = 8)))
            else
                print(buf, "\\u", uppercase(string(cp, base = 16, pad = 4)))
            end
        else
            write(buf, c)
        end
    end
    String(take!(buf))
end

# Whether a code point in a string literal must be escaped (beyond the short
# escapes handled explicitly). Canonical N-Triples escapes 0x00–0x1F, 0x7F,
# and the Unicode noncharacters U+FFFE / U+FFFF (observed in the W3C suite).
@inline function _c14n_str_codepoint_escape(cp::UInt32)
    cp < 0x20 || cp == 0x7F || cp == 0xFFFE || cp == 0xFFFF
end

function _c14n_escape_string(s::AbstractString)
    needs = false
    for c in s
        cp = UInt32(c)
        if c == '\\' || c == '"' || _c14n_str_codepoint_escape(cp)
            needs = true
            break
        end
    end
    needs || return String(s)
    buf = IOBuffer(sizehint = sizeof(s) + 16)
    for c in s
        cp = UInt32(c)
        if c == '\\'
            write(buf, "\\\\")
        elseif c == '"'
            write(buf, "\\\"")
        elseif c == '\n'
            write(buf, "\\n")
        elseif c == '\r'
            write(buf, "\\r")
        elseif c == '\t'
            write(buf, "\\t")
        elseif c == '\b'
            write(buf, "\\b")
        elseif c == '\f'
            write(buf, "\\f")
        elseif _c14n_str_codepoint_escape(cp)
            if cp > 0xFFFF
                print(buf, "\\U", uppercase(string(cp, base = 16, pad = 8)))
            else
                print(buf, "\\u", uppercase(string(cp, base = 16, pad = 4)))
            end
        else
            write(buf, c)
        end
    end
    String(take!(buf))
end

# Serialize a term to canonical form. `bnode_label` maps a BNode id -> the
# label string to emit for it (e.g. "c14n0", or "a"/"z" during hashing).
_c14n_term(u::URIRef, ::Function) = string("<", _c14n_escape_iri(u.value), ">")
_c14n_term(b::BNode, bnode_label::Function) = string("_:", bnode_label(b.id))

function _c14n_term(l::Literal, ::Function)
    s = string("\"", _c14n_escape_string(l.lexical), "\"")
    if !isnothing(l.language)
        s *= "@" * l.language
        if !isnothing(l.direction)
            s *= "--" * l.direction
        end
    elseif !isnothing(l.datatype)
        s *= "^^<" * _c14n_escape_iri(l.datatype.value) * ">"
    end
    s
end

# RDF 1.2 triple terms: canonical N-Triples writes them as `<<( s p o )>>`.
function _c14n_term(tt::TripleTerm, bnode_label::Function)
    string("<<( ", _c14n_term(tt.subject, bnode_label), " ",
           _c14n_term(tt.predicate, bnode_label), " ",
           _c14n_term(tt.object, bnode_label), " )>>")
end

# Serialize a single quad (graph name may be nothing for the default graph).
function _c14n_quad(s, p, o, g, bnode_label::Function)
    buf = IOBuffer()
    write(buf, _c14n_term(s, bnode_label)); write(buf, " ")
    write(buf, _c14n_term(p, bnode_label)); write(buf, " ")
    write(buf, _c14n_term(o, bnode_label))
    if g !== nothing
        write(buf, " ")
        write(buf, _c14n_term(g, bnode_label))
    end
    write(buf, " .")
    String(take!(buf))
end

# ─── Quad extraction ────────────────────────────────────────────────

struct _C14NQuad
    s::Node
    p::URIRef
    o::Identifier
    g::Union{URIRef,BNode,Nothing}
end

function _collect_quads(g::RDFGraph)
    out = _C14NQuad[]
    for t in g
        push!(out, _C14NQuad(t.subject, t.predicate, t.object, nothing))
    end
    out
end

function _collect_quads(ds::Dataset)
    out = _C14NQuad[]
    for q in quads(ds)
        push!(out, _C14NQuad(q.subject, q.predicate, q.object, q.graph))
    end
    out
end

# Collect blank-node ids referenced anywhere in a term (recursing TripleTerms).
function _term_bnodes!(acc::Set{String}, v)
    if v isa BNode
        push!(acc, v.id)
    elseif v isa TripleTerm
        _term_bnodes!(acc, v.subject)
        _term_bnodes!(acc, v.object)
    end
    acc
end

# Whether a term mentions a particular blank-node id.
function _term_mentions(v, id::String)
    if v isa BNode
        return v.id == id
    elseif v isa TripleTerm
        return _term_mentions(v.subject, id) || _term_mentions(v.object, id)
    end
    false
end

# ─── Issuer (canonical / temporary identifier issuer) ───────────────

mutable struct _Issuer
    prefix::String
    counter::Int
    issued::Dict{String,String}   # existing id -> issued id
    order::Vector{String}         # existing ids in issuance order
end
_Issuer(prefix::String) = _Issuer(prefix, 0, Dict{String,String}(), String[])

function _copy_issuer(iss::_Issuer)
    _Issuer(iss.prefix, iss.counter, copy(iss.issued), copy(iss.order))
end

# Issue (or return existing) identifier for `id`.
function _issue!(iss::_Issuer, id::String)
    haskey(iss.issued, id) && return iss.issued[id]
    newid = string(iss.prefix, iss.counter)
    iss.counter += 1
    iss.issued[id] = newid
    push!(iss.order, id)
    newid
end

_has_issued(iss::_Issuer, id::String) = haskey(iss.issued, id)

# ─── Hashing helpers ────────────────────────────────────────────────

_hex(bytes) = bytes2hex(bytes)
_sha256_hex(s::AbstractString) = _hex(SHA.sha256(s))

# ─── Canonicalization state ─────────────────────────────────────────

mutable struct _C14NState
    quads::Vector{_C14NQuad}
    bnode_to_quads::Dict{String,Vector{Int}}   # bnode id -> indices of quads
    hash_to_bnodes::Dict{String,Vector{String}}
    canon_issuer::_Issuer
end

function _C14NState(quads::Vector{_C14NQuad})
    bn2q = Dict{String,Vector{Int}}()
    for (i, q) in enumerate(quads)
        ids = Set{String}()
        _term_bnodes!(ids, q.s)
        _term_bnodes!(ids, q.o)
        q.g isa BNode && push!(ids, q.g.id)
        # graph name BNodes count too (per RDFC-1.0 referencing).
        for id in ids
            push!(get!(bn2q, id, Int[]), i)
        end
    end
    _C14NState(quads, bn2q, Dict{String,Vector{String}}(), _Issuer("c14n"))
end

# ─── 4.6 Hash First Degree Quads ────────────────────────────────────
#
# For the reference blank node `ref`, serialize each quad it appears in with
# the reference replaced by `_:a` and any *other* blank node by `_:z`, sort
# the serialized lines, concatenate, and hash with SHA-256.

function _hash_first_degree(state::_C14NState, ref::String)
    label = function (id::String)
        id == ref ? "a" : "z"
    end
    lines = String[]
    for qi in state.bnode_to_quads[ref]
        q = state.quads[qi]
        push!(lines, _c14n_quad(q.s, q.p, q.o, q.g, label) * "\n")
    end
    sort!(lines)
    _sha256_hex(join(lines))
end

# ─── 4.8 Hash Related Blank Node ────────────────────────────────────

function _hash_related(state::_C14NState, related::String, q::_C14NQuad,
                       issuer::_Issuer, position::Char)
    buf = IOBuffer()
    write(buf, position)
    if position != 'g'
        write(buf, "<", _c14n_escape_iri(q.p.value), ">")
    end
    if _has_issued(state.canon_issuer, related)
        write(buf, "_:", state.canon_issuer.issued[related])
    elseif _has_issued(issuer, related)
        write(buf, "_:", issuer.issued[related])
    else
        write(buf, "_:", _hash_first_degree(state, related))
    end
    _sha256_hex(String(take!(buf)))
end

# Determine which positions a blank node `related` occupies in quad `q`
# relative to the reference `ref`. Returns a vector of (related_id, position).
function _related_in_quad!(acc::Dict{String,Vector{Char}}, term, ref::String, pos::Char)
    if term isa BNode
        if term.id != ref
            push!(get!(acc, term.id, Char[]), pos)
        end
    elseif term isa TripleTerm
        # Triple terms: their bnodes are related too. RDFC-1.0 treats nested
        # bnodes; use the same position character of the enclosing component.
        _related_in_quad!(acc, term.subject, ref, pos)
        _related_in_quad!(acc, term.object, ref, pos)
    end
end

# ─── 4.9 Hash N-Degree Quads ────────────────────────────────────────

function _hash_n_degree(state::_C14NState, ref::String, issuer::_Issuer)
    # Step 1-3: build map of hash -> list of related bnodes.
    hash_to_related = Dict{String,Vector{String}}()
    for qi in state.bnode_to_quads[ref]
        q = state.quads[qi]
        # gather related bnodes by position s/o/g
        acc = Dict{String,Vector{Char}}()
        _related_in_quad!(acc, q.s, ref, 's')
        _related_in_quad!(acc, q.o, ref, 'o')
        if q.g isa BNode && q.g.id != ref
            push!(get!(acc, q.g.id, Char[]), 'g')
        end
        for (related, positions) in acc
            for pos in positions
                h = _hash_related(state, related, q, issuer, pos)
                push!(get!(hash_to_related, h, String[]), related)
            end
        end
    end

    data_to_hash = IOBuffer()
    # Process hashes in sorted (code point) order.
    for related_hash in sort!(collect(keys(hash_to_related)))
        write(data_to_hash, related_hash)
        chosen_path = ""
        chosen_issuer = nothing
        # Try each permutation of the related bnode list with this hash.
        related_list = hash_to_related[related_hash]
        for perm in _permutations(related_list)
            issuer_copy = _copy_issuer(issuer)
            path = ""
            recursion_list = String[]
            skip = false
            for related in perm
                if _has_issued(state.canon_issuer, related)
                    path *= "_:" * state.canon_issuer.issued[related]
                else
                    if !_has_issued(issuer_copy, related)
                        push!(recursion_list, related)
                    end
                    path *= "_:" * _issue!(issuer_copy, related)
                end
                # Early termination check against current best.
                if !isempty(chosen_path) && length(path) >= length(chosen_path) &&
                   path > chosen_path
                    skip = true
                    break
                end
            end
            if skip
                continue
            end
            for related in recursion_list
                result_hash, result_issuer = _hash_n_degree(state, related, issuer_copy)
                path *= "_:" * _issue!(issuer_copy, related)
                path *= "<" * result_hash * ">"
                issuer_copy = result_issuer
                if !isempty(chosen_path) && length(path) >= length(chosen_path) &&
                   path > chosen_path
                    skip = true
                    break
                end
            end
            skip && continue
            if isempty(chosen_path) || path < chosen_path
                chosen_path = path
                chosen_issuer = issuer_copy
            end
        end
        write(data_to_hash, chosen_path)
        issuer = chosen_issuer
    end
    (_sha256_hex(String(take!(data_to_hash))), issuer)
end

# Lazy permutations (Heap's algorithm via Combinatorics-free implementation).
function _permutations(v::Vector{String})
    n = length(v)
    n == 0 && return [String[]]
    n == 1 && return [copy(v)]
    result = Vector{Vector{String}}()
    function rec(arr::Vector{String}, k::Int)
        if k == 1
            push!(result, copy(arr))
        else
            for i in 1:k
                rec(arr, k - 1)
                if iseven(k)
                    arr[i], arr[k] = arr[k], arr[i]
                else
                    arr[1], arr[k] = arr[k], arr[1]
                end
            end
        end
    end
    rec(copy(v), n)
    result
end

# ─── 4.4 Main algorithm ─────────────────────────────────────────────

function _canonicalize(quads::Vector{_C14NQuad})
    state = _C14NState(quads)

    # Step 3: first-degree hashes.
    first_hashes = Dict{String,String}()
    for bn in keys(state.bnode_to_quads)
        h = _hash_first_degree(state, bn)
        first_hashes[bn] = h
        push!(get!(state.hash_to_bnodes, h, String[]), bn)
    end

    # Step 4-5: assign canonical ids to bnodes with a unique first-degree hash.
    non_unique = String[]
    for h in sort!(collect(keys(state.hash_to_bnodes)))
        bns = state.hash_to_bnodes[h]
        if length(bns) == 1
            _issue!(state.canon_issuer, bns[1])
        else
            append!(non_unique, bns)
        end
    end

    # Step 6: process the remaining (ambiguous) blank nodes via N-degree hashing.
    # Group by first-degree hash, process groups in sorted hash order.
    remaining_by_hash = Dict{String,Vector{String}}()
    for bn in non_unique
        push!(get!(remaining_by_hash, first_hashes[bn], String[]), bn)
    end
    for h in sort!(collect(keys(remaining_by_hash)))
        bns = remaining_by_hash[h]
        hash_path_list = Tuple{String,_Issuer}[]
        for bn in bns
            _has_issued(state.canon_issuer, bn) && continue
            temp_issuer = _Issuer("b")
            _issue!(temp_issuer, bn)
            result_hash, result_issuer = _hash_n_degree(state, bn, temp_issuer)
            push!(hash_path_list, (result_hash, result_issuer))
        end
        # Sort by hash (code point) and issue ids in issuance order.
        sort!(hash_path_list; by = first)
        for (_, temp_issuer) in hash_path_list
            for existing in temp_issuer.order
                _issue!(state.canon_issuer, existing)
            end
        end
    end

    state
end

# Map a bnode id to its canonical label string.
function _canon_label_fn(state::_C14NState)
    function (id::String)
        h = get(state.canon_issuer.issued, id, nothing)
        h === nothing ? id : h
    end
end

# Identity label function: emit blank-node ids unchanged.
_identity_label(id::String) = id

# ─── Public API ─────────────────────────────────────────────────────
#
# Two layers are provided:
#
#  * `rdf_canonicalize` — the *canonical N-Triples / N-Quads* form required by
#    the W3C RDF 1.2 `TestN{Triples,Quads}PositiveC14N` suites. This is the
#    canonical *serialization* (single-space layout, canonical literal/IRI
#    escaping, `xsd:string` datatype omitted, lower-cased language tags, triple
#    terms written `<<( s p o )>>`). Per those suites the form PRESERVES the
#    original blank-node labels and the input statement order — it is a
#    syntactic canonicalization, not blank-node relabelling.
#
#  * `rdfc10` — the full W3C RDF Dataset Canonicalization algorithm (RDFC-1.0,
#    SHA-256): blank nodes are relabelled to deterministic `c14nN` identifiers
#    via first-degree + N-degree hashing, every quad is written in canonical
#    form, and the lines are sorted by Unicode code point. This is what makes
#    isomorphic graphs canonicalize identically. `canonical_bnode_labels`
#    exposes the issued label mapping.

"""
    rdf_canonicalize(g::RDFGraph) -> String
    rdf_canonicalize(ds::Dataset) -> String

Return the canonical N-Triples (graph) / N-Quads (dataset) *serialization* of
the input, as defined by the W3C RDF 1.2 canonicalization test suites: each
statement is written in canonical form (single-space separators, canonical
literal & IRI escaping, an `xsd:string` datatype omitted, lower-cased language
tags, triple terms written `<<( s p o )>>`), terminated by `.` and a single
line feed. Blank-node labels and statement order are preserved.

For full RDF Dataset Canonicalization with deterministic `c14nN` blank-node
relabelling (RDFC-1.0), see [`rdfc10`](@ref).
"""
function rdf_canonicalize(quads::Vector{_C14NQuad})
    buf = IOBuffer()
    for q in quads
        write(buf, _c14n_quad(q.s, q.p, q.o, q.g, _identity_label))
        write(buf, "\n")
    end
    String(take!(buf))
end

rdf_canonicalize(g::RDFGraph) = rdf_canonicalize(_collect_quads(g))
rdf_canonicalize(ds::Dataset) = rdf_canonicalize(_collect_quads(ds))

"""
    rdfc10(g::RDFGraph) -> String
    rdfc10(ds::Dataset) -> String

Canonicalize an RDF graph or dataset using the full W3C RDF Dataset
Canonicalization algorithm (RDFC-1.0, SHA-256). Blank nodes are relabelled to
deterministic `c14nN` identifiers (first-degree + N-degree hashing), every
statement is written in canonical form, and the lines are sorted by Unicode
code point and joined with line feeds (trailing newline included). Isomorphic
graphs produce identical output, independent of input order or blank-node
labels.
"""
function rdfc10(quads::Vector{_C14NQuad})
    state = _canonicalize(quads)
    label = _canon_label_fn(state)
    lines = String[_c14n_quad(q.s, q.p, q.o, q.g, label) for q in state.quads]
    sort!(lines)
    isempty(lines) ? "" : join(lines, "\n") * "\n"
end

rdfc10(g::RDFGraph) = rdfc10(_collect_quads(g))
rdfc10(ds::Dataset) = rdfc10(_collect_quads(ds))

"""
    canonical_bnode_labels(g_or_ds) -> Dict{String,String}

Return the mapping from each original blank-node id to its issued canonical
`c14nN` label, as produced by the RDFC-1.0 algorithm ([`rdfc10`](@ref)).
"""
function canonical_bnode_labels(quads::Vector{_C14NQuad})
    state = _canonicalize(quads)
    copy(state.canon_issuer.issued)
end
canonical_bnode_labels(g::RDFGraph) = canonical_bnode_labels(_collect_quads(g))
canonical_bnode_labels(ds::Dataset) = canonical_bnode_labels(_collect_quads(ds))
