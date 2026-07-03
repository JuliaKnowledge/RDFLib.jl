# ─── SPARQLStore ─────────────────────────────────────────────────────
# Read-only store backed by a remote SPARQL endpoint.

using Downloads

"""
    SPARQLStore(endpoint_url::AbstractString; default_graph=nothing, timeout=30)

A read-only RDF store backed by a remote SPARQL endpoint.
Pattern matching is translated to SPARQL queries sent via HTTP.

# Examples
```julia
# DBpedia
store = SPARQLStore("https://dbpedia.org/sparql")
g = RDFGraph(store=store)
for t in triples(g, (URIRef("http://dbpedia.org/resource/Julia_(programming_language)"), nothing, nothing))
    println(t)
end

# Wikidata
store = SPARQLStore("https://query.wikidata.org/sparql")
```
"""
mutable struct SPARQLStore <: AbstractStore
    endpoint::String
    update_endpoint::Union{String, Nothing}
    default_graph::Union{String, Nothing}
    timeout::Int
end

function SPARQLStore(endpoint::AbstractString; update_endpoint=nothing, default_graph=nothing, timeout::Int=30)
    SPARQLStore(String(endpoint),
                isnothing(update_endpoint) ? nothing : String(update_endpoint),
                isnothing(default_graph) ? nothing : String(default_graph),
                timeout)
end

# ─── Read-only guards ───────────────────────────────────────────────

function add!(store::SPARQLStore, t::Triple)
    error("SPARQLStore is read-only")
end

function remove!(store::SPARQLStore, pattern::TriplePattern)
    error("SPARQLStore is read-only")
end

# ─── URL encoding ───────────────────────────────────────────────────

const _URL_SAFE = Set{Char}(vcat(
    collect('A':'Z'), collect('a':'z'), collect('0':'9'),
    ['-', '_', '.', '~']
))

function _url_encode(s::AbstractString)
    buf = IOBuffer()
    for c in s
        if c in _URL_SAFE
            write(buf, c)
        else
            for b in codeunits(string(c))
                write(buf, '%', uppercase(string(b, base=16, pad=2)))
            end
        end
    end
    String(take!(buf))
end

# ─── SPARQL query construction ──────────────────────────────────────

const _SPARQL_BNODE_RE = r"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"
const _SPARQL_LANG_RE = r"^[A-Za-z]+(?:-[A-Za-z0-9]+)*$"

function _sparql_term(term::URIRef)
    validate_iri!(term.value)
    "<$(_nt_escape_iri(term.value))>"
end

function _sparql_term(term::BNode)
    occursin(_SPARQL_BNODE_RE, term.id) && !endswith(term.id, ".") ||
        throw(ArgumentError("Invalid blank node label for SPARQL serialization: $(term.id)"))
    "_:$(term.id)"
end

function _sparql_term(term::Literal)
    lex = _nt_escape_string(term.lexical)
    if !isnothing(term.language)
        occursin(_SPARQL_LANG_RE, term.language) ||
            throw(ArgumentError("Invalid language tag for SPARQL serialization: $(term.language)"))
        s = "\"$(lex)\"@$(term.language)"
        if !isnothing(term.direction)
            term.direction in ("ltr", "rtl") ||
                throw(ArgumentError("Invalid base direction for SPARQL serialization: $(term.direction)"))
            s *= "--" * term.direction
        end
        s
    elseif !isnothing(term.datatype)
        validate_iri!(term.datatype.value)
        "\"$(lex)\"^^<$(_nt_escape_iri(term.datatype.value))>"
    else
        "\"$(lex)\""
    end
end

"""
    _sparql_pattern_query(pattern::TriplePattern) -> String

Convert a triple pattern to a SPARQL SELECT query string.
"""
function _sparql_pattern_query(pattern::TriplePattern)
    s, p, o = pattern
    s_str = isnothing(s) ? "?s" : _sparql_term(s)
    p_str = isnothing(p) ? "?p" : _sparql_term(p)
    o_str = isnothing(o) ? "?o" : _sparql_term(o)

    vars = String[]
    isnothing(s) && push!(vars, "?s")
    isnothing(p) && push!(vars, "?p")
    isnothing(o) && push!(vars, "?o")

    select_vars = isempty(vars) ? "*" : join(vars, " ")
    "SELECT $(select_vars) WHERE { $(s_str) $(p_str) $(o_str) }"
end

# ─── HTTP execution ─────────────────────────────────────────────────

function _sparql_http_query(store::SPARQLStore, query::AbstractString)
    params = ["query=" * _url_encode(query)]
    if !isnothing(store.default_graph)
        push!(params, "default-graph-uri=" * _url_encode(store.default_graph))
    end
    url = store.endpoint * "?" * join(params, "&")

    buf = IOBuffer()
    Downloads.download(url, buf;
        headers=["Accept" => "application/sparql-results+json"],
        timeout=store.timeout)
    String(take!(buf))
end

# ─── Parse SPARQL JSON results ──────────────────────────────────────

function _parse_sparql_json_binding_value(val)
    typ = val["type"]
    if typ == "uri"
        URIRef(val["value"])
    elseif typ == "bnode"
        BNode(val["value"])
    elseif typ == "literal" || typ == "typed-literal"
        lang_val = get(val, "xml:lang", get(val, "lang", nothing))
        dir_val = get(val, "its:dir", nothing)
        dt = get(val, "datatype", nothing)
        dt_uri = isnothing(dt) ? nothing : URIRef(dt)
        Literal(val["value"]; datatype=dt_uri, lang=lang_val, direction=dir_val)
    else
        error("Unknown SPARQL result binding type: $typ")
    end
end

"""
    _parse_sparql_json_results(json_str, pattern) -> Vector{Triple}

Parse a SPARQL JSON results response and reconstruct `Triple` objects,
filling in bound positions from the original pattern.
"""
function _parse_sparql_json_results(json_str::AbstractString,
                                     pattern::TriplePattern=(nothing, nothing, nothing))
    data = JSON3.read(json_str)
    bindings = data["results"]["bindings"]
    result = Triple[]
    s_pat, p_pat, o_pat = pattern
    for binding in bindings
        s = isnothing(s_pat) ? _parse_sparql_json_binding_value(binding["s"]) : s_pat
        p = isnothing(p_pat) ? _parse_sparql_json_binding_value(binding["p"]) : p_pat
        o = isnothing(o_pat) ? _parse_sparql_json_binding_value(binding["o"]) : o_pat
        push!(result, Triple(s, p, o))
    end
    result
end

# ─── Store interface ────────────────────────────────────────────────

function triples(store::SPARQLStore, pattern::TriplePattern)
    Channel{Triple}() do ch
        json_str = _sparql_http_query(store, _sparql_pattern_query(pattern))
        for t in _parse_sparql_json_results(json_str, pattern)
            put!(ch, t)
        end
    end
end

function Base.length(store::SPARQLStore)
    query = "SELECT (COUNT(*) AS ?count) WHERE { ?s ?p ?o }"
    json_str = _sparql_http_query(store, query)
    data = JSON3.read(json_str)
    bindings = data["results"]["bindings"]
    isempty(bindings) && return 0
    parse(Int, bindings[1]["count"]["value"])
end

Base.isempty(store::SPARQLStore) = length(store) == 0

# ─── Arbitrary SPARQL query ─────────────────────────────────────────

"""
    sparql_remote(store::SPARQLStore, query::AbstractString) -> Vector{Dict{String, Identifier}}

Execute an arbitrary SPARQL SELECT query against the remote endpoint
and return the results as a vector of variable-name → term dictionaries.
"""
function sparql_remote(store::SPARQLStore, query::AbstractString)
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
