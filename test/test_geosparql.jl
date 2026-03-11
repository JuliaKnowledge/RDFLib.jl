@testset "GeoSPARQL" begin

    @testset "WKT Parsing" begin
        @testset "POINT" begin
            p = parse_wkt("POINT (1.0 2.0)")
            @test p isa GeoPoint
            @test p.x ≈ 1.0
            @test p.y ≈ 2.0

            # No space after POINT
            p2 = parse_wkt("POINT(3 4)")
            @test p2 isa GeoPoint
            @test p2.x ≈ 3.0
            @test p2.y ≈ 4.0
        end

        @testset "LINESTRING" begin
            ls = parse_wkt("LINESTRING (0 0, 1 1, 2 0)")
            @test ls isa GeoLineString
            @test length(ls.points) == 3
            @test ls.points[1].x ≈ 0.0
            @test ls.points[3].y ≈ 0.0
        end

        @testset "POLYGON" begin
            poly = parse_wkt("POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0))")
            @test poly isa GeoPolygon
            @test length(poly.exterior) == 5
            @test isempty(poly.holes)

            # With hole
            poly_h = parse_wkt("POLYGON ((0 0, 20 0, 20 20, 0 20, 0 0), (5 5, 15 5, 15 15, 5 15, 5 5))")
            @test poly_h isa GeoPolygon
            @test length(poly_h.holes) == 1
            @test length(poly_h.holes[1]) == 5
        end

        @testset "MULTIPOINT" begin
            mp = parse_wkt("MULTIPOINT ((0 0), (1 1), (2 2))")
            @test mp isa GeoMultiPoint
            @test length(mp.points) == 3

            # Alternate syntax
            mp2 = parse_wkt("MULTIPOINT (0 0, 1 1)")
            @test mp2 isa GeoMultiPoint
            @test length(mp2.points) == 2
        end

        @testset "MULTILINESTRING" begin
            mls = parse_wkt("MULTILINESTRING ((0 0, 1 1), (2 2, 3 3))")
            @test mls isa GeoMultiLineString
            @test length(mls.lines) == 2
        end

        @testset "MULTIPOLYGON" begin
            mpoly = parse_wkt("MULTIPOLYGON (((0 0, 1 0, 1 1, 0 1, 0 0)), ((2 2, 3 2, 3 3, 2 3, 2 2)))")
            @test mpoly isa GeoMultiPolygon
            @test length(mpoly.polygons) == 2
        end

        @testset "GEOMETRYCOLLECTION" begin
            gc = parse_wkt("GEOMETRYCOLLECTION (POINT (0 0), LINESTRING (0 0, 1 1))")
            @test gc isa GeoCollection
            @test length(gc.geometries) == 2
            @test gc.geometries[1] isa GeoPoint
            @test gc.geometries[2] isa GeoLineString
        end

        @testset "SRID prefix" begin
            p = parse_wkt("SRID=4326;POINT(1 2)")
            @test p isa GeoPoint
            @test p.x ≈ 1.0
        end
    end

    @testset "Spatial Relations" begin
        square = parse_wkt("POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0))")
        inside_pt = parse_wkt("POINT (5 5)")
        outside_pt = parse_wkt("POINT (15 15)")
        edge_pt = parse_wkt("POINT (0 5)")

        @testset "contains/within" begin
            @test geo_contains(square, inside_pt) == true
            @test geo_contains(square, outside_pt) == false
            @test geo_within(inside_pt, square) == true
            @test geo_within(outside_pt, square) == false
        end

        @testset "intersects/disjoint" begin
            @test geo_intersects(square, inside_pt) == true
            @test geo_disjoint(square, outside_pt) == true
            @test geo_disjoint(square, inside_pt) == false
        end

        @testset "equals" begin
            sq2 = parse_wkt("POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0))")
            @test geo_equals(square, sq2) == true
            @test geo_equals(inside_pt, outside_pt) == false
            p1 = parse_wkt("POINT (1 2)")
            p2 = parse_wkt("POINT (1 2)")
            @test geo_equals(p1, p2) == true
        end

        @testset "touches" begin
            @test geo_touches(edge_pt, square) == true
            @test geo_touches(inside_pt, square) == false
            @test geo_touches(outside_pt, square) == false
        end

        @testset "overlaps" begin
            sq2 = parse_wkt("POLYGON ((5 5, 15 5, 15 15, 5 15, 5 5))")
            @test geo_overlaps(square, sq2) == true
            small = parse_wkt("POLYGON ((1 1, 2 1, 2 2, 1 2, 1 1))")
            @test geo_overlaps(square, small) == false  # contained, not overlapping
        end

        @testset "polygon-polygon disjoint" begin
            sq1 = parse_wkt("POLYGON ((0 0, 1 0, 1 1, 0 1, 0 0))")
            sq2 = parse_wkt("POLYGON ((5 5, 6 5, 6 6, 5 6, 5 5))")
            @test geo_disjoint(sq1, sq2) == true
            @test geo_intersects(sq1, sq2) == false
        end

        @testset "linestring relations" begin
            line = parse_wkt("LINESTRING (5 0, 5 10)")
            @test geo_intersects(line, square) == true
            @test geo_within(line, square) == true

            line_outside = parse_wkt("LINESTRING (20 0, 20 10)")
            @test geo_disjoint(line_outside, square) == true
        end
    end

    @testset "Distance" begin
        p1 = parse_wkt("POINT (0 0)")
        p2 = parse_wkt("POINT (3 4)")
        @test geo_distance(p1, p2) ≈ 5.0

        p3 = parse_wkt("POINT (1 0)")
        @test geo_distance(p1, p3) ≈ 1.0

        # Distance to polygon (point inside)
        square = parse_wkt("POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0))")
        p_inside = parse_wkt("POINT (5 5)")
        @test geo_distance(p_inside, square) ≈ 0.0

        # Distance to polygon (point outside)
        p_outside = parse_wkt("POINT (15 5)")
        @test geo_distance(p_outside, square) ≈ 5.0
    end

    @testset "Area" begin
        square = parse_wkt("POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0))")
        @test geo_area(square) ≈ 100.0

        # Triangle
        tri = parse_wkt("POLYGON ((0 0, 10 0, 5 10, 0 0))")
        @test geo_area(tri) ≈ 50.0

        # Point has zero area
        @test geo_area(parse_wkt("POINT (1 2)")) ≈ 0.0

        # Polygon with hole
        poly_h = parse_wkt("POLYGON ((0 0, 20 0, 20 20, 0 20, 0 0), (5 5, 15 5, 15 15, 5 15, 5 5))")
        @test geo_area(poly_h) ≈ 300.0  # 400 - 100
    end

    @testset "Buffer" begin
        p = parse_wkt("POINT (0 0)")
        buffered = geo_buffer(p, 1.0)
        @test buffered isa GeoPolygon
        @test length(buffered.exterior) == 33  # 32 + closing point
        # All points should be approximately 1 unit from origin
        for pt in buffered.exterior[1:end-1]
            @test sqrt(pt.x^2 + pt.y^2) ≈ 1.0 atol=0.01
        end
    end

    @testset "Boundary" begin
        poly = parse_wkt("POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0))")
        b = geo_boundary(poly)
        @test b isa GeoLineString
        @test length(b.points) == 5

        line = parse_wkt("LINESTRING (0 0, 10 10)")
        b2 = geo_boundary(line)
        @test b2 isa GeoMultiPoint
        @test length(b2.points) == 2
    end

    @testset "WKT Serialization" begin
        p = parse_wkt("POINT (1.0 2.0)")
        @test occursin("POINT", to_wkt(p))
        @test occursin("1.0", to_wkt(p))

        poly = parse_wkt("POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0))")
        wkt = to_wkt(poly)
        @test startswith(wkt, "POLYGON")
        # Round-trip
        poly2 = parse_wkt(wkt)
        @test geo_equals(poly, poly2)
    end

    @testset "SPARQL GeoSPARQL Functions" begin
        g = RDFGraph()
        geo_ns = "http://www.opengis.net/ont/geosparql#"
        wkt_dt = URIRef("$(geo_ns)wktLiteral")
        ex = "http://example.org/"

        # Add some spatial data
        add!(g, Triple(
            URIRef("$(ex)place1"),
            URIRef("$(geo_ns)asWKT"),
            Literal("POINT (5 5)", datatype=wkt_dt)
        ))
        add!(g, Triple(
            URIRef("$(ex)place1"),
            URIRef("$(ex)type"),
            Literal("place")
        ))
        add!(g, Triple(
            URIRef("$(ex)place2"),
            URIRef("$(geo_ns)asWKT"),
            Literal("POINT (8 9)", datatype=wkt_dt)
        ))
        add!(g, Triple(
            URIRef("$(ex)place2"),
            URIRef("$(ex)type"),
            Literal("place")
        ))
        add!(g, Triple(
            URIRef("$(ex)region1"),
            URIRef("$(geo_ns)asWKT"),
            Literal("POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0))", datatype=wkt_dt)
        ))

        @testset "geof:distance in BIND" begin
            query = """
            PREFIX geo: <http://www.opengis.net/ont/geosparql#>
            PREFIX geof: <http://www.opengis.net/def/function/geosparql/>
            PREFIX ex: <http://example.org/>
            SELECT ?place ?wkt ?dist
            WHERE {
                ?place geo:asWKT ?wkt .
                ?place ex:type "place" .
                BIND(geof:distance(?wkt, "POINT (0 0)") AS ?dist)
            }
            """
            results = sparql_query(g, query)
            @test length(results) == 2
            dists = [parse(Float64, r["dist"].lexical) for r in results]
            @test all(d -> d > 0, dists)
        end

        @testset "geof:sfContains in FILTER" begin
            query = """
            PREFIX geo: <http://www.opengis.net/ont/geosparql#>
            PREFIX geof: <http://www.opengis.net/def/function/geosparql/>
            PREFIX ex: <http://example.org/>
            SELECT ?place ?wkt
            WHERE {
                ?place geo:asWKT ?wkt .
                ?place ex:type "place" .
                <http://example.org/region1> geo:asWKT ?regionWkt .
                FILTER(geof:sfContains(?regionWkt, ?wkt))
            }
            """
            results = sparql_query(g, query)
            @test length(results) == 2
        end

        @testset "geof:sfWithin in BIND" begin
            query = """
            PREFIX geo: <http://www.opengis.net/ont/geosparql#>
            PREFIX geof: <http://www.opengis.net/def/function/geosparql/>
            SELECT ?within
            WHERE {
                <http://example.org/place1> geo:asWKT ?wkt .
                BIND(geof:sfWithin(?wkt, "POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0))") AS ?within)
            }
            """
            results = sparql_query(g, query)
            @test length(results) == 1
            @test results[1]["within"].lexical == "true"
        end
    end

    @testset "GEOF Namespace" begin
        @test GEOF isa DefinedNamespace
        contains_uri = GEOF.sfContains
        @test contains_uri isa URIRef
        @test string(contains_uri) == "http://www.opengis.net/def/function/geosparql/sfContains"
    end

    @testset "MultiPolygon operations" begin
        mp = parse_wkt("MULTIPOLYGON (((0 0, 5 0, 5 5, 0 5, 0 0)), ((10 10, 15 10, 15 15, 10 15, 10 10)))")
        @test mp isa GeoMultiPolygon
        @test geo_area(mp) ≈ 50.0  # 25 + 25
    end

    @testset "Edge cases" begin
        # Point equals itself
        p = parse_wkt("POINT (0 0)")
        @test geo_equals(p, p) == true
        @test geo_disjoint(p, p) == false
        @test geo_distance(p, p) ≈ 0.0

        # Point at polygon vertex
        poly = parse_wkt("POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0))")
        vertex = parse_wkt("POINT (0 0)")
        @test geo_touches(vertex, poly) == true
    end

    @testset "GeoSPARQL 1.3 - 3D Support" begin
        @testset "3D Point" begin
            p = parse_wkt("POINT Z (1 2 3)")
            @test p isa GeoPoint
            @test p.x == 1.0
            @test p.y == 2.0
            @test p.z == 3.0
            @test geo_is_3d(p) == true
            
            p2 = parse_wkt("POINT (4 5)")
            @test isnan(p2.z)
            @test geo_is_3d(p2) == false
            
            # WKT roundtrip
            @test to_wkt(p) == "POINT Z (1.0 2.0 3.0)"
            @test to_wkt(p2) == "POINT (4.0 5.0)"
        end

        @testset "3D LineString" begin
            ls = parse_wkt("LINESTRING Z (0 0 0, 1 1 1, 2 0 2)")
            @test ls isa GeoLineString
            @test length(ls.points) == 3
            @test ls.points[1].z == 0.0
            @test ls.points[2].z == 1.0
            @test ls.points[3].z == 2.0
            @test geo_is_3d(ls) == true
            @test startswith(to_wkt(ls), "LINESTRING Z")
        end

        @testset "3D Polygon" begin
            poly = parse_wkt("POLYGON Z ((0 0 0, 10 0 0, 10 10 0, 0 10 0, 0 0 0))")
            @test poly isa GeoPolygon
            @test length(poly.exterior) == 5
            @test poly.exterior[1].z == 0.0
            @test geo_is_3d(poly) == true
            @test startswith(to_wkt(poly), "POLYGON Z")
        end

        @testset "3D Distance" begin
            a = GeoPoint(0.0, 0.0, 0.0)
            b = GeoPoint(1.0, 0.0, 0.0)
            @test geo_distance(a, b) == 1.0
            
            c = GeoPoint(0.0, 0.0, 1.0)
            @test geo_distance(a, c) == 1.0
            
            d = GeoPoint(1.0, 1.0, 1.0)
            @test geo_distance(a, d) ≈ sqrt(3.0)
        end

        @testset "3D Equality" begin
            a = GeoPoint(1.0, 2.0, 3.0)
            b = GeoPoint(1.0, 2.0, 3.0)
            c = GeoPoint(1.0, 2.0, 4.0)
            d = GeoPoint(1.0, 2.0)  # 2D
            @test geo_equals(a, b) == true
            @test geo_equals(a, c) == false
            @test geo_equals(a, d) == false
        end

        @testset "GeoJSON 3D" begin
            p = GeoPoint(1.0, 2.0, 3.0)
            json = to_geojson(p)
            @test occursin("[1.0,2.0,3.0]", json)
            
            p2 = GeoPoint(1.0, 2.0)
            json2 = to_geojson(p2)
            @test occursin("[1.0,2.0]", json2)
            @test !occursin("NaN", json2)
        end

        @testset "PolyhedralSurface" begin
            # Unit cube bottom face
            wkt = "POLYHEDRALSURFACE Z (((0 0 0, 1 0 0, 1 1 0, 0 1 0, 0 0 0)), ((0 0 1, 1 0 1, 1 1 1, 0 1 1, 0 0 1)))"
            ps = parse_wkt(wkt)
            @test ps isa GeoPolyhedralSurface
            @test length(ps.patches) == 2
            @test geo_is_3d(ps) == true
            @test geo_geometry_type(ps) == "PolyhedralSurface"
            @test geo_num_geometries(ps) == 2
            @test geo_is_empty(ps) == false
            @test startswith(to_wkt(ps), "POLYHEDRALSURFACE Z")
        end

        @testset "TIN" begin
            wkt = "TIN Z (((0 0 0, 1 0 0, 0 1 0, 0 0 0)), ((0 0 0, 0 1 0, 0 0 1, 0 0 0)))"
            tin = parse_wkt(wkt)
            @test tin isa GeoTIN
            @test length(tin.triangles) == 2
            @test geo_is_3d(tin) == true
            @test geo_geometry_type(tin) == "TIN"
            @test geo_num_geometries(tin) == 2
        end

        @testset "Volume and Surface Area" begin
            # Tetrahedron: vertices at (0,0,0), (1,0,0), (0,1,0), (0,0,1)
            # Volume = 1/6
            faces = [
                GeoPolygon([GeoPoint(0,0,0), GeoPoint(1,0,0), GeoPoint(0,1,0), GeoPoint(0,0,0)], Vector{GeoPoint}[]),
                GeoPolygon([GeoPoint(0,0,0), GeoPoint(0,0,1), GeoPoint(1,0,0), GeoPoint(0,0,0)], Vector{GeoPoint}[]),
                GeoPolygon([GeoPoint(0,0,0), GeoPoint(0,1,0), GeoPoint(0,0,1), GeoPoint(0,0,0)], Vector{GeoPoint}[]),
                GeoPolygon([GeoPoint(1,0,0), GeoPoint(0,0,1), GeoPoint(0,1,0), GeoPoint(1,0,0)], Vector{GeoPoint}[]),
            ]
            ps = GeoPolyhedralSurface(faces)
            @test geo_volume(ps) ≈ 1/6 atol=0.01
            @test geo_surface_area(ps) > 0.0
        end

        @testset "is_measured" begin
            @test geo_is_measured(GeoPoint(1.0, 2.0)) == false
            @test geo_is_measured(GeoPoint(1.0, 2.0, 3.0)) == false
        end

        @testset "ZM parsing" begin
            # ZM should parse, M value ignored
            p = parse_wkt("POINT ZM (1 2 3 4)")
            @test p isa GeoPoint
            @test p.x == 1.0
            @test p.y == 2.0
            @test p.z == 3.0
        end
    end
end
