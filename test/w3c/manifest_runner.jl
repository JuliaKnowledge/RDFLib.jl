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

# Parse possibly-quad data (.nq/.trig) into a Dataset.
function _parse_dataset(path::String, base::String)
    fmt = _format_for(path)
    ds = Dataset()
    txt = read(path, String)
    if fmt isa NQuadsFormat
        RDFLib.parse_nquads!(ds, txt)
    elseif fmt isa TriGFormat
        RDFLib.parse_trig!(ds, txt)
    else
        g = _parse_graph(path, base)
        for t in g
            add!(ds, t)
        end
    end
    ds
end

# ─── result-set comparison (SELECT/ASK) ─────────────────────────────

# Canonicalize a row to a comparable, blank-node-blind key. Blank nodes are
# replaced by a structural placeholder so two result sets that differ only in
# bnode labels still compare equal in the common (≤ trivial bnode) cases.
function _row_key(row::Dict{String,Identifier})
    parts = String[]
    for k in sort(collect(keys(row)))
        v = row[k]
        token = v isa BNode ? "_:bnode" : _term_token(v)
        push!(parts, k * "=" * token)
    end
    join(parts, "")
end

function _term_token(v::Identifier)
    if v isa URIRef
        return "U:" * v.value
    elseif v isa BNode
        return "B"
    else  # Literal
        lex = v.lexical
        dt = RDFLib.datatype(v)
        lang = v.language
        dts = dt === nothing ? "" : dt.value
        return string("L:", lex, "|", dts, "|", lang === nothing ? "" : lang)
    end
end

_bag(rows) = begin
    d = Dict{String,Int}()
    for r in rows
        k = _row_key(r)
        d[k] = get(d, k, 0) + 1
    end
    d
end

function _compare_select(actual::Vector{Dict{String,Identifier}}, expected::Vector{Dict{String,Identifier}}, ordered::Bool)
    if ordered
        length(actual) == length(expected) || return (false, "row count $(length(actual)) vs $(length(expected))")
        for i in eachindex(actual)
            _row_key(actual[i]) == _row_key(expected[i]) || return (false, "row $i differs")
        end
        return (true, "")
    else
        _bag(actual) == _bag(expected) ? (true, "") :
            (false, "result bags differ ($(length(actual)) vs $(length(expected)) rows)")
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

# Pragmatic dataset isomorphism: default graphs isomorphic, same set of named
# graph names, each named graph pairwise isomorphic. (Does not model a single
# blank-node bijection shared across graphs; rare cross-graph-bnode tests that
# fail spuriously are recorded in the known-failures list.)
function _dataset_iso(a::Dataset, b::Dataset)
    isomorphic(get_graph(a), get_graph(b)) || return false
    na = Dict{String,RDFGraph}(); nb = Dict{String,RDFGraph}()
    for (n, g) in graphs(a); n === nothing || (na[string(n)] = g); end
    for (n, g) in graphs(b); n === nothing || (nb[string(n)] = g); end
    keys(na) == keys(nb) || return false
    for (k, g) in na
        isomorphic(g, nb[k]) || return false
    end
    true
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

function _run_query_eval(g_manifest, name, id, cls, action_node, result, manifest_dir, assumed_base)
    query_iri = _obj(g_manifest, action_node, URIRef(QT * "query"))
    data_iri  = _obj(g_manifest, action_node, URIRef(QT * "data"))
    gdata     = _objs(g_manifest, action_node, URIRef(QT * "graphData"))

    qpath = _local_path(manifest_dir, query_iri.value)
    query = read(qpath, String)

    if data_iri !== nothing || !isempty(gdata)
        ds = Dataset()
        if data_iri !== nothing
            dp = _local_path(manifest_dir, data_iri.value)
            for t in _parse_graph(dp, _base_iri(assumed_base, manifest_dir, data_iri.value)); add!(ds, t); end
        end
        for gd in gdata
            gp = _local_path(manifest_dir, gd.value)
            for t in _parse_graph(gp, _base_iri(assumed_base, manifest_dir, gd.value))
                add!(ds, t, URIRef(gd.value))
            end
        end
        # Query the default graph unless named graphs are present; then pass dataset.
        actual = sparql_query(isempty(gdata) ? get_graph(ds) : ds, query)
    else
        actual = sparql_query(RDFGraph(), query)
    end

    rpath = _local_path(manifest_dir, result.value)
    kind, payload = _parse_expected_result(rpath, _base_iri(assumed_base, manifest_dir, result.value))

    if kind == :ask
        ok = (actual === payload) || (actual isa Bool && actual == payload)
        return ok ? TestOutcome(id, name, cls, :pass, "") :
                    TestOutcome(id, name, cls, :fail, "ASK $(actual) vs $(payload)")
    elseif kind == :select
        actual isa Vector || return TestOutcome(id, name, cls, :error, "expected SELECT rows, got $(typeof(actual))")
        ordered = occursin("ORDER BY", uppercase(query))
        ok, why = _compare_select(actual, payload, ordered)
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
        for t in _parse_graph(_local_path(manifest_dir, data_iri.value), _base_iri(assumed_base, manifest_dir, data_iri.value)); add!(ds, t); end
    end
    for gd in gdata
        fileiri, name = _graphdata_entry(g_manifest, gd, UT)
        isempty(fileiri) && continue
        for t in _parse_graph(_local_path(manifest_dir, fileiri), _base_iri(assumed_base, manifest_dir, fileiri))
            add!(ds, t, URIRef(name))
        end
    end

    sparql_update(ds, req)

    # expected
    rdata_iri = _obj(g_manifest, result_node, URIRef(UT * "data"))
    rgdata = _objs(g_manifest, result_node, URIRef(UT * "graphData"))
    expds = Dataset()
    if rdata_iri !== nothing
        for t in _parse_graph(_local_path(manifest_dir, rdata_iri.value), _base_iri(assumed_base, manifest_dir, rdata_iri.value)); add!(expds, t); end
    end
    for gd in rgdata
        fileiri, name = _graphdata_entry(g_manifest, gd, UT)
        isempty(fileiri) && continue
        for t in _parse_graph(_local_path(manifest_dir, fileiri), _base_iri(assumed_base, manifest_dir, fileiri))
            add!(expds, t, URIRef(name))
        end
    end
    _dataset_iso(ds, expds) ? TestOutcome(id, name, cls, :pass, "") :
        TestOutcome(id, name, cls, :fail, "post-update dataset differs")
end

_short(e) = first(sprint(showerror, e), 120)

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
        elseif cls == "QueryEvaluationTest"
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
