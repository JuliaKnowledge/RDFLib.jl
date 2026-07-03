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
    io = IOBuffer()
    i = nextind(s, firstindex(s))
    closed = false
    while i <= lastindex(s)
        c = s[i]
        if c == '"'
            i = nextind(s, i)
            closed = true
            break
        elseif c == '\\'
            i = _unescape_n3!(io, s, i)
        else
            write(io, c)
            i = nextind(s, i)
        end
    end
    closed || throw(ArgumentError("Unterminated literal: $s"))

    lexical = String(take!(io))
    if i > lastindex(s)
        return Literal(lexical)
    end

    rest = String(SubString(s, i))
    if startswith(rest, "@")
        m = match(r"^@([A-Za-z]+(?:-[A-Za-z0-9]+)*)(?:--(ltr|rtl))?$", rest)
        isnothing(m) && throw(ArgumentError("Invalid language suffix in N3 literal: $s"))
        return Literal(lexical; lang=m.captures[1], direction=m.captures[2])
    elseif startswith(rest, "^^")
        dt_str = rest[3:end]
        if startswith(dt_str, "<") && endswith(dt_str, ">")
            end_idx = prevind(dt_str, lastindex(dt_str))
            return Literal(lexical; datatype=URIRef(String(SubString(dt_str, nextind(dt_str, firstindex(dt_str)), end_idx))))
        else
            for (prefix, uri) in _COMMON_PREFIXES
                if startswith(dt_str, prefix)
                    local_name = dt_str[length(prefix)+1:end]
                    isempty(local_name) && break
                    return Literal(lexical; datatype=URIRef(uri * local_name))
                end
            end
            throw(ArgumentError("Unknown prefix in datatype: $dt_str"))
        end
    end
    throw(ArgumentError("Trailing garbage after N3 literal: $s"))
end

function _unescape_n3(s::AbstractString)
    io = IOBuffer()
    i = firstindex(s)
    while i <= lastindex(s)
        if s[i] == '\\'
            i = _unescape_n3!(io, s, i)
        else
            write(io, s[i])
            i = nextind(s, i)
        end
    end
    String(take!(io))
end

function _unescape_n3!(io::IOBuffer, s::AbstractString, slash_idx::Int)
    i = nextind(s, slash_idx)
    i <= lastindex(s) || throw(ArgumentError("Trailing backslash in N3 literal"))
    esc = s[i]
    if esc == '"' || esc == '\\' || esc == '\''
        write(io, esc)
        return nextind(s, i)
    elseif esc == 'n'
        write(io, '\n')
        return nextind(s, i)
    elseif esc == 'r'
        write(io, '\r')
        return nextind(s, i)
    elseif esc == 't'
        write(io, '\t')
        return nextind(s, i)
    elseif esc == 'b'
        write(io, '\b')
        return nextind(s, i)
    elseif esc == 'f'
        write(io, '\f')
        return nextind(s, i)
    elseif esc == 'u' || esc == 'U'
        digits = esc == 'u' ? 4 : 8
        j = nextind(s, i)
        hex = IOBuffer()
        for _ in 1:digits
            j <= lastindex(s) || throw(ArgumentError("Truncated Unicode escape in N3 literal"))
            ch = s[j]
            isxdigit(ch) || throw(ArgumentError("Invalid Unicode escape in N3 literal"))
            write(hex, ch)
            j = nextind(s, j)
        end
        codepoint = parse(UInt32, String(take!(hex)); base=16)
        write(io, Char(codepoint))
        return j
    end
    throw(ArgumentError("Invalid escape sequence \\$esc in N3 literal"))
end

"""
    to_term(s::AbstractString) -> Identifier

Alias for `from_n3`. Parse an N3 notation string into an RDF term.
"""
const to_term = from_n3
