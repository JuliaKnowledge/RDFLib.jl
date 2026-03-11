# ─── GeoSPARQL Support ─────────────────────────────────────────────────────
# WKT parsing, spatial relations (Simple Features), metric functions,
# and SPARQL integration for GeoSPARQL function URIs.

# ─── GEOF Namespace ──────────────────────────────────────────────────────────

const GEOF = DefinedNamespace(
    "http://www.opengis.net/def/function/geosparql/",
    Set(["sfContains", "sfWithin", "sfIntersects", "sfOverlaps",
         "sfTouches", "sfDisjoint", "sfEquals", "sfCrosses",
         "ehContains", "ehCoveredBy", "ehCovers", "ehDisjoint",
         "ehEquals", "ehInside", "ehMeet", "ehOverlap",
         "rcc8dc", "rcc8ec", "rcc8po", "rcc8tpp", "rcc8ntpp",
         "rcc8tppi", "rcc8ntppi", "rcc8eq",
         "distance", "buffer", "area", "boundary", "length", "perimeter",
         "convexHull", "envelope", "centroid",
         "intersection", "union", "difference", "symDifference",
         "relate", "getSRID", "geometryType", "dimension",
         "isEmpty", "isSimple", "coordinateDimension",
         "minX", "maxX", "minY", "maxY", "minZ", "maxZ",
         "asWKT", "asGeoJSON", "numGeometries", "geometryN",
         "is3D", "isMeasured", "volume", "surfaceArea"])
)

const _GEOF_NS = "http://www.opengis.net/def/function/geosparql/"
const _GEO_NS  = "http://www.opengis.net/ont/geosparql#"
const _GEO_WKT_LITERAL = URIRef("http://www.opengis.net/ont/geosparql#wktLiteral")

# ─── Geometry Types ──────────────────────────────────────────────────────────

abstract type AbstractGeometry end

struct GeoPoint <: AbstractGeometry
    x::Float64
    y::Float64
    z::Float64
end
GeoPoint(x::Float64, y::Float64) = GeoPoint(x, y, NaN)
GeoPoint(x::Real, y::Real) = GeoPoint(Float64(x), Float64(y), NaN)
GeoPoint(x::Real, y::Real, z::Real) = GeoPoint(Float64(x), Float64(y), Float64(z))

struct GeoLineString <: AbstractGeometry
    points::Vector{GeoPoint}
end

struct GeoPolygon <: AbstractGeometry
    exterior::Vector{GeoPoint}
    holes::Vector{Vector{GeoPoint}}
end

struct GeoMultiPoint <: AbstractGeometry
    points::Vector{GeoPoint}
end

struct GeoMultiLineString <: AbstractGeometry
    lines::Vector{GeoLineString}
end

struct GeoMultiPolygon <: AbstractGeometry
    polygons::Vector{GeoPolygon}
end

struct GeoCollection <: AbstractGeometry
    geometries::Vector{AbstractGeometry}
end

struct GeoPolyhedralSurface <: AbstractGeometry
    patches::Vector{GeoPolygon}
end

struct GeoTIN <: AbstractGeometry
    triangles::Vector{GeoPolygon}
end

# ─── WKT Parsing ─────────────────────────────────────────────────────────────

"""
    parse_wkt(s::String) → AbstractGeometry

Parse a Well-Known Text string into a geometry struct.
Supports POINT, LINESTRING, POLYGON, MULTIPOINT, MULTILINESTRING,
MULTIPOLYGON, and GEOMETRYCOLLECTION.
"""
function parse_wkt(s::AbstractString)
    s = strip(s)
    # Strip optional SRID prefix: SRID=4326;POINT(...)
    m = match(r"^SRID\s*=\s*\d+\s*;\s*(.+)$"i, s)
    if !isnothing(m)
        s = strip(m.captures[1])
    end
    # Normalize: strip Z/ZM modifiers (3D coords are auto-detected by _parse_wkt_coord)
    s_norm = replace(s, r"(?i)^(\w+)\s+ZM?\s*\(" => s"\1 (")
    if s_norm != s
        s = s_norm
    end
    su = uppercase(s)
    if startswith(su, "GEOMETRYCOLLECTION")
        return _parse_wkt_geometrycollection(s)
    elseif startswith(su, "POLYHEDRALSURFACE")
        return _parse_wkt_polyhedralsurface(s)
    elseif startswith(su, "TIN")
        return _parse_wkt_tin(s)
    elseif startswith(su, "MULTIPOLYGON")
        return _parse_wkt_multipolygon(s)
    elseif startswith(su, "MULTILINESTRING")
        return _parse_wkt_multilinestring(s)
    elseif startswith(su, "MULTIPOINT")
        return _parse_wkt_multipoint(s)
    elseif startswith(su, "POLYGON")
        return _parse_wkt_polygon(s)
    elseif startswith(su, "LINESTRING")
        return _parse_wkt_linestring(s)
    elseif startswith(su, "POINT")
        return _parse_wkt_point(s)
    else
        error("Unsupported WKT geometry type: $s")
    end
end

function _wkt_extract_parens(s::AbstractString, keyword::AbstractString)
    m = match(Regex("^$(keyword)\\s*\\((.+)\\)\\s*\$", "is"), s)
    isnothing(m) && error("Invalid WKT $keyword: $s")
    return strip(m.captures[1])
end

function _parse_wkt_coord(s::AbstractString)
    parts = split(strip(s))
    length(parts) >= 2 || error("Invalid WKT coordinate: $s")
    x = parse(Float64, parts[1])
    y = parse(Float64, parts[2])
    if length(parts) >= 3
        z = parse(Float64, parts[3])
        return GeoPoint(x, y, z)
    end
    GeoPoint(x, y)
end

function _parse_wkt_coord_list(s::AbstractString)
    [_parse_wkt_coord(c) for c in split(s, ",")]
end

function _parse_wkt_point(s::AbstractString)
    # Handle POINT Z (...) syntax
    m = match(r"^POINT\s+Z\s*\((.+)\)\s*$"i, s)
    if isnothing(m)
        inner = _wkt_extract_parens(s, "POINT")
    else
        inner = strip(m.captures[1])
    end
    _parse_wkt_coord(inner)
end

function _parse_wkt_linestring(s::AbstractString)
    inner = _wkt_extract_parens(s, "LINESTRING")
    GeoLineString(_parse_wkt_coord_list(inner))
end

function _parse_wkt_ring_list(s::AbstractString)
    # Split on ),(  — each ring is in parens
    rings = Vector{GeoPoint}[]
    depth = 0
    buf = IOBuffer()
    for c in s
        if c == '('
            depth += 1
            depth > 1 && write(buf, c)
        elseif c == ')'
            depth -= 1
            if depth == 0
                push!(rings, _parse_wkt_coord_list(String(take!(buf))))
            else
                write(buf, c)
            end
        elseif c == ',' && depth == 0
            # separator between rings
        else
            write(buf, c)
        end
    end
    remaining = String(take!(buf))
    if !isempty(strip(remaining))
        push!(rings, _parse_wkt_coord_list(remaining))
    end
    return rings
end

function _parse_wkt_polygon(s::AbstractString)
    inner = _wkt_extract_parens(s, "POLYGON")
    rings = _parse_wkt_ring_list(inner)
    isempty(rings) && error("Invalid WKT POLYGON: no rings")
    GeoPolygon(rings[1], rings[2:end])
end

function _parse_wkt_multipoint(s::AbstractString)
    inner = _wkt_extract_parens(s, "MULTIPOINT")
    # MULTIPOINT can be ((x y), (x y)) or (x y, x y)
    if occursin('(', inner)
        points = GeoPoint[]
        for m in eachmatch(r"\(\s*([^)]+)\s*\)", inner)
            push!(points, _parse_wkt_coord(m.captures[1]))
        end
        return GeoMultiPoint(points)
    else
        return GeoMultiPoint(_parse_wkt_coord_list(inner))
    end
end

function _parse_wkt_multilinestring(s::AbstractString)
    inner = _wkt_extract_parens(s, "MULTILINESTRING")
    rings = _parse_wkt_ring_list(inner)
    GeoMultiLineString([GeoLineString(r) for r in rings])
end

function _parse_wkt_multipolygon(s::AbstractString)
    inner = _wkt_extract_parens(s, "MULTIPOLYGON")
    # Split into polygon groups — each polygon is ((ring), (ring), ...)
    # We need to split at depth 1 commas
    polygons = GeoPolygon[]
    depth = 0
    buf = IOBuffer()
    for c in inner
        if c == '('
            depth += 1
            write(buf, c)
        elseif c == ')'
            depth -= 1
            write(buf, c)
            if depth == 0
                raw = strip(String(take!(buf)))
                if !isempty(raw)
                    # raw is like ((x y, x y), (x y, x y))
                    # Extract the inner ring list
                    rm = match(r"^\((.+)\)$"s, raw)
                    if !isnothing(rm)
                        rings = _parse_wkt_ring_list(rm.captures[1])
                        isempty(rings) || push!(polygons, GeoPolygon(rings[1], rings[2:end]))
                    end
                end
            end
        elseif c == ',' && depth == 0
            # separator between polygon groups, skip
        else
            write(buf, c)
        end
    end
    GeoMultiPolygon(polygons)
end

function _parse_wkt_geometrycollection(s::AbstractString)
    inner = _wkt_extract_parens(s, "GEOMETRYCOLLECTION")
    # Split at depth-0 commas
    geoms = AbstractGeometry[]
    depth = 0
    buf = IOBuffer()
    for c in inner
        if c == '('
            depth += 1
            write(buf, c)
        elseif c == ')'
            depth -= 1
            write(buf, c)
        elseif c == ',' && depth == 0
            push!(geoms, parse_wkt(String(take!(buf))))
        else
            write(buf, c)
        end
    end
    remaining = String(take!(buf))
    !isempty(strip(remaining)) && push!(geoms, parse_wkt(remaining))
    GeoCollection(geoms)
end

function _parse_wkt_polyhedralsurface(s::AbstractString)
    inner = _wkt_extract_parens(s, "POLYHEDRALSURFACE")
    patches = GeoPolygon[]
    depth = 0
    buf = IOBuffer()
    for c in inner
        if c == '('
            depth += 1
            write(buf, c)
        elseif c == ')'
            depth -= 1
            write(buf, c)
            if depth == 0
                raw = strip(String(take!(buf)))
                if !isempty(raw)
                    rm = match(r"^\((.+)\)$"s, raw)
                    if !isnothing(rm)
                        rings = _parse_wkt_ring_list(rm.captures[1])
                        isempty(rings) || push!(patches, GeoPolygon(rings[1], rings[2:end]))
                    end
                end
            end
        elseif c == ',' && depth == 0
            # separator between patches
        else
            write(buf, c)
        end
    end
    GeoPolyhedralSurface(patches)
end

function _parse_wkt_tin(s::AbstractString)
    inner = _wkt_extract_parens(s, "TIN")
    triangles = GeoPolygon[]
    depth = 0
    buf = IOBuffer()
    for c in inner
        if c == '('
            depth += 1
            write(buf, c)
        elseif c == ')'
            depth -= 1
            write(buf, c)
            if depth == 0
                raw = strip(String(take!(buf)))
                if !isempty(raw)
                    rm = match(r"^\((.+)\)$"s, raw)
                    if !isnothing(rm)
                        rings = _parse_wkt_ring_list(rm.captures[1])
                        isempty(rings) || push!(triangles, GeoPolygon(rings[1], rings[2:end]))
                    end
                end
            end
        elseif c == ',' && depth == 0
            # separator between triangles
        else
            write(buf, c)
        end
    end
    GeoTIN(triangles)
end

# ─── Bounding Box ────────────────────────────────────────────────────────────

struct _BBox
    xmin::Float64; ymin::Float64
    xmax::Float64; ymax::Float64
end

function _bbox(pts::Vector{GeoPoint})
    isempty(pts) && return _BBox(0,0,0,0)
    _BBox(minimum(p.x for p in pts), minimum(p.y for p in pts),
          maximum(p.x for p in pts), maximum(p.y for p in pts))
end

function _bbox(g::GeoPoint)
    _BBox(g.x, g.y, g.x, g.y)
end

function _bbox(g::GeoLineString)
    _bbox(g.points)
end

function _bbox(g::GeoPolygon)
    _bbox(g.exterior)
end

function _bbox(g::GeoMultiPoint)
    _bbox(g.points)
end

function _bbox(g::GeoMultiLineString)
    pts = vcat([l.points for l in g.lines]...)
    _bbox(pts)
end

function _bbox(g::GeoMultiPolygon)
    pts = vcat([p.exterior for p in g.polygons]...)
    _bbox(pts)
end

function _bbox(g::GeoCollection)
    isempty(g.geometries) && return _BBox(0,0,0,0)
    bboxes = [_bbox(geom) for geom in g.geometries]
    _BBox(minimum(b.xmin for b in bboxes), minimum(b.ymin for b in bboxes),
          maximum(b.xmax for b in bboxes), maximum(b.ymax for b in bboxes))
end

_bbox(g::GeoPolyhedralSurface) = _bbox(vcat([p.exterior for p in g.patches]...))
_bbox(g::GeoTIN) = _bbox(vcat([t.exterior for t in g.triangles]...))

function _bbox_intersects(a::_BBox, b::_BBox)
    a.xmin <= b.xmax && a.xmax >= b.xmin && a.ymin <= b.ymax && a.ymax >= b.ymin
end

function _bbox_contains(outer::_BBox, inner::_BBox)
    outer.xmin <= inner.xmin && outer.ymin <= inner.ymin &&
    outer.xmax >= inner.xmax && outer.ymax >= inner.ymax
end

# ─── Core Geometric Algorithms ───────────────────────────────────────────────

function _cross2d(ox, oy, ax, ay, bx, by)
    (ax - ox) * (by - oy) - (ay - oy) * (bx - ox)
end

"""Ray casting algorithm for point-in-polygon."""
function _point_in_polygon(px, py, ring::Vector{GeoPoint})
    n = length(ring)
    inside = false
    j = n
    for i in 1:n
        xi, yi = ring[i].x, ring[i].y
        xj, yj = ring[j].x, ring[j].y
        if ((yi > py) != (yj > py)) &&
           (px < (xj - xi) * (py - yi) / (yj - yi) + xi)
            inside = !inside
        end
        j = i
    end
    inside
end

function _point_on_segment(px, py, ax, ay, bx, by; tol=1e-10)
    cross = _cross2d(ax, ay, px, py, bx, by)
    abs(cross) > tol && return false
    min(ax, bx) - tol <= px <= max(ax, bx) + tol &&
    min(ay, by) - tol <= py <= max(ay, by) + tol
end

function _point_on_ring(px, py, ring::Vector{GeoPoint})
    n = length(ring)
    for i in 1:n
        j = i == n ? 1 : i + 1
        if _point_on_segment(px, py, ring[i].x, ring[i].y, ring[j].x, ring[j].y)
            return true
        end
    end
    false
end

"""Check if two segments (a1-a2) and (b1-b2) intersect."""
function _segments_intersect(a1x, a1y, a2x, a2y, b1x, b1y, b2x, b2y)
    d1 = _cross2d(b1x, b1y, b2x, b2y, a1x, a1y)
    d2 = _cross2d(b1x, b1y, b2x, b2y, a2x, a2y)
    d3 = _cross2d(a1x, a1y, a2x, a2y, b1x, b1y)
    d4 = _cross2d(a1x, a1y, a2x, a2y, b2x, b2y)
    if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
       ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
        return true
    end
    # Collinear cases
    abs(d1) < 1e-10 && _point_on_segment(a1x, a1y, b1x, b1y, b2x, b2y) && return true
    abs(d2) < 1e-10 && _point_on_segment(a2x, a2y, b1x, b1y, b2x, b2y) && return true
    abs(d3) < 1e-10 && _point_on_segment(b1x, b1y, a1x, a1y, a2x, a2y) && return true
    abs(d4) < 1e-10 && _point_on_segment(b2x, b2y, a1x, a1y, a2x, a2y) && return true
    false
end

"""Check if two rings have any edge intersection."""
function _rings_intersect(r1::Vector{GeoPoint}, r2::Vector{GeoPoint})
    n1, n2 = length(r1), length(r2)
    for i in 1:n1
        j1 = i == n1 ? 1 : i + 1
        for k in 1:n2
            k1 = k == n2 ? 1 : k + 1
            if _segments_intersect(r1[i].x, r1[i].y, r1[j1].x, r1[j1].y,
                                   r2[k].x, r2[k].y, r2[k1].x, r2[k1].y)
                return true
            end
        end
    end
    false
end

"""Signed area of a polygon ring (positive = CCW)."""
function _signed_area(ring::Vector{GeoPoint})
    n = length(ring)
    a = 0.0
    for i in 1:n
        j = i == n ? 1 : i + 1
        a += ring[i].x * ring[j].y - ring[j].x * ring[i].y
    end
    a / 2.0
end

"""Centroid of a polygon ring."""
function _centroid(ring::Vector{GeoPoint})
    n = length(ring)
    cx, cy, a2 = 0.0, 0.0, 0.0
    for i in 1:n
        j = i == n ? 1 : i + 1
        cross = ring[i].x * ring[j].y - ring[j].x * ring[i].y
        cx += (ring[i].x + ring[j].x) * cross
        cy += (ring[i].y + ring[j].y) * cross
        a2 += cross
    end
    a2 == 0.0 && return GeoPoint(ring[1].x, ring[1].y)
    GeoPoint(cx / (3.0 * a2), cy / (3.0 * a2))
end

# ─── Centroid for all geometry types ─────────────────────────────────────────

_geo_centroid(g::GeoPoint) = g

function _geo_centroid(g::GeoLineString)
    isempty(g.points) && return GeoPoint(0.0, 0.0)
    mx = sum(p.x for p in g.points) / length(g.points)
    my = sum(p.y for p in g.points) / length(g.points)
    GeoPoint(mx, my)
end

_geo_centroid(g::GeoPolygon) = _centroid(g.exterior)

function _geo_centroid(g::GeoMultiPoint)
    isempty(g.points) && return GeoPoint(0.0, 0.0)
    mx = sum(p.x for p in g.points) / length(g.points)
    my = sum(p.y for p in g.points) / length(g.points)
    GeoPoint(mx, my)
end

function _geo_centroid(g::GeoMultiLineString)
    isempty(g.lines) && return GeoPoint(0.0, 0.0)
    pts = vcat([l.points for l in g.lines]...)
    mx = sum(p.x for p in pts) / length(pts)
    my = sum(p.y for p in pts) / length(pts)
    GeoPoint(mx, my)
end

function _geo_centroid(g::GeoMultiPolygon)
    isempty(g.polygons) && return GeoPoint(0.0, 0.0)
    centroids = [_geo_centroid(p) for p in g.polygons]
    mx = sum(c.x for c in centroids) / length(centroids)
    my = sum(c.y for c in centroids) / length(centroids)
    GeoPoint(mx, my)
end

function _geo_centroid(g::GeoCollection)
    isempty(g.geometries) && return GeoPoint(0.0, 0.0)
    centroids = [_geo_centroid(geom) for geom in g.geometries]
    mx = sum(c.x for c in centroids) / length(centroids)
    my = sum(c.y for c in centroids) / length(centroids)
    GeoPoint(mx, my)
end

"""
    geo_centroid(g::AbstractGeometry) → GeoPoint

Compute the centroid of a geometry.
"""
const geo_centroid = _geo_centroid

# ─── Point in polygon (with holes) ──────────────────────────────────────────

function _point_in_full_polygon(px, py, poly::GeoPolygon)
    _point_in_polygon(px, py, poly.exterior) || return false
    for hole in poly.holes
        _point_in_polygon(px, py, hole) && return false
    end
    true
end

# ─── All points of a geometry ────────────────────────────────────────────────

_all_points(g::GeoPoint) = [g]
_all_points(g::GeoLineString) = g.points
_all_points(g::GeoPolygon) = g.exterior
_all_points(g::GeoMultiPoint) = g.points
_all_points(g::GeoMultiLineString) = vcat([l.points for l in g.lines]...)
_all_points(g::GeoMultiPolygon) = vcat([p.exterior for p in g.polygons]...)
_all_points(g::GeoCollection) = vcat([_all_points(geom) for geom in g.geometries]...)
_all_points(g::GeoPolyhedralSurface) = vcat([p.exterior for p in g.patches]...)
_all_points(g::GeoTIN) = vcat([t.exterior for t in g.triangles]...)

# ─── Spatial Relations (Simple Features) ─────────────────────────────────────

"""
    geo_equals(a::AbstractGeometry, b::AbstractGeometry) → Bool

Test if two geometries are geometrically equal (same points within tolerance).
"""
function geo_equals(a::AbstractGeometry, b::AbstractGeometry)
    _geo_equals_impl(a, b)
end

function _geo_equals_impl(a::GeoPoint, b::GeoPoint; tol=1e-10)
    abs(a.x - b.x) < tol && abs(a.y - b.y) < tol &&
    (isnan(a.z) && isnan(b.z) || (!isnan(a.z) && !isnan(b.z) && abs(a.z - b.z) < tol))
end

function _geo_equals_impl(a::GeoLineString, b::GeoLineString; tol=1e-10)
    length(a.points) == length(b.points) || return false
    all(i -> _geo_equals_impl(a.points[i], b.points[i]; tol), 1:length(a.points))
end

function _geo_equals_impl(a::GeoPolygon, b::GeoPolygon; tol=1e-10)
    length(a.exterior) == length(b.exterior) || return false
    all(i -> _geo_equals_impl(a.exterior[i], b.exterior[i]; tol), 1:length(a.exterior)) || return false
    length(a.holes) == length(b.holes) || return false
    all(i -> begin
        length(a.holes[i]) == length(b.holes[i]) || return false
        all(j -> _geo_equals_impl(a.holes[i][j], b.holes[i][j]; tol), 1:length(a.holes[i]))
    end, 1:length(a.holes))
end

function _geo_equals_impl(a::AbstractGeometry, b::AbstractGeometry; tol=1e-10)
    typeof(a) == typeof(b) || return false
    ap = _all_points(a)
    bp = _all_points(b)
    length(ap) == length(bp) || return false
    all(i -> _geo_equals_impl(ap[i], bp[i]; tol), 1:length(ap))
end

"""
    geo_distance(a::AbstractGeometry, b::AbstractGeometry) → Float64

Euclidean distance between two geometries. Uses closest point for points/lines,
centroid for complex geometries.
"""
function geo_distance(a::AbstractGeometry, b::AbstractGeometry)
    _geo_distance_impl(a, b)
end

function _geo_distance_impl(a::GeoPoint, b::GeoPoint)
    d2 = (a.x - b.x)^2 + (a.y - b.y)^2
    if !isnan(a.z) && !isnan(b.z)
        d2 += (a.z - b.z)^2
    end
    sqrt(d2)
end

function _geo_distance_impl(a::GeoPoint, b::GeoLineString)
    isempty(b.points) && return Inf
    minimum(_point_segment_dist(a, b.points[i], b.points[i+1]) for i in 1:length(b.points)-1)
end

_geo_distance_impl(a::GeoLineString, b::GeoPoint) = _geo_distance_impl(b, a)

function _geo_distance_impl(a::GeoPoint, b::GeoPolygon)
    _point_in_full_polygon(a.x, a.y, b) && return 0.0
    _point_on_ring(a.x, a.y, b.exterior) && return 0.0
    # Distance to exterior ring edges
    d = Inf
    ring = b.exterior
    for i in 1:length(ring)
        j = i == length(ring) ? 1 : i + 1
        d = min(d, _point_segment_dist(a, ring[i], ring[j]))
    end
    d
end

_geo_distance_impl(a::GeoPolygon, b::GeoPoint) = _geo_distance_impl(b, a)

function _geo_distance_impl(a::AbstractGeometry, b::AbstractGeometry)
    ca = _geo_centroid(a)
    cb = _geo_centroid(b)
    _geo_distance_impl(ca, cb)
end

function _point_segment_dist(p::GeoPoint, a::GeoPoint, b::GeoPoint)
    dx = b.x - a.x
    dy = b.y - a.y
    len2 = dx^2 + dy^2
    if len2 < 1e-20
        return sqrt((p.x - a.x)^2 + (p.y - a.y)^2)
    end
    t = clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0.0, 1.0)
    proj_x = a.x + t * dx
    proj_y = a.y + t * dy
    sqrt((p.x - proj_x)^2 + (p.y - proj_y)^2)
end

"""
    geo_contains(a::AbstractGeometry, b::AbstractGeometry) → Bool

Test if geometry A contains geometry B.
"""
function geo_contains(a::AbstractGeometry, b::AbstractGeometry)
    geo_within(b, a)
end

"""
    geo_within(a::AbstractGeometry, b::AbstractGeometry) → Bool

Test if geometry A is within geometry B.
"""
function geo_within(a::AbstractGeometry, b::AbstractGeometry)
    _geo_within_impl(a, b)
end

# Point within Polygon
function _geo_within_impl(a::GeoPoint, b::GeoPolygon)
    _point_in_full_polygon(a.x, a.y, b)
end

# Point within Point
function _geo_within_impl(a::GeoPoint, b::GeoPoint)
    _geo_equals_impl(a, b)
end

# Polygon within Polygon
function _geo_within_impl(a::GeoPolygon, b::GeoPolygon)
    bb_a = _bbox(a); bb_b = _bbox(b)
    _bbox_contains(bb_b, bb_a) || return false
    all(p -> _point_in_full_polygon(p.x, p.y, b), a.exterior)
end

# LineString within Polygon
function _geo_within_impl(a::GeoLineString, b::GeoPolygon)
    all(p -> _point_in_full_polygon(p.x, p.y, b) || _point_on_ring(p.x, p.y, b.exterior), a.points)
end

# MultiPoint within Polygon
function _geo_within_impl(a::GeoMultiPoint, b::GeoPolygon)
    all(p -> _point_in_full_polygon(p.x, p.y, b), a.points)
end

# Generic: all points within
function _geo_within_impl(a::AbstractGeometry, b::GeoPolygon)
    all(p -> _point_in_full_polygon(p.x, p.y, b), _all_points(a))
end

function _geo_within_impl(a::AbstractGeometry, b::AbstractGeometry)
    # For non-polygon containers, fall back to bbox containment
    bb_a = _bbox(a); bb_b = _bbox(b)
    _bbox_contains(bb_b, bb_a)
end

"""
    geo_intersects(a::AbstractGeometry, b::AbstractGeometry) → Bool

Test if two geometries intersect (share any point).
"""
function geo_intersects(a::AbstractGeometry, b::AbstractGeometry)
    !geo_disjoint(a, b)
end

"""
    geo_disjoint(a::AbstractGeometry, b::AbstractGeometry) → Bool

Test if two geometries are disjoint (share no points).
"""
function geo_disjoint(a::AbstractGeometry, b::AbstractGeometry)
    _geo_disjoint_impl(a, b)
end

# Point vs Point
function _geo_disjoint_impl(a::GeoPoint, b::GeoPoint)
    !_geo_equals_impl(a, b)
end

# Point vs Polygon
function _geo_disjoint_impl(a::GeoPoint, b::GeoPolygon)
    !_point_in_full_polygon(a.x, a.y, b) && !_point_on_ring(a.x, a.y, b.exterior)
end
_geo_disjoint_impl(a::GeoPolygon, b::GeoPoint) = _geo_disjoint_impl(b, a)

# Point vs LineString
function _geo_disjoint_impl(a::GeoPoint, b::GeoLineString)
    for i in 1:length(b.points)-1
        _point_on_segment(a.x, a.y, b.points[i].x, b.points[i].y,
                         b.points[i+1].x, b.points[i+1].y) && return false
    end
    true
end
_geo_disjoint_impl(a::GeoLineString, b::GeoPoint) = _geo_disjoint_impl(b, a)

# Polygon vs Polygon
function _geo_disjoint_impl(a::GeoPolygon, b::GeoPolygon)
    bb_a = _bbox(a); bb_b = _bbox(b)
    _bbox_intersects(bb_a, bb_b) || return true
    # Check edge intersections
    _rings_intersect(a.exterior, b.exterior) && return false
    # Check point containment
    any(p -> _point_in_full_polygon(p.x, p.y, b), a.exterior) && return false
    any(p -> _point_in_full_polygon(p.x, p.y, a), b.exterior) && return false
    true
end

# LineString vs Polygon
function _geo_disjoint_impl(a::GeoLineString, b::GeoPolygon)
    bb_a = _bbox(a); bb_b = _bbox(b)
    _bbox_intersects(bb_a, bb_b) || return true
    any(p -> _point_in_full_polygon(p.x, p.y, b) || _point_on_ring(p.x, p.y, b.exterior), a.points) && return false
    # Check edge intersections
    for i in 1:length(a.points)-1
        for j in 1:length(b.exterior)
            k = j == length(b.exterior) ? 1 : j + 1
            _segments_intersect(a.points[i].x, a.points[i].y, a.points[i+1].x, a.points[i+1].y,
                               b.exterior[j].x, b.exterior[j].y, b.exterior[k].x, b.exterior[k].y) && return false
        end
    end
    true
end
_geo_disjoint_impl(a::GeoPolygon, b::GeoLineString) = _geo_disjoint_impl(b, a)

# LineString vs LineString
function _geo_disjoint_impl(a::GeoLineString, b::GeoLineString)
    bb_a = _bbox(a); bb_b = _bbox(b)
    _bbox_intersects(bb_a, bb_b) || return true
    for i in 1:length(a.points)-1
        for j in 1:length(b.points)-1
            _segments_intersect(a.points[i].x, a.points[i].y, a.points[i+1].x, a.points[i+1].y,
                               b.points[j].x, b.points[j].y, b.points[j+1].x, b.points[j+1].y) && return false
        end
    end
    true
end

# Generic fallback
function _geo_disjoint_impl(a::AbstractGeometry, b::AbstractGeometry)
    bb_a = _bbox(a); bb_b = _bbox(b)
    _bbox_intersects(bb_a, bb_b) || return true
    # Check all pairs of points for exact matches
    ap = _all_points(a)
    bp = _all_points(b)
    for pa in ap
        for pb in bp
            _geo_equals_impl(pa, pb) && return false
        end
    end
    # For polygons in multi-geometries, check containment
    for pa in ap
        if b isa GeoPolygon && _point_in_full_polygon(pa.x, pa.y, b)
            return false
        end
        if b isa GeoMultiPolygon
            for poly in b.polygons
                _point_in_full_polygon(pa.x, pa.y, poly) && return false
            end
        end
    end
    for pb in bp
        if a isa GeoPolygon && _point_in_full_polygon(pb.x, pb.y, a)
            return false
        end
        if a isa GeoMultiPolygon
            for poly in a.polygons
                _point_in_full_polygon(pb.x, pb.y, poly) && return false
            end
        end
    end
    true
end

"""
    geo_touches(a::AbstractGeometry, b::AbstractGeometry) → Bool

Test if two geometries touch (share boundary but not interior).
"""
function geo_touches(a::AbstractGeometry, b::AbstractGeometry)
    _geo_touches_impl(a, b)
end

function _geo_touches_impl(a::GeoPoint, b::GeoPolygon)
    on_boundary = _point_on_ring(a.x, a.y, b.exterior)
    # Also check if point is exactly a vertex
    if !on_boundary
        on_boundary = any(p -> abs(p.x - a.x) < 1e-10 && abs(p.y - a.y) < 1e-10, b.exterior)
    end
    # If point is on boundary, it touches (regardless of what ray casting says)
    on_boundary
end
_geo_touches_impl(a::GeoPolygon, b::GeoPoint) = _geo_touches_impl(b, a)

function _geo_touches_impl(a::GeoPoint, b::GeoLineString)
    # Point touches linestring only at endpoints
    n = length(b.points)
    n < 1 && return false
    (_geo_equals_impl(a, b.points[1]) || _geo_equals_impl(a, b.points[end]))
end
_geo_touches_impl(a::GeoLineString, b::GeoPoint) = _geo_touches_impl(b, a)

function _geo_touches_impl(a::GeoPolygon, b::GeoPolygon)
    # Polygons touch if they share boundary but no interior overlap
    bb_a = _bbox(a); bb_b = _bbox(b)
    _bbox_intersects(bb_a, bb_b) || return false
    any(p -> _point_in_polygon(p.x, p.y, b.exterior), a.exterior) && return false
    any(p -> _point_in_polygon(p.x, p.y, a.exterior), b.exterior) && return false
    _rings_intersect(a.exterior, b.exterior) ||
    any(p -> _point_on_ring(p.x, p.y, b.exterior), a.exterior) ||
    any(p -> _point_on_ring(p.x, p.y, a.exterior), b.exterior)
end

function _geo_touches_impl(a::AbstractGeometry, b::AbstractGeometry)
    # General: share boundary but no interior
    !geo_disjoint(a, b) && begin
        ap = _all_points(a)
        bp = _all_points(b)
        # Check if any points are on the other's boundary but not in interior
        if b isa GeoPolygon
            return any(p -> _point_on_ring(p.x, p.y, b.exterior), ap) &&
                   !any(p -> _point_in_polygon(p.x, p.y, b.exterior), ap)
        end
        if a isa GeoPolygon
            return any(p -> _point_on_ring(p.x, p.y, a.exterior), bp) &&
                   !any(p -> _point_in_polygon(p.x, p.y, a.exterior), bp)
        end
        false
    end
end

"""
    geo_overlaps(a::AbstractGeometry, b::AbstractGeometry) → Bool

Test if two geometries overlap (same dimension, share interior but neither contains the other).
"""
function geo_overlaps(a::AbstractGeometry, b::AbstractGeometry)
    _geo_overlaps_impl(a, b)
end

function _geo_overlaps_impl(a::GeoPolygon, b::GeoPolygon)
    geo_disjoint(a, b) && return false
    geo_within(a, b) && return false
    geo_within(b, a) && return false
    # They must share some interior
    any(p -> _point_in_polygon(p.x, p.y, b.exterior), a.exterior) ||
    any(p -> _point_in_polygon(p.x, p.y, a.exterior), b.exterior)
end

function _geo_overlaps_impl(a::AbstractGeometry, b::AbstractGeometry)
    geo_disjoint(a, b) && return false
    geo_within(a, b) && return false
    geo_within(b, a) && return false
    true
end

# ─── Crosses Relation ────────────────────────────────────────────────────────

"""
    geo_crosses(a::AbstractGeometry, b::AbstractGeometry) → Bool

Two geometries cross if their intersection has dimension less than the maximum
dimension of the inputs, and the intersection set is interior to both.
"""
function geo_crosses(a::AbstractGeometry, b::AbstractGeometry)
    _geo_crosses_impl(a, b)
end

function _geo_crosses_impl(a::GeoLineString, b::GeoLineString)
    # Lines cross if they intersect at a finite number of points (not collinear overlap)
    geo_disjoint(a, b) && return false
    geo_within(a, b) && return false
    geo_within(b, a) && return false
    # They share at least one point but neither contains the other
    true
end

function _geo_crosses_impl(a::GeoLineString, b::GeoPolygon)
    # Line crosses polygon if part of line is inside and part outside
    geo_disjoint(a, b) && return false
    geo_within(a, b) && return false
    # Some points inside, some outside
    has_in = any(p -> _point_in_full_polygon(p.x, p.y, b), a.points)
    has_out = any(p -> !_point_in_full_polygon(p.x, p.y, b) && !_point_on_ring(p.x, p.y, b.exterior), a.points)
    has_in && has_out
end

_geo_crosses_impl(a::GeoPolygon, b::GeoLineString) = _geo_crosses_impl(b, a)

# Default: points never cross, polygons never cross each other (they overlap instead)
_geo_crosses_impl(a::AbstractGeometry, b::AbstractGeometry) = false

# ─── Metric Functions ────────────────────────────────────────────────────────

"""
    geo_area(geom::AbstractGeometry) → Float64

Area of a polygon (unsigned). Returns 0 for non-polygon types.
"""
geo_area(g::GeoPoint) = 0.0
geo_area(g::GeoLineString) = 0.0
geo_area(g::GeoMultiPoint) = 0.0

function geo_area(g::GeoPolygon)
    a = abs(_signed_area(g.exterior))
    for hole in g.holes
        a -= abs(_signed_area(hole))
    end
    max(a, 0.0)
end

function geo_area(g::GeoMultiPolygon)
    sum(geo_area(p) for p in g.polygons)
end

function geo_area(g::GeoMultiLineString)
    0.0
end

function geo_area(g::GeoCollection)
    sum(geo_area(geom) for geom in g.geometries)
end
geo_area(g::GeoPolyhedralSurface) = sum(geo_area(p) for p in g.patches)
geo_area(g::GeoTIN) = sum(geo_area(t) for t in g.triangles)

# ─── Length / Perimeter ──────────────────────────────────────────────────────

"""
    geo_length(g::AbstractGeometry) → Float64

Length of a geometry (for LineStrings — sum of segment lengths).
"""
geo_length(g::GeoPoint) = 0.0
geo_length(g::GeoPolygon) = 0.0
geo_length(g::GeoMultiPoint) = 0.0

function geo_length(g::GeoLineString)
    len = 0.0
    for i in 1:length(g.points)-1
        dx = g.points[i+1].x - g.points[i].x
        dy = g.points[i+1].y - g.points[i].y
        len += sqrt(dx^2 + dy^2)
    end
    len
end

function geo_length(g::GeoMultiLineString)
    sum(geo_length(l) for l in g.lines)
end

geo_length(g::GeoMultiPolygon) = 0.0

function geo_length(g::GeoCollection)
    sum(geo_length(geom) for geom in g.geometries)
end

"""
    geo_perimeter(g::AbstractGeometry) → Float64

Perimeter of a polygon (sum of exterior + hole ring lengths).
"""
geo_perimeter(g::GeoPoint) = 0.0
geo_perimeter(g::GeoLineString) = 0.0
geo_perimeter(g::GeoMultiPoint) = 0.0

function _ring_length(pts::Vector{GeoPoint})
    len = 0.0
    for i in 1:length(pts)-1
        dx = pts[i+1].x - pts[i].x
        dy = pts[i+1].y - pts[i].y
        len += sqrt(dx^2 + dy^2)
    end
    len
end

function geo_perimeter(g::GeoPolygon)
    p = _ring_length(g.exterior)
    for hole in g.holes
        p += _ring_length(hole)
    end
    p
end

function geo_perimeter(g::GeoMultiPolygon)
    sum(geo_perimeter(p) for p in g.polygons)
end

geo_perimeter(g::GeoMultiLineString) = 0.0

function geo_perimeter(g::GeoCollection)
    sum(geo_perimeter(geom) for geom in g.geometries)
end

"""
    geo_buffer(geom::AbstractGeometry, distance::Float64) → GeoPolygon

Buffer a geometry by a distance. For points, creates a regular polygon approximation
of a circle. For polygons, offsets exterior ring outward.
"""
function geo_buffer(g::GeoPoint, distance::Float64; nseg::Int=32)
    pts = GeoPoint[]
    for i in 0:nseg-1
        θ = 2π * i / nseg
        push!(pts, GeoPoint(g.x + distance * cos(θ), g.y + distance * sin(θ)))
    end
    push!(pts, pts[1])  # close ring
    GeoPolygon(pts, Vector{GeoPoint}[])
end

function geo_buffer(g::GeoPolygon, distance::Float64; nseg::Int=32)
    c = _geo_centroid(g)
    # Simple offset: scale exterior ring relative to centroid
    new_ext = GeoPoint[]
    for p in g.exterior
        dx = p.x - c.x
        dy = p.y - c.y
        len = sqrt(dx^2 + dy^2)
        if len < 1e-15
            push!(new_ext, p)
        else
            factor = (len + distance) / len
            push!(new_ext, GeoPoint(c.x + dx * factor, c.y + dy * factor))
        end
    end
    GeoPolygon(new_ext, g.holes)
end

function geo_buffer(g::AbstractGeometry, distance::Float64; nseg::Int=32)
    c = _geo_centroid(g)
    geo_buffer(c, distance; nseg)
end

"""
    geo_boundary(geom::AbstractGeometry) → AbstractGeometry

Return the boundary of a geometry.
"""
geo_boundary(g::GeoPoint) = GeoCollection(AbstractGeometry[])

function geo_boundary(g::GeoLineString)
    isempty(g.points) && return GeoCollection(AbstractGeometry[])
    if length(g.points) < 2
        return GeoCollection(AbstractGeometry[])
    end
    if _geo_equals_impl(g.points[1], g.points[end])
        return GeoCollection(AbstractGeometry[])  # closed ring
    end
    GeoMultiPoint([g.points[1], g.points[end]])
end

function geo_boundary(g::GeoPolygon)
    rings = GeoLineString[GeoLineString(g.exterior)]
    for hole in g.holes
        push!(rings, GeoLineString(hole))
    end
    length(rings) == 1 ? rings[1] : GeoMultiLineString(rings)
end

function geo_boundary(g::GeoMultiPolygon)
    lines = GeoLineString[]
    for poly in g.polygons
        push!(lines, GeoLineString(poly.exterior))
        for hole in poly.holes
            push!(lines, GeoLineString(hole))
        end
    end
    GeoMultiLineString(lines)
end

geo_boundary(g::GeoMultiPoint) = GeoCollection(AbstractGeometry[])
geo_boundary(g::GeoMultiLineString) = GeoMultiPoint(vcat([
    [l.points[1], l.points[end]] for l in g.lines if length(l.points) >= 2 && !_geo_equals_impl(l.points[1], l.points[end])
]...))
geo_boundary(g::GeoCollection) = GeoCollection([geo_boundary(geom) for geom in g.geometries])
geo_boundary(g::GeoPolyhedralSurface) = GeoCollection([geo_boundary(p) for p in g.patches])
geo_boundary(g::GeoTIN) = GeoCollection([geo_boundary(t) for t in g.triangles])

# ─── WKT Serialization ──────────────────────────────────────────────────────

# Internal helper for 3D detection in WKT output
_has_z(p::GeoPoint) = !isnan(p.z)
_has_z(pts::Vector{GeoPoint}) = !isempty(pts) && !isnan(pts[1].z)

function _wkt_coord(p::GeoPoint)
    # Use compact representation
    sx = isinteger(p.x) ? string(Int(p.x)) : string(p.x)
    sy = isinteger(p.y) ? string(Int(p.y)) : string(p.y)
    if !isnan(p.z)
        sz = isinteger(p.z) ? string(Int(p.z)) : string(p.z)
        return "$sx $sy $sz"
    end
    "$sx $sy"
end

function _wkt_ring(pts::Vector{GeoPoint})
    "(" * join([_wkt_coord(p) for p in pts], ", ") * ")"
end

function to_wkt(g::GeoPoint)
    if !isnan(g.z)
        "POINT Z ($(g.x) $(g.y) $(g.z))"
    else
        "POINT ($(g.x) $(g.y))"
    end
end
function to_wkt(g::GeoLineString)
    z = _has_z(g.points) ? " Z" : ""
    "LINESTRING$z " * _wkt_ring(g.points)
end
function to_wkt(g::GeoPolygon)
    z = _has_z(g.exterior) ? " Z" : ""
    rings = [_wkt_ring(g.exterior)]
    for hole in g.holes
        push!(rings, _wkt_ring(hole))
    end
    "POLYGON$z (" * join(rings, ", ") * ")"
end
function to_wkt(g::GeoMultiPoint)
    z = _has_z(g.points) ? " Z" : ""
    "MULTIPOINT$z (" * join([_wkt_coord(p) for p in g.points], ", ") * ")"
end
function to_wkt(g::GeoMultiLineString)
    z = !isempty(g.lines) && _has_z(g.lines[1].points) ? " Z" : ""
    "MULTILINESTRING$z (" * join([_wkt_ring(l.points) for l in g.lines], ", ") * ")"
end
function to_wkt(g::GeoMultiPolygon)
    z = !isempty(g.polygons) && _has_z(g.polygons[1].exterior) ? " Z" : ""
    parts = String[]
    for poly in g.polygons
        rings = [_wkt_ring(poly.exterior)]
        for hole in poly.holes
            push!(rings, _wkt_ring(hole))
        end
        push!(parts, "(" * join(rings, ", ") * ")")
    end
    "MULTIPOLYGON$z (" * join(parts, ", ") * ")"
end
to_wkt(g::GeoCollection) = "GEOMETRYCOLLECTION (" * join([to_wkt(geom) for geom in g.geometries], ", ") * ")"
function to_wkt(g::GeoPolyhedralSurface)
    z = !isempty(g.patches) && _has_z(g.patches[1].exterior) ? " Z" : ""
    parts = String[]
    for p in g.patches
        rings = [_wkt_ring(p.exterior)]
        for h in p.holes; push!(rings, _wkt_ring(h)); end
        push!(parts, "(" * join(rings, ", ") * ")")
    end
    "POLYHEDRALSURFACE$z (" * join(parts, ", ") * ")"
end
function to_wkt(g::GeoTIN)
    z = !isempty(g.triangles) && _has_z(g.triangles[1].exterior) ? " Z" : ""
    parts = String[]
    for t in g.triangles
        rings = [_wkt_ring(t.exterior)]
        for h in t.holes; push!(rings, _wkt_ring(h)); end
        push!(parts, "(" * join(rings, ", ") * ")")
    end
    "TIN$z (" * join(parts, ", ") * ")"
end

# ─── Geometry Dimension Helper ───────────────────────────────────────────────

function _geom_dimension(g::GeoPoint) 0 end
function _geom_dimension(g::GeoMultiPoint) 0 end
function _geom_dimension(g::GeoLineString) 1 end
function _geom_dimension(g::GeoMultiLineString) 1 end
function _geom_dimension(g::GeoPolygon) 2 end
function _geom_dimension(g::GeoMultiPolygon) 2 end
function _geom_dimension(g::GeoCollection)
    isempty(g.geometries) && return -1
    maximum(_geom_dimension(geom) for geom in g.geometries)
end
function _geom_dimension(::GeoPolyhedralSurface) 2 end
function _geom_dimension(::GeoTIN) 2 end

# ─── Convex Hull (Graham Scan) ───────────────────────────────────────────────

"""
    geo_convex_hull(g::AbstractGeometry) → GeoPolygon

Compute the convex hull of a geometry's points using Graham scan.
"""
function geo_convex_hull(g::AbstractGeometry)
    pts = unique(p -> (p.x, p.y), _all_points(g))
    length(pts) == 0 && return GeoPolygon(GeoPoint[], Vector{GeoPoint}[])
    length(pts) == 1 && return GeoPolygon([pts[1], pts[1]], Vector{GeoPoint}[])
    length(pts) == 2 && return GeoPolygon([pts[1], pts[2], pts[1]], Vector{GeoPoint}[])
    # Find the lowest-then-leftmost point
    p0_idx = 1
    for i in 2:length(pts)
        if pts[i].y < pts[p0_idx].y || (pts[i].y == pts[p0_idx].y && pts[i].x < pts[p0_idx].x)
            p0_idx = i
        end
    end
    p0 = pts[p0_idx]
    rest = [pts[i] for i in eachindex(pts) if i != p0_idx]
    sort!(rest, by=p -> atan(p.y - p0.y, p.x - p0.x))
    hull = [p0, rest[1]]
    for i in 2:length(rest)
        while length(hull) > 1
            o = hull[end-1]; a = hull[end]; b = rest[i]
            cross = (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
            cross <= 0 ? pop!(hull) : break
        end
        push!(hull, rest[i])
    end
    push!(hull, hull[1])  # close ring
    GeoPolygon(hull, Vector{GeoPoint}[])
end

# ─── Envelope (Bounding Box) ────────────────────────────────────────────────

"""
    geo_envelope(g::AbstractGeometry) → GeoPolygon

Return the bounding box of a geometry as a polygon.
"""
function geo_envelope(g::AbstractGeometry)
    bb = _bbox(g)
    GeoPolygon(
        [GeoPoint(bb.xmin, bb.ymin), GeoPoint(bb.xmax, bb.ymin),
         GeoPoint(bb.xmax, bb.ymax), GeoPoint(bb.xmin, bb.ymax),
         GeoPoint(bb.xmin, bb.ymin)],
        Vector{GeoPoint}[]
    )
end

# ─── DE-9IM / geo_relate ────────────────────────────────────────────────────

"""
    geo_relate(a::AbstractGeometry, b::AbstractGeometry) → String

Compute the DE-9IM intersection matrix as a 9-character string.
Characters: 'F' (empty), '0' (point), '1' (line), '2' (area).
Matrix order: II, IB, IE, BI, BB, BE, EI, EB, EE
"""
function geo_relate(a::AbstractGeometry, b::AbstractGeometry)
    _compute_de9im(a, b)
end

function _dim_char(d::Int)
    d < 0 ? 'F' : d == 0 ? '0' : d == 1 ? '1' : '2'
end

function _compute_de9im(a::AbstractGeometry, b::AbstractGeometry)
    da = _geom_dimension(a)
    db = _geom_dimension(b)
    disjoint = geo_disjoint(a, b)
    equals = !disjoint && geo_equals(a, b)
    a_within_b = !disjoint && geo_within(a, b)
    b_within_a = !disjoint && geo_within(b, a)
    touches = !disjoint && geo_touches(a, b)
    overlaps_v = !disjoint && geo_overlaps(a, b)

    # II (Interior-Interior intersection dimension)
    ii = if disjoint || touches
        -1
    elseif equals
        max(da, db)
    elseif overlaps_v
        min(da, db)
    elseif a_within_b || b_within_a
        min(da, db)
    else
        min(da, db)
    end

    # IB (Interior-Boundary)
    ib = if disjoint
        -1
    elseif touches && da >= db
        min(da - 1, 0)
    elseif a_within_b
        -1
    else
        touches ? 0 : (overlaps_v && db >= 1 ? 0 : -1)
    end

    # IE (Interior-Exterior)
    ie = if a_within_b || equals
        -1
    else
        da
    end

    # BI (Boundary-Interior)
    bi = if disjoint
        -1
    elseif touches && db >= da
        min(db - 1, 0)
    elseif b_within_a
        -1
    else
        touches ? 0 : (overlaps_v && da >= 1 ? 0 : -1)
    end

    # BB (Boundary-Boundary)
    bb = if disjoint
        -1
    elseif touches
        min(da - 1, db - 1)
    elseif equals && da >= 1 && db >= 1
        da - 1
    else
        overlaps_v && da >= 1 && db >= 1 ? 0 : -1
    end

    # BE (Boundary-Exterior)
    be = if equals || a_within_b
        da >= 1 ? da - 1 : -1
    else
        da >= 1 ? da - 1 : -1
    end

    # EI (Exterior-Interior)
    ei = if b_within_a || equals
        -1
    else
        db
    end

    # EB (Exterior-Boundary)
    eb = if equals || b_within_a
        db >= 1 ? db - 1 : -1
    else
        db >= 1 ? db - 1 : -1
    end

    # EE always 2
    ee = 2

    string(_dim_char(ii), _dim_char(ib), _dim_char(ie),
           _dim_char(bi), _dim_char(bb), _dim_char(be),
           _dim_char(ei), _dim_char(eb), _dim_char(ee))
end

"""
    geo_relate(a::AbstractGeometry, b::AbstractGeometry, pattern::String) → Bool

Test if the DE-9IM matrix of a and b matches the given pattern.
Pattern characters: 'T' (any non-F), 'F' (empty), '*' (any), '0', '1', '2'.
"""
function geo_relate(a::AbstractGeometry, b::AbstractGeometry, pattern::String)
    length(pattern) != 9 && return false
    matrix = geo_relate(a, b)
    for (i, (m, p)) in enumerate(zip(matrix, pattern))
        p == '*' && continue
        p == 'T' && m == 'F' && return false
        p == 'T' && continue
        m != p && return false
    end
    true
end

# ─── Egenhofer Relations ─────────────────────────────────────────────────────

"""ehContains: Egenhofer Contains — B is inside A with no boundary contact"""
geo_eh_contains(a::AbstractGeometry, b::AbstractGeometry) = geo_relate(a, b, "T*TFF*FF*")

"""ehCoveredBy: A is inside B, boundaries may touch"""
geo_eh_covered_by(a::AbstractGeometry, b::AbstractGeometry) =
    geo_relate(a, b, "TFF*FFT**") || geo_relate(a, b, "T*F*FFT**") ||
    geo_relate(a, b, "TFF**FT**") || geo_relate(a, b, "T*F**FT**")

"""ehCovers: B is inside A, boundaries may touch"""
geo_eh_covers(a::AbstractGeometry, b::AbstractGeometry) = geo_eh_covered_by(b, a)

"""ehDisjoint: no shared points"""
geo_eh_disjoint(a::AbstractGeometry, b::AbstractGeometry) = geo_relate(a, b, "FF*FF****")

"""ehEquals: geometries are equal"""
geo_eh_equals(a::AbstractGeometry, b::AbstractGeometry) = geo_relate(a, b, "TFFFTFFFT")

"""ehInside: A is inside B with no boundary contact"""
geo_eh_inside(a::AbstractGeometry, b::AbstractGeometry) = geo_eh_contains(b, a)

"""ehMeet: boundaries touch, interiors don't overlap"""
geo_eh_meet(a::AbstractGeometry, b::AbstractGeometry) =
    geo_relate(a, b, "FT*******") || geo_relate(a, b, "F**T*****") || geo_relate(a, b, "F***T****")

"""ehOverlap: interiors overlap but neither is within the other"""
geo_eh_overlap(a::AbstractGeometry, b::AbstractGeometry) = geo_relate(a, b, "T*T***T**")

# ─── RCC8 Relations ──────────────────────────────────────────────────────────

"""rcc8dc: disconnected (disjoint)"""
geo_rcc8_dc(a::AbstractGeometry, b::AbstractGeometry) = geo_relate(a, b, "FFTFFTTTT")

"""rcc8ec: externally connected (touch at boundary only)"""
geo_rcc8_ec(a::AbstractGeometry, b::AbstractGeometry) =
    geo_relate(a, b, "FFTFT*TT*") || geo_relate(a, b, "F**FT*TT*")

"""rcc8po: partially overlapping"""
geo_rcc8_po(a::AbstractGeometry, b::AbstractGeometry) = geo_relate(a, b, "T*T***T**")

"""rcc8tpp: tangential proper part (A inside B, boundaries touch)"""
geo_rcc8_tpp(a::AbstractGeometry, b::AbstractGeometry) =
    geo_relate(a, b, "TFFTFFTTT") || geo_relate(a, b, "T*FTFFTTT")

"""rcc8ntpp: non-tangential proper part (A strictly inside B)"""
geo_rcc8_ntpp(a::AbstractGeometry, b::AbstractGeometry) = geo_relate(a, b, "TFFTFFTTT") && !geo_rcc8_tpp(a, b) ? false : geo_relate(a, b, "TFFTTFFFT") ? false : geo_relate(a, b, "TFFFFTFFT")

"""rcc8tppi: tangential proper part inverse"""
geo_rcc8_tppi(a::AbstractGeometry, b::AbstractGeometry) = geo_rcc8_tpp(b, a)

"""rcc8ntppi: non-tangential proper part inverse"""
geo_rcc8_ntppi(a::AbstractGeometry, b::AbstractGeometry) = geo_rcc8_ntpp(b, a)

"""rcc8eq: equal"""
geo_rcc8_eq(a::AbstractGeometry, b::AbstractGeometry) = geo_relate(a, b, "TFFFTFFFT")

# ─── Geometry Property Functions ─────────────────────────────────────────────

"""Return the geometry type name as a string."""
geo_geometry_type(::GeoPoint) = "Point"
geo_geometry_type(::GeoLineString) = "LineString"
geo_geometry_type(::GeoPolygon) = "Polygon"
geo_geometry_type(::GeoMultiPoint) = "MultiPoint"
geo_geometry_type(::GeoMultiLineString) = "MultiLineString"
geo_geometry_type(::GeoMultiPolygon) = "MultiPolygon"
geo_geometry_type(::GeoCollection) = "GeometryCollection"
geo_geometry_type(::GeoPolyhedralSurface) = "PolyhedralSurface"
geo_geometry_type(::GeoTIN) = "TIN"

"""Return the topological dimension (0=point, 1=line, 2=area)."""
geo_dimension(g::AbstractGeometry) = _geom_dimension(g)

"""Return the coordinate dimension (always 2 for our 2D implementation)."""
geo_coordinate_dimension(::AbstractGeometry) = 2

"""Check if a geometry is empty."""
geo_is_empty(::GeoPoint) = false
function geo_is_empty(g::GeoLineString) isempty(g.points) end
function geo_is_empty(g::GeoPolygon) isempty(g.exterior) end
function geo_is_empty(g::GeoMultiPoint) isempty(g.points) end
function geo_is_empty(g::GeoMultiLineString) isempty(g.lines) end
function geo_is_empty(g::GeoMultiPolygon) isempty(g.polygons) end
function geo_is_empty(g::GeoCollection) isempty(g.geometries) end
function geo_is_empty(g::GeoPolyhedralSurface) isempty(g.patches) end
function geo_is_empty(g::GeoTIN) isempty(g.triangles) end

"""Check if a geometry is simple (no self-intersections). Simplified implementation."""
geo_is_simple(::GeoPoint) = true
geo_is_simple(::GeoMultiPoint) = true
function geo_is_simple(g::GeoLineString)
    n = length(g.points)
    n <= 2 && return true
    for i in 1:n-1
        for j in i+2:n-1
            (i == 1 && j == n-1) && continue  # allow closed ring
            if _segments_intersect(g.points[i].x, g.points[i].y, g.points[i+1].x, g.points[i+1].y,
                                   g.points[j].x, g.points[j].y, g.points[j+1].x, g.points[j+1].y)
                return false
            end
        end
    end
    true
end
geo_is_simple(g::GeoPolygon) = true  # assume well-formed
geo_is_simple(g::GeoMultiLineString) = all(geo_is_simple, g.lines)
geo_is_simple(g::GeoMultiPolygon) = true  # assume well-formed
geo_is_simple(g::GeoCollection) = all(geo_is_simple, g.geometries)
geo_is_simple(g::GeoPolyhedralSurface) = true  # assume well-formed
geo_is_simple(g::GeoTIN) = true  # assume well-formed

"""Return the SRID (always 0/unknown for our implementation — no CRS tracking)."""
geo_get_srid(::AbstractGeometry) = 0

"""Return the number of geometries in a collection."""
geo_num_geometries(::GeoPoint) = 1
geo_num_geometries(::GeoLineString) = 1
geo_num_geometries(::GeoPolygon) = 1
geo_num_geometries(g::GeoMultiPoint) = length(g.points)
geo_num_geometries(g::GeoMultiLineString) = length(g.lines)
geo_num_geometries(g::GeoMultiPolygon) = length(g.polygons)
geo_num_geometries(g::GeoCollection) = length(g.geometries)
geo_num_geometries(g::GeoPolyhedralSurface) = length(g.patches)
geo_num_geometries(g::GeoTIN) = length(g.triangles)

"""Return the N-th geometry (1-indexed) from a collection."""
geo_geometry_n(g::GeoPoint, n::Int) = n == 1 ? g : error("index out of bounds")
geo_geometry_n(g::GeoLineString, n::Int) = n == 1 ? g : error("index out of bounds")
geo_geometry_n(g::GeoPolygon, n::Int) = n == 1 ? g : error("index out of bounds")
geo_geometry_n(g::GeoMultiPoint, n::Int) = GeoPoint(g.points[n].x, g.points[n].y)
geo_geometry_n(g::GeoMultiLineString, n::Int) = g.lines[n]
geo_geometry_n(g::GeoMultiPolygon, n::Int) = g.polygons[n]
geo_geometry_n(g::GeoCollection, n::Int) = g.geometries[n]
geo_geometry_n(g::GeoPolyhedralSurface, n::Int) = g.patches[n]
geo_geometry_n(g::GeoTIN, n::Int) = g.triangles[n]

"""Return coordinate bounds."""
geo_min_x(g::AbstractGeometry) = _bbox(g).xmin
geo_max_x(g::AbstractGeometry) = _bbox(g).xmax
geo_min_y(g::AbstractGeometry) = _bbox(g).ymin
geo_max_y(g::AbstractGeometry) = _bbox(g).ymax

# ─── Set-Theoretic Spatial Operations ────────────────────────────────────────

"""
    geo_intersection(a::AbstractGeometry, b::AbstractGeometry) → AbstractGeometry

Compute the geometric intersection of two geometries.
"""
function geo_intersection(a::GeoPolygon, b::GeoPolygon)
    result = _sutherland_hodgman(a.exterior, b.exterior)
    isempty(result) && return GeoCollection(AbstractGeometry[])
    if !isempty(result) && !(result[1].x ≈ result[end].x && result[1].y ≈ result[end].y)
        push!(result, result[1])
    end
    GeoPolygon(result, Vector{GeoPoint}[])
end

function geo_intersection(a::GeoPoint, b::AbstractGeometry)
    geo_disjoint(a, b) ? GeoCollection(AbstractGeometry[]) : a
end
geo_intersection(a::AbstractGeometry, b::GeoPoint) = geo_intersection(b, a)

function geo_intersection(a::AbstractGeometry, b::AbstractGeometry)
    geo_disjoint(a, b) && return GeoCollection(AbstractGeometry[])
    ea = geo_envelope(a)
    eb = geo_envelope(b)
    geo_intersection(ea, eb)
end

function _sutherland_hodgman(subject::Vector{GeoPoint}, clip::Vector{GeoPoint})
    output = copy(subject)
    clip_edges = clip
    if length(clip_edges) > 1 && clip_edges[1].x ≈ clip_edges[end].x && clip_edges[1].y ≈ clip_edges[end].y
        clip_edges = clip_edges[1:end-1]
    end
    if length(output) > 1 && output[1].x ≈ output[end].x && output[1].y ≈ output[end].y
        output = output[1:end-1]
    end

    for i in eachindex(clip_edges)
        isempty(output) && return GeoPoint[]
        j = i == length(clip_edges) ? 1 : i + 1
        edge_start = clip_edges[i]
        edge_end = clip_edges[j]
        input = output
        output = GeoPoint[]
        for k in eachindex(input)
            l = k == length(input) ? 1 : k + 1
            curr = input[k]
            next_pt = input[l]
            curr_inside = _is_inside(curr, edge_start, edge_end)
            next_inside = _is_inside(next_pt, edge_start, edge_end)
            if curr_inside
                push!(output, curr)
                if !next_inside
                    ix = _line_intersection(curr, next_pt, edge_start, edge_end)
                    !isnothing(ix) && push!(output, ix)
                end
            elseif next_inside
                ix = _line_intersection(curr, next_pt, edge_start, edge_end)
                !isnothing(ix) && push!(output, ix)
            end
        end
    end
    output
end

function _is_inside(p::GeoPoint, edge_start::GeoPoint, edge_end::GeoPoint)
    (edge_end.x - edge_start.x) * (p.y - edge_start.y) -
    (edge_end.y - edge_start.y) * (p.x - edge_start.x) >= 0
end

function _line_intersection(p1::GeoPoint, p2::GeoPoint, p3::GeoPoint, p4::GeoPoint)
    x1, y1 = p1.x, p1.y; x2, y2 = p2.x, p2.y
    x3, y3 = p3.x, p3.y; x4, y4 = p4.x, p4.y
    denom = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
    abs(denom) < 1e-15 && return nothing
    t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / denom
    GeoPoint(x1 + t * (x2 - x1), y1 + t * (y2 - y1))
end

"""
    geo_union(a::AbstractGeometry, b::AbstractGeometry) → AbstractGeometry

Compute the geometric union. For polygons, returns a GeoMultiPolygon or merged polygon.
"""
function geo_union(a::GeoPolygon, b::GeoPolygon)
    if geo_disjoint(a, b)
        return GeoMultiPolygon([a, b])
    end
    if geo_within(a, b)
        return b
    end
    if geo_within(b, a)
        return a
    end
    all_pts = vcat(_all_points(a), _all_points(b))
    geo_convex_hull(GeoMultiPoint(all_pts))
end

geo_union(a::AbstractGeometry, b::AbstractGeometry) = GeoCollection([a, b])

"""
    geo_difference(a::AbstractGeometry, b::AbstractGeometry) → AbstractGeometry

Compute the geometric difference (a minus b).
"""
function geo_difference(a::GeoPolygon, b::GeoPolygon)
    geo_disjoint(a, b) && return a
    geo_within(a, b) && return GeoCollection(AbstractGeometry[])
    if geo_intersects(a, b) && !geo_within(b, a)
        return a  # simplified — full difference is complex
    end
    GeoPolygon(a.exterior, vcat(a.holes, [b.exterior]))
end

geo_difference(a::AbstractGeometry, b::AbstractGeometry) =
    geo_disjoint(a, b) ? a : GeoCollection(AbstractGeometry[])

"""
    geo_sym_difference(a::AbstractGeometry, b::AbstractGeometry) → AbstractGeometry

Compute the symmetric difference.
"""
function geo_sym_difference(a::GeoPolygon, b::GeoPolygon)
    geo_disjoint(a, b) && return GeoMultiPolygon([a, b])
    geo_equals(a, b) && return GeoCollection(AbstractGeometry[])
    GeoCollection([geo_difference(a, b), geo_difference(b, a)])
end

geo_sym_difference(a::AbstractGeometry, b::AbstractGeometry) = GeoCollection([a, b])

# ─── GeoJSON Conversion ─────────────────────────────────────────────────────

"""
    to_geojson(g::AbstractGeometry) → String

Convert a geometry to GeoJSON string.
"""
function to_geojson(g::GeoPoint)
    if !isnan(g.z)
        "{\"type\":\"Point\",\"coordinates\":[$(g.x),$(g.y),$(g.z)]}"
    else
        "{\"type\":\"Point\",\"coordinates\":[$(g.x),$(g.y)]}"
    end
end

function to_geojson(g::GeoLineString)
    coords = join(["[$(p.x),$(p.y)]" for p in g.points], ",")
    "{\"type\":\"LineString\",\"coordinates\":[$coords]}"
end

function to_geojson(g::GeoPolygon)
    rings = String[]
    push!(rings, "[" * join(["[$(p.x),$(p.y)]" for p in g.exterior], ",") * "]")
    for hole in g.holes
        push!(rings, "[" * join(["[$(p.x),$(p.y)]" for p in hole], ",") * "]")
    end
    "{\"type\":\"Polygon\",\"coordinates\":[$(join(rings, ","))]}"
end

function to_geojson(g::GeoMultiPoint)
    coords = join(["[$(p.x),$(p.y)]" for p in g.points], ",")
    "{\"type\":\"MultiPoint\",\"coordinates\":[$coords]}"
end

function to_geojson(g::GeoMultiLineString)
    lines = join(["[" * join(["[$(p.x),$(p.y)]" for p in l.points], ",") * "]" for l in g.lines], ",")
    "{\"type\":\"MultiLineString\",\"coordinates\":[$lines]}"
end

function to_geojson(g::GeoMultiPolygon)
    polys = String[]
    for poly in g.polygons
        rings = String[]
        push!(rings, "[" * join(["[$(p.x),$(p.y)]" for p in poly.exterior], ",") * "]")
        for hole in poly.holes
            push!(rings, "[" * join(["[$(p.x),$(p.y)]" for p in hole], ",") * "]")
        end
        push!(polys, "[" * join(rings, ",") * "]")
    end
    "{\"type\":\"MultiPolygon\",\"coordinates\":[$(join(polys, ","))]}"
end

function to_geojson(g::GeoCollection)
    geoms = join([to_geojson(geom) for geom in g.geometries], ",")
    "{\"type\":\"GeometryCollection\",\"geometries\":[$geoms]}"
end

function to_geojson(g::GeoPolyhedralSurface)
    polys = [to_geojson(p) for p in g.patches]
    "{\"type\":\"GeometryCollection\",\"geometries\":[" * join(polys, ",") * "]}"
end
function to_geojson(g::GeoTIN)
    tris = [to_geojson(t) for t in g.triangles]
    "{\"type\":\"GeometryCollection\",\"geometries\":[" * join(tris, ",") * "]}"
end

# Aliases for SPARQL integration
const geo_to_wkt = to_wkt
const geo_to_geojson = to_geojson

# ─── 3D Functions (GeoSPARQL 1.3) ───────────────────────────────────────────

geo_is_3d(g::GeoPoint) = !isnan(g.z)
geo_is_3d(g::GeoLineString) = !isempty(g.points) && !isnan(g.points[1].z)
geo_is_3d(g::GeoPolygon) = !isempty(g.exterior) && !isnan(g.exterior[1].z)
geo_is_3d(g::GeoMultiPoint) = !isempty(g.points) && !isnan(g.points[1].z)
geo_is_3d(g::GeoMultiLineString) = !isempty(g.lines) && geo_is_3d(g.lines[1])
geo_is_3d(g::GeoMultiPolygon) = !isempty(g.polygons) && geo_is_3d(g.polygons[1])
geo_is_3d(g::GeoCollection) = !isempty(g.geometries) && geo_is_3d(g.geometries[1])
geo_is_3d(g::GeoPolyhedralSurface) = !isempty(g.patches) && geo_is_3d(g.patches[1])
geo_is_3d(g::GeoTIN) = !isempty(g.triangles) && geo_is_3d(g.triangles[1])

geo_is_measured(::AbstractGeometry) = false

function geo_volume(g::GeoPolyhedralSurface)
    vol = 0.0
    for patch in g.patches
        pts = patch.exterior
        length(pts) < 4 && continue
        p0 = pts[1]
        for i in 2:length(pts)-2
            p1 = pts[i]; p2 = pts[i+1]
            z0 = isnan(p0.z) ? 0.0 : p0.z
            z1 = isnan(p1.z) ? 0.0 : p1.z
            z2 = isnan(p2.z) ? 0.0 : p2.z
            vol += p0.x * (p1.y * z2 - p2.y * z1) -
                   p0.y * (p1.x * z2 - p2.x * z1) +
                   z0 * (p1.x * p2.y - p2.x * p1.y)
        end
    end
    abs(vol) / 6.0
end
geo_volume(::AbstractGeometry) = 0.0

function geo_surface_area(g::GeoPolyhedralSurface)
    area = 0.0
    for patch in g.patches
        pts = patch.exterior
        length(pts) < 4 && continue
        p0 = pts[1]
        for i in 2:length(pts)-2
            p1 = pts[i]; p2 = pts[i+1]
            z0 = isnan(p0.z) ? 0.0 : p0.z
            z1 = isnan(p1.z) ? 0.0 : p1.z
            z2 = isnan(p2.z) ? 0.0 : p2.z
            ax, ay, az = p1.x-p0.x, p1.y-p0.y, z1-z0
            bx, by, bz = p2.x-p0.x, p2.y-p0.y, z2-z0
            cx = ay*bz - az*by; cy = az*bx - ax*bz; cz = ax*by - ay*bx
            area += sqrt(cx^2 + cy^2 + cz^2) / 2.0
        end
    end
    area
end
function geo_surface_area(g::GeoTIN)
    geo_surface_area(GeoPolyhedralSurface(g.triangles))
end
geo_surface_area(::AbstractGeometry) = 0.0

# ─── Helper: extract WKT from Literal ───────────────────────────────────────

function _extract_wkt_geometry(val)
    isnothing(val) && return nothing
    s = if val isa Literal
        val.lexical
    elseif val isa AbstractString
        val
    else
        string(val)
    end
    try
        return parse_wkt(s)
    catch
        return nothing
    end
end
