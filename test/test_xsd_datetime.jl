using Test
using RDFLib
using Dates

@testset "XSD Datetime Utilities" begin
    @testset "parse_xsd_datetime" begin
        dt = parse_xsd_datetime("2023-01-15T10:30:00")
        @test dt == DateTime(2023, 1, 15, 10, 30, 0)

        dt = parse_xsd_datetime("2023-01-15T10:30:00Z")
        @test dt == DateTime(2023, 1, 15, 10, 30, 0)

        dt = parse_xsd_datetime("2023-01-15T10:30:00+05:30")
        @test dt == DateTime(2023, 1, 15, 10, 30, 0)

        dt = parse_xsd_datetime("2023-01-15T10:30:00.500")
        @test dt == DateTime(2023, 1, 15, 10, 30, 0, 500)
    end

    @testset "parse_xsd_date" begin
        d = parse_xsd_date("2023-01-15")
        @test d == Date(2023, 1, 15)

        d = parse_xsd_date("2023-01-15Z")
        @test d == Date(2023, 1, 15)
    end

    @testset "parse_xsd_time" begin
        t = parse_xsd_time("10:30:00")
        @test t == Time(10, 30, 0)

        t = parse_xsd_time("10:30:00Z")
        @test t == Time(10, 30, 0)

        t = parse_xsd_time("10:30:00.500")
        @test t == Time(10, 30, 0, 500)
    end

    @testset "format_xsd_datetime" begin
        @test format_xsd_datetime(DateTime(2023, 1, 15, 10, 30, 0)) == "2023-01-15T10:30:00"
    end

    @testset "format_xsd_date" begin
        @test format_xsd_date(Date(2023, 1, 15)) == "2023-01-15"
    end

    @testset "format_xsd_time" begin
        @test format_xsd_time(Time(10, 30, 0)) == "10:30:00"
    end

    @testset "xsd_literal" begin
        lit = xsd_literal(DateTime(2023, 1, 15, 10, 30, 0))
        @test lit.lexical == "2023-01-15T10:30:00"
        @test lit.datatype == XSD.dateTime

        lit = xsd_literal(Date(2023, 1, 15))
        @test lit.lexical == "2023-01-15"
        @test lit.datatype == XSD.date

        lit = xsd_literal(Time(10, 30, 0))
        @test lit.lexical == "10:30:00"
        @test lit.datatype == XSD.time

        lit = xsd_literal(42)
        @test lit.lexical == "42"
        @test lit.datatype == XSD.integer

        lit = xsd_literal(3.14)
        @test lit.lexical == "3.14"
        @test lit.datatype == XSD.double

        lit = xsd_literal(true)
        @test lit.lexical == "true"
        @test lit.datatype == XSD.boolean

        lit = xsd_literal(false)
        @test lit.lexical == "false"
        @test lit.datatype == XSD.boolean

        lit = xsd_literal("hello")
        @test lit.lexical == "hello"
        @test lit.datatype == XSD.string
    end

    @testset "round-trip" begin
        dt = DateTime(2023, 6, 15, 14, 30, 45)
        @test parse_xsd_datetime(format_xsd_datetime(dt)) == dt

        d = Date(2023, 6, 15)
        @test parse_xsd_date(format_xsd_date(d)) == d

        t = Time(14, 30, 45)
        @test parse_xsd_time(format_xsd_time(t)) == t
    end
end
