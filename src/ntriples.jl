# ─── N-Triples Format ───────────────────────────────────────────────
# Simplest RDF serialization: one triple per line as
#   <subject> <predicate> <object> .
# Supports RDF 1.2 / SPARQL 1.2 extensions:
#   - directional language-tagged strings:  "x"@en--ltr
#   - triple terms (RDF-star):              << <s> <p> <o> >>

# ─── Serialization ──────────────────────────────────────────────────

"""
    serialize_ntriples(io::IO, g::RDFGraph)

Write graph as N-Triples to an IO stream.
"""
function serialize_ntriples(io::IO, g::RDFGraph)
    for t in g
        _validate_rdf_serializable(t)
        write(io, _nt_term(t.subject))
        write(io, " ")
        write(io, _nt_term(t.predicate))
        write(io, " ")
        write(io, _nt_term(t.object))
        write(io, " .\n")
    end
end

_nt_term(u::URIRef) = string("<", _nt_escape_iri(u.value), ">")
_nt_term(b::BNode) = n3(b)

function _nt_term(l::Literal)
    s = string("\"", _nt_escape_string(l.lexical), "\"")
    if !isnothing(l.language)
        s *= "@" * l.language
        if !isnothing(l.direction)
            s *= "--" * l.direction
        end
    elseif !isnothing(l.datatype)
        s *= "^^" * _nt_term(l.datatype)
    end
    s
end

function _nt_term(tt::TripleTerm)
    string("<<( ", _nt_term(tt.subject), " ", _nt_term(tt.predicate), " ",
           _nt_term(tt.object), " )>>")
end

# Characters that may not appear raw inside an IRIREF per the N-Triples
# grammar: #x00-#x20, <, >, ", {, }, |, ^, `, \.  They are written using
# UCHAR (\u00XX) escapes, which the grammar permits inside IRIREF.
_nt_iri_char_needs_escape(c::Char) =
    UInt32(c) <= 0x20 || c == '<' || c == '>' || c == '"' ||
    c == '{' || c == '}' || c == '|' || c == '^' || c == '`' || c == '\\' ||
    UInt32(c) == 0x7F

function _nt_escape_iri(s::AbstractString)
    any(_nt_iri_char_needs_escape, s) || return String(s)
    buf = IOBuffer(sizehint=sizeof(s) + 16)
    for c in s
        if _nt_iri_char_needs_escape(c)
            print(buf, "\\u", uppercase(string(UInt32(c), base=16, pad=4)))
        else
            write(buf, c)
        end
    end
    String(take!(buf))
end

function _nt_escape_string(s::AbstractString)
    needs_escape = false
    for c in s
        if c == '\\' || c == '"' || UInt32(c) < 0x20 || UInt32(c) == 0x7F
            needs_escape = true
            break
        end
    end
    needs_escape || return String(s)

    buf = IOBuffer(sizehint=sizeof(s) + 16)
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
        elseif c == '\b'
            write(buf, "\\b")
        elseif c == '\f'
            write(buf, "\\f")
        elseif UInt32(c) < 0x20 || UInt32(c) == 0x7F
            print(buf, "\\u", uppercase(string(UInt32(c), base=16, pad=4)))
        else
            write(buf, c)
        end
    end
    String(take!(buf))
end

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

# Regex patterns kept for line-oriented fast paths (e.g. chunk_serializer.jl).
# Built from the full N-Triples grammar productions.
# Note: ranges use literal (Julia-escaped) characters because Julia's PCRE
# options (ALT_BSUX) do not support the \x{...} regex escape form.
const _PN_CHARS_BASE_RC = "A-Za-zÀ-ÖØ-öø-˿Ͱ-ͽͿ-῿‌-‍⁰-↏Ⰰ-⿯、-퟿豈-﷏ﷰ-�\U00010000-\U000EFFFF"
const _PN_CHARS_U_RC = _PN_CHARS_BASE_RC * "_"
const _PN_CHARS_RC = _PN_CHARS_U_RC * "\\-0-9·̀-ͯ‿-⁀"
const _NT_BNODE_PAT = "_:[$(_PN_CHARS_U_RC)0-9](?:[$(_PN_CHARS_RC).]*[$(_PN_CHARS_RC)])?"
const _NT_IRI_PAT = "<(?:[^\\x00-\\x20<>\"{}|^`\\\\]|\\\\u[0-9A-Fa-f]{4}|\\\\U[0-9A-Fa-f]{8})*>"
const _NT_LANGDIR_PAT = "@[a-zA-Z]+(?:-[a-zA-Z0-9]+)*(?:--(?:ltr|rtl))?"
const _NT_STRING_PAT = "\"(?:[^\"\\\\]|\\\\.)*\""
const _NT_LITERAL_PAT = "$(_NT_STRING_PAT)(?:$(_NT_LANGDIR_PAT)|\\^\\^$(_NT_IRI_PAT))?"

const _NT_URIREF = r"<([^>]*)>"
const _NT_BNODE = Regex("(" * _NT_BNODE_PAT * ")")
const _NT_LITERAL = Regex("\"((?:[^\"\\\\]|\\\\.)*)\"(?:@([a-zA-Z\\-0-9]+)|\\^\\^<([^>]*)>)?")
const _NT_LINE = Regex("^\\s*($(_NT_IRI_PAT)|$(_NT_BNODE_PAT))\\s*($(_NT_IRI_PAT))\\s*($(_NT_IRI_PAT)|$(_NT_BNODE_PAT)|$(_NT_LITERAL_PAT))\\s*\\.\\s*(?:#.*)?\$")

# ─── Character-level statement parser ───────────────────────────────

mutable struct _NTCursor
    s::String
    pos::Int
    lineno::Int
    fmt::String
end

@inline _nt_eof(c::_NTCursor) = c.pos > lastindex(c.s)

@inline function _nt_peek(c::_NTCursor)
    _nt_eof(c) ? '\0' : c.s[c.pos]
end

@inline function _nt_next!(c::_NTCursor)
    ch = c.s[c.pos]
    c.pos = nextind(c.s, c.pos)
    ch
end

function _nt_error(c::_NTCursor, msg::AbstractString)
    loc = c.lineno > 0 ? " at line $(c.lineno)" : ""
    throw(ArgumentError("$(c.fmt) parse error$loc: $msg"))
end

function _nt_skip_ws!(c::_NTCursor)
    while !_nt_eof(c)
        ch = c.s[c.pos]
        (ch == ' ' || ch == '\t' || ch == '\r') || break
        c.pos = nextind(c.s, c.pos)
    end
end

# PN_CHARS character classes (Turtle/N-Triples grammar).
# Prefixed `_nt_` to avoid clashing with the Turtle parser's equivalents.
function _nt_is_pn_chars_base(ch::Char)
    ('A' <= ch <= 'Z') && return true
    ('a' <= ch <= 'z') && return true
    cp = UInt32(ch)
    (0x00C0 <= cp <= 0x00D6) || (0x00D8 <= cp <= 0x00F6) ||
        (0x00F8 <= cp <= 0x02FF) || (0x0370 <= cp <= 0x037D) ||
        (0x037F <= cp <= 0x1FFF) || (0x200C <= cp <= 0x200D) ||
        (0x2070 <= cp <= 0x218F) || (0x2C00 <= cp <= 0x2FEF) ||
        (0x3001 <= cp <= 0xD7FF) || (0xF900 <= cp <= 0xFDCF) ||
        (0xFDF0 <= cp <= 0xFFFD) || (0x10000 <= cp <= 0xEFFFF)
end

_nt_is_pn_chars_u(ch::Char) = ch == '_' || _nt_is_pn_chars_base(ch)

function _nt_is_pn_chars(ch::Char)
    _nt_is_pn_chars_u(ch) && return true
    ch == '-' && return true
    ('0' <= ch <= '9') && return true
    cp = UInt32(ch)
    cp == 0x00B7 || (0x0300 <= cp <= 0x036F) || (0x203F <= cp <= 0x2040)
end

"""
Decode `n` hex digits of a `\\u`/`\\U` escape. The cursor is positioned at the
first hex digit. Throws a clean parse error on truncation, invalid hex digits,
surrogate code points (U+D800–U+DFFF), and out-of-range code points.
"""
function _nt_read_uchar!(c::_NTCursor, kind::Char)
    n = kind == 'u' ? 4 : 8
    v = UInt32(0)
    for _ in 1:n
        _nt_eof(c) && _nt_error(c, "truncated \\$kind escape sequence")
        ch = _nt_next!(c)
        d = if '0' <= ch <= '9'
            UInt32(ch) - UInt32('0')
        elseif 'a' <= ch <= 'f'
            UInt32(ch) - UInt32('a') + 0xA
        elseif 'A' <= ch <= 'F'
            UInt32(ch) - UInt32('A') + 0xA
        else
            _nt_error(c, "invalid hex digit '$ch' in \\$kind escape sequence")
        end
        v = v * UInt32(16) + d
    end
    (0xD800 <= v <= 0xDFFF) &&
        _nt_error(c, "surrogate code point U+$(uppercase(string(v, base=16, pad=4))) is not allowed in \\$kind escape")
    v > 0x10FFFF &&
        _nt_error(c, "code point U+$(uppercase(string(v, base=16))) out of Unicode range in \\$kind escape")
    Char(v)
end

# An absolute IRI must begin with a scheme: ALPHA *( ALPHA / DIGIT / "+" /
# "-" / "." ) ":".  N-Triples and N-Quads forbid relative IRIs.
function _nt_is_absolute_iri(s::AbstractString)
    isempty(s) && return false
    i = firstindex(s)
    c = s[i]
    (('A' <= c <= 'Z') || ('a' <= c <= 'z')) || return false
    i = nextind(s, i)
    while i <= lastindex(s)
        c = s[i]
        if c == ':'
            return true
        elseif ('A' <= c <= 'Z') || ('a' <= c <= 'z') || ('0' <= c <= '9') ||
               c == '+' || c == '-' || c == '.'
            i = nextind(s, i)
        else
            return false
        end
    end
    false
end

"Parse an IRIREF; the cursor is positioned at `<`. Decodes \\u/\\U escapes."
function _nt_parse_iriref!(c::_NTCursor)
    _nt_next!(c)  # consume '<'
    buf = IOBuffer()
    while true
        _nt_eof(c) && _nt_error(c, "unterminated IRI reference")
        ch = _nt_next!(c)
        if ch == '>'
            iri = String(take!(buf))
            _nt_is_absolute_iri(iri) ||
                _nt_error(c, "relative IRI <$iri> is not allowed (an absolute IRI with a scheme is required)")
            return URIRef(iri)
        elseif ch == '\\'
            _nt_eof(c) && _nt_error(c, "truncated escape sequence in IRI reference")
            esc = _nt_next!(c)
            (esc == 'u' || esc == 'U') ||
                _nt_error(c, "illegal escape '\\$esc' in IRI reference (only \\u/\\U are allowed)")
            write(buf, _nt_read_uchar!(c, esc))
        elseif UInt32(ch) <= 0x20 || ch == '<' || ch == '"' || ch == '{' ||
               ch == '}' || ch == '|' || ch == '^' || ch == '`'
            _nt_error(c, "illegal character $(repr(ch)) in IRI reference")
        else
            write(buf, ch)
        end
    end
end

"Parse a BLANK_NODE_LABEL; the cursor is positioned at `_`."
function _nt_parse_bnode!(c::_NTCursor)
    _nt_next!(c)  # consume '_'
    (_nt_eof(c) || _nt_next!(c) != ':') &&
        _nt_error(c, "invalid blank node label (expected '_:')")
    _nt_eof(c) && _nt_error(c, "invalid blank node label (empty label)")
    first_ch = _nt_peek(c)
    (_nt_is_pn_chars_u(first_ch) || ('0' <= first_ch <= '9')) ||
        _nt_error(c, "invalid first character $(repr(first_ch)) in blank node label")
    start = c.pos
    c.pos = nextind(c.s, c.pos)
    while !_nt_eof(c)
        ch = c.s[c.pos]
        (_nt_is_pn_chars(ch) || ch == '.') || break
        c.pos = nextind(c.s, c.pos)
    end
    # A label cannot end with '.': trailing dots belong to the statement.
    while c.s[prevind(c.s, c.pos)] == '.'
        c.pos = prevind(c.s, c.pos)
    end
    BNode(c.s[start:prevind(c.s, c.pos)])
end

"Parse a quoted literal (with optional language/direction or datatype)."
function _nt_parse_literal!(c::_NTCursor)
    _nt_next!(c)  # consume '"'
    buf = IOBuffer()
    while true
        _nt_eof(c) && _nt_error(c, "unterminated string literal")
        ch = _nt_next!(c)
        if ch == '"'
            break
        elseif ch == '\\'
            _nt_eof(c) && _nt_error(c, "truncated escape sequence in string literal")
            e = _nt_next!(c)
            if e == 't'
                write(buf, '\t')
            elseif e == 'b'
                write(buf, '\b')
            elseif e == 'n'
                write(buf, '\n')
            elseif e == 'r'
                write(buf, '\r')
            elseif e == 'f'
                write(buf, '\f')
            elseif e == '"'
                write(buf, '"')
            elseif e == '\''
                write(buf, '\'')
            elseif e == '\\'
                write(buf, '\\')
            elseif e == 'u' || e == 'U'
                write(buf, _nt_read_uchar!(c, e))
            else
                _nt_error(c, "invalid escape sequence '\\$e' in string literal")
            end
        else
            write(buf, ch)
        end
    end
    lexical = String(take!(buf))

    # Tolerate optional whitespace between the string and a following language
    # tag or datatype (only consumed when '@' / '^^' actually follows, so a
    # plain literal before the statement terminator is unaffected). Required by
    # the W3C c14n "extra_whitespace" tests; no negative test forbids it.
    mark = c.pos
    _nt_skip_ws!(c)
    ch = _nt_peek(c)
    (ch == '@' || ch == '^') || (c.pos = mark)
    ch = _nt_peek(c)
    if ch == '@'
        _nt_next!(c)
        lang, dir = _nt_parse_langtag!(c)
        return Literal(lexical, lang=lang, direction=dir)
    elseif ch == '^'
        _nt_next!(c)
        (_nt_peek(c) == '^') || _nt_error(c, "expected '^^' before literal datatype")
        _nt_next!(c)
        _nt_skip_ws!(c)
        (_nt_peek(c) == '<') || _nt_error(c, "expected IRI after '^^'")
        dt = _nt_parse_iriref!(c)
        # rdf:langString / rdf:dirLangString may not be used as an explicit
        # datatype — they only arise implicitly from a language tag.
        (dt == _RDF_LANGSTRING_DT || dt == _RDF_DIRLANGSTRING_DT) &&
            _nt_error(c, "datatype <$(dt.value)> may not be used explicitly; it is implied by a language tag")
        return Literal(lexical, datatype=dt)
    else
        return Literal(lexical)
    end
end

"""
Parse a LANGTAG body (after `@`): `[a-zA-Z]+(-[a-zA-Z0-9]+)*` with an optional
SPARQL 1.2 base direction suffix `--ltr` / `--rtl`.
Returns `(lang, direction)`.
"""
function _nt_parse_langtag!(c::_NTCursor)
    buf = IOBuffer()
    isletter_ascii(ch) = ('a' <= ch <= 'z') || ('A' <= ch <= 'Z')
    isalnum_ascii(ch) = isletter_ascii(ch) || ('0' <= ch <= '9')

    !_nt_eof(c) && isletter_ascii(_nt_peek(c)) ||
        _nt_error(c, "invalid language tag (must start with a letter)")
    primary_len = 0
    while !_nt_eof(c) && isletter_ascii(_nt_peek(c))
        write(buf, _nt_next!(c))
        primary_len += 1
    end
    primary_len <= 8 ||
        _nt_error(c, "invalid language tag (primary subtag exceeds 8 characters)")
    # Subtags: '-' followed by alphanumerics. A '--' starts the direction.
    while _nt_peek(c) == '-'
        p2 = nextind(c.s, c.pos)
        (p2 <= lastindex(c.s) && c.s[p2] == '-') && break  # '--' → direction
        _nt_next!(c)  # consume '-'
        (!_nt_eof(c) && isalnum_ascii(_nt_peek(c))) ||
            _nt_error(c, "invalid language tag subtag")
        write(buf, '-')
        sub_len = 0
        while !_nt_eof(c) && isalnum_ascii(_nt_peek(c))
            write(buf, _nt_next!(c))
            sub_len += 1
        end
        sub_len <= 8 ||
            _nt_error(c, "invalid language tag (subtag exceeds 8 characters)")
    end
    dir = nothing
    if _nt_peek(c) == '-'  # must be '--' (checked above)
        _nt_next!(c)
        _nt_next!(c)
        start = c.pos
        while !_nt_eof(c) && isletter_ascii(_nt_peek(c))
            _nt_next!(c)
        end
        dir = start <= lastindex(c.s) ? c.s[start:prevind(c.s, c.pos)] : ""
        dir in ("ltr", "rtl") ||
            _nt_error(c, "invalid base direction '$dir' (expected 'ltr' or 'rtl')")
    end
    (String(take!(buf)), dir)
end

"""
Parse an RDF 1.2 triple term; the cursor is positioned at the first `<` of
`<<(`. Only the parenthesised form `<<( S P O )>>` is valid N-Triples 1.2.
The subject must be an IRI/blank node/triple term (not a literal), the
predicate must be an IRI, and the object any term.
"""
function _nt_parse_tripleterm!(c::_NTCursor)
    _nt_next!(c)  # '<'
    _nt_next!(c)  # '<'
    (_nt_peek(c) == '(') ||
        _nt_error(c, "expected '<<(' to open triple term (reifier syntax '<< ... >>' is not allowed in N-Triples)")
    _nt_next!(c)  # '('
    _nt_skip_ws!(c)
    subj = _nt_parse_subject!(c; allow_tripleterm=false)
    _nt_skip_ws!(c)
    pred = _nt_parse_predicate!(c)
    _nt_skip_ws!(c)
    obj = _nt_parse_object!(c)
    _nt_skip_ws!(c)
    (_nt_peek(c) == ')') || _nt_error(c, "expected ')>>' to close triple term")
    _nt_next!(c)
    (_nt_peek(c) == '>') || _nt_error(c, "expected '>>' to close triple term")
    _nt_next!(c)
    (_nt_peek(c) == '>') || _nt_error(c, "expected '>>' to close triple term")
    _nt_next!(c)
    TripleTerm(subj, pred, obj)
end

# A triple term begins with '<<(' (RDF 1.2). A plain '<<' (reifier) is not
# valid N-Triples and is rejected at the point of use.
function _nt_at_tripleterm(c::_NTCursor)
    _nt_peek(c) == '<' || return false
    p2 = nextind(c.s, c.pos)
    (p2 <= lastindex(c.s) && c.s[p2] == '<') || return false
    p3 = nextind(c.s, p2)
    p3 <= lastindex(c.s) && c.s[p3] == '('
end

# True if the cursor is at a '<<' that is NOT a valid triple term start (i.e.
# a reifier `<< ... >>`, which is illegal in N-Triples).
function _nt_at_reifier(c::_NTCursor)
    _nt_peek(c) == '<' || return false
    p2 = nextind(c.s, c.pos)
    (p2 <= lastindex(c.s) && c.s[p2] == '<') || return false
    p3 = nextind(c.s, p2)
    !(p3 <= lastindex(c.s) && c.s[p3] == '(')
end

function _nt_parse_subject!(c::_NTCursor; allow_tripleterm::Bool=true)
    ch = _nt_peek(c)
    if ch == '<'
        if _nt_at_tripleterm(c)
            allow_tripleterm ||
                _nt_error(c, "a triple term '<<( ... )>>' may only appear in object position")
            return _nt_parse_tripleterm!(c)
        elseif _nt_at_reifier(c)
            _nt_error(c, "reifier '<< ... >>' is not allowed in N-Triples")
        end
        return _nt_parse_iriref!(c)
    elseif ch == '_'
        return _nt_parse_bnode!(c)
    end
    _nt_error(c, "expected subject (IRI, blank node, or triple term), got $(repr(ch))")
end

function _nt_parse_predicate!(c::_NTCursor)
    (_nt_peek(c) == '<' && !_nt_at_tripleterm(c) && !_nt_at_reifier(c)) ||
        _nt_error(c, "expected predicate IRI")
    _nt_parse_iriref!(c)
end

function _nt_parse_object!(c::_NTCursor)
    ch = _nt_peek(c)
    if ch == '"'
        return _nt_parse_literal!(c)
    elseif ch == '<'
        if _nt_at_tripleterm(c)
            return _nt_parse_tripleterm!(c)
        elseif _nt_at_reifier(c)
            _nt_error(c, "reifier '<< ... >>' is not allowed in N-Triples")
        end
        return _nt_parse_iriref!(c)
    elseif ch == '_'
        return _nt_parse_bnode!(c)
    end
    _nt_error(c, "expected object (IRI, blank node, literal, or triple term), got $(repr(ch))")
end

"""
Parse one N-Triples/N-Quads statement from a line. Returns
`(subject, predicate, object, graph)` or `nothing` for blank/comment lines.
Throws an `ArgumentError` with the line number for any malformed line.
"""
function _nt_parse_statement(line::AbstractString, lineno::Int, fmt::String;
                             allow_graph::Bool=false)
    c = _NTCursor(String(line), firstindex(line), lineno, fmt)
    _nt_skip_ws!(c)
    (_nt_eof(c) || _nt_peek(c) == '#') && return nothing

    subj = _nt_parse_subject!(c; allow_tripleterm=false)
    _nt_skip_ws!(c)
    pred = _nt_parse_predicate!(c)
    _nt_skip_ws!(c)
    obj = _nt_parse_object!(c)
    _nt_skip_ws!(c)

    graph = nothing
    if allow_graph
        ch = _nt_peek(c)
        if ch == '<'
            graph = _nt_parse_iriref!(c)
        elseif ch == '_'
            graph = _nt_parse_bnode!(c)
        end
        _nt_skip_ws!(c)
    end

    (_nt_peek(c) == '.') || _nt_error(c, "expected '.' at end of statement")
    _nt_next!(c)
    _nt_skip_ws!(c)
    (_nt_eof(c) || _nt_peek(c) == '#') ||
        _nt_error(c, "unexpected content after statement terminator")
    (subj, pred, obj, graph)
end

"""
    parse_ntriples!(g::RDFGraph, io::IO) -> RDFGraph

Parse N-Triples from an IO stream and add triples to the graph.
Malformed lines raise an `ArgumentError` reporting the line number.
"""
function parse_ntriples!(g::RDFGraph, io::IO)
    lineno = 0
    for line in eachline(io)
        lineno += 1
        st = _nt_parse_statement(line, lineno, "N-Triples")
        isnothing(st) && continue
        add!(g, Triple(st[1], st[2], st[3]))
    end
    g
end

"""
Specialised fast path for `DuckDBStore`: parse first into a
`Vector{Triple}` and then `bulk_add!` via DuckDB's Appender.
Roughly 100× faster than per-`add!` on multi-million triple files.
"""
function parse_ntriples!(g::RDFGraph{DuckDBStore}, io::IO)
    ts = parse_ntriples_vec(io)
    bulk_add!(g.store, ts)
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

"""
    parse_ntriples_vec(io::IO) -> Vector{Triple}

Parse N-Triples from an IO stream into a Vector{Triple} without creating a graph.
Useful for bulk loading into stores that accept triple vectors.
Malformed lines raise an `ArgumentError` reporting the line number.
"""
function parse_ntriples_vec(io::IO)
    result = Triple[]
    lineno = 0
    for line in eachline(io)
        lineno += 1
        st = _nt_parse_statement(line, lineno, "N-Triples")
        isnothing(st) && continue
        push!(result, Triple(st[1], st[2], st[3]))
    end
    result
end

# ─── Single-term helpers (used by chunk_serializer.jl) ──────────────

function _parse_nt_node(s::AbstractString)
    c = _NTCursor(String(s), firstindex(s), 0, "N-Triples")
    _nt_skip_ws!(c)
    _nt_parse_subject!(c)
end

function _parse_nt_object(s::AbstractString)
    c = _NTCursor(String(s), firstindex(s), 0, "N-Triples")
    _nt_skip_ws!(c)
    _nt_parse_object!(c)
end

"""
Unescape an N-Triples string-literal body. Handles the full ECHAR set
(`\\t \\b \\n \\r \\f \\" \\' \\\\`) and UCHAR (`\\uXXXX` / `\\UXXXXXXXX`)
escapes. Throws `ArgumentError` for truncated or invalid escapes and for
surrogate code points.
"""
function _unescape_ntriples(s::AbstractString)
    c = _NTCursor(String(s), firstindex(s), 0, "N-Triples")
    buf = IOBuffer()
    while !_nt_eof(c)
        ch = _nt_next!(c)
        if ch == '\\'
            _nt_eof(c) && _nt_error(c, "truncated escape sequence in string literal")
            e = _nt_next!(c)
            if e == 't'
                write(buf, '\t')
            elseif e == 'b'
                write(buf, '\b')
            elseif e == 'n'
                write(buf, '\n')
            elseif e == 'r'
                write(buf, '\r')
            elseif e == 'f'
                write(buf, '\f')
            elseif e == '"'
                write(buf, '"')
            elseif e == '\''
                write(buf, '\'')
            elseif e == '\\'
                write(buf, '\\')
            elseif e == 'u' || e == 'U'
                write(buf, _nt_read_uchar!(c, e))
            else
                _nt_error(c, "invalid escape sequence '\\$e' in string literal")
            end
        else
            write(buf, ch)
        end
    end
    String(take!(buf))
end
