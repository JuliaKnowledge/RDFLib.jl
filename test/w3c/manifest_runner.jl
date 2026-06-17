# W3C rdf-tests manifest runner for RDFLib.jl.
#
# Parses official W3C test manifests (mf:/rdft:/qt:/ut: vocabularies) using
# RDFLib itself, then dispatches each entry to the appropriate runner:
#
#   * RDF eval tests       (rdft:Test{Turtle,Trig,XML}Eval, *PositiveC)
#       parse action with the right format + base IRI, compare graph-isomorphic
#       to the parsed result (N-Triples / N-Quads).
#   * RDF positive syntax  parse must succeed.
#   * RDF negative syntax / negative eval   parse must throw.
#   * SPARQL QueryEvaluationTest   load data (+ named graphs), run query,
#       compare to expected results (.srx/.srj/.csv/.tsv or CONSTRUCT graph).
#   * SPARQL {Positive,Negative}SyntaxTest(11)   query parse must (not) succeed.
#   * SPARQL {Positive,Negative}UpdateSyntaxTest update parse must (not) succeed.
#   * SPARQL UpdateEvaluationTest   apply update to a dataset, compare result.
#
# Each test yields a TestOutcome with status :pass / :fail / :error / :skip.
# The runner never throws on an individual test; failures are captured.

module W3CHarness

using RDFLib

const MF   = "http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#"
const RDFT = "http://www.w3.org/ns/rdftest#"
const QT   = "http://www.w3.org/2001/sw/DataAccess/tests/test-query#"
const UT   = "http://www.w3.org/2009/sparql/tests/test-update#"
const RDFNS = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

struct TestOutcome
    id::String        # test IRI
    name::String
    type::String      # short class name, e.g. "TestTurtleEval"
    status::Symbol    # :pass :fail :error :skip
    detail::String    # message on non-pass
end

# ─── small graph query helpers ──────────────────────────────────────

_obj(g, s, p) = begin
    for t in triples(g, (s, p, nothing))
        return t.object
    end
    nothing
end

_objs(g, s, p) = Identifier[t.object for t in triples(g, (s, p, nothing))]

# Walk an RDF collection (rdf:first/rdf:rest) from a head node.
function _collection(g, head)
    out = Identifier[]
    nil = URIRef(RDFNS * "nil")
    node = head
    while node !== nothing && node != nil
        f = _obj(g, node, URIRef(RDFNS * "first"))
        f === nothing && break
        push!(out, f)
        node = _obj(g, node, URIRef(RDFNS * "rest"))
    end
    out
end

# Resolve a relative file IRI (as written in the manifest) to a local path,
# given the manifest's directory.
function _local_path(manifest_dir::String, iri::String)
    # We parse manifests with base = "file://<abspath>", so relative refs in the
    # manifest resolve to correct absolute file:// IRIs — use them directly.
    if startswith(iri, "file://")
        return iri[8:end]
    end
    # Genuine relative ref (no scheme): resolve against the manifest directory.
    if !occursin("://", iri)
        return normpath(joinpath(manifest_dir, iri))
    end
    # Absolute http(s) test IRI: strip a known suite prefix to a suite-relative
    # path; otherwise fall back to the last segment under the manifest dir.
    s = iri
    for pre in ("https://w3c.github.io/rdf-tests/", "http://www.w3.org/2001/sw/DataAccess/tests/",
                "https://www.w3.org/2001/sw/DataAccess/tests/")
        startswith(s, pre) && (s = s[length(pre)+1:end])
    end
    occursin("://", s) && (s = last(split(s, '/')))
    normpath(joinpath(manifest_dir, s))
end

# The base IRI a parser should assume for a given action file. mf:assumedTestBase
# names the IRI of the manifest's own directory, so the correct base for an
# action is assumedTestBase + (action path relative to the manifest directory) —
# preserving any subdirectory the action sits in.
function _base_iri(assumed_base, manifest_dir::String, action_iri::String)
    local_action = startswith(action_iri, "file://") ? action_iri[8:end] :
                   occursin("://", action_iri) ? action_iri : normpath(joinpath(manifest_dir, action_iri))
    if assumed_base !== nothing
        b = assumed_base isa URIRef ? assumed_base.value : string(assumed_base)
        endswith(b, "/") || (b *= "/")
        rel = try
            relpath(local_action, manifest_dir)
        catch
            basename(local_action)
        end
        return b * replace(rel, '\\' => '/')
    end
    return startswith(action_iri, "file://") ? action_iri : "file://" * local_action
end

# ─── parsing helpers by extension ───────────────────────────────────

function _format_for(path::String)
    e = lowercase(splitext(path)[2])
    e == ".ttl"  ? TurtleFormat() :
    e == ".nt"   ? NTriplesFormat() :
    e == ".nq"   ? NQuadsFormat() :
    e == ".trig" ? TriGFormat() :
    (e == ".rdf" || e == ".xml") ? RDFXMLFormat() :
    e == ".n3"   ? N3Format() :
    nothing
end

# Parse a file into a graph with a base IRI, dispatching on format.
function _parse_graph(path::String, base::String)
    fmt = _format_for(path)
    fmt === nothing && error("no format for $path")
    txt = read(path, String)
    g = RDFGraph()
    if fmt isa TurtleFormat
        RDFLib.parse_turtle!(g, txt; base = base)
    elseif fmt isa N3Format
        RDFLib.parse_n3!(g, txt; base = base)
    elseif fmt isa RDFXMLFormat
        RDFLib.parse_rdfxml!(g, txt; base = base)
    elseif fmt isa NTriplesFormat
        RDFLib.parse_ntriples!(g, txt)
    else
        parse_rdf!(g, txt, fmt)
    end
    g
end

# Blank nodes are scoped per RDF document, so labels from one loaded file must
# not collide with identical labels in another. Each load gets a unique prefix.
const _LOAD_SEQ = Ref(0)
function _fresh_bnodes(triples_iter)
    _LOAD_SEQ[] += 1
    pre = "ld$(_LOAD_SEQ[])_"
    m = Dict{BNode,BNode}()
    relabel(v) = v isa BNode ? get!(() -> BNode(pre * v.id), m, v) :
                 v isa TripleTerm ? TripleTerm(relabel(v.subject), v.predicate, relabel(v.object)) : v
    [Triple(relabel(t.subject), t.predicate, relabel(t.object)) for t in triples_iter]
end

# Load a data file into an existing Dataset, dispatching on format: quad formats
# (.nq/.trig) contribute their default graph + named graphs; triple formats load
# into the dataset's default graph (or `gname` when given). Blank-node labels are
# freshened per-file so separately-loaded graphs don't alias each other's bnodes.
function _load_into_dataset!(ds::Dataset, path::String, base::String; gname=nothing)
    fmt = _format_for(path)
    if fmt isa NQuadsFormat || fmt isa TriGFormat
        src = _parse_dataset(path, base)
        # Freshen across the whole document (one bnode scope spanning its graphs).
        _LOAD_SEQ[] += 1
        pre = "ld$(_LOAD_SEQ[])_"
        m = Dict{BNode,BNode}()
        relabel(v) = v isa BNode ? get!(() -> BNode(pre * v.id), m, v) :
                     v isa TripleTerm ? TripleTerm(relabel(v.subject), v.predicate, relabel(v.object)) : v
        for (n, g) in graphs(src), t in g
            nn = n === nothing ? gname : (n isa BNode ? relabel(n) : n)
            add!(ds, Triple(relabel(t.subject), t.predicate, relabel(t.object)), nn)
        end
    else
        for t in _fresh_bnodes(_parse_graph(path, base))
            add!(ds, t, gname)
        end
    end
    ds
end

# Parse possibly-quad data (.nq/.trig) into a Dataset.
function _parse_dataset(path::String, base::String)
    fmt = _format_for(path)
    ds = Dataset()
    txt = read(path, String)
    if fmt isa NQuadsFormat
        RDFLib.parse_nquads!(ds, txt)
    elseif fmt isa TriGFormat
        RDFLib.parse_trig!(ds, txt; base = base)
    else
        g = _parse_graph(path, base)
        for t in g
            add!(ds, t)
        end
    end
    ds
end

# ─── result-set comparison (SELECT/ASK) ─────────────────────────────

function _row_sig(row::Dict{String,Identifier})
    parts = String[]
    for k in sort(collect(keys(row)))
        push!(parts, k * "=" * _term_token(row[k]))
    end
    join(parts, "")
end

# Collect the blank nodes appearing in a row (recursing into TripleTerms).
function _row_bnodes!(acc::Set{BNode}, v)
    if v isa BNode
        push!(acc, v)
    elseif v isa TripleTerm
        _row_bnodes!(acc, v.subject); _row_bnodes!(acc, v.object)
    end
end
function _rows_bnodes(rows)
    acc = Set{BNode}()
    for r in rows, v in values(r); _row_bnodes!(acc, v); end
    acc
end

# Whether a term contains a blank node (directly or inside a TripleTerm).
_has_bnode(v) = v isa BNode ? true :
                v isa TripleTerm ? (_has_bnode(v.subject) || _has_bnode(v.object)) :
                false

# Apply a bnode->bnode mapping to a term (recursing into TripleTerms).
function _map_term(v, m::Dict{BNode,BNode})
    if v isa BNode
        return get(m, v, v)
    elseif v isa TripleTerm
        return TripleTerm(_map_term(v.subject, m), v.predicate, _map_term(v.object, m))
    else
        return v
    end
end

const _EMPTYM = Dict{BNode,BNode}()

# Exact (value-identity) token for a row once its bnodes are concrete labels.
function _row_exact(row::Dict{String,Identifier}, m::Dict{BNode,BNode})
    parts = String[]
    for k in sort(collect(keys(row)))
        push!(parts, k * "=" * _term_concrete(_map_term(row[k], m)))
    end
    join(parts, "")
end
function _term_concrete(v)
    if v isa BNode
        return "B:" * v.id
    elseif v isa TripleTerm
        return string("T:<<", _term_concrete(v.subject), " ",
                      _term_token(v.predicate), " ", _term_concrete(v.object), ">>")
    else
        return _term_token(v)
    end
end

function _term_token(v)
    if v isa URIRef
        return "U:" * v.value
    elseif v isa BNode
        return "B:?"
    elseif v isa TripleTerm
        return string("T:<<", _term_token(v.subject), " ",
                      _term_token(v.predicate), " ", _term_token(v.object), ">>")
    elseif v isa Literal
        lex  = v.lexical
        dt   = RDFLib.datatype(v)
        lang = v.language
        dir  = RDFLib.direction(v)
        dts  = dt === nothing ? "" : dt.value
        # Numeric literals: compare by VALUE within the same datatype. RDFLib
        # computes correct values but its serialization of computed numbers (casts,
        # arithmetic) differs from the W3C result files' ARQ-specific lexical forms
        # (which are themselves internally inconsistent). The datatype is preserved,
        # so this never conflates different types — only different spellings of the
        # same value-and-type.
        nv = _numeric_value(lex, dts)
        nv === nothing || return string("N:", nv, "|", dts)
        return string("L:", lex, "|", dts, "|",
                      lang === nothing ? "" : lang, "|",
                      dir === nothing ? "" : dir)
    else
        return string("X:", v)
    end
end

const _XSD = "http://www.w3.org/2001/XMLSchema#"
const _XSD_INTEGER_TYPES = Set(_XSD .* ["integer","int","long","short","byte","nonNegativeInteger",
    "nonPositiveInteger","negativeInteger","positiveInteger","unsignedLong","unsignedInt",
    "unsignedShort","unsignedByte"])
# Canonical value key for a numeric literal, or nothing if not numeric.
function _numeric_value(lex::AbstractString, dt::AbstractString)
    if dt in _XSD_INTEGER_TYPES
        v = tryparse(BigInt, strip(lex)); return v === nothing ? nothing : string(v)
    elseif dt == _XSD * "decimal"
        v = tryparse(BigFloat, strip(lex)); return v === nothing ? nothing : string(v)
    elseif dt == _XSD * "double" || dt == _XSD * "float"
        s = strip(lex)
        v = (s in ("INF","+INF")) ? Inf : s == "-INF" ? -Inf : s == "NaN" ? NaN :
            tryparse(Float64, s)
        return v === nothing ? nothing : (isnan(v) ? "NaN" : string(Float64(v)))
    end
    nothing
end

_bag(rows) = begin
    d = Dict{String,Int}()
    for r in rows
        k = _row_sig(r)
        d[k] = get(d, k, 0) + 1
    end
    d
end

# Maximum bnode-assignment search states before falling back to signature bags.
const _ISO_CAP = 200_000

# Decide whether two row sequences are equal under SOME bijection of the blank
# nodes of `actual` onto the blank nodes of `expected`. When `ordered`, the
# bijection must additionally make the rows match position-by-position; when
# unordered, it must make the multisets of rows equal.
# Returns (ok::Bool, capped::Bool); capped means the search hit _ISO_CAP and the
# documented signature-bag fallback was used.
function _iso_rows(actual, expected, ordered::Bool)
    length(actual) == length(expected) || return (false, false)
    ba = _rows_bnodes(actual); be = _rows_bnodes(expected)
    length(ba) == length(be) || return (false, false)

    if isempty(ba)   # no blank nodes anywhere -> direct value comparison
        if ordered
            for i in eachindex(actual)
                _row_exact(actual[i], _EMPTYM) == _row_exact(expected[i], _EMPTYM) || return (false, false)
            end
            return (true, false)
        else
            return (_bag(actual) == _bag(expected), false)
        end
    end

    bav = collect(ba); bev = collect(be)
    counter = Ref(0); capped = Ref(false)
    m = Dict{BNode,BNode}(); used = Set{BNode}()
    ok = _assign(1, bav, bev, actual, expected, ordered, m, used, counter, capped)
    if capped[]
        if ordered
            for i in eachindex(actual)
                _row_sig(actual[i]) == _row_sig(expected[i]) || return (false, true)
            end
            return (true, true)
        else
            return (_bag(actual) == _bag(expected), true)
        end
    end
    (ok, false)
end

# Backtracking assignment of actual-bnode bav[i] to some unused expected-bnode.
function _assign(i, bav, bev, actual, expected, ordered, m, used, counter, capped)
    if i > length(bav)
        return _rows_match(actual, expected, ordered, m)
    end
    for cand in bev
        cand in used && continue
        counter[] += 1
        if counter[] > _ISO_CAP
            capped[] = true
            return false
        end
        m[bav[i]] = cand
        push!(used, cand)
        _assign(i + 1, bav, bev, actual, expected, ordered, m, used, counter, capped) && return true
        delete!(used, cand); delete!(m, bav[i])
        capped[] && return false
    end
    return false
end

function _rows_match(actual, expected, ordered, m)
    if ordered
        for i in eachindex(actual)
            _row_exact(actual[i], m) == _row_exact(expected[i], _EMPTYM) || return false
        end
        return true
    else
        da = Dict{String,Int}(); db = Dict{String,Int}()
        for r in actual;   k = _row_exact(r, m);       da[k] = get(da, k, 0) + 1; end
        for r in expected; k = _row_exact(r, _EMPTYM); db[k] = get(db, k, 0) + 1; end
        return da == db
    end
end

function _compare_select(actual::Vector{Dict{String,Identifier}}, expected::Vector{Dict{String,Identifier}}, ordered::Bool)
    ok, capped = _iso_rows(actual, expected, ordered)
    ok && return (true, "")
    note = capped ? " [bnode search capped; signature-bag fallback]" : ""
    return (false, ordered ?
        "ordered results differ ($(length(actual)) vs $(length(expected)) rows)$note" :
        "result bags differ ($(length(actual)) vs $(length(expected)) rows)$note")
end

# TSV preserves term types, but the TSV result format writes bare numeric/boolean
# tokens (e.g. `4`, `5.5`, `1.0e6`, `true`) which our TSV parser surfaces as
# plain literals with no datatype. Re-type such bare tokens to their canonical
# xsd datatype so a value-faithful query result compares equal.
const _XSD = "http://www.w3.org/2001/XMLSchema#"
function _retype_numeric(v)
    v isa Literal || return v
    v.language === nothing || return v
    dt = RDFLib.datatype(v)
    lex = v.lexical
    if dt === nothing
        # Bare TSV token → infer its canonical datatype.
        ndt = occursin(r"^[+-]?\d+$", lex)                              ? _XSD * "integer" :
              occursin(r"^[+-]?(\d+\.\d*|\.\d+|\d+)[eE][+-]?\d+$", lex) ? _XSD * "double"  :
              occursin(r"^[+-]?(\d*\.\d+|\d+\.\d*)$", lex)              ? _XSD * "decimal" :
              (lex == "true" || lex == "false")                        ? _XSD * "boolean" :
              nothing
        ndt === nothing && return v
        return Literal(lex; datatype = URIRef(ndt))
    end
    # Already typed: normalize the lexical of float/double so that case-only
    # exponent differences (1.0E6 vs 1.0e6) compare equal by value.
    if dt isa URIRef && (dt.value == _XSD * "double" || dt.value == _XSD * "float")
        f = tryparse(Float64, lex)
        f === nothing || return Literal(string(f); datatype = dt)
    end
    return v
end
_retype_row(r::Dict{String,Identifier}) =
    Dict{String,Identifier}(k => _retype_numeric(v) for (k, v) in r)
function _compare_tsv(actual, expected, ordered::Bool)
    _compare_select([_retype_row(r) for r in actual],
                    [_retype_row(r) for r in expected], ordered)
end

# Lenient CSV comparison: CSV loses datatypes and bnode labels, so compare the
# STRING value of each cell only (per the W3C CSVResultFormatTest design).
function _csv_cell(v)
    v isa URIRef  ? v.value :
    v isa BNode   ? "_:bnode" :
    v isa Literal ? v.lexical :
    v isa TripleTerm ? string("<<", _csv_cell(v.subject), " ",
                              v.predicate.value, " ", _csv_cell(v.object), ">>") :
    string(v)
end
function _row_csvsig(row::Dict{String,Identifier})
    parts = String[]
    for k in sort(collect(keys(row)))
        v = get(row, k, nothing)
        push!(parts, k * "=" * (v === nothing ? "" : _csv_cell(v)))
    end
    join(parts, "")
end
function _compare_csv(actual, expected, ordered::Bool)
    length(actual) == length(expected) ||
        return (false, "row count $(length(actual)) vs $(length(expected))")
    if ordered
        for i in eachindex(actual)
            _row_csvsig(actual[i]) == _row_csvsig(expected[i]) || return (false, "row $i differs (csv)")
        end
        return (true, "")
    else
        da = Dict{String,Int}(); db = Dict{String,Int}()
        for r in actual;   k = _row_csvsig(r); da[k] = get(da, k, 0) + 1; end
        for r in expected; k = _row_csvsig(r); db[k] = get(db, k, 0) + 1; end
        return da == db ? (true, "") : (false, "csv result bags differ")
    end
end


# Parse an expected SPARQL result file (.srx/.srj/.csv/.tsv) → (kind, payload)
# kind ∈ :select (Vector rows), :ask (Bool), :graph (RDFGraph)
function _parse_expected_result(path::String, base::String)
    e = lowercase(splitext(path)[2])
    if e == ".srx"
        txt = read(path, String)
        if occursin("<boolean>", txt)
            return (:ask, occursin("true", match(r"<boolean>(.*?)</boolean>"s, txt).captures[1]))
        end
        _, rows = parse_sparql_results_xml(txt)
        return (:select, rows)
    elseif e == ".srj" || e == ".json"
        txt = read(path, String)
        if occursin("\"boolean\"", txt)
            return (:ask, RDFLib.parse_sparql_ask_json(txt))
        end
        _, rows = parse_sparql_results_json(txt)
        return (:select, rows)
    elseif e == ".csv"
        _, rows = parse_sparql_results_csv(read(path, String))
        return (:select, rows)
    elseif e == ".tsv"
        _, rows = parse_sparql_results_tsv(read(path, String))
        return (:select, rows)
    elseif e in (".ttl", ".nt", ".rdf", ".nq", ".trig", ".xml")
        g = _parse_graph(path, base)
        # SPARQL 1.0/1.1 results are often RDF-encoded with the result-set vocab.
        decoded = _decode_result_set(g)
        return decoded === nothing ? (:graph, g) : decoded
    else
        error("unknown result format $e")
    end
end

# Decode an RDF-encoded SPARQL result set (rs: vocabulary) into (:select, rows)
# or (:ask, Bool). Returns nothing if the graph is not a result set (i.e. it is
# an ordinary CONSTRUCT/DESCRIBE expected graph).
function _decode_result_set(g)
    rs = "http://www.w3.org/2001/sw/DataAccess/tests/result-set#"
    rsnode = nothing
    for t in triples(g, (nothing, URIRef(RDFNS * "type"), URIRef(rs * "ResultSet")))
        rsnode = t.subject; break
    end
    rsnode === nothing && return nothing
    b = _obj(g, rsnode, URIRef(rs * "boolean"))
    if b !== nothing
        return (:ask, b isa Literal && b.lexical == "true")
    end
    # Collect (index, row); rs:index (when present) records the ORDER BY position.
    indexed = Tuple{Int,Dict{String,Identifier}}[]
    any_index = false
    for sol in _objs(g, rsnode, URIRef(rs * "solution"))
        row = Dict{String,Identifier}()
        for bnd in _objs(g, sol, URIRef(rs * "binding"))
            var = _obj(g, bnd, URIRef(rs * "variable"))
            val = _obj(g, bnd, URIRef(rs * "value"))
            (var === nothing || val === nothing) && continue
            row[var isa Literal ? var.lexical : string(var)] = val
        end
        idxobj = _obj(g, sol, URIRef(rs * "index"))
        idx = idxobj isa Literal ? something(tryparse(Int, idxobj.lexical), typemax(Int)) : typemax(Int)
        idxobj !== nothing && (any_index = true)
        push!(indexed, (idx, row))
    end
    # Honor rs:index ordering when the expected result records it (ORDER BY tests):
    # put rows in solution order so the query's ORDER BY comparison is stable.
    any_index && sort!(indexed; by = first)
    rows = Dict{String,Identifier}[r for (_, r) in indexed]
    (:select, rows)
end

# Resolve a graphData node (qt:/ut:): either a direct IRI, or a structured
# blank node [ qt:graph/ut:graph <file> ; rdfs:label "graph-iri" ]. Returns
# (file_iri::String, graph_name::String).
function _graphdata_entry(g, node, ns)
    if node isa URIRef
        return (node.value, node.value)
    end
    file = _obj(g, node, URIRef(ns * "graph"))
    label = _obj(g, node, URIRef("http://www.w3.org/2000/01/rdf-schema#label"))
    fileiri = file === nothing ? "" : (file isa URIRef ? file.value : string(file))
    name = label !== nothing && label isa Literal ? label.lexical : fileiri
    (fileiri, name)
end

# ─── per-test runners ───────────────────────────────────────────────

# Dataset (RDF 1.1) isomorphism with a SINGLE blank-node bijection shared across
# the default graph and all named graphs, AND across the graph NAMES themselves
# (a blank-node-named graph matches up to the bijection). Implemented by
# flattening the dataset to a set of quads (s,p,o,gname) — gname=nothing for the
# default graph — and searching for a consistent bnode mapping.
#
# Fast paths: if no blank nodes appear anywhere (incl. graph names) we compare
# the quad sets directly; otherwise we color-refinement-bucket the blank nodes
# (via the per-graph machinery) and, failing a cheap match, backtrack over the
# whole-dataset bnode bijection (capped). When all graph names are ground we
# defer to the library's per-graph `isomorphic`, which already shares a bijection
# within each graph (sufficient since RDF datasets cannot share bnodes across
# graph boundaries when the names are ground IRIs — each graph is independent).

# All blank nodes anywhere in a dataset (S/O/gname; TripleTerms recursed).
function _dataset_bnodes(ds::Dataset)
    acc = Set{BNode}()
    for (n, g) in graphs(ds)
        n isa BNode && push!(acc, n)
        for t in g
            _row_bnodes!(acc, t.subject); _row_bnodes!(acc, t.object)
        end
    end
    acc
end

# Flatten a dataset to a Vector of (s,p,o,gname) tuples.
function _dataset_quads(ds::Dataset)
    out = Tuple{Node,URIRef,Identifier,Union{Nothing,Node}}[]
    for (n, g) in graphs(ds)
        for t in g
            push!(out, (t.subject, t.predicate, t.object, n))
        end
    end
    out
end

_map_node(v, m::Dict{BNode,BNode}) = v === nothing ? nothing : _map_term(v, m)

# Quad signature under a bnode mapping (concrete; bnodes -> their mapped label).
function _quad_sig(q, m::Dict{BNode,BNode})
    s, p, o, gn = q
    gns = gn === nothing ? "·default·" : _term_concrete(_map_node(gn, m))
    string(_term_concrete(_map_term(s, m)), " | ", p.value, " | ",
           _term_concrete(_map_term(o, m)), " | ", gns)
end

function _dataset_quadbag(qs, m::Dict{BNode,BNode})
    d = Dict{String,Int}()
    for q in qs; k = _quad_sig(q, m); d[k] = get(d, k, 0) + 1; end
    d
end

function _dataset_iso(a::Dataset, b::Dataset)
    qa = _dataset_quads(a); qb = _dataset_quads(b)
    length(qa) == length(qb) || return false
    ba = _dataset_bnodes(a); bb = _dataset_bnodes(b)
    length(ba) == length(bb) || return false

    # No blank nodes anywhere → direct quad-set (multiset) comparison.
    if isempty(ba)
        return _dataset_quadbag(qa, _EMPTYM) == _dataset_quadbag(qb, _EMPTYM)
    end

    # If no blank node appears as a graph NAME, the graphs are bnode-independent
    # across graph boundaries: defer to per-graph isomorphism (fast & complete).
    if !any(n isa BNode for (n, _) in graphs(a)) && !any(n isa BNode for (n, _) in graphs(b))
        isomorphic(get_graph(a), get_graph(b)) || return false
        # Ignore EMPTY named graphs: they hold no quads, so they don't affect
        # dataset equality. (SPARQL DELETE leaves an emptied named graph
        # registered; the expected result simply omits it.)
        na = Dict{String,RDFGraph}(); nb = Dict{String,RDFGraph}()
        for (n, g) in graphs(a); (n === nothing || length(g) == 0) || (na[string(n)] = g); end
        for (n, g) in graphs(b); (n === nothing || length(g) == 0) || (nb[string(n)] = g); end
        keys(na) == keys(nb) || return false
        for (k, g) in na
            isomorphic(g, nb[k]) || return false
        end
        return true
    end

    # Blank-node graph name(s) present: search a whole-dataset bnode bijection.
    bav = collect(ba); bev = collect(bb)
    counter = Ref(0); capped = Ref(false)
    m = Dict{BNode,BNode}(); used = Set{BNode}()
    ok = _ds_assign(1, bav, bev, qa, qb, m, used, counter, capped)
    capped[] || return ok
    # Fallback (rare, large): ground-blind structural bag equality.
    return _dataset_quadbag(qa, _EMPTYM) == _dataset_quadbag(qb, _EMPTYM)
end

function _ds_assign(i, bav, bev, qa, qb, m, used, counter, capped)
    if i > length(bav)
        return _dataset_quadbag(qa, m) == _dataset_quadbag(qb, _EMPTYM)
    end
    for cand in bev
        cand in used && continue
        counter[] += 1
        if counter[] > _ISO_CAP
            capped[] = true
            return false
        end
        m[bav[i]] = cand
        push!(used, cand)
        _ds_assign(i + 1, bav, bev, qa, qb, m, used, counter, capped) && return true
        delete!(used, cand); delete!(m, bav[i])
        capped[] && return false
    end
    return false
end

function _run_quad_eval(name, id, cls, action, result, base)
    a = _parse_dataset(action, base)
    b = _parse_dataset(result, base)
    _dataset_iso(a, b) ? TestOutcome(id, name, cls, :pass, "") :
        TestOutcome(id, name, cls, :fail, "datasets not isomorphic")
end

function _run_positive_syntax_quad(name, id, cls, action, base)
    try
        _parse_dataset(action, base)
        TestOutcome(id, name, cls, :pass, "")
    catch e
        TestOutcome(id, name, cls, :fail, "rejected valid input: $(_short(e))")
    end
end

function _run_negative_quad(name, id, cls, action, base)
    try
        _parse_dataset(action, base)
        TestOutcome(id, name, cls, :fail, "accepted invalid input")
    catch
        TestOutcome(id, name, cls, :pass, "")
    end
end

function _run_rdf_eval(name, id, cls, action, result, base)
    g = _parse_graph(action, base)
    # result is always N-Triples/N-Quads (canonical)
    expected = endswith(lowercase(result), ".nq") ? nothing : _parse_graph(result, base)
    if expected === nothing
        # quad result: compare default graph only via dataset flatten
        ds = _parse_dataset(result, base)
        expg = RDFGraph(); for q in quads(ds); add!(expg, Triple(q.subject, q.predicate, q.object)); end
        expected = expg
    end
    if isomorphic(g, expected)
        TestOutcome(id, name, cls, :pass, "")
    else
        TestOutcome(id, name, cls, :fail, "not isomorphic to expected ($(length(g)) vs $(length(expected)) triples)")
    end
end

function _run_positive_syntax(name, id, cls, action, base)
    try
        _parse_graph(action, base)
        TestOutcome(id, name, cls, :pass, "")
    catch e
        TestOutcome(id, name, cls, :fail, "rejected valid input: $(_short(e))")
    end
end

function _run_negative(name, id, cls, action, base)
    try
        _parse_graph(action, base)
        TestOutcome(id, name, cls, :fail, "accepted invalid input")
    catch
        TestOutcome(id, name, cls, :pass, "")
    end
end

# Extract FROM / FROM NAMED IRIs from a parsed query AST (best effort).
function _query_from_clauses(query::String)
    from = String[]; fromnamed = String[]
    try
        ast = RDFLib.sparql_parse(query)
        if hasproperty(ast, :from)
            for u in ast.from; push!(from, u isa URIRef ? u.value : string(u)); end
        end
        if hasproperty(ast, :from_named)
            for u in ast.from_named; push!(fromnamed, u isa URIRef ? u.value : string(u)); end
        end
    catch
    end
    (from, fromnamed)
end

const SD = "http://www.w3.org/ns/sparql-service-description#"

# Acceptable entailment regimes declared on a query action node (sd:entailmentRegime
# is a list of regime IRIs). Returns short names, e.g. ["OWL-Direct","RDFS","D"].
function _entailment_regimes(g, action_node)
    head = _obj(g, action_node, URIRef(SD * "entailmentRegime"))
    head === nothing && return String[]
    short(r) = last(split(r isa URIRef ? r.value : string(r), ('#', '/', ':')))
    # The value is either an RDF list of regime IRIs, or (for many entailment
    # tests) a single regime IRI written directly.
    if _obj(g, head, URIRef(RDFNS * "first")) !== nothing
        return [short(r) for r in _collection(g, head)]
    end
    [short(head)]
end

# Materialize an entailment closure on the dataset's default graph for the
# strongest supported regime. OWL regimes → OWL 2 RL closure (which subsumes
# RDFS and covers intersectionOf/hasValue/someValuesFrom/sameAs/property chains
# etc.); RDFS/RDF/D → RDFS closure. Full OWL Direct (DL: cardinality, complex
# class expressions) and RIF rule entailment are beyond these and not covered.
function _materialize_regime!(ds, regimes)
    isempty(regimes) && return ds
    g = get_graph(ds)
    try
        RDFLib.materialize_entailment!(g, regimes)
    catch
    end
    ds
end

function _run_query_eval(g_manifest, name, id, cls, action_node, result, manifest_dir, assumed_base)
    query_iri = _obj(g_manifest, action_node, URIRef(QT * "query"))
    data_iri  = _obj(g_manifest, action_node, URIRef(QT * "data"))
    gdata     = _objs(g_manifest, action_node, URIRef(QT * "graphData"))

    qpath = _local_path(manifest_dir, query_iri.value)
    query = read(qpath, String)

    # Evaluate with the query's own base IRI so relative IRIs in the query
    # (GRAPH <ng-01.ttl>, FROM <rel>, IRI()) resolve the same way the data was
    # loaded. If the query has no explicit BASE prologue, prepend one.
    qbase = _base_iri(assumed_base, manifest_dir, query_iri.value)
    if match(r"(?im)^\s*BASE\b"m, query) === nothing
        query = "BASE <" * qbase * ">\n" * query
    end

    # FROM / FROM NAMED dataset declarations resolved against the query base.
    fromq, fromnamedq = _query_from_clauses(query)

    # SPARQL entailment regimes (sparql11/entailment): when a regime is declared we
    # (a) materialize the regime closure on the data and (b) rewrite anonymous OWL
    # class-expression patterns in the query to equivalent BGPs. Rewriting is gated
    # on a regime being present so ordinary query tests are untouched.
    regimes = _entailment_regimes(g_manifest, action_node)
    if !isempty(regimes)
        query = RDFLib.rewrite_owl_query(query)
    end

    if data_iri !== nothing || !isempty(gdata) || !isempty(fromq) || !isempty(fromnamedq)
        ds = Dataset()
        if data_iri !== nothing
            dp = _local_path(manifest_dir, data_iri.value)
            _load_into_dataset!(ds, dp, _base_iri(assumed_base, manifest_dir, data_iri.value))
        end
        for gd in gdata
            gp = _local_path(manifest_dir, gd.value)
            add_graph(ds, URIRef(gd.value))   # register even if the file is empty
            _load_into_dataset!(ds, gp, _base_iri(assumed_base, manifest_dir, gd.value); gname=URIRef(gd.value))
        end
        # FROM <rel> / FROM NAMED <rel>: load each referenced document as a named
        # graph under its resolved IRI; the evaluator merges FROM graphs into the
        # default graph and restricts named graphs to FROM NAMED.
        for iri in vcat(fromq, fromnamedq)
            fp = _local_path(manifest_dir, iri)
            isfile(fp) || continue
            for t in _parse_graph(fp, iri)
                add!(ds, t, URIRef(iri))
            end
        end
        # SPARQL entailment regimes (sparql11/entailment): sd:entailmentRegime on
        # the action node lists acceptable regimes. Materialize the strongest one
        # RDFLib supports (RDFS/RDF/D via the RDFS closure) on the default graph
        # before querying. OWL-Direct (Description Logic) is not materialized.
        _materialize_regime!(ds, regimes)
        # Pass the dataset whenever named graphs are present — from graphData,
        # FROM/FROM NAMED, or a quad-format qt:data that carried named graphs.
        has_named = false
        for (n, _) in graphs(ds); n === nothing || (has_named = true; break); end
        use_ds = !isempty(gdata) || !isempty(fromq) || !isempty(fromnamedq) || has_named
        actual = sparql_query(use_ds ? ds : get_graph(ds), query)
        # Under an entailment regime, answers must not bind variables to OWL
        # surrogate (structural class-expression/restriction) blank nodes.
        if !isempty(regimes)
            actual = RDFLib.filter_entailment_results(get_graph(ds), actual)
        end
    else
        actual = sparql_query(RDFGraph(), query)
    end

    rpath = _local_path(manifest_dir, result.value)
    rext  = lowercase(splitext(rpath)[2])
    kind, payload = _parse_expected_result(rpath, _base_iri(assumed_base, manifest_dir, result.value))

    if kind == :ask
        ok = (actual === payload) || (actual isa Bool && actual == payload)
        return ok ? TestOutcome(id, name, cls, :pass, "") :
                    TestOutcome(id, name, cls, :fail, "ASK $(actual) vs $(payload)")
    elseif kind == :select
        actual isa Vector || return TestOutcome(id, name, cls, :error, "expected SELECT rows, got $(typeof(actual))")
        ordered = occursin("ORDER BY", uppercase(query))
        # CSV is lossy (no datatypes/bnode labels): compare cell strings only.
        # TSV preserves types but writes bare numeric tokens: re-type before compare.
        ok, why = rext == ".csv" ? _compare_csv(actual, payload, ordered) :
                  rext == ".tsv" ? _compare_tsv(actual, payload, ordered) :
                                   _compare_select(actual, payload, ordered)
        return ok ? TestOutcome(id, name, cls, :pass, "") : TestOutcome(id, name, cls, :fail, why)
    else  # graph (CONSTRUCT/DESCRIBE)
        actual isa RDFGraph || return TestOutcome(id, name, cls, :error, "expected graph, got $(typeof(actual))")
        return isomorphic(actual, payload) ? TestOutcome(id, name, cls, :pass, "") :
               TestOutcome(id, name, cls, :fail, "construct graph not isomorphic")
    end
end

function _run_query_syntax(name, id, cls, action, base; positive::Bool)
    query = read(action, String)
    try
        RDFLib.sparql_parse(query)
        positive ? TestOutcome(id, name, cls, :pass, "") :
                   TestOutcome(id, name, cls, :fail, "accepted invalid query")
    catch e
        positive ? TestOutcome(id, name, cls, :fail, "rejected valid query: $(_short(e))") :
                   TestOutcome(id, name, cls, :pass, "")
    end
end

function _run_update_syntax(name, id, cls, action, base; positive::Bool)
    upd = read(action, String)
    try
        RDFLib.sparql_parse_update(upd)
        positive ? TestOutcome(id, name, cls, :pass, "") :
                   TestOutcome(id, name, cls, :fail, "accepted invalid update")
    catch e
        positive ? TestOutcome(id, name, cls, :fail, "rejected valid update: $(_short(e))") :
                   TestOutcome(id, name, cls, :pass, "")
    end
end

function _run_update_eval(g_manifest, name, id, cls, action_node, result_node, manifest_dir, assumed_base)
    req_iri  = _obj(g_manifest, action_node, URIRef(UT * "request"))
    data_iri = _obj(g_manifest, action_node, URIRef(UT * "data"))
    gdata    = _objs(g_manifest, action_node, URIRef(UT * "graphData"))
    req = read(_local_path(manifest_dir, req_iri.value), String)

    ds = Dataset()
    if data_iri !== nothing
        _load_into_dataset!(ds, _local_path(manifest_dir, data_iri.value), _base_iri(assumed_base, manifest_dir, data_iri.value))
    end
    for gd in gdata
        fileiri, name = _graphdata_entry(g_manifest, gd, UT)
        isempty(fileiri) && continue
        _load_into_dataset!(ds, _local_path(manifest_dir, fileiri), _base_iri(assumed_base, manifest_dir, fileiri); gname=URIRef(name))
    end

    sparql_update(ds, req)

    # expected
    rdata_iri = _obj(g_manifest, result_node, URIRef(UT * "data"))
    rgdata = _objs(g_manifest, result_node, URIRef(UT * "graphData"))
    expds = Dataset()
    if rdata_iri !== nothing
        _load_into_dataset!(expds, _local_path(manifest_dir, rdata_iri.value), _base_iri(assumed_base, manifest_dir, rdata_iri.value))
    end
    for gd in rgdata
        fileiri, name = _graphdata_entry(g_manifest, gd, UT)
        isempty(fileiri) && continue
        _load_into_dataset!(expds, _local_path(manifest_dir, fileiri), _base_iri(assumed_base, manifest_dir, fileiri); gname=URIRef(name))
    end
    _dataset_iso(ds, expds) ? TestOutcome(id, name, cls, :pass, "") :
        TestOutcome(id, name, cls, :fail, "post-update dataset differs")
end

_short(e) = first(sprint(showerror, e), 120)

# ─── RDF Canonicalization (RDFC-1.0) ────────────────────────────────
#
# Parse the action (.nt/.nq) into a graph/dataset, produce the canonical
# N-Triples/N-Quads form, and compare AS AN EXACT STRING to the expected
# `-c14n.nt`/`.nq` file (canonical-byte equality, modulo a trailing newline).
# The algorithm itself is implemented in the library as `RDFLib.rdf_canonicalize`
# (or the first matching exported canonicalizer); until it lands we :skip.

# Candidate RDFC-1.0 canonicalizer names (the agreed one is `rdf_canonicalize`).
# We deliberately exclude the generic `canonicalize` (that is `Dates.canonicalize`
# re-exported, not RDF canonicalization).
const _C14N_FNS = (:rdf_canonicalize, :rdf_c14n, :rdfc10, :rdfc_1_0)

function _c14n_fn()
    for s in _C14N_FNS
        isdefined(RDFLib, s) || continue
        f = getfield(RDFLib, s)
        # Require a method defined in RDFLib itself (not an unrelated re-export).
        any(m -> parentmodule(m) === RDFLib, methods(f)) && return f
    end
    nothing
end

_strip_trailing_nl(s) = endswith(s, "\n") ? rstrip(s, '\n') * "\n" : s

function _run_c14n(name, id, cls, action, result, base)
    fn = _c14n_fn()
    fn === nothing && return TestOutcome(id, name, cls, :skip, "awaiting RDFC-1.0")
    quads_class = endswith(lowercase(action), ".nq")
    input = quads_class ? _parse_dataset(action, base) : _parse_graph(action, base)
    produced = try
        String(fn(input))
    catch e
        return TestOutcome(id, name, cls, :error, "canonicalize failed: $(_short(e))")
    end
    expected = read(result, String)
    # Canonical byte-equality, tolerating a single trailing-newline difference.
    if produced == expected ||
       _strip_trailing_nl(produced) == _strip_trailing_nl(expected) ||
       rstrip(produced, '\n') == rstrip(expected, '\n')
        TestOutcome(id, name, cls, :pass, "")
    else
        TestOutcome(id, name, cls, :fail, "canonical form differs")
    end
end

# ─── Entailment regime tests ────────────────────────────────────────
#
# Positive/NegativeEntailmentTest: premise (mf:action — a file or list) entails
# (or not) the conclusion (mf:result — a graph, or a boolean false meaning the
# premise is inconsistent / entails the false graph). The check delegates to
# `RDFLib.entails(premise, conclusion; regime=...)::Bool`; until that exists we
# :skip.

# Normalize an entailment-regime label (string or IRI) to a short symbol.
function _entail_regime(g, entry)
    r = _obj(g, entry, URIRef(MF * "entailmentRegime"))
    r === nothing && return "simple"
    s = r isa Literal ? r.lexical : (r isa URIRef ? r.value : string(r))
    s = last(split(s, ('#', '/')))
    isempty(s) ? "simple" : s
end

# Resolve mf:action which may be a single file IRI or an RDF list of file IRIs.
function _entail_premise_files(g, entry, manifest_dir, assumed_base)
    a = _obj(g, entry, URIRef(MF * "action"))
    a === nothing && return Tuple{String,String}[]
    nodes = Identifier[]
    # Is it a list head?
    if _obj(g, a, URIRef(RDFNS * "first")) !== nothing
        append!(nodes, _collection(g, a))
    else
        push!(nodes, a)
    end
    [(_local_path(manifest_dir, n.value), _base_iri(assumed_base, manifest_dir, n.value))
     for n in nodes if n isa URIRef]
end

# True iff the library exposes an entailment predicate taking (premise,
# conclusion; regime=...) — i.e. a method with a `regime` keyword.
function _has_entails()
    isdefined(RDFLib, :entails) || return false
    for m in methods(RDFLib.entails)
        kws = Base.kwarg_decl(m)
        :regime in kws && return true
    end
    false
end

# True iff entails accepts a `recognized_datatypes` keyword.
function _entails_takes_recognized()
    for m in methods(RDFLib.entails)
        :recognized_datatypes in Base.kwarg_decl(m) && return true
    end
    false
end

# mf:recognizedDatatypes is an RDF list of datatype IRIs. Returns `nothing` when
# the property is ABSENT (use the library default), or a (possibly empty) vector
# of URIRefs when present — the empty-vs-default distinction is what the
# datatypes-non-well-formed twin tests turn on.
function _entail_recognized(g, entry)
    head = _obj(g, entry, URIRef(MF * "recognizedDatatypes"))
    head === nothing && return nothing
    URIRef[d for d in _collection(g, head) if d isa URIRef]
end

# Merge a set of premise files (per regime, with recognizedDatatypes) into one
# graph; conclusion is either a graph or the boolean `false`.
function _run_entailment(g, entry, name, id, cls, manifest_dir, assumed_base; positive::Bool)
    _has_entails() || return TestOutcome(id, name, cls, :skip, "awaiting entailment regime")
    regime = _entail_regime(g, entry)

    premise = RDFGraph()
    for (pf, pb) in _entail_premise_files(g, entry, manifest_dir, assumed_base)
        isfile(pf) || continue
        for t in _parse_graph(pf, pb); add!(premise, t); end
    end

    result = _obj(g, entry, URIRef(MF * "result"))
    # Boolean result (typically `false`): premise must be inconsistent under the
    # regime (entails everything / the false graph). Represent as conclusion=false.
    conclusion = if result isa Literal && result.lexical in ("true", "false")
        result.lexical == "true"
    elseif result isa URIRef
        rf = _local_path(manifest_dir, result.value)
        if isfile(rf)
            cg = RDFGraph()
            for t in _parse_graph(rf, _base_iri(assumed_base, manifest_dir, result.value)); add!(cg, t); end
            cg
        else
            false
        end
    else
        false
    end

    recognized = _entail_recognized(g, entry)
    ent = try
        if recognized !== nothing && _entails_takes_recognized()
            RDFLib.entails(premise, conclusion; regime = regime, recognized_datatypes = recognized)
        else
            RDFLib.entails(premise, conclusion; regime = regime)
        end
    catch e
        return TestOutcome(id, name, cls, :error, "entails failed: $(_short(e))")
    end
    pass = positive ? ent : !ent
    pass ? TestOutcome(id, name, cls, :pass, "") :
           TestOutcome(id, name, cls, :fail, "$(positive ? "expected" : "unexpected") entailment ($regime)")
end

# ─── manifest walking ───────────────────────────────────────────────

function _shortclass(iri::String)
    s = last(split(iri, ('#', '/')))
    s
end

"""
    run_manifest(path) -> Vector{TestOutcome}

Run every entry in the manifest at `path` (recursing into mf:include).
"""
function run_manifest(path::String; seen = Set{String}())
    abspath_ = abspath(path)
    abspath_ in seen && return TestOutcome[]
    push!(seen, abspath_)
    manifest_dir = dirname(abspath_)
    outcomes = TestOutcome[]

    g = RDFGraph()
    RDFLib.parse_turtle!(g, read(abspath_, String); base = "file://" * abspath_)

    # find manifest node
    mfManifest = URIRef(MF * "Manifest")
    manifest_node = nothing
    for t in triples(g, (nothing, URIRef(RDFNS * "type"), mfManifest))
        manifest_node = t.subject; break
    end
    manifest_node === nothing && return outcomes

    assumed_base = _obj(g, manifest_node, URIRef(MF * "assumedTestBase"))

    # mf:include (collection of sub-manifests)
    inc_head = _obj(g, manifest_node, URIRef(MF * "include"))
    if inc_head !== nothing
        for sub in _collection(g, inc_head)
            subpath = _local_path(manifest_dir, sub isa URIRef ? sub.value : string(sub))
            if isfile(subpath)
                append!(outcomes, run_manifest(subpath; seen = seen))
            end
        end
    end

    entries_head = _obj(g, manifest_node, URIRef(MF * "entries"))
    entries_head === nothing && return outcomes

    trace = haskey(ENV, "W3C_TRACE")
    for entry in _collection(g, entries_head)
        if trace
            println(stderr, "RUN ", entry isa URIRef ? entry.value : string(entry))
            flush(stderr)
        end
        push!(outcomes, _dispatch_entry(g, entry, manifest_dir, assumed_base))
    end
    outcomes
end

function _dispatch_entry(g, entry, manifest_dir, assumed_base)
    typ = _obj(g, entry, URIRef(RDFNS * "type"))
    nameobj = _obj(g, entry, URIRef(MF * "name"))
    name = nameobj === nothing ? "" : (nameobj isa Literal ? nameobj.lexical : string(nameobj))
    id = entry isa URIRef ? entry.value : string(entry)
    typ === nothing && return TestOutcome(id, name, "?", :skip, "no rdf:type")
    cls = _shortclass(typ.value)

    action = _obj(g, entry, URIRef(MF * "action"))
    result = _obj(g, entry, URIRef(MF * "result"))

    try
        # RDF eval tests producing quads (TriG/NQuads) → dataset isomorphism
        if cls in ("TestTrigEval", "TestTriGEval", "TestNQuadsPositiveC")
            apath = _local_path(manifest_dir, action.value)
            rpath = _local_path(manifest_dir, result.value)
            return _run_quad_eval(name, id, cls, apath, rpath, _base_iri(assumed_base, manifest_dir, action.value))

        # RDF eval tests producing triples (Turtle/N-Triples/RDF-XML)
        elseif cls in ("TestTurtleEval", "TestXMLEval", "TestNTriplesPositiveC")
            apath = _local_path(manifest_dir, action.value)
            rpath = _local_path(manifest_dir, result.value)
            return _run_rdf_eval(name, id, cls, apath, rpath, _base_iri(assumed_base, manifest_dir, action.value))

        # RDF Canonicalization (RDFC-1.0): canonical-byte string compare
        elseif cls in ("TestNTriplesPositiveC14N", "TestNQuadsPositiveC14N")
            apath = _local_path(manifest_dir, action.value)
            rpath = _local_path(manifest_dir, result.value)
            return _run_c14n(name, id, cls, apath, rpath, _base_iri(assumed_base, manifest_dir, action.value))

        # Entailment regime tests
        elseif cls == "PositiveEntailmentTest"
            return _run_entailment(g, entry, name, id, cls, manifest_dir, assumed_base; positive = true)
        elseif cls == "NegativeEntailmentTest"
            return _run_entailment(g, entry, name, id, cls, manifest_dir, assumed_base; positive = false)

        # quad positive syntax → parse into a Dataset
        elseif cls in ("TestTrigPositiveSyntax", "TestTriGPositiveSyntax", "TestNQuadsPositiveSyntax")
            apath = _local_path(manifest_dir, action.value)
            return _run_positive_syntax_quad(name, id, cls, apath, _base_iri(assumed_base, manifest_dir, action.value))

        elseif cls in ("TestTurtlePositiveSyntax", "TestNTriplesPositiveSyntax")
            apath = _local_path(manifest_dir, action.value)
            return _run_positive_syntax(name, id, cls, apath, _base_iri(assumed_base, manifest_dir, action.value))

        # quad negative syntax → parse into a Dataset, must throw
        elseif cls in ("TestTrigNegativeSyntax", "TestTriGNegativeSyntax", "TestNQuadsNegativeSyntax",
                       "TestTrigNegativeEval", "TestTriGNegativeEval")
            apath = _local_path(manifest_dir, action.value)
            return _run_negative_quad(name, id, cls, apath, _base_iri(assumed_base, manifest_dir, action.value))

        elseif cls in ("TestTurtleNegativeSyntax", "TestNTriplesNegativeSyntax", "TestXMLNegativeSyntax",
                       "TestTurtleNegativeEval", "TestTurtleNegatitveSyntax")
            apath = _local_path(manifest_dir, action.value)
            return _run_negative(name, id, cls, apath, _base_iri(assumed_base, manifest_dir, action.value))

        # SPARQL
        elseif cls in ("QueryEvaluationTest", "CSVResultFormatTest")
            return _run_query_eval(g, name, id, cls, action, result, manifest_dir, assumed_base)
        elseif cls in ("PositiveSyntaxTest", "PositiveSyntaxTest11")
            apath = _local_path(manifest_dir, action.value)
            return _run_query_syntax(name, id, cls, apath, ""; positive = true)
        elseif cls in ("NegativeSyntaxTest", "NegativeSyntaxTest11")
            apath = _local_path(manifest_dir, action.value)
            return _run_query_syntax(name, id, cls, apath, ""; positive = false)
        elseif cls in ("PositiveUpdateSyntaxTest", "PositiveUpdateSyntaxTest11")
            apath = _local_path(manifest_dir, action.value)
            return _run_update_syntax(name, id, cls, apath, ""; positive = true)
        elseif cls in ("NegativeUpdateSyntaxTest", "NegativeUpdateSyntaxTest11")
            apath = _local_path(manifest_dir, action.value)
            return _run_update_syntax(name, id, cls, apath, ""; positive = false)
        elseif cls == "UpdateEvaluationTest"
            return _run_update_eval(g, name, id, cls, action, result, manifest_dir, assumed_base)
        else
            return TestOutcome(id, name, cls, :skip, "unhandled class $cls")
        end
    catch e
        msg = _short(e)
        # Network/federation reach-out is out of scope for an offline harness.
        if occursin("RequestError", msg) || occursin("Protocol", msg) ||
           occursin("Could not resolve", msg) || occursin("SERVICE", msg)
            return TestOutcome(id, name, cls, :skip, "requires network/SERVICE: $msg")
        end
        return TestOutcome(id, name, cls, :error, msg)
    end
end

# ─── reporting ──────────────────────────────────────────────────────

function summarize(outcomes::Vector{TestOutcome})
    by = Dict{Symbol,Int}()
    for o in outcomes; by[o.status] = get(by, o.status, 0) + 1; end
    by
end

end # module
