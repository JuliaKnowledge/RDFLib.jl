# ─── ShEx (Shape Expressions) Validation ─────────────────────────────

# ─── AST Types ───────────────────────────────────────────────────────

"""
    ShExSchema

A parsed ShEx schema containing shape expressions and prefix declarations.
"""
struct ShExSchema
    prefixes::Dict{String,String}
    base::Union{String,Nothing}
    shapes::Dict{URIRef,Any}   # shape name → ShapeExpr
    start::Union{URIRef,Nothing}
end

"""
    ShExValidationReport

Result of ShEx validation: whether the focus nodes conform and individual results.
"""
struct ShExValidationReport
    conforms::Bool
    results::Vector{NamedTuple{(:node, :shape, :status, :reason), Tuple{Identifier, URIRef, Symbol, String}}}
end

# ─── Shape expression AST ───────────────────────────────────────────

abstract type ShapeExpr end
abstract type TripleExpr end

"""NodeConstraint — constrains a single RDF term (datatype, facets, values)."""
struct NodeConstraint <: ShapeExpr
    datatype::Union{URIRef,Nothing}
    node_kind::Union{Symbol,Nothing}         # :iri, :bnode, :literal, :nonliteral
    min_length::Union{Int,Nothing}
    max_length::Union{Int,Nothing}
    pattern::Union{Regex,Nothing}
    min_inclusive::Union{Float64,Nothing}
    max_inclusive::Union{Float64,Nothing}
    min_exclusive::Union{Float64,Nothing}
    max_exclusive::Union{Float64,Nothing}
    values::Union{Vector{Any},Nothing}       # value set entries
end

function NodeConstraint(;
    datatype=nothing, node_kind=nothing,
    min_length=nothing, max_length=nothing, pattern=nothing,
    min_inclusive=nothing, max_inclusive=nothing,
    min_exclusive=nothing, max_exclusive=nothing,
    values=nothing)
    NodeConstraint(datatype, node_kind, min_length, max_length, pattern,
                   min_inclusive, max_inclusive, min_exclusive, max_exclusive, values)
end

"""TripleConstraint — constrains triples with a given predicate."""
struct TripleConstraint <: TripleExpr
    predicate::URIRef
    value_expr::Union{ShapeExpr,Nothing}   # constraint on the object
    min_card::Int
    max_card::Int                          # -1 means unbounded
    inverse::Bool
end

function TripleConstraint(predicate::URIRef;
    value_expr=nothing, min_card=1, max_card=1, inverse=false)
    TripleConstraint(predicate, value_expr, min_card, max_card, inverse)
end

const UNBOUNDED = -1

"""EachOf — all triple expressions must match (AND of triple exprs)."""
struct EachOf <: TripleExpr
    exprs::Vector{TripleExpr}
end

"""OneOf — exactly one triple expression must match (OR of triple exprs)."""
struct OneOf <: TripleExpr
    exprs::Vector{TripleExpr}
end

"""Shape — a shape with an optional triple expression body."""
struct Shape <: ShapeExpr
    expression::Union{TripleExpr,Nothing}
    closed::Bool
    extra::Vector{URIRef}
end

function Shape(; expression=nothing, closed=false, extra=URIRef[])
    Shape(expression, closed, extra)
end

"""ShapeAnd — conjunction of shape expressions."""
struct ShapeAnd <: ShapeExpr
    exprs::Vector{ShapeExpr}
end

"""ShapeOr — disjunction of shape expressions."""
struct ShapeOr <: ShapeExpr
    exprs::Vector{ShapeExpr}
end

"""ShapeNot — negation of a shape expression."""
struct ShapeNot <: ShapeExpr
    expr::ShapeExpr
end

"""ShapeRef — reference to a named shape in the schema."""
struct ShapeRef <: ShapeExpr
    ref::URIRef
end

"""ShapeExternal — externally-defined shape (always passes)."""
struct ShapeExternal <: ShapeExpr end

"""ShapeEmpty — the empty/dot shape (matches any node)."""
struct ShapeEmpty <: ShapeExpr end

# ─── Shape map entries ──────────────────────────────────────────────

struct ShapeMapEntry
    node::Union{Identifier,Nothing}       # nothing = query map with focus_type
    shape::URIRef
    focus_type::Union{URIRef,Nothing}      # for query shape maps: {FOCUS a :Type}
end

# ─── ShExC Parser ───────────────────────────────────────────────────

const _SHEX_XSD = "http://www.w3.org/2001/XMLSchema#"

mutable struct ShExParser
    input::String
    pos::Int
    prefixes::Dict{String,String}
    base::Union{String,Nothing}
    shapes::Dict{URIRef,ShapeExpr}
    start::Union{URIRef,Nothing}
end

function ShExParser(input::String)
    ShExParser(input, 1, Dict{String,String}(), nothing,
               Dict{URIRef,ShapeExpr}(), nothing)
end

# ─── Lexer helpers ──────────────────────────────────────────────────

function _shex_skip_ws!(p::ShExParser)
    while p.pos <= length(p.input)
        c = p.input[p.pos]
        if c == '#'
            # skip comment to end of line
            while p.pos <= length(p.input) && p.input[p.pos] != '\n'
                p.pos += 1
            end
        elseif isspace(c)
            p.pos += 1
        else
            break
        end
    end
end

function _shex_peek(p::ShExParser)
    _shex_skip_ws!(p)
    p.pos > length(p.input) ? nothing : p.input[p.pos]
end

function _shex_at_end(p::ShExParser)
    _shex_skip_ws!(p)
    p.pos > length(p.input)
end

function _shex_expect(p::ShExParser, s::AbstractString)
    _shex_skip_ws!(p)
    if !startswith(SubString(p.input, p.pos), s)
        got = p.pos <= length(p.input) ? p.input[p.pos:min(p.pos+20, length(p.input))] : "<EOF>"
        error("ShEx parse error at position $(p.pos): expected '$s', got '$got'")
    end
    p.pos += length(s)
end

function _shex_match_keyword(p::ShExParser, kw::AbstractString)
    _shex_skip_ws!(p)
    sub = SubString(p.input, p.pos)
    if startswith(sub, kw)
        after = p.pos + length(kw)
        if after > length(p.input) || !isletter(p.input[after])
            p.pos = after
            return true
        end
    end
    false
end

function _shex_read_iri(p::ShExParser)
    _shex_skip_ws!(p)
    if p.input[p.pos] == '<'
        p.pos += 1
        start = p.pos
        while p.pos <= length(p.input) && p.input[p.pos] != '>'
            p.pos += 1
        end
        uri = p.input[start:p.pos-1]
        p.pos += 1  # skip '>'
        if !isnothing(p.base) && !occursin("://", uri)
            uri = p.base * uri
        end
        return URIRef(uri)
    elseif p.input[p.pos] == '_' && p.pos + 1 <= length(p.input) && p.input[p.pos+1] == ':'
        # blank node — not an IRI but handle gracefully
        p.pos += 2
        start = p.pos
        while p.pos <= length(p.input) && (isletter(p.input[p.pos]) || isdigit(p.input[p.pos]) || p.input[p.pos] in ('.', '-', '_'))
            p.pos += 1
        end
        return BNode(p.input[start:p.pos-1])
    else
        return _shex_read_pname(p)
    end
end

function _shex_read_pname(p::ShExParser)
    _shex_skip_ws!(p)
    start = p.pos
    # Read prefix part
    while p.pos <= length(p.input) && p.input[p.pos] != ':' && (isletter(p.input[p.pos]) || isdigit(p.input[p.pos]) || p.input[p.pos] in ('-', '_', '.'))
        p.pos += 1
    end
    if p.pos > length(p.input) || p.input[p.pos] != ':'
        error("ShEx parse error at position $(start): expected prefixed name")
    end
    prefix = p.input[start:p.pos-1]
    p.pos += 1  # skip ':'
    # Read local part
    local_start = p.pos
    while p.pos <= length(p.input) && (isletter(p.input[p.pos]) || isdigit(p.input[p.pos]) || p.input[p.pos] in ('-', '_', '.', '/', '%'))
        p.pos += 1
    end
    local_name = p.input[local_start:p.pos-1]
    base_uri = get(p.prefixes, prefix, nothing)
    if isnothing(base_uri)
        error("ShEx parse error: undefined prefix '$prefix'")
    end
    URIRef(base_uri * local_name)
end

function _shex_read_string(p::ShExParser)
    _shex_skip_ws!(p)
    _shex_expect(p, "\"")
    buf = IOBuffer()
    while p.pos <= length(p.input) && p.input[p.pos] != '"'
        if p.input[p.pos] == '\\'
            p.pos += 1
            c = p.input[p.pos]
            if c == 'n'; write(buf, '\n')
            elseif c == 't'; write(buf, '\t')
            elseif c == 'r'; write(buf, '\r')
            elseif c == '\\'; write(buf, '\\')
            elseif c == '"'; write(buf, '"')
            else write(buf, c)
            end
        else
            write(buf, p.input[p.pos])
        end
        p.pos += 1
    end
    _shex_expect(p, "\"")
    String(take!(buf))
end

function _shex_read_integer(p::ShExParser)
    _shex_skip_ws!(p)
    start = p.pos
    if p.pos <= length(p.input) && p.input[p.pos] == '-'
        p.pos += 1
    end
    while p.pos <= length(p.input) && isdigit(p.input[p.pos])
        p.pos += 1
    end
    parse(Int, p.input[start:p.pos-1])
end

function _shex_read_number(p::ShExParser)
    _shex_skip_ws!(p)
    start = p.pos
    if p.pos <= length(p.input) && (p.input[p.pos] == '-' || p.input[p.pos] == '+')
        p.pos += 1
    end
    while p.pos <= length(p.input) && isdigit(p.input[p.pos])
        p.pos += 1
    end
    if p.pos <= length(p.input) && p.input[p.pos] == '.'
        p.pos += 1
        while p.pos <= length(p.input) && isdigit(p.input[p.pos])
            p.pos += 1
        end
    end
    parse(Float64, p.input[start:p.pos-1])
end

# ─── Top-level parser ───────────────────────────────────────────────

"""
    parse_shex(input::String) -> ShExSchema

Parse a ShExC (compact syntax) schema string into a `ShExSchema`.

# Example
```julia
schema = parse_shex(\"\"\"
    PREFIX ex: <http://example.org/>
    PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>

    ex:PersonShape {
        ex:name xsd:string ;
        ex:age xsd:integer ?
    }
\"\"\")
```
"""
function parse_shex(input::String)
    p = ShExParser(input)
    _shex_parse_schema!(p)
    ShExSchema(p.prefixes, p.base, p.shapes, p.start)
end

function _shex_parse_schema!(p::ShExParser)
    while !_shex_at_end(p)
        c = _shex_peek(p)
        isnothing(c) && break

        if _shex_match_keyword(p, "PREFIX") || _shex_match_keyword(p, "prefix")
            _shex_parse_prefix!(p)
        elseif _shex_match_keyword(p, "BASE") || _shex_match_keyword(p, "base")
            _shex_parse_base!(p)
        elseif _shex_match_keyword(p, "start")
            _shex_skip_ws!(p)
            _shex_expect(p, "=")
            _shex_skip_ws!(p)
            ref = _shex_read_iri(p)
            p.start = ref isa URIRef ? ref : nothing
        else
            _shex_parse_shape_decl!(p)
        end
    end
end

function _shex_parse_prefix!(p::ShExParser)
    _shex_skip_ws!(p)
    start = p.pos
    while p.pos <= length(p.input) && p.input[p.pos] != ':'
        p.pos += 1
    end
    prefix = p.input[start:p.pos-1]
    p.pos += 1  # skip ':'
    _shex_skip_ws!(p)
    iri = _shex_read_iri(p)
    p.prefixes[prefix] = iri.value
end

function _shex_parse_base!(p::ShExParser)
    _shex_skip_ws!(p)
    iri = _shex_read_iri(p)
    p.base = iri.value
end

function _shex_parse_shape_decl!(p::ShExParser)
    _shex_skip_ws!(p)
    name = _shex_read_iri(p)
    name isa URIRef || error("ShEx parse error: shape name must be an IRI, got $name")
    _shex_skip_ws!(p)

    expr = _shex_parse_shape_expr(p)
    p.shapes[name] = expr
end

# ─── Shape expression parsing ───────────────────────────────────────

function _shex_parse_shape_expr(p::ShExParser)
    _shex_skip_ws!(p)
    left = _shex_parse_shape_expr_atom(p)
    _shex_skip_ws!(p)

    # Check for AND / OR
    while !_shex_at_end(p)
        if _shex_match_keyword(p, "AND")
            right = _shex_parse_shape_expr_atom(p)
            left = left isa ShapeAnd ? ShapeAnd(push!(copy(left.exprs), right)) : ShapeAnd([left, right])
        elseif _shex_match_keyword(p, "OR")
            right = _shex_parse_shape_expr_atom(p)
            left = left isa ShapeOr ? ShapeOr(push!(copy(left.exprs), right)) : ShapeOr([left, right])
        else
            break
        end
        _shex_skip_ws!(p)
    end
    left
end

function _shex_parse_shape_expr_atom(p::ShExParser)
    _shex_skip_ws!(p)
    c = _shex_peek(p)
    isnothing(c) && error("ShEx parse error: unexpected end of input")

    if _shex_match_keyword(p, "NOT")
        inner = _shex_parse_shape_expr_atom(p)
        return ShapeNot(inner)
    elseif _shex_match_keyword(p, "EXTERNAL")
        return ShapeExternal()
    elseif c == '{'
        return _shex_parse_shape_body(p)
    elseif c == '('
        p.pos += 1
        expr = _shex_parse_shape_expr(p)
        _shex_expect(p, ")")
        return expr
    elseif c == '.'
        p.pos += 1
        return ShapeEmpty()
    elseif c == '@'
        p.pos += 1
        ref = _shex_read_iri(p)
        return ShapeRef(ref)
    elseif c == '['
        return _shex_parse_node_constraint(p)
    else
        # Could be a datatype IRI (NodeConstraint), prefixed name, or a CLOSED/EXTRA shape
        if _shex_match_keyword(p, "CLOSED")
            return _shex_parse_shape_body(p; closed=true)
        end
        # Try node kind keywords
        for (kw, kind) in [("IRI", :iri), ("BNode", :bnode), ("Literal", :literal), ("NonLiteral", :nonliteral)]
            if _shex_match_keyword(p, kw)
                return _shex_parse_node_constraint_cont(p; node_kind=kind)
            end
        end
        # Must be a datatype IRI for NodeConstraint, or a shape reference with @
        saved_pos = p.pos
        iri = _shex_read_iri(p)
        _shex_skip_ws!(p)
        nc = _shex_peek(p)
        if nc == '{' || nc == nothing || nc == ';' || nc == ')' || nc == ']'
            # This is a bare datatype NodeConstraint
            return NodeConstraint(datatype=iri)
        else
            # Could be followed by string facets etc; rewind
            p.pos = saved_pos
            iri2 = _shex_read_iri(p)
            return _shex_parse_node_constraint_cont(p; datatype=iri2)
        end
    end
end

function _shex_parse_shape_body(p::ShExParser; closed=false)
    _shex_skip_ws!(p)
    extra = URIRef[]

    # Handle EXTRA before {
    while _shex_match_keyword(p, "EXTRA")
        push!(extra, _shex_read_iri(p))
        _shex_skip_ws!(p)
    end

    _shex_expect(p, "{")
    _shex_skip_ws!(p)

    c = _shex_peek(p)
    if c == '}'
        p.pos += 1
        return Shape(expression=nothing, closed=closed, extra=extra)
    end

    expr = _shex_parse_triple_expr(p)
    _shex_skip_ws!(p)
    _shex_expect(p, "}")
    Shape(expression=expr, closed=closed, extra=extra)
end

# ─── Triple expression parsing ──────────────────────────────────────

function _shex_parse_triple_expr(p::ShExParser)
    first_te = _shex_parse_triple_constraint(p)
    _shex_skip_ws!(p)

    exprs = TripleExpr[first_te]
    separator = nothing

    while !_shex_at_end(p)
        c = _shex_peek(p)
        isnothing(c) && break
        if c == ';'
            p.pos += 1
            _shex_skip_ws!(p)
            # Allow trailing semicolons
            nc = _shex_peek(p)
            (isnothing(nc) || nc == '}') && break
            if !isnothing(separator) && separator == '|'
                error("ShEx parse error: cannot mix ';' and '|' separators")
            end
            separator = ';'
            push!(exprs, _shex_parse_triple_constraint(p))
            _shex_skip_ws!(p)
        elseif c == '|'
            p.pos += 1
            _shex_skip_ws!(p)
            if !isnothing(separator) && separator == ';'
                error("ShEx parse error: cannot mix ';' and '|' separators")
            end
            separator = '|'
            push!(exprs, _shex_parse_triple_constraint(p))
            _shex_skip_ws!(p)
        else
            break
        end
    end

    length(exprs) == 1 && return exprs[1]
    separator == '|' ? OneOf(exprs) : EachOf(exprs)
end

function _shex_parse_triple_constraint(p::ShExParser)
    _shex_skip_ws!(p)

    inverse = false
    if _shex_peek(p) == '^'
        p.pos += 1
        _shex_expect(p, "^")  # ^^ for inverse (we use ^ shorthand)
        inverse = true
    end

    pred = _shex_read_iri(p)
    _shex_skip_ws!(p)

    # Parse value expression
    value_expr = nothing
    c = _shex_peek(p)
    if !isnothing(c) && c ∉ (';', '|', '}', '?', '*', '+', '{')
        # Need to check if next token is a cardinality or separator
        value_expr = _shex_parse_inline_shape_expr(p)
    end

    # Parse cardinality
    min_card, max_card = _shex_parse_cardinality(p)

    TripleConstraint(pred; value_expr=value_expr, min_card=min_card, max_card=max_card, inverse=inverse)
end

function _shex_parse_inline_shape_expr(p::ShExParser)
    _shex_skip_ws!(p)
    c = _shex_peek(p)
    isnothing(c) && return nothing

    if c == '@'
        p.pos += 1
        ref = _shex_read_iri(p)
        return ShapeRef(ref)
    elseif c == '['
        return _shex_parse_node_constraint(p)
    elseif c == '.'
        p.pos += 1
        return ShapeEmpty()
    elseif c == '('
        p.pos += 1
        expr = _shex_parse_shape_expr(p)
        _shex_expect(p, ")")
        return expr
    else
        # Check for NOT keyword
        if _shex_match_keyword(p, "NOT")
            inner = _shex_parse_inline_shape_expr(p)
            return ShapeNot(inner)
        end
        # Node kind keywords
        for (kw, kind) in [("IRI", :iri), ("BNode", :bnode), ("Literal", :literal), ("NonLiteral", :nonliteral)]
            if _shex_match_keyword(p, kw)
                return _shex_parse_node_constraint_cont(p; node_kind=kind)
            end
        end
        # Try as datatype IRI
        saved_pos = p.pos
        try
            iri = _shex_read_iri(p)
            return NodeConstraint(datatype=iri)
        catch
            p.pos = saved_pos
            return nothing
        end
    end
end

function _shex_parse_cardinality(p::ShExParser)
    _shex_skip_ws!(p)
    c = _shex_peek(p)
    isnothing(c) && return (1, 1)

    if c == '?'
        p.pos += 1
        return (0, 1)
    elseif c == '*'
        p.pos += 1
        return (0, UNBOUNDED)
    elseif c == '+'
        p.pos += 1
        return (1, UNBOUNDED)
    elseif c == '{'
        p.pos += 1
        _shex_skip_ws!(p)
        min_val = _shex_read_integer(p)
        _shex_skip_ws!(p)
        c2 = _shex_peek(p)
        if c2 == ','
            p.pos += 1
            _shex_skip_ws!(p)
            c3 = _shex_peek(p)
            if c3 == '*'
                p.pos += 1
                max_val = UNBOUNDED
            elseif !isnothing(c3) && (isdigit(c3) || c3 == '-')
                max_val = _shex_read_integer(p)
            else
                max_val = UNBOUNDED
            end
        else
            max_val = min_val
        end
        _shex_expect(p, "}")
        return (min_val, max_val)
    else
        return (1, 1)
    end
end

# ─── Node constraint parsing ────────────────────────────────────────

function _shex_parse_node_constraint(p::ShExParser)
    _shex_skip_ws!(p)
    c = _shex_peek(p)

    if c == '['
        # Value set
        values = _shex_parse_value_set(p)
        return _shex_parse_node_constraint_cont(p; values=values)
    else
        return _shex_parse_node_constraint_cont(p)
    end
end

function _shex_parse_node_constraint_cont(p::ShExParser;
    datatype=nothing, node_kind=nothing, values=nothing)
    min_length = nothing
    max_length = nothing
    pattern = nothing
    min_inclusive = nothing
    max_inclusive = nothing
    min_exclusive = nothing
    max_exclusive = nothing

    while !_shex_at_end(p)
        _shex_skip_ws!(p)
        if _shex_match_keyword(p, "MinLength")
            _shex_skip_ws!(p)
            min_length = _shex_read_integer(p)
        elseif _shex_match_keyword(p, "MaxLength")
            _shex_skip_ws!(p)
            max_length = _shex_read_integer(p)
        elseif _shex_match_keyword(p, "Pattern")
            _shex_skip_ws!(p)
            pat_str = _shex_read_string(p)
            pattern = Regex(pat_str)
        elseif _shex_match_keyword(p, "MinInclusive")
            _shex_skip_ws!(p)
            min_inclusive = _shex_read_number(p)
        elseif _shex_match_keyword(p, "MaxInclusive")
            _shex_skip_ws!(p)
            max_inclusive = _shex_read_number(p)
        elseif _shex_match_keyword(p, "MinExclusive")
            _shex_skip_ws!(p)
            min_exclusive = _shex_read_number(p)
        elseif _shex_match_keyword(p, "MaxExclusive")
            _shex_skip_ws!(p)
            max_exclusive = _shex_read_number(p)
        else
            break
        end
    end

    NodeConstraint(; datatype=datatype, node_kind=node_kind,
                   min_length=min_length, max_length=max_length, pattern=pattern,
                   min_inclusive=min_inclusive, max_inclusive=max_inclusive,
                   min_exclusive=min_exclusive, max_exclusive=max_exclusive,
                   values=values)
end

function _shex_parse_value_set(p::ShExParser)
    _shex_expect(p, "[")
    values = Any[]
    _shex_skip_ws!(p)
    while _shex_peek(p) != ']'
        _shex_skip_ws!(p)
        c = _shex_peek(p)
        isnothing(c) && error("ShEx parse error: unterminated value set")
        if c == '.'
            # exclusion or wildcard
            p.pos += 1
            push!(values, :wildcard)
        elseif c == '"'
            # string literal in value set
            str = _shex_read_string(p)
            _shex_skip_ws!(p)
            nc = _shex_peek(p)
            if nc == '@'
                p.pos += 1
                lang_start = p.pos
                while p.pos <= length(p.input) && (isletter(p.input[p.pos]) || p.input[p.pos] == '-')
                    p.pos += 1
                end
                lang_tag = p.input[lang_start:p.pos-1]
                push!(values, Literal(str, lang=lang_tag))
            elseif nc == '^'
                _shex_expect(p, "^^")
                dt = _shex_read_iri(p)
                push!(values, Literal(str, datatype=dt))
            else
                push!(values, Literal(str))
            end
        elseif c == '@'
            # language stem
            p.pos += 1
            lang_start = p.pos
            while p.pos <= length(p.input) && (isletter(p.input[p.pos]) || p.input[p.pos] == '-')
                p.pos += 1
            end
            lang_tag = p.input[lang_start:p.pos-1]
            _shex_skip_ws!(p)
            if _shex_peek(p) == '~'
                p.pos += 1
                push!(values, (:lang_stem, lang_tag))
            else
                push!(values, (:language, lang_tag))
            end
        else
            # IRI or IRI stem
            iri = _shex_read_iri(p)
            _shex_skip_ws!(p)
            if _shex_peek(p) == '~'
                p.pos += 1
                push!(values, (:stem, iri))
            else
                push!(values, iri)
            end
        end
        _shex_skip_ws!(p)
    end
    _shex_expect(p, "]")
    values
end

# ─── Validation Engine ──────────────────────────────────────────────

"""
    validate_shex(graph::RDFGraph, schema::ShExSchema, shape_map) -> ShExValidationReport

Validate an RDF graph against a ShEx schema using the given shape map.

The `shape_map` is a vector of `(node, shape_uri)` pairs specifying which
nodes to validate against which shapes.

# Example
```julia
schema = parse_shex(\"\"\"
    PREFIX ex: <http://example.org/>
    PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
    ex:PersonShape {
        ex:name xsd:string ;
        ex:age xsd:integer ?
    }
\"\"\")

g = RDFGraph()
add!(g, Triple(URIRef("http://example.org/alice"), URIRef("http://example.org/name"),
               Literal("Alice", datatype=URIRef("http://www.w3.org/2001/XMLSchema#string"))))

report = validate_shex(g, schema, [
    (URIRef("http://example.org/alice"), URIRef("http://example.org/PersonShape"))
])
report.conforms  # true
```
"""
function validate_shex(graph::RDFGraph, schema::ShExSchema,
                       shape_map::Vector{<:Tuple{<:Identifier, URIRef}})
    results = NamedTuple{(:node, :shape, :status, :reason), Tuple{Identifier, URIRef, Symbol, String}}[]

    for (node, shape_uri) in shape_map
        shape_expr = get(schema.shapes, shape_uri, nothing)
        if isnothing(shape_expr)
            push!(results, (node=node, shape=shape_uri, status=:fail, reason="Shape not found: $(shape_uri.value)"))
            continue
        end
        ok, reason = _shex_validate_node(graph, schema, node, shape_expr)
        push!(results, (node=node, shape=shape_uri, status=ok ? :pass : :fail, reason=reason))
    end

    conforms = all(r -> r.status == :pass, results)
    ShExValidationReport(conforms, results)
end

# Convenience: validate start shape against all typed nodes
function validate_shex(graph::RDFGraph, schema::ShExSchema)
    if isnothing(schema.start)
        # No start shape — validate all shapes against all instances
        pairs = Tuple{Identifier, URIRef}[]
        return validate_shex(graph, schema, pairs)
    end
    shape_expr = get(schema.shapes, schema.start, nothing)
    isnothing(shape_expr) && return ShExValidationReport(true, [])
    pairs = [(n, schema.start) for n in _shex_all_subjects(graph)]
    validate_shex(graph, schema, pairs)
end

function _shex_all_subjects(graph::RDFGraph)
    seen = Set{Identifier}()
    for t in triples(graph, (nothing, nothing, nothing))
        push!(seen, t.subject)
    end
    collect(seen)
end

# ─── Node validation ────────────────────────────────────────────────

function _shex_validate_node(graph::RDFGraph, schema::ShExSchema,
                             node::Identifier, expr::ShapeExpr)
    if expr isa NodeConstraint
        return _shex_check_node_constraint(node, expr)
    elseif expr isa Shape
        return _shex_check_shape(graph, schema, node, expr)
    elseif expr isa ShapeAnd
        for e in expr.exprs
            ok, reason = _shex_validate_node(graph, schema, node, e)
            ok || return (false, reason)
        end
        return (true, "")
    elseif expr isa ShapeOr
        reasons = String[]
        for e in expr.exprs
            ok, reason = _shex_validate_node(graph, schema, node, e)
            ok && return (true, "")
            push!(reasons, reason)
        end
        return (false, "None of the OR alternatives matched: " * join(reasons, "; "))
    elseif expr isa ShapeNot
        ok, _ = _shex_validate_node(graph, schema, node, expr.expr)
        ok && return (false, "NOT constraint violated: node matches the negated shape")
        return (true, "")
    elseif expr isa ShapeRef
        ref_expr = get(schema.shapes, expr.ref, nothing)
        isnothing(ref_expr) && return (false, "Referenced shape not found: $(expr.ref.value)")
        return _shex_validate_node(graph, schema, node, ref_expr)
    elseif expr isa ShapeExternal
        return (true, "")
    elseif expr isa ShapeEmpty
        return (true, "")
    else
        return (false, "Unknown shape expression type: $(typeof(expr))")
    end
end

# ─── Node constraint checking ───────────────────────────────────────

function _shex_check_node_constraint(node::Identifier, nc::NodeConstraint)
    # Node kind check
    if !isnothing(nc.node_kind)
        if nc.node_kind == :iri && !(node isa URIRef)
            return (false, "Expected IRI, got $(typeof(node))")
        elseif nc.node_kind == :bnode && !(node isa BNode)
            return (false, "Expected BNode, got $(typeof(node))")
        elseif nc.node_kind == :literal && !(node isa Literal)
            return (false, "Expected Literal, got $(typeof(node))")
        elseif nc.node_kind == :nonliteral && (node isa Literal)
            return (false, "Expected NonLiteral, got Literal")
        end
    end

    # Datatype check
    if !isnothing(nc.datatype)
        if !(node isa Literal)
            return (false, "Expected Literal with datatype $(nc.datatype.value), got $(typeof(node))")
        end
        eff_dt = _shex_effective_datatype(node)
        if eff_dt != nc.datatype
            return (false, "Expected datatype $(nc.datatype.value), got $(eff_dt.value)")
        end
    end

    # String facets (only for Literals and URIRefs)
    lexical = _shex_node_lexical(node)

    if !isnothing(nc.min_length)
        if length(lexical) < nc.min_length
            return (false, "String length $(length(lexical)) < minLength $(nc.min_length)")
        end
    end
    if !isnothing(nc.max_length)
        if length(lexical) > nc.max_length
            return (false, "String length $(length(lexical)) > maxLength $(nc.max_length)")
        end
    end
    if !isnothing(nc.pattern)
        if !occursin(nc.pattern, lexical)
            return (false, "Value \"$lexical\" does not match pattern")
        end
    end

    # Numeric facets
    if node isa Literal
        numval = tryparse(Float64, node.lexical)
        if !isnothing(nc.min_inclusive) && !isnothing(numval)
            numval < nc.min_inclusive && return (false, "Value $numval < minInclusive $(nc.min_inclusive)")
        end
        if !isnothing(nc.max_inclusive) && !isnothing(numval)
            numval > nc.max_inclusive && return (false, "Value $numval > maxInclusive $(nc.max_inclusive)")
        end
        if !isnothing(nc.min_exclusive) && !isnothing(numval)
            numval <= nc.min_exclusive && return (false, "Value $numval <= minExclusive $(nc.min_exclusive)")
        end
        if !isnothing(nc.max_exclusive) && !isnothing(numval)
            numval >= nc.max_exclusive && return (false, "Value $numval >= maxExclusive $(nc.max_exclusive)")
        end
    end

    # Value set
    if !isnothing(nc.values)
        if !_shex_check_value_set(node, nc.values)
            return (false, "Value not in value set")
        end
    end

    (true, "")
end

function _shex_effective_datatype(lit::Literal)
    if !isnothing(lit.datatype)
        return lit.datatype
    end
    if !isnothing(lit.language)
        return URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#langString")
    end
    URIRef(_SHEX_XSD * "string")
end

function _shex_node_lexical(node::Identifier)
    node isa Literal && return node.lexical
    node isa URIRef && return node.value
    node isa BNode && return node.id
    ""
end

function _shex_check_value_set(node::Identifier, values::Vector{Any})
    for v in values
        if v isa URIRef
            node == v && return true
        elseif v isa Literal
            node == v && return true
        elseif v isa Tuple{Symbol,Any}
            kind, val = v
            if kind == :stem && node isa URIRef
                startswith(node.value, val.value) && return true
            elseif kind == :language && node isa Literal
                !isnothing(node.language) && node.language == val && return true
            elseif kind == :lang_stem && node isa Literal
                !isnothing(node.language) && startswith(node.language, val) && return true
            end
        elseif v == :wildcard
            return true
        end
    end
    false
end

# ─── Shape (with triple expression) checking ────────────────────────

function _shex_check_shape(graph::RDFGraph, schema::ShExSchema,
                           node::Identifier, shape::Shape)
    if isnothing(shape.expression)
        return (true, "")
    end

    # Collect all outgoing triples for this node
    out_triples = Triple[]
    for t in triples(graph, (node, nothing, nothing))
        push!(out_triples, t)
    end

    return _shex_check_triple_expr(graph, schema, node, shape.expression, out_triples)
end

function _shex_check_triple_expr(graph::RDFGraph, schema::ShExSchema,
                                 node::Identifier, expr::TripleExpr,
                                 available::Vector{Triple})
    if expr isa TripleConstraint
        return _shex_check_triple_constraint(graph, schema, node, expr, available)
    elseif expr isa EachOf
        for e in expr.exprs
            ok, reason = _shex_check_triple_expr(graph, schema, node, e, available)
            ok || return (false, reason)
        end
        return (true, "")
    elseif expr isa OneOf
        reasons = String[]
        for e in expr.exprs
            ok, reason = _shex_check_triple_expr(graph, schema, node, e, available)
            ok && return (true, "")
            push!(reasons, reason)
        end
        return (false, "None of the OneOf alternatives matched: " * join(reasons, "; "))
    else
        return (false, "Unknown triple expression type: $(typeof(expr))")
    end
end

function _shex_check_triple_constraint(graph::RDFGraph, schema::ShExSchema,
                                       node::Identifier, tc::TripleConstraint,
                                       available::Vector{Triple})
    # Find matching triples
    matching = Triple[]
    for t in available
        if t.predicate == tc.predicate
            push!(matching, t)
        end
    end

    count = length(matching)

    # Check cardinality
    if count < tc.min_card
        return (false, "Property $(tc.predicate.value): found $count triples, minimum is $(tc.min_card)")
    end
    if tc.max_card != UNBOUNDED && count > tc.max_card
        return (false, "Property $(tc.predicate.value): found $count triples, maximum is $(tc.max_card)")
    end

    # Check value constraints on each matching triple's object
    if !isnothing(tc.value_expr)
        for t in matching
            ok, reason = _shex_validate_node(graph, schema, t.object, tc.value_expr)
            if !ok
                return (false, "Property $(tc.predicate.value): object $(t.object) failed: $reason")
            end
        end
    end

    (true, "")
end
