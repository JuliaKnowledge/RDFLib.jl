# ─── DuckDB SPARQL BGP pushdown ──────────────────────────────────────
#
# Translate pure-BGP SELECT queries (with optional GROUP BY, COUNT
# aggregates, trailing OPTIONAL, DISTINCT/REDUCED) into a single SQL
# query executed by DuckDB. This collapses what was N round-trips
# (one per pattern) into one vectorized columnar query plan.
#
# CORRECTNESS CONTRACT: the pushdown must return exactly the same
# answers as the main SPARQL evaluator. Anything whose SQL semantics
# could diverge from SPARQL term semantics (typed literals, language
# tags, value-vs-lexical comparison, SPARQL ORDER BY total order,
# numeric aggregate typing) is rejected by the eligibility gate and
# falls back to the generic evaluator.
#
# Eligibility (gate) — the pushdown handles queries where:
#   - all WHERE patterns are PatTriple, optionally followed by a
#     trailing PatOptional whose body is also pure PatTriple;
#   - no FILTER (SQL comparisons over the bare `object` VARCHAR ignore
#     datatype/language and TRY_CAST silently NULLs strings — both
#     diverge from SPARQL), no BIND, UNION, MINUS, VALUES, SERVICE,
#     LATERAL, subquery, property paths, or RDF-star;
#   - aggregates are limited to the COUNT family: COUNT(*), COUNT(?v),
#     and COUNT(DISTINCT ?v) when ?v is provably a URI/BNode-valued
#     variable (appears in a subject or predicate position) so that
#     lexical-distinct equals term-distinct. SUM/AVG/MIN/MAX/SAMPLE
#     fall back (SQL MIN/MAX are VARCHAR-lexicographic; SUM/AVG typing
#     and error semantics differ from the SPARQL evaluator);
#   - no SELECT expressions (BIND-as-projection);
#   - GROUP BY only references variables bound by the *required* body
#     (not the OPTIONAL part);
#   - no ORDER BY (SPARQL ordering is a typed total order with
#     unbound-first semantics that SQL ORDER BY does not reproduce);
#   - no LIMIT/OFFSET (without ORDER BY the selected subset would be
#     nondeterministic and differ from the main evaluator).
#
# Joins, GROUP BY and DISTINCT over object-position variables compare
# the full term — (object, object_type, datatype, language) — never the
# bare lexical. Projected object variables fetch the same metadata so
# terms decode back exactly (no heuristic URI guessing).
#
# Anything else falls back to the generic SPARQL evaluator.

using DuckDB
using Tables

# ─── Eligibility check ───────────────────────────────────────────────

function _duckdb_pushdown_eligible(q::SparqlSelect, g::RDFGraph)
    g.store isa DuckDBStore || return false
    isnothing(q.having) || return false
    isempty(q.select_exprs) || return false
    isempty(q.order_by) || return false
    isnothing(q.limit) || return false
    q.offset == 0 || return false

    pats = q.patterns
    isempty(pats) && return false
    n = length(pats)

    # Find tail OPTIONAL boundary; everything before must be PatTriple.
    # Trailing PatOptional must contain only PatTriple.
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

    # Variable classification over the whole pattern set:
    #   body_vars: vars bound by the required body
    #   node_vars: vars that occur in a subject or predicate position
    #              anywhere (values are always URIs/BNodes)
    body_vars = Set{String}()
    node_vars = Set{String}()
    all_vars  = Set{String}()
    function _scan_triple!(p::PatTriple, in_body::Bool)
        s = p.subject
        if s isa AbstractString
            push!(all_vars, String(s)); push!(node_vars, String(s))
            in_body && push!(body_vars, String(s))
        end
        pr = p.predicate
        if pr isa AbstractString
            push!(all_vars, String(pr)); push!(node_vars, String(pr))
            in_body && push!(body_vars, String(pr))
        end
        o = p.object
        if o isa AbstractString
            push!(all_vars, String(o))
            in_body && push!(body_vars, String(o))
        end
        nothing
    end
    @inbounds for i in 1:body_end
        _scan_triple!(pats[i]::PatTriple, true)
    end
    if has_opt
        for ip in (pats[end]::PatOptional).patterns
            _scan_triple!(ip::PatTriple, false)
        end
    end

    # Aggregates: COUNT family only (see header for rationale).
    for sa in q.aggregates
        agg = sa.agg
        agg.func == "COUNT" || return false
        a = agg.arg
        if a isa ExprStar
            agg.distinct && return false  # COUNT(DISTINCT *): row dedupe — fall back
        elseif a isa ExprVar
            a.name in all_vars || return false
            if agg.distinct
                # Lexical DISTINCT is only exact for URI/BNode-valued vars.
                a.name in node_vars || return false
            end
        else
            return false
        end
    end

    # GROUP BY: only variables bound by the required body (an OPTIONAL-
    # sourced group key would group SQL NULLs in ways the main evaluator
    # does not reproduce).
    for gb in q.group_by
        gb isa ExprVar || return false
        (gb::ExprVar).name in body_vars || return false
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

# Shared-variable join condition between a new occurrence at
# `(alias, col)` and the variable's source `ref`. Object columns carry
# term metadata; subject/predicate columns are URI/BNode strings. The
# condition must compare TERMS, not bare lexicals:
#   object  = object   → all four columns must agree
#   object  = subject  → lexicals equal AND object is a uri/bnode
#   object  = predicate→ lexicals equal AND object is a uri
#   subject/predicate vs subject/predicate → plain string equality
function _ddb_join_conds(alias::String, col::Symbol, ref::_DDBVarRef)
    conds = String["$alias.$col = $(ref.alias).$(ref.col)"]
    if col === :object && ref.col === :object
        push!(conds, "$alias.object_type = $(ref.alias).object_type")
        push!(conds, "$alias.datatype = $(ref.alias).datatype")
        push!(conds, "$alias.language = $(ref.alias).language")
    elseif col === :object && ref.col === :subject
        push!(conds, "$alias.object_type IN ('uri','bnode')")
    elseif col === :object && ref.col === :predicate
        push!(conds, "$alias.object_type = 'uri'")
    elseif col === :subject && ref.col === :object
        push!(conds, "$(ref.alias).object_type IN ('uri','bnode')")
    elseif col === :predicate && ref.col === :object
        push!(conds, "$(ref.alias).object_type = 'uri'")
    end
    conds
end

# Build the SQL for a single BGP (list of PatTriple). Returns:
#   (aliases::Vector{String}, where_clauses::Vector{String}, var_refs::Dict)
# where var_refs maps variable name -> _DDBVarRef giving source col.
function _ddb_build_bgp(pats::AbstractVector,
                         start_alias::Int,
                         outer_var_refs::Union{Nothing,Dict{String,_DDBVarRef}}=nothing)
    aliases = String[]
    where_clauses = String[]
    var_refs = outer_var_refs === nothing ? Dict{String,_DDBVarRef}() :
                                              copy(outer_var_refs)
    alias_idx = start_alias

    for pat in pats
        p = pat::PatTriple
        a = "t" * string(alias_idx)
        alias_idx += 1
        push!(aliases, a)

        # Subject
        s = p.subject
        if s isa AbstractString
            ref = get(var_refs, String(s), nothing)
            if ref === nothing
                var_refs[String(s)] = _DDBVarRef(a, :subject)
            else
                append!(where_clauses, _ddb_join_conds(a, :subject, ref))
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
                append!(where_clauses, _ddb_join_conds(a, :predicate, ref))
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
                append!(where_clauses, _ddb_join_conds(a, :object, ref))
            end
        else
            for c in _ddb_object_constraints(a, o::Identifier)
                push!(where_clauses, c)
            end
        end
    end
    return aliases, where_clauses, var_refs
end

# Map an aggregate to a SQL expression. Gate guarantees COUNT family only.
function _ddb_agg_sql(sa::SelectAggregate, var_refs::Dict{String,_DDBVarRef})
    f = sa.agg.func
    f == "COUNT" || error("unhandled aggregate $f")
    a = sa.agg.arg
    a isa ExprStar && return "COUNT(*)"
    var = (a::ExprVar).name
    ref = get(var_refs, var, nothing)
    # Var never bound by the BGP: COUNT over an unbound var is 0.
    ref === nothing && return "COUNT(NULL)"
    src = "$(ref.alias).$(ref.col)"
    distinct = sa.agg.distinct ? "DISTINCT " : ""
    return "COUNT($(distinct)$src)"
end

# Build the full SQL statement for a SparqlSelect. Returns
# (sql, projected::Vector{String}, var_refs, obj_meta::Dict{String,String},
#  agg_aliases::Set{String}).
# `obj_meta[v]` is the column-alias prefix under which the object_type/
# datatype/language companion columns for variable `v` were selected.
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
        # OPTIONAL: LEFT JOIN; outer body var_refs are visible in the join
        # condition.
        opt_aliases, opt_where, var_refs = _ddb_build_bgp(opt_pats,
                                                            length(body_aliases) + 1,
                                                            var_refs)
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

    # Build SELECT list. Object-sourced variables additionally select the
    # term metadata columns so that decoding is exact (and DISTINCT /
    # GROUP BY operate on full terms, not bare lexicals).
    select_parts = String[]
    projected = String[]
    obj_meta = Dict{String,String}()
    group_cols = String[]

    function _select_var!(v::String; grouped::Bool=false)
        ref = var_refs[v]
        push!(select_parts, "$(ref.alias).$(ref.col) AS \"$v\"")
        push!(projected, v)
        grouped && push!(group_cols, "\"$v\"")
        if ref.col === :object
            tag = "__$(v)_meta_"
            push!(select_parts, "$(ref.alias).object_type AS \"$(tag)t\"")
            push!(select_parts, "$(ref.alias).datatype AS \"$(tag)d\"")
            push!(select_parts, "$(ref.alias).language AS \"$(tag)l\"")
            obj_meta[v] = tag
            if grouped
                push!(group_cols, "\"$(tag)t\"")
                push!(group_cols, "\"$(tag)d\"")
                push!(group_cols, "\"$(tag)l\"")
            end
        end
        nothing
    end

    agg_aliases = Set{String}()
    if !isempty(q.aggregates) || !isempty(q.group_by)
        # Aggregate query: GROUP BY vars first, then aggregates.
        for gb in q.group_by
            _select_var!((gb::ExprVar).name; grouped=true)
        end
        for sa in q.aggregates
            push!(select_parts, _ddb_agg_sql(sa, var_refs) * " AS \"$(sa.alias)\"")
            push!(projected, sa.alias)
            push!(agg_aliases, sa.alias)
        end
    else
        # Plain SELECT (vars or *)
        sel_vars = isempty(q.variables) ? sort!(collect(keys(var_refs))) : q.variables
        for v in sel_vars
            haskey(var_refs, v) || continue  # Var not bound by BGP — skip
            _select_var!(v)
        end
    end
    isempty(select_parts) && error("no projectable columns")
    # Only DISTINCT forces dedup. REDUCED is implementation-defined and the main
    # evaluator keeps all rows (matching the W3C reference results), so the
    # pushdown must keep them too for backend consistency.
    distinct_kw = q.distinct ? "DISTINCT " : ""
    select_sql = "SELECT " * distinct_kw * join(select_parts, ", ")

    # WHERE
    where_sql = isempty(body_where) ? "" : " WHERE " * join(body_where, " AND ")

    # GROUP BY (over full terms — includes metadata columns)
    group_sql = isempty(group_cols) ? "" : " GROUP BY " * join(group_cols, ", ")

    sql = select_sql * " FROM " * from_sql * where_sql * group_sql
    return sql, projected, var_refs, obj_meta, agg_aliases
end

# ─── Result decoding ─────────────────────────────────────────────────
#
# Every cell decodes EXACTLY:
#   - object-sourced variable: via the companion object_type/datatype/
#     language metadata columns (same reconstruction as the store API);
#   - subject/predicate-sourced variable: URI or BNode by the "_:"
#     encoding (no heuristics — these positions hold nothing else);
#   - COUNT aggregate alias: integer literal (matches `_agg_finalize`).

function _duckdb_pushdown_run(g::RDFGraph, q::SparqlSelect)
    sql, projected, var_refs, obj_meta, agg_aliases = _duckdb_pushdown_sql(q)

    store = g.store::DuckDBStore
    qres = DBInterface.execute(store.con, sql)
    # Materialize into columns once (much cheaper than per-row NamedTuple
    # iteration when projecting many columns / many rows).
    cols = Tables.columntable(qres)
    nrows = isempty(cols) ? 0 : length(cols[1])
    isempty(cols) && return Dict{String,Identifier}[]

    n = length(projected)
    val_cols     = Vector{Any}(undef, n)
    meta_t_cols  = Vector{Any}(undef, n)
    meta_d_cols  = Vector{Any}(undef, n)
    meta_l_cols  = Vector{Any}(undef, n)
    kind         = Vector{Symbol}(undef, n)  # :object, :node, :agg
    @inbounds for (i, v) in enumerate(projected)
        val_cols[i] = cols[Symbol(v)]
        if haskey(obj_meta, v)
            tag = obj_meta[v]
            meta_t_cols[i] = cols[Symbol(tag * "t")]
            meta_d_cols[i] = cols[Symbol(tag * "d")]
            meta_l_cols[i] = cols[Symbol(tag * "l")]
            kind[i] = :object
        elseif v in agg_aliases
            kind[i] = :agg
        else
            kind[i] = :node
        end
    end

    bindings = Vector{Dict{String,Identifier}}(undef, nrows)
    @inbounds for r in 1:nrows
        b = Dict{String,Identifier}()
        for i in 1:n
            v = projected[i]
            val = val_cols[i][r]
            val === missing && continue
            k = kind[i]
            if k === :object
                ot = meta_t_cols[i][r]
                dt = meta_d_cols[i][r]
                lg = meta_l_cols[i][r]
                b[v] = _duckdb_decode_object(string(val),
                                              ot === missing ? "" : string(ot),
                                              dt === missing ? "" : string(dt),
                                              lg === missing ? "" : string(lg))
            elseif k === :agg
                b[v] = _ddb_decode_count(val)
            else
                b[v] = _duckdb_decode_node(string(val))
            end
        end
        bindings[r] = b
    end
    return bindings
end

# COUNT results come back as SQL integers; mirror the main evaluator's
# `Literal(::Integer)` (xsd:integer) finalization exactly.
@inline function _ddb_decode_count(val)
    val isa Integer && return Literal(Int(val))
    val isa AbstractFloat && return Literal(Int(round(val)))
    return Literal(string(val))
end
