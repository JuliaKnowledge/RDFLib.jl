# XSD datetime parsing and formatting utilities

"""
    parse_xsd_datetime(s::AbstractString) -> DateTime

Parse an XSD dateTime string (e.g. `2023-01-15T10:30:00Z`, `2023-01-15T10:30:00+05:30`).
Timezone offset is stripped (Julia DateTime has no timezone support).
"""
function parse_xsd_datetime(s::AbstractString)
    s = strip(s)
    # Strip timezone info for DateTime parsing
    base = _strip_tz(s)
    # Handle fractional seconds
    if occursin(".", base)
        # Julia's DateTime supports milliseconds
        parts = split(base, ".")
        frac = parts[2]
        if length(frac) > 3
            frac = frac[1:3]
        elseif length(frac) < 3
            frac = rpad(frac, 3, '0')
        end
        base = parts[1] * "." * frac
        return DateTime(base, dateformat"yyyy-mm-ddTHH:MM:SS.sss")
    end
    DateTime(base, dateformat"yyyy-mm-ddTHH:MM:SS")
end

"""
    parse_xsd_date(s::AbstractString) -> Date

Parse an XSD date string (e.g. `2023-01-15`).
"""
function parse_xsd_date(s::AbstractString)
    s = _strip_tz(strip(s))
    Date(s, dateformat"yyyy-mm-dd")
end

"""
    parse_xsd_time(s::AbstractString) -> Time

Parse an XSD time string (e.g. `10:30:00`, `10:30:00.5Z`).
"""
function parse_xsd_time(s::AbstractString)
    s = _strip_tz(strip(s))
    if occursin(".", s)
        parts = split(s, ".")
        frac = parts[2]
        if length(frac) > 3
            frac = frac[1:3]
        elseif length(frac) < 3
            frac = rpad(frac, 3, '0')
        end
        s = parts[1] * "." * frac
        return Time(s, dateformat"HH:MM:SS.sss")
    end
    Time(s, dateformat"HH:MM:SS")
end

function _strip_tz(s::AbstractString)
    # Remove Z suffix
    s = replace(s, r"Z$" => "")
    # Remove +HH:MM or -HH:MM timezone offset at end
    s = replace(s, r"[+-]\d{2}:\d{2}$" => "")
    s
end

"""
    format_xsd_datetime(dt::DateTime) -> String

Format a DateTime as XSD dateTime string.
"""
format_xsd_datetime(dt::DateTime) = Dates.format(dt, dateformat"yyyy-mm-ddTHH:MM:SS")

"""
    format_xsd_date(d::Date) -> String

Format a Date as XSD date string.
"""
format_xsd_date(d::Date) = Dates.format(d, dateformat"yyyy-mm-dd")

"""
    format_xsd_time(t::Time) -> String

Format a Time as XSD time string.
"""
format_xsd_time(t::Time) = Dates.format(t, dateformat"HH:MM:SS")

"""
    xsd_literal(value) -> Literal

Create a typed XSD Literal from a Julia value.
"""
xsd_literal(dt::DateTime) = Literal(format_xsd_datetime(dt); datatype=XSD.dateTime)
xsd_literal(d::Date) = Literal(format_xsd_date(d); datatype=XSD.date)
xsd_literal(t::Time) = Literal(format_xsd_time(t); datatype=XSD.time)
xsd_literal(i::Integer) = Literal(string(i); datatype=XSD.integer)
xsd_literal(f::AbstractFloat) = Literal(string(f); datatype=XSD.double)
xsd_literal(b::Bool) = Literal(b ? "true" : "false"; datatype=XSD.boolean)
xsd_literal(s::AbstractString) = Literal(s; datatype=XSD.string)
