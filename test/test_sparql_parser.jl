@testset "SPARQL Parser — Recursive Descent" begin

# ─── Tokenizer ─────────────────────────────────────────────────────

@testset "Tokenizer basics" begin
    # Keywords are case-insensitive
    tz = RDFLib._sparql_tokenize_all("select WHERE Filter")
    @test tz.tokens[1].kind == RDFLib.TOK_KEYWORD
    @test tz.tokens[1].value == "SELECT"
    @test tz.tokens[2].kind == RDFLib.TOK_KEYWORD
    @test tz.tokens[2].value == "WHERE"
    @test tz.tokens[3].kind == RDFLib.TOK_KEYWORD
    @test tz.tokens[3].value == "FILTER"

    # Variables
    tz = RDFLib._sparql_tokenize_all("?x \$y")
    @test tz.tokens[1].kind == RDFLib.TOK_VAR
    @test tz.tokens[1].value == "?x"
    @test tz.tokens[2].kind == RDFLib.TOK_VAR
    @test tz.tokens[2].value == "\$y"

    # IRIs
    tz = RDFLib._sparql_tokenize_all("<http://example.org/foo>")
    @test tz.tokens[1].kind == RDFLib.TOK_IRI
    @test tz.tokens[1].value == "http://example.org/foo"

    # Prefixed names
    tz = RDFLib._sparql_tokenize_all("ex:foo :bar rdf:type")
    @test tz.tokens[1].kind == RDFLib.TOK_PNAME
    @test tz.tokens[1].value == "ex:foo"
    @test tz.tokens[2].kind == RDFLib.TOK_PNAME
    @test tz.tokens[2].value == ":bar"
    @test tz.tokens[3].kind == RDFLib.TOK_PNAME
    @test tz.tokens[3].value == "rdf:type"

    # 'a' keyword
    tz = RDFLib._sparql_tokenize_all("?s a ?o")
    @test tz.tokens[2].kind == RDFLib.TOK_A

    # Booleans
    tz = RDFLib._sparql_tokenize_all("true false")
    @test tz.tokens[1].kind == RDFLib.TOK_TRUE
    @test tz.tokens[2].kind == RDFLib.TOK_FALSE

    # Numeric literals
    tz = RDFLib._sparql_tokenize_all("42 3.14 1.5e10")
    @test tz.tokens[1].kind == RDFLib.TOK_INTEGER
    @test tz.tokens[2].kind == RDFLib.TOK_DECIMAL
    @test tz.tokens[3].kind == RDFLib.TOK_DOUBLE

    # String literals
    tz = RDFLib._sparql_tokenize_all("\"hello\" 'world'")
    @test tz.tokens[1].kind == RDFLib.TOK_STRING
    @test tz.tokens[1].value == "\"hello\""
    @test tz.tokens[2].kind == RDFLib.TOK_STRING
    @test tz.tokens[2].value == "'world'"

    # Blank nodes
    tz = RDFLib._sparql_tokenize_all("_:b1 _:foo")
    @test tz.tokens[1].kind == RDFLib.TOK_BNODE
    @test tz.tokens[2].kind == RDFLib.TOK_BNODE

    # Comments are skipped
    tz = RDFLib._sparql_tokenize_all("SELECT # comment\n?x")
    non_eof = filter(t -> t.kind != RDFLib.TOK_EOF, tz.tokens)
    @test length(non_eof) == 2

    # Standalone ? (path modifier) vs variable
    tz = RDFLib._sparql_tokenize_all(":p? ?x")
    @test tz.tokens[1].kind == RDFLib.TOK_PNAME
    @test tz.tokens[2].kind == RDFLib.TOK_QUESTION
    @test tz.tokens[3].kind == RDFLib.TOK_VAR
end

@testset "Tokenizer — SPARQL function names as keywords" begin
    # Built-in functions must be keywords, not PNAMEs
    for fname in ["REGEX", "CONTAINS", "STRSTARTS", "STRENDS",
                   "ISBLANK", "ISNUMERIC", "ISIRI", "ISLITERAL",
                   "BOUND", "STR", "LANG", "DATATYPE",
                   "MD5", "SHA1", "SHA256", "IF", "COALESCE",
                   "SUBSTR", "REPLACE", "CONCAT", "URI", "IRI",
                   "STRLEN", "UCASE", "LCASE", "ABS", "CEIL", "FLOOR", "ROUND",
                   "YEAR", "MONTH", "DAY", "HOURS", "MINUTES", "SECONDS",
                   "NOW", "UUID", "STRUUID", "BNODE", "RAND",
                   "SAMETERM", "TRIPLE", "ISTRIPLE"]
        tz = RDFLib._sparql_tokenize_all(fname)
        @test tz.tokens[1].kind == RDFLib.TOK_KEYWORD
    end

    # But prefixed versions remain PNAMEs
    tz = RDFLib._sparql_tokenize_all("ex:CONTAINS ex:REGEX")
    @test tz.tokens[1].kind == RDFLib.TOK_PNAME
    @test tz.tokens[2].kind == RDFLib.TOK_PNAME
end

@testset "Tokenizer — slash not in PNAME" begin
    # ex:knows/ex:knows must tokenize as PNAME SLASH PNAME, not one big PNAME
    tz = RDFLib._sparql_tokenize_all("ex:knows/ex:knows")
    kinds = [t.kind for t in tz.tokens if t.kind != RDFLib.TOK_EOF]
    @test kinds == [RDFLib.TOK_PNAME, RDFLib.TOK_SLASH, RDFLib.TOK_PNAME]
end

@testset "Tokenizer — operators and delimiters" begin
    tz = RDFLib._sparql_tokenize_all("( ) { } [ ] . , ; ^ ^^ | / * + - ! = != < > <= >= << >>")
    kinds = [t.kind for t in tz.tokens if t.kind != RDFLib.TOK_EOF]
    @test RDFLib.TOK_LPAREN in kinds
    @test RDFLib.TOK_RPAREN in kinds
    @test RDFLib.TOK_LBRACE in kinds
    @test RDFLib.TOK_RBRACE in kinds
    @test RDFLib.TOK_DOT in kinds
    @test RDFLib.TOK_COMMA in kinds
    @test RDFLib.TOK_SEMICOLON in kinds
    @test RDFLib.TOK_CARETCARET in kinds
    @test RDFLib.TOK_PIPE in kinds
    @test RDFLib.TOK_STAR in kinds
    @test RDFLib.TOK_BANG in kinds
    @test RDFLib.TOK_EQ in kinds
    @test RDFLib.TOK_NE in kinds
    @test RDFLib.TOK_LE in kinds
    @test RDFLib.TOK_GE in kinds
    @test RDFLib.TOK_LTLT in kinds
    @test RDFLib.TOK_GTGT in kinds
end

# ─── Parser — Query forms ──────────────────────────────────────────

@testset "Parse SELECT" begin
    q = RDFLib.sparql_parse("SELECT ?s ?p ?o WHERE { ?s ?p ?o }")
    @test q isa RDFLib.SparqlSelect
    @test "s" in q.variables
    @test "p" in q.variables
    @test "o" in q.variables
    @test !q.distinct
end

@testset "Parse SELECT DISTINCT" begin
    q = RDFLib.sparql_parse("SELECT DISTINCT ?x WHERE { ?x a <http://ex.org/T> }")
    @test q isa RDFLib.SparqlSelect
    @test q.distinct
    @test q.variables == ["x"]
end

@testset "Parse SELECT *" begin
    q = RDFLib.sparql_parse("SELECT * WHERE { ?s ?p ?o }")
    @test q isa RDFLib.SparqlSelect
    @test isempty(q.variables)  # star means all
end

@testset "Parse ASK" begin
    q = RDFLib.sparql_parse("ASK { ?s <http://ex.org/p> \"hello\" }")
    @test q isa RDFLib.SparqlAsk
    @test !isempty(q.patterns)
end

@testset "Parse CONSTRUCT" begin
    q = RDFLib.sparql_parse("CONSTRUCT { ?s <http://ex.org/label> ?n } WHERE { ?s <http://ex.org/name> ?n }")
    @test q isa RDFLib.SparqlConstruct
    @test !isempty(q.template)
    @test !isempty(q.patterns)
end

@testset "Parse CONSTRUCT WHERE shorthand" begin
    q = RDFLib.sparql_parse("CONSTRUCT WHERE { ?s <http://ex.org/p> ?o }")
    @test q isa RDFLib.SparqlConstruct
    @test !isempty(q.template)
    @test !isempty(q.patterns)
end

@testset "Parse DESCRIBE" begin
    q = RDFLib.sparql_parse("DESCRIBE <http://ex.org/s1>")
    @test q isa RDFLib.SparqlDescribe
end

@testset "Parse with PREFIX" begin
    q = RDFLib.sparql_parse("PREFIX ex: <http://example.org/> SELECT ?s WHERE { ?s ex:name ?o }")
    @test q isa RDFLib.SparqlSelect
    @test haskey(q.prefixes, "ex")
    @test q.prefixes["ex"] == "http://example.org/"
end

@testset "Parse with multiple PREFIXes" begin
    q = RDFLib.sparql_parse("""
        PREFIX ex: <http://example.org/>
        PREFIX foaf: <http://xmlns.com/foaf/0.1/>
        SELECT ?s WHERE { ?s foaf:name ?n }
    """)
    @test haskey(q.prefixes, "ex")
    @test haskey(q.prefixes, "foaf")
end

@testset "Parse FROM clause" begin
    q = RDFLib.sparql_parse("SELECT ?s FROM <http://example.org/graph1> WHERE { ?s ?p ?o }")
    @test q isa RDFLib.SparqlSelect
end

@testset "Parse FROM NAMED clause" begin
    q = RDFLib.sparql_parse("SELECT ?s FROM NAMED <http://example.org/g1> WHERE { ?s ?p ?o }")
    @test q isa RDFLib.SparqlSelect
end

# ─── Parser — Patterns ────────────────────────────────────────────

@testset "Parse OPTIONAL" begin
    q = RDFLib.sparql_parse("SELECT ?s ?o WHERE { ?s <http://ex.org/p> ?o OPTIONAL { ?s <http://ex.org/q> ?z } }")
    has_opt = any(p -> p isa RDFLib.PatOptional, q.patterns)
    @test has_opt
end

@testset "Parse UNION" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { { ?s <http://ex.org/p> ?o } UNION { ?s <http://ex.org/q> ?o } }")
    has_union = any(p -> p isa RDFLib.PatUnion, q.patterns)
    @test has_union
end

@testset "Parse MINUS" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/p> ?o MINUS { ?s <http://ex.org/q> ?z } }")
    has_minus = any(p -> p isa RDFLib.PatMinus, q.patterns)
    @test has_minus
end

@testset "Parse FILTER" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/age> ?a FILTER(?a > 18) }")
    has_filter = any(p -> p isa RDFLib.PatFilter, q.patterns)
    @test has_filter
end

@testset "Parse FILTER with bare function call" begin
    # FILTER regex(...) without extra parens
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/name> ?n FILTER regex(?n, \"^A\") }")
    has_filter = any(p -> p isa RDFLib.PatFilter, q.patterns)
    @test has_filter
end

@testset "Parse FILTER EXISTS / NOT EXISTS" begin
    q1 = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/p> ?o FILTER EXISTS { ?s <http://ex.org/q> ?z } }")
    @test any(p -> p isa RDFLib.PatFilterExists && !p.negated, q1.patterns)

    q2 = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/p> ?o FILTER NOT EXISTS { ?s <http://ex.org/q> ?z } }")
    @test any(p -> p isa RDFLib.PatFilterExists && p.negated, q2.patterns)
end

@testset "Parse BIND" begin
    q = RDFLib.sparql_parse("SELECT ?s ?label WHERE { ?s <http://ex.org/name> ?n BIND(CONCAT(\"Name: \", ?n) AS ?label) }")
    has_bind = any(p -> p isa RDFLib.PatBind, q.patterns)
    @test has_bind
end

@testset "Parse VALUES — single variable" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { VALUES ?s { <http://ex.org/a> <http://ex.org/b> } ?s ?p ?o }")
    has_values = any(p -> p isa RDFLib.PatValues, q.patterns)
    @test has_values
end

@testset "Parse VALUES — multiple variables" begin
    q = RDFLib.sparql_parse("SELECT ?s ?p WHERE { VALUES (?s ?p) { (<http://ex.org/a> <http://ex.org/p>) } ?s ?p ?o }")
    has_values = any(p -> p isa RDFLib.PatValues, q.patterns)
    @test has_values
end

@testset "Parse GRAPH" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { GRAPH <http://ex.org/g1> { ?s ?p ?o } }")
    has_graph = any(p -> p isa RDFLib.PatGraph, q.patterns)
    @test has_graph
end

@testset "Parse SERVICE" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { SERVICE <http://ex.org/sparql> { ?s ?p ?o } }")
    has_service = any(p -> p isa RDFLib.PatService, q.patterns)
    @test has_service
end

@testset "Parse subquery" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { { SELECT ?s WHERE { ?s ?p ?o } LIMIT 10 } ?s <http://ex.org/name> ?n }")
    has_subq = any(p -> p isa RDFLib.PatSubquery, q.patterns)
    @test has_subq
end

# ─── Parser — Expressions & Operator Precedence ───────────────────

@testset "Expression precedence: && binds tighter than ||" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/a> ?x FILTER(?x > 1 || ?x < 10 && ?x != 5) }")
    f = first(p for p in q.patterns if p isa RDFLib.PatFilter)
    # The top-level expr should be OR (|| binds looser)
    @test f.expr isa RDFLib.ExprBinaryOp
    @test f.expr.op == :||
end

@testset "Expression precedence: * binds tighter than +" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/v> ?x FILTER(?x + 2 * 3 > 10) }")
    f = first(p for p in q.patterns if p isa RDFLib.PatFilter)
    # Top is >, left is +, right of + is *
    @test f.expr isa RDFLib.ExprBinaryOp
    @test f.expr.op == :>
end

@testset "Unary NOT" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/p> ?x FILTER(!BOUND(?x)) }")
    f = first(p for p in q.patterns if p isa RDFLib.PatFilter)
    @test f.expr isa RDFLib.ExprUnaryOp
    @test f.expr.op == :!
end

@testset "Parenthesized expressions" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/v> ?x FILTER((?x + 2) * 3 > 10) }")
    f = first(p for p in q.patterns if p isa RDFLib.PatFilter)
    @test f.expr isa RDFLib.ExprBinaryOp
    @test f.expr.op == :>
    @test f.expr.left isa RDFLib.ExprBinaryOp
    @test f.expr.left.op == :*
end

@testset "IN expression" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/v> ?x FILTER(?x IN (1, 2, 3)) }")
    f = first(p for p in q.patterns if p isa RDFLib.PatFilter)
    @test f.expr isa RDFLib.ExprIn
    @test !f.expr.negated
    @test length(f.expr.values) == 3
end

@testset "NOT IN expression" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/v> ?x FILTER(?x NOT IN (1, 2)) }")
    f = first(p for p in q.patterns if p isa RDFLib.PatFilter)
    @test f.expr isa RDFLib.ExprIn
    @test f.expr.negated
end

# ─── Parser — Function Calls ──────────────────────────────────────

@testset "Nested function calls" begin
    q = RDFLib.sparql_parse("SELECT (UCASE(STR(?x)) AS ?upper) WHERE { ?s <http://ex.org/p> ?x }")
    @test !isempty(q.select_exprs) || !isempty(q.aggregates)
end

@testset "Multi-arg function calls" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/n> ?n FILTER(CONTAINS(?n, \"test\")) }")
    f = first(p for p in q.patterns if p isa RDFLib.PatFilter)
    @test f.expr isa RDFLib.ExprFunctionCall
    @test f.expr.name == "CONTAINS"
    @test length(f.expr.args) == 2
end

@testset "IF function (3 args)" begin
    q = RDFLib.sparql_parse("SELECT (IF(?x > 0, \"pos\", \"neg\") AS ?sign) WHERE { ?s <http://ex.org/v> ?x }")
    @test q isa RDFLib.SparqlSelect
end

@testset "COALESCE function" begin
    q = RDFLib.sparql_parse("SELECT (COALESCE(?a, ?b, \"default\") AS ?val) WHERE { ?s <http://ex.org/p> ?o }")
    @test q isa RDFLib.SparqlSelect
end

@testset "REGEX with flags" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/n> ?n FILTER(REGEX(?n, \"^test\", \"i\")) }")
    f = first(p for p in q.patterns if p isa RDFLib.PatFilter)
    @test f.expr isa RDFLib.ExprFunctionCall
    @test f.expr.name == "REGEX"
    @test length(f.expr.args) == 3
end

# ─── Parser — Aggregates ──────────────────────────────────────────

@testset "COUNT(*)" begin
    q = RDFLib.sparql_parse("SELECT (COUNT(*) AS ?c) WHERE { ?s ?p ?o }")
    @test !isempty(q.aggregates)
    agg = q.aggregates[1]
    @test agg.agg.func == "COUNT"
end

@testset "COUNT(DISTINCT ?x)" begin
    q = RDFLib.sparql_parse("SELECT (COUNT(DISTINCT ?x) AS ?c) WHERE { ?s <http://ex.org/p> ?x }")
    agg = q.aggregates[1]
    @test agg.agg.func == "COUNT"
    @test agg.agg.distinct
end

@testset "Multiple aggregates" begin
    q = RDFLib.sparql_parse("SELECT (MIN(?x) AS ?min) (MAX(?x) AS ?max) (AVG(?x) AS ?avg) WHERE { ?s <http://ex.org/v> ?x }")
    @test length(q.aggregates) == 3
    funcs = sort([a.agg.func for a in q.aggregates])
    @test funcs == ["AVG", "MAX", "MIN"]
end

@testset "GROUP_CONCAT with separator" begin
    q = RDFLib.sparql_parse("SELECT (GROUP_CONCAT(?n; separator=\", \") AS ?names) WHERE { ?s <http://ex.org/n> ?n }")
    @test !isempty(q.aggregates)
    @test q.aggregates[1].agg.func == "GROUP_CONCAT"
end

# ─── Parser — Solution Modifiers ──────────────────────────────────

@testset "ORDER BY" begin
    q = RDFLib.sparql_parse("SELECT ?s ?n WHERE { ?s <http://ex.org/n> ?n } ORDER BY ?n")
    @test !isnothing(q.order_by) && !isempty(q.order_by)
end

@testset "ORDER BY DESC" begin
    q = RDFLib.sparql_parse("SELECT ?s ?n WHERE { ?s <http://ex.org/n> ?n } ORDER BY DESC(?n)")
    @test !isnothing(q.order_by) && !isempty(q.order_by)
end

@testset "LIMIT and OFFSET" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s ?p ?o } LIMIT 10 OFFSET 5")
    @test q.limit == 10
    @test q.offset == 5
end

@testset "GROUP BY" begin
    q = RDFLib.sparql_parse("SELECT ?type (COUNT(?s) AS ?c) WHERE { ?s a ?type } GROUP BY ?type")
    @test !isnothing(q.group_by) && !isempty(q.group_by)
end

@testset "GROUP BY with HAVING" begin
    q = RDFLib.sparql_parse("SELECT ?type (COUNT(?s) AS ?c) WHERE { ?s a ?type } GROUP BY ?type HAVING(COUNT(?s) > 5)")
    @test !isnothing(q.group_by) && !isempty(q.group_by)
    @test !isnothing(q.having)
end

# ─── Parser — Property Paths ──────────────────────────────────────

@testset "Path sequence (/)" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/a>/<http://ex.org/b> ?o }")
    pat = first(p for p in q.patterns if p isa RDFLib.PatTriple)
    @test pat.predicate isa RDFLib.PathSequence
end

@testset "Path alternative (|)" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/a>|<http://ex.org/b> ?o }")
    pat = first(p for p in q.patterns if p isa RDFLib.PatTriple)
    @test pat.predicate isa RDFLib.PathAlternative
end

@testset "Path inverse (^)" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s ^<http://ex.org/parent> ?o }")
    pat = first(p for p in q.patterns if p isa RDFLib.PatTriple)
    @test pat.predicate isa RDFLib.PathInverse
end

@testset "Path ZeroOrMore (*)" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/knows>* ?o }")
    pat = first(p for p in q.patterns if p isa RDFLib.PatTriple)
    @test pat.predicate isa RDFLib.PathZeroOrMore
end

@testset "Path OneOrMore (+)" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/knows>+ ?o }")
    pat = first(p for p in q.patterns if p isa RDFLib.PatTriple)
    @test pat.predicate isa RDFLib.PathOneOrMore
end

@testset "Path ZeroOrOne (?)" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/knows>? ?o }")
    pat = first(p for p in q.patterns if p isa RDFLib.PatTriple)
    @test pat.predicate isa RDFLib.PathZeroOrOne
end

@testset "Path negated set (!)" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s !<http://www.w3.org/1999/02/22-rdf-syntax-ns#type> ?o }")
    pat = first(p for p in q.patterns if p isa RDFLib.PatTriple)
    @test pat.predicate isa RDFLib.PathNegatedSet
end

@testset "Complex path: inverse + sequence" begin
    q = RDFLib.sparql_parse("PREFIX ex: <http://example.org/> SELECT ?s WHERE { ?s ^ex:rel/ex:name ?o }")
    @test q isa RDFLib.SparqlSelect
end

@testset "Complex path: alternative + modifiers" begin
    q = RDFLib.sparql_parse("PREFIX ex: <http://example.org/> SELECT ?s WHERE { ?s (ex:a|ex:b)+ ?o }")
    @test q isa RDFLib.SparqlSelect
end

# ─── Parser — Literals and Datatypes ──────────────────────────────

@testset "Typed literal" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/v> \"42\"^^<http://www.w3.org/2001/XMLSchema#integer> }")
    @test q isa RDFLib.SparqlSelect
end

@testset "Language-tagged literal" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/name> \"hello\"@en }")
    @test q isa RDFLib.SparqlSelect
end

@testset "Numeric literals in patterns" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/v> 42 }")
    @test q isa RDFLib.SparqlSelect
end

@testset "Boolean literal" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/active> true }")
    @test q isa RDFLib.SparqlSelect
end

# ─── Parser — UPDATE operations ───────────────────────────────────

@testset "Parse INSERT DATA" begin
    op = RDFLib.sparql_parse_update("INSERT DATA { <http://ex.org/s> <http://ex.org/p> \"hello\" . }")
    @test op isa RDFLib._SPARQLInsertData
    @test length(op.triples) == 1
end

@testset "Parse DELETE DATA" begin
    op = RDFLib.sparql_parse_update("DELETE DATA { <http://ex.org/s> <http://ex.org/p> \"hello\" . }")
    @test op isa RDFLib._SPARQLDeleteData
    @test length(op.triples) == 1
end

@testset "Parse DELETE WHERE" begin
    op = RDFLib.sparql_parse_update("DELETE WHERE { ?s <http://ex.org/p> ?o }")
    @test op isa RDFLib._SPARQLModify
end

@testset "Parse CLEAR ALL" begin
    op = RDFLib.sparql_parse_update("CLEAR ALL")
    @test op isa RDFLib._SPARQLClear
    @test op.target == "ALL"
end

@testset "Parse DROP DEFAULT" begin
    op = RDFLib.sparql_parse_update("DROP DEFAULT")
    @test op isa RDFLib._SPARQLClear
    @test op.target == "DEFAULT"
end

@testset "Parse INSERT DATA with PREFIX" begin
    op = RDFLib.sparql_parse_update("PREFIX ex: <http://example.org/> INSERT DATA { ex:s1 ex:name \"Alice\" . }")
    @test op isa RDFLib._SPARQLInsertData
    @test length(op.triples) >= 1
end

@testset "Parse DELETE/INSERT WHERE" begin
    op = RDFLib.sparql_parse_update("""
        DELETE { ?s <http://ex.org/old> ?o }
        INSERT { ?s <http://ex.org/new> ?o }
        WHERE { ?s <http://ex.org/old> ?o }
    """)
    @test op isa RDFLib._SPARQLModify
    @test !isempty(op.delete_template)
    @test !isempty(op.insert_template)
end

# ─── Parser — Error handling ──────────────────────────────────────

@testset "Invalid query throws error" begin
    @test_throws Exception RDFLib.sparql_parse("SELECTX * WHERE { }")
    @test_throws Exception RDFLib.sparql_parse("SELECT WHERE")
    @test_throws Exception RDFLib.sparql_parse("")
end

# ─── End-to-end: parse + evaluate ─────────────────────────────────

@testset "End-to-end SELECT" begin
    g = RDFGraph()
    add!(g, Triple(URIRef("http://ex.org/s1"), URIRef("http://ex.org/name"), Literal("Alice")))
    add!(g, Triple(URIRef("http://ex.org/s2"), URIRef("http://ex.org/name"), Literal("Bob")))
    ast = RDFLib.sparql_parse("SELECT ?s ?n WHERE { ?s <http://ex.org/name> ?n } ORDER BY ?n")
    result = RDFLib._ast_evaluate(g, ast)
    @test length(result) == 2
end

@testset "End-to-end FILTER with built-in" begin
    g = RDFGraph()
    add!(g, Triple(URIRef("http://ex.org/s1"), URIRef("http://ex.org/name"), Literal("Alice")))
    add!(g, Triple(URIRef("http://ex.org/s2"), URIRef("http://ex.org/name"), Literal("Bob")))
    ast = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/name> ?n FILTER(STRSTARTS(?n, \"A\")) }")
    result = RDFLib._ast_evaluate(g, ast)
    @test length(result) == 1
end

@testset "End-to-end bare FILTER regex" begin
    g = RDFGraph()
    add!(g, Triple(URIRef("http://ex.org/s1"), URIRef("http://ex.org/name"), Literal("Alice")))
    add!(g, Triple(URIRef("http://ex.org/s2"), URIRef("http://ex.org/name"), Literal("Bob")))
    ast = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/name> ?n FILTER regex(?n, \"^A\", \"i\") }")
    result = RDFLib._ast_evaluate(g, ast)
    @test length(result) == 1
end

@testset "End-to-end ASK" begin
    g = RDFGraph()
    add!(g, Triple(URIRef("http://ex.org/s1"), URIRef("http://ex.org/name"), Literal("Alice")))
    ast = RDFLib.sparql_parse("ASK { ?s <http://ex.org/name> \"Alice\" }")
    result = RDFLib._ast_evaluate(g, ast)
    @test length(result) == 1  # ASK returns boolean-ish result
end

@testset "End-to-end CONSTRUCT" begin
    g = RDFGraph()
    add!(g, Triple(URIRef("http://ex.org/s1"), URIRef("http://ex.org/name"), Literal("Alice")))
    ast = RDFLib.sparql_parse("CONSTRUCT { ?s <http://ex.org/label> ?n } WHERE { ?s <http://ex.org/name> ?n }")
    result = RDFLib._ast_evaluate(g, ast)
    @test result isa RDFGraph
    @test length(result) == 1
end

@testset "End-to-end hash functions" begin
    g = RDFGraph()
    add!(g, Triple(URIRef("http://ex.org/s1"), URIRef("http://ex.org/name"), Literal("hello")))
    for func in ["MD5", "SHA1", "SHA256"]
        ast = RDFLib.sparql_parse("SELECT ($func(?n) AS ?hash) WHERE { ?s <http://ex.org/name> ?n }")
        result = RDFLib._ast_evaluate(g, ast)
        @test length(result) == 1
        @test haskey(result[1], "hash")
    end
end

@testset "End-to-end CONSTRUCT WHERE shorthand" begin
    g = RDFGraph()
    add!(g, Triple(URIRef("http://ex.org/s1"), URIRef("http://ex.org/name"), Literal("Alice")))
    ast = RDFLib.sparql_parse("CONSTRUCT WHERE { ?s <http://ex.org/name> ?n }")
    result = RDFLib._ast_evaluate(g, ast)
    @test result isa RDFGraph
    @test length(result) == 1
end

@testset "End-to-end UPDATE — INSERT DATA + CLEAR" begin
    g = RDFGraph()
    sparql_update(g, "INSERT DATA { <http://ex.org/s1> <http://ex.org/p> \"test\" . }")
    @test length(g) == 1
    sparql_update(g, "CLEAR ALL")
    @test length(g) == 0
end

end # outer testset
