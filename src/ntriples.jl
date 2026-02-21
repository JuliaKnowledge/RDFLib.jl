# ─── N-Triples Format ───────────────────────────────────────────────
# Simplest RDF serialization: one triple per line as
#   <subject> <predicate> <object> .

# ─── Serialization ──────────────────────────────────────────────────

"""
    serialize_ntriples(io::IO, g::RDFGraph)

Write graph as N-Triples to an IO stream.
"""
function serialize_ntriples(io::IO, g::RDFGraph)
    for t in g
        write(io, _nt_term(t.subject))
        write(io, " ")
        write(io, _nt_term(t.predicate))
        write(io, " ")
        write(io, _nt_term(t.object))
        write(io, " .\n")
    end
end

_nt_term(u::URIRef) = n3(u)
_nt_term(b::BNode) = n3(b)
_nt_term(l::Literal) = n3(l)

"""
    serialize_ntriples(g::RDFGraph) -> String

Serialize graph to N-Triples string.
"""
function serialize_ntriples(g::RDFGraph)
    buf = IOBuffer()
    serialize_ntriples(buf, g)
    String(take!(buf))
end

# ─── Parsing ────────────────────────────────────────────────────────

# Regex patterns for N-Triples terms
const _NT_URIREF = r"<([^>]*)>"
const _NT_BNODE = r"_:([A-Za-z0-9_]+)"
const _NT_LITERAL = r"\"((?:[^\"\\]|\\.)*)\"(?:@([a-zA-Z\-]+)|\^\^<([^>]*)>)?"
const _NT_LINE = r"^\s*((?:<[^>]*>)|(?:_:[A-Za-z0-9_]+))\s+((?:<[^>]*>))\s+((?:<[^>]*>)|(?:_:[A-Za-z0-9_]+)|(?:\"(?:[^\"\\]|\\.)*\"(?:@[a-zA-Z\-]+|\^\^<[^>]*>)?))\s*\.\s*$"

"""
    parse_ntriples!(g::RDFGraph, io::IO) -> RDFGraph

Parse N-Triples from an IO stream and add triples to the graph.
"""
function parse_ntriples!(g::RDFGraph, io::IO)
    for line in eachline(io)
        stripped = strip(line)
        isempty(stripped) && continue
        startswith(stripped, '#') && continue  # comment

        m = match(_NT_LINE, stripped)
        if isnothing(m)
            @warn "Skipping invalid N-Triples line: $stripped"
            continue
        end

        subj = _parse_nt_node(m.captures[1])
        pred_match = match(_NT_URIREF, m.captures[2])
        pred = URIRef(pred_match.captures[1])
        obj = _parse_nt_object(m.captures[3])

        add!(g, Triple(subj, pred, obj))
    end
    g
end

"""
    parse_ntriples!(g::RDFGraph, s::AbstractString) -> RDFGraph

Parse N-Triples from a string.
"""
function parse_ntriples!(g::RDFGraph, s::AbstractString)
    parse_ntriples!(g, IOBuffer(s))
end

"""
    parse_ntriples(io_or_string) -> RDFGraph

Parse N-Triples into a new graph.
"""
function parse_ntriples(source)
    g = RDFGraph()
    parse_ntriples!(g, source)
end

function _parse_nt_node(s::AbstractString)
    m = match(_NT_URIREF, s)
    !isnothing(m) && return URIRef(m.captures[1])
    m = match(_NT_BNODE, s)
    !isnothing(m) && return BNode(m.captures[1])
    throw(ArgumentError("Invalid N-Triples node: $s"))
end

function _parse_nt_object(s::AbstractString)
    # Check literal first (starts with ")
    if startswith(s, '"')
        m = match(_NT_LITERAL, s)
        if !isnothing(m)
            lexical = _unescape_ntriples(m.captures[1])
            lang_tag = m.captures[2]
            dt = m.captures[3]
            if !isnothing(lang_tag)
                return Literal(lexical, lang=lang_tag)
            elseif !isnothing(dt)
                return Literal(lexical, datatype=URIRef(dt))
            else
                return Literal(lexical)
            end
        end
    end
    m = match(_NT_URIREF, s)
    !isnothing(m) && return URIRef(m.captures[1])
    m = match(_NT_BNODE, s)
    !isnothing(m) && return BNode(m.captures[1])
    throw(ArgumentError("Invalid N-Triples object: $s"))
end

function _unescape_ntriples(s::AbstractString)
    buf = IOBuffer()
    i = firstindex(s)
    while i <= lastindex(s)
        c = s[i]
        if c == '\\' && i < lastindex(s)
            next = s[nextind(s, i)]
            if next == 'n'
                write(buf, '\n')
                i = nextind(s, nextind(s, i))
            elseif next == 'r'
                write(buf, '\r')
                i = nextind(s, nextind(s, i))
            elseif next == 't'
                write(buf, '\t')
                i = nextind(s, nextind(s, i))
            elseif next == '\\'
                write(buf, '\\')
                i = nextind(s, nextind(s, i))
            elseif next == '"'
                write(buf, '"')
                i = nextind(s, nextind(s, i))
            elseif next == 'u'
                # \uXXXX
                hex = s[nextind(s, i, 2):nextind(s, i, 5)]
                write(buf, Char(parse(UInt32, hex, base=16)))
                i = nextind(s, i, 6)
            elseif next == 'U'
                # \UXXXXXXXX
                hex = s[nextind(s, i, 2):nextind(s, i, 9)]
                write(buf, Char(parse(UInt32, hex, base=16)))
                i = nextind(s, i, 10)
            else
                write(buf, c)
                i = nextind(s, i)
            end
        else
            write(buf, c)
            i = nextind(s, i)
        end
    end
    String(take!(buf))
end
