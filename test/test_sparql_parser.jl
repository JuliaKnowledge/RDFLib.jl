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

@testset "ORDER BY expression" begin
    q = RDFLib.sparql_parse("SELECT ?s ?n WHERE { ?s <http://ex.org/n> ?n } ORDER BY STRLEN(?n)")
    @test length(q.order_by) == 1
    @test q.order_by[1][1] isa RDFLib.ExprFunctionCall
    @test q.order_by[1][2] == :asc
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
    @test op isa RDFLib.UpdateGraphOp
    @test op.op == :clear
    @test op.target == :all
end

@testset "Parse DROP DEFAULT" begin
    op = RDFLib.sparql_parse_update("DROP DEFAULT")
    @test op isa RDFLib.UpdateGraphOp
    @test op.op == :drop
    @test op.target == :default
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

# ═══ Regression tests for review fixes ════════════════════════════

# Fix 1: `!` binds at unary level, not between && and comparison
@testset "Regression: ! precedence (unary level)" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/p> ?x FILTER(!?x = ?y) }")
    f = first(p for p in q.patterns if p isa RDFLib.PatFilter)
    # (!?x) = ?y  → top-level is the comparison, left arg is the negation
    @test f.expr isa RDFLib.ExprBinaryOp
    @test f.expr.op == :(==)
    @test f.expr.left isa RDFLib.ExprUnaryOp
    @test f.expr.left.op == :!

    # !A && B  → (!A) && B
    q2 = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/p> ?x FILTER(!BOUND(?x) && ?x > 1) }")
    f2 = first(p for p in q2.patterns if p isa RDFLib.PatFilter)
    @test f2.expr isa RDFLib.ExprBinaryOp
    @test f2.expr.op == :&&
    @test f2.expr.left isa RDFLib.ExprUnaryOp
end

# Fix 2: IRI-named function calls keep their IRI; builtins stay uppercase
@testset "Regression: function name casing" begin
    q = RDFLib.sparql_parse("""
        PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
        SELECT (xsd:integer(?x) AS ?i) WHERE { ?s <http://ex.org/p> ?x }
    """)
    @test length(q.select_exprs) == 1
    fc = q.select_exprs[1].expr
    @test fc isa RDFLib.ExprFunctionCall
    @test fc.name == "http://www.w3.org/2001/XMLSchema#integer"

    # Full-IRI function call
    q2 = RDFLib.sparql_parse("SELECT (<http://example.org/MyFunc>(?x) AS ?y) WHERE { ?s ?p ?x }")
    fc2 = q2.select_exprs[1].expr
    @test fc2 isa RDFLib.ExprFunctionCall
    @test fc2.name == "http://example.org/MyFunc"

    # Bare builtins still uppercased (lowercase in query)
    q3 = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/n> ?n FILTER(contains(?n, \"x\")) }")
    f3 = first(p for p in q3.patterns if p isa RDFLib.PatFilter)
    @test f3.expr.name == "CONTAINS"
end

# Fix 3: decimal literals keep lexical form and get xsd:decimal
@testset "Regression: decimal literal datatype + lexical" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/v> ?x FILTER(?x = 1.50) }")
    f = first(p for p in q.patterns if p isa RDFLib.PatFilter)
    lit = f.expr.right.value
    @test lit isa Literal
    @test lit.lexical == "1.50"
    @test lit.datatype == URIRef("http://www.w3.org/2001/XMLSchema#decimal")

    # DOUBLE (exponent form) stays xsd:double
    q2 = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/v> ?x FILTER(?x = 1.5e2) }")
    lit2 = first(p for p in q2.patterns if p isa RDFLib.PatFilter).expr.right.value
    @test lit2.datatype == URIRef("http://www.w3.org/2001/XMLSchema#double")
    @test lit2.lexical == "1.5e2"

    # INTEGER stays xsd:integer
    q3 = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/v> ?x FILTER(?x = 42) }")
    lit3 = first(p for p in q3.patterns if p isa RDFLib.PatFilter).expr.right.value
    @test lit3.datatype == URIRef("http://www.w3.org/2001/XMLSchema#integer")
end

# Fix 4: trailing dot terminates pnames / bnode labels
@testset "Regression: trailing dot not swallowed" begin
    tz = RDFLib._sparql_tokenize_all(":o.")
    @test tz.tokens[1].kind == RDFLib.TOK_PNAME
    @test tz.tokens[1].value == ":o"
    @test tz.tokens[2].kind == RDFLib.TOK_DOT

    tz2 = RDFLib._sparql_tokenize_all("_:b1.")
    @test tz2.tokens[1].kind == RDFLib.TOK_BNODE
    @test tz2.tokens[1].value == "_:b1"
    @test tz2.tokens[2].kind == RDFLib.TOK_DOT

    tz3 = RDFLib._sparql_tokenize_all("ex:foo.bar.")
    @test tz3.tokens[1].kind == RDFLib.TOK_PNAME
    @test tz3.tokens[1].value == "ex:foo.bar"  # internal dot kept
    @test tz3.tokens[2].kind == RDFLib.TOK_DOT

    # End-to-end: triple terminated by dot glued to the object pname
    g = RDFGraph()
    add!(g, Triple(URIRef("http://ex.org/s"), URIRef("http://ex.org/p"), URIRef("http://ex.org/o")))
    res = sparql_query(g, "PREFIX : <http://ex.org/> SELECT ?s WHERE { ?s :p :o. }")
    @test length(res) == 1
end

# Fix 5: variables may start with a digit
@testset "Regression: digit-starting variable names" begin
    tz = RDFLib._sparql_tokenize_all("?1 \$2x")
    @test tz.tokens[1].kind == RDFLib.TOK_VAR
    @test tz.tokens[1].value == "?1"
    @test tz.tokens[2].kind == RDFLib.TOK_VAR
    @test tz.tokens[2].value == "\$2x"
    q = RDFLib.sparql_parse("SELECT ?1 WHERE { ?1 ?p ?o }")
    @test q.variables == ["1"]
end

# Fix 6: < as comparison operator is not mistaken for an IRI
@testset "Regression: < operator vs IRI disambiguation" begin
    q = RDFLib.sparql_parse("SELECT * WHERE { ?a <http://ex.org/p> ?b . ?c <http://ex.org/p> ?d FILTER(?a<?b&&?c>?d) }")
    f = first(p for p in q.patterns if p isa RDFLib.PatFilter)
    @test f.expr isa RDFLib.ExprBinaryOp
    @test f.expr.op == :&&

    # Real IRIs (absolute and relative) still tokenize as IRIs
    tz = RDFLib._sparql_tokenize_all("<http://ex.org/x> <rel/path>")
    @test tz.tokens[1].kind == RDFLib.TOK_IRI
    @test tz.tokens[2].kind == RDFLib.TOK_IRI
end

# Fix 7: `?x-1` (negative numeric literal as additive continuation)
@testset "Regression: ?x-1 additive" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/v> ?x FILTER(?x-1 > 0) }")
    f = first(p for p in q.patterns if p isa RDFLib.PatFilter)
    @test f.expr isa RDFLib.ExprBinaryOp
    @test f.expr.op == :>
    add_e = f.expr.left
    @test add_e isa RDFLib.ExprBinaryOp
    @test add_e.op == :+
    @test add_e.right isa RDFLib.ExprLiteral
    @test add_e.right.value.lexical == "-1"

    # End-to-end
    g = RDFGraph()
    add!(g, Triple(URIRef("http://ex.org/s"), URIRef("http://ex.org/v"), Literal(5)))
    res = sparql_query(g, "SELECT (?x-1 AS ?y) WHERE { ?s <http://ex.org/v> ?x }")
    @test length(res) == 1
    @test RDFLib._ast_to_numeric(res[1]["y"]) == 4
end

# Fix 8: blank node property lists and collections
@testset "Regression: blank node property lists" begin
    g = RDFGraph()
    ex = "http://ex.org/"
    add!(g, Triple(BNode("x"), URIRef(ex * "p"), Literal("v1")))
    add!(g, Triple(BNode("x"), URIRef(ex * "q"), Literal("v2")))
    add!(g, Triple(URIRef(ex * "s"), URIRef(ex * "r"), BNode("x")))

    # Object position
    res = sparql_query(g, "PREFIX : <$ex> SELECT ?s WHERE { ?s :r [ :p \"v1\" ; :q \"v2\" ] }")
    @test length(res) == 1
    @test res[1]["s"] == URIRef(ex * "s")

    # Subject position
    res2 = sparql_query(g, "PREFIX : <$ex> SELECT ?v WHERE { [ :p \"v1\" ] :q ?v }")
    @test length(res2) == 1
    @test res2[1]["v"] == Literal("v2")

    # Standalone property-list subject
    res3 = sparql_query(g, "PREFIX : <$ex> ASK { [ :p \"v1\" ; :q \"v2\" ] }")
    @test res3 == true

    # SELECT * does not leak internal anon variables
    res4 = sparql_query(g, "PREFIX : <$ex> SELECT * WHERE { ?s :r [ :p ?v ] }")
    @test length(res4) == 1
    @test sort(collect(keys(res4[1]))) == ["s", "v"]
end

@testset "Regression: collections in patterns" begin
    rdfns = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    g = RDFGraph()
    ex = "http://ex.org/"
    b1 = BNode(); b2 = BNode()
    add!(g, Triple(URIRef(ex * "s"), URIRef(ex * "list"), b1))
    add!(g, Triple(b1, URIRef(rdfns * "first"), Literal(1)))
    add!(g, Triple(b1, URIRef(rdfns * "rest"), b2))
    add!(g, Triple(b2, URIRef(rdfns * "first"), Literal(2)))
    add!(g, Triple(b2, URIRef(rdfns * "rest"), URIRef(rdfns * "nil")))

    res = sparql_query(g, "PREFIX : <$ex> SELECT ?s WHERE { ?s :list ( 1 2 ) }")
    @test length(res) == 1
    @test res[1]["s"] == URIRef(ex * "s")

    # Empty collection is rdf:nil
    q = RDFLib.sparql_parse("PREFIX : <$ex> SELECT ?s WHERE { ?s :list () }")
    pat = first(p for p in q.patterns if p isa RDFLib.PatTriple)
    @test pat.object == URIRef(rdfns * "nil")
end

# Fix 9: trailing VALUES clause + EOF enforcement
@testset "Regression: trailing VALUES clause" begin
    g = RDFGraph()
    ex = "http://ex.org/"
    add!(g, Triple(URIRef(ex * "a"), URIRef(ex * "p"), Literal("1")))
    add!(g, Triple(URIRef(ex * "b"), URIRef(ex * "p"), Literal("2")))
    res = sparql_query(g, "PREFIX : <$ex> SELECT ?s ?v WHERE { ?s :p ?v } VALUES ?s { :a }")
    @test length(res) == 1
    @test res[1]["s"] == URIRef(ex * "a")
end

@testset "Regression: trailing garbage is a parse error" begin
    @test_throws Exception RDFLib.sparql_parse("SELECT ?s WHERE { ?s ?p ?o } garbage here")
    @test_throws Exception RDFLib.sparql_parse("SELECT ?s WHERE { ?s ?p ?o } } }")
    @test_throws Exception RDFLib.sparql_parse_update("CLEAR ALL nonsense")
end

# Fix 10: GROUP BY robustness
@testset "Regression: GROUP BY builtin and alias" begin
    # Bare builtin without parens-wrapping
    q = RDFLib.sparql_parse("SELECT (COUNT(*) AS ?c) WHERE { ?s <http://ex.org/n> ?n } GROUP BY STRLEN(?n)")
    @test length(q.group_by) == 1
    @test q.group_by[1] isa RDFLib.ExprFunctionCall

    # (expr AS ?v) keeps the alias bound
    g = RDFGraph()
    ex = "http://ex.org/"
    add!(g, Triple(URIRef(ex * "a"), URIRef(ex * "n"), Literal("ab")))
    add!(g, Triple(URIRef(ex * "b"), URIRef(ex * "n"), Literal("cd")))
    add!(g, Triple(URIRef(ex * "c"), URIRef(ex * "n"), Literal("xyz")))
    res = sparql_query(g, "PREFIX : <$ex> SELECT ?len (COUNT(?s) AS ?c) WHERE { ?s :n ?n } GROUP BY (STRLEN(?n) AS ?len)")
    @test length(res) == 2
    @test all(haskey(r, "len") for r in res)
    by_len = Dict(RDFLib._ast_to_numeric(r["len"]) => RDFLib._ast_to_numeric(r["c"]) for r in res)
    @test by_len[2] == 2
    @test by_len[3] == 1
end

# Fix 11: string escapes
@testset "Regression: string escapes" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/p> \"a\\u00e9b\" }")
    pat = first(p for p in q.patterns if p isa RDFLib.PatTriple)
    @test pat.object.lexical == "aéb"

    q2 = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/p> \"x\\U0001F600y\" }")
    pat2 = first(p for p in q2.patterns if p isa RDFLib.PatTriple)
    @test pat2.object.lexical == "x😀y"

    q3 = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/p> \"a\\bb\\fc\" }")
    pat3 = first(p for p in q3.patterns if p isa RDFLib.PatTriple)
    @test pat3.object.lexical == "a\bb\fc"

    # Surrogates rejected
    @test_throws Exception RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/p> \"\\uD800\" }")

    # Long single-quoted strings
    q4 = RDFLib.sparql_parse("SELECT ?s WHERE { ?s <http://ex.org/p> '''multi\nline''' }")
    pat4 = first(p for p in q4.patterns if p isa RDFLib.PatTriple)
    @test pat4.object.lexical == "multi\nline"
end

# Fix 12: direct subselect with single braces
@testset "Regression: direct subselect" begin
    q = RDFLib.sparql_parse("SELECT ?s WHERE { SELECT ?s WHERE { ?s ?p ?o } LIMIT 5 }")
    @test any(p -> p isa RDFLib.PatSubquery, q.patterns)

    g = RDFGraph()
    add!(g, Triple(URIRef("http://ex.org/s"), URIRef("http://ex.org/p"), Literal("v")))
    res = sparql_query(g, "SELECT ?s WHERE { SELECT ?s WHERE { ?s ?p ?o } }")
    @test length(res) == 1
end

# Fix 13: negated property sets with inverse members and `a`
@testset "Regression: negated property sets" begin
    q = RDFLib.sparql_parse("PREFIX : <http://ex.org/> SELECT ?s WHERE { ?s !(:p|^:q) ?o }")
    pat = first(p for p in q.patterns if p isa RDFLib.PatTriple)
    @test pat.predicate isa RDFLib.PathNegatedSet
    @test pat.predicate.uris == [URIRef("http://ex.org/p")]
    @test pat.predicate.inverse == [URIRef("http://ex.org/q")]

    q2 = RDFLib.sparql_parse("PREFIX : <http://ex.org/> SELECT ?s WHERE { ?s !^:p ?o }")
    pat2 = first(p for p in q2.patterns if p isa RDFLib.PatTriple)
    @test isempty(pat2.predicate.uris)
    @test pat2.predicate.inverse == [URIRef("http://ex.org/p")]

    q3 = RDFLib.sparql_parse("SELECT ?s WHERE { ?s !a ?o }")
    pat3 = first(p for p in q3.patterns if p isa RDFLib.PatTriple)
    @test pat3.predicate.uris == [URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")]

    # Eval: !^:q matches only reverse edges with predicate != q
    g = RDFGraph()
    ex = "http://ex.org/"
    add!(g, Triple(URIRef(ex * "a"), URIRef(ex * "p"), URIRef(ex * "b")))
    add!(g, Triple(URIRef(ex * "c"), URIRef(ex * "q"), URIRef(ex * "d")))
    res = sparql_query(g, "PREFIX : <$ex> SELECT ?x ?y WHERE { ?x !^:q ?y }")
    @test length(res) == 1
    @test res[1]["x"] == URIRef(ex * "b") && res[1]["y"] == URIRef(ex * "a")

    # Eval: !(:nope|^:q) — forward edges (pred != nope) plus inverse edges (pred != q)
    res2 = sparql_query(g, "PREFIX : <$ex> SELECT ?x ?y WHERE { ?x !(:nope|^:q) ?y }")
    pairs = Set((r["x"], r["y"]) for r in res2)
    @test (URIRef(ex * "a"), URIRef(ex * "b")) in pairs   # forward :p
    @test (URIRef(ex * "c"), URIRef(ex * "d")) in pairs   # forward :q (not excluded forward)
    @test (URIRef(ex * "b"), URIRef(ex * "a")) in pairs   # inverse :p
    @test !((URIRef(ex * "d"), URIRef(ex * "c")) in pairs) # inverse :q excluded
end

# Fix 14: UPDATE graph management
@testset "Regression: UPDATE graph management parse" begin
    op = RDFLib.sparql_parse_update("COPY DEFAULT TO <http://ex.org/g>")
    @test op isa RDFLib.UpdateGraphOp
    @test op.op == :copy && op.source === :default && op.target == URIRef("http://ex.org/g")

    op2 = RDFLib.sparql_parse_update("MOVE SILENT GRAPH <http://ex.org/g1> TO GRAPH <http://ex.org/g2>")
    @test op2.op == :move && op2.silent
    @test op2.source == URIRef("http://ex.org/g1") && op2.target == URIRef("http://ex.org/g2")

    op3 = RDFLib.sparql_parse_update("ADD <http://ex.org/g1> TO DEFAULT")
    @test op3.op == :add && op3.target === :default

    op4 = RDFLib.sparql_parse_update("CREATE SILENT GRAPH <http://ex.org/g>")
    @test op4.op == :create && op4.silent && op4.target == URIRef("http://ex.org/g")

    op5 = RDFLib.sparql_parse_update("CLEAR GRAPH <http://ex.org/g>")
    @test op5.op == :clear && op5.target == URIRef("http://ex.org/g")

    op6 = RDFLib.sparql_parse_update("DROP NAMED")
    @test op6.op == :drop && op6.target === :named

    # WITH / USING parse without error
    op7 = RDFLib.sparql_parse_update("""
        WITH <http://ex.org/g>
        DELETE { ?s <http://ex.org/old> ?o }
        INSERT { ?s <http://ex.org/new> ?o }
        WHERE { ?s <http://ex.org/old> ?o }
    """)
    @test op7 isa RDFLib._SPARQLModify
    @test op7.with_graph == URIRef("http://ex.org/g")

    op8 = RDFLib.sparql_parse_update("""
        DELETE { ?s ?p ?o }
        USING <http://ex.org/g> USING NAMED <http://ex.org/h>
        WHERE { ?s ?p ?o }
    """)
    @test op8 isa RDFLib._SPARQLModify
end

@testset "Regression: UPDATE graph management eval" begin
    ex = "http://ex.org/"
    # Plain RDFGraph: CREATE/DROP GRAPH throw unless SILENT; CLEAR DEFAULT works
    g = RDFGraph()
    add!(g, Triple(URIRef(ex * "s"), URIRef(ex * "p"), Literal("v")))
    @test_throws Exception sparql_update(g, "CREATE GRAPH <http://ex.org/g>")
    @test_throws Exception sparql_update(g, "DROP GRAPH <http://ex.org/g>")
    sparql_update(g, "DROP SILENT GRAPH <http://ex.org/g>")  # silent: no-op
    @test length(g) == 1
    sparql_update(g, "CLEAR DEFAULT")
    @test length(g) == 0

    # Dataset: full graph management
    ds = RDFLib.Dataset()
    g1 = URIRef(ex * "g1")
    g2 = URIRef(ex * "g2")
    add!(ds, Triple(URIRef(ex * "s"), URIRef(ex * "p"), Literal("default")))
    add!(ds, Triple(URIRef(ex * "s1"), URIRef(ex * "p"), Literal("one")), g1)

    sparql_update(ds, "CREATE GRAPH <$(ex)g3>")
    @test haskey(ds.named_graphs, URIRef(ex * "g3"))
    @test_throws Exception sparql_update(ds, "CREATE GRAPH <$(ex)g3>")
    sparql_update(ds, "CREATE SILENT GRAPH <$(ex)g3>")  # no error

    sparql_update(ds, "COPY <$(ex)g1> TO <$(ex)g2>")
    @test length(ds.named_graphs[g2]) == 1
    @test length(ds.named_graphs[g1]) == 1

    sparql_update(ds, "ADD DEFAULT TO <$(ex)g2>")
    @test length(ds.named_graphs[g2]) == 2

    sparql_update(ds, "MOVE <$(ex)g1> TO <$(ex)g4>")
    @test !haskey(ds.named_graphs, g1)
    @test length(ds.named_graphs[URIRef(ex * "g4")]) == 1

    sparql_update(ds, "CLEAR GRAPH <$(ex)g2>")
    @test length(ds.named_graphs[g2]) == 0

    sparql_update(ds, "DROP GRAPH <$(ex)g2>")
    @test !haskey(ds.named_graphs, g2)

    sparql_update(ds, "CLEAR ALL")
    @test length(ds.default_graph) == 0

    # WITH applies the modify to a named graph
    ds2 = RDFLib.Dataset()
    add!(ds2, Triple(URIRef(ex * "s"), URIRef(ex * "old"), Literal("v")), g1)
    sparql_update(ds2, "WITH <$(ex)g1> DELETE { ?s <$(ex)old> ?o } INSERT { ?s <$(ex)new> ?o } WHERE { ?s <$(ex)old> ?o }")
    gg = ds2.named_graphs[g1]
    @test length(gg) == 1
    @test first(triples(gg)).predicate == URIRef(ex * "new")
    @test length(ds2.default_graph) == 0
end

# Fix 15: BASE applied to relative IRIs
@testset "Regression: BASE resolution" begin
    q = RDFLib.sparql_parse("BASE <http://example.org/base/> SELECT ?s WHERE { ?s <rel> <#frag> }")
    pat = first(p for p in q.patterns if p isa RDFLib.PatTriple)
    @test pat.predicate isa RDFLib.PathURI || pat.predicate isa URIRef
    pred_uri = pat.predicate isa RDFLib.PathURI ? pat.predicate.uri : pat.predicate
    @test pred_uri == URIRef("http://example.org/base/rel")
    @test pat.object == URIRef("http://example.org/base/#frag")

    # Absolute IRIs unaffected
    q2 = RDFLib.sparql_parse("BASE <http://example.org/> SELECT ?s WHERE { ?s <http://other.org/p> ?o }")
    pat2 = first(p for p in q2.patterns if p isa RDFLib.PatTriple)
    pred2 = pat2.predicate isa RDFLib.PathURI ? pat2.predicate.uri : pat2.predicate
    @test pred2 == URIRef("http://other.org/p")

    # PREFIX IRIs resolve against BASE
    q3 = RDFLib.sparql_parse("BASE <http://example.org/ns/> PREFIX : <vocab#> SELECT ?s WHERE { ?s :p ?o }")
    @test q3.prefixes[""] == "http://example.org/ns/vocab#"
end

# ─── W3C conformance regressions ──────────────────────────────────

@testset "Regression: PN_LOCAL dots / colons / escapes / percent" begin
    sp = RDFLib.sparql_parse
    pref = "PREFIX : <http://example/>\n"

    # Internal colons in the local part: `:c:d`
    q = sp(pref * "SELECT * { :a :b :c:d . }")
    o = first(p for p in q.patterns if p isa RDFLib.PatTriple).object
    @test o == URIRef("http://example/c:d")

    # PN_LOCAL_ESC backslash escapes are removed (`\~`, `\.`)
    q = sp(pref * "SELECT * { :a :b :c\\~z\\. . }")
    @test first(p for p in q.patterns if p isa RDFLib.PatTriple).object ==
          URIRef("http://example/c~z.")

    # PERCENT (%HH) is kept verbatim
    q = sp("PREFIX og: <http://ogp.me/ns#>\nSELECT * { ?p og:audio%3Atitle ?t }")
    @test first(p for p in q.patterns if p isa RDFLib.PatTriple).predicate ==
          URIRef("http://ogp.me/ns#audio%3Atitle")

    # Internal dots and a leading-digit local part: `:123`, `:12.3`
    q = sp(pref * "SELECT * { :a :123 :12.3 . }")
    t = first(p for p in q.patterns if p isa RDFLib.PatTriple)
    @test t.predicate == URIRef("http://example/123")
    @test t.object == URIRef("http://example/12.3")

    # Negatives: `:a:b:c` is a single term ⇒ incomplete triple ⇒ rejected
    @test_throws Exception sp(pref * "SELECT * { :a:b:c . }")
    # Bad PREFIX declarations (PNAME_NS must be `PN_PREFIX? ':'`)
    @test_throws Exception sp("PREFIX ex:ex: <http://example/>\nASK {}")
    @test_throws Exception sp("PREFIX :: <http://example/>\nASK {}")
end

@testset "Regression: IRI UCHAR escapes and unusual IRIs" begin
    sp = RDFLib.sparql_parse
    # \u escapes inside an IRIREF are unescaped (U+0078 = 'x')
    q = sp("SELECT * WHERE { <\\u0078> <p> \"y\" }")
    @test first(p for p in q.patterns if p isa RDFLib.PatTriple).subject ==
          URIRef("x")
    # `<?z>` is a legal IRI, not a less-than/variable
    q = sp("SELECT * WHERE { <a> <b> <?z> }")
    @test first(p for p in q.patterns if p isa RDFLib.PatTriple).object ==
          URIRef("?z")
end

@testset "Regression: optional DOT after GraphPatternNotTriples" begin
    sp = RDFLib.sparql_parse
    @test sp("SELECT * WHERE { FILTER (?o > 5) . }") isa RDFLib.SparqlSelect
    @test sp("PREFIX : <http://e/>\nSELECT * { :p :q :r . OPTIONAL { :a :b :c } . }") isa RDFLib.SparqlSelect
    @test sp("PREFIX : <http://e/>\nSELECT * { OPTIONAL { :a :b :c } . ?x ?y ?z }") isa RDFLib.SparqlSelect
    @test sp("PREFIX : <http://e/>\nSELECT * { :p :q :r ; OPTIONAL { :a :b :c } }") isa RDFLib.SparqlSelect
    # Missing dot between two triples is rejected
    @test_throws Exception sp("PREFIX : <http://e/>\nSELECT * { :s1 :p1 :o1 :s2 :p2 :o2 . }")
    # Bare / doubled dots are rejected
    @test_throws Exception sp("SELECT * WHERE { . }")
    @test_throws Exception sp("SELECT * WHERE { ?s ?p ?o . . }")
end

@testset "Regression: FILTER constraint and bnode-in-expression" begin
    sp = RDFLib.sparql_parse
    @test_throws Exception sp("SELECT * { ?s ?p ?o FILTER ?x }")
    @test_throws Exception sp("SELECT * WHERE { <a> <b> _:x FILTER(_:x) }")
end

@testset "Regression: long string with escaped quote" begin
    q = RDFLib.sparql_parse(
        "BASE <http://e/> PREFIX : <#>\nSELECT * WHERE { :x :p \"\"\"Long\\\"\"\"Literal\"\"\" }")
    @test q isa RDFLib.SparqlSelect
end

@testset "Regression: VALUES width and SELECT alias uniqueness" begin
    sp = RDFLib.sparql_parse
    @test_throws Exception sp("SELECT * WHERE { VALUES (?a ?b) { (1 2 3) } }")
    @test_throws Exception sp("SELECT * WHERE { VALUES (?a ?b) { (1) } }")
    @test_throws Exception sp("SELECT (1 AS ?X) (1 AS ?X) {}")
    @test sp("SELECT * WHERE { VALUES (?a ?b) { (1 2) (3 4) } }") isa RDFLib.SparqlSelect
end

@testset "Regression: HAVING with multiple conditions" begin
    q = RDFLib.sparql_parse(
        "SELECT ?s (COUNT(?o) AS ?c) WHERE { ?s ?p ?o } GROUP BY ?s " *
        "HAVING (COUNT(?o) > 1) (COUNT(?o) < 10)")
    @test q isa RDFLib.SparqlSelect
    @test q.having isa RDFLib.ExprBinaryOp
    @test q.having.op == :&&
end

@testset "Regression: multibyte prefixes/locals (kanji)" begin
    q = RDFLib.sparql_parse(
        "PREFIX 食: <http://ex/kanji#>\nSELECT ?f WHERE { [ 食:食べる ?f ] . }")
    @test q isa RDFLib.SparqlSelect
end

@testset "Regression: GRAPH in UPDATE templates/data" begin
    pu = RDFLib.sparql_parse_update
    # INSERT DATA with GRAPH ⇒ quad-aware UpdateInsertData
    r = pu("INSERT DATA { GRAPH <http://g/> { <s> <p> 'o1', 'o2' } }")
    @test r isa RDFLib.UpdateInsertData
    @test length(r.quads) == 2
    @test all(q -> q[4] == URIRef("http://g/"), r.quads)

    # Plain INSERT DATA (no GRAPH) keeps the legacy 3-tuple struct
    r = pu("INSERT DATA { <s> <p> <o> }")
    @test r isa RDFLib._SPARQLInsertData

    # DELETE/INSERT WHERE with GRAPH templates ⇒ quad-aware UpdateModify
    r = pu("DELETE { GRAPH <http://g/> { ?s <p> ?o } } WHERE { ?s <p> ?o }")
    @test r isa RDFLib.UpdateModify
    @test r.delete_template[1][4] == URIRef("http://g/")

    # DATA forbids variables / blank nodes
    @test_throws Exception pu("INSERT DATA { ?s <p> <o> }")
    @test_throws Exception pu("DELETE DATA { _:a <p> <o> }")
    @test_throws Exception pu("DELETE WHERE { _:a <p> <o> }")
end

@testset "Regression: multi-operation UPDATE requests" begin
    pu = RDFLib.sparql_parse_update
    r = pu("CREATE GRAPH <http://g/> ; LOAD <http://x/> INTO GRAPH <http://g/>")
    @test r isa RDFLib.UpdateRequest
    @test length(r.operations) == 2
    @test r.operations[1] isa RDFLib.UpdateGraphOp

    # ';'-separated INSERT DATA sequence
    r = pu("INSERT DATA { <a> <b> <c> } ; INSERT DATA { <d> <e> <f> }")
    @test r isa RDFLib.UpdateRequest
    @test length(r.operations) == 2

    # Empty request (prologue only) ⇒ empty UpdateRequest
    r = pu("PREFIX : <http://example/>")
    @test r isa RDFLib.UpdateRequest
    @test isempty(r.operations)

    # Single operation is still returned bare (backwards compatible)
    @test pu("INSERT DATA { <a> <b> <c> }") isa RDFLib._SPARQLInsertData
end

end # outer testset
