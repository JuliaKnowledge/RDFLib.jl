# ─── SQLite-backed Store ─────────────────────────────────────────────
# Uses DBInterface.jl for database operations, making it straightforward
# to adapt to other database backends (PostgreSQL, MySQL, etc.).

using SQLite
using DBInterface

"""
    SQLiteStore(db_path::AbstractString=":memory:")
    SQLiteStore(db::SQLite.DB)

A persistent RDF triple store backed by SQLite.

Uses DBInterface.jl for database operations, making it straightforward
to adapt to other database backends.

# Examples
```julia
# In-memory (ephemeral)
store = SQLiteStore()
g = RDFGraph(store=store)

# File-backed (persistent)
store = SQLiteStore("my_graph.db")
g = RDFGraph(store=store)
add!(g, Triple(URIRef("http://example.org/s"), URIRef("http://example.org/p"), Literal("hello")))
# Data persists across sessions
```
"""
mutable struct SQLiteStore <: AbstractStore
    db::SQLite.DB
    _count::Int  # cached count, -1 means needs refresh
end

function SQLiteStore(db_path::AbstractString=":memory:")
    db = SQLite.DB(db_path)
    _init_schema!(db)
    SQLiteStore(db, -1)
end

function SQLiteStore(db::SQLite.DB)
    _init_schema!(db)
    SQLiteStore(db, -1)
end

function _init_schema!(db::SQLite.DB)
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS triples (
            subject TEXT NOT NULL,
            predicate TEXT NOT NULL,
            object TEXT NOT NULL,
            object_type TEXT NOT NULL,
            datatype TEXT,
            language TEXT,
            UNIQUE(subject, predicate, object, object_type, datatype, language)
        )
    """)
    DBInterface.execute(db, "CREATE INDEX IF NOT EXISTS idx_spo ON triples(subject, predicate, object)")
    DBInterface.execute(db, "CREATE INDEX IF NOT EXISTS idx_pos ON triples(predicate, object, subject)")
    DBInterface.execute(db, "CREATE INDEX IF NOT EXISTS idx_osp ON triples(object, subject, predicate)")
    DBInterface.execute(db, "CREATE INDEX IF NOT EXISTS idx_s ON triples(subject)")
    DBInterface.execute(db, "CREATE INDEX IF NOT EXISTS idx_p ON triples(predicate)")
    DBInterface.execute(db, "CREATE INDEX IF NOT EXISTS idx_o ON triples(object)")
    nothing
end

# ─── Term encoding/decoding ──────────────────────────────────────────

_sql_encode_node(n::URIRef) = n.value
_sql_encode_node(n::BNode) = "_:" * n.id

# Use empty strings instead of NULL for datatype/language so that
# SQLite's UNIQUE constraint correctly deduplicates triples.

function _sql_encode_object(o::URIRef)
    (o.value, "uri", "", "")
end

function _sql_encode_object(o::BNode)
    ("_:" * o.id, "bnode", "", "")
end

function _sql_encode_object(o::Literal)
    dt = isnothing(o.datatype) ? "" : o.datatype.value
    lang = isnothing(o.language) ? "" : o.language
    (o.lexical, "literal", dt, lang)
end

function _sql_decode_node(value::AbstractString)
    if startswith(value, "_:")
        BNode(value[3:end])
    else
        URIRef(value)
    end
end

function _sql_decode_object(value, obj_type, datatype, language)
    # Handle missing values from SQLite (NULL → missing) and empty strings
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

function add!(store::SQLiteStore, t::Triple)
    s = _sql_encode_node(t.subject)
    p = t.predicate.value
    o_val, o_type, o_dt, o_lang = _sql_encode_object(t.object)
    DBInterface.execute(store.db,
        "INSERT OR IGNORE INTO triples (subject, predicate, object, object_type, datatype, language) VALUES (?, ?, ?, ?, ?, ?)",
        (s, p, o_val, o_type, o_dt, o_lang))
    store._count = -1
    store
end

function remove!(store::SQLiteStore, pattern::TriplePattern)
    s, p, o = pattern
    conditions = String[]
    params = Any[]

    if !isnothing(s)
        push!(conditions, "subject = ?")
        push!(params, _sql_encode_node(s))
    end
    if !isnothing(p)
        push!(conditions, "predicate = ?")
        push!(params, p.value)
    end
    if !isnothing(o)
        o_val, o_type, o_dt, o_lang = _sql_encode_object(o)
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
    DBInterface.execute(store.db, sql, params)
    store._count = -1
    store
end

function triples(store::SQLiteStore, pattern::TriplePattern)
    s, p, o = pattern
    conditions = String[]
    params = Any[]

    if !isnothing(s)
        push!(conditions, "subject = ?")
        push!(params, _sql_encode_node(s))
    end
    if !isnothing(p)
        push!(conditions, "predicate = ?")
        push!(params, p.value)
    end
    if !isnothing(o)
        o_val, o_type, o_dt, o_lang = _sql_encode_object(o)
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
    result = DBInterface.execute(store.db, sql, params)
    rows = [(row.subject, row.predicate, row.object, row.object_type, row.datatype, row.language) for row in result]

    Channel{Triple}() do ch
        for (subj, pred, obj, obj_type, dt, lang) in rows
            s_node = _sql_decode_node(subj)
            p_node = URIRef(pred)
            o_node = _sql_decode_object(obj, obj_type, dt, lang)
            put!(ch, Triple(s_node, p_node, o_node))
        end
    end
end

function Base.length(store::SQLiteStore)
    if store._count < 0
        result = DBInterface.execute(store.db, "SELECT COUNT(*) as cnt FROM triples")
        row = first(result)
        store._count = row.cnt
    end
    store._count
end

Base.isempty(store::SQLiteStore) = length(store) == 0

"""
    close(store::SQLiteStore)

Close the underlying database connection.
"""
Base.close(store::SQLiteStore) = DBInterface.close!(store.db)

"""
    transaction(f, store::SQLiteStore)

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
function transaction(f, store::SQLiteStore)
    DBInterface.execute(store.db, "BEGIN TRANSACTION")
    try
        f()
        DBInterface.execute(store.db, "COMMIT")
    catch e
        DBInterface.execute(store.db, "ROLLBACK")
        rethrow(e)
    end
    store._count = -1
    nothing
end
