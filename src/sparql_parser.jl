# ═══════════════════════════════════════════════════════════════════
# SPARQL Parser — Recursive descent with proper expression parsing
# ═══════════════════════════════════════════════════════════════════
#
# Replaces the ad-hoc regex parsing in the legacy sparql.jl with a
# proper tokenizer + recursive descent parser.  Expression parsing
# uses Pratt parsing for correct operator precedence.
#
# Architecture:
#   1. Tokenizer: _SparqlTokenizer produces _SparqlToken stream
#   2. Parser:    recursive descent consuming tokens → AST nodes
#   3. Expressions use Pratt (top-down operator precedence) parsing

# ─── Token types ───────────────────────────────────────────────────

@enum SparqlTokenKind begin
    TOK_EOF
    TOK_KEYWORD      # SELECT, WHERE, FILTER, etc.
    TOK_VAR           # ?name, $x
    TOK_IRI           # <http://...>
    TOK_PNAME          # prefix:local
    TOK_STRING        # "hello", 'world', """long"""
    TOK_INTEGER       # 42
    TOK_DECIMAL       # 3.14
    TOK_DOUBLE        # 1.5e10
    TOK_LANGTAG       # @en, @en-US
    TOK_BNODE         # _:label
    TOK_LPAREN        # (
    TOK_RPAREN        # )
    TOK_LBRACE        # {
    TOK_RBRACE        # }
    TOK_LBRACKET      # [
    TOK_RBRACKET      # ]
    TOK_DOT           # .
    TOK_COMMA         # ,
    TOK_SEMICOLON     # ;
    TOK_CARET         # ^
    TOK_CARETCARET    # ^^
    TOK_PIPE          # |
    TOK_SLASH         # /
    TOK_STAR          # *
    TOK_PLUS          # +
    TOK_MINUS         # -
    TOK_BANG          # !
    TOK_EQ            # =
    TOK_NE            # !=
    TOK_LT            # <  (when not IRI)
    TOK_GT            # >
    TOK_LE            # <=
    TOK_GE            # >=
    TOK_AND           # &&
    TOK_OR            # ||
    TOK_QUESTION      # ?  (as path modifier, not var prefix)
    TOK_LTLT          # <<
    TOK_GTGT          # >>
    TOK_LTLT_PAREN    # <<(  (triple term open)
    TOK_RPAREN_GTGT   # )>>  (triple term close)
    TOK_ANNOT_OPEN    # {|   (annotation block open)
    TOK_ANNOT_CLOSE   # |}   (annotation block close)
    TOK_TILDE         # ~    (reifier marker)
    TOK_A             # 'a' (rdf:type shortcut)
    TOK_TRUE          # true
    TOK_FALSE         # false
end

struct _SparqlToken
    kind::SparqlTokenKind
    value::String
    pos::Int
end

# ─── Tokenizer ─────────────────────────────────────────────────────

mutable struct _SparqlTokenizer
    input::String
    pos::Int
    tokens::Vector{_SparqlToken}
    idx::Int       # current position in token stream
end

const _SPARQL_KEYWORDS = Set([
    "SELECT", "ASK", "CONSTRUCT", "DESCRIBE", "WHERE", "FILTER",
    "OPTIONAL", "UNION", "MINUS", "BIND", "AS", "VALUES", "GRAPH",
    "SERVICE", "SILENT", "LATERAL", "EXISTS", "NOT", "IN",
    "ORDER", "BY", "ASC", "DESC", "LIMIT", "OFFSET",
    "GROUP", "HAVING", "DISTINCT", "REDUCED",
    "PREFIX", "BASE", "VERSION", "FROM",
    "COUNT", "SUM", "AVG", "MIN", "MAX", "GROUP_CONCAT", "SAMPLE",
    "MEDIAN", "MODE", "SEPARATOR",
    "INSERT", "DELETE", "DATA", "CLEAR", "DROP", "LOAD", "INTO",
    "COPY", "MOVE", "ADD", "CREATE", "TO", "WITH", "USING",
    "DEFAULT", "ALL", "NAMED", "UNDEF",
    # Built-in functions (must be keywords so they aren't tokenized as PNAME)
    "STR", "LANG", "LANGMATCHES", "DATATYPE", "BOUND", "IRI", "URI",
    "BNODE", "RAND", "ABS", "CEIL", "FLOOR", "ROUND", "CONCAT",
    "STRLEN", "UCASE", "LCASE", "ENCODE_FOR_URI", "CONTAINS",
    "STRSTARTS", "STRENDS", "STRBEFORE", "STRAFTER", "YEAR", "MONTH",
    "DAY", "HOURS", "MINUTES", "SECONDS", "TIMEZONE", "TZ", "NOW",
    "UUID", "STRUUID", "MD5", "SHA1", "SHA256", "SHA384", "SHA512",
    "COALESCE", "IF", "STRLANG", "STRDT", "SAMETERM", "ISIRI",
    "ISURI", "ISBLANK", "ISLITERAL", "ISNUMERIC", "REGEX", "REPLACE",
    "SUBSTR", "TRIPLE", "ISTRIPLE", "SUBJECT", "PREDICATE", "OBJECT",
    "SAMEVALUE",
])

# ─── Prefixed-name scanning (shared with Turtle PN_LOCAL grammar) ───
#
# PN_PREFIX ::= PN_CHARS_BASE ((PN_CHARS | '.')* PN_CHARS)?
# PN_LOCAL  ::= (PN_CHARS_U | ':' | [0-9] | PLX)
#               ((PN_CHARS | '.' | ':' | PLX)* (PN_CHARS | ':' | PLX))?
# PLX       ::= PERCENT | PN_LOCAL_ESC
#
# These scanners return the *raw* lexical text (escapes/percent kept verbatim).
# Resolution to a URIRef unescapes PN_LOCAL_ESC and keeps PERCENT verbatim.

# Scan the local part starting at `pos` (just after the ':'). Returns the
# end index (exclusive) of the local part, with trailing '.' (not part of a
# valid token-final char) backed off. Mirrors Turtle `_parse_pn_local!`.
function _scan_pn_local(input::AbstractString, pos::Int, len::Int)
    is_first = true
    pending_dots = 0  # count of trailing '.' to back off if no valid char follows
    while pos <= len
        c = input[pos]
        if c == '%'
            h1 = nextind(input, pos)
            h2 = h1 <= len ? nextind(input, h1) : h1
            (h1 > len || h2 > len || !_is_hex_digit(input[h1]) || !_is_hex_digit(input[h2])) && break
            pending_dots = 0
            pos = nextind(input, h2)
        elseif c == '\\'
            esc = nextind(input, pos)
            (esc > len || !(input[esc] in _PN_LOCAL_ESC_CHARS)) && break
            pending_dots = 0
            pos = nextind(input, esc)
        elseif c == ':' || _is_pn_chars(c)
            if is_first && !(_is_pn_chars_u(c) || isdigit(c) || c == ':')
                break
            end
            pending_dots = 0
            pos = nextind(input, pos)
        elseif c == '.' && !is_first
            pending_dots += 1
            pos = nextind(input, pos)
        else
            break
        end
        is_first = false
    end
    # '.' is single-byte ASCII; rewind unconsumed trailing dots
    pos - pending_dots
end

# Unescape a raw PN_LOCAL lexical form: drop PN_LOCAL_ESC backslashes,
# keep PERCENT (%HH) verbatim.
function _unescape_pn_local(s::AbstractString)
    occursin('\\', s) || return String(s)
    io = IOBuffer()
    i = firstindex(s)
    last_i = lastindex(s)
    while i <= last_i
        c = s[i]
        if c == '\\' && i < last_i
            nxt = nextind(s, i)
            ec = s[nxt]
            if ec in _PN_LOCAL_ESC_CHARS
                write(io, ec)
                i = nextind(s, nxt)
                continue
            end
        end
        write(io, c)
        i = nextind(s, i)
    end
    String(take!(io))
end

# Validate IRIREF inner content: every char must be > U+0020 and not one of
# the excluded chars; a '\' is permitted only when it begins a UCHAR
# (\uHHHH or \UHHHHHHHH).
function _is_valid_iriref_content(content::AbstractString)
    i = firstindex(content)
    last_i = lastindex(content)
    while i <= last_i
        ch = content[i]
        if ch == '\\'
            i < last_i || return false
            j = nextind(content, i)
            e = content[j]
            n = e == 'u' ? 4 : e == 'U' ? 8 : return false
            k = nextind(content, j)
            for _ in 1:n
                k <= last_i && _is_hex_digit(content[k]) || return false
                k = nextind(content, k)
            end
            i = k
        elseif ch <= ' ' || ch in ('<', '>', '"', '{', '}', '|', '^', '`')
            return false
        else
            i = nextind(content, i)
        end
    end
    true
end

# Unescape UCHAR (\uHHHH / \UHHHHHHHH) escapes in an IRIREF.
function _unescape_iri_uchar(s::AbstractString)
    occursin('\\', s) || return String(s)
    io = IOBuffer()
    i = firstindex(s)
    last_i = lastindex(s)
    while i <= last_i
        c = s[i]
        if c == '\\' && i < last_i
            j = nextind(s, i)
            e = s[j]
            if e == 'u' || e == 'U'
                n = e == 'u' ? 4 : 8
                k = nextind(s, j)
                hex = IOBuffer()
                for _ in 1:n
                    write(hex, s[k]); k = nextind(s, k)
                end
                cp = parse(UInt32, String(take!(hex)), base=16)
                (0xD800 <= cp <= 0xDFFF) &&
                    error("Surrogate code point U+$(string(cp, base=16, pad=4)) is not allowed in an IRI \\$e escape")
                write(io, Char(cp))
                i = k
                continue
            end
        end
        write(io, c)
        i = nextind(s, i)
    end
    String(take!(io))
end

function _sparql_tokenize_all(input::AbstractString)
    tokens = _SparqlToken[]
    pos = 1
    len = lastindex(input)

    while pos <= len
        c = input[pos]

        # Skip whitespace
        if isspace(c)
            pos = nextind(input, pos)
            continue
        end

        # Skip comments
        if c == '#'
            while pos <= len && input[pos] != '\n'
                pos = nextind(input, pos)
            end
            continue
        end

        # IRI: <...>
        if c == '<'
            if pos < len && input[pos+1] == '<'
                # `<<(` triple-term open vs `<<` reifier open
                if pos + 1 < len && input[pos+2] == '('
                    push!(tokens, _SparqlToken(TOK_LTLT_PAREN, "<<(", pos))
                    pos += 3
                    continue
                end
                push!(tokens, _SparqlToken(TOK_LTLT, "<<", pos))
                pos += 2
                continue
            end
            # Disambiguate IRIREF vs less-than operator under the SPARQL
            # "longest token rule": treat <...> as an IRI whenever the bracketed
            # content is valid IRIREF content — i.e. every char is > U+0020 and
            # none of <, >, ", {, }, |, ^, ` (a backslash is allowed only in a
            # UCHAR escape). The IRIREF production does NOT exclude `&` or `|`,
            # so e.g. `<?a&&?b>` lexes as an IRIREF (and a FILTER like
            # `(?x<?a&&?b>?y)` is then a syntax error — syn-bad-26). Only when
            # the content is not valid IRIREF do we fall back to the `<`/`<=`
            # operator.
            end_pos = findnext('>', input, nextind(input, pos))
            if !isnothing(end_pos)
                content = SubString(input, nextind(input, pos), prevind(input, end_pos))
                if _is_valid_iriref_content(content)
                    push!(tokens, _SparqlToken(TOK_IRI, _unescape_iri_uchar(content), pos))
                    pos = nextind(input, end_pos)
                    continue
                end
            end
            # Less-than operator
            if pos < len && input[pos+1] == '='
                push!(tokens, _SparqlToken(TOK_LE, "<=", pos))
                pos += 2
            else
                push!(tokens, _SparqlToken(TOK_LT, "<", pos))
                pos += 1
            end
            continue
        end

        # >> 
        if c == '>' && pos < len && input[pos+1] == '>'
            push!(tokens, _SparqlToken(TOK_GTGT, ">>", pos))
            pos += 2
            continue
        end

        # >= or >
        if c == '>'
            if pos < len && input[pos+1] == '='
                push!(tokens, _SparqlToken(TOK_GE, ">=", pos))
                pos += 2
            else
                push!(tokens, _SparqlToken(TOK_GT, ">", pos))
                pos += 1
            end
            continue
        end

        # String literals
        if c == '"' || c == '\''
            tok, new_pos = _tokenize_string(input, pos)
            push!(tokens, _SparqlToken(TOK_STRING, tok, pos))
            pos = new_pos
            continue
        end

        # Variable: ?name or $name (VARNAME may start with a digit, e.g. ?1)
        if (c == '?' || c == '$') && pos < len && (isletter(input[pos+1]) || input[pos+1] == '_' || isdigit(input[pos+1]))
            start = pos
            pos = nextind(input, pos)
            while pos <= len && (isdigit(input[pos]) || isletter(input[pos]) || input[pos] == '_')
                pos = nextind(input, pos)
            end
            push!(tokens, _SparqlToken(TOK_VAR, input[start:pos-1], start))
            continue
        end

        # Standalone ? (path modifier)
        if c == '?'
            push!(tokens, _SparqlToken(TOK_QUESTION, "?", pos))
            pos = nextind(input, pos)
            continue
        end

        # Blank node: _:label (label may contain internal dots, but a trailing
        # dot is a statement terminator — back off)
        if c == '_' && pos < len && input[pos+1] == ':'
            start = pos
            pos += 2
            label_start = pos
            while pos <= len && (isdigit(input[pos]) || isletter(input[pos]) || input[pos] in ('.', '-', '_'))
                pos = nextind(input, pos)
            end
            while pos > label_start && input[prevind(input, pos)] == '.'
                pos = prevind(input, pos)
            end
            push!(tokens, _SparqlToken(TOK_BNODE, input[start:pos-1], start))
            continue
        end

        # @lang tag
        if c == '@'
            start = pos
            pos = nextind(input, pos)
            while pos <= len && (isletter(input[pos]) || input[pos] == '-' || isdigit(input[pos]))
                pos = nextind(input, pos)
            end
            push!(tokens, _SparqlToken(TOK_LANGTAG, input[start:pos-1], start))
            continue
        end

        # Operators and punctuation
        if c == '(' ; push!(tokens, _SparqlToken(TOK_LPAREN, "(", pos));   pos += 1; continue; end
        if c == ')'
            # `)>>` triple-term close (no internal whitespace)
            if pos + 1 < len && input[pos+1] == '>' && input[pos+2] == '>'
                push!(tokens, _SparqlToken(TOK_RPAREN_GTGT, ")>>", pos))
                pos += 3
                continue
            end
            push!(tokens, _SparqlToken(TOK_RPAREN, ")", pos)); pos += 1; continue
        end
        if c == '{'
            # `{|` annotation-block open
            if pos < len && input[pos+1] == '|'
                push!(tokens, _SparqlToken(TOK_ANNOT_OPEN, "{|", pos))
                pos += 2
                continue
            end
            push!(tokens, _SparqlToken(TOK_LBRACE, "{", pos)); pos += 1; continue
        end
        if c == '}' ; push!(tokens, _SparqlToken(TOK_RBRACE, "}", pos));   pos += 1; continue; end
        if c == '[' ; push!(tokens, _SparqlToken(TOK_LBRACKET, "[", pos)); pos += 1; continue; end
        if c == ']' ; push!(tokens, _SparqlToken(TOK_RBRACKET, "]", pos)); pos += 1; continue; end
        if c == '.' ; push!(tokens, _SparqlToken(TOK_DOT, ".", pos));       pos += 1; continue; end
        if c == ',' ; push!(tokens, _SparqlToken(TOK_COMMA, ",", pos));     pos += 1; continue; end
        if c == ';' ; push!(tokens, _SparqlToken(TOK_SEMICOLON, ";", pos)); pos += 1; continue; end
        if c == '*' ; push!(tokens, _SparqlToken(TOK_STAR, "*", pos));      pos += 1; continue; end
        if c == '/' ; push!(tokens, _SparqlToken(TOK_SLASH, "/", pos));     pos += 1; continue; end

        if c == '^'
            if pos < len && input[pos+1] == '^'
                push!(tokens, _SparqlToken(TOK_CARETCARET, "^^", pos))
                pos += 2
            else
                push!(tokens, _SparqlToken(TOK_CARET, "^", pos))
                pos += 1
            end
            continue
        end

        if c == '|'
            if pos < len && input[pos+1] == '|'
                push!(tokens, _SparqlToken(TOK_OR, "||", pos))
                pos += 2
            elseif pos < len && input[pos+1] == '}'
                push!(tokens, _SparqlToken(TOK_ANNOT_CLOSE, "|}", pos))
                pos += 2
            else
                push!(tokens, _SparqlToken(TOK_PIPE, "|", pos))
                pos += 1
            end
            continue
        end

        if c == '~'
            push!(tokens, _SparqlToken(TOK_TILDE, "~", pos))
            pos += 1
            continue
        end

        if c == '&' && pos < len && input[pos+1] == '&'
            push!(tokens, _SparqlToken(TOK_AND, "&&", pos))
            pos += 2
            continue
        end

        if c == '!'
            if pos < len && input[pos+1] == '='
                push!(tokens, _SparqlToken(TOK_NE, "!=", pos))
                pos += 2
            else
                push!(tokens, _SparqlToken(TOK_BANG, "!", pos))
                pos += 1
            end
            continue
        end

        if c == '='
            push!(tokens, _SparqlToken(TOK_EQ, "=", pos))
            pos += 1
            continue
        end

        if c == '+' ; push!(tokens, _SparqlToken(TOK_PLUS, "+", pos));   pos += 1; continue; end
        if c == '-'
            # Check if this is a negative number
            if pos < len && isdigit(input[pos+1])
                start = pos
                pos = nextind(input, pos)
                has_dot = false
                has_e = false
                while pos <= len
                    ch = input[pos]
                    if isdigit(ch)
                        pos = nextind(input, pos)
                    elseif ch == '.' && !has_dot && !has_e
                        has_dot = true
                        pos = nextind(input, pos)
                    elseif (ch == 'e' || ch == 'E') && !has_e
                        has_e = true
                        pos = nextind(input, pos)
                        if pos <= len && (input[pos] == '+' || input[pos] == '-')
                            pos = nextind(input, pos)
                        end
                    else
                        break
                    end
                end
                numstr = input[start:pos-1]
                kind = has_e ? TOK_DOUBLE : (has_dot ? TOK_DECIMAL : TOK_INTEGER)
                push!(tokens, _SparqlToken(kind, numstr, start))
                continue
            end
            push!(tokens, _SparqlToken(TOK_MINUS, "-", pos))
            pos += 1
            continue
        end

        # Numbers
        if isdigit(c)
            start = pos
            has_dot = false
            has_e = false
            while pos <= len
                ch = input[pos]
                if isdigit(ch)
                    pos = nextind(input, pos)
                elseif ch == '.' && !has_dot && !has_e
                    # Peek ahead: is this a decimal or a statement terminator?
                    if pos < len && isdigit(input[pos+1])
                        has_dot = true
                        pos = nextind(input, pos)
                    else
                        break
                    end
                elseif (ch == 'e' || ch == 'E') && !has_e
                    has_e = true
                    pos = nextind(input, pos)
                    if pos <= len && (input[pos] == '+' || input[pos] == '-')
                        pos = nextind(input, pos)
                    end
                else
                    break
                end
            end
            numstr = input[start:pos-1]
            kind = has_e ? TOK_DOUBLE : (has_dot ? TOK_DECIMAL : TOK_INTEGER)
            push!(tokens, _SparqlToken(kind, numstr, start))
            continue
        end

        # Words: keywords, prefixed names, 'a', 'true', 'false'
        if isletter(c) || c == '_'
            start = pos
            while pos <= len && (isletter(input[pos]) || isdigit(input[pos]) || input[pos] in ('_', '.', '-'))
                pos = nextind(input, pos)
            end
            # Names may contain internal dots but never end with one — a
            # trailing dot is the statement terminator.
            while pos > start && input[prevind(input, pos)] == '.'
                pos = prevind(input, pos)
            end
            word = input[start:prevind(input, pos)]

            # Check for prefixed name (word followed by :)
            if pos <= len && input[pos] == ':'
                pos = nextind(input, pos)          # consume ':'
                pos = _scan_pn_local(input, pos, len)  # PN_LOCAL grammar
                pname = input[start:prevind(input, pos)]
                push!(tokens, _SparqlToken(TOK_PNAME, pname, start))
                continue
            end

            # Special words
            uw = uppercase(word)
            if word == "a"
                push!(tokens, _SparqlToken(TOK_A, "a", start))
            elseif uw == "TRUE"
                push!(tokens, _SparqlToken(TOK_TRUE, "true", start))
            elseif uw == "FALSE"
                push!(tokens, _SparqlToken(TOK_FALSE, "false", start))
            elseif uw in _SPARQL_KEYWORDS
                push!(tokens, _SparqlToken(TOK_KEYWORD, uw, start))
            else
                # Could be a function name or bare word — treat as PNAME
                push!(tokens, _SparqlToken(TOK_PNAME, word, start))
            end
            continue
        end

        # Bare colon (empty prefix)
        if c == ':'
            start = pos
            pos = nextind(input, pos)          # consume ':'
            pos = _scan_pn_local(input, pos, len)  # PN_LOCAL grammar
            push!(tokens, _SparqlToken(TOK_PNAME, input[start:prevind(input, pos)], start))
            continue
        end

        # A stray backslash outside a string/IRI is illegal (e.g. a UCHAR
        # escape used as a bare term: `?s ?p A`).
        if c == '\\'
            error("Unexpected '\\' at position $pos")
        end

        # Unknown character — skip
        pos = nextind(input, pos)
    end

    push!(tokens, _SparqlToken(TOK_EOF, "", pos))
    _SparqlTokenizer(input, 1, tokens, 1)
end

function _tokenize_string(input::AbstractString, pos::Int)
    q = input[pos]
    # Check for long string (triple quotes)
    if pos + 2 <= lastindex(input) && input[pos+1] == q && input[pos+2] == q
        # Scan char-by-char honouring '\' escapes, so an escaped quote
        # (e.g. \" inside """...""") does not prematurely close the literal.
        i = pos + 3
        last_i = lastindex(input)
        while i <= last_i
            c = input[i]
            if c == '\\'
                i = nextind(input, nextind(input, i))  # skip escaped char
            elseif c == q && i + 2 <= last_i + 1 &&
                   nextind(input, i) <= last_i && input[nextind(input, i)] == q &&
                   nextind(input, nextind(input, i)) <= last_i &&
                   input[nextind(input, nextind(input, i))] == q
                close_end = nextind(input, nextind(input, i))
                return (input[pos:close_end], nextind(input, close_end))
            else
                i = nextind(input, i)
            end
        end
        error("Unterminated long string at position $pos")
    end
    # Short string
    i = pos + 1
    while i <= lastindex(input)
        c = input[i]
        if c == '\\'
            i = nextind(input, nextind(input, i))  # skip escaped char
        elseif c == q
            return (input[pos:i], i + 1)
        else
            i = nextind(input, i)
        end
    end
    error("Unterminated string at position $pos")
end

# ─── Token stream helpers ──────────────────────────────────────────

function _peek(tz::_SparqlTokenizer)::_SparqlToken
    tz.tokens[tz.idx]
end

function _advance!(tz::_SparqlTokenizer)::_SparqlToken
    tok = tz.tokens[tz.idx]
    if tok.kind != TOK_EOF
        tz.idx += 1
    end
    tok
end

function _expect!(tz::_SparqlTokenizer, kind::SparqlTokenKind)::_SparqlToken
    tok = _advance!(tz)
    tok.kind == kind || error("Expected $(kind), got $(tok.kind) '$(tok.value)' at position $(tok.pos)")
    tok
end

function _expect_keyword!(tz::_SparqlTokenizer, kw::String)::_SparqlToken
    tok = _advance!(tz)
    (tok.kind == TOK_KEYWORD && tok.value == kw) ||
        error("Expected keyword $kw, got $(tok.kind) '$(tok.value)' at position $(tok.pos)")
    tok
end

function _check(tz::_SparqlTokenizer, kind::SparqlTokenKind)::Bool
    _peek(tz).kind == kind
end

function _check_keyword(tz::_SparqlTokenizer, kw::String)::Bool
    tok = _peek(tz)
    tok.kind == TOK_KEYWORD && tok.value == kw
end

function _match!(tz::_SparqlTokenizer, kind::SparqlTokenKind)::Union{_SparqlToken, Nothing}
    if _peek(tz).kind == kind
        return _advance!(tz)
    end
    nothing
end

function _match_keyword!(tz::_SparqlTokenizer, kw::String)::Union{_SparqlToken, Nothing}
    tok = _peek(tz)
    if tok.kind == TOK_KEYWORD && tok.value == kw
        return _advance!(tz)
    end
    nothing
end

# ─── Expression Parser (Pratt / TDOP) ─────────────────────────────
# Correct operator precedence without left-recursion.
# Precedence (low to high): || < && < comparisons < +- < */ < unary (!, +, -) < primary

function _parse_expr(tz::_SparqlTokenizer, prefixes::Dict{String,String})::SparqlExpr
    _parse_or(tz, prefixes)
end

function _parse_or(tz::_SparqlTokenizer, prefixes)::SparqlExpr
    left = _parse_and(tz, prefixes)
    while _check(tz, TOK_OR)
        _advance!(tz)
        right = _parse_and(tz, prefixes)
        left = ExprBinaryOp(:||, left, right)
    end
    left
end

function _parse_and(tz::_SparqlTokenizer, prefixes)::SparqlExpr
    left = _parse_comparison(tz, prefixes)
    while _check(tz, TOK_AND)
        _advance!(tz)
        right = _parse_comparison(tz, prefixes)
        left = ExprBinaryOp(:&&, left, right)
    end
    left
end

function _parse_comparison(tz::_SparqlTokenizer, prefixes)::SparqlExpr
    left = _parse_additive(tz, prefixes)
    tok = _peek(tz)
    if tok.kind == TOK_EQ;  _advance!(tz); return ExprBinaryOp(:(==), left, _parse_additive(tz, prefixes)); end
    if tok.kind == TOK_NE;  _advance!(tz); return ExprBinaryOp(:!=, left, _parse_additive(tz, prefixes)); end
    if tok.kind == TOK_LT;  _advance!(tz); return ExprBinaryOp(:<, left, _parse_additive(tz, prefixes)); end
    if tok.kind == TOK_GT;  _advance!(tz); return ExprBinaryOp(:>, left, _parse_additive(tz, prefixes)); end
    if tok.kind == TOK_LE;  _advance!(tz); return ExprBinaryOp(:<=, left, _parse_additive(tz, prefixes)); end
    if tok.kind == TOK_GE;  _advance!(tz); return ExprBinaryOp(:>=, left, _parse_additive(tz, prefixes)); end
    # IN / NOT IN
    if _check_keyword(tz, "IN")
        _advance!(tz)
        _expect!(tz, TOK_LPAREN)
        vals = _parse_expr_list(tz, prefixes)
        _expect!(tz, TOK_RPAREN)
        return ExprIn(left, vals, false)
    end
    if _check_keyword(tz, "NOT") && tz.idx + 1 <= length(tz.tokens) &&
            tz.tokens[tz.idx + 1].kind == TOK_KEYWORD && tz.tokens[tz.idx + 1].value == "IN"
        _advance!(tz); _advance!(tz)  # NOT IN
        _expect!(tz, TOK_LPAREN)
        vals = _parse_expr_list(tz, prefixes)
        _expect!(tz, TOK_RPAREN)
        return ExprIn(left, vals, true)
    end
    left
end

function _parse_additive(tz::_SparqlTokenizer, prefixes)::SparqlExpr
    left = _parse_multiplicative(tz, prefixes)
    while true
        if _check(tz, TOK_PLUS)
            _advance!(tz)
            left = ExprBinaryOp(:+, left, _parse_multiplicative(tz, prefixes))
        elseif _check(tz, TOK_MINUS)
            _advance!(tz)
            left = ExprBinaryOp(:-, left, _parse_multiplicative(tz, prefixes))
        elseif (_check(tz, TOK_INTEGER) || _check(tz, TOK_DECIMAL) || _check(tz, TOK_DOUBLE)) &&
               startswith(_peek(tz).value, '-')
            # Grammar: AdditiveExpression may continue with a NumericLiteralNegative
            # (`?x-1` lexes as VAR, INTEGER "-1"). Treat `-1` as `- 1`, allowing
            # the */-continuation the grammar permits on the signed literal.
            t = _advance!(tz)
            rhs::SparqlExpr = _numeric_token_literal(t)
            while true
                if _check(tz, TOK_STAR)
                    _advance!(tz)
                    rhs = ExprBinaryOp(:*, rhs, _parse_unary(tz, prefixes))
                elseif _check(tz, TOK_SLASH)
                    _advance!(tz)
                    rhs = ExprBinaryOp(:/, rhs, _parse_unary(tz, prefixes))
                else
                    break
                end
            end
            left = ExprBinaryOp(:+, left, rhs)
        else
            break
        end
    end
    left
end

# Build an ExprLiteral from a numeric token, preserving the lexical form
# and assigning the grammar-mandated datatype.
function _numeric_token_literal(tok::_SparqlToken)::ExprLiteral
    dt = tok.kind == TOK_INTEGER ? "integer" :
         tok.kind == TOK_DECIMAL ? "decimal" : "double"
    ExprLiteral(Literal(tok.value, datatype=URIRef("http://www.w3.org/2001/XMLSchema#" * dt)))
end

function _parse_multiplicative(tz::_SparqlTokenizer, prefixes)::SparqlExpr
    left = _parse_unary(tz, prefixes)
    while true
        if _check(tz, TOK_STAR)
            _advance!(tz)
            left = ExprBinaryOp(:*, left, _parse_unary(tz, prefixes))
        elseif _check(tz, TOK_SLASH)
            _advance!(tz)
            left = ExprBinaryOp(:/, left, _parse_unary(tz, prefixes))
        else
            break
        end
    end
    left
end

function _parse_unary(tz::_SparqlTokenizer, prefixes)::SparqlExpr
    if _check(tz, TOK_BANG)
        _advance!(tz)
        return ExprUnaryOp(:!, _parse_unary(tz, prefixes))
    end
    if _check(tz, TOK_PLUS)
        _advance!(tz)
        return ExprUnaryOp(:+, _parse_unary(tz, prefixes))
    end
    if _check(tz, TOK_MINUS)
        _advance!(tz)
        return ExprUnaryOp(:-, _parse_unary(tz, prefixes))
    end
    _parse_primary_expr(tz, prefixes)
end

function _parse_primary_expr(tz::_SparqlTokenizer, prefixes)::SparqlExpr
    tok = _peek(tz)

    # Parenthesized expression
    if tok.kind == TOK_LPAREN
        _advance!(tz)
        expr = _parse_expr(tz, prefixes)
        _expect!(tz, TOK_RPAREN)
        return expr
    end

    # Variable
    if tok.kind == TOK_VAR
        _advance!(tz)
        return ExprVar(tok.value[2:end])
    end

    # IRI
    if tok.kind == TOK_IRI
        # Could be an IRI-named function call, e.g. <http://ex.org/fn>(?x)
        if _peek_is_funcall(tz)
            return _parse_funcall_or_iri(tz, prefixes)
        end
        _advance!(tz)
        return ExprURI(_make_uri(tok.value, prefixes))
    end

    # BNode — blank nodes are not allowed in expressions (not in the
    # PrimaryExpression grammar), e.g. `FILTER(_:x)` is a syntax error.
    if tok.kind == TOK_BNODE
        error("Blank node '$(tok.value)' is not allowed in an expression at position $(tok.pos)")
    end

    # Boolean
    if tok.kind == TOK_TRUE;  _advance!(tz); return ExprBool(true);  end
    if tok.kind == TOK_FALSE; _advance!(tz); return ExprBool(false); end

    # Numeric literal — keep the original lexical form; INTEGER → xsd:integer,
    # DECIMAL → xsd:decimal, DOUBLE → xsd:double
    if tok.kind == TOK_INTEGER || tok.kind == TOK_DECIMAL || tok.kind == TOK_DOUBLE
        _advance!(tz)
        return _numeric_token_literal(tok)
    end

    # String literal (possibly with ^^type or @lang)
    if tok.kind == TOK_STRING
        return _parse_literal_expr(tz, prefixes)
    end

    # Aggregates
    if tok.kind == TOK_KEYWORD && tok.value in ("COUNT", "SUM", "AVG", "MIN", "MAX",
                                                  "SAMPLE", "MEDIAN", "MODE")
        return _parse_aggregate(tz, prefixes)
    end
    if tok.kind == TOK_KEYWORD && tok.value == "GROUP_CONCAT"
        return _parse_group_concat(tz, prefixes)
    end

    # EXISTS / NOT EXISTS
    if _check_keyword(tz, "EXISTS")
        _advance!(tz)
        pats = _parse_group_graph_pattern(tz, prefixes)
        return ExprExists(pats, false)
    end
    if _check_keyword(tz, "NOT") && tz.idx + 1 <= length(tz.tokens) &&
            tz.tokens[tz.idx + 1].kind == TOK_KEYWORD && tz.tokens[tz.idx + 1].value == "EXISTS"
        _advance!(tz); _advance!(tz)
        pats = _parse_group_graph_pattern(tz, prefixes)
        return ExprExists(pats, true)
    end

    # Function call or prefixed name
    if tok.kind == TOK_PNAME || (tok.kind == TOK_KEYWORD && _peek_is_funcall(tz))
        return _parse_funcall_or_iri(tz, prefixes)
    end

    # Star (for COUNT(*))
    if tok.kind == TOK_STAR
        _advance!(tz)
        return ExprStar()
    end

    # SPARQL 1.2 triple term `<<( s p o )>>` in an expression.
    if tok.kind == TOK_LTLT_PAREN
        return _parse_triple_term(tz, prefixes, PatTriple[]; as_var=true, in_expr=true)
    end

    error("Unexpected token in expression: $(tok.kind) '$(tok.value)' at position $(tok.pos)")
end

function _peek_is_funcall(tz::_SparqlTokenizer)::Bool
    # Check if current keyword is followed by '('
    tz.idx + 1 <= length(tz.tokens) && tz.tokens[tz.idx + 1].kind == TOK_LPAREN
end

function _parse_funcall_or_iri(tz::_SparqlTokenizer, prefixes)::SparqlExpr
    tok = _advance!(tz)
    name = tok.value
    is_iri_name = false

    if tok.kind == TOK_IRI
        is_iri_name = true
        name = _make_uri(name, prefixes).value
    elseif tok.kind == TOK_PNAME
        colon_idx = findfirst(':', name)
        if !isnothing(colon_idx)
            is_iri_name = true
            name = _resolve_pname(name, prefixes).value
        end
    end

    # Check if function call
    if _check(tz, TOK_LPAREN)
        _advance!(tz)  # consume (
        args = SparqlExpr[]
        if !_check(tz, TOK_RPAREN)
            push!(args, _parse_expr(tz, prefixes))
            while _check(tz, TOK_COMMA)
                _advance!(tz)
                push!(args, _parse_expr(tz, prefixes))
            end
        end
        _expect!(tz, TOK_RPAREN)
        # Uppercase ONLY bare builtin names (keywords or bare words); IRIs and
        # prefixed names (e.g. xsd:integer casts) must keep their exact form.
        fname = is_iri_name ? name : uppercase(name)
        return ExprFunctionCall(fname, args)
    end

    # Just an IRI
    is_iri_name && return ExprURI(URIRef(name))
    ExprURI(_resolve_pname(name, prefixes))
end

function _parse_literal_expr(tz::_SparqlTokenizer, prefixes)::SparqlExpr
    tok = _advance!(tz)
    lexical = _unescape_sparql_string(tok.value)

    # Check for ^^datatype
    if _check(tz, TOK_CARETCARET)
        _advance!(tz)
        dt_tok = _advance!(tz)
        dt_uri = if dt_tok.kind == TOK_IRI
            _make_uri(dt_tok.value, prefixes)
        elseif dt_tok.kind == TOK_PNAME
            _resolve_pname(dt_tok.value, prefixes)
        else
            error("Expected IRI after ^^, got $(dt_tok.kind)")
        end
        return ExprLiteral(Literal(lexical, datatype=dt_uri))
    end

    # Check for @lang (possibly with a base direction `@lang--dir`)
    if _check(tz, TOK_LANGTAG)
        lt = _advance!(tz)
        lang, dir = _split_langtag(lt.value[2:end])
        return ExprLiteral(_make_lang_literal(lexical, lang, dir))
    end

    ExprLiteral(Literal(lexical))
end

# Split a SPARQL 1.2 language tag `lang--dir` into (lang, dir). When no `--`
# is present, dir is `nothing`.
function _split_langtag(tag::AbstractString)
    i = findfirst("--", tag)
    isnothing(i) && return (String(tag), nothing)
    return (String(tag[1:first(i)-1]), String(tag[last(i)+1:end]))
end

function _make_lang_literal(lexical, lang, dir)
    dir === nothing && return Literal(lexical, lang=lang)
    return Literal(lexical, lang=lang, direction=dir)
end

function _parse_aggregate(tz::_SparqlTokenizer, prefixes)::SparqlExpr
    func = _advance!(tz).value
    _expect!(tz, TOK_LPAREN)
    distinct = !isnothing(_match_keyword!(tz, "DISTINCT"))
    arg = if _check(tz, TOK_STAR)
        _advance!(tz)
        ExprStar()
    else
        _parse_expr(tz, prefixes)
    end
    _expect!(tz, TOK_RPAREN)
    _reject_nested_aggregate(arg, func)
    ExprAggregate(func, arg, distinct, nothing)
end

# Aggregates may not be nested (e.g. COUNT(SUM(?x)) is a syntax error).
function _reject_nested_aggregate(arg::SparqlExpr, outer)
    if _expr_contains_aggregate(arg)
        error("Nested aggregate function is not allowed inside $(outer)(...)")
    end
end

_expr_contains_aggregate(e::ExprAggregate) = true
_expr_contains_aggregate(e::ExprBinaryOp) = _expr_contains_aggregate(e.left) || _expr_contains_aggregate(e.right)
_expr_contains_aggregate(e::ExprUnaryOp) = _expr_contains_aggregate(e.arg)
_expr_contains_aggregate(e::ExprFunctionCall) = any(_expr_contains_aggregate, e.args)
_expr_contains_aggregate(e::ExprIn) = _expr_contains_aggregate(e.expr) || any(_expr_contains_aggregate, e.values)
_expr_contains_aggregate(e) = false

function _parse_group_concat(tz::_SparqlTokenizer, prefixes)::SparqlExpr
    _advance!(tz)  # GROUP_CONCAT
    _expect!(tz, TOK_LPAREN)
    distinct = !isnothing(_match_keyword!(tz, "DISTINCT"))
    arg = _parse_expr(tz, prefixes)
    sep = nothing
    if _check(tz, TOK_SEMICOLON)
        _advance!(tz)
        _expect_keyword!(tz, "SEPARATOR")
        _expect!(tz, TOK_EQ)
        sep_tok = _expect!(tz, TOK_STRING)
        sep = _unescape_sparql_string(sep_tok.value)
    end
    _expect!(tz, TOK_RPAREN)
    _reject_nested_aggregate(arg, "GROUP_CONCAT")
    ExprAggregate("GROUP_CONCAT", arg, distinct, sep)
end

function _parse_expr_list(tz::_SparqlTokenizer, prefixes)::Vector{SparqlExpr}
    exprs = SparqlExpr[]
    if !_check(tz, TOK_RPAREN)
        push!(exprs, _parse_expr(tz, prefixes))
        while _check(tz, TOK_COMMA)
            _advance!(tz)
            push!(exprs, _parse_expr(tz, prefixes))
        end
    end
    exprs
end

# ─── String/IRI helpers ───────────────────────────────────────────

function _unescape_sparql_string(s::AbstractString)
    # Strip quotes (long forms first)
    if (startswith(s, "\"\"\"") && endswith(s, "\"\"\"") && lastindex(s) >= 6) ||
       (startswith(s, "'''") && endswith(s, "'''") && lastindex(s) >= 6)
        s = s[4:prevind(s, lastindex(s), 3)]
    elseif startswith(s, '"') && endswith(s, '"')
        s = s[2:prevind(s, lastindex(s))]
    elseif startswith(s, '\'') && endswith(s, '\'')
        s = s[2:prevind(s, lastindex(s))]
    end
    occursin('\\', s) || return String(s)
    io = IOBuffer(sizehint=ncodeunits(s))
    i = firstindex(s)
    last_i = lastindex(s)
    while i <= last_i
        c = s[i]
        if c != '\\' || i == last_i
            write(io, c)
            i = nextind(s, i)
            continue
        end
        i = nextind(s, i)
        e = s[i]
        i = nextind(s, i)
        if e == 'n';      write(io, '\n')
        elseif e == 't';  write(io, '\t')
        elseif e == 'r';  write(io, '\r')
        elseif e == 'b';  write(io, '\b')
        elseif e == 'f';  write(io, '\f')
        elseif e == '"';  write(io, '"')
        elseif e == '\''; write(io, '\'')
        elseif e == '\\'; write(io, '\\')
        elseif e == 'u' || e == 'U'
            n = e == 'u' ? 4 : 8
            hex = ""
            for _ in 1:n
                i <= last_i || error("Truncated \\$e escape in SPARQL string literal")
                hex *= s[i]
                i = nextind(s, i)
            end
            cp = tryparse(UInt32, hex, base=16)
            isnothing(cp) && error("Invalid \\$e escape '\\$e$hex' in SPARQL string literal")
            (0xD800 <= cp <= 0xDFFF) && error("Surrogate code point U+$(string(cp, base=16, pad=4)) is not allowed in \\$e escape")
            cp > 0x10FFFF && error("Code point out of range in \\$e escape: \\$e$hex")
            write(io, Char(cp))
        else
            # Unknown escape — keep verbatim
            write(io, '\\')
            write(io, e)
        end
    end
    String(take!(io))
end

function _resolve_pname(name::AbstractString, prefixes::Dict{String,String})::URIRef
    colon_idx = findfirst(':', name)
    if isnothing(colon_idx)
        return URIRef(name)
    end
    prefix = name[1:prevind(name, colon_idx)]
    local_part = _unescape_pn_local(name[nextind(name, colon_idx):end])
    if haskey(prefixes, prefix)
        return URIRef(prefixes[prefix] * local_part)
    end
    URIRef(name)
end

# ─── BASE resolution ──────────────────────────────────────────────
# The prologue stores the BASE IRI under the reserved key "@base" in the
# prefixes Dict ('@' can never appear in a PNAME prefix, so no collision).

const _BASE_KEY = "@base"

"""Build a URIRef from an IRIREF token value, resolving relative IRIs
against the query's BASE (if declared)."""
function _make_uri(value::AbstractString, prefixes::Dict{String,String})::URIRef
    base = get(prefixes, _BASE_KEY, nothing)
    if !isnothing(base) && isnothing(match(r"^[A-Za-z][A-Za-z0-9+.\-]*:", value))
        return URIRef(_sparql_resolve_base(base, value))
    end
    URIRef(String(value))
end

# Minimal RFC 3986-style relative reference resolution.
function _sparql_resolve_base(base::AbstractString, rel::AbstractString)::String
    isempty(rel) && return String(base)
    if startswith(rel, '#')
        h = findfirst('#', base)
        return string(isnothing(h) ? base : base[1:prevind(base, h)], rel)
    end
    if startswith(rel, "//")
        m = match(r"^[A-Za-z][A-Za-z0-9+.\-]*:", base)
        return isnothing(m) ? String(rel) : string(m.match, rel)
    end
    if startswith(rel, '/')
        m = match(r"^([A-Za-z][A-Za-z0-9+.\-]*://[^/]*)", base)
        return isnothing(m) ? String(rel) : string(m.captures[1], rel)
    end
    # Path-relative: drop base query/fragment, replace last path segment
    b = first(split(first(split(base, '#')), '?'))
    # Keep authority intact: find last '/' after scheme://authority
    m = match(r"^[A-Za-z][A-Za-z0-9+.\-]*://[^/]*", b)
    path_start = isnothing(m) ? firstindex(b) : nextind(b, lastindex(m.match))
    slash = findlast('/', b)
    prefix = if isnothing(slash) || (!isnothing(m) && slash < path_start)
        b * "/"
    else
        b[1:slash]
    end
    r = String(rel)
    while true
        if startswith(r, "./")
            r = r[3:end]
        elseif startswith(r, "../")
            r = r[4:end]
            p = rstrip(prefix, '/')
            j = findlast('/', p)
            if !isnothing(j) && (isnothing(m) || j >= path_start)
                prefix = p[1:j]
            end
        else
            break
        end
    end
    string(prefix, r)
end

# ─── Query-level parser ───────────────────────────────────────────

"""
    sparql_parse(query::AbstractString) -> SparqlQuery

Parse a SPARQL query string into a typed AST.
Returns one of: `SparqlSelect`, `SparqlAsk`, `SparqlConstruct`, `SparqlDescribe`.
"""
function sparql_parse(query::AbstractString)
    tz = _sparql_tokenize_all(strip(query))
    prefixes = _parse_prologue!(tz)
    q = _parse_query_body(tz, prefixes)
    # Whole input must be consumed — trailing garbage is a parse error
    if !_check(tz, TOK_EOF)
        tok = _peek(tz)
        error("Unexpected trailing input after query: $(tok.kind) '$(tok.value)' at position $(tok.pos)")
    end
    q
end

function _parse_prologue!(tz::_SparqlTokenizer,
                          prefixes::Dict{String,String}=Dict{String,String}())::Dict{String,String}
    while true
        if _check_keyword(tz, "PREFIX")
            _advance!(tz)
            pname_tok = _advance!(tz)  # PNAME_NS: PN_PREFIX? ':'
            # The declared prefix must be a PNAME_NS — exactly one ':', and it
            # must be the final char (no local part, no extra colons).
            nm = pname_tok.value
            c_idx = findfirst(':', nm)
            (pname_tok.kind == TOK_PNAME && !isnothing(c_idx) && c_idx == lastindex(nm)) ||
                error("Invalid PREFIX declaration '$(nm)' at position $(pname_tok.pos)")
            iri_tok = _expect!(tz, TOK_IRI)
            prefix = nm[1:prevind(nm, c_idx)]
            # Prefix IRIs are themselves resolved against any earlier BASE
            prefixes[prefix] = _make_uri(iri_tok.value, prefixes).value
        elseif _check_keyword(tz, "BASE")
            _advance!(tz)
            base_tok = _expect!(tz, TOK_IRI)
            # Successive BASE declarations resolve against the previous one
            prefixes[_BASE_KEY] = _make_uri(base_tok.value, prefixes).value
        elseif _check_keyword(tz, "VERSION")
            _advance!(tz)
            # SPARQL 1.2 VersionSpecifier ::= a short string literal only.
            # Reject bare numbers (VERSION 1.2) and long strings (VERSION """1.2""").
            vtok = _peek(tz)
            vtok.kind == TOK_STRING ||
                error("VERSION expects a quoted string, got $(vtok.kind) '$(vtok.value)' at position $(vtok.pos)")
            (startswith(vtok.value, "\"\"\"") || startswith(vtok.value, "'''")) &&
                error("VERSION expects a short string literal at position $(vtok.pos)")
            _advance!(tz)
        else
            break
        end
    end
    prefixes
end

function _parse_query_body(tz::_SparqlTokenizer, prefixes::Dict{String,String})
    tok = _peek(tz)
    if _check_keyword(tz, "SELECT")
        return _parse_select(tz, prefixes)
    elseif _check_keyword(tz, "ASK")
        return _parse_ask(tz, prefixes)
    elseif _check_keyword(tz, "CONSTRUCT")
        return _parse_construct(tz, prefixes)
    elseif _check_keyword(tz, "DESCRIBE")
        return _parse_describe(tz, prefixes)
    else
        error("Expected SELECT, ASK, CONSTRUCT, or DESCRIBE at position $(tok.pos)")
    end
end

# Parse FROM / FROM NAMED clauses (dataset declarations).
# Returns `(from, from_named)` vectors of graph IRIs. Callers that don't
# support dataset clauses simply discard the result (legacy behavior).
function _skip_from_clauses!(tz::_SparqlTokenizer, prefixes=Dict{String,String}())
    from = URIRef[]
    from_named = URIRef[]
    while _check_keyword(tz, "FROM")
        _advance!(tz)
        named = !isnothing(_match_keyword!(tz, "NAMED"))
        target = named ? from_named : from
        if _check(tz, TOK_IRI)
            push!(target, _make_uri(_advance!(tz).value, prefixes))
        elseif _check(tz, TOK_PNAME)
            push!(target, _resolve_pname(_advance!(tz).value, prefixes))
        end
    end
    (from, from_named)
end

# ─── SELECT ────────────────────────────────────────────────────────

function _parse_select(tz::_SparqlTokenizer, prefixes)
    _expect_keyword!(tz, "SELECT")

    distinct = !isnothing(_match_keyword!(tz, "DISTINCT"))
    reduced = !isnothing(_match_keyword!(tz, "REDUCED"))

    variables = String[]
    select_exprs = SelectExpr[]
    aggregates = SelectAggregate[]

    seen = Set{String}()   # projected names must be distinct
    is_star = false
    if _check(tz, TOK_STAR)
        is_star = true
        _advance!(tz)
    else
        while !_check_keyword(tz, "WHERE") && !_check_keyword(tz, "FROM") && !_check(tz, TOK_LBRACE) && !_check(tz, TOK_EOF)
            if _check(tz, TOK_VAR)
                v = _advance!(tz).value[2:end]
                v in seen && error("Projected variable ?$v appears more than once in SELECT")
                push!(seen, v)
                push!(variables, v)
            elseif _check(tz, TOK_LPAREN)
                _advance!(tz)  # (
                expr = _parse_expr(tz, prefixes)
                _expect_keyword!(tz, "AS")
                var = _expect!(tz, TOK_VAR)
                _expect!(tz, TOK_RPAREN)
                alias = var.value[2:end]
                # The AS alias must not already be a projected name in this SELECT.
                alias in seen && error("SELECT alias ?$alias is already used in this projection")
                push!(seen, alias)
                if expr isa ExprAggregate
                    push!(aggregates, SelectAggregate(expr, alias))
                else
                    push!(select_exprs, SelectExpr(expr, alias))
                end
            else
                break
            end
        end
    end

    from, from_named = _skip_from_clauses!(tz, prefixes)

    # WHERE clause
    _match_keyword!(tz, "WHERE")
    patterns = _parse_group_graph_pattern(tz, prefixes)

    # Solution modifiers
    group_by, group_binds, having, order_by, limit, offset = _parse_solution_modifiers(tz, prefixes)

    # SPARQL grammar scope rule: a project-expression alias `(... AS ?z)` must
    # not collide with a variable exposed by GROUP BY (a group key variable or a
    # `GROUP BY (expr AS ?z)` alias).
    # `SELECT *` is not allowed together with GROUP BY or aggregation.
    is_star && (!isempty(group_by) || !isempty(aggregates)) &&
        error("SELECT * is not allowed with GROUP BY or aggregates")
    if !isempty(group_by) || !isempty(aggregates)
        # Aggregation is in effect. Group keys are the GROUP BY variables (the
        # empty set when only bare aggregates are present). Every variable used
        # in the SELECT clause — whether projected directly or referenced inside
        # a non-aggregate projection expression — must be a group key (or an
        # alias defined earlier in the SELECT).
        gb_vars = Set{String}()
        for ge in group_by
            ge isa ExprVar && push!(gb_vars, ge.name)
        end
        for se in select_exprs
            se.alias in gb_vars &&
                error("SELECT alias ?$(se.alias) collides with a GROUP BY variable")
        end
        for sa in aggregates
            sa.alias in gb_vars &&
                error("SELECT alias ?$(sa.alias) collides with a GROUP BY variable")
        end
        # A plain projected variable must be a group key.
        for v in variables
            v in gb_vars ||
                error("Projected variable ?$v is not a GROUP BY key")
        end
        # Variables referenced outside aggregates in a SELECT expression must be
        # group keys, aggregate aliases, or earlier SELECT-expression aliases.
        avail = copy(gb_vars)
        for sa in aggregates; push!(avail, sa.alias); end
        for se in select_exprs
            evs = String[]
            _collect_nonagg_expr_vars!(evs, se.expr)
            for v in evs
                v in avail ||
                    error("Variable ?$v used in a SELECT expression is not a GROUP BY key")
            end
            push!(avail, se.alias)
        end
    end
    if isempty(group_by) && isempty(aggregates)
        # No GROUP BY: a project-expression alias `(... AS ?z)` must be a fresh
        # variable not already in-scope in the WHERE clause.
        ws_vars = Set{String}()
        for p in patterns; _collect_inscope_vars!(ws_vars, p); end
        for se in select_exprs
            se.alias in ws_vars &&
                error("SELECT alias ?$(se.alias) is already in-scope in the WHERE clause")
        end
    end
    append!(patterns, group_binds)

    # Trailing ValuesClause
    if _check_keyword(tz, "VALUES")
        push!(patterns, _parse_values(tz, prefixes))
    end

    SparqlSelect(variables, patterns, prefixes, limit, offset,
                 order_by, distinct, reduced, aggregates,
                 group_by, having, select_exprs, from, from_named)
end

# ─── ASK ───────────────────────────────────────────────────────────

function _parse_ask(tz::_SparqlTokenizer, prefixes)
    _expect_keyword!(tz, "ASK")
    _skip_from_clauses!(tz, prefixes)
    _match_keyword!(tz, "WHERE")
    patterns = _parse_group_graph_pattern(tz, prefixes)
    if _check_keyword(tz, "VALUES")
        push!(patterns, _parse_values(tz, prefixes))
    end
    SparqlAsk(patterns, prefixes)
end

# ─── CONSTRUCT ─────────────────────────────────────────────────────

function _parse_construct(tz::_SparqlTokenizer, prefixes)
    _expect_keyword!(tz, "CONSTRUCT")
    # CONSTRUCT WHERE { ... } shorthand — WHERE pattern is also the template
    if _check_keyword(tz, "WHERE") || _check_keyword(tz, "FROM")
        from, from_named = _skip_from_clauses!(tz, prefixes)
        _match_keyword!(tz, "WHERE")
        patterns = _parse_group_graph_pattern(tz, prefixes)
        # CONSTRUCT WHERE shorthand permits only a TriplesTemplate — no FILTER,
        # BIND, OPTIONAL, sub-select, etc.
        for p in patterns
            p isa PatTriple ||
                error("CONSTRUCT WHERE template may contain only triples")
        end
        # Extract PatTriple patterns as template. In a CONSTRUCT WHERE template,
        # parser-generated blank-node variables (`_:…`, from `[]`/`_:b` and the
        # desugaring of reifiers/annotation blocks) behave as TEMPLATE blank
        # nodes — minted fresh per solution — not as solution-bound variables.
        # (This mirrors the explicit-template CONSTRUCT, where these are BNodes.)
        # Mapping each distinct `_:label` to a stable BNode keeps a label shared
        # across template triples consistent within one solution.
        tmpl_bnodes = Dict{String,BNode}()
        _cw_term(t) = if t isa AbstractString && startswith(t, "_:")
            get!(() -> BNode(t[3:end]), tmpl_bnodes, t)
        elseif t isa TripleTermPattern
            TripleTermPattern(_cw_term(t.subject), t.predicate, _cw_term(t.object))
        else
            t
        end
        template = PatTriple[PatTriple(_cw_term(p.subject), _cw_term(p.predicate), _cw_term(p.object))
                             for p in patterns if p isa PatTriple]
        group_by, group_binds, having, order_by, limit, offset = _parse_solution_modifiers(tz, prefixes)
        if _check_keyword(tz, "VALUES")
            push!(patterns, _parse_values(tz, prefixes))
        end
        return SparqlConstruct(template, patterns, prefixes, limit, offset, order_by, from, from_named)
    end
    template = _parse_construct_template(tz, prefixes)
    from, from_named = _skip_from_clauses!(tz, prefixes)
    _match_keyword!(tz, "WHERE")
    patterns = _parse_group_graph_pattern(tz, prefixes)
    group_by, group_binds, having, order_by, limit, offset = _parse_solution_modifiers(tz, prefixes)
    if _check_keyword(tz, "VALUES")
        push!(patterns, _parse_values(tz, prefixes))
    end
    SparqlConstruct(template, patterns, prefixes, limit, offset, order_by, from, from_named)
end

function _parse_construct_template(tz::_SparqlTokenizer, prefixes)
    _expect!(tz, TOK_LBRACE)
    triples = PatTriple[]
    while !_check(tz, TOK_RBRACE) && !_check(tz, TOK_EOF)
        n_before = length(triples)
        s = _parse_term_or_node(tz, prefixes, triples; as_var=false)
        # Standalone property list subject: `[ :p :o ] .`
        if length(triples) > n_before && (_check(tz, TOK_DOT) || _check(tz, TOK_RBRACE))
            _match!(tz, TOK_DOT)
            continue
        end
        _parse_predicate_object_list!(tz, prefixes, s, triples; as_var=false)
        _match!(tz, TOK_DOT)
    end
    _expect!(tz, TOK_RBRACE)
    triples
end

# ─── DESCRIBE ──────────────────────────────────────────────────────

function _parse_describe(tz::_SparqlTokenizer, prefixes)
    _expect_keyword!(tz, "DESCRIBE")
    terms = Any[]
    if _check(tz, TOK_STAR)
        _advance!(tz)
    else
        while !_check_keyword(tz, "WHERE") && !_check_keyword(tz, "FROM") && !_check(tz, TOK_LBRACE) && !_check(tz, TOK_EOF)
            if _check(tz, TOK_VAR)
                push!(terms, ExprVar(_advance!(tz).value[2:end]))
            elseif _check(tz, TOK_IRI)
                push!(terms, ExprURI(_make_uri(_advance!(tz).value, prefixes)))
            elseif _check(tz, TOK_PNAME)
                push!(terms, ExprURI(_resolve_pname(_advance!(tz).value, prefixes)))
            else
                break
            end
        end
    end
    _skip_from_clauses!(tz, prefixes)
    patterns = SparqlPattern[]
    if _check_keyword(tz, "WHERE") || _check(tz, TOK_LBRACE)
        _match_keyword!(tz, "WHERE")
        patterns = _parse_group_graph_pattern(tz, prefixes)
    end
    SparqlDescribe(terms, patterns, prefixes)
end

# ─── Group graph pattern ──────────────────────────────────────────

function _parse_group_graph_pattern(tz::_SparqlTokenizer, prefixes)::Vector{SparqlPattern}
    _expect!(tz, TOK_LBRACE)
    patterns = _parse_group_body(tz, prefixes)
    _expect!(tz, TOK_RBRACE)
    patterns
end

# Whether a flattened nested group must be wrapped in PatGroup to preserve
# FILTER/BIND variable scoping. A FILTER is scope-sensitive (it must not see
# variables bound only outside its group). A bare BGP group is join-equivalent
# to the surrounding group and need not be wrapped.
function _group_needs_scope(pats::Vector{SparqlPattern})
    # A nested group must retain its own algebra boundary (be kept as a PatGroup
    # rather than flattened into the surrounding group) whenever flattening would
    # change the algebra. FILTER scope aside, an OPTIONAL/MINUS inside the group
    # is translated as LeftJoin/Minus whose *left* operand is the group's own
    # preceding patterns; flattening would wrongly extend that left operand to the
    # surrounding group's earlier patterns (SPARQL algebra "Join scope" test).
    # A BIND likewise needs its own scope: an expression in a nested group's
    # BIND only sees variables bound *within that group* (SPARQL "BIND scope" —
    # e.g. `{ ?s ?p ?o } { BIND(?o+1 AS ?z) }` leaves ?z unbound because ?o is
    # not in scope inside the second group). Flattening would wrongly expose ?o.
    any(p -> p isa PatFilter || p isa PatFilterExists ||
             p isa PatOptional || p isa PatMinus || p isa PatBind, pats)
end

# Collect variable names referenced in an expression OUTSIDE of any aggregate
# (aggregate arguments are evaluated per-group and need not be group keys).
function _collect_nonagg_expr_vars!(out::Vector{String}, e)
    if e isa ExprVar
        push!(out, e.name)
    elseif e isa ExprBinaryOp
        _collect_nonagg_expr_vars!(out, e.left); _collect_nonagg_expr_vars!(out, e.right)
    elseif e isa ExprUnaryOp
        _collect_nonagg_expr_vars!(out, e.arg)
    elseif e isa ExprFunctionCall
        for a in e.args; _collect_nonagg_expr_vars!(out, a); end
    elseif e isa ExprIn
        _collect_nonagg_expr_vars!(out, e.expr)
        for a in e.values; _collect_nonagg_expr_vars!(out, a); end
    elseif e isa TripleTermPattern
        e.subject isa String && push!(out, e.subject)
        e.predicate isa String && push!(out, e.predicate)
        e.object isa String && push!(out, e.object)
    end
    # ExprAggregate / ExprExists: do not descend (aggregate args are allowed).
end

# Collect variable names that a pattern brings into scope (for BIND-freshness
# checks). Conservative: includes vars from nested OPTIONAL/UNION/GRAPH/etc.
function _collect_inscope_vars!(out::Set{String}, p)
    _collect_term_in!(t) = (t isa String && push!(out, t);
                            t isa TripleTermPattern && (_collect_term_in!(t.subject);
                            _collect_term_in!(t.predicate); _collect_term_in!(t.object)))
    if p isa PatTriple
        _collect_term_in!(p.subject); _collect_term_in!(p.predicate); _collect_term_in!(p.object)
    elseif p isa PatBind
        push!(out, p.var)
    elseif p isa PatValues
        for v in p.variables; push!(out, v); end
    elseif p isa PatGroup
        for q in p.patterns; _collect_inscope_vars!(out, q); end
    elseif p isa PatOptional
        for q in p.patterns; _collect_inscope_vars!(out, q); end
    elseif p isa PatMinus
        # MINUS does not bind variables into the outer scope.
    elseif p isa PatUnion
        for br in p.branches, q in br; _collect_inscope_vars!(out, q); end
    elseif p isa PatGraph
        p.graph_term isa ExprVar && push!(out, p.graph_term.name)
        for q in p.patterns; _collect_inscope_vars!(out, q); end
    elseif p isa PatService
        for q in p.patterns; _collect_inscope_vars!(out, q); end
    elseif p isa PatLateral
        for q in p.patterns; _collect_inscope_vars!(out, q); end
    elseif p isa PatSubquery
        sq = p.query
        if sq isa SparqlSelect
            for v in sq.variables; push!(out, v); end
            for se in sq.select_exprs; push!(out, se.alias); end
            for sa in sq.aggregates; push!(out, sa.alias); end
        end
    end
end

# Collect blank-node labels appearing in a parsed pattern (recursively).
function _collect_bnode_labels!(out::Set{String}, p)
    addt = t -> begin
        t isa BNode && push!(out, t.id)
        t isa TripleTermPattern && (addt(t.subject); addt(t.predicate); addt(t.object))
    end
    if p isa PatTriple
        addt(p.subject); addt(p.predicate); addt(p.object)
    elseif p isa PatGroup || p isa PatOptional || p isa PatMinus ||
           p isa PatService || p isa PatLateral || p isa PatFilterExists
        for q in p.patterns; _collect_bnode_labels!(out, q); end
    elseif p isa PatGraph
        for q in p.patterns; _collect_bnode_labels!(out, q); end
    elseif p isa PatUnion
        for br in p.branches, q in br; _collect_bnode_labels!(out, q); end
    end
end

# A blank-node label may not be shared across the branches of a UNION.
function _check_union_bnode_scope(branches::Vector{Vector{SparqlPattern}})
    seen = Set{String}()
    for branch in branches
        bl = Set{String}()
        for p in branch; _collect_bnode_labels!(bl, p); end
        for lbl in bl
            lbl in seen &&
                error("Blank node label _:$lbl reused across UNION branches")
        end
        union!(seen, bl)
    end
end

function _parse_group_body(tz::_SparqlTokenizer, prefixes)::Vector{SparqlPattern}
    patterns = SparqlPattern[]
    n_elements = 0   # number of group elements parsed (incl. empty `{}`)
    # Cross-BGP blank-node label scoping: a label used in one BGP region may not
    # reappear in a different region of the same group (regions are separated by
    # any GraphPatternNotTriples — OPTIONAL/UNION/GRAPH/MINUS/nested group/etc.).
    closed_bnode_labels = Set{String}()  # labels from prior closed regions
    region_tb_labels = Set{String}()      # labels from triples blocks in current region
    region_start = 1                      # index of first pattern of current region
    # Grammar: GroupGraphPatternSub ::= TriplesBlock?
    #   ( GraphPatternNotTriples '.'? TriplesBlock? )*
    # An optional '.' separator may follow a GraphPatternNotTriples; it is
    # consumed at the end of each such branch (`_match!(tz, TOK_DOT)`). A bare
    # or doubled '.' that does not follow a GraphPatternNotTriples is illegal
    # and falls through to `_parse_triples_block`, which rejects it.
    while !_check(tz, TOK_RBRACE) && !_check(tz, TOK_EOF)
        tok = _peek(tz)
        is_not_triples = true  # set false in the TriplesBlock branch
        # Whether this group element starts a *new* Basic Graph Pattern region
        # for blank-node-label scoping (SPARQL 1.1 §19.6). FILTER, BIND and
        # VALUES do NOT split a BGP — adjacent triples blocks separated only by
        # such constructs form one BGP, so a blank-node label may be shared.
        # Genuine splitters: OPTIONAL/MINUS/LATERAL/GRAPH/SERVICE/UNION/group/
        # subquery (these set `splits_bgp = true` below).
        splits_bgp = false

        if _check_keyword(tz, "OPTIONAL")
            splits_bgp = true
            _advance!(tz)
            pats = _parse_group_graph_pattern(tz, prefixes)
            push!(patterns, PatOptional(pats))

        elseif _check_keyword(tz, "MINUS")
            splits_bgp = true
            _advance!(tz)
            pats = _parse_group_graph_pattern(tz, prefixes)
            push!(patterns, PatMinus(pats))

        elseif _check_keyword(tz, "LATERAL")
            splits_bgp = true
            _advance!(tz)
            pats = _parse_group_graph_pattern(tz, prefixes)
            push!(patterns, PatLateral(pats))

        elseif _check_keyword(tz, "FILTER")
            _advance!(tz)
            if _check_keyword(tz, "EXISTS")
                _advance!(tz)
                pats = _parse_group_graph_pattern(tz, prefixes)
                push!(patterns, PatFilterExists(pats, false))
            elseif _check_keyword(tz, "NOT")
                _advance!(tz)
                _expect_keyword!(tz, "EXISTS")
                pats = _parse_group_graph_pattern(tz, prefixes)
                push!(patterns, PatFilterExists(pats, true))
            else
                # Grammar: Constraint ::= BrackettedExpression
                #                       | BuiltInCall | FunctionCall
                # A bare term (e.g. `FILTER ?x`) is NOT a valid constraint.
                if _check(tz, TOK_LPAREN)
                    _advance!(tz)
                    expr = _parse_expr(tz, prefixes)
                    _expect!(tz, TOK_RPAREN)
                elseif _check(tz, TOK_KEYWORD) || _check(tz, TOK_PNAME) || _check(tz, TOK_IRI)
                    # Bare builtin/function call: FILTER regex(...), FILTER ex:fn(...)
                    expr = _parse_expr(tz, prefixes)
                else
                    t = _peek(tz)
                    error("FILTER constraint must be a bracketted expression or a function call, got $(t.kind) '$(t.value)' at position $(t.pos)")
                end
                push!(patterns, PatFilter(expr))
            end

        elseif _check_keyword(tz, "BIND")
            _advance!(tz)
            _expect!(tz, TOK_LPAREN)
            expr = _parse_expr(tz, prefixes)
            _expect_keyword!(tz, "AS")
            var = _expect!(tz, TOK_VAR)
            _expect!(tz, TOK_RPAREN)
            bvar = var.value[2:end]
            # The BIND target must be a fresh variable: it may not already be
            # in-scope in this group (SPARQL grammar note on BIND).
            in_scope = Set{String}()
            for prev in patterns; _collect_inscope_vars!(in_scope, prev); end
            bvar in in_scope &&
                error("BIND variable ?$bvar is already in-scope at position $(var.pos)")
            push!(patterns, PatBind(expr, bvar))

        elseif _check_keyword(tz, "VALUES")
            push!(patterns, _parse_values(tz, prefixes))

        elseif _check_keyword(tz, "GRAPH")
            splits_bgp = true
            _advance!(tz)
            gt = if _check(tz, TOK_VAR)
                ExprVar(_advance!(tz).value[2:end])
            else
                ExprURI(_parse_iri(tz, prefixes))
            end
            pats = _parse_group_graph_pattern(tz, prefixes)
            push!(patterns, PatGraph(gt, pats))

        elseif _check_keyword(tz, "SERVICE")
            splits_bgp = true
            _advance!(tz)
            silent = !isnothing(_match_keyword!(tz, "SILENT"))
            ep = if _check(tz, TOK_VAR)
                ExprVar(_advance!(tz).value[2:end])
            else
                ExprURI(_parse_iri(tz, prefixes))
            end
            pats = _parse_group_graph_pattern(tz, prefixes)
            push!(patterns, PatService(ep, pats, silent))

        elseif _check_keyword(tz, "SELECT")
            # A SubSelect is the *entire* content of a GroupGraphPattern; it may
            # only appear as the first (and only) element. `{ {} SELECT … }` is
            # illegal (the empty `{}` already counts as an element).
            splits_bgp = true
            n_elements == 0 ||
                error("SELECT subquery must be the sole content of a group at position $(_peek(tz).pos)")
            subq = _parse_select(tz, prefixes)
            push!(patterns, PatSubquery(subq))
            # Nothing may follow a bare SubSelect within the same braces.
            (_check(tz, TOK_RBRACE) || _check(tz, TOK_EOF)) ||
                error("Unexpected input after SELECT subquery at position $(_peek(tz).pos)")

        elseif _check(tz, TOK_LBRACE)
            # Subquery or nested group or UNION
            splits_bgp = true
            saved_idx = tz.idx
            _advance!(tz)
            if _check_keyword(tz, "SELECT")
                tz.idx = saved_idx
                _advance!(tz)  # {
                subq = _parse_select(tz, prefixes)
                _expect!(tz, TOK_RBRACE)
                sub = PatSubquery(subq)
                # Check for UNION
                if _check_keyword(tz, "UNION")
                    branches = Vector{SparqlPattern}[[sub]]
                    while _check_keyword(tz, "UNION")
                        _advance!(tz)
                        pats = _parse_group_graph_pattern(tz, prefixes)
                        push!(branches, pats)
                    end
                    _check_union_bnode_scope(branches)
                    push!(patterns, PatUnion(branches))
                else
                    push!(patterns, sub)
                end
            else
                # Nested group → could be start of UNION
                tz.idx = saved_idx
                first_pats = _parse_group_graph_pattern(tz, prefixes)
                if _check_keyword(tz, "UNION")
                    branches = Vector{SparqlPattern}[first_pats]
                    while _check_keyword(tz, "UNION")
                        _advance!(tz)
                        pats = _parse_group_graph_pattern(tz, prefixes)
                        push!(branches, pats)
                    end
                    _check_union_bnode_scope(branches)
                    push!(patterns, PatUnion(branches))
                elseif _group_needs_scope(first_pats)
                    # A nested group containing a FILTER (or BIND) must keep its
                    # own scope: evaluate it as an independent join unit so the
                    # FILTER cannot see variables bound only outside the group.
                    push!(patterns, PatGroup(first_pats))
                else
                    append!(patterns, first_pats)
                end
            end

        else
            # Triple pattern(s): subject predicate-object-list
            is_not_triples = false
            triples = _parse_triples_block(tz, prefixes)
            # A blank-node label in this triples block must not have appeared in
            # a previously-closed BGP region of this group.
            tb_labels = Set{String}()
            for t in triples; _collect_bnode_labels!(tb_labels, t); end
            for lbl in tb_labels
                lbl in closed_bnode_labels &&
                    error("Blank node label _:$lbl reused across a basic graph pattern boundary")
                push!(region_tb_labels, lbl)
            end
            append!(patterns, triples)
            # A TriplesBlock consumes all '.'-separated triples; if another
            # triple subject follows immediately, a '.' separator was missing.
            if _starts_triples_same_subject(tz)
                t = _peek(tz)
                error("Expected '.' between triples, got $(t.kind) '$(t.value)' at position $(t.pos)")
            end
        end

        if splits_bgp
            # A BGP-splitting GraphPatternNotTriples is its own BGP region. Its
            # blank-node labels must not appear in the surrounding group's other
            # regions. (FILTER/BIND/VALUES do NOT split a BGP, so they leave the
            # current triples-block region open — see `splits_bgp` above.)
            elem_labels = Set{String}()
            for k in region_start:length(patterns)
                _collect_bnode_labels!(elem_labels, patterns[k])
            end
            for lbl in elem_labels
                (lbl in closed_bnode_labels || lbl in region_tb_labels) &&
                    error("Blank node label _:$lbl reused across a basic graph pattern boundary")
            end
            # Close the region: all labels seen so far become unusable later.
            union!(closed_bnode_labels, region_tb_labels)
            union!(closed_bnode_labels, elem_labels)
            empty!(region_tb_labels)
            region_start = length(patterns) + 1
        end

        # Optional '.' separator after a GraphPatternNotTriples.
        is_not_triples && _match!(tz, TOK_DOT)
        n_elements += 1
    end
    patterns
end

# ─── Triple patterns ──────────────────────────────────────────────

const _SPARQL_RDF_NS = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
const _SPARQL_RDF_FIRST = URIRef(_SPARQL_RDF_NS * "first")
const _SPARQL_RDF_REST = URIRef(_SPARQL_RDF_NS * "rest")
const _SPARQL_RDF_NIL = URIRef(_SPARQL_RDF_NS * "nil")

# Fresh anonymous-node counter for blank node property lists / collections.
# In WHERE patterns these become variables (per SPARQL semantics blank nodes
# in patterns behave as variables); the "_:" prefix cannot clash with a user
# variable name and is filtered from SELECT * projections.
const _ANON_NODE_COUNTER = Ref(0)
_fresh_anon_var() = "_:anon$(_ANON_NODE_COUNTER[] += 1)"

const _SPARQL_RDF_REIFIES = URIRef(_SPARQL_RDF_NS * "reifies")

# ─── SPARQL 1.2 triple terms / reification ────────────────────────
#
# Triple term:    <<( s p o )>>          → TripleTermPattern (a term value)
# Reified triple: << s p o (~reifier)? >> → introduces a reifier node `r` and
#                 emits `r rdf:reifies <<( s p o )>>`; the reified-triple
#                 expression denotes `r` (a fresh blank node / variable when
#                 the reifier is anonymous, otherwise the given iri/var/bnode).

# Parse the inner `s p o` of a triple term and return a TripleTermPattern.
# `subject`/`object` are VarOrTerm (incl. nested triple terms, []); `predicate`
# is a verb (iri/`a`/var) but NOT a property path. No collections allowed.
function _parse_triple_term_inner(tz::_SparqlTokenizer, prefixes, acc; as_var::Bool=true, in_expr::Bool=false)
    s = _parse_tt_subobj(tz, prefixes, acc; as_var=as_var, in_expr=in_expr, is_subject=true)
    p = _parse_tt_predicate(tz, prefixes)
    o = _parse_tt_subobj(tz, prefixes, acc; as_var=as_var, in_expr=in_expr, is_subject=false)
    return TripleTermPattern(s, p, o)
end

# Subject/object position inside a triple term: a term, [], or (object only) a
# nested triple term. Collections `( ... )` and reifiers are NOT allowed here.
# The *subject* position cannot be a triple term. In expression context (BIND
# etc.), blank nodes (`[]` and reified triples) are not allowed.
function _parse_tt_subobj(tz::_SparqlTokenizer, prefixes, acc; as_var::Bool=true,
                          in_expr::Bool=false, is_subject::Bool=false)
    if _check(tz, TOK_LTLT_PAREN)
        (is_subject && in_expr) && error("A triple term is not allowed in the subject position of a triple term at position $(_peek(tz).pos)")
        return _parse_triple_term(tz, prefixes, acc; as_var=as_var, in_expr=in_expr)
    end
    if _check(tz, TOK_LTLT)
        in_expr && error("Reified triples are not allowed in expressions at position $(_peek(tz).pos)")
        return _parse_reified_triple_term(tz, prefixes, acc; as_var=as_var)
    end
    if _check(tz, TOK_LBRACKET)
        in_expr && error("Blank node not allowed in a triple term in an expression at position $(_peek(tz).pos)")
        _advance!(tz)
        node = as_var ? _fresh_anon_var() : BNode()
        # Only the empty blank node `[]` is allowed inside a triple term.
        _expect!(tz, TOK_RBRACKET)
        return node
    end
    if _check(tz, TOK_BNODE) && in_expr
        error("Blank node not allowed in a triple term in an expression at position $(_peek(tz).pos)")
    end
    if _check(tz, TOK_LPAREN)
        t = _peek(tz)
        error("Collections are not allowed inside a triple term at position $(t.pos)")
    end
    if is_subject && _peek(tz).kind in (TOK_STRING, TOK_INTEGER, TOK_DECIMAL, TOK_DOUBLE, TOK_TRUE, TOK_FALSE)
        t = _peek(tz)
        error("A literal is not allowed in the subject position of a triple term at position $(t.pos)")
    end
    _parse_term(tz, prefixes)
end

# Predicate position inside a triple term: `a`, a variable, or an IRI — never a
# property path or a blank node.
function _parse_tt_predicate(tz::_SparqlTokenizer, prefixes)
    if _check(tz, TOK_A)
        _advance!(tz)
        return URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    end
    if _check(tz, TOK_VAR)
        return _advance!(tz).value[2:end]
    end
    if _check(tz, TOK_IRI) || _check(tz, TOK_PNAME)
        return _parse_iri(tz, prefixes)
    end
    t = _peek(tz)
    error("Expected IRI or variable as triple-term predicate, got $(t.kind) '$(t.value)' at position $(t.pos)")
end

# `<<( s p o )>>`  →  TripleTermPattern
function _parse_triple_term(tz::_SparqlTokenizer, prefixes, acc; as_var::Bool=true, in_expr::Bool=false)
    _expect!(tz, TOK_LTLT_PAREN)
    tt = _parse_triple_term_inner(tz, prefixes, acc; as_var=as_var, in_expr=in_expr)
    _expect!(tz, TOK_RPAREN_GTGT)
    return tt
end

# `<< s p o (~ reifier)? >>` as a *term* → emit `reifier rdf:reifies <<(s p o)>>`
# onto `acc` and return the reifier node.
function _parse_reified_triple_term(tz::_SparqlTokenizer, prefixes, acc; as_var::Bool=true)
    _expect!(tz, TOK_LTLT)
    tt = _parse_triple_term_inner(tz, prefixes, acc; as_var=as_var)
    reifier = _parse_optional_reifier(tz, prefixes, acc; as_var=as_var)
    _expect!(tz, TOK_GTGT)
    push!(acc, PatTriple(reifier, _SPARQL_RDF_REIFIES, tt))
    return reifier
end

# Parse an optional `~ reifier`. Returns the reifier node (a fresh anon
# var/bnode when absent or when `~` is given without an explicit term).
function _parse_optional_reifier(tz::_SparqlTokenizer, prefixes, acc; as_var::Bool=true)
    if _check(tz, TOK_TILDE)
        _advance!(tz)
        # `~` may be followed by an explicit reifier term (iri/var/bnode) or
        # nothing (anonymous reifier).
        if _check(tz, TOK_IRI) || _check(tz, TOK_PNAME)
            return _parse_iri(tz, prefixes)
        elseif _check(tz, TOK_VAR)
            return _advance!(tz).value[2:end]
        elseif _check(tz, TOK_BNODE)
            t = _advance!(tz)
            return as_var ? string(t.value) : BNode(t.value[3:end])
        elseif _check(tz, TOK_LBRACKET)
            _advance!(tz)
            _expect!(tz, TOK_RBRACKET)
            return as_var ? _fresh_anon_var() : BNode()
        end
        return as_var ? _fresh_anon_var() : BNode()
    end
    return as_var ? _fresh_anon_var() : BNode()
end

"""
Parse a graph node: a plain term, a blank node property list
`[ :p :o ; ... ]`, or a collection `( e1 e2 ... )`.

Nested triples generated by property lists / collections are pushed onto
`acc`. When `as_var` is true (WHERE patterns), allocated blank nodes are
represented as fresh internal variables; when false (templates), as BNodes.
"""
function _parse_term_or_node(tz::_SparqlTokenizer, prefixes, acc::AbstractVector; as_var::Bool=true)
    # SPARQL 1.2 triple term: <<( s p o )>>
    if _check(tz, TOK_LTLT_PAREN)
        return _parse_triple_term(tz, prefixes, acc; as_var=as_var)
    end
    # SPARQL 1.2 reified triple as a term: << s p o (~ reifier)? >>
    if _check(tz, TOK_LTLT)
        return _parse_reified_triple_term(tz, prefixes, acc; as_var=as_var)
    end
    if _check(tz, TOK_LBRACKET)
        _advance!(tz)
        node = as_var ? _fresh_anon_var() : BNode()
        if _check(tz, TOK_RBRACKET)
            _advance!(tz)
            return node
        end
        _parse_predicate_object_list!(tz, prefixes, node, acc; as_var=as_var)
        _expect!(tz, TOK_RBRACKET)
        return node
    end
    if _check(tz, TOK_LPAREN)
        _advance!(tz)
        items = Any[]
        while !_check(tz, TOK_RPAREN) && !_check(tz, TOK_EOF)
            push!(items, _parse_term_or_node(tz, prefixes, acc; as_var=as_var))
        end
        _expect!(tz, TOK_RPAREN)
        isempty(items) && return _SPARQL_RDF_NIL
        head = as_var ? _fresh_anon_var() : BNode()
        cur = head
        for (i, item) in enumerate(items)
            push!(acc, PatTriple(cur, _SPARQL_RDF_FIRST, item))
            if i < length(items)
                nxt = as_var ? _fresh_anon_var() : BNode()
                push!(acc, PatTriple(cur, _SPARQL_RDF_REST, nxt))
                cur = nxt
            else
                push!(acc, PatTriple(cur, _SPARQL_RDF_REST, _SPARQL_RDF_NIL))
            end
        end
        return head
    end
    _parse_term(tz, prefixes)
end

# Parse SPARQL 1.2 annotation following a triple object: a sequence of
# reifiers `~r` and annotation blocks `{| predicateObjectList |}`. Desugars by
# emitting `reifier rdf:reifies <<( s p o )>>` and the annotation triples onto
# `acc`. Multiple annotation blocks reuse the most-recent reifier (a fresh one
# is created when a block appears with no preceding reifier).
function _parse_annotation!(tz::_SparqlTokenizer, prefixes, s, p, o, acc::AbstractVector; as_var::Bool=true)
    # An annotation/reifier may follow only a plain `s p o` triple — a property
    # path predicate cannot be reified/annotated.
    if _check(tz, TOK_TILDE) || _check(tz, TOK_ANNOT_OPEN)
        if !(p isa URIRef || p isa String)
            t = _peek(tz)
            error("Reifier/annotation is not allowed on a property-path triple at position $(t.pos)")
        end
    end
    # The reified triple term to relate via rdf:reifies.
    tt = TripleTermPattern(s, p, o)
    current_reifier = nothing
    while true
        if _check(tz, TOK_TILDE)
            _advance!(tz)
            r = if _check(tz, TOK_IRI) || _check(tz, TOK_PNAME)
                _parse_iri(tz, prefixes)
            elseif _check(tz, TOK_VAR)
                _advance!(tz).value[2:end]
            elseif _check(tz, TOK_BNODE)
                t = _advance!(tz)
                as_var ? string(t.value) : BNode(t.value[3:end])
            elseif _check(tz, TOK_LBRACKET)
                _advance!(tz); _expect!(tz, TOK_RBRACKET)
                as_var ? _fresh_anon_var() : BNode()
            else
                as_var ? _fresh_anon_var() : BNode()
            end
            push!(acc, PatTriple(r, _SPARQL_RDF_REIFIES, tt))
            current_reifier = r
        elseif _check(tz, TOK_ANNOT_OPEN)
            _advance!(tz)
            if current_reifier === nothing
                current_reifier = as_var ? _fresh_anon_var() : BNode()
                push!(acc, PatTriple(current_reifier, _SPARQL_RDF_REIFIES, tt))
            end
            _parse_predicate_object_list!(tz, prefixes, current_reifier, acc; as_var=as_var)
            _expect!(tz, TOK_ANNOT_CLOSE)
        else
            break
        end
    end
    return current_reifier
end

"""Parse `verb objectList ( ';' ( verb objectList )? )*` for subject `subj`,
pushing PatTriples onto `acc`."""
function _parse_predicate_object_list!(tz::_SparqlTokenizer, prefixes, subj, acc::AbstractVector; as_var::Bool=true)
    while true
        pred = _parse_verb(tz, prefixes)
        while true
            obj = _parse_term_or_node(tz, prefixes, acc; as_var=as_var)
            push!(acc, PatTriple(subj, pred, obj))
            # SPARQL 1.2 reifier `~r` and/or annotation blocks `{| ... |}`
            # may follow an object. They only apply to a plain `s p o` triple
            # (predicate must be an IRI/`a`/var, not a property path).
            _parse_annotation!(tz, prefixes, subj, pred, obj, acc; as_var=as_var)
            if _check(tz, TOK_COMMA)
                _advance!(tz)
            else
                break
            end
        end
        if _check(tz, TOK_SEMICOLON)
            _advance!(tz)
            # A ';' may be trailing: terminated by '.'/'}'/']'/EOF, or by
            # whatever follows the triples block (e.g. a GraphPatternNotTriples
            # keyword like FILTER/OPTIONAL). Continue only if a verb follows.
            nxt = _peek(tz).kind
            if !(nxt in (TOK_A, TOK_VAR, TOK_IRI, TOK_PNAME, TOK_CARET, TOK_BANG, TOK_LPAREN))
                break
            end
        else
            break
        end
    end
end

# TriplesBlock ::= TriplesSameSubjectPath ( '.' TriplesBlock? )?
# Consecutive triples MUST be '.'-separated; the final '.' is optional. A
# missing dot between two triples is a syntax error (caught here).
function _parse_triples_block(tz::_SparqlTokenizer, prefixes)::Vector{SparqlPattern}
    patterns = SparqlPattern[]
    while true
        n_before = length(patterns)
        subj = _parse_term_or_node(tz, prefixes, patterns)

        # A blank node property list / collection may stand alone as a subject
        # with no following predicate-object list: `[ :p :o ] .`
        if length(patterns) > n_before && (_check(tz, TOK_DOT) || _check(tz, TOK_RBRACE) || _check(tz, TOK_EOF))
            # standalone subject — fall through to dot handling below
        else
            _parse_predicate_object_list!(tz, prefixes, subj, patterns)
        end

        if _check(tz, TOK_DOT)
            _advance!(tz)
            # A '.' may end the block (followed by '}' or a
            # GraphPatternNotTriples) or separate it from the next triple.
            if !_starts_triples_same_subject(tz)
                break
            end
        else
            break  # no dot ⇒ end of this TriplesBlock
        end
    end
    patterns
end

# Whether the current token can begin a TriplesSameSubject (a VarOrTerm or
# TriplesNode subject). Used to decide if a '.' separates more triples.
function _starts_triples_same_subject(tz::_SparqlTokenizer)::Bool
    k = _peek(tz).kind
    k in (TOK_VAR, TOK_IRI, TOK_PNAME, TOK_BNODE, TOK_A, TOK_STRING,
          TOK_INTEGER, TOK_DECIMAL, TOK_DOUBLE, TOK_TRUE, TOK_FALSE,
          TOK_LBRACKET, TOK_LPAREN, TOK_LTLT, TOK_LTLT_PAREN)
end

function _parse_verb(tz::_SparqlTokenizer, prefixes)
    if _check(tz, TOK_A)
        _advance!(tz)
        return URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    end
    if _check(tz, TOK_VAR)
        return _advance!(tz).value[2:end]  # variable name
    end
    # Property path or IRI
    _parse_path_or_iri(tz, prefixes)
end

function _parse_path_or_iri(tz::_SparqlTokenizer, prefixes)
    # Try to parse a property path
    path = _parse_path_alternative(tz, prefixes)
    path
end

# ─── Property Path Parser ─────────────────────────────────────────

function _parse_path_alternative(tz::_SparqlTokenizer, prefixes)
    left = _parse_path_sequence(tz, prefixes)
    if _check(tz, TOK_PIPE)
        options = Any[left]
        while _check(tz, TOK_PIPE)
            _advance!(tz)
            push!(options, _parse_path_sequence(tz, prefixes))
        end
        return PathAlternative(PathExpr[_to_path_expr(o) for o in options])
    end
    left
end

function _parse_path_sequence(tz::_SparqlTokenizer, prefixes)
    left = _parse_path_elt(tz, prefixes)
    if _check(tz, TOK_SLASH)
        steps = Any[left]
        while _check(tz, TOK_SLASH)
            _advance!(tz)
            push!(steps, _parse_path_elt(tz, prefixes))
        end
        return PathSequence(PathExpr[_to_path_expr(s) for s in steps])
    end
    left
end

function _parse_path_elt(tz::_SparqlTokenizer, prefixes)
    # Inverse
    if _check(tz, TOK_CARET)
        _advance!(tz)
        inner = _parse_path_primary(tz, prefixes)
        path = PathInverse(_to_path_expr(inner))
        return _parse_path_modifier(tz, path)
    end
    primary = _parse_path_primary(tz, prefixes)
    _parse_path_modifier(tz, primary)
end

function _parse_path_modifier(tz::_SparqlTokenizer, path)
    if _check(tz, TOK_STAR)
        _advance!(tz)
        return PathZeroOrMore(_to_path_expr(path))
    elseif _check(tz, TOK_PLUS)
        _advance!(tz)
        return PathOneOrMore(_to_path_expr(path))
    elseif _check(tz, TOK_QUESTION)
        _advance!(tz)
        return PathZeroOrOne(_to_path_expr(path))
    end
    path
end

function _parse_path_primary(tz::_SparqlTokenizer, prefixes)
    if _check(tz, TOK_LPAREN)
        _advance!(tz)
        path = _parse_path_alternative(tz, prefixes)
        _expect!(tz, TOK_RPAREN)
        return path
    end
    if _check(tz, TOK_BANG)
        _advance!(tz)
        return _parse_path_negated(tz, prefixes)
    end
    if _check(tz, TOK_A)
        _advance!(tz)
        return PathURI(URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"))
    end
    _parse_iri(tz, prefixes)
end

function _parse_path_negated(tz::_SparqlTokenizer, prefixes)
    fwd = URIRef[]
    inv = URIRef[]
    # PathOneInPropertySet ::= iri | 'a' | '^' ( iri | 'a' )
    # (_parse_iri accepts TOK_A and returns rdf:type)
    parse_member! = function ()
        if _check(tz, TOK_CARET)
            _advance!(tz)
            push!(inv, _parse_iri(tz, prefixes))
        else
            push!(fwd, _parse_iri(tz, prefixes))
        end
    end
    if _check(tz, TOK_LPAREN)
        _advance!(tz)
        if !_check(tz, TOK_RPAREN)
            parse_member!()
            while _check(tz, TOK_PIPE)
                _advance!(tz)
                parse_member!()
            end
        end
        _expect!(tz, TOK_RPAREN)
        return PathNegatedSet(fwd, inv)
    end
    parse_member!()
    PathNegatedSet(fwd, inv)
end

function _to_path_expr(x)::PathExpr
    x isa PathExpr && return x
    x isa URIRef && return PathURI(x)
    error("Cannot convert $(typeof(x)) to PathExpr")
end

# ─── Term parser ───────────────────────────────────────────────────

function _parse_term(tz::_SparqlTokenizer, prefixes)
    tok = _peek(tz)

    # Signed numeric literal: INTEGER_POSITIVE/NEGATIVE etc. — a leading
    # '+'/'-' immediately preceding a numeric token (e.g. object `+5`).
    if (tok.kind == TOK_PLUS || tok.kind == TOK_MINUS) &&
       tz.idx + 1 <= length(tz.tokens) &&
       tz.tokens[tz.idx + 1].kind in (TOK_INTEGER, TOK_DECIMAL, TOK_DOUBLE)
        sign = _advance!(tz).kind == TOK_MINUS ? "-" : "+"
        ntok = _advance!(tz)
        dt = ntok.kind == TOK_INTEGER ? "integer" :
             ntok.kind == TOK_DOUBLE ? "double" : "decimal"
        return Literal(sign * ntok.value, datatype=URIRef("http://www.w3.org/2001/XMLSchema#$dt"))
    end

    if tok.kind == TOK_VAR
        return _advance!(tz).value[2:end]  # return variable name as String
    end

    if tok.kind == TOK_IRI
        _advance!(tz)
        return _make_uri(tok.value, prefixes)
    end

    if tok.kind == TOK_PNAME
        _advance!(tz)
        return _resolve_pname(tok.value, prefixes)
    end

    if tok.kind == TOK_A
        _advance!(tz)
        return URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    end

    if tok.kind == TOK_STRING
        return _parse_literal_term(tz, prefixes)
    end

    if tok.kind == TOK_INTEGER
        _advance!(tz)
        return Literal(tok.value, datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))
    end

    if tok.kind == TOK_DECIMAL || tok.kind == TOK_DOUBLE
        _advance!(tz)
        dt = tok.kind == TOK_DOUBLE ? "double" : "decimal"
        return Literal(tok.value, datatype=URIRef("http://www.w3.org/2001/XMLSchema#$dt"))
    end

    if tok.kind == TOK_TRUE
        _advance!(tz)
        return Literal("true", datatype=URIRef("http://www.w3.org/2001/XMLSchema#boolean"))
    end
    if tok.kind == TOK_FALSE
        _advance!(tz)
        return Literal("false", datatype=URIRef("http://www.w3.org/2001/XMLSchema#boolean"))
    end

    if tok.kind == TOK_BNODE
        _advance!(tz)
        return BNode(tok.value[3:end])  # strip _:
    end

    if tok.kind == TOK_LBRACKET
        _advance!(tz)
        _expect!(tz, TOK_RBRACKET)
        return BNode()
    end

    # SPARQL 1.2 ground triple term `<<( s p o )>>` (e.g. in VALUES). Reified
    # triples `<< ... >>` are not RDFTerms and must not appear here.
    if tok.kind == TOK_LTLT_PAREN
        ttp = _parse_triple_term(tz, prefixes, PatTriple[]; as_var=true, in_expr=true)
        gt = _ground_triple_term(ttp)
        isnothing(gt) && error("Triple term with variables not allowed here at position $(tok.pos)")
        return gt
    end

    error("Expected term, got $(tok.kind) '$(tok.value)' at position $(tok.pos)")
end

# Convert a fully-ground TripleTermPattern into a concrete TripleTerm, or
# return nothing if it contains variables.
function _ground_triple_term(ttp::TripleTermPattern)
    s = ttp.subject isa TripleTermPattern ? _ground_triple_term(ttp.subject) : ttp.subject
    o = ttp.object isa TripleTermPattern ? _ground_triple_term(ttp.object) : ttp.object
    p = ttp.predicate
    (s isa Node && p isa URIRef && o isa Identifier) || return nothing
    return TripleTerm(s, p, o)
end

function _parse_literal_term(tz::_SparqlTokenizer, prefixes)::Literal
    tok = _advance!(tz)
    lexical = _unescape_sparql_string(tok.value)

    if _check(tz, TOK_CARETCARET)
        _advance!(tz)
        dt_uri = _parse_iri(tz, prefixes)
        return Literal(lexical, datatype=dt_uri)
    end

    if _check(tz, TOK_LANGTAG)
        lt = _advance!(tz)
        lang, dir = _split_langtag(lt.value[2:end])
        return _make_lang_literal(lexical, lang, dir)
    end

    Literal(lexical)
end

function _parse_iri(tz::_SparqlTokenizer, prefixes)::URIRef
    tok = _advance!(tz)
    if tok.kind == TOK_IRI
        return _make_uri(tok.value, prefixes)
    elseif tok.kind == TOK_PNAME
        # A valid PrefixedName always contains a ':'. A colon-less PNAME token
        # is a bareword (e.g. a misspelled keyword) and is not an IRI.
        isnothing(findfirst(':', tok.value)) &&
            error("Expected IRI, got bare word '$(tok.value)' at position $(tok.pos)")
        return _resolve_pname(tok.value, prefixes)
    elseif tok.kind == TOK_A
        return URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    end
    error("Expected IRI, got $(tok.kind) '$(tok.value)' at position $(tok.pos)")
end

# ─── VALUES ────────────────────────────────────────────────────────

function _parse_values(tz::_SparqlTokenizer, prefixes)::PatValues
    _expect_keyword!(tz, "VALUES")
    vars = String[]
    if _check(tz, TOK_LPAREN)
        _advance!(tz)
        while _check(tz, TOK_VAR)
            v = _advance!(tz).value[2:end]
            v in vars && error("Duplicate variable '?$v' in VALUES clause")
            push!(vars, v)
        end
        _expect!(tz, TOK_RPAREN)
    elseif _check(tz, TOK_VAR)
        push!(vars, _advance!(tz).value[2:end])
    end

    _expect!(tz, TOK_LBRACE)
    rows = Vector{Union{Identifier, Nothing}}[]
    single_var = length(vars) == 1
    while !_check(tz, TOK_RBRACE) && !_check(tz, TOK_EOF)
        if _check(tz, TOK_LPAREN)
            _expect!(tz, TOK_LPAREN)
            row = Union{Identifier, Nothing}[]
            while !_check(tz, TOK_RPAREN) && !_check(tz, TOK_EOF)
                if _check_keyword(tz, "UNDEF")
                    _advance!(tz)
                    push!(row, nothing)
                else
                    push!(row, _parse_term(tz, prefixes))
                end
            end
            _expect!(tz, TOK_RPAREN)
            # Each row in a parenthesized VALUES must have exactly one value
            # per declared variable.
            length(row) == length(vars) ||
                error("VALUES row has $(length(row)) values but $(length(vars)) variables were declared")
            push!(rows, row)
        elseif single_var
            # Single-variable VALUES without parens: VALUES ?x { val1 val2 ... }
            if _check_keyword(tz, "UNDEF")
                _advance!(tz)
                push!(rows, Union{Identifier, Nothing}[nothing])
            else
                push!(rows, Union{Identifier, Nothing}[_parse_term(tz, prefixes)])
            end
        else
            break
        end
    end
    _expect!(tz, TOK_RBRACE)
    PatValues(vars, rows)
end

# ─── Solution modifiers ───────────────────────────────────────────

function _parse_solution_modifiers(tz::_SparqlTokenizer, prefixes)
    group_by = SparqlExpr[]
    group_binds = PatBind[]
    having = nothing
    order_by = Tuple{SparqlExpr, Symbol}[]
    limit = nothing
    offset = 0

    # GROUP BY — GroupCondition ::= BuiltInCall | FunctionCall
    #                             | '(' Expression ( 'AS' Var )? ')' | Var
    if _check_keyword(tz, "GROUP")
        _advance!(tz)
        _expect_keyword!(tz, "BY")
        while true
            if _check(tz, TOK_VAR)
                push!(group_by, ExprVar(_advance!(tz).value[2:end]))
            elseif _check(tz, TOK_LPAREN)
                _advance!(tz)
                expr = _parse_expr(tz, prefixes)
                alias = nothing
                if _check_keyword(tz, "AS")
                    _advance!(tz)
                    alias = _expect!(tz, TOK_VAR).value[2:end]
                end
                _expect!(tz, TOK_RPAREN)
                if isnothing(alias)
                    push!(group_by, expr)
                else
                    # `GROUP BY (expr AS ?v)` binds ?v per solution before
                    # grouping — emit a PatBind and group on the variable.
                    push!(group_binds, PatBind(expr, alias))
                    push!(group_by, ExprVar(alias))
                end
            elseif (_check(tz, TOK_KEYWORD) || _check(tz, TOK_PNAME) || _check(tz, TOK_IRI)) &&
                   _peek_is_funcall(tz) &&
                   !(_peek(tz).value in ("HAVING", "ORDER", "LIMIT", "OFFSET", "VALUES", "GROUP"))
                # Bare builtin or function call: GROUP BY STRLEN(?x)
                push!(group_by, _parse_funcall_or_iri(tz, prefixes))
            else
                break
            end
        end
        isempty(group_by) && error("Expected group condition after GROUP BY at position $(_peek(tz).pos)")
    end

    # HAVING — HavingClause ::= 'HAVING' HavingCondition+
    # Multiple conditions are conjoined with '&&'.
    if _check_keyword(tz, "HAVING")
        _advance!(tz)
        while true
            cond = if _check(tz, TOK_LPAREN)
                _advance!(tz)
                e = _parse_expr(tz, prefixes)
                _expect!(tz, TOK_RPAREN)
                e
            elseif (_check(tz, TOK_KEYWORD) || _check(tz, TOK_PNAME) || _check(tz, TOK_IRI)) &&
                   _peek_is_funcall(tz) &&
                   !(_peek(tz).value in ("ORDER", "LIMIT", "OFFSET", "VALUES", "GROUP"))
                # Bare BuiltInCall / FunctionCall constraint, e.g. HAVING REGEX(…)
                _parse_expr(tz, prefixes)
            else
                break
            end
            having = isnothing(having) ? cond : ExprBinaryOp(:&&, having, cond)
        end
        isnothing(having) && error("Expected HAVING condition at position $(_peek(tz).pos)")
    end

    # ORDER BY
    if _check_keyword(tz, "ORDER")
        _advance!(tz)
        _expect_keyword!(tz, "BY")
        while !_check(tz, TOK_EOF) && !_check_keyword(tz, "LIMIT") &&
              !_check_keyword(tz, "OFFSET") && !_check_keyword(tz, "VALUES") &&
              !_check(tz, TOK_RBRACE)
            if _check_keyword(tz, "DESC")
                _advance!(tz)
                _expect!(tz, TOK_LPAREN)
                expr = _parse_expr(tz, prefixes)
                _expect!(tz, TOK_RPAREN)
                push!(order_by, (expr, :desc))
            elseif _check_keyword(tz, "ASC")
                _advance!(tz)
                _expect!(tz, TOK_LPAREN)
                expr = _parse_expr(tz, prefixes)
                _expect!(tz, TOK_RPAREN)
                push!(order_by, (expr, :asc))
            elseif _check(tz, TOK_VAR)
                push!(order_by, (ExprVar(_advance!(tz).value[2:end]), :asc))
            else
                push!(order_by, (_parse_expr(tz, prefixes), :asc))
            end
        end
    end

    # LIMIT / OFFSET (either order)
    for _ in 1:2
        if _check_keyword(tz, "LIMIT")
            _advance!(tz)
            limit = parse(Int, _expect!(tz, TOK_INTEGER).value)
        elseif _check_keyword(tz, "OFFSET")
            _advance!(tz)
            offset = parse(Int, _expect!(tz, TOK_INTEGER).value)
        end
    end

    (group_by, group_binds, having, order_by, limit, offset)
end

# ─── SPARQL UPDATE Parser ─────────────────────────────────────────

"""
Parse a SPARQL UPDATE query string into an update operation AST node
using the recursive descent tokenizer/parser infrastructure.
"""
# Blank-node labels appearing in the ground data of an INSERT/DELETE DATA op.
function _update_op_data_bnodes(op)
    out = Set{String}()
    add_terms! = (s, p, o) -> begin
        s isa BNode && push!(out, s.id)
        o isa BNode && push!(out, o.id)
    end
    if op isa UpdateInsertData || op isa UpdateDeleteData
        for (s, p, o, _) in op.quads; add_terms!(s, p, o); end
    elseif op isa _SPARQLInsertData || op isa _SPARQLDeleteData
        for (s, p, o) in op.triples; add_terms!(s, p, o); end
    end
    out
end

function sparql_parse_update(query::String)
    tz = _sparql_tokenize_all(strip(query))
    # Grammar: Update ::= Prologue ( Update1 ( ';' Update )? )?
    # i.e. a ';'-separated sequence of operations, each with its own prologue
    # contributions. Prefixes/BASE accumulate across the whole request.
    prefixes = Dict{String,String}()
    ops = Any[]
    # Blank-node labels are scoped to a single operation: a label appearing in
    # one INSERT/DELETE DATA operation may not reappear in another operation of
    # the same request (SPARQL 1.1 Update §19.6).
    seen_data_bnodes = Set{String}()
    while true
        _parse_prologue!(tz, prefixes)
        _check(tz, TOK_EOF) && break
        op = _parse_update_op(tz, prefixes)
        op_bnodes = _update_op_data_bnodes(op)
        for lbl in op_bnodes
            lbl in seen_data_bnodes &&
                error("Blank node label _:$lbl reused across update operations")
        end
        union!(seen_data_bnodes, op_bnodes)
        push!(ops, op)
        # Operations are separated by ';'. A trailing ';' is permitted.
        if _check(tz, TOK_SEMICOLON)
            _advance!(tz)
        else
            break
        end
    end
    if !_check(tz, TOK_EOF)
        tok = _peek(tz)
        error("Unexpected trailing input after update: $(tok.kind) '$(tok.value)' at position $(tok.pos)")
    end
    # Backwards-compatible: a single operation is returned bare (the common
    # case the evaluator already handles); zero or many ops wrap in
    # UpdateRequest so the evaluator can execute the sequence in order.
    length(ops) == 1 ? ops[1] : UpdateRequest(ops)
end

# GraphRef / GraphRefAll: GRAPH <iri> | <iri> | DEFAULT | NAMED | ALL
function _parse_graph_ref(tz::_SparqlTokenizer, prefixes; allow_named_all::Bool=true)
    if !isnothing(_match_keyword!(tz, "DEFAULT"))
        return :default
    elseif allow_named_all && _check_keyword(tz, "NAMED")
        _advance!(tz)
        return :named
    elseif allow_named_all && _check_keyword(tz, "ALL")
        _advance!(tz)
        return :all
    end
    _match_keyword!(tz, "GRAPH")  # GRAPH keyword is optional in COPY/MOVE/ADD
    _parse_iri(tz, prefixes)
end

# USING <iri> / USING NAMED <iri> dataset clauses (parsed, currently unused)
function _parse_using_clauses!(tz::_SparqlTokenizer, prefixes)
    using_graphs = URIRef[]
    using_named = URIRef[]
    while _check_keyword(tz, "USING")
        _advance!(tz)
        if !isnothing(_match_keyword!(tz, "NAMED"))
            push!(using_named, _parse_iri(tz, prefixes))
        else
            push!(using_graphs, _parse_iri(tz, prefixes))
        end
    end
    (using_graphs, using_named)
end

function _parse_update_op(tz::_SparqlTokenizer, prefixes)
    # CLEAR / DROP [SILENT] (GRAPH <iri> | DEFAULT | NAMED | ALL)
    if _check_keyword(tz, "CLEAR") || _check_keyword(tz, "DROP")
        op = _advance!(tz).value == "CLEAR" ? :clear : :drop
        silent = !isnothing(_match_keyword!(tz, "SILENT"))
        target = _parse_graph_ref(tz, prefixes)
        return UpdateGraphOp(op, silent, nothing, target)
    end

    # CREATE [SILENT] GRAPH <iri>
    if _check_keyword(tz, "CREATE")
        _advance!(tz)
        silent = !isnothing(_match_keyword!(tz, "SILENT"))
        _match_keyword!(tz, "GRAPH")
        target = _parse_iri(tz, prefixes)
        return UpdateGraphOp(:create, silent, nothing, target)
    end

    # COPY / MOVE / ADD [SILENT] (GRAPH <iri> | DEFAULT) TO (GRAPH <iri> | DEFAULT)
    if _check_keyword(tz, "COPY") || _check_keyword(tz, "MOVE") || _check_keyword(tz, "ADD")
        kw = _advance!(tz).value
        op = kw == "COPY" ? :copy : kw == "MOVE" ? :move : :add
        silent = !isnothing(_match_keyword!(tz, "SILENT"))
        source = _parse_graph_ref(tz, prefixes; allow_named_all=false)
        _expect_keyword!(tz, "TO")
        dest = _parse_graph_ref(tz, prefixes; allow_named_all=false)
        return UpdateGraphOp(op, silent, source, dest)
    end

    # LOAD [SILENT] <uri> [INTO GRAPH <target>]
    if _check_keyword(tz, "LOAD")
        _advance!(tz)
        _match_keyword!(tz, "SILENT")
        source = _expect!(tz, TOK_IRI).value
        target = nothing
        if _match_keyword!(tz, "INTO") !== nothing
            _expect_keyword!(tz, "GRAPH")
            target = _expect!(tz, TOK_IRI).value
        end
        return _SPARQLLoad(source, target)
    end

    # WITH <iri> — names the graph that DELETE/INSERT ... WHERE operates on
    with_graph = nothing
    if _check_keyword(tz, "WITH")
        _advance!(tz)
        with_graph = _parse_iri(tz, prefixes)
    end

    # INSERT DATA { quaddata } / INSERT { template } WHERE { patterns }
    if _check_keyword(tz, "INSERT")
        _advance!(tz)
        if _check_keyword(tz, "DATA")
            isnothing(with_graph) || error("WITH is not allowed with INSERT DATA")
            _advance!(tz)
            tpl = _parse_update_template(tz, prefixes; data=true, allow_bnode=true)
            return _has_graph(tpl) ? UpdateInsertData(tpl, prefixes) :
                                     _SPARQLInsertData(_drop_graph(tpl), prefixes)
        end
        ins = _parse_update_template(tz, prefixes)
        ug, un = _parse_using_clauses!(tz, prefixes)
        _expect_keyword!(tz, "WHERE")
        pats = SparqlPattern[_parse_group_graph_pattern(tz, prefixes)...]
        return _make_modify(_empty_quad_template(), ins, pats, prefixes, with_graph, ug, un)
    end

    # DELETE ...
    if _check_keyword(tz, "DELETE")
        _advance!(tz)

        # DELETE DATA { quaddata } — ground, no variables, no blank nodes
        if _check_keyword(tz, "DATA")
            isnothing(with_graph) || error("WITH is not allowed with DELETE DATA")
            _advance!(tz)
            tpl = _parse_update_template(tz, prefixes; data=true, allow_bnode=false)
            return _has_graph(tpl) ? UpdateDeleteData(tpl, prefixes) :
                                     _SPARQLDeleteData(_drop_graph(tpl), prefixes)
        end

        # DELETE WHERE { quadpattern } — shorthand (no blank nodes allowed)
        if _check_keyword(tz, "WHERE")
            _advance!(tz)
            pats = _parse_group_graph_pattern(tz, prefixes)
            del = _patterns_to_template(pats)
            _reject_bnodes_in_template(del)
            return _make_modify(del, _empty_quad_template(), SparqlPattern[pats...], prefixes, with_graph)
        end

        # DELETE { template } [INSERT { template }] WHERE { patterns }
        del = _parse_update_template(tz, prefixes; allow_bnode=false)
        ins = _empty_quad_template()
        if _check_keyword(tz, "INSERT")
            _advance!(tz)
            ins = _parse_update_template(tz, prefixes)
        end
        ug, un = _parse_using_clauses!(tz, prefixes)
        _expect_keyword!(tz, "WHERE")
        pats = SparqlPattern[_parse_group_graph_pattern(tz, prefixes)...]
        return _make_modify(del, ins, pats, prefixes, with_graph, ug, un)
    end

    error("Unsupported SPARQL UPDATE operation")
end

_empty_quad_template() = Tuple{Any,Any,Any,Any}[]

# True if any quad in the template/data targets a named graph.
_has_graph(quads) = any(q -> q[4] !== nothing, quads)

# Strip the graph slot, yielding the legacy 3-tuple list.
_drop_graph(quads) = Tuple{Any,Any,Any}[(q[1], q[2], q[3]) for q in quads]

# Choose the legacy 3-tuple `_SPARQLModify` (no named graphs) or the quad-aware
# `UpdateModify` (when delete/insert templates reference named graphs).
function _make_modify(del, ins, pats, prefixes, with_graph, using_graphs=URIRef[], using_named=URIRef[])
    if _has_graph(del) || _has_graph(ins)
        UpdateModify(del, ins, pats, prefixes, with_graph, using_graphs, using_named)
    else
        _SPARQLModify(_drop_graph(del), _drop_graph(ins), pats, prefixes, with_graph, using_graphs, using_named)
    end
end

function _reject_bnodes_in_template(tpl)
    for (s, p, o, _) in tpl
        (s isa BNode || o isa BNode || _is_anon_var(s) || _is_anon_var(o)) &&
            error("Blank node not allowed in DELETE template")
    end
end

"""
Parse a braced QuadData / QuadPattern block `{ tripleBlock | GRAPH g { ... } ... }`
into a Vector of 4-tuples `(s, p, o, graph)`, where `graph` is `nothing` for the
default graph, a `URIRef` for `GRAPH <iri> { … }`, or a variable-name `String`
for `GRAPH ?g { … }` (only valid in DELETE/INSERT ... WHERE templates).

When `data=true` (INSERT DATA / DELETE DATA) the block is ground: variables are
rejected. The `allow_bnode` flag controls whether blank nodes are permitted
(DELETE templates / DELETE DATA forbid them).
"""
function _parse_update_template(tz::_SparqlTokenizer, prefixes;
                                data::Bool=false, allow_bnode::Bool=true)
    _expect!(tz, TOK_LBRACE)
    quads = Tuple{Any,Any,Any,Any}[]
    while !_check(tz, TOK_RBRACE) && !_check(tz, TOK_EOF)
        if _check_keyword(tz, "GRAPH")
            _advance!(tz)
            gterm = if _check(tz, TOK_VAR)
                data && error("Variable not allowed in GRAPH block of a DATA operation at position $(_peek(tz).pos)")
                _advance!(tz).value[2:end]   # variable name String
            else
                _parse_iri(tz, prefixes)     # URIRef
            end
            inner = _parse_quad_triples(tz, prefixes)
            for (s, p, o) in inner
                push!(quads, (s, p, o, gterm))
            end
        else
            for (s, p, o) in _parse_quad_triples(tz, prefixes; single=true)
                push!(quads, (s, p, o, nothing))
            end
        end
        _match!(tz, TOK_DOT)  # '.' separator between GRAPH blocks / trailing dot
    end
    _expect!(tz, TOK_RBRACE)

    # Validate per the operation's constraints.
    for (s, p, o, _) in quads
        if data && (s isa AbstractString || p isa AbstractString || o isa AbstractString)
            error("Variable not allowed in DATA update")
        end
        if !allow_bnode && (s isa BNode || o isa BNode || _is_anon_var(s) || _is_anon_var(o))
            error("Blank node not allowed in this update template")
        end
    end
    quads
end

# A fresh-anon variable produced from `[]` / `[ … ]` (its name starts with "_:").
_is_anon_var(x) = x isa AbstractString && startswith(x, "_:")

# Parse the triples inside a (Quad)Data/Pattern braced group, up to the closing
# '}' (when `single=false`) or until a GRAPH keyword / '}' boundary
# (when `single=true`, i.e. default-graph triples interleaved with GRAPH blocks).
function _parse_quad_triples(tz::_SparqlTokenizer, prefixes; single::Bool=false)::Vector{Tuple{Any,Any,Any}}
    if !single
        _expect!(tz, TOK_LBRACE)
    end
    acc = PatTriple[]
    while !_check(tz, TOK_RBRACE) && !_check(tz, TOK_EOF) &&
          !(single && _check_keyword(tz, "GRAPH"))
        n_before = length(acc)
        subj = _parse_term_or_node(tz, prefixes, acc; as_var=false)
        if length(acc) > n_before && (_check(tz, TOK_DOT) || _check(tz, TOK_RBRACE))
            _match!(tz, TOK_DOT)
            single && _check_keyword(tz, "GRAPH") && break
            continue
        end
        _parse_predicate_object_list!(tz, prefixes, subj, acc; as_var=false)
        _match!(tz, TOK_DOT)
        single && _check_keyword(tz, "GRAPH") && break
    end
    if !single
        _expect!(tz, TOK_RBRACE)
    end
    Tuple{Any,Any,Any}[(t.subject, t.predicate, t.object) for t in acc]
end

"""
Extract (s, p, o, graph) quad templates from parsed SparqlPattern nodes
(for DELETE WHERE shorthand). Triples inside `GRAPH g { … }` carry their graph.
"""
function _patterns_to_template(pats::Vector{SparqlPattern})::Vector{Tuple{Any,Any,Any,Any}}
    result = Tuple{Any,Any,Any,Any}[]
    _collect_quad_template!(result, pats, nothing)
    result
end

function _collect_quad_template!(result, pats, graph)
    for p in pats
        if p isa PatTriple
            push!(result, (p.subject, p.predicate, p.object, graph))
        elseif p isa PatGraph
            g = p.graph_term isa ExprURI ? p.graph_term.uri :
                p.graph_term isa ExprVar ? p.graph_term.name : graph
            _collect_quad_template!(result, p.patterns, g)
        end
    end
end
