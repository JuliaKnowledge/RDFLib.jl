# GeoSPARQL

Spatial data support following the OGC GeoSPARQL standard.

## Parsing and Serialization

```@docs
parse_wkt
to_geojson
geo_to_geojson
```

## Spatial Predicates

```@docs
geo_contains
geo_within
geo_intersects
geo_disjoint
geo_equals
geo_touches
geo_overlaps
geo_crosses
```

## Metric Functions

```@docs
geo_distance
geo_area
geo_length
geo_perimeter
geo_buffer
geo_boundary
geo_centroid
geo_convex_hull
geo_envelope
geo_relate
```

## Set Operations

```@docs
geo_intersection
geo_union
geo_difference
geo_sym_difference
```

## Geometry Properties

```@docs
geo_geometry_type
geo_dimension
geo_coordinate_dimension
geo_is_empty
geo_is_simple
geo_get_srid
geo_num_geometries
geo_geometry_n
geo_min_x
```

## Egenhofer Relations

```@docs
geo_eh_contains
geo_eh_covered_by
geo_eh_covers
geo_eh_disjoint
geo_eh_equals
geo_eh_inside
geo_eh_meet
geo_eh_overlap
```

## RCC8 Relations

```@docs
geo_rcc8_dc
geo_rcc8_ec
geo_rcc8_po
geo_rcc8_tpp
geo_rcc8_ntpp
geo_rcc8_tppi
geo_rcc8_ntppi
geo_rcc8_eq
```
