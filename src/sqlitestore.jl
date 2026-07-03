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
    # Prepared statement cache keyed by SQL text. Only a small, bounded set
    # of SQL strings is ever generated (one INSERT plus the 8/16 pattern
    # variants of SELECT/DELETE), so this never grows unbounded.
    _stmts::Dict{String, SQLite.Stmt}
end

function SQLiteStore(db_path::AbstractString=":memory:")
    db = SQLite.DB(db_path)
    _init_schema!(db)
    SQLiteStore(db, -1, Dict{String, SQLite.Stmt}())
end

function SQLiteStore(db::SQLite.DB)
    _init_schema!(db)
    SQLiteStore(db, -1, Dict{String, SQLite.Stmt}())
end

function _create_triples_table!(db::SQLite.DB)
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS triples (
            subject TEXT NOT NULL,
            predicate TEXT NOT NULL,
            object TEXT NOT NULL,
            object_type TEXT NOT NULL,
            datatype TEXT NOT NULL,
            language TEXT NOT NULL,
            direction TEXT NOT NULL,
            UNIQUE(subject, predicate, object, object_type, datatype, language, direction)
        )
    """)
end

function _init_schema!(db::SQLite.DB)
    cols = Set{String}()
    for row in DBInterface.execute(db, "PRAGMA table_info(triples)")
        push!(cols, String(row.name))
    end

    if isempty(cols)
        _create_triples_table!(db)
    elseif !("direction" in cols)
        DBInterface.execute(db, "BEGIN")
        try
            DBInterface.execute(db, "ALTER TABLE triples RENAME TO triples_old")
            _create_triples_table!(db)
            DBInterface.execute(db, """
                INSERT OR IGNORE INTO triples
                    (subject, predicate, object, object_type, datatype, language, direction)
                SELECT
                    subject,
                    predicate,
                    object,
                    object_type,
                    COALESCE(datatype, ''),
                    COALESCE(language, ''),
                    ''
                FROM triples_old
            """)
            DBInterface.execute(db, "DROP TABLE triples_old")
            DBInterface.execute(db, "COMMIT")
        catch
            DBInterface.execute(db, "ROLLBACK")
            rethrow()
        end
    end
    DBInterface.execute(db, "CREATE INDEX IF NOT EXISTS idx_spo ON triples(subject, predicate, object)")
    DBInterface.execute(db, "CREATE INDEX IF NOT EXISTS idx_pos ON triples(predicate, object, subject)")
    DBInterface.execute(db, "CREATE INDEX IF NOT EXISTS idx_osp ON triples(object, subject, predicate)")
    # Migration: drop single-column indexes from older schema versions —
    # each is a leftmost prefix of one of the composite indexes above
    # (idx_s ⊂ idx_spo, idx_p ⊂ idx_pos, idx_o ⊂ idx_osp), so they only
    # waste space and slow down writes.
    DBInterface.execute(db, "DROP INDEX IF EXISTS idx_s")
    DBInterface.execute(db, "DROP INDEX IF EXISTS idx_p")
    DBInterface.execute(db, "DROP INDEX IF EXISTS idx_o")
    nothing
end

# Return a cached prepared statement for `sql`, preparing it on first use.
function _prepared(store::SQLiteStore, sql::String)
    get!(store._stmts, sql) do
        DBInterface.prepare(store.db, sql)
    end
end

const _SQL_INSERT_TRIPLE = "INSERT OR IGNORE INTO triples (subject, predicate, object, object_type, datatype, language, direction) VALUES (?, ?, ?, ?, ?, ?, ?)"

# ─── Term encoding/decoding ──────────────────────────────────────────

_sql_encode_node(n::URIRef) = n.value
_sql_encode_node(n::BNode) = "_:" * n.id

# Use empty strings instead of NULL for datatype/language so that
# SQLite's UNIQUE constraint correctly deduplicates triples.

function _sql_encode_object(o::URIRef)
    (o.value, "uri", "", "", "")
end

function _sql_encode_object(o::BNode)
    ("_:" * o.id, "bnode", "", "", "")
end

function _sql_encode_object(o::Literal)
    dt = isnothing(o.datatype) ? "" : o.datatype.value
    lang = isnothing(o.language) ? "" : o.language
    dir = isnothing(o.direction) ? "" : o.direction
    (o.lexical, "literal", dt, lang, dir)
end

function _sql_decode_node(value::AbstractString)
    if startswith(value, "_:")
        BNode(value[3:end])
    else
        URIRef(value)
    end
end

function _sql_decode_object(value, obj_type, datatype, language, direction)
    # Handle missing values from SQLite (NULL → missing) and empty strings
    dt_val = (datatype === missing || datatype == "") ? nothing : datatype
    lang_val = (language === missing || language == "") ? nothing : language
    dir_val = (direction === missing || direction == "") ? nothing : direction

    if obj_type == "uri"
        URIRef(value)
    elseif obj_type == "bnode"
        BNode(value[3:end])
    else  # "literal"
        dt = isnothing(dt_val) ? nothing : URIRef(dt_val)
        Literal(value; datatype=dt, lang=lang_val, direction=dir_val)
    end
end

# ─── Store interface implementation ──────────────────────────────────

function add!(store::SQLiteStore, t::Triple)
    s = _sql_encode_node(t.subject)
    p = t.predicate.value
    o_val, o_type, o_dt, o_lang, o_dir = _sql_encode_object(t.object)
    DBInterface.execute(_prepared(store, _SQL_INSERT_TRIPLE),
        (s, p, o_val, o_type, o_dt, o_lang, o_dir))
    store._count = -1
    store
end

"""
    add_bulk!(store::SQLiteStore, triples_iter) -> store

Add many triples in a single transaction using one prepared INSERT
statement. Orders of magnitude faster than repeated `add!` calls (which
each commit their own implicit transaction). Duplicates are ignored, as
with `add!`. For batching arbitrary operations, see [`transaction`](@ref).
"""
function add_bulk!(store::SQLiteStore, triples_iter)
    stmt = _prepared(store, _SQL_INSERT_TRIPLE)
    transaction(store) do
        for t in triples_iter
            s = _sql_encode_node(t.subject)
            p = t.predicate.value
            o_val, o_type, o_dt, o_lang, o_dir = _sql_encode_object(t.object)
            DBInterface.execute(stmt, (s, p, o_val, o_type, o_dt, o_lang, o_dir))
        end
    end
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
        o_val, o_type, o_dt, o_lang, o_dir = _sql_encode_object(o)
        push!(conditions, "object = ?")
        push!(params, o_val)
        push!(conditions, "object_type = ?")
        push!(params, o_type)
        push!(conditions, "datatype = ?")
        push!(params, o_dt)
        push!(conditions, "language = ?")
        push!(params, o_lang)
        push!(conditions, "direction = ?")
        push!(params, o_dir)
    end

    sql = "DELETE FROM triples"
    if !isempty(conditions)
        sql *= " WHERE " * join(conditions, " AND ")
    end
    DBInterface.execute(_prepared(store, sql), params)
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
        o_val, o_type, o_dt, o_lang, o_dir = _sql_encode_object(o)
        push!(conditions, "object = ?")
        push!(params, o_val)
        push!(conditions, "object_type = ?")
        push!(params, o_type)
        push!(conditions, "datatype = ?")
        push!(params, o_dt)
        push!(conditions, "language = ?")
        push!(params, o_lang)
        push!(conditions, "direction = ?")
        push!(params, o_dir)
    end

    sql = "SELECT subject, predicate, object, object_type, datatype, language, direction FROM triples"
    if !isempty(conditions)
        sql *= " WHERE " * join(conditions, " AND ")
    end

    # Materialize eagerly (avoids holding the cursor open) and return the
    # vector directly — callers only iterate/collect, so the previous
    # unbuffered Channel replay added a task round-trip per triple for
    # nothing.
    result = DBInterface.execute(_prepared(store, sql), params)
    out = Triple[]
    for row in result
        s_node = _sql_decode_node(row.subject)
        p_node = URIRef(row.predicate)
        o_node = _sql_decode_object(row.object, row.object_type, row.datatype, row.language, row.direction)
        push!(out, Triple(s_node, p_node, o_node))
    end
    out
end

function Base.length(store::SQLiteStore)
    if store._count < 0
        result = DBInterface.execute(_prepared(store, "SELECT COUNT(*) as cnt FROM triples"))
        row = first(result)
        store._count = row.cnt
    end
    store._count
end

Base.isempty(store::SQLiteStore) = length(store) == 0

"""
    close(store::SQLiteStore)

Close cached prepared statements and the underlying database connection.
"""
function Base.close(store::SQLiteStore)
    for stmt in values(store._stmts)
        try
            DBInterface.close!(stmt)
        catch
        end
    end
    empty!(store._stmts)
    DBInterface.close!(store.db)
end

"""
    transaction(f, store::SQLiteStore)

Execute function `f` within a database transaction. Use this to batch many
`add!`/`remove!` calls into one commit — without it every call commits its
own implicit transaction, which is dramatically slower. For plain bulk
insertion prefer [`add_bulk!`](@ref), which also reuses a single prepared
statement.

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
