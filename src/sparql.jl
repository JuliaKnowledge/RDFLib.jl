# ─── Basic SPARQL Query Engine ──────────────────────────────────────
# Supports SELECT, ASK, CONSTRUCT, DESCRIBE with basic graph patterns and filters.

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
    parsed = _sparql_parse(String(query), g)
    _sparql_evaluate(g, parsed)
end

# ─── Query types ────────────────────────────────────────────────────

struct _Aggregate
    func::String       # "COUNT", "SUM", "AVG", "MIN", "MAX", "GROUP_CONCAT", "SAMPLE"
    var::String        # variable being aggregated
    alias::String      # AS alias
    distinct::Bool     # COUNT(DISTINCT ?x)
end

struct _SelectExpr
    expr::String
    alias::String
end

struct _SPARQLSelect
    variables::Vector{String}   # empty = SELECT *
    patterns::Vector{Any}       # BGP triples + filters
    prefixes::Dict{String, String}
    limit::Union{Int, Nothing}
    offset::Int
    order_by::Vector{Tuple{String, Symbol}}  # (variable, :asc or :desc)
    distinct::Bool
    reduced::Bool
    aggregates::Vector{_Aggregate}
    group_by::Vector{String}
    having::Union{AbstractString, Nothing}
    select_exprs::Vector{_SelectExpr}
end

struct _SPARQLAsk
    patterns::Vector{Any}
    prefixes::Dict{String, String}
end

struct _SPARQLConstruct
    template::Vector{Tuple{Any, Any, Any}}
    patterns::Vector{Any}
    prefixes::Dict{String, String}
end

struct _BGPTriple
    s::Any  # String (variable) or Identifier
    p::Any
    o::Any
end

struct _Filter
    expr::AbstractString
end

struct _Union
    left::Vector{Any}
    right::Vector{Any}
end

struct _Bind
    expr::AbstractString
    var::String
end

struct _FilterExists
    patterns::Vector{Any}
    negated::Bool
end

# ─── Property Path types ───────────────────────────────────────────

abstract type _PathExpr end

struct _PathURI <: _PathExpr
    uri::URIRef
end

struct _PathSequence <: _PathExpr
    steps::Vector{_PathExpr}
end

struct _PathAlternative <: _PathExpr
    options::Vector{_PathExpr}
end

struct _PathInverse <: _PathExpr
    path::_PathExpr
end

struct _PathZeroOrMore <: _PathExpr
    path::_PathExpr
end

struct _PathOneOrMore <: _PathExpr
    path::_PathExpr
end

struct _PathZeroOrOne <: _PathExpr
    path::_PathExpr
end

struct _PathNegatedSet <: _PathExpr
    uris::Vector{URIRef}
end

# ─── DESCRIBE query type ───────────────────────────────────────────

struct _SPARQLDescribe
    terms::Vector{Any}          # URIRef or variable names (String)
    patterns::Vector{Any}
    prefixes::Dict{String, String}
end

# ─── UPDATE operation types ────────────────────────────────────────

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
end

struct _SPARQLClear
    target::String  # "ALL", "DEFAULT", "NAMED"
end

struct _SPARQLLoad
    source::String
    target::Union{String,Nothing}
end

# ─── MINUS, VALUES, Subquery types ─────────────────────────────────

struct _Minus
    patterns::Vector{Any}
end

struct _Values
    variables::Vector{String}
    values::Vector{Vector{Union{Identifier, Nothing}}}
end

struct _Subquery
    query::_SPARQLSelect
end

struct _GraphPattern
    graph_term::Any  # URIRef or variable name (String)
    patterns::Vector{Any}
end

struct _Service
    endpoint::Any  # URIRef or variable name (String)
    patterns::Vector{Any}
    silent::Bool
end

# ─── Parser ─────────────────────────────────────────────────────────

function _sparql_parse(query::AbstractString, g::RDFGraph)
    q = strip(query)
    prefixes = Dict{String, String}()

    # Parse VERSION declaration (SPARQL 1.2)
    m = match(r"^\s*VERSION\s+'([^']*)'\s*"i, q)
    if !isnothing(m)
        q = q[m.offset + length(m.match):end]
    end

    # Parse BASE declaration
    while true
        m = match(r"^\s*BASE\s+<([^>]*)>\s*"i, q)
        isnothing(m) && break
        q = q[m.offset + length(m.match):end]
    end

    # Parse PREFIX declarations
    while true
        m = match(r"^\s*PREFIX\s+(\w*):\s*<([^>]*)>\s*"i, q)
        isnothing(m) && break
        prefixes[m.captures[1]] = m.captures[2]
        q = q[m.offset + length(m.match):end]
    end

    # Add graph namespace bindings as fallbacks
    for (prefix, uri) in namespaces(g)
        if !haskey(prefixes, prefix)
            prefixes[prefix] = uri
        end
    end

    # Strip FROM / FROM NAMED clauses (appear between SELECT clause and WHERE)
    while true
        m_fn = match(r"\bFROM\s+NAMED\s+<([^>]*)>"i, q)
        if !isnothing(m_fn)
            q = replace(q, m_fn.match => "", count=1)
            continue
        end
        m_f = match(r"\bFROM\s+<([^>]*)>"i, q)
        if !isnothing(m_f)
            q = replace(q, m_f.match => "", count=1)
            continue
        end
        break
    end

    q_upper = uppercase(strip(q))

    if startswith(q_upper, "SELECT")
        return _sparql_parse_select(q, prefixes)
    elseif startswith(q_upper, "ASK")
        return _sparql_parse_ask(q, prefixes)
    elseif startswith(q_upper, "CONSTRUCT")
        return _sparql_parse_construct(q, prefixes)
    elseif startswith(q_upper, "DESCRIBE")
        return _sparql_parse_describe(q, prefixes)
    else
        throw(ArgumentError("Unsupported SPARQL query type"))
    end
end

function _sparql_parse_select(q::AbstractString, prefixes::Dict{String,String})
    # Parse SELECT [DISTINCT|REDUCED] vars WHERE { patterns } [GROUP BY] [HAVING] [ORDER BY] [LIMIT] [OFFSET]
    m = match(r"SELECT\s+(DISTINCT\s+|REDUCED\s+)?(.*?)\s*WHERE\s*\{(.*)\}\s*(GROUP\s+BY\s+((?:\?\w+\s*)+))?\s*(HAVING\s*\((.+)\))?\s*(ORDER\s+BY\s+(.*?))?\s*(LIMIT\s+(\d+))?\s*(OFFSET\s+(\d+))?\s*$"is, q)
    isnothing(m) && throw(ArgumentError("Invalid SELECT query"))

    modifier = isnothing(m.captures[1]) ? "" : uppercase(strip(m.captures[1]))
    distinct = modifier == "DISTINCT"
    reduced = modifier == "REDUCED"

    # Parse variables, aggregates, and select expressions from SELECT clause
    vars_str = strip(m.captures[2])
    aggregates = _Aggregate[]
    select_exprs = _SelectExpr[]
    agg_regex = r"\(\s*(COUNT|SUM|AVG|MIN|MAX|GROUP_CONCAT|SAMPLE)\s*\(\s*(DISTINCT\s+)?\?(\w+)\s*\)\s+AS\s+\?(\w+)\s*\)"i
    for m_agg in eachmatch(agg_regex, vars_str)
        push!(aggregates, _Aggregate(
            uppercase(String(m_agg.captures[1])),
            String(m_agg.captures[3]),
            String(m_agg.captures[4]),
            !isnothing(m_agg.captures[2])
        ))
    end
    # Parse general select expressions: (expr AS ?alias) that are NOT aggregates
    # Support up to 3 levels of nested parentheses
    sel_expr_regex = r"\(([^()]*(?:\([^()]*(?:\([^()]*\)[^()]*)*\)[^()]*)*)\s+AS\s+\?(\w+)\s*\)"i
    for m_se in eachmatch(sel_expr_regex, vars_str)
        inner = strip(m_se.captures[1])
        alias = String(m_se.captures[2])
        # Skip if it's an aggregate (already captured)
        if !isnothing(match(r"^\s*(COUNT|SUM|AVG|MIN|MAX|GROUP_CONCAT|SAMPLE)\s*\("i, inner))
            continue
        end
        push!(select_exprs, _SelectExpr(_sparql_expand_prefixes_in_expr(inner, prefixes), alias))
    end
    clean_vars = strip(replace(vars_str, agg_regex => ""))
    clean_vars = strip(replace(clean_vars, sel_expr_regex => ""))
    variables = if clean_vars == "*" || isempty(clean_vars)
        String[]
    else
        [strip(v, '?') for v in split(clean_vars) if startswith(v, '?')]
    end

    patterns = _sparql_parse_patterns(m.captures[3], prefixes)

    # Parse GROUP BY
    group_by = if !isnothing(m.captures[5])
        [strip(v, '?') for v in split(strip(m.captures[5])) if startswith(v, '?')]
    else
        String[]
    end

    having = !isnothing(m.captures[7]) ? strip(String(m.captures[7])) : nothing

    # Parse ORDER BY with ASC/DESC support
    order_by = Tuple{String, Symbol}[]
    if !isnothing(m.captures[9])
        ob_str = strip(m.captures[9])
        # Match DESC(?var), ASC(?var), or bare ?var
        for ob_m in eachmatch(r"(?:DESC\s*\(\s*\?(\w+)\s*\))|(?:ASC\s*\(\s*\?(\w+)\s*\))|(?:\?(\w+))"i, ob_str)
            if !isnothing(ob_m.captures[1])
                push!(order_by, (String(ob_m.captures[1]), :desc))
            elseif !isnothing(ob_m.captures[2])
                push!(order_by, (String(ob_m.captures[2]), :asc))
            elseif !isnothing(ob_m.captures[3])
                push!(order_by, (String(ob_m.captures[3]), :asc))
            end
        end
    end

    limit = !isnothing(m.captures[11]) ? parse(Int, m.captures[11]) : nothing
    offset = !isnothing(m.captures[13]) ? parse(Int, m.captures[13]) : 0

    _SPARQLSelect(variables, patterns, prefixes, limit, offset, order_by, distinct, reduced, aggregates, group_by, having, select_exprs)
end

function _sparql_parse_ask(q::AbstractString, prefixes::Dict{String,String})
    m = match(r"ASK\s*\{(.*)\}\s*$"is, q)
    isnothing(m) && throw(ArgumentError("Invalid ASK query"))
    patterns = _sparql_parse_patterns(m.captures[1], prefixes)
    _SPARQLAsk(patterns, prefixes)
end

function _sparql_parse_construct(q::AbstractString, prefixes::Dict{String,String})
    # Try CONSTRUCT WHERE { ... } shorthand first
    m = match(r"^CONSTRUCT\s+WHERE\s*\{(.*)\}\s*$"is, q)
    if !isnothing(m)
        patterns = _sparql_parse_patterns(m.captures[1], prefixes)
        template = _sparql_parse_template(m.captures[1], prefixes)
        return _SPARQLConstruct(template, patterns, prefixes)
    end
    m = match(r"CONSTRUCT\s*\{(.*?)\}\s*WHERE\s*\{(.*)\}\s*$"is, q)
    isnothing(m) && throw(ArgumentError("Invalid CONSTRUCT query"))
    template = _sparql_parse_template(m.captures[1], prefixes)
    patterns = _sparql_parse_patterns(m.captures[2], prefixes)
    _SPARQLConstruct(template, patterns, prefixes)
end

function _sparql_parse_describe(q::AbstractString, prefixes::Dict{String,String})
    # DESCRIBE <uri> or DESCRIBE ?var WHERE { ... }
    m = match(r"DESCRIBE\s+(.*?)\s*(?:WHERE\s*\{(.*)\})?\s*$"is, q)
    isnothing(m) && throw(ArgumentError("Invalid DESCRIBE query"))
    terms_str = strip(m.captures[1])
    terms = Any[]
    for tok in split(terms_str)
        tok = strip(tok)
        isempty(tok) && continue
        push!(terms, _sparql_parse_term(String(tok), prefixes))
    end
    patterns = if !isnothing(m.captures[2])
        _sparql_parse_patterns(m.captures[2], prefixes)
    else
        Any[]
    end
    _SPARQLDescribe(terms, patterns, prefixes)
end

function _sparql_try_split_union(stmt::AbstractString)
    s = strip(stmt)
    !startswith(s, '{') && return nothing
    depth = 0
    chars = collect(s)
    for i in eachindex(chars)
        c = chars[i]
        if c == '{'
            depth += 1
        elseif c == '}'
            depth -= 1
            if depth == 0
                rest = lstrip(String(chars[i+1:end]))
                m = match(r"^UNION\s*\{(.*)\}\s*$"is, rest)
                if !isnothing(m)
                    inner_left = String(chars[2:i-1])
                    inner_right = m.captures[1]
                    return (strip(inner_left), strip(String(inner_right)))
                else
                    return nothing
                end
            end
        end
    end
    return nothing
end

function _sparql_expand_keywords!(out::Vector{String}, stmt::AbstractString)
    s = strip(stmt)
    isempty(s) && return
    # Split on keyword boundaries: BIND, FILTER, OPTIONAL, MINUS, VALUES at start of line
    # but not inside nested {} or strings
    parts = String[]
    buf = IOBuffer()
    in_string = false
    quote_char = nothing
    depth = 0
    chars = collect(s)
    i = 1
    while i <= length(chars)
        c = chars[i]
        if in_string
            write(buf, c)
            if c == '\\' && i < length(chars)
                i += 1; write(buf, chars[i])
            elseif c == quote_char
                in_string = false
            end
        else
            if c == '"' || c == '\''
                in_string = true; quote_char = c; write(buf, c)
            elseif c == '{'; depth += 1; write(buf, c)
            elseif c == '}'; depth -= 1; write(buf, c)
            elseif depth == 0 && c == '\n'
                # Check if next non-whitespace is a keyword
                rest = lstrip(String(chars[i+1:end]))
                kw = uppercase(rest)
                is_kw = startswith(kw, "BIND") || startswith(kw, "FILTER") ||
                         startswith(kw, "OPTIONAL") || startswith(kw, "MINUS") ||
                         startswith(kw, "VALUES") || startswith(kw, "GRAPH") ||
                         startswith(kw, "SERVICE") ||
                         startswith(kw, "{")
                # Don't split before '{' if buffer ends with UNION (part of { } UNION { } construct)
                if is_kw && startswith(kw, "{") && position(buf) > 0
                    buf_content = String(take!(buf))
                    write(buf, buf_content)
                    if endswith(rstrip(uppercase(buf_content)), "UNION")
                        is_kw = false
                    end
                end
                if is_kw && position(buf) > 0
                    push!(parts, String(take!(buf)))
                else
                    write(buf, c)
                end
            else
                write(buf, c)
            end
        end
        i += 1
    end
    remaining = String(take!(buf))
    !isempty(strip(remaining)) && push!(parts, remaining)
    append!(out, parts)
end

function _sparql_parse_patterns(body::AbstractString, prefixes::Dict{String,String})
    patterns = Any[]
    body = strip(body)

    # Split on '.' but be careful about quoted strings and nested {}
    statements = _sparql_split_statements(body)

    # Further split statements that contain multiple keywords (BIND, FILTER, OPTIONAL, MINUS, VALUES)
    # without separating dots
    expanded = String[]
    for stmt in statements
        _sparql_expand_keywords!(expanded, stmt)
    end

    for stmt in expanded
        stmt = strip(stmt)
        isempty(stmt) && continue

        # Check for UNION: { ... } UNION { ... }
        union_parts = _sparql_try_split_union(stmt)
        if !isnothing(union_parts)
            left, right = union_parts
            push!(patterns, _Union(
                _sparql_parse_patterns(left, prefixes),
                _sparql_parse_patterns(right, prefixes)
            ))
            continue
        end

        # Check for FILTER NOT EXISTS { ... }
        m = match(r"^FILTER\s+NOT\s+EXISTS\s*\{(.*)\}\s*$"is, stmt)
        if !isnothing(m)
            push!(patterns, _FilterExists(_sparql_parse_patterns(m.captures[1], prefixes), true))
            continue
        end

        # Check for FILTER EXISTS { ... }
        m = match(r"^FILTER\s+EXISTS\s*\{(.*)\}\s*$"is, stmt)
        if !isnothing(m)
            push!(patterns, _FilterExists(_sparql_parse_patterns(m.captures[1], prefixes), false))
            continue
        end

        # Check for FILTER
        m = match(r"^FILTER\s*\((.*)\)\s*$"is, stmt)
        if !isnothing(m)
            push!(patterns, _Filter(strip(m.captures[1])))
            continue
        end

        # Check for FILTER without outer parens (e.g., FILTER CONTAINS(...), FILTER STRSTARTS(...))
        m = match(r"^FILTER\s+(\w+\s*\(.*\))\s*$"is, stmt)
        if !isnothing(m)
            push!(patterns, _Filter(strip(m.captures[1])))
            continue
        end

        # Check for BIND (expr AS ?var)
        m = match(r"^BIND\s*\((.+)\s+AS\s+\?(\w+)\)\s*$"is, stmt)
        if !isnothing(m)
            push!(patterns, _Bind(_sparql_expand_prefixes_in_expr(strip(m.captures[1]), prefixes), String(m.captures[2])))
            continue
        end

        # Check for OPTIONAL
        m = match(r"^OPTIONAL\s*\{(.*)\}\s*$"is, stmt)
        if !isnothing(m)
            # Parse as optional pattern group (stored as tuple marker)
            opt_patterns = _sparql_parse_patterns(m.captures[1], prefixes)
            push!(patterns, (:optional, opt_patterns))
            continue
        end

        # Check for MINUS { ... }
        m = match(r"^MINUS\s*\{(.*)\}\s*$"is, stmt)
        if !isnothing(m)
            push!(patterns, _Minus(_sparql_parse_patterns(m.captures[1], prefixes)))
            continue
        end

        # Check for VALUES (?x ?y) { ... } or VALUES ?x { ... }
        m = match(r"^VALUES\s+(.+?)\s*\{(.*)\}\s*$"is, stmt)
        if !isnothing(m)
            push!(patterns, _sparql_parse_values(m.captures[1], m.captures[2], prefixes))
            continue
        end

        # Check for subquery: { SELECT ... }
        m = match(r"^\{\s*(SELECT\s+.+)\}\s*$"is, stmt)
        if !isnothing(m)
            sub = _sparql_parse_select(strip(m.captures[1]), prefixes)
            push!(patterns, _Subquery(sub))
            continue
        end

        # Check for GRAPH <uri> { ... } or GRAPH ?var { ... }
        m = match(r"^GRAPH\s+(\S+)\s*\{(.*)\}\s*$"is, stmt)
        if !isnothing(m)
            graph_term = _sparql_parse_term(strip(m.captures[1]), prefixes)
            graph_patterns = _sparql_parse_patterns(m.captures[2], prefixes)
            push!(patterns, _GraphPattern(graph_term, graph_patterns))
            continue
        end

        # Check for SERVICE [SILENT] <endpoint> { ... } or SERVICE [SILENT] ?var { ... }
        m = match(r"^SERVICE\s+(SILENT\s+)?(\S+)\s*\{(.*)\}\s*$"is, stmt)
        if !isnothing(m)
            silent = !isnothing(m.captures[1])
            endpoint = _sparql_parse_term(strip(m.captures[2]), prefixes)
            svc_patterns = _sparql_parse_patterns(m.captures[3], prefixes)
            push!(patterns, _Service(endpoint, svc_patterns, silent))
            continue
        end

        # Parse as triple pattern
        triple = _sparql_parse_triple(stmt, prefixes)
        !isnothing(triple) && push!(patterns, triple)
    end

    patterns
end

function _sparql_parse_values(vars_str::AbstractString, data_str::AbstractString, prefixes::Dict{String,String})
    vars_str = strip(vars_str)
    # Single variable: VALUES ?x { ... }
    if startswith(vars_str, '?') && !occursin('(', vars_str)
        varname = strip(vars_str[2:end])
        vals = Union{Identifier, Nothing}[]
        for tok in _sparql_tokenize(strip(data_str))
            tok = strip(tok)
            if uppercase(tok) == "UNDEF"
                push!(vals, nothing)
            else
                push!(vals, _sparql_parse_term(tok, prefixes))
            end
        end
        return _Values([String(varname)], [Union{Identifier, Nothing}[v] for v in vals])
    end
    # Multiple variables: VALUES (?x ?y) { (<a> <b>) (<c> <d>) }
    m = match(r"^\((.*)\)$"s, vars_str)
    isnothing(m) && throw(ArgumentError("Invalid VALUES variables: $vars_str"))
    variables = [strip(v, '?') for v in split(strip(m.captures[1])) if startswith(v, '?')]
    rows = Vector{Union{Identifier, Nothing}}[]
    for row_m in eachmatch(r"\(([^)]*)\)", data_str)
        row = Union{Identifier, Nothing}[]
        for tok in _sparql_tokenize(strip(row_m.captures[1]))
            tok = strip(tok)
            if uppercase(tok) == "UNDEF"
                push!(row, nothing)
            else
                push!(row, _sparql_parse_term(tok, prefixes))
            end
        end
        push!(rows, row)
    end
    _Values(variables, rows)
end

function _sparql_split_statements(body::AbstractString)
    stmts = String[]
    buf = IOBuffer()
    in_string = false
    in_uri = false
    quote_char = nothing
    depth = 0
    chars = collect(body)
    i = 1

    while i <= length(chars)
        c = chars[i]
        if in_string
            write(buf, c)
            if c == '\\' && i < length(chars)
                i += 1
                write(buf, chars[i])
            elseif c == quote_char
                in_string = false
            end
        elseif in_uri
            write(buf, c)
            c == '>' && (in_uri = false)
        else
            if c == '"' || c == '\''
                in_string = true
                quote_char = c
                write(buf, c)
            elseif c == '<'
                # Only treat as URI if followed by a letter or _ (not space/digit for comparisons)
                if i < length(chars) && (isletter(chars[i+1]) || chars[i+1] == '_')
                    in_uri = true
                end
                write(buf, c)
            elseif c == '{'
                depth += 1
                write(buf, c)
            elseif c == '}'
                depth -= 1
                write(buf, c)
                # Split after closing brace at depth 0, but NOT if followed by UNION
                if depth == 0
                    rest = lstrip(String(chars[i+1:end]))
                    if !startswith(uppercase(rest), "UNION")
                        s = String(take!(buf))
                        !isempty(strip(s)) && push!(stmts, s)
                    end
                end
            elseif c == '.' && depth == 0
                # Only split on '.' that is followed by whitespace or end
                next_is_ws = (i == length(chars)) || (i < length(chars) && chars[i+1] in (' ', '\t', '\n', '\r'))
                if next_is_ws
                    push!(stmts, String(take!(buf)))
                else
                    write(buf, c)
                end
            else
                write(buf, c)
            end
        end
        i += 1
    end
    remaining = String(take!(buf))
    !isempty(strip(remaining)) && push!(stmts, remaining)
    stmts
end

function _sparql_parse_triple(stmt::AbstractString, prefixes::Dict{String,String})
    # Tokenize: split on whitespace respecting quotes and <>
    tokens = _sparql_tokenize(stmt)
    length(tokens) < 3 && return nothing

    s = _sparql_parse_term(tokens[1], prefixes)
    pred_token = tokens[2]
    p = if _is_path_token(pred_token)
        _sparql_parse_path(pred_token, prefixes)
    else
        _sparql_parse_term(pred_token, prefixes)
    end
    o = _sparql_parse_term(join(tokens[3:end], " "), prefixes)

    _BGPTriple(s, p, o)
end

function _is_path_token(token::AbstractString)
    isempty(token) && return false
    (startswith(token, '?') || startswith(token, '$')) && return false
    startswith(token, "!(") && return true
    in_uri = false
    for c in token
        if in_uri
            c == '>' && (in_uri = false)
        else
            c == '<' && (in_uri = true; continue)
            c in ('/', '|') && return true
        end
    end
    first(token) == '^' && return true
    last(token) in ('*', '+', '?') && return true
    false
end

function _path_split_on(token::AbstractString, sep::Char)
    parts = String[]
    buf = IOBuffer()
    depth = 0
    in_uri = false
    for c in token
        if in_uri
            write(buf, c)
            c == '>' && (in_uri = false)
        elseif c == '<'
            in_uri = true
            write(buf, c)
        elseif c == '('
            depth += 1
            write(buf, c)
        elseif c == ')'
            depth -= 1
            write(buf, c)
        elseif c == sep && depth == 0
            push!(parts, String(take!(buf)))
        else
            write(buf, c)
        end
    end
    remaining = String(take!(buf))
    !isempty(remaining) && push!(parts, remaining)
    parts
end

function _sparql_parse_path(token::AbstractString, prefixes::Dict{String,String})
    token = strip(token)

    # Split on | (lowest precedence — alternative)
    alts = _path_split_on(token, '|')
    if length(alts) > 1
        return _PathAlternative([_sparql_parse_path(a, prefixes) for a in alts])
    end

    # Split on / (sequence)
    seqs = _path_split_on(token, '/')
    if length(seqs) > 1
        return _PathSequence([_sparql_parse_path(s, prefixes) for s in seqs])
    end

    # ^ prefix (inverse)
    if startswith(token, '^')
        return _PathInverse(_sparql_parse_path(token[2:end], prefixes))
    end

    # Suffix */+/? (repetition — highest precedence)
    if endswith(token, '*')
        return _PathZeroOrMore(_sparql_parse_path(chop(token), prefixes))
    end
    if endswith(token, '+')
        return _PathOneOrMore(_sparql_parse_path(chop(token), prefixes))
    end
    if endswith(token, '?')
        return _PathZeroOrOne(_sparql_parse_path(chop(token), prefixes))
    end

    # Parenthesized grouping
    if startswith(token, '(') && endswith(token, ')')
        return _sparql_parse_path(token[2:end-1], prefixes)
    end

    # Negated property set: !(ex:p1|ex:p2)
    m = match(r"^!\((.+)\)$", token)
    if !isnothing(m)
        uris = URIRef[]
        for part in _path_split_on(m.captures[1], '|')
            uri = _sparql_parse_term(strip(part), prefixes)
            uri isa URIRef && push!(uris, uri)
        end
        return _PathNegatedSet(uris)
    end

    # Base case: plain URI
    uri = _sparql_parse_term(token, prefixes)
    uri isa URIRef && return _PathURI(uri)
    throw(ArgumentError("Invalid path expression: $token"))
end

function _sparql_tokenize(s::AbstractString)
    tokens = String[]
    buf = IOBuffer()
    in_uri = false
    in_string = false
    quote_char = nothing

    for c in s
        if in_uri
            write(buf, c)
            c == '>' && (in_uri = false)
        elseif in_string
            write(buf, c)
            if c != '\\' && c == quote_char
                in_string = false
            end
        else
            if c == '<'
                in_uri = true
                write(buf, c)
            elseif c == '"' || c == '\''
                in_string = true
                quote_char = c
                write(buf, c)
            elseif c in (' ', '\t', '\n', '\r')
                t = String(take!(buf))
                !isempty(t) && push!(tokens, t)
            else
                write(buf, c)
            end
        end
    end
    t = String(take!(buf))
    !isempty(t) && push!(tokens, t)

    # Handle language tags and datatypes attached to literals
    merged = String[]
    i = 1
    while i <= length(tokens)
        tok = tokens[i]
        if (endswith(tok, '"') || endswith(tok, '\'')) && i < length(tokens)
            next = tokens[i+1]
            if startswith(next, '@') || startswith(next, "^^")
                push!(merged, tok * next)
                i += 2
                continue
            end
        end
        push!(merged, tok)
        i += 1
    end
    merged
end

function _sparql_parse_term(token::AbstractString, prefixes::Dict{String,String})
    token = strip(token)

    # Variable
    if startswith(token, '?') || startswith(token, '$')
        return token[2:end]  # Return variable name as String
    end

    # Full URI
    if startswith(token, '<') && endswith(token, '>')
        return URIRef(token[2:end-1])
    end

    # Keyword 'a' → rdf:type
    if token == "a"
        return URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    end

    # Literal
    if startswith(token, '"') || startswith(token, '\'')
        return _sparql_parse_literal(token)
    end

    # Boolean
    if token == "true"
        return Literal(true)
    elseif token == "false"
        return Literal(false)
    end

    # Numeric
    if !isnothing(tryparse(Int, token))
        return Literal(parse(Int, token))
    end
    if !isnothing(tryparse(Float64, token))
        return Literal(parse(Float64, token))
    end

    # Prefixed name
    idx = findfirst(':', token)
    if !isnothing(idx)
        prefix = token[1:idx-1]
        localname = token[idx+1:end]
        ns = get(prefixes, prefix, nothing)
        !isnothing(ns) && return URIRef(ns * localname)
    end

    throw(ArgumentError("Cannot parse SPARQL term: $token"))
end

function _sparql_parse_literal(token::AbstractString)
    # Handle "value"@lang or "value"^^<type> or "value"^^prefix:local
    m = match(r"^[\"'](.*?)[\"'](?:@([a-zA-Z\-]+)|\^\^<?([^>]*)>?)?$"s, token)
    isnothing(m) && return Literal(token)

    lexical = m.captures[1]
    lang_tag = m.captures[2]
    dt = m.captures[3]

    if !isnothing(lang_tag)
        return Literal(lexical, lang=lang_tag)
    elseif !isnothing(dt)
        return Literal(lexical, datatype=URIRef(dt))
    else
        return Literal(lexical)
    end
end

"""Expand prefixed names in an expression string to full `<URI>` form."""
function _sparql_expand_prefixes_in_expr(expr::AbstractString, prefixes::Dict{String,String})
    result = expr
    # Replace prefixed names (prefix:local) with <full-uri> but avoid touching
    # strings, variables, and already-expanded URIs
    result = replace(result, r"(?<![<\?\"'\\])(?<!\w)([A-Za-z_]\w*):([A-Za-z_]\w*)" => function(m_str)
        mm = match(r"^([A-Za-z_]\w*):([A-Za-z_]\w*)$", m_str)
        isnothing(mm) && return m_str
        prefix = mm.captures[1]
        local_name = mm.captures[2]
        ns = get(prefixes, prefix, nothing)
        isnothing(ns) && return m_str
        return "<" * ns * local_name * ">"
    end)
    result
end

function _sparql_parse_template(body::AbstractString, prefixes::Dict{String,String})
    template = Tuple{Any,Any,Any}[]
    statements = _sparql_split_statements(body)
    for stmt in statements
        stmt = strip(stmt)
        isempty(stmt) && continue
        tokens = _sparql_tokenize(stmt)
        length(tokens) < 3 && continue
        s = _sparql_parse_term(tokens[1], prefixes)
        p = _sparql_parse_term(tokens[2], prefixes)
        o = _sparql_parse_term(join(tokens[3:end], " "), prefixes)
        push!(template, (s, p, o))
    end
    template
end

# ─── Evaluation ─────────────────────────────────────────────────────

function _sparql_evaluate(g::RDFGraph, q::_SPARQLSelect)
    bindings = _sparql_eval_patterns(g, q.patterns)

    # Evaluate SELECT expressions and add to bindings
    if !isempty(q.select_exprs)
        for b in bindings
            for se in q.select_exprs
                val = _sparql_eval_bind_expr(se.expr, b)
                if !isnothing(val)
                    b[se.alias] = val
                end
            end
        end
    end

    # Handle aggregates and GROUP BY
    if !isempty(q.aggregates) || !isempty(q.group_by)
        groups = Dict{Any, Vector{Dict{String, Identifier}}}()
        for b in bindings
            key = if !isempty(q.group_by)
                Tuple(get(b, v, nothing) for v in q.group_by)
            else
                ()
            end
            if !haskey(groups, key)
                groups[key] = Dict{String, Identifier}[]
            end
            push!(groups[key], b)
        end

        new_bindings = Dict{String, Identifier}[]
        for (key, group) in groups
            result = Dict{String, Identifier}()
            if !isempty(q.group_by) && !isempty(group)
                for v in q.group_by
                    if haskey(group[1], v)
                        result[v] = group[1][v]
                    end
                end
            end
            for agg in q.aggregates
                result[agg.alias] = _sparql_compute_aggregate(agg, group)
            end
            push!(new_bindings, result)
        end

        if !isnothing(q.having)
            new_bindings = filter(b -> _sparql_eval_filter_expr(q.having, b, g), new_bindings)
        end

        bindings = new_bindings
    end

    # Apply ORDER BY
    if !isempty(q.order_by)
        sort!(bindings, lt=(a, b) -> begin
            for (var, dir) in q.order_by
                va = string(get(a, var, ""))
                vb = string(get(b, var, ""))
                if va != vb
                    return dir == :asc ? va < vb : va > vb
                end
            end
            false
        end)
    end

    # Project variables (include aggregate aliases and select expression aliases)
    proj_vars = copy(q.variables)
    for agg in q.aggregates
        if !(agg.alias in proj_vars)
            push!(proj_vars, agg.alias)
        end
    end
    for se in q.select_exprs
        if !(se.alias in proj_vars)
            push!(proj_vars, se.alias)
        end
    end
    if !isempty(proj_vars)
        bindings = [Dict{String, Identifier}(v => b[v] for v in proj_vars if haskey(b, v)) for b in bindings]
    end

    # Apply DISTINCT or REDUCED (after projection)
    if q.distinct || q.reduced
        bindings = unique(bindings)
    end

    # Apply OFFSET and LIMIT
    start_idx = q.offset + 1
    if !isnothing(q.limit)
        end_idx = min(start_idx + q.limit - 1, length(bindings))
    else
        end_idx = length(bindings)
    end
    bindings = start_idx <= length(bindings) ? bindings[start_idx:end_idx] : Dict{String, Identifier}[]

    bindings
end

function _sparql_evaluate(g::RDFGraph, q::_SPARQLAsk)
    bindings = _sparql_eval_patterns(g, q.patterns)
    !isempty(bindings)
end

function _sparql_evaluate(g::RDFGraph, q::_SPARQLConstruct)
    bindings = _sparql_eval_patterns(g, q.patterns)
    result = RDFGraph()

    for binding in bindings
        for (s_tmpl, p_tmpl, o_tmpl) in q.template
            s = _sparql_resolve(s_tmpl, binding)
            p = _sparql_resolve(p_tmpl, binding)
            o = _sparql_resolve(o_tmpl, binding)

            (isnothing(s) || isnothing(p) || isnothing(o)) && continue
            s isa Node || continue
            p isa URIRef || continue
            o isa Identifier || continue

            add!(result, Triple(s, p, o))
        end
    end

    result
end

function _sparql_evaluate(g::RDFGraph, q::_SPARQLDescribe)
    # Collect described resources
    resources = Set{Node}()
    if !isempty(q.patterns)
        bindings = _sparql_eval_patterns(g, q.patterns)
        for term in q.terms
            if term isa AbstractString  # variable
                for b in bindings
                    val = get(b, String(term), nothing)
                    val isa Node && push!(resources, val)
                end
            elseif term isa Node
                push!(resources, term)
            end
        end
    else
        for term in q.terms
            term isa Node && push!(resources, term)
        end
    end
    # Build result graph from CBDs
    result = RDFGraph()
    for node in resources
        desc = cbd(g, node)
        for t in triples(desc)
            add!(result, t)
        end
    end
    result
end

function _sparql_resolve(term, binding::Dict{String, Identifier})
    if term isa AbstractString  # Variable name
        return get(binding, String(term), nothing)
    end
    term  # Already an Identifier
end

# ─── Pattern evaluation (BGP) ──────────────────────────────────────

function _sparql_eval_patterns(g::RDFGraph, patterns::Vector{Any})
    _sparql_eval_patterns(g, patterns, Dict{String, Identifier}[Dict{String, Identifier}()])
end

function _sparql_eval_patterns(g::RDFGraph, patterns::Vector{Any}, bindings::Vector{Dict{String, Identifier}})
    for pattern in patterns
        if pattern isa _BGPTriple
            bindings = _sparql_eval_bgp(g, pattern, bindings)
        elseif pattern isa _Filter
            bindings = _sparql_eval_filter(pattern, bindings, g)
        elseif pattern isa Tuple && pattern[1] === :optional
            opt_patterns = pattern[2]
            for b in bindings
                opt_bindings = _sparql_eval_patterns(g, opt_patterns)
                opt_matches = filter(ob -> _sparql_compatible(b, ob), opt_bindings)
                if !isempty(opt_matches)
                    merge!(b, first(opt_matches))
                end
            end
        elseif pattern isa _Union
            new_bindings = Dict{String, Identifier}[]
            for b in bindings
                left_result = _sparql_eval_patterns(g, pattern.left, Dict{String, Identifier}[copy(b)])
                right_result = _sparql_eval_patterns(g, pattern.right, Dict{String, Identifier}[copy(b)])
                append!(new_bindings, left_result)
                append!(new_bindings, right_result)
            end
            bindings = new_bindings
        elseif pattern isa _Bind
            for b in bindings
                val = _sparql_eval_bind_expr(pattern.expr, b)
                if !isnothing(val)
                    b[pattern.var] = val
                end
            end
        elseif pattern isa _FilterExists
            new_bindings = Dict{String, Identifier}[]
            for b in bindings
                inner = _sparql_eval_patterns(g, pattern.patterns, Dict{String, Identifier}[copy(b)])
                has_match = !isempty(inner)
                if pattern.negated ? !has_match : has_match
                    push!(new_bindings, b)
                end
            end
            bindings = new_bindings
        elseif pattern isa _Minus
            new_bindings = Dict{String, Identifier}[]
            inner = _sparql_eval_patterns(g, pattern.patterns)
            for b in bindings
                # Keep binding only if no inner result is compatible on shared variables
                compatible = any(ib -> _sparql_compatible_shared(b, ib), inner)
                compatible || push!(new_bindings, b)
            end
            bindings = new_bindings
        elseif pattern isa _Values
            new_bindings = Dict{String, Identifier}[]
            for b in bindings
                for row in pattern.values
                    new_b = copy(b)
                    ok = true
                    for (i, var) in enumerate(pattern.variables)
                        i > length(row) && (ok = false; break)
                        val = row[i]
                        isnothing(val) && continue
                        if haskey(new_b, var)
                            new_b[var] != val && (ok = false; break)
                        else
                            new_b[var] = val
                        end
                    end
                    ok && push!(new_bindings, new_b)
                end
            end
            bindings = new_bindings
        elseif pattern isa _Subquery
            sub_results = _sparql_evaluate(g, pattern.query)
            new_bindings = Dict{String, Identifier}[]
            for b in bindings
                for sr in sub_results
                    if _sparql_compatible(b, sr)
                        push!(new_bindings, merge(b, sr))
                    end
                end
            end
            bindings = new_bindings
        elseif pattern isa _GraphPattern
            # For local evaluation, GRAPH patterns are evaluated against the graph itself
            # (named graph support would require a Dataset)
            inner = _sparql_eval_patterns(g, pattern.patterns, bindings)
            bindings = inner
        elseif pattern isa _Service
            # SERVICE [SILENT] <endpoint> { ... } — federated query
            try
                endpoint_uri = if pattern.endpoint isa URIRef
                    pattern.endpoint.value
                elseif pattern.endpoint isa String
                    val = get(first(bindings), pattern.endpoint, nothing)
                    val isa URIRef ? val.value : nothing
                else
                    nothing
                end
                if !isnothing(endpoint_uri)
                    store = SPARQLStore(endpoint_uri)
                    remote_query = _build_service_query(pattern.patterns)
                    cached = _service_cache_lookup(endpoint_uri, remote_query)
                    remote_results = if !isnothing(cached)
                        cached
                    else
                        res = _remote_select(store, remote_query)
                        _service_cache_store!(endpoint_uri, remote_query, res)
                        res
                    end
                    new_bindings = Dict{String, Identifier}[]
                    for binding in bindings
                        for rr in remote_results
                            compatible = true
                            for (k, v) in binding
                                if haskey(rr, k) && rr[k] != v
                                    compatible = false
                                    break
                                end
                            end
                            compatible && push!(new_bindings, merge(binding, rr))
                        end
                    end
                    bindings = isempty(new_bindings) ? bindings : new_bindings
                end
            catch e
                pattern.silent || rethrow(e)
            end
        end
    end

    bindings
end

function _sparql_compatible_shared(b1::Dict, b2::Dict)
    shared = false
    for (k, v) in b1
        if haskey(b2, k)
            shared = true
            b2[k] != v && return false
        end
    end
    shared
end

function _sparql_compatible(b1::Dict, b2::Dict)
    for (k, v) in b1
        if haskey(b2, k) && b2[k] != v
            return false
        end
    end
    true
end

function _sparql_eval_bgp(g::RDFGraph, bgp::_BGPTriple, bindings::Vector{Dict{String, Identifier}})
    new_bindings = Dict{String, Identifier}[]

    for binding in bindings
        if bgp.p isa _PathExpr
            s_term = _sparql_bind_term(bgp.s, binding)
            o_term = _sparql_bind_term(bgp.o, binding)
            s_node = s_term isa Node ? s_term : nothing
            o_id = o_term isa Identifier ? o_term : nothing
            pairs = _eval_path_expr(g, bgp.p, s_node, o_id)
            for (s_val, o_val) in pairs
                new_binding = copy(binding)
                ok = true
                ok = ok && _sparql_try_bind!(new_binding, bgp.s, s_val)
                ok = ok && _sparql_try_bind!(new_binding, bgp.o, o_val)
                ok && push!(new_bindings, new_binding)
            end
        else
            # Resolve terms against current binding
            s_term = _sparql_bind_term(bgp.s, binding)
            p_term = _sparql_bind_term(bgp.p, binding)
            o_term = _sparql_bind_term(bgp.o, binding)

            # Build pattern for store lookup
            s_pat = s_term isa Node ? s_term : nothing
            p_pat = p_term isa URIRef ? p_term : nothing
            o_pat = o_term isa Identifier ? o_term : nothing

            for t in triples(g, (s_pat, p_pat, o_pat))
                new_binding = copy(binding)
                ok = true

                # Bind variables
                ok = ok && _sparql_try_bind!(new_binding, bgp.s, t.subject)
                ok = ok && _sparql_try_bind!(new_binding, bgp.p, t.predicate)
                ok = ok && _sparql_try_bind!(new_binding, bgp.o, t.object)

                ok && push!(new_bindings, new_binding)
            end
        end
    end

    new_bindings
end

# ─── Property path evaluation ──────────────────────────────────────

function _all_graph_nodes(g::RDFGraph)
    nodes = Set{Node}()
    for t in triples(g)
        push!(nodes, t.subject)
        t.object isa Node && push!(nodes, t.object)
    end
    nodes
end

function _eval_path_expr(g::RDFGraph, path::_PathURI, start::Union{Node,Nothing}, target::Union{Identifier,Nothing})
    results = Set{Tuple{Node, Identifier}}()
    for t in triples(g, (start, path.uri, target))
        push!(results, (t.subject, t.object))
    end
    results
end

function _eval_path_expr(g::RDFGraph, path::_PathSequence, start::Union{Node,Nothing}, target::Union{Identifier,Nothing})
    isempty(path.steps) && return Set{Tuple{Node, Identifier}}()
    length(path.steps) == 1 && return _eval_path_expr(g, path.steps[1], start, target)

    first_step = path.steps[1]
    rest = length(path.steps) == 2 ? path.steps[2] : _PathSequence(path.steps[2:end])

    first_pairs = _eval_path_expr(g, first_step, start, nothing)
    results = Set{Tuple{Node, Identifier}}()
    for (s, m) in first_pairs
        m isa Node || continue
        rest_pairs = _eval_path_expr(g, rest, m, target)
        for (_, o) in rest_pairs
            push!(results, (s, o))
        end
    end
    results
end

function _eval_path_expr(g::RDFGraph, path::_PathAlternative, start::Union{Node,Nothing}, target::Union{Identifier,Nothing})
    results = Set{Tuple{Node, Identifier}}()
    for option in path.options
        union!(results, _eval_path_expr(g, option, start, target))
    end
    results
end

function _eval_path_expr(g::RDFGraph, path::_PathInverse, start::Union{Node,Nothing}, target::Union{Identifier,Nothing})
    inv_start = target isa Node ? target : nothing
    inv_target = start
    pairs = _eval_path_expr(g, path.path, inv_start, inv_target)
    results = Set{Tuple{Node, Identifier}}()
    for (s, o) in pairs
        o isa Node || continue
        push!(results, (o, s))
    end
    results
end

function _eval_path_expr(g::RDFGraph, path::_PathZeroOrMore, start::Union{Node,Nothing}, target::Union{Identifier,Nothing})
    _eval_path_closure(g, path.path, start, target; include_zero=true)
end

function _eval_path_expr(g::RDFGraph, path::_PathOneOrMore, start::Union{Node,Nothing}, target::Union{Identifier,Nothing})
    _eval_path_closure(g, path.path, start, target; include_zero=false)
end

function _eval_path_expr(g::RDFGraph, path::_PathZeroOrOne, start::Union{Node,Nothing}, target::Union{Identifier,Nothing})
    results = Set{Tuple{Node, Identifier}}()
    union!(results, _eval_path_expr(g, path.path, start, target))
    if !isnothing(start)
        if isnothing(target) || start == target
            push!(results, (start, start))
        end
    else
        for node in _all_graph_nodes(g)
            if isnothing(target) || node == target
                push!(results, (node, node))
            end
        end
    end
    results
end

function _eval_path_closure(g::RDFGraph, path::_PathExpr, start::Union{Node,Nothing}, target::Union{Identifier,Nothing}; include_zero::Bool=false)
    results = Set{Tuple{Node, Identifier}}()
    if !isnothing(start)
        include_zero && push!(results, (start, start))
        visited = Set{Identifier}([start])
        queue = Node[start]
        while !isempty(queue)
            current = popfirst!(queue)
            for (_, next) in _eval_path_expr(g, path, current, nothing)
                if next ∉ visited
                    push!(visited, next)
                    push!(results, (start, next))
                    next isa Node && push!(queue, next)
                end
            end
        end
        if !isnothing(target)
            filter!(p -> p[2] == target, results)
        end
    else
        for node in _all_graph_nodes(g)
            union!(results, _eval_path_closure(g, path, node, target; include_zero=include_zero))
        end
    end
    results
end

function _eval_path_expr(g::RDFGraph, path::_PathNegatedSet, start::Union{Node,Nothing}, target::Union{Identifier,Nothing})
    negated = Set{URIRef}(path.uris)
    results = Set{Tuple{Node, Identifier}}()
    for t in triples(g, (start, nothing, target))
        t.predicate in negated || push!(results, (t.subject, t.object))
    end
    results
end

function _sparql_bind_term(term, binding::Dict{String, Identifier})
    if term isa AbstractString  # Variable
        return get(binding, String(term), term)
    end
    term
end

function _sparql_try_bind!(binding::Dict{String, Identifier}, pattern_term, actual::Identifier)
    if pattern_term isa AbstractString  # Variable
        key = String(pattern_term)
        if haskey(binding, key)
            return binding[key] == actual
        else
            binding[key] = actual
            return true
        end
    end
    # Concrete term — must match
    return pattern_term == actual
end

# ─── Filter evaluation ─────────────────────────────────────────────

function _sparql_eval_filter(f::_Filter, bindings::Vector{Dict{String, Identifier}}, g::RDFGraph)
    filter(b -> _sparql_eval_filter_expr(f.expr, b, g), bindings)
end

function _sparql_eval_filter_expr(expr::AbstractString, binding::Dict{String, Identifier}, g::RDFGraph)
    expr = strip(expr)

    # Handle && and || at top level (respecting parentheses depth)
    parts_and = _sparql_split_filter_connective(expr, "&&")
    if length(parts_and) > 1
        return all(p -> _sparql_eval_filter_expr(p, binding, g), parts_and)
    end
    parts_or = _sparql_split_filter_connective(expr, "||")
    if length(parts_or) > 1
        return any(p -> _sparql_eval_filter_expr(p, binding, g), parts_or)
    end

    # Strip wrapping parens
    if startswith(expr, '(') && endswith(expr, ')')
        inner = _sparql_strip_outer_parens(expr)
        if !isnothing(inner)
            return _sparql_eval_filter_expr(inner, binding, g)
        end
    end

    # Handle NOT/!
    m = match(r"^!\s*(.+)$", expr)
    if !isnothing(m)
        return !_sparql_eval_filter_expr(m.captures[1], binding, g)
    end

    # Handle BOUND(?var)
    m = match(r"^BOUND\s*\(\s*\?(\w+)\s*\)$"i, expr)
    if !isnothing(m)
        return haskey(binding, m.captures[1])
    end

    # Handle isIRI(?var) / isURI(?var)
    m = match(r"^(?:isIRI|isURI)\s*\(\s*\?(\w+)\s*\)$"i, expr)
    if !isnothing(m)
        val = get(binding, m.captures[1], nothing)
        return val isa URIRef
    end

    # Handle isLiteral(?var)
    m = match(r"^isLiteral\s*\(\s*\?(\w+)\s*\)$"i, expr)
    if !isnothing(m)
        val = get(binding, m.captures[1], nothing)
        return val isa Literal
    end

    # Handle isBlank(?var)
    m = match(r"^isBlank\s*\(\s*\?(\w+)\s*\)$"i, expr)
    if !isnothing(m)
        val = get(binding, m.captures[1], nothing)
        return val isa BNode
    end

    # Handle isTRIPLE(?var)
    m = match(r"^isTRIPLE\s*\(\s*\?(\w+)\s*\)$"i, expr)
    if !isnothing(m)
        val = get(binding, String(m.captures[1]), nothing)
        return !isnothing(val) && val isa TripleTerm
    end

    # Handle isNUMERIC(?var)
    m = match(r"^isNUMERIC\s*\(\s*\?(\w+)\s*\)$"i, expr)
    if !isnothing(m)
        val = get(binding, m.captures[1], nothing)
        val isa Literal || return false
        return !isnothing(_sparql_numeric_value(val))
    end

    # Handle sameTerm(?x, ?y)
    m = match(r"^sameTerm\s*\(\s*\?(\w+)\s*,\s*\?(\w+)\s*\)$"i, expr)
    if !isnothing(m)
        v1 = get(binding, m.captures[1], nothing)
        v2 = get(binding, m.captures[2], nothing)
        (isnothing(v1) || isnothing(v2)) && return false
        return v1 === v2 || v1 == v2
    end

    # ─── GeoSPARQL filter functions ──────────────────────────────
    m = match(r"^(?:geof:(\w+)|<http://www\.opengis\.net/def/function/geosparql/(\w+)>)\s*\((.+)\)$"i, expr)
    if !isnothing(m)
        func_name = lowercase(something(m.captures[1], m.captures[2]))
        args = _sparql_split_args(m.captures[3])
        _geo_filt = Dict("sfcontains"=>geo_contains, "sfwithin"=>geo_within,
            "sfintersects"=>geo_intersects, "sfoverlaps"=>geo_overlaps,
            "sftouches"=>geo_touches, "sfdisjoint"=>geo_disjoint, "sfequals"=>geo_equals)
        if haskey(_geo_filt, func_name) && length(args) >= 2
            v1 = _sparql_eval_bind_expr(strip(args[1]), binding)
            v2 = _sparql_eval_bind_expr(strip(args[2]), binding)
            g1 = _extract_wkt_geometry(v1)
            g2 = _extract_wkt_geometry(v2)
            (isnothing(g1) || isnothing(g2)) && return false
            return _geo_filt[func_name](g1, g2)
        end
    end

    # Handle LANG(?var) = "tag"
    m = match(r"^LANG\s*\(\s*\?(\w+)\s*\)\s*(=|!=)\s*\"([^\"]*)\"\s*$"i, expr)
    if !isnothing(m)
        val = get(binding, m.captures[1], nothing)
        val isa Literal || return false
        ltag = something(val.language, "")
        return m.captures[2] == "=" ? ltag == m.captures[3] : ltag != m.captures[3]
    end

    # Handle DATATYPE(?var) = <uri> or DATATYPE(?var) = prefix:local
    m = match(r"^DATATYPE\s*\(\s*\?(\w+)\s*\)\s*(=|!=)\s*(.+)$"i, expr)
    if !isnothing(m)
        val = get(binding, m.captures[1], nothing)
        val isa Literal || return false
        dt = val.datatype
        rhs_str = strip(m.captures[3])
        rhs_uri = if startswith(rhs_str, '<') && endswith(rhs_str, '>')
            URIRef(rhs_str[2:end-1])
        else
            _sparql_try_resolve_prefixed(rhs_str, binding, g)
        end
        isnothing(rhs_uri) && return false
        return m.captures[2] == "=" ? dt == rhs_uri : dt != rhs_uri
    end

    # Handle LANGMATCHES(LANG(?var), "tag")
    m = match(r"^LANGMATCHES\s*\(\s*LANG\s*\(\s*\?(\w+)\s*\)\s*,\s*\"([^\"]*)\"\s*\)$"i, expr)
    if !isnothing(m)
        val = get(binding, m.captures[1], nothing)
        val isa Literal || return false
        ltag = something(val.language, "")
        target_lang = m.captures[2]
        target_lang == "*" && return !isempty(ltag)
        return lowercase(ltag) == lowercase(target_lang) || startswith(lowercase(ltag), lowercase(target_lang) * "-")
    end

    # Handle CONTAINS(?var, "str")
    m = match(r"^CONTAINS\s*\(\s*\?(\w+)\s*,\s*\"([^\"]*)\"\s*\)$"i, expr)
    if !isnothing(m)
        val = get(binding, m.captures[1], nothing)
        isnothing(val) && return false
        return occursin(m.captures[2], val isa Literal ? val.lexical : string(val))
    end

    # Handle STRSTARTS(?var, "str")
    m = match(r"^STRSTARTS\s*\(\s*\?(\w+)\s*,\s*\"([^\"]*)\"\s*\)$"i, expr)
    if !isnothing(m)
        val = get(binding, m.captures[1], nothing)
        isnothing(val) && return false
        return startswith(val isa Literal ? val.lexical : string(val), m.captures[2])
    end

    # Handle STRENDS(?var, "str")
    m = match(r"^STRENDS\s*\(\s*\?(\w+)\s*,\s*\"([^\"]*)\"\s*\)$"i, expr)
    if !isnothing(m)
        val = get(binding, m.captures[1], nothing)
        isnothing(val) && return false
        return endswith(val isa Literal ? val.lexical : string(val), m.captures[2])
    end

    # Handle STRLEN(?var) op value
    m = match(r"^STRLEN\s*\(\s*\?(\w+)\s*\)\s*(<=|>=|!=|=|<|>)\s*(\d+)$"i, expr)
    if !isnothing(m)
        val = get(binding, m.captures[1], nothing)
        isnothing(val) && return false
        slen = length(val isa Literal ? val.lexical : string(val))
        rval = parse(Int, m.captures[3])
        return _sparql_compare_numeric(slen, m.captures[2], rval)
    end

    # Handle UCASE/LCASE comparison
    m = match(r"^(UCASE|LCASE)\s*\(\s*\?(\w+)\s*\)\s*(=|!=)\s*\"([^\"]*)\"\s*$"i, expr)
    if !isnothing(m)
        func = uppercase(m.captures[1])
        val = get(binding, m.captures[2], nothing)
        isnothing(val) && return false
        s = val isa Literal ? val.lexical : string(val)
        transformed = func == "UCASE" ? uppercase(s) : lowercase(s)
        return m.captures[3] == "=" ? transformed == m.captures[4] : transformed != m.captures[4]
    end

    # Handle ?x IN (<a>, <b>, <c>)
    m = match(r"^\?(\w+)\s+IN\s*\((.+)\)\s*$"i, expr)
    if !isnothing(m)
        val = get(binding, m.captures[1], nothing)
        isnothing(val) && return false
        items = [strip(x) for x in split(m.captures[2], ",")]
        for item in items
            parsed = _sparql_parse_filter_value(strip(item), binding; g=g)
            !isnothing(parsed) && val == parsed && return true
        end
        return false
    end

    # Handle ?x NOT IN (<a>, <b>)
    m = match(r"^\?(\w+)\s+NOT\s+IN\s*\((.+)\)\s*$"i, expr)
    if !isnothing(m)
        val = get(binding, m.captures[1], nothing)
        isnothing(val) && return true
        items = [strip(x) for x in split(m.captures[2], ",")]
        for item in items
            parsed = _sparql_parse_filter_value(strip(item), binding; g=g)
            !isnothing(parsed) && val == parsed && return false
        end
        return true
    end

    # Handle STR(?var)
    m = match(r"^STR\s*\(\s*\?(\w+)\s*\)$"i, expr)
    if !isnothing(m)
        return true
    end

    # Handle comparisons: ?var = value, ?var != value, ?var < value, etc.
    # Also support STR(?var) op, LANG(?var) op, STRLEN(?var) op on LHS
    m = match(r"^(STR\s*\(\s*\?(\w+)\s*\)|\?(\w+))\s*(<=|>=|!=|=|<|>)\s*(.+)$"i, expr)
    if !isnothing(m)
        lhs_str_func = m.captures[2]
        lhs_var = m.captures[3]
        op = m.captures[4]
        rhs_str = strip(m.captures[5])

        if !isnothing(lhs_str_func)
            # STR(?var) op value
            val = get(binding, lhs_str_func, nothing)
            isnothing(val) && return false
            lhs = Literal(val isa Literal ? val.lexical : string(val))
        else
            lhs = get(binding, lhs_var, nothing)
            isnothing(lhs) && return false
        end

        rhs = _sparql_parse_filter_value(rhs_str, binding; g=g)
        isnothing(rhs) && return false

        return _sparql_compare(lhs, op, rhs)
    end

    # Handle REGEX(?var, "pattern")
    m = match(r"^REGEX\s*\(\s*(?:STR\s*\(\s*)?\?(\w+)\s*\)?\s*,\s*\"([^\"]*)\"\s*(?:,\s*\"([^\"]*)\"\s*)?\)$"i, expr)
    if !isnothing(m)
        var = m.captures[1]
        pattern = m.captures[2]
        flags = something(m.captures[3], "")
        val = get(binding, var, nothing)
        isnothing(val) && return false
        val_str = val isa Literal ? val.lexical : string(val)
        if 'i' in flags
            return occursin(Regex(pattern, "i"), val_str)
        else
            return occursin(Regex(pattern), val_str)
        end
    end

    # Default: can't evaluate
    @warn "Cannot evaluate SPARQL filter: $expr"
    true
end

function _sparql_split_filter_connective(expr::AbstractString, op::AbstractString)
    parts = String[]
    buf = IOBuffer()
    depth = 0
    in_string = false
    in_uri = false
    quote_char = nothing
    chars = collect(expr)
    i = 1
    oplen = length(op)
    while i <= length(chars)
        c = chars[i]
        if in_string
            write(buf, c)
            if c == '\\' && i < length(chars)
                i += 1; write(buf, chars[i])
            elseif c == quote_char
                in_string = false
            end
        elseif in_uri
            write(buf, c)
            c == '>' && (in_uri = false)
        elseif c == '"' || c == '\''
            in_string = true; quote_char = c; write(buf, c)
        elseif c == '<'
            in_uri = true; write(buf, c)
        elseif c == '(' || c == '{'
            depth += 1; write(buf, c)
        elseif c == ')' || c == '}'
            depth -= 1; write(buf, c)
        elseif depth == 0 && i + oplen - 1 <= length(chars) && String(chars[i:i+oplen-1]) == op
            push!(parts, strip(String(take!(buf))))
            i += oplen
            continue
        else
            write(buf, c)
        end
        i += 1
    end
    remaining = strip(String(take!(buf)))
    !isempty(remaining) && push!(parts, remaining)
    parts
end

function _sparql_strip_outer_parens(expr::AbstractString)
    expr[1] != '(' && return nothing
    depth = 0
    for (i, c) in enumerate(expr)
        c == '(' && (depth += 1)
        c == ')' && (depth -= 1)
        depth == 0 && i < length(expr) && return nothing
    end
    depth == 0 ? strip(expr[2:end-1]) : nothing
end

function _sparql_parse_filter_value(s::AbstractString, binding::Dict{String, Identifier}; g::Union{RDFGraph, Nothing}=nothing)
    s = strip(s)
    if startswith(s, '"') || startswith(s, '\'')
        return _sparql_parse_literal(s)
    elseif startswith(s, '<') && endswith(s, '>')
        return URIRef(s[2:end-1])
    elseif startswith(s, '?')
        return get(binding, s[2:end], nothing)
    elseif !isnothing(tryparse(Int, s))
        return Literal(parse(Int, s))
    elseif !isnothing(tryparse(Float64, s))
        return Literal(parse(Float64, s))
    elseif s == "true"
        return Literal(true)
    elseif s == "false"
        return Literal(false)
    elseif !isnothing(g) && occursin(':', s) && !startswith(s, "http")
        # Try as prefixed name
        idx = findfirst(':', s)
        if !isnothing(idx)
            prefix = s[1:idx-1]
            local_name = s[idx+1:end]
            for (p, uri) in namespaces(g)
                if p == prefix
                    return URIRef(uri * local_name)
                end
            end
        end
    end
    nothing
end

function _sparql_try_resolve_prefixed(s::AbstractString, binding::Dict{String, Identifier}, g::RDFGraph)
    s = strip(s)
    startswith(s, '<') && endswith(s, '>') && return URIRef(s[2:end-1])
    idx = findfirst(':', s)
    if !isnothing(idx)
        prefix = s[1:idx-1]
        local_name = s[idx+1:end]
        for (p, uri) in namespaces(g)
            p == prefix && return URIRef(uri * local_name)
        end
    end
    nothing
end

function _sparql_compare_numeric(lhs::Number, op::AbstractString, rhs::Number)
    op == "=" && return lhs == rhs
    op == "!=" && return lhs != rhs
    op == "<" && return lhs < rhs
    op == ">" && return lhs > rhs
    op == "<=" && return lhs <= rhs
    op == ">=" && return lhs >= rhs
    false
end

function _sparql_compare(lhs::Identifier, op::AbstractString, rhs::Identifier)
    if op == "="
        return lhs == rhs
    elseif op == "!="
        return lhs != rhs
    end

    # Numeric comparison for literals
    if lhs isa Literal && rhs isa Literal
        lv = _sparql_numeric_value(lhs)
        rv = _sparql_numeric_value(rhs)
        if !isnothing(lv) && !isnothing(rv)
            if op == "<"; return lv < rv
            elseif op == ">"; return lv > rv
            elseif op == "<="; return lv <= rv
            elseif op == ">="; return lv >= rv
            end
        end
        # String comparison fallback
        if op == "<"; return lhs.lexical < rhs.lexical
        elseif op == ">"; return lhs.lexical > rhs.lexical
        elseif op == "<="; return lhs.lexical <= rhs.lexical
        elseif op == ">="; return lhs.lexical >= rhs.lexical
        end
    end
    false
end

function _sparql_numeric_value(lit::Literal)
    v = tryparse(Float64, lit.lexical)
    !isnothing(v) && return v
    nothing
end

# ─── Aggregate evaluation ──────────────────────────────────────────

function _sparql_compute_aggregate(agg::_Aggregate, group::Vector{Dict{String, Identifier}})
    values = Identifier[b[agg.var] for b in group if haskey(b, agg.var)]
    if agg.distinct
        values = unique(values)
    end

    if agg.func == "COUNT"
        return Literal(length(values))
    elseif agg.func == "SUM"
        total = sum((_sparql_numeric_value(v) for v in values if v isa Literal && !isnothing(_sparql_numeric_value(v))); init=0.0)
        return Literal(isinteger(total) ? Int(total) : total)
    elseif agg.func == "AVG"
        nums = [_sparql_numeric_value(v) for v in values if v isa Literal && !isnothing(_sparql_numeric_value(v))]
        isempty(nums) && return Literal(0)
        avg = sum(nums) / length(nums)
        return Literal(isinteger(avg) ? Int(avg) : avg)
    elseif agg.func == "MIN"
        isempty(values) && return Literal("")
        return reduce((a, b) -> string(a) < string(b) ? a : b, values)
    elseif agg.func == "MAX"
        isempty(values) && return Literal("")
        return reduce((a, b) -> string(a) > string(b) ? a : b, values)
    elseif agg.func == "GROUP_CONCAT"
        return Literal(join([v isa Literal ? v.lexical : string(v) for v in values], " "))
    elseif agg.func == "SAMPLE"
        isempty(values) && return Literal("")
        return first(values)
    end
    Literal("")
end

# ─── BIND expression evaluation ───────────────────────────────────

function _sparql_eval_bind_expr(expr::AbstractString, binding::Dict{String, Identifier})
    expr = strip(expr)

    # URI: <...>
    if startswith(expr, '<') && endswith(expr, '>')
        return URIRef(expr[2:end-1])
    end

    # Variable: ?var (only if the entire expression is a variable name)
    if startswith(expr, '?') && !isnothing(match(r"^\?\w+$", expr))
        return get(binding, String(expr[2:end]), nothing)
    end

    # Literal
    if startswith(expr, '"') || startswith(expr, '\'')
        return _sparql_parse_literal(expr)
    end

    # Numeric literal
    if !isnothing(tryparse(Int, expr))
        return Literal(parse(Int, expr))
    end
    if !isnothing(tryparse(Float64, expr))
        return Literal(parse(Float64, expr))
    end

    # Boolean
    expr == "true" && return Literal(true)
    expr == "false" && return Literal(false)

    # STR(?var)
    m = match(r"^STR\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        isnothing(val) && return nothing
        return Literal(val isa Literal ? val.lexical : string(val))
    end

    # CONCAT(expr1, expr2, ...)
    m = match(r"^CONCAT\s*\((.+)\)$"i, expr)
    if !isnothing(m)
        args = _sparql_split_args(m.captures[1])
        parts = String[]
        for arg in args
            val = _sparql_eval_bind_expr(strip(arg), binding)
            isnothing(val) && return nothing
            push!(parts, val isa Literal ? val.lexical : string(val))
        end
        return Literal(join(parts))
    end

    # IF(cond, then, else)
    m = match(r"^IF\s*\((.+)\)$"i, expr)
    if !isnothing(m)
        args = _sparql_split_args(m.captures[1])
        length(args) == 3 || return nothing
        # Evaluate condition as a filter expression (needs a dummy graph)
        cond_val = try
            _sparql_eval_filter_expr(strip(args[1]), binding, RDFGraph())
        catch
            false
        end
        return cond_val ? _sparql_eval_bind_expr(strip(args[2]), binding) : _sparql_eval_bind_expr(strip(args[3]), binding)
    end

    # COALESCE(expr1, expr2, ...)
    m = match(r"^COALESCE\s*\((.+)\)$"i, expr)
    if !isnothing(m)
        args = _sparql_split_args(m.captures[1])
        for arg in args
            val = _sparql_eval_bind_expr(strip(arg), binding)
            !isnothing(val) && return val
        end
        return nothing
    end

    # IRI(str) / URI(str)
    m = match(r"^(?:IRI|URI)\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        isnothing(val) && return nothing
        s = val isa Literal ? val.lexical : string(val)
        return URIRef(s)
    end

    # BNODE() or BNODE(str)
    m = match(r"^BNODE\s*\(\s*(.*?)\s*\)$"i, expr)
    if !isnothing(m)
        arg = strip(m.captures[1])
        if isempty(arg)
            return BNode()
        else
            val = _sparql_eval_bind_expr(arg, binding)
            isnothing(val) && return BNode()
            return BNode(val isa Literal ? val.lexical : string(val))
        end
    end

    # STRLANG(str, lang)
    m = match(r"^STRLANG\s*\((.+)\)$"i, expr)
    if !isnothing(m)
        args = _sparql_split_args(m.captures[1])
        length(args) == 2 || return nothing
        val = _sparql_eval_bind_expr(strip(args[1]), binding)
        lang_val = _sparql_eval_bind_expr(strip(args[2]), binding)
        isnothing(val) && return nothing
        s = val isa Literal ? val.lexical : string(val)
        l = lang_val isa Literal ? lang_val.lexical : string(something(lang_val, ""))
        return Literal(s, lang=l)
    end

    # STRDT(str, datatype)
    m = match(r"^STRDT\s*\((.+)\)$"i, expr)
    if !isnothing(m)
        args = _sparql_split_args(m.captures[1])
        length(args) == 2 || return nothing
        val = _sparql_eval_bind_expr(strip(args[1]), binding)
        dt_val = _sparql_eval_bind_expr(strip(args[2]), binding)
        isnothing(val) && return nothing
        s = val isa Literal ? val.lexical : string(val)
        dt_uri = dt_val isa URIRef ? dt_val : URIRef(dt_val isa Literal ? dt_val.lexical : string(something(dt_val, "")))
        return Literal(s, datatype=dt_uri)
    end

    # UCASE(str)
    m = match(r"^UCASE\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        isnothing(val) && return nothing
        s = val isa Literal ? val.lexical : string(val)
        return Literal(uppercase(s))
    end

    # LCASE(str)
    m = match(r"^LCASE\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        isnothing(val) && return nothing
        s = val isa Literal ? val.lexical : string(val)
        return Literal(lowercase(s))
    end

    # SUBSTR(str, start[, length])
    m = match(r"^SUBSTR\s*\((.+)\)$"i, expr)
    if !isnothing(m)
        args = _sparql_split_args(m.captures[1])
        (length(args) < 2 || length(args) > 3) && return nothing
        val = _sparql_eval_bind_expr(strip(args[1]), binding)
        isnothing(val) && return nothing
        s = val isa Literal ? val.lexical : string(val)
        start_val = _sparql_eval_bind_expr(strip(args[2]), binding)
        isnothing(start_val) && return nothing
        start_idx = _sparql_to_int(start_val)
        isnothing(start_idx) && return nothing
        if length(args) == 3
            len_val = _sparql_eval_bind_expr(strip(args[3]), binding)
            isnothing(len_val) && return nothing
            len = _sparql_to_int(len_val)
            isnothing(len) && return nothing
            return Literal(s[start_idx:min(start_idx + len - 1, lastindex(s))])
        else
            return Literal(s[start_idx:end])
        end
    end

    # STRLEN(str)
    m = match(r"^STRLEN\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        isnothing(val) && return nothing
        s = val isa Literal ? val.lexical : string(val)
        return Literal(length(s))
    end

    # REPLACE(str, pattern, replacement)
    m = match(r"^REPLACE\s*\((.+)\)$"i, expr)
    if !isnothing(m)
        args = _sparql_split_args(m.captures[1])
        length(args) >= 3 || return nothing
        val = _sparql_eval_bind_expr(strip(args[1]), binding)
        isnothing(val) && return nothing
        s = val isa Literal ? val.lexical : string(val)
        pat_val = _sparql_eval_bind_expr(strip(args[2]), binding)
        rep_val = _sparql_eval_bind_expr(strip(args[3]), binding)
        isnothing(pat_val) && return nothing
        isnothing(rep_val) && return nothing
        pat = pat_val isa Literal ? pat_val.lexical : string(pat_val)
        rep = rep_val isa Literal ? rep_val.lexical : string(rep_val)
        return Literal(replace(s, Regex(pat) => rep))
    end

    # CONTAINS(str1, str2)
    m = match(r"^CONTAINS\s*\((.+)\)$"i, expr)
    if !isnothing(m)
        args = _sparql_split_args(m.captures[1])
        length(args) == 2 || return nothing
        v1 = _sparql_eval_bind_expr(strip(args[1]), binding)
        v2 = _sparql_eval_bind_expr(strip(args[2]), binding)
        (isnothing(v1) || isnothing(v2)) && return nothing
        s1 = v1 isa Literal ? v1.lexical : string(v1)
        s2 = v2 isa Literal ? v2.lexical : string(v2)
        return Literal(occursin(s2, s1))
    end

    # STRSTARTS(str1, str2)
    m = match(r"^STRSTARTS\s*\((.+)\)$"i, expr)
    if !isnothing(m)
        args = _sparql_split_args(m.captures[1])
        length(args) == 2 || return nothing
        v1 = _sparql_eval_bind_expr(strip(args[1]), binding)
        v2 = _sparql_eval_bind_expr(strip(args[2]), binding)
        (isnothing(v1) || isnothing(v2)) && return nothing
        s1 = v1 isa Literal ? v1.lexical : string(v1)
        s2 = v2 isa Literal ? v2.lexical : string(v2)
        return Literal(startswith(s1, s2))
    end

    # STRENDS(str1, str2)
    m = match(r"^STRENDS\s*\((.+)\)$"i, expr)
    if !isnothing(m)
        args = _sparql_split_args(m.captures[1])
        length(args) == 2 || return nothing
        v1 = _sparql_eval_bind_expr(strip(args[1]), binding)
        v2 = _sparql_eval_bind_expr(strip(args[2]), binding)
        (isnothing(v1) || isnothing(v2)) && return nothing
        s1 = v1 isa Literal ? v1.lexical : string(v1)
        s2 = v2 isa Literal ? v2.lexical : string(v2)
        return Literal(endswith(s1, s2))
    end

    # ABS(num)
    m = match(r"^ABS\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        isnothing(val) && return nothing
        val isa Literal || return nothing
        n = _sparql_numeric_value(val)
        isnothing(n) && return nothing
        return Literal(isinteger(n) ? Int(abs(n)) : abs(n))
    end

    # CEIL(num)
    m = match(r"^CEIL\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        isnothing(val) && return nothing
        val isa Literal || return nothing
        n = _sparql_numeric_value(val)
        isnothing(n) && return nothing
        return Literal(Int(ceil(n)))
    end

    # FLOOR(num)
    m = match(r"^FLOOR\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        isnothing(val) && return nothing
        val isa Literal || return nothing
        n = _sparql_numeric_value(val)
        isnothing(n) && return nothing
        return Literal(Int(floor(n)))
    end

    # ROUND(num)
    m = match(r"^ROUND\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        isnothing(val) && return nothing
        val isa Literal || return nothing
        n = _sparql_numeric_value(val)
        isnothing(n) && return nothing
        return Literal(Int(round(n)))
    end

    # NOW()
    if occursin(r"^NOW\s*\(\s*\)$"i, expr)
        return Literal(Dates.now())
    end

    # UUID()
    if occursin(r"^UUID\s*\(\s*\)$"i, expr)
        return URIRef("urn:uuid:" * string(UUIDs.uuid4()))
    end

    # STRUUID()
    if occursin(r"^STRUUID\s*\(\s*\)$"i, expr)
        return Literal(string(UUIDs.uuid4()))
    end

    # ENCODE_FOR_URI(str)
    m = match(r"^ENCODE_FOR_URI\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        isnothing(val) && return nothing
        s = val isa Literal ? val.lexical : string(val)
        return Literal(_sparql_uri_encode(s))
    end

    # LANG(?var)
    m = match(r"^LANG\s*\(\s*\?(\w+)\s*\)$"i, expr)
    if !isnothing(m)
        val = get(binding, String(m.captures[1]), nothing)
        val isa Literal || return Literal("")
        return Literal(something(val.language, ""))
    end

    # DATATYPE(?var)
    m = match(r"^DATATYPE\s*\(\s*\?(\w+)\s*\)$"i, expr)
    if !isnothing(m)
        val = get(binding, String(m.captures[1]), nothing)
        val isa Literal || return nothing
        return val.datatype
    end

    # ─── SHA Hash Functions (SPARQL 1.2) ──────────────────────────
    m = match(r"^SHA1\s*\((.+)\)$"i, expr)
    if !isnothing(m)
        inner = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        isnothing(inner) && return nothing
        s = inner isa Literal ? inner.lexical : string(inner)
        return Literal(bytes2hex(SHA.sha1(Vector{UInt8}(s))))
    end

    m = match(r"^SHA256\s*\((.+)\)$"i, expr)
    if !isnothing(m)
        inner = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        isnothing(inner) && return nothing
        s = inner isa Literal ? inner.lexical : string(inner)
        return Literal(bytes2hex(SHA.sha256(Vector{UInt8}(s))))
    end

    m = match(r"^SHA384\s*\((.+)\)$"i, expr)
    if !isnothing(m)
        inner = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        isnothing(inner) && return nothing
        s = inner isa Literal ? inner.lexical : string(inner)
        return Literal(bytes2hex(SHA.sha384(Vector{UInt8}(s))))
    end

    m = match(r"^SHA512\s*\((.+)\)$"i, expr)
    if !isnothing(m)
        inner = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        isnothing(inner) && return nothing
        s = inner isa Literal ? inner.lexical : string(inner)
        return Literal(bytes2hex(SHA.sha512(Vector{UInt8}(s))))
    end

    # ─── Date/Time Functions (SPARQL 1.2) ─────────────────────────
    m = match(r"^YEAR\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        dt = _sparql_parse_datetime(val)
        !isnothing(dt) && return Literal(Dates.year(dt))
        return nothing
    end

    m = match(r"^MONTH\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        dt = _sparql_parse_datetime(val)
        !isnothing(dt) && return Literal(Dates.month(dt))
        return nothing
    end

    m = match(r"^DAY\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        dt = _sparql_parse_datetime(val)
        !isnothing(dt) && return Literal(Dates.day(dt))
        return nothing
    end

    m = match(r"^HOURS\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        dt = _sparql_parse_datetime(val)
        !isnothing(dt) && return Literal(Dates.hour(dt))
        return nothing
    end

    m = match(r"^MINUTES\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        dt = _sparql_parse_datetime(val)
        !isnothing(dt) && return Literal(Dates.minute(dt))
        return nothing
    end

    m = match(r"^SECONDS\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        dt = _sparql_parse_datetime(val)
        !isnothing(dt) && return Literal(Dates.second(dt))
        return nothing
    end

    m = match(r"^TZ\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        isnothing(val) && return nothing
        s = val isa Literal ? val.lexical : string(val)
        # Extract timezone from ISO 8601 string
        tz_m = match(r"(Z|[+-]\d{2}:\d{2})$", s)
        return Literal(!isnothing(tz_m) ? tz_m.captures[1] : "")
    end

    # ─── RAND() (SPARQL 1.2) ─────────────────────────────────────
    if occursin(r"^RAND\s*\(\s*\)$"i, expr)
        return Literal(rand())
    end

    # ─── STRBEFORE / STRAFTER (SPARQL 1.2) ───────────────────────
    m = match(r"^STRBEFORE\s*\((.+)\)$"i, expr)
    if !isnothing(m)
        args = _sparql_split_args(m.captures[1])
        length(args) == 2 || return nothing
        v1 = _sparql_eval_bind_expr(strip(args[1]), binding)
        v2 = _sparql_eval_bind_expr(strip(args[2]), binding)
        (isnothing(v1) || isnothing(v2)) && return nothing
        s1 = v1 isa Literal ? v1.lexical : string(v1)
        s2 = v2 isa Literal ? v2.lexical : string(v2)
        idx = findfirst(s2, s1)
        isnothing(idx) && return Literal("")
        return Literal(s1[1:first(idx)-1])
    end

    m = match(r"^STRAFTER\s*\((.+)\)$"i, expr)
    if !isnothing(m)
        args = _sparql_split_args(m.captures[1])
        length(args) == 2 || return nothing
        v1 = _sparql_eval_bind_expr(strip(args[1]), binding)
        v2 = _sparql_eval_bind_expr(strip(args[2]), binding)
        (isnothing(v1) || isnothing(v2)) && return nothing
        s1 = v1 isa Literal ? v1.lexical : string(v1)
        s2 = v2 isa Literal ? v2.lexical : string(v2)
        idx = findfirst(s2, s1)
        isnothing(idx) && return Literal("")
        return Literal(s1[last(idx)+1:end])
    end

    # ─── sameValue (SPARQL 1.2) ──────────────────────────────────
    m = match(r"^sameValue\s*\((.+)\)$"i, expr)
    if !isnothing(m)
        args = _sparql_split_args(m.captures[1])
        length(args) == 2 || return nothing
        v1 = _sparql_eval_bind_expr(strip(args[1]), binding)
        v2 = _sparql_eval_bind_expr(strip(args[2]), binding)
        (isnothing(v1) || isnothing(v2)) && return nothing
        if v1 isa Literal && v2 isa Literal
            n1 = _sparql_numeric_value(v1)
            n2 = _sparql_numeric_value(v2)
            if !isnothing(n1) && !isnothing(n2)
                return Literal(n1 == n2)
            end
        end
        return Literal(v1 == v2)
    end

    # ─── RDF-star triple term functions (SPARQL 1.2) ─────────────

    # TRIPLE(s, p, o) — construct a triple term
    m = match(r"^TRIPLE\s*\((.+)\)$"i, expr)
    if !isnothing(m)
        args = _sparql_split_args(m.captures[1])
        length(args) == 3 || return nothing
        s = _sparql_eval_bind_expr(strip(args[1]), binding)
        p = _sparql_eval_bind_expr(strip(args[2]), binding)
        o = _sparql_eval_bind_expr(strip(args[3]), binding)
        (isnothing(s) || isnothing(p) || isnothing(o)) && return nothing
        s isa Node || return nothing
        p isa URIRef || return nothing
        return TripleTerm(s, p, o)
    end

    # SUBJECT(triple_term)
    m = match(r"^SUBJECT\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        val isa TripleTerm && return val.subject
        return nothing
    end

    # PREDICATE(triple_term)
    m = match(r"^PREDICATE\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        val isa TripleTerm && return val.predicate
        return nothing
    end

    # OBJECT(triple_term)
    m = match(r"^OBJECT\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        val isa TripleTerm && return val.object
        return nothing
    end

    # isTRIPLE(term)
    m = match(r"^isTRIPLE\s*\(\s*(.+)\s*\)$"i, expr)
    if !isnothing(m)
        val = _sparql_eval_bind_expr(strip(m.captures[1]), binding)
        isnothing(val) && return nothing
        return Literal(val isa TripleTerm)
    end

    # ─── GeoSPARQL Functions ─────────────────────────────────────────
    m = match(r"^(?:geof:(\w+)|<http://www\.opengis\.net/def/function/geosparql/(\w+)>)\s*\((.+)\)$"i, expr)
    if !isnothing(m)
        func_name = lowercase(something(m.captures[1], m.captures[2]))
        args = _sparql_split_args(m.captures[3])
        if func_name == "distance" && length(args) >= 2
            v1 = _sparql_eval_bind_expr(strip(args[1]), binding)
            v2 = _sparql_eval_bind_expr(strip(args[2]), binding)
            g1 = _extract_wkt_geometry(v1)
            g2 = _extract_wkt_geometry(v2)
            (isnothing(g1) || isnothing(g2)) && return nothing
            return Literal(geo_distance(g1, g2))
        end
        _geo_rel = Dict("sfcontains"=>geo_contains, "sfwithin"=>geo_within,
            "sfintersects"=>geo_intersects, "sfoverlaps"=>geo_overlaps,
            "sftouches"=>geo_touches, "sfdisjoint"=>geo_disjoint, "sfequals"=>geo_equals)
        if haskey(_geo_rel, func_name) && length(args) >= 2
            v1 = _sparql_eval_bind_expr(strip(args[1]), binding)
            v2 = _sparql_eval_bind_expr(strip(args[2]), binding)
            g1 = _extract_wkt_geometry(v1)
            g2 = _extract_wkt_geometry(v2)
            (isnothing(g1) || isnothing(g2)) && return nothing
            return Literal(_geo_rel[func_name](g1, g2))
        end
    end

    # ─── Arithmetic expressions (SPARQL 1.2) ─────────────────────
    arith_result = _sparql_eval_arithmetic(expr, binding)
    !isnothing(arith_result) && return arith_result

    nothing
end

# ─── DateTime helper ──────────────────────────────────────────────

function _sparql_parse_datetime(val)
    isnothing(val) && return nothing
    val isa Literal || return nothing
    s = val.lexical
    # Try DateTime format: 2024-01-15T10:30:00, with optional timezone
    s_clean = replace(s, r"(Z|[+-]\d{2}:\d{2})$" => "")
    dt = tryparse(Dates.DateTime, s_clean)
    !isnothing(dt) && return dt
    d = tryparse(Dates.Date, s_clean)
    !isnothing(d) && return Dates.DateTime(d)
    nothing
end

# ─── Arithmetic expression evaluator ─────────────────────────────

function _sparql_eval_arithmetic(expr::AbstractString, binding::Dict{String, Identifier})
    expr = strip(expr)
    isempty(expr) && return nothing

    # Strip outer parens
    if startswith(expr, '(') && endswith(expr, ')')
        inner = _sparql_strip_outer_parens(expr)
        if !isnothing(inner)
            result = _sparql_eval_arithmetic(inner, binding)
            !isnothing(result) && return result
        end
    end

    # Find top-level + or - (lowest precedence, right-to-left)
    for op in ['+', '-']
        pos = _find_top_level_op(expr, op)
        if !isnothing(pos)
            left = _sparql_eval_bind_expr(expr[1:pos-1], binding)
            right = _sparql_eval_bind_expr(expr[pos+1:end], binding)
            (isnothing(left) || isnothing(right)) && return nothing
            lv = _sparql_numeric_value_any(left)
            rv = _sparql_numeric_value_any(right)
            (isnothing(lv) || isnothing(rv)) && return nothing
            result = op == '+' ? lv + rv : lv - rv
            return Literal(isinteger(result) ? Int(result) : result)
        end
    end

    # Find top-level * or / (higher precedence, left-to-right)
    for op in ['*', '/']
        pos = _find_top_level_op(expr, op)
        if !isnothing(pos)
            left = _sparql_eval_bind_expr(expr[1:pos-1], binding)
            right = _sparql_eval_bind_expr(expr[pos+1:end], binding)
            (isnothing(left) || isnothing(right)) && return nothing
            lv = _sparql_numeric_value_any(left)
            rv = _sparql_numeric_value_any(right)
            (isnothing(lv) || isnothing(rv)) && return nothing
            if op == '/' && rv == 0
                return nothing
            end
            result = op == '*' ? lv * rv : lv / rv
            return Literal(isinteger(result) ? Int(result) : result)
        end
    end

    nothing
end

function _sparql_numeric_value_any(val)
    val isa Literal || return nothing
    _sparql_numeric_value(val)
end

function _find_top_level_op(expr::AbstractString, op::Char)
    depth = 0
    in_string = false
    in_uri = false
    quote_char = nothing
    chars = collect(expr)
    # For + and -, search right-to-left; for * and /, search left-to-right
    indices = op in ('+', '-') ? reverse(collect(eachindex(chars))) : collect(eachindex(chars))
    for i in indices
        c = chars[i]
        if in_string
            c == quote_char && (in_string = false)
            continue
        end
        if in_uri
            c == '>' && (in_uri = false)
            continue
        end
        if c == '"' || c == '\''
            in_string = true; quote_char = c
        elseif c == '<'
            in_uri = true
        elseif op in ('+', '-')
            # Right-to-left: parens tracking is reversed
            if c == ')'; depth += 1
            elseif c == '('; depth -= 1
            elseif c == op && depth == 0
                # Don't match unary minus/plus at start or after another operator
                i == 1 && continue
                prev = chars[i-1]
                prev in ('(', '+', '-', '*', '/') && continue
                return i
            end
        else
            if c == '('; depth += 1
            elseif c == ')'; depth -= 1
            elseif c == op && depth == 0
                return i
            end
        end
    end
    nothing
end

function _sparql_split_args(s::AbstractString)
    args = String[]
    buf = IOBuffer()
    depth = 0
    in_string = false
    in_uri = false
    qc = nothing
    for c in s
        if in_string
            write(buf, c)
            c == qc && (in_string = false)
        elseif in_uri
            write(buf, c)
            c == '>' && (in_uri = false)
        elseif c == '"' || c == '\''
            in_string = true; qc = c; write(buf, c)
        elseif c == '<'
            in_uri = true; write(buf, c)
        elseif c == '('
            depth += 1; write(buf, c)
        elseif c == ')'
            depth -= 1; write(buf, c)
        elseif c == ',' && depth == 0
            push!(args, String(take!(buf)))
        else
            write(buf, c)
        end
    end
    remaining = String(take!(buf))
    !isempty(strip(remaining)) && push!(args, remaining)
    args
end

function _sparql_to_int(val)
    val isa Literal || return nothing
    v = tryparse(Int, val.lexical)
    !isnothing(v) && return v
    f = tryparse(Float64, val.lexical)
    !isnothing(f) && return Int(f)
    nothing
end

function _sparql_uri_encode(s::AbstractString)
    io = IOBuffer()
    for c in s
        if isletter(c) || isdigit(c) || c in ('-', '_', '.', '~')
            write(io, c)
        else
            for b in codeunits(string(c))
                write(io, '%')
                write(io, uppercase(string(b, base=16, pad=2)))
            end
        end
    end
    String(take!(io))
end

# ─── SPARQL UPDATE ─────────────────────────────────────────────────

"""
    sparql_update(g::RDFGraph, query::AbstractString)

Execute a SPARQL UPDATE operation against a graph, modifying it in-place.

Supports: INSERT DATA, DELETE DATA, DELETE/INSERT WHERE, CLEAR, DROP, LOAD.
"""
function sparql_update(g::RDFGraph, query::AbstractString)
    parsed = _sparql_parse_update(String(query), g)
    _sparql_exec_update(g, parsed)
    nothing
end

function _sparql_parse_update(query::AbstractString, g::RDFGraph)
    q = strip(query)
    prefixes = Dict{String, String}()

    while true
        m = match(r"^\s*PREFIX\s+(\w*):\s*<([^>]*)>\s*"i, q)
        isnothing(m) && break
        prefixes[m.captures[1]] = m.captures[2]
        q = q[m.offset + length(m.match):end]
    end

    for (prefix, uri) in namespaces(g)
        !haskey(prefixes, prefix) && (prefixes[prefix] = uri)
    end

    q_upper = uppercase(strip(q))

    # CLEAR ALL / CLEAR DEFAULT
    m = match(r"^(?:CLEAR|DROP)\s+(ALL|DEFAULT|NAMED)\s*$"i, strip(q))
    if !isnothing(m)
        return _SPARQLClear(uppercase(m.captures[1]))
    end

    # LOAD <uri> [INTO GRAPH <target>]
    m = match(r"^LOAD\s+<([^>]+)>\s*(?:INTO\s+GRAPH\s+<([^>]+)>)?\s*$"i, strip(q))
    if !isnothing(m)
        return _SPARQLLoad(m.captures[1], m.captures[2])
    end

    # INSERT DATA { triples }
    m = match(r"^INSERT\s+DATA\s*\{(.*)\}\s*$"is, strip(q))
    if !isnothing(m)
        triples_data = _sparql_parse_template(m.captures[1], prefixes)
        return _SPARQLInsertData(triples_data, prefixes)
    end

    # DELETE DATA { triples }
    m = match(r"^DELETE\s+DATA\s*\{(.*)\}\s*$"is, strip(q))
    if !isnothing(m)
        triples_data = _sparql_parse_template(m.captures[1], prefixes)
        return _SPARQLDeleteData(triples_data, prefixes)
    end

    # DELETE { del } INSERT { ins } WHERE { patterns }
    m = match(r"^DELETE\s*\{(.*?)\}\s*INSERT\s*\{(.*?)\}\s*WHERE\s*\{(.*)\}\s*$"is, strip(q))
    if !isnothing(m)
        del = _sparql_parse_template(m.captures[1], prefixes)
        ins = _sparql_parse_template(m.captures[2], prefixes)
        pats = _sparql_parse_patterns(m.captures[3], prefixes)
        return _SPARQLModify(del, ins, pats, prefixes)
    end

    # DELETE { del } WHERE { patterns }
    m = match(r"^DELETE\s*\{(.*?)\}\s*WHERE\s*\{(.*)\}\s*$"is, strip(q))
    if !isnothing(m)
        del = _sparql_parse_template(m.captures[1], prefixes)
        pats = _sparql_parse_patterns(m.captures[2], prefixes)
        return _SPARQLModify(del, Tuple{Any,Any,Any}[], pats, prefixes)
    end

    # INSERT { ins } WHERE { patterns }
    m = match(r"^INSERT\s*\{(.*?)\}\s*WHERE\s*\{(.*)\}\s*$"is, strip(q))
    if !isnothing(m)
        ins = _sparql_parse_template(m.captures[1], prefixes)
        pats = _sparql_parse_patterns(m.captures[2], prefixes)
        return _SPARQLModify(Tuple{Any,Any,Any}[], ins, pats, prefixes)
    end

    # COPY DEFAULT TO <graph> — parse but noop for single graph
    m = match(r"^COPY\s+DEFAULT\s+TO\s+<([^>]+)>\s*$"i, strip(q))
    if !isnothing(m)
        return _SPARQLClear("NOOP")
    end

    throw(ArgumentError("Unsupported SPARQL UPDATE operation"))
end

function _sparql_exec_update(g::RDFGraph, op::_SPARQLClear)
    if op.target in ("ALL", "DEFAULT")
        for t in collect(triples(g))
            remove!(g, t)
        end
    end
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
    bindings = _sparql_eval_patterns(g, op.patterns)
    # Delete first
    for binding in bindings
        for (s_t, p_t, o_t) in op.delete_template
            s = _sparql_resolve(s_t, binding)
            p = _sparql_resolve(p_t, binding)
            o = _sparql_resolve(o_t, binding)
            (isnothing(s) || isnothing(p) || isnothing(o)) && continue
            s isa Node && p isa URIRef && o isa Identifier && remove!(g, Triple(s, p, o))
        end
    end
    # Then insert
    for binding in bindings
        for (s_t, p_t, o_t) in op.insert_template
            s = _sparql_resolve(s_t, binding)
            p = _sparql_resolve(p_t, binding)
            o = _sparql_resolve(o_t, binding)
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

    io = IOBuffer()
    write(io, "{\"head\":{\"vars\":[")
    write(io, join(["\"$(v)\"" for v in vars], ","))
    write(io, "]},\"results\":{\"bindings\":[")
    for (i, binding) in enumerate(results)
        i > 1 && write(io, ",")
        write(io, "{")
        first_var = true
        for v in vars
            val = get(binding, v, nothing)
            isnothing(val) && continue
            !first_var && write(io, ",")
            first_var = false
            write(io, "\"$(v)\":")
            write(io, _sparql_json_term(val))
        end
        write(io, "}")
    end
    write(io, "]}}")
    String(take!(io))
end

function _sparql_json_term(val::URIRef)
    "{\"type\":\"uri\",\"value\":\"$(val.value)\"}"
end

function _sparql_json_term(val::BNode)
    "{\"type\":\"bnode\",\"value\":\"$(val.id)\"}"
end

function _sparql_json_term(val::Literal)
    io = IOBuffer()
    write(io, "{\"type\":\"literal\",\"value\":\"$(_sparql_json_escape(val.lexical))\"")
    if !isnothing(val.language) && !isempty(val.language)
        write(io, ",\"xml:lang\":\"$(val.language)\"")
    elseif !isnothing(val.datatype) && val.datatype != URIRef(_XSD * "string")
        write(io, ",\"datatype\":\"$(val.datatype.value)\"")
    end
    write(io, "}")
    String(take!(io))
end

function _sparql_json_escape(s::AbstractString)
    s = replace(s, "\\" => "\\\\")
    s = replace(s, "\"" => "\\\"")
    s = replace(s, "\n" => "\\n")
    s = replace(s, "\r" => "\\r")
    s = replace(s, "\t" => "\\t")
    s
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

# ─── SERVICE query builder ─────────────────────────────────────────

function _build_service_query(patterns::Vector{Any})
    # Build a simple SELECT * WHERE { ... } from BGP patterns
    body = IOBuffer()
    vars = Set{String}()
    for p in patterns
        if p isa _BGPTriple
            s_str = p.s isa String ? "?" * p.s : n3(p.s)
            p_str = p.p isa String ? "?" * p.p : n3(p.p)
            o_str = p.o isa String ? "?" * p.o : n3(p.o)
            p.s isa String && push!(vars, p.s)
            p.p isa String && push!(vars, p.p)
            p.o isa String && push!(vars, p.o)
            write(body, "  $s_str $p_str $o_str .\n")
        end
    end
    "SELECT * WHERE {\n" * String(take!(body)) * "}\n"
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
    # Strip prefixes/version to detect query type
    q_stripped = replace(strip(query), r"^\s*(PREFIX|BASE|VERSION)\s+[^\n]*\n"im => "")
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
    # Try Turtle first, fall back to N-Triples
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
