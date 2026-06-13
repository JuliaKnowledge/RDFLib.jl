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
                push!(tokens, _SparqlToken(TOK_LTLT, "<<", pos))
                pos += 2
                continue
            end
            # Disambiguate IRIREF vs less-than operator: treat <...> as an IRI
            # only when the bracketed content is plausible IRI content — it must
            # not start with ?/$ (variables), must contain no whitespace/control
            # chars or chars excluded from IRIREF (<, ", {, }, |, ^, `, \), and
            # must not contain the boolean operators &&/||.
            end_pos = findnext('>', input, pos + 1)
            if !isnothing(end_pos)
                content = SubString(input, nextind(input, pos), prevind(input, end_pos))
                if !startswith(content, '?') && !startswith(content, '$') &&
                   !occursin("&&", content) && !occursin("||", content) &&
                   all(ch -> ch > ' ' && !(ch in ('<', '"', '{', '}', '|', '^', '`', '\\')), content)
                    push!(tokens, _SparqlToken(TOK_IRI, String(content), pos))
                    pos = end_pos + 1
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
        if c == ')' ; push!(tokens, _SparqlToken(TOK_RPAREN, ")", pos));   pos += 1; continue; end
        if c == '{' ; push!(tokens, _SparqlToken(TOK_LBRACE, "{", pos));   pos += 1; continue; end
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
            else
                push!(tokens, _SparqlToken(TOK_PIPE, "|", pos))
                pos += 1
            end
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
            word = input[start:pos-1]

            # Check for prefixed name (word followed by :)
            if pos <= len && input[pos] == ':'
                pos = nextind(input, pos)
                local_start = pos
                # Read local part
                while pos <= len && (isletter(input[pos]) || isdigit(input[pos]) || input[pos] in ('_', '.', '-'))
                    pos = nextind(input, pos)
                end
                while pos > local_start && input[prevind(input, pos)] == '.'
                    pos = prevind(input, pos)
                end
                pname = input[start:pos-1]
                push!(tokens, _SparqlToken(TOK_PNAME, pname, start))
                continue
            end

            # Special words
            uw = uppercase(word)
            if word == "a"
                push!(tokens, _SparqlToken(TOK_A, "a", start))
            elseif word == "true"
                push!(tokens, _SparqlToken(TOK_TRUE, "true", start))
            elseif word == "false"
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
            pos = nextind(input, pos)
            local_start = pos
            while pos <= len && (isletter(input[pos]) || isdigit(input[pos]) || input[pos] in ('_', '.', '-'))
                pos = nextind(input, pos)
            end
            # Trailing dot terminates the statement; back off
            while pos > local_start && input[prevind(input, pos)] == '.'
                pos = prevind(input, pos)
            end
            push!(tokens, _SparqlToken(TOK_PNAME, input[start:pos-1], start))
            continue
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
        end_pat = string(q, q, q)
        end_pos = findnext(end_pat, input, pos + 3)
        isnothing(end_pos) && error("Unterminated long string at position $pos")
        return (input[pos:end_pos[end]], end_pos[end] + 1)
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

    # BNode
    if tok.kind == TOK_BNODE
        _advance!(tz)
        return ExprBNode(BNode(tok.value))
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

    # Check for @lang
    if _check(tz, TOK_LANGTAG)
        lt = _advance!(tz)
        lang = lt.value[2:end]  # strip @
        return ExprLiteral(Literal(lexical, lang=lang))
    end

    ExprLiteral(Literal(lexical))
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
    ExprAggregate(func, arg, distinct, nothing)
end

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
    prefix = name[1:colon_idx-1]
    local_part = name[colon_idx+1:end]
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

function _parse_prologue!(tz::_SparqlTokenizer)::Dict{String,String}
    prefixes = Dict{String,String}()
    while true
        if _check_keyword(tz, "PREFIX")
            _advance!(tz)
            pname_tok = _advance!(tz)  # prefix name with colon
            iri_tok = _expect!(tz, TOK_IRI)
            prefix = rstrip(pname_tok.value, ':')
            # Prefix IRIs are themselves resolved against any earlier BASE
            prefixes[prefix] = _make_uri(iri_tok.value, prefixes).value
        elseif _check_keyword(tz, "BASE")
            _advance!(tz)
            base_tok = _expect!(tz, TOK_IRI)
            # Successive BASE declarations resolve against the previous one
            prefixes[_BASE_KEY] = _make_uri(base_tok.value, prefixes).value
        elseif _check_keyword(tz, "VERSION")
            _advance!(tz)
            # Skip version value
            while !_check(tz, TOK_EOF) && !_check_keyword(tz, "SELECT") &&
                  !_check_keyword(tz, "ASK") && !_check_keyword(tz, "CONSTRUCT") &&
                  !_check_keyword(tz, "DESCRIBE") && !_check_keyword(tz, "PREFIX")
                _advance!(tz)
            end
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

# Skip FROM / FROM NAMED clauses (dataset declarations)
function _skip_from_clauses!(tz::_SparqlTokenizer)
    while _check_keyword(tz, "FROM")
        _advance!(tz)
        _match_keyword!(tz, "NAMED")
        if _check(tz, TOK_IRI)
            _advance!(tz)
        elseif _check(tz, TOK_PNAME)
            _advance!(tz)
        end
    end
end

# ─── SELECT ────────────────────────────────────────────────────────

function _parse_select(tz::_SparqlTokenizer, prefixes)
    _expect_keyword!(tz, "SELECT")

    distinct = !isnothing(_match_keyword!(tz, "DISTINCT"))
    reduced = !isnothing(_match_keyword!(tz, "REDUCED"))

    variables = String[]
    select_exprs = SelectExpr[]
    aggregates = SelectAggregate[]

    if _check(tz, TOK_STAR)
        _advance!(tz)
    else
        while !_check_keyword(tz, "WHERE") && !_check_keyword(tz, "FROM") && !_check(tz, TOK_LBRACE) && !_check(tz, TOK_EOF)
            if _check(tz, TOK_VAR)
                push!(variables, _advance!(tz).value[2:end])
            elseif _check(tz, TOK_LPAREN)
                _advance!(tz)  # (
                expr = _parse_expr(tz, prefixes)
                _expect_keyword!(tz, "AS")
                var = _expect!(tz, TOK_VAR)
                _expect!(tz, TOK_RPAREN)
                alias = var.value[2:end]
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

    _skip_from_clauses!(tz)

    # WHERE clause
    _match_keyword!(tz, "WHERE")
    patterns = _parse_group_graph_pattern(tz, prefixes)

    # Solution modifiers
    group_by, group_binds, having, order_by, limit, offset = _parse_solution_modifiers(tz, prefixes)
    append!(patterns, group_binds)

    # Trailing ValuesClause
    if _check_keyword(tz, "VALUES")
        push!(patterns, _parse_values(tz, prefixes))
    end

    SparqlSelect(variables, patterns, prefixes, limit, offset,
                 order_by, distinct, reduced, aggregates,
                 group_by, having, select_exprs)
end

# ─── ASK ───────────────────────────────────────────────────────────

function _parse_ask(tz::_SparqlTokenizer, prefixes)
    _expect_keyword!(tz, "ASK")
    _skip_from_clauses!(tz)
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
        _skip_from_clauses!(tz)
        _match_keyword!(tz, "WHERE")
        patterns = _parse_group_graph_pattern(tz, prefixes)
        # Extract PatTriple patterns as template
        template = PatTriple[p for p in patterns if p isa PatTriple]
        group_by, group_binds, having, order_by, limit, offset = _parse_solution_modifiers(tz, prefixes)
        if _check_keyword(tz, "VALUES")
            push!(patterns, _parse_values(tz, prefixes))
        end
        return SparqlConstruct(template, patterns, prefixes, limit, offset, order_by)
    end
    template = _parse_construct_template(tz, prefixes)
    _skip_from_clauses!(tz)
    _match_keyword!(tz, "WHERE")
    patterns = _parse_group_graph_pattern(tz, prefixes)
    group_by, group_binds, having, order_by, limit, offset = _parse_solution_modifiers(tz, prefixes)
    if _check_keyword(tz, "VALUES")
        push!(patterns, _parse_values(tz, prefixes))
    end
    SparqlConstruct(template, patterns, prefixes, limit, offset, order_by)
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
    _skip_from_clauses!(tz)
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

function _parse_group_body(tz::_SparqlTokenizer, prefixes)::Vector{SparqlPattern}
    patterns = SparqlPattern[]
    while !_check(tz, TOK_RBRACE) && !_check(tz, TOK_EOF)
        tok = _peek(tz)

        if _check_keyword(tz, "OPTIONAL")
            _advance!(tz)
            pats = _parse_group_graph_pattern(tz, prefixes)
            push!(patterns, PatOptional(pats))

        elseif _check_keyword(tz, "MINUS")
            _advance!(tz)
            pats = _parse_group_graph_pattern(tz, prefixes)
            push!(patterns, PatMinus(pats))

        elseif _check_keyword(tz, "LATERAL")
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
                # SPARQL grammar: FILTER can be BrackettedExpression or BuiltInCall
                if _check(tz, TOK_LPAREN)
                    _advance!(tz)
                    expr = _parse_expr(tz, prefixes)
                    _expect!(tz, TOK_RPAREN)
                else
                    # Bare function call: FILTER regex(...), FILTER CONTAINS(...)
                    expr = _parse_expr(tz, prefixes)
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
            push!(patterns, PatBind(expr, var.value[2:end]))

        elseif _check_keyword(tz, "VALUES")
            push!(patterns, _parse_values(tz, prefixes))

        elseif _check_keyword(tz, "GRAPH")
            _advance!(tz)
            gt = if _check(tz, TOK_VAR)
                ExprVar(_advance!(tz).value[2:end])
            else
                ExprURI(_parse_iri(tz, prefixes))
            end
            pats = _parse_group_graph_pattern(tz, prefixes)
            push!(patterns, PatGraph(gt, pats))

        elseif _check_keyword(tz, "SERVICE")
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
            # Direct subselect: WHERE { SELECT ... } (single braces)
            subq = _parse_select(tz, prefixes)
            push!(patterns, PatSubquery(subq))

        elseif _check(tz, TOK_LBRACE)
            # Subquery or nested group or UNION
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
                    push!(patterns, PatUnion(branches))
                else
                    append!(patterns, first_pats)
                end
            end

        elseif _check(tz, TOK_LTLT)
            # Triple term pattern: << s p o >>
            _advance!(tz)
            s = _parse_term(tz, prefixes)
            p = _parse_verb(tz, prefixes)
            o = _parse_term(tz, prefixes)
            _expect!(tz, TOK_GTGT)
            push!(patterns, PatTripleTerm(s, p, o, nothing))
            _match!(tz, TOK_DOT)

        else
            # Triple pattern(s): subject predicate-object-list
            triples = _parse_triples_block(tz, prefixes)
            if isempty(triples)
                # Skip unexpected token to prevent infinite loop
                _advance!(tz)
            else
                append!(patterns, triples)
            end
        end
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

"""
Parse a graph node: a plain term, a blank node property list
`[ :p :o ; ... ]`, or a collection `( e1 e2 ... )`.

Nested triples generated by property lists / collections are pushed onto
`acc`. When `as_var` is true (WHERE patterns), allocated blank nodes are
represented as fresh internal variables; when false (templates), as BNodes.
"""
function _parse_term_or_node(tz::_SparqlTokenizer, prefixes, acc::AbstractVector; as_var::Bool=true)
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

"""Parse `verb objectList ( ';' ( verb objectList )? )*` for subject `subj`,
pushing PatTriples onto `acc`."""
function _parse_predicate_object_list!(tz::_SparqlTokenizer, prefixes, subj, acc::AbstractVector; as_var::Bool=true)
    while true
        pred = _parse_verb(tz, prefixes)
        while true
            obj = _parse_term_or_node(tz, prefixes, acc; as_var=as_var)
            push!(acc, PatTriple(subj, pred, obj))
            if _check(tz, TOK_COMMA)
                _advance!(tz)
            else
                break
            end
        end
        if _check(tz, TOK_SEMICOLON)
            _advance!(tz)
            # Trailing ; before a terminator
            if _check(tz, TOK_DOT) || _check(tz, TOK_RBRACE) || _check(tz, TOK_RBRACKET) || _check(tz, TOK_EOF)
                break
            end
        else
            break
        end
    end
end

function _parse_triples_block(tz::_SparqlTokenizer, prefixes)::Vector{SparqlPattern}
    patterns = SparqlPattern[]
    subj = _parse_term_or_node(tz, prefixes, patterns)

    # A blank node property list / collection may stand alone as a subject
    # with no following predicate-object list: `[ :p :o ] .`
    if !isempty(patterns) && (_check(tz, TOK_DOT) || _check(tz, TOK_RBRACE) || _check(tz, TOK_EOF))
        _match!(tz, TOK_DOT)
        return patterns
    end

    _parse_predicate_object_list!(tz, prefixes, subj, patterns)
    _match!(tz, TOK_DOT)  # optional trailing dot
    patterns
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

    error("Expected term, got $(tok.kind) '$(tok.value)' at position $(tok.pos)")
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
        return Literal(lexical, lang=lt.value[2:end])
    end

    Literal(lexical)
end

function _parse_iri(tz::_SparqlTokenizer, prefixes)::URIRef
    tok = _advance!(tz)
    if tok.kind == TOK_IRI
        return _make_uri(tok.value, prefixes)
    elseif tok.kind == TOK_PNAME
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
            push!(vars, _advance!(tz).value[2:end])
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

    # HAVING
    if _check_keyword(tz, "HAVING")
        _advance!(tz)
        _expect!(tz, TOK_LPAREN)
        having = _parse_expr(tz, prefixes)
        _expect!(tz, TOK_RPAREN)
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
function sparql_parse_update(query::String)
    tz = _sparql_tokenize_all(strip(query))
    prefixes = _parse_prologue!(tz)
    op = _parse_update_op(tz, prefixes)
    _match!(tz, TOK_SEMICOLON)  # optional trailing ;
    if !_check(tz, TOK_EOF)
        tok = _peek(tz)
        error("Unexpected trailing input after update: $(tok.kind) '$(tok.value)' at position $(tok.pos)" *
              (tok.kind == TOK_KEYWORD ? " (multi-operation updates are not supported)" : ""))
    end
    op
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

    # INSERT DATA { triples } / INSERT { template } WHERE { patterns }
    if _check_keyword(tz, "INSERT")
        _advance!(tz)
        if _check_keyword(tz, "DATA")
            isnothing(with_graph) || error("WITH is not allowed with INSERT DATA")
            _advance!(tz)
            tpl = _parse_update_template(tz, prefixes)
            return _SPARQLInsertData(tpl, prefixes)
        end
        ins = _parse_update_template(tz, prefixes)
        _parse_using_clauses!(tz, prefixes)
        _expect_keyword!(tz, "WHERE")
        pats = _parse_group_graph_pattern(tz, prefixes)
        return _SPARQLModify(Tuple{Any,Any,Any}[], ins, SparqlPattern[pats...], prefixes, with_graph)
    end

    # DELETE ...
    if _check_keyword(tz, "DELETE")
        _advance!(tz)

        # DELETE DATA { triples }
        if _check_keyword(tz, "DATA")
            isnothing(with_graph) || error("WITH is not allowed with DELETE DATA")
            _advance!(tz)
            tpl = _parse_update_template(tz, prefixes)
            return _SPARQLDeleteData(tpl, prefixes)
        end

        # DELETE WHERE { patterns } — shorthand
        if _check_keyword(tz, "WHERE")
            _advance!(tz)
            pats = _parse_group_graph_pattern(tz, prefixes)
            # Extract triples from patterns as delete template
            del = _patterns_to_template(pats)
            return _SPARQLModify(del, Tuple{Any,Any,Any}[], SparqlPattern[pats...], prefixes, with_graph)
        end

        # DELETE { template } [INSERT { template }] WHERE { patterns }
        del = _parse_update_template(tz, prefixes)
        ins = Tuple{Any,Any,Any}[]
        if _check_keyword(tz, "INSERT")
            _advance!(tz)
            ins = _parse_update_template(tz, prefixes)
        end
        _parse_using_clauses!(tz, prefixes)
        _expect_keyword!(tz, "WHERE")
        pats = _parse_group_graph_pattern(tz, prefixes)
        return _SPARQLModify(del, ins, SparqlPattern[pats...], prefixes, with_graph)
    end

    error("Unsupported SPARQL UPDATE operation")
end

"""
Parse a braced template `{ s p o . ... }` into a Vector{Tuple{Any,Any,Any}}.
"""
function _parse_update_template(tz::_SparqlTokenizer, prefixes)::Vector{Tuple{Any,Any,Any}}
    _expect!(tz, TOK_LBRACE)
    acc = PatTriple[]
    while !_check(tz, TOK_RBRACE) && !_check(tz, TOK_EOF)
        n_before = length(acc)
        subj = _parse_term_or_node(tz, prefixes, acc; as_var=false)
        # Standalone property list subject
        if length(acc) > n_before && (_check(tz, TOK_DOT) || _check(tz, TOK_RBRACE))
            _match!(tz, TOK_DOT)
            continue
        end
        _parse_predicate_object_list!(tz, prefixes, subj, acc; as_var=false)
        _match!(tz, TOK_DOT)
    end
    _expect!(tz, TOK_RBRACE)
    Tuple{Any,Any,Any}[(t.subject, t.predicate, t.object) for t in acc]
end

"""
Extract triple templates from parsed SparqlPattern nodes (for DELETE WHERE shorthand).
"""
function _patterns_to_template(pats::Vector{SparqlPattern})::Vector{Tuple{Any,Any,Any}}
    result = Tuple{Any,Any,Any}[]
    for p in pats
        if p isa PatTriple
            push!(result, (p.subject, p.predicate, p.object))
        end
    end
    result
end
