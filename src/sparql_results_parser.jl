# ─── SPARQL Results Parsers ───────────────────────────────────────────
# Parse SPARQL query results in JSON, XML, CSV, and TSV formats back
# into Julia data structures (variable lists + binding vectors).

"""
    parse_sparql_results_json(json_str::AbstractString)

Parse a SPARQL Results JSON string (application/sparql-results+json) into
`(variables, results)` where `variables::Vector{String}` and
`results::Vector{Dict{String, Identifier}}`.
"""
function parse_sparql_results_json(json_str::AbstractString)
    obj = JSON.parse(json_str)
    head = get(obj, "head", Dict())
    vars = convert(Vector{String}, get(head, "vars", String[]))

    raw_bindings = get(get(obj, "results", Dict()), "bindings", [])
    results = Vector{Dict{String, Identifier}}()
    for binding in raw_bindings
        row = Dict{String, Identifier}()
        for (k, v) in binding
            row[k] = _json_term_to_identifier(v)
        end
        push!(results, row)
    end
    (vars, results)
end

function _json_term_to_identifier(v::AbstractDict)
    typ = get(v, "type", "")
    val = get(v, "value", "")
    if typ == "uri"
        return URIRef(val)
    elseif typ == "bnode"
        return BNode(val)
    elseif typ == "triple"
        # SPARQL 1.2 triple term: value is { subject, predicate, object }
        s = _json_term_to_identifier(val["subject"])
        p = _json_term_to_identifier(val["predicate"])
        o = _json_term_to_identifier(val["object"])
        return TripleTerm(s, p, o)
    elseif typ == "literal" || typ == "typed-literal"
        lang = get(v, "xml:lang", nothing)
        dir = get(v, "its:dir", nothing)
        dt_str = get(v, "datatype", nothing)
        dt = isnothing(dt_str) ? nothing : URIRef(dt_str)
        return Literal(val; datatype=dt, lang=lang, direction=dir)
    else
        return Literal(val)
    end
end

"""
    parse_sparql_ask_json(json_str::AbstractString) -> Bool

Parse a SPARQL ASK result in JSON format, returning the boolean answer.
"""
function parse_sparql_ask_json(json_str::AbstractString)
    obj = JSON.parse(json_str)
    return obj["boolean"]::Bool
end

# ─── XML parsing ─────────────────────────────────────────────────────

"""
    parse_sparql_results_xml(xml_str::AbstractString)

Parse a SPARQL Results XML string (application/sparql-results+xml) into
`(variables, results)` where `variables::Vector{String}` and
`results::Vector{Dict{String, Identifier}}`.
"""
function parse_sparql_results_xml(xml_str::AbstractString)
    doc = EzXML.parsexml(xml_str)
    root = EzXML.root(doc)
    ns = ["sr" => "http://www.w3.org/2005/sparql-results#"]

    # Extract variables from <head>
    vars = String[]
    for vnode in EzXML.findall("//sr:head/sr:variable", root, ns)
        push!(vars, vnode["name"])
    end

    # Extract result bindings
    results = Vector{Dict{String, Identifier}}()
    for rnode in EzXML.findall("//sr:results/sr:result", root, ns)
        row = Dict{String, Identifier}()
        for bnode in EzXML.findall("sr:binding", rnode, ns)
            name = bnode["name"]
            row[name] = _xml_binding_to_identifier(bnode, ns)
        end
        push!(results, row)
    end
    (vars, results)
end

function _xml_binding_to_identifier(bnode::EzXML.Node, ns)
    for child in EzXML.eachelement(bnode)
        v = _xml_node_to_identifier(child, ns)
        isnothing(v) || return v
    end
    error("No term found in binding element")
end

# Convert a single XML term element (<uri>/<bnode>/<literal>/<triple>) to an
# Identifier, or nothing if the element is not a recognised term.
function _xml_node_to_identifier(child::EzXML.Node, ns)
    tag = EzXML.nodename(child)
    if tag == "uri"
        return URIRef(EzXML.nodecontent(child))
    elseif tag == "bnode"
        return BNode(EzXML.nodecontent(child))
    elseif tag == "literal"
        val = EzXML.nodecontent(child)
        lang = nothing
        dir = nothing
        dt = nothing
        if EzXML.haskey(child, "xml:lang")
            lang = child["xml:lang"]
        elseif EzXML.haskey(child, "datatype")
            dt = URIRef(child["datatype"])
        end
        # SPARQL 1.2 base direction is carried in an its:dir attribute.
        if EzXML.haskey(child, "its:dir")
            dir = child["its:dir"]
        end
        return Literal(val; datatype=dt, lang=lang, direction=dir)
    elseif tag == "triple"
        s = p = o = nothing
        for part in EzXML.eachelement(child)
            ptag = EzXML.nodename(part)
            inner = nothing
            for sub in EzXML.eachelement(part)
                inner = _xml_node_to_identifier(sub, ns)
                inner === nothing || break
            end
            ptag == "subject"   && (s = inner)
            ptag == "predicate" && (p = inner)
            ptag == "object"    && (o = inner)
        end
        return TripleTerm(s, p, o)
    end
    return nothing
end

"""
    parse_sparql_ask_xml(xml_str::AbstractString) -> Bool

Parse a SPARQL ASK result in XML format, returning the boolean answer.
"""
function parse_sparql_ask_xml(xml_str::AbstractString)
    doc = EzXML.parsexml(xml_str)
    root = EzXML.root(doc)
    ns = ["sr" => "http://www.w3.org/2005/sparql-results#"]
    bool_nodes = EzXML.findall("//sr:boolean", root, ns)
    if isempty(bool_nodes)
        error("No <boolean> element found in SPARQL ASK XML result")
    end
    return strip(EzXML.nodecontent(bool_nodes[1])) == "true"
end

# ─── CSV parsing ─────────────────────────────────────────────────────

"""
    parse_sparql_results_csv(csv_str::AbstractString)

Parse a SPARQL Results CSV string into `(variables, results)`.

CSV format is lossy: URIs appear as bare strings, blank nodes as `_:id`,
and literals as plain values. This parser heuristically reconstructs types:
values starting with `http://` or `https://` → URIRef, `_:` → BNode,
otherwise → Literal.
"""
function parse_sparql_results_csv(csv_str::AbstractString)
    lines = split(rstrip(csv_str), '\n')
    isempty(lines) && return (String[], Vector{Dict{String, Identifier}}())

    # Parse header
    vars = String[strip(v) for v in split(lines[1], ',')]

    results = Vector{Dict{String, Identifier}}()
    for i in 2:length(lines)
        line = strip(lines[i])
        isempty(line) && continue
        fields = _csv_split(line)
        row = Dict{String, Identifier}()
        for (j, v) in enumerate(vars)
            j > length(fields) && break
            val = strip(fields[j])
            isempty(val) && continue
            row[v] = _csv_value_to_identifier(val)
        end
        push!(results, row)
    end
    (vars, results)
end

function _csv_split(line::AbstractString)
    fields = String[]
    buf = IOBuffer()
    in_quotes = false
    i = 1
    chars = collect(line)
    while i <= length(chars)
        c = chars[i]
        if in_quotes
            if c == '"'
                if i < length(chars) && chars[i+1] == '"'
                    write(buf, '"')
                    i += 1
                else
                    in_quotes = false
                end
            else
                write(buf, c)
            end
        else
            if c == '"'
                in_quotes = true
            elseif c == ','
                push!(fields, String(take!(buf)))
            else
                write(buf, c)
            end
        end
        i += 1
    end
    push!(fields, String(take!(buf)))
    fields
end

function _csv_value_to_identifier(val::AbstractString)
    if startswith(val, "http://") || startswith(val, "https://") || startswith(val, "urn:")
        return URIRef(val)
    elseif startswith(val, "_:")
        return BNode(val[3:end])
    else
        return Literal(val)
    end
end

# ─── TSV parsing ─────────────────────────────────────────────────────

"""
    parse_sparql_results_tsv(tsv_str::AbstractString)

Parse a SPARQL Results TSV string into `(variables, results)`.

TSV format preserves term types: URIs as `<uri>`, blank nodes as `_:id`,
literals in N3 notation (`"value"@lang` or `"value"^^<datatype>`).
"""
function parse_sparql_results_tsv(tsv_str::AbstractString)
    lines = split(rstrip(tsv_str), '\n')
    isempty(lines) && return (String[], Vector{Dict{String, Identifier}}())

    # Parse header — variables prefixed with ?
    header = split(lines[1], '\t')
    vars = String[replace(strip(v), r"^\?" => "") for v in header]

    results = Vector{Dict{String, Identifier}}()
    for i in 2:length(lines)
        line = lines[i]
        isempty(strip(line)) && continue
        fields = split(line, '\t')
        row = Dict{String, Identifier}()
        for (j, v) in enumerate(vars)
            j > length(fields) && break
            val = strip(fields[j])
            isempty(val) && continue
            row[v] = _tsv_value_to_identifier(val)
        end
        push!(results, row)
    end
    (vars, results)
end

function _tsv_value_to_identifier(val::AbstractString)
    # <uri>
    if startswith(val, '<') && endswith(val, '>')
        return URIRef(val[2:end-1])
    end
    # _:bnodeid
    if startswith(val, "_:")
        return BNode(val[3:end])
    end
    # N3 literal: "lexical"@lang or "lexical"^^<datatype> or "lexical"
    if startswith(val, '"')
        return _parse_n3_literal(val)
    end
    # Fallback
    return Literal(val)
end

function _parse_n3_literal(val::AbstractString)
    # Find the closing quote (handling escaped quotes)
    i = 2  # start after opening quote
    chars = collect(val)
    buf = IOBuffer()
    while i <= length(chars)
        c = chars[i]
        if c == '\\' && i < length(chars)
            nc = chars[i+1]
            if nc == '"'
                write(buf, '"')
            elseif nc == '\\'
                write(buf, '\\')
            elseif nc == 'n'
                write(buf, '\n')
            elseif nc == 'r'
                write(buf, '\r')
            elseif nc == 't'
                write(buf, '\t')
            else
                write(buf, '\\')
                write(buf, nc)
            end
            i += 2
            continue
        elseif c == '"'
            # End of lexical value
            lexical = String(take!(buf))
            rest = String(chars[i+1:end])
            if startswith(rest, "@")
                return Literal(lexical; lang=rest[2:end])
            elseif startswith(rest, "^^<") && endswith(rest, ">")
                dt = URIRef(rest[4:end-1])
                return Literal(lexical; datatype=dt)
            else
                return Literal(lexical)
            end
        else
            write(buf, c)
        end
        i += 1
    end
    # Fallback: treat whole thing as literal value
    return Literal(val)
end
