# XSD datetime parsing and formatting utilities

# Split a trailing timezone designator off an XSD date/time lexical form.
# Returns `(base, offset_minutes)` where `offset_minutes` is `nothing` when no
# timezone is present, `0` for `Z`, and the signed offset in minutes for
# `±HH:MM`.
function _split_tz(s::AbstractString)
    if endswith(s, 'Z') || endswith(s, 'z')
        return (String(chop(s)), 0)
    end
    m = match(r"([+-])(\d{2}):(\d{2})$", s)
    isnothing(m) && return (String(s), nothing)
    sign = m.captures[1] == "-" ? -1 : 1
    hh = parse(Int, m.captures[2])
    mm = parse(Int, m.captures[3])
    (hh < 14 || (hh == 14 && mm == 0)) || throw(ArgumentError("Invalid xsd timezone offset: $s"))
    mm < 60 || throw(ArgumentError("Invalid xsd timezone offset: $s"))
    mins = sign * (hh * 60 + mm)
    (String(s[1:end-6]), mins)
end

# Backwards-compatible helper: remove a trailing timezone designator.
function _strip_tz(s::AbstractString)
    first(_split_tz(s))
end

function _xsd_year_string(y::Int)
    abs_y = abs(y)
    body = lpad(string(abs_y), max(4, ndigits(abs_y)), '0')
    y < 0 ? "-" * body : body
end

function _xsd_date_prefix(y::Int, mo::Int, d::Int)
    string(_xsd_year_string(y), "-",
           lpad(string(mo), 2, '0'), "-",
           lpad(string(d), 2, '0'))
end

# Convert a fractional-seconds digit string to milliseconds, truncating any
# precision beyond milliseconds.
function _frac_to_ms(frac::Union{AbstractString, Nothing})
    isnothing(frac) && return 0
    f = length(frac) > 3 ? frac[1:3] : rpad(frac, 3, '0')
    parse(Int, f)
end

"""
    parse_xsd_datetime(s::AbstractString) -> DateTime

Parse an XSD dateTime string (e.g. `2023-01-15T10:30:00Z`,
`2023-01-15T10:30:00.123+05:30`, `-0500-01-15T00:00:00`).

A timezone offset (`Z` or `±HH:MM`), when present, is applied so the returned
`DateTime` is normalized to UTC (Julia's `DateTime` carries no timezone).
Fractional seconds of any precision are accepted (truncated to milliseconds).
Negative and >4-digit years are supported.
"""
function parse_xsd_datetime(s::AbstractString)
    str = strip(s)
    base, tzmin = _split_tz(str)
    # Tolerant of date-only and seconds-less forms (missing parts default to 0),
    # matching the leniency of the previous implementation.
    m = match(r"^(-?\d{4,})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?)?$", base)
    isnothing(m) && throw(ArgumentError("Invalid xsd:dateTime lexical form: $s"))
    y  = parse(Int, m.captures[1])
    mo = parse(Int, m.captures[2])
    d  = parse(Int, m.captures[3])
    h  = isnothing(m.captures[4]) ? 0 : parse(Int, m.captures[4])
    mi = isnothing(m.captures[5]) ? 0 : parse(Int, m.captures[5])
    se = isnothing(m.captures[6]) ? 0 : parse(Int, m.captures[6])
    ms = _frac_to_ms(m.captures[7])
    # XSD allows 24:00:00 meaning the first instant of the following day
    dt = if h == 24 && mi == 0 && se == 0 && ms == 0
        DateTime(y, mo, d) + Day(1)
    else
        DateTime(y, mo, d, h, mi, se, ms)
    end
    isnothing(tzmin) || tzmin == 0 || (dt -= Minute(tzmin))
    dt
end

"""
    parse_xsd_date(s::AbstractString) -> Date

Parse an XSD date string (e.g. `2023-01-15`, `-0500-01-15`, `2023-01-15Z`).
Negative and >4-digit years are supported. A trailing timezone designator is
accepted and ignored (Julia's `Date` carries no timezone).
"""
function parse_xsd_date(s::AbstractString)
    base, _ = _split_tz(strip(s))
    m = match(r"^(-?\d{4,})-(\d{2})-(\d{2})$", base)
    isnothing(m) && throw(ArgumentError("Invalid xsd:date lexical form: $s"))
    Date(parse(Int, m.captures[1]), parse(Int, m.captures[2]), parse(Int, m.captures[3]))
end

"""
    parse_xsd_time(s::AbstractString) -> Time

Parse an XSD time string (e.g. `10:30:00`, `10:30:00.5Z`, `10:30:00+05:30`).

A timezone offset (`Z` or `±HH:MM`), when present, is applied so the returned
`Time` is normalized to UTC (wrapping around midnight as needed). Fractional
seconds of any precision are accepted (truncated to milliseconds).
"""
function parse_xsd_time(s::AbstractString)
    base, tzmin = _split_tz(strip(s))
    m = match(r"^(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?$", base)
    isnothing(m) && throw(ArgumentError("Invalid xsd:time lexical form: $s"))
    h  = parse(Int, m.captures[1])
    mi = parse(Int, m.captures[2])
    se = parse(Int, m.captures[3])
    ms = _frac_to_ms(m.captures[4])
    t = if h == 24 && mi == 0 && se == 0 && ms == 0
        Time(0)
    else
        Time(h, mi, se, ms)
    end
    isnothing(tzmin) || tzmin == 0 || (t -= Minute(tzmin))
    t
end

"""
    format_xsd_datetime(dt::DateTime) -> String

Format a DateTime as XSD dateTime string. Fractional seconds are included
when non-zero (e.g. `2020-01-01T00:00:00.123`).
"""
function format_xsd_datetime(dt::DateTime)
    prefix = _xsd_date_prefix(year(dt), month(dt), day(dt))
    suffix = string(lpad(string(hour(dt)), 2, '0'), ":",
                    lpad(string(minute(dt)), 2, '0'), ":",
                    lpad(string(second(dt)), 2, '0'))
    if millisecond(dt) == 0
        prefix * "T" * suffix
    else
        prefix * "T" * suffix * "." * lpad(string(millisecond(dt)), 3, '0')
    end
end

"""
    format_xsd_date(d::Date) -> String

Format a Date as XSD date string.
"""
format_xsd_date(d::Date) = _xsd_date_prefix(year(d), month(d), day(d))

"""
    format_xsd_time(t::Time) -> String

Format a Time as XSD time string. Fractional seconds are included when
non-zero.
"""
function format_xsd_time(t::Time)
    if millisecond(t) == 0 && microsecond(t) == 0 && nanosecond(t) == 0
        Dates.format(t, dateformat"HH:MM:SS")
    else
        Dates.format(t, dateformat"HH:MM:SS.sss")
    end
end

"""
    xsd_literal(value) -> Literal

Create a typed XSD Literal from a Julia value.
"""
xsd_literal(dt::DateTime) = Literal(format_xsd_datetime(dt); datatype=XSD.dateTime)
xsd_literal(d::Date) = Literal(format_xsd_date(d); datatype=XSD.date)
xsd_literal(t::Time) = Literal(format_xsd_time(t); datatype=XSD.time)
xsd_literal(i::Integer) = Literal(string(i); datatype=XSD.integer)
xsd_literal(f::AbstractFloat) = Literal(_float_lexical(f); datatype=XSD.double)
xsd_literal(b::Bool) = Literal(b ? "true" : "false"; datatype=XSD.boolean)
xsd_literal(s::AbstractString) = Literal(s; datatype=XSD.string)
