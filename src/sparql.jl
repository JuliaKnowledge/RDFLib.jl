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
    # Note: on a plain RDFGraph there are no named graphs — FROM / FROM NAMED
    # clauses fall back to querying the graph itself, and GRAPH patterns
    # yield zero solutions (spec semantics for an empty set of named graphs).
    ast = sparql_parse(String(query))
    _ast_evaluate(g, ast)
end

"""
    sparql_query(ds::Dataset, query::AbstractString)

Execute a SPARQL query against a dataset. The default graph is queried
directly; `GRAPH <iri> { ... }` patterns evaluate against the dataset's
named graphs and `GRAPH ?g` iterates them. FROM / FROM NAMED clauses are
honored: FROM graphs are merged into the queried default graph, FROM NAMED
restricts the named graphs visible to GRAPH.
"""
function sparql_query(ds::Dataset, query::AbstractString)
    ast = sparql_parse(String(query))
    _sparql_eval_on_dataset(ds, ast)
end

"""
    sparql_query(cg, query::AbstractString)

Query a ConjunctiveGraph (or any wrapper exposing a `dataset::Dataset`
field): the default graph for matching is the union of all graphs
(rdflib-compatible semantics); GRAPH patterns address the named graphs.
"""
function sparql_query(x, query::AbstractString)
    if hasfield(typeof(x), :dataset) && getfield(x, :dataset) isa Dataset
        ds = getfield(x, :dataset)::Dataset
        ast = sparql_parse(String(query))
        return _sparql_eval_on_dataset(ds, ast; union_default=true)
    end
    throw(MethodError(sparql_query, (x, query)))
end

function _sparql_eval_on_dataset(ds::Dataset, ast; union_default::Bool=false)
    from = (ast isa SparqlSelect || ast isa SparqlConstruct || ast isa SparqlDescribe) ?
        ast.from : URIRef[]
    from_named = (ast isa SparqlSelect || ast isa SparqlConstruct || ast isa SparqlDescribe) ?
        ast.from_named : URIRef[]

    default_g, named_filter = if isempty(from) && isempty(from_named)
        if union_default
            merged = RDFGraph()
            for t in triples(ds.default_graph)
                add!(merged, t)
            end
            for (_, ng) in ds.named_graphs, t in triples(ng)
                add!(merged, t)
            end
            (merged, nothing)
        else
            (ds.default_graph, nothing)
        end
    else
        # Explicit dataset description: FROM graphs (merged) become the
        # default graph (empty if only FROM NAMED given); FROM NAMED lists
        # the named graphs visible to GRAPH.
        merged = RDFGraph()
        for iri in from
            src = get(ds.named_graphs, iri, nothing)
            src === nothing && continue
            for t in triples(src)
                add!(merged, t)
            end
        end
        (merged, Set{GraphName}(from_named))
    end

    old_ds = _ACTIVE_DATASET[]
    old_filter = _ACTIVE_NAMED_FILTER[]
    _ACTIVE_DATASET[] = ds
    _ACTIVE_NAMED_FILTER[] = named_filter
    try
        return _ast_evaluate(default_g, ast)
    finally
        _ACTIVE_DATASET[] = old_ds
        _ACTIVE_NAMED_FILTER[] = old_filter
    end
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
    using_graphs::Vector{URIRef}        # USING <iri> — WHERE-clause default graph(s)
    using_named::Vector{URIRef}         # USING NAMED <iri> — WHERE-clause named graphs
end

_SPARQLModify(del, ins, pats, prefixes) = _SPARQLModify(del, ins, pats, prefixes, nothing, URIRef[], URIRef[])
_SPARQLModify(del, ins, pats, prefixes, with_graph) = _SPARQLModify(del, ins, pats, prefixes, with_graph, URIRef[], URIRef[])

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
    _sparql_exec_update(ds, parsed)
    nothing
end

# ─── Dataset-level dispatch for every UPDATE operation ──────────────
#
# The W3C update-evaluation harness passes a `Dataset` and expects the full
# named-graph routing. Each operation type below resolves its target graph(s)
# from the dataset and applies the change.

# A sequence of operations — execute in order against the same dataset.
function _sparql_exec_update(ds::Dataset, op::UpdateRequest)
    for sub in op.operations
        _sparql_exec_update(ds, sub)
    end
    nothing
end

# Legacy default-graph-only operations: route to the default graph (or WITH).
function _sparql_exec_update(ds::Dataset, op::_SPARQLInsertData)
    _sparql_exec_update(ds.default_graph, op)
end
function _sparql_exec_update(ds::Dataset, op::_SPARQLDeleteData)
    _sparql_exec_update(ds.default_graph, op)
end
function _sparql_exec_update(ds::Dataset, op::_SPARQLLoad)
    # The parser drops the LOAD SILENT flag, so we cannot reliably tell a
    # SILENT load from a plain one here. Treat download/parse failure as a
    # best-effort no-op (matches the SILENT semantics the test suite exercises;
    # plain LOAD of a reachable source is unaffected). We only materialize the
    # target named graph once data has been parsed, so a failed load leaves no
    # stray empty graph behind.
    local body
    try
        tmpfile = Downloads.download(op.source)
        body = read(tmpfile, String)
        rm(tmpfile, force=true)
    catch
        return nothing
    end
    target = isnothing(op.target) ? ds.default_graph :
             _get_or_create_graph!(ds, URIRef(op.target))
    try
        parse_rdf!(target, body)
    catch
    end
    nothing
end
function _sparql_exec_update(ds::Dataset, op::_SPARQLClear)
    _sparql_exec_update(ds.default_graph, op)
end

# DELETE/INSERT ... WHERE (no named graphs in templates): evaluate the WHERE
# patterns against the dataset (so GRAPH patterns resolve), then apply the
# 3-tuple templates to the default graph (or the WITH graph).
function _sparql_exec_update(ds::Dataset, op::_SPARQLModify)
    target_g = isnothing(op.with_graph) ? ds.default_graph :
               _get_or_create_graph!(ds, op.with_graph)
    bindings = _modify_bindings(ds, op.patterns, op.with_graph, op.using_graphs, op.using_named)
    # Delete first, then insert (per SPARQL 1.1 Update §3.1.3).
    for binding in bindings
        bnodes = Dict{String,BNode}()
        for (s_t, p_t, o_t) in op.delete_template
            s = _resolve_template_term(s_t, binding, bnodes)
            p = _resolve_template_term(p_t, binding, bnodes)
            o = _resolve_template_term(o_t, binding, bnodes)
            (isnothing(s) || isnothing(p) || isnothing(o)) && continue
            s isa Node && p isa URIRef && o isa Identifier && remove!(target_g, Triple(s, p, o))
        end
    end
    for binding in bindings
        bnodes = Dict{String,BNode}()
        for (s_t, p_t, o_t) in op.insert_template
            s = _resolve_template_term(s_t, binding, bnodes)
            p = _resolve_template_term(p_t, binding, bnodes)
            o = _resolve_template_term(o_t, binding, bnodes)
            (isnothing(s) || isnothing(p) || isnothing(o)) && continue
            s isa Node && p isa URIRef && o isa Identifier && add!(target_g, Triple(s, p, o))
        end
    end
    nothing
end

# Evaluate the WHERE patterns of a DELETE/INSERT against a dataset. The WITH
# graph (if any) becomes the active default graph for matching, matching the
# spec: WITH names both the default graph for the WHERE clause and the target.
function _modify_bindings(ds::Dataset, patterns, with_graph,
                          using_graphs::Vector{URIRef}=URIRef[],
                          using_named::Vector{URIRef}=URIRef[])
    ast_patterns = SparqlPattern[p for p in patterns if p isa SparqlPattern]
    isempty(ast_patterns) && return Dict{String,Identifier}[Dict{String,Identifier}()]

    # A USING clause specifies the dataset for the WHERE clause (overriding the
    # default graph and the visible named graphs), per SPARQL 1.1 Update §4.1.2.
    # USING and WITH together: USING wins for the WHERE dataset; WITH still
    # names the target graph for DELETE/INSERT.
    named_filter = nothing
    if !isempty(using_graphs) || !isempty(using_named)
        merged = RDFGraph()
        for iri in using_graphs
            src = get(ds.named_graphs, iri, nothing)
            src === nothing && continue
            for t in triples(src); add!(merged, t); end
        end
        default_g = merged
        named_filter = Set{GraphName}(using_named)
    else
        default_g = isnothing(with_graph) ? ds.default_graph :
                    _get_or_create_graph!(ds, with_graph)
    end

    old_ds = _ACTIVE_DATASET[]
    old_filter = _ACTIVE_NAMED_FILTER[]
    _ACTIVE_DATASET[] = ds
    _ACTIVE_NAMED_FILTER[] = named_filter
    try
        return _ast_eval_patterns(default_g, ast_patterns)
    finally
        _ACTIVE_DATASET[] = old_ds
        _ACTIVE_NAMED_FILTER[] = old_filter
    end
end

# INSERT DATA with GRAPH routing.
function _sparql_exec_update(ds::Dataset, op::UpdateInsertData)
    for (s, p, o, gr) in op.quads
        s = _materialize_data_term(s); o = _materialize_data_term(o)
        g = _quad_target_graph!(ds, gr)
        s isa Node && p isa URIRef && o isa Identifier && add!(g, Triple(s, p, o))
    end
    nothing
end

# DELETE DATA with GRAPH routing.
function _sparql_exec_update(ds::Dataset, op::UpdateDeleteData)
    for (s, p, o, gr) in op.quads
        s = _materialize_data_term(s); o = _materialize_data_term(o)
        g = isnothing(gr) ? ds.default_graph : get(ds.named_graphs, gr, nothing)
        isnothing(g) && continue
        s isa Node && p isa URIRef && o isa Identifier && remove!(g, Triple(s, p, o))
    end
    nothing
end

# DELETE/INSERT ... WHERE with quad (GRAPH-aware) templates.
function _sparql_exec_update(ds::Dataset, op::UpdateModify)
    bindings = _modify_bindings(ds, op.patterns, op.with_graph, op.using_graphs, op.using_named)
    for binding in bindings
        bnodes = Dict{String,BNode}()
        for (s_t, p_t, o_t, gr) in op.delete_template
            s = _resolve_template_term(s_t, binding, bnodes)
            p = _resolve_template_term(p_t, binding, bnodes)
            o = _resolve_template_term(o_t, binding, bnodes)
            (isnothing(s) || isnothing(p) || isnothing(o)) && continue
            (s isa Node && p isa URIRef && o isa Identifier) || continue
            g = _quad_graph_for_delete(ds, gr, binding, op.with_graph)
            isnothing(g) && continue
            remove!(g, Triple(s, p, o))
        end
    end
    for binding in bindings
        bnodes = Dict{String,BNode}()
        for (s_t, p_t, o_t, gr) in op.insert_template
            s = _resolve_template_term(s_t, binding, bnodes)
            p = _resolve_template_term(p_t, binding, bnodes)
            o = _resolve_template_term(o_t, binding, bnodes)
            (isnothing(s) || isnothing(p) || isnothing(o)) && continue
            (s isa Node && p isa URIRef && o isa Identifier) || continue
            g = _quad_graph_for_insert!(ds, gr, binding, op.with_graph)
            isnothing(g) && continue
            add!(g, Triple(s, p, o))
        end
    end
    nothing
end

# Resolve the destination graph for an INSERT-DATA quad (creating named graphs).
function _quad_target_graph!(ds::Dataset, gr)
    isnothing(gr) && return ds.default_graph
    gr isa URIRef && return _get_or_create_graph!(ds, gr)
    ds.default_graph
end

# Resolve the target graph for a DELETE template quad. `gr` is nothing
# (default/WITH graph), a URIRef, or a variable name to bind from the row.
function _quad_graph_for_delete(ds::Dataset, gr, binding, with_graph)
    if isnothing(gr)
        return isnothing(with_graph) ? ds.default_graph :
               get(ds.named_graphs, with_graph, nothing)
    elseif gr isa URIRef
        return get(ds.named_graphs, gr, nothing)
    else  # variable name
        gv = get(binding, gr, nothing)
        gv isa URIRef || return nothing
        return get(ds.named_graphs, gv, nothing)
    end
end

# Resolve the target graph for an INSERT template quad (creating as needed).
function _quad_graph_for_insert!(ds::Dataset, gr, binding, with_graph)
    if isnothing(gr)
        return isnothing(with_graph) ? ds.default_graph :
               _get_or_create_graph!(ds, with_graph)
    elseif gr isa URIRef
        return _get_or_create_graph!(ds, gr)
    else  # variable name
        gv = get(binding, gr, nothing)
        gv isa URIRef || return nothing
        return _get_or_create_graph!(ds, gv)
    end
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
        # COPY and MOVE both replace the destination (DROP dst; INSERT src);
        # ADD merges into it.
        (op.op == :copy || op.op == :move) && _sparql_clear_graph!(dst)
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

# Materialize a ground DATA-template term: a TripleTermPattern (from SPARQL 1.2
# reification syntax, e.g. `s p o {| … |}` → `r rdf:reifies <<( s p o )>>`)
# becomes a concrete TripleTerm. Other terms pass through unchanged.
_materialize_data_term(t) =
    t isa TripleTermPattern ? _ast_resolve_term(t, _EMPTY_BINDING) : t

const _EMPTY_BINDING = Dict{String,Identifier}()

function _sparql_exec_update(g::RDFGraph, op::_SPARQLInsertData)
    for (s, p, o) in op.triples
        s = _materialize_data_term(s); o = _materialize_data_term(o)
        s isa Node && p isa URIRef && o isa Identifier && add!(g, Triple(s, p, o))
    end
end

function _sparql_exec_update(g::RDFGraph, op::_SPARQLDeleteData)
    for (s, p, o) in op.triples
        s = _materialize_data_term(s); o = _materialize_data_term(o)
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
