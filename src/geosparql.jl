# ─── GeoSPARQL Support ─────────────────────────────────────────────────────
# WKT parsing, spatial relations (Simple Features), metric functions,
# and SPARQL integration for GeoSPARQL function URIs.

# ─── GEOF Namespace ──────────────────────────────────────────────────────────

const GEOF = DefinedNamespace(
    "http://www.opengis.net/def/function/geosparql/",
    Set(["sfContains", "sfWithin", "sfIntersects", "sfOverlaps",
         "sfTouches", "sfDisjoint", "sfEquals", "sfCrosses",
         "distance", "buffer", "area", "boundary",
         "ehContains", "ehCoveredBy", "ehCovers", "ehDisjoint",
         "ehEquals", "ehInside", "ehMeet", "ehOverlap"])
)

const _GEOF_NS = "http://www.opengis.net/def/function/geosparql/"
const _GEO_NS  = "http://www.opengis.net/ont/geosparql#"
const _GEO_WKT_LITERAL = URIRef("http://www.opengis.net/ont/geosparql#wktLiteral")

# ─── Geometry Types ──────────────────────────────────────────────────────────

abstract type AbstractGeometry end

struct GeoPoint <: AbstractGeometry
    x::Float64
    y::Float64
end

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
    su = uppercase(s)
    if startswith(su, "GEOMETRYCOLLECTION")
        return _parse_wkt_geometrycollection(s)
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
    GeoPoint(parse(Float64, parts[1]), parse(Float64, parts[2]))
end

function _parse_wkt_coord_list(s::AbstractString)
    [_parse_wkt_coord(c) for c in split(s, ",")]
end

function _parse_wkt_point(s::AbstractString)
    inner = _wkt_extract_parens(s, "POINT")
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

# ─── Spatial Relations (Simple Features) ─────────────────────────────────────

"""
    geo_equals(a::AbstractGeometry, b::AbstractGeometry) → Bool

Test if two geometries are geometrically equal (same points within tolerance).
"""
function geo_equals(a::AbstractGeometry, b::AbstractGeometry)
    _geo_equals_impl(a, b)
end

function _geo_equals_impl(a::GeoPoint, b::GeoPoint; tol=1e-10)
    abs(a.x - b.x) < tol && abs(a.y - b.y) < tol
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
    sqrt((a.x - b.x)^2 + (a.y - b.y)^2)
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

# ─── WKT Serialization ──────────────────────────────────────────────────────

function _wkt_coord(p::GeoPoint)
    # Use compact representation
    sx = isinteger(p.x) ? string(Int(p.x)) : string(p.x)
    sy = isinteger(p.y) ? string(Int(p.y)) : string(p.y)
    "$sx $sy"
end

function _wkt_ring(pts::Vector{GeoPoint})
    "(" * join([_wkt_coord(p) for p in pts], ", ") * ")"
end

to_wkt(g::GeoPoint) = "POINT ($(g.x) $(g.y))"
to_wkt(g::GeoLineString) = "LINESTRING " * _wkt_ring(g.points)
function to_wkt(g::GeoPolygon)
    rings = [_wkt_ring(g.exterior)]
    for hole in g.holes
        push!(rings, _wkt_ring(hole))
    end
    "POLYGON (" * join(rings, ", ") * ")"
end
to_wkt(g::GeoMultiPoint) = "MULTIPOINT (" * join([_wkt_coord(p) for p in g.points], ", ") * ")"
to_wkt(g::GeoMultiLineString) = "MULTILINESTRING (" * join([_wkt_ring(l.points) for l in g.lines], ", ") * ")"
function to_wkt(g::GeoMultiPolygon)
    parts = String[]
    for poly in g.polygons
        rings = [_wkt_ring(poly.exterior)]
        for hole in poly.holes
            push!(rings, _wkt_ring(hole))
        end
        push!(parts, "(" * join(rings, ", ") * ")")
    end
    "MULTIPOLYGON (" * join(parts, ", ") * ")"
end
to_wkt(g::GeoCollection) = "GEOMETRYCOLLECTION (" * join([to_wkt(geom) for geom in g.geometries], ", ") * ")"

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
