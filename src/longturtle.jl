# ─── Long Turtle Format ───────────────────────────────────────────────
# Verbose Turtle: one triple per line, full URIs, no prefixes or grouping.
# Useful for diffs and line-oriented tooling.

"""
    serialize_longturtle(g::RDFGraph) -> String

Serialize a graph to Long Turtle format: one triple per line with full URIs.
"""
function serialize_longturtle(g::RDFGraph)
    buf = IOBuffer()
    for t in g
        write(buf, _longturtle_term(t.subject))
        write(buf, " ")
        write(buf, _longturtle_term(t.predicate))
        write(buf, " ")
        write(buf, _longturtle_term(t.object))
        write(buf, " .\n")
    end
    String(take!(buf))
end

_longturtle_term(u::URIRef) = "<" * u.value * ">"
_longturtle_term(b::BNode) = "_:" * b.id

function _longturtle_term(lit::Literal)
    escaped = _lt_escape(lit.lexical)
    s = "\"" * escaped * "\""
    if !isnothing(lit.language)
        s *= "@" * lit.language
    elseif !isnothing(lit.datatype)
        s *= "^^<" * lit.datatype.value * ">"
    end
    s
end

function _lt_escape(s::AbstractString)
    buf = IOBuffer()
    for c in s
        if c == '\\'
            write(buf, "\\\\")
        elseif c == '"'
            write(buf, "\\\"")
        elseif c == '\n'
            write(buf, "\\n")
        elseif c == '\r'
            write(buf, "\\r")
        elseif c == '\t'
            write(buf, "\\t")
        else
            write(buf, c)
        end
    end
    String(take!(buf))
end
