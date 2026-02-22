using Test
using RDFLib

@testset "Exceptions" begin
    EX = RDFLib.Namespace("http://example.org/")

    @testset "ParserError" begin
        e1 = ParserError("bad syntax")
        @test e1.message == "bad syntax"
        @test e1.format == ""
        @test e1.line == 0

        e2 = ParserError("unexpected token", "turtle")
        @test e2.format == "turtle"
        @test e2.line == 0

        e3 = ParserError("missing dot", "ntriples", 42)
        @test e3.line == 42

        @test_throws ParserError throw(e1)

        buf = IOBuffer()
        showerror(buf, e3)
        msg = String(take!(buf))
        @test occursin("ParserError", msg)
        @test occursin("missing dot", msg)
        @test occursin("ntriples", msg)
        @test occursin("42", msg)
    end

    @testset "UniquenessError" begin
        e = UniquenessError("multiple values")
        @test e.message == "multiple values"
        @test_throws UniquenessError throw(e)

        buf = IOBuffer()
        showerror(buf, e)
        @test occursin("UniquenessError", String(take!(buf)))
    end

    @testset "SPARQLError" begin
        e = SPARQLError("query failed")
        @test e.message == "query failed"
        @test_throws SPARQLError throw(e)

        buf = IOBuffer()
        showerror(buf, e)
        @test occursin("SPARQLError", String(take!(buf)))
    end

    @testset "SerializationError" begin
        e1 = SerializationError("write failed")
        @test e1.format == ""

        e2 = SerializationError("encoding error", "turtle")
        @test e2.format == "turtle"
        @test_throws SerializationError throw(e1)

        buf = IOBuffer()
        showerror(buf, e2)
        msg = String(take!(buf))
        @test occursin("SerializationError", msg)
        @test occursin("turtle", msg)
    end

    @testset "NamespaceError" begin
        e = NamespaceError("unknown prefix")
        @test_throws NamespaceError throw(e)

        buf = IOBuffer()
        showerror(buf, e)
        @test occursin("NamespaceError", String(take!(buf)))
    end

    @testset "StoreError" begin
        e = StoreError("connection failed")
        @test_throws StoreError throw(e)

        buf = IOBuffer()
        showerror(buf, e)
        @test occursin("StoreError", String(take!(buf)))
    end

    @testset "RDFError hierarchy" begin
        @test ParserError("x") isa RDFError
        @test UniquenessError("x") isa RDFError
        @test SPARQLError("x") isa RDFError
        @test SerializationError("x") isa RDFError
        @test NamespaceError("x") isa RDFError
        @test StoreError("x") isa RDFError
    end

    @testset "unique_value" begin
        g = RDFGraph()
        s = EX("s")
        p = EX("p")

        # 0 values → UniquenessError
        @test_throws UniquenessError unique_value(g, s, p)

        # 1 value → returns it
        add!(g, Triple(s, p, Literal("only")))
        @test unique_value(g, s, p) == Literal("only")

        # 2 values → UniquenessError
        add!(g, Triple(s, p, Literal("extra")))
        @test_throws UniquenessError unique_value(g, s, p)
    end
end
