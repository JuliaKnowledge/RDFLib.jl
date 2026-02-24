# ─── Full-Text Search Index for RDF Literals ───────────────────────
# Simple inverted index enabling fast text search over literal values.

"""
    TextIndex

An inverted index for fast text search on RDF literal values.

# Example
```julia
idx = TextIndex(graph)
results = text_search(idx, "alice")
results = text_search(idx, "ali*")   # prefix search
```
"""
mutable struct TextIndex
    inverted_index::Dict{String, Vector{Tuple{Triple, Int}}}
    indexed::Bool
end

"""
    TextIndex()

Create an empty text index.
"""
TextIndex() = TextIndex(Dict{String, Vector{Tuple{Triple, Int}}}(), false)

"""
    TextIndex(g::RDFGraph)

Create a text index and immediately build it from the given graph.
"""
function TextIndex(g::RDFGraph)
    idx = TextIndex()
    build!(idx, g)
    idx
end

# ─── Tokenization ──────────────────────────────────────────────────

"""
    _text_tokenize(text::AbstractString) -> Vector{String}

Tokenize text: lowercase, split on whitespace and punctuation, filter empty.
"""
function _text_tokenize(text::AbstractString)
    lowered = lowercase(text)
    tokens = split(lowered, r"[\s\p{P}]+")
    filter!(!isempty, tokens)
    String.(tokens)
end

# ─── Build index ────────────────────────────────────────────────────

"""
    build!(idx::TextIndex, g::RDFGraph)

Build (or rebuild) the inverted index from all literal values in the graph.
"""
function build!(idx::TextIndex, g::RDFGraph)
    empty!(idx.inverted_index)
    for triple in triples(g, (nothing, nothing, nothing))
        obj = triple.object
        obj isa Literal || continue
        tokens = _text_tokenize(obj.lexical)
        for (pos, token) in enumerate(tokens)
            entries = get!(Vector{Tuple{Triple, Int}}, idx.inverted_index, token)
            push!(entries, (triple, pos))
        end
    end
    idx.indexed = true
    idx
end

# ─── Search ─────────────────────────────────────────────────────────

"""
    text_search(idx::TextIndex, query::AbstractString; limit::Int=100) -> Vector{Triple}

Search the index for triples whose literal objects contain matching tokens.

Supports:
- Exact token match: `text_search(idx, "alice")`
- Prefix wildcard: `text_search(idx, "ali*")`
- Multi-token (AND): `text_search(idx, "alice bob")` — triples matching all tokens

Returns unique triples, up to `limit` results.
"""
function text_search(idx::TextIndex, query::AbstractString; limit::Int=100)
    idx.indexed || error("TextIndex has not been built; call build!(idx, graph) first")

    query_str = strip(lowercase(query))
    isempty(query_str) && return Triple[]

    tokens = _text_tokenize(query_str)
    isempty(tokens) && return Triple[]

    # Check if last token has wildcard (prefix search)
    is_prefix = endswith(strip(lowercase(query)), '*')
    if is_prefix && !isempty(tokens)
        # Remove trailing * from last token if it snuck through
        tokens[end] = rstrip(tokens[end], '*')
        isempty(tokens[end]) && pop!(tokens)
    end

    isempty(tokens) && return Triple[]

    # For single token queries
    if length(tokens) == 1
        token = tokens[1]
        matching = _text_find_token(idx, token, is_prefix)
        seen = Set{Triple}()
        result = Triple[]
        for (triple, _) in matching
            if triple ∉ seen
                push!(seen, triple)
                push!(result, triple)
                length(result) >= limit && break
            end
        end
        return result
    end

    # Multi-token: AND semantics — triple must match all tokens
    # Get sets of triples per token
    triple_sets = Set{Triple}[]
    for (i, token) in enumerate(tokens)
        do_prefix = is_prefix && i == length(tokens)
        matching = _text_find_token(idx, token, do_prefix)
        push!(triple_sets, Set{Triple}(t for (t, _) in matching))
    end

    common = intersect(triple_sets...)
    result = collect(common)
    if length(result) > limit
        resize!(result, limit)
    end
    return result
end

function _text_find_token(idx::TextIndex, token::String, prefix::Bool)
    if prefix
        results = Tuple{Triple, Int}[]
        for (key, entries) in idx.inverted_index
            if startswith(key, token)
                append!(results, entries)
            end
        end
        return results
    else
        return get(idx.inverted_index, token, Tuple{Triple, Int}[])
    end
end

# ─── SPARQL integration: CONTAINS_TEXT function ─────────────────────
# This adds a global text index that can be set and used by SPARQL filters.

const _GLOBAL_TEXT_INDEX = Ref{Union{TextIndex, Nothing}}(nothing)

"""
    set_text_index!(idx::TextIndex)

Set the global text index used by `CONTAINS_TEXT` in SPARQL FILTER expressions.
"""
function set_text_index!(idx::TextIndex)
    _GLOBAL_TEXT_INDEX[] = idx
end

"""
    clear_text_index!()

Clear the global text index.
"""
function clear_text_index!()
    _GLOBAL_TEXT_INDEX[] = nothing
end
