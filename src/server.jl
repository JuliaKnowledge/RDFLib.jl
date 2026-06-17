# ─── RDFLib.jl SPARQL/N3 Server ──────────────────────────────────
# A high-performance SPARQL 1.1/1.2 and Notation3 server built on HTTP.jl,
# inspired by Apache Jena Fuseki but with native Jelly, N3 reasoning, and
# SHACL validation support.
#
# Endpoints (per dataset):
#   GET/POST  /<ds>/sparql    — SPARQL query
#   POST      /<ds>/update    — SPARQL update
#   GET/PUT/POST/DELETE /<ds>/data — Graph Store Protocol (GSP)
#   POST      /<ds>/upload    — File upload (any RDF format + Jelly)
#   POST      /<ds>/reason    — N3 reasoning
#   POST      /<ds>/shacl     — SHACL validation
#   GET       /<ds>/            — Dataset info
#
# Admin endpoints:
#   GET       /$/datasets     — List datasets
#   POST      /$/datasets     — Create dataset
#   DELETE    /$/datasets/<ds> — Delete dataset
#   GET       /$/server       — Server info
#   GET       /$/ping         — Health check
#
# Content types supported:
#   text/turtle, application/n-triples, application/rdf+xml,
#   application/ld+json, application/trig, application/n-quads,
#   text/n3, application/x-jelly-rdf (Jelly binary),
#   application/sparql-results+json, application/sparql-results+xml,
#   text/csv, text/tab-separated-values

using HTTP
using Dates

# ─── Server State ─────────────────────────────────────────────────

mutable struct DatasetEndpoint
    name::String
    dataset::Dataset
    lock::ReentrantLock
    query_count::Int
    update_count::Int
    created_at::DateTime
end

function DatasetEndpoint(name::String; store_factory::Union{Function, Nothing}=nothing)
    DatasetEndpoint(name, Dataset(), ReentrantLock(), 0, 0, now(UTC))
end

mutable struct SparqlServer
    host::String
    port::Int
    datasets::Dict{String, DatasetEndpoint}
    datasets_lock::ReentrantLock
    server::Union{HTTP.Server, Nothing}
    started_at::Union{DateTime, Nothing}
    verbose::Bool
    store_factory::Union{Function, Nothing}  # default store factory for new datasets
    # Optional top-level protocol endpoints (W3C SPARQL Protocol / Graph Store
    # Protocol conformance). When set, `/sparql` (query+update) and `/gsp`
    # (graph store) at the server root are served by the named dataset.
    protocol_dataset::Union{String, Nothing}
end

function SparqlServer(;
    host::String="0.0.0.0",
    port::Int=3330,
    verbose::Bool=true,
    store_factory::Union{Function, Nothing}=nothing,
    protocol_dataset::Union{String, Nothing}=nothing,
)
    SparqlServer(host, port, Dict{String,DatasetEndpoint}(), ReentrantLock(), nothing, nothing, verbose, store_factory, protocol_dataset)
end

# ─── Content Type Constants ───────────────────────────────────────

const CT_TURTLE        = "text/turtle"
const CT_NTRIPLES      = "application/n-triples"
const CT_NQUADS        = "application/n-quads"
const CT_RDFXML        = "application/rdf+xml"
const CT_TRIG          = "application/trig"
const CT_JSONLD        = "application/ld+json"
const CT_N3            = "text/n3"
const CT_JELLY         = "application/x-jelly-rdf"
const CT_SPARQL_QUERY  = "application/sparql-query"
const CT_SPARQL_UPDATE = "application/sparql-update"
const CT_FORM          = "application/x-www-form-urlencoded"
const CT_RESULTS_JSON  = "application/sparql-results+json"
const CT_RESULTS_XML   = "application/sparql-results+xml"
const CT_CSV           = "text/csv"
const CT_TSV           = "text/tab-separated-values"
const CT_JSON          = "application/json"
const CT_HTML          = "text/html"
const CT_TEXT          = "text/plain"

# Ordered by preference for content negotiation
const RDF_CONTENT_TYPES = [
    CT_TURTLE, CT_JSONLD, CT_NTRIPLES, CT_RDFXML, CT_TRIG, CT_NQUADS, CT_N3, CT_JELLY
]

const RESULT_CONTENT_TYPES = [
    CT_RESULTS_JSON, CT_RESULTS_XML, CT_CSV, CT_TSV, CT_JSON
]

# ─── Bulk loading helper ─────────────────────────────────────────
# Use add_bulk! for LMDBStore, individual add! for others
function _server_bulk_load!(target::RDFGraph, source_triples)
    if target.store isa LMDBStore
        add_bulk!(target.store, source_triples)
    else
        for t in source_triples
            add!(target, t)
        end
    end
end

# Direct body-to-store loader: skips temporary MemoryStore for bulk import
function _server_bulk_load_body!(target::RDFGraph, body::Vector{UInt8}, ct::String)
    if target.store isa LMDBStore && ct == CT_NTRIPLES
        # Parse N-Triples directly into Vector{Triple}, skip MemoryStore
        triples_vec = parse_ntriples_vec(IOBuffer(body))
        add_bulk!(target.store, triples_vec)
    else
        new_g = _parse_rdf_body(body, ct)
        _server_bulk_load!(target, triples(new_g))
    end
end

# ─── Content Negotiation ─────────────────────────────────────────

function _parse_accept(accept::String)::Vector{Tuple{String, Float64}}
    result = Tuple{String, Float64}[]
    for part in split(accept, ',')
        part = strip(part)
        isempty(part) && continue
        tokens = split(part, ';')
        mime = strip(tokens[1])
        q = 1.0
        for t in tokens[2:end]
            t = strip(t)
            if startswith(t, "q=")
                q = tryparse(Float64, t[3:end])
                isnothing(q) && (q = 0.0)
            end
        end
        push!(result, (String(mime), q))
    end
    sort!(result, by=x -> -x[2])
    return result
end

function _negotiate_content_type(accept::String, available::Vector{String})::String
    prefs = _parse_accept(accept)
    for (mime, _) in prefs
        if mime == "*/*"
            return available[1]
        end
        for avail in available
            if mime == avail || (endswith(mime, "/*") && startswith(avail, split(mime, '/')[1] * "/"))
                return avail
            end
        end
    end
    return available[1]  # fallback to first
end

function _get_content_type(req::HTTP.Request)::String
    for (k, v) in req.headers
        lowercase(k) == "content-type" && return lowercase(strip(split(v, ';')[1]))
    end
    return ""
end

function _get_accept(req::HTTP.Request)::String
    for (k, v) in req.headers
        lowercase(k) == "accept" && return v
    end
    return "*/*"
end

# ─── Format Helpers ───────────────────────────────────────────────

function _ct_to_format(ct::String)
    ct == CT_TURTLE   && return TurtleFormat()
    ct == CT_NTRIPLES && return NTriplesFormat()
    ct == CT_NQUADS   && return NQuadsFormat()
    ct == CT_RDFXML   && return RDFXMLFormat()
    ct == CT_TRIG     && return TriGFormat()
    ct == CT_JSONLD   && return JSONLDFormat()
    ct == CT_N3       && return TurtleFormat()  # N3 parsed as extended Turtle
    (ct == CT_JSON || ct == "application/json") && return JSONLDFormat()
    ct == "application/x-turtle" && return TurtleFormat()
    ct == "text/plain" && return NTriplesFormat()
    nothing
end

function _serialize_graph(g::RDFGraph, ct::String)::Tuple{Vector{UInt8}, String}
    ct == CT_JELLY && return (serialize_jelly(g), CT_JELLY)
    ct == CT_N3    && return (Vector{UInt8}(serialize_n3(g)), CT_N3)
    fmt = _ct_to_format(ct)
    isnothing(fmt) && (fmt = TurtleFormat(); ct = CT_TURTLE)
    buf = IOBuffer()
    serialize(buf, g, fmt)
    return (take!(buf), ct)
end

function _serialize_dataset(ds::Dataset, ct::String)::Tuple{Vector{UInt8}, String}
    if ct == CT_TRIG
        return (Vector{UInt8}(serialize_trig(ds)), CT_TRIG)
    elseif ct == CT_NQUADS
        return (Vector{UInt8}(serialize_nquads(ds)), CT_NQUADS)
    elseif ct == CT_JELLY
        return (serialize_jelly(ds.default_graph), CT_JELLY)
    end
    # Default: serialize default graph
    _serialize_graph(ds.default_graph, ct)
end

function _parse_rdf_body(body::Vector{UInt8}, ct::String)::RDFGraph
    if ct == CT_JELLY
        return parse_jelly(body)
    end
    fmt = _ct_to_format(ct)
    isnothing(fmt) && throw(ArgumentError("Unsupported content type: $ct"))
    text = String(copy(body))
    if ct == CT_N3
        return parse_n3(text)
    end
    return parse_rdf(text, fmt)
end

function _format_results(results, accept::String)::Tuple{String, String}
    ct = _negotiate_content_type(accept, RESULT_CONTENT_TYPES)

    if results isa Bool
        # ASK result
        if ct == CT_RESULTS_JSON || ct == CT_JSON
            return ("{\"head\":{},\"boolean\":$(results)}", CT_RESULTS_JSON)
        elseif ct == CT_RESULTS_XML
            xml = """<?xml version="1.0"?>
<sparql xmlns="http://www.w3.org/2005/sparql-results#">
  <head/>
  <boolean>$(results)</boolean>
</sparql>"""
            return (xml, CT_RESULTS_XML)
        else
            return (string(results), CT_TEXT)
        end
    elseif results isa RDFGraph
        # CONSTRUCT/DESCRIBE result — negotiate as RDF
        rdf_ct = _negotiate_content_type(accept, RDF_CONTENT_TYPES)
        data, actual_ct = _serialize_graph(results, rdf_ct)
        return (String(data), actual_ct)
    elseif results isa Vector
        # SELECT result
        if ct == CT_RESULTS_JSON || ct == CT_JSON
            return (sparql_results_json(results), CT_RESULTS_JSON)
        elseif ct == CT_RESULTS_XML
            return (sparql_results_xml(results), CT_RESULTS_XML)
        elseif ct == CT_CSV
            return (sparql_results_csv(results), CT_CSV)
        elseif ct == CT_TSV
            return (sparql_results_tsv(results), CT_TSV)
        else
            return (sparql_results_json(results), CT_RESULTS_JSON)
        end
    end
    return (string(results), CT_TEXT)
end

# ─── HTTP Response Helpers ────────────────────────────────────────

function _response(status::Int, body::String, content_type::String;
                   headers::Vector{Pair{String,String}}=Pair{String,String}[])
    all_headers = [
        "Content-Type" => content_type,
        "Access-Control-Allow-Origin" => "*",
        "Server" => "RDFLib.jl/1.0",
        headers...
    ]
    HTTP.Response(status, all_headers, body)
end

function _response(status::Int, body::Vector{UInt8}, content_type::String;
                   headers::Vector{Pair{String,String}}=Pair{String,String}[])
    all_headers = [
        "Content-Type" => content_type,
        "Access-Control-Allow-Origin" => "*",
        "Server" => "RDFLib.jl/1.0",
        headers...
    ]
    HTTP.Response(status, all_headers, body)
end

function _error_response(status::Int, message::String)
    body = "{\"error\":$(JSON.json(message))}"
    _response(status, body, CT_JSON)
end

function _json_response(status::Int, obj)
    _response(status, JSON.json(obj), CT_JSON)
end

# ─── URL Parsing ──────────────────────────────────────────────────

function _parse_query_params(uri::String)::Dict{String,String}
    params = Dict{String,String}()
    idx = findfirst('?', uri)
    isnothing(idx) && return params
    query = uri[idx+1:end]
    for pair in split(query, '&')
        isempty(pair) && continue
        kv = split(pair, '=', limit=2)
        key = HTTP.URIs.unescapeuri(kv[1])
        val = length(kv) >= 2 ? HTTP.URIs.unescapeuri(kv[2]) : ""
        params[key] = val
    end
    return params
end

# Parse the query string preserving repeated keys (needed for
# default-graph-uri / named-graph-uri multiplicity and for detecting
# duplicate `query=` / `update=` params, which are protocol errors).
function _parse_query_params_multi(uri::String)::Dict{String,Vector{String}}
    params = Dict{String,Vector{String}}()
    idx = findfirst('?', uri)
    isnothing(idx) && return params
    query = uri[idx+1:end]
    for pair in split(query, '&')
        isempty(pair) && continue
        kv = split(pair, '=', limit=2)
        key = HTTP.URIs.unescapeuri(kv[1])
        val = length(kv) >= 2 ? HTTP.URIs.unescapeuri(kv[2]) : ""
        push!(get!(() -> String[], params, key), String(val))
    end
    return params
end

function _parse_form_body_multi(body::Vector{UInt8})::Dict{String,Vector{String}}
    # application/x-www-form-urlencoded: '+' encodes a space.
    params = Dict{String,Vector{String}}()
    text = String(copy(body))
    for pair in split(text, '&')
        isempty(pair) && continue
        kv = split(pair, '=', limit=2)
        key = HTTP.URIs.unescapeuri(replace(kv[1], '+' => ' '))
        val = length(kv) >= 2 ? HTTP.URIs.unescapeuri(replace(kv[2], '+' => ' ')) : ""
        push!(get!(() -> String[], params, key), String(val))
    end
    return params
end

function _parse_form_body(body::Vector{UInt8})::Dict{String,String}
    _parse_query_params("?" * String(copy(body)))
end

function _path_segments(uri::String)::Vector{String}
    path = split(uri, '?')[1]
    filter(!isempty, split(path, '/'))
end

# ─── Dataset Management ──────────────────────────────────────────

function add_dataset!(server::SparqlServer, name::String;
                      dataset::Union{Dataset, Nothing}=nothing)
    lock(server.datasets_lock) do
        haskey(server.datasets, name) && error("Dataset '$name' already exists")
        ep = DatasetEndpoint(name, store_factory=server.store_factory)
        if !isnothing(dataset)
            ep.dataset = dataset
        end
        server.datasets[name] = ep
    end
    server
end

function remove_dataset!(server::SparqlServer, name::String)
    lock(server.datasets_lock) do
        delete!(server.datasets, name)
    end
    server
end

function get_dataset(server::SparqlServer, name::String)::Union{DatasetEndpoint, Nothing}
    lock(server.datasets_lock) do
        get(server.datasets, name, nothing)
    end
end

# ─── Request Handlers ─────────────────────────────────────────────

# SPARQL Query: GET/POST /<ds>/sparql
function _handle_sparql_query(ep::DatasetEndpoint, req::HTTP.Request, params::Dict{String,String})
    method = String(req.method)
    ct = _get_content_type(req)
    query = ""

    if method == "GET"
        query = get(params, "query", "")
    elseif method == "POST"
        if ct == CT_SPARQL_QUERY
            query = String(copy(req.body))
        elseif ct == CT_FORM
            form = _parse_form_body(req.body)
            query = get(form, "query", "")
        else
            query = String(copy(req.body))
        end
    end

    isempty(query) && return _error_response(400, "Missing query parameter")

    # Check for default-graph-uri / named-graph-uri params
    default_graph_uri = get(params, "default-graph-uri", "")
    named_graph_uri = get(params, "named-graph-uri", "")

    # Execute query against appropriate graph
    g = if !isempty(named_graph_uri)
        uri = URIRef(named_graph_uri)
        ng = get(ep.dataset.named_graphs, uri, nothing)
        isnothing(ng) && return _error_response(404, "Named graph not found: $named_graph_uri")
        ng
    else
        ep.dataset.default_graph
    end

    results = try
        lock(ep.lock) do
            ep.query_count += 1
            sparql_query(g, query)
        end
    catch e
        return _error_response(400, "SPARQL error: $(sprint(showerror, e))")
    end

    accept = _get_accept(req)
    body, result_ct = _format_results(results, accept)
    _response(200, body, result_ct)
end

# SPARQL Update: POST /<ds>/update
function _handle_sparql_update(ep::DatasetEndpoint, req::HTTP.Request, params::Dict{String,String})
    ct = _get_content_type(req)
    update = ""

    if ct == CT_SPARQL_UPDATE
        update = String(copy(req.body))
    elseif ct == CT_FORM
        form = _parse_form_body(req.body)
        update = get(form, "update", "")
    else
        update = String(copy(req.body))
    end

    isempty(update) && return _error_response(400, "Missing update")

    try
        lock(ep.lock) do
            ep.update_count += 1
            sparql_update(ep.dataset.default_graph, update)
        end
    catch e
        return _error_response(400, "SPARQL update error: $(sprint(showerror, e))")
    end

    _response(204, "", CT_TEXT)
end

# ─── W3C SPARQL Protocol conformance ─────────────────────────────
#
# The official SPARQL Protocol test suite drives a single `/sparql` endpoint
# for both query and update, distinguishing them by HTTP method, request
# media type and parameters. These handlers implement that contract precisely
# (status codes 200/204/400, content negotiation, protocol-specified dataset).

# Raw Content-Type header value (with parameters like charset preserved).
function _get_content_type_raw(req::HTTP.Request)::String
    for (k, v) in req.headers
        lowercase(k) == "content-type" && return strip(v)
    end
    return ""
end

# Extract the charset parameter (lowercased) from a Content-Type header.
function _content_type_charset(raw::String)::String
    for tok in split(raw, ';')[2:end]
        tok = strip(tok)
        if startswith(lowercase(tok), "charset=")
            return lowercase(strip(tok[9:end], ['"', ' ']))
        end
    end
    return ""
end

# Build a query-time dataset view from the protocol-specified graph params.
# `default-graph-uri` graphs are merged into the default graph; each
# `named-graph-uri` becomes a visible named graph. When neither is given the
# endpoint's own dataset is queried as-is.
function _protocol_query_dataset(ep::DatasetEndpoint,
                                 default_uris::Vector{String},
                                 named_uris::Vector{String})
    if isempty(default_uris) && isempty(named_uris)
        return ep.dataset
    end
    ds = Dataset()
    for u in default_uris
        src = get(ep.dataset.named_graphs, URIRef(u), nothing)
        isnothing(src) && continue
        for t in triples(src)
            add!(ds.default_graph, t)
        end
    end
    for u in named_uris
        name = URIRef(u)
        src = get(ep.dataset.named_graphs, name, nothing)
        g = add_graph(ds, name)
        if !isnothing(src)
            for t in triples(src)
                add!(g, t)
            end
        end
    end
    return ds
end

# Unified W3C SPARQL Protocol endpoint: query AND update on one path.
function _handle_protocol_sparql(ep::DatasetEndpoint, req::HTTP.Request,
                                 uri::String)
    method = String(req.method)
    raw_ct = _get_content_type_raw(req)
    ct = isempty(raw_ct) ? "" : lowercase(strip(split(raw_ct, ';')[1]))
    pmulti = _parse_query_params_multi(uri)

    # Decide query vs update vs error, per SPARQL Protocol §2.
    if method == "GET"
        haskey(pmulti, "update") && return _error_response(400, "Update must use POST")
        return _protocol_query(ep, req, pmulti, GET_query_string(pmulti))
    elseif method != "POST"
        return _error_response(400, "Method $method not allowed on SPARQL endpoint")
    end

    # POST: dispatch on media type.
    if ct == CT_SPARQL_QUERY
        cs = _content_type_charset(raw_ct)
        (cs != "" && cs != "utf-8") && return _error_response(400, "Unsupported charset: $cs")
        q = String(copy(req.body))
        return _protocol_query(ep, req, pmulti, q)
    elseif ct == CT_SPARQL_UPDATE
        cs = _content_type_charset(raw_ct)
        (cs != "" && cs != "utf-8") && return _error_response(400, "Unsupported charset: $cs")
        upd = String(copy(req.body))
        return _protocol_update(ep, req, pmulti, upd)
    elseif ct == CT_FORM
        form = _parse_form_body_multi(req.body)
        has_q = haskey(form, "query")
        has_u = haskey(form, "update")
        if has_q && has_u
            return _error_response(400, "Cannot mix query and update")
        elseif has_q
            length(form["query"]) > 1 && return _error_response(400, "Multiple query parameters")
            # merge protocol graph params from the form
            for k in ("default-graph-uri", "named-graph-uri")
                haskey(form, k) && (pmulti[k] = form[k])
            end
            return _protocol_query(ep, req, pmulti, form["query"][1])
        elseif has_u
            length(form["update"]) > 1 && return _error_response(400, "Multiple update parameters")
            for k in ("using-graph-uri", "using-named-graph-uri")
                haskey(form, k) && (pmulti[k] = form[k])
            end
            return _protocol_update(ep, req, pmulti, form["update"][1])
        else
            return _error_response(400, "Missing query or update parameter")
        end
    else
        return _error_response(400, "Unsupported media type for SPARQL operation: $(isempty(ct) ? "(none)" : ct)")
    end
end

# Resolve the single query string for a GET request (duplicate = error).
function GET_query_string(pmulti::Dict{String,Vector{String}})
    qs = get(pmulti, "query", String[])
    length(qs) > 1 && return :multiple
    isempty(qs) && return ""
    qs[1]
end

function _protocol_query(ep::DatasetEndpoint, req::HTTP.Request,
                         pmulti::Dict{String,Vector{String}}, query)
    query === :multiple && return _error_response(400, "Multiple query parameters")
    (query isa AbstractString && isempty(query)) && return _error_response(400, "Missing query")

    default_uris = get(pmulti, "default-graph-uri", String[])
    named_uris   = get(pmulti, "named-graph-uri", String[])

    results = try
        lock(ep.lock) do
            ep.query_count += 1
            target = _protocol_query_dataset(ep, default_uris, named_uris)
            sparql_query(target, String(query))
        end
    catch e
        return _error_response(400, "SPARQL query error: $(sprint(showerror, e))")
    end

    accept = _get_accept(req)
    body, result_ct = _format_results(results, accept)
    _response(200, body, result_ct)
end

function _protocol_update(ep::DatasetEndpoint, req::HTTP.Request,
                          pmulti::Dict{String,Vector{String}}, update)
    isempty(update) && return _error_response(400, "Missing update")

    using_g = get(pmulti, "using-graph-uri", String[])
    using_n = get(pmulti, "using-named-graph-uri", String[])

    # Protocol error: combining using-(named-)graph-uri with USING/WITH/WITH in
    # the update text (SPARQL Protocol §2.2.3).
    if (!isempty(using_g) || !isempty(using_n)) &&
       (occursin(r"\bUSING\b"i, update) || occursin(r"\bWITH\b"i, update))
        return _error_response(400, "Cannot combine protocol using-graph-uri with USING/WITH clause")
    end

    ug = URIRef[URIRef(u) for u in using_g]
    un = URIRef[URIRef(u) for u in using_n]
    update = _inject_base(String(update), _endpoint_base(req))

    try
        lock(ep.lock) do
            ep.update_count += 1
            _protocol_apply_update(ep.dataset, String(update), ug, un)
        end
    catch e
        return _error_response(400, "SPARQL update error: $(sprint(showerror, e))")
    end
    _response(204, "", CT_TEXT)
end

# Service-defined BASE IRI (may be the service endpoint) used to resolve
# relative IRIs in protocol query/update text that declares no BASE itself.
function _endpoint_base(req::HTTP.Request)
    authority = "localhost"
    for (k, v) in req.headers
        lowercase(k) == "host" && (authority = v)
    end
    "http://$authority/sparql"
end

# Prepend `BASE <iri>` to a SPARQL request that has no BASE declaration, so
# relative IRIs resolve. Detects an existing leading BASE (after optional
# comments/whitespace) to avoid overriding the request's own base.
function _inject_base(text::String, base::String)
    # crude but safe: if a BASE keyword appears before the first '{' or
    # INSERT/DELETE/SELECT/ASK keyword, assume the request sets its own base.
    occursin(r"(?i)\bBASE\b\s*<"m, text) && return text
    "BASE <$base>\n" * text
end

# Apply an update to a dataset, injecting protocol-specified using-graph-uri /
# using-named-graph-uri into any DELETE/INSERT...WHERE operation that does not
# carry its own USING/WITH (SPARQL Protocol §2.1.4 / Update §4.1.2).
function _protocol_apply_update(ds::Dataset, update::String,
                                using_graphs::Vector{URIRef},
                                using_named::Vector{URIRef})
    if isempty(using_graphs) && isempty(using_named)
        return sparql_update(ds, update)
    end
    parsed = sparql_parse_update(update)
    _exec_with_using(ds, parsed, using_graphs, using_named)
    nothing
end

function _exec_with_using(ds::Dataset, op::UpdateRequest, ug, un)
    for sub in op.operations
        _exec_with_using(ds, sub, ug, un)
    end
end
function _exec_with_using(ds::Dataset, op::UpdateModify, ug, un)
    if op.with_graph === nothing && isempty(op.using_graphs) && isempty(op.using_named)
        op = UpdateModify(op.delete_template, op.insert_template, op.patterns,
                          op.prefixes, op.with_graph, ug, un)
    end
    _sparql_exec_update(ds, op)
end
function _exec_with_using(ds::Dataset, op, ug, un)
    _sparql_exec_update(ds, op)
end

# ─── W3C Graph Store Protocol conformance (`/gsp`) ────────────────
#
# Supports both indirect (`?graph=<iri>` / `?default`) and direct
# (`/gsp/person/1.ttl` → graph IRI) identification, plus HEAD, with the
# status codes the conformance suite expects (200/201/204/404), multipart
# POST, and Turtle responses carrying `charset=utf-8`.

const CT_TURTLE_UTF8 = "text/turtle; charset=utf-8"

# Parse a (possibly multipart) request body into a Vector{Triple}.
function _gsp_parse_body(body::Vector{UInt8}, raw_ct::String)
    ct = lowercase(strip(split(raw_ct, ';')[1]))
    if ct == "multipart/form-data"
        boundary = ""
        for tok in split(raw_ct, ';')
            tok = strip(tok)
            if startswith(lowercase(tok), "boundary=")
                boundary = strip(tok[10:end], ['"'])
            end
        end
        isempty(boundary) && throw(ArgumentError("multipart without boundary"))
        triples_out = Triple[]
        text = String(copy(body))
        delim = "--" * boundary
        for part in split(text, delim)
            part = strip(part)
            (isempty(part) || part == "--") && continue
            # split headers from content on the blank line
            sep = findfirst("\r\n\r\n", part)
            isnothing(sep) && (sep = findfirst("\n\n", part))
            isnothing(sep) && continue
            content = part[last(sep)+1:end]
            pct = CT_TURTLE
            for hl in split(part[1:first(sep)-1], r"\r?\n")
                if startswith(lowercase(strip(hl)), "content-type:")
                    pct = lowercase(strip(split(split(hl, ':', limit=2)[2], ';')[1]))
                end
            end
            g = _parse_rdf_body(Vector{UInt8}(content), pct)
            append!(triples_out, collect(triples(g)))
        end
        return triples_out
    end
    g = _parse_rdf_body(body, ct)
    collect(triples(g))
end

# Resolve the target graph for a GSP request: returns
# (:default, nothing) | (:named, URIRef) | (:error, msg).
function _gsp_target(req::HTTP.Request, uri::String, segments::Vector{String})
    params = _parse_query_params(uri)
    # Direct identification: /gsp/<rest...> with a non-empty rest path.
    if length(segments) >= 2 && segments[1] == "gsp"
        rest = join(segments[2:end], "/")
        # reconstruct absolute graph IRI using request authority
        authority = "www.example"
        for (k, v) in req.headers
            lowercase(k) == "host" && (authority = v)
        end
        return (:named, URIRef("http://$authority/gsp/$rest"))
    end
    haskey(params, "default") && return (:default, nothing)
    if haskey(params, "graph")
        g = params["graph"]
        isempty(g) && return (:error, "Empty graph parameter")
        return (:named, URIRef(g))
    end
    # No identification given: treat as default graph (some clients do this).
    return (:default, nothing)
end

function _handle_protocol_gsp(ep::DatasetEndpoint, req::HTTP.Request, uri::String)
    method = String(req.method)
    segments = _path_segments(uri)
    kind, graph_name = _gsp_target(req, uri, segments)
    kind == :error && return _error_response(400, graph_name)

    getg() = isnothing(graph_name) ? ep.dataset.default_graph :
             get(ep.dataset.named_graphs, graph_name, nothing)

    if method == "GET" || method == "HEAD"
        g = lock(ep.lock) do
            gg = getg()
            isnothing(gg) ? nothing : begin
                # snapshot a copy under the lock for serialization
                snap = RDFGraph(); for t in triples(gg); add!(snap, t); end; snap
            end
        end
        isnothing(g) && return _error_response(404, "Graph not found")
        accept = _get_accept(req)
        ct = _negotiate_content_type(accept, RDF_CONTENT_TYPES)
        data, actual_ct = _serialize_graph(g, ct)
        out_ct = actual_ct == CT_TURTLE ? CT_TURTLE_UTF8 : actual_ct
        if method == "HEAD"
            return _response(200, UInt8[], out_ct)
        end
        return _response(200, data, out_ct)

    elseif method == "PUT"
        raw_ct = _get_content_type_raw(req)
        isempty(raw_ct) && return _error_response(400, "Content-Type required")
        parsed = try
            _gsp_parse_body(req.body, raw_ct)
        catch e
            return _error_response(400, "Parse error: $(sprint(showerror, e))")
        end
        existed = lock(ep.lock) do
            if isnothing(graph_name)
                dg = ep.dataset.default_graph
                had = length(dg) > 0
                remove!(dg, (nothing, nothing, nothing))
                for t in parsed; add!(dg, t); end
                true   # default graph always "exists"
            else
                had = haskey(ep.dataset.named_graphs, graph_name)
                g = add_graph(ep.dataset, graph_name)
                remove!(g, (nothing, nothing, nothing))
                for t in parsed; add!(g, t); end
                had
            end
        end
        # 201 Created when a new (named) graph was created, else 204.
        return existed ? _response(204, "", CT_TEXT) :
                         _response(201, "", CT_TEXT,
                                   headers=["Location" => (isnothing(graph_name) ? "" : graph_name.value)])

    elseif method == "POST"
        raw_ct = _get_content_type_raw(req)
        # POST to the bare endpoint creates a fresh graph (POSTGraphCreation).
        bare = !occursin('?', uri) && length(segments) == 1 && segments[1] == "gsp"
        isempty(raw_ct) && return _error_response(400, "Content-Type required")
        parsed = try
            _gsp_parse_body(req.body, raw_ct)
        catch e
            return _error_response(400, "Parse error: $(sprint(showerror, e))")
        end
        if bare
            authority = "www.example"
            for (k, v) in req.headers
                lowercase(k) == "host" && (authority = v)
            end
            new_iri = URIRef("http://$authority/gsp/_created/" * string(hash((time_ns(), rand(UInt))), base=16))
            lock(ep.lock) do
                g = add_graph(ep.dataset, new_iri)
                for t in parsed; add!(g, t); end
            end
            return _response(201, "", CT_TEXT, headers=["Location" => new_iri.value])
        end
        existed = lock(ep.lock) do
            had = isnothing(graph_name) ? true : haskey(ep.dataset.named_graphs, graph_name)
            g = isnothing(graph_name) ? ep.dataset.default_graph : add_graph(ep.dataset, graph_name)
            for t in parsed; add!(g, t); end
            had
        end
        return existed ? _response(204, "", CT_TEXT) : _response(201, "", CT_TEXT)

    elseif method == "DELETE"
        found = lock(ep.lock) do
            if isnothing(graph_name)
                remove!(ep.dataset.default_graph, (nothing, nothing, nothing))
                true
            else
                if haskey(ep.dataset.named_graphs, graph_name)
                    delete!(ep.dataset.named_graphs, graph_name)
                    true
                else
                    false
                end
            end
        end
        return found ? _response(204, "", CT_TEXT) : _error_response(404, "Graph not found")
    end
    _error_response(405, "Method not allowed")
end

# Graph Store Protocol: GET/PUT/POST/DELETE /<ds>/data
function _handle_gsp(ep::DatasetEndpoint, req::HTTP.Request, params::Dict{String,String})
    method = String(req.method)
    is_default = haskey(params, "default")
    graph_uri = get(params, "graph", "")

    # Determine target graph
    if is_default || (isempty(graph_uri) && method == "GET")
        # If neither ?default nor ?graph, return entire dataset as quads
        if !is_default && isempty(graph_uri) && method == "GET"
            accept = _get_accept(req)
            ct = _negotiate_content_type(accept, [CT_TRIG, CT_NQUADS, CT_TURTLE])
            data, actual_ct = lock(ep.lock) do
                _serialize_dataset(ep.dataset, ct)
            end
            return _response(200, data, actual_ct)
        end
        # Operations on default graph
        return _handle_gsp_graph(ep, req, method, nothing, params)
    else
        return _handle_gsp_graph(ep, req, method, URIRef(graph_uri), params)
    end
end

function _handle_gsp_graph(ep::DatasetEndpoint, req::HTTP.Request, method::String,
                           graph_name::Union{URIRef, Nothing}, params::Dict{String,String})
    if method == "GET"
        g = lock(ep.lock) do
            if isnothing(graph_name)
                ep.dataset.default_graph
            else
                get(ep.dataset.named_graphs, graph_name, nothing)
            end
        end
        isnothing(g) && return _error_response(404, "Graph not found")
        accept = _get_accept(req)
        ct = _negotiate_content_type(accept, RDF_CONTENT_TYPES)
        data, actual_ct = _serialize_graph(g, ct)
        return _response(200, data, actual_ct)

    elseif method == "PUT"
        # Replace graph entirely
        ct = _get_content_type(req)
        isempty(ct) && return _error_response(400, "Content-Type required")
        # Parse outside lock (avoid return-from-closure issue)
        parsed = try
            if (ep.dataset.default_graph.store isa LMDBStore || ep.dataset.default_graph.store isa MemoryStore) && ct == CT_NTRIPLES && isnothing(graph_name)
                parse_ntriples_vec(IOBuffer(req.body))  # fast path: Vector{Triple}
            else
                _parse_rdf_body(req.body, ct)  # standard path: RDFGraph
            end
        catch e
            return _error_response(400, "Parse error: $(sprint(showerror, e))")
        end
        lock(ep.lock) do
            if isnothing(graph_name)
                dg = ep.dataset.default_graph
                if dg.store isa LMDBStore
                    clear!(dg.store)
                else
                    remove!(dg, (nothing, nothing, nothing))
                end
                if parsed isa Vector{Triple}
                    add_bulk!(dg.store, parsed)
                else
                    _server_bulk_load!(dg, triples(parsed))
                end
            else
                ep.dataset.named_graphs[graph_name] = parsed isa RDFGraph ? parsed : begin
                    g = RDFGraph(); for t in parsed; add!(g, t); end; g
                end
            end
        end
        return _response(204, "", CT_TEXT)

    elseif method == "POST"
        # Merge into graph
        ct = _get_content_type(req)
        isempty(ct) && return _error_response(400, "Content-Type required")
        parsed = try
            target_g = isnothing(graph_name) ? ep.dataset.default_graph : get(ep.dataset.named_graphs, graph_name, ep.dataset.default_graph)
            if (target_g.store isa LMDBStore || target_g.store isa MemoryStore) && ct == CT_NTRIPLES
                parse_ntriples_vec(IOBuffer(req.body))
            else
                _parse_rdf_body(req.body, ct)
            end
        catch e
            return _error_response(400, "Parse error: $(sprint(showerror, e))")
        end
        count = parsed isa Vector ? length(parsed) : length(parsed)
        lock(ep.lock) do
            target = if isnothing(graph_name)
                ep.dataset.default_graph
            else
                if !haskey(ep.dataset.named_graphs, graph_name)
                    ep.dataset.named_graphs[graph_name] = RDFGraph()
                end
                ep.dataset.named_graphs[graph_name]
            end
            if parsed isa Vector{Triple} && (target.store isa LMDBStore || target.store isa MemoryStore)
                add_bulk!(target.store, parsed)
            elseif parsed isa RDFGraph
                _server_bulk_load!(target, triples(parsed))
            else
                for t in parsed; add!(target, t); end
            end
        end
        return _response(200,
            "{\"success\":true,\"tripleCount\":$count}",
            CT_JSON)

    elseif method == "DELETE"
        lock(ep.lock) do
            if isnothing(graph_name)
                remove!(ep.dataset.default_graph, (nothing, nothing, nothing))
            else
                delete!(ep.dataset.named_graphs, graph_name)
            end
        end
        return _response(204, "", CT_TEXT)
    end

    _error_response(405, "Method not allowed")
end

# File Upload: POST /<ds>/upload
function _handle_upload(ep::DatasetEndpoint, req::HTTP.Request, params::Dict{String,String})
    ct = _get_content_type(req)
    isempty(ct) && return _error_response(400, "Content-Type required")

    graph_name = get(params, "graph", "")

    target_g = isempty(graph_name) ? ep.dataset.default_graph : get(ep.dataset.named_graphs, URIRef(graph_name), ep.dataset.default_graph)
    parsed = try
        if target_g.store isa LMDBStore && ct == CT_NTRIPLES
            parse_ntriples_vec(IOBuffer(req.body))
        else
            _parse_rdf_body(req.body, ct)
        end
    catch e
        return _error_response(400, "Parse error: $(sprint(showerror, e))")
    end

    count = parsed isa Vector ? length(parsed) : length(parsed)
    lock(ep.lock) do
        target = if isempty(graph_name)
            ep.dataset.default_graph
        else
            uri = URIRef(graph_name)
            if !haskey(ep.dataset.named_graphs, uri)
                ep.dataset.named_graphs[uri] = RDFGraph()
            end
            ep.dataset.named_graphs[uri]
        end
        if parsed isa Vector{Triple} && target.store isa LMDBStore
            add_bulk!(target.store, parsed)
        elseif parsed isa RDFGraph
            _server_bulk_load!(target, triples(parsed))
        else
            for t in parsed; add!(target, t); end
        end
    end

    _response(200, "{\"success\":true,\"tripleCount\":$count}", CT_JSON)
end

# N3 Reasoning: POST /<ds>/reason
function _handle_reason(ep::DatasetEndpoint, req::HTTP.Request, params::Dict{String,String})
    ct = _get_content_type(req)

    # Body contains N3 rules (the query/rules)
    rules_text = String(copy(req.body))
    isempty(rules_text) && return _error_response(400, "Missing N3 rules in request body")

    result = try
        lock(ep.lock) do
            data_graph = ep.dataset.default_graph
            rules_graph = parse_n3(rules_text)
            ruleset = extract_rules(rules_graph)
            reasoner = N3Reasoner(data_graph, ruleset)
            reason(reasoner)
        end
    catch e
        return _error_response(400, "Reasoning error: $(sprint(showerror, e))")
    end

    accept = _get_accept(req)
    ct_out = _negotiate_content_type(accept, [CT_N3, CT_TURTLE, CT_NTRIPLES, CT_JSONLD])
    if ct_out == CT_N3
        body = serialize_n3(result)
        return _response(200, body, CT_N3)
    end
    data, actual_ct = _serialize_graph(result, ct_out)
    return _response(200, data, actual_ct)
end

# SHACL Validation: POST /<ds>/shacl
function _handle_shacl(ep::DatasetEndpoint, req::HTTP.Request, params::Dict{String,String})
    ct = _get_content_type(req)
    isempty(ct) && return _error_response(400, "Content-Type required for shapes graph")

    shapes_graph = try
        _parse_rdf_body(req.body, ct)
    catch e
        return _error_response(400, "Parse error: $(sprint(showerror, e))")
    end

    report = try
        lock(ep.lock) do
            validate(ep.dataset.default_graph, shapes_graph)
        end
    catch e
        return _error_response(400, "Validation error: $(sprint(showerror, e))")
    end

    accept = _get_accept(req)
    ct_out = _negotiate_content_type(accept, [CT_JSONLD, CT_TURTLE, CT_NTRIPLES, CT_JSON])

    # Build report graph
    report_graph = RDFGraph()
    report_node = BNode()
    add!(report_graph, Triple(report_node, URIRef(string(RDF.type)), URIRef(string(SH.ValidationReport))))
    add!(report_graph, Triple(report_node,
        URIRef(string(SH.conforms)),
        Literal(string(report.conforms), datatype=URIRef(string(XSD.boolean)))))
    for r in report.results
        result_node = BNode()
        add!(report_graph, Triple(report_node, URIRef(string(SH.result)), result_node))
        add!(report_graph, Triple(result_node, URIRef(string(RDF.type)), URIRef(string(SH.ValidationResult))))
        add!(report_graph, Triple(result_node,
            URIRef(string(SH.resultSeverity)),
            URIRef(r.severity)))
        add!(report_graph, Triple(result_node,
            URIRef(string(SH.resultMessage)),
            Literal(r.message)))
        if !isnothing(r.focus_node)
            add!(report_graph, Triple(result_node,
                URIRef(string(SH.focusNode)),
                r.focus_node))
        end
        if !isnothing(r.result_path)
            add!(report_graph, Triple(result_node,
                URIRef(string(SH.resultPath)),
                r.result_path))
        end
    end

    data, actual_ct = _serialize_graph(report_graph, ct_out)
    _response(200, data, actual_ct)
end

# Dataset info: GET /<ds>/
function _handle_dataset_info(ep::DatasetEndpoint, req::HTTP.Request)
    accept = _get_accept(req)
    info = lock(ep.lock) do
        n_default = length(ep.dataset.default_graph)
        n_named = length(ep.dataset.named_graphs)
        n_total = n_default + sum(length(g) for g in values(ep.dataset.named_graphs); init=0)
        named_list = [Dict("name" => string(k), "size" => length(v))
                      for (k, v) in ep.dataset.named_graphs]
        Dict(
            "name" => ep.name,
            "defaultGraph" => Dict("size" => n_default),
            "namedGraphs" => named_list,
            "totalTriples" => n_total,
            "queryCount" => ep.query_count,
            "updateCount" => ep.update_count,
            "createdAt" => string(ep.created_at),
            "endpoints" => Dict(
                "sparql" => "/$(ep.name)/sparql",
                "update" => "/$(ep.name)/update",
                "data"   => "/$(ep.name)/data",
                "upload" => "/$(ep.name)/upload",
                "reason" => "/$(ep.name)/reason",
                "shacl"  => "/$(ep.name)/shacl",
            )
        )
    end

    if occursin(CT_HTML, accept) && !occursin(CT_JSON, accept)
        return _response(200, _html_dataset_info(info), CT_HTML)
    end
    _json_response(200, info)
end

# ─── Admin Handlers ───────────────────────────────────────────────

function _handle_admin(server::SparqlServer, req::HTTP.Request, segments::Vector{String}, params::Dict{String,String})
    path = length(segments) >= 2 ? segments[2] : ""
    method = String(req.method)

    if path == "datasets" && length(segments) < 3
        if method == "GET"
            datasets = lock(server.datasets_lock) do
                [Dict(
                    "name" => "/$(ep.name)",
                    "defaultGraphSize" => length(ep.dataset.default_graph),
                    "namedGraphCount" => length(ep.dataset.named_graphs),
                    "queryCount" => ep.query_count,
                    "updateCount" => ep.update_count,
                ) for ep in values(server.datasets)]
            end
            return _json_response(200, Dict("datasets" => datasets))

        elseif method == "POST"
            ct = _get_content_type(req)
            name = ""
            if ct == CT_FORM
                form = _parse_form_body(req.body)
                name = get(form, "dbName", get(form, "name", ""))
            elseif ct == CT_JSON || ct == CT_JSONLD
                obj = JSON.parse(String(copy(req.body)))
                name = get(obj, "name", get(obj, "dbName", ""))
            end
            isempty(name) && return _error_response(400, "Missing dataset name (dbName or name)")
            name = replace(name, "/" => "")  # strip leading slashes
            try
                add_dataset!(server, name)
            catch e
                return _error_response(409, sprint(showerror, e))
            end
            return _json_response(201, Dict("name" => "/$name", "status" => "created"))
        end

    elseif startswith(path, "datasets") && length(segments) >= 3
        ds_name = segments[3]
        if method == "DELETE"
            if haskey(server.datasets, ds_name)
                remove_dataset!(server, ds_name)
                return _response(204, "", CT_TEXT)
            else
                return _error_response(404, "Dataset not found: $ds_name")
            end
        elseif method == "GET"
            ep = get_dataset(server, ds_name)
            isnothing(ep) && return _error_response(404, "Dataset not found: $ds_name")
            return _handle_dataset_info(ep, req)
        end

    elseif path == "server"
        info = Dict(
            "server" => "RDFLib.jl SPARQL Server",
            "version" => "1.0.0",
            "julia" => string(VERSION),
            "startedAt" => isnothing(server.started_at) ? nothing : string(server.started_at),
            "uptime" => isnothing(server.started_at) ? 0 :
                        Dates.value(now(UTC) - server.started_at) / 1000,
            "datasets" => length(server.datasets),
            "features" => [
                "SPARQL 1.1 Query", "SPARQL 1.1 Update",
                "SPARQL 1.2 (partial)",
                "Graph Store Protocol",
                "Jelly RDF binary upload/download",
                "N3 Reasoning (EAM)",
                "SHACL Validation",
                "Content Negotiation",
                "CORS",
            ],
            "formats" => Dict(
                "rdf" => ["text/turtle", "application/n-triples", "application/rdf+xml",
                          "application/ld+json", "application/trig", "application/n-quads",
                          "text/n3", "application/x-jelly-rdf"],
                "results" => ["application/sparql-results+json",
                              "application/sparql-results+xml",
                              "text/csv", "text/tab-separated-values"],
            ),
        )
        return _json_response(200, info)

    elseif path == "ping"
        return _response(200, "OK", CT_TEXT)
    end

    _error_response(404, "Unknown admin endpoint: /\$/$path")
end

# ─── HTML Templates ───────────────────────────────────────────────

function _html_landing(server::SparqlServer)
    datasets_html = join([
        """<tr>
            <td><a href="/$(ep.name)/">$(ep.name)</a></td>
            <td>$(length(ep.dataset.default_graph))</td>
            <td>$(length(ep.dataset.named_graphs))</td>
            <td><a href="/$(ep.name)/sparql?query=SELECT+*+WHERE+{+?s+?p+?o+}+LIMIT+10">query</a></td>
        </tr>"""
        for ep in values(server.datasets)
    ], "\n")

    """<!DOCTYPE html>
<html><head><title>RDFLib.jl SPARQL Server</title>
<style>
body{font-family:system-ui,sans-serif;max-width:900px;margin:40px auto;padding:0 20px;color:#333}
h1{color:#2563eb}table{border-collapse:collapse;width:100%}
th,td{border:1px solid #ddd;padding:8px;text-align:left}
th{background:#f0f0f0}a{color:#2563eb}
.endpoints{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin:20px 0}
.endpoint{background:#f8f9fa;padding:15px;border-radius:8px;border:1px solid #e0e0e0}
code{background:#e8e8e8;padding:2px 6px;border-radius:3px;font-size:0.9em}
</style></head><body>
<h1>🔷 RDFLib.jl SPARQL Server</h1>
<p>Julia $(VERSION) · SPARQL 1.1/1.2 · N3 Reasoning · SHACL · Jelly</p>
<h2>Datasets</h2>
<table><tr><th>Name</th><th>Triples</th><th>Named Graphs</th><th>Actions</th></tr>
$datasets_html
</table>
<h2>API Endpoints</h2>
<div class="endpoints">
<div class="endpoint"><strong>Query</strong><br><code>GET/POST /&lt;ds&gt;/sparql</code></div>
<div class="endpoint"><strong>Update</strong><br><code>POST /&lt;ds&gt;/update</code></div>
<div class="endpoint"><strong>Graph Store</strong><br><code>GET/PUT/POST/DELETE /&lt;ds&gt;/data</code></div>
<div class="endpoint"><strong>Upload</strong><br><code>POST /&lt;ds&gt;/upload</code></div>
<div class="endpoint"><strong>N3 Reasoning</strong><br><code>POST /&lt;ds&gt;/reason</code></div>
<div class="endpoint"><strong>SHACL</strong><br><code>POST /&lt;ds&gt;/shacl</code></div>
<div class="endpoint"><strong>Admin</strong><br><code>GET /\$/server</code></div>
<div class="endpoint"><strong>Datasets</strong><br><code>GET/POST /\$/datasets</code></div>
</div>
<h2>Supported Formats</h2>
<p>Turtle · N-Triples · RDF/XML · JSON-LD · TriG · N-Quads · N3 · <strong>Jelly</strong></p>
<p>Results: SPARQL JSON · SPARQL XML · CSV · TSV</p>
</body></html>"""
end

function _html_dataset_info(info::Dict)
    named_html = join([
        "<li><code>$(ng["name"])</code> — $(ng["size"]) triples</li>"
        for ng in info["namedGraphs"]
    ], "\n")

    """<!DOCTYPE html>
<html><head><title>$(info["name"]) — RDFLib.jl</title>
<style>body{font-family:system-ui,sans-serif;max-width:800px;margin:40px auto;padding:0 20px}
h1{color:#2563eb}code{background:#e8e8e8;padding:2px 6px;border-radius:3px}
.stat{display:inline-block;background:#f0f7ff;padding:10px 20px;border-radius:8px;margin:5px;border:1px solid #bdd}
</style></head><body>
<h1>📊 Dataset: $(info["name"])</h1>
<div>
<span class="stat">Default graph: <strong>$(info["defaultGraph"]["size"])</strong> triples</span>
<span class="stat">Total: <strong>$(info["totalTriples"])</strong> triples</span>
<span class="stat">Queries: <strong>$(info["queryCount"])</strong></span>
<span class="stat">Updates: <strong>$(info["updateCount"])</strong></span>
</div>
<h2>Named Graphs</h2>
<ul>$(isempty(named_html) ? "<li><em>None</em></li>" : named_html)</ul>
<h2>Endpoints</h2>
<ul>
$(join(["<li><strong>$k</strong>: <code>$v</code></li>" for (k,v) in info["endpoints"]], "\n"))
</ul>
<p><a href="/">← Back to server</a></p>
</body></html>"""
end

# ─── SPARQL Service Description ───────────────────────────────────
#
# A GET on the SPARQL endpoint (without a query) returns a SPARQL 1.1
# Service Description graph containing an `sd:endpoint` triple naming this
# endpoint's URL, serialized as RDF (Turtle by default; content-negotiated).

const SD = "http://www.w3.org/ns/sparql-service-description#"
const RDFNS_SERVER = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

function _service_description(server::SparqlServer, req::HTTP.Request)
    authority = "$(server.host):$(server.port)"
    for (k, v) in req.headers
        lowercase(k) == "host" && (authority = v)
    end
    endpoint_url = "http://$authority/sparql"
    g = RDFGraph()
    svc = BNode()
    rdftype = URIRef(RDFNS_SERVER * "type")
    add!(g, Triple(svc, rdftype, URIRef(SD * "Service")))
    add!(g, Triple(svc, URIRef(SD * "endpoint"), URIRef(endpoint_url)))
    add!(g, Triple(svc, URIRef(SD * "supportedLanguage"), URIRef(SD * "SPARQL11Query")))
    add!(g, Triple(svc, URIRef(SD * "supportedLanguage"), URIRef(SD * "SPARQL11Update")))
    add!(g, Triple(svc, URIRef(SD * "resultFormat"),
                   URIRef("http://www.w3.org/ns/formats/SPARQL_Results_JSON")))
    add!(g, Triple(svc, URIRef(SD * "resultFormat"),
                   URIRef("http://www.w3.org/ns/formats/SPARQL_Results_XML")))
    accept = _get_accept(req)
    ct = _negotiate_content_type(accept, RDF_CONTENT_TYPES)
    data, actual_ct = _serialize_graph(g, ct)
    out_ct = actual_ct == CT_TURTLE ? CT_TURTLE_UTF8 : actual_ct
    _response(200, data, out_ct)
end

# ─── Main Router ──────────────────────────────────────────────────

function _route(server::SparqlServer, req::HTTP.Request)
    uri = String(req.target)
    method = String(req.method)
    params = _parse_query_params(uri)
    segments = _path_segments(uri)

    # CORS preflight
    if method == "OPTIONS"
        return _response(204, "", CT_TEXT, headers=[
            "Access-Control-Allow-Methods" => "GET, POST, PUT, DELETE, PATCH, OPTIONS",
            "Access-Control-Allow-Headers" => "Content-Type, Accept, Authorization",
            "Access-Control-Max-Age" => "86400",
        ])
    end

    # W3C protocol endpoints at the server root (when configured): `/sparql`
    # (SPARQL Protocol query+update) and `/gsp[...]` (Graph Store Protocol).
    if !isnothing(server.protocol_dataset) && !isempty(segments)
        pep = get_dataset(server, server.protocol_dataset)
        if !isnothing(pep)
            if segments[1] == "sparql"
                if method == "GET"
                    # Service Description: GET on the endpoint with no `query`
                    # (and no update) returns an RDF service description.
                    if !haskey(params, "query") && !haskey(params, "update")
                        return _service_description(server, req)
                    end
                end
                return _handle_protocol_sparql(pep, req, uri)
            elseif segments[1] == "gsp"
                return _handle_protocol_gsp(pep, req, uri)
            end
        end
    end

    # Root
    if isempty(segments)
        accept = _get_accept(req)
        if occursin(CT_HTML, accept)
            return _response(200, _html_landing(server), CT_HTML)
        end
        return _json_response(200, Dict(
            "server" => "RDFLib.jl SPARQL Server",
            "datasets" => ["/" * ep.name for ep in values(server.datasets)],
        ))
    end

    # Admin endpoints: /$/...
    if segments[1] == "\$"
        return _handle_admin(server, req, segments, params)
    end

    # Dataset endpoints: /<name>/...
    ds_name = segments[1]
    ep = get_dataset(server, ds_name)
    isnothing(ep) && return _error_response(404, "Dataset not found: /$ds_name")

    service = length(segments) >= 2 ? segments[2] : ""

    if service == "" || service == ds_name
        if method == "GET"
            return _handle_dataset_info(ep, req)
        end

    elseif service == "sparql" || service == "query"
        if method in ("GET", "POST")
            return _handle_sparql_query(ep, req, params)
        end

    elseif service == "update"
        if method == "POST"
            return _handle_sparql_update(ep, req, params)
        end

    elseif service == "data"
        return _handle_gsp(ep, req, params)

    elseif service == "upload"
        if method == "POST"
            return _handle_upload(ep, req, params)
        end

    elseif service == "reason"
        if method == "POST"
            return _handle_reason(ep, req, params)
        end

    elseif service == "shacl"
        if method == "POST"
            return _handle_shacl(ep, req, params)
        end

    else
        return _error_response(404, "Unknown service: $service")
    end

    _error_response(405, "Method $method not allowed for /$ds_name/$service")
end

# ─── Server Lifecycle ─────────────────────────────────────────────

"""
    serve!(server::SparqlServer; background=false)

Start the SPARQL server. If `background=true`, runs in a background task.

# Example
```julia
server = SparqlServer(port=3330)
add_dataset!(server, "mydata")
serve!(server)
```
"""
function serve!(server::SparqlServer; background::Bool=false)
    handler = req -> begin
        t0 = time()
        resp = try
            _route(server, req)
        catch e
            @error "Unhandled error" exception=(e, catch_backtrace())
            _error_response(500, "Internal server error: $(sprint(showerror, e))")
        end
        if server.verbose
            elapsed = round((time() - t0) * 1000, digits=1)
            status = resp.status
            method = String(req.method)
            path = split(String(req.target), '?')[1]
            @info "$(method) $(path) → $(status) ($(elapsed)ms)"
        end
        resp
    end

    server.started_at = now(UTC)

    if server.verbose
        println("╔══════════════════════════════════════════════════╗")
        println("║     🔷 RDFLib.jl SPARQL Server v1.0.0          ║")
        println("╠══════════════════════════════════════════════════╣")
        println("║  Port:     $(lpad(server.port, 5))                              ║")
        println("║  Datasets: $(lpad(length(server.datasets), 5))                              ║")
        println("║  Features: SPARQL 1.1/1.2 · N3 · SHACL · Jelly ║")
        println("╚══════════════════════════════════════════════════╝")
        println()
        for (name, ep) in server.datasets
            println("  📁 /$name ($(length(ep.dataset.default_graph)) triples)")
            println("     sparql: http://$(server.host):$(server.port)/$name/sparql")
            println("     update: http://$(server.host):$(server.port)/$name/update")
            println("     data:   http://$(server.host):$(server.port)/$name/data")
        end
        println()
        println("  Server ready at http://$(server.host):$(server.port)/")
    end

    if background
        # Non-blocking: store the server handle so stop!() can shut it down.
        server.server = HTTP.serve!(handler, server.host, server.port)
        return server.server
    else
        HTTP.serve(handler, server.host, server.port)
    end
end

"""
    stop!(server::SparqlServer)

Stop the running server.
"""
function stop!(server::SparqlServer)
    if !isnothing(server.server)
        close(server.server)
        server.server = nothing
    end
end
