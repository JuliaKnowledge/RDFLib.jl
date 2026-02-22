# ─── JSON-LD Processing ──────────────────────────────────────────────
# Expansion, Compaction, Framing, and Flattening for JSON-LD documents.

const RDF_TYPE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"

# ─── Helpers ─────────────────────────────────────────────────────────

"""Convert JSON3 output (or any AbstractDict/AbstractVector) to plain Dict/Vector."""
function _to_plain(x)
    if x isa AbstractDict
        Dict{String,Any}(String(k) => _to_plain(v) for (k, v) in pairs(x))
    elseif x isa AbstractVector
        Any[_to_plain(v) for v in x]
    elseif x isa AbstractString
        String(x)
    else
        x
    end
end

function _parse_json(input::AbstractString)
    _to_plain(JSON3.read(input))
end

"""Merge two context dicts; `child` overrides `parent`."""
function _merge_contexts(parent::Dict{String,Any}, child::Dict{String,Any})
    merged = copy(parent)
    merge!(merged, child)
    merged
end

"""Resolve a term using the context. Returns the full IRI or the term unchanged."""
function _expand_term(term::AbstractString, ctx::Dict{String,Any})
    # JSON-LD keywords
    startswith(term, "@") && return term
    # Already a full URI
    (occursin("://", term) || startswith(term, "urn:")) && return term
    # Direct mapping in context
    if haskey(ctx, term)
        v = ctx[term]
        if v isa AbstractString
            return String(v)
        elseif v isa AbstractDict
            id = get(v, "@id", nothing)
            id !== nothing && return String(id)
        end
    end
    # Prefixed name (prefix:localname)
    parts = split(term, ":", limit=2)
    if length(parts) == 2
        pfx, localname = parts
        if haskey(ctx, String(pfx))
            pv = ctx[String(pfx)]
            base = pv isa AbstractString ? pv : get(pv, "@id", String(pfx) * ":")
            return base * localname
        end
    end
    term
end

"""Build a flat context dict from a raw @context value (string, dict, or array)."""
function _build_context(raw)::Dict{String,Any}
    if raw === nothing
        return Dict{String,Any}()
    elseif raw isa AbstractDict
        ctx = Dict{String,Any}()
        for (k, v) in pairs(raw)
            ctx[String(k)] = v isa AbstractString ? String(v) : _to_plain(v)
        end
        return ctx
    elseif raw isa AbstractVector
        ctx = Dict{String,Any}()
        for item in raw
            merge!(ctx, _build_context(item))
        end
        return ctx
    else
        return Dict{String,Any}()
    end
end

"""Get the @type coercion for a term from context, if any."""
function _get_type_coercion(term::AbstractString, ctx::Dict{String,Any})
    if haskey(ctx, term) && ctx[term] isa AbstractDict
        return get(ctx[term], "@type", nothing)
    end
    nothing
end

"""Get the @container setting for a term from context, if any."""
function _get_container(term::AbstractString, ctx::Dict{String,Any})
    if haskey(ctx, term) && ctx[term] isa AbstractDict
        return get(ctx[term], "@container", nothing)
    end
    nothing
end

# ─── Expansion ───────────────────────────────────────────────────────

"""
    jsonld_expand(input::AbstractString)::Vector{Dict{String, Any}}

Expand a JSON-LD document, resolving all context terms to full IRIs.
Returns a Vector of expanded node objects.
"""
function jsonld_expand(input::AbstractString)::Vector{Dict{String,Any}}
    doc = _parse_json(input)
    if doc isa AbstractVector
        result = Dict{String,Any}[]
        for item in doc
            ctx = _build_context(get(item, "@context", nothing))
            expanded = _expand_node(item, ctx)
            if expanded !== nothing
                push!(result, expanded)
            end
        end
        return result
    else
        ctx = _build_context(get(doc, "@context", nothing))
        expanded = _expand_node(doc, ctx)
        return expanded === nothing ? Dict{String,Any}[] : [expanded]
    end
end

"""Expand a single node object."""
function _expand_node(node::AbstractDict, ctx::Dict{String,Any})
    # Handle nested @context
    if haskey(node, "@context")
        child_ctx = _build_context(node["@context"])
        ctx = _merge_contexts(ctx, child_ctx)
    end
    default_lang = get(ctx, "@language", nothing)

    result = Dict{String,Any}()

    for (key, val) in pairs(node)
        key == "@context" && continue

        if key == "@id"
            result["@id"] = _expand_term(String(val), ctx)
            continue
        end

        if key == "@type"
            types = val isa AbstractVector ? val : [val]
            result["@type"] = [_expand_term(String(t), ctx) for t in types]
            continue
        end

        expanded_key = _expand_term(key, ctx)
        startswith(expanded_key, "@") && (result[expanded_key] = val; continue)

        type_coercion = _get_type_coercion(key, ctx)
        result[expanded_key] = _expand_value(val, ctx, default_lang, type_coercion)
    end

    # Don't return empty nodes (only had @context)
    isempty(result) && return nothing
    result
end

"""Expand a value into an array of value objects."""
function _expand_value(val, ctx::Dict{String,Any}, default_lang, type_coercion)
    if val isa AbstractVector
        expanded = Any[]
        for v in val
            items = _expand_value(v, ctx, default_lang, type_coercion)
            append!(expanded, items)
        end
        return expanded
    elseif val isa AbstractDict
        # Nested node or value object
        if haskey(val, "@value")
            return [_to_plain(val)]
        elseif haskey(val, "@id")
            expanded = _expand_node(val, ctx)
            return expanded === nothing ? Any[] : Any[expanded]
        elseif haskey(val, "@list")
            list_items = _expand_value(val["@list"], ctx, default_lang, type_coercion)
            return Any[Dict{String,Any}("@list" => list_items)]
        else
            expanded = _expand_node(val, ctx)
            return expanded === nothing ? Any[] : Any[expanded]
        end
    elseif val isa AbstractString
        if type_coercion == "@id"
            return Any[Dict{String,Any}("@id" => _expand_term(String(val), ctx))]
        elseif default_lang !== nothing
            return Any[Dict{String,Any}("@value" => String(val), "@language" => String(default_lang))]
        else
            return Any[Dict{String,Any}("@value" => String(val))]
        end
    elseif val isa Bool
        return Any[Dict{String,Any}("@value" => val)]
    elseif val isa Number
        return Any[Dict{String,Any}("@value" => val)]
    elseif val === nothing
        return Any[]
    else
        return Any[Dict{String,Any}("@value" => val)]
    end
end

# ─── Compaction ──────────────────────────────────────────────────────

"""
    jsonld_compact(input, context::Dict{String, Any})::Dict{String, Any}

Compact expanded JSON-LD using the provided context.
`input` can be a JSON string or a Vector/Dict of expanded nodes.
"""
function jsonld_compact(input, context::Dict{String,Any})::Dict{String,Any}
    if input isa AbstractString
        nodes = jsonld_expand(input)
    elseif input isa AbstractVector
        nodes = input
    elseif input isa AbstractDict
        nodes = [input]
    else
        error("jsonld_compact: unsupported input type")
    end

    ctx = _build_context(context)
    reverse_map = _build_reverse_map(ctx)

    if length(nodes) == 1
        compacted = _compact_node(nodes[1], ctx, reverse_map)
        compacted["@context"] = _to_plain(context)
        return compacted
    else
        compacted_nodes = [_compact_node(n, ctx, reverse_map) for n in nodes]
        result = Dict{String,Any}("@context" => _to_plain(context), "@graph" => compacted_nodes)
        return result
    end
end

"""Build a reverse mapping from full IRI to compact term."""
function _build_reverse_map(ctx::Dict{String,Any})
    rev = Dict{String,String}()
    for (term, val) in ctx
        startswith(term, "@") && continue
        if val isa AbstractString
            rev[val] = term
        elseif val isa AbstractDict
            id = get(val, "@id", nothing)
            id !== nothing && (rev[id] = term)
        end
    end
    rev
end

"""Compact a full IRI using the reverse map or prefix matching."""
function _compact_iri(iri::AbstractString, ctx::Dict{String,Any}, reverse_map::Dict{String,String})
    haskey(reverse_map, iri) && return reverse_map[iri]
    # Try prefix-based compaction
    for (term, val) in ctx
        startswith(term, "@") && continue
        base = val isa AbstractString ? val : get(val, "@id", nothing)
        base === nothing && continue
        if startswith(iri, base) && length(iri) > length(base)
            local_name = iri[length(base)+1:end]
            if !isempty(local_name)
                return term * ":" * local_name
            end
        end
    end
    iri
end

"""Compact a single expanded node."""
function _compact_node(node::AbstractDict, ctx::Dict{String,Any}, reverse_map::Dict{String,String})
    result = Dict{String,Any}()

    for (key, val) in pairs(node)
        if key == "@id"
            result["@id"] = val
            continue
        end
        if key == "@type"
            types = val isa AbstractVector ? val : [val]
            compacted_types = [_compact_iri(t, ctx, reverse_map) for t in types]
            result["@type"] = length(compacted_types) == 1 ? compacted_types[1] : compacted_types
            continue
        end
        if startswith(key, "@")
            result[key] = val
            continue
        end

        compact_key = _compact_iri(key, ctx, reverse_map)
        result[compact_key] = _compact_value(val, ctx, reverse_map)
    end
    result
end

"""Compact an expanded value (typically an array of value/node objects)."""
function _compact_value(val, ctx::Dict{String,Any}, reverse_map::Dict{String,String})
    if val isa AbstractVector
        compacted = Any[_compact_single_value(v, ctx, reverse_map) for v in val]
        return length(compacted) == 1 ? compacted[1] : compacted
    else
        return _compact_single_value(val, ctx, reverse_map)
    end
end

"""Compact a single value object."""
function _compact_single_value(val, ctx::Dict{String,Any}, reverse_map::Dict{String,String})
    if val isa AbstractDict
        if haskey(val, "@value")
            v = val["@value"]
            # Unwrap plain string values with no extra annotations
            if length(val) == 1
                return v
            end
            return _to_plain(val)
        elseif haskey(val, "@id") && length(val) == 1
            return _compact_iri(val["@id"], ctx, reverse_map)
        elseif haskey(val, "@list")
            return Dict{String,Any}("@list" => _compact_value(val["@list"], ctx, reverse_map))
        else
            return _compact_node(val, ctx, reverse_map)
        end
    else
        return val
    end
end

# ─── Framing ─────────────────────────────────────────────────────────

"""
    jsonld_frame(input, frame::Dict{String, Any})::Dict{String, Any}

Frame JSON-LD data to match a template structure.
Selects nodes matching the frame's @type and includes properties specified in the frame.
"""
function jsonld_frame(input, frame::Dict{String,Any})::Dict{String,Any}
    if input isa AbstractString
        nodes = jsonld_expand(input)
    elseif input isa AbstractVector
        nodes = input
    elseif input isa AbstractDict
        nodes = haskey(input, "@graph") ? input["@graph"] : [input]
    else
        error("jsonld_frame: unsupported input type")
    end

    # Build a node index by @id for embedding
    node_index = Dict{String,Dict{String,Any}}()
    for n in nodes
        if n isa AbstractDict && haskey(n, "@id")
            node_index[n["@id"]] = n
        end
    end

    frame_ctx = _build_context(get(frame, "@context", nothing))
    target_type = get(frame, "@type", nothing)
    if target_type !== nothing
        target_type = target_type isa AbstractVector ? target_type : [target_type]
        target_type = [_expand_term(String(t), frame_ctx) for t in target_type]
    end
    embed_mode = get(frame, "@embed", "@once")

    # Determine which frame properties to include
    frame_props = Set{String}()
    for k in keys(frame)
        startswith(k, "@") && continue
        push!(frame_props, _expand_term(k, frame_ctx))
    end

    matched = Dict{String,Any}[]
    for node in nodes
        node isa AbstractDict || continue
        if target_type !== nothing
            node_types = get(node, "@type", String[])
            node_types = node_types isa AbstractVector ? node_types : [node_types]
            any(t -> t in node_types, target_type) || continue
        end

        framed = Dict{String,Any}()
        haskey(node, "@id") && (framed["@id"] = node["@id"])
        haskey(node, "@type") && (framed["@type"] = node["@type"])

        for prop in frame_props
            if haskey(node, prop)
                val = node[prop]
                if embed_mode in ("@always", "@once")
                    framed[prop] = _embed_values(val, node_index)
                else
                    framed[prop] = val
                end
            else
                default_val = get(frame, prop, nothing)
                if default_val isa AbstractDict && haskey(default_val, "@default")
                    framed[prop] = default_val["@default"]
                end
            end
        end

        push!(matched, framed)
    end

    # Build output with context from frame
    result = Dict{String,Any}()
    if haskey(frame, "@context")
        result["@context"] = frame["@context"]
    end
    if length(matched) == 1
        merge!(result, matched[1])
    else
        result["@graph"] = matched
    end
    result
end

"""Embed referenced nodes inline when they exist in the index."""
function _embed_values(val, node_index::Dict{String,Dict{String,Any}})
    if val isa AbstractVector
        return Any[_embed_single(v, node_index) for v in val]
    else
        return _embed_single(val, node_index)
    end
end

function _embed_single(val, node_index::Dict{String,Dict{String,Any}})
    if val isa AbstractDict && haskey(val, "@id") && length(val) == 1
        id = val["@id"]
        if haskey(node_index, id)
            return copy(node_index[id])
        end
    end
    val
end

# ─── Flatten ─────────────────────────────────────────────────────────

"""
    jsonld_flatten(input::AbstractString)::Dict{String, Any}

Flatten a JSON-LD document. All nodes are placed in a top-level @graph array,
blank nodes receive generated @id values, and nested nodes become references.
"""
function jsonld_flatten(input::AbstractString)::Dict{String,Any}
    nodes = jsonld_expand(input)
    node_map = Dict{String,Dict{String,Any}}()
    _bnode_counter = Ref(0)

    for node in nodes
        _flatten_node!(node, node_map, _bnode_counter)
    end

    graph = collect(values(node_map))
    sort!(graph, by = n -> get(n, "@id", ""))
    Dict{String,Any}("@graph" => graph)
end

"""Generate a fresh blank node ID."""
function _gen_bnode_id(counter::Ref{Int})
    counter[] += 1
    "_:b$(counter[])"
end

"""Flatten a node, extracting nested nodes into the node_map."""
function _flatten_node!(node::AbstractDict, node_map::Dict{String,Dict{String,Any}}, counter::Ref{Int})
    id = get(node, "@id", nothing)
    if id === nothing
        id = _gen_bnode_id(counter)
    end

    entry = get!(node_map, id, Dict{String,Any}("@id" => id))

    for (key, val) in pairs(node)
        if key == "@id"
            continue
        elseif key == "@type"
            existing = get(entry, "@type", String[])
            new_types = val isa AbstractVector ? val : [val]
            entry["@type"] = unique(vcat(existing, new_types))
        elseif startswith(key, "@")
            entry[key] = val
        else
            entry[key] = _flatten_values(val, node_map, counter)
        end
    end
end

"""Flatten values, replacing nested nodes with @id references."""
function _flatten_values(val, node_map::Dict{String,Dict{String,Any}}, counter::Ref{Int})
    if val isa AbstractVector
        result = Any[]
        for v in val
            append!(result, _flatten_values(v, node_map, counter))
        end
        return result
    elseif val isa AbstractDict
        if haskey(val, "@value")
            return Any[val]
        end
        # Nested node — flatten it and return a reference
        _flatten_node!(val, node_map, counter)
        ref_id = get(val, "@id", nothing)
        if ref_id === nothing
            # Should have been assigned by _flatten_node!
            return Any[val]
        end
        return Any[Dict{String,Any}("@id" => ref_id)]
    else
        return Any[val]
    end
end
