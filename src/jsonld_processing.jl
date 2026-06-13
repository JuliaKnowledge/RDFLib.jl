# ─── JSON-LD 1.1 Processing ──────────────────────────────────────────
# Expansion, Compaction, Framing, and Flattening for JSON-LD documents.
#
# This implements a substantial subset of the JSON-LD 1.1 API
# (https://www.w3.org/TR/json-ld11/ and https://www.w3.org/TR/json-ld11-api/):
#
# Supported:
#   - @context processing: term definitions, compact IRIs, @vocab (including
#     "@vocab": "" resolving against @base), @base, default @language and
#     @direction, @propagate, context arrays, null contexts
#   - Remote contexts via an injectable `context_loader` hook (per-call cache,
#     cycle detection)
#   - Scoped contexts: property-scoped (@context inside a term definition,
#     propagates) and type-scoped (applied via @type, does not propagate by
#     default per @propagate semantics)
#   - Expansion/compaction of @id, @type, @value, @language, @direction,
#     @index, @list, @set, @graph, @reverse (keyword and reverse terms), @nest
#   - Container mappings: @list, @set, @index, @language, @id, @type
#   - Type coercion: @id, @vocab, @json (rdf:JSON literals), datatype IRIs
#   - Keyword aliasing during expansion (terms mapping to keywords, e.g.
#     "id": "@id")
#
# Not supported (documented limitations):
#   - @included, @import, @protected (ignored), @version enforcement
#   - Keyword aliases in *compacted* output (compaction always emits "@id",
#     "@type", ... literally)
#   - JCS canonicalization of rdf:JSON literals (plain JSON serialization is
#     used instead)
#   - i18n (https://www.w3.org/ns/i18n#) compound datatypes for base
#     direction; `@direction` maps to the `direction` field of `Literal`
#   - Framing beyond the basic subset implemented in `jsonld_frame`
#   - Named graph semantics: `@graph` contents are merged into a single graph

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

const _JLD_KEYWORDS = Set([
    "@base", "@container", "@context", "@direction", "@graph", "@id", "@import",
    "@included", "@index", "@json", "@language", "@list", "@nest", "@none",
    "@prefix", "@propagate", "@protected", "@reverse", "@set", "@type",
    "@value", "@version", "@vocab",
])

_jld_is_keyword(s::AbstractString) = String(s) in _JLD_KEYWORDS

_jld_is_absolute(s::AbstractString) = occursin(r"^[A-Za-z][A-Za-z0-9+.\-]*:", s)

const _EMPTY_CONTAINER = Set{String}()

"""Resolve a (possibly relative) IRI reference against a base IRI."""
function _jld_resolve(base::Union{String,Nothing}, rel::AbstractString)
    r = String(rel)
    (base === nothing || isempty(base)) && return r
    _jld_is_absolute(r) && return r
    startswith(r, "_:") && return r
    try
        return string(URIs.resolvereference(URIs.URI(base), URIs.URI(r)))
    catch
        return r
    end
end

# ─── Active context ──────────────────────────────────────────────────

"""A term definition within an active JSON-LD context."""
Base.@kwdef struct JLDTermDef
    iri::Union{String,Nothing} = nothing        # nothing => term maps to null (dropped)
    reverse::Bool = false
    type_mapping::Union{String,Nothing} = nothing
    language::Union{String,Nothing} = nothing
    has_language::Bool = false                  # term sets @language (possibly null)
    direction::Union{String,Nothing} = nothing
    has_direction::Bool = false
    container::Set{String} = Set{String}()
    local_context::Any = nothing                # raw property-scoped @context
    has_context::Bool = false
    nest::Union{String,Nothing} = nothing
    prefix_flag::Bool = false
end

"""The active context used during expansion/compaction."""
mutable struct JLDActiveContext
    terms::Dict{String,JLDTermDef}
    base::Union{String,Nothing}
    vocab::Union{String,Nothing}                # "" => use @base (i.e. "@vocab": "")
    language::Union{String,Nothing}
    direction::Union{String,Nothing}
    previous::Union{JLDActiveContext,Nothing}   # for @propagate: false semantics
end

JLDActiveContext(base::Union{String,Nothing}=nothing) =
    JLDActiveContext(Dict{String,JLDTermDef}(), base, nothing, nothing, nothing, nothing)

_jld_copy(c::JLDActiveContext) =
    JLDActiveContext(copy(c.terms), c.base, c.vocab, c.language, c.direction, c.previous)

"""Processing options carried through expansion/compaction."""
struct JLDOptions
    loader::Any                     # callable url::String -> JSON string or Dict, or nothing
    cache::Dict{String,Any}         # per-call cache of loaded remote contexts
    base::Union{String,Nothing}
end

JLDOptions(loader, base::Union{String,Nothing}=nothing) =
    JLDOptions(loader, Dict{String,Any}(), base)

"""
    _jsonld_default_loader(url::AbstractString) -> String

Default remote-context document loader: fetches `url` over HTTP(S) using
`Downloads` (the same mechanism as content negotiation in `load_rdf`), with an
`Accept` header preferring `application/ld+json`. Pass a custom function as
`context_loader=` to any of the JSON-LD API functions to override (e.g. for
offline tests).
"""
function _jsonld_default_loader(url::AbstractString)
    buf = IOBuffer()
    try
        Downloads.request(String(url);
            headers=["Accept" => "application/ld+json, application/json;q=0.9, */*;q=0.1"],
            output=buf)
    catch e
        throw(ErrorException("JSON-LD: failed to load remote context $url: $e"))
    end
    String(take!(buf))
end

# ─── Context processing ──────────────────────────────────────────────

"""
Process a local context (`nothing`, string IRI, dict, or array thereof) against
an active context, returning the new active context.

Implements (a subset of) the JSON-LD 1.1 Context Processing algorithm:
remote contexts (with cycle detection), `@base`, `@vocab`, `@language`,
`@direction`, `@propagate`, and term definitions.
"""
function _process_context(active::JLDActiveContext, local_ctx, opts::JLDOptions;
                          propagate::Bool=true, remote_stack::Vector{String}=String[])
    result = _jld_copy(active)
    items = local_ctx isa AbstractVector ? local_ctx : Any[local_ctx]
    for item in items
        # An in-context "@propagate" overrides the call-level propagate flag
        item_propagate = propagate
        if item isa AbstractDict && get(item, "@propagate", nothing) isa Bool
            item_propagate = item["@propagate"]
        end
        if item === nothing
            # null context: reset to initial context
            result = JLDActiveContext(opts.base)
            if !item_propagate
                result.previous = active
            end
            continue
        elseif item isa AbstractString
            # Remote context reference
            url = _jld_resolve(result.base === nothing ? opts.base : result.base, String(item))
            url in remote_stack &&
                error("JSON-LD: cyclic @context inclusion detected: $url")
            ctxval = get!(opts.cache, url) do
                opts.loader === nothing &&
                    error("JSON-LD: remote @context \"$url\" encountered but no context_loader is available")
                raw = opts.loader(url)
                doc = raw isa AbstractString ? _parse_json(raw) : _to_plain(raw)
                doc isa AbstractDict ||
                    error("JSON-LD: remote context $url did not resolve to a JSON object")
                haskey(doc, "@context") ||
                    error("JSON-LD: remote document $url has no @context entry")
                doc["@context"]
            end
            result = _process_context(result, ctxval, opts;
                                      propagate=propagate,
                                      remote_stack=vcat(remote_stack, [url]))
            continue
        elseif !(item isa AbstractDict)
            error("JSON-LD: invalid @context entry of type $(typeof(item))")
        end
        ctx = item
        if haskey(ctx, "@base")
            b = ctx["@base"]
            if b === nothing
                result.base = nothing
            elseif b isa AbstractString
                bs = String(b)
                result.base = _jld_is_absolute(bs) ? bs :
                    (result.base !== nothing ? _jld_resolve(result.base, bs) : bs)
            end
        end
        if haskey(ctx, "@vocab")
            v = ctx["@vocab"]
            if v === nothing
                result.vocab = nothing
            elseif v isa AbstractString
                vs = String(v)
                if vs == ""
                    # "@vocab": "" — vocabulary-relative terms resolve against @base
                    result.vocab = result.base === nothing ? "" : result.base
                elseif _jld_is_absolute(vs) || startswith(vs, "_:")
                    result.vocab = vs
                else
                    # vocabulary-relative @vocab (JSON-LD 1.1)
                    result.vocab = (result.vocab !== nothing && result.vocab != "") ?
                        result.vocab * vs : _jld_resolve(result.base, vs)
                end
            end
        end
        if haskey(ctx, "@language")
            l = ctx["@language"]
            result.language = l isa AbstractString ? lowercase(String(l)) : nothing
        end
        if haskey(ctx, "@direction")
            d = ctx["@direction"]
            result.direction = (d isa AbstractString && String(d) in ("ltr", "rtl")) ?
                String(d) : nothing
        end
        if !item_propagate && result.previous === nothing
            result.previous = active
        end
        defined = Dict{String,Bool}()
        for key in sort!(collect(String.(keys(ctx))))
            key in ("@base", "@vocab", "@language", "@direction", "@propagate",
                    "@version", "@import", "@protected") && continue
            _create_term_definition!(result, ctx, key, defined, opts, remote_stack)
        end
    end
    result
end

"""Create (or overwrite) the term definition for `term` from raw context `ctx`."""
function _create_term_definition!(active::JLDActiveContext, ctx, term::String,
                                  defined::Dict{String,Bool}, opts::JLDOptions,
                                  remote_stack::Vector{String})
    if haskey(defined, term)
        defined[term] && return
        error("JSON-LD: cyclic IRI mapping involving term \"$term\"")
    end
    defined[term] = false
    isempty(term) && (defined[term] = true; return)
    if _jld_is_keyword(term) || occursin(r"^@[A-Za-z]+$", term)
        # Keywords cannot be redefined; keyword-like terms are ignored
        defined[term] = true
        return
    end
    raw = ctx[term]
    delete!(active.terms, term)
    simple = raw isa AbstractString
    value = raw === nothing ? Dict{String,Any}("@id" => nothing) :
            raw isa AbstractString ? Dict{String,Any}("@id" => String(raw)) :
            raw isa AbstractDict ? raw :
            error("JSON-LD: invalid term definition for \"$term\"")

    rev = false
    iri = nothing
    if haskey(value, "@reverse")
        rv = value["@reverse"]
        rv isa AbstractString || error("JSON-LD: invalid @reverse value for term \"$term\"")
        rev = true
        iri = _expand_iri(active, String(rv); vocab=true, local_ctx=ctx,
                          defined=defined, opts=opts)
    elseif haskey(value, "@id")
        idv = value["@id"]
        if idv isa AbstractString
            iri = _expand_iri(active, String(idv); vocab=true, local_ctx=ctx,
                              defined=defined, opts=opts)
        end
        # @id: null leaves iri === nothing (term is decoupled / dropped)
    elseif (idx = findfirst(':', term); idx !== nothing && idx > 1)
        iri = _expand_iri(active, term; vocab=true, local_ctx=ctx,
                          defined=defined, opts=opts)
    elseif active.vocab !== nothing
        vb = active.vocab == "" ? (active.base === nothing ? "" : active.base) : active.vocab
        iri = vb * term
    end

    tm = nothing
    if haskey(value, "@type") && value["@type"] isa AbstractString
        tvs = String(value["@type"])
        tm = tvs in ("@id", "@vocab", "@json", "@none") ? tvs :
             _expand_iri(active, tvs; vocab=true, local_ctx=ctx,
                         defined=defined, opts=opts)
    end

    container = Set{String}()
    if haskey(value, "@container")
        cv = value["@container"]
        for c in (cv isa AbstractVector ? cv : Any[cv])
            c isa AbstractString && push!(container, String(c))
        end
    end

    has_lang = haskey(value, "@language")
    langm = (has_lang && value["@language"] isa AbstractString) ?
        lowercase(String(value["@language"])) : nothing
    has_dir = haskey(value, "@direction")
    dirm = (has_dir && value["@direction"] isa AbstractString &&
            String(value["@direction"]) in ("ltr", "rtl")) ?
        String(value["@direction"]) : nothing
    has_ctx = haskey(value, "@context")
    lctx = has_ctx ? _to_plain(value["@context"]) : nothing
    nest = (haskey(value, "@nest") && value["@nest"] isa AbstractString) ?
        String(value["@nest"]) : nothing

    pflag = simple || get(value, "@prefix", false) === true
    if !pflag && iri !== nothing && !isempty(iri) && !occursin(":", term)
        # Lenient: dict-defined terms whose IRI ends in a gen-delim character
        # may also be used as prefixes (JSON-LD 1.0 compatibility)
        pflag = iri[end] in ('/', '#', ':', '?', '[', ']', '@')
    end

    active.terms[term] = JLDTermDef(iri=iri, reverse=rev, type_mapping=tm,
        language=langm, has_language=has_lang, direction=dirm, has_direction=has_dir,
        container=container, local_context=lctx, has_context=has_ctx, nest=nest,
        prefix_flag=pflag)
    defined[term] = true
    return
end

# ─── IRI expansion ───────────────────────────────────────────────────

"""
Expand `value` to an absolute IRI / keyword using the active context.

- `vocab=true`: interpret relative to terms and `@vocab` (used for properties
  and `@type` values).
- `relative=true`: resolve remaining relative IRIs against `@base` (used for
  `@id` values).

Returns `nothing` for terms that explicitly map to null and for keyword-like
(but unknown) strings.
"""
function _expand_iri(active::JLDActiveContext, value::Union{AbstractString,Nothing};
                     vocab::Bool=false, relative::Bool=false,
                     local_ctx=nothing, defined=nothing,
                     opts::Union{JLDOptions,Nothing}=nothing)
    value === nothing && return nothing
    v = String(value)
    _jld_is_keyword(v) && return v
    occursin(r"^@[A-Za-z]+$", v) && return nothing
    _opts = opts === nothing ? JLDOptions(nothing) : opts
    _defined = defined === nothing ? Dict{String,Bool}() : defined
    if local_ctx !== nothing && haskey(local_ctx, v) && get(_defined, v, false) !== true
        _create_term_definition!(active, local_ctx, v, _defined, _opts, String[])
    end
    if vocab && haskey(active.terms, v)
        return active.terms[v].iri
    end
    idx = findfirst(':', v)
    if idx !== nothing && idx > 1
        prefix = v[1:prevind(v, idx)]
        suffix = v[idx+1:end]
        startswith(suffix, "//") && return v       # already an absolute IRI
        prefix == "_" && return v                  # blank node identifier
        if local_ctx !== nothing && haskey(local_ctx, prefix) &&
           get(_defined, prefix, false) !== true
            _create_term_definition!(active, local_ctx, prefix, _defined, _opts, String[])
        end
        if haskey(active.terms, prefix)
            td = active.terms[prefix]
            if td.iri !== nothing && td.prefix_flag
                return td.iri * suffix
            end
        end
        _jld_is_absolute(v) && return v
    end
    if vocab && active.vocab !== nothing
        vb = active.vocab == "" ? (active.base === nothing ? "" : active.base) : active.vocab
        return vb == "" ? v : vb * v
    end
    relative && return _jld_resolve(active.base, v)
    return v
end

# ─── Expansion ───────────────────────────────────────────────────────

"""
    jsonld_expand(input; base=nothing, expand_context=nothing,
                  context_loader=_jsonld_default_loader)::Vector{Dict{String,Any}}

Expand a JSON-LD document, resolving all context terms to full IRIs.
Returns a Vector of expanded node objects.

`input` may be a JSON string or an already-parsed Dict/Vector.

Supported JSON-LD 1.1 features: prefixed names, `@vocab` (including
`"@vocab": ""`), `@base`, type coercion (`@id`, `@vocab`, `@json`, datatype
IRIs), default and term `@language`/`@direction`, `@list`/`@set` (keyword and
`@container`), `@reverse` (keyword and reverse terms), `@nest`, container maps
(`@index`, `@language`, `@id`, `@type`), property- and type-scoped contexts
with `@propagate` semantics, keyword aliases, and remote contexts.

# Keyword arguments
- `base`: base IRI for resolving relative IRIs.
- `expand_context`: an optional context (dict or `{"@context": ...}` wrapper)
  applied before processing the document.
- `context_loader`: function called with a URL string when a remote context is
  referenced; must return a JSON string or parsed Dict for the remote document.
  Defaults to an HTTP loader using `Downloads`. Loaded contexts are cached per
  call, and context inclusion cycles raise an error.
"""
function jsonld_expand(input; base=nothing, expand_context=nothing,
                       context_loader=_jsonld_default_loader)::Vector{Dict{String,Any}}
    doc = input isa AbstractString ? _parse_json(input) : _to_plain(input)
    opts = JLDOptions(context_loader, base === nothing ? nothing : String(base))
    active = JLDActiveContext(opts.base)
    if expand_context !== nothing
        ec = _to_plain(expand_context)
        if ec isa AbstractDict && haskey(ec, "@context")
            ec = ec["@context"]
        end
        active = _process_context(active, ec, opts)
    end
    expanded = _expand_element(active, nothing, doc, opts)
    if expanded isa AbstractDict && length(expanded) == 1 && haskey(expanded, "@graph")
        expanded = expanded["@graph"]
    end
    expanded === nothing && return Dict{String,Any}[]
    arr = expanded isa AbstractVector ? expanded : Any[expanded]
    return Dict{String,Any}[x for x in arr if x isa AbstractDict]
end

"""Core recursive expansion (JSON-LD 1.1 Expansion algorithm, simplified)."""
function _expand_element(active::JLDActiveContext, active_prop::Union{String,Nothing},
                         element, opts::JLDOptions; from_map::Bool=false)
    element === nothing && return nothing
    prop_td = active_prop === nothing ? nothing : get(active.terms, active_prop, nothing)
    # @json type coercion short-circuits structural interpretation of the value
    if prop_td !== nothing && prop_td.type_mapping == "@json"
        return Dict{String,Any}("@value" => _to_plain(element), "@type" => "@json")
    end
    if element isa AbstractVector
        out = Any[]
        is_list_prop = prop_td !== nothing && "@list" in prop_td.container
        for item in element
            e = _expand_element(active, active_prop, item, opts; from_map=from_map)
            e === nothing && continue
            if e isa AbstractVector
                if is_list_prop && item isa AbstractVector
                    # JSON-LD 1.1: nested arrays under a @list container
                    # become nested list objects (lists of lists)
                    push!(out, Dict{String,Any}("@list" => e))
                else
                    append!(out, e)
                end
            else
                push!(out, e)
            end
        end
        return out
    end
    if !(element isa AbstractDict)
        # Scalar: free-floating scalars are dropped
        (active_prop === nothing || active_prop == "@graph") && return nothing
        return _expand_scalar(active, active_prop, element)
    end
    # Map (node object or value object)
    # Revert to previous context for node objects when a non-propagating
    # (type-scoped) context is active (@propagate: false semantics)
    if !from_map && active.previous !== nothing && !haskey(element, "@value") &&
       !(length(element) == 1 && haskey(element, "@id"))
        active = active.previous
    end
    # Property-scoped context (propagates by default)
    if prop_td !== nothing && prop_td.has_context
        active = _process_context(active, prop_td.local_context, opts)
    end
    # The element's own @context
    if haskey(element, "@context")
        active = _process_context(active, element["@context"], opts)
    end
    # Type-scoped contexts (do not propagate by default)
    type_terms = String[]
    for k in keys(element)
        ek = _expand_iri(active, String(k); vocab=true)
        ek == "@type" || continue
        tv = element[k]
        for t in (tv isa AbstractVector ? tv : Any[tv])
            t isa AbstractString && push!(type_terms, String(t))
        end
    end
    for t in sort(type_terms)
        ttd = get(active.terms, t, nothing)
        if ttd !== nothing && ttd.has_context
            active = _process_context(active, ttd.local_context, opts; propagate=false)
        end
    end

    result = Dict{String,Any}()
    _expand_entries!(result, active, element, opts, active_prop)

    # @set: the expanded value of @set replaces the element
    haskey(result, "@set") && return result["@set"]
    if haskey(result, "@value")
        result["@value"] === nothing && return nothing
        if haskey(result, "@type") && result["@type"] isa AbstractVector
            tarr = result["@type"]
            isempty(tarr) ? delete!(result, "@type") : (result["@type"] = String(tarr[1]))
        end
        for k in collect(keys(result))
            k in ("@value", "@type", "@language", "@direction", "@index") || delete!(result, k)
        end
        return result
    end
    if haskey(result, "@type") && !(result["@type"] isa AbstractVector)
        result["@type"] = Any[result["@type"]]
    end
    length(result) == 1 && haskey(result, "@language") && return nothing
    isempty(result) && return nothing
    return result
end

"""Expand all entries of a map into `result` (also used to unfold @nest)."""
function _expand_entries!(result::Dict{String,Any}, active::JLDActiveContext,
                          element::AbstractDict, opts::JLDOptions, active_prop)
    for key in sort!(collect(String.(keys(element))))
        key == "@context" && continue
        value = element[key]
        expanded_key = _expand_iri(active, key; vocab=true)
        expanded_key === nothing && continue
        if _jld_is_keyword(expanded_key)
            _expand_keyword_entry!(result, active, expanded_key, value, opts, active_prop)
            continue
        end
        occursin(":", expanded_key) || continue   # non-IRI keys are dropped

        td = get(active.terms, key, nothing)
        term_active = active
        if td !== nothing && td.has_context
            # Property-scoped context applies while expanding this value
            term_active = _process_context(active, td.local_context, opts)
        end
        container = td === nothing ? _EMPTY_CONTAINER : td.container

        expanded_value = if value isa AbstractDict && "@language" in container
            _expand_language_map(term_active, td, value)
        elseif value isa AbstractDict &&
               ("@index" in container || "@id" in container || "@type" in container)
            _expand_index_map(term_active, key, td, value, opts, container)
        else
            _expand_element(term_active, key, value, opts)
        end
        expanded_value === nothing && continue

        if "@list" in container
            if !(expanded_value isa AbstractDict && haskey(expanded_value, "@list"))
                lv = expanded_value isa AbstractVector ? expanded_value : Any[expanded_value]
                if length(lv) == 1 && lv[1] isa AbstractDict && haskey(lv[1], "@list")
                    expanded_value = lv[1]
                else
                    expanded_value = Dict{String,Any}("@list" => lv)
                end
            end
        end

        if td !== nothing && td.reverse
            rev = get!(result, "@reverse", Dict{String,Any}())
            arr = get!(rev, expanded_key, Any[])
            for item in (expanded_value isa AbstractVector ? expanded_value : Any[expanded_value])
                if item isa AbstractDict && (haskey(item, "@value") || haskey(item, "@list"))
                    error("JSON-LD: invalid reverse property value (literals and lists cannot be reversed)")
                end
                push!(arr, item)
            end
        else
            arr = get!(result, expanded_key, Any[])
            expanded_value isa AbstractVector ? append!(arr, expanded_value) :
                push!(arr, expanded_value)
        end
    end
    return result
end

"""Handle an entry whose key expands to a JSON-LD keyword."""
function _expand_keyword_entry!(result::Dict{String,Any}, active::JLDActiveContext,
                                kw::String, value, opts::JLDOptions, active_prop)
    if kw == "@id"
        if value isa AbstractString
            e = _expand_iri(active, String(value); relative=true)
            e !== nothing && (result["@id"] = e)
        end
    elseif kw == "@type"
        vals = value isa AbstractVector ? value : Any[value]
        ts = Any[]
        for t in vals
            t isa AbstractString || continue
            et = _expand_iri(active, String(t); vocab=true, relative=true)
            et === nothing || push!(ts, et)
        end
        existing = get(result, "@type", Any[])
        existing isa AbstractVector || (existing = Any[existing])
        result["@type"] = vcat(existing, ts)
    elseif kw == "@value"
        result["@value"] = value isa Union{AbstractDict,AbstractVector} ? _to_plain(value) :
                           value isa AbstractString ? String(value) : value
    elseif kw == "@language"
        value isa AbstractString && (result["@language"] = lowercase(String(value)))
    elseif kw == "@direction"
        if value isa AbstractString && String(value) in ("ltr", "rtl")
            result["@direction"] = String(value)
        end
    elseif kw == "@index"
        value isa AbstractString && (result["@index"] = String(value))
    elseif kw == "@list"
        (active_prop === nothing || active_prop == "@graph") && return
        lst = _expand_element(active, active_prop, value, opts)
        lst === nothing && (lst = Any[])
        lst isa AbstractVector || (lst = Any[lst])
        result["@list"] = lst
    elseif kw == "@set"
        ev = _expand_element(active, active_prop, value, opts)
        ev === nothing && (ev = Any[])
        ev isa AbstractVector || (ev = Any[ev])
        result["@set"] = ev
    elseif kw == "@reverse"
        value isa AbstractDict || return
        rev = get!(result, "@reverse", Dict{String,Any}())
        for rk in sort!(collect(String.(keys(value))))
            rkx = _expand_iri(active, rk; vocab=true)
            (rkx === nothing || startswith(rkx, "@")) && continue
            rtd = get(active.terms, rk, nothing)
            rterm_active = active
            if rtd !== nothing && rtd.has_context
                rterm_active = _process_context(active, rtd.local_context, opts)
            end
            ev = _expand_element(rterm_active, rk, value[rk], opts)
            ev === nothing && continue
            arr = get!(rev, rkx, Any[])
            for item in (ev isa AbstractVector ? ev : Any[ev])
                if item isa AbstractDict && (haskey(item, "@value") || haskey(item, "@list"))
                    error("JSON-LD: invalid reverse property value (literals and lists cannot be reversed)")
                end
                push!(arr, item)
            end
        end
        isempty(rev) && delete!(result, "@reverse")
    elseif kw == "@graph"
        gv = _expand_element(active, "@graph", value, opts)
        gv === nothing && return
        gv isa AbstractVector || (gv = Any[gv])
        result["@graph"] = gv
    elseif kw == "@nest"
        vals = value isa AbstractVector ? value : Any[value]
        for nv in vals
            nv isa AbstractDict || error("JSON-LD: @nest value must be a map")
            haskey(nv, "@value") && error("JSON-LD: @nest value must not be a value object")
            _expand_entries!(result, active, nv, opts, active_prop)
        end
    end
    # @included, @version, @propagate, etc. are ignored
    return
end

"""Expand the values of a language map (@container: @language)."""
function _expand_language_map(active::JLDActiveContext, td, value::AbstractDict)
    items = Any[]
    for lk in sort!(collect(String.(keys(value))))
        lv = value[lk]
        kx = _expand_iri(active, lk; vocab=true)
        for s in (lv isa AbstractVector ? lv : Any[lv])
            s === nothing && continue
            s isa AbstractString ||
                error("JSON-LD: language map values must be strings")
            item = Dict{String,Any}("@value" => String(s))
            kx == "@none" || (item["@language"] = lowercase(lk))
            dir = (td !== nothing && td.has_direction) ? td.direction : active.direction
            dir !== nothing && (item["@direction"] = dir)
            push!(items, item)
        end
    end
    items
end

"""Expand the values of an index/id/type map (@container: @index/@id/@type)."""
function _expand_index_map(active::JLDActiveContext, key::String, td,
                           value::AbstractDict, opts::JLDOptions, container::Set{String})
    items = Any[]
    for ik in sort!(collect(String.(keys(value))))
        iv = value[ik]
        map_active = active
        if "@type" in container
            # The map key of a type map may itself have a scoped context
            iktd = get(active.terms, ik, nothing)
            if iktd !== nothing && iktd.has_context
                map_active = _process_context(active, iktd.local_context, opts;
                                              propagate=false)
            end
        end
        ev = _expand_element(map_active, key, iv, opts; from_map=true)
        ev === nothing && continue
        ev isa AbstractVector || (ev = Any[ev])
        ikx = _expand_iri(active, ik; vocab=true)
        for item in ev
            item isa AbstractDict || continue
            if "@index" in container
                if ikx != "@none" && !haskey(item, "@index")
                    item["@index"] = ik
                end
            elseif "@id" in container
                if ikx != "@none" && !haskey(item, "@id") && !haskey(item, "@value")
                    item["@id"] = _expand_iri(active, ik; relative=true)
                end
            elseif "@type" in container
                if ikx != "@none" && !haskey(item, "@value")
                    t = _expand_iri(active, ik; vocab=true, relative=true)
                    existing = get(item, "@type", Any[])
                    existing isa AbstractVector || (existing = Any[existing])
                    item["@type"] = vcat(Any[t], existing)
                end
            end
            push!(items, item)
        end
    end
    items
end

"""Value expansion of a scalar against the term definition of `prop`."""
function _expand_scalar(active::JLDActiveContext, prop::String, value)
    td = get(active.terms, prop, nothing)
    tm = td === nothing ? nothing : td.type_mapping
    if value isa AbstractString
        if tm == "@id"
            return Dict{String,Any}("@id" => _expand_iri(active, String(value); relative=true))
        elseif tm == "@vocab"
            return Dict{String,Any}("@id" => _expand_iri(active, String(value);
                                                         vocab=true, relative=true))
        end
    end
    res = Dict{String,Any}("@value" => value isa AbstractString ? String(value) : value)
    if tm !== nothing && !(tm in ("@id", "@vocab", "@none"))
        res["@type"] = tm           # includes "@json"
    elseif value isa AbstractString
        lang = (td !== nothing && td.has_language) ? td.language : active.language
        dir = (td !== nothing && td.has_direction) ? td.direction : active.direction
        lang !== nothing && (res["@language"] = lang)
        dir !== nothing && (res["@direction"] = dir)
    end
    res
end

# ─── Compaction ──────────────────────────────────────────────────────

"""
    jsonld_compact(input, context; base=nothing,
                   context_loader=_jsonld_default_loader,
                   compact_arrays=true)::Dict{String,Any}

Compact expanded JSON-LD using the provided context.
`input` can be a JSON string or a Vector/Dict of expanded nodes; `context` is
a context dict (optionally wrapped in `{"@context": ...}`).

Supported: term selection by IRI with container/type/language matching,
compact IRIs, `@vocab`-relative compaction, value compaction (dropping
`@value` wrappers when term coercions match), `@list` containers (bare
arrays), `@index`/`@language`/`@id`/`@type` container maps, reverse terms and
the `@reverse` keyword, `@nest` re-nesting, type-scoped contexts, and `@json`
literals. Keyword aliases are not used in output.
"""
function jsonld_compact(input, context; base=nothing,
                        context_loader=_jsonld_default_loader,
                        compact_arrays::Bool=true)::Dict{String,Any}
    nodes = if input isa AbstractString
        Any[n for n in jsonld_expand(input; base=base, context_loader=context_loader)]
    elseif input isa AbstractVector
        Any[_to_plain(n) for n in input]
    elseif input isa AbstractDict
        Any[_to_plain(input)]
    else
        error("jsonld_compact: unsupported input type $(typeof(input))")
    end
    opts = JLDOptions(context_loader, base === nothing ? nothing : String(base))
    raw_ctx = _to_plain(context)
    inner = raw_ctx isa AbstractDict && haskey(raw_ctx, "@context") ?
        raw_ctx["@context"] : raw_ctx
    active = _process_context(JLDActiveContext(opts.base), inner, opts)
    inv = _build_inverse(active)
    if length(nodes) == 1 && nodes[1] isa AbstractDict
        compacted = _compact_node(nodes[1], active, inv, opts, compact_arrays)
        compacted["@context"] = inner
        return compacted
    else
        out = Any[_compact_node(n, active, inv, opts, compact_arrays) for n in nodes]
        return Dict{String,Any}("@context" => inner, "@graph" => out)
    end
end

"""Build an inverse mapping from IRI to candidate (term, definition) pairs."""
function _build_inverse(active::JLDActiveContext)
    inv = Dict{String,Vector{Tuple{String,JLDTermDef}}}()
    for (term, td) in active.terms
        td.iri === nothing && continue
        push!(get!(inv, td.iri, Tuple{String,JLDTermDef}[]), (term, td))
    end
    for v in values(inv)
        sort!(v, by=x -> (length(x[1]), x[1]))
    end
    inv
end

"""Compact an IRI to a term, @vocab-relative suffix, or compact IRI."""
function _compact_iri(iri::String, active::JLDActiveContext, inv; vocab::Bool=true)
    startswith(iri, "@") && return iri
    startswith(iri, "_:") && return iri
    if vocab
        cands = get(inv, iri, nothing)
        if cands !== nothing
            for (term, td) in cands
                td.reverse && continue
                return term
            end
        end
        if active.vocab !== nothing && active.vocab != "" &&
           startswith(iri, active.vocab) && sizeof(iri) > sizeof(active.vocab)
            suffix = iri[sizeof(active.vocab)+1:end]
            haskey(active.terms, suffix) || return suffix
        end
    end
    best = nothing
    bestlen = 0
    for (term, td) in active.terms
        (td.iri === nothing || td.reverse || !td.prefix_flag) && continue
        occursin(":", term) && continue
        b = td.iri
        if startswith(iri, b) && sizeof(iri) > sizeof(b) && sizeof(b) > bestlen
            cand = term * ":" * iri[sizeof(b)+1:end]
            if !haskey(active.terms, cand) || active.terms[cand].iri == iri
                best = cand
                bestlen = sizeof(b)
            end
        end
    end
    best !== nothing && return best
    return iri
end

"""Select the best term for a property IRI given the expanded values."""
function _select_term(iri::String, vals, active::JLDActiveContext, inv;
                      reverse::Bool=false)
    cands = get(inv, iri, nothing)
    cands === nothing && return nothing
    best = nothing
    best_score = -1
    for (term, td) in cands
        td.reverse == reverse || continue
        s = _term_score(td, vals, active)
        s < 0 && continue
        if s > best_score
            best = term
            best_score = s
        end
    end
    best
end

"""Score how well a term definition fits the expanded values (-1 = unusable)."""
function _term_score(td::JLDTermDef, vals, active::JLDActiveContext)
    c = td.container
    all_lists = !isempty(vals) &&
        all(v -> v isa AbstractDict && haskey(v, "@list"), vals)
    if "@list" in c
        return (all_lists && length(vals) == 1) ? 30 : -1
    end
    if "@language" in c
        ok = all(v -> v isa AbstractDict && haskey(v, "@value") &&
                     v["@value"] isa AbstractString &&
                     !haskey(v, "@type") && !haskey(v, "@direction"), vals)
        ok || return -1
        return all(v -> haskey(v, "@language"), vals) ? 20 : 8
    end
    if "@index" in c
        all(v -> v isa AbstractDict, vals) || return -1
        return all(v -> haskey(v, "@index"), vals) ? 20 : 8
    end
    if "@id" in c
        ok = all(v -> v isa AbstractDict && !haskey(v, "@value") && !haskey(v, "@list"), vals)
        ok || return -1
        return all(v -> haskey(v, "@id"), vals) ? 20 : 8
    end
    if "@type" in c
        ok = all(v -> v isa AbstractDict && !haskey(v, "@value") && !haskey(v, "@list"), vals)
        ok || return -1
        return all(v -> !isempty(get(v, "@type", Any[])), vals) ? 20 : 8
    end
    score = 10
    if td.type_mapping !== nothing
        if td.type_mapping in ("@id", "@vocab")
            all(v -> v isa AbstractDict && haskey(v, "@id") && length(v) == 1, vals) &&
                (score += 3)
        elseif all(v -> v isa AbstractDict && get(v, "@type", nothing) == td.type_mapping, vals)
            score += 3
        end
    elseif td.has_language && td.language !== nothing
        all(v -> v isa AbstractDict && get(v, "@language", nothing) == td.language, vals) &&
            (score += 2)
    end
    "@set" in c && (score += 1)
    return score
end

"""Compact a single expanded node object."""
function _compact_node(node::AbstractDict, active::JLDActiveContext, inv,
                       opts::JLDOptions, compact_arrays::Bool)
    # Apply type-scoped contexts before compacting properties
    types = get(node, "@type", nothing)
    ctypes = String[]
    if types !== nothing
        tarr = types isa AbstractVector ? types : Any[types]
        ctypes = String[_compact_iri(String(t), active, inv) for t in tarr]
        for ct in sort(ctypes)
            ttd = get(active.terms, ct, nothing)
            if ttd !== nothing && ttd.has_context
                active = _process_context(active, ttd.local_context, opts; propagate=false)
                inv = _build_inverse(active)
            end
        end
    end
    result = Dict{String,Any}()
    if !isempty(ctypes)
        result["@type"] = (length(ctypes) == 1 && compact_arrays) ? ctypes[1] : ctypes
    end
    for key in sort!(collect(String.(keys(node))))
        key == "@type" && continue
        val = node[key]
        if key == "@id"
            result["@id"] = val isa AbstractString ?
                _compact_iri(String(val), active, inv; vocab=false) : val
            continue
        end
        if key == "@reverse"
            rev_out = Dict{String,Any}()
            for rk in sort!(collect(String.(keys(val))))
                rvals = val[rk]
                rvals isa AbstractVector || (rvals = Any[rvals])
                term = _select_term(rk, rvals, active, inv; reverse=true)
                if term !== nothing
                    _emit_property!(result, term, active.terms[term], rvals,
                                    active, inv, opts, compact_arrays)
                else
                    ck = _compact_iri(String(rk), active, inv)
                    cvals = Any[_compact_value_single(v, nothing, active, inv, opts,
                                                      compact_arrays) for v in rvals]
                    rev_out[ck] = (length(cvals) == 1 && compact_arrays) ? cvals[1] : cvals
                end
            end
            isempty(rev_out) || (result["@reverse"] = rev_out)
            continue
        end
        if key == "@graph"
            arr = val isa AbstractVector ? val : Any[val]
            result["@graph"] = Any[n isa AbstractDict ?
                _compact_node(n, active, inv, opts, compact_arrays) : n for n in arr]
            continue
        end
        if startswith(key, "@")
            result[key] = val
            continue
        end
        vals = val isa AbstractVector ? val : Any[val]
        term = _select_term(key, vals, active, inv; reverse=false)
        if term !== nothing
            _emit_property!(result, term, active.terms[term], vals, active, inv,
                            opts, compact_arrays)
        else
            ck = _compact_iri(key, active, inv)
            _emit_property!(result, ck, nothing, vals, active, inv, opts, compact_arrays)
        end
    end
    result
end

"""Insert a value into a container map, honoring array compaction."""
function _push_mapval!(m::Dict{String,Any}, k::String, v, scalarize::Bool)
    if haskey(m, k)
        ex = m[k]
        ex isa AbstractVector ? push!(ex, v) : (m[k] = Any[ex, v])
    else
        m[k] = scalarize ? v : Any[v]
    end
    return
end

"""Emit a compacted property (handling @nest and container maps)."""
function _emit_property!(result::Dict{String,Any}, ckey::String,
                         td::Union{JLDTermDef,Nothing}, vals,
                         active::JLDActiveContext, inv, opts::JLDOptions,
                         compact_arrays::Bool)
    target = result
    if td !== nothing && td.nest !== nothing
        nt = get(result, td.nest, nothing)
        if !(nt isa AbstractDict)
            nt = Dict{String,Any}()
            result[td.nest] = nt
        end
        target = nt
    end
    c = td === nothing ? _EMPTY_CONTAINER : td.container
    scalarize = compact_arrays && !("@set" in c)
    if "@language" in c
        m = Dict{String,Any}()
        for v in vals
            k = String(get(v, "@language", "@none"))
            _push_mapval!(m, k, v["@value"], scalarize)
        end
        target[ckey] = m
        return
    end
    if "@index" in c
        m = Dict{String,Any}()
        for v in vals
            k = String(get(v, "@index", "@none"))
            v2 = copy(v)
            delete!(v2, "@index")
            _push_mapval!(m, k, _compact_value_single(v2, td, active, inv, opts,
                                                      compact_arrays), scalarize)
        end
        target[ckey] = m
        return
    end
    if "@id" in c
        m = Dict{String,Any}()
        for v in vals
            k = haskey(v, "@id") ?
                _compact_iri(String(v["@id"]), active, inv; vocab=false) : "@none"
            v2 = copy(v)
            delete!(v2, "@id")
            _push_mapval!(m, k, _compact_node(v2, active, inv, opts, compact_arrays),
                          scalarize)
        end
        target[ckey] = m
        return
    end
    if "@type" in c
        m = Dict{String,Any}()
        for v in vals
            ts = get(v, "@type", Any[])
            ts isa AbstractVector || (ts = Any[ts])
            v2 = copy(v)
            if isempty(ts)
                k = "@none"
            else
                k = _compact_iri(String(ts[1]), active, inv)
                rest = Any[t for t in ts[2:end]]
                isempty(rest) ? delete!(v2, "@type") : (v2["@type"] = rest)
            end
            _push_mapval!(m, k, _compact_node(v2, active, inv, opts, compact_arrays),
                          scalarize)
        end
        target[ckey] = m
        return
    end
    if "@list" in c && length(vals) == 1 && vals[1] isa AbstractDict &&
       haskey(vals[1], "@list")
        lst = vals[1]["@list"]
        items = Any[_compact_value_single(it, td, active, inv, opts, compact_arrays)
                    for it in lst]
        if haskey(vals[1], "@index")
            target[ckey] = Dict{String,Any}("@list" => items,
                                            "@index" => vals[1]["@index"])
        else
            target[ckey] = items
        end
        return
    end
    compacted = Any[_compact_value_single(v, td, active, inv, opts, compact_arrays)
                    for v in vals]
    keep_array = !compact_arrays || (td !== nothing && ("@set" in c || "@list" in c))
    target[ckey] = (length(compacted) == 1 && !keep_array) ? compacted[1] : compacted
    return
end

"""Compact a single expanded value (value object, node, reference, or list)."""
function _compact_value_single(v, td::Union{JLDTermDef,Nothing},
                               active::JLDActiveContext, inv, opts::JLDOptions,
                               compact_arrays::Bool)
    v isa AbstractDict || return v
    if haskey(v, "@list")
        items = Any[_compact_value_single(it, td, active, inv, opts, compact_arrays)
                    for it in v["@list"]]
        out = Dict{String,Any}("@list" => items)
        haskey(v, "@index") && (out["@index"] = v["@index"])
        return out
    end
    if haskey(v, "@value")
        val = v["@value"]
        vtype = get(v, "@type", nothing)
        vlang = get(v, "@language", nothing)
        vdir = get(v, "@direction", nothing)
        vidx = get(v, "@index", nothing)
        tm = td === nothing ? nothing : td.type_mapping
        eff_lang = (td !== nothing && td.has_language) ? td.language : active.language
        eff_dir = (td !== nothing && td.has_direction) ? td.direction : active.direction
        if vidx === nothing
            if vtype == "@json"
                tm == "@json" && return val
            elseif vtype !== nothing
                vtype == tm && return val
            elseif vlang !== nothing
                (vlang == eff_lang && vdir == eff_dir) && return val
            else
                if val isa AbstractString
                    (eff_lang === nothing && eff_dir === nothing && tm === nothing) &&
                        return val
                else
                    (tm === nothing || tm in ("@id", "@vocab", "@none")) && return val
                end
            end
        end
        out = Dict{String,Any}("@value" => val)
        vtype !== nothing && (out["@type"] = vtype == "@json" ? "@json" :
                                             _compact_iri(String(vtype), active, inv))
        vlang !== nothing && (out["@language"] = vlang)
        vdir !== nothing && (out["@direction"] = vdir)
        vidx !== nothing && (out["@index"] = vidx)
        return out
    end
    if haskey(v, "@id") && length(v) == 1
        tm = td === nothing ? nothing : td.type_mapping
        if tm == "@id"
            return _compact_iri(String(v["@id"]), active, inv; vocab=false)
        elseif tm == "@vocab"
            return _compact_iri(String(v["@id"]), active, inv; vocab=true)
        end
        return Dict{String,Any}("@id" => _compact_iri(String(v["@id"]), active, inv;
                                                      vocab=false))
    end
    return _compact_node(v, active, inv, opts, compact_arrays)
end

# ─── Framing ─────────────────────────────────────────────────────────

"""
    jsonld_frame(input, frame::Dict{String, Any})::Dict{String, Any}

Frame JSON-LD data to match a template structure.

This implements a *basic subset* of JSON-LD Framing 1.1: node selection by
`@type`, inclusion of the properties listed in the frame, `@default` values,
and embedding of referenced nodes (`@embed` `"@always"`/`"@once"`/`"@never"`).
Not supported: `@explicit`, `@requireAll`, `@omitDefault`, `@embed` ids,
wildcard/value-pattern matching, recursive sub-frames, and `@reverse` framing.
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

    opts = JLDOptions(nothing)
    fc = get(frame, "@context", nothing)
    frame_active = fc === nothing ? JLDActiveContext(nothing) :
        _process_context(JLDActiveContext(nothing), _to_plain(fc), opts)

    target_type = get(frame, "@type", nothing)
    if target_type !== nothing
        tt = target_type isa AbstractVector ? target_type : [target_type]
        expanded_tt = String[]
        for t in tt
            t isa AbstractString || continue
            et = _expand_iri(frame_active, String(t); vocab=true)
            et === nothing || push!(expanded_tt, et)
        end
        target_type = expanded_tt
    end
    embed_mode = get(frame, "@embed", "@once")

    # Determine which frame properties to include
    frame_props = Set{String}()
    prop_map = Dict{String,String}()    # expanded -> frame key (for @default lookup)
    for k in keys(frame)
        startswith(k, "@") && continue
        ek = _expand_iri(frame_active, String(k); vocab=true)
        ek === nothing && continue
        push!(frame_props, ek)
        prop_map[ek] = String(k)
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
                fkey = get(prop_map, prop, prop)
                default_val = get(frame, fkey, get(frame, prop, nothing))
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
    jsonld_flatten(input; base=nothing,
                   context_loader=_jsonld_default_loader)::Dict{String,Any}

Flatten a JSON-LD document. All nodes are placed in a top-level `@graph` array,
blank nodes receive generated `@id` values, and nested nodes become references.
`@list` values are preserved in place (their node items become references) and
`@reverse` entries are converted into forward edges on the target nodes.
`input` may be a JSON string, a Dict, or a Vector of already-expanded nodes.
"""
function jsonld_flatten(input; base=nothing,
                        context_loader=_jsonld_default_loader)::Dict{String,Any}
    nodes = if input isa AbstractVector
        Any[_to_plain(n) for n in input]
    else
        Any[n for n in jsonld_expand(input; base=base, context_loader=context_loader)]
    end
    node_map = Dict{String,Dict{String,Any}}()
    _bnode_counter = Ref(0)

    for node in nodes
        node isa AbstractDict && _flatten_node!(node, node_map, _bnode_counter)
    end

    # Per the Flattening algorithm, nodes containing only @id are removed
    graph = [n for n in values(node_map) if length(n) > 1]
    isempty(graph) && (graph = collect(values(node_map)))
    sort!(graph, by=n -> get(n, "@id", ""))
    Dict{String,Any}("@graph" => graph)
end

"""Generate a fresh blank node ID."""
function _gen_bnode_id(counter::Ref{Int})
    counter[] += 1
    "_:b$(counter[])"
end

"""Flatten a node into the node_map; returns the node's @id."""
function _flatten_node!(node::AbstractDict, node_map::Dict{String,Dict{String,Any}},
                        counter::Ref{Int})::String
    id = get(node, "@id", nothing)
    id === nothing && (id = _gen_bnode_id(counter))
    id = String(id)
    entry = get!(node_map, id, Dict{String,Any}("@id" => id))

    for key in sort!(collect(String.(keys(node))))
        key == "@id" && continue
        val = node[key]
        if key == "@type"
            existing = get(entry, "@type", Any[])
            existing isa AbstractVector || (existing = Any[existing])
            new_types = val isa AbstractVector ? val : Any[val]
            entry["@type"] = unique(vcat(existing, new_types))
        elseif key == "@reverse"
            # Convert reverse edges into forward edges on the target nodes
            for (rprop, rvals) in val
                for rv in (rvals isa AbstractVector ? rvals : Any[rvals])
                    rv isa AbstractDict || continue
                    rid = _flatten_node!(rv, node_map, counter)
                    rentry = node_map[rid]
                    arr = get!(rentry, String(rprop), Any[])
                    arr isa AbstractVector || (arr = Any[arr]; rentry[String(rprop)] = arr)
                    ref = Dict{String,Any}("@id" => id)
                    ref in arr || push!(arr, ref)
                end
            end
        elseif key == "@graph"
            for n in (val isa AbstractVector ? val : Any[val])
                n isa AbstractDict && _flatten_node!(n, node_map, counter)
            end
        elseif startswith(key, "@")
            entry[key] = val
        else
            arr = get!(entry, key, Any[])
            arr isa AbstractVector || (arr = Any[arr]; entry[key] = arr)
            append!(arr, _flatten_values(val, node_map, counter))
        end
    end
    id
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
        haskey(val, "@value") && return Any[val]
        if haskey(val, "@list")
            items = Any[]
            for it in val["@list"]
                append!(items, _flatten_values(it, node_map, counter))
            end
            out = Dict{String,Any}("@list" => items)
            haskey(val, "@index") && (out["@index"] = val["@index"])
            return Any[out]
        end
        # Nested node — flatten it and return a reference
        rid = _flatten_node!(val, node_map, counter)
        return Any[Dict{String,Any}("@id" => rid)]
    else
        return Any[val]
    end
end
