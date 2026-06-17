# W3C SPARQL Protocol / Graph Store Protocol / Service Description runner.
#
# Starts a live `SparqlServer` on an ephemeral localhost port and replays the
# official W3C HTTP-in-RDF protocol test manifests against it over real HTTP,
# checking each `ht:Response` against `mf:expectedStatus` / `mf:expectedBoolean`
# / `mf:expectedFormat`.
#
# Vocabulary:
#   ht:  = http://www.w3.org/2011/http#
#   hts: = http://www.w3.org/2011/http-statusCodes#
#   cnt: = http://www.w3.org/2011/content#
#   mf:  = http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#
#   ut:  = http://www.w3.org/2009/sparql/tests/test-update#
#
# Each test yields a TestOutcome (:pass / :fail / :error / :skip). The runner
# never throws on an individual test.

module ProtocolHarness

using RDFLib
using HTTP
using Sockets

const MF   = "http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#"
const HT   = "http://www.w3.org/2011/http#"
const HTS  = "http://www.w3.org/2011/http-statusCodes#"
const CNT  = "http://www.w3.org/2011/content#"
const UT   = "http://www.w3.org/2009/sparql/tests/test-update#"
const RDFS = "http://www.w3.org/2000/01/rdf-schema#"
const RDFNS = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

struct TestOutcome
    id::String
    name::String
    type::String
    status::Symbol
    detail::String
end

# ─── small graph query helpers ──────────────────────────────────────

_obj(g, s, p) = begin
    for t in triples(g, (s, p, nothing)); return t.object; end
    nothing
end
_objs(g, s, p) = Identifier[t.object for t in triples(g, (s, p, nothing))]

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

_str(x) = x isa Literal ? x.lexical : x isa URIRef ? x.value : string(x)

# ─── status code classes ────────────────────────────────────────────

# Map an hts: status IRI to a predicate over an actual integer status code.
function _status_matches(hts_iri::String, status::Integer)::Bool
    name = replace(hts_iri, HTS => "")
    if name == "StatusCode2xx"; return 200 <= status < 300
    elseif name == "StatusCode3xx"; return 300 <= status < 400
    elseif name == "StatusCode4xx"; return 400 <= status < 500
    elseif name == "StatusCode5xx"; return 500 <= status < 600
    elseif name == "OK"; return status == 200
    elseif name == "Created"; return status == 201
    elseif name == "NoContent"; return status == 204
    elseif name == "NotFound"; return status == 404
    elseif name == "Conflict"; return status == 409
    elseif name == "BadRequest"; return status == 400
    end
    # Unknown — be lenient
    return false
end

# ─── manifest entry extraction ──────────────────────────────────────

struct ReqSpec
    method::String
    path::String
    headers::Vector{Pair{String,String}}
    body::Union{String,Nothing}
    body_encoding::String
    expected_status::Vector{String}     # hts: IRIs
    expected_boolean::Union{Bool,Nothing}
    expected_format::Union{String,Nothing}
    expected_location::Union{String,Nothing}
end

struct ProtoTest
    id::String
    name::String
    type::String
    graph_data::Vector{Tuple{String,String}}  # (file path, graph IRI label)
    requests::Vector{ReqSpec}
end

function _parse_requests(g, list_head)
    reqs = ReqSpec[]
    for rnode in _collection(g, list_head)
        method = _str(something(_obj(g, rnode, URIRef(HT * "methodName")), Literal("GET")))
        path   = _str(something(_obj(g, rnode, URIRef(HT * "absolutePath")), Literal("/")))

        headers = Pair{String,String}[]
        hlist = _obj(g, rnode, URIRef(HT * "headers"))
        if hlist !== nothing
            for hn in _collection(g, hlist)
                fn = _obj(g, hn, URIRef(HT * "fieldName"))
                fv = _obj(g, hn, URIRef(HT * "fieldValue"))
                (fn !== nothing && fv !== nothing) && push!(headers, _str(fn) => _str(fv))
            end
        end

        body = nothing; benc = "UTF-8"
        bnode = _obj(g, rnode, URIRef(HT * "body"))
        if bnode !== nothing
            cnode = _obj(g, bnode, URIRef(CNT * "chars"))
            body = cnode === nothing ? nothing : _str(cnode)
            enc = _obj(g, bnode, URIRef(CNT * "characterEncoding"))
            enc !== nothing && (benc = _str(enc))
        end

        resp = _obj(g, rnode, URIRef(HT * "resp"))
        estatus = String[]; ebool = nothing; efmt = nothing; eloc = nothing
        if resp !== nothing
            for s in _objs(g, resp, URIRef(MF * "expectedStatus"))
                push!(estatus, _str(s))
            end
            b = _obj(g, resp, URIRef(MF * "expectedBoolean"))
            b !== nothing && (ebool = lowercase(_str(b)) == "true")
            f = _obj(g, resp, URIRef(MF * "expectedFormat"))
            f !== nothing && (efmt = _str(f))
            l = _obj(g, resp, URIRef(MF * "expectedLocation"))
            l !== nothing && (eloc = _str(l))
        end
        push!(reqs, ReqSpec(method, path, headers, body, benc, estatus, ebool, efmt, eloc))
    end
    reqs
end

function _parse_proto_test(g, tnode, manifest_dir::String)
    id = tnode isa URIRef ? tnode.value : string(tnode)
    name_o = _obj(g, tnode, URIRef(MF * "name"))
    name = name_o === nothing ? id : _str(name_o)
    type_o = _obj(g, tnode, URIRef(RDFNS * "type"))
    type = type_o === nothing ? "" : replace(_str(type_o), MF => "")

    # ut:graphData — (file, graph IRI label)
    gdata = Tuple{String,String}[]
    for gd in _objs(g, tnode, URIRef(UT * "graphData"))
        gf = _obj(g, gd, URIRef(UT * "graph"))
        lbl = _obj(g, gd, URIRef(RDFS * "label"))
        gf === nothing && continue
        fpath = _str(gf)
        if startswith(fpath, "file://"); fpath = fpath[8:end]
        elseif !occursin("://", fpath); fpath = normpath(joinpath(manifest_dir, fpath)); end
        push!(gdata, (fpath, lbl === nothing ? "" : _str(lbl)))
    end

    action = _obj(g, tnode, URIRef(MF * "action"))
    reqs = ReqSpec[]
    if action !== nothing
        rlist = _obj(g, action, URIRef(HT * "requests"))
        rlist !== nothing && (reqs = _parse_requests(g, rlist))
    end
    ProtoTest(id, name, type, gdata, reqs)
end

# Collect mf:entries, following mf:include for sub-manifests.
function _load_entries(path::String)
    base = "file://" * abspath(path)
    g = RDFGraph()
    RDFLib.parse_turtle!(g, read(path, String); base = base)
    mdir = dirname(abspath(path))
    # find manifest node
    manifest = nothing
    for t in triples(g, (nothing, URIRef(RDFNS * "type"), URIRef(MF * "Manifest")))
        manifest = t.subject; break
    end
    tests = ProtoTest[]
    manifest === nothing && return tests
    # includes
    inc = _obj(g, manifest, URIRef(MF * "include"))
    if inc !== nothing
        for sub in _collection(g, inc)
            subpath = sub isa URIRef ? sub.value : string(sub)
            startswith(subpath, "file://") && (subpath = subpath[8:end])
            occursin("://", subpath) || (subpath = normpath(joinpath(mdir, subpath)))
            isfile(subpath) && append!(tests, _load_entries(subpath))
        end
    end
    # entries
    ent = _obj(g, manifest, URIRef(MF * "entries"))
    if ent !== nothing
        for tnode in _collection(g, ent)
            push!(tests, _parse_proto_test(g, tnode, mdir))
        end
    end
    tests
end

# ─── server setup ───────────────────────────────────────────────────

function _free_port()
    s = Sockets.listen(Sockets.localhost, 0)
    p = Sockets.getsockname(s)[2]
    close(s)
    Int(p)
end

# Load each ut:graphData file into the protocol dataset as a named graph
# (keyed by its rdfs:label graph IRI), so default-graph-uri / named-graph-uri
# can build the query dataset view.
function _load_graph_data!(ep, gdata)
    for (fpath, label) in gdata
        isfile(fpath) || continue
        isempty(label) && continue
        g = RDFGraph()
        try
            parse_rdf!(g, read(fpath, String), NTriplesFormat())
        catch
            continue
        end
        name = URIRef(label)
        target = add_graph(ep.dataset, name)
        for t in triples(g); add!(target, t); end
    end
end

# ─── request replay ─────────────────────────────────────────────────

# Build the bytes for a request body given its declared character encoding.
function _encode_body(body::String, enc::String)
    e = lowercase(enc)
    if e == "utf-8" || e == "utf8" || isempty(e)
        return Vector{UInt8}(body)
    elseif e == "utf-16"
        return reinterpret(UInt8, transcode(UInt16, body)) |> collect
    else
        return Vector{UInt8}(body)
    end
end

# Replace template variables (e.g. $LOCATION$) in a string.
_subst(s::String, vars::Dict{String,String}) = begin
    out = s
    for (k, v) in vars; out = replace(out, k => v); end
    out
end

function _run_test(t::ProtoTest, server, base_url::String)
    # Reset protocol dataset before each test for isolation.
    ep = get_dataset(server, server.protocol_dataset)
    lock(ep.lock) do
        remove!(ep.dataset.default_graph, (nothing, nothing, nothing))
        empty!(ep.dataset.named_graphs)
    end
    _load_graph_data!(ep, t.graph_data)

    vars = Dict{String,String}()
    for (i, rs) in enumerate(t.requests)
        path = _subst(rs.path, vars)
        url = base_url * path
        hdrs = Pair{String,String}[]
        for (k, v) in rs.headers
            push!(hdrs, k => _subst(v, vars))
        end
        body = rs.body === nothing ? UInt8[] : _encode_body(_subst(rs.body, vars), rs.body_encoding)

        # A pooled keep-alive connection can occasionally be reset between
        # requests (e.g. after an empty-body 201/204). Retry once on a *transport*
        # error — but only for the safe/idempotent GET and HEAD methods, since a
        # blind retry of a PUT/POST/DELETE could change observable state (e.g.
        # turning a 201-Created into a 204 on the second hit). For unsafe methods
        # we close idle pooled connections first to avoid reusing a stale socket.
        if rs.method in ("PUT", "POST", "DELETE")
            try; HTTP.Connections.closeall(); catch; end
        end
        local resp
        local lasterr = nothing
        local attempts = rs.method in ("GET", "HEAD") ? 2 : 1
        for attempt in 1:attempts
            try
                resp = HTTP.request(rs.method, url, hdrs, body;
                                    status_exception=false, redirect=false,
                                    retry=false, connect_timeout=10, readtimeout=20)
                lasterr = nothing
                break
            catch e
                lasterr = e
                sleep(0.05)
            end
        end
        if lasterr !== nothing
            return TestOutcome(t.id, t.name, t.type, :error,
                               "request $i ($(rs.method) $path) failed: $(sprint(showerror, lasterr))")
        end

        status = resp.status
        # expected status
        if !isempty(rs.expected_status)
            if !any(s -> _status_matches(s, status), rs.expected_status)
                return TestOutcome(t.id, t.name, t.type, :fail,
                    "request $i: status $status not in {$(join(rs.expected_status, ", "))}")
            end
        end

        rbody = String(resp.body)
        rct = ""
        for (k, v) in resp.headers
            lowercase(k) == "content-type" && (rct = lowercase(v))
        end

        # expected boolean (ASK result)
        if rs.expected_boolean !== nothing
            got = _parse_ask_boolean(rbody, rct)
            if got === nothing
                return TestOutcome(t.id, t.name, t.type, :fail,
                    "request $i: could not parse boolean from response ($(first(rbody, 80)))")
            elseif got != rs.expected_boolean
                return TestOutcome(t.id, t.name, t.type, :fail,
                    "request $i: expected boolean $(rs.expected_boolean), got $got")
            end
        end

        # expected format
        if rs.expected_format !== nothing
            ok = _format_ok(rs.expected_format, rbody, rct)
            if !ok
                return TestOutcome(t.id, t.name, t.type, :fail,
                    "request $i: response not valid $(rs.expected_format) (ct=$rct)")
            end
        end

        # expected location → template variable
        if rs.expected_location !== nothing
            loc = ""
            for (k, v) in resp.headers
                lowercase(k) == "location" && (loc = v)
            end
            isempty(loc) && return TestOutcome(t.id, t.name, t.type, :fail,
                "request $i: expected Location header, none present")
            vars[rs.expected_location] = loc
        end
    end
    TestOutcome(t.id, t.name, t.type, :pass, "")
end

# Parse an ASK boolean from a SPARQL results document.
function _parse_ask_boolean(body::String, ct::String)
    b = lowercase(strip(body))
    if occursin("json", ct) || startswith(b, "{")
        m = match(r"\"boolean\"\s*:\s*(true|false)", body)
        m !== nothing && return m.captures[1] == "true"
    end
    if occursin("xml", ct) || occursin("<sparql", b)
        m = match(r"<boolean>\s*(true|false)\s*</boolean>", body)
        m !== nothing && return m.captures[1] == "true"
    end
    # plain text fallback
    b == "true" && return true
    b == "false" && return false
    nothing
end

# Validate that the response is a SPARQL results doc of the expected kind.
function _format_ok(fmt::String, body::String, ct::String)
    if fmt == "boolean"
        return _parse_ask_boolean(body, ct) !== nothing
    elseif fmt == "tabular"
        # SELECT results: XML / JSON / CSV / TSV
        return occursin("sparql-results", ct) || occursin("text/csv", ct) ||
               occursin("tab-separated", ct) || occursin("json", ct) ||
               occursin("<sparql", lowercase(body)) || occursin("\"results\"", body)
    elseif fmt == "RDF"
        # CONSTRUCT / DESCRIBE: any RDF serialization. Try to parse turtle.
        if occursin("turtle", ct) || occursin("n-triples", ct) || occursin("rdf+xml", ct) ||
           occursin("ld+json", ct) || occursin("n3", ct)
            return true
        end
        # last resort: try parsing as turtle
        try
            parse_rdf(body, TurtleFormat())
            return true
        catch
            return false
        end
    end
    true
end

# ─── public entry point ─────────────────────────────────────────────

function run_manifest(path::String)
    tests = _load_entries(path)
    outs = TestOutcome[]
    isempty(tests) && return outs

    port = _free_port()
    server = SparqlServer(host="127.0.0.1", port=port, verbose=false,
                          protocol_dataset="protocol")
    add_dataset!(server, "protocol")
    base_url = "http://127.0.0.1:$port"

    serve!(server; background=true)
    # wait for the server to come up
    up = false
    for _ in 1:100
        try
            r = HTTP.get("$base_url/sparql?query=" * HTTP.URIs.escapeuri("ASK {}");
                         status_exception=false, retry=false, connect_timeout=2)
            up = true; break
        catch
            sleep(0.05)
        end
    end
    try
        if !up
            for t in tests
                push!(outs, TestOutcome(t.id, t.name, t.type, :error, "server failed to start"))
            end
            return outs
        end
        for t in tests
            if isempty(t.requests) && t.type == "ServiceDescriptionTest"
                push!(outs, _run_service_description(t, server, base_url))
            elseif isempty(t.requests)
                push!(outs, TestOutcome(t.id, t.name, t.type, :skip, "no requests in manifest entry"))
            else
                push!(outs, _run_test(t, server, base_url))
            end
        end
    finally
        try; stop!(server); catch; end
    end
    outs
end

# Service Description tests have no ht:requests; we issue a GET on /sparql and
# inspect the returned RDF for an sd:endpoint triple.
function _run_service_description(t::ProtoTest, server, base_url::String)
    local resp
    try
        resp = HTTP.get("$base_url/sparql", ["Accept" => "text/turtle"];
                        status_exception=false, retry=false)
    catch e
        return TestOutcome(t.id, t.name, t.type, :error, sprint(showerror, e))
    end
    if t.name == "GET on endpoint returns RDF" || occursin("returns RDF", t.name)
        # status 2xx and parseable RDF
        (200 <= resp.status < 300) || return TestOutcome(t.id, t.name, t.type, :fail, "status $(resp.status)")
        g = try
            parse_rdf(String(resp.body), TurtleFormat())
        catch e
            return TestOutcome(t.id, t.name, t.type, :fail, "response not RDF: $(sprint(showerror, e))")
        end
        return TestOutcome(t.id, t.name, t.type, :pass, "")
    elseif occursin("sd:endpoint", t.name) || occursin("endpoint triple", t.name)
        g = try
            parse_rdf(String(resp.body), TurtleFormat())
        catch e
            return TestOutcome(t.id, t.name, t.type, :fail, "response not RDF")
        end
        has = false
        for tr in triples(g, (nothing, URIRef("http://www.w3.org/ns/sparql-service-description#endpoint"), nothing))
            has = true; break
        end
        return has ? TestOutcome(t.id, t.name, t.type, :pass, "") :
                     TestOutcome(t.id, t.name, t.type, :fail, "no sd:endpoint triple")
    elseif occursin("conforms to schema", t.name)
        # Lightweight schema check: must declare an sd:Service.
        g = try
            parse_rdf(String(resp.body), TurtleFormat())
        catch
            return TestOutcome(t.id, t.name, t.type, :fail, "response not RDF")
        end
        has = false
        for tr in triples(g, (nothing, URIRef(RDFNS * "type"), URIRef("http://www.w3.org/ns/sparql-service-description#Service")))
            has = true; break
        end
        return has ? TestOutcome(t.id, t.name, t.type, :pass, "") :
                     TestOutcome(t.id, t.name, t.type, :fail, "no sd:Service typed node")
    end
    TestOutcome(t.id, t.name, t.type, :skip, "unrecognized service description test")
end

function summarize(outcomes::Vector{TestOutcome})
    by = Dict{Symbol,Int}()
    for o in outcomes; by[o.status] = get(by, o.status, 0) + 1; end
    by
end

end # module
