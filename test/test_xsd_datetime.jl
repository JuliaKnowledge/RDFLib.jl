using Test
using RDFLib
using Dates

@testset "XSD Datetime Utilities" begin
    @testset "parse_xsd_datetime" begin
        dt = parse_xsd_datetime("2023-01-15T10:30:00")
        @test dt == DateTime(2023, 1, 15, 10, 30, 0)

        dt = parse_xsd_datetime("2023-01-15T10:30:00Z")
        @test dt == DateTime(2023, 1, 15, 10, 30, 0)

        # Timezone offsets are APPLIED (normalized to UTC), not stripped
        dt = parse_xsd_datetime("2023-01-15T10:30:00+05:30")
        @test dt == DateTime(2023, 1, 15, 5, 0, 0)

        dt = parse_xsd_datetime("2023-01-15T10:30:00-05:00")
        @test dt == DateTime(2023, 1, 15, 15, 30, 0)

        # Same instant in different zones compares equal
        @test parse_xsd_datetime("2023-01-15T10:30:00+05:30") ==
              parse_xsd_datetime("2023-01-15T05:00:00Z")
        # Different instants are NOT equal
        @test parse_xsd_datetime("2023-01-15T10:30:00+05:30") !=
              parse_xsd_datetime("2023-01-15T10:30:00Z")

        # Offset crossing a date boundary
        @test parse_xsd_datetime("2023-01-15T01:00:00+05:00") ==
              DateTime(2023, 1, 14, 20, 0, 0)

        dt = parse_xsd_datetime("2023-01-15T10:30:00.500")
        @test dt == DateTime(2023, 1, 15, 10, 30, 0, 500)

        # Fractional seconds of any precision (truncated beyond ms)
        @test parse_xsd_datetime("2023-01-15T10:30:00.5") ==
              DateTime(2023, 1, 15, 10, 30, 0, 500)
        @test parse_xsd_datetime("2023-01-15T10:30:00.123456789") ==
              DateTime(2023, 1, 15, 10, 30, 0, 123)
        @test parse_xsd_datetime("2023-01-15T10:30:00.123456789Z") ==
              DateTime(2023, 1, 15, 10, 30, 0, 123)
        @test parse_xsd_datetime("2023-01-15T10:30:00.25+05:30") ==
              DateTime(2023, 1, 15, 5, 0, 0, 250)

        # Negative years and years beyond 9999
        @test parse_xsd_datetime("-0500-01-15T00:00:00") == DateTime(-500, 1, 15)
        @test parse_xsd_datetime("12023-01-15T10:30:00") == DateTime(12023, 1, 15, 10, 30, 0)

        # XSD's 24:00:00 means first instant of the next day
        @test parse_xsd_datetime("2023-01-15T24:00:00") == DateTime(2023, 1, 16)

        @test_throws ArgumentError parse_xsd_datetime("not-a-datetime")
    end

    @testset "parse_xsd_date" begin
        d = parse_xsd_date("2023-01-15")
        @test d == Date(2023, 1, 15)

        d = parse_xsd_date("2023-01-15Z")
        @test d == Date(2023, 1, 15)

        d = parse_xsd_date("2023-01-15+05:30")
        @test d == Date(2023, 1, 15)

        # Negative years and years beyond 9999 (valid xsd:date)
        @test parse_xsd_date("-0500-01-15") == Date(-500, 1, 15)
        @test parse_xsd_date("-25000-12-31") == Date(-25000, 12, 31)
        @test parse_xsd_date("12023-01-15") == Date(12023, 1, 15)

        @test_throws ArgumentError parse_xsd_date("2023/01/15")
    end

    @testset "parse_xsd_time" begin
        t = parse_xsd_time("10:30:00")
        @test t == Time(10, 30, 0)

        t = parse_xsd_time("10:30:00Z")
        @test t == Time(10, 30, 0)

        t = parse_xsd_time("10:30:00.500")
        @test t == Time(10, 30, 0, 500)

        # Timezone offsets are applied (normalized to UTC, wrapping midnight)
        @test parse_xsd_time("10:30:00+05:30") == Time(5, 0, 0)
        @test parse_xsd_time("10:30:00+05:30") != parse_xsd_time("10:30:00Z")
        @test parse_xsd_time("01:00:00+05:00") == Time(20, 0, 0)  # wraps
        @test parse_xsd_time("22:00:00-05:00") == Time(3, 0, 0)   # wraps

        # Fractional seconds of any precision
        @test parse_xsd_time("10:30:00.123456789") == Time(10, 30, 0, 123)
        @test parse_xsd_time("10:30:00.5Z") == Time(10, 30, 0, 500)
    end

    @testset "format_xsd_datetime" begin
        @test format_xsd_datetime(DateTime(2023, 1, 15, 10, 30, 0)) == "2023-01-15T10:30:00"
        # Non-zero milliseconds are serialized
        @test format_xsd_datetime(DateTime(2020, 1, 1, 0, 0, 0, 123)) == "2020-01-01T00:00:00.123"
        @test format_xsd_datetime(DateTime(2023, 1, 15, 10, 30, 45, 500)) == "2023-01-15T10:30:45.500"
    end

    @testset "format_xsd_date" begin
        @test format_xsd_date(Date(2023, 1, 15)) == "2023-01-15"
    end

    @testset "format_xsd_time" begin
        @test format_xsd_time(Time(10, 30, 0)) == "10:30:00"
        @test format_xsd_time(Time(10, 30, 0, 500)) == "10:30:00.500"
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

        # XSD canonical lexicals for special floats
        @test xsd_literal(Inf).lexical == "INF"
        @test xsd_literal(-Inf).lexical == "-INF"
        @test xsd_literal(NaN).lexical == "NaN"

        lit = xsd_literal(true)
        @test lit.lexical == "true"
        @test lit.datatype == XSD.boolean

        lit = xsd_literal(false)
        @test lit.lexical == "false"
        @test lit.datatype == XSD.boolean

        # RDF 1.1: an xsd:string literal IS a simple literal (canonical form
        # stores no datatype)
        lit = xsd_literal("hello")
        @test lit.lexical == "hello"
        @test lit.datatype === nothing
        @test lit == Literal("hello")
    end

    @testset "round-trip" begin
        dt = DateTime(2023, 6, 15, 14, 30, 45)
        @test parse_xsd_datetime(format_xsd_datetime(dt)) == dt

        # Milliseconds survive the round-trip
        dtms = DateTime(2023, 6, 15, 14, 30, 45, 123)
        @test parse_xsd_datetime(format_xsd_datetime(dtms)) == dtms

        d = Date(2023, 6, 15)
        @test parse_xsd_date(format_xsd_date(d)) == d

        t = Time(14, 30, 45)
        @test parse_xsd_time(format_xsd_time(t)) == t

        tms = Time(14, 30, 45, 250)
        @test parse_xsd_time(format_xsd_time(tms)) == tms
    end
end
