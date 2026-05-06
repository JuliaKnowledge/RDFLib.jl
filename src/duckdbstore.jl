# ─── DuckDB-backed Store ─────────────────────────────────────────────
# Uses DBInterface.jl for database operations with DuckDB — an in-process
# analytical database good for large RDF datasets.

using DuckDB

"""
    DuckDBStore(db_path::AbstractString=":memory:")

A persistent RDF triple store backed by DuckDB — an in-process analytical database.
Good for large RDF datasets and analytical queries.

Uses DBInterface.jl for database operations.

# Examples
```julia
# In-memory
store = DuckDBStore()
g = RDFGraph(store=store)

# File-backed (persistent)
store = DuckDBStore("my_graph.duckdb")
g = RDFGraph(store=store)
```
"""
mutable struct DuckDBStore <: AbstractStore
    db::DuckDB.DB
    con::DuckDB.Connection
    _count::Int  # cached count, -1 means needs refresh
end

function DuckDBStore(db_path::AbstractString=":memory:")
    db = db_path == ":memory:" ? DuckDB.DB() : DuckDB.DB(db_path)
    con = DBInterface.connect(db)
    _duckdb_init_schema!(con)
    DuckDBStore(db, con, -1)
end

function _duckdb_init_schema!(con::DuckDB.Connection)
    DBInterface.execute(con, """
        CREATE TABLE IF NOT EXISTS triples (
            subject TEXT NOT NULL,
            predicate TEXT NOT NULL,
            object TEXT NOT NULL,
            object_type TEXT NOT NULL,
            datatype TEXT NOT NULL,
            language TEXT NOT NULL,
            UNIQUE(subject, predicate, object, object_type, datatype, language)
        )
    """)
    DBInterface.execute(con, "CREATE INDEX IF NOT EXISTS idx_ddb_spo ON triples(subject, predicate, object)")
    DBInterface.execute(con, "CREATE INDEX IF NOT EXISTS idx_ddb_pos ON triples(predicate, object, subject)")
    DBInterface.execute(con, "CREATE INDEX IF NOT EXISTS idx_ddb_osp ON triples(object, subject, predicate)")
    DBInterface.execute(con, "CREATE INDEX IF NOT EXISTS idx_ddb_s ON triples(subject)")
    DBInterface.execute(con, "CREATE INDEX IF NOT EXISTS idx_ddb_p ON triples(predicate)")
    DBInterface.execute(con, "CREATE INDEX IF NOT EXISTS idx_ddb_o ON triples(object)")
    nothing
end

# ─── Term encoding/decoding ──────────────────────────────────────────

_duckdb_encode_node(n::URIRef) = n.value
_duckdb_encode_node(n::BNode) = "_:" * n.id

function _duckdb_encode_object(o::URIRef)
    (o.value, "uri", "", "")
end

function _duckdb_encode_object(o::BNode)
    ("_:" * o.id, "bnode", "", "")
end

function _duckdb_encode_object(o::Literal)
    dt = isnothing(o.datatype) ? "" : o.datatype.value
    lang = isnothing(o.language) ? "" : o.language
    (o.lexical, "literal", dt, lang)
end

function _duckdb_decode_node(value::AbstractString)
    if startswith(value, "_:")
        BNode(value[3:end])
    else
        URIRef(value)
    end
end

function _duckdb_decode_object(value, obj_type, datatype, language)
    dt_val = (datatype === missing || datatype == "") ? nothing : datatype
    lang_val = (language === missing || language == "") ? nothing : language

    if obj_type == "uri"
        URIRef(value)
    elseif obj_type == "bnode"
        BNode(value[3:end])
    else  # "literal"
        dt = isnothing(dt_val) ? nothing : URIRef(dt_val)
        Literal(value; datatype=dt, lang=lang_val)
    end
end

# ─── Store interface implementation ──────────────────────────────────

function add!(store::DuckDBStore, t::Triple)
    s = _duckdb_encode_node(t.subject)
    p = t.predicate.value
    o_val, o_type, o_dt, o_lang = _duckdb_encode_object(t.object)
    try
        DBInterface.execute(store.con,
            "INSERT INTO triples (subject, predicate, object, object_type, datatype, language) VALUES (?, ?, ?, ?, ?, ?)",
            (s, p, o_val, o_type, o_dt, o_lang))
    catch e
        # Ignore unique constraint violations (duplicate triples)
        e isa DuckDB.QueryException || rethrow(e)
    end
    store._count = -1
    store
end

function remove!(store::DuckDBStore, pattern::TriplePattern)
    s, p, o = pattern
    conditions = String[]
    params = Any[]

    if !isnothing(s)
        push!(conditions, "subject = ?")
        push!(params, _duckdb_encode_node(s))
    end
    if !isnothing(p)
        push!(conditions, "predicate = ?")
        push!(params, p.value)
    end
    if !isnothing(o)
        o_val, o_type, o_dt, o_lang = _duckdb_encode_object(o)
        push!(conditions, "object = ?")
        push!(params, o_val)
        push!(conditions, "object_type = ?")
        push!(params, o_type)
        push!(conditions, "datatype = ?")
        push!(params, o_dt)
        push!(conditions, "language = ?")
        push!(params, o_lang)
    end

    sql = "DELETE FROM triples"
    if !isempty(conditions)
        sql *= " WHERE " * join(conditions, " AND ")
    end
    DBInterface.execute(store.con, sql, params)
    store._count = -1
    store
end

function triples(store::DuckDBStore, pattern::TriplePattern)
    s, p, o = pattern
    conditions = String[]
    params = Any[]

    if !isnothing(s)
        push!(conditions, "subject = ?")
        push!(params, _duckdb_encode_node(s))
    end
    if !isnothing(p)
        push!(conditions, "predicate = ?")
        push!(params, p.value)
    end
    if !isnothing(o)
        o_val, o_type, o_dt, o_lang = _duckdb_encode_object(o)
        push!(conditions, "object = ?")
        push!(params, o_val)
        push!(conditions, "object_type = ?")
        push!(params, o_type)
        push!(conditions, "datatype = ?")
        push!(params, o_dt)
        push!(conditions, "language = ?")
        push!(params, o_lang)
    end

    sql = "SELECT subject, predicate, object, object_type, datatype, language FROM triples"
    if !isempty(conditions)
        sql *= " WHERE " * join(conditions, " AND ")
    end

    # Collect results eagerly to avoid holding the cursor open
    result = DBInterface.execute(store.con, sql, params)
    rows = [(row.subject, row.predicate, row.object, row.object_type, row.datatype, row.language) for row in result]

    Channel{Triple}() do ch
        for (subj, pred, obj, obj_type, dt, lang) in rows
            s_node = _duckdb_decode_node(subj)
            p_node = URIRef(pred)
            o_node = _duckdb_decode_object(obj, obj_type, dt, lang)
            put!(ch, Triple(s_node, p_node, o_node))
        end
    end
end

function Base.length(store::DuckDBStore)
    if store._count < 0
        result = DBInterface.execute(store.con, "SELECT COUNT(*) as cnt FROM triples")
        row = first(result)
        store._count = Int(row.cnt)
    end
    store._count
end

Base.isempty(store::DuckDBStore) = length(store) == 0

"""
    close(store::DuckDBStore)

Close the underlying database connection and database.
"""
function Base.close(store::DuckDBStore)
    DBInterface.close!(store.con)
    DuckDB.close(store.db)
end

"""
    transaction(f, store::DuckDBStore)

Execute function `f` within a database transaction for bulk operations.

# Example
```julia
transaction(store) do
    for t in large_triple_list
        add!(store, t)
    end
end
```
"""
function transaction(f, store::DuckDBStore)
    DBInterface.execute(store.con, "BEGIN TRANSACTION")
    try
        f()
        DBInterface.execute(store.con, "COMMIT")
    catch e
        DBInterface.execute(store.con, "ROLLBACK")
        rethrow(e)
    end
    store._count = -1
    nothing
end

"""
    bulk_add!(store::DuckDBStore, triples_iter; dedup=true)

Bulk-load triples into a DuckDBStore using DuckDB's columnar Appender API.
Typically 30–50× faster than per-`add!` for large datasets.

The triples are first appended to a constraint-free staging table, then
moved into the main `triples` table in a single set-based `INSERT`.
With `dedup=true` (default), duplicates against the existing graph are
silently dropped (mirrors `add!` semantics). With `dedup=false`, the
unique-check is skipped — only safe when the input is known unique
*and* disjoint from the existing graph.

# Example
```julia
g = RDFGraph(store=DuckDBStore())
ts = parse_ntriples_vec(open("dataset.nt"))   # Vector{Triple}
bulk_add!(g.store, ts)
```
"""
function bulk_add!(store::DuckDBStore, ts; dedup::Bool=true)
    con = store.con
    DBInterface.execute(con, """
        CREATE TEMP TABLE IF NOT EXISTS _rdflib_bulk_stg (
            subject TEXT NOT NULL,
            predicate TEXT NOT NULL,
            object TEXT NOT NULL,
            object_type TEXT NOT NULL,
            datatype TEXT NOT NULL,
            language TEXT NOT NULL
        )
    """)
    DBInterface.execute(con, "DELETE FROM _rdflib_bulk_stg")

    appender = DuckDB.Appender(con, "_rdflib_bulk_stg")
    try
        for t in ts
            s = _duckdb_encode_node(t.subject)
            p = t.predicate.value
            ov, ot, od, ol = _duckdb_encode_object(t.object)
            DuckDB.append(appender, s)
            DuckDB.append(appender, p)
            DuckDB.append(appender, ov)
            DuckDB.append(appender, ot)
            DuckDB.append(appender, od)
            DuckDB.append(appender, ol)
            DuckDB.end_row(appender)
        end
        DuckDB.flush(appender)
    finally
        DuckDB.close(appender)
    end

    if dedup
        DBInterface.execute(con,
            "INSERT OR IGNORE INTO triples SELECT * FROM _rdflib_bulk_stg")
    else
        DBInterface.execute(con,
            "INSERT INTO triples SELECT * FROM _rdflib_bulk_stg")
    end
    DBInterface.execute(con, "DROP TABLE _rdflib_bulk_stg")

    store._count = -1
    store
end

"""
    bulk_add!(g, triples_iter; dedup=true)

Convenience wrapper dispatching on a graph rather than its store.
The graph's store must be a DuckDBStore.
"""
bulk_add!(g, ts; kwargs...) = (bulk_add!(g.store, ts; kwargs...); g)
