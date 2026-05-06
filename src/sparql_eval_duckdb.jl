# ─── DuckDB SPARQL BGP pushdown ──────────────────────────────────────
#
# Translate pure-BGP SELECT queries (with optional GROUP BY, aggregates,
# trailing OPTIONAL, ORDER BY, LIMIT/OFFSET, DISTINCT) into a single
# SQL query executed by DuckDB. This collapses what was N round-trips
# (one per pattern) into one vectorized columnar query plan.
#
# Eligibility (gate) — the pushdown handles queries where:
#   - all WHERE patterns are PatTriple, optionally followed by a
#     trailing PatOptional whose body is also pure PatTriple;
#   - no FILTER, BIND, UNION, MINUS, VALUES, SERVICE, LATERAL,
#     subquery, property paths, or RDF-star;
#   - all aggregates are COUNT/SUM/AVG/MIN/MAX/SAMPLE over a var or
#     COUNT(*) — no GROUP_CONCAT/MEDIAN/MODE;
#   - no SELECT expressions (BIND-as-projection);
#   - GROUP BY / ORDER BY only reference plain variables or aggregate
#     aliases.
#
# Anything else falls back to the generic SPARQL evaluator.

using DuckDB

# ─── Eligibility check ───────────────────────────────────────────────

function _duckdb_pushdown_eligible(q::SparqlSelect, g::RDFGraph)
    g.store isa DuckDBStore || return false
    isnothing(q.having) || return false
    isempty(q.select_exprs) || return false

    pats = q.patterns
    isempty(pats) && return false
    n = length(pats)

    # Check pattern shape: PatTriple* + optional PatOptional{PatTriple*}
    has_opt = pats[end] isa PatOptional
    body_end = has_opt ? n - 1 : n
    body_end >= 1 || return false
    @inbounds for i in 1:body_end
        p = pats[i]
        p isa PatTriple || return false
        _is_simple_triple_term(p.subject)   || return false
        _is_simple_pred(p.predicate)        || return false
        _is_simple_triple_term(p.object)    || return false
    end
    if has_opt
        for ip in (pats[end]::PatOptional).patterns
            ip isa PatTriple || return false
            _is_simple_triple_term(ip.subject) || return false
            _is_simple_pred(ip.predicate)      || return false
            _is_simple_triple_term(ip.object)  || return false
        end
    end

    # Aggregates
    for sa in q.aggregates
        f = sa.agg.func
        f in ("COUNT","SUM","AVG","MIN","MAX","SAMPLE") || return false
        a = sa.agg.arg
        (a isa ExprStar || a isa ExprVar) || return false
    end

    # GROUP BY: only variables
    for gb in q.group_by
        gb isa ExprVar || return false
    end

    # ORDER BY: variable or aggregate alias only
    agg_aliases = Set{String}(sa.alias for sa in q.aggregates)
    for ob in q.order_by
        e = ob[1]
        e isa ExprVar || return false
    end

    return true
end

@inline _is_simple_triple_term(x) =
    (x isa AbstractString) || (x isa Identifier)

@inline _is_simple_pred(x) =
    (x isa AbstractString) || (x isa URIRef)

# ─── SQL generation ──────────────────────────────────────────────────

# Per-variable source column reference for the SQL projection / joins.
struct _DDBVarRef
    alias::String     # SQL table alias (e.g. "t1")
    col::Symbol       # :subject, :predicate, or :object
end

# Encode a constant Identifier or string for SQL injection. Returns
# the SQL literal expression. Subjects/predicates are plain strings;
# objects need extra type/datatype/lang constraints emitted separately.
@inline function _sql_str_lit(s::AbstractString)
    # DuckDB uses single-quote strings; escape single-quote by doubling.
    "'" * replace(String(s), "'" => "''") * "'"
end

# Encode a term that appears in subject or predicate position (URI or
# BNode only) into its DuckDB string form.
function _ddb_sp_lit(t::URIRef);  _sql_str_lit(t.value); end
function _ddb_sp_lit(t::BNode);   _sql_str_lit("_:" * t.id); end
function _ddb_sp_lit(s::AbstractString); _sql_str_lit(s); end  # already encoded

# Generate object-position WHERE clauses for a constant.
# Returns a Vector{String} of conjunctive predicates over `<alias>.<col>` etc.
function _ddb_object_constraints(alias::String, t::Identifier)
    if t isa URIRef
        ["$alias.object = $(_sql_str_lit(t.value))",
         "$alias.object_type = 'uri'"]
    elseif t isa BNode
        bn = "_:" * t.id
        ["$alias.object = $(_sql_str_lit(bn))",
         "$alias.object_type = 'bnode'"]
    elseif t isa Literal
        c = String["$alias.object = $(_sql_str_lit(t.lexical))",
                   "$alias.object_type = 'literal'"]
        if !isnothing(t.datatype)
            push!(c, "$alias.datatype = $(_sql_str_lit(t.datatype.value))")
        else
            push!(c, "$alias.datatype = ''")
        end
        if !isnothing(t.language)
            push!(c, "$alias.language = $(_sql_str_lit(t.language))")
        else
            push!(c, "$alias.language = ''")
        end
        c
    else
        String[]
    end
end

# Map an aggregate's variable reference to a SQL expression suitable
# for COUNT/SUM/AVG/MIN/MAX. For SUM/AVG we cast object to DOUBLE (with
# TRY_CAST so non-numeric rows become NULL rather than errors).
function _ddb_agg_sql(sa::SelectAggregate, var_refs::Dict{String,_DDBVarRef})
    f = sa.agg.func
    a = sa.agg.arg
    if a isa ExprStar
        return "COUNT(*)"
    end
    var = (a::ExprVar).name
    ref = var_refs[var]
    src = "$(ref.alias).$(ref.col)"
    distinct = sa.agg.distinct ? "DISTINCT " : ""
    if f == "COUNT"
        return "COUNT($(distinct)$src)"
    elseif f == "SUM"
        return "SUM($(distinct)TRY_CAST($src AS DOUBLE))"
    elseif f == "AVG"
        return "AVG($(distinct)TRY_CAST($src AS DOUBLE))"
    elseif f == "MIN"
        return "MIN($(distinct)$src)"
    elseif f == "MAX"
        return "MAX($(distinct)$src)"
    elseif f == "SAMPLE"
        return "ANY_VALUE($src)"
    end
    error("unhandled aggregate $f")
end

# Build the SQL for a single BGP (list of PatTriple). Returns:
#   (from_clause::String, where_clauses::Vector{String}, var_refs::Dict)
# where var_refs maps variable name -> _DDBVarRef giving source col.
function _ddb_build_bgp(pats::AbstractVector,
                         start_alias::Int,
                         outer_var_refs::Union{Nothing,Dict{String,_DDBVarRef}}=nothing)
    aliases = String[]
    where_clauses = String[]
    var_refs = outer_var_refs === nothing ? Dict{String,_DDBVarRef}() :
                                              copy(outer_var_refs)

    for (i, pat) in enumerate(pats)
        p = pat::PatTriple
        a = "t" * string(start_alias + i - 1)
        push!(aliases, a)

        # Subject
        s = p.subject
        if s isa AbstractString
            ref = get(var_refs, String(s), nothing)
            if ref === nothing
                var_refs[String(s)] = _DDBVarRef(a, :subject)
            else
                push!(where_clauses, "$a.subject = $(ref.alias).$(ref.col)")
            end
        else
            push!(where_clauses, "$a.subject = $(_ddb_sp_lit(s))")
        end

        # Predicate
        pr = p.predicate
        if pr isa AbstractString
            ref = get(var_refs, String(pr), nothing)
            if ref === nothing
                var_refs[String(pr)] = _DDBVarRef(a, :predicate)
            else
                push!(where_clauses, "$a.predicate = $(ref.alias).$(ref.col)")
            end
        else
            push!(where_clauses, "$a.predicate = $(_ddb_sp_lit(pr::URIRef))")
        end

        # Object
        o = p.object
        if o isa AbstractString
            ref = get(var_refs, String(o), nothing)
            if ref === nothing
                var_refs[String(o)] = _DDBVarRef(a, :object)
            else
                # Cross-position: just compare lexicals (URIs/BNodes match).
                push!(where_clauses, "$a.object = $(ref.alias).$(ref.col)")
            end
        else
            for c in _ddb_object_constraints(a, o::Identifier)
                push!(where_clauses, c)
            end
        end
    end
    return aliases, where_clauses, var_refs
end

# Build the full SQL statement for a SparqlSelect. Returns
# (sql::String, projected_var_names::Vector{String}, var_refs::Dict).
function _duckdb_pushdown_sql(q::SparqlSelect)
    pats = q.patterns
    has_opt = pats[end] isa PatOptional
    body_pats = has_opt ? pats[1:end-1] : pats
    opt_pats = has_opt ? (pats[end]::PatOptional).patterns : SparqlPattern[]

    body_aliases, body_where, var_refs = _ddb_build_bgp(body_pats, 1)

    # FROM clause for body
    from_parts = String[]
    push!(from_parts, "triples " * body_aliases[1])
    for i in 2:length(body_aliases)
        push!(from_parts, "JOIN triples " * body_aliases[i] * " ON TRUE")
    end

    if has_opt && !isempty(opt_pats)
        # OPTIONAL: LEFT JOIN with a scope-limited subquery so the
        # outer body var_refs are visible in the join condition. Easier:
        # generate a LEFT JOIN with multiple `triples` aliases on TRUE
        # plus AND'd join predicates including refs to outer.
        opt_aliases, opt_where, var_refs = _ddb_build_bgp(opt_pats,
                                                            length(body_aliases) + 1,
                                                            var_refs)
        # All opt aliases together as cross-joined LEFT join with combined
        # condition. DuckDB supports this when written as
        #   LEFT JOIN (triples o1 JOIN triples o2 ON TRUE ...) ON (cond)
        if length(opt_aliases) == 1
            cond = isempty(opt_where) ? "TRUE" : join(opt_where, " AND ")
            push!(from_parts, "LEFT JOIN triples $(opt_aliases[1]) ON ($cond)")
        else
            inner_from = "triples " * opt_aliases[1]
            for i in 2:length(opt_aliases)
                inner_from *= " JOIN triples " * opt_aliases[i] * " ON TRUE"
            end
            cond = isempty(opt_where) ? "TRUE" : join(opt_where, " AND ")
            push!(from_parts, "LEFT JOIN ($inner_from) ON ($cond)")
        end
    end

    from_sql = join(from_parts, " ")

    # Build SELECT list
    select_parts = String[]
    projected = String[]
    if !isempty(q.aggregates) || !isempty(q.group_by)
        # Aggregate query: GROUP BY vars first, then aggregates.
        for gb in q.group_by
            v = (gb::ExprVar).name
            ref = var_refs[v]
            push!(select_parts, "$(ref.alias).$(ref.col) AS \"$v\"")
            push!(projected, v)
        end
        for sa in q.aggregates
            push!(select_parts, _ddb_agg_sql(sa, var_refs) * " AS \"$(sa.alias)\"")
            push!(projected, sa.alias)
        end
    else
        # Plain SELECT (vars or *)
        sel_vars = isempty(q.variables) ? collect(keys(var_refs)) : q.variables
        for v in sel_vars
            ref = get(var_refs, v, nothing)
            ref === nothing && continue  # Var not bound by BGP — skip
            push!(select_parts, "$(ref.alias).$(ref.col) AS \"$v\"")
            push!(projected, v)
        end
    end
    distinct_kw = q.distinct ? "DISTINCT " : ""
    select_sql = "SELECT " * distinct_kw * join(select_parts, ", ")

    # WHERE
    where_sql = isempty(body_where) ? "" : " WHERE " * join(body_where, " AND ")

    # GROUP BY
    group_sql = if !isempty(q.group_by)
        " GROUP BY " * join(["\"$((gb::ExprVar).name)\"" for gb in q.group_by], ", ")
    else
        ""
    end

    # ORDER BY
    order_sql = if !isempty(q.order_by)
        parts = String[]
        for (e, dir) in q.order_by
            v = (e::ExprVar).name
            push!(parts, "\"$v\" " * (dir === :desc ? "DESC" : "ASC"))
        end
        " ORDER BY " * join(parts, ", ")
    else
        ""
    end

    # LIMIT / OFFSET
    limit_sql = isnothing(q.limit) ? "" : " LIMIT $(q.limit)"
    offset_sql = q.offset > 0 ? " OFFSET $(q.offset)" : ""

    sql = select_sql * " FROM " * from_sql * where_sql * group_sql *
           order_sql * limit_sql * offset_sql
    return sql, projected, var_refs
end

# ─── Result decoding ─────────────────────────────────────────────────
#
# DuckDB returns each row as a NamedTuple with the column aliases. We
# decode each cell back to an Identifier:
#   - aggregate alias: numeric or text → Literal
#   - bound variable: look up the var_ref's column type (subject/predicate
#     are always URIs or BNodes; object needs richer decoding using the
#     companion object_type/datatype/language columns — but our SQL
#     doesn't fetch those for projected variables, so we apply a best-
#     effort decode based on the string form).
#
# To keep decoding correct for object-position variables (which may be
# URIs, BNodes, or literals), we extend the SELECT to also fetch the
# accompanying object_type/datatype/language for each projected var that
# sources from an :object column.

function _duckdb_pushdown_run(g::RDFGraph, q::SparqlSelect)
    sql, projected, var_refs = _duckdb_pushdown_sql(q)
    # Augment select for object-sourced projected vars: also fetch
    # the metadata columns so we can rebuild Literals correctly.
    obj_meta = Dict{String,String}()  # var -> alias name
    extra_selects = String[]
    for v in projected
        ref = get(var_refs, v, nothing)
        ref === nothing && continue
        if ref.col === :object
            tag = "__$(v)_meta_"
            push!(extra_selects, "$(ref.alias).object_type AS \"$(tag)t\"")
            push!(extra_selects, "$(ref.alias).datatype AS \"$(tag)d\"")
            push!(extra_selects, "$(ref.alias).language AS \"$(tag)l\"")
            obj_meta[v] = tag
        end
    end
    if !isempty(extra_selects)
        # Skip metadata augmentation for aggregated queries — they don't
        # have raw object rows in scope.
        if isempty(q.aggregates) && isempty(q.group_by)
            sql = replace(sql, " FROM " => ", " * join(extra_selects, ", ") * " FROM ", count=1)
        end
    end

    store = g.store::DuckDBStore
    qres = DBInterface.execute(store.con, sql)
    bindings = Dict{String,Identifier}[]
    for row in qres
        b = Dict{String,Identifier}()
        for v in projected
            colsym = Symbol(v)
            val = getproperty(row, colsym)
            val === missing && continue
            ref = get(var_refs, v, nothing)
            if ref !== nothing
                if ref.col === :object && haskey(obj_meta, v) &&
                    isempty(q.aggregates) && isempty(q.group_by)
                    tag = obj_meta[v]
                    ot = getproperty(row, Symbol(tag * "t"))
                    dt = getproperty(row, Symbol(tag * "d"))
                    lg = getproperty(row, Symbol(tag * "l"))
                    b[v] = _duckdb_decode_object(string(val),
                                                  ot === missing ? "" : string(ot),
                                                  dt === missing ? "" : string(dt),
                                                  lg === missing ? "" : string(lg))
                else
                    # Subject/predicate/group-key/aggregate value
                    b[v] = _decode_pushdown_value(val)
                end
            else
                # Aggregate alias
                b[v] = _decode_pushdown_value(val)
            end
        end
        push!(bindings, b)
    end
    return bindings
end

# Decode a generic SQL value (string/number) back to an Identifier.
@inline function _decode_pushdown_value(val)
    if val isa AbstractString
        s = String(val)
        return startswith(s, "_:") ? BNode(s[3:end]) :
                _looks_like_uri(s) ? URIRef(s) : Literal(s)
    elseif val isa Integer
        return Literal(string(val),
                        datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))
    elseif val isa AbstractFloat
        return Literal(string(val),
                        datatype=URIRef("http://www.w3.org/2001/XMLSchema#double"))
    elseif val isa Bool
        return Literal(val ? "true" : "false",
                        datatype=URIRef("http://www.w3.org/2001/XMLSchema#boolean"))
    elseif val === nothing || val === missing
        return Literal("")
    else
        return Literal(string(val))
    end
end

@inline function _looks_like_uri(s::AbstractString)
    # Crude heuristic — sufficient for projected subject/predicate vars
    # (which are always URIs or BNodes; BNodes already handled).
    occursin(":", s) && (startswith(s, "http://") || startswith(s, "https://") ||
                         startswith(s, "urn:") || startswith(s, "file://") ||
                         startswith(s, "ftp://") || occursin("://", s))
end
