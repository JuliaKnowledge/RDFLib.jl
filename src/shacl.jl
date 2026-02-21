# ─── SHACL (Shapes Constraint Language) Validation ──────────────────

"""
    ValidationResult

A single SHACL validation result.
"""
struct ValidationResult
    focus_node::Identifier
    path::Union{URIRef, Nothing}
    value::Union{Identifier, Nothing}
    source_shape::Identifier
    severity::URIRef
    message::String
end

"""
    ValidationReport

The result of SHACL validation.
"""
struct ValidationReport
    conforms::Bool
    results::Vector{ValidationResult}
end

const _SH_IN    = URIRef("http://www.w3.org/ns/shacl#in")
const _SH_CLASS = URIRef("http://www.w3.org/ns/shacl#class")

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
    r = tryparse(Float64, v.lexical)
    r
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

# ─── Validation entry point ─────────────────────────────────────────

"""
    validate(data::RDFGraph, shapes::RDFGraph) -> ValidationReport

Validate a data graph against SHACL shapes.

# Supported constraints
- `sh:targetClass` — target nodes by rdf:type
- `sh:targetNode` — target specific nodes
- `sh:property` — property shapes with:
  - `sh:path` — property path (simple URIRef only)
  - `sh:minCount` / `sh:maxCount` — cardinality
  - `sh:datatype` — value datatype
  - `sh:nodeKind` — sh:IRI, sh:Literal, sh:BlankNode, etc.
  - `sh:minInclusive` / `sh:maxInclusive` / `sh:minExclusive` / `sh:maxExclusive` — value ranges
  - `sh:minLength` / `sh:maxLength` — string length
  - `sh:pattern` — regex pattern (with optional `sh:flags`)
  - `sh:hasValue` — required value
  - `sh:in` — allowed values (rdf:List)
  - `sh:class` — value must have rdf:type

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
    results = ValidationResult[]

    for shape_node in subjects(shapes, RDF.type, SH.NodeShape)
        _validate_shape(data, shapes, shape_node, results)
    end

    ValidationReport(isempty(results), results)
end

# ─── Shape validation ───────────────────────────────────────────────

function _validate_shape(data::RDFGraph, shapes::RDFGraph, shape_node, results::Vector{ValidationResult})
    targets = _collect_targets(data, shapes, shape_node)

    severity = let v = _get_value(shapes, shape_node, SH.severity)
        v isa URIRef ? v : SH.Violation
    end

    for focus in targets
        for prop_shape in objects(shapes, shape_node, SH.property)
            _validate_property(data, shapes, focus, prop_shape, severity, results)
        end
    end
end

function _collect_targets(data::RDFGraph, shapes::RDFGraph, shape_node)
    targets = Set{Identifier}()

    # sh:targetClass
    for cls in objects(shapes, shape_node, SH.targetClass)
        for node in subjects(data, RDF.type, cls)
            push!(targets, node)
        end
    end

    # sh:targetNode
    for node in objects(shapes, shape_node, SH.targetNode)
        push!(targets, node)
    end

    targets
end

# ─── Property constraint validation ─────────────────────────────────

function _validate_property(data::RDFGraph, shapes::RDFGraph, focus_node, prop_shape, severity::URIRef, results::Vector{ValidationResult})
    path = _get_value(shapes, prop_shape, SH.path)
    isnothing(path) && return
    path isa URIRef || return

    values = collect(objects(data, focus_node, path))

    # sh:minCount
    min_count = _get_int(shapes, prop_shape, SH.minCount)
    if !isnothing(min_count) && length(values) < min_count
        push!(results, ValidationResult(focus_node, path, nothing, prop_shape,
            severity, "Expected at least $min_count values for $(path.value), got $(length(values))"))
    end

    # sh:maxCount
    max_count = _get_int(shapes, prop_shape, SH.maxCount)
    if !isnothing(max_count) && length(values) > max_count
        push!(results, ValidationResult(focus_node, path, nothing, prop_shape,
            severity, "Expected at most $max_count values for $(path.value), got $(length(values))"))
    end

    # sh:hasValue
    has_val = _get_value(shapes, prop_shape, SH.hasValue)
    if !isnothing(has_val) && !(has_val in values)
        push!(results, ValidationResult(focus_node, path, nothing, prop_shape,
            severity, "Missing required value $(has_val)"))
    end

    # Per-value constraints
    for val in values
        _validate_value_constraints(data, shapes, focus_node, path, val, prop_shape, severity, results)
    end
end

# ─── Per-value constraint checks ────────────────────────────────────

function _validate_value_constraints(data::RDFGraph, shapes::RDFGraph, focus_node, path::URIRef, val, prop_shape, severity::URIRef, results::Vector{ValidationResult})
    # sh:datatype
    req_dt = _get_value(shapes, prop_shape, SH.datatype)
    if !isnothing(req_dt) && req_dt isa URIRef
        if val isa Literal
            if _effective_datatype(val) != req_dt
                push!(results, ValidationResult(focus_node, path, val, prop_shape,
                    severity, "Expected datatype $(req_dt.value), got $(_effective_datatype(val).value)"))
            end
        else
            push!(results, ValidationResult(focus_node, path, val, prop_shape,
                severity, "Expected a Literal with datatype $(req_dt.value)"))
        end
    end

    # sh:nodeKind
    req_nk = _get_value(shapes, prop_shape, SH.nodeKind)
    if !isnothing(req_nk) && req_nk isa URIRef
        if !_check_node_kind(val, req_nk)
            push!(results, ValidationResult(focus_node, path, val, prop_shape,
                severity, "Value does not match nodeKind $(req_nk.value)"))
        end
    end

    # Numeric range constraints (only for Literals)
    if val isa Literal
        numval = _literal_numeric(val)

        # sh:minInclusive
        min_inc = _get_numeric(shapes, prop_shape, SH.minInclusive)
        if !isnothing(min_inc) && !isnothing(numval) && numval < min_inc
            push!(results, ValidationResult(focus_node, path, val, prop_shape,
                severity, "Value $(val.lexical) < minInclusive $min_inc"))
        end

        # sh:maxInclusive
        max_inc = _get_numeric(shapes, prop_shape, SH.maxInclusive)
        if !isnothing(max_inc) && !isnothing(numval) && numval > max_inc
            push!(results, ValidationResult(focus_node, path, val, prop_shape,
                severity, "Value $(val.lexical) > maxInclusive $max_inc"))
        end

        # sh:minExclusive
        min_exc = _get_numeric(shapes, prop_shape, SH.minExclusive)
        if !isnothing(min_exc) && !isnothing(numval) && numval <= min_exc
            push!(results, ValidationResult(focus_node, path, val, prop_shape,
                severity, "Value $(val.lexical) <= minExclusive $min_exc"))
        end

        # sh:maxExclusive
        max_exc = _get_numeric(shapes, prop_shape, SH.maxExclusive)
        if !isnothing(max_exc) && !isnothing(numval) && numval >= max_exc
            push!(results, ValidationResult(focus_node, path, val, prop_shape,
                severity, "Value $(val.lexical) >= maxExclusive $max_exc"))
        end

        # sh:minLength
        min_len = _get_int(shapes, prop_shape, SH.minLength)
        if !isnothing(min_len) && length(val.lexical) < min_len
            push!(results, ValidationResult(focus_node, path, val, prop_shape,
                severity, "String length $(length(val.lexical)) < minLength $min_len"))
        end

        # sh:maxLength
        max_len = _get_int(shapes, prop_shape, SH.maxLength)
        if !isnothing(max_len) && length(val.lexical) > max_len
            push!(results, ValidationResult(focus_node, path, val, prop_shape,
                severity, "String length $(length(val.lexical)) > maxLength $max_len"))
        end

        # sh:pattern
        pat_val = _get_value(shapes, prop_shape, SH.pattern)
        if !isnothing(pat_val) && pat_val isa Literal
            flags_val = _get_value(shapes, prop_shape, SH.flags)
            regex_flags = ""
            if !isnothing(flags_val) && flags_val isa Literal
                regex_flags = flags_val.lexical
            end
            rx = _make_regex(pat_val.lexical, regex_flags)
            if !isnothing(rx) && !occursin(rx, val.lexical)
                push!(results, ValidationResult(focus_node, path, val, prop_shape,
                    severity, "Value \"$(val.lexical)\" does not match pattern \"$(pat_val.lexical)\""))
            end
        end
    end

    # sh:in (allowed values list)
    in_head = _get_value(shapes, prop_shape, _SH_IN)
    if !isnothing(in_head) && in_head isa Node
        allowed = collect_list(shapes, in_head)
        if !(val in allowed)
            push!(results, ValidationResult(focus_node, path, val, prop_shape,
                severity, "Value not in allowed list"))
        end
    end

    # sh:class (value must have rdf:type)
    req_class = _get_value(shapes, prop_shape, _SH_CLASS)
    if !isnothing(req_class) && req_class isa URIRef
        if val isa Node
            types = collect(objects(data, val, RDF.type))
            if !(req_class in types)
                push!(results, ValidationResult(focus_node, path, val, prop_shape,
                    severity, "Value does not have required rdf:type $(req_class.value)"))
            end
        else
            push!(results, ValidationResult(focus_node, path, val, prop_shape,
                severity, "sh:class requires a node value, got Literal"))
        end
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
