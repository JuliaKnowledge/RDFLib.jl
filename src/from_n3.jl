# Parse N3 notation strings back to RDF terms

const _COMMON_PREFIXES = Dict{String, String}(
    "xsd:" => "http://www.w3.org/2001/XMLSchema#",
    "rdf:" => "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    "rdfs:" => "http://www.w3.org/2000/01/rdf-schema#",
    "owl:" => "http://www.w3.org/2002/07/owl#",
    "skos:" => "http://www.w3.org/2004/02/skos/core#",
)

"""
    from_n3(s::AbstractString) -> Identifier

Parse an N3 notation string into an RDF term.

Supported formats:
- `<http://example.org/x>` → URIRef
- `_:b1` → BNode
- `"hello"` → Literal (plain)
- `"hello"@en` → Literal with language tag
- `"42"^^<http://www.w3.org/2001/XMLSchema#integer>` → Literal with datatype
- `"true"^^xsd:boolean` → Literal with common prefix datatype
"""
function from_n3(s::AbstractString)
    s = strip(s)
    isempty(s) && throw(ArgumentError("Empty N3 string"))

    # URI: <...>
    if startswith(s, "<") && endswith(s, ">")
        return URIRef(s[2:end-1])
    end

    # Blank node: _:id
    if startswith(s, "_:")
        return BNode(s[3:end])
    end

    # Literal: "..."
    if startswith(s, "\"")
        return _parse_from_n3_literal(s)
    end

    throw(ArgumentError("Cannot parse N3 string: $s"))
end

function _parse_from_n3_literal(s::AbstractString)
    # Find the closing quote (handle escaped quotes)
    i = 2
    while i <= length(s)
        if s[i] == '\\' && i < length(s)
            i += 2
            continue
        end
        if s[i] == '"'
            break
        end
        i += 1
    end
    i > length(s) && throw(ArgumentError("Unterminated literal: $s"))

    lexical = _unescape_n3(s[2:i-1])
    rest = s[i+1:end]

    if startswith(rest, "@")
        return Literal(lexical; lang=rest[2:end])
    elseif startswith(rest, "^^")
        dt_str = rest[3:end]
        if startswith(dt_str, "<") && endswith(dt_str, ">")
            return Literal(lexical; datatype=URIRef(dt_str[2:end-1]))
        else
            # Try common prefixes
            for (prefix, uri) in _COMMON_PREFIXES
                if startswith(dt_str, prefix)
                    return Literal(lexical; datatype=URIRef(uri * dt_str[length(prefix)+1:end]))
                end
            end
            throw(ArgumentError("Unknown prefix in datatype: $dt_str"))
        end
    else
        return Literal(lexical)
    end
end

function _unescape_n3(s::AbstractString)
    s = replace(s, "\\\"" => "\"")
    s = replace(s, "\\\\" => "\\")
    s = replace(s, "\\n" => "\n")
    s = replace(s, "\\r" => "\r")
    s = replace(s, "\\t" => "\t")
    s
end

"""
    to_term(s::AbstractString) -> Identifier

Alias for `from_n3`. Parse an N3 notation string into an RDF term.
"""
const to_term = from_n3
