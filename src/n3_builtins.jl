# ─── N3 Builtin Predicates ──────────────────────────────────────────
# Computational predicates for N3 reasoning (math, string, log, crypto, list, graph, time).
# Each builtin takes (subject, object, bindings, graph) and returns a vector of
# binding dicts — non-empty on success, empty on failure.

const _BUILTIN_REGISTRY = Dict{URIRef, Function}()

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

_resolve(term::Identifier, bindings::Dict{Variable, Identifier}) =
    term isa Variable ? get(bindings, term, term) : term

function _to_number(lit::Identifier)
    lit isa Literal || return nothing
    v = tryparse(Float64, lit.lexical)
    v !== nothing && isinteger(v) ? Int(v) : v
end

function _from_number(n)
    if n isa Integer
        Literal(string(n); datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))
    else
        Literal(string(Float64(n)); datatype=URIRef("http://www.w3.org/2001/XMLSchema#double"))
    end
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
                return a == b ? _success(bindings) : _failure()
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
                    (:notGreaterThan, :<=), (:notLessThan, :>=),
                    (:equalTo, :(==)), (:notEqualTo, :(!=))]
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

# --- unary functions (subject → object) ---

for (name, fn) in [(:negation, :(-)), (:absoluteValue, :abs),
                    (:floor, :floor), (:ceiling, :ceil), (:rounded, :round),
                    (:sqrt, :sqrt),
                    (:sin, :sin), (:cos, :cos), (:tan, :tan),
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
        (a !== nothing && b !== nothing && b != 0) || return _failure()
        return _bind_or_check(object, _from_number(a / b), bindings)
    end
    return _failure()
end

# math:remainder: (a b) math:remainder result  (a % b)
function _builtin_math_remainder(subject::Identifier, object::Identifier,
                                 bindings::Dict{Variable, Identifier},
                                 graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    items = _resolve_rdf_list(s, graph)
    if items !== nothing && length(items) == 2
        items = _resolve_items(items, bindings)
        a = _to_number(items[1])
        b = _to_number(items[2])
        (a !== nothing && b !== nothing && b != 0) || return _failure()
        return _bind_or_check(object, _from_number(rem(a, b)), bindings)
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
            return _bind_or_check(object, _from_number(a^b), bindings)
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
            item isa Literal || return _failure()
            push!(strs, item.lexical)
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

# ─── Log builtins ──────────────────────────────────────────────────

const _LOG = "http://www.w3.org/2000/10/swap/log#"

function _builtin_log_equalTo(subject::Identifier, object::Identifier,
                              bindings::Dict{Variable, Identifier},
                              graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Variable || o isa Variable) && return _failure()
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
    s != o ? _success(bindings) : _failure()
end

function _builtin_log_includes(subject::Identifier, object::Identifier,
                               bindings::Dict{Variable, Identifier},
                               graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    o = _resolve(object, bindings)
    (s isa Formula && o isa Formula) || return _failure()
    # Check if all triples in object's graph are included in subject's graph
    for t in o.graph
        found = false
        for ft in triples(s.graph, (nothing, nothing, nothing))
            if unify_triple(t, ft, Binding()) !== nothing
                found = true
                break
            end
        end
        found || return _failure()
    end
    _success(bindings)
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
    log = Namespace(_LOG)
    type_uri = if s isa Literal
        log("Literal")
    elseif s isa Formula
        log("Formula")
    elseif s isa BNode
        log("LabeledBlankNode")
    elseif s isa URIRef
        log("Other")
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
    s = _resolve(subject, bindings)
    s isa Literal || return _failure()
    _bind_or_check(object, Literal(s.lexical), bindings)
end

function _builtin_log_bound(subject::Identifier, object::Identifier,
                            bindings::Dict{Variable, Identifier},
                            graph::Union{RDFGraph, Nothing}=nothing)
    s = _resolve(subject, bindings)
    s isa Variable ? _failure() : _success(bindings)
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

    nothing
end

_register_n3_builtins!()
