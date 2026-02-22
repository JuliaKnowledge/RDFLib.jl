# ─── N3 Builtin Predicates ──────────────────────────────────────────
# Computational predicates for N3 reasoning (math, string, log, crypto, list, graph, time).
# Each builtin takes (subject, object, bindings, graph) and returns a vector of
# binding dicts — non-empty on success, empty on failure.

const _BUILTIN_REGISTRY = Dict{URIRef, Function}()

# Base directory for resolving relative file URIs in builtins (log:semantics, etc.)
const _N3_BASE_DIRS = String[]

"""
    register_builtin!(uri::URIRef, fn::Function)

Register a builtin predicate.  `fn(subject, object, bindings, graph)` must return
`Vector{Dict{Variable,Identifier}}` — one dict per successful binding set.
"""
function register_builtin!(uri::URIRef, fn::Function)
    _BUILTIN_REGISTRY[uri] = fn
end

"""Return `true` if `uri` is a registered builtin predicate."""
is_builtin(uri::URIRef) = haskey(_BUILTIN_REGISTRY, uri)

"""Look up and evaluate a builtin; returns empty vector on failure."""
function evaluate_builtin(uri::URIRef, subject::Identifier, object::Identifier,
                          bindings::Dict{Variable, Identifier},
                          graph::Union{RDFGraph, Nothing}=nothing)
    fn = get(_BUILTIN_REGISTRY, uri, nothing)
    fn === nothing && return Dict{Variable, Identifier}[]
    try
        return fn(subject, object, bindings, graph)
    catch
        return Dict{Variable, Identifier}[]
    end
end

# ─── helpers ────────────────────────────────────────────────────────

# Follow variable binding chains to find the ground term (or the last Variable).
function _resolve(term::Identifier, bindings::Dict{Variable, Identifier})
    seen = Set{Variable}()
    while term isa Variable && haskey(bindings, term) && !(term in seen)
        push!(seen, term)
        term = bindings[term]
    end
    term
end

function _to_number(lit::Identifier)
    lit isa Literal || return nothing
    v = tryparse(Float64, lit.lexical)
    v === nothing && return nothing
    # Convert integer-valued floats to Int, but preserve float zeros (-0.0, 0.0e0)
    if isinteger(v) && isfinite(v) && !iszero(v)
        return Int(v)
    elseif iszero(v) && _is_integer_input(lit)
        return Int(0)
    end
    return v
end

const _XSD_INTEGER = URIRef("http://www.w3.org/2001/XMLSchema#integer")
const _XSD_DECIMAL = URIRef("http://www.w3.org/2001/XMLSchema#decimal")
const _XSD_DOUBLE  = URIRef("http://www.w3.org/2001/XMLSchema#double")

function _from_number(n)
    if n isa Integer
        Literal(string(n); datatype=_XSD_INTEGER)
    elseif isnan(n)
        Literal("NaN"; datatype=_XSD_DOUBLE)
    elseif isinf(n)
        Literal(n > 0 ? "INF" : "-INF"; datatype=_XSD_DOUBLE)
    elseif isinteger(n) && isfinite(n)
        Literal(string(Int(n)); datatype=_XSD_INTEGER)
    else
        Literal(string(Float64(n)); datatype=_XSD_DECIMAL)
    end
end

"""Check if a literal represents an integer (by datatype or lexical form)."""
function _is_integer_input(lit::Identifier)
    lit isa Literal || return false
    dt = lit.datatype
    if dt !== nothing
        dtval = dt.value
        xsd = "http://www.w3.org/2001/XMLSchema#"
        if startswith(dtval, xsd)
            t = dtval[length(xsd)+1:end]
            return t in ("integer", "int", "long", "short", "byte",
                         "nonNegativeInteger", "positiveInteger",
                         "negativeInteger", "nonPositiveInteger",
                         "unsignedInt", "unsignedLong", "unsignedShort", "unsignedByte")
        end
    end
    lex = lit.lexical
    return !occursin('.', lex) && !occursin('e', lex) && !occursin('E', lex) &&
           tryparse(Int, lex) !== nothing
end

function _success(bindings, extra::Pair{Variable, <:Identifier}...)
    result = copy(bindings)
    for (k, v) in extra
        result[k] = v
    end
    [result]
end

_failure() = Dict{Variable, Identifier}[]

"""Resolve variables in list items against bindings."""
_resolve_items(items::Vector{Identifier}, bindings::Dict{Variable, Identifier}) =
    Identifier[_resolve(item, bindings) for item in items]

"""Check if regex pattern has capture groups (unescaped `(` not followed by `?`)."""
function _has_capture_groups(pattern::String)
    i = 1
    while i <= lastindex(pattern)
        c = pattern[i]
        if c == '\\'
            i = nextind(pattern, i)
            i <= lastindex(pattern) && (i = nextind(pattern, i))
        elseif c == '(' && (nextind(pattern, i) > lastindex(pattern) || pattern[nextind(pattern, i)] != '?')
            return true
        else
            i = nextind(pattern, i)
        end
    end
    false
end

# Try to bind `term` (which may be a Variable) to `val`.
function _bind_or_check(term::Identifier, val::Identifier,
                        bindings::Dict{Variable, Identifier},
                        graph::Union{RDFGraph, Nothing}=nothing)
    resolved = _resolve(term, bindings)
    if resolved isa Variable
        return _success(bindings, resolved => val)
    else
        # Numeric comparison for literals with different datatypes
        if resolved isa Literal && val isa Literal
            a = _to_number(resolved)
            b = _to_number(val)
            if a !== nothing && b !== nothing
                eq = (a isa Integer && b isa Integer) ? (a == b) : isapprox(Float64(a), Float64(b))
                return eq ? _success(bindings) : _failure()
            end
        end
        # Structural list comparison for BNodes
        if resolved isa BNode && val isa BNode && graph !== nothing
            if _terms_equal(resolved, val, graph)
                return _success(bindings)
            end
        end
        return resolved == val ? _success(bindings) : _failure()
    end
end

# Canonical sort key for deterministic ordering of collected terms
function _canonical_sort_key(t::Identifier)
    if t isa Literal
        return (1, t.lexical, something(t.language, ""), t.datatype !== nothing ? t.datatype.value : "")
    elseif t isa URIRef
        return (2, t.value, "", "")
    elseif t isa BNode
        return (3, t.id, "", "")
    elseif t isa Formula
        return (4, string(hash(t)), "", "")
    else
        return (5, string(t), "", "")
    end
end

# Deep sort key: resolves BNode list heads to their content for sorting
function _canonical_sort_key_deep(t::Identifier, graph::Union{RDFGraph, Nothing})
    if t isa BNode && graph !== nothing
        items = _resolve_rdf_list(t, graph)
        if items !== nothing
            # Sort by list content
            content = join([_sort_key_str(it, graph) for it in items], ",")
            return (0, content, "", "")
        end
    end
    return _canonical_sort_key(t)
end

function _sort_key_str(t::Identifier, graph::Union{RDFGraph, Nothing})
    if t isa Literal
        return "L:" * t.lexical
    elseif t isa URIRef
        return "U:" * t.value
    elseif t isa BNode && graph !== nothing
        items = _resolve_rdf_list(t, graph)
        if items !== nothing
            return "(" * join([_sort_key_str(it, graph) for it in items], ",") * ")"
        end
        return "B:" * t.id
    else
        return string(t)
    end
end

# ─── RDF List resolution ───────────────────────────────────────────

const _RDF_FIRST = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
const _RDF_REST = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
const _RDF_NIL = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")

"""
    _resolve_rdf_list(node, graph) -> Union{Vector{Identifier}, Nothing}

Follow rdf:first/rdf:rest chain from `node` to reconstruct a list.
Returns nothing if `node` is not an RDF collection head.
"""
function _resolve_rdf_list(node::Identifier, graph::Union{RDFGraph, Nothing})
    graph === nothing && return nothing
    (node isa BNode || node isa URIRef) || return nothing
    node == _RDF_NIL && return Identifier[]

    items = Identifier[]
    current = node
    seen = Set{Identifier}()
    while current != _RDF_NIL
        current in seen && return nothing  # cycle
        push!(seen, current)
        first_val = nothing
        rest_val = nothing
        for t in triples(graph, (current, _RDF_FIRST, nothing))
            first_val = t.object
            break
        end
        for t in triples(graph, (current, _RDF_REST, nothing))
            rest_val = t.object
            break
        end
        first_val === nothing && return nothing
        rest_val === nothing && return nothing
        push!(items, first_val)
        current = rest_val
    end
    return items
end

"""Structural equality for two RDF terms, treating BNode list heads as equal if their lists match."""
function _terms_equal(a::Identifier, b::Identifier, graph::Union{RDFGraph, Nothing})
    a == b && return true
    graph === nothing && return false
    if a isa BNode && b isa BNode
        la = _resolve_rdf_list(a, graph)
        lb = _resolve_rdf_list(b, graph)
        if la !== nothing && lb !== nothing
            return _items_equal(la, lb, graph)
        end
    end
    return false
end

function _items_equal(a::Vector, b::Vector, graph::Union{RDFGraph, Nothing})
    length(a) != length(b) && return false
    all(_terms_equal(a[i], b[i], graph) for i in 1:length(a))
end

"""Cross-graph structural equality: resolve `a` from `graph_a` and `b` from `graph_b`."""
function _terms_equal_cross(a::Identifier, b::Identifier,
                            graph_a::Union{RDFGraph, Nothing},
                            graph_b::Union{RDFGraph, Nothing})
    a == b && return true
    if a isa BNode && b isa BNode && graph_a !== nothing && graph_b !== nothing
        la = _resolve_rdf_list(a, graph_a)
        lb = _resolve_rdf_list(b, graph_b)
        if la !== nothing && lb !== nothing
            length(la) != length(lb) && return false
            return all(_terms_equal_cross(la[i], lb[i], graph_a, graph_b) for i in 1:length(la))
        end
    end
    return false
end

"""Find an existing RDF list in `graph` whose elements match `items`."""
function _find_existing_list(items::Vector{<:Identifier}, graph::RDFGraph)
    isempty(items) && return _RDF_NIL
    for t in triples(graph, (nothing, _RDF_FIRST, items[1]))
        head = t.subject
        existing = _resolve_rdf_list(head, graph)
        if existing !== nothing && _items_equal(existing, items, graph)
            return head
        end
    end
    return nothing
end

"""
    _build_rdf_list(items, graph) -> Identifier

Build an RDF collection (rdf:first/rdf:rest chain) in the graph, returning the head node.
Reuses an existing list if one with identical content is found (content-addressed).
"""
function _build_rdf_list(items::Vector{<:Identifier}, graph::Union{RDFGraph, Nothing})
    isempty(items) && return _RDF_NIL
    # Try to reuse existing list
    if graph !== nothing
        existing = _find_existing_list(items, graph)
        existing !== nothing && return existing
    end
    nodes = [BNode() for _ in items]
    for (i, item) in enumerate(items)
        add!(graph, Triple(nodes[i], _RDF_FIRST, item))
        next_node = i < length(items) ? nodes[i+1] : _RDF_NIL
        add!(graph, Triple(nodes[i], _RDF_REST, next_node))
    end
    return nodes[1]
end

"""Resolve a term that might be an RDF list, trying both the formula graph and the main graph."""
function _resolve_list_from_graphs(node::Identifier, formula_graph::Union{RDFGraph,Nothing},
                                    main_graph::Union{RDFGraph,Nothing})
    if formula_graph !== nothing
        result = _resolve_rdf_list(node, formula_graph)
        result !== nothing && return result
    end
    if main_graph !== nothing
        return _resolve_rdf_list(node, main_graph)
    end
    return nothing
end

# ─── Math builtins ──────────────────────────────────────────────────

const _MATH = "http://www.w3.org/2000/10/swap/math#"

# --- comparisons ---

for (name, op) in [(:greaterThan, :>), (:lessThan, :<),
                    (:notGreaterThan, :<=), (:notLessThan, :>=)]
    fname = Symbol("_builtin_math_", name)
    @eval function $fname(subject::Identifier, object::Identifier,
                          bindings::Dict{Variable, Identifier},
                          graph::Union{RDFGraph, Nothing}=nothing)
        s = _resolve(subject, bindings)
        o = _resolve(object, bindings)
        a = _to_number(s)
        b = _to_number(o)
        (a !== nothing && b !== nothing && $op(a, b)) ? _success(bindings) : _failure()
    end
end

# equalTo / notEqualTo use isapprox for float tolerance
function _builtin_math_equalTo(subject::Identifier, object::Identifier,
                               bindings::Dict{Variable, Identifier},
                               graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    a = _to_number(s)
    b = _to_number(o)
    (a !== nothing && b !== nothing) || return _failure()
    eq = (a isa Integer && b isa Integer) ? (a == b) : isapprox(Float64(a), Float64(b))
    eq ? _success(bindings) : _failure()
end

function _builtin_math_notEqualTo(subject::Identifier, object::Identifier,
                                  bindings::Dict{Variable, Identifier},
                                  graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    a = _to_number(s)
    b = _to_number(o)
    (a !== nothing && b !== nothing) || return _failure()
    eq = (a isa Integer && b isa Integer) ? (a == b) : isapprox(Float64(a), Float64(b))
    !eq ? _success(bindings) : _failure()
end

# --- unary functions (subject → object) ---

for (name, fn) in [(:absoluteValue, :abs),
                    (:floor, :floor), (:ceiling, :ceil),
                    (:sqrt, :sqrt),
                    (:asin, :asin), (:acos, :acos), (:atan, :atan),
                    (:sinh, :sinh), (:cosh, :cosh), (:tanh, :tanh),
                    (:asinh, :asinh), (:acosh, :acosh), (:atanh, :atanh)]
    fname = Symbol("_builtin_math_", name)
    @eval function $fname(subject::Identifier, object::Identifier,
                          bindings::Dict{Variable, Identifier},
                          graph::Union{RDFGraph, Nothing}=nothing)
        s = _resolve(subject, bindings)
        a = _to_number(s)
        a === nothing && return _failure()
        result = $fn(a)
        _bind_or_check(object, _from_number(result), bindings)
    end
end

# negation: supports inverse (?x math:negation 3 → ?x = -3)
function _builtin_math_negation(subject::Identifier, object::Identifier,
                                bindings::Dict{Variable, Identifier},
                                graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    if s isa Variable
        b = _to_number(o)
        b === nothing && return _failure()
        return _success(bindings, s => _from_number(-b))
    end
    a = _to_number(s)
    a === nothing && return _failure()
    _bind_or_check(object, _from_number(-a), bindings)
end

# rounded: uses RoundNearestTiesUp (W3C spec: 0.5 → 1, 2.5 → 3)
function _builtin_math_rounded(subject::Identifier, object::Identifier,
                               bindings::Dict{Variable, Identifier},
                               graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    a = _to_number(s)
    a === nothing && return _failure()
    result = round(a, RoundNearestTiesUp)
    _bind_or_check(object, _from_number(result), bindings)
end

# sin/cos/tan: support inverse mode (?y math:sin val → ?y = asin(val))
for (name, fn, inv_fn) in [(:sin, :sin, :asin), (:cos, :cos, :acos), (:tan, :tan, :atan)]
    fname = Symbol("_builtin_math_", name)
    @eval function $fname(subject::Identifier, object::Identifier,
                          bindings::Dict{Variable, Identifier},
                          graph::Union{RDFGraph, Nothing}=nothing)
        s = _resolve(subject, bindings)
        if s isa Variable
            o = _resolve(object, bindings)
            b = _to_number(o)
            b === nothing && return _failure()
            inv_result = $inv_fn(b)
            return _success(bindings, s => _from_number(inv_result))
        end
        a = _to_number(s)
        a === nothing && return _failure()
        result = $fn(a)
        _bind_or_check(object, _from_number(result), bindings)
    end
end

# atan2: (y x) math:atan2 θ
function _builtin_math_atan2(subject::Identifier, object::Identifier,
                             bindings::Dict{Variable, Identifier},
                             graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    a = _to_number(s)
    b = _to_number(o)
    (a !== nothing && b !== nothing) || return _failure()
    _bind_or_check(object, _from_number(atan(a, b)), bindings)
end

# math:sum on list: (a b c) math:sum result
function _builtin_math_sum_list(subject::Identifier, object::Identifier,
                                bindings::Dict{Variable, Identifier},
                                graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    # Try as RDF list
    items = _resolve_rdf_list(s, graph)
    if items !== nothing
        items = _resolve_items(items, bindings)
        if isempty(items)
            return _bind_or_check(object, _from_number(0), bindings)
        end
        nums = [_to_number(x) for x in items]
        any(isnothing, nums) && return _failure()
        return _bind_or_check(object, _from_number(sum(nums)), bindings)
    end
    # Fallback: two-argument sum
    o = _resolve(object, bindings)
    a = _to_number(s)
    b = _to_number(o)
    (a !== nothing && b !== nothing) || return _failure()
    _bind_or_check(object, _from_number(a + b), bindings)
end

# math:product on list: (a b c) math:product result
function _builtin_math_product_list(subject::Identifier, object::Identifier,
                                    bindings::Dict{Variable, Identifier},
                                    graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    if items !== nothing
        items = _resolve_items(items, bindings)
        if isempty(items)
            return _bind_or_check(object, _from_number(1), bindings)
        end
        nums = [_to_number(x) for x in items]
        any(isnothing, nums) && return _failure()
        return _bind_or_check(object, _from_number(prod(nums)), bindings)
    end
    o = _resolve(object, bindings)
    a = _to_number(s)
    b = _to_number(o)
    (a !== nothing && b !== nothing) || return _failure()
    _bind_or_check(object, _from_number(a * b), bindings)
end

# math:difference: (a b) math:difference result  (a - b)
function _builtin_math_difference(subject::Identifier, object::Identifier,
                                  bindings::Dict{Variable, Identifier},
                                  graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    if items !== nothing && length(items) == 2
        items = _resolve_items(items, bindings)
        a = _to_number(items[1])
        b = _to_number(items[2])
        (a !== nothing && b !== nothing) || return _failure()
        return _bind_or_check(object, _from_number(a - b), bindings)
    end
    return _failure()
end

# math:quotient: (a b) math:quotient result  (a / b)
function _builtin_math_quotient(subject::Identifier, object::Identifier,
                                bindings::Dict{Variable, Identifier},
                                graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    if items !== nothing && length(items) == 2
        items = _resolve_items(items, bindings)
        a = _to_number(items[1])
        b = _to_number(items[2])
        (a !== nothing && b !== nothing) || return _failure()
        if b == 0
            # Allow float division by zero when either operand is non-integer
            (items[1] isa Literal && !_is_integer_input(items[1])) ||
            (items[2] isa Literal && !_is_integer_input(items[2])) || return _failure()
        end
        return _bind_or_check(object, _from_number(Float64(a) / Float64(b)), bindings)
    end
    return _failure()
end

# math:remainder: (a b) math:remainder result  — integer only, uses mod (sign of divisor)
function _builtin_math_remainder(subject::Identifier, object::Identifier,
                                 bindings::Dict{Variable, Identifier},
                                 graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    if items !== nothing && length(items) == 2
        items = _resolve_items(items, bindings)
        _is_integer_input(items[1]) && _is_integer_input(items[2]) || return _failure()
        a = _to_number(items[1])
        b = _to_number(items[2])
        (a !== nothing && b !== nothing && b != 0) || return _failure()
        return _bind_or_check(object, _from_number(mod(a, b)), bindings)
    end
    return _failure()
end

# math:exponentiation: (base exp) math:exponentiation result
function _builtin_math_exponentiation(subject::Identifier, object::Identifier,
                                      bindings::Dict{Variable, Identifier},
                                      graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    items = _resolve_rdf_list(s, graph)
    if items !== nothing && length(items) == 2
        resolved_a = _resolve(items[1], bindings)
        resolved_b = _resolve(items[2], bindings)
        a = _to_number(resolved_a)
        b = _to_number(resolved_b)
        if a !== nothing && b !== nothing
            # Forward: (base, exp) → result
            if a isa Integer && b isa Integer && b >= 0
                return _bind_or_check(object, _from_number(a^b), bindings)
            else
                return _bind_or_check(object, _from_number(Float64(a)^Float64(b)), bindings)
            end
        elseif a !== nothing && b === nothing && resolved_b isa Variable
            # Inverse: (base, ?exp) with known result → find exp
            r = _to_number(o)
            (r !== nothing && a > 0 && r > 0) || return _failure()
            exp_val = log(r) / log(a)
            result = copy(bindings)
            result[resolved_b] = _from_number(exp_val)
            return [result]
        elseif b !== nothing && a === nothing && resolved_a isa Variable
            # Inverse: (?base, exp) with known result → find base
            r = _to_number(o)
            (r !== nothing && b != 0) || return _failure()
            base_val = r^(1/b)
            result = copy(bindings)
            result[resolved_a] = _from_number(base_val)
            return [result]
        end
    end
    return _failure()
end

# math:logarithm: (value base) math:logarithm result
function _builtin_math_logarithm(subject::Identifier, object::Identifier,
                                 bindings::Dict{Variable, Identifier},
                                 graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    items = _resolve_rdf_list(s, graph)
    if items !== nothing && length(items) == 2
        resolved_a = _resolve(items[1], bindings)
        resolved_b = _resolve(items[2], bindings)
        a = _to_number(resolved_a)
        b = _to_number(resolved_b)
        if a !== nothing && b !== nothing
            (a > 0 && b > 0) || return _failure()
            return _bind_or_check(object, _from_number(log(b, a)), bindings)
        elseif a !== nothing && b === nothing && resolved_b isa Variable
            # Inverse: (value, ?base) with known result → find base
            r = _to_number(o)
            (r !== nothing && a > 0 && r != 0) || return _failure()
            base_val = a^(1/r)
            result = copy(bindings)
            result[resolved_b] = _from_number(base_val)
            return [result]
        end
    end
    # Single argument: natural log
    a = _to_number(s)
    (a !== nothing && a > 0) || return _failure()
    _bind_or_check(object, _from_number(log(a)), bindings)
end

# math:max/min on list
function _builtin_math_max(subject::Identifier, object::Identifier,
                           bindings::Dict{Variable, Identifier},
                           graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    items === nothing && return _failure()
    items = _resolve_items(items, bindings)
    nums = [_to_number(x) for x in items]
    any(isnothing, nums) && return _failure()
    _bind_or_check(object, _from_number(maximum(nums)), bindings)
end

function _builtin_math_min(subject::Identifier, object::Identifier,
                           bindings::Dict{Variable, Identifier},
                           graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    items === nothing && return _failure()
    items = _resolve_items(items, bindings)
    nums = [_to_number(x) for x in items]
    any(isnothing, nums) && return _failure()
    _bind_or_check(object, _from_number(minimum(nums)), bindings)
end

# math:degrees / math:radians
function _builtin_math_degrees(subject::Identifier, object::Identifier,
                               bindings::Dict{Variable, Identifier},
                               graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    a = _to_number(s)
    a === nothing && return _failure()
    _bind_or_check(object, _from_number(rad2deg(a)), bindings)
end

function _builtin_math_radians(subject::Identifier, object::Identifier,
                               bindings::Dict{Variable, Identifier},
                               graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    a = _to_number(s)
    a === nothing && return _failure()
    _bind_or_check(object, _from_number(deg2rad(a)), bindings)
end

# math:roundedTo: (value precision) math:roundedTo result
function _builtin_math_roundedTo(subject::Identifier, object::Identifier,
                                 bindings::Dict{Variable, Identifier},
                                 graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    if items !== nothing && length(items) == 2
        items = _resolve_items(items, bindings)
        val = _to_number(items[1])
        prec = _to_number(items[2])
        (val !== nothing && prec !== nothing) || return _failure()
        return _bind_or_check(object, _from_number(round(val; digits=Int(prec))), bindings)
    end
    return _failure()
end

# ─── String builtins ───────────────────────────────────────────────

const _STRING = "http://www.w3.org/2000/10/swap/string#"

function _builtin_string_length(subject::Identifier, object::Identifier,
                                bindings::Dict{Variable, Identifier},
                                graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Literal || return _failure()
    if s.datatype !== nothing
        dt = s.datatype.value
        xsd = "http://www.w3.org/2001/XMLSchema#"
        for t in ("integer", "int", "long", "short", "byte", "float", "double",
                  "decimal", "boolean", "nonNegativeInteger", "positiveInteger",
                  "nonPositiveInteger", "negativeInteger", "unsignedInt",
                  "unsignedLong", "unsignedShort", "unsignedByte")
            dt == xsd * t && return _failure()
        end
    end
    _bind_or_check(object, _from_number(length(s.lexical)), bindings)
end

function _builtin_string_contains(subject::Identifier, object::Identifier,
                                  bindings::Dict{Variable, Identifier},
                                  graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Literal && o isa Literal) || return _failure()
    contains(s.lexical, o.lexical) ? _success(bindings) : _failure()
end

function _builtin_string_startsWith(subject::Identifier, object::Identifier,
                                    bindings::Dict{Variable, Identifier},
                                    graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Literal && o isa Literal) || return _failure()
    startswith(s.lexical, o.lexical) ? _success(bindings) : _failure()
end

function _builtin_string_endsWith(subject::Identifier, object::Identifier,
                                  bindings::Dict{Variable, Identifier},
                                  graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Literal && o isa Literal) || return _failure()
    endswith(s.lexical, o.lexical) ? _success(bindings) : _failure()
end

function _builtin_string_upperCase(subject::Identifier, object::Identifier,
                                   bindings::Dict{Variable, Identifier},
                                   graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Literal || return _failure()
    _bind_or_check(object, Literal(uppercase(s.lexical)), bindings)
end

function _builtin_string_lowerCase(subject::Identifier, object::Identifier,
                                   bindings::Dict{Variable, Identifier},
                                   graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Literal || return _failure()
    _bind_or_check(object, Literal(lowercase(s.lexical)), bindings)
end

function _item_to_string(item::Identifier)::Union{String,Nothing}
    if item isa Literal
        # For numeric/boolean typed literals, evaluate to canonical string form
        if item.datatype !== nothing
            dt = item.datatype.value
            if dt in ("http://www.w3.org/2001/XMLSchema#integer",
                       "http://www.w3.org/2001/XMLSchema#decimal",
                       "http://www.w3.org/2001/XMLSchema#double",
                       "http://www.w3.org/2001/XMLSchema#float")
                v = tryparse(Float64, item.lexical)
                if v !== nothing
                    if isinteger(v) && isfinite(v)
                        return string(Int(v))
                    else
                        return string(v)
                    end
                end
            elseif dt == "http://www.w3.org/2001/XMLSchema#boolean"
                return item.lexical in ("true", "1") ? "true" : "false"
            end
        end
        return item.lexical
    elseif item isa URIRef
        return item.value
    else
        return nothing
    end
end

function _builtin_string_concatenation(subject::Identifier, object::Identifier,
                                       bindings::Dict{Variable, Identifier},
                                       graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    # Try as RDF list of strings
    items = _resolve_rdf_list(s, graph)
    if items !== nothing
        items = _resolve_items(items, bindings)
        strs = String[]
        for item in items
            str = _item_to_string(item)
            str === nothing && return _failure()
            push!(strs, str)
        end
        return _bind_or_check(object, Literal(join(strs, "")), bindings)
    end
    # Fallback: two-literal concatenation
    o = _resolve(object, bindings)
    (s isa Literal && o isa Literal) || return _failure()
    _bind_or_check(object, Literal(s.lexical * o.lexical), bindings)
end

function _builtin_string_matches(subject::Identifier, object::Identifier,
                                 bindings::Dict{Variable, Identifier},
                                 graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Literal && o isa Literal) || return _failure()
    occursin(Regex(o.lexical), s.lexical) ? _success(bindings) : _failure()
end

function _builtin_string_notMatches(subject::Identifier, object::Identifier,
                                    bindings::Dict{Variable, Identifier},
                                    graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Literal && o isa Literal) || return _failure()
    !occursin(Regex(o.lexical), s.lexical) ? _success(bindings) : _failure()
end

function _builtin_string_replace(subject::Identifier, object::Identifier,
                                 bindings::Dict{Variable, Identifier},
                                 graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    # N3 replace: (string pattern replacement) string:replace result
    items = _resolve_rdf_list(s, graph)
    if items !== nothing && length(items) == 3
        items = _resolve_items(items, bindings)
        all(x -> x isa Literal, items) || return _failure()
        pat = items[2].lexical
        # Wrap pattern in () if no capture groups, so $1 refers to whole match
        if !_has_capture_groups(pat)
            pat = "(" * pat * ")"
        end
        repl = replace(items[3].lexical, r"\$(\d+)" => s"\\\1")
        result = replace(items[1].lexical, Regex(pat) => SubstitutionString(repl))
        return _bind_or_check(object, Literal(result), bindings)
    end
    return _failure()
end

function _builtin_string_replaceAll(subject::Identifier, object::Identifier,
                                    bindings::Dict{Variable, Identifier},
                                    graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    if items !== nothing && length(items) == 3
        items = _resolve_items(items, bindings)
        items[1] isa Literal || return _failure()
        # items[2] and items[3] can be lists of patterns/replacements
        pats = _resolve_rdf_list(items[2], graph)
        repls = _resolve_rdf_list(items[3], graph)
        if pats !== nothing && repls !== nothing
            pats = _resolve_items(pats, bindings)
            repls = _resolve_items(repls, bindings)
            length(pats) == length(repls) || return _failure()
            all(x -> x isa Literal, pats) || return _failure()
            all(x -> x isa Literal, repls) || return _failure()
            result = items[1].lexical
            for (p, r) in zip(pats, repls)
                pat = p.lexical
                if !_has_capture_groups(pat)
                    pat = "(" * pat * ")"
                end
                repl = replace(r.lexical, r"\$(\d+)" => s"\\\1")
                result = replace(result, Regex(pat) => SubstitutionString(repl))
            end
            return _bind_or_check(object, Literal(result), bindings)
        end
        # Fallback: single pattern/replacement (all three are literals)
        if items[2] isa Literal && items[3] isa Literal
            pat = items[2].lexical
            if !_has_capture_groups(pat)
                pat = "(" * pat * ")"
            end
            repl = replace(items[3].lexical, r"\$(\d+)" => s"\\\1")
            result = replace(items[1].lexical, Regex(pat) => SubstitutionString(repl))
            return _bind_or_check(object, Literal(result), bindings)
        end
    end
    return _failure()
end

function _builtin_string_scrape(subject::Identifier, object::Identifier,
                                bindings::Dict{Variable, Identifier},
                                graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    if items !== nothing && length(items) == 2
        items = _resolve_items(items, bindings)
        all(x -> x isa Literal, items) || return _failure()
        m = match(Regex(items[2].lexical), items[1].lexical)
        m === nothing && return _failure()
        isempty(m.captures) && return _failure()
        return _bind_or_check(object, Literal(m.captures[1]), bindings)
    end
    return _failure()
end

function _builtin_string_scrapeAll(subject::Identifier, object::Identifier,
                                   bindings::Dict{Variable, Identifier},
                                   graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    if items !== nothing && length(items) == 2
        items = _resolve_items(items, bindings)
        all(x -> x isa Literal, items) || return _failure()
        matches = collect(eachmatch(Regex(items[2].lexical), items[1].lexical))
        result_items = Identifier[Literal(isempty(m.captures) ? m.match : m.captures[1]) for m in matches]
        graph === nothing && return _failure()
        head = _build_rdf_list(result_items, graph)
        return _bind_or_check(object, head, bindings, graph)
    end
    return _failure()
end

function _builtin_string_substring(subject::Identifier, object::Identifier,
                                   bindings::Dict{Variable, Identifier},
                                   graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    if items !== nothing && length(items) >= 2
        items = _resolve_items(items, bindings)
        items[1] isa Literal || return _failure()
        start = _to_number(items[2])
        start === nothing && return _failure()
        str = items[1].lexical
        # N3 substring uses 1-based indexing
        si = max(1, Int(start))
        if length(items) >= 3
            len = _to_number(items[3])
            len === nothing && return _failure()
            ei = min(length(str), si + Int(len) - 1)
            result = si > length(str) ? "" : str[si:ei]
        else
            result = si > length(str) ? "" : str[si:end]
        end
        return _bind_or_check(object, Literal(result), bindings)
    end
    return _failure()
end

function _builtin_string_join(subject::Identifier, object::Identifier,
                              bindings::Dict{Variable, Identifier},
                              graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    if items !== nothing && length(items) == 2
        items = _resolve_items(items, bindings)
        list_node = items[1]
        items[2] isa Literal || return _failure()
        sep = items[2].lexical
        inner = _resolve_rdf_list(list_node, graph)
        inner === nothing && return _failure()
        inner = _resolve_items(inner, bindings)
        strs = [x isa Literal ? x.lexical : string(x) for x in inner]
        return _bind_or_check(object, Literal(join(strs, sep)), bindings)
    end
    return _failure()
end

function _builtin_string_format(subject::Identifier, object::Identifier,
                                bindings::Dict{Variable, Identifier},
                                graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    items === nothing && return _failure()
    items = _resolve_items(items, bindings)
    isempty(items) && return _failure()
    items[1] isa Literal || return _failure()
    fmt = items[1].lexical
    args = [x isa Literal ? x.lexical : string(x) for x in items[2:end]]
    # Simple %s replacement
    result = fmt
    for arg in args
        result = replace(result, "%s" => arg; count=1)
    end
    _bind_or_check(object, Literal(result), bindings)
end

function _builtin_string_capitalize(subject::Identifier, object::Identifier,
                                    bindings::Dict{Variable, Identifier},
                                    graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Literal || return _failure()
    str = s.lexical
    result = isempty(str) ? str : uppercase(str[1:1]) * str[2:end]
    _bind_or_check(object, Literal(result), bindings)
end

function _builtin_string_greaterThan(subject::Identifier, object::Identifier,
                                     bindings::Dict{Variable, Identifier},
                                     graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Literal && o isa Literal) || return _failure()
    s.lexical > o.lexical ? _success(bindings) : _failure()
end

function _builtin_string_lessThan(subject::Identifier, object::Identifier,
                                  bindings::Dict{Variable, Identifier},
                                  graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Literal && o isa Literal) || return _failure()
    s.lexical < o.lexical ? _success(bindings) : _failure()
end

function _builtin_string_notGreaterThan(subject::Identifier, object::Identifier,
                                        bindings::Dict{Variable, Identifier},
                                        graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Literal && o isa Literal) || return _failure()
    s.lexical <= o.lexical ? _success(bindings) : _failure()
end

function _builtin_string_notLessThan(subject::Identifier, object::Identifier,
                                     bindings::Dict{Variable, Identifier},
                                     graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Literal && o isa Literal) || return _failure()
    s.lexical >= o.lexical ? _success(bindings) : _failure()
end

function _builtin_string_containsIgnoringCase(subject::Identifier, object::Identifier,
                                              bindings::Dict{Variable, Identifier},
                                              graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Literal && o isa Literal) || return _failure()
    contains(lowercase(s.lexical), lowercase(o.lexical)) ? _success(bindings) : _failure()
end

function _builtin_string_equalIgnoringCase(subject::Identifier, object::Identifier,
                                           bindings::Dict{Variable, Identifier},
                                           graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Literal && o isa Literal) || return _failure()
    lowercase(s.lexical) == lowercase(o.lexical) ? _success(bindings) : _failure()
end

function _builtin_string_notEqualIgnoringCase(subject::Identifier, object::Identifier,
                                              bindings::Dict{Variable, Identifier},
                                              graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Literal && o isa Literal) || return _failure()
    lowercase(s.lexical) != lowercase(o.lexical) ? _success(bindings) : _failure()
end

function _builtin_string_containsRoughly(subject::Identifier, object::Identifier,
                                         bindings::Dict{Variable, Identifier},
                                         graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Literal && o isa Literal) || return _failure()
    # Normalize: lowercase and collapse whitespace
    norm(x) = replace(lowercase(strip(x)), r"\s+" => " ")
    contains(norm(s.lexical), norm(o.lexical)) ? _success(bindings) : _failure()
end

function _builtin_string_notContainsRoughly(subject::Identifier, object::Identifier,
                                            bindings::Dict{Variable, Identifier},
                                            graph::Union{RDFGraph, Nothing}=nothing)
    result = _builtin_string_containsRoughly(subject, object, bindings, graph)
    isempty(result) ? _success(bindings) : _failure()
end

function _percent_encode(s::String, safe::Set{Char})
    buf = IOBuffer()
    for c in s
        if c in safe
            write(buf, c)
        else
            for b in codeunits(string(c))
                write(buf, '%', uppercase(string(b; base=16, pad=2)))
            end
        end
    end
    String(take!(buf))
end

function _builtin_string_encodeForURI(subject::Identifier, object::Identifier,
                                      bindings::Dict{Variable, Identifier},
                                      graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Literal || return _failure()
    # RFC 3986: unreserved + sub-delims + :@#? (but NOT /)
    safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~!\$&'()*+,;=:@#?")
    encoded = _percent_encode(s.lexical, safe)
    _bind_or_check(object, Literal(encoded), bindings)
end

function _builtin_string_encodeForFragID(subject::Identifier, object::Identifier,
                                         bindings::Dict{Variable, Identifier},
                                         graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Literal || return _failure()
    # Fragment ID: alphanumeric + -_./ are safe
    safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_./")
    encoded = _percent_encode(s.lexical, safe)
    _bind_or_check(object, Literal(encoded), bindings)
end

# ─── Log builtins ──────────────────────────────────────────────────

const _LOG = "http://www.w3.org/2000/10/swap/log#"

function _builtin_log_equalTo(subject::Identifier, object::Identifier,
                              bindings::Dict{Variable, Identifier},
                              graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    # If both are unbound variables, bind them together (succeed)
    if s isa Variable && o isa Variable
        result = copy(bindings)
        result[s] = o
        return [result]
    end
    # If one is unbound, bind it to the other
    if s isa Variable
        result = copy(bindings)
        result[s] = o
        return [result]
    end
    if o isa Variable
        result = copy(bindings)
        result[o] = s
        return [result]
    end
    # Handle RDF list equality
    if (s isa BNode || s isa URIRef) && (o isa BNode || o isa URIRef) && graph !== nothing
        s_list = _resolve_rdf_list(s, graph)
        o_list = _resolve_rdf_list(o, graph)
        if s_list !== nothing && o_list !== nothing
            return s_list == o_list ? _success(bindings) : _failure()
        end
    end
    # Numeric comparison
    if s isa Literal && o isa Literal
        a = _to_number(s)
        b = _to_number(o)
        if a !== nothing && b !== nothing
            return a == b ? _success(bindings) : _failure()
        end
    end
    # Formula comparison (graph equality)
    if s isa Formula && o isa Formula
        s_triples = Set(collect(s.graph))
        o_triples = Set(collect(o.graph))
        return s_triples == o_triples ? _success(bindings) : _failure()
    end
    s == o ? _success(bindings) : _failure()
end

function _builtin_log_notEqualTo(subject::Identifier, object::Identifier,
                                 bindings::Dict{Variable, Identifier},
                                 graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    # If either is an unbound variable, can't determine inequality
    (s isa Variable || o isa Variable) && return _failure()
    # Handle RDF list equality
    if (s isa BNode || s isa URIRef) && (o isa BNode || o isa URIRef) && graph !== nothing
        s_list = _resolve_rdf_list(s, graph)
        o_list = _resolve_rdf_list(o, graph)
        if s_list !== nothing && o_list !== nothing
            return s_list != o_list ? _success(bindings) : _failure()
        end
    end
    # Numeric comparison
    if s isa Literal && o isa Literal
        a = _to_number(s)
        b = _to_number(o)
        if a !== nothing && b !== nothing
            return a != b ? _success(bindings) : _failure()
        end
    end
    # Formula comparison
    if s isa Formula && o isa Formula
        s_triples = Set(collect(s.graph))
        o_triples = Set(collect(o.graph))
        return s_triples != o_triples ? _success(bindings) : _failure()
    end
    s != o ? _success(bindings) : _failure()
end

function _builtin_log_includes(subject::Identifier, object::Identifier,
                               bindings::Dict{Variable, Identifier},
                               graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Formula && o isa Formula) || return _failure()
    # Match all triples in object's graph against subject's graph, collecting bindings
    o_triples = collect(o.graph)
    isempty(o_triples) && return _success(bindings)
    match_results = _match_formula_triples(o_triples, collect(s.graph), 1, Dict{Variable, Identifier}())
    isempty(match_results) && return _failure()
    # Merge the first successful match into bindings
    results = Dict{Variable, Identifier}[]
    for mr in match_results
        merged = copy(bindings)
        for (k, v) in mr
            if haskey(merged, k)
                merged[k] != v && @goto next_match
            else
                merged[k] = v
            end
        end
        push!(results, merged)
        @label next_match
    end
    isempty(results) ? _failure() : results
end

function _match_formula_triples(pat::Vector{Triple}, facts::Vector{Triple},
                                 idx::Int, bindings::Dict{Variable, Identifier})
    idx > length(pat) && return [bindings]
    results = Dict{Variable, Identifier}[]
    for ft in facts
        new_b = unify_triple(pat[idx], ft, bindings)
        if new_b !== nothing
            sub = _match_formula_triples(pat, facts, idx + 1, new_b)
            append!(results, sub)
        end
    end
    results
end

function _builtin_log_notIncludes(subject::Identifier, object::Identifier,
                                  bindings::Dict{Variable, Identifier},
                                  graph::Union{RDFGraph, Nothing}=nothing)
    result = _builtin_log_includes(subject, object, bindings, graph)
    isempty(result) ? _success(bindings) : _failure()
end

function _builtin_log_rawType(subject::Identifier, object::Identifier,
                              bindings::Dict{Variable, Identifier},
                              graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Variable && return _failure()
    log_ns = Namespace(_LOG)
    rdf_type = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    rdf_list = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#List")
    log_set = log_ns("Set")
    type_uri = if s isa Literal
        log_ns("Literal")
    elseif s isa Formula
        log_ns("Formula")
    elseif s isa BNode
        # Check type annotations in graph first
        found_type = nothing
        if graph !== nothing
            for t in triples(graph, (s, rdf_type, nothing))
                tobj = t.object
                if tobj == log_ns("LabeledBlankNode") || tobj == log_ns("UnlabeledBlankNode") ||
                   tobj == log_ns("SkolemIRI") || tobj == log_ns("ForSome") || tobj == log_ns("ForAll") ||
                   tobj == log_set
                    found_type = tobj
                    break
                end
            end
        end
        if found_type == log_set
            log_set
        elseif found_type !== nothing
            found_type
        else
            # Determine if this is an auto-generated BNode
            is_uuid = startswith(s.id, "N") && length(s.id) == 33 && all(c -> c in "0123456789abcdef", s.id[2:end])
            is_parser_gen = !is_uuid && match(r"^b\d+$", s.id) !== nothing
            if is_uuid || is_parser_gen
                # Auto-generated BNode — check if it's a list/set head
                if graph !== nothing && _resolve_rdf_list(s, graph) !== nothing
                    rdf_list
                elseif is_uuid
                    log_ns("UnlabeledBlankNode")
                else
                    log_ns("UnlabeledBlankNode")
                end
            else
                log_ns("LabeledBlankNode")  # user-defined _:name BNode
            end
        end
    elseif s isa URIRef
        # Check if it has ForSome/ForAll type annotations in graph
        if graph !== nothing
            for t in triples(graph, (s, rdf_type, nothing))
                tobj = t.object
                if tobj == log_ns("ForSome")
                    return _bind_or_check(object, log_ns("ForSome"), bindings)
                elseif tobj == log_ns("ForAll")
                    return _bind_or_check(object, log_ns("ForAll"), bindings)
                end
            end
        end
        # Check if it's a SkolemIRI
        if contains(s.value, ".well-known/genid")
            log_ns("SkolemIRI")
        else
            log_ns("Other")
        end
    else
        return _failure()
    end
    _bind_or_check(object, type_uri, bindings)
end

function _builtin_log_uri(subject::Identifier, object::Identifier,
                          bindings::Dict{Variable, Identifier},
                          graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    if s isa URIRef
        return _bind_or_check(object, Literal(s.value), bindings)
    elseif o isa Literal
        return _bind_or_check(subject, URIRef(o.lexical), bindings)
    end
    _failure()
end

function _builtin_log_langlit(subject::Identifier, object::Identifier,
                              bindings::Dict{Variable, Identifier},
                              graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    items = _resolve_rdf_list(s, graph)
    if items !== nothing && length(items) == 2
        items = _resolve_items(items, bindings)
        if items[1] isa Literal && items[2] isa Literal
            result = Literal(items[1].lexical; lang=items[2].lexical)
            return _bind_or_check(object, result, bindings)
        elseif o isa Literal && o.language !== nothing && o.language != ""
            # Reverse: bind variables from known lang-tagged literal
            b = copy(bindings)
            if items[1] isa Variable
                b[items[1]] = Literal(o.lexical)
            elseif items[1] isa Literal && items[1].lexical != o.lexical
                return _failure()
            end
            if items[2] isa Variable
                b[items[2]] = Literal(o.language)
            elseif items[2] isa Literal && items[2].lexical != o.language
                return _failure()
            end
            return [b]
        end
    end
    _failure()
end

function _builtin_log_dtlit(subject::Identifier, object::Identifier,
                            bindings::Dict{Variable, Identifier},
                            graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    items = _resolve_rdf_list(s, graph)
    if items !== nothing && length(items) == 2
        items = _resolve_items(items, bindings)
        if items[1] isa Literal && items[2] isa URIRef
            # Forward: (value, type) → typed literal
            result = Literal(items[1].lexical; datatype=items[2])
            return _bind_or_check(object, result, bindings)
        elseif items[1] isa Literal && items[2] isa Variable && o isa Literal && o.datatype !== nothing
            # Reverse: (value, ?type) with known typed literal → bind type
            result = copy(bindings)
            result[items[2]] = o.datatype
            return [result]
        elseif items[1] isa Variable && items[2] isa URIRef && o isa Literal
            # Reverse: (?value, type) with known literal → bind value
            result = copy(bindings)
            result[items[1]] = Literal(o.lexical)
            return [result]
        end
    end
    # Reverse: object is known typed literal, bind subject list
    if o isa Literal && o.datatype !== nothing && s isa Variable
        if graph !== nothing
            val_lit = Literal(o.lexical)
            head = _build_rdf_list(Identifier[val_lit, o.datatype], graph)
            return _success(bindings, s => head)
        end
    end
    _failure()
end

function _builtin_log_conjunction(subject::Identifier, object::Identifier,
                                  bindings::Dict{Variable, Identifier},
                                  graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    items === nothing && return _failure()
    items = _resolve_items(items, bindings)
    # Merge all formula graphs into a single formula
    merged = Formula()
    for item in items
        if item isa Formula
            for t in item.graph
                add!(merged, t)
            end
        end
    end
    _bind_or_check(object, merged, bindings)
end

function _builtin_log_outputString(subject::Identifier, object::Identifier,
                                   bindings::Dict{Variable, Identifier},
                                   graph::Union{RDFGraph, Nothing}=nothing)
    # Subject can be anything (even BNode), just used as a label
    o = _resolve(object, bindings)
    o isa Literal || (o isa Variable && return _failure())
    o isa Variable && return _failure()
    o isa Literal || return _failure()
    _success(bindings)
end

function _builtin_log_bound(subject::Identifier, object::Identifier,
                            bindings::Dict{Variable, Identifier},
                            graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    is_bound = !(s isa Variable)
    # If object is a boolean literal, check against bound status
    if o isa Literal
        xsd_bool = URIRef("http://www.w3.org/2001/XMLSchema#boolean")
        if o == Literal("true"; datatype=xsd_bool) || o == Literal(true)
            return is_bound ? _success(bindings) : _failure()
        elseif o == Literal("false"; datatype=xsd_bool) || o == Literal(false)
            return is_bound ? _failure() : _success(bindings)
        end
    end
    # If object is a variable, bind it to the boolean result
    if o isa Variable
        xsd_bool = URIRef("http://www.w3.org/2001/XMLSchema#boolean")
        result = Literal(is_bound ? "true" : "false"; datatype=xsd_bool)
        return _success(bindings, o => result)
    end
    is_bound ? _success(bindings) : _failure()
end

function _builtin_log_localName(subject::Identifier, object::Identifier,
                                bindings::Dict{Variable, Identifier},
                                graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa URIRef || return _failure()
    uri = s.value
    # Find local name after last # or /
    idx = max(something(findlast('#', uri), 0), something(findlast('/', uri), 0))
    local_name = idx > 0 ? uri[idx+1:end] : uri
    _bind_or_check(object, Literal(local_name), bindings)
end

function _builtin_log_namespace(subject::Identifier, object::Identifier,
                                bindings::Dict{Variable, Identifier},
                                graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa URIRef || return _failure()
    uri = s.value
    idx = max(something(findlast('#', uri), 0), something(findlast('/', uri), 0))
    ns = idx > 0 ? uri[1:idx] : uri
    _bind_or_check(object, Literal(ns), bindings)
end

function _builtin_log_prefix(subject::Identifier, object::Identifier,
                              bindings::Dict{Variable, Identifier},
                              graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    graph === nothing && return _failure()
    if s isa URIRef && o isa Literal
        # Check: does URI s have prefix o?
        for (prefix, ns_uri) in namespaces(graph)
            if ns_uri == s.value && prefix == o.lexical
                return _success(bindings)
            end
        end
        return _failure()
    elseif s isa Variable && o isa Literal
        # Find URI for prefix name
        for (prefix, ns_uri) in namespaces(graph)
            if prefix == o.lexical
                return _success(bindings, s => URIRef(ns_uri))
            end
        end
        return _failure()
    elseif s isa URIRef && o isa Variable
        # Find prefix for URI
        for (prefix, ns_uri) in namespaces(graph)
            if ns_uri == s.value
                return _success(bindings, o => Literal(prefix))
            end
        end
        return _failure()
    end
    _failure()
end

function _builtin_log_hasPrefix(subject::Identifier, object::Identifier,
                                bindings::Dict{Variable, Identifier},
                                graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    s isa URIRef || return _failure()
    # Check if a prefix is registered for this URI in the namespace manager
    if graph !== nothing
        has_prefix = false
        for (_, ns_uri) in namespaces(graph)
            if s.value == ns_uri || startswith(s.value, ns_uri)
                has_prefix = true
                break
            end
        end
        xsd_bool = URIRef("http://www.w3.org/2001/XMLSchema#boolean")
        result = Literal(has_prefix ? "true" : "false"; datatype=xsd_bool)
        return _bind_or_check(object, result, bindings)
    end
    # Fallback: check if object is a string prefix
    (o isa Literal) || return _failure()
    startswith(s.value, o.lexical) ? _success(bindings) : _failure()
end

function _builtin_log_skolem(subject::Identifier, object::Identifier,
                             bindings::Dict{Variable, Identifier},
                             graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    if o isa Variable
        # Generate skolem URI based on subject content
        items = _resolve_rdf_list(s, graph)
        if items !== nothing
            items = _resolve_items(items, bindings)
            # Hash based on list content for deterministic output
            content = join([x isa Literal ? x.lexical : string(x) for x in items], ":")
            h = bytes2hex(SHA.sha256(Vector{UInt8}(content)))
            sk = URIRef("urn:/.well-known/genid/" * h[1:32])
        else
            sk = URIRef("urn:/.well-known/genid/" * replace(string(uuid4()), "-" => ""))
        end
        return _success(bindings, o => sk)
    end
    _failure()
end

function _builtin_log_uuid(subject::Identifier, object::Identifier,
                           bindings::Dict{Variable, Identifier},
                           graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    uuid_str = string(uuid4())
    _bind_or_check(object, Literal(uuid_str), bindings)
end

# log:racine — extract base URI without fragment
function _builtin_log_racine(subject::Identifier, object::Identifier,
                              bindings::Dict{Variable, Identifier},
                              graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa URIRef || return _failure()
    uri = s.value
    idx = findfirst('#', uri)
    base = idx !== nothing ? uri[1:prevind(uri, idx)] : uri
    _bind_or_check(object, URIRef(base), bindings)
end

# log:n3String — serialize term to N3 string
function _builtin_log_n3String(subject::Identifier, object::Identifier,
                                bindings::Dict{Variable, Identifier},
                                graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Variable && return _failure()
    n3str = if s isa Formula
        buf = IOBuffer()
        for (i, t) in enumerate(s.graph)
            i > 1 && write(buf, " ")
            write(buf, _term_to_n3(t.subject), " ", _term_to_n3(t.predicate), " ", _term_to_n3(t.object), " .")
        end
        String(take!(buf))
    else
        _term_to_n3(s)
    end
    _bind_or_check(object, Literal(n3str), bindings)
end

# log:localN3String — like n3String but with short prefixes
function _builtin_log_localN3String(subject::Identifier, object::Identifier,
                                     bindings::Dict{Variable, Identifier},
                                     graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Variable && return _failure()
    # Collect prefixes from graph namespace manager if available
    prefix_map = Dict{String, String}()
    if graph !== nothing
        for (prefix, ns_uri) in namespaces(graph)
            prefix_map[ns_uri] = prefix
        end
    end
    n3str = if s isa Formula
        buf = IOBuffer()
        ts = collect(s.graph)
        for (i, t) in enumerate(ts)
            i > 1 && write(buf, " . ")
            write(buf, _term_to_local_n3(t.subject, prefix_map), " ",
                       _term_to_local_n3(t.predicate, prefix_map), " ",
                       _term_to_local_n3(t.object, prefix_map))
        end
        String(take!(buf))
    else
        _term_to_local_n3(s, prefix_map)
    end
    _bind_or_check(object, Literal(n3str), bindings)
end

function _term_to_n3(t::URIRef)
    "<" * t.value * ">"
end
function _term_to_n3(t::BNode)
    "_:" * t.id
end
function _term_to_n3(t::Literal)
    if t.language !== nothing && t.language != ""
        "\"" * t.lexical * "\"@" * t.language
    elseif t.datatype !== nothing && t.datatype != URIRef("http://www.w3.org/2001/XMLSchema#string")
        "\"" * t.lexical * "\"^^<" * t.datatype.value * ">"
    else
        "\"" * t.lexical * "\""
    end
end
function _term_to_n3(t::Variable)
    "?" * t.name
end
function _term_to_n3(t::Identifier)
    string(t)
end

function _term_to_local_n3(t::URIRef, prefix_map::Dict{String, String})
    uri = t.value
    # Check if rdf:type → a
    if uri == "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
        return "a"
    end
    for (ns_uri, prefix) in prefix_map
        if startswith(uri, ns_uri)
            localname = uri[length(ns_uri)+1:end]
            if isempty(prefix)
                return ":" * localname
            else
                return prefix * ":" * localname
            end
        end
    end
    "<" * uri * ">"
end
function _term_to_local_n3(t::Identifier, prefix_map::Dict{String, String})
    _term_to_n3(t)
end

# log:repeat — generate integers 0..N-1
function _builtin_log_repeat(subject::Identifier, object::Identifier,
                              bindings::Dict{Variable, Identifier},
                              graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    n = _to_number(s)
    n === nothing && return _failure()
    n = Int(n)
    n <= 0 && return _failure()
    results = Dict{Variable, Identifier}[]
    for i in 0:(n-1)
        push!(results, _bind_or_check(object, _from_number(i), bindings)...)
    end
    results
end

# log:satisfiable — check if formula is satisfiable
function _builtin_log_satisfiable(subject::Identifier, object::Identifier,
                                   bindings::Dict{Variable, Identifier},
                                   graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Formula || return _failure()
    log_implies = URIRef("http://www.w3.org/2000/10/swap/log#implies")
    false_lit = Literal(false)
    has_contradiction = false
    for t in s.graph
        if t.predicate == log_implies && t.object == false_lit
            has_contradiction = true
            break
        end
    end
    result = has_contradiction ? Literal(false) : Literal(true)
    _bind_or_check(object, result, bindings)
end

# log:isomorphic — check structural isomorphism
function _builtin_log_isomorphic(subject::Identifier, object::Identifier,
                                  bindings::Dict{Variable, Identifier},
                                  graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Variable || o isa Variable) && return _success(bindings)
    # Same term
    if s == o
        return _success(bindings)
    end
    # Both BNodes or both Variables — isomorphic (single nodes)
    if (s isa BNode && o isa BNode) || (s isa Variable && o isa Variable)
        return _success(bindings)
    end
    # Both Formulas — structural isomorphism
    if s isa Formula && o isa Formula
        if _formulas_isomorphic(s, o)
            return _success(bindings)
        else
            return _failure()
        end
    end
    # Same type of Literal
    if s isa Literal && o isa Literal
        a = _to_number(s)
        b = _to_number(o)
        if a !== nothing && b !== nothing
            return a == b ? _success(bindings) : _failure()
        end
        return s == o ? _success(bindings) : _failure()
    end
    _failure()
end

# Check if two formulas are isomorphic (structurally equal modulo BNode/Variable renaming)
function _formulas_isomorphic(a::Formula, b::Formula)
    a_triples = collect(a.graph)
    b_triples = collect(b.graph)
    length(a_triples) != length(b_triples) && return false
    # Try to find a mapping from BNodes/Variables in a to BNodes/Variables in b
    _try_iso_match(a_triples, b_triples, 1, Dict{Identifier, Identifier}(), Dict{Identifier, Identifier}())
end

function _try_iso_match(a_ts::Vector{Triple}, b_ts::Vector{Triple}, idx::Int,
                        fwd_map::Dict{Identifier, Identifier},
                        rev_map::Dict{Identifier, Identifier})
    idx > length(a_ts) && return true
    at = a_ts[idx]
    for bt in b_ts
        new_fwd = copy(fwd_map)
        new_rev = copy(rev_map)
        if _iso_match_terms(at.subject, bt.subject, new_fwd, new_rev) &&
           _iso_match_terms(at.predicate, bt.predicate, new_fwd, new_rev) &&
           _iso_match_terms(at.object, bt.object, new_fwd, new_rev)
            if _try_iso_match(a_ts, b_ts, idx + 1, new_fwd, new_rev)
                return true
            end
        end
    end
    false
end

function _iso_match_terms(a::Identifier, b::Identifier,
                          fwd::Dict{Identifier, Identifier},
                          rev::Dict{Identifier, Identifier})
    a_is_blank = (a isa BNode || a isa Variable)
    b_is_blank = (b isa BNode || b isa Variable)
    # If both are blank/variable, create bijective mapping
    if a_is_blank && b_is_blank
        if haskey(fwd, a)
            return fwd[a] == b
        end
        if haskey(rev, b)
            return rev[b] == a
        end
        fwd[a] = b
        rev[b] = a
        return true
    end
    # If only one side is blank, it can match any term (existential semantics)
    if a_is_blank
        if haskey(fwd, a)
            return fwd[a] == b
        end
        fwd[a] = b
        return true
    end
    if b_is_blank
        if haskey(rev, b)
            return rev[b] == a
        end
        rev[b] = a
        return true
    end
    if a isa Formula && b isa Formula
        return _formulas_isomorphic(a, b)
    end
    a == b
end

# log:becomes — retract subject formula, assert object formula
function _builtin_log_becomes(subject::Identifier, object::Identifier,
                               bindings::Dict{Variable, Identifier},
                               graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Formula && o isa Formula && graph !== nothing) || return _failure()
    # Apply current bindings to formula triples
    for t in collect(s.graph)
        grounded = apply_bindings(t, bindings)
        is_ground(grounded) && remove!(graph, (grounded.subject, grounded.predicate, grounded.object))
    end
    for t in o.graph
        grounded = apply_bindings(t, bindings)
        is_ground(grounded) && add!(graph, grounded)
    end
    _success(bindings)
end

# log:trace — debug output to stderr, always succeeds
function _builtin_log_trace(subject::Identifier, object::Identifier,
                            bindings::Dict{Variable, Identifier},
                            graph::Union{RDFGraph, Nothing}=nothing)
    _success(bindings)
end

# log:semantics — load N3 file at URI, parse, return as Formula
function _builtin_log_semantics(subject::Identifier, object::Identifier,
                                 bindings::Dict{Variable, Identifier},
                                 graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa URIRef || return _failure()
    # Resolve file path from URI
    path = _uri_to_filepath(s.value)
    path === nothing && return _failure()
    isfile(path) || return _failure()
    content = try
        read(path, String)
    catch
        return _failure()
    end
    parsed = try
        parse_n3(content)
    catch
        return _failure()
    end
    formula = Formula()
    for t in parsed
        add!(formula, t)
    end
    _bind_or_check(object, formula, bindings)
end

# log:semanticsOrError — like semantics but return error string on failure
function _builtin_log_semanticsOrError(subject::Identifier, object::Identifier,
                                        bindings::Dict{Variable, Identifier},
                                        graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa URIRef || return _failure()
    path = _uri_to_filepath(s.value)
    path === nothing && return _bind_or_check(object, Literal("Cannot resolve URI: $(s.value)"), bindings)
    if !isfile(path)
        return _bind_or_check(object, Literal("File not found: $path"), bindings)
    end
    content = try
        read(path, String)
    catch e
        return _bind_or_check(object, Literal("Error reading: $e"), bindings)
    end
    parsed = try
        parse_n3(content)
    catch e
        return _bind_or_check(object, Literal("Parse error: $e"), bindings)
    end
    formula = Formula()
    for t in parsed
        add!(formula, t)
    end
    _bind_or_check(object, formula, bindings)
end

# log:conclusion — run reasoner on a formula and return all conclusions
function _builtin_log_conclusion(subject::Identifier, object::Identifier,
                                  bindings::Dict{Variable, Identifier},
                                  graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Formula || return _failure()
    # Build a graph from the formula's triples
    input_graph = RDFGraph()
    for t in s.graph
        add!(input_graph, t)
    end
    # Run the reasoner on this sub-graph
    result_graph = try
        reason(input_graph; max_iterations=100, pass_only_new=false)
    catch
        return _failure()
    end
    # Collect all triples into a result Formula
    result_formula = Formula()
    for t in result_graph
        add!(result_formula, t)
    end
    _bind_or_check(object, result_formula, bindings)
end

# log:inferences — check if triples are inferred from a formula
function _builtin_log_inferences(subject::Identifier, object::Identifier,
                                  bindings::Dict{Variable, Identifier},
                                  graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Formula || return _failure()
    o = _resolve(object, bindings)
    # Run the reasoner to get conclusions
    input_graph = RDFGraph()
    for t in s.graph
        add!(input_graph, t)
    end
    result_graph = try
        reason(input_graph; max_iterations=100, pass_only_new=false)
    catch
        return _failure()
    end
    if o isa Formula
        # Check if all triples in the object formula are in the result
        for t in o.graph
            found = false
            for rt in result_graph
                if rt.subject == t.subject && rt.predicate == t.predicate && rt.object == t.object
                    found = true; break
                end
            end
            found || return _failure()
        end
        return _success(bindings)
    elseif o isa Variable
        # Bind to all conclusions
        result_formula = Formula()
        for t in result_graph
            add!(result_formula, t)
        end
        return _bind_or_check(object, result_formula, bindings)
    end
    _failure()
end

# log:content — read content of URI as string (supports file: and http/https)
function _builtin_log_content(subject::Identifier, object::Identifier,
                               bindings::Dict{Variable, Identifier},
                               graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa URIRef || return _failure()
    uri = s.value
    content = if startswith(uri, "http://") || startswith(uri, "https://")
        # HTTP fetch
        try
            tmpfile = download(uri)
            read(tmpfile, String)
        catch
            return _failure()
        end
    else
        path = _uri_to_filepath(uri)
        path === nothing && return _failure()
        isfile(path) || return _failure()
        try
            read(path, String)
        catch
            return _failure()
        end
    end
    _bind_or_check(object, Literal(content), bindings)
end

# Helper: resolve a URI to a local file path
function _uri_to_filepath(uri::String)
    if startswith(uri, "file://")
        return uri[8:end]
    elseif !contains(uri, "://")
        # Relative path — check if it exists as-is
        isfile(uri) && return uri
        # Try resolving relative to registered base directories
        for dir in _N3_BASE_DIRS
            candidate = joinpath(dir, uri)
            isfile(candidate) && return candidate
        end
        return uri  # Return as-is, caller will check isfile()
    end
    return nothing
end

# log:parsedAsN3 — parse string as N3, produce Formula
function _builtin_log_parsedAsN3(subject::Identifier, object::Identifier,
                                  bindings::Dict{Variable, Identifier},
                                  graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    if s isa Literal
        # Forward: parse string → formula
        parsed_graph = try
            parse_n3(s.lexical)
        catch
            return _failure()
        end
        formula = Formula()
        for t in parsed_graph
            add!(formula, t)
        end
        return _bind_or_check(object, formula, bindings)
    elseif o isa Formula
        # Reverse: formula → string
        buf = IOBuffer()
        for (i, t) in enumerate(o.graph)
            i > 1 && write(buf, " ")
            write(buf, _term_to_n3(t.subject), " ", _term_to_n3(t.predicate), " ", _term_to_n3(t.object), " .")
        end
        return _bind_or_check(subject, Literal(String(take!(buf))), bindings)
    end
    _failure()
end

# log:includesNotBind — like includes but doesn't bind variables in the object formula
function _builtin_log_includesNotBind(subject::Identifier, object::Identifier,
                                      bindings::Dict{Variable, Identifier},
                                      graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Formula && o isa Formula) || return _failure()
    o_triples = collect(o.graph)
    isempty(o_triples) && return _success(bindings)
    match_results = _match_formula_triples(o_triples, collect(s.graph), 1, Dict{Variable, Identifier}())
    isempty(match_results) && return _failure()
    # Succeed but do NOT merge match_results into bindings — that's the "NotBind" part
    _success(bindings)
end

# log:collectAllIn — findall: collect all bindings of pattern from formula into a list
function _builtin_log_collectAllIn(subject::Identifier, object::Identifier,
                                    bindings::Dict{Variable, Identifier},
                                    graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    graph === nothing && return _failure()
    items = _resolve_rdf_list(s, graph)
    items === nothing && return _failure()
    length(items) == 3 || return _failure()

    pattern_term = items[1]  # Don't resolve yet — keep the list structure
    formula = _resolve(items[2], bindings)
    result_var = _resolve(items[3], bindings)
    formula isa Formula || return _failure()

    # Get triples from formula as patterns
    formula_triples = collect(formula.graph)
    isempty(formula_triples) && return _bind_or_check(result_var, _RDF_NIL, bindings, graph)

    # Match formula triples against working graph with builtins
    all_bindings = _match_with_builtins_standalone(formula_triples, graph, bindings)

    # For each binding, evaluate the pattern term
    collected = Identifier[]
    seen = Set{UInt64}()
    for b in all_bindings
        val = _apply_bindings_deep(pattern_term, b, graph)
        val isa Variable && continue
        h = hash(val)
        h in seen && continue
        push!(seen, h)
        push!(collected, val)
    end

    # Build result list (order depends on graph iteration order)
    head = _build_rdf_list(collected, graph)
    return _bind_or_check(result_var, head, bindings, graph)
end

# Apply bindings deeply: if term is a BNode list head, resolve the list,
# apply bindings to each element, and build a new list
function _apply_bindings_deep(term::Identifier, bindings::Dict{Variable, Identifier},
                               graph::Union{RDFGraph, Nothing})
    if term isa Variable
        return _resolve(term, bindings)
    elseif term isa BNode && graph !== nothing
        items = _resolve_rdf_list(term, graph)
        if items !== nothing
            new_items = Identifier[_apply_bindings_deep(it, bindings, graph) for it in items]
            return _build_rdf_list(new_items, graph)
        end
    end
    return term
end

# log:forAllIn — check that for ALL bindings from formula 1, formula 2 holds
function _builtin_log_forAllIn(subject::Identifier, object::Identifier,
                                bindings::Dict{Variable, Identifier},
                                graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    graph === nothing && return _failure()
    items = _resolve_rdf_list(s, graph)
    items === nothing && return _failure()
    length(items) == 2 || return _failure()

    generator = _resolve(items[1], bindings)
    test_formula = _resolve(items[2], bindings)
    (generator isa Formula && test_formula isa Formula) || return _failure()

    gen_triples = collect(generator.graph)
    test_triples = collect(test_formula.graph)
    isempty(gen_triples) && return _success(bindings)

    gen_bindings = _match_with_builtins_standalone(gen_triples, graph, bindings)
    isempty(gen_bindings) && return _success(bindings)  # vacuously true

    for gb in gen_bindings
        test_results = _match_with_builtins_standalone(test_triples, graph, gb)
        isempty(test_results) && return _failure()
    end
    _success(bindings)
end

# log:ifThenElseIn — if condition succeeds, run then, else run else
function _builtin_log_ifThenElseIn(subject::Identifier, object::Identifier,
                                    bindings::Dict{Variable, Identifier},
                                    graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    graph === nothing && return _failure()
    items = _resolve_rdf_list(s, graph)
    items === nothing && return _failure()
    length(items) == 3 || return _failure()

    condition = _resolve(items[1], bindings)
    then_formula = _resolve(items[2], bindings)
    else_formula = _resolve(items[3], bindings)
    (condition isa Formula && then_formula isa Formula && else_formula isa Formula) || return _failure()

    cond_triples = collect(condition.graph)
    cond_bindings = _match_with_builtins_standalone(cond_triples, graph, bindings)

    if !isempty(cond_bindings)
        # Condition succeeded — execute "then" branch with each condition binding
        results = Binding[]
        then_triples = collect(then_formula.graph)
        for cb in cond_bindings
            then_results = _match_with_builtins_standalone(then_triples, graph, cb)
            append!(results, then_results)
        end
        return isempty(results) ? _failure() : results
    else
        # Condition failed — execute "else" branch
        else_triples = collect(else_formula.graph)
        return _match_with_builtins_standalone(else_triples, graph, bindings)
    end
end

# log:call — execute subject formula, then object formula with combined bindings
function _builtin_log_call(subject::Identifier, object::Identifier,
                           bindings::Dict{Variable, Identifier},
                           graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Formula && o isa Formula && graph !== nothing) || return _failure()

    subj_triples = collect(s.graph)
    obj_triples = collect(o.graph)

    subj_bindings = _match_with_builtins_standalone(subj_triples, graph, bindings)
    isempty(subj_bindings) && return _failure()

    results = Binding[]
    for sb in subj_bindings
        obj_results = _match_with_builtins_standalone(obj_triples, graph, sb)
        append!(results, obj_results)
    end
    isempty(results) ? _failure() : results
end

# log:callWithOptional — execute subject (required), optionally execute object
function _builtin_log_callWithOptional(subject::Identifier, object::Identifier,
                                       bindings::Dict{Variable, Identifier},
                                       graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Formula && o isa Formula && graph !== nothing) || return _failure()

    subj_triples = collect(s.graph)
    obj_triples = collect(o.graph)

    subj_bindings = _match_with_builtins_standalone(subj_triples, graph, bindings)
    isempty(subj_bindings) && return _failure()

    results = Binding[]
    for sb in subj_bindings
        obj_results = _match_with_builtins_standalone(obj_triples, graph, sb)
        if isempty(obj_results)
            push!(results, sb)  # Optional: keep subject bindings even if object fails
        else
            append!(results, obj_results)
        end
    end
    isempty(results) ? _failure() : results
end

# log:callWithCut — execute formula but stop after first match
function _builtin_log_callWithCut(subject::Identifier, object::Identifier,
                                   bindings::Dict{Variable, Identifier},
                                   graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    graph === nothing && return _failure()
    s isa Formula || return _failure()

    formula_triples = collect(s.graph)
    results = _match_with_builtins_standalone(formula_triples, graph, bindings)
    isempty(results) && return _failure()
    # Cut: return only the first match
    return [results[1]]
end

# log:callWithCleanup — execute subject formula; always succeed (cleanup always runs)
function _builtin_log_callWithCleanup(subject::Identifier, object::Identifier,
                                      bindings::Dict{Variable, Identifier},
                                      graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    graph === nothing && return _failure()
    s isa Formula || return _failure()

    formula_triples = collect(s.graph)
    results = _match_with_builtins_standalone(formula_triples, graph, bindings)
    # Always succeed — if formula matched, use those bindings; otherwise use current
    if !isempty(results)
        return results
    else
        return _success(bindings)
    end
end

# Helper: standalone matching of formula triples against a graph with builtins
# This is used by the meta-builtins (call, collectAllIn, etc.)
# Uses late binding to access functions defined later in the loading order
function _match_with_builtins_standalone(patterns::Vector{Triple}, graph::RDFGraph,
                                          bindings::Dict{Variable, Identifier})
    regular = Triple[]
    builtin_pats = Triple[]
    list_structure = Triple[]

    rdf_first = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
    rdf_rest = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")

    for p in patterns
        if p.predicate isa URIRef && is_builtin(p.predicate)
            push!(builtin_pats, p)
        elseif p.subject isa BNode && (p.predicate == rdf_first || p.predicate == rdf_rest)
            push!(list_structure, p)
        else
            push!(regular, p)
        end
    end

    # Add list-structure triples to graph for resolution
    if !isempty(list_structure)
        for t in list_structure
            add!(graph, apply_bindings(t, bindings))
        end
    end

    eval_graph = !isempty(list_structure) ? graph : nothing
    base_bindings = match_conjunction(regular, graph, bindings; list_graph=eval_graph)

    isempty(builtin_pats) && return base_bindings

    # Sort and evaluate builtins using reasoner's infrastructure
    sorted = _sort_builtins(builtin_pats, isempty(base_bindings) ? bindings : base_bindings[1];
                            list_structure=list_structure)

    results = Dict{Variable, Identifier}[]
    for b in base_bindings
        _apply_builtins!(results, sorted, 1, b, graph)
    end
    return results
end

# ─── Crypto builtins ───────────────────────────────────────────────

const _CRYPTO = "http://www.w3.org/2000/10/swap/crypto#"

function _builtin_crypto_sha1(subject::Identifier, object::Identifier,
                             bindings::Dict{Variable, Identifier},
                             graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Literal || return _failure()
    h = bytes2hex(SHA.sha1(Vector{UInt8}(s.lexical)))
    _bind_or_check(object, Literal(h), bindings)
end

function _builtin_crypto_md5(subject::Identifier, object::Identifier,
                             bindings::Dict{Variable, Identifier},
                             graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Literal || return _failure()
    h = bytes2hex(MD5.md5(Vector{UInt8}(s.lexical)))
    _bind_or_check(object, Literal(h), bindings)
end

function _builtin_crypto_sha256(subject::Identifier, object::Identifier,
                                bindings::Dict{Variable, Identifier},
                                graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Literal || return _failure()
    h = bytes2hex(SHA.sha256(Vector{UInt8}(s.lexical)))
    _bind_or_check(object, Literal(h), bindings)
end

function _builtin_crypto_sha512(subject::Identifier, object::Identifier,
                                bindings::Dict{Variable, Identifier},
                                graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Literal || return _failure()
    h = bytes2hex(SHA.sha512(Vector{UInt8}(s.lexical)))
    _bind_or_check(object, Literal(h), bindings)
end

# ─── List builtins ─────────────────────────────────────────────────

const _LIST = "http://www.w3.org/2000/10/swap/list#"

function _builtin_list_in(subject::Identifier, object::Identifier,
                          bindings::Dict{Variable, Identifier},
                          graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    items = _resolve_rdf_list(o, graph)
    items === nothing && return _failure()
    items = _resolve_items(items, bindings)
    if s isa Variable
        # Generate one binding per list member
        results = Binding[]
        for item in items
            push!(results, merge(bindings, Dict(s => item)))
        end
        return results
    else
        return any(item -> _terms_equal(s, item, graph), items) ? _success(bindings) : _failure()
    end
end

function _builtin_list_member(subject::Identifier, object::Identifier,
                              bindings::Dict{Variable, Identifier},
                              graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    items === nothing && return _failure()
    items = _resolve_items(items, bindings)
    o = _resolve(object, bindings)
    if o isa Variable
        results = Binding[]
        for item in items
            push!(results, merge(bindings, Dict(o => item)))
        end
        return results
    else
        return any(item -> _terms_equal(o, item, graph), items) ? _success(bindings) : _failure()
    end
end

function _builtin_list_first(subject::Identifier, object::Identifier,
                             bindings::Dict{Variable, Identifier},
                             graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    (items !== nothing && !isempty(items)) || return _failure()
    items = _resolve_items(items, bindings)
    _bind_or_check(object, items[1], bindings, graph)
end

function _builtin_list_last(subject::Identifier, object::Identifier,
                            bindings::Dict{Variable, Identifier},
                            graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    (items !== nothing && !isempty(items)) || return _failure()
    items = _resolve_items(items, bindings)
    _bind_or_check(object, items[end], bindings, graph)
end

function _builtin_list_rest(subject::Identifier, object::Identifier,
                            bindings::Dict{Variable, Identifier},
                            graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    (items !== nothing && !isempty(items)) || return _failure()
    items = _resolve_items(items, bindings)
    rest_items = items[2:end]
    graph === nothing && return _failure()
    head = _build_rdf_list(rest_items, graph)
    _bind_or_check(object, head, bindings, graph)
end

function _builtin_list_length(subject::Identifier, object::Identifier,
                              bindings::Dict{Variable, Identifier},
                              graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    items === nothing && return _failure()
    _bind_or_check(object, _from_number(length(items)), bindings)
end

function _builtin_list_append(subject::Identifier, object::Identifier,
                              bindings::Dict{Variable, Identifier},
                              graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    outer = _resolve_rdf_list(s, graph)
    outer === nothing && return _failure()
    outer = _resolve_items(outer, bindings)
    # Subject is a list of lists; concatenate them
    all_items = Identifier[]
    for item in outer
        inner = _resolve_rdf_list(item, graph)
        if inner !== nothing
            append!(all_items, inner)
        else
            push!(all_items, item)
        end
    end
    graph === nothing && return _failure()
    head = _build_rdf_list(all_items, graph)
    _bind_or_check(object, head, bindings, graph)
end

function _builtin_list_iterate(subject::Identifier, object::Identifier,
                               bindings::Dict{Variable, Identifier},
                               graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    items === nothing && return _failure()
    items = _resolve_items(items, bindings)
    o = _resolve(object, bindings)
    # Object should be a pair (index, value)
    obj_list = _resolve_rdf_list(o, graph)

    results = Binding[]
    for (i, item) in enumerate(items)
        idx_lit = _from_number(i - 1)  # 0-based index
        if obj_list !== nothing && length(obj_list) == 2
            # Check/bind index and value
            idx_term = obj_list[1]
            val_term = obj_list[2]
            b = copy(bindings)
            ok = true
            ri = _resolve(idx_term, bindings)
            rv = _resolve(val_term, bindings)
            if ri isa Variable
                b[ri] = idx_lit
            elseif ri != idx_lit
                ok = false
            end
            if ok
                if rv isa Variable
                    b[rv] = item
                elseif rv != item
                    ok = false
                end
            end
            ok && push!(results, b)
        elseif o isa Variable
            # Build pair list in graph
            if graph !== nothing
                pair_head = _build_rdf_list(Identifier[idx_lit, item], graph)
                push!(results, merge(bindings, Dict(o => pair_head)))
            end
        end
    end
    return results
end

function _builtin_list_sort(subject::Identifier, object::Identifier,
                            bindings::Dict{Variable, Identifier},
                            graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    items === nothing && return _failure()
    items = _resolve_items(items, bindings)
    sorted = sort(items; by=x -> x isa Literal ? x.lexical : string(x))
    graph === nothing && return _failure()
    head = _build_rdf_list(sorted, graph)
    _bind_or_check(object, head, bindings, graph)
end

function _builtin_list_unique(subject::Identifier, object::Identifier,
                              bindings::Dict{Variable, Identifier},
                              graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    items === nothing && return _failure()
    items = _resolve_items(items, bindings)
    unique_items = unique(items)
    graph === nothing && return _failure()
    head = _build_rdf_list(unique_items, graph)
    _bind_or_check(object, head, bindings, graph)
end

function _builtin_list_remove(subject::Identifier, object::Identifier,
                              bindings::Dict{Variable, Identifier},
                              graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    outer = _resolve_rdf_list(s, graph)
    (outer !== nothing && length(outer) == 2) || return _failure()
    outer = _resolve_items(outer, bindings)
    list1 = _resolve_rdf_list(outer[1], graph)
    list1 === nothing && return _failure()
    list1 = _resolve_items(list1, bindings)
    # outer[2] can be a single element or a list of elements to remove
    list2 = _resolve_rdf_list(outer[2], graph)
    if list2 !== nothing
        list2 = _resolve_items(list2, bindings)
    else
        list2 = [outer[2]]  # single element
    end
    # Remove ALL occurrences of each element in list2
    result = copy(list1)
    for item in list2
        result = filter(!=(item), result)
    end
    graph === nothing && return _failure()
    head = _build_rdf_list(result, graph)
    _bind_or_check(object, head, bindings, graph)
end

function _builtin_list_removeAt(subject::Identifier, object::Identifier,
                                bindings::Dict{Variable, Identifier},
                                graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    outer = _resolve_rdf_list(s, graph)
    (outer !== nothing && length(outer) == 2) || return _failure()
    outer = _resolve_items(outer, bindings)
    list1 = _resolve_rdf_list(outer[1], graph)
    list1 === nothing && return _failure()
    list1 = _resolve_items(list1, bindings)
    idx_term = outer[2]
    o = _resolve(object, bindings)
    if idx_term isa Variable || (idx_term isa Literal && _to_number(idx_term) === nothing)
        # Index unknown — try reverse lookup: find index by result
        if !(o isa Variable)
            o_list = _resolve_rdf_list(o, graph)
            if o_list !== nothing
                o_list = _resolve_items(o_list, bindings)
                results = Binding[]
                for i in 1:length(list1)
                    candidate = [list1[j] for j in 1:length(list1) if j != i]
                    if candidate == o_list
                        b = copy(bindings)
                        if idx_term isa Variable
                            b[idx_term] = _from_number(i - 1)  # 0-based
                        end
                        push!(results, b)
                    end
                end
                return results
            end
        end
        return _failure()
    end
    idx = _to_number(idx_term)
    idx === nothing && return _failure()
    i = Int(idx) + 1  # 0-based to 1-based
    (i >= 1 && i <= length(list1)) || return _failure()
    result = [list1[j] for j in 1:length(list1) if j != i]
    graph === nothing && return _failure()
    head = _build_rdf_list(result, graph)
    _bind_or_check(object, head, bindings, graph)
end

function _builtin_list_memberAt(subject::Identifier, object::Identifier,
                                bindings::Dict{Variable, Identifier},
                                graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    outer = _resolve_rdf_list(s, graph)
    (outer !== nothing && length(outer) == 2) || return _failure()
    outer = _resolve_items(outer, bindings)
    list1 = _resolve_rdf_list(outer[1], graph)
    list1 === nothing && return _failure()
    list1 = _resolve_items(list1, bindings)
    idx_term = outer[2]
    o = _resolve(object, bindings)
    if idx_term isa Variable || (idx_term isa Literal && _to_number(idx_term) === nothing)
        # Index unknown, try to find by value
        if !(o isa Variable)
            results = Binding[]
            for (i, item) in enumerate(list1)
                if item == o
                    b = copy(bindings)
                    if idx_term isa Variable
                        b[idx_term] = _from_number(i - 1)  # 0-based
                    end
                    push!(results, b)
                end
            end
            return results
        end
        return _failure()
    end
    idx = _to_number(idx_term)
    idx === nothing && return _failure()
    i = Int(idx) + 1  # 0-based to 1-based
    if idx < 0
        i = length(list1) + Int(idx) + 1
    end
    (i >= 1 && i <= length(list1)) || return _failure()
    _bind_or_check(object, list1[i], bindings, graph)
end

function _builtin_list_removeDuplicates(subject::Identifier, object::Identifier,
                                        bindings::Dict{Variable, Identifier},
                                        graph::Union{RDFGraph, Nothing}=nothing)
    _builtin_list_unique(subject, object, bindings, graph)
end

function _builtin_list_firstRest(subject::Identifier, object::Identifier,
                                 bindings::Dict{Variable, Identifier},
                                 graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    (items !== nothing && !isempty(items)) || return _failure()
    items = _resolve_items(items, bindings)
    graph === nothing && return _failure()
    rest_head = _build_rdf_list(items[2:end], graph)
    pair_head = _build_rdf_list(Identifier[items[1], rest_head], graph)
    _bind_or_check(object, pair_head, bindings, graph)
end

function _builtin_list_setEqualTo(subject::Identifier, object::Identifier,
                                  bindings::Dict{Variable, Identifier},
                                  graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    s_items = _resolve_rdf_list(s, graph)
    o_items = _resolve_rdf_list(o, graph)
    (s_items !== nothing && o_items !== nothing) || return _failure()
    s_items = _resolve_items(s_items, bindings)
    o_items = _resolve_items(o_items, bindings)
    Set(s_items) == Set(o_items) ? _success(bindings) : _failure()
end

function _builtin_list_setNotEqualTo(subject::Identifier, object::Identifier,
                                     bindings::Dict{Variable, Identifier},
                                     graph::Union{RDFGraph, Nothing}=nothing)
    result = _builtin_list_setEqualTo(subject, object, bindings, graph)
    isempty(result) ? _success(bindings) : _failure()
end

function _builtin_list_multisetEqualTo(subject::Identifier, object::Identifier,
                                       bindings::Dict{Variable, Identifier},
                                       graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    s_items = _resolve_rdf_list(s, graph)
    o_items = _resolve_rdf_list(o, graph)
    (s_items !== nothing && o_items !== nothing) || return _failure()
    s_items = _resolve_items(s_items, bindings)
    o_items = _resolve_items(o_items, bindings)
    sort(s_items; by=string) == sort(o_items; by=string) ? _success(bindings) : _failure()
end

function _builtin_list_multisetNotEqualTo(subject::Identifier, object::Identifier,
                                          bindings::Dict{Variable, Identifier},
                                          graph::Union{RDFGraph, Nothing}=nothing)
    result = _builtin_list_multisetEqualTo(subject, object, bindings, graph)
    isempty(result) ? _success(bindings) : _failure()
end

function _builtin_list_map(subject::Identifier, object::Identifier,
                           bindings::Dict{Variable, Identifier},
                           graph::Union{RDFGraph, Nothing}=nothing)
    # (list builtin) list:map result_list
    # Subject is a pair (list, builtin_uri)
    s = _resolve(subject, bindings)
    outer = _resolve_rdf_list(s, graph)
    (outer !== nothing && length(outer) == 2) || return _failure()
    outer = _resolve_items(outer, bindings)
    list_node = outer[1]
    builtin_uri = outer[2]
    builtin_uri isa URIRef || return _failure()
    is_builtin(builtin_uri) || return _failure()
    items = _resolve_rdf_list(list_node, graph)
    items === nothing && return _failure()
    items = _resolve_items(items, bindings)
    graph === nothing && return _failure()
    result_items = Identifier[]
    for item in items
        # Each item is the subject; evaluate builtin with a fresh variable as object
        tmp_var = Variable("_map_result")
        tmp_bindings = copy(bindings)
        results = evaluate_builtin(builtin_uri, item, tmp_var, tmp_bindings, graph)
        isempty(results) && return _failure()
        val = get(results[1], tmp_var, nothing)
        val === nothing && return _failure()
        push!(result_items, val)
    end
    head = _build_rdf_list(result_items, graph)
    _bind_or_check(object, head, bindings, graph)
end

# ─── Graph builtins ────────────────────────────────────────────────

const _GRAPH = "http://www.w3.org/2000/10/swap/graph#"

function _builtin_graph_length(subject::Identifier, object::Identifier,
                               bindings::Dict{Variable, Identifier},
                               graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Formula || return _failure()
    # Count only non-list-structure triples (exclude rdf:first/rdf:rest)
    rdf_first = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
    rdf_rest = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
    n = count(t -> t.predicate != rdf_first && t.predicate != rdf_rest, s.graph)
    _bind_or_check(object, _from_number(n), bindings)
end

function _builtin_graph_member(subject::Identifier, object::Identifier,
                               bindings::Dict{Variable, Identifier},
                               graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    s isa Formula || return _failure()
    results = Binding[]
    for t in s.graph
        member_formula = Formula()
        add!(member_formula, t)
        if o isa Variable
            push!(results, merge(bindings, Dict(o => member_formula)))
        elseif o isa Formula
            # Check if the formula matches
            o_triples = Set(collect(o.graph))
            m_triples = Set(collect(member_formula.graph))
            o_triples == m_triples && push!(results, copy(bindings))
        end
    end
    return isempty(results) ? _failure() : results
end

function _builtin_graph_union(subject::Identifier, object::Identifier,
                              bindings::Dict{Variable, Identifier},
                              graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    items === nothing && return _failure()
    items = _resolve_items(items, bindings)
    merged = Formula()
    for item in items
        item isa Formula || continue
        for t in item.graph
            add!(merged, t)
        end
    end
    _bind_or_check(object, merged, bindings)
end

function _builtin_graph_intersection(subject::Identifier, object::Identifier,
                                     bindings::Dict{Variable, Identifier},
                                     graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    items === nothing && return _failure()
    items = _resolve_items(items, bindings)
    formulas = [x for x in items if x isa Formula]
    isempty(formulas) && return _failure()
    common = Set(collect(formulas[1].graph))
    for f in formulas[2:end]
        common = intersect(common, Set(collect(f.graph)))
    end
    result = Formula()
    for t in common
        add!(result, t)
    end
    _bind_or_check(object, result, bindings)
end

function _builtin_graph_difference(subject::Identifier, object::Identifier,
                                   bindings::Dict{Variable, Identifier},
                                   graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    (items !== nothing && length(items) == 2) || return _failure()
    items = _resolve_items(items, bindings)
    (items[1] isa Formula && items[2] isa Formula) || return _failure()
    result = Formula()
    set2 = Set(collect(items[2].graph))
    for t in items[1].graph
        t in set2 || add!(result, t)
    end
    _bind_or_check(object, result, bindings)
end

function _builtin_graph_list(subject::Identifier, object::Identifier,
                             bindings::Dict{Variable, Identifier},
                             graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    if s isa Formula
        # Forward: Formula → list of single-triple Formulas
        graph === nothing && return _failure()
        ts = collect(s.graph)
        formula_items = Identifier[]
        for t in ts
            f = Formula()
            add!(f, t)
            push!(formula_items, f)
        end
        head = _build_rdf_list(formula_items, graph)
        return _bind_or_check(object, head, bindings, graph)
    end
    # Backward: list of Formulas → merged Formula
    o_list = _resolve_rdf_list(o, graph)
    if o_list !== nothing
        o_list = _resolve_items(o_list, bindings)
        merged = Formula()
        for item in o_list
            if item isa Formula
                for t in item.graph
                    add!(merged, t)
                end
            end
        end
        return _bind_or_check(subject, merged, bindings)
    end
    _failure()
end

# ─── Time builtins ─────────────────────────────────────────────────

const _TIME = "http://www.w3.org/2000/10/swap/time#"

function _builtin_time_localTime(subject::Identifier, object::Identifier,
                                 bindings::Dict{Variable, Identifier},
                                 graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    now_utc = Dates.now(Dates.UTC)
    now_str = Dates.format(now_utc, "yyyy-mm-ddTHH:MM:SS.sssZ")
    _bind_or_check(object, Literal(now_str), bindings)
end

function _builtin_time_year(subject::Identifier, object::Identifier,
                            bindings::Dict{Variable, Identifier},
                            graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Literal || return _failure()
    m = match(r"^(\d{4})", s.lexical)
    m === nothing && return _failure()
    _bind_or_check(object, _from_number(parse(Int, m.captures[1])), bindings)
end

function _builtin_time_month(subject::Identifier, object::Identifier,
                             bindings::Dict{Variable, Identifier},
                             graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Literal || return _failure()
    m = match(r"^\d{4}-(\d{2})", s.lexical)
    m === nothing && return _failure()
    _bind_or_check(object, _from_number(parse(Int, m.captures[1])), bindings)
end

function _builtin_time_day(subject::Identifier, object::Identifier,
                           bindings::Dict{Variable, Identifier},
                           graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Literal || return _failure()
    m = match(r"^\d{4}-\d{2}-(\d{2})", s.lexical)
    m === nothing && return _failure()
    _bind_or_check(object, _from_number(parse(Int, m.captures[1])), bindings)
end

function _builtin_time_hour(subject::Identifier, object::Identifier,
                            bindings::Dict{Variable, Identifier},
                            graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Literal || return _failure()
    m = match(r"T(\d{2})", s.lexical)
    m === nothing && return _failure()
    _bind_or_check(object, _from_number(parse(Int, m.captures[1])), bindings)
end

function _builtin_time_minute(subject::Identifier, object::Identifier,
                              bindings::Dict{Variable, Identifier},
                              graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Literal || return _failure()
    m = match(r"T\d{2}:(\d{2})", s.lexical)
    m === nothing && return _failure()
    _bind_or_check(object, _from_number(parse(Int, m.captures[1])), bindings)
end

function _builtin_time_second(subject::Identifier, object::Identifier,
                              bindings::Dict{Variable, Identifier},
                              graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Literal || return _failure()
    m = match(r"T\d{2}:\d{2}:(\d{2})", s.lexical)
    m === nothing && return _failure()
    _bind_or_check(object, _from_number(parse(Int, m.captures[1])), bindings)
end

function _builtin_time_timeZone(subject::Identifier, object::Identifier,
                                bindings::Dict{Variable, Identifier},
                                graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Literal || return _failure()
    m = match(r"([+-]\d{2}:\d{2})$", s.lexical)
    m === nothing && return _failure()
    _bind_or_check(object, Literal(m.captures[1]), bindings)
end

function _parse_datetime_to_unix(datestr::String)
    # Parse ISO 8601 datetime strings to Unix epoch seconds
    # Supports: "2002-06-22T22:09:32-05:00", "2002-06-22T12:34Z", "2002-06-22", "2002-06", "2002"
    tz_offset = 0
    clean = datestr
    # Extract timezone
    m_tz = match(r"([+-])(\d{2}):(\d{2})$", clean)
    if m_tz !== nothing
        sign = m_tz.captures[1] == "+" ? 1 : -1
        tz_offset = sign * (parse(Int, m_tz.captures[2]) * 3600 + parse(Int, m_tz.captures[3]) * 60)
        clean = clean[1:m_tz.offset-1]
    elseif endswith(clean, "Z")
        clean = clean[1:end-1]
    end

    parts = split(clean, "T")
    date_part = parts[1]
    time_part = length(parts) > 1 ? parts[2] : ""

    date_fields = split(date_part, "-")
    yr = parse(Int, date_fields[1])
    mo = length(date_fields) >= 2 ? parse(Int, date_fields[2]) : 1
    dy = length(date_fields) >= 3 ? parse(Int, date_fields[3]) : 1

    hr = 0; mn = 0; sc = 0
    if !isempty(time_part)
        time_fields = split(time_part, ":")
        hr = parse(Int, time_fields[1])
        mn = length(time_fields) >= 2 ? parse(Int, time_fields[2]) : 0
        if length(time_fields) >= 3
            sc_val = tryparse(Float64, time_fields[3])
            sc = sc_val !== nothing ? floor(Int, sc_val) : 0
        end
    end

    dt = Dates.DateTime(yr, mo, dy, hr, mn, sc)
    epoch = Dates.DateTime(1970, 1, 1)
    secs = div(Dates.value(dt - epoch), 1000) - tz_offset
    return secs
end

function _builtin_time_inSeconds(subject::Identifier, object::Identifier,
                                 bindings::Dict{Variable, Identifier},
                                 graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    if s isa Literal
        secs = _parse_datetime_to_unix(s.lexical)
        return _bind_or_check(object, _from_number(secs), bindings)
    elseif o isa Literal
        # Reverse: given seconds, produce datetime string
        n = _to_number(o)
        n === nothing && return _failure()
        epoch = Dates.DateTime(1970, 1, 1)
        dt = epoch + Dates.Second(Int(n))
        dt_str = Dates.format(dt, "yyyy-mm-ddTHH:MM:SSZ")
        # Remove trailing 'Z' to add as 'Z'
        return _bind_or_check(subject, Literal(dt_str), bindings)
    end
    return _failure()
end

function _builtin_time_dayOfWeek(subject::Identifier, object::Identifier,
                                 bindings::Dict{Variable, Identifier},
                                 graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Literal || return _failure()
    # Parse date components directly (local time, not UTC-adjusted)
    m = match(r"^(\d{4})(?:-(\d{2}))?(?:-(\d{2}))?", s.lexical)
    m === nothing && return _failure()
    yr = parse(Int, m.captures[1])
    mo = m.captures[2] !== nothing ? parse(Int, m.captures[2]) : 1
    dy = m.captures[3] !== nothing ? parse(Int, m.captures[3]) : 1
    dt = Dates.Date(yr, mo, dy)
    # Julia: Monday=1..Sunday=7; CWM: Sunday=0..Saturday=6
    dow = Dates.dayofweek(dt)
    cwm_dow = dow == 7 ? 0 : dow
    _bind_or_check(object, _from_number(cwm_dow), bindings)
end

# ─── Registration ──────────────────────────────────────────────────

function _register_n3_builtins!()
    math = Namespace(_MATH)
    for name in [:greaterThan, :lessThan, :notGreaterThan, :notLessThan,
                 :equalTo, :notEqualTo,
                 :negation, :absoluteValue, :floor, :ceiling, :rounded,
                 :sqrt, :sin, :cos, :tan,
                 :asin, :acos, :atan, :sinh, :cosh, :tanh,
                 :asinh, :acosh, :atanh]
        fn = getfield(@__MODULE__, Symbol("_builtin_math_", name))
        register_builtin!(math(String(name)), fn)
    end
    register_builtin!(math("atan2"), _builtin_math_atan2)
    register_builtin!(math("sum"), _builtin_math_sum_list)
    register_builtin!(math("product"), _builtin_math_product_list)
    register_builtin!(math("difference"), _builtin_math_difference)
    register_builtin!(math("quotient"), _builtin_math_quotient)
    register_builtin!(math("remainder"), _builtin_math_remainder)
    register_builtin!(math("exponentiation"), _builtin_math_exponentiation)
    register_builtin!(math("logarithm"), _builtin_math_logarithm)
    register_builtin!(math("max"), _builtin_math_max)
    register_builtin!(math("min"), _builtin_math_min)
    register_builtin!(math("degrees"), _builtin_math_degrees)
    register_builtin!(math("radians"), _builtin_math_radians)
    register_builtin!(math("roundedTo"), _builtin_math_roundedTo)

    str = Namespace(_STRING)
    register_builtin!(str("length"),                _builtin_string_length)
    register_builtin!(str("contains"),              _builtin_string_contains)
    register_builtin!(str("startsWith"),            _builtin_string_startsWith)
    register_builtin!(str("endsWith"),              _builtin_string_endsWith)
    register_builtin!(str("upperCase"),             _builtin_string_upperCase)
    register_builtin!(str("lowerCase"),             _builtin_string_lowerCase)
    register_builtin!(str("concatenation"),         _builtin_string_concatenation)
    register_builtin!(str("matches"),               _builtin_string_matches)
    register_builtin!(str("notMatches"),            _builtin_string_notMatches)
    register_builtin!(str("replace"),               _builtin_string_replace)
    register_builtin!(str("replaceAll"),            _builtin_string_replaceAll)
    register_builtin!(str("scrape"),                _builtin_string_scrape)
    register_builtin!(str("scrapeAll"),             _builtin_string_scrapeAll)
    register_builtin!(str("substring"),             _builtin_string_substring)
    register_builtin!(str("join"),                  _builtin_string_join)
    register_builtin!(str("format"),                _builtin_string_format)
    register_builtin!(str("capitalize"),            _builtin_string_capitalize)
    register_builtin!(str("greaterThan"),           _builtin_string_greaterThan)
    register_builtin!(str("lessThan"),              _builtin_string_lessThan)
    register_builtin!(str("notGreaterThan"),        _builtin_string_notGreaterThan)
    register_builtin!(str("notLessThan"),           _builtin_string_notLessThan)
    register_builtin!(str("containsIgnoringCase"),  _builtin_string_containsIgnoringCase)
    register_builtin!(str("equalIgnoringCase"),     _builtin_string_equalIgnoringCase)
    register_builtin!(str("notEqualIgnoringCase"),  _builtin_string_notEqualIgnoringCase)
    register_builtin!(str("containsRoughly"),       _builtin_string_containsRoughly)
    register_builtin!(str("notContainsRoughly"),    _builtin_string_notContainsRoughly)
    register_builtin!(str("encodeForURI"),           _builtin_string_encodeForURI)
    register_builtin!(str("encodeForFragID"),        _builtin_string_encodeForFragID)

    log = Namespace(_LOG)
    register_builtin!(log("equalTo"),       _builtin_log_equalTo)
    register_builtin!(log("notEqualTo"),    _builtin_log_notEqualTo)
    register_builtin!(log("includes"),      _builtin_log_includes)
    register_builtin!(log("notIncludes"),   _builtin_log_notIncludes)
    register_builtin!(log("rawType"),       _builtin_log_rawType)
    register_builtin!(log("uri"),           _builtin_log_uri)
    register_builtin!(log("langlit"),       _builtin_log_langlit)
    register_builtin!(log("dtlit"),         _builtin_log_dtlit)
    register_builtin!(log("conjunction"),   _builtin_log_conjunction)
    register_builtin!(log("outputString"),  _builtin_log_outputString)
    register_builtin!(log("bound"),         _builtin_log_bound)
    register_builtin!(log("localName"),     _builtin_log_localName)
    register_builtin!(log("namespace"),     _builtin_log_namespace)
    register_builtin!(log("prefix"),        _builtin_log_prefix)
    register_builtin!(log("hasPrefix"),     _builtin_log_hasPrefix)
    register_builtin!(log("skolem"),        _builtin_log_skolem)
    register_builtin!(log("uuid"),          _builtin_log_uuid)
    register_builtin!(log("racine"),        _builtin_log_racine)
    register_builtin!(log("n3String"),      _builtin_log_n3String)
    register_builtin!(log("localN3String"), _builtin_log_localN3String)
    register_builtin!(log("repeat"),        _builtin_log_repeat)
    register_builtin!(log("satisfiable"),   _builtin_log_satisfiable)
    register_builtin!(log("isomorphic"),    _builtin_log_isomorphic)
    register_builtin!(log("becomes"),          _builtin_log_becomes)
    register_builtin!(log("trace"),            _builtin_log_trace)
    register_builtin!(log("semantics"),        _builtin_log_semantics)
    register_builtin!(log("semanticsOrError"), _builtin_log_semanticsOrError)
    register_builtin!(log("content"),          _builtin_log_content)
    register_builtin!(log("parsedAsN3"),       _builtin_log_parsedAsN3)
    register_builtin!(log("includesNotBind"),   _builtin_log_includesNotBind)
    register_builtin!(log("collectAllIn"),      _builtin_log_collectAllIn)
    register_builtin!(log("forAllIn"),          _builtin_log_forAllIn)
    register_builtin!(log("ifThenElseIn"),      _builtin_log_ifThenElseIn)
    register_builtin!(log("call"),              _builtin_log_call)
    register_builtin!(log("callWithOptional"),  _builtin_log_callWithOptional)
    register_builtin!(log("callWithCut"),       _builtin_log_callWithCut)
    register_builtin!(log("callWithCleanup"),   _builtin_log_callWithCleanup)
    register_builtin!(log("conclusion"),         _builtin_log_conclusion)
    register_builtin!(log("inferences"),         _builtin_log_inferences)

    crypto = Namespace(_CRYPTO)
    register_builtin!(crypto("sha"),     _builtin_crypto_sha1)
    register_builtin!(crypto("sha1"),    _builtin_crypto_sha1)
    register_builtin!(crypto("md5"),     _builtin_crypto_md5)
    register_builtin!(crypto("sha256"),  _builtin_crypto_sha256)
    register_builtin!(crypto("sha512"),  _builtin_crypto_sha512)

    list = Namespace(_LIST)
    register_builtin!(list("in"),              _builtin_list_in)
    register_builtin!(list("member"),          _builtin_list_member)
    register_builtin!(list("first"),           _builtin_list_first)
    register_builtin!(list("last"),            _builtin_list_last)
    register_builtin!(list("rest"),            _builtin_list_rest)
    register_builtin!(list("length"),          _builtin_list_length)
    register_builtin!(list("append"),          _builtin_list_append)
    register_builtin!(list("iterate"),         _builtin_list_iterate)
    register_builtin!(list("sort"),            _builtin_list_sort)
    register_builtin!(list("unique"),          _builtin_list_unique)
    register_builtin!(list("remove"),          _builtin_list_remove)
    register_builtin!(list("removeAt"),        _builtin_list_removeAt)
    register_builtin!(list("memberAt"),        _builtin_list_memberAt)
    register_builtin!(list("removeDuplicates"), _builtin_list_removeDuplicates)
    register_builtin!(list("firstRest"),       _builtin_list_firstRest)
    register_builtin!(list("setEqualTo"),      _builtin_list_setEqualTo)
    register_builtin!(list("setNotEqualTo"),   _builtin_list_setNotEqualTo)
    register_builtin!(list("multisetEqualTo"), _builtin_list_multisetEqualTo)
    register_builtin!(list("multisetNotEqualTo"), _builtin_list_multisetNotEqualTo)
    register_builtin!(list("map"),              _builtin_list_map)

    grph = Namespace(_GRAPH)
    register_builtin!(grph("length"),       _builtin_graph_length)
    register_builtin!(grph("member"),       _builtin_graph_member)
    register_builtin!(grph("union"),        _builtin_graph_union)
    register_builtin!(grph("intersection"), _builtin_graph_intersection)
    register_builtin!(grph("difference"),   _builtin_graph_difference)
    register_builtin!(grph("list"),         _builtin_graph_list)

    time = Namespace(_TIME)
    register_builtin!(time("localTime"), _builtin_time_localTime)
    register_builtin!(time("year"),      _builtin_time_year)
    register_builtin!(time("month"),     _builtin_time_month)
    register_builtin!(time("day"),       _builtin_time_day)
    register_builtin!(time("hour"),      _builtin_time_hour)
    register_builtin!(time("minute"),    _builtin_time_minute)
    register_builtin!(time("second"),    _builtin_time_second)
    register_builtin!(time("dayOfWeek"), _builtin_time_dayOfWeek)
    register_builtin!(time("inSeconds"), _builtin_time_inSeconds)
    register_builtin!(time("timeZone"),  _builtin_time_timeZone)

    nothing
end

_register_n3_builtins!()
