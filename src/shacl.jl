# ─── SHACL (Shapes Constraint Language) Validation ──────────────────

"""
    ValidationResult

A single SHACL validation result.

Fields:
- `focus_node` — the node being validated
- `path` — the property path of the result (a `URIRef` for simple paths, a
  `BNode` for complex paths, or `nothing` for node-shape results). Also
  accessible as `result_path`.
- `value` — the offending value (or `nothing`)
- `source_shape` — the shape that produced the result
- `severity` — `sh:Violation` (default), `sh:Warning` or `sh:Info`
- `message` — human-readable message (`sh:message` of the shape if present)
"""
struct ValidationResult
    focus_node::Identifier
    path::Union{Identifier, Nothing}
    value::Union{Identifier, Nothing}
    source_shape::Identifier
    severity::URIRef
    message::String
end

# Compatibility alias: `r.result_path` mirrors the SHACL vocabulary term
# `sh:resultPath` (used e.g. by the HTTP server report serializer).
function Base.getproperty(r::ValidationResult, name::Symbol)
    name === :result_path && return getfield(r, :path)
    getfield(r, name)
end

"""
    ValidationReport

The result of SHACL validation.
"""
struct ValidationReport
    conforms::Bool
    results::Vector{ValidationResult}
end

# ─── SHACL vocabulary terms not in the `SH` DefinedNamespace ─────────

const _SHACL_NS = "http://www.w3.org/ns/shacl#"

const _SH_IN    = URIRef(_SHACL_NS * "in")
const _SH_CLASS = URIRef(_SHACL_NS * "class")
# Logical constraint components
const _SH_NOT  = URIRef(_SHACL_NS * "not")
const _SH_AND  = URIRef(_SHACL_NS * "and")
const _SH_OR   = URIRef(_SHACL_NS * "or")
const _SH_XONE = URIRef(_SHACL_NS * "xone")
# Shape-based constraint components
const _SH_NODE                = URIRef(_SHACL_NS * "node")
const _SH_QUALIFIED_VALUE_SHAPE = URIRef(_SHACL_NS * "qualifiedValueShape")
const _SH_QUALIFIED_MIN_COUNT = URIRef(_SHACL_NS * "qualifiedMinCount")
const _SH_QUALIFIED_MAX_COUNT = URIRef(_SHACL_NS * "qualifiedMaxCount")
const _SH_QUALIFIED_DISJOINT  = URIRef(_SHACL_NS * "qualifiedValueShapesDisjoint")
# Closed shapes
const _SH_CLOSED             = URIRef(_SHACL_NS * "closed")
const _SH_IGNORED_PROPERTIES = URIRef(_SHACL_NS * "ignoredProperties")
# Property paths
const _SH_INVERSE_PATH     = URIRef(_SHACL_NS * "inversePath")
const _SH_ALTERNATIVE_PATH = URIRef(_SHACL_NS * "alternativePath")
const _SH_ZERO_OR_MORE     = URIRef(_SHACL_NS * "zeroOrMorePath")
const _SH_ONE_OR_MORE      = URIRef(_SHACL_NS * "oneOrMorePath")
const _SH_ZERO_OR_ONE      = URIRef(_SHACL_NS * "zeroOrOnePath")
# Property-pair constraint components
const _SH_EQUALS              = URIRef(_SHACL_NS * "equals")
const _SH_DISJOINT            = URIRef(_SHACL_NS * "disjoint")
const _SH_LESS_THAN           = URIRef(_SHACL_NS * "lessThan")
const _SH_LESS_THAN_OR_EQUALS = URIRef(_SHACL_NS * "lessThanOrEquals")
# String/language constraint components
const _SH_LANGUAGE_IN = URIRef(_SHACL_NS * "languageIn")
# SPARQL-based constraints
const _SH_SPARQL    = URIRef(_SHACL_NS * "sparql")
const _SH_SELECT    = URIRef(_SHACL_NS * "select")
const _SH_PREFIXES  = URIRef(_SHACL_NS * "prefixes")
const _SH_DECLARE   = URIRef(_SHACL_NS * "declare")
const _SH_PREFIX    = URIRef(_SHACL_NS * "prefix")
const _SH_NAMESPACE = URIRef(_SHACL_NS * "namespace")
# Misc
const _SH_DEACTIVATED = URIRef(_SHACL_NS * "deactivated")

# Numeric XSD datatypes for value comparison (sh:lessThan etc.)
const _SHACL_NUMERIC_DTS = Set{URIRef}(URIRef(_XSD * n) for n in (
    "integer", "decimal", "double", "float",
    "long", "int", "short", "byte",
    "nonNegativeInteger", "nonPositiveInteger",
    "negativeInteger", "positiveInteger",
    "unsignedLong", "unsignedInt", "unsignedShort", "unsignedByte"))

# ─── Helpers ────────────────────────────────────────────────────────

function _get_value(g::RDFGraph, s, p)
    for o in objects(g, s, p)
        return o
    end
    nothing
end

function _get_int(g::RDFGraph, s, p)
    v = _get_value(g, s, p)
    isnothing(v) && return nothing
    v isa Literal || return nothing
    tryparse(Int, v.lexical)
end

function _get_numeric(g::RDFGraph, s, p)
    v = _get_value(g, s, p)
    isnothing(v) && return nothing
    v isa Literal || return nothing
    tryparse(Float64, v.lexical)
end

function _get_bool(g::RDFGraph, s, p)
    v = _get_value(g, s, p)
    v isa Literal || return nothing
    v.lexical in ("true", "1") && return true
    v.lexical in ("false", "0") && return false
    nothing
end

function _literal_numeric(lit::Literal)
    tryparse(Float64, lit.lexical)
end

function _effective_datatype(lit::Literal)
    if !isnothing(lit.datatype)
        return lit.datatype
    end
    if !isnothing(lit.language)
        return URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#langString")
    end
    # Plain literal defaults to xsd:string
    URIRef("http://www.w3.org/2001/XMLSchema#string")
end

# String value used for sh:minLength / sh:maxLength / sh:pattern.
# Per SHACL these also apply to IRIs (their string form); blank nodes
# have no string value and always fail such constraints.
function _string_value(val)
    val isa Literal && return val.lexical
    val isa URIRef && return val.value
    nothing
end

_is_deactivated(shapes::RDFGraph, shape) = _get_bool(shapes, shape, _SH_DEACTIVATED) === true

function _shape_severity(shapes::RDFGraph, shape)
    v = _get_value(shapes, shape, SH.severity)
    v isa URIRef ? v : SH.Violation
end

function _shape_message(shapes::RDFGraph, shape)
    v = _get_value(shapes, shape, SH.message)
    v isa Literal ? v.lexical : nothing
end

# Value comparison for sh:lessThan / sh:lessThanOrEquals.
# Returns -1 / 0 / 1, or `nothing` when incomparable.
function _value_compare(a, b)
    (a isa Literal && b isa Literal) || return nothing
    if !isnothing(a.datatype) && a.datatype in _SHACL_NUMERIC_DTS &&
       !isnothing(b.datatype) && b.datatype in _SHACL_NUMERIC_DTS
        na = _literal_numeric(a)
        nb = _literal_numeric(b)
        (isnothing(na) || isnothing(nb)) && return nothing
        return na < nb ? -1 : (na > nb ? 1 : 0)
    end
    # Plain / xsd:string literals — codepoint comparison
    if isnothing(a.datatype) && isnothing(a.language) &&
       isnothing(b.datatype) && isnothing(b.language)
        return cmp(a.lexical, b.lexical)
    end
    # Same explicit datatype (e.g. xsd:date / xsd:dateTime — ISO lexical order)
    if a.datatype == b.datatype && isnothing(a.language) && isnothing(b.language)
        return cmp(a.lexical, b.lexical)
    end
    nothing
end

# Basic language-range matching (RFC 4647 basic filtering):
# "en" matches "en" and "en-GB"; "*" matches any tag.
function _lang_matches(lang::AbstractString, range::AbstractString)
    range == "*" && return true
    l = lowercase(lang)
    r = lowercase(range)
    l == r || startswith(l, r * "-")
end

# SHACL instance check: rdf:type / rdfs:subClassOf* (in the data graph)
function _is_subclass_of(data::RDFGraph, sub::URIRef, sup::URIRef)
    sub == sup && return true
    seen = Set{URIRef}([sub])
    queue = URIRef[sub]
    while !isempty(queue)
        c = popfirst!(queue)
        for s in objects(data, c, RDFS.subClassOf)
            s isa URIRef || continue
            s == sup && return true
            if !(s in seen)
                push!(seen, s)
                push!(queue, s)
            end
        end
    end
    false
end

function _has_class(data::RDFGraph, val, cls::URIRef)
    val isa Node || return false
    for t in objects(data, val, RDF.type)
        t isa URIRef || continue
        _is_subclass_of(data, t, cls) && return true
    end
    false
end

# All instances of `cls` (including instances of subclasses)
function _class_instances(data::RDFGraph, cls::URIRef)
    classes = Set{URIRef}([cls])
    queue = URIRef[cls]
    while !isempty(queue)
        c = popfirst!(queue)
        for sub in subjects(data, RDFS.subClassOf, c)
            sub isa URIRef || continue
            if !(sub in classes)
                push!(classes, sub)
                push!(queue, sub)
            end
        end
    end
    out = Identifier[]
    seen = Set{Identifier}()
    for c in classes
        for n in subjects(data, RDF.type, c)
            if !(n in seen)
                push!(seen, n)
                push!(out, n)
            end
        end
    end
    out
end

# ─── Property paths ─────────────────────────────────────────────────

abstract type _SHPath end
struct _PredPath <: _SHPath
    pred::URIRef
end
struct _InvPredPath <: _SHPath
    pred::URIRef
end
struct _SeqPath <: _SHPath
    parts::Vector{_SHPath}
end
struct _AltPath <: _SHPath
    alts::Vector{_SHPath}
end
struct _ZeroOrMorePath <: _SHPath
    inner::_SHPath
end
struct _OneOrMorePath <: _SHPath
    inner::_SHPath
end
struct _ZeroOrOnePath <: _SHPath
    inner::_SHPath
end

_invert_path(p::_PredPath)       = _InvPredPath(p.pred)
_invert_path(p::_InvPredPath)    = _PredPath(p.pred)
_invert_path(p::_SeqPath)        = _SeqPath([_invert_path(x) for x in reverse(p.parts)])
_invert_path(p::_AltPath)        = _AltPath([_invert_path(x) for x in p.alts])
_invert_path(p::_ZeroOrMorePath) = _ZeroOrMorePath(_invert_path(p.inner))
_invert_path(p::_OneOrMorePath)  = _OneOrMorePath(_invert_path(p.inner))
_invert_path(p::_ZeroOrOnePath)  = _ZeroOrOnePath(_invert_path(p.inner))

"""
    _parse_path(shapes, node) -> Union{_SHPath, Nothing}

Parse a SHACL property path expression from the shapes graph.
Returns `nothing` for unrecognized path structures.
"""
function _parse_path(shapes::RDFGraph, node)
    node isa URIRef && return _PredPath(node)
    node isa BNode || return nothing

    # Sequence path: an rdf:List of paths
    if !isnothing(_get_value(shapes, node, RDF_FIRST))
        items = collect_list(shapes, node)
        parts = _SHPath[]
        for it in items
            p = _parse_path(shapes, it)
            isnothing(p) && return nothing
            push!(parts, p)
        end
        isempty(parts) && return nothing
        return length(parts) == 1 ? parts[1] : _SeqPath(parts)
    end

    inv = _get_value(shapes, node, _SH_INVERSE_PATH)
    if !isnothing(inv)
        inner = _parse_path(shapes, inv)
        isnothing(inner) && return nothing
        return _invert_path(inner)
    end

    alt = _get_value(shapes, node, _SH_ALTERNATIVE_PATH)
    if !isnothing(alt) && alt isa Node
        items = collect_list(shapes, alt)
        alts = _SHPath[]
        for it in items
            p = _parse_path(shapes, it)
            isnothing(p) && return nothing
            push!(alts, p)
        end
        isempty(alts) && return nothing
        return _AltPath(alts)
    end

    for (pred, T) in ((_SH_ZERO_OR_MORE, _ZeroOrMorePath),
                      (_SH_ONE_OR_MORE, _OneOrMorePath),
                      (_SH_ZERO_OR_ONE, _ZeroOrOnePath))
        inner_node = _get_value(shapes, node, pred)
        if !isnothing(inner_node)
            inner = _parse_path(shapes, inner_node)
            isnothing(inner) && return nothing
            return T(inner)
        end
    end

    nothing
end

_path_string(p::_PredPath)       = "<$(p.pred.value)>"
_path_string(p::_InvPredPath)    = "^<$(p.pred.value)>"
_path_string(p::_SeqPath)        = join((_path_string(x) for x in p.parts), "/")
_path_string(p::_AltPath)        = "(" * join((_path_string(x) for x in p.alts), "|") * ")"
_path_string(p::_ZeroOrMorePath) = "(" * _path_string(p.inner) * ")*"
_path_string(p::_OneOrMorePath)  = "(" * _path_string(p.inner) * ")+"
_path_string(p::_ZeroOrOnePath)  = "(" * _path_string(p.inner) * ")?"

function _add_path_value!(out::Vector{Identifier}, seen::Set{Identifier}, v)
    if !(v in seen)
        push!(seen, v)
        push!(out, v)
    end
    nothing
end

"""
    _path_values(data, focus, path::_SHPath) -> Vector{Identifier}

Resolve the (set of) value nodes reachable from `focus` via `path`.
"""
function _path_values(data::RDFGraph, focus::Identifier, path::_SHPath)
    out = Identifier[]
    seen = Set{Identifier}()
    _path_step!(out, seen, data, focus, path)
    out
end

function _path_step!(out, seen, data::RDFGraph, node, p::_PredPath)
    node isa Node || return
    for o in objects(data, node, p.pred)
        _add_path_value!(out, seen, o)
    end
end

function _path_step!(out, seen, data::RDFGraph, node, p::_InvPredPath)
    for s in subjects(data, p.pred, node)
        _add_path_value!(out, seen, s)
    end
end

function _path_step!(out, seen, data::RDFGraph, node, p::_SeqPath)
    frontier = Identifier[node]
    for part in p.parts
        nxt = Identifier[]
        nseen = Set{Identifier}()
        for n in frontier
            for v in _path_values(data, n, part)
                if !(v in nseen)
                    push!(nseen, v)
                    push!(nxt, v)
                end
            end
        end
        frontier = nxt
        isempty(frontier) && break
    end
    for v in frontier
        _add_path_value!(out, seen, v)
    end
end

function _path_step!(out, seen, data::RDFGraph, node, p::_AltPath)
    for alt in p.alts
        for v in _path_values(data, node, alt)
            _add_path_value!(out, seen, v)
        end
    end
end

function _path_step!(out, seen, data::RDFGraph, node, p::_ZeroOrMorePath)
    visited = Set{Identifier}([node])
    queue = Identifier[node]
    _add_path_value!(out, seen, node)
    while !isempty(queue)
        n = popfirst!(queue)
        for v in _path_values(data, n, p.inner)
            if !(v in visited)
                push!(visited, v)
                push!(queue, v)
                _add_path_value!(out, seen, v)
            end
        end
    end
end

function _path_step!(out, seen, data::RDFGraph, node, p::_OneOrMorePath)
    visited = Set{Identifier}()
    queue = Identifier[]
    for v in _path_values(data, node, p.inner)
        if !(v in visited)
            push!(visited, v)
            push!(queue, v)
            _add_path_value!(out, seen, v)
        end
    end
    while !isempty(queue)
        n = popfirst!(queue)
        for v in _path_values(data, n, p.inner)
            if !(v in visited)
                push!(visited, v)
                push!(queue, v)
                _add_path_value!(out, seen, v)
            end
        end
    end
end

function _path_step!(out, seen, data::RDFGraph, node, p::_ZeroOrOnePath)
    _add_path_value!(out, seen, node)
    for v in _path_values(data, node, p.inner)
        _add_path_value!(out, seen, v)
    end
end

# ─── Validation context ─────────────────────────────────────────────

struct _SHACLContext
    data::RDFGraph
    shapes::RDFGraph
    in_progress::Set{Tuple{Identifier, Identifier}}  # (focus, shape) pairs
end

function _report!(results::Vector{ValidationResult}, ctx::_SHACLContext,
                  focus, path, value, shape, default_msg::String)
    sev = _shape_severity(ctx.shapes, shape)
    msg = something(_shape_message(ctx.shapes, shape), default_msg)
    push!(results, ValidationResult(focus, path, value, shape, sev, msg))
    nothing
end

# ─── Validation entry point ─────────────────────────────────────────

"""
    validate(data::RDFGraph, shapes::RDFGraph) -> ValidationReport

Validate a data graph against SHACL shapes.

# Supported features
Targets:
- `sh:targetClass` (with `rdfs:subClassOf` closure in the data graph),
  implicit class targets (shape that is itself an `rdfs:Class`)
- `sh:targetNode`, `sh:targetSubjectsOf`, `sh:targetObjectsOf`

Property paths (`sh:path`):
- predicate paths, sequence paths (RDF lists), `sh:inversePath`,
  `sh:alternativePath`, `sh:zeroOrMorePath`, `sh:oneOrMorePath`,
  `sh:zeroOrOnePath` (arbitrarily nested)

Core constraint components:
- Cardinality: `sh:minCount`, `sh:maxCount`
- Value type: `sh:datatype`, `sh:nodeKind`, `sh:class` (with subclass closure)
- Value range: `sh:minInclusive`, `sh:maxInclusive`, `sh:minExclusive`, `sh:maxExclusive`
- String: `sh:minLength`, `sh:maxLength` (also on IRIs), `sh:pattern` (+ `sh:flags`),
  `sh:languageIn`, `sh:uniqueLang`
- Property pair: `sh:equals`, `sh:disjoint`, `sh:lessThan`, `sh:lessThanOrEquals`
- Logical: `sh:not`, `sh:and`, `sh:or`, `sh:xone`
- Shape-based: `sh:property`, `sh:node`, `sh:qualifiedValueShape` with
  `sh:qualifiedMinCount` / `sh:qualifiedMaxCount` / `sh:qualifiedValueShapesDisjoint`
- Other: `sh:closed` (+ `sh:ignoredProperties`), `sh:hasValue`, `sh:in`,
  `sh:deactivated`, `sh:severity`, `sh:message`
- SPARQL-based constraints: `sh:sparql` with `sh:select`, `sh:message`,
  and `sh:prefixes` (`sh:declare` / `sh:prefix` / `sh:namespace`).
  `\$this` is pre-bound by rewriting it to `?this` and injecting a
  `VALUES ?this { <focus> }` clause into the WHERE block.

# Known limitations
- `sh:sparql` is skipped for blank-node focus nodes (no true pre-binding),
  ASK-based validators (`sh:ask`) and `\$PATH`/`\$shapesGraph` substitution
  are not supported, and SPARQL constraints producing parse/eval errors are
  silently skipped.
- Value comparisons for `sh:lessThan` / `sh:lessThanOrEquals` cover numeric
  literals, plain strings, and literals sharing the same datatype
  (lexical/ISO order); incomparable pairs are reported as violations.
- Numeric range constraints are skipped for non-numeric lexical forms.
- Not implemented: SHACL-SPARQL constraint components (`sh:ConstraintComponent`),
  SPARQL-based targets, `sh:shapesGraph` import resolution, `owl:imports`.

# Example
```julia
shapes = RDFGraph()
shape = BNode()
add!(shapes, Triple(shape, RDF.type, SH.NodeShape))
add!(shapes, Triple(shape, SH.targetClass, EX("Person")))
prop = BNode()
add!(shapes, Triple(shape, SH.property, prop))
add!(shapes, Triple(prop, SH.path, EX("name")))
add!(shapes, Triple(prop, SH.minCount, Literal(1)))
add!(shapes, Triple(prop, SH.maxCount, Literal(1)))

report = validate(data_graph, shapes)
report.conforms  # true/false
```
"""
function validate(data::RDFGraph, shapes::RDFGraph)
    ctx = _SHACLContext(data, shapes, Set{Tuple{Identifier, Identifier}}())
    results = ValidationResult[]

    for shape_node in _all_target_shapes(shapes)
        _is_deactivated(shapes, shape_node) && continue
        for focus in _collect_targets(data, shapes, shape_node)
            append!(results, _shape_results(ctx, focus, shape_node))
        end
    end

    ValidationReport(isempty(results), results)
end

# All nodes that are explicitly declared shapes or carry target declarations
function _all_target_shapes(shapes::RDFGraph)
    out = Identifier[]
    seen = Set{Identifier}()
    addshape = s -> begin
        if !(s in seen)
            push!(seen, s)
            push!(out, s)
        end
    end
    for s in subjects(shapes, RDF.type, SH.NodeShape)
        addshape(s)
    end
    for s in subjects(shapes, RDF.type, SH.PropertyShape)
        addshape(s)
    end
    for p in (SH.targetClass, SH.targetNode, SH.targetSubjectsOf, SH.targetObjectsOf)
        for s in subjects(shapes, p)
            addshape(s)
        end
    end
    out
end

function _collect_targets(data::RDFGraph, shapes::RDFGraph, shape_node)
    targets = Identifier[]
    seen = Set{Identifier}()
    addtarget = n -> begin
        if !(n in seen)
            push!(seen, n)
            push!(targets, n)
        end
    end

    # sh:targetClass (+ implicit class target when the shape is an rdfs:Class)
    classes = URIRef[]
    for cls in objects(shapes, shape_node, SH.targetClass)
        cls isa URIRef && push!(classes, cls)
    end
    if shape_node isa URIRef && any(==(RDFS.Class), objects(shapes, shape_node, RDF.type))
        push!(classes, shape_node)
    end
    for cls in classes
        for node in _class_instances(data, cls)
            addtarget(node)
        end
    end

    # sh:targetNode
    for node in objects(shapes, shape_node, SH.targetNode)
        addtarget(node)
    end

    # sh:targetSubjectsOf
    for pred in objects(shapes, shape_node, SH.targetSubjectsOf)
        pred isa URIRef || continue
        for s in subjects(data, pred)
            addtarget(s)
        end
    end

    # sh:targetObjectsOf
    for pred in objects(shapes, shape_node, SH.targetObjectsOf)
        pred isa URIRef || continue
        for o in objects(data, nothing, pred)
            addtarget(o)
        end
    end

    targets
end

# ─── Shape validation ───────────────────────────────────────────────

"""
    _shape_results(ctx, focus, shape) -> Vector{ValidationResult}

Validate a single focus node against a shape (node shape or property shape).
Cyclic shape references terminate via the `(focus, shape)` in-progress set
(a cycle is treated as conforming).
"""
function _shape_results(ctx::_SHACLContext, focus, shape)
    results = ValidationResult[]
    shape isa Node || return results  # malformed shape reference
    _is_deactivated(ctx.shapes, shape) && return results
    key = (focus, shape)
    key in ctx.in_progress && return results
    push!(ctx.in_progress, key)
    try
        _validate_node_against_shape!(ctx, focus, shape, results)
    finally
        delete!(ctx.in_progress, key)
    end
    results
end

_conforms(ctx::_SHACLContext, focus, shape) = isempty(_shape_results(ctx, focus, shape))

function _validate_node_against_shape!(ctx::_SHACLContext, focus, shape, results::Vector{ValidationResult})
    shapes = ctx.shapes
    data = ctx.data

    path_node = _get_value(shapes, shape, SH.path)
    parsed_path = isnothing(path_node) ? nothing : _parse_path(shapes, path_node)
    # A shape with an unparseable sh:path cannot be evaluated — skip it
    !isnothing(path_node) && isnothing(parsed_path) && return

    is_prop = !isnothing(parsed_path)
    path_repr = is_prop ? path_node : nothing
    path_desc = is_prop ? _path_string(parsed_path) : "node"
    values = is_prop ? _path_values(data, focus, parsed_path) : Identifier[focus]

    # ── Cardinality (property shapes only) ──
    if is_prop
        min_count = _get_int(shapes, shape, SH.minCount)
        if !isnothing(min_count) && length(values) < min_count
            _report!(results, ctx, focus, path_repr, nothing, shape,
                "Expected at least $min_count values for $path_desc, got $(length(values))")
        end

        max_count = _get_int(shapes, shape, SH.maxCount)
        if !isnothing(max_count) && length(values) > max_count
            _report!(results, ctx, focus, path_repr, nothing, shape,
                "Expected at most $max_count values for $path_desc, got $(length(values))")
        end
    end

    # ── sh:hasValue ──
    has_val = _get_value(shapes, shape, SH.hasValue)
    if !isnothing(has_val) && !(has_val in values)
        _report!(results, ctx, focus, path_repr, nothing, shape,
            "Missing required value $(has_val)")
    end

    # ── sh:uniqueLang ──
    if _get_bool(shapes, shape, SH.uniqueLang) === true
        lang_counts = Dict{String, Int}()
        for v in values
            v isa Literal && !isnothing(v.language) || continue
            lang_counts[v.language] = get(lang_counts, v.language, 0) + 1
        end
        for (lang, c) in lang_counts
            if c > 1
                _report!(results, ctx, focus, path_repr, nothing, shape,
                    "Language tag \"$lang\" is used by $c values; sh:uniqueLang requires at most one")
            end
        end
    end

    # ── Property-pair constraints ──
    _check_pair_constraints!(ctx, focus, path_repr, path_desc, values, shape, results)

    # ── Qualified value shapes ──
    _check_qualified_shapes!(ctx, focus, path_repr, path_desc, values, shape, results)

    # ── sh:closed (applied to each value node; for node shapes, the focus) ──
    _check_closed!(ctx, focus, values, shape, results)

    # ── Per-value constraints ──
    for val in values
        _validate_value_constraints!(ctx, focus, path_repr, path_desc, val, shape, results)
    end

    # ── Nested property shapes (sh:property) ──
    for prop_shape in objects(shapes, shape, SH.property)
        for val in values
            append!(results, _shape_results(ctx, val, prop_shape))
        end
    end

    # ── SPARQL-based constraints (sh:sparql) — once per focus node ──
    for cnode in objects(shapes, shape, _SH_SPARQL)
        _check_sparql_constraint!(ctx, focus, path_repr, shape, cnode, results)
    end
end

# ─── Property-pair constraints ──────────────────────────────────────

function _check_pair_constraints!(ctx::_SHACLContext, focus, path_repr, path_desc,
                                  values::Vector{Identifier}, shape, results)
    shapes = ctx.shapes
    data = ctx.data

    other_values = pred -> focus isa Node ? collect(objects(data, focus, pred)) : Identifier[]

    # sh:equals — the value sets must be identical
    for pred in objects(shapes, shape, _SH_EQUALS)
        pred isa URIRef || continue
        other = other_values(pred)
        for v in values
            if !(v in other)
                _report!(results, ctx, focus, path_repr, v, shape,
                    "Value must also be a value of <$(pred.value)> (sh:equals)")
            end
        end
        for o in other
            if !(o in values)
                _report!(results, ctx, focus, path_repr, o, shape,
                    "Value of <$(pred.value)> is missing from $path_desc (sh:equals)")
            end
        end
    end

    # sh:disjoint — no shared values
    for pred in objects(shapes, shape, _SH_DISJOINT)
        pred isa URIRef || continue
        other = other_values(pred)
        for v in values
            if v in other
                _report!(results, ctx, focus, path_repr, v, shape,
                    "Value must not also be a value of <$(pred.value)> (sh:disjoint)")
            end
        end
    end

    # sh:lessThan / sh:lessThanOrEquals — pairwise comparison
    for (constraint, strict) in ((_SH_LESS_THAN, true), (_SH_LESS_THAN_OR_EQUALS, false))
        for pred in objects(shapes, shape, constraint)
            pred isa URIRef || continue
            other = other_values(pred)
            for v in values, o in other
                c = _value_compare(v, o)
                ok = !isnothing(c) && (strict ? c < 0 : c <= 0)
                if !ok
                    op = strict ? "<" : "<="
                    _report!(results, ctx, focus, path_repr, v, shape,
                        "Value is not $op the value(s) of <$(pred.value)>")
                end
            end
        end
    end
end

# ─── Qualified value shapes ─────────────────────────────────────────

function _check_qualified_shapes!(ctx::_SHACLContext, focus, path_repr, path_desc,
                                  values::Vector{Identifier}, shape, results)
    shapes = ctx.shapes

    qshape = _get_value(shapes, shape, _SH_QUALIFIED_VALUE_SHAPE)
    isnothing(qshape) && return

    qmin = _get_int(shapes, shape, _SH_QUALIFIED_MIN_COUNT)
    qmax = _get_int(shapes, shape, _SH_QUALIFIED_MAX_COUNT)
    isnothing(qmin) && isnothing(qmax) && return

    disjoint = _get_bool(shapes, shape, _SH_QUALIFIED_DISJOINT) === true
    siblings = disjoint ? _sibling_qualified_shapes(shapes, shape, qshape) : Identifier[]

    count_conforming = 0
    for v in values
        _conforms(ctx, v, qshape) || continue
        if disjoint && any(_conforms(ctx, v, sib) for sib in siblings)
            continue
        end
        count_conforming += 1
    end

    if !isnothing(qmin) && count_conforming < qmin
        _report!(results, ctx, focus, path_repr, nothing, shape,
            "Expected at least $qmin values of $path_desc conforming to the qualified shape, got $count_conforming")
    end
    if !isnothing(qmax) && count_conforming > qmax
        _report!(results, ctx, focus, path_repr, nothing, shape,
            "Expected at most $qmax values of $path_desc conforming to the qualified shape, got $count_conforming")
    end
end

# Sibling qualified value shapes: qualified shapes of the other property
# shapes attached to the same parent shape(s) via sh:property.
function _sibling_qualified_shapes(shapes::RDFGraph, prop_shape, qshape)
    sibs = Identifier[]
    for parent in subjects(shapes, SH.property, prop_shape)
        for other_ps in objects(shapes, parent, SH.property)
            other_ps == prop_shape && continue
            for q in objects(shapes, other_ps, _SH_QUALIFIED_VALUE_SHAPE)
                q == qshape && continue
                q in sibs || push!(sibs, q)
            end
        end
    end
    sibs
end

# ─── sh:closed ──────────────────────────────────────────────────────

function _check_closed!(ctx::_SHACLContext, focus, values::Vector{Identifier}, shape, results)
    shapes = ctx.shapes
    data = ctx.data

    _get_bool(shapes, shape, _SH_CLOSED) === true || return

    allowed = Set{URIRef}()
    for prop_shape in objects(shapes, shape, SH.property)
        p = _get_value(shapes, prop_shape, SH.path)
        p isa URIRef && push!(allowed, p)
    end
    ignored = _get_value(shapes, shape, _SH_IGNORED_PROPERTIES)
    if ignored isa Node
        for it in collect_list(shapes, ignored)
            it isa URIRef && push!(allowed, it)
        end
    end

    for v in values
        v isa Node || continue
        for t in triples(data, (v, nothing, nothing))
            if !(t.predicate in allowed)
                _report!(results, ctx, focus, t.predicate, t.object, shape,
                    "Predicate <$(t.predicate.value)> is not allowed by closed shape")
            end
        end
    end
end

# ─── Per-value constraint checks ────────────────────────────────────

function _validate_value_constraints!(ctx::_SHACLContext, focus, path_repr, path_desc,
                                      val, shape, results::Vector{ValidationResult})
    shapes = ctx.shapes
    data = ctx.data

    # sh:datatype
    req_dt = _get_value(shapes, shape, SH.datatype)
    if !isnothing(req_dt) && req_dt isa URIRef
        if val isa Literal
            if _effective_datatype(val) != req_dt
                _report!(results, ctx, focus, path_repr, val, shape,
                    "Expected datatype $(req_dt.value), got $(_effective_datatype(val).value)")
            end
        else
            _report!(results, ctx, focus, path_repr, val, shape,
                "Expected a Literal with datatype $(req_dt.value)")
        end
    end

    # sh:nodeKind
    req_nk = _get_value(shapes, shape, SH.nodeKind)
    if !isnothing(req_nk) && req_nk isa URIRef
        if !_check_node_kind(val, req_nk)
            _report!(results, ctx, focus, path_repr, val, shape,
                "Value does not match nodeKind $(req_nk.value)")
        end
    end

    # Numeric range constraints (only checked for Literals with numeric lexical form)
    if val isa Literal
        numval = _literal_numeric(val)

        # sh:minInclusive
        min_inc = _get_numeric(shapes, shape, SH.minInclusive)
        if !isnothing(min_inc) && !isnothing(numval) && numval < min_inc
            _report!(results, ctx, focus, path_repr, val, shape,
                "Value $(val.lexical) < minInclusive $min_inc")
        end

        # sh:maxInclusive
        max_inc = _get_numeric(shapes, shape, SH.maxInclusive)
        if !isnothing(max_inc) && !isnothing(numval) && numval > max_inc
            _report!(results, ctx, focus, path_repr, val, shape,
                "Value $(val.lexical) > maxInclusive $max_inc")
        end

        # sh:minExclusive
        min_exc = _get_numeric(shapes, shape, SH.minExclusive)
        if !isnothing(min_exc) && !isnothing(numval) && numval <= min_exc
            _report!(results, ctx, focus, path_repr, val, shape,
                "Value $(val.lexical) <= minExclusive $min_exc")
        end

        # sh:maxExclusive
        max_exc = _get_numeric(shapes, shape, SH.maxExclusive)
        if !isnothing(max_exc) && !isnothing(numval) && numval >= max_exc
            _report!(results, ctx, focus, path_repr, val, shape,
                "Value $(val.lexical) >= maxExclusive $max_exc")
        end
    end

    # String constraints — apply to Literals and IRIs; blank nodes always fail
    strval = _string_value(val)

    # sh:minLength
    min_len = _get_int(shapes, shape, SH.minLength)
    if !isnothing(min_len)
        if isnothing(strval)
            _report!(results, ctx, focus, path_repr, val, shape,
                "Blank node has no string value for minLength")
        elseif length(strval) < min_len
            _report!(results, ctx, focus, path_repr, val, shape,
                "String length $(length(strval)) < minLength $min_len")
        end
    end

    # sh:maxLength
    max_len = _get_int(shapes, shape, SH.maxLength)
    if !isnothing(max_len)
        if isnothing(strval)
            _report!(results, ctx, focus, path_repr, val, shape,
                "Blank node has no string value for maxLength")
        elseif length(strval) > max_len
            _report!(results, ctx, focus, path_repr, val, shape,
                "String length $(length(strval)) > maxLength $max_len")
        end
    end

    # sh:pattern
    pat_val = _get_value(shapes, shape, SH.pattern)
    if !isnothing(pat_val) && pat_val isa Literal
        flags_val = _get_value(shapes, shape, SH.flags)
        regex_flags = ""
        if !isnothing(flags_val) && flags_val isa Literal
            regex_flags = flags_val.lexical
        end
        rx = _make_regex(pat_val.lexical, regex_flags)
        if !isnothing(rx)
            if isnothing(strval)
                _report!(results, ctx, focus, path_repr, val, shape,
                    "Blank node has no string value for pattern")
            elseif !occursin(rx, strval)
                _report!(results, ctx, focus, path_repr, val, shape,
                    "Value \"$strval\" does not match pattern \"$(pat_val.lexical)\"")
            end
        end
    end

    # sh:languageIn
    lang_head = _get_value(shapes, shape, _SH_LANGUAGE_IN)
    if !isnothing(lang_head) && lang_head isa Node
        tags = String[x.lexical for x in collect_list(shapes, lang_head) if x isa Literal]
        ok = val isa Literal && !isnothing(val.language) &&
             any(_lang_matches(val.language, t) for t in tags)
        if !ok
            _report!(results, ctx, focus, path_repr, val, shape,
                "Value does not have a language tag in [$(join(tags, ", "))]")
        end
    end

    # sh:in (allowed values list)
    in_head = _get_value(shapes, shape, _SH_IN)
    if !isnothing(in_head) && in_head isa Node
        allowed = collect_list(shapes, in_head)
        if !(val in allowed)
            _report!(results, ctx, focus, path_repr, val, shape,
                "Value not in allowed list")
        end
    end

    # sh:class (value must be a SHACL instance of the class)
    for req_class in objects(shapes, shape, _SH_CLASS)
        req_class isa URIRef || continue
        if val isa Node
            if !_has_class(data, val, req_class)
                _report!(results, ctx, focus, path_repr, val, shape,
                    "Value does not have required rdf:type $(req_class.value)")
            end
        else
            _report!(results, ctx, focus, path_repr, val, shape,
                "sh:class requires a node value, got Literal")
        end
    end

    # ── Logical constraint components ──

    # sh:not — value must NOT conform to the given shape
    for not_shape in objects(shapes, shape, _SH_NOT)
        if _conforms(ctx, val, not_shape)
            _report!(results, ctx, focus, path_repr, val, shape,
                "Value conforms to shape it must not conform to (sh:not)")
        end
    end

    # sh:and — value must conform to all member shapes
    for and_head in objects(shapes, shape, _SH_AND)
        and_head isa Node || continue
        for member in collect_list(shapes, and_head)
            if !_conforms(ctx, val, member)
                _report!(results, ctx, focus, path_repr, val, shape,
                    "Value does not conform to all shapes in sh:and list")
                break
            end
        end
    end

    # sh:or — value must conform to at least one member shape
    for or_head in objects(shapes, shape, _SH_OR)
        or_head isa Node || continue
        members = collect_list(shapes, or_head)
        if !any(_conforms(ctx, val, m) for m in members)
            _report!(results, ctx, focus, path_repr, val, shape,
                "Value does not conform to any shape in sh:or list")
        end
    end

    # sh:xone — value must conform to exactly one member shape
    for xone_head in objects(shapes, shape, _SH_XONE)
        xone_head isa Node || continue
        members = collect_list(shapes, xone_head)
        n = count(_conforms(ctx, val, m) for m in members)
        if n != 1
            _report!(results, ctx, focus, path_repr, val, shape,
                "Value conforms to $n shapes in sh:xone list, expected exactly 1")
        end
    end

    # sh:node — value must conform to the given node shape
    for node_shape in objects(shapes, shape, _SH_NODE)
        if !_conforms(ctx, val, node_shape)
            _report!(results, ctx, focus, path_repr, val, shape,
                "Value does not conform to node shape $(node_shape)")
        end
    end
end

# ─── SPARQL-based constraints (sh:sparql) ───────────────────────────

function _sparql_prefix_header(shapes::RDFGraph, cnode)
    io = IOBuffer()
    for px in objects(shapes, cnode, _SH_PREFIXES)
        px isa Node || continue
        for decl in objects(shapes, px, _SH_DECLARE)
            decl isa Node || continue
            p = _get_value(shapes, decl, _SH_PREFIX)
            ns = _get_value(shapes, decl, _SH_NAMESPACE)
            p isa Literal || continue
            nsv = ns isa Literal ? ns.lexical : (ns isa URIRef ? ns.value : nothing)
            isnothing(nsv) && continue
            println(io, "PREFIX $(p.lexical): <$nsv>")
        end
    end
    String(take!(io))
end

# Pre-bind $this by rewriting to ?this and injecting a VALUES clause
# right after the opening brace of the WHERE block.
function _prebind_this(query::String, focus)
    q = replace(query, "\$this" => "?this")
    values_clause = " VALUES ?this { $(n3(focus)) } "
    m = match(r"WHERE\s*\{"i, q)
    if !isnothing(m)
        pos = m.offset + length(m.match) - 1  # index of the '{'
        return q[1:pos] * values_clause * q[pos+1:end]
    end
    # No WHERE keyword found — append a trailing VALUES clause
    q * "\nVALUES ?this { $(n3(focus)) }"
end

function _check_sparql_constraint!(ctx::_SHACLContext, focus, path_repr, shape, cnode, results)
    shapes = ctx.shapes
    cnode isa Node || return
    _is_deactivated(shapes, cnode) && return

    sel = _get_value(shapes, cnode, _SH_SELECT)
    sel isa Literal || return

    # Limitation: blank nodes cannot be pre-bound via textual substitution
    focus isa BNode && return

    query = _sparql_prefix_header(shapes, cnode) * _prebind_this(sel.lexical, focus)

    solutions = try
        sparql_query(ctx.data, query)
    catch
        return  # malformed/unsupported query — skipped (see docstring)
    end
    solutions isa AbstractVector || return

    msg_lit = _get_value(shapes, cnode, SH.message)
    sev = _shape_severity(shapes, shape)
    for sol in solutions
        val = get(sol, "value", nothing)
        res_path = get(sol, "path", nothing)
        msg = if msg_lit isa Literal
            m = replace(msg_lit.lexical, "{\$this}" => string(focus), "{?this}" => string(focus))
            isnothing(val) ? m : replace(m, "{?value}" => string(val), "{\$value}" => string(val))
        else
            something(_shape_message(shapes, shape), "SPARQL constraint violated")
        end
        rpath = res_path isa URIRef ? res_path : path_repr
        push!(results, ValidationResult(focus, rpath, val, shape, sev, msg))
    end
end

# ─── nodeKind check ──────────────────────────────────────────────────

function _check_node_kind(val, nk::URIRef)
    nk == SH.IRI             && return val isa URIRef
    nk == SH.Literal         && return val isa Literal
    nk == SH.BlankNode       && return val isa BNode
    nk == SH.BlankNodeOrIRI  && return val isa URIRef || val isa BNode
    nk == SH.IRIOrLiteral    && return val isa URIRef || val isa Literal
    nk == SH.BlankNodeOrLiteral && return val isa BNode || val isa Literal
    true  # unknown nodeKind — pass
end

# ─── Regex helper ────────────────────────────────────────────────────

function _make_regex(pattern::String, flags::String)
    try
        opts = ""
        if 'i' in flags
            opts *= "i"
        end
        if 'm' in flags
            opts *= "m"
        end
        if 's' in flags
            opts *= "s"
        end
        if 'x' in flags
            opts *= "x"
        end
        if isempty(opts)
            Regex(pattern)
        else
            Regex(pattern, opts)
        end
    catch
        nothing
    end
end
