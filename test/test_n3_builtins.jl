using Test, RDFLib

@testset "N3 Builtins" begin
    MATH = Namespace("http://www.w3.org/2000/10/swap/math#")
    STR  = Namespace("http://www.w3.org/2000/10/swap/string#")
    LOG  = Namespace("http://www.w3.org/2000/10/swap/log#")
    CRYPTO = Namespace("http://www.w3.org/2000/10/swap/crypto#")

    bindings = Dict{Variable, Identifier}()
    lit(n) = Literal(n)

    # ─── is_builtin / registry ──────────────────────────────────────
    @testset "registry" begin
        @test is_builtin(MATH("greaterThan"))
        @test is_builtin(STR("length"))
        @test is_builtin(LOG("equalTo"))
        @test is_builtin(CRYPTO("sha256"))
        @test !is_builtin(URIRef("http://example.org/notABuiltin"))
    end

    # ─── Math comparisons ──────────────────────────────────────────
    @testset "math comparisons" begin
        @test !isempty(evaluate_builtin(MATH("greaterThan"), lit(5), lit(3), bindings))
        @test  isempty(evaluate_builtin(MATH("greaterThan"), lit(3), lit(5), bindings))
        @test  isempty(evaluate_builtin(MATH("greaterThan"), lit(3), lit(3), bindings))

        @test !isempty(evaluate_builtin(MATH("lessThan"), lit(2), lit(4), bindings))
        @test  isempty(evaluate_builtin(MATH("lessThan"), lit(4), lit(2), bindings))

        @test !isempty(evaluate_builtin(MATH("equalTo"), lit(7), lit(7), bindings))
        @test  isempty(evaluate_builtin(MATH("equalTo"), lit(7), lit(8), bindings))

        @test !isempty(evaluate_builtin(MATH("notEqualTo"), lit(1), lit(2), bindings))
        @test  isempty(evaluate_builtin(MATH("notEqualTo"), lit(5), lit(5), bindings))

        @test !isempty(evaluate_builtin(MATH("notGreaterThan"), lit(3), lit(5), bindings))
        @test !isempty(evaluate_builtin(MATH("notGreaterThan"), lit(3), lit(3), bindings))
        @test  isempty(evaluate_builtin(MATH("notGreaterThan"), lit(5), lit(3), bindings))

        @test !isempty(evaluate_builtin(MATH("notLessThan"), lit(5), lit(3), bindings))
        @test !isempty(evaluate_builtin(MATH("notLessThan"), lit(3), lit(3), bindings))
        @test  isempty(evaluate_builtin(MATH("notLessThan"), lit(3), lit(5), bindings))
    end

    # ─── Math unary ────────────────────────────────────────────────
    @testset "math unary" begin
        v = Variable("result")

        # negation
        r = evaluate_builtin(MATH("negation"), lit(5), v, bindings)
        @test length(r) == 1
        @test r[1][v] == lit(-5)

        # absoluteValue
        r = evaluate_builtin(MATH("absoluteValue"), lit(-3), v, bindings)
        @test length(r) == 1
        @test r[1][v] == lit(3)

        # floor
        r = evaluate_builtin(MATH("floor"), Literal("3.7"; datatype=URIRef("http://www.w3.org/2001/XMLSchema#double")), v, bindings)
        @test length(r) == 1

        # ceiling
        r = evaluate_builtin(MATH("ceiling"), Literal("3.2"; datatype=URIRef("http://www.w3.org/2001/XMLSchema#double")), v, bindings)
        @test length(r) == 1

        # rounded
        r = evaluate_builtin(MATH("rounded"), Literal("3.5"; datatype=URIRef("http://www.w3.org/2001/XMLSchema#double")), v, bindings)
        @test length(r) == 1

        # sqrt
        r = evaluate_builtin(MATH("sqrt"), lit(4), v, bindings)
        @test length(r) == 1
    end

    # ─── Math trig ─────────────────────────────────────────────────
    @testset "math trig" begin
        v = Variable("r")
        @test !isempty(evaluate_builtin(MATH("sin"), lit(0), v, bindings))
        @test !isempty(evaluate_builtin(MATH("cos"), lit(0), v, bindings))
        @test !isempty(evaluate_builtin(MATH("tan"), lit(0), v, bindings))
    end

    # ─── String builtins ───────────────────────────────────────────
    @testset "string length" begin
        v = Variable("len")
        r = evaluate_builtin(STR("length"), Literal("hello"), v, bindings)
        @test length(r) == 1
        @test r[1][v] == lit(5)
    end

    @testset "string contains" begin
        @test !isempty(evaluate_builtin(STR("contains"), Literal("hello world"), Literal("world"), bindings))
        @test  isempty(evaluate_builtin(STR("contains"), Literal("hello"), Literal("xyz"), bindings))
    end

    @testset "string startsWith / endsWith" begin
        @test !isempty(evaluate_builtin(STR("startsWith"), Literal("hello"), Literal("hel"), bindings))
        @test  isempty(evaluate_builtin(STR("startsWith"), Literal("hello"), Literal("llo"), bindings))
        @test !isempty(evaluate_builtin(STR("endsWith"), Literal("hello"), Literal("llo"), bindings))
        @test  isempty(evaluate_builtin(STR("endsWith"), Literal("hello"), Literal("hel"), bindings))
    end

    @testset "string upperCase / lowerCase" begin
        v = Variable("out")
        r = evaluate_builtin(STR("upperCase"), Literal("hello"), v, bindings)
        @test length(r) == 1
        @test r[1][v] == Literal("HELLO")

        r = evaluate_builtin(STR("lowerCase"), Literal("HELLO"), v, bindings)
        @test length(r) == 1
        @test r[1][v] == Literal("hello")
    end

    @testset "string matches" begin
        @test !isempty(evaluate_builtin(STR("matches"), Literal("foo123bar"), Literal("[0-9]+"), bindings))
        @test  isempty(evaluate_builtin(STR("matches"), Literal("foobar"), Literal("[0-9]+"), bindings))
    end

    # ─── Log builtins ─────────────────────────────────────────────
    @testset "log equalTo / notEqualTo" begin
        a = URIRef("http://example.org/a")
        b = URIRef("http://example.org/b")

        @test !isempty(evaluate_builtin(LOG("equalTo"), a, a, bindings))
        @test  isempty(evaluate_builtin(LOG("equalTo"), a, b, bindings))

        @test !isempty(evaluate_builtin(LOG("notEqualTo"), a, b, bindings))
        @test  isempty(evaluate_builtin(LOG("notEqualTo"), a, a, bindings))
    end

    # ─── Crypto builtins ──────────────────────────────────────────
    @testset "crypto hashes" begin
        v = Variable("hash")

        r = evaluate_builtin(CRYPTO("sha1"), Literal("hello"), v, bindings)
        @test length(r) == 1
        @test r[1][v] isa Literal
        @test length(r[1][v].lexical) == 40  # SHA1 hex length

        r = evaluate_builtin(CRYPTO("sha256"), Literal("hello"), v, bindings)
        @test length(r) == 1
        @test length(r[1][v].lexical) == 64  # SHA256 hex length

        r = evaluate_builtin(CRYPTO("sha512"), Literal("hello"), v, bindings)
        @test length(r) == 1
        @test length(r[1][v].lexical) == 128  # SHA512 hex length
    end

    # ─── Variable binding ─────────────────────────────────────────
    @testset "variable binding" begin
        x = Variable("x")
        pre = Dict{Variable, Identifier}(x => Literal("10"))

        # object is a Variable, should be bound to negated value
        v = Variable("neg")
        r = evaluate_builtin(MATH("negation"), x, v, pre)
        @test length(r) == 1
        @test haskey(r[1], v)
        @test r[1][v] == lit(-10)
        # original binding preserved
        @test r[1][x] == Literal("10")
    end

    # ─── Failure cases ────────────────────────────────────────────
    @testset "failure cases" begin
        # wrong types
        @test isempty(evaluate_builtin(MATH("greaterThan"), URIRef("http://x"), lit(1), bindings))
        @test isempty(evaluate_builtin(MATH("negation"), URIRef("http://x"), Variable("v"), bindings))
        @test isempty(evaluate_builtin(STR("length"), Literal(42), Variable("v"), bindings))

        # unregistered builtin
        @test isempty(evaluate_builtin(URIRef("http://example.org/fake"), lit(1), lit(2), bindings))

        # unresolved variables in log:equalTo — now binds them (BNode existential semantics)
        @test !isempty(evaluate_builtin(LOG("equalTo"), Variable("a"), Variable("b"), bindings))
    end
end
