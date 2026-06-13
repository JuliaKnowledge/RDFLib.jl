# ─── SPARQL Query Engine ──────────────────────────────────────────
# Entry points for SPARQL query and update, result serialization,
# and remote SPARQLStore support.

using Downloads: Downloads

# ─── SERVICE Query Cache ───────────────────────────────────────────

const _SERVICE_CACHE = Dict{UInt64, Tuple{Float64, Vector{Dict{String, Identifier}}}}()
const _SERVICE_CACHE_TTL = Ref{Int}(300)

"""
    clear_service_cache!()

Clear all cached SERVICE query results.
"""
function clear_service_cache!()
    empty!(_SERVICE_CACHE)
    nothing
end

"""
    set_service_cache_ttl!(seconds::Int)

Set the TTL (time-to-live) in seconds for cached SERVICE query results. Default is 300.
"""
function set_service_cache_ttl!(seconds::Int)
    seconds >= 0 || throw(ArgumentError("TTL must be non-negative"))
    _SERVICE_CACHE_TTL[] = seconds
    nothing
end

function _service_cache_key(endpoint::AbstractString, query::AbstractString)
    hash((endpoint, query))
end

function _service_cache_lookup(endpoint::AbstractString, query::AbstractString)
    key = _service_cache_key(endpoint, query)
    haskey(_SERVICE_CACHE, key) || return nothing
    ts, results = _SERVICE_CACHE[key]
    if time() - ts > _SERVICE_CACHE_TTL[]
        delete!(_SERVICE_CACHE, key)
        return nothing
    end
    return results
end

function _service_cache_store!(endpoint::AbstractString, query::AbstractString,
                               results::Vector{Dict{String, Identifier}})
    key = _service_cache_key(endpoint, query)
    _SERVICE_CACHE[key] = (time(), results)
    nothing
end

# ─── Query entry point ─────────────────────────────────────────────

"""
    sparql_query(g::RDFGraph, query::AbstractString)

Execute a SPARQL query against a graph.

Returns:
- SELECT → Vector of Dict{String, Identifier} (variable bindings)
- ASK → Bool
- CONSTRUCT → RDFGraph

# Examples
```julia
results = sparql_query(g, \"\"\"
    SELECT ?s ?name WHERE {
        ?s <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://example.org/Person> .
        ?s <http://www.w3.org/2000/01/rdf-schema#label> ?name .
    }
\"\"\")
```
"""
function sparql_query(g::RDFGraph, query::AbstractString)
    ast = sparql_parse(String(query))
    _ast_evaluate(g, ast)
end

# ─── UPDATE types ──────────────────────────────────────────────────

struct _SPARQLInsertData
    triples::Vector{Tuple{Any,Any,Any}}
    prefixes::Dict{String,String}
end

struct _SPARQLDeleteData
    triples::Vector{Tuple{Any,Any,Any}}
    prefixes::Dict{String,String}
end

struct _SPARQLModify
    delete_template::Vector{Tuple{Any,Any,Any}}
    insert_template::Vector{Tuple{Any,Any,Any}}
    patterns::Vector{Any}
    prefixes::Dict{String,String}
    with_graph::Union{URIRef,Nothing}   # WITH <iri> target graph (nothing = default)
end

_SPARQLModify(del, ins, pats, prefixes) = _SPARQLModify(del, ins, pats, prefixes, nothing)

struct _SPARQLClear
    target::String  # "ALL", "DEFAULT", "NAMED"
end

struct _SPARQLLoad
    source::String
    target::Union{String,Nothing}
end

# ─── Resolve variable/term in a binding ────────────────────────────

function _sparql_resolve(term, binding::Dict{String, Identifier})
    if term isa AbstractString  # Variable name
        return get(binding, String(term), nothing)
    end
    term  # Already an Identifier
end

# ─── UPDATE entry point ───────────────────────────────────────────

function sparql_update(g::RDFGraph, query::AbstractString)
    parsed = sparql_parse_update(String(query))
    if parsed isa _SPARQLModify && !isempty(parsed.patterns) && all(p -> p isa SparqlPattern, parsed.patterns)
        _sparql_exec_update(g, parsed, Val(:ast))
    else
        _sparql_exec_update(g, parsed)
    end
    nothing
end

# ─── UPDATE execution ─────────────────────────────────────────────

function _sparql_exec_update(g::RDFGraph, op::_SPARQLClear)
    if op.target in ("ALL", "DEFAULT")
        for t in collect(triples(g))
            remove!(g, t)
        end
    end
end

_sparql_clear_graph!(g::RDFGraph) = (for t in collect(triples(g)); remove!(g, t); end; g)

# ─── Graph management (COPY/MOVE/ADD/CREATE/DROP/CLEAR) ───────────
#
# A plain RDFGraph has no named graphs: only the DEFAULT/ALL targets are
# meaningful; named-graph operations error unless SILENT.

function _sparql_exec_update(g::RDFGraph, op::UpdateGraphOp)
    if op.op == :clear || op.op == :drop
        t = op.target
        if t === :default || t === :all
            _sparql_clear_graph!(g)
        elseif t === :named
            # No named graphs in a plain graph — nothing to do
        else  # specific graph IRI
            op.silent || error("$(uppercase(string(op.op))) GRAPH <$(t.value)> is not supported on a plain RDFGraph; use a Dataset or ConjunctiveGraph")
        end
    elseif op.op == :create
        op.silent || error("CREATE GRAPH is not supported on a plain RDFGraph; use a Dataset or ConjunctiveGraph")
    else  # :copy / :move / :add
        if op.source === :default && op.target === :default
            # source == destination → no-op per SPARQL 1.1 Update
            return
        end
        op.silent || error("$(uppercase(string(op.op))) involving named graphs is not supported on a plain RDFGraph; use a Dataset or ConjunctiveGraph")
    end
    nothing
end

# ─── UPDATE on Dataset / ConjunctiveGraph (named graph support) ────

"""
    sparql_update(ds::Dataset, query::AbstractString)

Execute a SPARQL UPDATE against a dataset. Graph-management operations
(COPY/MOVE/ADD/CREATE/DROP/CLEAR) operate on the dataset's named graphs;
other operations apply to the default graph (or the WITH graph for
DELETE/INSERT ... WHERE).
"""
function sparql_update(ds::Dataset, query::AbstractString)
    parsed = sparql_parse_update(String(query))
    if parsed isa UpdateGraphOp
        _sparql_exec_update(ds, parsed)
    else
        target_g = ds.default_graph
        if parsed isa _SPARQLModify && !isnothing(parsed.with_graph)
            target_g = _get_or_create_graph!(ds, parsed.with_graph)
        end
        if parsed isa _SPARQLModify && !isempty(parsed.patterns) && all(p -> p isa SparqlPattern, parsed.patterns)
            _sparql_exec_update(target_g, parsed, Val(:ast))
        else
            _sparql_exec_update(target_g, parsed)
        end
    end
    nothing
end

# ConjunctiveGraph is defined after this file is included, so delegate via a
# duck-typed fallback: any wrapper exposing a `dataset::Dataset` field
# (e.g. ConjunctiveGraph) updates through its dataset.
function sparql_update(x, query::AbstractString)
    if hasfield(typeof(x), :dataset) && getfield(x, :dataset) isa Dataset
        return sparql_update(getfield(x, :dataset)::Dataset, query)
    end
    throw(MethodError(sparql_update, (x, query)))
end

function _sparql_exec_update(ds::Dataset, op::UpdateGraphOp)
    if op.op == :create
        if haskey(ds.named_graphs, op.target) && !op.silent
            error("CREATE GRAPH: graph <$(op.target.value)> already exists")
        end
        add_graph(ds, op.target::URIRef)
    elseif op.op == :clear || op.op == :drop
        t = op.target
        if t === :default
            _sparql_clear_graph!(ds.default_graph)
        elseif t === :named
            if op.op == :drop
                empty!(ds.named_graphs)
            else
                foreach(_sparql_clear_graph!, values(ds.named_graphs))
            end
        elseif t === :all
            _sparql_clear_graph!(ds.default_graph)
            if op.op == :drop
                empty!(ds.named_graphs)
            else
                foreach(_sparql_clear_graph!, values(ds.named_graphs))
            end
        else  # specific graph IRI
            g = get(ds.named_graphs, t, nothing)
            if isnothing(g)
                op.silent || error("$(uppercase(string(op.op))) GRAPH: no such graph <$(t.value)>")
            elseif op.op == :drop
                remove_graph(ds, t::URIRef)
            else
                _sparql_clear_graph!(g)
            end
        end
    else  # :copy / :move / :add
        op.source == op.target && return nothing  # same graph → no-op
        src = op.source === :default ? ds.default_graph : get(ds.named_graphs, op.source, nothing)
        if isnothing(src)
            op.silent && return nothing
            error("$(uppercase(string(op.op))): source graph <$(op.source.value)> does not exist")
        end
        dst = op.target === :default ? ds.default_graph : _get_or_create_graph!(ds, op.target::URIRef)
        op.op == :copy && _sparql_clear_graph!(dst)
        for t in collect(triples(src))
            add!(dst, t)
        end
        if op.op == :move
            if op.source === :default
                _sparql_clear_graph!(ds.default_graph)
            else
                remove_graph(ds, op.source::URIRef)
            end
        end
    end
    nothing
end

function _sparql_exec_update(g::RDFGraph, op::_SPARQLInsertData)
    for (s, p, o) in op.triples
        s isa Node && p isa URIRef && o isa Identifier && add!(g, Triple(s, p, o))
    end
end

function _sparql_exec_update(g::RDFGraph, op::_SPARQLDeleteData)
    for (s, p, o) in op.triples
        s isa Node && p isa URIRef && o isa Identifier && remove!(g, Triple(s, p, o))
    end
end

function _sparql_exec_update(g::RDFGraph, op::_SPARQLModify)
    # Use AST evaluation for patterns
    ast_patterns = Vector{SparqlPattern}([p for p in op.patterns if p isa SparqlPattern])
    bindings = if !isempty(ast_patterns)
        _ast_eval_patterns(g, ast_patterns)
    else
        Dict{String, Identifier}[Dict{String, Identifier}()]
    end
    # Delete first
    for binding in bindings
        delete_bnodes = Dict{String, BNode}()
        for (s_t, p_t, o_t) in op.delete_template
            s = _resolve_template_term(s_t, binding, delete_bnodes)
            p = _resolve_template_term(p_t, binding, delete_bnodes)
            o = _resolve_template_term(o_t, binding, delete_bnodes)
            (isnothing(s) || isnothing(p) || isnothing(o)) && continue
            s isa Node && p isa URIRef && o isa Identifier && remove!(g, Triple(s, p, o))
        end
    end
    # Then insert
    for binding in bindings
        insert_bnodes = Dict{String, BNode}()
        for (s_t, p_t, o_t) in op.insert_template
            s = _resolve_template_term(s_t, binding, insert_bnodes)
            p = _resolve_template_term(p_t, binding, insert_bnodes)
            o = _resolve_template_term(o_t, binding, insert_bnodes)
            (isnothing(s) || isnothing(p) || isnothing(o)) && continue
            s isa Node && p isa URIRef && o isa Identifier && add!(g, Triple(s, p, o))
        end
    end
end

function _sparql_exec_update(g::RDFGraph, op::_SPARQLLoad)
    tmpfile = Downloads.download(op.source)
    parse_rdf!(g, read(tmpfile, String))
    rm(tmpfile, force=true)
end

# AST-aware SPARQL UPDATE execution (patterns are SparqlPattern nodes)
function _sparql_exec_update(g::RDFGraph, op::_SPARQLModify, ::Val{:ast})
    bindings = _ast_eval_patterns(g, Vector{SparqlPattern}(op.patterns))
    for binding in bindings
        delete_bnodes = Dict{String, BNode}()
        for (s_t, p_t, o_t) in op.delete_template
            s = _resolve_template_term(s_t, binding, delete_bnodes)
            p = _resolve_template_term(p_t, binding, delete_bnodes)
            o = _resolve_template_term(o_t, binding, delete_bnodes)
            (isnothing(s) || isnothing(p) || isnothing(o)) && continue
            s isa Node && p isa URIRef && o isa Identifier && remove!(g, Triple(s, p, o))
        end
    end
    for binding in bindings
        insert_bnodes = Dict{String, BNode}()
        for (s_t, p_t, o_t) in op.insert_template
            s = _resolve_template_term(s_t, binding, insert_bnodes)
            p = _resolve_template_term(p_t, binding, insert_bnodes)
            o = _resolve_template_term(o_t, binding, insert_bnodes)
            (isnothing(s) || isnothing(p) || isnothing(o)) && continue
            s isa Node && p isa URIRef && o isa Identifier && add!(g, Triple(s, p, o))
        end
    end
end

# ─── SPARQL Result Serialization ──────────────────────────────────

"""
    sparql_results_json(results; variables=nothing)

Serialize SPARQL query results to JSON (SPARQL Results JSON format).
`results` can be a `Vector{Dict{String,Identifier}}` (SELECT) or `Bool` (ASK).
"""
function sparql_results_json(results; variables=nothing)
    if results isa Bool
        return "{\"head\":{},\"boolean\":$(results)}"
    end

    vars = if !isnothing(variables)
        variables
    elseif !isempty(results)
        sort(collect(keys(results[1])))
    else
        String[]
    end

    io = IOBuffer(; sizehint=max(256, length(results) * length(vars) * 80))
    write(io, "{\"head\":{\"vars\":[")
    for (i, v) in enumerate(vars)
        i > 1 && write(io, ',')
        write(io, '"'); write(io, v); write(io, '"')
    end
    write(io, "]},\"results\":{\"bindings\":[")
    for (i, binding) in enumerate(results)
        i > 1 && write(io, ',')
        write(io, '{')
        first_var = true
        for v in vars
            val = get(binding, v, nothing)
            isnothing(val) && continue
            !first_var && write(io, ',')
            first_var = false
            write(io, '"'); write(io, v); write(io, "\":")
            _sparql_json_term!(io, val)
        end
        write(io, '}')
    end
    write(io, "]}}")
    String(take!(io))
end

function _sparql_json_term!(io::IOBuffer, val::URIRef)
    write(io, "{\"type\":\"uri\",\"value\":\"")
    write(io, val.value)
    write(io, "\"}")
end

function _sparql_json_term!(io::IOBuffer, val::BNode)
    write(io, "{\"type\":\"bnode\",\"value\":\"")
    write(io, val.id)
    write(io, "\"}")
end

function _sparql_json_term!(io::IOBuffer, val::Literal)
    write(io, "{\"type\":\"literal\",\"value\":\"")
    _sparql_json_write_escaped!(io, val.lexical)
    write(io, '"')
    if !isnothing(val.language) && !isempty(val.language)
        write(io, ",\"xml:lang\":\"")
        write(io, val.language)
        write(io, '"')
    elseif !isnothing(val.datatype) && val.datatype != URIRef(_XSD * "string")
        write(io, ",\"datatype\":\"")
        write(io, val.datatype.value)
        write(io, '"')
    end
    write(io, '}')
end

# Write JSON-escaped string directly to IO without allocating intermediate strings
function _sparql_json_write_escaped!(io::IOBuffer, s::AbstractString)
    for c in s
        if c == '\\'
            write(io, "\\\\")
        elseif c == '"'
            write(io, "\\\"")
        elseif c == '\n'
            write(io, "\\n")
        elseif c == '\r'
            write(io, "\\r")
        elseif c == '\t'
            write(io, "\\t")
        else
            write(io, c)
        end
    end
end

"""
    sparql_results_xml(results; variables=nothing)

Serialize SPARQL query results to XML (SPARQL Results XML format).
"""
function sparql_results_xml(results; variables=nothing)
    if results isa Bool
        return "<?xml version=\"1.0\"?>\n<sparql xmlns=\"http://www.w3.org/2005/sparql-results#\">\n  <head/>\n  <boolean>$(results)</boolean>\n</sparql>"
    end

    vars = if !isnothing(variables)
        variables
    elseif !isempty(results)
        sort(collect(keys(results[1])))
    else
        String[]
    end

    io = IOBuffer()
    write(io, "<?xml version=\"1.0\"?>\n")
    write(io, "<sparql xmlns=\"http://www.w3.org/2005/sparql-results#\">\n")
    write(io, "  <head>\n")
    for v in vars
        write(io, "    <variable name=\"$(v)\"/>\n")
    end
    write(io, "  </head>\n  <results>\n")
    for binding in results
        write(io, "    <result>\n")
        for v in vars
            val = get(binding, v, nothing)
            isnothing(val) && continue
            write(io, "      <binding name=\"$(v)\">")
            write(io, _sparql_xml_term(val))
            write(io, "</binding>\n")
        end
        write(io, "    </result>\n")
    end
    write(io, "  </results>\n</sparql>")
    String(take!(io))
end

function _sparql_xml_term(val::URIRef)
    "<uri>$(_sparql_xml_escape(val.value))</uri>"
end

function _sparql_xml_term(val::BNode)
    "<bnode>$(val.id)</bnode>"
end

function _sparql_xml_term(val::Literal)
    io = IOBuffer()
    write(io, "<literal")
    if !isnothing(val.language) && !isempty(val.language)
        write(io, " xml:lang=\"$(val.language)\"")
    elseif !isnothing(val.datatype) && val.datatype != URIRef(_XSD * "string")
        write(io, " datatype=\"$(val.datatype.value)\"")
    end
    write(io, ">$(_sparql_xml_escape(val.lexical))</literal>")
    String(take!(io))
end

function _sparql_xml_escape(s::AbstractString)
    s = replace(s, "&" => "&amp;")
    s = replace(s, "<" => "&lt;")
    s = replace(s, ">" => "&gt;")
    s = replace(s, "\"" => "&quot;")
    s
end

"""
    sparql_results_csv(results; variables=nothing)

Serialize SPARQL query results to CSV (SPARQL Results CSV format).
"""
function sparql_results_csv(results; variables=nothing)
    if results isa Bool
        return results ? "true" : "false"
    end

    vars = if !isnothing(variables)
        variables
    elseif !isempty(results)
        sort(collect(keys(results[1])))
    else
        String[]
    end

    io = IOBuffer()
    write(io, join(vars, ","))
    write(io, "\n")
    for binding in results
        vals = String[]
        for v in vars
            val = get(binding, v, nothing)
            if isnothing(val)
                push!(vals, "")
            elseif val isa URIRef
                push!(vals, val.value)
            elseif val isa BNode
                push!(vals, "_:" * val.id)
            elseif val isa Literal
                s = val.lexical
                if occursin(',', s) || occursin('"', s) || occursin('\n', s)
                    push!(vals, "\"" * replace(s, "\"" => "\"\"") * "\"")
                else
                    push!(vals, s)
                end
            else
                push!(vals, string(val))
            end
        end
        write(io, join(vals, ","))
        write(io, "\n")
    end
    String(take!(io))
end

# ─── Remote SPARQL query/update for SPARQLStore ────────────────────

"""
    sparql_query(g::RDFGraph{SPARQLStore}, query::AbstractString)

Execute a SPARQL query against the remote endpoint.
Supports SELECT (returns Vector{Dict}), ASK (returns Bool),
CONSTRUCT/DESCRIBE (returns RDFGraph).
"""
function sparql_query(g::RDFGraph{SPARQLStore}, query::AbstractString)
    store = g.store
    q_stripped = replace(strip(query), r"^\s*(PREFIX\s+\S+:\s*<[^>]*>\s*|BASE\s*<[^>]*>\s*|VERSION\s+\S+\s*)"im => "")
    q_upper = uppercase(strip(q_stripped))

    if startswith(q_upper, "ASK")
        return _remote_ask(store, query)
    elseif startswith(q_upper, "CONSTRUCT") || startswith(q_upper, "DESCRIBE")
        return _remote_graph(store, query)
    else
        return _remote_select(store, query)
    end
end

function _remote_select(store::SPARQLStore, query::AbstractString)
    json_str = _sparql_http_query(store, query)
    data = JSON3.read(json_str)
    bindings = data["results"]["bindings"]
    result = Vector{Dict{String, Identifier}}()
    for binding in bindings
        row = Dict{String, Identifier}()
        for (var, val) in pairs(binding)
            row[String(var)] = _parse_sparql_json_binding_value(val)
        end
        push!(result, row)
    end
    result
end

function _remote_ask(store::SPARQLStore, query::AbstractString)
    json_str = _sparql_http_query(store, query)
    data = JSON3.read(json_str)
    return get(data, "boolean", false)
end

function _remote_graph(store::SPARQLStore, query::AbstractString)
    params = ["query=" * _url_encode(query)]
    if !isnothing(store.default_graph)
        push!(params, "default-graph-uri=" * _url_encode(store.default_graph))
    end
    url = store.endpoint * "?" * join(params, "&")

    buf = IOBuffer()
    Downloads.download(url, buf;
        headers=["Accept" => "text/turtle, application/n-triples"],
        timeout=store.timeout)
    body = String(take!(buf))
    g = RDFGraph()
    try
        parse_rdf!(g, body, TurtleFormat())
    catch
        parse_rdf!(g, body, NTriplesFormat())
    end
    g
end

"""
    sparql_update(g::RDFGraph{SPARQLStore}, query::AbstractString)

Execute a SPARQL UPDATE operation against the remote endpoint.
Requires `update_endpoint` to be set on the SPARQLStore.
"""
function sparql_update(g::RDFGraph{SPARQLStore}, query::AbstractString)
    store = g.store
    endpoint = something(store.update_endpoint, store.endpoint)
    Downloads.request(endpoint;
        method="POST",
        headers=["Content-Type" => "application/sparql-update"],
        input=IOBuffer(query),
        output=devnull,
        timeout=store.timeout)
    nothing
end
